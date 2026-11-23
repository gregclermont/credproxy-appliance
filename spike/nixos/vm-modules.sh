# Keep the kernel modules a VM can use: drop the drivers for physical
# hardware (classes Debian's cloud kernel leaves out), keep every kernel
# feature (net/, fs/, crypto/, block, md/dm, KVM, virtio and the other
# paravirtual drivers, software network devices). The dependencies of what
# stays are kept whatever their directory.
#   vm-modules.sh SRC DST   (SRC, DST: lib/modules/<version> directories)
set -euo pipefail
src=$1 dst=$2
drop='^kernel/(sound/|drivers/(accessibility|atm|auxdisplay|bcma|bluetooth|comedi|counter|cpufreq|crypto|dca|dpll|edac|extcon|fpga|gnss|gpio|gpu|greybus|hid|hsi|hte|hwmon|i2c|i3c|iio|infiniband/hw|input/(gameport|joystick|keyboard|misc|mouse|rmi4|tablet|touchscreen)|isdn|leds|media|memstick|mfd|mmc|most|mtd|mux|net/(arcnet|can|dsa|ethernet|fddi|hamradio|ieee802154|ipa|mdio|pcs|phy|plip|thunderbolt|usb|wan|wireless|wwan)|nfc|ntb|parport|pcmcia|phy|pinctrl|platform|power|powercap|pwm|rapidio|regulator|scsi/[^/]+/|siox|slimbus|soundwire|spi|spmi|ssb|staging|thermal|thunderbolt|ufs|usb|w1)/)'
# virtual devices inside the dropped classes
except='^kernel/drivers/(gpu/drm/(virtio|qxl|tiny/bochs|tiny/cirrus-qemu|vmwgfx|hyperv)/|hid/(hid|hid-generic|uhid|hid-hyperv)[.]ko|crypto/virtio/|net/can/(vcan|vxcan)[.]ko|net/ethernet/(amazon|google|microsoft)/|scsi/(device_handler|libsas)/)'
mods=$(cut -d: -f1 "$src/modules.dep")
dropped=$(grep -E "$drop" <<<"$mods" | grep -Ev "$except" || true)
# a driver that needs a dropped module drives that hardware too (parport,
# PCMCIA, a NIC's storage offload...): drop it, unless excepted
keep=$(awk -F': *' -v ex="$except" 'NR==FNR { d[$1] = 1; next } ($1 in d) { next }
	$1 ~ /^kernel\/drivers\// && $1 !~ ex { n = split($2, x, " "); for (i = 1; i <= n; i++) if (x[i] in d) next }
	{ print $1 }' <(echo "$dropped") "$src/modules.dep")
# modules.dep lists every module's dependencies, transitively
closure=$(awk -F': *' 'NR==FNR { k[$1] = 1; next } ($1 in k) { print $1; n = split($2, d, " "); for (i = 1; i <= n; i++) print d[i] }' \
	<(echo "$keep") "$src/modules.dep" | sort -u)
mkdir -p "$dst"
for f in $closure; do
	mkdir -p "$dst/${f%/*}"
	cp "$src/$f" "$dst/$f"
done
cp "$src"/modules.{builtin,builtin.modinfo,order} "$dst/"
echo "vm-modules: kept $(wc -l <<<"$closure") of $(wc -l <<<"$mods") modules, $(( $(wc -l <<<"$closure") - $(wc -l <<<"$keep") )) only as dependencies"
