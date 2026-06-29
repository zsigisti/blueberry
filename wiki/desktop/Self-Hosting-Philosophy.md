# Self-Hosting Philosophy

Blueberry's defining constraint: **it depends on no third-party binary mirror at
runtime.** No Arch mirror, no Debian pool, no Flathub requirement. Everything a
running Blueberry system installs comes from **our own mirror**, built from
recipes in this repository.

## What that means in practice

- **Every package is a recipe.** [`packages/<name>/bpm.toml`](../packages)
  describes how to fetch upstream source and build it. The toolchain, Mesa,
  LLVM, all of Qt 6, all of KDE Plasma 6, the GTK stack — each was compiled from
  source into the repo.
- **One signed mirror.** Artifacts are published to
  `https://repo.mmzsigmond.me/`, indexed by `tools/bpmrepo.sh`, and the index is
  **ed25519-signed**. `bpm` trusts that key and nothing else.
- **Build, don't borrow.** When a new library is needed, the answer is "write a
  recipe and build it," not "pull a binary from someone else's repo."

## The build-time exception (and why it's fine)

Packages are *built* in an ephemeral Arch container, and `bpmbuild` pulls
*build* dependencies from Arch during that build. This is a **bootstrap detail**,
not a runtime dependency:

- The container is thrown away after each build.
- The resulting package's **runtime** dependencies are Blueberry package names,
  resolved from *our* mirror at install time.
- The shipped system never talks to Arch.

Think of it like using one compiler to build another: the host toolchain
bootstraps the build, but the product stands alone.

## The closed-source exception

Steam, Spotify, and Brave cannot be built from source — there is no source.
Every distribution ships these by **repackaging the vendor's official binary**,
and so does Blueberry:

- The recipe downloads the **vendor's own** Linux build (Mozilla, Valve,
  Spotify, Brave) and packages it, bundling the libraries it needs.
- It is then hosted on **our** mirror like everything else — so the system still
  depends only on Blueberry, just with a binary payload we didn't compile.

This is the only honest option for non-free software, and it keeps the
self-hosting guarantee intact: install-time, your machine only ever contacts the
Blueberry mirror.

## Why bother?

- **Trust.** You can audit the entire supply chain — it's one git repo plus one
  signed mirror you control.
- **Independence.** No upstream mirror going offline, changing layout, or
  shipping something unexpected can break a Blueberry system.
- **Reproducibility.** Fixed `SOURCE_DATE_EPOCH` + pinned source checksums mean
  a recipe yields the same bytes every time.
- **It's yours.** Fork the repo, point `bpm` at your own mirror, and you have a
  complete, independent distribution.

## See also

- [Creating Packages](Creating-Packages) — write a recipe.
- [Hosting a Mirror](Hosting-a-Mirror) — run your own signed repo.
- [Package Management](Package-Management) — how `bpm` verifies installs.
