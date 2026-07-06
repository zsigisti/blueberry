#!/usr/bin/env python3
"""check-closure.py — assert the .bpm recipe tree is dependency-closed.

Every `depends` (and optionally `makedepends`) listed in a packages/<name>/bpm.toml
must resolve to either another recipe in packages/ or a host-provided name
(etc/bpm/provided + the implicit glibc/gcc-libs). This catches the recurring
"declares a dep that was never packaged" bug (exiv2, appstream, polkit-qt6,
kirigami-addons, the applets…) at CI time instead of at runtime on the ISO.

Usage:
  tools/pkg/check-closure.py [--make]   # --make also checks makedepends
Exit status: 0 if closed, 1 if any dependency is missing.
"""
import os, sys, glob, tomllib

TOP = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PKGDIR = os.path.join(TOP, "packages")
PROVIDED_FILE = os.path.join(TOP, "etc", "bpm", "provided")

# Implicitly provided by the base image. glibc is now a real recipe
# (packages/glibc, staged into the rootfs and bundled from there); it stays
# listed so older `depends = ["glibc"]` atoms still resolve. gcc-libs
# (libstdc++/libgcc_s) is still host/toolchain-provided via bundle-glibc.
IMPLICIT = {"glibc", "gcc-libs"}


def load_provided() -> set[str]:
    provided = set(IMPLICIT)
    if os.path.isfile(PROVIDED_FILE):
        for line in open(PROVIDED_FILE):
            line = line.strip()
            if line and not line.startswith("#"):
                provided.add(line.split()[0])
    return provided


def load_recipes() -> dict[str, dict]:
    recipes = {}
    for toml in glob.glob(os.path.join(PKGDIR, "*", "bpm.toml")):
        with open(toml, "rb") as f:
            data = tomllib.load(f)
        pkg = data.get("package", {})
        name = pkg.get("name") or os.path.basename(os.path.dirname(toml))
        recipes[name] = {
            "depends": [d.split(">")[0].split("=")[0].split("<")[0].strip()
                        for d in pkg.get("depends", [])],
            "makedepends": [d.split(">")[0].split("=")[0].split("<")[0].strip()
                            for d in pkg.get("makedepends", [])],
        }
    return recipes


def main() -> int:
    check_make = "--make" in sys.argv
    provided = load_provided()
    recipes = load_recipes()
    available = set(recipes) | provided

    missing: dict[str, list[str]] = {}
    for name, r in recipes.items():
        deps = r["depends"] + (r["makedepends"] if check_make else [])
        for d in deps:
            if d and d not in available:
                missing.setdefault(d, []).append(name)

    print(f"recipes: {len(recipes)}   provided: {len(provided)}   "
          f"checking: depends{'+makedepends' if check_make else ''}")
    if not missing:
        print("✓ closure is complete — every dependency has a recipe or is provided")
        return 0

    print(f"\n✗ {len(missing)} unresolved dependencies "
          f"(needed by {len({p for ps in missing.values() for p in ps})} packages):\n")
    for dep, users in sorted(missing.items(), key=lambda x: -len(x[1])):
        shown = ", ".join(sorted(users)[:6]) + ("…" if len(users) > 6 else "")
        print(f"  {len(users):3}  {dep:24}  ← {shown}")
    print("\nPackage each missing dependency (a recipe in packages/<name>/), or add "
          "it to etc/bpm/provided if the base image supplies it.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
