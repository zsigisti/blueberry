# Blueberry Linux — Instagram content pack

Ready-to-post copy for @larplarpsahurr. Everything below is accurate — Blueberry
really is built from source out of one repo with its own package manager, mirror,
and installer. It's an honest early-beta, one-person project; lean into that
story rather than "fastest/best" claims.

Repo: https://github.com/zsigisti/blueberry · Releases (beta ISOs) on that page.

---

## The one-line hook (story / first slide)

> One person built an entire Linux distribution from scratch — kernel to package
> manager to installer — that depends on no other distro. Meet **Blueberry Linux**.

---

## Short caption (punchy feed post)

> This is **Blueberry Linux** 🫐 — a Linux distribution built *entirely from
> source* out of a single git repo.
>
> No Arch, no Debian, no Ubuntu underneath. Its own package manager, its own
> signed mirror, its own installer. Everything from the kernel up.
>
> It's a lean, rolling **server** OS — boots to a shell in seconds, no bloat.
> Currently in public beta, and 100% open source (GPL-3.0).
>
> Would you daily-drive a distro one person built from nothing? 👇
>
> ⭐ github.com/zsigisti/blueberry

---

## Longer caption (the "how is this even possible" angle)

> Most "custom" Linux distros are just Ubuntu with a new wallpaper.
>
> **Blueberry Linux** 🫐 is not that. Every single package — the C library, the
> compiler, the shell, the networking stack — is compiled from upstream source
> inside one git repository. It ships from its own mirror that depends on **no
> other distro**. If every other Linux vanished tomorrow, Blueberry would still
> build and update itself.
>
> What's in it:
> • **bpm** — a package manager written from scratch in Rust. Signed index,
>   SHA-256 verified installs, and proper `rollback` / `downgrade`.
> • A **TUI installer** — pick your disk, filesystem (ext4/xfs/btrfs), optional
>   full-disk encryption, done.
> • A tuned, pinned kernel and a real server userland — systemd, OpenSSH,
>   NetworkManager, a firewall, the works.
>
> It's a **rolling CLI server** distro: minimal, fast, and yours to fork.
> Public beta out now, GPL-3.0, built in the open.
>
> Drop a 🫐 if you want a full build-along / review.
>
> 🔗 github.com/zsigisti/blueberry

---

## Carousel outline (8 slides — text per slide)

1. **Blueberry Linux 🫐** — A Linux distro built entirely from source. One repo.
   Zero other distros underneath.
2. **Why it's different** — Not a reskin of Ubuntu. Kernel → libc → compiler →
   shell, all compiled from upstream source.
3. **Its own package manager** — `bpm`, written in Rust. Signed, verified,
   with rollback & downgrade. `bpm install nginx` and you're done.
4. **Its own signed mirror** — Every package is served from Blueberry's own
   ed25519-signed repo. It depends on no one else's servers.
5. **Its own installer** — A clean text-mode installer: disk, filesystem
   (ext4 / xfs / btrfs), optional LUKS encryption. Minutes to a running server.
6. **Built for servers** — Rolling releases, boots to a shell in seconds,
   no desktop bloat. systemd, SSH, firewall, Wi-Fi — ready out of the box.
7. **100% open source** — GPL-3.0. Fork it, run your own mirror, build your own
   distro on top. That's a first-class use case.
8. **Public beta is live** — Grab an ISO, flash it, try it in a VM.
   ⭐ github.com/zsigisti/blueberry

---

## Hashtags (mix — trim to ~15–20 for IG)

#linux #opensource #distro #linuxdistro #selfhosting #homelab #sysadmin
#devops #programming #rustlang #rust #foss #freesoftware #server #cybersecurity
#coding #softwareengineering #kernel #cli #techtok #buildinpublic #indiedev
#gpl #linuxcommunity #tech

---

## Quick facts / talking points (for comments & DMs)

- **What is it?** A from-source, self-hosted, rolling **CLI server** Linux distro.
- **Based on?** Nothing. One monorepo builds the whole OS. (An Arch container is
  used only as a build tool — it's not part of the running system.)
- **Package manager?** `bpm`, custom, in Rust — signed index, SHA-256 verified,
  rollback/downgrade, dependency resolution.
- **Install options?** BIOS + UEFI, ext4/xfs/btrfs, optional LUKS full-disk
  encryption, guided TUI or fully unattended.
- **Kernel?** A pinned, prebuilt, tuned Linux kernel — updates are deliberate,
  never surprise-breaking.
- **License?** GPL-3.0-or-later. Fully open; run your own mirror / fork it.
- **Status?** Public **beta** — usable, honest about rough edges, actively built.
- **Who's it for?** People who self-host, homelabbers, and anyone who wants a
  minimal server OS they fully control end-to-end.
- **Cost?** Free.

## Tone notes for the partner

- It's genuinely impressive that it's solo-built and self-hosting — that's the
  story. Don't claim it's "faster than Arch" or "more secure than X"; claim it's
  **independent, minimal, and built from scratch**.
- Good CTA: "would you try it / want a full review?" invites engagement.
- Screenshots that land: the TUI installer, `bpm install …` in a terminal, and
  a fast boot to a login prompt.
