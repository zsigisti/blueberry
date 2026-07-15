## Blueberry Linux — v0.8.0-beta

A "catch the whole tree up" release. Every package that was behind upstream was
bumped to current — about 50 recipes — headlined by **systemd 256.7 → 261.1**, a
current GNU userland, and a refreshed toolchain and crypto stack. The ISOs are
rebuilt on the new base and pass the full end-to-end gate (server ISO boots to
multi-user; an unattended install boots with sshd and networkd up and no failed
units). On an existing system it is `bpm update && bpm upgrade`.

### systemd 256.7 → 261.1

Five major versions forward. The one recipe change needed was dropping
`-Ddefault-hierarchy=unified` (removed upstream in 261 now that cgroup v1 support
is gone — unified is the only hierarchy). Built into the base and boot-tested:
the freshly assembled server ISO reaches `multi-user.target`, and an unattended
install of it comes up clean.

### The userland is current

About 50 recipes moved to their latest upstream release. Highlights:

- **GNU core:** coreutils 9.7 → 9.11, bash 5.2.37 → 5.3, grep 3.11 → 3.12,
  sed 4.9 → 4.10, gawk 5.3.1 → 5.4.1, findutils, diffutils, gzip, patch, which.
- **CLI tools:** vim 9.1 → 9.2, tmux 3.5a → 3.7b, htop 3.5.1, fzf 0.74.0,
  rclone 1.74.4, strace 7.1, and a dozen more (lsof, mtr, iotop, whois, p7zip,
  fastfetch, node_exporter, sysstat, dhcpcd, tree, screen, parted).
- **Shared libraries:** ncurses 6.6, readline 8.3, libffi 3.7.1, zlib 1.3.2,
  zstd 1.5.7, libseccomp 2.6.1, plus gdbm, brotli, jansson, libpsl, libtasn1,
  libunistring, libusb, p11-kit. Every library's soname was checked in its built
  payload and confirmed unchanged, so nothing that links them had to be rebuilt.

### Toolchain and crypto

- **binutils 2.44 → 2.46.1.**
- **nettle 3.10 → 4.0** (`libnettle.so.8 → .so.9`). This also closes a latent
  mismatch: the build environment already provided nettle 4.0, so the shipped
  gnutls was already linking `.so.9` while the nettle recipe still said 3.10.
  **gnutls** is rebuilt against it (release 2); its own soname is unchanged, so
  gnupg and msmtp are unaffected.
- **podman 6.0.0 → 6.0.1**, **containers-common 0.64.1 → 1.0.1**,
  **polkit 126 → 127**, **pam 1.7.0 → 1.7.2** (the newer pam needs `libpwaccess`
  and `elogind` explicitly disabled at configure time).

### lsof stays inside the base

`check-base` (the base DT_NEEDED closure gate) caught that lsof 4.99.7 had begun
auto-linking `libtirpc`, which the base does not ship. lsof is now built
`--without-libtirpc` so it stays self-contained; the base closure is clean.

### CI, and BUR publishing verifies the payload

- **A GitHub Actions gate** now runs on every push: recipe dependency closure,
  bpm unit + end-to-end lifecycle tests, a `bpmbuild --check` tamper test, and an
  advisory package-freshness report.
- **BUR publishing now unpacks the uploaded `.bpm` and checks it against the
  manifest inside it** — `payload_sha256` and `installed_size` — on top of the
  existing recipe-vs-manifest checks. No server-side rebuild; an artifact that
  does not match its own manifest is rejected.
- **bpm** gained an end-to-end lifecycle test suite (install / upgrade / rollback
  / downgrade / remove + config-file preservation), and there is now a
  `check-updates.py` freshness tracker that reports which recipes are behind
  upstream (it is what drove this release).

---

**Upgrade:** `bpm update && bpm upgrade`. Because nettle changed soname, the
upgrade pulls the matched nettle 4.0 + gnutls pair together. Fresh installs from
these ISOs already have everything. `bpm install bur` for the community client.
