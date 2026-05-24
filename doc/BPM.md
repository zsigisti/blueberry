# bpm — Blueberry Package Manager User Guide

## 1. Overview

`bpm` manages binary `.bb` packages on a Blueberry Linux system. It
installs, removes, and upgrades packages, resolves dependencies, builds
packages from source recipes (BBUILD), and manages repository configuration.

```
bpm [global flags] <command> [flags] [args]
```

Global flags:
- `-r <path>`, `--root <path>` — install root (default: `/`)
- `-v`, `--verbose` — verbose output

---

## 2. Commands

### `bpm install <package>...`

Install one or more packages and their dependencies.

```sh
bpm install openssh
bpm install git curl wget
bpm install -y openssh          # skip confirmation
bpm install -f myapp-1.0-1-x86_64.bb  # install from .bb file
```

**Flags:**
- `-y`, `--yes` — skip the confirmation prompt
- `-f`, `--file` — treat arguments as local `.bb` file paths

**What it does:**
1. Queries all configured repos for each requested package.
2. Resolves the full dependency closure (BFS + topological sort).
3. Prints the install plan and asks for confirmation (unless `-y`).
4. Downloads `.bb` files into `/var/lib/bpm/cache/packages/`.
5. Verifies SHA-256 checksums.
6. For each package (dependencies first): runs `pre-install` script,
   extracts files, records install in `/var/lib/bpm/db/installed/<name>/`,
   runs `post-install` script.
7. Adds explicitly requested packages to `/var/lib/bpm/db/world`.

**Exit codes:**
- `0` — success
- `1` — unresolved dependency, checksum failure, or other error

---

### `bpm remove <package>...`

Remove installed packages.

```sh
bpm remove openssh
bpm remove -y git curl
```

**Flags:**
- `-y`, `--yes` — skip confirmation

**What it does:**
1. Checks reverse dependencies — refuses to remove packages required by others.
2. Runs `pre-remove` script for each package.
3. Removes all files listed in `/var/lib/bpm/db/installed/<name>/FILES`.
4. Removes the database entry.
5. Runs `post-remove` script.
6. Removes the package from `/var/lib/bpm/db/world`.

**Note:** Empty directories left behind are silently removed. Non-empty
directories (containing user data) are left in place.

---

### `bpm update`

Synchronise the package indices from all enabled repositories.

```sh
bpm update
```

Downloads `BBINDEX.zst` from each repository's URL and caches it in
`/var/lib/bpm/cache/indices/<reponame>.zst`.

Run this before `install` or `upgrade` to see current package versions.

---

### `bpm upgrade [package]...`

Upgrade packages to the latest available version.

```sh
bpm upgrade             # upgrade all installed packages
bpm upgrade openssh     # upgrade only openssh
bpm upgrade -y          # skip confirmation
```

**Flags:**
- `-y`, `--yes` — skip confirmation

**What it does:**
1. Compares installed versions against the repository index.
2. Prints a list of available upgrades.
3. For each upgrade: removes the old version, installs the new.

---

### `bpm search <query>`

Search package names and descriptions for a substring.

```sh
bpm search ssh
bpm search "web server"
```

Output format:
```
openssh                        9.8p1-1         OpenSSH: free SSH protocol implementation
libssh2                        1.11.0-1        SSH library
```

---

### `bpm info <package>`

Display detailed information about a package.

```sh
bpm info openssh
```

Shows all manifest fields for both the installed version (if any) and the
repository version.

---

### `bpm list`

List packages.

```sh
bpm list                    # list installed packages
bpm list -u                 # list upgradable packages
bpm list -a                 # list all available packages
```

**Flags:**
- `-i`, `--installed` — list installed packages (default)
- `-u`, `--upgradable` — list packages with available upgrades
- `-a`, `--available` — list all packages in all repos

Output columns: `name`, `version`, `description`.
Explicitly-installed packages are marked with `[explicit]`.

---

### `bpm verify [package]...`

Verify the integrity of installed packages by comparing installed files
against the checksums recorded in the `.CHECKSUMS` file.

```sh
bpm verify                  # verify all installed packages
bpm verify openssh musl
```

Output:
```
OK   musl
OK   busybox
FAIL openssh
       modified: usr/sbin/sshd
       missing:  usr/lib/ssh/sftp-server
```

Exit code `1` if any package fails verification.

---

### `bpm clean`

Remove cached package archives.

