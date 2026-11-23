# spike/alpine: an Alpine appliance image

What this is: an Alpine + OpenRC appliance image for Lima workspace VMs:
a dm-verity root, Docker from Alpine's packages, the Lima glue credproxy
needs. It started as a boot-time measurement against the Debian + mkosi
image (`spike/mkosi`): it reaches sshd and Docker's API about 2.5 s sooner
end to end. It is now being hardened toward a default image; it is not a
product image yet.

## Where it stands

Enforced by the image (each tested under QEMU; on VZ only the earlier
measurement image was run):

- **Verified root, no other way to boot.** The initramfs opens the root
  only through dm-verity with the `roothash=` on the kernel command line
  (exactly one, 64 lowercase hex digits), `panic_on_corruption` and
  `panic_on_error`. There is no unverified build or fallback.
- **Fails closed, visibly.** Every initramfs failure, checked or not, ends
  in a kernel panic on the console, which is what the host watches for: a
  bad or missing root hash, another disk in the image's place, an
  unexpected hash superblock, a failed module load, a root without
  `/sbin/init`, any unexpected command failure. No shell, waits bounded by
  uptime. Values read from the hash superblock, which the root hash does
  not cover, are checked against the image's own (algorithm, version,
  block sizes, salt size) or bounded; the data block count is also checked
  against the erofs superblock read through the verified device, since a
  lowered count would still verify and leave the end of the root
  unreadable.
