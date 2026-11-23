# Docker Engine, rootful, pinned: Docker's own static release binaries
# (dockerd, containerd, runc, docker CLI), not nixpkgs' docker, whose
# wrappers pull ~400 MiB of runtime deps into the closure (xfsprogs ->
# python3, git, buildx, compose, rootlesskit). Units as Debian's docker.io
# ships them: containerd and dockerd started with the boot (credproxy's first
# guest command is a docker call), data on the state disk (cpstate binds
# /var/lib/docker).
{ pkgs, lib, ... }:
let
  version = "29.9.3";
  arch = { x86_64-linux = "x86_64"; aarch64-linux = "aarch64"; }.${pkgs.stdenv.hostPlatform.system};
  hash = {
    x86_64 = "sha256-P7XR8TAUwYzFSUW8F3xYqQVqSC2toDHhfRLPLmkiyXM=";
    aarch64 = "sha256-Gyf9c5N475OEAegc5a+3O3rXQy1PWYgUqf9fgmu0ZNI=";
  }.${arch};
  docker = pkgs.stdenvNoCC.mkDerivation {
    pname = "docker-static";
    inherit version;
    src = pkgs.fetchurl {
      url = "https://download.docker.com/linux/static/stable/${arch}/docker-${version}.tgz";
      inherit hash;
    };
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      install -Dm755 -t $out/bin containerd containerd-shim-runc-v2 docker docker-init docker-proxy dockerd runc
    '';
  };
  # what dockerd and containerd exec besides each other
  runtimePath = with pkgs; [ docker iptables kmod util-linux procps coreutils xz ];
in
{
  environment.systemPackages = [ docker pkgs.iptables ];
  # The overlay2 graph driver, as Debian's Docker 26 has it: with the
  # containerd image store (Docker 29's default) images would land in
  # /var/lib/containerd, on the tmpfs root, and a state disk would not carry
  # over between the mkosi and the NixOS image.
  environment.etc."docker/daemon.json".text = builtins.toJSON {
    features."containerd-snapshotter" = false;
  };
  # Debian's docker.io gets gid 102 in spike/mkosi's image; the same gid
  # here keeps the workspace container (credproxy recreates it when the
  # socket's gid changes) across an image swap.
  users.groups.docker.gid = 102;

  systemd.services.containerd = {
    description = "containerd container runtime";
    after = [ "network.target" "local-fs.target" "dbus.service" ];
    path = runtimePath;
    serviceConfig = {
      ExecStartPre = "-${pkgs.kmod}/bin/modprobe overlay";
      ExecStart = "${docker}/bin/containerd";
      Type = "notify";
      Delegate = true;
      KillMode = "process";
      Restart = "always";
      RestartSec = 5;
      LimitNPROC = "infinity";
      LimitCORE = "infinity";
      TasksMax = "infinity";
      OOMScoreAdjust = -999;
    };
  };

  systemd.sockets.docker = {
    description = "Docker Socket for the API";
    wantedBy = [ "sockets.target" ];
    socketConfig = {
      ListenStream = "/run/docker.sock";
      SocketMode = "0660";
      SocketUser = "root";
      SocketGroup = "docker";
    };
  };

  systemd.services.docker = {
    description = "Docker Application Container Engine";
    after = [ "network-online.target" "nss-lookup.target" "docker.socket" "containerd.service" "time-set.target" ];
    wants = [ "network-online.target" "containerd.service" ];
    requires = [ "docker.socket" ];
    wantedBy = [ "multi-user.target" ];
    path = runtimePath;
    serviceConfig = {
      Type = "notify";
      ExecStart = "${docker}/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock";
      ExecReload = "${pkgs.coreutils}/bin/kill -s HUP $MAINPID";
      TimeoutStartSec = 0;
      RestartSec = 2;
      Restart = "always";
      LimitNPROC = "infinity";
      LimitCORE = "infinity";
      TasksMax = "infinity";
      Delegate = true;
      KillMode = "process";
      OOMScoreAdjust = -500;
    };
    unitConfig = {
      StartLimitBurst = 3;
      StartLimitIntervalSec = 60;
    };
  };

  # spike/mkosi cpvm-prefetch.service: the store is erofs under dm-verity,
  # every page dockerd and containerd fault in at start is a cold read plus a
  # hash check; one sequential read early does that work ahead of them.
  systemd.services.cpvm-prefetch = {
    description = "Read Docker's binaries into the page cache early";
    unitConfig.DefaultDependencies = false;
    unitConfig.ConditionKernelCommandLine = "!cpvm.noprefetch";
    wantedBy = [ "sysinit.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/sh -c 'cat ${docker}/bin/containerd ${docker}/bin/dockerd ${docker}/bin/docker ${docker}/bin/containerd-shim-runc-v2 ${docker}/bin/runc ${pkgs.iptables}/bin/xtables-nft-multi >/dev/null'";
    };
  };
}
