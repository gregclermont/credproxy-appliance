#!/bin/bash
# Build the NixOS appliance with Nix in a container (docker or podman; no Nix
# on the host). The store persists in the volume cpv2-nix-store
# (CPVM_NIX_VOLUME), Nix's fetcher cache in <volume>-cache.
#   build.sh [OUTDIR] [nix build args...]
# OUTDIR (default <checkout>/.tmp/nixos/out/latest) gets cpvm.raw and
# dkb/{kernel,initrd,kernel.cmdline}: point CREDPROXY_APPLIANCE at it.
# CPVM_SYSTEM=aarch64-linux selects the other architecture (needs a native
# or remote aarch64 builder).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
spike=$(dirname "$here")
common=$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)
out=${1:-$(dirname "$common")/.tmp/nixos/out/latest}
shift || true
arch=$(uname -m); [ "$arch" = arm64 ] && arch=aarch64 # macOS on Apple silicon
system=${CPVM_SYSTEM:-$arch-linux}
image=${CPVM_NIX_IMAGE:-docker.io/nixos/nix@sha256:746280551ddc1c72177d1a597c05eacac86dfaa18d5d649bf86411278bcd5470}
engine=${CPVM_ENGINE:-docker}
vol=${CPVM_NIX_VOLUME:-cpv2-nix-store}
mkdir -p "$out"
out=$(cd "$out" && pwd)
# a snapshot of the sources: edits made while the build runs don't leak in
# in the checkout's .tmp (git-ignored): under $HOME, which every engine's VM
# shares (colima does not share macOS's /var/folders); CPVM_TMPDIR overrides
tmp=${CPVM_TMPDIR:-$(dirname "$common")/.tmp}
mkdir -p "$tmp"
src=$(mktemp -d "$tmp/nixos-src.XXXXXX")
trap 'rm -rf "$src"' EXIT
cp -a "$spike/nixos" "$spike/mkosi" "$src/"

# CPVM_LOCK: a lock file held for the build itself (shared benchmark hosts)
if [ -n "${CPVM_LOCK:-}" ]; then
	exec 9>>"$CPVM_LOCK"
	flock -w 5400 9
fi
# seccomp=unconfined: Nix's build sandbox sets up namespaces (sethostname)
# that the default container profile refuses; no other privilege.
start=$(date +%s)
"$engine" run --rm --security-opt seccomp=unconfined \
	-v "$vol":/nix -v "$vol-cache":/root/.cache -v "$src":/src:ro -v "$out":/out \
	-e NIX_CONFIG="experimental-features = nix-command flakes
sandbox = true
max-jobs = auto" \
	"$image" sh -euc '
		sys=$1; shift
		f="path:/src?dir=nixos"
		nix build --no-update-lock-file -L --out-link /tmp/app "$f#packages.$sys.appliance" "$@"
		rm -rf /out/dkb /out/cpvm.raw
		mkdir -p /out/dkb
		cp -L /tmp/app/cpvm.raw /out/cpvm.raw
		cp -L /tmp/app/dkb/kernel /tmp/app/dkb/initrd /tmp/app/dkb/kernel.cmdline /out/dkb/
		chmod 644 /out/cpvm.raw /out/dkb/*
		top=$(tr " " "\n" </out/dkb/kernel.cmdline | grep "^init=" | cut -d= -f2)
		top=${top%/init}
		{
			echo "toplevel: $top"
			echo "closure: $(nix path-info -S "$top" | tr -s " " | cut -d" " -f2) bytes, $(nix path-info -r "$top" | wc -l) paths"
			echo "kernel.cmdline: $(cat /out/dkb/kernel.cmdline)"
		} >/out/MANIFEST
		nix path-info -rSh "$top" | sort -k2 -h | tail -25 >/out/closure-top.txt
		# each path by its own size (NAR bytes), largest first
		nix path-info -rs "$top" | sort -k2 -rn >/out/closure-self.txt
		# a rootful engine writes as root: hand the outputs to the owner of OUTDIR
		# (where the mount refuses chown, the host-side chmod below says so)
		chown -R "$(stat -c %u:%g /out)" /out/cpvm.raw /out/dkb /out/MANIFEST /out/closure-top.txt /out/closure-self.txt || true
	' sh "$system" "$@" 9>&-
chmod u+w "$out/cpvm.raw" "$out"/dkb/*
echo "build_seconds: $(($(date +%s) - start))" >>"$out/MANIFEST"
sha=sha256sum
command -v sha256sum >/dev/null || sha="shasum -a 256" # macOS
(cd "$out" && $sha cpvm.raw dkb/*) >>"$out/MANIFEST"
cat "$out/MANIFEST"
