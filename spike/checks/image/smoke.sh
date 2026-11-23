#!/bin/bash
# usage: smoke.sh PROFILE IMAGE_DIR OUT_DIR [TAMPER]
#
# Boots an appliance image (IMAGE_DIR/cpvm.raw + dkb/{kernel,initrd,
# kernel.cmdline}) in QEMU the way Lima does (direct kernel boot, virtio
# disk, hvc0 console), with a minimal cidata CD-ROM so that lima-init and
# lima-boot run as under Lima (a user, no ssh keys, a boot.sh that only
# prints), and no state disk (cpstate carries on without one). Needs only
# QEMU (and genisoimage or xorriso for the cidata; without one, or with
# SMOKE_CIDATA=0, the boot goes on without cidata, and the systemd images
# wait 90 s for it).
#
# PROFILE says what a good boot shows on the console: mkosi | nixos | alpine.
# TAMPER: boot a changed copy instead (a kind of tamper.py: image or kernel
# command line; tamper.py --list); pass = the kernel panics and the console
# shows that kind's own refusal line (tamper.py --expect KIND), so a panic
# for another reason fails. Two more kinds change what is attached
# (alpine profile): cidata-none boots without cidata, cidata-two with two
# cidata CDs; pass = the boot ends in a panic after lima-init's
# "cpvm: FATAL" line about cidata.
#
# KVM when /dev/kvm is usable, else TCG. Output: OUT_DIR/serial-*.log, a
# summary on stdout (and in $GITHUB_STEP_SUMMARY when set). Exit 0 = pass.
set -u
profile=${1:?usage: smoke.sh PROFILE IMAGE_DIR OUT_DIR [TAMPER]} img=${2:?} out=${3:?} tamper=${4:-}
mkdir -p "$out"
work=$(mktemp -d "${TMPDIR:-/tmp}/smoke.XXXXXX")
trap 'rm -rf "$work"' EXIT
raw=$img/cpvm.raw tag=${tamper:+tamper-$tamper}; tag=${tag:-boot}

here=$(cd "$(dirname "$0")" && pwd)
cmdline=$(cat "$img/dkb/kernel.cmdline")
want=
case $tamper in
'') ;;
cidata-none | cidata-two) want='cpvm: FATAL: lima-init: .*cidata' ;;
*)
  want=$(python3 -I "$here/tamper.py" --expect "$tamper") || exit 2
  mkdir -p "$work/img/dkb"
  cp --sparse=always -L "$raw" "$work/img/cpvm.raw"
  cp -L "$img/dkb/kernel.cmdline" "$work/img/dkb/"
  python3 -I "$here/tamper.py" "$work/img" "$tamper" | sed 's/^/tamper: /' || exit 2
  raw=$work/img/cpvm.raw cmdline=$(cat "$work/img/dkb/kernel.cmdline") ;;
esac

# cidata as Lima writes it, reduced to what lima-init reads
cd_args=()
iso=""
mkdir -p "$work/cidata"
(
  cd "$work/cidata" || exit 1
  printf 'instance-id: iid-smoke\nlocal-hostname: smoke\n' >meta-data
  printf '#cloud-config\nusers:\n  - name: smoke\n' >user-data
  printf '%s\n' LIMA_CIDATA_USER=smoke LIMA_CIDATA_UID=1000 LIMA_CIDATA_HOME=/home/smoke.linux \
    LIMA_CIDATA_COMMENT=smoke LIMA_CIDATA_SHELL=/bin/sh LIMA_CIDATA_PASSWORDLESS_SUDO=1 \
    LIMA_CIDATA_IID=iid-smoke LIMA_CIDATA_VSOCK_PORT=0 >lima.env
  printf '#LIMA-START\n#LIMA-END\n' >etc_environment
  printf '#!/bin/sh\necho "smoke: cidata boot.sh ran" >/dev/console\n' >boot.sh
  chmod 755 boot.sh
)
if [ "${SMOKE_CIDATA:-1}" = 0 ] || [ "$tamper" = cidata-none ]; then
  :
elif command -v genisoimage >/dev/null; then
  genisoimage -quiet -V cidata -R -J -o "$work/cidata.iso" "$work/cidata" && iso=$work/cidata.iso
elif command -v xorriso >/dev/null; then
  xorriso -as mkisofs -quiet -V cidata -R -J -o "$work/cidata.iso" "$work/cidata" 2>/dev/null && iso=$work/cidata.iso
fi
[ -n "$iso" ] && cd_args=(-device virtio-scsi-pci,id=scsi0 -drive if=none,id=cd0,file="$iso",format=raw,media=cdrom,readonly=on -device scsi-cd,bus=scsi0.0,drive=cd0)
[ "$tamper" = cidata-two ] && [ -n "$iso" ] && cd_args+=(-drive if=none,id=cd1,file="$iso",format=raw,media=cdrom,readonly=on -device scsi-cd,bus=scsi0.0,drive=cd1)

