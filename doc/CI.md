# CI/CD Pipeline

Blueberry Linux uses four GitHub Actions workflows, each with a distinct role.
They are intentionally decoupled so that a package update does not require a
full kernel recompile, and a kernel recompile does not trigger on every commit.

---

## Overview

```
Every push / PR
  └─ software.yml       lint → test → build bpm         (~1 min)

Push to main (when pkgs/** or GNUmakefile changes)
  └─ packages.yml       build all packages → sign → publish   (~5-10 min)

Manual / weekly (Sunday 02:00 UTC)
  └─ world.yml          build world → QEMU smoke tests        (~40-60 min)

Weekly (Monday 06:00 UTC)
  └─ auto-update.yml    check versions → open draft PRs       (~2 min)
```

---

## `software.yml` — bpm CI

**Trigger:** every `git push`, every pull request

**Purpose:** catch regressions in the package manager quickly, on every single
commit, without waiting for any compilation.

### Jobs

```
lint → (test, build) in parallel
```

| Job | Steps | What passes/fails |
|-----|-------|------------------|
| `lint` | `go fmt ./... && git diff --exit-code` | formatting drift |
| `lint` | `go vet ./...` | vet diagnostics |
| `test` | `go test -race ./...` | unit test failures, data races |
| `build` | `make bpm` | compilation failures |
| `build` | `$OBJDIR/bpm --help` | binary runs without crashing |

The `test` and `build` jobs both depend on `lint` passing first so you get
clean output — no cascading failures from a format issue.

**Artifact uploaded:** `bpm-<sha>` (the compiled binary, kept 14 days)

### Local equivalent

```sh
cd src/bpm
go fmt ./... && git diff --exit-code
go vet ./...
go test -race ./...
cd ..
make bpm
```

---

## `packages.yml` — Package Repository

**Trigger:** push to `main`/`master` when any of these paths change:
- `pkgs/**` (any BBUILD recipe)
- `src/bpm/**` (the build engine)
- `tools/mkrepo.sh` (the index builder)
- `GNUmakefile`, `Make.config`

Also: manual via `workflow_dispatch`

**Purpose:** build all package recipes and publish them to the repo server.
Does **not** depend on `make world`. Each BBUILD compiles its package using
`musl-gcc` from the Ubuntu `musl-tools` apt package. No kernel compilation.

### Jobs

```
build → publish (only on push to main, not on PRs or forks)
```

| Job | Key steps |
|-----|-----------|
| `build` | `apt install musl-tools libssl-dev bc flex bison ...` |
| `build` | `make repo` → builds all 9 (or more) core packages |
| `build` | Lists packages, uploads `packages` artifact |
| `publish` | Downloads `packages` artifact |
| `publish` | Signs each `.bb` with `minisign` using `MINISIGN_PRIVATE_KEY` |
| `publish` | Connects to Tailscale (to reach private NAS) |
| `publish` | `rsync` to `deploy@<server>:/srv/blueberry/repo/packages/x86_64/` |

**Artifact uploaded:** `packages` (all `.bb` files + BBINDEX.zst, kept 30 days)

### Why this doesn't need `make world`

`make repo` calls `bpm build` for each BBUILD. Each BBUILD script uses
`musl-gcc` (from `musl-tools`) which is a wrapper around the host GCC that
links against musl libc instead of glibc. No kernel, no sysroot, no world
build needed.

The packages are self-contained — each BBUILD downloads its own source,
compiles it, and installs it into `$pkgdir`. Dependencies between packages
(e.g. openssh needs openssl headers) are resolved by the build host having
`libssl-dev` installed.

### Local equivalent

```sh
# On Debian/Ubuntu (has musl-tools):
sudo apt install musl-tools libssl-dev
make repo

# On other systems (needs the world build sysroot first):
make musl    # builds sysroot + musl-gcc wrapper, ~2 min
make repo

# Build just one package:
make pkg PKG=musl
make pkg PKG=openssh
```

