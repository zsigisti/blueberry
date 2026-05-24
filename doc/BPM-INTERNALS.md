# bpm Internals

This document describes the internal architecture of the `bpm` binary for
contributors and developers who need to understand or modify it.

## 1. Module Overview

```
src/bpm/
  main.go                    entry point: calls cmd.Execute()
  cmd/
    root.go                  cobra root command, global flags, initConfig
    install.go               bpm install
    remove.go                bpm remove
    update.go                bpm update
    upgrade.go               bpm upgrade
    search.go                bpm search
    info.go                  bpm info
    list.go                  bpm list
    clean.go                 bpm clean
    verify.go                bpm verify
    build.go                 bpm build
    repo.go                  bpm repo {list,add,remove,enable,disable}
  internal/
    manifest/manifest.go     Package type + BBINDEX/TOML codec
    archive/archive.go       .bb archive read/write
    db/db.go                 installed-package database
    repo/repo.go             repository manager (config, fetch, search)
    solver/solver.go         dependency resolver
    build/build.go           BBUILD parser + builder
    config/config.go         bpm.conf loader
```

---

## 2. Data Flow: `bpm install foo`

```
cmd/install.go: runInstall()
  │
  ├─ db.New()              open /var/lib/bpm/db/
  ├─ repo.NewManager()     load /etc/bpm/repos.d/*.conf
  ├─ solver.New()          create resolver
  │
  ├─ solver.Resolve(["foo"])
  │     ├─ repo.Find("foo")   → searches BBINDEX cache
  │     ├─ recurse into foo's Depends
  │     └─ topo-sort         → ordered install list
  │
  ├─ Print plan, ask confirm
  │
  └─ for each pkg in plan:
        ├─ repo.Download(pkg)   → fetch .bb, verify sha256
        ├─ archive.Open(f)      → read .MANIFEST, .CHECKSUMS, scripts
        ├─ pkg.Script("pre-install") → run if present
        ├─ pkg.Extract(root)    → unpack files
        ├─ db.Record(pkg, files)  → write MANIFEST + FILES
        ├─ pkg.Script("post-install") → run if present
        └─ db.AddToWorld(name)  (for explicitly requested packages only)
```

---

## 3. `internal/manifest` — Package Type

`manifest.Package` is the central type. It is used for:

- The `.MANIFEST` file inside a `.bb` archive (written/read with `EncodeTOML`/`DecodeTOML`)
- The repository index (`BBINDEX.zst`) records (written/read with `Encode`/`DecodeIndex`)
- The installed database manifest files

The two codec formats are **different** but carry the same fields:

| File | Format | Separator |
|------|--------|-----------|
| `.MANIFEST` | TOML-like `key = "value"` | n/a (one file) |
| `BBINDEX` | `key: value` lines | blank line between records |

### `DepName(dep string) string`

Strips the version constraint from a dependency string:
```
"musl>=1.2.0" → "musl"
"openssl=3.3.1" → "openssl"
"zlib" → "zlib"
```

---

## 4. `internal/archive` — The `.bb` Format

### Reading

`archive.Open(r io.Reader) (*Package, error)`:
1. Reads all bytes from `r` into memory (needed for two-pass: metadata + extraction).
2. Opens a zstd decoder.
3. Iterates the tar stream:
   - `.MANIFEST` → parse with `manifest.DecodeTOML`
   - `.CHECKSUMS` → parse into `map[string]string` (path → hex sha256)
   - `.SCRIPTS/*` → store as `map[string][]byte`
   - Everything else → record header for extraction
4. Returns a `*Package` with all metadata loaded.

`Package.Extract(destDir string)`:
1. Reopens the zstd decoder from the buffered bytes.
2. Iterates tar stream again.
3. For each regular file: creates parent dirs, writes file with correct mode.
4. For symlinks: calls `os.Symlink`.
5. For hardlinks: calls `os.Link`.
6. Returns list of installed paths.

### Writing

`archive.Create(w io.Writer, meta *manifest.Package, files map[string]string, scripts map[string][]byte)`:
1. Opens a zstd encoder on `w` at `SpeedBestCompression`.
2. For each file in `files` (archivePath → srcPath):
   - Writes tar header + file content.
   - Computes SHA-256 as it writes.
   - Accumulates `meta.InstalledSize`.
3. Writes `.CHECKSUMS`.
4. Writes any scripts.
5. Writes `.MANIFEST` (last, so size is known).
6. Closes tar then zstd.

---

## 5. `internal/db` — Installed Package Database

```
/var/lib/bpm/db/
  installed/
    musl/
      MANIFEST      ← copy of package .MANIFEST
      FILES         ← newline list of installed paths
    busybox/
      MANIFEST
      FILES
    ...
  world             ← newline list of explicitly installed names
```

### Key operations

