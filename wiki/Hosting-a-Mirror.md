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

`tools/pkg/bpmrepo.sh` scans a directory, writes `bpm.index`, and signs it:

```sh
sh tools/pkg/bpmrepo.sh /srv/blueberry-repo
# → wrote bpm.index (N packages; previous M)
# → signed bpm.index.sig with the ed25519 key
```

It is **safe to run repeatedly**: it refuses to overwrite a healthy index with
an empty one or with a >10% package drop (a bad scan or missing files would
otherwise cause an outage), snapshots the current `bpm.index`/`.sig` into
`.index-backups/` before swapping, and swaps the index and its signature
together so clients never see a new index with a stale signature. Override the
safety floor with `BPMREPO_FORCE=1` for an intentional big shrink or the very
first index.

The signing key is an ed25519 private key (e.g.
`~/.config/bpm/repo-ed25519.pem`). The matching **public** key must be the one
compiled into the `bpm` binaries that will use this mirror — if you run your own
mirror with your own key, build `bpm` with your public key.

## Publishing packages

The one-command safe path (`tools/release/repo-publish.sh`) uploads the
packages, re-indexes remotely through the guardrails above, and validates the
result over the CDN:

```sh
# build first
ENGINE=podman tools/pkg/build-bpm-pkg.sh ./out nginx redis

# upload + re-index + validate in one step
REPO_HOST=root@mirror tools/release/repo-publish.sh ./out/*.bpm
```

Or do it by hand:

```sh
scp ./out/*.bpm root@mirror:/srv/blueberry-repo/
ssh root@mirror 'sh /root/bpmrepo.sh /srv/blueberry-repo'
```

To rebuild the **whole** package set at once, `make repo-build` builds every
`packages/<name>/bpm.toml` into `obj/bpm-out`; then publish those `.bpm` files
as above.

> Keep only ONE version of each package in the pool — `bpm` resolves the *first*
> index line for a name, so leaving both `foo-1.0` and `foo-1.1` shadows the
> newer one. Delete the superseded `.bpm` before re-indexing.

## Serving it

Any static HTTP(S) server works. Use the version-controlled vhost at
[`tools/release/mirror/nginx-repo.conf`](../tools/release/mirror/nginx-repo.conf) —
it sets the correct cache policy: `.bpm` packages are content-addressed and
served **immutable** (cache forever), while `bpm.index`/`.sig` are served
**no-cache** so a freshly published package is visible immediately. The
`.index-backups/` rollback dir is not served publicly.

The official mirror sits behind Cloudflare at `https://repo.blueberrylinux.org/`
(packages at the root, no `/x86_64`). To make Cloudflare edge-cache `.bpm` (it
does not cache unknown extensions by default), add one dashboard Cache Rule —
*URI Path ends with `.bpm` → Eligible for cache, Edge TTL = use cache-control
header*; see the header comment in the vhost file. The index needs no rule; its
`no-cache` header is honored automatically.

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
More: [doc/BPM.md](../../doc/BPM.md).
