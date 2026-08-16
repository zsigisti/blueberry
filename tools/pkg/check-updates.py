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
  * downloads.sourceforge.net  -> SourceForge best_release.json
  * anything else ending in    -> the tarball's own directory, read as a
    NAME-VERSION.tar*             release index (most tarball projects ship one)
A recipe can override or add detection with an `[upstream]` table:
  [upstream]
  github = "owner/repo"           # or  gitlab = "owner/repo"
  sourceforge = "project"         # or  pypi = "distribution"
  url    = "https://x/releases"   # fetch this page and…
  regex  = "v([0-9.]+)\\.tar"      # …take the highest capture group
  url + name = "foo"              # …or read it as a NAME-VERSION.tar* index
  track  = "3.4"                  # only track this series (LTS pins)
  skip   = true                   # don't track (with an optional reason= )

Auth: set GITHUB_TOKEN (CI provides one) to lift the GitHub rate limit.

Usage:
  tools/pkg/check-updates.py [--json] [--only NAME]... [--fail-outdated]
                             [--jobs N]
Exit: 0 normally; non-zero only with --fail-outdated when something is behind.
"""
import argparse
import concurrent.futures
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
PRERELEASE_RE = re.compile(r"(rc|alpha|beta|pre|dev|snapshot|nightly|test)", re.I)
# Tags that name a platform, not a release. smartmontools carries
# X86_64_LINUX_OK next to RELEASE_7_5; read as a version that is "86.64",
# which outranks every real tag forever.
PLATFORM_RE = re.compile(
    r"(x86|i[36]86|amd64|arm64|aarch64|powerpc|sparc|s390|"
    r"win32|win64|windows|mingw|cygwin|darwin|macos|freebsd|solaris)", re.I)


def _parts(v):
    return [int(x) if x.isdigit() else x for x in re.findall(r"\d+|[a-zA-Z]+", v)]


def newer(a, b):
    pa, pb = _parts(a), _parts(b)
    for x, y in zip(pa, pb):
        if type(x) is type(y):
            if x != y:
                return x > y
        else:  # a number outranks a letter run (1.0.1 > 1.0rc1)
            return isinstance(x, int)
    if len(pa) == len(pb):
        return False
    # One ran out first. Its extra part decides: a pre-release word demotes the
    # longer string (1.0 > 1.0rc1), anything else extends it — an extra number
    # (1.2.3 > 1.2) or a patch letter, which is how tmux/ncurses ship fixes
    # (3.7b > 3.7).
    a_shorter = len(pa) < len(pb)
    extra = (pb if a_shorter else pa)[min(len(pa), len(pb))]
    demoted = isinstance(extra, str) and PRERELEASE_RE.fullmatch(extra)
    return a_shorter if demoted else not a_shorter


def _clean(tag):
    """Strip the decoration real repos put around a version.

    Tags in the wild are a version wearing a costume: `openssl-3.4.6`,
    `llvmorg-22.1.8`, `R_2_8_2`, `libnl3_11_0`, `RELEASE_7_4`, `NSS_3_108_RTM`,
    `go1.26.5`, `r58`. Undressing them here is what keeps a package tracked
    instead of silently reported as "no usable tags".
    """
    t = tag.strip().rsplit("/", 1)[-1]      # refs/tags/v1.2, debian/1.2
    while t and t[0].isalpha():             # project/`v`/`release` prefix, and
        stripped = re.sub(r"^[A-Za-z]+[-_.]?", "", t)   # json-c-0.19 needs two
        if stripped == t:
            break
        t = stripped
    # A short digit run then a hyphen can be the tail of the *name* rather than
    # the version (pcre2-10.47 -> 10.47) — but only when what follows is a
    # dotted version on its own. flex tags flex-2-5-10 and logrotate tags
    # r3-9-1, where that same leading digit is the major version.
    head, sep, rest = t.partition("-")
    if sep and head.isdigit() and len(head) <= 2 and "." in rest and "-" not in rest:
        t = rest
    t = re.sub(r"(?<=\d)-(?=\d)", ".", t)   # 2-5-10 -> 2.5.10, 20240808-3.1 -> …
    if "." not in t and "_" in t:
        # 3_11_0 -> 3.11.0, and NSS_3_108_RTM -> 3.108: one trailing word is
        # release decoration, more than one means the tag was never a version
        # (86_64_LINUX_OK), so leave it unparseable rather than invent 86.64.
        segs = t.split("_")
        if segs and not segs[-1].isdigit():
            segs.pop()
        t = ".".join(segs) if all(s.isdigit() for s in segs) else t
    # drop trailing decoration that carries no number (2.8.3.RTM -> 2.8.3)
    parts = t.split(".")
    while len(parts) > 1 and not any(c.isdigit() for c in parts[-1]):
        parts.pop()
    return ".".join(parts)


VER_RE = re.compile(r"^[0-9][0-9.]*[0-9a-zA-Z.]*$")


def _first_int(v):
    m = re.match(r"(\d+)", v)
    return int(m.group(1)) if m else None


def _in_track(v, track):
    """Is v inside the pinned release series? `3.4` covers 3.4 and 3.4.x, not 3.40."""
    return v == track or v.startswith(track + ".")


def _pick_latest(cands, cur, track=None):
    """Highest release-looking tag that is shape-compatible with the current
    version. The shape check rejects the junk real repos carry — date tags
    (20060301), commit serials — that would otherwise dwarf a real version.
    `track` pins the search to one release series, for packages we deliberately
    hold on an LTS branch (openssl 3.4, postgresql 17, …)."""
    cur_has_dot = "." in cur
    cur_first = _first_int(cur)
    best = None
    for raw in cands:
        if PLATFORM_RE.search(raw) or PRERELEASE_RE.search(raw):
            continue  # judged on the raw tag: cleaning hides the give-away word
        c = _clean(raw)
        if not VER_RE.match(c):
            continue
        if track and not _in_track(c, track):
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
    hdr = {**UA, **(headers or {})}
    tok = os.environ.get("GITHUB_TOKEN")
    if tok and "api.github.com" in url and "Authorization" not in hdr:
        hdr["Authorization"] = f"Bearer {tok}"   # so [upstream] url= can use the API too
    req = urllib.request.Request(url, headers=hdr)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return r.read().decode("utf-8", "replace")


def _get_json(url, headers=None):
    return json.loads(_get(url, headers))


# ── providers: return the latest upstream version string, or raise ───────────
def latest_github(owner_repo, cur, track=None):
    hdr = {"Accept": "application/vnd.github+json"}
    tok = os.environ.get("GITHUB_TOKEN")
    if tok:
        hdr["Authorization"] = f"Bearer {tok}"
    tags = _get_json(f"https://api.github.com/repos/{owner_repo}/tags?per_page=100", hdr)
    return _pick_latest((t["name"] for t in tags), cur, track)


def latest_gitlab(owner_repo, cur, track=None):
    proj = urllib.parse.quote(owner_repo, safe="")
    tags = _get_json(f"https://gitlab.com/api/v4/projects/{proj}/repository/tags?per_page=100")
    return _pick_latest((t["name"] for t in tags), cur, track)


def latest_gnu(project, cur, track=None):
    html = _get(f"https://ftp.gnu.org/gnu/{project}/")
    cands = re.findall(rf"{re.escape(project)}[-_]([0-9][0-9.]*)\.tar", html)
    return _pick_latest(cands, cur, track)


def latest_regex(url_regex_join, cur, track=None):
    url, regex, join = url_regex_join
    html = _get(url)
    # Several groups = a version the page splits differently than the recipe
    # writes it: cacert-2026-05-14.pem -> 20260514 (join ""), and sqlite's
    # 3530400 -> 3.53.4 (join "."). Put it back together the recipe's way.
    cands = [join.join(m) if isinstance(m, tuple) else m for m in re.findall(regex, html)]
    return _pick_latest(cands, cur, track)


def _listing_versions(html, name):
    """Every NAME-<version>.tar* / NAME-<version>.zip in a directory index.

    The trailing `[-_.]` guard keeps a sibling project out of the result:
    libcap's index also lists libcap-ng-0.8.5.tar.gz, and without it that
    parses as libcap 0.8.5 — a downgrade reported as an update.
    """
    pat = rf"{re.escape(name)}[-_]v?(\d[\d.]*\d|\d)\.(?:tar|tgz|zip)"
    return [m for m in re.findall(pat, html)]


def latest_listing(dir_name, cur, track=None):
    """Most tarball projects publish into a directory index — use it as the
    release list. This is the fallback that keeps the long tail of hand-rolled
    download pages (kernel.org, netfilter, savannah, gnupg, …) tracked."""
    url, name = dir_name
    return _pick_latest(_listing_versions(_get(url), name), cur, track)


def latest_sourceforge(project, cur, track=None):
    """SourceForge's file browser is JS-driven; best_release.json is not."""
    d = _get_json(f"https://sourceforge.net/projects/{project}/best_release.json")
    fn = (d.get("release") or {}).get("filename", "")
    cands = re.findall(r"(\d[\d.]*\d)", os.path.basename(fn))
    return _pick_latest(cands, cur, track)


