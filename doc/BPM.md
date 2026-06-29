# bpm — Blueberry Package Manager

`bpm` installs native `.bpm` packages — the output of the `bpm.toml` recipes in
[`packages/`](../packages/). It is a small Rust program
([`src/bpm-rs/`](../src/bpm-rs/)) that streams package extraction straight to
disk; the release binary links only glibc + libgcc_s (libzstd is bundled
statically), so it runs natively on the live system with no extra runtime.

## Commands

```sh
bpm install <name|file.bpm>...           install (resolve deps from repos)
bpm remove  <name>...                    remove installed package(s)
bpm update                               sync repo indices
bpm upgrade                              upgrade all installed packages
bpm search  <term>                       search the repo index
bpm list                                 list installed packages
bpm info    <name>                       show package metadata
bpm files   <name>                       list files a package owns
bpm owns    <path>                       which package owns a path
```

`BPM_ROOT=<dir>` installs into a staging root instead of `/` (used for image
assembly and tests).

## How it works

- **Database:** `/var/lib/bpm/db/<name>/{desc,files}` — `desc` is the package's
  `.PKGINFO`; `files` is the owned-file list (used by `remove` and `owns`).
- **Index:** `/var/lib/bpm/index`, fetched by `bpm update`. Each line is
  `name|version|filename|sha256|deps|repo`.
- **Cache:** `/var/lib/bpm/cache/`.
- **Integrity:** every download is checked against the sha256 from the index.
- **Dependencies:** `install <name>` resolves `depend` entries recursively;
  names not in any repo are assumed provided by the base system (glibc, bash…).
- **Scriptlets:** a package's `.INSTALL` may define `pre/post_install` and
  `pre/post_upgrade` shell hooks; bpm sources them in the install root.

## systemd services

A package that should run as a service ships an empty marker per unit:

    usr/lib/bpm/enable/<unit>            # e.g. usr/lib/bpm/enable/sshd.service

On install bpm reads its own `[Install]` section (`WantedBy=`/`RequiredBy=`) and
writes the enable symlinks under the install root — the same thing
`systemctl enable` does, but **offline**, so it works inside a chroot or a disk
image and takes effect on next boot. When installing into the live root (`BPM_ROOT`
unset) and `systemctl` is present, bpm also runs `daemon-reload` and starts the
unit immediately. Native `.bpm` recipes declare this once:

    [package]
    enable = ["sshd.service"]           # bpmbuild drops the marker for you

## Repositories and mirrors

`/etc/bpm/repos.conf` — one line per repo, origin first then mirrors:

```
core https://repo.mmzsigmond.me http://mirror1.lan http://mirror2.lan
```

`bpm update` and downloads try each URL in turn and fail over when one is
unreachable. Integrity is the per-package SHA-256 recorded in `bpm.index`
(verified on every download), with the index fetched over TLS — there is no
index signing.

Build a repo from a directory of `.bpm` files with `tools/mkrepo.sh`:

```sh
tools/mkrepo.sh /path/to/repo      # writes /path/to/repo/bpm.index
```

### Building + publishing a repo

`make repo-build` builds every `packages/<name>/bpm.toml` into `obj/bpm-out`,
driving `tools/build-bpm-pkg.sh` (which runs `bpmbuild` in an ephemeral Arch
container). It is **idempotent**: a package whose `.bpm` is newer than its
`bpm.toml` is skipped, so adding one recipe rebuilds one package.

```sh
# build the whole package set as .bpm
make repo-build

# build a subset directly
ENGINE=podman tools/build-bpm-pkg.sh obj/bpm-out nano vim

# index + ed25519-sign a repo directory
tools/mkrepo.sh /srv/blueberry-repo
```

To publish, `scp` the `.bpm` files to the mirror host and re-index there
(`mkrepo.sh` regenerates `bpm.index` + its signature). The webroot is a pure
publish target — nothing served decides what to rebuild, so a wiped or
hand-edited webroot can't trigger a rebuild and a half-built artifact is never
served. Builds run parallel across all cores (`-j$(nproc)`).

## Example

```sh
bpm update
bpm install wireguard-tools     # pulls deps, verifies checksums, installs
bpm list
bpm owns /usr/bin/wg
bpm remove wireguard-tools
```
