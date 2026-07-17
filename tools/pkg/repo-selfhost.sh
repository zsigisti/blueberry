#!/bin/sh
# repo-selfhost.sh — rebuild the whole package set inside the Blueberry builder
# image (BASE=blueberry, zero Arch), in runtime-dependency order, so every .bpm
# the mirror serves is produced by Blueberry's own toolchain.
#
# How it stays correct, non-destructive and resumable:
#   * Seed    — any recipe with no artifact in the store is downloaded from the
#               mirror first, so every build closure is satisfiable from the start.
#   * Order   — packages build in runtime-`depends` order (deps before
#               dependents), so each links freshly self-hosted libraries.
#   * No cascade — a package's old artifact is removed just before its rebuild;
#               if that build fails, the previous artifact is restored from the
#               mirror so dependents still link and one pass surfaces every gap.
#   * Resume  — packages that build are recorded in obj/.selfhost-done and skipped
#               on the next run (FORCE=1 rebuilds everything).
#
# Rootless note: obj/bpm-out is written by the build container as a subordinate
# uid, so the host user cannot mutate it directly. All store writes (seed,
# remove, restore) run through `podman unshare`, i.e. as namespace-root.
#
# Usage: repo-selfhost.sh [pkg...]        (default: all recipes, topo-ordered)
# Env:   ENGINE=podman|docker   FORCE=1   NO_SEED=1
set -eu
TOPDIR=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$TOPDIR/obj/bpm-out"
DONE="$TOPDIR/obj/.selfhost-done"
ENGINE=${ENGINE:-podman}; export ENGINE
FETCH="$TOPDIR/tools/pkg/fetch-bpm.sh"
BUILD="$TOPDIR/tools/pkg/build-bpm-pkg.sh"
# Pinned artifacts fetched from the mirror, never rebuilt per run (libc + kernel).
EXCLUDE=" glibc linux "

mkdir -p "$OUT"
[ -n "${FORCE:-}" ] && : > "$DONE"
[ -f "$DONE" ] || : > "$DONE"

# Store mutators (namespace-root; docker owns files as the invoking user, so plain).
if [ "$ENGINE" = podman ]; then
    store() { podman unshare "$@"; }
else
    store() { "$@"; }
fi
seed()  { store env BPM_CACHE="$OUT" sh "$FETCH" "$1" - "$OUT" >/dev/null 2>&1; }
have()  { ls "$OUT/$1"-[0-9]*.bpm >/dev/null 2>&1; }

if [ $# -gt 0 ]; then
    order="$*"
else
    order=$(python3 "$TOPDIR/tools/pkg/makedep-closure.py" --topo)
fi

# 1. Seed the store from the mirror so every build closure resolves.
if [ -z "${NO_SEED:-}" ]; then
    echo "[selfhost] seeding store from mirror where missing…"
    for p in $order; do
        have "$p" && continue
        seed "$p" && echo "  seed $p" || echo "  seed $p — NOT on mirror"
    done
fi

# 2. Rebuild each package self-hosted, dependencies first.
built=0; skipped=0; failed=""
for p in $order; do
    case "$EXCLUDE" in *" $p "*) echo "[selfhost] pinned, skip: $p"; skipped=$((skipped+1)); continue;; esac
    if grep -qxF "$p" "$DONE"; then skipped=$((skipped+1)); continue; fi
    echo "======== [selfhost] $p ========"
    store rm -f "$OUT/$p"-[0-9]*.bpm            # force a fresh self-hosted build
    if BASE=blueberry sh "$BUILD" "$OUT" "$p"; then
        echo "$p" >> "$DONE"; built=$((built+1))
    else
        echo "!! [selfhost] FAILED self-hosted: $p" >&2; failed="$failed $p"
        seed "$p" || true                       # restore from mirror so dependents resolve
    fi
done

echo "[selfhost] rebuilt=$built skipped=$skipped"
if [ -n "$failed" ]; then
    echo "[selfhost] FAILED self-hosted:$failed" >&2
    exit 1
fi
echo "[selfhost] ALL packages built self-hosted (no Arch fallback)."