if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then accel=kvm; else accel=tcg; fi
case $(uname -m) in
  aarch64 | arm64)
    qemu=qemu-system-aarch64 machine=virt early=earlycon
    [ $accel = kvm ] && cpu=host || cpu=max,pauth-impdef=on
    wait=900 ;;
  *)
    qemu=qemu-system-x86_64 machine=q35 early=earlycon=uart8250,io,0x3f8
    [ $accel = kvm ] && cpu=host || cpu=max
    wait=300 ;;
esac
log=$out/serial-$tag-hvc0.log early_log=$out/serial-$tag-early.log
: >"$log"
start=$(date +%s)
$qemu -machine $machine,accel=$accel -cpu $cpu -smp 2 -m 2048 \
  -display none -monitor none -no-reboot \
  -kernel "$img/dkb/kernel" -initrd "$img/dkb/initrd" \
  -append "$cmdline $early keep_bootcon" \
  -drive if=none,id=img,file="$raw",format=raw,readonly=on -device virtio-blk-pci,drive=img \
  "${cd_args[@]}" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0,romfile= \
  -device virtio-serial-pci -chardev file,id=hvc,path="$log" -device virtconsole,chardev=hvc \
  -serial file:"$early_log" &
pid=$!

# the console without colours, progress spinners and carriage returns
clean() { cat "$log" "$early_log" 2>/dev/null | sed -E 's/\x1b(\[[0-9;]*[A-Za-z]|M)//g' | tr -d '\r' | grep -av 'Job .* running'; }
case $profile in
  mkosi | nixos) done_re='Reached target .*Multi-User System' ;;
  alpine) done_re='login:' ;;
  *) echo "unknown profile $profile" >&2; kill $pid; exit 2 ;;
esac
panic_re='Kernel panic'
result=timeout
while [ $(($(date +%s) - start)) -lt $wait ]; do
  if ! kill -0 $pid 2>/dev/null; then result=exited; break; fi
  if clean | grep -qE "$panic_re"; then result=panic; break; fi
  if clean | grep -qE "$done_re"; then
    # lima-boot runs boot.sh after Docker, which may come after the login
    # prompt; services started last get a moment to report
    t=$(date +%s)
    while [ -n "$iso" ] && ! clean | grep -q 'smoke: cidata boot.sh ran' && [ $(($(date +%s) - t)) -lt 60 ]; do sleep 1; done
    sleep 5
    result=booted; break
  fi
  sleep 1
done
elapsed=$(($(date +%s) - start))
kill $pid 2>/dev/null; wait $pid 2>/dev/null
c=$(clean)
has() { grep -qE "$1" <<<"$c"; }

problems=()
if [ -n "$tamper" ]; then
  if [ $result = panic ] && has "$want"; then pass=1
  else pass=0; problems+=("$result, without the expected line: $want"); fi
else
  [ $result = booted ] || problems+=("$result")
  case $profile in
    mkosi)
      has 'Finished systemd-veritysetup@root' || problems+=(no-verity)
      has 'Mounted sysroot\.mount' || problems+=(no-sysroot)
      has 'Started ssh\.service' || problems+=(no-sshd)
      has 'Started docker\.service' || problems+=(no-docker) ;;
    nixos)
      has 'Mounted .*/sysroot/nix/store' || problems+=(no-store-mount)
      has 'Started .*SSH Daemon|Started sshd' || problems+=(no-sshd) ;;
    alpine)
      has '@@cpm [0-9.]+ switch' || problems+=(no-switch)
      has 'Starting Docker' || problems+=(no-docker)
      # parallel services interleave their lines: match each service's own error
      ! has 'ERROR: (docker|lima-init|sshd|lima-boot) ' || problems+=(service-error) ;;
  esac
  # without cidata lima-init fails, and lima-boot with it
  if [ -n "$iso" ]; then
    has 'smoke: cidata boot.sh ran' || problems+=(no-boot.sh)
    case $profile in mkosi | nixos) ! has '\[ *FAILED *\]' || problems+=(failed-units) ;; esac
  fi
  [ ${#problems[@]} = 0 ] && pass=1 || pass=0
fi
verdict=$([ $pass = 1 ] && echo pass || echo "FAIL: ${problems[*]}")
{
  echo "### smoke ($profile, $tag): $verdict after ${elapsed} s ($accel$([ -n "$iso" ] && echo ", cidata" || echo ", no cidata"))"
  echo '```'
  grep -aE 'cpvm-initramfs|cpvm: FATAL|verity|sysroot|/sysroot/nix/store|Switching [Rr]oot|@@cpm|ssh|docker|lima|cidata|cpstate|Multi-User|FAILED|ERROR|Kernel panic|login:' <<<"$c" | head -50
  echo '```'
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
[ $pass = 1 ]
