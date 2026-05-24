# Package Format Specification

## 1. The `.bb` Archive Format

A `.bb` file is a **zstd-compressed tar archive** (RFC 8878 for zstd, POSIX.1-2001
pax for tar). The file name follows the convention:

```
<name>-<version>-<release>-<arch>.bb
  e.g.  musl-1.2.5-1-x86_64.bb
        openssh-9.8p1-1-aarch64.bb
```

### 1.1  Archive layout

Inside the tar stream, files appear in this order (enforced by `archive.Create`):

```
regular files and directories    ← installed file tree, paths relative to /
.CHECKSUMS                       ← sha256 per installed file
.SCRIPTS/pre-install             ← optional lifecycle hooks
.SCRIPTS/post-install
.SCRIPTS/pre-remove
.SCRIPTS/post-remove
.MANIFEST                        ← package metadata (written last, size known)
```

Paths of installed files do **not** have a leading `/`. Example:
```
usr/bin/ssh
usr/lib/libcrypto.so.3
etc/ssh/sshd_config
```

`.MANIFEST`, `.CHECKSUMS`, and `.SCRIPTS/` are identified by their leading `.`
and are never installed to the filesystem.

### 1.2  Detecting a `.bb` file

Read the first 4 bytes. A valid `.bb` must start with the zstd magic number:

```
0x28 0xB5 0x2F 0xFD
```

### 1.3  Compression parameters

Production packages use zstd level 19 (maximum). During development, level 3
is acceptable for faster builds:

```sh
bpm build --zstd-level 3 pkgs/core/foo/BBUILD
```

---

## 2. The `.MANIFEST` File

`.MANIFEST` is a UTF-8 plain-text file using a simplified TOML-like syntax:
`key = "value"` for strings, `key = [...]` for string arrays, `key = N` for
integers.

### 2.1  Field reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Package name. `[a-z0-9][a-z0-9+._-]*` |
| `version` | string | yes | Upstream version string |
| `release` | integer | yes | Blueberry release counter. Starts at 1. |
| `arch` | string | yes | Target architecture: `x86_64`, `aarch64`, `riscv64`, `noarch` |
| `description` | string | yes | One-line description (< 80 chars) |
| `url` | string | yes | Upstream home page URL |
| `license` | string | yes | SPDX license identifier(s) |
| `depends` | string[] | no | Runtime dependencies |
| `provides` | string[] | no | Virtual package names this package satisfies |
| `conflicts` | string[] | no | Package names that cannot be installed simultaneously |
| `replaces` | string[] | no | Package names superseded by this package |
| `size` | integer | no | Compressed package size in bytes |
| `installed_size` | integer | yes | Sum of installed file sizes in bytes |
| `build_date` | string | no | ISO 8601 UTC timestamp: `2026-01-01T12:00:00Z` |
| `packager` | string | no | `Name <email>` of the packager |
| `sha256` | string | no | SHA-256 hex digest of the `.bb` file itself |

### 2.2  Example `.MANIFEST`

```toml
name = "openssh"
version = "9.8p1"
release = 1
arch = "x86_64"
description = "OpenSSH: free SSH protocol implementation"
url = "https://www.openssh.com/"
license = "BSD"
depends = ["musl", "openssl", "zlib"]
provides = []
conflicts = []
replaces = []
size = 1234567
installed_size = 3456789
build_date = "2026-05-01T10:00:00Z"
packager = "Blueberry Maintainers <maintainers@blueberry.mmzsigmond.me>"
sha256 = "a1b2c3d4..."
```

### 2.3  `depends` version constraints

Dependency strings may include version constraints:

```
musl>=1.2.0          at least version 1.2.0
openssl=3.3.1        exactly this version
zlib                 any version (preferred form when version doesn't matter)
```

Operators: `=`, `>=`, `<=`, `>`, `<`, `!=`

The dependency solver (`internal/solver`) strips the constraint for lookup
purposes and records the full string for display.

---

## 3. The `.CHECKSUMS` File

One line per regular file in the package:

```
sha256:<hex>  <path>
```

The path is identical to the tar header name (no leading `/`). Example:

```
sha256:a1b2c3...  usr/bin/ssh
sha256:d4e5f6...  usr/bin/scp
sha256:789abc...  etc/ssh/sshd_config
```

Used by `bpm verify` to detect post-install file modifications. Symlinks and
directories are not checksummed.

---

## 4. Lifecycle Scripts

Scripts in `.SCRIPTS/` are optional. If present they are extracted to a
temporary file, `chmod 700`, and executed with `sh -e`. A non-zero exit
aborts the corresponding operation.

