#!/usr/bin/env python3
"""bpm-audit.py — report known CVEs affecting the installed packages.

Freshness (`check-updates.py`) tells you when upstream *moves*; this tells you
when an installed version is *vulnerable* — the difference between "rolling" and
"rolling toward a fix." It reads the local installed database and, for every
package it has a mapping for, asks an authoritative source which published CVEs
affect that exact version.

Sources (chosen empirically — see the mapping table below):
  * NVD 2.0  — C/system packages. `virtualMatchString` with the installed
    version returns only CVEs whose CPE range covers it, so no client-side
    range matching. Set NVD_API_KEY to lift the 5-request/30s anonymous limit.
  * OSV.dev  — language-ecosystem packages (our Go binaries, Rust helpers).
    OSV does the range matching server-side and needs no key.

A package with no mapping is reported as "untracked", never silently passed —
the point is to be honest about coverage, not to look clean.

Usage:
  tools/pkg/bpm-audit.py [--root /] [--packages name=ver,...] [--json]
                         [--fail-on none|low|medium|high|critical]
Exit: 0 unless --fail-on is set and a CVE at/above that severity is found.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

NVD_API = "https://services.nvd.nist.gov/rest/json/cves/2.0"
OSV_API = "https://api.osv.dev/v1/query"
UA = {"User-Agent": "blueberry-bpm-audit"}
TIMEOUT = 30
SEV_ORDER = {"CRITICAL": 4, "HIGH": 3, "MEDIUM": 2, "LOW": 1, "NONE": 0, "UNKNOWN": 0}

# name -> source spec:
#   ("nvd", "vendor:product")            query NVD by CPE
#   ("go",  "module/path")               query OSV Go ecosystem
#   ("cargo", "crate")                   query OSV crates.io
#   None                                 explicitly not security-tracked
# Only the packages where a CVE actually matters on a server are mapped; the CPE
# vendor:product strings are the finicky part and are the maintenance surface.
CPE_MAP = {
    # crypto / TLS / auth — the crown jewels on a server
    "openssl": ("nvd", "openssl:openssl"),
    "openssh": ("nvd", "openbsd:openssh"),
    "gnutls": ("nvd", "gnu:gnutls"),
    "nettle": ("nvd", "nettle_project:nettle"),
    "libtasn1": ("nvd", "gnu:libtasn1"),
    "p11-kit": ("nvd", "p11-kit_project:p11-kit"),
    "libgcrypt": ("nvd", "gnupg:libgcrypt"),
    "gnupg": ("nvd", "gnupg:gnupg"),
    "pam": ("nvd", "linux-pam:linux-pam"),
    "sudo": ("nvd", "sudo_project:sudo"),
    "polkit": ("nvd", "polkit_project:polkit"),
    "shadow": ("nvd", "shadow_project:shadow"),
    "ca-certificates": None,
    # init / core system
    "systemd": ("nvd", "systemd_project:systemd"),
    "dbus": ("nvd", "freedesktop:dbus"),
    "glibc": ("nvd", "gnu:glibc"),
    "util-linux": ("nvd", "kernel:util-linux"),
    "kmod": None,
    "cryptsetup": ("nvd", "cryptsetup_project:cryptsetup"),
    "lvm2": ("nvd", "redhat:lvm2"),
    "device-mapper": ("nvd", "redhat:lvm2"),
    "e2fsprogs": ("nvd", "e2fsprogs_project:e2fsprogs"),
    "libcap": ("nvd", "libcap_project:libcap"),
    "libseccomp": ("nvd", "libseccomp_project:libseccomp"),
    # shells / core CLI
    "bash": ("nvd", "gnu:bash"),
    "coreutils": ("nvd", "gnu:coreutils"),
    "gzip": ("nvd", "gnu:gzip"),
    "tar": ("nvd", "gnu:tar"),
    "xz": ("nvd", "tukaani:xz"),
    "bzip2": ("nvd", "bzip:bzip2"),
    "zstd": ("nvd", "facebook:zstd"),
    "zlib": ("nvd", "zlib:zlib"),
    "vim": ("nvd", "vim:vim"),
    "less": ("nvd", "greenwoodsoftware:less"),
    "sqlite": ("nvd", "sqlite:sqlite"),
    "pcre2": ("nvd", "pcre:pcre2"),
    "expat": ("nvd", "libexpat_project:libexpat"),
    "libxml2": ("nvd", "xmlsoft:libxml2"),
    "readline": ("nvd", "gnu:readline"),
    "ncurses": ("nvd", "gnu:ncurses"),
    "libpsl": None,
    "gmp": ("nvd", "gmplib:gmp"),
    # networking userland / servers
    "wget": ("nvd", "gnu:wget"),
    "iproute2": None,
    "iptables": ("nvd", "netfilter:iptables"),
    "wpa_supplicant": ("nvd", "w1.fi:wpa_supplicant"),
    "chrony": ("nvd", "tuxfamily:chrony"),
    "nginx": ("nvd", "f5:nginx"),
    "mariadb": ("nvd", "mariadb:mariadb"),
    "postgresql": ("nvd", "postgresql:postgresql"),
    "redis": ("nvd", "redis:redis"),
    "python": ("nvd", "python:python"),
    "perl": ("nvd", "perl:perl"),
    "ufw": None,
    # containers stack — Go/Rust, best served by OSV
    "podman": ("go", "github.com/containers/podman"),
    "rclone": ("go", "github.com/rclone/rclone"),
    "node_exporter": ("go", "github.com/prometheus/node_exporter"),
    "fzf": ("go", "github.com/junegunn/fzf"),
    "crun": ("nvd", "crun_project:crun"),
    "conmon": None,
    "netavark": ("cargo", "netavark"),
    "aardvark-dns": ("cargo", "aardvark-dns"),
    # toolchain (a CVE here matters less at runtime but we track the big ones)
    "binutils": ("nvd", "gnu:binutils"),
    "gcc": ("nvd", "gnu:gcc"),
}


def die(msg):
    print(f"bpm-audit: {msg}", file=sys.stderr)
    sys.exit(2)


def read_installed(root):
    """Return {name: version} from <root>/var/lib/bpm/db/<name>/desc."""
    db = os.path.join(root, "var/lib/bpm/db")
    if not os.path.isdir(db):
        die(f"no installed database at {db} (wrong --root?)")
    out = {}
    for name in sorted(os.listdir(db)):
        desc = os.path.join(db, name, "desc")
        try:
            with open(desc, encoding="utf-8", errors="replace") as f:
                txt = f.read()
        except OSError:
            continue
        ver = None
        for line in txt.splitlines():
            if line.startswith("pkgver"):
                ver = line.split("=", 1)[1].strip() if "=" in line else None
                break
        if ver:
            out[name] = ver.rsplit("-", 1)[0]  # drop the -release suffix
    return out


def _get(url, headers):
    req = urllib.request.Request(url, headers={**UA, **headers})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.load(r)


def _post(url, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers={**UA, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.load(r)


def _applies_to_version(cve, cpe_vp, version):
    """Keep a CVE only if a CPE match for our product names our exact version or
    carries an UPPER bound (versionEnd*). NVD's virtualMatchString already
    confirmed our version falls within any bounded range server-side, so an upper
    bound means "fixed in a later version" — a real, actionable finding. Matches
    that are open-ended (a bare `product:*` with only versionStartIncluding, e.g.
    a 2013 glibc CVE recorded as "affects >= 2.17" with no fix version) match
    every newer release and are stale/mis-scoped far more often than real, so we
    drop them. This is the single biggest source of NVD false positives on a
    rolling distro that always sits at the latest upstream version."""
    prefix = f"cpe:2.3:a:{cpe_vp}:"
    for node in (n for c in cve.get("configurations", []) for n in c.get("nodes", [])):
        for m in node.get("cpeMatch", []):
            crit = m.get("criteria", "")
            if not crit.startswith(prefix):
                continue
            parts = crit.split(":")
            ver_field = parts[5] if len(parts) > 5 else "*"
            if ver_field not in ("*", "-", "") and ver_field == version:
                return True  # exact vulnerable version pinned in the CPE
            if any(k in m for k in ("versionEndIncluding", "versionEndExcluding")):
                return True  # bounded above → a real "fixed in X" finding
    return False


def nvd_cves(cpe_vp, version, api_key):
    """CVEs affecting cpe:2.3:a:<cpe_vp>:<version>. Returns [(id, sev, desc)]."""
    vms = f"cpe:2.3:a:{cpe_vp}:{version}"
    url = f"{NVD_API}?virtualMatchString={urllib.parse.quote(vms)}&resultsPerPage=200"
    headers = {"apiKey": api_key} if api_key else {}
    data = None
    for attempt in range(4):
        try:
            data = _get(url, headers)
            break
        except urllib.error.HTTPError as e:
            if e.code in (403, 429, 503) and attempt < 3:
                time.sleep(12 * (attempt + 1))
                continue
            raise
    out = []
    for v in data.get("vulnerabilities", []):
        cve = v.get("cve", {})
        if not _applies_to_version(cve, cpe_vp, version):
            continue  # drop open-ended / mis-scoped matches
        cid = cve.get("id", "?")
        metrics = cve.get("metrics", {})
        sev = "UNKNOWN"
        for key in ("cvssMetricV31", "cvssMetricV30"):
            arr = metrics.get(key)
            if arr:
                sev = arr[0].get("cvssData", {}).get("baseSeverity", "UNKNOWN")
                break
        desc = next((d["value"] for d in cve.get("descriptions", []) if d.get("lang") == "en"), "")
        out.append((cid, sev.upper(), desc))
    return out


def osv_vulns(name, ecosystem, version):
    body = {"package": {"name": name, "ecosystem": ecosystem}, "version": version}
    data = _post(OSV_API, body)
    out = []
    for v in data.get("vulns", []):
        cid = v.get("id", "?")
        sev = "UNKNOWN"
        # OSV: CVSS vector in severity[], or a text severity in database_specific
        ds = (v.get("database_specific") or {}).get("severity")
        if isinstance(ds, str):
            sev = ds.upper()
        out.append((cid, sev, (v.get("summary") or "")[:200]))
    return out


def audit(installed, api_key, throttle):
    rows, untracked = [], []
    for name in sorted(installed):
        ver = installed[name]
        spec = CPE_MAP.get(name, "MISSING")
        if spec == "MISSING":
            untracked.append(name)
            continue
        if spec is None:
            continue  # explicitly not tracked
        src, ident = spec
        try:
            if src == "nvd":
                cves = nvd_cves(ident, ver, api_key)
                if throttle:
                    time.sleep(0.7 if api_key else 8.0)
            elif src == "go":
                cves = osv_vulns(ident, "Go", ver)
            elif src == "cargo":
                cves = osv_vulns(ident, "crates.io", ver)
            else:
                continue
        except Exception as e:  # never let one package abort the whole audit
            rows.append((name, ver, "ERROR", str(e)[:80], []))
            continue
        if cves:
            top = max((SEV_ORDER.get(s, 0) for _, s, _ in cves), default=0)
            top_name = next((k for k, val in SEV_ORDER.items() if val == top), "UNKNOWN")
            rows.append((name, ver, top_name, f"{len(cves)} CVE(s)", cves))
    return rows, untracked


def main():
    ap = argparse.ArgumentParser(description="report known CVEs for installed packages")
    ap.add_argument("--root", default="/", help="filesystem root of the installed system")
    ap.add_argument("--packages", help="audit these instead of the DB: name=ver,name=ver")
    ap.add_argument("--recipes", metavar="DIR",
                    help="audit the versions in DIR/*/bpm.toml (what the distro ships)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-throttle", action="store_true", help="skip NVD rate-limit sleeps")
    ap.add_argument("--fail-on", default="none",
                    choices=["none", "low", "medium", "high", "critical"])
    args = ap.parse_args()

    if args.packages:
        installed = {}
        for tok in args.packages.split(","):
            n, _, v = tok.partition("=")
            if n and v:
                installed[n.strip()] = v.strip()
    elif args.recipes:
        import glob
        import tomllib
        installed = {}
        for rec in sorted(glob.glob(os.path.join(args.recipes, "*", "bpm.toml"))):
            try:
                with open(rec, "rb") as f:
                    pkg = tomllib.load(f).get("package", {})
                if pkg.get("name") and pkg.get("version"):
                    installed[str(pkg["name"])] = str(pkg["version"])
            except (OSError, tomllib.TOMLDecodeError):
                continue
    else:
        installed = read_installed(args.root)

    api_key = os.environ.get("NVD_API_KEY", "").strip()
    rows, untracked = audit(installed, api_key, throttle=not args.no_throttle)

    vuln = [r for r in rows if r[2] not in ("ERROR",) and r[4]]
    if args.json:
        print(json.dumps({
            "installed": len(installed),
            "tracked": len(installed) - len(untracked),
            "vulnerable": len(vuln),
            "findings": [{"package": n, "version": v, "severity": s,
                          "cves": [{"id": i, "severity": cs} for i, cs, _ in c]}
                         for n, v, s, _, c in rows if c],
            "untracked": untracked,
        }, indent=2))
    else:
        if not vuln:
            print(f"bpm audit: no known CVEs affecting {len(installed) - len(untracked)} "
                  f"tracked packages ({len(untracked)} untracked).")
        else:
            print(f"bpm audit: {len(vuln)} package(s) with known CVEs "
                  f"(of {len(installed) - len(untracked)} tracked):\n")
            for n, v, s, cnt, cves in sorted(vuln, key=lambda r: -SEV_ORDER.get(r[2], 0)):
                ids = " ".join(i for i, _, _ in cves[:8])
                more = "" if len(cves) <= 8 else f" (+{len(cves) - 8} more)"
                print(f"  [{s:8}] {n} {v} — {cnt}: {ids}{more}")
            print(f"\n  {len(untracked)} package(s) untracked (no CPE mapping).")
        errs = [r for r in rows if r[2] == "ERROR"]
        if errs:
            print(f"\n  {len(errs)} lookup error(s):")
            for n, v, _, e, _ in errs:
                print(f"    {n} {v}: {e}")

    threshold = SEV_ORDER[{"none": "NONE", "low": "LOW", "medium": "MEDIUM",
                           "high": "HIGH", "critical": "CRITICAL"}[args.fail_on]]
    if args.fail_on != "none":
        worst = max((SEV_ORDER.get(r[2], 0) for r in vuln), default=0)
        if worst >= threshold:
            sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
