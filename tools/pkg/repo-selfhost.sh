#!/bin/sh
# repo-selfhost.sh - rebuild every package inside the Blueberry builder image
# (BASE=blueberry, no Arch at all), deps first, so everything the mirror serves
# was built by Blueberry's own toolchain.
#
#   seed     recipes with nothing in the store get pulled from the mirror
#            first, so every build closure resolves from the start
#   order    makedep-closure.py --topo, deps before dependents
#   no cascade  the old artifact is stashed before a rebuild and put back if
#            the build fails, so dependents still link and one pass shows
#            every broken package
#   resume   finished packages go in obj/.selfhost-done and get skipped next
#            run (FORCE=1 starts over)
#
# usage: repo-selfhost.sh [pkg...]        (default: all recipes, topo order)
# env:   ENGINE=podman|docker   FORCE=1   NO_SEED=1
set -eu
TOPDIR=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$TOPDIR/obj/bpm-out"
DONE="$TOPDIR/obj/.selfhost-done"
ENGINE=${ENGINE:-podman}; export ENGINE
FETCH="$TOPDIR/tools/pkg/fetch-bpm.sh"
BUILD="$TOPDIR/tools/pkg/build-bpm-pkg.sh"
# pinned, always from the mirror, never rebuilt here
EXCLUDE=" glibc linux "

mkdir -p "$OUT"
[ -n "${FORCE:-}" ] && : > "$DONE"
[ -f "$DONE" ] || : > "$DONE"

# rootless podman writes obj/bpm-out as a subordinate uid we can't touch from
# the host, so every store write goes through `podman unshare`. rootful podman
# (the repo server) and docker write as the real user, and podman unshare
# refuses to run rootful anyway, so there it's a plain passthrough.
if [ "$ENGINE" = podman ] && \
   [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = true ]; then
    store() { podman unshare "$@"; }
else
    store() { "$@"; }
fi
seed()  { store env BPM_CACHE="$OUT" sh "$FETCH" "$1" - "$OUT" >/dev/null 2>&1; }
have()  { ls "$OUT/$1"-[0-9]*.bpm >/dev/null 2>&1; }
BAK="$TOPDIR/obj/.selfhost-bak"   # sibling of the store, not inside it
store mkdir -p "$BAK"
# stash the current artifact before rebuilding and restore it locally if the
# build fails, don't count on the mirror having it. the toolchain SCC builds
# itself, lose one member and you can't rebuild the rest.
stash()   { store sh -c "mv -f '$OUT/$1'-[0-9]*.bpm '$BAK/' 2>/dev/null || true"; }
unstash() { store sh -c "mv -f '$BAK/$1'-[0-9]*.bpm '$OUT/' 2>/dev/null || true"; }
dropbak() { store sh -c "rm -f '$BAK/$1'-[0-9]*.bpm 2>/dev/null || true"; }

if [ $# -gt 0 ]; then
    order="$*"
else
    order=$(python3 "$TOPDIR/tools/pkg/makedep-closure.py" --topo)
fi

if [ -z "${NO_SEED:-}" ]; then
    echo "[selfhost] seeding store from mirror where missing..."
    for p in $order; do
        have "$p" && continue
        seed "$p" && echo "  seed $p" || echo "  seed $p - NOT on mirror"
    done
fi

built=0; skipped=0; failed=""
for p in $order; do
    case "$EXCLUDE" in *" $p "*) echo "[selfhost] pinned, skip: $p"; skipped=$((skipped+1)); continue;; esac
    if grep -qxF "$p" "$DONE"; then skipped=$((skipped+1)); continue; fi
    echo "======== [selfhost] $p ========"
    stash "$p"
    if BASE=blueberry sh "$BUILD" "$OUT" "$p"; then
        echo "$p" >> "$DONE"; built=$((built+1)); dropbak "$p"
    else
        echo "!! [selfhost] FAILED self-hosted: $p" >&2; failed="$failed $p"
        unstash "$p"
        have "$p" || seed "$p" || true          # nothing stashed? try the mirror
    fi
done

echo "[selfhost] rebuilt=$built skipped=$skipped"
if [ -n "$failed" ]; then
    echo "[selfhost] FAILED self-hosted:$failed" >&2
    exit 1
fi
echo "[selfhost] ALL packages built self-hosted (no Arch fallback)."
