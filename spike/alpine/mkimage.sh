#!/bin/sh
# Runs inside an alpine:3.24 container (build.sh): root filesystem with
# `apk --root`, cpvm.raw = GPT with that root as erofs (lz4hc, as the mkosi
# image) and its dm-verity hash partition (veritysetup format), the linux-virt
# kernel, a busybox initramfs (initramfs-init) and the cmdline with roothash=
# in dkb/.
# DOCKER=apk: Alpine's docker-engine. DOCKER=static26: Alpine's package with
# its binaries replaced by Docker's static 26.1.4 (/dl/docker-26.1.4.tgz), to
# separate Docker's version from the rest of the image.
set -eu
R=/work/root O=/out S=/src
DOCKER=${DOCKER:-apk}
# LIMA=1: also what Lima's boot scripts need on Alpine: lima-boot
# (runs cidata's boot.sh), an acpid service for busybox's acpid (10-alpine-prep.sh
# enables it),
# GNU tar/coreutils/grep/findutils (credproxy's guest commands), rsync (Lima's
# 30-install-packages.sh apk-adds it on every boot otherwise); no probe.
LIMA=${LIMA:-0}
# CTRD=1: containerd as its own OpenRC service (ctrd/), dockerd pointed at it.
CTRD=${CTRD:-0}
apk add -q erofs-utils kmod cpio busybox-static zstd cryptsetup device-mapper-static sfdisk
mkdir -p $R/etc/apk
cp -a /etc/apk/keys $R/etc/apk/
cp /etc/apk/repositories $R/etc/apk/
apk add -q --root $R --initdb --no-cache \
	alpine-baselayout alpine-release busybox busybox-binsh musl-utils openrc \
	openssh-server openssh-keygen sudo shadow bash e2fsprogs sfdisk blkid kmod \
	iptables ip6tables ca-certificates tzdata linux-virt \
	docker-engine docker-cli docker-openrc
# credproxy's guest commands use GNU options (tar --no-same-permissions,
# chown/chmod --reference, grep -z)
[ "$LIMA" != 1 ] || apk add -q --root $R --no-cache tar coreutils grep findutils rsync
kver=$(ls $R/lib/modules)

if [ "$DOCKER" = static26 ]; then
	mkdir -p /work/d26 && tar -xzf /dl/docker-26.1.4.tgz -C /work/d26
	for b in /work/d26/docker/*; do
		n=${b##*/}
		[ -e "$R/usr/bin/$n" ] || echo "static26: $n has no Alpine counterpart, added" >&2
		install -m 755 "$b" "$R/usr/bin/$n"
	done
	[ ! -e $R/usr/bin/tini-static ] || ln -sf docker-init $R/usr/bin/tini-static
fi

cp -a $S/rootfs/. $R/
install -m 755 $S/probe.sh $R/usr/libexec/cpvm/probe
[ "$LIMA" != 1 ] || cp -a $S/lima/. $R/
[ "$CTRD" != 1 ] || cp -a $S/ctrd/. $R/
chmod 755 $R/etc/init.d/cp* $R/etc/init.d/lima-init $R/usr/libexec/cpvm/*

# docker group at the gid the mkosi image pins
old=$(chroot $R getent group docker | cut -d: -f3)
if [ "$old" != 102 ]; then
	chroot $R groupmod -g 102 docker
	chroot $R find / -xdev -gid "$old" -exec chgrp -h 102 {} +
fi

rl() { mkdir -p $R/etc/runlevels/$2 && ln -sf /etc/init.d/$1 $R/etc/runlevels/$2/$1; }
rm -rf $R/etc/runlevels/*/*
for s in devfs sysfs cgroups cpprefetch cphw; do rl $s sysinit; done
[ "$LIMA" = 1 ] || rl cpprobe sysinit
for s in cpmodules sysctl cpstate cpnet lima-init sshd docker cplog; do rl $s default; done
[ "$LIMA" != 1 ] || { rl lima-boot default; rl acpid default; }
[ "$CTRD" != 1 ] || rl cpcontainerd default

# the image ships no host key (cpstate makes one on the state disk)
rm -f $R/etc/ssh/ssh_host_*
: >$R/etc/fstab
echo cpvm >$R/etc/hostname
sed -i 's/^\(root:[^:]*\):[^:]*:/\1:*:/' $R/etc/shadow 2>/dev/null || true

# prefetch list: the binaries dockerd and containerd fault in at start
pf=
for b in usr/bin/containerd usr/bin/dockerd usr/bin/docker usr/bin/containerd-shim-runc-v2 usr/bin/runc usr/sbin/xtables-nft-multi sbin/xtables-nft-multi; do
	[ -e "$R/$b" ] && pf="$pf /$b"
