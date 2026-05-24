# Contributing to Blueberry Linux

## 1. Ways to Contribute

- **Package recipes** — Write a `BBUILD` for software not yet in `pkgs/`
- **Core system improvements** — Fix bugs or add features in the build system, init scripts, or bpm
- **Documentation** — Improve or extend `doc/`
- **Bug reports** — Open an issue on GitHub

---

## 2. Development Setup

```sh
git clone https://github.com/mmzsigmond/blueberry.git
cd blueberry

# Check build prerequisites
make _check_tools

# Build bpm only (fast, for package work)
make bpm

# Full world build (slow, for system work)
make world
```

---

## 3. Adding a Package

### 3.1  File layout

```
pkgs/
  core/      ← base system (musl, busybox, runit, etc.)
  extra/     ← extended packages (editors, databases, web servers)
  community/ ← community-maintained packages
```

Choose the appropriate tier. Most contributions belong in `extra/` or
`community/`.

### 3.2  Create the recipe

```sh
mkdir pkgs/extra/mypackage
cat > pkgs/extra/mypackage/BBUILD << 'EOF'
name=mypackage
version=1.0.0
release=1
description="A brief description"
url="https://upstream.example.com/"
license="MIT"
arch=("x86_64" "aarch64")
depends=("musl")
makedepends=()
source=("https://upstream.example.com/mypackage-$version.tar.gz")
checksums=("sha256:FILL_IN_CHECKSUM")
packager="Your Name <your@email.com>"

build() {
    cd "$name-$version"
    ./configure --prefix=/usr
    make
}

package() {
    cd "$name-$version"
    make DESTDIR="$pkgdir" install
    rm -rf "$pkgdir/usr/share/doc"
}
EOF
```

### 3.3  Get the checksum

```sh
wget https://upstream.example.com/mypackage-1.0.0.tar.gz
sha256sum mypackage-1.0.0.tar.gz
```

Update `checksums` in BBUILD.

### 3.4  Test the build

```sh
make bpm   # ensure bpm is built

obj/bpm build pkgs/extra/mypackage/BBUILD
# If successful: mypackage-1.0.0-1-x86_64.bb
```

### 3.5  Test installation

```sh
mkdir -p /tmp/test-root
obj/bpm --root /tmp/test-root install --file mypackage-1.0.0-1-x86_64.bb
ls /tmp/test-root/usr/bin/
```

### 3.6  Submit

```sh
git checkout -b add-mypackage
git add pkgs/extra/mypackage/
git commit -m "feat(pkgs): add mypackage 1.0.0"
git push origin add-mypackage
# Open a Pull Request on GitHub
```

---

## 4. BBUILD Checklist

Before submitting a new package recipe, verify:

- [ ] `name` matches the directory name exactly
- [ ] All fields in the Required section are present
- [ ] `source` entries have corresponding `checksums` entries
- [ ] `depends` lists only **runtime** dependencies
- [ ] `makedepends` lists only **build-time** dependencies
- [ ] `build()` does not install anything
- [ ] `package()` only installs to `$pkgdir`
- [ ] Static libraries (`.a`) are removed unless `staticlibs` option is set
- [ ] Documentation (`/usr/share/doc`, man pages) is retained unless space is critical
- [ ] The package builds cleanly with `bpm build`
- [ ] Installation into a test root succeeds
- [ ] The installed binary runs correctly in the test root

---

## 5. Commit Message Format

```
<type>(<scope>): <short description>

[optional body]
```

**Types:**
- `feat` — new feature or package
- `fix` — bug fix
- `refactor` — code restructuring without behavior change
- `docs` — documentation only
- `build` — build system changes
- `chore` — dependency updates, formatting

**Scopes:**
- `kernel` — src/kernel/
- `musl`, `busybox`, `runit`, `bpm` — respective src/ subdirs
- `pkgs` — any package recipe
- `init` — src/init/
- `doc` — documentation
- `infra` — tools/, CI, Docker

Examples:
```
feat(pkgs): add nginx 1.27.0
fix(bpm): handle empty depends array without panic
docs(BBUILD): document subpackage functions
build: update MUSL_VERSION to 1.2.5
```

---

## 6. Code Style (Go)

bpm is written in idiomatic Go. Follow the standard Go style:

- `gofmt` before committing (enforced by CI)
- Error strings are lowercase: `fmt.Errorf("file not found")` not `"File not found"`
- No magic numbers — use named constants
- Functions shorter than 50 lines where possible
- No global mutable state outside of `cmd/root.go`

Run before committing:
```sh
cd src/bpm
go fmt ./...
go vet ./...
```

---

## 7. Testing

Currently bpm has no automated tests. Adding them is the highest-priority
contribution. See `doc/BPM-INTERNALS.md` for the module layout.

Suggested test coverage:
- `internal/manifest`: round-trip encode/decode for TOML and BBINDEX formats
- `internal/solver`: BFS correctness, topological sort, cycle detection
- `internal/archive`: create then open a .bb and verify contents
- `internal/db`: record, get, list, remove operations

Run tests:
```sh
cd src/bpm
go test ./...
go test -race ./...
```

---

## 8. Pull Request Process

1. Fork the repository on GitHub.
2. Create a branch with a descriptive name: `add-nginx`, `fix-solver-cycle`, etc.
3. Make your changes following the commit format above.
4. Ensure `make bpm` and `bpm build <your-BBUILD>` succeed.
5. Open a Pull Request. Describe what you changed and why.
6. Address review feedback. GitHub Actions CI must pass.
7. A maintainer merges when CI passes and the change is approved.

---

## 9. Security Reporting

Do **not** open a public issue for security vulnerabilities. Email
`security@blueberry.mmzsigmond.me` with:
- Description of the vulnerability
- Steps to reproduce
- Affected components and versions
- Suggested fix (optional)

We aim to respond within 48 hours and to release a fix within 14 days of
confirmation.
