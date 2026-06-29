#!/bin/sh
# changed-packages.sh — list packages/<name> whose recipe changed in a git range,
# minus a skip-list of giants that are too slow for per-push CI. Used by the
# build-check workflow to build only what changed (the full set is build-world).
# Usage: tools/changed-packages.sh <BASE_SHA> [MAX]
set -eu
BASE="${1:?usage: changed-packages.sh <base-sha> [max]}"
MAX="${2:-12}"
# Recipes whose from-source build is too heavy for a hosted runner (built by the
# weekly build-world on a self-hosted box instead).
SKIP="gcc binutils glibc llvm mesa qt6-base qt6-declarative qt6-webengine \
qt6-quick3d qt6-multimedia qt6-tools kde-frameworks linux firefox brave \
chromium thunderbird blender libreoffice nss poppler ffmpeg boost"
git diff --name-only "$BASE"...HEAD -- 'packages/*/bpm.toml' 2>/dev/null \
  | sed -n 's#^packages/\([^/]*\)/bpm.toml$#\1#p' | sort -u \
  | while read -r p; do case " $SKIP " in *" $p "*) ;; *) echo "$p" ;; esac; done \
  | head -n "$MAX"