```sh
bpm clean           # remove cached .bb files
bpm clean -a        # also remove cached indices
```

**Flags:**
- `-a`, `--all` — also clear repository indices (forces re-fetch on next update)

---

### `bpm build <BBUILD>`

Build a `.bb` package from a BBUILD recipe.

```sh
bpm build pkgs/core/openssh/BBUILD
bpm build -o /tmp/pkgs pkgs/core/openssh/BBUILD
bpm build -j16 pkgs/core/openssh/BBUILD
```

**Flags:**
- `-o <dir>`, `--output <dir>` — output directory (default: current dir)
- `--workdir <dir>` — build workspace (default: system temp dir)
- `-j <n>`, `--jobs <n>` — parallel make jobs (default: nproc)
- `--arch <arch>` — target architecture

The produced `.bb` file is named `<name>-<version>-<release>-<arch>.bb`.

---

### `bpm repo list`

List configured repositories.

```sh
bpm repo list
```

Output:
```
core                enabled    https://bb.mmzsigmond.me/packages/x86_64
extra               enabled    https://bb.mmzsigmond.me/extra/x86_64
local               disabled   file:///var/lib/bpm/local-repo
```

---

### `bpm repo add <name> <url>`

Add a repository.

```sh
bpm repo add extra https://bb.mmzsigmond.me/extra/x86_64
bpm repo add local file:///var/lib/bpm/local-repo
```

Creates `/etc/bpm/repos.d/<name>.conf`. Run `bpm update` afterwards.

---

### `bpm repo remove <name>`

Remove a repository configuration.

```sh
bpm repo remove local
```

---

### `bpm repo enable <name>` / `bpm repo disable <name>`

Enable or disable a repository without removing its configuration.

```sh
bpm repo disable extra
bpm repo enable extra
```

---

## 3. Configuration

### `/etc/bpm/bpm.conf`

```toml
# Blueberry Package Manager configuration
# Uncomment and set to override defaults.

# root       = "/"
# cache_dir  = "/var/lib/bpm/cache"
# repos_dir  = "/etc/bpm/repos.d"
# db_path    = "/var/lib/bpm/db"
# arch       = "x86_64"
```

### `/etc/bpm/repos.d/<name>.conf`

```toml
name    = "core"
url     = "https://bb.mmzsigmond.me/packages/x86_64"
enabled = true
```

### File locations

| Path | Description |
|------|-------------|
| `/etc/bpm/bpm.conf` | Main configuration |
| `/etc/bpm/repos.d/` | Repository configs |
| `/etc/bpm/trusted-keys/` | Package signing public keys |
| `/var/lib/bpm/db/installed/` | Installed package database |
| `/var/lib/bpm/db/world` | Explicitly installed packages |
| `/var/lib/bpm/cache/packages/` | Downloaded .bb files |
| `/var/lib/bpm/cache/indices/` | Cached BBINDEX files |

---

## 4. Installing from a File

To install a `.bb` file directly (bypasses repo lookup):

```sh
bpm install --file mypackage-1.0-1-x86_64.bb
```

bpm still runs pre/post scripts and records the package in the database.
Package signing is bypassed unless `--verify` is explicitly passed.

---

## 5. Installing into a Different Root

Use `--root` to install into a directory other than `/`:

```sh
bpm --root /mnt/new-system install musl busybox runit bpm
```

This is how `tools/bootstrap.sh` populates a new system image.

---

## 6. Pinning Packages

To prevent a package from being upgraded, add it to `/etc/bpm/hold`:

```sh
echo openssh >> /etc/bpm/hold
```

`bpm upgrade` skips held packages. `bpm install` still installs them.

---

## 7. Troubleshooting

### `package not found in any repository`

```sh
bpm update    # refresh indices
bpm search <name>   # check spelling and repo coverage
```

### `checksum mismatch`

The cached `.bb` file is corrupt or tampered. Remove it and retry:

```sh
bpm clean
bpm install <package>
```

### `cannot remove X: required by Y`

Package Y depends on X. Either remove Y first, or use:

```sh
bpm remove X Y    # remove both at once
```

### `disk full during install`

If `bpm install` fails mid-way, the database may be inconsistent. Re-run
the install; bpm overwrites already-extracted files idempotently.

### Check what package owns a file

```sh
bpm verify --owner /usr/bin/ssh
```

(Scans the installed database for ownership; slow for large installs.)
