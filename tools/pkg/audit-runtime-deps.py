#!/usr/bin/env python3
"""audit-runtime-deps.py - find recipes that link libraries they never declared.

In the Arch container pacman pulled deps in for us, so lots of recipes only list
the headline libs. Self-hosted builds (BASE=blueberry) install exactly the
declared closure, so anything missing breaks there. This checks the real ELF
linkage of every built package in the store against what's declared.

Runs inside the builder image, store at /deps, recipes at /repo:

  podman run --rm -v $PWD:/repo:ro -v $PWD/obj/bpm-out:/deps:ro \\
      localhost/blueberry-builder:latest \\
      python3 /repo/tools/pkg/audit-runtime-deps.py [--toml]

Prints `<pkg>: <provider> ...` per package with missing deps, or with --toml a
`depends = [...]` line ready to paste.
"""
import glob
import os
import struct
import subprocess
import sys
import tomllib

REPO = "/repo"
STORE = "/deps"
PKGDIR = os.path.join(REPO, "packages")

# always there from the base image / toolchain, never a package dep
BASE_SONAMES = {
    "ld-linux-x86-64.so.2", "libc.so.6", "libm.so.6", "libdl.so.2",
    "librt.so.1", "libpthread.so.0", "libresolv.so.2", "libutil.so.1",
    "libanl.so.1", "libnsl.so.1", "libmvec.so.1",              # glibc
    "libstdc++.so.6", "libgcc_s.so.1", "libatomic.so.1",       # gcc-libs
    "libgomp.so.1", "libgfortran.so.5", "libgo.so.22",
}


def atom(dep: str) -> str:
    return dep.split(">")[0].split("=")[0].split("<")[0].strip()


def load_recipes():
    recipes = {}
    for toml in glob.glob(os.path.join(PKGDIR, "*", "bpm.toml")):
        with open(toml, "rb") as f:
            data = tomllib.load(f)
        pkg = data.get("package", {})
        name = pkg.get("name") or os.path.basename(os.path.dirname(toml))
        recipes[name] = {
            "depends": [atom(d) for d in pkg.get("depends", [])],
            "provides": [atom(d) for d in pkg.get("provides", [])],
            "toml": toml,
        }
    return recipes


def readelf_dyn(path):
    # (soname, [needed]) for an ELF64 LE file, (None, []) for anything else.
    # hand-parsed because the builder image's readelf links libdebuginfod and
    # may not even run there
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None, []
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        return None, []
    e_phoff = struct.unpack_from("<Q", data, 0x20)[0]
    e_phentsize = struct.unpack_from("<H", data, 0x36)[0]
    e_phnum = struct.unpack_from("<H", data, 0x38)[0]
    dyn_off = dyn_size = None
    loads = []                   # (p_offset, p_vaddr, p_filesz)
    for i in range(e_phnum):
        base = e_phoff + i * e_phentsize
        if base + 56 > len(data):
            break
        p_type = struct.unpack_from("<I", data, base)[0]
        p_offset = struct.unpack_from("<Q", data, base + 8)[0]
        p_vaddr = struct.unpack_from("<Q", data, base + 16)[0]
        p_filesz = struct.unpack_from("<Q", data, base + 32)[0]
        if p_type == 2:          # PT_DYNAMIC
            dyn_off, dyn_size = p_offset, p_filesz
        elif p_type == 1:        # PT_LOAD
            loads.append((p_offset, p_vaddr, p_filesz))
    if dyn_off is None:
        return None, []
    needed_offs, soname_off, strtab_vaddr = [], None, None
    for off in range(dyn_off, dyn_off + dyn_size, 16):
        if off + 16 > len(data):
            break
        d_tag, d_val = struct.unpack_from("<qQ", data, off)
        if d_tag == 0:           # DT_NULL
            break
        if d_tag == 1:           # DT_NEEDED
            needed_offs.append(d_val)
        elif d_tag == 14:        # DT_SONAME
            soname_off = d_val
        elif d_tag == 5:         # DT_STRTAB (virtual address)
            strtab_vaddr = d_val
    if strtab_vaddr is None:
        return None, []
    strtab_file = None
    for p_off, p_vaddr, p_filesz in loads:
        if p_vaddr <= strtab_vaddr < p_vaddr + p_filesz:
            strtab_file = p_off + (strtab_vaddr - p_vaddr)
            break
    if strtab_file is None:
        return None, []

    def s(idx):
        end = data.find(b"\x00", strtab_file + idx)
        return data[strtab_file + idx:end].decode("latin-1")

    soname = s(soname_off) if soname_off is not None else None
    return soname, [s(o) for o in needed_offs]


