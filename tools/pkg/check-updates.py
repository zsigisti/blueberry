#!/usr/bin/env python3
"""check-updates.py — report which packages/ recipes are behind upstream.

"Rolling" only means something if someone notices when upstream moves. This
scans every packages/<name>/bpm.toml, works out the latest upstream version, and
flags the ones that are behind — so version bumps are driven by a report instead
of by memory.

Upstream is auto-detected from the recipe's first `[[source]]` URL:
  * github.com/OWNER/REPO      -> GitHub tags API
  * gitlab.com/OWNER/REPO      -> GitLab tags API
  * ftp.gnu.org/gnu/PROJECT    -> GNU ftp listing
A recipe can override or add detection with an `[upstream]` table:
  [upstream]
  github = "owner/repo"           # or  gitlab = "owner/repo"
  url    = "https://x/releases"   # fetch this page and…
  regex  = "v([0-9.]+)\\.tar"      # …take the highest capture group
  skip   = true                   # don't track (with an optional reason= )

Auth: set GITHUB_TOKEN (CI provides one) to lift the GitHub rate limit.

Usage:
  tools/pkg/check-updates.py [--json] [--only NAME]... [--fail-outdated]
Exit: 0 normally; non-zero only with --fail-outdated when something is behind.
"""
import argparse
import glob
import json
import os
import re
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request

TOP = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PKGDIR = os.path.join(TOP, "packages")
UA = {"User-Agent": "blueberry-check-updates"}
TIMEOUT = 20


# ── version comparison (numeric-aware, "is a newer than b") ──────────────────
def _parts(v):
    return [int(x) if x.isdigit() else x for x in re.findall(r"\d+|[a-zA-Z]+", v)]


def newer(a, b):
    pa, pb = _parts(a), _parts(b)
    for x, y in zip(pa, pb):
        if type(x) is type(y):
            if x != y:
                return x > y
        else:  # a number outranks a letter run (1.0 > 1.0rc1)
            return isinstance(x, int)
    return len(pa) > len(pb)


def _clean(tag):
    """Strip common prefixes so tags compare against a bare recipe version."""
    t = tag.strip().lstrip("vV")
    t = re.sub(r"^(release[-_]?|rel[-_]?|ver[-_]?)", "", t, flags=re.I)
    return t


VER_RE = re.compile(r"^[0-9][0-9.]*[0-9a-zA-Z.]*$")


def _first_int(v):
    m = re.match(r"(\d+)", v)
    return int(m.group(1)) if m else None


def _pick_latest(cands, cur):
    """Highest release-looking tag that is shape-compatible with the current
    version. The shape check rejects the junk real repos carry — date tags
    (20060301), commit serials — that would otherwise dwarf a real version."""
    cur_has_dot = "." in cur
    cur_first = _first_int(cur)
    best = None
    for c in cands:
        c = _clean(c)
        if not VER_RE.match(c):
            continue
        if re.search(r"(rc|alpha|beta|pre|dev|snapshot|nightly|test)", c, re.I):
            continue
        if cur_has_dot and "." not in c:
            continue  # a dotted project won't suddenly ship a bare-integer version
        cf = _first_int(c)
        if cur_first and cf and cf > cur_first * 50 + 1000:
            continue  # leading component dwarfs current's — a date/serial, not a bump
        if best is None or newer(c, best):
            best = c
    return best


# ── network helpers ──────────────────────────────────────────────────────────
def _get(url, headers=None):
    req = urllib.request.Request(url, headers={**UA, **(headers or {})})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return r.read().decode("utf-8", "replace")


def _get_json(url, headers=None):
    return json.loads(_get(url, headers))


# ── providers: return the latest upstream version string, or raise ───────────
def latest_github(owner_repo, cur):
    hdr = {"Accept": "application/vnd.github+json"}
    tok = os.environ.get("GITHUB_TOKEN")
    if tok:
        hdr["Authorization"] = f"Bearer {tok}"
    tags = _get_json(f"https://api.github.com/repos/{owner_repo}/tags?per_page=100", hdr)
    return _pick_latest((t["name"] for t in tags), cur)


def latest_gitlab(owner_repo, cur):
    proj = urllib.parse.quote(owner_repo, safe="")
    tags = _get_json(f"https://gitlab.com/api/v4/projects/{proj}/repository/tags?per_page=100")
    return _pick_latest((t["name"] for t in tags), cur)


