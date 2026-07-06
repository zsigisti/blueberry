# CI/CD

Blueberry has **one** GitHub workflow: `.github/workflows/release.yml`. There is
no per-push build or test pipeline — building the world happens on the project's
own build box, not on GitHub runners (GitHub can't build an Arch container full
of packages cheaply, and git rejects the 100 MB+ ISOs). Instead, the ISOs are
built and staged locally, and CI only **publishes a GitHub Release**.

## The release workflow

`release.yml` triggers on a push to `master` whose commit message contains
`[RELEASE]`. It:

1. **Derives the tag + flags** from the commit subject: the first `vX…` token
   becomes the tag (else `beta-<date>-<shortsha>`), and the release is marked
   **pre-release** unless the message contains `[RELEASE:stable]`.
2. **Fetches the images** listed in `release/isos.sha256` from the mirror
   (`https://repo.mmzsigmond.me/isos/<name>`) and **verifies** them against that
   committed manifest (`sha256sum -c`). A tampered or truncated image fails the
   build.
3. **Creates the release** with `gh release create`, attaching the verified
   ISOs and using `release/NOTES.md` as the body.

```sh
# cut a release
make release-stage                       # build ISOs, upload to the mirror,
                                         # write release/isos.sha256 + NOTES.md
git commit -am "[RELEASE] v0.3.0-beta — <summary>"
git push origin master                   # → the workflow publishes the release
```

Use `[RELEASE:stable]` in the subject to publish a non-prerelease.

## Why images live on the mirror, not in git

GitHub rejects files over 100 MB in a git push, and ISOs are far larger. So the
build artifacts are uploaded to the mirror by `make release-stage`, and only a
small **checksum manifest** (`release/isos.sha256`) and **notes**
(`release/NOTES.md`) are committed. CI re-downloads and re-verifies the images
before attaching them, so the published release still matches the committed
hashes.

## Local checks (run by hand or on the build box)

There is no GitHub job for these; run them yourself before a release:

```sh
make _check_tools                 # verify the build toolchain is present
python3 tools/pkg/check-closure.py    # every recipe's depends resolve (closed graph)
make world && make test           # build the base + headless boot self-test
make test-install                 # unattended install to a disk image, assert boot
make repo-build                   # build every packages/*/bpm.toml
```

## The boot self-test

The checks live in `src/initramfs/selftest` and run inside the guest as part of
`/init` when the kernel is booted with `bbtest` on its command line. They verify
the live CLI is functional: busybox/`sh` work, core applets work, `/proc`/`/sys`/
`/dev` are mounted and populated, PID 1 is visible, `/tmp` is writable, the
hostname was applied. `make test` boots this headless and asserts
`BLUEBERRY_TEST=PASS`.

To add a check, edit `src/initramfs/selftest`, rebuild the initramfs (automatic
on `make test`), and confirm the new `PASS:` line appears.
