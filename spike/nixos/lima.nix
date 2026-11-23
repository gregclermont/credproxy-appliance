# Lima provisioning without cloud-init: spike/mkosi's lima-init and
# lima-boot units around the same scripts, plus what Lima's boot scripts
# assume of an FHS distro, and the files they would write, pre-shipped
# byte-identical so they skip restarts and reloads.
{ pkgs, lib, ... }:
let
  mkosiExtra = ../mkosi/mkosi.extra;
  # what Lima's boot scripts and lima-init call
  limaPath = with pkgs; [
    bash coreutils findutils gnused gnugrep gawk util-linux shadow kmod
    iproute2 e2fsprogs systemd procps gzip hostname-debian getent openssh
  ];
  # /etc/systemd/system is a symlink into the store, even with the etc
  # overlay; lima-init (and Lima's install-systemd after it) write the
  # guest agent unit there. A copy of the directory (its entries stay
  # symlinks to the same units) makes it writable on the tmpfs upper layer.
  # The guest agent's wants link then points where `systemctl enable` would
  # put it, or Lima's install-systemd relinks it and reloads PID 1 (0.2 s,
  # once 8 s under load).
  unitDirWritable = pkgs.writeShellScript "cpvm-unitdir-writable" ''
    d=/etc/systemd/system
    [ -L $d ] || exit 0
    t=$(${pkgs.coreutils}/bin/readlink -f $d)
    ${pkgs.coreutils}/bin/rm $d
    ${pkgs.coreutils}/bin/cp -a "$t" $d
    ${pkgs.coreutils}/bin/chmod -R u+w $d
    ${pkgs.coreutils}/bin/ln -sfn $d/lima-guestagent.service $d/multi-user.target.wants/lima-guestagent.service
  '';
in
{
  environment.systemPackages = limaPath;

  systemd.tmpfiles.rules = [
    # Lima's scripts use #!/bin/bash, and the Lima user's login shell is /bin/bash
    "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
    "d /etc/sudoers.d 0750 root root -"
    # lima-init links /etc/localtime into it
    "L+ /usr/share/zoneinfo - - - - ${pkgs.tzdata}/share/zoneinfo"
  ];

  # lima-init's useradd: a group of the user's own (gid = uid), as on Debian
  # and as cloud-init does, not NixOS's default `users` group
  security.loginDefs.settings.USERGROUPS_ENAB = "yes";

  # lima-init writes /etc/sudoers.d/90-lima-users
  security.sudo.extraConfig = "@includedir /etc/sudoers.d";

  systemd.services.lima-init = {
    description = "Lima user and SSH key from cidata (replaces cloud-init)";
    after = [ "local-fs.target" "systemd-logind.service" "userborn.service" "systemd-tmpfiles-setup.service" ];
    before = [ "sshd.service" "systemd-user-sessions.service" ];
    wantedBy = [ "multi-user.target" ];
    path = limaPath;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPre = "${unitDirWritable}";
      ExecStart = "${pkgs.bash}/bin/sh ${mkosiExtra}/usr/libexec/lima-init";
    };
  };

  systemd.services.lima-boot = {
    description = "Lima boot scripts (cidata boot.sh, cloud-init per-boot in stock images)";
    requires = [ "lima-init.service" ];
    # after dockerd: nothing on a workspace's start path needs boot.sh, and
    # its work (a PID 1 reload among it) would compete with dockerd's start
    # (as spike/mkosi's lima-boot.service)
    after = [ "lima-init.service" "systemd-resolved.service" "network.target" "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    # sudo is the setuid wrapper in /run/wrappers/bin
    path = limaPath ++ [ "/run/wrappers" ];
    environment.LIMA_CIDATA_MNT = "/mnt/lima-cidata";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "/mnt/lima-cidata/boot.sh";
      Nice = 10;
      CPUWeight = 20;
      IOWeight = 20;
    };
  };

  # Lima's 00-modprobe.sh list, off the critical path; br_netfilter is
  # dockerd's, on its start path otherwise. Without ip_tables, ip6_tables
  # and the iptable_* tables: nixpkgs' kernel has no
  # CONFIG_IP_NF_IPTABLES_LEGACY (Debian's has), so Lima's script logs them
  # as missing; iptables here is the nft backend.
  systemd.services.lima-modules = {
    description = "Kernel modules Lima's boot scripts load (00-modprobe.sh), early and in parallel";
    unitConfig.DefaultDependencies = false;
    before = [ "lima-boot.service" "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = [
        "-${pkgs.kmod}/bin/modprobe -a fuse tun tap bridge veth nf_tables x_tables xt_MASQUERADE xt_addrtype xt_comment xt_conntrack xt_mark xt_multiport xt_nat xt_tcpudp overlay"
        "-${pkgs.kmod}/bin/modprobe br_netfilter"
      ];
    };
  };

  environment.etc."systemd/resolved.conf.d/00-lima-enable-mdns.conf".source =
    "${mkosiExtra}/etc/systemd/resolved.conf.d/00-lima-enable-mdns.conf";
  # what 20-rootless-base.sh writes on a kernel without unprivileged_userns_clone
  environment.etc."sysctl.d/99-lima.conf".text = ''
    net.ipv4.ping_group_range = 0 2147483647
    net.ipv4.ip_unprivileged_port_start=0
  '';
  # what `lima-guestagent install-systemd` writes (VZ, vsock 2222); lima-init
  # rewrites ExecStart for this VM's transport
  systemd.units."lima-guestagent.service" = {
    text = builtins.readFile "${mkosiExtra}/etc/systemd/system/lima-guestagent.service";
    wantedBy = [ "multi-user.target" ];
  };
  systemd.packages = [
    (pkgs.runCommand "cpvm-lima-dropins" { } ''
      d=$out/lib/systemd/system
      mkdir -p $d/lima-guestagent.service.d $d/user@.service.d $d/service.d
      cp ${mkosiExtra}/usr/lib/systemd/system/lima-guestagent.service.d/cpvm.conf $d/lima-guestagent.service.d/
      cp ${mkosiExtra}/etc/systemd/system/user@.service.d/lima.conf $d/user@.service.d/
      cp ${mkosiExtra}/usr/lib/systemd/system/service.d/10-no-credentials.conf $d/service.d/
    '')
  ];
}