def main():
    want_toml = "--toml" in sys.argv[1:]
    recipes = load_recipes()

    # unpack each package from the store into its own dir and see which sonames it owns
    work = "/tmp/audit-roots"
    subprocess.run(["rm", "-rf", work])
    os.makedirs(work)
    pkg_dir, soname_of_pkg, elf_paths = {}, {}, {}
    for name in recipes:
        hits = sorted(glob.glob(os.path.join(STORE, f"{name}-[0-9]*.bpm")))
        if not hits:
            continue
        d = os.path.join(work, name)
        os.makedirs(d, exist_ok=True)
        subprocess.run(f"zstd -dcq '{hits[-1]}' | tar -x -C '{d}' --exclude=.BPM "
                       "2>/dev/null", shell=True)
        pkg_dir[name] = d
        owns, elfs = set(), []
        for root, _, files in os.walk(d):
            for fn in files:
                p = os.path.join(root, fn)
                if os.path.islink(p):
                    # libfoo.so.1 -> libfoo.so.1.2: the link name is a soname we provide
                    if fn.endswith(".so") or ".so." in fn:
                        owns.add(fn)
                    continue
                so, needed = readelf_dyn(p)
                if so is None and not needed and not fn.endswith(".so") and ".so." not in fn:
                    continue
                if so or needed:
                    elfs.append((p, needed))
                    if so:
                        owns.add(so)
                # some .so files have no SONAME, so count the filename too
                if fn.endswith(".so") or ".so." in fn:
                    owns.add(fn)
        soname_of_pkg[name] = owns
        elf_paths[name] = elfs

    # soname -> package, then recipe `provides` as a fallback
    provider = {}
    for name, owns in soname_of_pkg.items():
        for so in owns:
            provider.setdefault(so, name)
    for name, r in recipes.items():
        for p in r["provides"]:
            provider.setdefault(p, name)

    # what a self-hosted build would actually install
    def declared_closure(name):
        seen, stack = set(), [name]
        while stack:
            n = stack.pop()
            for d in recipes.get(n, {}).get("depends", []):
                d = d if d in recipes else next(
                    (pn for pn, rr in recipes.items() if d in rr["provides"]), d)
                if d not in seen:
                    seen.add(d)
                    stack.append(d)
        return seen

    report = {}
    for name in sorted(pkg_dir):
        covered = declared_closure(name) | {name}
        missing = set()
        for _, needed in elf_paths[name]:
            for so in needed:
                if so in BASE_SONAMES or so in soname_of_pkg[name]:
                    continue
                prov = provider.get(so)
                if prov is None:
                    prov = f"?{so}"           # nobody in the store has it
                elif prov in covered:
                    continue
                missing.add(prov)
        if missing:
            report[name] = sorted(missing)

    for name, miss in report.items():
        if want_toml:
            cur = recipes[name]["depends"]
            new = cur + [m for m in miss if not m.startswith("?")]
            print(f"{name}: depends = {new}")
            unresolved = [m for m in miss if m.startswith("?")]
            if unresolved:
                print(f"  # UNRESOLVED: {' '.join(unresolved)}")
        else:
            print(f"{name}: {' '.join(miss)}")
    if not report:
        print("audit: every package's runtime linkage is covered by declared deps")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
