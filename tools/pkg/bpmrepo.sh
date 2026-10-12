#!/bin/sh
# bpmrepo.sh - build and sign bpm.index from a directory of .bpm files.
#
# This is the only indexer. The repo is .bpm-only, and pointing the old
# .pkg.tar.zst mkrepo.sh at it writes an empty index over the real one.
#
# An empty or stale index takes the whole repo down (been there), so:
#   - refuses 0 packages, or fewer than 90% of the current index, unless
#     BPMREPO_FORCE=1
#   - copies the current index+sig to .index-backups/ first, keeps the last 10.
#     rolling back = put a pair back
#   - signs the staged index, then moves sig and index in together, so clients
#     never see a new index next to an old signature
#
# usage: tools/pkg/bpmrepo.sh <repo-dir>
#   BPMREPO_FORCE=1     skip the count floor (first index ever, or a real shrink)
#   BPM_SIGN_KEY=<pem>  signing key (default ~/.config/bpm/repo-ed25519.pem)
# index line: name|version|filename|sha256|deps|size|desc
set -eu
REPO="${1:-.}"
[ -d "$REPO" ] || { echo "bpmrepo: no such dir: $REPO" >&2; exit 1; }
for t in zstd tar sha256sum; do
    command -v "$t" >/dev/null 2>&1 || { echo "bpmrepo: need $t" >&2; exit 1; }
done
SIGN_KEY="${BPM_SIGN_KEY:-$HOME/.config/bpm/repo-ed25519.pem}"
FORCE="${BPMREPO_FORCE:-0}"
BACKUP_DIR="$REPO/.index-backups"
BACKUP_KEEP=10

# the .BPM manifest out of a .bpm, then tiny awk "toml" readers for it
bpmmeta() { zstd -dcq "$1" | tar -xO -f - .BPM 2>/dev/null \
            || zstd -dcq "$1" | tar -xO -f - ./.BPM 2>/dev/null; }
# key = "value" -> value
tval() { awk -v k="$1" -F' = ' '$1==k{v=$2; gsub(/^"|"$/,"",v); print v; exit}'; }
# key = 123 -> 123
tint() { awk -v k="$1" -F' = ' '$1==k{print $2; exit}'; }
# key = ["a", "b"] -> a,b
tarr() { awk -v k="$1" -F' = ' '$1==k{print $2; exit}' \
         | sed 's/^\[//;s/\]$//;s/"//g;s/, */,/g;s/^ *//;s/ *$//'; }
clean() { tr '|\n' '  '; }

out="$REPO/bpm.index"
tmp="$out.tmp.$$"
trap 'rm -f "$tmp" "$tmp.sig" "$tmp.d"' EXIT INT TERM
: > "$tmp"
n=0
for pkg in "$REPO"/*.bpm; do
    [ -f "$pkg" ] || continue
    meta=$(bpmmeta "$pkg") || { echo "bpmrepo: skip (no .BPM): $pkg" >&2; continue; }
    name=$(printf '%s\n' "$meta" | tval name)
    ver=$(printf '%s\n'  "$meta" | tval version)
    rel=$(printf '%s\n'  "$meta" | tint release)
    [ -n "$name" ] || { echo "bpmrepo: skip (no name): $pkg" >&2; continue; }
    [ -n "$rel" ] && ver="$ver-$rel"
    deps=$(printf '%s\n' "$meta" | tarr depends)
    size=$(printf '%s\n' "$meta" | tint installed_size); size=${size:-0}
    desc=$(printf '%s\n' "$meta" | tval summary | clean)
    sha=$(sha256sum "$pkg" | cut -d' ' -f1)
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
        "$name" "$ver" "$(basename "$pkg")" "$sha" "$deps" "$size" "$desc" >> "$tmp"
    n=$((n + 1))
done

# newest version per name only. bpm's index lookup takes the FIRST matching
# line, so an old .bpm left in the pool (cache / rollback) would shadow the new
# one. sort -V by name then version and keep the last per name.
if [ "$n" -gt 0 ]; then
    sort -t'|' -k1,1 -k2,2V "$tmp" \
        | awk -F'|' '{cur[$1] = $0} END {for (k in cur) print cur[k]}' \
        | sort > "$tmp.d"
    mv "$tmp.d" "$tmp"
    n=$(grep -c '' "$tmp")
fi

# serial (epoch seconds) so clients can refuse a rolled-back index from a
# sketchy mirror. it's signed like everything else, and the empty name field
# means older bpm clients just skip the line.
[ "$n" -gt 0 ] && printf '|serial|%s\n' "$(date -u +%s)" >> "$tmp"

sort -o "$tmp" "$tmp"

# count floor: a broken scan must not clobber a healthy index.
# count package lines only, not |serial|
prev=0
[ -f "$out" ] && prev=$(grep -vc '^|serial|' "$out" 2>/dev/null || echo 0)
prev=${prev:-0}
if [ "$FORCE" != "1" ]; then
    if [ "$n" -eq 0 ]; then
        echo "bpmrepo: REFUSING to write an empty index (found 0 .bpm in $REPO)." >&2
        echo "bpmrepo: the current index ($prev pkgs) is left untouched." >&2
        echo "bpmrepo: if this is truly intended, re-run with BPMREPO_FORCE=1." >&2
        exit 1
    fi
    # n < 0.9 * prev, in integers
    if [ "$prev" -gt 0 ] && [ $((10 * n)) -lt $((9 * prev)) ]; then
        echo "bpmrepo: REFUSING - new index has $n pkgs, current has $prev (>10% drop)." >&2
        echo "bpmrepo: this usually means a bad scan or missing files. Index untouched." >&2
        echo "bpmrepo: if the shrink is intentional, re-run with BPMREPO_FORCE=1." >&2
        exit 1
    fi
fi

# sign the staged file, so index and sig always match after the swap
signed=0
if [ -f "$SIGN_KEY" ] && command -v openssl >/dev/null 2>&1; then
    openssl pkeyutl -sign -inkey "$SIGN_KEY" -rawin -in "$tmp" -out "$tmp.sig"
    signed=1
else
    echo "bpmrepo: no signing key at $SIGN_KEY, index will be UNSIGNED" >&2
fi

if [ -f "$out" ]; then
    mkdir -p "$BACKUP_DIR"
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    cp -p "$out" "$BACKUP_DIR/bpm.index.$ts"
    [ -f "$out.sig" ] && cp -p "$out.sig" "$BACKUP_DIR/bpm.index.sig.$ts"
    # keep the newest $BACKUP_KEEP snapshots (and their sigs)
    ls -1t "$BACKUP_DIR"/bpm.index.[0-9]* 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | while read -r old; do
        rm -f "$old" "${old%%.index.*}.index.sig.${old##*.index.}"
    done
fi

# sig first, then the index
[ "$signed" = 1 ] && mv "$tmp.sig" "$out.sig"
mv "$tmp" "$out"
trap - EXIT INT TERM
echo "bpmrepo: wrote $out ($n packages; previous $prev)"
[ "$signed" = 1 ] && echo "bpmrepo: signed $out.sig with $SIGN_KEY"
exit 0
