#!/bin/sh
# Push .bpm packages to the mirror. Use this, not scp by hand - it's the only
# way the guardrails actually run:
#   1. scp the files to the origin repo dir
#   2. re-index on the server with /root/bpmrepo.sh (refuses if the package
#      count drops, keeps a timestamped backup, swaps index + sig together)
#   3. read the index back through Cloudflare and complain if it looks wrong
# ISOs don't go here (GitHub release), and mkrepo.sh is retired - don't.
#
# usage:
#   tools/release/repo-publish.sh path/to/*.bpm
#   tools/release/repo-publish.sh --reindex       # no upload, just re-index
#
# env: REPO_HOST (root@192.168.0.79), REPO_DIR (/srv/blueberry-repo),
#      MIRROR (https://repo.blueberrylinux.org), SSH_PASS (for SSH_ASKPASS;
#      the dev host has no sshpass)
set -eu

REPO_HOST=${REPO_HOST:-root@192.168.0.79}
REPO_DIR=${REPO_DIR:-/srv/blueberry-repo}
MIRROR=${MIRROR:-https://repo.blueberrylinux.org}

ASKPASS=""
if [ -n "${SSH_PASS:-}" ]; then
    ASKPASS=$(mktemp)
    printf '#!/bin/sh\necho %s\n' "$SSH_PASS" > "$ASKPASS"
    chmod +x "$ASKPASS"
    trap 'rm -f "$ASKPASS"' EXIT
fi
_ssh() {
    if [ -n "$ASKPASS" ]; then
        SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force setsid -w ssh -o StrictHostKeyChecking=accept-new "$@"
    else
        ssh -o StrictHostKeyChecking=accept-new "$@"
    fi
}
_scp() {
    if [ -n "$ASKPASS" ]; then
        SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force setsid -w scp -o StrictHostKeyChecking=accept-new "$@"
    else
        scp -o StrictHostKeyChecking=accept-new "$@"
    fi
}

reindex_only=0
[ "${1:-}" = "--reindex" ] && { reindex_only=1; shift; }

if [ "$reindex_only" -eq 0 ]; then
    [ "$#" -gt 0 ] || { echo "repo-publish: no .bpm files given (or use --reindex)"; exit 1; }
    for f in "$@"; do
        case "$f" in *.bpm) ;; *) echo "repo-publish: not a .bpm: $f" >&2; exit 1 ;; esac
        [ -f "$f" ] || { echo "repo-publish: no such file: $f" >&2; exit 1; }
    done
    echo "==> uploading $# package(s) to $REPO_HOST:$REPO_DIR"
    _scp "$@" "$REPO_HOST:$REPO_DIR/"
fi

echo "==> re-indexing remotely (hardened /root/bpmrepo.sh)"
_ssh "$REPO_HOST" "sh /root/bpmrepo.sh $REPO_DIR"

echo "==> validating over Cloudflare ($MIRROR)"
# don't count the |serial| rollback-guard line
served=$(curl -fsSL -H 'Cache-Control: no-cache' "$MIRROR/bpm.index" | grep -vc '^|serial|' || echo 0)
echo "    served index: $served packages"
[ "$served" -gt 0 ] || { echo "repo-publish: served index is EMPTY, check the mirror!" >&2; exit 1; }
if [ "$reindex_only" -eq 0 ]; then
    for f in "$@"; do
        name=$(basename "$f"); name=${name%%-[0-9]*}
        curl -fsSL -H 'Cache-Control: no-cache' "$MIRROR/bpm.index" \
            | awk -F'|' -v p="$name" '$1==p{ok=1} END{exit !ok}' \
            || echo "repo-publish: WARNING '$name' not visible in served index yet (cache?)" >&2
    done
fi
echo "==> published."
