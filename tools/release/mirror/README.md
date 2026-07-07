# Blueberry mirror kit

Everything needed to run a Blueberry bpm mirror (a read-only replica of the
origin repo) or to configure the origin itself. A mirror is an **untrusted file
server** — the index is ed25519-signed and every package is sha256-verified by
the client — so replication is a plain rsync pull with no secrets and no push
access. See the [Hosting a Mirror](../../../wiki/Hosting-a-Mirror.md) wiki page
for the walkthrough.

| File | Where it runs | Purpose |
|------|---------------|---------|
| `nginx-repo.conf` | origin **and** mirror | vhost with the correct cache policy: `.bpm` immutable (cache forever), `bpm.index`/`.sig` no-cache, `.index-backups/` hidden |
| `rsyncd-blueberry.conf` | origin | read-only rsync module `blueberry-repo` so mirrors can pull |
| `mirror-sync.sh` | mirror | three-phase pull (add packages → swap index → prune) → `/usr/local/bin/blueberry-mirror-sync` |
| `blueberry-mirror-sync.service` / `.timer` | mirror | run the sync every 15 min (jittered, persistent) |
| `mirror-setup.sh` | mirror | one-shot installer: drops the above into place + first sync |
| `mirrorlist` | reference | canonical mirror URLs for `repos.conf` |

## Origin (one-time)

```sh
cp rsyncd-blueberry.conf /etc/rsyncd.conf        # or include it
systemctl enable --now rsync
cp nginx-repo.conf /etc/nginx/sites-available/blueberry-repo   # already deployed
```

> **Exposing rsync (873):** Cloudflare only proxies HTTP, so an off-site mirror
> can't reach the module through the CDN. Either open 873 to a grey-clouded DNS
> record (publishes the origin's real IP) or pull over rsync-over-SSH with a
> command-forced key. The origin's `ufw` currently keeps 873 localhost-only, so
> the module is verified working locally but not yet publicly reachable — make
> this call when the first off-site mirror is provisioned. Alternatively, a
> mirror can sync entirely over HTTPS through the CDN (fetch `bpm.index`, then
> `GET` each `.bpm`); slower and no delta, but needs no new port.

Publishing packages goes through [`../repo-publish.sh`](../repo-publish.sh),
which re-indexes with the hardened `bpmrepo.sh` (count-floor, backups, atomic
swap).

## New mirror

```sh
ORIGIN_RSYNC=rsync://<origin>/blueberry-repo sh mirror-setup.sh --enable
```

Then add the mirror's URL to clients' `repos.conf` (nearest first); `bpm` fails
over across mirrors automatically.
