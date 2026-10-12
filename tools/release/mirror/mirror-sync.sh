#!/bin/sh
# Pull the repo from the origin. Clients verify everything themselves, so a
# mirror holds no secrets and needs no push access - it's just rsync.
#
# Three passes, because a client hitting us mid-sync must never get an index
# naming a .bpm we don't have yet, or lose a package its index still names:
#   1. new packages, no index, no --delete (old index still matches)
#   2. index + sig
#   3. --delete whatever the new index dropped
#
# env: ORIGIN_RSYNC (rsync://repo-origin.blueberrylinux.org/blueberry-repo),
#      REPO_DIR (/srv/blueberry-repo)
set -eu

ORIGIN_RSYNC=${ORIGIN_RSYNC:-rsync://repo-origin.blueberrylinux.org/blueberry-repo}
REPO_DIR=${REPO_DIR:-/srv/blueberry-repo}

command -v rsync >/dev/null 2>&1 || { echo "mirror-sync: need rsync" >&2; exit 1; }
mkdir -p "$REPO_DIR"

NOTIDX="--exclude=bpm.index --exclude=bpm.index.sig --exclude=.index-backups/ --exclude=*.tmp.*"

# 1
# shellcheck disable=SC2086
rsync -rtO --info=stats1 $NOTIDX "$ORIGIN_RSYNC/" "$REPO_DIR/"

# 2
rsync -rtO --info=stats1 \
    --include=bpm.index --include=bpm.index.sig --exclude='*' \
    "$ORIGIN_RSYNC/" "$REPO_DIR/"

# 3
# shellcheck disable=SC2086
rsync -rtO --info=stats1 --delete $NOTIDX "$ORIGIN_RSYNC/" "$REPO_DIR/"

n=$(grep -c '' "$REPO_DIR/bpm.index" 2>/dev/null || echo 0)
echo "mirror-sync: replica up to date ($n packages) from $ORIGIN_RSYNC"
