# Hosting the Package Repository and Build Server

Source code lives on **GitHub**. CI/CD runs on **GitHub Actions**. The only
server you need to run yourself is an **Nginx** instance to serve the `.bb`
package files that `bpm` downloads.

TLS is handled by a **Cloudflare Tunnel** — Cloudflare terminates HTTPS
publicly and forwards plain HTTP to Nginx on your local machine. No certs,
no open ports required.

---

## 1. Architecture Overview

```
GitHub (source code + CI)
  │
  ├─ push / PR  → GitHub Actions
  │                 lint → test → build bpm
  │                 (main only) → build world → build packages
  │                             → sign with minisign
  │                             → rsync to repo server (via Tailscale)
  │
  └─ NAS (192.168.0.79) running Nginx, no open ports
       Cloudflare Tunnel → bb.mmzsigmond.me      → .bb files + BBINDEX.zst
       Cloudflare Tunnel → blueberry.mmzsigmond.me → project site
```

---

## 2. Repo Server Setup (Nginx on your NAS)

The repo server is a single Nginx container. No Forgejo, no Woodpecker.

### Directory layout on the host

```
/srv/blueberry/
  docker-compose.yml
  nginx/conf.d/
    repo.conf
  repo/
    packages/
      x86_64/      ← .bb + BBINDEX.zst + .minisig files land here via rsync
      aarch64/
    keys/
      blueberry-repo.pub   ← public signing key (served to clients)
  certbot/
    conf/
    webroot/
```

### docker-compose.yml

Nginx only listens on HTTP — Cloudflare Tunnel handles TLS publicly.

```yaml
# /srv/blueberry/docker-compose.yml
services:
  nginx:
    image: nginx:1.27-alpine
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:80"   # bind to localhost only — Cloudflare connects here
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./repo:/srv/repo:ro

  cloudflared:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=${CLOUDFLARE_TUNNEL_TOKEN}
    depends_on:
      - nginx
```

### nginx/conf.d/repo.conf — package repository

```nginx
server {
    listen 80;
    server_name bb.mmzsigmond.me;

    root /srv/repo;
    autoindex on;

    location ~* BBINDEX\.zst$ {
        add_header Cache-Control "no-cache, must-revalidate";
        expires 0;
    }

    location ~* \.(bb|minisig|pub)$ {
        add_header Cache-Control "public, max-age=86400";
        expires 1d;
    }

    location /keys/ {
        autoindex off;
    }

    access_log /var/log/nginx/repo.access.log;
    error_log  /var/log/nginx/repo.error.log;
}
```

### nginx/conf.d/site.conf — project website

```nginx
server {
    listen 80;
    server_name blueberry.mmzsigmond.me;

    root /srv/site;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    access_log /var/log/nginx/site.access.log;
    error_log  /var/log/nginx/site.error.log;
}
```

Add a `site/` volume to docker-compose.yml alongside `repo/`:
```yaml
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./repo:/srv/repo:ro
      - ./site:/srv/site:ro
```

Drop your static HTML into `/srv/blueberry/site/` and it'll be live at
`https://blueberry.mmzsigmond.me`.

---

### .env file (next to docker-compose.yml)

```sh
CLOUDFLARE_TUNNEL_TOKEN=your-token-here
```

### Cloudflare Tunnel setup

1. Go to Cloudflare Zero Trust → Networks → Tunnels → Create a tunnel
2. Name it `blueberry`
3. Copy the tunnel token → put it in `.env` as `CLOUDFLARE_TUNNEL_TOKEN`
4. In the tunnel's **Public Hostnames** tab, add two routes:

   | Subdomain | Domain | Service |
   |-----------|--------|---------|
   | _(empty)_ | `bb.mmzsigmond.me` | `http://nginx:80` |
   | _(empty)_ | `blueberry.mmzsigmond.me` | `http://nginx:80` |

5. Save

### Start it

```sh
cd /srv/blueberry
docker compose up -d
docker compose ps
```

### Verify

```sh
curl https://bb.mmzsigmond.me/
# Should return an HTML directory listing
```

---

## 3. TLS

No action needed. Cloudflare terminates TLS for `bb.mmzsigmond.me`
automatically. The certificate renews itself via Cloudflare.

---

## 4. Deploy User for rsync

