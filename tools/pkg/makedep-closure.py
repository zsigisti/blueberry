#!/usr/bin/env python3
"""makedep-closure.py — the build-time dependency closure of a package.

To build packages/<X> we must have present, in the build container: X's
makedepends and depends, plus the transitive *runtime* depends of all of those
(a makedep's shared libraries, and their libraries, must exist for the tools to
run and for X to link). We do NOT need a makedep's *own* makedepends — those were
only needed to build the makedep itself, which is already done.

So: seed = makedepends(X) ∪ depends(X); then follow `depends` edges transitively.
Host-`provided` names (etc/bpm/provided) and the implicit glibc/gcc-libs are the
leaves — they come from the base image, never extracted. X itself is excluded.

Output: one package name per line, dependencies before dependents (topological),
so a consumer can extract/install them in a safe order. With --check, instead
verify every closure member has a built .bpm under the given out-dir (or is
provided) and exit non-zero listing any that are missing.

Usage:
  makedep-closure.py <pkg> [<pkg>...]                 # print the union closure
  makedep-closure.py --check <out-dir> <pkg> [<pkg>...]
"""
import os
import sys
import glob
import tomllib

TOP = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PKGDIR = os.path.join(TOP, "packages")
PROVIDED_FILE = os.path.join(TOP, "etc", "bpm", "provided")

# Same implicit set as check-closure.py: shipped by the base image / toolchain.
IMPLICIT = {"glibc", "gcc-libs"}


def _atom(dep: str) -> str:
    """Strip a version constraint (foo>=1.2 -> foo)."""
    return dep.split(">")[0].split("=")[0].split("<")[0].strip()


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
            "depends": [_atom(d) for d in pkg.get("depends", [])],
            "makedepends": [_atom(d) for d in pkg.get("makedepends", [])],
            "provides": [_atom(d) for d in pkg.get("provides", [])],
        }
    return recipes


def build_provides(recipes: dict[str, dict]) -> dict[str, str]:
    """Map each provided name/soname to the recipe that provides it, so a dep on
    e.g. cargo (rust), clang (llvm) or libssl.so (openssl) resolves to a real
    package rather than looking missing."""
    prov: dict[str, str] = {}
    for name, r in recipes.items():
        for p in r["provides"]:
            prov.setdefault(p, name)
    return prov


def closure(pkgs, recipes, provided, prov) -> list[str]:
    """Topologically-ordered build-time closure (deps before dependents)."""
    order: list[str] = []
    visiting: set[str] = set()
    done: set[str] = set()

    def resolve(name: str) -> str:
        return name if name in recipes else prov.get(name, name)

    def visit_runtime(name: str):
        # A runtime dependency: emit its own depends first, then itself.
        name = resolve(name)
        if name in done or name in provided or name in visiting:
            return
        if name not in recipes:
            # Unknown + not provided: surface it as a leaf so --check can flag it.
            done.add(name)
            order.append(name)
            return
        visiting.add(name)
        for d in recipes[name]["depends"]:
            visit_runtime(d)
        visiting.discard(name)
        done.add(name)
        order.append(name)

    for x in pkgs:
        r = recipes.get(x, {"depends": [], "makedepends": [], "provides": []})
        for d in r["makedepends"] + r["depends"]:
            visit_runtime(d)
    # Never include the requested packages themselves.
    return [n for n in order if n not in set(pkgs)]


def main() -> int:
    args = sys.argv[1:]
    check = False
    outdir = None
    if args and args[0] == "--check":
        check = True
        if len(args) < 3:
            print("usage: makedep-closure.py --check <out-dir> <pkg>...", file=sys.stderr)
            return 2
        outdir = args[1]
        args = args[2:]
    if not args:
        print("usage: makedep-closure.py [--check <out-dir>] <pkg>...", file=sys.stderr)
        return 2

    provided = load_provided()
    recipes = load_recipes()
    prov = build_provides(recipes)
    members = closure(args, recipes, provided, prov)

    if not check:
        for m in members:
            print(m)
        return 0

    missing = []
    for m in members:
        if m in provided:
            continue
        if not glob.glob(os.path.join(outdir, f"{m}-[0-9]*.bpm")):
            missing.append(m)
    if missing:
        print(
            "makedep-closure: missing built .bpm for: " + " ".join(missing) +
            f"\n  (build them first: run `make repo-build`, or bbdev build {' '.join(missing)})",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
