# Hosting a Mirror

A Blueberry mirror is just a directory of `.bpm` files plus a signed
index, served over HTTPS. You can run your own — for a fork, an internal
network, or a downstream distribution.

## What a mirror contains

```
/srv/blueberry-repo/
├── *.bpm        the packages
├── bpm.index            text index: name|version|file|sha256|deps|size|desc
└── bpm.index.sig        ed25519 signature of bpm.index
```

## Building the index

`tools/bpmrepo.sh` scans a directory, writes `bpm.index`, and signs it:

```sh
sh tools/bpmrepo.sh /srv/blueberry-repo
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
ENGINE=podman tools/build-bpm-pkg.sh ./out firefox kate

# 2. copy to the mirror host
scp ./out/*.bpm root@mirror:/srv/blueberry-repo/

# 3. re-index + sign on the mirror
ssh root@mirror 'sh /root/bpmrepo.sh /srv/blueberry-repo'
```

To rebuild the **whole** package set at once, `make repo-build` builds every
`packages/<name>/bpm.toml` into `obj/bpm-out`; then `scp` those `.bpm` files to
the mirror and re-index as above.

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
More: [doc/BPM.md](../doc/BPM.md).
