## Blueberry Linux — v0.7.1-beta

A hardening release: HTTPS actually works for everything now (not just bpm),
`bpm upgrade` stops looping, community publishing can no longer be tricked into
serving an unreviewed package, and install scripts survive packaging. New ISOs
carry the base trust-store fix; the rest is `bpm update && bpm upgrade`.

### Real CA trust store (HTTPS worked only for bpm before)

The base only copied the host's CA **bundle** to
`/etc/ssl/certs/ca-certificates.crt` and marked the dep satisfied — but that
single file is not a trust store to OpenSSL, whose default CAfile is
`/etc/ssl/cert.pem`. So `bpm` (rustls) and `curl` worked, while **anything using
OpenSSL's defaults trusted nothing**: `python`, `pip`, and `bur build` all died
with `CERTIFICATE_VERIFY_FAILED`.

- **`ca-certificates` is now a real, tracked base package** that installs
  `/etc/ssl/cert.pem` as well as the bundle — no more host-copy leaking into the
  image (same class of bug as the recent `loadkeys`/libxkbcommon fix).
- **`bur build` / `bpmbuild`** no longer rely on the default verify paths at all;
  they point an explicit SSL context at the bundle, so a source fetch works on
  any layout.

### `bpm upgrade` converges

The `.BPM` manifest keeps `version` and `release` separate, but the repo index
publishes them fused as `ver-rel`. bpm's runtime installer dropped `release`, so
it recorded `2.10.0` while the index advertised `2.10.0-2` — they never compared
equal and **every `bpm upgrade` re-offered the same packages forever**. Fixed;
the first upgrade after this lands rewrites the stale versions, so existing
installs self-heal. **bpm 1.11.3 → 1.11.4.**

### Install scripts survive packaging

`post_install`/`post_upgrade`/`post_remove` hooks — the highest-risk part of a
community package, run as root — never round-tripped: `bpmbuild` emitted them as
invalid TOML (a literal newline in a basic string), which bpm's own reader would
have truncated to the first line. Now emitted as TOML `'''literal'''` blocks and
parsed as multi-line values on both sides, covered by unit tests (including
embedded quotes/backslashes). No packaged recipe used scripts yet, so nothing in
the wild was affected — but community recipes now can.

### BUR: publishing can't be tricked, plus CLI staples

The community publish endpoint used to write **any** upload into the repo under
the approved recipe's canonical name — approve one recipe, publish a different
artifact (different deps, or a root scriptlet nobody reviewed). It now recomputes
what the `.bpm` manifest must say from the reviewed recipe and rejects any
mismatch: package identity, `depends`/`provides`/`backup`, install scripts (exact
match), and payload paths (must stay in `usr,etc,opt,srv,var` — no `..`/absolute
escapes). Proven against smuggled-script, swapped-dep, path-escape and
not-a-`.bpm` attacks.

**`bur` 0.1.1 → 0.1.3** also adds:

- **`bur build`** — the subcommand the docs already told you to run; wraps the
  bundled `bpmbuild`, with a **makedepends preflight** that names missing build
  tools up front instead of failing deep in a compile.
- **`bur upgrade`** — upgrades installed community packages BUR has a newer build
  of (uses bpm's exact version comparison).
- **`bur info <unknown>`** now says "not found" instead of a decode error.

### `loadkeys` fixed

`kbd` linked `libxkbcommon` whenever the build container happened to ship it, but
Blueberry packages none — so `loadkeys` died at runtime with
`libxkbcommon.so.0: cannot open shared object file`. Built with `--disable-xkb`
(console keymaps don't need it); the binary now needs only `libc`. **kbd
2.10.0-2.**

---

**Upgrade:** `bpm update && bpm upgrade` picks up bpm 1.11.4, kbd 2.10.0-2 and
`ca-certificates`. On an existing install, run `bpm install ca-certificates`
explicitly the first time (a fresh install from these ISOs already has it).
`bpm install bur` for the 0.1.3 client.
