# Contributing

Blueberry is one repository, so contributing is straightforward: add a recipe,
fix a build, improve a doc, send a PR.

## Ways to contribute

- **Package recipes** — the most useful contribution. Add or update a
  `packages/<name>/bpm.toml`. See [Creating Packages](Creating-Packages).
- **Build fixes** — keep recipes building against the current toolchain
  (the container ships GCC 16; expect strictness fixes).
- **The OS** — kernel config, init, `bpm` (Rust), the installer (C).
- **Documentation** — this wiki, `doc/`, and the READMEs.
- **The Desktop edition** — Plasma/GNOME packaging, the Blueberry installer branding, the live
  overlay.

## Workflow

1. Fork and branch.
2. Make the change. For a package, build it:
   ```sh
   ENGINE=podman tools/build-bpm-pkg.sh ./out <pkg>
   bpm install ./out/<pkg>-*.bpm    # smoke-test
   ```
3. Use conventional commits: `feat(desktop): …`, `fix(apps): …`, `docs: …`.
4. Open a PR describing what and why; include the build/test you ran.

## Recipe checklist

- [ ] `depends` are **Blueberry** package names (runtime closure).
- [ ] `makedepends` cover build-only tools (pulled from Arch in the container).
- [ ] `sha256sums` pinned (or `SKIP` only for always-latest vendor binaries).
- [ ] Installs under `/usr` into `$pkgdir`.
- [ ] Builds clean with `tools/build-bpm-pkg.sh`.
- [ ] Version matches any sibling packages that must agree (e.g. all KDE
      Frameworks share one version).

## Submitting recipes without a PR

Open a pull request with your recipe (`packages/<name>/`). Recipes are reviewed
and built into the mirror.

## Code of conduct & licensing

Contributions are under the repo's MIT license (bundled upstreams keep their own
licenses). Be respectful; review is about the code, not the coder.

See [doc/CONTRIBUTING.md](../../doc/CONTRIBUTING.md) for the full version.
