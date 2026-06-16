# Blueberry build server (Proxmox LXC, Ubuntu 22.04 + nginx)

A self-hosted box that clones the recipes, builds any changed package in an
ephemeral Arch container, and serves the `bpm` repo over HTTP. No signing keys —
integrity is the per-package SHA-256 in `bpm.index`, and the index is fetched
over TLS (terminate TLS at Cloudflare or a reverse proxy in front of nginx).

## 1. Create the container on Proxmox

Builds use **podman inside the container**, which needs nesting + keyctl. On the
Proxmox host:

```sh
# Get the Ubuntu 22.04 template (once)
pveam update
pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst

# Create an unprivileged LXC. Give it a few cores + ~4 GB RAM and ~20 GB disk
# (gcc is the heavy build). nesting=1,keyctl=1 are required for podman.
pct create 110 local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
  --hostname blueberry-repo \
  --cores 4 --memory 4096 --swap 1024 \
  --rootfs local-lvm:20 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --features nesting=1,keyctl=1 \
  --unprivileged 1 \
  --onboot 1 --start 1

pct enter 110
```

> The provisioner writes `/etc/containers/containers.conf.d/blueberry.conf`
> (`keyring=false`, `cgroup_manager=cgroupfs`, `events_logger=file`) — the
> settings podman needs inside an LXC. Without them you get
> `create keyring: Function not implemented`.
>
> If podman still can't build (cgroup/overlay errors on older kernels), recreate
> with `--unprivileged 0` (a privileged container) — nesting/keyctl behave more
> simply there.

## 2. Provision it (one command, as root in the container)

```sh
apt-get update && apt-get install -y curl
curl -fsSL https://raw.githubusercontent.com/zsigisti/blueberry/master/tools/buildserver-provision.sh | sh
```

That installs podman + nginx + git, clones the repo to `/opt/blueberry`,
configures nginx to serve `/srv/blueberry-repo` on port 80, installs a systemd
timer that rebuilds hourly, and runs the first build (which pulls the Arch build
image once, then builds every package — the initial run is the slow one).

Tunables (prefix the command): `WEBROOT=`, `PORT=`, `INTERVAL=2h`, `BRANCH=`,
`GIT_URL=` (e.g. a private mirror).

## 3. Point the repo URL at it

Map `repo.mmzsigmond.me` to the container (Cloudflare DNS / proxy for TLS, or a
reverse proxy). Clients use, in `/etc/bpm/repos.conf`:

```
core https://repo.mmzsigmond.me
```

bpm fetches `https://repo.mmzsigmond.me/bpm.index` and each
`https://repo.mmzsigmond.me/<pkg>.pkg.tar.zst`, verifying SHA-256 against the
index.

## Day-to-day

| Task | Command |
|------|---------|
| Build now | `systemctl start blueberry-build.service` |
| Watch a build | `journalctl -fu blueberry-build` |
| Build one package | `REPO=/opt/blueberry sh /opt/blueberry/tools/blueberry-build-server.sh nano` |
| Work on a recipe by hand | edit under `/opt/blueberry/packages/<name>`, then `PULL=0 sh /opt/blueberry/tools/blueberry-build-server.sh <name>` |
| Change rebuild cadence | edit `OnUnitActiveSec=` in `/etc/systemd/system/blueberry-build.timer`, `systemctl daemon-reload` |

The build is incremental by content hash: editing one `packages/<name>/`
rebuilds only that package; everything else is served from the cache at
`/var/cache/blueberry-repo-sync`. The webroot is publish-only — wiping it never
forces a full rebuild, and a half-built artifact is never served.

## How the pieces fit

```
git (recipes) ──► blueberry-build-server.sh ──► blueberry-repo-sync.sh
                    (pull master)                 │  content-hash cache
                                                  │  build changed pkgs in podman/Arch
                                                  ▼
                              /srv/blueberry-repo  ──►  nginx :80  ──►  Cloudflare TLS
                              (*.pkg.tar.zst + bpm.index)              repo.mmzsigmond.me
```
