#!/bin/sh
# usage: build.sh NAME [apk|static26] [lima|nolima] [ctrd|noctrd] [verity] -> $OUT/NAME/{cpvm.raw,dkb/{kernel,initrd,kernel.cmdline},packages.txt,MANIFEST}
# Engine: CPVM_ENGINE (default podman, rootless; docker where there is no podman).
# OUT, DL default to the main checkout's .tmp (also from a worktree); DL (a dir
# holding docker-26.1.4.tgz) is read only by static26.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)")
OUT=${OUT:-$repo/.tmp/alp/out}
name=$1 docker=${2:-apk} lima=0
[ "${3:-}" != lima ] || lima=1
ctrd=0; [ "${4:-}" != ctrd ] || ctrd=1
verity=0; [ "${5:-}" != verity ] || verity=1
engine=${CPVM_ENGINE:-podman}
command -v "$engine" >/dev/null || [ -n "${CPVM_ENGINE:-}" ] || engine=docker
img=docker.io/library/alpine:3.23@sha256:469c9ea410b9215eaee7976ba6c0639039b444be8e5d638f7abbada189971eb2
dl=
if [ "$docker" = static26 ]; then
	DL=${DL:-$repo/.tmp/alp/dl}
	[ -f "$DL/docker-26.1.4.tgz" ] || { echo "static26: no $DL/docker-26.1.4.tgz" >&2; exit 1; }
	dl="-v $DL:/dl:ro"
fi
to=; command -v timeout >/dev/null && to="timeout 1800" # not on macOS
rm -rf "${OUT:?}/${name:?}"; mkdir -p "$OUT/$name"
t0=$(date +%s)
# shellcheck disable=SC2086 # $to, $dl: empty or several words
$to "$engine" run --rm --network=host -e DOCKER="$docker" -e LIMA=$lima -e CTRD=$ctrd -e VERITY=$verity \
	-v "$here:/src:ro" -v "$OUT/$name:/out" $dl "$img" sh /src/mkimage.sh
t1=$(date +%s)
cd "$OUT/$name"
{
	echo "source: spike/alpine $(git -C "$here" rev-parse --short HEAD)$(git -C "$here" diff --quiet -- . || echo +dirty)"
	echo "docker: $docker lima: $lima ctrd: $ctrd verity: $verity"
	echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ) build_seconds=$((t1 - t0))"
	echo "sizes (bytes):"
	for f in cpvm.raw dkb/kernel dkb/initrd; do echo "  $f $(wc -c <"$f" | tr -d ' ')"; done
} >MANIFEST
cat MANIFEST
