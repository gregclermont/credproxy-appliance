# mkosi: Debian appliance image with a dm-verity root, booted by Lima

An appliance image spike. mkosi is Linux-only, so it runs in a Lima build VM.

- `builder.yaml`: Debian 13 build VM (`mkb`). Mounts this dir at `/src`
  (read-only) and an output directory at `/out` (defaults: a checkout at
  `~/src/credproxy-appliance`, output in its `.tmp/mkosi-out`; `--set` below).
- `mkosi.conf`, `mkosi.postinst.chroot`, `mkosi.repart/`: the image. Debian
  trixie, cloud kernel, Docker (`docker.io`), no ESP/bootloader (direct
  kernel boot), erofs root under dm-verity, `systemd.volatile=overlay` (tmpfs
  upper layer) so Lima's provisioning can write `/etc`, `/usr/local`. No
  cloud-init; per-boot work the volatile root would redo masked.
- `initrd/`: our minimal initrd (systemd, udev, veritysetup), built first by
  `build.sh` and passed with `--initrd`; mkosi appends only the five modules
  in `KernelModulesInitrdInclude=`. Loads them via `modules-load.d`, drops
  per-service credential mounts (systemd's mount rate limit).
- `mkosi.extra/usr/libexec/lima-init` + `lima-init.service`,
  `lima-boot.service`: replace cloud-init. `lima-init` reads Lima's cidata
  (`lima.env`, `meta-data`, `user-data`: hostname, timezone, user, sudo, ssh
  keys, `mounts:`) and warns on user-data it doesn't implement;
  `lima-boot` runs cidata `boot.sh` like cloud-init's per-boot hook.
  Network: `80-cpvm-eth.network` (DHCP on `eth*`, `net.ifnames=0`).
- Pre-satisfied Lima boot scripts (files byte-identical to what they'd
  write, so they skip restarts/reloads): mDNS `resolved.conf.d` drop-in,
  `sysctl.d/99-lima.conf`, `user@.service.d/lima.conf`,
  `etc/systemd/system/lima-guestagent.service` (+ a `ConditionPathExists`
  drop-in), `lima-modules.service` (Lima's modprobe list, off the boot's
  critical path), the sshd `10-acceptenv-colorterm.conf` drop-in (11
  exits without reloading sshd). `lima-init` also writes Lima's
  `/etc/environment` block as 07 does, before sshd starts (07 then finds
  the file unchanged and runs no `loginctl terminate-user`), and creates
  `/run/credproxy-ssh-stable`: credproxy's start then runs its first
  guest command without waiting for boot.sh.
- `mkosi.extra/`: `cpstate.service` + `/usr/libexec/cpstate-setup`: mounts
  the state disk (Lima `additionalDisks` entry `cpstate`) before
  `local-fs.target`, formatting it on first use (GPT + ext4 labelled
  `lima-cpstate`, Lima's convention, so Lima's own disk script leaves it
  alone), and binds `/home` and `/var/lib/docker` from it. It also
  generates the sshd host key there on first use: the image ships none,
  sshd reads only `/var/lib/cpstate/ssh/ssh_host_ed25519_key`
  (`sshd_config.d/10-cpvm-hostkey.conf`), so every VM has its own.
  `20-cpvm-forwards.conf` makes sockets forwarded from the host 0666.
  `lima-init` adds the Lima user to the `docker` group.
- `mkosi.extra/usr/lib/systemd/system-preset/10-cpvm.preset`: Docker via
  `docker.service` started with the boot (presets are how enable/disable
  sticks with mkosi); `systemd-networkd-wait-online` masked in postinst so
  docker.service's `network-online.target` doesn't wait on it.
- `build.sh`: run in the builder: mkosi build (initrd, then image), then write the direct-boot
  files (`kernel`, `initrd`, `kernel.cmdline` with the roothash recovered
  from the partition UUIDs) to `/out/dkb`.
- `cpvm.yaml`: Lima VZ instance booting `mkosi-out/cpvm.raw` with the
  `cpstate` disk.

```sh
# from the checkout; LIMA_HOME: a Lima home of its own, not the default one
export LIMA_HOME=$PWD/.tmp/lima
src=$PWD/spike/mkosi out=$PWD/.tmp/mkosi-out
limactl start --name mkb --set ".mounts[0].location=\"$src\" | .mounts[1].location=\"$out\"" spike/mkosi/builder.yaml
limactl shell --workdir / mkb /src/build.sh     # --cache-only=always to stay offline
limactl disk create cpstate --size 10GiB --format raw
limactl create --name cpvm --set ".images[0].location=\"$out/cpvm.raw\"" spike/mkosi/cpvm.yaml
cp "$out"/dkb/{kernel,initrd,kernel.cmdline} "$LIMA_HOME/cpvm/"
limactl start cpvm       # direct kernel boot: roothash held host-side
```

On Linux (QEMU/KVM; same image, same `build.sh`): the builder runs under
QEMU (Lima's default vmType there; its mounts default to reverse-sshfs,
which works for the build). Point the mounts at the checkout and an output
dir, and keep the memory small enough for the host:

```sh
export LIMA_HOME=$PWD/.tmp/lima      # a Lima home of its own
out=$PWD/.tmp/mkosi-out; mkdir -p $out
limactl start --tty=false --name mkb --memory 3 \
  --set ".mounts[0].location=\"$PWD/spike/mkosi\" | .mounts[1].location=\"$out\"" spike/mkosi/builder.yaml
limactl shell --workdir / mkb /src/build.sh
limactl stop mkb
```

CI: `.github/workflows/mkosi-image.yml` runs the same `build.sh` in a
Debian 13 container (mkosi 25.3-7, `/src` and `/out` mounted as in the
builder) on GitHub's x86_64 and arm64 runners, reports packages, sizes and
roothash in the job summary, keeps the image 3 days and smoke-boots it under
QEMU. The architecture is the build host's; per-architecture settings are in
`mkosi.conf.d/` and `initrd/mkosi.conf.d/`.

Outputs: `$out/cpvm.raw`, `$out/dkb/{kernel,initrd,kernel.cmdline}`. Boot it
with credproxy (`CREDPROXY_APPLIANCE` pointed at `$out`), not with
`cpvm.yaml`. Under
QEMU, Lima attaches cidata as a virtio-scsi CD-ROM (`sr0`), not a virtio
disk: udev loads `virtio_scsi`/`sr_mod`/`isofs` on demand, nothing to add.
`console=hvc0` works there too (QEMU's virtconsole, `serialv.log`).

On a shared Lima user-mode network (`cp`): keep another VM on it
running (else `limactl stop` makes Lima SIGTERM the network's daemon), then create the
instance with
`--set '.networks=[{"lima":"cp"}] | .additionalDisks=[{"name":"cpnetstate","format":false}]'`
(its own state disk: a disk attaches to one instance).

Gotchas found:
- (UEFI boot only, before the ESP was dropped) ESP must be >= ~512 MiB: at 256 MiB mkfs.fat makes a FAT32 with too few
  clusters, EDK2 (VZ and OVMF) refuses it, and VZ just powers off with an
  empty serial log. Debug boots with QEMU + OVMF in the builder (TCG, slow
  but verbose): `-serial file:fw.log` for firmware/systemd-boot, and
  `-device virtio-serial-pci -chardev file,id=c,path=hvc.log -device
  virtconsole,chardev=c` for the kernel's `hvc0`.
- Only one of `ssh.service` / `ssh.socket`: both bind :22 and Lima's
  `systemctl reload ssh` then kills the service. Keep the service (cloud-init
  restarts it explicitly), mask the socket. `systemctl disable` in postinst
  doesn't stick: mkosi applies presets afterwards.
- Lima's boot scripts expect `/etc/fstab` and `/etc/systemd/resolved.conf.d/`.
- Disk order isn't what you'd guess: with one additional disk, VZ gives
  vda = image, vdb = additional disk, vdc = cidata. Pick the state disk by
  content (label, else the only blank disk), never by name.
- Needs `libpam-systemd` (else `user@<uid>` fails) and `libnss-myhostname`
  (else sudo can't resolve the hostname).
- Without cloud-init, `fdisk` (`sfdisk`, state disk first use) and `tzdata`
  must be listed explicitly.
- Lima regenerates cidata with a new instance-id on every start, so cloud-init
  can't be made to skip its per-instance work; replacing it is the only way
  to stop paying for it (~2.5 s here).
- Don't put boot-time modules in the main image's `modules-load.d`:
  `systemd-modules-load` runs serially before `sysinit.target`.
- Timing: time `limactl start cpvm` from the host, then `limactl shell cpvm
  systemd-analyze`; to see what PID 1 waits for, append
  `systemd.log_level=debug` to the instance's `kernel.cmdline` for one boot.
