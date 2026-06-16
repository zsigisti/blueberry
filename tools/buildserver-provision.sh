#!/bin/sh
# buildserver-provision.sh — turn a fresh Ubuntu 22.04 box into a Blueberry
# build server. Run it as root INSIDE the container (a Proxmox LXC works well;
# see doc/BUILDSERVER.md for creating one).
#
# It installs podman + nginx + git, clones the repo once, serves the repo over
# HTTP, and schedules periodic builds. Builds run in an ephemeral Arch container
# (podman) via tools/blueberry-build-server.sh -> blueberry-repo-sync.sh, which
# is incremental: only changed recipes rebuild.
#
# Env (all optional):
#   REPO      checkout path                 (default /opt/blueberry)
#   GIT_URL   clone URL                      (default the GitHub origin)
#   BRANCH    branch to track               (default master)
#   WEBROOT   nginx docroot = published repo (default /srv/blueberry-repo)
#   INTERVAL  systemd timer cadence          (default 1h)
#   PORT      nginx listen port              (default 80)
set -eu

REPO=${REPO:-/opt/blueberry}
GIT_URL=${GIT_URL:-https://github.com/zsigisti/blueberry.git}
BRANCH=${BRANCH:-master}
WEBROOT=${WEBROOT:-/srv/blueberry-repo}
INTERVAL=${INTERVAL:-1h}
PORT=${PORT:-80}

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

log "installing podman, nginx, git"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    podman git nginx zstd ca-certificates \
    uidmap fuse-overlayfs slirp4netns >/dev/null

log "cloning recipes -> $REPO (single clone; later runs git-pull)"
mkdir -p "$WEBROOT"
[ -d "$REPO/.git" ] || git clone --depth 1 -b "$BRANCH" "$GIT_URL" "$REPO"

log "configuring nginx to serve $WEBROOT on :$PORT"
cat > /etc/nginx/sites-available/blueberry-repo <<EOF
# Blueberry bpm repo. Put TLS in front (Cloudflare / a reverse proxy); bpm
# verifies each package by SHA-256 from the index, which is fetched over TLS.
server {
    listen $PORT default_server;
    listen [::]:$PORT default_server;
    server_name _;
    root $WEBROOT;
    autoindex on;
    default_type application/octet-stream;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
ln -sf /etc/nginx/sites-available/blueberry-repo /etc/nginx/sites-enabled/blueberry-repo
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx >/dev/null 2>&1 || true
systemctl reload nginx || systemctl restart nginx

log "installing build service + ${INTERVAL} timer"
cat > /etc/systemd/system/blueberry-build.service <<EOF
[Unit]
Description=Blueberry repo build + publish
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=REPO=$REPO BRANCH=$BRANCH WEBROOT=$WEBROOT
ExecStart=/bin/sh $REPO/tools/blueberry-build-server.sh
TimeoutStartSec=0
EOF
cat > /etc/systemd/system/blueberry-build.timer <<EOF
[Unit]
Description=Build the Blueberry repo periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=$INTERVAL
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now blueberry-build.timer

log "running the first build now (this pulls the Arch build image once)"
REPO=$REPO BRANCH=$BRANCH WEBROOT=$WEBROOT sh "$REPO/tools/blueberry-build-server.sh" || {
    echo "first build failed — check 'journalctl -u blueberry-build' / podman nesting (see doc/BUILDSERVER.md)" >&2
    exit 1
}

cat <<EOF

==> Build server ready.
    Repo recipes : $REPO   (git pull each run)
    Published at : $WEBROOT  (served by nginx on :$PORT)
    Rebuilds     : every $INTERVAL (systemd timer 'blueberry-build.timer')

    Point your DNS/Cloudflare at this host and set the client repo to its URL:
      core https://repo.mmzsigmond.me        # /etc/bpm/repos.conf

    Build now:        systemctl start blueberry-build.service
    Watch a build:    journalctl -fu blueberry-build
    Build one pkg:    REPO=$REPO sh $REPO/tools/blueberry-build-server.sh nano
EOF