| Method | Description |
|--------|-------------|
| `IsInstalled(name)` | `stat` check on `installed/<name>/MANIFEST` |
| `Get(name)` | Open + parse `installed/<name>/MANIFEST` |
| `Files(name)` | Read + parse `installed/<name>/FILES` |
| `List()` | `os.ReadDir("installed/")` |
| `Record(pkg, files)` | Write MANIFEST + FILES |
| `Remove(name)` | `os.RemoveAll("installed/<name>")` |
| `World()` | Parse `world` file into `map[string]bool` |
| `AddToWorld(name)` | Append to world set |
| `RemoveFromWorld(name)` | Remove from world set |

No locking is implemented in v0.1. For concurrent invocations, use external
locking (e.g., `flock /var/lib/bpm/lock`).

---

## 6. `internal/repo` — Repository Manager

### Repository config format

```toml
name    = "core"
url     = "https://bb.mmzsigmond.me/packages/x86_64"
enabled = true
```

Parsed by `parseRepoConf()`. Missing or malformed conf files emit a warning
and are skipped.

### Index cache

`Manager.Update()` fetches `<url>/BBINDEX.zst` for each enabled repo and
writes it to `/var/lib/bpm/cache/indices/<name>.zst`.

`Manager.LoadIndex(r)` decompresses the cache and parses it with
`manifest.DecodeIndex`. The resulting `Index.Packages` map is indexed by
both `name` and every entry in `provides[]` (first match wins).

### Download flow

`Manager.Download(pkg, repo)`:
1. Checks if `cache/packages/<filename>` exists and matches SHA-256.
2. If not: fetches `<repo.URL>/<pkg.Filename>` with `http.Client`.
3. Writes to cache.
4. Verifies SHA-256.
5. Returns local cache path.

---

## 7. `internal/solver` — Dependency Resolver

Uses a simple BFS (breadth-first search):

```
Resolve(["foo", "bar"])
  queue = ["foo", "bar"]
  visited = {}

  loop:
    name = dequeue
    if visited[name]: continue
    visited[name] = true

    if installed at same version: skip (or add to Upgrade if newer available)
    
    pkg = repo.Find(name)
    plan.Install << pkg
    for dep in pkg.Depends:
      if !visited[dep]: enqueue(DepName(dep))

  plan.Install = topoSort(plan.Install)
```

### Topological sort

`topoSort(pkgs)` uses DFS with a visited set:
1. Build an index of package name → package for all packages in the plan.
2. For each package, recursively visit its dependencies that are in the plan.
3. Append a package to `sorted` after all its dependencies are appended.

This ensures that when installing, each package's dependencies are already
installed before it.

### Reverse-dependency check (for remove)

`ResolveRemove(names)` scans all installed packages. For each installed
package NOT in the removal set, it checks if any of its `Depends` entries
reference a package being removed. If so, it returns an error.

---

## 8. `internal/build` — BBUILD Builder

### Static parsing

`build.Parse(path)` reads the BBUILD file line by line and extracts header
variables. It stops at the first function definition (`() {` or `(){`).
Variables are parsed as simple `key=value` or `key=(array elements)`.

**Limitation:** Variables that reference other variables (e.g. `url="https://example.com/$name"`)
are not expanded during static parsing. The actual values are used when the
script is executed.

### Build execution

`build.Build(recipe, opts)`:
1. Creates a temporary work directory with `src/` and `pkg/` subdirs.
2. Downloads each source URL into `src/` using `wget`.
3. Verifies checksums with `archive.SHA256File`.
4. Generates a shell script that:
   - Sources the BBUILD file
   - Calls `build()`
   - Calls `package()`
5. Executes via `sh -e -` with a clean environment (see `buildEnv`).
6. Collects all files from `pkg/` into a `map[string]string`.
7. Calls `archive.Create` to produce the `.bb` file.

The build runs in the same mount namespace as bpm itself. For reproducible
builds in CI, use the Docker container described in `doc/HOSTING.md`.

---

## 9. `internal/config` — Configuration

`config.Default()`:
1. Initialises a `Config` with compiled-in defaults.
2. Calls `loadFile("/etc/bpm/bpm.conf")`.
3. Returns the merged config.

The architecture is detected from `/proc/sys/kernel/arch` if available,
otherwise falls back to the GOARCH-to-distro-arch mapping compiled in.

---

## 10. Adding a New Command

1. Create `src/bpm/cmd/<name>.go`.
2. Define a `cobra.Command` variable named `<name>Cmd`.
3. Add it to `rootCmd.AddCommand(...)` in `cmd/root.go`.

Example minimal command:

```go
package cmd

import (
    "fmt"
    "github.com/spf13/cobra"
)

var whoamiCmd = &cobra.Command{
    Use:   "whoami",
    Short: "Print the effective install root",
    Args:  cobra.NoArgs,
    RunE: func(cmd *cobra.Command, args []string) error {
        fmt.Println(cfg.Root)
        return nil
    },
}
```

---

## 11. Testing

```sh
cd src/bpm
go test ./...

# Run a specific package
go test ./internal/solver/ -v

# Run with race detector
go test -race ./...
```

There are currently no test files — adding them is a contribution
opportunity. See `doc/CONTRIBUTING.md`.
