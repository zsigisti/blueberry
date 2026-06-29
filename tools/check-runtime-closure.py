#!/usr/bin/env python3
# check-runtime-closure.py — assert a staged rootfs is dynamically self-contained.
#
# Walks DT_NEEDED from the session-critical entry binaries AND every dlopen'd
# Qt/Plasma plugin, following the transitive closure, and reports any shared
# library soname that is NOT present anywhere in the rootfs. A missing soname
# means the binary/plugin that needs it will fail to load at runtime (this is
# what silently breaks Plasma applets, media playback, the network stack, …).
#
# Unlike tools/check-closure.py (which is a *static* recipe check — every declared
# `depends` resolves to a recipe), this is a *runtime* check against real built
# artifacts: it catches a soname that is missing even though some recipe nominally
# provides the package (wrong package list, unbuilt dep, soname version bump).
#
# Usage:  tools/check-runtime-closure.py [ROOTFS]
#   ROOTFS   staged rootfs to inspect (default: ../blueberry-build/desktop-rootfs)
#
# Exit 0 if the closure is complete, 1 if any soname is missing, 2 on bad usage.
import os
import re
import subprocess
import sys

TOPDIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOTFS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    TOPDIR, "..", "blueberry-build", "desktop-rootfs")
ROOTFS = os.path.abspath(ROOTFS)

if not os.path.isdir(ROOTFS):
    print(f"check-runtime-closure: no such rootfs: {ROOTFS}", file=sys.stderr)
    print("  (run 'make desktop-stage' first, or pass a rootfs path)", file=sys.stderr)
    sys.exit(2)

# The glibc dynamic loader resolves these from the base; they are always present
# on a real system and are not packaged as sonames in the rootfs lib dirs.
BASE_SONAMES = {
    "ld-linux-x86-64.so.2", "linux-vdso.so.1", "linux-gate.so.1",
}

# ── Index every shared object available in the rootfs by basename ─────────────
have = {}
for base in ("usr/lib", "lib", "usr/lib64", "lib64"):
    root_base = os.path.join(ROOTFS, base)
    if not os.path.isdir(root_base):
        continue
    for root, _, files in os.walk(root_base):
        for f in files:
            if ".so" in f:
                have.setdefault(f, os.path.join(root, f))


def needed(path):
    try:
        out = subprocess.run(["readelf", "-d", path],
                             capture_output=True, text=True).stdout
        return re.findall(r"\(NEEDED\)\s+Shared library:\s+\[([^\]]+)\]", out)
    except Exception:
        return []


def find_bin(name):
    for d in ("usr/bin", "usr/sbin", "bin", "sbin", "usr/libexec"):
        p = os.path.join(ROOTFS, d, name)
        if os.path.exists(p):
            return p
    return None


# ── Entry points: session-critical binaries + every dlopen'd plugin ───────────
entries = {}
for n in ("startplasma-wayland", "startplasma-x11", "kwin_wayland", "kwin_x11",
          "plasmashell", "sddm", "sddm-greeter-qt6", "Xwayland", "plasma_session",
          "kwin_wayland_wrapper", "calamares", "dbus-daemon", "systemsettings"):
    p = find_bin(n)
    if p:
        entries[n] = p

plugin_roots = ("usr/lib/qt6/plugins", "usr/lib/qt6/qml", "usr/lib/plasma",
                "usr/lib/qt/plugins")
plugins = 0
for pr in plugin_roots:
    base = os.path.join(ROOTFS, pr)
    if not os.path.isdir(base):
        continue
    for root, _, files in os.walk(base):
        for f in files:
            if f.endswith(".so"):
                entries[f"plugin:{os.path.relpath(os.path.join(root, f), ROOTFS)}"] = \
                    os.path.join(root, f)
                plugins += 1

# ── BFS the NEEDED closure ────────────────────────────────────────────────────
seen = set()
missing = {}  # soname -> set(requirers)
stack = []
for n, p in entries.items():
    for so in needed(p):
        stack.append((so, n))
while stack:
    so, req = stack.pop()
    if so in BASE_SONAMES:
        continue
    if so in have:
        if have[so] not in seen:
            seen.add(have[so])
            for s2 in needed(have[so]):
                stack.append((s2, so))
    else:
        missing.setdefault(so, set()).add(req)

print(f"rootfs: {ROOTFS}")
print(f"entry points: {len(entries)} ({plugins} plugins) · "
      f"{len(seen)} libraries resolved")

if not missing:
    print("runtime closure: COMPLETE — every NEEDED soname is present")
    sys.exit(0)

print(f"\nruntime closure: {len(missing)} MISSING soname(s):")
for so in sorted(missing):
    reqs = sorted(missing[so])
    head = ", ".join(reqs[:4])
    more = f" (+{len(reqs) - 4} more)" if len(reqs) > 4 else ""
    print(f"  {so:<32} <- {head}{more}")
print("\nBuild the package that provides each soname (and add it to the desktop "
      "package list), then re-stage and re-check.")
sys.exit(1)
