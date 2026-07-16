# Secure Boot

Blueberry supports UEFI Secure Boot with **your own keys**. There is no
Microsoft-signed shim (that is a months-long external process), so instead of
trusting a vendor chain you generate a Blueberry key set, **enroll it in your
firmware once**, and Blueberry signs its own boot chain that your firmware then
trusts:

```
firmware ──(db)──► GRUB ──(db + GPG)──► vmlinuz ──► initramfs
```

Everything is driven by the `blueberry-secureboot` command. The one manual step
is **enrolling the key in firmware** — this page walks through it.

---

## 1. Generate a key set

On the installed system:

```sh
sudo blueberry-secureboot keygen
```

This writes, to `/etc/blueberry/secureboot/` (mode `700`):

| file | what it is |
|------|-----------|
| `PK.key/.crt` | Platform Key — the root of your Secure Boot trust |
| `KEK.key/.crt` | Key Exchange Key |
| `db.key/.crt` | signature database key — signs GRUB **and** the kernel |
| `gpg/`, `grub-gpg.pub` | GPG key GRUB uses to verify the kernel/initramfs |
| `GUID` | owner GUID for the EFI signature lists |

> **Back this directory up somewhere safe and offline.** Anyone who has `db.key`
> can sign a binary your machine will trust. If you lose it you can always
> `keygen` again and re-enroll.

## 2. Produce the enrollment files

```sh
sudo blueberry-secureboot enroll-artifacts /boot/efi/blueberry-keys
```

This creates `PK.auth`, `KEK.auth`, `db.auth` (signed variable updates) plus raw
`.esl`/`.crt` copies. Put them somewhere your firmware can read — the EFI System
Partition (as above) or a FAT USB stick.

## 3. Enroll the key in firmware

Secure Boot only trusts what is in the firmware's key database. You enroll the
Blueberry keys **once per machine**. Pick whichever method your hardware offers.

### A. Firmware setup (most common)

1. Reboot into firmware setup (usually **Del**, **F2**, or **F10** at power-on).
2. Find the **Secure Boot** menu (often under *Security* or *Boot*).
3. Put Secure Boot into **Setup Mode** / **Custom Mode**, or **Erase all keys** —
   this lets you install your own PK.
4. Use **Enroll key / Add key / Import from file** to enroll, **in this order**:
   `PK.auth` → `KEK.auth` → `db.auth`.
   (Some firmwares want the `.esl`/`.crt` under "Enroll signature/certificate"
   instead — either works.)
5. Set Secure Boot back to **Enabled / Standard Mode** and save.

Once a PK is enrolled the firmware leaves Setup Mode and enforces Secure Boot.

### B. From Linux, without rebooting to setup

If the firmware is in **Setup Mode**, you can enroll straight from Blueberry:

```sh
cd /boot/efi/blueberry-keys
sudo sbkeysync --verbose --pk PK.auth --kek KEK.auth db.auth
```

Then re-enable Secure Boot in firmware.

### C. In a VM (QEMU / OVMF)

Enroll the keys directly into the varstore with
[`virt-fw-vars`](https://gitlab.com/kraxel/virt-firmware) — no interactive setup:

```sh
GUID=$(cat /etc/blueberry/secureboot/GUID)
virt-fw-vars -i OVMF_VARS.4m.fd \
  --set-pk  "$GUID" PK.crt \
  --add-kek "$GUID" KEK.crt \
  --add-db  "$GUID" db.crt \
  --sb -o OVMF_VARS.enrolled.fd
```

Boot QEMU with the secure-boot firmware and the enrolled varstore:

```sh
qemu-system-x86_64 -machine q35,smm=on \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,unit=0,readonly=on,file=OVMF_CODE.secboot.4m.fd \
  -drive if=pflash,unit=1,file=OVMF_VARS.enrolled.fd \
  -drive file=blueberry.img,format=raw,if=virtio ...
```

This is exactly what `make test-secureboot` automates.

## 4. Sign the boot chain

A disk image built with a key set present is already signed:

```sh
SECUREBOOT_KEYDIR=/etc/blueberry/secureboot tools/image/mkdisk.sh out.img
```

On a running system — **re-run this after every kernel update**, since a new
kernel is unsigned:

```sh
sudo blueberry-secureboot sign-boot     # sbsign GRUB + kernel, GPG-sign kernel + initramfs
sudo blueberry-secureboot verify        # sbverify + gpg --verify the whole chain
blueberry-secureboot status             # show firmware SB state + key/signature status
```

## Troubleshooting

- **"Access Denied" / "Security Violation" at boot.** Firmware rejected GRUB —
  the `db` key isn't enrolled, or GRUB isn't signed. Re-check step 3, and run
  `blueberry-secureboot verify`.
- **Boots to the GRUB menu but the kernel won't load** (`cannot load image` /
  `bad signature`). The kernel is unsigned or was updated without re-signing —
  run `blueberry-secureboot sign-boot`.
- **`status` says SecureBoot disabled** but you enrolled keys. You likely left
  the firmware in Setup Mode — re-enable Secure Boot in firmware setup.
- **Locked out?** Disable Secure Boot in firmware to boot normally, fix the
  signatures, then re-enable. Your data is untouched.

## Why your own keys

Out-of-the-box Secure Boot on any stock machine needs a Microsoft-signed shim,
which Blueberry does not have. The own-keys model is fully self-hosted and puts
*you* in control of the trust root — the only cost is this one-time enrollment.
See also the reference notes in [`doc/SECUREBOOT.md`](../doc/SECUREBOOT.md).
