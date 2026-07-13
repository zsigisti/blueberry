#!/bin/sh
# bpm-integration.sh — end-to-end lifecycle test for bpm against real .bpm files.
#
# Exercises install → upgrade → rollback → downgrade → remove plus config-file
# (backup) preservation, in a throwaway BPM_ROOT. Hermetic: it builds its own
# fixture packages with bpmbuild (local sources, no network) and asserts on the
# real on-disk state bpm leaves behind. No repo/signature is involved, so this
# needs no network and no signing key — the repo-resolution path is covered
# separately by the signed live mirror.
#
# Requires: a built bpm (src/bpm-rs/target/release/bpm or on PATH), bpmbuild,
# python3, zstd, tar, fakeroot. Exit 0 = all passed.
set -eu

TOP=$(cd "$(dirname "$0")/../.." && pwd)
BPM="${BPM_BIN:-$TOP/src/bpm-rs/target/release/bpm}"
BPMBUILD="$TOP/tools/pkg/bpmbuild"

command -v "$BPM" >/dev/null 2>&1 || [ -x "$BPM" ] || { echo "no bpm at $BPM (build it: cargo build --release)"; exit 1; }
for t in python3 zstd tar fakeroot; do
    command -v "$t" >/dev/null 2>&1 || { echo "need $t"; exit 1; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bpm-itest.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
ROOT="$WORK/root"
CACHE="$ROOT/var/lib/bpm/cache"
mkdir -p "$ROOT" "$CACHE"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

run() { BPM_ROOT="$ROOT" "$BPM" "$@"; }
dbver() { cat "$ROOT/var/lib/bpm/db/$1/desc" 2>/dev/null | sed -n 's/^pkgver = //p'; }

# ── build a fixture package: build_fixture <name> <ver> <bin-content> <conf-content>
build_fixture() {
    n="$1"; v="$2"; binc="$3"; confc="$4"
    d="$WORK/src-$n-$v"; mkdir -p "$d"
    printf '#!/bin/sh\necho "%s"\n' "$binc" > "$d/$n.sh"
    printf '%s\n' "$confc" > "$d/$n.conf"
    cat > "$d/bpm.toml" <<EOF
[package]
name     = "$n"
version  = "$v"
release  = 1
summary  = "integration fixture"
arch     = ["x86_64"]
provides = ["$n"]
backup   = ["etc/$n.conf"]

[[source]]
url = "$n.sh"
[[source]]
url = "$n.conf"

[steps]
package = '''
install -Dm755 "\$srcdir/$n.sh"   "\$pkgdir/usr/bin/$n"
install -Dm644 "\$srcdir/$n.conf" "\$pkgdir/etc/$n.conf"
'''
EOF
    python3 "$BPMBUILD" "$d" "$WORK/pkgs" >/dev/null 2>&1 \
        || { echo "fixture build failed: $n $v"; exit 1; }
    echo "$WORK/pkgs/$n-$v-1-x86_64.bpm"
}

echo "== building fixtures =="
V1=$(build_fixture itest 1.0 "itest v1" "setting=one")
V2=$(build_fixture itest 2.0 "itest v2" "setting=two")
echo "   $V1"
echo "   $V2"

echo "== install (from file) =="
run install "$V1" >/dev/null 2>&1 || true
check "installed version 1.0-1"        '[ "$(dbver itest)" = "1.0-1" ]'
check "binary present"                 '[ -f "$ROOT/usr/bin/itest" ]'
check "binary is v1"                   'grep -q "itest v1" "$ROOT/usr/bin/itest"'
check "config present"                 '[ -f "$ROOT/etc/itest.conf" ]'
check "listed as installed"            'run list 2>/dev/null | grep -q "^itest 1.0-1"'
check "marked explicit"                '[ -f "$ROOT/var/lib/bpm/db/itest/explicit" ]'

echo "== upgrade (from file) =="
run install "$V2" >/dev/null 2>&1 || true
check "upgraded to 2.0-1"              '[ "$(dbver itest)" = "2.0-1" ]'
check "binary now v2"                  'grep -q "itest v2" "$ROOT/usr/bin/itest"'
check "no stale v1 content"            '! grep -q "itest v1" "$ROOT/usr/bin/itest"'

echo "== config-file preservation (backup) =="
# User edits the tracked config, then upgrades again to a build with new default.
printf 'setting=USER_EDIT\n' > "$ROOT/etc/itest.conf"
V3=$(build_fixture itest 3.0 "itest v3" "setting=three")
run install "$V3" >/dev/null 2>&1 || true
check "upgraded to 3.0-1"              '[ "$(dbver itest)" = "3.0-1" ]'
check "user config edit preserved"     'grep -q "USER_EDIT" "$ROOT/etc/itest.conf"'
check "new default saved as .bpmnew"   '[ -f "$ROOT/etc/itest.conf.bpmnew" ] && grep -q "setting=three" "$ROOT/etc/itest.conf.bpmnew"'

echo "== rollback (cache) =="
# rollback/downgrade read the cache; seed it with the fetched artifacts.
cp "$V1" "$V2" "$V3" "$CACHE/"
run rollback itest >/dev/null 2>&1 || true
check "rolled back 3.0 -> 2.0"         '[ "$(dbver itest)" = "2.0-1" ]'
check "binary back to v2"              'grep -q "itest v2" "$ROOT/usr/bin/itest"'

echo "== downgrade to exact version (cache) =="
# version is the full ver-rel (cache::exact matches on version AND release).
run downgrade itest=1.0-1 >/dev/null 2>&1 || true
check "downgraded to 1.0-1"            '[ "$(dbver itest)" = "1.0-1" ]'
check "binary back to v1"              'grep -q "itest v1" "$ROOT/usr/bin/itest"'

echo "== downgrade to missing version fails cleanly =="
check "rejects uncached version"       '! run downgrade itest=9.9-1 >/dev/null 2>&1'
check "still at 1.0-1 after failure"   '[ "$(dbver itest)" = "1.0-1" ]'

echo "== remove =="
run remove itest >/dev/null 2>&1 || true
check "no longer installed"            '! run list 2>/dev/null | grep -q "^itest "'
check "binary removed"                 '[ ! -f "$ROOT/usr/bin/itest" ]'
check "db entry gone"                  '[ ! -d "$ROOT/var/lib/bpm/db/itest" ]'

echo
echo "bpm integration: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
