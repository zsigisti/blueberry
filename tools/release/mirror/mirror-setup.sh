#!/bin/sh
# mirror-setup.sh — turn a fresh box into a Blueberry bpm mirror.
#
# Installs the sync script + systemd timer that pull a read-only replica from the
# origin, drops in the nginx vhost with the correct cache policy, does a first
# sync, and (optionally) enables the timer. Run as root ON THE MIRROR.
#
# Usage:
#   ORIGIN_RSYNC=rsync://<origin>/blueberry-repo sh mirror-setup.sh [--enable]
#
# Env:
#   ORIGIN_RSYNC   rsync source on the origin (required)
#   REPO_DIR       where to store the replica (default /srv/blueberry-repo)
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=${REPO_DIR:-/srv/blueberry-repo}
ENABLE=0
[ "${1:-}" = "--enable" ] && ENABLE=1

[ "$(id -u)" = 0 ] || { echo "mirror-setup: run as root" >&2; exit 1; }
: "${ORIGIN_RSYNC:?set ORIGIN_RSYNC=rsync://<origin>/blueberry-repo}"
for t in rsync nginx; do
    command -v "$t" >/dev/null 2>&1 || echo "mirror-setup: WARNING '$t' not found — install it" >&2
done

echo "==> installing sync script -> /usr/local/bin/blueberry-mirror-sync"
install -Dm755 "$HERE/mirror-sync.sh" /usr/local/bin/blueberry-mirror-sync

echo "==> writing /etc/default/blueberry-mirror"
mkdir -p /etc/default
printf 'ORIGIN_RSYNC=%s\nREPO_DIR=%s\n' "$ORIGIN_RSYNC" "$REPO_DIR" > /etc/default/blueberry-mirror

echo "==> installing systemd units"
install -Dm644 "$HERE/blueberry-mirror-sync.service" /etc/systemd/system/blueberry-mirror-sync.service
install -Dm644 "$HERE/blueberry-mirror-sync.timer"   /etc/systemd/system/blueberry-mirror-sync.timer
systemctl daemon-reload

echo "==> installing nginx vhost (edit server_name / add TLS as needed)"
install -Dm644 "$HERE/nginx-repo.conf" /etc/nginx/sites-available/blueberry-repo
ln -sf /etc/nginx/sites-available/blueberry-repo /etc/nginx/sites-enabled/blueberry-repo 2>/dev/null || true

echo "==> initial sync"
mkdir -p "$REPO_DIR"
ORIGIN_RSYNC="$ORIGIN_RSYNC" REPO_DIR="$REPO_DIR" /usr/local/bin/blueberry-mirror-sync

if [ "$ENABLE" -eq 1 ]; then
    echo "==> enabling timer + reloading nginx"
    systemctl enable --now blueberry-mirror-sync.timer
    nginx -t && systemctl reload nginx || echo "mirror-setup: check nginx config manually"
else
    echo "==> done (dry run). To go live:"
    echo "    systemctl enable --now blueberry-mirror-sync.timer"
    echo "    nginx -t && systemctl reload nginx"
fi
