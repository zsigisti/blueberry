#!/usr/bin/env python3
"""makedep-closure.py - what has to be installed to build a package.

To build X you need its makedepends and depends, plus the runtime depends of
those, transitively (the tools have to run and X has to link). You don't need a
makedep's own makedepends, that thing is already built. Provided names
(etc/bpm/provided, glibc, gcc-libs) are leaves. X itself is left out.

Prints one name per line, deps before dependents, so it can be installed in
that order. --check instead fails if any member has no built .bpm in out-dir.
--topo prints a build order for every recipe (or the given subset).

  makedep-closure.py <pkg> [<pkg>...]
  makedep-closure.py --check <out-dir> <pkg> [<pkg>...]
  makedep-closure.py --topo [<pkg>...]
"""
import glob
import os
import sys
try:
    import tomllib
except ModuleNotFoundError:  # python 3.10 on the repo server, tomli has the same API
    import tomli as tomllib

TOP = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PKGDIR = os.path.join(TOP, "packages")
PROVIDED_FILE = os.path.join(TOP, "etc", "bpm", "provided")

IMPLICIT = {"glibc", "gcc-libs"}  # same as check-closure.py


def atom(dep: str) -> str:
    # foo>=1.2 -> foo
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
            pkg = tomllib.load(f).get("package", {})
        name = pkg.get("name") or os.path.basename(os.path.dirname(toml))
        recipes[name] = {k: [atom(d) for d in pkg.get(k, [])]
                         for k in ("depends", "makedepends", "provides")}
    return recipes


def build_provides(recipes: dict[str, dict]) -> dict[str, str]:
    # provided name -> recipe, so cargo/clang/libssl.so resolve to rust/llvm/openssl
    prov: dict[str, str] = {}
    for name, r in recipes.items():
        for p in r["provides"]:
            prov.setdefault(p, name)
    return prov


def kahn(names, deps) -> list[str]:
    # deps before dependents; whatever is stuck in a cycle goes last, sorted
    order: list[str] = []
    remaining = set(names)
    while remaining:
        ready = sorted(n for n in remaining if not (deps[n] & remaining))
        if not ready:
            break
        for n in ready:
            order.append(n)
            remaining.discard(n)
    order.extend(sorted(remaining))
    return order


def topo_order(recipes, provided, prov, subset=None) -> list[str]:
    """Build order over all recipes, edges = makedepends + depends.

    That graph is very cyclic: gcc, make, binutils, coreutils and friends all
    build-depend on each other. So collapse strongly connected components
    (Tarjan) and order the DAG of those. The toolchain blob comes out first
    (the builder image already has those tools) and cmake -> llvm -> rust -> ...
    follows. Inside a blob we order by runtime depends, best effort; it doesn't
    matter for correctness since the image covers the blob's own needs.
    """
    names = set(recipes) if subset is None else {n for n in subset if n in recipes}

    def resolve(name: str) -> str:
        return name if name in recipes else prov.get(name, name)

    def edges(kinds):
        g: dict[str, set[str]] = {}
        for n in names:
            d = set()
            for kind in kinds:
                for raw in recipes[n][kind]:
                    m = resolve(raw)
                    if m != n and m in names:
                        d.add(m)
            g[n] = d
        return g

    build = edges(("makedepends", "depends"))
    runtime = edges(("depends",))

    # iterative tarjan, the recursive one blows the stack on this graph
    index, low, comp_of = {}, {}, {}
    on, stack, comps = set(), [], []
    counter = 0
    for root in names:
        if root in index:
            continue
        work = [(root, iter(sorted(build[root])))]
        while work:
            node, it = work[-1]
            if node not in index:
                index[node] = low[node] = counter
                counter += 1
                stack.append(node)
                on.add(node)
            advanced = False
            for w in it:
                if w not in index:
                    work.append((w, iter(sorted(build[w]))))
                    advanced = True
                    break
                if w in on:
                    low[node] = min(low[node], index[w])
            if advanced:
                continue
            if low[node] == index[node]:
                comp = []
                while True:
                    m = stack.pop()
                    on.discard(m)
                    comp_of[m] = len(comps)
                    comp.append(m)
                    if m == node:
                        break
                comps.append(comp)
            work.pop()
            if work:
                parent = work[-1][0]
                low[parent] = min(low[parent], low[node])

    cdeps: dict[int, set[int]] = {i: set() for i in range(len(comps))}
    for n in names:
        for m in build[n]:
            a, b = comp_of[n], comp_of[m]
            if a != b:
                cdeps[a].add(b)

    comp_order = kahn(range(len(comps)), cdeps)
    for c in comp_order:
        if len(comps[c]) > 1:
            print(f"makedep-closure: --topo SCC ({len(comps[c])} pkgs): "
                  + " ".join(sorted(comps[c])), file=sys.stderr)

    order: list[str] = []
    for c in comp_order:
        members = comps[c]
        if len(members) == 1:
            order.append(members[0])
        else:
            sub = {m: (runtime[m] & set(members)) for m in members}
            order.extend(kahn(members, sub))
    return order


def closure(pkgs, recipes, provided, prov) -> list[str]:
    order: list[str] = []
    visiting: set[str] = set()
    done: set[str] = set()

    def resolve(name: str) -> str:
        return name if name in recipes else prov.get(name, name)

    def visit(name: str):
        # runtime dep: its depends first, then itself
        name = resolve(name)
        if name in done or name in provided or name in visiting:
            return
        if name not in recipes:
            # unknown and not provided: keep it so --check complains about it
            done.add(name)
            order.append(name)
            return
        visiting.add(name)
        for d in recipes[name]["depends"]:
            visit(d)
        visiting.discard(name)
        done.add(name)
        order.append(name)

    for x in pkgs:
        r = recipes.get(x, {"depends": [], "makedepends": [], "provides": []})
        for d in r["makedepends"] + r["depends"]:
            visit(d)
    return [n for n in order if n not in set(pkgs)]


def main() -> int:
    args = sys.argv[1:]
    check = topo = False
    outdir = None
    if args and args[0] == "--topo":
        topo = True
        args = args[1:]  # optional subset, default is everything
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

    missing = [m for m in members if m not in provided
               and not glob.glob(os.path.join(outdir, f"{m}-[0-9]*.bpm"))]
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