| Script | When executed | Common use |
|--------|---------------|------------|
| `pre-install` | Before files are extracted | Stop a running service |
| `post-install` | After files are extracted | Run ldconfig, add user/group |
| `pre-remove` | Before files are deleted | Stop a running service |
| `post-remove` | After files are deleted | Remove created users/groups |

Scripts receive the following environment variables:

```sh
BPM_NAME=openssh
BPM_VERSION=9.8p1
BPM_RELEASE=1
BPM_ROOT=/          # install root (may differ with --root)
```

Scripts must be idempotent — they may be called more than once (e.g., during
an interrupted upgrade that retries).

---

## 5. The BBINDEX Repository Index

`BBINDEX.zst` is a zstd-compressed plain-text file. It contains one record
per package, separated by blank lines. Each record is a sequence of
`key: value` lines.

### 5.1  BBINDEX field reference

| Field | Description |
|-------|-------------|
| `name` | Package name |
| `version` | Upstream version |
| `release` | Blueberry release counter |
| `arch` | Architecture |
| `description` | One-line description |
| `url` | Upstream URL |
| `license` | SPDX license |
| `depends` | Space-separated dependency list |
| `provides` | Space-separated virtual names |
| `conflicts` | Space-separated conflicts |
| `replaces` | Space-separated replaced packages |
| `size` | Compressed package size in bytes |
| `installed_size` | Installed footprint in bytes |
| `build_date` | ISO 8601 UTC build timestamp |
| `packager` | Packager name and email |
| `sha256` | SHA-256 of the `.bb` file |
| `filename` | Bare filename of the `.bb` file, e.g. `foo-1.0-1-x86_64.bb` |

### 5.2  Example BBINDEX record

```
name: musl
version: 1.2.5
release: 1
arch: x86_64
description: the musl c library
url: https://musl.libc.org/
license: MIT
size: 443266
installed_size: 1454080
build_date: 2026-05-01T10:00:00Z
packager: Blueberry Maintainers <maintainers@blueberry.mmzsigmond.me>
sha256: a1b2c3d4e5f6...
filename: musl-1.2.5-1-x86_64.bb

name: busybox
version: 1.36.1
...

```

The file ends with a trailing blank line.

### 5.3  Generating BBINDEX

```sh
tools/mkrepo.sh /path/to/packages/
# writes /path/to/packages/BBINDEX.zst
```

Or via the build system:
```sh
make repo
# writes obj/repo/BBINDEX.zst
```

---

## 6. The Installed Package Database

`/var/lib/bpm/db/installed/<name>/` contains:

| File | Description |
|------|-------------|
| `MANIFEST` | Copy of the package's `.MANIFEST` (same format) |
| `FILES` | Newline-separated list of installed paths (no leading `/`) |

### 6.1  `FILES` format

```
usr/bin/ssh
usr/bin/scp
usr/bin/sftp
usr/sbin/sshd
usr/lib/ssh/sftp-server
etc/ssh/sshd_config
var/empty
```

bpm uses this list to remove files on `bpm remove` and to check file
ownership with `bpm verify`.

### 6.2  The `world` file

`/var/lib/bpm/db/world` is a newline-separated list of **explicitly
installed** package names (those the user asked for, not pulled in as
dependencies). It is used by `bpm remove` to determine whether removing a
package leaves orphaned dependencies.

---

## 7. Version Comparison

Version strings are compared segment by segment, splitting on `.`, `-`, and
`~`. Each segment is compared numerically if both sides are digits, or
lexicographically otherwise.

`~` before any segment makes that segment sort before everything, including
the empty string. This is used for pre-release versions:

```
1.0~beta1 < 1.0 < 1.0-1 < 1.0.1
```

The `release` integer is compared after the version string as a tie-breaker.

---

## 8. Architecture Values

| Value | CPU |
|-------|-----|
| `x86_64` | Intel/AMD 64-bit |
| `aarch64` | ARM 64-bit (ARMv8+) |
| `riscv64` | RISC-V 64-bit |
| `noarch` | Architecture-independent (scripts, docs, data) |

---

## 9. Package Signing

Packages are signed with [minisign](https://jedisct1.github.io/minisign/)
when `REPO_SIGN=1` is set in the build environment. The signature is stored
as a separate file alongside each `.bb`:

```
musl-1.2.5-1-x86_64.bb
musl-1.2.5-1-x86_64.bb.minisig
```

The repository's public key is stored in `/etc/bpm/trusted-keys/`.

Verification happens automatically during `bpm install` when a `.minisig`
file is present. To disable: `bpm install --no-verify`.

See `doc/HOSTING.md` for key generation and signing workflow.
