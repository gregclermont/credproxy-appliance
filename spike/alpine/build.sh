#!/bin/sh
# usage: build.sh NAME [apk|static26] [lima|nolima] [ctrd|noctrd|-] [verity] -> $OUT/NAME/{cpvm.raw,dkb/{kernel,initrd,kernel.cmdline},packages.txt,MANIFEST}
# The root is always dm-verity protected; "verity" is accepted for older callers.
# Engine: CPVM_ENGINE (default podman, rootless; docker where there is no podman).
# OUT, DL default to the main checkout's .tmp (also from a worktree); DL (a dir
# holding docker-26.1.4.tgz) is read only by static26.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)")
OUT=${OUT:-$repo/.tmp/alp/out}
name=$1 docker=${2:-apk} lima=0
[ "${3:-}" != lima ] || lima=1
# ctrd: default with lima (its stop is 1 s shorter), "-" for the default
case ${4:--} in ctrd) ctrd=1 ;; -) ctrd=$lima ;; *) ctrd=0 ;; esac
case ${5:-verity} in verity) ;; *) echo "build.sh: the only root is dm-verity (fifth argument: verity or nothing)" >&2; exit 2 ;; esac
engine=${CPVM_ENGINE:-podman}
command -v "$engine" >/dev/null || [ -n "${CPVM_ENGINE:-}" ] || engine=docker
img=docker.io/library/alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf
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
$to "$engine" run --rm --network=host -e DOCKER="$docker" -e LIMA=$lima -e CTRD=$ctrd \
	-v "$here:/src:ro" -v "$OUT/$name:/out" $dl "$img" sh /src/mkimage.sh
t1=$(date +%s)
cd "$OUT/$name"
{
	echo "source: spike/alpine $(git -C "$here" rev-parse --short HEAD)$(git -C "$here" diff --quiet -- . || echo +dirty)"
	echo "docker: $docker lima: $lima ctrd: $ctrd verity: 1"
	echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ) build_seconds=$((t1 - t0))"
	echo "sizes (bytes):"
	for f in cpvm.raw dkb/kernel dkb/initrd; do echo "  $f $(wc -c <"$f" | tr -d ' ')"; done
} >MANIFEST
cat MANIFEST
