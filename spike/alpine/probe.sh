#!/bin/sh
# Boot milestones as "@@cpm <event>" lines on the console; the host stamps them
# on arrival (a QEMU boot harness). Same script in both images: baked into the
# Alpine root, passed to the mkosi image as a system credential.
exec </dev/null >/dev/console 2>&1
m() { read -r up _ </proc/uptime; printf '\n@@cpm %s %s\n' "$up" "$*"; }
(
	n=0
	until [ -S /run/docker.sock ]; do
		n=$((n + 1)); [ $n -lt 3000 ] || exit 0
		sleep 0.02
	done
	n=0
	until docker info >/dev/null 2>&1; do
		n=$((n + 1)); [ $n -lt 600 ] || { m apifail; exit 0; }
		sleep 0.05
	done
	m api
	if docker run --rm busybox:1.37 true >/dev/null 2>&1; then m run; else m runfail; fi
	m blk "$(cat /sys/block/vda/stat)"
	m mem "$(grep -E '^(MemTotal|MemFree|Cached|AnonPages|Shmem):' /proc/meminfo | tr -s ' \n' '  ')"
	m docker "$(docker version --format '{{.Server.Version}} {{.Server.Os}}' 2>&1) $(docker info --format '{{.Driver}} {{.CgroupVersion}}' 2>&1)"
) &
net=0 ssh=0 n=0
while [ $n -lt 3000 ]; do
	if [ $net = 0 ]; then
		while read -r i d _; do
			[ "$d" = 00000000 ] && [ "$i" != Iface ] && { net=1; m net; break; }
		done </proc/net/route
	fi
	if [ $ssh = 0 ]; then
		while read -r _ la _ st _; do
			case "$la:$st" in *:0016:0A) ssh=1; m sshd; break ;; esac
		done </proc/net/tcp
	fi
	[ $net = 1 ] && [ $ssh = 1 ] && break
	n=$((n + 1))
	sleep 0.02
done
wait