- **The image disk is recognised, not assumed.** It must be `vda`, its
  primary GPT's first two partitions must carry the two halves of the root
  hash as their unique GUIDs (systemd's convention, set at build time),
  and the partitions the kernel uses must have those entries' extents
  (else it took them from the backup GPT or an MBR). This is an identity
  check against a wrong disk in `vda`'s place, not a security boundary:
  the partition table is not covered by the root hash, and integrity
  rests on dm-verity alone, which verifies every block read whatever
  table described the partitions.
- **cidata is chosen by device.** Its `boot.sh` runs as root at every boot,
  so it is taken only from a whole disk the kernel sees as read-only that
  is neither the image disk nor the state disk, with an iso9660 labelled
  `cidata`; exactly one, or the boot ends in a panic. A filesystem
  labelled `cidata` that guest root writes to a writable disk is ignored.
- **The state disk is chosen by device**, not by its label: the only
  writable virtio disk that is not the image disk. It is used if its
  first partition is ext4 labelled `lima-cpstate`, formatted only if it is
  entirely blank, and refused otherwise. Its mount and the `/home` bind
  are `nosuid,nodev` (Docker's data directory keeps both); the user's
  `~/.ssh` is written as the user, so links planted there lead nowhere.
- **No silent half-boot.** A state disk or cidata that cannot be used
  would leave the VM without sshd: `cpstate` and `lima-init` end such a
  failure in a kernel panic after a `cpvm: FATAL` line, as the initramfs
  does, so the host reports it at once. A shared folder that does not
  mount stays a warning.
- **Devices without a driver are reported.** With no device manager, a
  device whose module is not loaded stays silent; `devcheck` lists every
  unbound virtio, SCSI and PCI device (chipset parts and the empty USB
  controller excepted) in `/run/cpvm/devcheck` and on the console. The boot
  goes on.
- **Containers get what they get on Debian.** containerd (and so every
  container) runs with Debian's unit's limits (1048576 open files,
  unlimited processes); `/dev/kvm` where the host lets the guest nest,
  `/dev/net/tun` usable by all, `binfmt_misc` mounted, `pid_max`, inotify
  limits and `ptrace_scope` as Debian or larger; a panic leaves the VM
  down instead of rebooting it.

Still missing for a product image, most important first:

- **The image disk is guest-writable and persistent.** Lima attaches it
  read-write and keeps it across stop and start. Guest root cannot change
  what the verified root contains, but it can damage the disk, after which
  every start fails closed until the VM is recreated. A fresh disk at each
  start, or a read-only attachment, needs a host-side change.
- **No release process.** No reproducible build: Alpine's mirrors keep only
  the latest build of each package, so a pinned image needs its own copy of
  the `.apk` files; two builds of one commit differ in salt, root hash and
  timestamps. No signing, no update channel.
- **Alpine's cadence.** Docker, containerd and runc come from `community`,
  supported only until the next stable release: the image must move to
  each new Alpine branch about every six months.
- **Platforms.** arm64 is built and smoke-booted under emulation only; on
  VZ the first hardening round passed, the later fixes are untested there.
- **No legacy iptables.** No packaged Alpine kernel builds the legacy
  tables (`ip_tables`, `iptable_*`): `iptables-legacy` in a privileged
  container fails, the default nf_tables `iptables` works.
- **Diagnostics.** A small in-memory log (below) and the console; nothing
  survives a stop, no journal, no per-service output capture.
- **Smaller gaps.** Lima's own mount of the state disk (under `/mnt`) is
  not `nosuid,nodev`; sshd runs without PAM; no NTP in the guest; the
  VM's own `docker` has no compose or buildx plugin.

## Image (`build.sh NAME [apk|static26] [lima|nolima] [ctrd|noctrd|-] [verity]`)

Rootless: `podman run alpine:3.24` (pinned by digest) runs `mkimage.sh`,
which assembles the root with `apk --root`, writes it as erofs (lz4hc) and
its dm-verity hash device (`veritysetup format` on files) into `cpvm.raw`
(GPT: root, root-verity), and puts the `linux-virt` kernel, a busybox
initramfs (`initramfs-init`) and the command line with `roothash=` in
`dkb/`. Output in `.tmp/alp/out/NAME`. Build time ~25-60 s.
`CPVM_ENGINE=docker` runs it with Docker instead (as
`.github/workflows/alpine-image.yml` does: the `lima` variant on GitHub's
x86_64 and arm64 runners, report in the job summary, image kept 3 days,
smoke boot and tamper boots under QEMU with `spike/checks/image/smoke.sh`).
The fifth argument, `verity`, is accepted and changes nothing: every build
is verity.

- `apk`: Alpine's Docker (29.9.3, containerd 2.3.7, runc 1.4.4 on 3.24).
- `static26`: the same image with Docker's static 26.1.4 binaries over
  Alpine's (separates Docker's version from the distribution).
- `lima`: adds what Lima's boot scripts need on Alpine (`lima-boot` runs
  cidata's `boot.sh` after Docker; busybox's `acpid` service, which
  `10-alpine-prep.sh` enables, with a power-button script), GNU
  tar/coreutils/grep/findutils (credproxy's guest commands), rsync (else
  Lima's `30-install-packages.sh` installs it every boot); no probe. The
  power-button script marks `/run/cpvm-poweroff` so that shutdown powers
  off at once (below).
- `ctrd`: containerd as its own OpenRC service (`ctrd/`), dockerd pointed
  at it. The default with `lima` (`-` or no fourth argument): dockerd's
  managed containerd adds 1.0 s to its stop. `noctrd` keeps the managed one.

Boot: kernel -> initramfs -> `switch_root` -> busybox init -> OpenRC. The
initramfs loads virtio_blk, erofs, overlay and dm-verity, checks `vda`'s
partitions and the hash superblock, creates the verity device with
`dmsetup.static` (Alpine's `device-mapper-static`; `veritysetup` would
bring libcryptsetup and its libraries for the same table), checks the
erofs block count, mounts the root read-only under a tmpfs overlay (as
`systemd.volatile=overlay`) and starts `/sbin/init` with an empty
environment. Tuning, all in `rootfs/` and `mkimage.sh`:

- OpenRC `rc_parallel=YES`, no rc logger, cgroup v2 only.
- Runlevels: sysinit = devfs, sysfs, cgroups, the probe, the Docker
  prefetch, the device drivers and `devcheck` (`cphw`); default =
  everything else, in parallel: `cpmodules` (Lima's module list +
  br_netfilter, backgrounded, as `lima-modules.service`), sysctl, `cpstate`
  (port of `cpstate-setup`), `cpnet` (udhcpc in the background: `net` is
  provided before the lease, as networkd's `network.target`), `lima-init`
  (port of the mkosi one, minus systemd parts, cidata by device), sshd,
  docker, `cplog`.
- Shutdown: busybox init runs `openrc shutdown`, then
  `/usr/libexec/cpvm/cpshutdown` (its last `::shutdown:` action):
  SIGTERM to all, wait while processes remain (at most 1 s), SIGKILL,
  unmount everything but `/`, `/proc`, `/sys`, `/dev` and host-backed
  shares (remount read-only what will not unmount), so the state disk's
  ext4 ends clean; after the power button (Lima's stop) `poweroff -f`
  at once, otherwise busybox's own path (1 s + 1 s of fixed sleeps) and
  syscall (`reboot`, `halt`, a typed `poweroff`). Without it busybox
  unmounted nothing (journal recovery on every boot) and slept 2 s.
- No device manager (no udev/mdev): devtmpfs nodes, an explicit module
  list in `cphw` (virtio net, rng, balloon, scsi, vsock, virtiofs; CD,
  iso9660, ext4, ACPI button), checked by `devcheck`. No getty except one
  on hvc0, no ntp, no acpid (except with `lima`).
- Log: `cplog`, busybox `syslogd` into a 512 KiB RAM ring buffer, read
  with `logread` (sshd and sudo, Lima's account changes, start-stop- and
  supervise-daemon). Started after sshd and Docker so that nothing waits
  for it: earlier messages are lost, and all of it at shutdown. The kernel
  log stays in `dmesg`, dockerd's in `/var/log/docker.log`.
- sshd: no host key generation (`sshd_disable_keygen`), the key from the
  state disk; no PAM (the Lima user's password is set to `*`, not locked).
- docker: Alpine's OpenRC service (supervise-daemon, log_proxy to
  `/var/log/docker.log`), no daemon.json; `cpprefetch` reads Docker's
  binaries early (as `cpvm-prefetch.service`). Docker gid pinned to 102.
