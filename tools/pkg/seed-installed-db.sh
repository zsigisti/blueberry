#!/bin/sh
# seed-installed-db.sh - register something built straight into the image (bpm
# itself) in the bpm database, so `bpm list` / `bpm upgrade` know about it.
# Writes the usual db/<name>/{desc,files}; version, release and summary come
# from the recipe so it matches the published .bpm.
#
# usage: seed-installed-db.sh <stagedir> <recipe.toml> <owned-path>...
set -eu
STAGE=${1:?usage: seed-installed-db.sh <stagedir> <recipe.toml> <owned-path>...}
REC=${2:?missing recipe.toml}
shift 2
[ -f "$REC" ] || { echo "seed-installed-db: no $REC" >&2; exit 1; }

name=$(awk -F'"' '/^name[[:space:]]*=/{print $2; exit}' "$REC")
ver=$(awk -F'"' '/^version[[:space:]]*=/{print $2; exit}' "$REC")
rel=$(awk -F'=' '/^release[[:space:]]*=/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$REC")
sum=$(awk -F'"' '/^summary[[:space:]]*=/{print $2; exit}' "$REC")
[ -n "$name" ] && [ -n "$ver" ] && [ -n "$rel" ] || { echo "seed-installed-db: bad recipe $REC" >&2; exit 1; }

DB="$STAGE/var/lib/bpm/db/$name"
mkdir -p "$DB"
{
    printf 'pkgname = %s\n' "$name"
    printf 'pkgver = %s-%s\n' "$ver" "$rel"
    printf 'pkgdesc = %s\n' "$sum"
} > "$DB/desc"
: > "$DB/files"
for f in "$@"; do printf '%s\n' "$f" >> "$DB/files"; done

echo "[seed-installed-db] registered $name $ver-$rel"