def latest_pypi(project, cur, track=None):
    d = _get_json(f"https://pypi.org/pypi/{project}/json")
    releases = d.get("releases") or {}
    return _pick_latest(releases.keys() or [d["info"]["version"]], cur, track)


# ── detect the provider for one recipe ───────────────────────────────────────
def detect(pkg):
    up = pkg.get("upstream") or {}
    if up.get("skip"):
        return ("skip", up.get("reason", "marked skip"))
    if up.get("github"):
        return ("github", up["github"])
    if up.get("gitlab"):
        return ("gitlab", up["gitlab"])
    if up.get("sourceforge"):
        return ("sourceforge", up["sourceforge"])
    if up.get("pypi"):
        return ("pypi", up["pypi"])
    if up.get("url") and up.get("regex"):
        return ("regex", (up["url"], up["regex"], up.get("join", "")))
    if up.get("url") and up.get("name"):
        return ("listing", (up["url"], up["name"]))

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
        # sourceforge mirrors: downloads.sf.net/PROJECT/… or …/project/PROJECT/…
        m = re.search(r"(?:downloads?|dl)\.sourceforge\.net/(?:project/)?([^/]+)/", url)
        if m:
            return ("sourceforge", m.group(1))
        # Fallback: the tarball's own directory is usually a release index.
        dir_name = _listing_target(url)
        if dir_name:
            return ("listing", dir_name)
    return (None, None)