done
sed -i "s|@PREFETCH@|$pf|" $R/etc/init.d/cpprefetch

mkdir -p $O/dkb
k=$R/boot/vmlinuz-virt
if [ "$(head -c 8 $k | tail -c 4)" = zimg ]; then
	# arm64 EFI zboot: VZLinuxBootLoader takes only the uncompressed Image
	[ "$(head -c 28 $k | tail -c 4)" = gzip ] || { echo "zboot: not gzip" >&2; exit 1; }
	off=$(od -A n -t u4 -j 8 -N 4 $k | tr -d ' ') len=$(od -A n -t u4 -j 12 -N 4 $k | tr -d ' ')
	tail -c +$((off + 1)) $k | head -c $len | gzip -dc >$O/dkb/kernel
else
	cp $k $O/dkb/kernel
fi
rm -rf $R/boot/* $R/var/cache/apk/* $R/lib/apk/db/scripts.tar 2>/dev/null || true

# initramfs: static busybox, the modules needed to reach the root, init
I=/work/initramfs
mkdir -p $I/bin $I/lib/modules $I/dev $I/proc $I/sys $I/lower $I/rw $I/newroot
cp /bin/busybox.static $I/bin/busybox
ln -s busybox $I/bin/sh
cp $S/initramfs-init $I/init && chmod 755 $I/init
: >$I/modules
mods="virtio_blk erofs overlay dm-verity"
cp /usr/sbin/dmsetup.static $I/bin/dmsetup
modprobe -d $R -S "$kver" --show-depends -a $mods | awk '$1 == "insmod" {print $2}' |
	while read -r m; do
		n=${m##*/}; n=${n%.gz}
		[ -e $I/lib/modules/$n ] && continue
		gzip -dc "$m" >$I/lib/modules/$n
		echo "$n" >>$I/modules
	done
(cd $I && find . | cpio -o -H newc --quiet | gzip -9) >$O/dkb/initrd

W=/work/img
mkdir -p $W
mkfs.erofs --quiet -zlz4hc $W/root $R
: >$W/hash
rh=$(veritysetup format $W/root $W/hash | sed -n 's/^Root hash:[[:space:]]*//p')
case $rh in *[!0-9a-f]*) rh= ;; esac
[ ${#rh} = 64 ] || { echo "veritysetup format failed" >&2; exit 1; }
mib=1048576
pad() { s=$(stat -c %s "$1"); truncate -s $(( (s + mib - 1) / mib * mib )) "$1"; stat -c %s "$1"; }
rs=$(pad $W/root) hs=$(pad $W/hash)
head -c $mib /dev/zero >$W/lead
cat $W/lead $W/root $W/hash $W/lead >$O/cpvm.raw
rm -f $W/root $W/hash
# root and root-verity partition types (discoverable partitions spec)
case $(apk --print-arch) in
x86_64) pr=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709 pv=2C7357ED-EBD2-46D9-AEC1-23D437EC2BF5 ;;
aarch64) pr=B921B045-1DF0-41C3-AF44-4C6F280D3FAE pv=DF3300CE-D69F-4C92-978C-9BFB0F38D820 ;;
*) echo "no partition types for $(apk --print-arch)" >&2; exit 1 ;;
esac
# partition GUIDs = the root hash's halves (systemd's convention): the
# initramfs refuses a disk whose partitions are not this image's
uuid() { echo "$1" | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)/\1-\2-\3-\4-/'; }
ur=$(uuid "$(echo "$rh" | cut -c1-32)") uv=$(uuid "$(echo "$rh" | cut -c33-64)")
sfdisk -q --label gpt $O/cpvm.raw <<EOT
start=2048, size=$((rs / 512)), type=$pr, uuid=$ur, name=root
start=$((2048 + rs / 512)), size=$((hs / 512)), type=$pv, uuid=$uv, name=root-verity
EOT
cl="roothash=$rh console=hvc0 net.ifnames=0 page_reporting.page_reporting_order=0"
echo "$cl" >$O/dkb/kernel.cmdline
{
	echo "alpine: $(cat $R/etc/alpine-release) kernel: $kver docker: $DOCKER lima: $LIMA ctrd: $CTRD"
	chroot $R apk info -v 2>/dev/null | sort
} >$O/packages.txt
chroot $R /usr/bin/dockerd --version >>$O/packages.txt 2>&1 || true
cat $I/modules >$O/initramfs-modules.txt
# a rootful engine writes as root: hand the outputs to the owner of /out
chown -R "$(stat -c %u:%g $O)" $O
