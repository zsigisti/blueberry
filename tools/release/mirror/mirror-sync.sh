#!/bin/sh
# mirror-sync.sh — pull a full replica of the Blueberry bpm repo from the origin.
#
# Mirrors are UNTRUSTED file servers: the index is ed25519-signed and every
# package is sha256-verified by the client, so a mirror only has to serve bytes.
# That makes replication a plain rsync pull — no secrets on the mirror, no push
# access to the origin.
#
# Ordering matters: a client syncing against this mirror mid-transfer must never
# see an index that references a .bpm not present yet, nor have a package it
# still needs deleted out from under it. So we sync in THREE phases:
#   1. ADD packages   — everything except the index/sig, NO --delete (new .bpm
#                        land; old ones stay; the still-old index is valid).
#   2. SWAP the index  — index+sig only (now every package it names is present).
#   3. PRUNE packages  — --delete stale .bpm the *new* index no longer names.
#
# Usage:  mirror-sync.sh
# Env:
#   ORIGIN_RSYNC   rsync source   (default rsync://repo-origin.blueberrylinux.org/blueberry-repo)
#   REPO_DIR       local repo dir (default /srv/blueberry-repo)
set -eu

ORIGIN_RSYNC=${ORIGIN_RSYNC:-rsync://repo-origin.blueberrylinux.org/blueberry-repo}
REPO_DIR=${REPO_DIR:-/srv/blueberry-repo}

command -v rsync >/dev/null 2>&1 || { echo "mirror-sync: need rsync" >&2; exit 1; }
mkdir -p "$REPO_DIR"

NOTIDX="--exclude=bpm.index --exclude=bpm.index.sig --exclude=.index-backups/ --exclude=*.tmp.*"

# 1. ADD packages (no delete) — new .bpm arrive, old index still consistent.
# shellcheck disable=SC2086
rsync -rtO --info=stats1 $NOTIDX "$ORIGIN_RSYNC/" "$REPO_DIR/"

# 2. SWAP the index + signature only (include just those two, exclude the rest).
rsync -rtO --info=stats1 \
    --include=bpm.index --include=bpm.index.sig --exclude='*' \
    "$ORIGIN_RSYNC/" "$REPO_DIR/"

# 3. PRUNE packages the new index dropped (safe now: nothing references them).
# shellcheck disable=SC2086
rsync -rtO --info=stats1 --delete $NOTIDX "$ORIGIN_RSYNC/" "$REPO_DIR/"

n=$(grep -c '' "$REPO_DIR/bpm.index" 2>/dev/null || echo 0)
echo "mirror-sync: replica up to date ($n packages) from $ORIGIN_RSYNC"