GitHub Actions rsyncs packages to the server over SSH. Create a locked-down
user on the repo server:

```sh
# On the repo server
useradd -r -s /sbin/nologin -d /srv/blueberry/repo deploy
mkdir -p /home/deploy/.ssh && chmod 700 /home/deploy/.ssh

# Paste the public half of REPO_SSH_KEY here:
echo "ssh-ed25519 AAAA... github-actions" > /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh

# Give deploy write access to the repo directory only
chown -R deploy:deploy /srv/blueberry/repo
```

Generate the key pair (on your local machine, not the server):

```sh
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ./deploy_key -N ""
# deploy_key      → add as REPO_SSH_KEY secret in GitHub
# deploy_key.pub  → paste into authorized_keys on the server
```

---

## 5. GitHub Actions Secrets

Go to your repo → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|--------|-------|
| `MINISIGN_PRIVATE_KEY` | Contents of `blueberry-repo.key` (the minisign signing key) |
| `REPO_SSH_KEY` | Contents of `deploy_key` (the SSH private key for rsync) |
| `TAILSCALE_AUTHKEY` | Tailscale auth key — only needed if your repo server has no public IP |

---

## 6. Tailscale (if your repo server is on a private network)

If your repo server is a home NAS (e.g. 192.168.0.79) without a public IP,
GitHub Actions can't reach it directly. Use Tailscale to create a private
tunnel:

```sh
# On the repo server
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
# Note the Tailscale IP (e.g. 100.x.y.z) — use this in the rsync destination
```

In `.github/workflows/ci.yml`, the `sign-and-publish` job already includes
the Tailscale step. Generate an auth key at tailscale.com/admin/settings/keys
(reusable, ephemeral) and add it as `TAILSCALE_AUTHKEY`.

Update the rsync target in `ci.yml` to use the Tailscale IP:

```yaml
rsync -av --delete /tmp/packages/ \
  deploy@100.x.y.z:/srv/blueberry/repo/packages/x86_64/
```

---

## 7. Package Signing

### Generate a signing key pair

```sh
# On a secure machine (offline ideally)
minisign -G -s blueberry-repo.key -p blueberry-repo.pub \
    -c "Blueberry Linux package repository"
```

- Store `blueberry-repo.key` securely — this is your `MINISIGN_PRIVATE_KEY` secret.
- Copy `blueberry-repo.pub` to `/srv/blueberry/repo/keys/` so clients can fetch it.

### Add the key to a Blueberry install

```sh
mkdir -p /etc/bpm/trusted-keys
wget -O /etc/bpm/trusted-keys/blueberry-repo.pub \
    https://bb.mmzsigmond.me/keys/blueberry-repo.pub
```

---

## 8. CI Pipeline Summary

`.github/workflows/ci.yml` runs these jobs:

| Job | Trigger | What it does |
|-----|---------|--------------|
| `lint-bpm` | all pushes + PRs | `go fmt` + `go vet` |
| `test-bpm` | all pushes + PRs | `go test -race ./...` |
| `build-bpm` | all pushes + PRs | `make bpm`, uploads binary artifact |
| `build-world` | push to main | `make world JOBS=4`, uploads boot/ artifact |
| `build-packages` | push to main | `make repo`, uploads repo/ artifact |
| `sign-and-publish` | push to main | Signs with minisign, rsyncs to repo server |

---

## 9. Local Package Repository (Air-Gapped / Testing)

To serve packages locally without the CI pipeline:

```sh
make repo
# packages land in ../blueberry-build/repo/

# Serve with Python
python3 -m http.server 8080 --directory ../blueberry-build/repo/

# Or with busybox
busybox httpd -f -p 8080 -h ../blueberry-build/repo/
```

Add to `/etc/bpm/repos.d/local.conf` on target systems:

```toml
name    = "local"
url     = "http://192.168.0.79:8080"
enabled = true
```

---

## 10. Disaster Recovery

### Repo server goes down

Users can install from local `.bb` files: `bpm install --file package.bb`

The entire package set rebuilds from source with `make repo`.

### Signing key compromised

1. Generate a new key pair.
2. Remove the old key from `/etc/bpm/trusted-keys/` on all systems.
3. Rebuild and re-sign all packages.
4. Announce the rotation via a GitHub release / security advisory.
