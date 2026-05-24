# Security

## 1. Package Integrity

### Checksums

Every `.bb` archive contains a `.CHECKSUMS` file with SHA-256 hashes of all
installed files. `bpm verify` uses these to detect post-install modifications.

Every package in the repository index (`BBINDEX.zst`) includes the SHA-256
of the `.bb` archive itself. bpm verifies this before extraction.

### Package signing

Production repositories sign every `.bb` with minisign (Ed25519). The
signature is stored as `<package>.bb.minisig` alongside the archive.

bpm verifies signatures when:
- `REPO_SIGN=1` is set in bpm.conf (the server default)
- A public key is present in `/etc/bpm/trusted-keys/`

To add a trusted key:
```sh
# Download the repo's public key
wget -O /etc/bpm/trusted-keys/core.pub \
    https://bb.mmzsigmond.me/keys/blueberry-repo.pub
```

To generate a signing key pair (repository maintainers only):
```sh
minisign -G -s blueberry.key -p blueberry.pub \
    -c "Blueberry Linux package repository signing key"
```

Keep `blueberry.key` in an offline vault. The passphrase protects it if the
file is stolen, but there is no passphrase substitution for offline storage.

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

The default `sshd_config` shipped in `pkgs/core/openssh/BBUILD`:

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