---

## `world.yml` — Full OS Build + QEMU Tests

**Trigger:** manual (`workflow_dispatch`) or weekly schedule (Sunday 02:00 UTC)

**Purpose:** verify that the OS compiles and that the initramfs boots to a
working shell, network, and package manager. This is a **CI smoke test** — not
a simulation of the production deployment target, which is real bare-metal
x86_64 hardware. QEMU is used purely because it lets CI verify boot correctness
without physical machines.

This is the slow job (~40-60 minutes) so it does not run on every push.

### Jobs

```
build-world ──┐
               ├─► smoke-test
build-packages ┘
```

`build-world` and `build-packages` run **in parallel** to save time.

| Job | What it does |
|-----|--------------|
| `build-world` | `apt install` all build deps including kernel headers, flex, bison |
| `build-world` | `make world JOBS=$(nproc)` — full kernel + sysroot + userland + initramfs |
| `build-world` | Uploads `boot-<run_id>` artifact (vmlinuz + initramfs) |
| `build-packages` | `make repo` — builds packages (for the bpm install smoke test) |
| `build-packages` | Uploads `repo-<run_id>` artifact |
| `smoke-test` | Downloads both artifacts |
| `smoke-test` | Unpacks initramfs, injects `test-init` and networking applets |
| `smoke-test` | Starts a Python HTTP server on port 8080 serving the package repo |
| `smoke-test` | Boots QEMU with `rdinit=/test-init BPMREPO=http://10.0.2.2:8080` |
| `smoke-test` | Greps output for `SMOKE_TEST_RESULT=PASS` |
| `smoke-test` | Uploads `boot-log-<run_id>` artifact (always, for debugging) |

### QEMU smoke test details

> **Note:** QEMU is used only for CI boot verification. The production deployment
> target is real bare-metal x86_64 hardware. The smoke test confirms the kernel
> boots and the package manager works — it is not a hardware compatibility test.

The test-init script (`src/initramfs/test-init`) runs as PID 1 inside the
initramfs via `rdinit=/test-init`. It has no real root disk — everything runs
in RAM. It:

1. Mounts `/proc`, `/sys`, `/dev`
2. Runs basic shell commands: `ls /bin`, `busybox ps`, `mount`, `busybox uname -a`
3. Waits up to 5s for an Ethernet interface to appear (e1000 driver probes PCI
   concurrently with init), assigns static `10.0.2.15/24` — QEMU SLIRP always
   uses this range
4. Pings the QEMU gateway at `10.0.2.2`
5. Fetches `http://1.1.1.1/` to verify internet access
6. If `BPMREPO=` is set on the kernel cmdline: creates a repo config pointing
   to the CI's local Python server (`10.0.2.2:8080`), runs `bpm update` and
   `bpm install zlib`
7. Prints `SMOKE_TEST_RESULT=PASS` or `FAIL`
8. Powers off (`halt -f -p`)

QEMU network setup: `-net nic,model=e1000 -net user`
- Guest IP: `10.0.2.15` (static; QEMU SLIRP always uses this subnet)
- Gateway / host: `10.0.2.2` (the CI Python HTTP server is accessible here)
- DNS: `10.0.2.3`

### Local equivalent

Use absolute paths throughout — relative paths break when you `cd` into a work directory.

