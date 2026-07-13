# CI/CD

Blueberry splits its automation in two: a **lightweight GitHub Actions gate**
that runs on every push, and a **manual release** cut from the project's own
build box. Building the world (an Arch build container full of packages, plus
multi-GB ISOs) is far too heavy and too large for GitHub runners, so that stays
local — GitHub only runs the checks that don't need a full image build.

## The CI gate — `.github/workflows/ci.yml`

Runs on every push and pull request to `master`, on stock `ubuntu-latest`
runners (no Arch container). Three jobs:

- **recipe closure + bpmbuild** — `check-closure.py` asserts the recipe
  dependency graph is closed (every `depends` resolves to a recipe or a
  host-provided name), then builds a fixture package with `bpmbuild` and proves
  `bpmbuild --check` accepts it and rejects a payload tampered after packaging.
- **bpm unit + integration tests** — `cargo test` (version compare, manifest
  parsing) plus `tools/test/bpm-integration.sh`, the end-to-end
  install/upgrade/rollback/downgrade/remove + config-preservation lifecycle
  against real `.bpm` fixtures.
- **package freshness (advisory)** — `check-updates.py` reports which recipes
  are behind upstream. `continue-on-error`, so it never blocks a merge —
  upstream releases are not our regressions.

What CI deliberately does **not** do: build the base image, run `check-base`
(needs a built rootfs), or boot an ISO. Those run on the build box (below).

## Cutting a release

Releases are **manual** and cut from the build box, where the ISOs are built.
ISOs are attached **directly to the GitHub release** as assets (up to 2 GB each)
— they are never uploaded to the project mirror, which carries only `.bpm`
packages and the pinned kernel/glibc.

```sh
# 1. build the images
make server-iso            # systemd live CLI ISO (the primary artifact)
make iso                   # busybox rescue ISO (optional)

# 2. gate them
make test-server           # headless boot: assert multi-user.target

# 3. write the notes, then cut the release
$EDITOR release/NOTES.md   # plain text, no emoji headers
make release TAG=v0.7.1-beta TITLE="v0.7.1-beta — <summary>"
```

`tools/release/stage-release.sh` (invoked by `make release`) attaches every
non-desktop `iso/*.iso` to a new GitHub release, uses `release/NOTES.md` as the
body, and marks it a pre-release when the tag contains `-beta`/`-rc`/`-alpha`.

## Local / build-box checks

Run these before a release (CI runs the first four automatically):

```sh
python3 tools/pkg/check-closure.py     # recipe dependency graph is closed
cd src/bpm-rs && cargo test            # bpm unit tests
sh tools/test/bpm-integration.sh       # bpm lifecycle end-to-end
python3 tools/pkg/check-updates.py     # which recipes are behind upstream

make world && make test-server         # build base + headless boot self-test
make test-install                      # unattended install to a disk image, assert boot
make check-base                        # base binaries' DT_NEEDED are all provided
make repo-build                        # build every packages/*/bpm.toml
```

## The boot self-test

`make test-server` boots the server ISO headless and asserts it reaches
`multi-user.target` (systemd). The older busybox smoke path (`make test`) boots
the initramfs self-test in `src/initramfs/selftest`, which runs inside the guest
from `/init` when the kernel command line contains `bbtest`: it verifies the live
CLI is functional (`sh` + core applets, `/proc`/`/sys`/`/dev` mounted, PID 1
visible, `/tmp` writable, hostname applied) and prints `BLUEBERRY_TEST=PASS`.
