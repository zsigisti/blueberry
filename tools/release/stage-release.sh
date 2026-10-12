#!/bin/bash
# usage: tools/release/stage-release.sh v0.5.2-beta ["Release title"]
#
# GitHub release with iso/*.iso attached (assets go up to 2 GB). ISOs never go
# on the mirror - that's only .bpm packages and the pinned kernel/glibc.
# Body is release/NOTES.md, -beta/-rc/-alpha tags become pre-releases.
# Needs a logged-in gh and the ISOs built (make iso server-iso).
set -euo pipefail

cd "$(dirname "$0")/../.."

TAG=${1:?usage: stage-release.sh <tag> [title]   e.g. v0.5.2-beta}
TITLE=${2:-$TAG}

command -v gh >/dev/null 2>&1 || { echo "stage-release: gh CLI required (and authenticated)"; exit 1; }
[ -f release/NOTES.md ] || { echo "stage-release: release/NOTES.md missing, write the notes first"; exit 1; }

# the desktop edition is dead, don't ship leftover images of it
isos=()
for f in iso/*.iso; do
    case "$f" in *desktop*) continue ;; esac
    [ -e "$f" ] && isos+=("$f")
done
[ "${#isos[@]}" -gt 0 ] || { echo "stage-release: no server ISOs in iso/, build them first (make iso server-iso)"; exit 1; }

pre=""
case "$TAG" in *-beta*|*-rc*|*-alpha*) pre="--prerelease" ;; esac

echo "==> creating GitHub release $TAG with ${#isos[@]} ISO(s) attached directly:"
for f in "${isos[@]}"; do echo "      $(basename "$f")  ($(du -h "$f" | cut -f1))"; done

# wipe a half-made release/tag from an earlier attempt
gh release delete "$TAG" --yes --cleanup-tag 2>/dev/null || true
gh release create "$TAG" "${isos[@]}" \
    --title "$TITLE" --notes-file release/NOTES.md --target master $pre

echo "==> released: $(gh release view "$TAG" --json url -q .url 2>/dev/null)"