```sh
SRCDIR=~/projects/blueberry        # adjust if your clone is elsewhere
OBJDIR=~/projects/blueberry-build  # default output location

# The easiest way — just run:
cd $SRCDIR && make smoke-test

# Or manually, step by step:

# 1. Build world (one-time, ~20-40 min — skip if already done)
cd $SRCDIR && make world JOBS=$(nproc)

# 2. Build packages
cd $SRCDIR && make repo

# 3. Serve packages + boot
python3 -m http.server 8080 --directory $OBJDIR/repo &
mkdir -p /tmp/itest
zstd -d < $OBJDIR/boot/initramfs.cpio.zst | cpio -id --quiet -D /tmp/itest
cp $SRCDIR/src/initramfs/test-init /tmp/itest/test-init && chmod 755 /tmp/itest/test-init
(cd /tmp/itest && find . | sort | cpio -H newc -o --quiet | zstd -19 -q > /tmp/test.cpio.zst)

qemu-system-x86_64 \
  -kernel $OBJDIR/boot/vmlinuz \
  -initrd /tmp/test.cpio.zst \
  -append "console=ttyS0 rdinit=/test-init BPMREPO=http://10.0.2.2:8080" \
  -display none -serial stdio -monitor null \
  -no-reboot -m 512M -net nic,model=e1000 -net user
```

Watch for `SMOKE_TEST_RESULT=PASS` in the serial output. The VM powers off automatically when done.

---

## `auto-update.yml` — Upstream Version Checks

**Trigger:** weekly cron (Monday 06:00 UTC) or manual `workflow_dispatch`

**Purpose:** detect when core packages have new upstream versions and
automatically open draft PRs to update them.

### Job

| Step | What it does |
|------|--------------|
| `git config` | Sets bot committer identity |
| `bash tools/check-updates.sh --pr` | Checks 7 upstreams, creates PRs for updates |

### Package checks

| Package | How it checks |
|---------|--------------|
| `musl` | Parses `git.musl-libc.org/cgit/musl/refs/tags` for latest `vX.Y.Z` tag |
| `busybox` | Parses `busybox.net/downloads/` for latest tarball version |
| `linux-headers` | Queries `kernel.org/releases.json` for latest stable major.minor |
| `openssl` | GitHub releases API for `openssl/openssl` (latest non-pre-release) |
| `util-linux` | GitHub tags API for `util-linux/util-linux` (stable tags only) |
| `zlib` | GitHub releases API for `madler/zlib` |
| `openssh` | Parses `cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/` for latest tarball |

Packages without upstream checks: `runit` (releases very rarely), `bpm`
(internal project).

### PR format

Each PR is created on branch `auto-update/<pkg>-<version>`:

```
Title:  chore(pkgs): update musl 1.2.5 → 1.2.6
Status: Draft (requires human review before merge)
Body:   Table showing old/new version, checksum updated: yes/no
```

After merge, `packages.yml` automatically rebuilds and publishes the updated
package.

### Local equivalent

```sh
# Just check — no PRs, no changes
tools/check-updates.sh

# Check a single package
tools/check-updates.sh musl

# Full run: bump BBUILDs and open PRs (needs gh CLI + GITHUB_TOKEN)
tools/check-updates.sh --pr
```

---

## Required GitHub Secrets

Go to **Settings → Secrets and variables → Actions**:

| Secret | Used by | How to get it |
|--------|---------|---------------|
| `MINISIGN_PRIVATE_KEY` | `packages.yml` | `minisign -G -s key.key -p key.pub` |
| `REPO_SSH_KEY` | `packages.yml` | `ssh-keygen -t ed25519 -f deploy_key` |
| `TAILSCALE_AUTHKEY` | `packages.yml` | tailscale.com → Settings → Keys → Generate |

If your repo server has a public IP, remove the Tailscale step from
`packages.yml` and update the rsync destination.

---

## Workflow File Summary

| File | Triggers | Duration | Publishes |
|------|---------|----------|-----------|
| `.github/workflows/software.yml` | every push/PR | ~1 min | bpm binary artifact |
| `.github/workflows/packages.yml` | push to main (pkgs changed) | ~5-10 min | `.bb` files to repo server |
| `.github/workflows/world.yml` | manual / weekly | ~40-60 min | boot artifacts, boot log |
| `.github/workflows/auto-update.yml` | weekly / manual | ~2 min | draft PRs on GitHub |
