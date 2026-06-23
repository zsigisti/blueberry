# Hosting a Mirror

A Blueberry mirror is just a directory of `.pkg.tar.zst` files plus a signed
index, served over HTTPS. You can run your own — for a fork, an internal
network, or a downstream distribution.

## What a mirror contains

```
/srv/blueberry-repo/
├── *.pkg.tar.zst        the packages
├── bpm.index            text index: name|version|file|sha256|deps|size|desc
└── bpm.index.sig        ed25519 signature of bpm.index
```

## Building the index

`tools/mkrepo.sh` scans a directory, writes `bpm.index`, and signs it:

```sh
sh tools/mkrepo.sh /srv/blueberry-repo
# → wrote bpm.index (N packages)
# → signed bpm.index.sig with the ed25519 key
```

The signing key is an ed25519 private key (e.g.
`~/.config/bpm/repo-ed25519.pem`). The matching **public** key must be the one
compiled into the `bpm` binaries that will use this mirror — if you run your own
mirror with your own key, build `bpm` with your public key.

## Publishing packages

Build, copy, re-index, serve:

```sh
# 1. build
ENGINE=podman tools/build-pkgs.sh ./out firefox kate

# 2. copy to the mirror host
scp ./out/*.pkg.tar.zst root@mirror:/srv/blueberry-repo/

# 3. re-index + sign on the mirror
ssh root@mirror 'sh /root/mkrepo.sh /srv/blueberry-repo'
```

Or use the helpers:

- `tools/blueberry-repo-sync.sh` — build a set and push it.
- `tools/blueberry-build-server.sh` — a one-command build-and-publish server.

## Serving it

Any static HTTP(S) server works. The official mirror sits behind Cloudflare at
`https://repo.mmzsigmond.me/` (packages at the root, no `/x86_64`). When testing
through a CDN, bust the cache:

```sh
curl -H 'Cache-Control: no-cache' https://your-mirror/bpm.index
```

## Pointing clients at it

Edit `/etc/bpm/repos.conf` on the client to list your mirror URL, then:

```sh
bpm update
```

`bpm` will fetch the index, verify the ed25519 signature against its built-in
public key, and install packages with SHA-256 verification. See
[Package Management](Package-Management).

## Accepting community recipes

Collect community recipes via pull requests to `packages/`. See [Contributing](Contributing).
More: [doc/BPM.md](../doc/BPM.md), [doc/BUILDSERVER.md](../doc/BUILDSERVER.md).