def _listing_target(url):
    """(directory-url, project-name) for a `…/NAME-VERSION.tar.*` source URL."""
    base = url.rsplit("/", 1)
    if len(base) != 2:
        return None
    m = re.match(r"^(.+?)[-_]v?\d[\d.]*\.(?:tar|tgz|zip)", base[1])
    return (base[0] + "/", m.group(1)) if m else None


def latest_for(method, arg, cur, track=None):
    return {
        "github": latest_github,
        "gitlab": latest_gitlab,
        "gnu": latest_gnu,
        "regex": latest_regex,
        "listing": latest_listing,
        "sourceforge": latest_sourceforge,
        "pypi": latest_pypi,
    }[method](arg, cur, track)


def check_one(name, cur, method, arg, track):
    """One recipe -> its report row. Network-bound; safe to run in a thread."""
    try:
        latest = latest_for(method, arg, cur, track)
    except (urllib.error.URLError, urllib.error.HTTPError, KeyError,
            ValueError, TimeoutError, ConnectionError, OSError) as e:
        return (name, cur, "?", "error", f"{method}: {type(e).__name__}")
    if not latest:
        return (name, cur, "?", "error", f"{method}: no usable tags")
    if newer(latest, cur):
        return (name, cur, latest, "OUTDATED", method)
    return (name, cur, latest, "current", method)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--only", action="append", default=[], help="limit to these package names")
    ap.add_argument("--fail-outdated", action="store_true")
    ap.add_argument("--jobs", type=int, default=8, help="parallel upstream queries")
    args = ap.parse_args()

    rows, queries = [], []
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
        elif not method:
            rows.append((name, cur, "?", "unknown", "no upstream (add [upstream])"))
        else:
            queries.append((name, cur, method, arg, (data.get("upstream") or {}).get("track")))

    # ~220 recipes against ~90 different hosts, each with a 20s timeout: serial
    # this is a quarter-hour, which is too slow to stay in CI.
    if queries:
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            rows += list(pool.map(lambda q: check_one(*q), queries))
    rows.sort(key=lambda r: r[0])

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
