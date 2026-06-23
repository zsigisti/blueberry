# Contributing to Blueberry Linux

## 1. Ways to Contribute

- **Core system** — the build system, kernel config, init scripts, or the
  live-CLI initramfs
- **Documentation** — improve or extend `doc/`
- **Bug reports** — open an issue on GitHub

---

## 2. Development Setup

```sh
git clone https://github.com/zsigisti/blueberry.git
cd blueberry

# Check build prerequisites
make _check_tools

# Full world build (kernel + userland + initramfs)
make world

# Boot it and try your change interactively
make run

# Run the automated boot self-test
make test
```

The fast inner loop for live-CLI work is editing
`src/initramfs/{init,selftest,profile}` and re-running `make test` — the
initramfs rebuilds automatically because the stamp depends on those files.

---

## 3. Making a Change

1. **Branch** off `master`.
2. **Edit** the relevant component:
   - boot behaviour / live CLI → `src/initramfs/init`
   - self-test coverage → `src/initramfs/selftest`
   - shell environment → `src/initramfs/profile`
   - kernel options → `src/kernel/config`
   - userland versions → `Make.config`
   - QEMU runner → `tools/qemu.sh`
3. **Verify**: `make test` must print `BLUEBERRY_TEST=PASS`. If you changed
   the kernel or userland, run a full `make world` first.
4. **Commit** using Conventional Commits (`feat:`, `fix:`, `docs:`, `ci:`, …).
5. **Open a PR**. CI builds the world and boot-tests it in QEMU.

---

## 4. Coding Conventions

- Shell scripts are POSIX `sh` (busybox ash) unless they only ever run on the
  build host, in which case `bash` is fine (`tools/qemu.sh`).
- Keep `/init` dependency-free: it runs as PID 1 with only busybox available.
- Every new boot capability should come with a matching check in
  `src/initramfs/selftest`.

---

## 5. Commit Message Format

```
<type>: <short summary>

<optional body explaining the why>
```

Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`, `ci`.
