# CI/CD

Blueberry has a single CI workflow: **`.github/workflows/ci.yml`**.

## What it does

On every push, pull request, and manual dispatch it:

1. Installs the build toolchain (gcc, kernel build deps, zstd,
   cpio, `qemu-system-x86`).
2. Runs `make _check_tools`.
3. Builds the full OS: `make world` (busybox + runit + dropbear + kernel +
   initramfs).
4. Boots the result headless in QEMU and asserts the in-guest self-test
   prints `BLUEBERRY_TEST=PASS`: `make test TIMEOUT=180`.
5. On failure, uploads the QEMU serial log as a build artifact.

GitHub runners have no `/dev/kvm`, so `tools/qemu.sh` runs QEMU under TCG
automatically — slower than KVM but fully deterministic.

## Running it locally

CI runs exactly the same commands you do:

```sh
make _check_tools
make world JOBS="$(nproc)"
make test TIMEOUT=180
```

`make test` exits non-zero if the boot self-test fails, so it is safe to chain
in any pipeline.

## The boot self-test

The checks live in `src/initramfs/selftest` and run inside the guest as part
of `/init` when the kernel is booted with `bbtest` on its command line. They
verify the live CLI is functional:

- busybox + `sh` work
- core applets (`ls`, `echo`, `uname`) work
- `/proc`, `/sys`, `/dev` are mounted and populated
- `ps` sees PID 1, `/tmp` is writable, the hostname was applied

To add a check, edit `src/initramfs/selftest`, rebuild the initramfs
(automatic on `make test`), and confirm the new `PASS:` line appears.

## Tuning

- `make test TIMEOUT=<seconds>` — watchdog for slow/TCG hosts.
- `make test MEM=1G` — give the guest more RAM.
- `make test ARCH=aarch64` — boot under `qemu-system-aarch64`.
