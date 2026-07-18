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
try:
    import tomllib
except ModuleNotFoundError:  # Python <=3.10 (the repo server): same API via tomli
    import tomli as tomllib

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


def _kahn(names, deps) -> list[str]:
    """Emit names deps-before-dependents; residual (cyclic) nodes appended sorted."""
    order: list[str] = []
    done: set[str] = set()
    remaining = set(names)
    while remaining:
        ready = sorted(n for n in remaining if not (deps[n] & remaining))
        if not ready:
            break
        for n in ready:
            order.append(n); done.add(n); remaining.discard(n)
    order.extend(sorted(remaining))
    return order


def topo_order(recipes, provided, prov, subset=None) -> list[str]:
    """A global build order over all recipes: dependencies before dependents.

    Edges are makedepends ∪ depends (a build tool such as rust/go/cmake must be
    built before the packages that compile against it, not only the runtime libs
    a package links). That graph is deeply cyclic — the C/C++ toolchain (gcc, make,
    binutils, coreutils, their math libs, …) mutually build-depends and forms one
    big strongly-connected component. We therefore condense strongly-connected
    components (Tarjan) into super-nodes and topologically order the resulting DAG,
    so the toolchain SCC lands first (bootstrapped from the builder image's baked
    tools) and everything downstream — cmake → llvm → rust → the Rust programs —
    follows in the right order. Within a multi-node SCC, members are ordered by
    their runtime `depends` (best effort); the image supplies every tool the SCC
    needs internally, so the residual order inside it does not affect correctness.
    Self-edges are ignored; provided/implicit/unknown names are leaves.
    """
    names = set(recipes) if subset is None else {n for n in subset if n in recipes}

    def resolve(name: str) -> str:
        return name if name in recipes else prov.get(name, name)

    def edges(kinds):
        g: dict[str, set[str]] = {}
        for n in names:
            r = recipes[n]
            d = set()
            for kind in kinds:
                for raw in r[kind]:
                    m = resolve(raw)
                    if m != n and m in names:
                        d.add(m)
            g[n] = d
        return g

    build = edges(("makedepends", "depends"))   # full build-time graph
    runtime = edges(("depends",))                # for intra-SCC ordering

    # Tarjan strongly-connected components (iterative, to avoid recursion limits).
    index = {}; low = {}; on = set(); stack = []; comp_of = {}; comps = []
    counter = 0
    for root in names:
        if root in index:
            continue
        work = [(root, iter(sorted(build[root])))]
        while work:
            node, it = work[-1]
            if node not in index:
                index[node] = low[node] = counter; counter += 1
                stack.append(node); on.add(node)
            advanced = False
            for w in it:
                if w not in index:
                    work.append((w, iter(sorted(build[w])))); advanced = True; break
                if w in on:
                    low[node] = min(low[node], index[w])
            if advanced:
                continue
            if low[node] == index[node]:
                comp = []
                while True:
                    m = stack.pop(); on.discard(m); comp_of[m] = len(comps); comp.append(m)
                    if m == node:
                        break
                comps.append(comp)
            work.pop()
            if work:
                parent = work[-1][0]
                low[parent] = min(low[parent], low[node])

    # Condensation DAG: cdeps[c] = SCCs c depends on (excluding itself).
    cdeps: dict[int, set[int]] = {i: set() for i in range(len(comps))}
    for n in names:
        for m in build[n]:
            a, b = comp_of[n], comp_of[m]
            if a != b:
                cdeps[a].add(b)

    comp_order = _kahn(range(len(comps)), cdeps)
    multi = [c for c in comp_order if len(comps[c]) > 1]
    if multi:
        for c in multi:
            print("makedep-closure: --topo SCC (" + str(len(comps[c])) + " pkgs): "
                  + " ".join(sorted(comps[c])), file=sys.stderr)

    order: list[str] = []
    for c in comp_order:
        members = comps[c]
        if len(members) == 1:
            order.append(members[0])
        else:
            sub = {m: (runtime[m] & set(members)) for m in members}
            order.extend(_kahn(members, sub))
    return order


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
    topo = False
    outdir = None
    if args and args[0] == "--topo":
        topo = True
        args = args[1:]  # optional subset; default = all recipes
    elif args and args[0] == "--check":
        check = True
        if len(args) < 3:
            print("usage: makedep-closure.py --check <out-dir> <pkg>...", file=sys.stderr)
            return 2
        outdir = args[1]
        args = args[2:]
    if not args and not topo:
        print("usage: makedep-closure.py [--topo|--check <out-dir>] <pkg>...", file=sys.stderr)
        return 2

    provided = load_provided()
    recipes = load_recipes()
    prov = build_provides(recipes)

    if topo:
        for m in topo_order(recipes, provided, prov, subset=args or None):
            print(m)
        return 0

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
