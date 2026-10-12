#!/usr/bin/env python3
"""check-updates.py - which recipes are behind upstream.

"Rolling" means nothing if nobody notices upstream moving, so this walks
packages/*/bpm.toml, finds the latest upstream version and flags what's behind.

Upstream is guessed from the first [[source]] URL:
  github.com/OWNER/REPO      -> GitHub tags API
  gitlab.com/OWNER/REPO      -> GitLab tags API
  .../gnu/PROJECT/           -> GNU ftp listing
  downloads.sourceforge.net  -> SourceForge best_release.json
  .../NAME-VERSION.tar*      -> that directory, read as a release index
or set explicitly with an [upstream] table:
  github = "owner/repo"           # or gitlab = "owner/repo"
  sourceforge = "project"         # or pypi = "distribution"
  url    = "https://x/releases"   # fetch this page and
  regex  = "v([0-9.]+)\\.tar"      # take the highest capture
  url + name = "foo"              # or read it as a NAME-VERSION.tar* index
  track  = "3.4"                  # stick to one series (LTS pins)
  skip   = true                   # don't track (optional reason = "...")

Set GITHUB_TOKEN (CI has one) or GitHub rate-limits you quickly.

  tools/pkg/check-updates.py [--json] [--only NAME]... [--fail-outdated] [--jobs N]

Exit is 0 unless --fail-outdated and something is behind.
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


PRERELEASE_RE = re.compile(r"(rc|alpha|beta|pre|dev|snapshot|nightly|test)", re.I)
# tags naming a platform, not a release. smartmontools has X86_64_LINUX_OK next
# to RELEASE_7_5, and "86.64" would outrank every real tag forever.
PLATFORM_RE = re.compile(
    r"(x86|i[36]86|amd64|arm64|aarch64|powerpc|sparc|s390|"
    r"win32|win64|windows|mingw|cygwin|darwin|macos|freebsd|solaris)", re.I)


def _parts(v):
    return [int(x) if x.isdigit() else x for x in re.findall(r"\d+|[a-zA-Z]+", v)]


def newer(a, b):
    """is a newer than b"""
    pa, pb = _parts(a), _parts(b)
    for x, y in zip(pa, pb):
        if type(x) is type(y):
            if x != y:
                return x > y
        else:  # number beats letters (1.0.1 > 1.0rc1)
            return isinstance(x, int)
    if len(pa) == len(pb):
        return False
    # one ran out first, so the longer one's next part decides: a pre-release
    # word demotes it (1.0 > 1.0rc1), anything else makes it newer, be it an
    # extra number (1.2.3 > 1.2) or a patch letter like tmux's 3.7b > 3.7
    a_shorter = len(pa) < len(pb)
    extra = (pb if a_shorter else pa)[min(len(pa), len(pb))]
    demoted = isinstance(extra, str) and PRERELEASE_RE.fullmatch(extra)
    return a_shorter if demoted else not a_shorter


def _clean(tag):
    # dig the version out of whatever repos tag with: openssl-3.4.6,
    # llvmorg-22.1.8, R_2_8_2, libnl3_11_0, NSS_3_108_RTM, go1.26.5, r58.
    # anything this misses shows up as "no usable tags" and stops being tracked.
    t = tag.strip().rsplit("/", 1)[-1]      # refs/tags/v1.2, debian/1.2
    while t and t[0].isalpha():             # name / v / release prefixes;
        stripped = re.sub(r"^[A-Za-z]+[-_.]?", "", t)   # json-c-0.19 takes two rounds
        if stripped == t:
            break
        t = stripped
    # a short digit run + hyphen can be the end of the *name* (pcre2-10.47),
    # but only if a plain dotted version follows. flex-2-5-10 and logrotate's
    # r3-9-1 lead with the major version instead.
    head, sep, rest = t.partition("-")
    if sep and head.isdigit() and len(head) <= 2 and "." in rest and "-" not in rest:
        t = rest
    t = re.sub(r"(?<=\d)-(?=\d)", ".", t)   # 2-5-10 -> 2.5.10, 20240808-3.1 -> 20240808.3.1
    if "." not in t and "_" in t:
        # 3_11_0 -> 3.11.0, NSS_3_108_RTM -> 3.108. one trailing word is
        # decoration; more than one (86_64_LINUX_OK) means it was never a
        # version, so leave it unparseable instead of inventing 86.64
        segs = t.split("_")
        if segs and not segs[-1].isdigit():
            segs.pop()
        t = ".".join(segs) if all(s.isdigit() for s in segs) else t
    # trailing junk with no digits in it (2.8.3.RTM -> 2.8.3)
    parts = t.split(".")
    while len(parts) > 1 and not any(c.isdigit() for c in parts[-1]):
        parts.pop()
    return ".".join(parts)


VER_RE = re.compile(r"^[0-9][0-9.]*[0-9a-zA-Z.]*$")


def _first_int(v):
    m = re.match(r"(\d+)", v)
    return int(m.group(1)) if m else None


def _in_track(v, track):
    # "3.4" covers 3.4 and 3.4.x, not 3.40
    return v == track or v.startswith(track + ".")


def _pick_latest(cands, cur, track=None):
    # highest release-looking tag shaped like the current version. the shape
    # checks throw out date tags (20060301) and commit serials that would
    # otherwise beat any real version. track pins an LTS series (openssl 3.4...)
    cur_has_dot = "." in cur
    cur_first = _first_int(cur)
    best = None
    for raw in cands:
        if PLATFORM_RE.search(raw) or PRERELEASE_RE.search(raw):
            continue  # check the raw tag, cleaning strips the giveaway word
        c = _clean(raw)
        if not VER_RE.match(c):
            continue
        if track and not _in_track(c, track):
            continue
        if cur_has_dot and "." not in c:
            continue  # dotted projects don't suddenly ship bare integers
        cf = _first_int(c)
        if cur_first and cf and cf > cur_first * 50 + 1000:
            continue  # way bigger leading number: a date/serial, not a bump
        if best is None or newer(c, best):
            best = c
    return best


def _get(url, headers=None):
    hdr = {**UA, **(headers or {})}
    tok = os.environ.get("GITHUB_TOKEN")
    if tok and "api.github.com" in url and "Authorization" not in hdr:
        hdr["Authorization"] = f"Bearer {tok}"   # [upstream] url= can hit the API too
    req = urllib.request.Request(url, headers=hdr)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return r.read().decode("utf-8", "replace")


def _get_json(url, headers=None):
    return json.loads(_get(url, headers))


# providers: return the latest version string (or None), raise on network trouble

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
    # several groups = the page splits the version differently from the recipe:
    # cacert-2026-05-14.pem -> 20260514 (join ""), sqlite 3530400 -> 3.53.4 (join ".")
    cands = [join.join(m) if isinstance(m, tuple) else m for m in re.findall(regex, html)]
    return _pick_latest(cands, cur, track)


def _listing_versions(html, name):
    # NAME-<ver>.tar*/.zip in a directory index. the [-_] right after the name
    # matters: libcap's index also has libcap-ng-0.8.5.tar.gz, which would
    # otherwise read as libcap 0.8.5
    pat = rf"{re.escape(name)}[-_]v?(\d[\d.]*\d|\d)\.(?:tar|tgz|zip)"
    return re.findall(pat, html)


def latest_listing(dir_name, cur, track=None):
    # catches the long tail of plain download dirs (kernel.org, savannah, gnupg...)
    url, name = dir_name
    return _pick_latest(_listing_versions(_get(url), name), cur, track)


def latest_sourceforge(project, cur, track=None):
    # the file browser is all JS, best_release.json isn't
    d = _get_json(f"https://sourceforge.net/projects/{project}/best_release.json")
    fn = (d.get("release") or {}).get("filename", "")
    cands = re.findall(r"(\d[\d.]*\d)", os.path.basename(fn))
    return _pick_latest(cands, cur, track)


def latest_pypi(project, cur, track=None):
    d = _get_json(f"https://pypi.org/pypi/{project}/json")
    releases = d.get("releases") or {}
    return _pick_latest(releases.keys() or [d["info"]["version"]], cur, track)


def detect(pkg):
    up = pkg.get("upstream") or {}
    if up.get("skip"):
        return ("skip", up.get("reason", "marked skip"))
    for key in ("github", "gitlab", "sourceforge", "pypi"):
        if up.get(key):
            return (key, up[key])
    if up.get("url") and up.get("regex"):
        return ("regex", (up["url"], up["regex"], up.get("join", "")))
    if up.get("url") and up.get("name"):
        return ("listing", (up["url"], up["name"]))

    for s in pkg.get("source", []) or pkg.get("sources", []):
        raw = s.get("url", "")
        url = raw.split("::", 1)[1] if "::" in raw else raw
        m = re.search(r"github\.com/([^/]+/[^/]+?)(?:\.git)?/", url)
        if m:
            return ("github", m.group(1))
        m = re.search(r"gitlab\.com/([^/]+/[^/]+?)/-/", url)
        if m:
            return ("gitlab", m.group(1))
        # GNU lives on lots of mirrors, so match the /gnu/PROJECT/ path, not the host
        m = re.search(r"/gnu/([^/]+)/[^/]*\.tar", url)
        if m:
            return ("gnu", m.group(1))
        # downloads.sf.net/PROJECT/... or .../project/PROJECT/...
        m = re.search(r"(?:downloads?|dl)\.sourceforge\.net/(?:project/)?([^/]+)/", url)
        if m:
            return ("sourceforge", m.group(1))
        dir_name = _listing_target(url)
        if dir_name:
            return ("listing", dir_name)
    return (None, None)


def _listing_target(url):
    # (dir url, project name) for .../NAME-VERSION.tar.*
    base = url.rsplit("/", 1)
    if len(base) != 2:
        return None
    m = re.match(r"^(.+?)[-_]v?\d[\d.]*\.(?:tar|tgz|zip)", base[1])
    return (base[0] + "/", m.group(1)) if m else None


PROVIDERS = {
    "github": latest_github,
    "gitlab": latest_gitlab,
    "gnu": latest_gnu,
    "regex": latest_regex,
    "listing": latest_listing,
    "sourceforge": latest_sourceforge,
    "pypi": latest_pypi,
}


def latest_for(method, arg, cur, track=None):
    return PROVIDERS[method](arg, cur, track)


def check_one(name, cur, method, arg, track):
    # runs in a worker thread
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


MARKS = {"OUTDATED": "!!", "current": "ok", "unknown": "??", "error": "..", "skip": "--"}


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

    # ~220 recipes, ~90 hosts, 20s timeouts: serially that's a quarter hour
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
            mark = MARKS.get(status, "  ")
            print(f"{mark} {name:<{w}}  {cur:<14} -> {latest:<14} {status:<9} {note}")

    counts = {}
    for r in rows:
        counts[r[3]] = counts.get(r[3], 0) + 1
    summary = ", ".join(f"{k}: {v}" for k, v in sorted(counts.items()))
    print(f"\ncheck-updates: {len(rows)} recipes - {summary}", file=sys.stderr)

    if args.fail_outdated and any(r[3] == "OUTDATED" for r in rows):
        sys.exit(1)


if __name__ == "__main__":
    main()
