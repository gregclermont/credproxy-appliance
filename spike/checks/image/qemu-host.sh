#!/bin/bash
# usage: qemu-host.sh [PACKAGE...] : on a GitHub Ubuntu runner, QEMU for this
# machine's architecture, genisoimage (smoke.sh's cidata), /dev/kvm usable by
# the runner user; extra apt packages as arguments.
set -euo pipefail
case $(uname -m) in
  x86_64) qemu=qemu-system-x86 ;;
  aarch64) qemu=qemu-system-arm ;;
  *) echo "unsupported $(uname -m)" >&2; exit 1 ;;
esac
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends "$qemu" genisoimage "$@" >/dev/null
if [ -e /dev/kvm ]; then sudo chmod 666 /dev/kvm; else echo "no /dev/kvm: TCG"; fi
