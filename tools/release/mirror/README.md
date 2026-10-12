# Blueberry mirror kit

Files for running a bpm mirror, or setting up the origin so mirrors can pull
from it. Clients check the index signature and every package hash themselves,
so a mirror is just a dumb file server: an rsync pull, no secrets, no push
access. The full walkthrough is on the [Hosting a Mirror](../../../wiki/Hosting-a-Mirror.md)
wiki page.

| File | Where it runs | Purpose |
|------|---------------|---------|
| `nginx-repo.conf` | origin and mirror | vhost: `.bpm` cached forever, `bpm.index`/`.sig` never, `.index-backups/` hidden |
| `rsyncd-blueberry.conf` | origin | read-only rsync module `blueberry-repo` so mirrors can pull |
| `mirror-sync.sh` | mirror | three-pass pull (add packages, swap index, prune); installed as `/usr/local/bin/blueberry-mirror-sync` |
| `blueberry-mirror-sync.service` / `.timer` | mirror | runs the sync every 15 min |
| `mirror-setup.sh` | mirror | puts all of the above in place and does the first sync |
| `mirrorlist` | reference | known mirror URLs for `repos.conf` |

## Origin (one-time)

```sh
cp rsyncd-blueberry.conf /etc/rsyncd.conf        # or include it
systemctl enable --now rsync
cp nginx-repo.conf /etc/nginx/sites-available/blueberry-repo   # already deployed
```

> **About port 873:** Cloudflare only proxies HTTP, so an off-site mirror can't
> reach rsync through it. Options: open 873 on a grey-clouded DNS name (which
> publishes the origin's real IP), or rsync over SSH with a command-forced key.
> Right now `ufw` keeps 873 localhost-only. It works locally, nobody outside can
> reach it yet. Decide when the first real mirror shows up. A mirror could also
> just sync over HTTPS (fetch `bpm.index`, then `GET` each `.bpm`): slower, no
> deltas, but no new port.

Publish packages with [`../repo-publish.sh`](../repo-publish.sh). It re-indexes
through `bpmrepo.sh`, which refuses a shrinking package count, keeps backups and
swaps the index atomically.

## New mirror

```sh
ORIGIN_RSYNC=rsync://<origin>/blueberry-repo sh mirror-setup.sh --enable
```

Then add its URL to clients' `repos.conf`, nearest first. `bpm` fails over on
its own.

## Scaling notes

Already handled:

- **Old versions lying around are fine.** `bpmrepo.sh` indexes the newest
  version of each package (`sort -V`) and `bpm` takes the first index line, so
  an old `.bpm` never shadows a new one. Prune only when you want the disk back.
- **No rollbacks.** The signed index has an increasing serial and `bpm` refuses
  an older one, so a mirror can't feed clients a stale index.

Later, when something actually needs it. Both change the download URLs that
deployed clients use, so each needs a compatibility plan first:

- **`pool/` split.** Blobs in `pool/`, metadata at the root. Only backward
  compatible if the index's filename field includes the `pool/` prefix, since
  clients fetch `<url>/<filename>` as-is. Not worth it until the flat dir gets
  unwieldy.
- **Per-arch index.** Everything is `x86_64` today and the arch is in the
  filename. Once there are `aarch64` machines, split into `<arch>/bpm.index`
  (or `bpm.index.<arch>`) and teach `bpm` to fetch its own. There's no aarch64
  target yet.
