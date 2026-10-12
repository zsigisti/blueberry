#!/usr/bin/env python3
"""check-closure.py - make sure every recipe dependency actually exists.

Each depends (and with --make, makedepends) in packages/*/bpm.toml has to be
another recipe, something a recipe provides, or listed in etc/bpm/provided.
Catches the "declared a dep nobody ever packaged" bug in CI instead of on the ISO.

  tools/pkg/check-closure.py [--make]

Exits 1 if anything is missing.
"""
import glob
import os
import sys
import tomllib

TOP = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PKGDIR = os.path.join(TOP, "packages")
PROVIDED_FILE = os.path.join(TOP, "etc", "bpm", "provided")

# glibc is a real recipe now, but older `depends = ["glibc"]` atoms still need
# to resolve. gcc-libs (libstdc++/libgcc_s) still comes from the toolchain.
IMPLICIT = {"glibc", "gcc-libs"}


def load_provided() -> set[str]:
    provided = set(IMPLICIT)
    if os.path.isfile(PROVIDED_FILE):
        for line in open(PROVIDED_FILE):
            line = line.strip()
            if line and not line.startswith("#"):
                provided.add(line.split()[0])
    return provided


def bare(atom):
    # "foo>=1.2" -> "foo"
    return atom.split(">")[0].split("=")[0].split("<")[0].strip()


def load_recipes() -> dict[str, dict]:
    recipes = {}
    for toml in glob.glob(os.path.join(PKGDIR, "*", "bpm.toml")):
        with open(toml, "rb") as f:
            pkg = tomllib.load(f).get("package", {})
        name = pkg.get("name") or os.path.basename(os.path.dirname(toml))
        recipes[name] = {k: [bare(d) for d in pkg.get(k, [])]
                         for k in ("depends", "makedepends", "provides")}
    return recipes


def main() -> int:
    check_make = "--make" in sys.argv
    provided = load_provided()
    recipes = load_recipes()
    # deps can name what a recipe provides (cargo -> rust, libssl.so -> openssl)
    recipe_provides = {p for r in recipes.values() for p in r["provides"]}
    available = set(recipes) | provided | recipe_provides

    missing: dict[str, list[str]] = {}
    for name, r in recipes.items():
        deps = r["depends"] + (r["makedepends"] if check_make else [])
        for d in deps:
            if d and d not in available:
                missing.setdefault(d, []).append(name)

    print(f"recipes: {len(recipes)}   provided: {len(provided)}   "
          f"checking: depends{'+makedepends' if check_make else ''}")
    if not missing:
        print("ok: closure is complete, every dependency has a recipe or is provided")
        return 0

    users_total = len({p for ps in missing.values() for p in ps})
    print(f"\n{len(missing)} unresolved dependencies (needed by {users_total} packages):\n")
    for dep, users in sorted(missing.items(), key=lambda x: -len(x[1])):
        shown = ", ".join(sorted(users)[:6]) + ("..." if len(users) > 6 else "")
        print(f"  {len(users):3}  {dep:24}  <- {shown}")
    print("\nPackage each missing dependency (a recipe in packages/<name>/), or add "
          "it to etc/bpm/provided if the base image supplies it.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
