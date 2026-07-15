#!/bin/sh
# service-smoke.sh — does each server service actually RUN, not just install?
#
# test-install proves the box boots; this proves the *software works*. For each
# server package it builds the Blueberry .bpm, extracts it into an ephemeral
# container, starts the daemon, and probes it with a real client (redis PING,
# an HTTP GET from nginx, a SQL SELECT from postgres, …). Catches the whole
# "it installed but doesn't run / doesn't serve / was built without a feature"
# class that a boot test can't see.
#
# The Blueberry-built binaries run against the build container's shared libraries
# (a pure-Blueberry runtime is the self-hosted-container track); that's still a
# faithful test of *our build* of each service — its code, config and features.
#
# Usage: tools/test/service-smoke.sh [service...]   (default: the whole matrix)
set -eu

cd "$(dirname "$0")/../.."
TOP=$(pwd)
OUT="$TOP/obj/bpm-out"
ENGINE=${ENGINE:-podman}
IMAGE=${IMAGE:-docker.io/library/archlinux:latest}
CACHE=${PACMAN_CACHE:-blueberry-pacman}
SERVICES=${*:-sqlite redis nginx postgresql}

echo "[services] building: $SERVICES"
# shellcheck disable=SC2086
sh "$TOP/tools/pkg/build-bpm-pkg.sh" "$OUT" $SERVICES

# The probe matrix runs inside one container. Each service extracts its .bpm (and
# gets its runtime libs from pacman), starts, and is probed; failures are
# collected and reported at the end.
"$ENGINE" run --rm \
    -v "$CACHE:/var/cache/pacman/pkg" \
    -v "$OUT:/out:ro,z" \
    -e "SERVICES=$SERVICES" \
    "$IMAGE" bash -euc '
pacman -Sy --noconfirm --needed zstd curl >/dev/null 2>&1

extract() {  # extract a Blueberry .bpm payload into /
    f=$(ls -1 /out/"$1"-[0-9]*.bpm 2>/dev/null | head -1)
    [ -n "$f" ] || { echo "  no .bpm for $1"; return 1; }
    zstd -dcq "$f" | tar -x -C / --exclude=.BPM 2>/dev/null
}
libs() { pacman -S --noconfirm --needed "$@" >/dev/null 2>&1 || true; }

fail=""; pass=""
ok()  { echo "  PASS $1"; pass="$pass $1"; }
bad() { echo "  FAIL $1: $2"; fail="$fail $1"; }

for svc in $SERVICES; do
    echo "== $svc =="
    extract "$svc" || { bad "$svc" "no package"; continue; }
    case "$svc" in
      sqlite)
        libs
        out=$(printf "select 40+2;\n" | /usr/bin/sqlite3 :memory: 2>&1 || true)
        [ "$out" = 42 ] && ok sqlite || bad sqlite "select gave: $out" ;;
      redis)
        libs
        /usr/bin/redis-server --port 6390 --daemonize yes --save "" >/dev/null 2>&1 || \
          { bad redis "server did not start"; continue; }
        sleep 1
        out=$(/usr/bin/redis-cli -p 6390 ping 2>&1 || true)
        [ "$out" = PONG ] && ok redis || bad redis "ping gave: $out"
        /usr/bin/redis-cli -p 6390 shutdown nosave >/dev/null 2>&1 || true ;;
      nginx)
        libs pcre2 openssl zlib
        useradd -M -r http 2>/dev/null || true
        mkdir -p /srv/www /var/log/nginx /var/lib/nginx/tmp /run
        echo OK > /srv/www/index.html
        cat > /tmp/nginx.conf <<CONF
pid /run/nginx.pid;
events { worker_connections 16; }
http {
  access_log off; error_log /var/log/nginx/e.log;
  client_body_temp_path /var/lib/nginx/tmp;
  server { listen 8099; location / { root /srv/www; } }
}
CONF
        /usr/bin/nginx -c /tmp/nginx.conf 2>/tmp/nginx.err || { bad nginx "$(cat /tmp/nginx.err)"; continue; }
        sleep 1
        out=$(curl -s http://127.0.0.1:8099/ 2>&1 || true)
        [ "$out" = OK ] && ok nginx || bad nginx "GET gave: $out"
        /usr/bin/nginx -c /tmp/nginx.conf -s stop 2>/dev/null || true ;;
      postgresql)
        libs readline openssl zlib icu lz4 zstd
        useradd -M -r pg 2>/dev/null || true
        mkdir -p /pgdata /run/pg && chown pg /pgdata /run/pg
        su pg -c "/usr/bin/initdb -D /pgdata -A trust >/tmp/pg-init.log 2>&1" || { bad postgresql "initdb: $(tail -3 /tmp/pg-init.log)"; continue; }
        su pg -c "/usr/bin/pg_ctl -D /pgdata -o \"-k /run/pg\" -l /tmp/pg.log -w start" >/dev/null 2>&1 || { bad postgresql "start: $(tail -3 /tmp/pg.log)"; continue; }
        out=$(su pg -c "/usr/bin/psql -h /run/pg -d postgres -tAc \"select 40+2\"" 2>&1 || true)
        [ "$(echo "$out" | tr -d "[:space:]")" = 42 ] && ok postgresql || bad postgresql "select gave: $out"
        su pg -c "/usr/bin/pg_ctl -D /pgdata stop" >/dev/null 2>&1 || true ;;
      *) bad "$svc" "no probe defined" ;;
    esac
done

echo
echo "service-smoke:$(echo $pass | wc -w) passed,$(echo $fail | wc -w) failed"
[ -z "$fail" ] || { echo "  failed:$fail"; exit 1; }
'
