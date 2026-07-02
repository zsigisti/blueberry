#!/bin/bash
# stage-release.sh — stage the current iso/ images for a GitHub release.
#
# GitHub can't hold multi-GB files in git, so the images live on the project
# mirror and only a sha256 manifest is committed; .github/workflows/release.yml
# fetches + verifies them from there when a [RELEASE] commit lands on master.
#
# Usage:  tools/stage-release.sh [user@host:/srv/blueberry-repo]
#   1. uploads iso/*.iso to <mirror>/isos/
#   2. writes release/isos.sha256 (the manifest CI verifies against)
#   3. seeds release/NOTES.md if absent (edit it — it becomes the release body)
# Then:   git add release/ && git commit -m "[RELEASE] v0.1.0-beta — …" && git push
set -euo pipefail

DEST=${1:-root@192.168.0.79:/srv/blueberry-repo}
cd "$(dirname "$0")/.."

# Server-only: never stage stray desktop images (the desktop edition is gone).
isos=()
for f in iso/*.iso; do
    case "$f" in *desktop*) continue ;; esac
    [ -e "$f" ] && isos+=("$f")
done
[ "${#isos[@]}" -gt 0 ] || { echo "no server ISOs in iso/ — build them first (make iso)"; exit 1; }

mkdir -p release
: > release/isos.sha256
for f in "${isos[@]}"; do
    echo "==> checksumming $(basename "$f")"
    (cd iso && sha256sum "$(basename "$f")") >> release/isos.sha256
done

echo "==> uploading ${#isos[@]} image(s) to $DEST/isos/"
ssh "${DEST%%:*}" "mkdir -p ${DEST#*:}/isos"
scp "${isos[@]}" "$DEST/isos/"

if [ ! -f release/NOTES.md ]; then
    cat > release/NOTES.md <<'EOF'
## Blueberry Linux — beta release

First public beta. Images (BIOS + UEFI, all boot into the TUI installer):

| image | what it is |
|---|---|
| `blueberry-<date>-x86_64.iso` | Server (rolling CLI) |
| `blueberry-desktop-<ver>-kde-x86_64.iso` | Desktop, offline install |
| `blueberry-desktop-<ver>-kde-netinstall-x86_64.iso` | Desktop, netinstall |

Write to a USB stick: `dd if=<iso> of=/dev/sdX bs=4M oflag=sync`

This is a **beta**: expect rough edges, report what you find.
EOF
    echo "==> seeded release/NOTES.md — edit it before committing"
fi

echo
echo "Staged. Now:"
echo "  \$EDITOR release/NOTES.md"
echo "  git add release/ && git commit -m '[RELEASE] v0.1.0-beta — first beta' && git push"