def latest_gnu(project, cur):
    html = _get(f"https://ftp.gnu.org/gnu/{project}/")
    cands = re.findall(rf"{re.escape(project)}[-_]([0-9][0-9.]*)\.tar", html)
    return _pick_latest(cands, cur)


def latest_regex(url_regex, cur):
    url, regex = url_regex
    html = _get(url)
    return _pick_latest(re.findall(regex, html), cur)


# ── detect the provider for one recipe ───────────────────────────────────────
def detect(pkg):
    up = pkg.get("upstream") or {}
    if up.get("skip"):
        return ("skip", up.get("reason", "marked skip"))
    if up.get("github"):
        return ("github", up["github"])
    if up.get("gitlab"):
        return ("gitlab", up["gitlab"])
    if up.get("url") and up.get("regex"):
        return ("regex", (up["url"], up["regex"]))

    srcs = pkg.get("source", []) or pkg.get("sources", [])
    for s in srcs:
        raw = s.get("url", "")
        url = raw.split("::", 1)[1] if "::" in raw else raw
        m = re.search(r"github\.com/([^/]+/[^/]+?)(?:\.git)?/", url)
        if m:
            return ("github", m.group(1))
        m = re.search(r"gitlab\.com/([^/]+/[^/]+?)/-/", url)
        if m:
            return ("gitlab", m.group(1))
        # GNU projects are mirrored widely (ftp.gnu.org, ftpmirror.gnu.org,
        # mirrors.kernel.org/gnu, …) — key off the /gnu/PROJECT/ path, not the host.
        m = re.search(r"/gnu/([^/]+)/[^/]*\.tar", url)
        if m:
            return ("gnu", m.group(1))
    return (None, None)


def latest_for(method, arg, cur):
    return {
        "github": latest_github,
        "gitlab": latest_gitlab,
        "gnu": latest_gnu,
        "regex": latest_regex,
    }[method](arg, cur)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--only", action="append", default=[], help="limit to these package names")
    ap.add_argument("--fail-outdated", action="store_true")
    args = ap.parse_args()

    rows = []
    for toml in sorted(glob.glob(os.path.join(PKGDIR, "*", "bpm.toml"))):
        with open(toml, "rb") as f:
            data = tomllib.load(f)
        pkg = data.get("package", {})
        name = pkg.get("name") or os.path.basename(os.path.dirname(toml))
        if args.only and name not in args.only:
            continue
        cur = str(pkg.get("version", ""))
        method, arg = detect(data)
        if method == "skip":
            rows.append((name, cur, "-", "skip", arg))
            continue
        if not method:
            rows.append((name, cur, "?", "unknown", "no upstream (add [upstream])"))
            continue
        try:
            latest = latest_for(method, arg, cur)
        except (urllib.error.URLError, urllib.error.HTTPError, KeyError, ValueError, TimeoutError) as e:
            rows.append((name, cur, "?", "error", f"{method}: {type(e).__name__}"))
            continue
        if not latest:
            rows.append((name, cur, "?", "error", f"{method}: no usable tags"))
        elif newer(latest, cur):
            rows.append((name, cur, latest, "OUTDATED", method))
        else:
            rows.append((name, cur, latest, "current", method))

    if args.json:
        print(json.dumps(
            [dict(zip(("name", "current", "latest", "status", "note"), r)) for r in rows],
            indent=2,
        ))
    else:
        w = max((len(r[0]) for r in rows), default=4)
        for name, cur, latest, status, note in rows:
            mark = {"OUTDATED": "!!", "current": "ok", "unknown": "??", "error": "..", "skip": "--"}.get(status, "  ")
            print(f"{mark} {name:<{w}}  {cur:<14} -> {latest:<14} {status:<9} {note}")

    outdated = [r for r in rows if r[3] == "OUTDATED"]
    counts = {}
    for r in rows:
        counts[r[3]] = counts.get(r[3], 0) + 1
    summary = ", ".join(f"{k}: {v}" for k, v in sorted(counts.items()))
    print(f"\ncheck-updates: {len(rows)} recipes — {summary}", file=sys.stderr)

    if args.fail_outdated and outdated:
        sys.exit(1)


if __name__ == "__main__":
    main()
