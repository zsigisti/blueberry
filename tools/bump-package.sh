#!/bin/bash
# tools/bump-package.sh — bump a BBUILD to a new (or latest) version
#
# Usage:
#   tools/bump-package.sh <name>              check upstream, bump to latest
#   tools/bump-package.sh <name> <version>   bump to a specific version
#   tools/bump-package.sh <name> --build      bump to latest, then build
#   tools/bump-package.sh <name> <ver> --build
#
# Examples:
#   tools/bump-package.sh musl                # bump musl to latest upstream
#   tools/bump-package.sh musl 1.2.7          # bump musl to exactly 1.2.7
#   tools/bump-package.sh zlib --build        # bump zlib and verify it builds

set -euo pipefail

TOPDIR="$(cd "$(dirname "$0")/.." && pwd)"
OBJDIR="${OBJDIR:-/tmp/blueberry-build}"

PKG="${1:?Usage: $0 <name> [version] [--build]}"
shift

TARGET_VERSION=""
DO_BUILD=false
for arg in "$@"; do
    case "$arg" in
        --build) DO_BUILD=true ;;
        *)       TARGET_VERSION="$arg" ;;
    esac
done

# ── Locate BBUILD ─────────────────────────────────────────────────────────────
BBUILD=""
for tier in core extra community; do
    candidate="$TOPDIR/pkgs/$tier/$PKG/BBUILD"
    [ -f "$candidate" ] && { BBUILD="$candidate"; break; }
done
[ -z "$BBUILD" ] && {
    echo "ERROR: package '$PKG' not found in pkgs/{core,extra,community}/"
    echo "  Available packages:"
    find "$TOPDIR/pkgs" -name BBUILD | sed "s|$TOPDIR/pkgs/||;s|/BBUILD||" | sort | \
        awk '{printf "    %s\n", $0}'
    exit 1
}

CURRENT=$(grep '^version=' "$BBUILD" | head -1 | cut -d= -f2)

# ── Resolve target version ────────────────────────────────────────────────────
if [ -z "$TARGET_VERSION" ]; then
    echo "Checking upstream version for $PKG (current: $CURRENT)..."
    # Delegate to check-updates.sh with single-package filter
    LATEST=$(bash "$TOPDIR/tools/check-updates.sh" "$PKG" 2>/dev/null \
             | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
             | grep -oE '→ [^ ]+$' | tail -1 | sed 's/→ //' || true)
    if [ -z "$LATEST" ]; then
        echo "Already up to date or no upstream check configured for $PKG."
        exit 0
    fi
    TARGET_VERSION="$LATEST"
fi

if [ "$TARGET_VERSION" = "$CURRENT" ]; then
    echo "$PKG is already at version $TARGET_VERSION — nothing to do."
    exit 0
fi

echo "Bumping $PKG: $CURRENT → $TARGET_VERSION"

# ── Build the new source URL from the BBUILD template ─────────────────────────
# Read first entry from source=("...")
SRC_LINE=$(grep '^source=(' "$BBUILD" | head -1 \
           | sed "s/^source=(//;s/)$//" | tr -d '"'"'" | xargs)
NEW_URL=$(printf '%s' "$SRC_LINE" \
    | sed "s/\$version/$TARGET_VERSION/g" \
    | sed "s/\${version}/$TARGET_VERSION/g" \
    | sed "s/\$name/$PKG/g" \
    | sed "s/\${name}/$PKG/g")

# ── Fetch new checksum ────────────────────────────────────────────────────────
echo "Fetching source to compute checksum..."
echo "  URL: $NEW_URL"
NEW_SHA=$(wget -q -O - "$NEW_URL" | sha256sum | cut -d' ' -f1) || {
    echo "ERROR: could not fetch $NEW_URL"
    echo "  Check the URL template in $BBUILD"
    exit 1
}
echo "  sha256: $NEW_SHA"

# ── Patch the BBUILD ──────────────────────────────────────────────────────────
OLD_SHA=$(grep -oE '[0-9a-f]{64}' "$BBUILD" | head -1 || true)

# Bump version=, reset release=1, replace checksum
sed -i \
    -e "s|^version=${CURRENT}$|version=${TARGET_VERSION}|" \
    -e 's|^release=[0-9]*$|release=1|' \
    "$BBUILD"

if [ -n "$OLD_SHA" ] && [ "$OLD_SHA" != "$NEW_SHA" ]; then
    sed -i "s|$OLD_SHA|$NEW_SHA|" "$BBUILD"
    echo "  Checksum updated: ${OLD_SHA:0:16}... → ${NEW_SHA:0:16}..."
fi

echo ""
echo "BBUILD updated:"
grep '^version=\|^release=\|^checksums=' "$BBUILD" | sed 's/^/  /'

# ── Optionally build ─────────────────────────────────────────────────────────
if $DO_BUILD; then
    echo ""
    echo "Building $PKG $TARGET_VERSION..."
    make -C "$TOPDIR" bpm OBJDIR="$OBJDIR" 2>/dev/null || true
    MUSL_SYSROOT="$OBJDIR/sysroot"
    PATH="$MUSL_SYSROOT/bin:$PATH" \
    "$OBJDIR/bpm" build \
        --output "$OBJDIR/repo" \
        --arch "${ARCH:-x86_64}" \
        --topdir "$TOPDIR" \
        "$BBUILD"
fi

echo ""
echo "Done. To build and verify:"
echo "  make pkg PKG=$PKG"
echo ""
echo "To commit:"
echo "  git add $BBUILD"
echo "  git commit -m \"chore(pkgs): update $PKG $CURRENT → $TARGET_VERSION\""
