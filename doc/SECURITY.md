# Security

## 1. Image Integrity

The base image is exactly what `make world` produced from the source tree — no
opaque vendor blobs in the boot path. Beyond the base, software is installed by
`bpm` from Blueberry's **own** signed mirror (no third-party binary mirror at
runtime): the `bpm.index` is ed25519-signed and verified against a key baked into
the `bpm` binary, and every package is checked against a per-package SHA-256 from
that signed index before it touches disk. So the supply chain is end-to-end
controlled — from pinned source, through a reproducible build, to a signed mirror.

- **Pinned sources.** Upstream versions are pinned in `Make.config`
  (`LINUX_VERSION`, `BUSYBOX_VERSION`, `RUNIT_VERSION`, `DROPBEAR_VERSION`).
  Changing one is a reviewable, atomic commit.
- **Verify what you ship.** The build artefacts under `../blueberry-build/boot/`
  (`vmlinuz`, `initramfs.cpio.zst`) are the only things that boot. Hash them
  and record the digests for a release:
  ```sh
  sha256sum ../blueberry-build/boot/vmlinuz \
            ../blueberry-build/boot/initramfs.cpio.zst
  ```
- **Audit the userland.** Everything in the live CLI is a single busybox
  binary plus the scripts in `src/initramfs/`. There is no opaque package
  database to trust.

---

## 2. Kernel Hardening

### Active mitigations

| Mitigation | Kernel option | Threat |
|------------|--------------|--------|
| Kernel Page Table Isolation | `CONFIG_PAGE_TABLE_ISOLATION` | Meltdown (CVE-2017-5754) |
| Retpoline | `CONFIG_RETPOLINE` | Spectre v2 (CVE-2017-5715) |
| Speculative Store Bypass disable | kernel default | Spectre v4 |
| KASLR | `CONFIG_RANDOMIZE_BASE` | Reduces kernel exploit reliability |
| KPTI | enabled by PTI config | Spectre v3a |
| SMAP | CPU feature, no config | Supervisor access to user pages |
| SMEP | CPU feature, no config | Supervisor code execution in user pages |
| Stack protector (strong) | `CONFIG_STACKPROTECTOR_STRONG` | Stack buffer overflows |
| Init-on-alloc | `CONFIG_INIT_ON_ALLOC_DEFAULT_ON` | Uninitialised data leaks |
| Fortify source | `CONFIG_FORTIFY_SOURCE` | String/memory function overflows |

### Lockdown mode

`CONFIG_SECURITY_LOCKDOWN_LSM=y` enables the kernel lockdown subsystem.
When activated (via kernel command line `lockdown=confidentiality`), it:

- Prevents `/dev/mem` and `/dev/kmem` access
- Blocks arbitrary module loading
- Restricts `/proc/kcore`
- Prevents hibernate (can leak kernel memory)
- Disables PCI BAR access from userspace

Blueberry ships lockdown compiled in but **not activated by default**, to
avoid breaking legitimate administrative access. Enable for high-security
deployments.

### kptr_restrict and dmesg_restrict

`etc/sysctl.d/10-blueberry.conf` sets:
```
kernel.kptr_restrict = 2     # hide kernel pointers even from root
kernel.dmesg_restrict = 1    # restrict dmesg to root
```

---

## 3. Network Hardening

`etc/sysctl.d/10-blueberry.conf` enforces:

```
net.ipv4.tcp_syncookies = 1         SYN flood mitigation
net.ipv4.conf.all.rp_filter = 1     Strict reverse path filtering (anti-spoofing)
net.ipv4.conf.all.accept_redirects = 0    No ICMP redirects
net.ipv4.conf.all.accept_source_route = 0 No source-routed packets
net.ipv4.conf.all.log_martians = 1  Log impossible addresses
net.ipv4.icmp_echo_ignore_broadcasts = 1  Ignore broadcast ping (smurf)
net.ipv6.conf.all.accept_redirects = 0
```

---

## 4. SSH Hardening

The default `sshd_config` for the disk-boot path (sshd runs as a runit service,
`src/init/sv/sshd/`):

```
PermitRootLogin no             Never allow direct root login
PasswordAuthentication no      Keys only
PubkeyAuthentication yes
X11Forwarding no               No X11 (server has no display)
PrintMotd no                   Suppress MOTD (avoid info leakage)
AcceptEnv LANG LC_*            Only pass locale environment
```

Recommended additions for high-security servers:

```
AllowUsers yourusername
LoginGraceTime 20
MaxAuthTries 3
MaxSessions 5
ClientAliveInterval 300
ClientAliveCountMax 2
KexAlgorithms curve25519-sha256,diffie-hellman-group16-sha512
HostKeyAlgorithms ssh-ed25519
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com
```

---

## 5. Filesystem Security

### /tmp is a tmpfs

`/tmp` is mounted as `tmpfs` (not on disk) with `nosuid` and `nodev`.
This prevents privilege escalation through SUID binaries placed in /tmp.

### Sticky bit on /tmp

```
chmod 1777 /tmp
```

Set during `make install`. Prevents users from deleting each other's files.

### /var/empty

The sshd privilege separation directory (`/var/empty`) is:
- Owned by `root:root`
- Mode `711` (execute only — no listing, no writing)
- Empty (nothing in it)

---

## 6. User and Group Policy

### Default users

| User | UID | Purpose |
|------|-----|---------|
| `root` | 0 | System administrator |
| `daemon` | 1 | System daemons |
| `bin` | 2 | Binary owner |
| `sys` | 3 | System files |
| `nobody` | 65534 | Unprivileged user for daemons |
| `sshd` | 100 | sshd privilege separation |

### Adding service users

Service accounts should be created in `post-install` scripts:

```sh
#!/bin/sh
# post-install for a web server
id www-data >/dev/null 2>&1 || \
    adduser -D -H -h /var/www -s /sbin/nologin -u 80 www-data
```

Service accounts should have:
- `-D` — no password
- `-H` — no home directory (or a dedicated, restricted one)
- `-s /sbin/nologin` — no shell

---

## 7. Reporting Security Issues

**Do not open public issues for vulnerabilities.**

Email `security@blueberry.mmzsigmond.me` with:

1. Affected component and version
2. Description of the vulnerability
3. Steps to reproduce
4. Impact assessment
5. Optional: proposed fix

We follow a coordinated disclosure policy:
- Acknowledge receipt within 48 hours
- Confirm and assess within 7 days
- Release fix within 14 days of confirmation
- Credit reporters in the advisory unless they request anonymity
