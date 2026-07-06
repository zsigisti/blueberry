#!/bin/bash
# stage-release.sh — cut a GitHub release for the current iso/ images.
#
# ISOs are attached DIRECTLY to the GitHub release (assets support up to 2 GB
# each) — they are NEVER uploaded to the project mirror. The mirror carries only
# .bpm packages + the pinned kernel/glibc. (This replaced an older flow that
# scp'd the ISOs to <mirror>/isos/ and had CI fetch them back.)
#
# Usage:  tools/release/stage-release.sh v0.5.2-beta ["Release title"]
#   - attaches every non-desktop iso/*.iso to the release
#   - uses release/NOTES.md as the body (edit it first)
#   - marks the release a pre-release when the tag has -beta/-rc/-alpha
#
# Requires: gh (authenticated), and the ISOs already built (make iso server-iso).
set -euo pipefail

cd "$(dirname "$0")/../.."

TAG=${1:?usage: stage-release.sh <tag> [title]   e.g. v0.5.2-beta}
TITLE=${2:-$TAG}

command -v gh >/dev/null 2>&1 || { echo "stage-release: gh CLI required (and authenticated)"; exit 1; }
[ -f release/NOTES.md ] || { echo "stage-release: release/NOTES.md missing — write the notes first"; exit 1; }

# Server-only: never ship stray desktop images (the desktop edition is gone).
isos=()
for f in iso/*.iso; do
    case "$f" in *desktop*) continue ;; esac
    [ -e "$f" ] && isos+=("$f")
done
[ "${#isos[@]}" -gt 0 ] || { echo "stage-release: no server ISOs in iso/ — build them first (make iso server-iso)"; exit 1; }

# Pre-release unless the tag is a plain final version.
pre=""
case "$TAG" in *-beta*|*-rc*|*-alpha*) pre="--prerelease" ;; esac

echo "==> creating GitHub release $TAG with ${#isos[@]} ISO(s) attached directly:"
for f in "${isos[@]}"; do echo "      $(basename "$f")  ($(du -h "$f" | cut -f1))"; done

# Recreate cleanly if a partial release/tag already exists.
gh release delete "$TAG" --yes --cleanup-tag 2>/dev/null || true
gh release create "$TAG" "${isos[@]}" \
    --title "$TITLE" --notes-file release/NOTES.md --target master $pre

echo "==> released: $(gh release view "$TAG" --json url -q .url 2>/dev/null)"
