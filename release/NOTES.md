## Blueberry Linux — v0.9.0-beta

A self-hosting release. The build now runs in Blueberry's own container instead of
Arch, the ISO is assembled from the signed mirror instead of compiled locally, and
Blueberry can Secure-Boot with its own keys. The images are rebuilt and pass the
full end-to-end gate (server ISO boots to multi-user; an unattended install boots
with sshd and networkd up and no failed units). On an existing system it is
`bpm update && bpm upgrade`.

### Self-hosted build path is the default

The whole build toolchain — gcc, binutils, autotools, meson/ninja, cmake, go,
rust, LLVM + clang, the Python build modules — is packaged in the tree, so every
recipe's makedependencies resolve to a Blueberry package or a provided host name.
`build-bpm-pkg.sh` now builds in the Blueberry builder image by default: each
package's build closure is installed by extracting the already-built `.bpm` from
the local store, with no pacman and no Arch. `makedep-closure.py` computes that
closure and is provides-aware (a dep on `cargo` resolves to rust, `clang` to
llvm, `libssl.so` to openssl). Any package that cannot yet build self-hosted falls
back to the bootstrap path with a loud warning, so the switch is regression-proof.

### The ISO is assembled from the mirror

`make install` and `make iso` now fetch every prebuilt, signed base package from
the mirror by default (`BASE_SRC=mirror`) rather than compiling it locally — the
image is reproducible from published packages, the same way glibc and the kernel
already worked. `BASE_SRC=source` restores local builds for recipe work. The
switch surfaced real base-closure gaps that the mirror packages' true dependencies
need, now closed: `lzo` (btrfs), `e2fsprogs` (btrfs-convert), and a new `libtirpc`
package (lsof). `check-base` is clean.

### Secure Boot with your own keys

Blueberry can now Secure-Boot without a Microsoft-signed shim, using a key set you
enroll once. The chain is firmware to GRUB (Authenticode `db`) to kernel (`db` plus
GPG-verified) to initramfs (GPG-verified). `blueberry-secureboot` does keygen,
enroll-artifacts, sign-boot, verify and status; `sbsigntools` and `gnu-efi` are
packaged; `mkdisk` signs the boot chain when `SECUREBOOT_KEYDIR` is set. GRUB is
built with `--disable-shim-lock` so its own PGP verifier gates the kernel, and both
GRUB and the kernel are sbsigned so the firmware `LoadImage` check passes.
`make test-secureboot` proves it under QEMU and OVMF: a signed image boots and an
unsigned one is rejected. See `wiki/Secure-Boot.md`.

### Fixes and packaging

- **`bpmbuild --check`** no longer reports a false mismatch on packages with setuid
  binaries (openssh, sudo): Python 3.12+ stripped setuid bits on re-extraction.
- **`bpmbuild`** extracts sources with the `tar` filter, so GNU tarballs that ship
  an absolute-target `INSTALL` symlink extract cleanly.
- **New/updated packages:** `libxcrypt` (crypt was previously an untracked host
  bundle), `gnu-efi`, `sbsigntools`, `libtirpc`; dev files kept in `libmd`,
  `libbsd`, `fuse3` so they work as build dependencies.
- The advisory **`bpm audit` CVE report** continues to run in CI on every push.
