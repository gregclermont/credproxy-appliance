# credproxy appliance images

Definitions and CI for the appliance VM images that
credproxy workspaces boot under
[Lima](https://lima-vm.io/) (VZ on macOS, QEMU on Linux). Only the images
are here: credproxy's own code is not part of this repository.

Each image is a directory the workspace VM boots directly, without a
bootloader:

```
cpvm.raw                 read-only root (erofs) under dm-verity, plus its hash partition
dkb/kernel               uncompressed kernel (what VZ's Linux boot loader takes)
dkb/initrd
dkb/kernel.cmdline       includes roothash=: the root hash travels with the kernel, not in the image
```

The guest root is read-only, with a tmpfs overlay on top; a separate state
disk (Lima `additionalDisks`) holds `/home`, Docker's data and the sshd host
key, formatted on first use. Lima's cloud-init provisioning is replaced by a
small `lima-init` that reads Lima's cidata. Docker starts with the boot.

| image | definition | build | CI |
|---|---|---|---|
| Debian 13, mkosi | `spike/mkosi/` | `spike/mkosi/build.sh` inside a Debian 13 builder (a Lima VM, `spike/mkosi/builder.yaml`, or a container) | `.github/workflows/mkosi-image.yml` |
| NixOS 26.05 | `spike/nixos/` (also reads files from `spike/mkosi/`) | `spike/nixos/build.sh [OUTDIR]`: Nix runs in a container (Docker or Podman), none on the host | `.github/workflows/nixos-image.yml` |
| Alpine 3.23, OpenRC | `spike/alpine/` | `spike/alpine/build.sh NAME apk lima noctrd verity`: runs in an Alpine container | `.github/workflows/alpine-image.yml` |

Each directory's README has the details: what the image contains, why, and
the gotchas found on the way.

## Building

- **mkosi:** in a Debian 13 environment with mkosi 25.x, mount
  `spike/mkosi` at `/src` and an output directory at `/out`, then run
  `/src/build.sh`. The CI workflow shows the exact container invocation
  (privileges included); `spike/mkosi/README.md` shows the Lima builder VM.
- **NixOS:** `spike/nixos/build.sh /some/dir` (Docker by default,
  `CPVM_ENGINE=podman` otherwise). The first build fetches about 450 MiB from
  cache.nixos.org into a container volume. `CPVM_SYSTEM=aarch64-linux`
  builds for arm64 (needs an arm64 host or builder).
- **Alpine:** `spike/alpine/build.sh ci apk lima noctrd verity` (rootless
  Podman by default, `CPVM_ENGINE=docker` otherwise); output in
  `.tmp/alp/out/ci`.

Images are built for the build host's architecture (x86_64 or arm64).

## CI

Each workflow runs on GitHub's x86_64 and arm64 runners. It builds the
image, writes a report to the job summary (sizes, root hash, package list,
checksums), uploads the image as a short-lived artifact, and smoke-boots it
under QEMU with direct kernel boot (KVM when the runner has it): the boot
must reach its init system with the verity root mounted. Lima itself is not
involved in CI: without its cidata, provisioning steps fail by design and the
smoke test does not count them.

Third-party actions are pinned by commit.

## Status

These are working definitions from an ongoing evaluation, not released
artifacts: no signed images, no versioning, no update story yet. Issues and
pull requests are not accepted here; the definitions are maintained
elsewhere and exported to this repository.

## License

Apache License 2.0: see `LICENSE`. `NOTICE` lists the copyright holder
and the third-party material these definitions adapt. The images built from
these definitions contain third-party software (Debian, NixOS, Alpine,
Docker and others) under those projects' own licences.
