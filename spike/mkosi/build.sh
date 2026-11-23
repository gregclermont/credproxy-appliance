#!/bin/bash
# Run inside the builder VM: build the image, write the direct-boot files
# (kernel, initrd, kernel.cmdline) to /out/dkb and the image to /out. Extra args
# go to mkosi (e.g. --cache-only=always to stay offline).
set -euo pipefail
# fresh copy of the config trees (cp alone would keep files deleted from /src)
mkdir -p ~/w && cd ~/w && sudo rm -rf mkosi.extra mkosi.repart mkosi.conf.d initrd && cp -a /src/. ./
# minimal initrd first (initrd/), then the image using it
(cd initrd && sudo mkosi -f "$@" build)
sudo mkosi -f --initrd="$PWD/initrd/$(cd initrd && ls initrd.cpio*)" "$@" build
# No UKI without a bootloader, so mkosi writes no roothash anywhere. systemd-repart
# derives the partition UUIDs from it: root = first 128 bits, root-verity = last 128.
uuid() { sudo sfdisk --part-uuid cpvm.raw "$1" | tr -d '-' | tr 'A-F' 'a-f'; }
roothash=$(uuid 1)$(uuid 2)
cmdline=$(sed -n 's/^KernelCommandLine=//p' /src/mkosi.conf)
mkdir -p /out/dkb
# arm64's vmlinuz is a gzip'd Image: VZLinuxBootLoader takes only the uncompressed one
if [ "$(head -c 2 cpvm.vmlinuz | od -A n -t x1 | tr -d ' ')" = 1f8b ]; then
	zcat cpvm.vmlinuz > /out/dkb/kernel
else
	cp cpvm.vmlinuz /out/dkb/kernel
fi
cp cpvm.initrd /out/dkb/initrd
echo "roothash=$roothash $cmdline" > /out/dkb/kernel.cmdline
cp cpvm.raw /out/cpvm.raw
cat /out/dkb/kernel.cmdline
