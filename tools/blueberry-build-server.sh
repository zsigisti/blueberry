#!/bin/sh
# blueberry-build-server.sh — one command to run on the Rocky build host.
#
# Pulls the recipes (PKGBUILDs live in the git repo), then builds anything that
# isn't already built and publishes the signed repo. Incremental: a package is
# (re)built only when its packages/<name>/ contents change — everything else is
# served straight from the build cache. So this is safe to run on a cron/timer
# or by hand; adding one recipe builds one package.
#
# Typical use on Rocky:
#   blueberry-build-server.sh                 # update recipes, build all missing
#   blueberry-build-server.sh nano vim        # just these
#   PULL=0 blueberry-build-server.sh          # use the local checkout as-is
#                                             # (edit PKGBUILDs, build, repeat)
#
# Env:
#   REPO     path to the blueberry checkout         (default /opt/blueberry)
#   GIT_URL  clone URL used if REPO is missing       (default the GitHub origin)
#   BRANCH   git branch to track                     (default master)
#   PULL     1 = git fetch+reset before building     (default 1; 0 = local only)
#   WEBROOT / CACHE / IMAGE / JOBS
#            passed straight through to blueberry-repo-sync.sh
#
# Requires on the host: git and podman (or docker). Integrity is the per-package
# sha256 in the index; the index is served over TLS. No signing keys needed.
set -eu

REPO=${REPO:-/opt/blueberry}
GIT_URL=${GIT_URL:-https://github.com/zsigisti/blueberry.git}
BRANCH=${BRANCH:-master}
PULL=${PULL:-1}

log() { printf '==> %s\n' "$*"; }

# 1. Recipes: clone the checkout if missing, otherwise fast-forward to origin.
if [ ! -d "$REPO/.git" ]; then
    log "cloning $GIT_URL -> $REPO"
    git clone "$GIT_URL" "$REPO"
elif [ "$PULL" = 1 ]; then
    log "updating recipes in $REPO ($BRANCH)"
    git -C "$REPO" fetch --quiet origin "$BRANCH"
    git -C "$REPO" checkout --quiet "$BRANCH"
    git -C "$REPO" reset --hard --quiet "origin/$BRANCH"
else
    log "using local checkout $REPO as-is (PULL=0)"
fi

# 2. Build whatever changed/missing and publish the signed repo. repo-sync is
#    the engine: content-hash cache, build in an ephemeral container, prune
#    superseded artifacts, regenerate + sign bpm.index.
log "building + publishing"
exec sh "$REPO/tools/blueberry-repo-sync.sh" "$@"
