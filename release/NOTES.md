## Blueberry Linux — v0.8.1-beta

A bugfix release. The installed system shipped with no `passwd` command at all —
there was no way to change the root password, or any user's password, from a
running system. This restores the shadow account-management suite to the base
image. On an existing system it is `bpm update && bpm upgrade`; on a fresh
install, use this ISO.

### passwd is back (with useradd / usermod / chage)

The `shadow` package was never part of the base package set, and on top of that
its recipe deleted `passwd` — on the mistaken assumption that util-linux or
busybox provide one. util-linux ships no `passwd`, and there is no busybox in the
base, so the system had none. Two fixes:

- `shadow` is now in the base image, so `passwd`, `useradd`, `usermod`,
  `groupadd`, `chage`, `gpasswd`, and the rootless-container helpers
  `newuidmap` / `newgidmap` ship by default.
- The recipe keeps `passwd` — now explicitly setuid root, so an ordinary user can
  change their own password — and only drops `su` / `login` / `nologin`, which
  util-linux does provide, to avoid file conflicts.

The base runtime closure gained `libxcrypt` (libcrypt.so.2), `libbsd`, and
`libmd`, which shadow's binaries link, so the flat base list stays self-contained
and `make check-base` passes.

Nothing else changed from v0.8.0-beta.
