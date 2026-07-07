#!/bin/sh
# bpmrepo.sh — build a bpm repository index from a directory of native .bpm files.
#
# This is the repository indexer: it reads each .bpm's TOML `.BPM` manifest and
# emits the index line format bpm's parser expects, then ed25519-signs the index.
# It is the ONLY indexer — the repo is .bpm-only (the old .pkg.tar.zst mkrepo.sh
# is retired). Pointing a .pkg.tar.zst indexer at the .bpm repo writes an empty
# index and clobbers it, so always use this script.
#
# Safety guardrails (a stale/empty index is a full repo outage — it has happened):
#   * Count floor   — refuses to publish an index with 0 packages, or fewer than
#                     90% of the CURRENT index, unless BPMREPO_FORCE=1. This is
#                     what stops "indexer found nothing → empty index → outage".
#   * Backups       — snapshots the current index+sig into .index-backups/ before
#                     swapping, keeping the last 10. Rollback = restore a pair.
#   * Atomic + paired swap — signs the staged index, then moves BOTH index and
#                     sig into place, so clients never see a new index with an old
#                     (mismatched) signature.
#
# Usage: tools/pkg/bpmrepo.sh <repo-dir>
#   Env: BPMREPO_FORCE=1     bypass the count floor (first-ever index, or an
#                            intentional big shrink)
#        BPM_SIGN_KEY=<pem>  signing key (default ~/.config/bpm/repo-ed25519.pem)
#   Index line:  name|version|filename|sha256|deps|size|desc
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

# Read the .BPM TOML member of a .bpm.
bpmmeta() { zstd -dcq "$1" | tar -xO -f - .BPM 2>/dev/null \
            || zstd -dcq "$1" | tar -xO -f - ./.BPM 2>/dev/null; }
# Scalar string:  key = "value"  → value
tval() { awk -v k="$1" -F' = ' '$1==k{v=$2; gsub(/^"|"$/,"",v); print v; exit}'; }
# Int:  key = 123 → 123
tint() { awk -v k="$1" -F' = ' '$1==k{print $2; exit}'; }
# String array:  key = ["a", "b"] → a,b
tarr() { awk -v k="$1" -F' = ' '$1==k{print $2; exit}' \
         | sed 's/^\[//;s/\]$//;s/"//g;s/, */,/g;s/^ *//;s/ *$//'; }
clean() { tr '|\n' '  '; }

out="$REPO/bpm.index"
tmp="$out.tmp.$$"
trap 'rm -f "$tmp" "$tmp.sig"' EXIT INT TERM
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

# Monotonic serial (epoch seconds) — lets clients reject a rolled-back or stale
# index served by an untrusted mirror (replay/downgrade protection). Carried on
# a line the existing bpm parser IGNORES (empty name field before the first '|'),
# so it is fully backward compatible with already-deployed clients. It is part
# of the signed content, so it can't be forged. Never emitted for an empty scan.
[ "$n" -gt 0 ] && printf '|serial|%s\n' "$(date -u +%s)" >> "$tmp"

sort -o "$tmp" "$tmp"

# ── count floor: never let a broken scan clobber a healthy index ──────────────
prev=0
# Count PACKAGE lines only (exclude the |serial| line, which starts with '|').
[ -f "$out" ] && prev=$(grep -vc '^|serial|' "$out" 2>/dev/null || echo 0)
prev=${prev:-0}
if [ "$FORCE" != "1" ]; then
    if [ "$n" -eq 0 ]; then
        echo "bpmrepo: REFUSING to write an empty index (found 0 .bpm in $REPO)." >&2
        echo "bpmrepo: the current index ($prev pkgs) is left untouched." >&2
        echo "bpmrepo: if this is truly intended, re-run with BPMREPO_FORCE=1." >&2
        exit 1
    fi
    # integer 90%: refuse if new < 0.9 * prev  ⇔  10*n < 9*prev
    if [ "$prev" -gt 0 ] && [ $((10 * n)) -lt $((9 * prev)) ]; then
        echo "bpmrepo: REFUSING — new index has $n pkgs, current has $prev (>10% drop)." >&2
        echo "bpmrepo: this usually means a bad scan or missing files. Index untouched." >&2
        echo "bpmrepo: if the shrink is intentional, re-run with BPMREPO_FORCE=1." >&2
        exit 1
    fi
fi

# ── sign the STAGED index first (so index+sig always match on swap) ───────────
signed=0
if [ -f "$SIGN_KEY" ] && command -v openssl >/dev/null 2>&1; then
    openssl pkeyutl -sign -inkey "$SIGN_KEY" -rawin -in "$tmp" -out "$tmp.sig"
    signed=1
else
    echo "bpmrepo: no signing key at $SIGN_KEY — index will be UNSIGNED" >&2
fi

# ── backup current index+sig before the swap ─────────────────────────────────
if [ -f "$out" ]; then
    mkdir -p "$BACKUP_DIR"
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    cp -p "$out" "$BACKUP_DIR/bpm.index.$ts"
    [ -f "$out.sig" ] && cp -p "$out.sig" "$BACKUP_DIR/bpm.index.sig.$ts"
    # prune: keep the newest $BACKUP_KEEP index snapshots (+ their sigs)
    ls -1t "$BACKUP_DIR"/bpm.index.[0-9]* 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | while read -r old; do
        rm -f "$old" "${old%%.index.*}.index.sig.${old##*.index.}"
    done
fi

# ── atomic, paired swap ───────────────────────────────────────────────────────
[ "$signed" = 1 ] && mv "$tmp.sig" "$out.sig"
mv "$tmp" "$out"
trap - EXIT INT TERM
echo "bpmrepo: wrote $out ($n packages; previous $prev)"
[ "$signed" = 1 ] && echo "bpmrepo: signed $out.sig with $SIGN_KEY"
exit 0
