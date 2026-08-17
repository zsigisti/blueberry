#!/bin/sh
# Check the image has exactly one glibc, and that it's the one bpm recorded.
#
# The stage rootfs isn't wiped between builds, so an old libc can stick around.
# The 2026-08-16 server ISO had the packaged 2.44 in /lib64 and a leftover 2.43
# in /usr/lib from July. It booted fine because the loader hits /lib64 first,
# which is why nobody noticed for a month.
#
# usage: check-libc-single.sh <rootdir>
# exit:  0 ok, 1 duplicate or mismatch, 2 usage
set -eu
ROOT=${1:?usage: check-libc-single.sh <rootdir>}
[ -d "$ROOT" ] || { echo "check-libc-single: no such rootdir: $ROOT" >&2; exit 2; }

# real files only; symlinks to the same libc aren't duplicates
libcs=$(find "$ROOT" -name 'libc.so.6' -type f 2>/dev/null | sort)
[ -n "$libcs" ] || { echo "check-libc-single: FAIL - no libc.so.6 in $ROOT" >&2; exit 1; }

# ask the binary, not the path: glibc embeds its own release string
report=""
versions=""
for f in $libcs; do
    v=$(strings "$f" 2>/dev/null | sed -n 's/^GNU C Library.*stable release version \([0-9.]*\)\.$/\1/p' | head -1)
    [ -n "$v" ] || v="unknown"
    report="$report  ${f#"$ROOT"}  ->  $v
"
    versions="$versions $v"
done
uniq_versions=$(printf '%s\n' $versions | sort -u | tr '\n' ' ' | sed 's/ $//')

db="$ROOT/var/lib/bpm/db/glibc/desc"
dbver=""
[ -f "$db" ] && dbver=$(sed -n 's/^pkgver *= *\([0-9.]*\).*/\1/p' "$db" | head -1)

rc=0
case "$uniq_versions" in
    *" "*)
        echo "check-libc-single: FAIL - image has more than one glibc:" >&2
        printf '%s' "$report" >&2
        echo "  stale libc left in the stage rootfs. Remove it, or rebuild from" >&2
        echo "  a clean \$(OBJDIR)/rootfs." >&2
        rc=1 ;;
esac
if [ -n "$dbver" ] && [ "$uniq_versions" != "$dbver" ] && [ "$rc" = 0 ]; then
    echo "check-libc-single: FAIL - image libc is $uniq_versions, bpm db says $dbver" >&2
    printf '%s' "$report" >&2
    rc=1
fi
[ "$rc" = 0 ] && echo "check-libc-single: ok, one glibc ($uniq_versions), matches bpm db"
exit $rc
