# nixos: the credproxy appliance image on NixOS

The NixOS counterpart of `../mkosi/`, held to the same contract: what
credproxy's `CREDPROXY_APPLIANCE` reads (`cpvm.raw` + `dkb/{kernel,initrd,
kernel.cmdline}`), a dm-verity root whose hash rides on the kernel command
line (`roothash=`, held host-side), the state disk, rootful Docker, Lima
without cloud-init.

Build (Nix runs in a container, none on the host; first build downloads
~450 MiB from cache.nixos.org (about 3 min here) into the volume `cpv2-nix-store`):

```sh
spike/nixos/build.sh                 # -> <checkout>/.tmp/nixos/out/latest
spike/nixos/build.sh /some/dir       # or anywhere
CREDPROXY_APPLIANCE=<that dir> credproxy workspace <ws> start
```

`CPVM_SYSTEM=aarch64-linux` builds the arm64 image (needs an aarch64
builder). CI: `.github/workflows/nixos-image.yml` runs this script on
GitHub's x86_64 and arm64 runners (push to `spike/nixos/**` or
`spike/mkosi/**`, or by hand), puts MANIFEST, sizes and the modules
dropped in the job summary, keeps the image 3 days and smoke-boots it
under QEMU. nixpkgs is pinned in `flake.lock`; bump it with
`nix flake update` (in the same container) to take security fixes.

- `flake.nix`: `nixosConfigurations.<system>` and `packages.<system>.appliance`,
  the appliance directory as one derivation (cmdline =
  `roothash=<store hash> init=<toplevel>/init <kernel-params>`); the store
  partition holds the toplevel's closure minus the kernel and initrd, which
  boot from `dkb/` (the toplevel's links to them dangle in the guest).
- `configuration.nix`: root a tmpfs, `/etc` the NixOS etc overlay
  (`profiles/perlless.nix`: systemd initrd, userborn), `/nix/store` an erofs
  partition under dm-verity (`image.repart`, partitions labelled
  `nix-store` / `nix-store-verity`), opened by systemd's own
  veritysetup generator from `roothash=` +
  `systemd.verity_root_{data,hash,options}=` (`panic-on-corruption`), so
  the device is `/dev/mapper/root` as on mkosi. Network, sshd (host key
  on the state disk), the `/dev/kvm` rule, the initrd's
  `cpvm-utab-event` generator and the no-credentials drop-in, all as on
  mkosi.
- `lima.nix`: `lima-init`, `lima-boot`, `lima-modules` and the
  pre-satisfied Lima boot-script outputs, using `../mkosi`'s files
  directly (one copy of `lima-init`), plus the FHS bits Lima assumes:
  `/bin/bash`, sudo on PATH (`/run/wrappers/bin`), `@includedir
  /etc/sudoers.d`, `/usr/share/zoneinfo`, and a writable
  `/etc/systemd/system` (NixOS makes it a store symlink; it is copied
  onto the etc overlay's tmpfs before `lima-init` writes the guest agent
  unit there).
- `cpstate.nix`: `../mkosi`'s `cpstate-setup`, unchanged.
- `docker.nix`: Docker Engine from Docker's static release tarball
  (version and hash pinned there, not nixpkgs' docker), started with the
  boot; the docker group pinned to gid 102 (the mkosi image's); the
  prefetch unit.
- `vm-modules.sh`: the kernel module tree minus drivers for physical
  hardware.
- `build.sh`: the one-command build.

Gotchas:
- systemd-repart formats erofs with the image's 512-byte sector size:
  libblkid doesn't recognise it and the initrd waits 90 s for the dm
  device. `mkfsOptions.erofs = [ "-b4096" ]`, 4 KiB verity blocks.
- Nix's build sandbox needs `--security-opt seccomp=unconfined` in a
  (rootless) container: the default profile refuses `sethostname`.
- NixOS's kernel has `virtio_console` as a module: no `hvc0` until it is
  loaded in the initrd.
- `/etc/systemd/system` is a store symlink even with the etc overlay.
- Lima's `/etc/environment` block (07-etc-environment.sh) is not read by
  NixOS's pam_env (it reads `/etc/pam/environment`); credproxy sets
  nothing there.
- PID 1 holds mount jobs while its mount-event source is over 5 dispatches
  per second, and every libmount utab write is a dispatch: fstab's
  `x-initrd.mount` (written to utab) on `/sysroot` and the store tripped it
  in the initrd before `/sysroot/etc` was mounted (0.5 s, a third of boots).
  `cpvmInitrdNoUtab` mounts both without it. Debug with
  `rd.systemd.log_level=debug` and look for "entered rate limit state".
