# spike/alpine: an Alpine appliance image, as a measurement

What this is: the image definition behind an Alpine boot-time
measurement (2026-11-23). It answers
one question: does an Alpine + OpenRC guest reach sshd and a usable Docker
sooner than the Debian + mkosi image (`spike/mkosi`)?

What it is not: a product image. dm-verity only with `verity` (below;
without it the root is a plain erofs and appliance dirs built that way carry a
`roothash=` placeholder for credproxy's check), no reproducibility, arm64 built and smoke-booted in CI only, no update story, Lima integration only
as far as the end-to-end measurement needed.

## Image (`build.sh NAME [apk|static26] [lima|nolima] [ctrd]`)

Rootless: `podman run alpine:3.23` (pinned digest) runs `mkimage.sh`, which
assembles the root with `apk --root`, writes it as erofs (lz4hc, as the
mkosi image) to `cpvm.raw`, and puts the `linux-virt` kernel and a busybox
initramfs (`initramfs-init`) in `dkb/`. Output in `.tmp/alp/out/NAME`.
Build time ~25 s. `CPVM_ENGINE=docker` runs it with Docker instead (as
`.github/workflows/alpine-image.yml` does: the `lima` + `verity` variant on
GitHub's x86_64 and arm64 runners, report in the job summary, image kept 3
days, smoke boot and verity tamper boots under QEMU with
`spike/checks/image/smoke.sh`).

- `apk`: Alpine's Docker (29.5.2, containerd 2.2, runc 1.4).
- `static26`: the same image with Docker's static 26.1.4 binaries over
  Alpine's (separates Docker's version from the distribution).
- `lima`: adds what Lima's boot scripts need on Alpine (`lima-boot` runs
  cidata's `boot.sh` after Docker; busybox's `acpid` service, which
  `10-alpine-prep.sh` enables, with a power-button script), GNU
  tar/coreutils/grep/findutils (credproxy's guest commands), rsync (else
  Lima's `30-install-packages.sh` installs it every boot); no probe. Used
  for the end-to-end runs.
- `verity`: `cpvm.raw` = GPT root + root-verity hash partition
  (`veritysetup format` on files), `roothash=` on the cmdline; the
  initramfs reads the hash superblock and loads the dm-verity table with
  `dmsetup.static`, `panic_on_corruption`; any initramfs failure crashes
  the kernel (sysrq) so credproxy sees a panic.
- `ctrd`: containerd as its own OpenRC service (`ctrd/`), dockerd pointed
  at it; for the Docker 26 vs 29 comparison.

Boot: kernel -> initramfs (insmod virtio_blk, erofs, overlay; erofs root
read-only under a tmpfs overlay, as `systemd.volatile=overlay`) ->
`switch_root` -> busybox init -> OpenRC. Tuning, all in `rootfs/` and
`mkimage.sh`:

- OpenRC `rc_parallel=YES`, no rc logger, cgroup v2 only.
- Runlevels: sysinit = devfs, sysfs, cgroups, the probe, the Docker
  prefetch, the device drivers (`cphw`); default = everything else, in
  parallel: `cpmodules` (Lima's module list + br_netfilter, backgrounded, as
  `lima-modules.service`), sysctl, `cpstate` (port of
  `cpstate-setup`), `cpnet` (udhcpc in the background: `net` is provided
  before the lease, as networkd's `network.target`), `lima-init` (port of
  the mkosi one, minus systemd parts), sshd, docker.
- No device manager (no udev/mdev): devtmpfs nodes, an explicit virtio
  module list. No getty except one on hvc0, no syslog, no ntp, no acpid
  (except with `lima`).
- sshd: no host key generation (`sshd_disable_keygen`), the key from the
  state disk; no PAM (the Lima user's password is set to `*`, not locked).
- docker: Alpine's OpenRC service (supervise-daemon, log_proxy to
  `/var/log/docker.log`), no daemon.json; `cpprefetch` reads Docker's
  binaries early (as `cpvm-prefetch.service`). Docker gid pinned to 102.
