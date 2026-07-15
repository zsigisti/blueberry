#!/usr/bin/env python3
"""auto-bump.py — mechanically bump one recipe to a new upstream version.

This is the tedious part of "rolling" done by a machine: rewrite version, source
URL and sha256, reset the release, and update any version string hard-coded in
the build steps. It fetches the new tarball to compute the *real* checksum — a
stale checksum is worse than no bump — and it refuses cases that genuinely need
a human (multiple sources) rather than guessing.

It changes the recipe on disk and prints a human summary (used as the PR body by
the auto-bump workflow). It does NOT build; the reviewer build-verifies with bbdev.

Usage:
  tools/pkg/auto-bump.py <package> [--new-version X]   # X auto-detected if omitted
Exit: 0 on a clean bump; non-zero if nothing to do or a human is needed.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request

TOP = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UA = {"User-Agent": "blueberry-auto-bump"}


def die(msg, code=2):
    print(f"auto-bump: {msg}", file=sys.stderr)
    sys.exit(code)


def detect_latest(name):
    """Ask check-updates.py for the latest version of one recipe."""
    out = subprocess.run(
        [sys.executable, os.path.join(TOP, "tools/pkg/check-updates.py"),
         "--json", "--only", name],
        capture_output=True, text=True,
    )
    try:
        rows = json.loads(out.stdout or "[]")
    except json.JSONDecodeError:
        die("could not parse check-updates output")
    for r in rows:
        if r.get("name") == name:
            return r.get("latest"), r.get("status")
    die(f"{name}: not reported by check-updates")


def boundary_sub(text, old, new):
    """Replace `old` with `new` only where it is a whole version token. A version
    continues through digits and dot-then-digit (so 1.2 must not match inside
    1.20 or 1.2.3), but a trailing filename dot (…2.3.2.tar) does not continue it,
    so both the tag and the tarball name in a URL like /2.3.2/tree-2.3.2.tar.gz
    are rewritten."""
    pat = rf"(?<!\d)(?<!\d\.){re.escape(old)}(?!\d)(?!\.\d)"
    return re.sub(pat, new, text)


def fetch_sha256(url):
    req = urllib.request.Request(url, headers=UA)
    h = hashlib.sha256()
    with urllib.request.urlopen(req, timeout=120) as r:
        for chunk in iter(lambda: r.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description="bump one recipe to a new upstream version")
    ap.add_argument("package")
    ap.add_argument("--new-version", help="target version (auto-detected if omitted)")
    args = ap.parse_args()

    recipe = os.path.join(TOP, "packages", args.package, "bpm.toml")
    if not os.path.isfile(recipe):
        die(f"no recipe: {recipe}")
    text = open(recipe, encoding="utf-8").read()

    cur = re.search(r'(?m)^version\s*=\s*"([^"]+)"', text)
    if not cur:
        die("cannot find version in recipe")
    cur = cur.group(1)

    new = args.new_version or detect_latest(args.package)[0]
    if not new or new in ("?", "-"):
        die(f"{args.package}: no usable upstream version")
    if new == cur:
        die(f"{args.package}: already at {cur}", code=1)

    # One source only — multi-source recipes are rare and need judgement.
    urls = re.findall(r'(?m)^\s*url\s*=\s*"([^"]+)"', text)
    shas = re.findall(r'(?m)^\s*sha256\s*=\s*"([0-9a-f]{64})"', text)
    if len(urls) != 1 or len(shas) != 1:
        die(f"{args.package}: {len(urls)} source(s)/{len(shas)} checksum(s) — bump by hand", code=3)
    old_url, old_sha = urls[0], shas[0]
    new_url = boundary_sub(old_url, cur, new)
    if new_url == old_url:
        die(f"{args.package}: version {cur} not present in the source URL — bump by hand", code=3)

    print(f"fetching {new_url}")
    try:
        new_sha = fetch_sha256(new_url)
    except Exception as e:
        die(f"fetch failed ({e}) — upstream may name {new} differently", code=3)

    # Rewrite: version field, release -> 1, the url line, the checksum.
    new_text = re.sub(r'(?m)^(version\s*=\s*")[^"]+(")', rf"\g<1>{new}\g<2>", text, count=1)
    new_text = re.sub(r'(?m)^(release\s*=\s*)\d+', r"\g<1>1", new_text, count=1)
    new_text = new_text.replace(old_url, new_url, 1)
    new_text = new_text.replace(old_sha, new_sha, 1)

    # Hard-coded version strings in the build steps (e.g. -X main.version=…).
    steps_hardcoded = False
    m = re.search(r'(?s)\[steps\].*', new_text)
    if m and boundary_sub(m.group(0), cur, new) != m.group(0):
        steps_hardcoded = True
        head, tail = new_text[: m.start()], boundary_sub(m.group(0), cur, new)
        new_text = head + tail

    open(recipe, "w", encoding="utf-8").write(new_text)

    print(f"\n{args.package}: {cur} -> {new}")
    print(f"  url    {new_url}")
    print(f"  sha256 {new_sha}")
    print("  release reset to 1")
    if steps_hardcoded:
        print(f"  NOTE: also rewrote {cur}->{new} inside [steps] — REVIEW the build carefully")
    print("\n  Build-verify before merge:  ./src/bbdev/target/release/bbdev build "
          + args.package)


if __name__ == "__main__":
    main()
