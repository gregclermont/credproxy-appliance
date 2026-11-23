# credproxy appliance VM image on NixOS: the counterpart of spike/mkosi, same
# contract. Root is a tmpfs, /etc the NixOS etc overlay (erofs metadata +
# tmpfs upper), /nix/store an erofs partition under dm-verity. The root hash
# is on the kernel command line (roothash=, systemd-veritysetup-generator, as
# mkosi's image), which Lima passes with the kernel and initrd from the
# instance directory: no ESP or bootloader in the image.
{ config, lib, pkgs, modulesPath, ... }:
let
  verityOpts = [
    "systemd.verity_root_data=/dev/disk/by-partlabel/nix-store"
    "systemd.verity_root_hash=/dev/disk/by-partlabel/nix-store-verity"
    "systemd.verity_root_options=panic-on-corruption"
  ];
in
{
  imports = [
    "${modulesPath}/image/repart.nix"
    "${modulesPath}/profiles/minimal.nix"
    # systemd initrd, etc overlay, userborn: no perl activation at boot
    "${modulesPath}/profiles/perlless.nix"
    ./lima.nix
    ./cpstate.nix
    ./docker.nix
  ];

  system.stateVersion = "26.05";
  networking.hostName = ""; # from cidata (lima-init) and credproxy
  time.timeZone = null; # from cidata (lima-init)

  # --- boot ---
  boot.loader.grub.enable = false;
  boot.initrd.systemd.enable = true;
  boot.initrd.systemd.dmVerity.enable = true;
  # initrd activation by nixos-init (one binary) instead of the bash
  # activation script
  system.nixos-init.enable = true;
  boot.initrd.includeDefaultModules = false;
  boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "erofs" "dm_verity" "overlay" ];
  # hvc0 (Lima's serial log on both VZ and QEMU) is a module in NixOS's
  # kernel; the cidata CD-ROM on QEMU (virtio-scsi) is probed while the
  # initrd sets up the store, so lima-init need not wait for udev to load
  # these from the verity store.
  boot.initrd.kernelModules = [ "virtio_console" "virtio_scsi" "sr_mod" "isofs" ];
  boot.initrd.systemd.contents."/etc/systemd/system-generators/cpvm-utab-event".source =
    "${pkgs.cpvmUtabEvent}/bin/cpvm-utab-event";
  # The initrd mounts /sysroot, /sysroot/run, the store, the etc metadata
  # image and the etc overlay within about a second, and PID 1 holds every
  # mount job while its mount-event source is over 5 dispatches per second
  # (0.5 s stall in a third of boots). fstab's x-initrd.mount option is
  # written to libmount's utab, and every utab write is a dispatch of its
  # own: these mounts go without it. The store gets nodev,nosuid up front,
  # so nixos-init need not remount it.
  boot.initrd.systemd.packages = [ pkgs.cpvmNoCredentials pkgs.cpvmInitrdNoUtab ];
  # scsi_mod.scan=async: NixOS's kernel scans the SCSI bus synchronously,
  # and inserting virtio_scsi (QEMU's cidata CD-ROM) then held the initrd's
  # systemd-modules-load ~2.7 s; Debian's kernel scans asynchronously.
  # systemd.tty.*: systemd >= 258's PID 1 asks /dev/console for its terminal
  # type and size with ANSI queries and waits for answers hvc0 never sends
  # (~0.33 s each, three of them, after switch-root).
  boot.kernelParams = [
    "console=hvc0" "net.ifnames=0" "fsck.mode=skip" "scsi_mod.scan=async"
    "systemd.tty.term.console=vt220" "systemd.tty.rows.console=24" "systemd.tty.columns.console=80"
    # free page reporting at any order to the balloon credproxy gives QEMU
    # guests (as spike/mkosi's cmdline)
    "page_reporting.page_reporting_order=0"
  ] ++ verityOpts;

  # Kernel modules for a VM: NixOS's kernel without its drivers for physical
  # hardware (vm-modules.sh); the kernel and its config are nixpkgs', so the
  # build stays on the binary cache.
  system.modulesTree = lib.mkForce [
    (let kernel = config.boot.kernelPackages.kernel; in
      pkgs.runCommand "${kernel.name}-vm-modules" { nativeBuildInputs = [ pkgs.kmod ]; } ''
        full=${lib.getOutput "modules" kernel}/lib/modules
        ver=$(ls $full)
        bash ${./vm-modules.sh} $full/$ver $out/lib/modules/$ver
        depmod -b $out -a $ver
        depmod -b $out -n -e -F ${kernel}/System.map $ver 2>err >/dev/null
        if grep . err; then exit 1; fi
      '')
  ];

  nixpkgs.overlays = [
    (final: prev: {
      # systemd mounts a tmpfs under /run/credentials/ for every service
      # importing credentials (journald, tmpfiles, udev...), even with none;
      # those mounts trip PID 1's mount-event rate limit (5/s) and mount jobs
      # wait for the 1 s window. Nothing passes credentials to this VM.
      cpvmNoCredentials = final.runCommand "cpvm-no-credentials" { } ''
        mkdir -p $out/lib/systemd/system/service.d
        printf '[Service]\nImportCredential=\nLoadCredential=\n' >$out/lib/systemd/system/service.d/10-no-credentials.conf
      '';
      cpvmInitrdNoUtab = final.runCommand "cpvm-initrd-no-utab" { } ''
        d=$out/lib/systemd/system
        mkdir -p $d/sysroot.mount.d $d/sysroot-nix-store.mount.d
        printf '[Mount]\nOptions=mode=0755\n' >$d/sysroot.mount.d/cpvm-no-utab.conf
        printf '[Mount]\nOptions=ro,nodev,nosuid\n' >$d/sysroot-nix-store.mount.d/cpvm-no-utab.conf
      '';
      # spike/mkosi/initrd/.../cpvm-utab-event: PID 1's mount monitor watches
      # /run/mount/utab.event, or while it is missing every create in /run.
      cpvmUtabEvent = final.writeShellScriptBin "cpvm-utab-event" ''
        [ -e /run/mount/utab.event ] && exit 0
        ${final.coreutils}/bin/mkdir -p -m 0755 /run/mount && : >> /run/mount/utab.event
      '';
    })
  ];

  # --- filesystems ---
  fileSystems."/" = { fsType = "tmpfs"; options = [ "mode=0755" ]; };
  fileSystems."/nix/store" = { device = "/dev/mapper/root"; fsType = "erofs"; };

  image.repart = {
    name = "cpvm";
    # repart makes erofs with the image's 512-byte sector size as block size:
    # libblkid then doesn't recognise it, udev leaves the dm device
    # SYSTEMD_READY=0 and the initrd times out; 512-byte clusters also
    # barely compress.
    mkfsOptions.erofs = [ "-b4096" ];
    partitions = {
      "10-nix-store" = {
        storePaths = [ config.system.build.toplevel ];
        nixStorePrefix = "/";
        repartConfig = {
          Type = "linux-generic";
          Label = "nix-store";
          Format = "erofs";
          # as spike/mkosi's root (no measurable boot cost there)
          Compression = "lz4hc";
          Minimize = "best";
          Verity = "data";
          VerityMatchKey = "nix-store";
          VerityDataBlockSizeBytes = 4096;
          VerityHashBlockSizeBytes = 4096;
        };
      };
      "20-nix-store-verity".repartConfig = {
        Type = "linux-generic";
        Label = "nix-store-verity";
        Verity = "hash";
        VerityMatchKey = "nix-store";
        VerityDataBlockSizeBytes = 4096;
        VerityHashBlockSizeBytes = 4096;
        Minimize = "best";
      };
    };
  };

  # --- appliance: no nix, nothing the tmpfs root would redo per boot ---
  nix.enable = false;
  system.switch.enable = false;
  users.mutableUsers = true; # lima-init adds the Lima user at boot
  networking.firewall.enable = false;
  programs.ssh.setXAuthLocation = false;
  programs.nano.enable = false;
  fonts.fontconfig.enable = false;
  boot.swraid.enable = false;
  boot.bcache.enable = false;
  boot.kexec.enable = false;
  services.getty.autologinUser = null;
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@".enable = false;
  console.enable = false;
  # An empty machine-id: not a first boot (PID 1 then binds a transient ID
  # over it). Missing, every boot was a first boot on the tmpfs root, and
  # PID 1 applied presets to the store-backed unit tree: ~5 s after
  # switch-root.
  environment.etc."machine-id".text = "";
  # Per-boot work the ephemeral root would redo every boot for nothing
  # (as spike/mkosi masks it)
  systemd.services.systemd-journal-catalog-update.enable = false;
  systemd.services.systemd-update-done.enable = false;
  systemd.services.systemd-machine-id-commit.enable = false;
  # NixOS's linger-users.service would drop the linger lima-init enables
  # for the Lima user, who is not declared here
  users.manageLingering = false;
  # The setuid wrappers (/run/wrappers, recreated every boot) held
  # sysinit.target ~0.5-0.9 s; only logins and Lima's boot scripts need them
  # (sudo).
  systemd.services.suid-sgid-wrappers = {
    before = lib.mkForce [ "sshd.service" "lima-boot.service" "systemd-user-sessions.service" "shutdown.target" ];
    wantedBy = lib.mkForce [ "multi-user.target" ];
    unitConfig.DefaultDependencies = false;
    after = [ "local-fs.target" ];
  };
  # udev's hardware database (13 MiB): no device of a VM needs its
  # properties (spike/mkosi removes it too)
  environment.etc."udev/hwdb.bin".enable = false;
  # No locale archive: C.UTF-8 is built into glibc, and the Debian image has
  # no locale either. su's PAM file would pull xauth for X11 forwarding.
  i18n.defaultLocale = "C.UTF-8";
  i18n.glibcLocales = null;
  security.pam.services.su.forwardXAuth = lib.mkForce false;
  # Services NixOS starts by default that the Debian image does not have,
  # each work on the 2-vCPU guest's boot: the userspace OOM killer, NTP (the
  # guest clock is the hypervisor's), weekly fstrim, the coredump handler
  # (cores go where the kernel puts them, as on Debian), rfkill, lastlog2's
  # import.
  systemd.oomd.enable = false;
  services.timesyncd.enable = false;
  services.fstrim.enable = false;
  systemd.coredump.enable = false;
  systemd.suppressedSystemUnits = [ "systemd-rfkill.service" "systemd-rfkill.socket" ]
    # systemd-importd (machine image downloads) is the only user of gnupg
    # and, through it, openldap (~17 MiB)
    ++ [ "systemd-importd.service" ];
  systemd.services.lastlog2-import.enable = lib.mkForce false;

  # --- network: DHCP on eth0 (spike/mkosi 80-cpvm-eth.network) ---
  networking.useNetworkd = true;
  networking.useDHCP = false;
  systemd.network.wait-online.enable = false;
  systemd.network.networks."80-cpvm-eth" = {
    matchConfig.Name = "eth*";
    networkConfig = {
      DHCP = "ipv4";
      # credproxy's bootstrap name: resolved sends *.local to mDNS only,
      # unless a link routes the domain to unicast DNS
      Domains = "~proxy.local";
      DNSDefaultRoute = true;
    };
    dhcpV4Config = { RouteMetric = 200; UseMTU = true; };
  };
  services.resolved.enable = true;

  # --- sshd: host key on the state disk (cpstate-setup), none in the image ---
  services.openssh = {
    enable = true;
    hostKeys = [ { type = "ed25519"; path = "/var/lib/cpstate/ssh/ssh_host_ed25519_key"; } ];
    settings.PasswordAuthentication = false;
    settings.KbdInteractiveAuthentication = false;
    # COLORTERM: Lima's 11-colorterm-environment.sh greps sshd_config for it
    # (no sshd_config.d here) and then leaves sshd alone. Forwarded sockets
    # are bound into the workspace container, whose user need not be the ssh
    # user (spike/mkosi 20-cpvm-forwards.conf).
    extraConfig = ''
      AcceptEnv COLORTERM
      StreamLocalBindMask 0111
      StreamLocalBindUnlink yes
    '';
  };

  # /dev/kvm usable by any user in the guest (spike/mkosi 99-credproxy-kvm.rules)
  services.udev.extraRules = ''
    KERNEL=="kvm", MODE="0666"
  '';
}
