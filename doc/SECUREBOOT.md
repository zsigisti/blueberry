# Secure Boot (own keys)

Blueberry supports UEFI Secure Boot using **your own key set** — not a
Microsoft-signed shim. A distribution can only boot out-of-the-box on stock
firmware if its bootloader is signed via Microsoft's UEFI CA (a shim), which is a
months-long external signing process. Blueberry instead lets you generate a
Blueberry key set, enroll it in your firmware once, and run a fully signed boot
chain that firmware you control will trust:

```
firmware --(db / Authenticode)--> GRUB --(GPG + db)--> kernel --> initramfs
```

- The **db key** (X.509) signs the GRUB EFI binary *and* the kernel. Firmware
  verifies GRUB against the enrolled `db`; GRUB's EFI loader boots the kernel via
  firmware `LoadImage`, which also checks `db`.
- GRUB is built with an embedded **GPG public key** and `check_signatures=enforce`
  (and `--disable-shim-lock`, since there is no shim), so it additionally refuses
  to load a kernel/initramfs whose detached GPG signature does not verify. This
  is what covers the **initramfs**, which `LoadImage` does not see.

Everything is driven by `blueberry-secureboot` (package: `blueberry-secureboot`).

## 1. Generate a key set

```sh
blueberry-secureboot keygen
```

Creates, in `/etc/blueberry/secureboot` (mode 700):

| file | purpose |
|------|---------|
| `PK.key/.crt`, `KEK.key/.crt`, `db.key/.crt` | X.509 Platform / Key-Exchange / signature-DB keys |
| `gpg/` + `grub-gpg.pub` | GPG boot-signing key (GRUB → kernel/initramfs) |
| `GUID` | owner GUID for the EFI signature lists |

**Back these up and keep the private keys offline where you can.** Anyone with
`db.key` can sign a binary your firmware will trust.

## 2. Enroll the keys in firmware

```sh
blueberry-secureboot enroll-artifacts /run/media/USB/blueberry-sb
```

Writes `PK.auth`, `KEK.auth`, `db.auth` (signed variable updates) plus the raw
`.esl`/`.crt`. Then, on the target machine:

- **Firmware setup:** put Secure Boot into *Setup/Custom Mode* and enroll
  `PK.auth`, `KEK.auth`, `db.auth` (or "enroll from file" the `.esl`/`.crt`), then
  re-enable Secure Boot; **or**
- **From Linux** (firmware in Setup Mode): `sbkeysync --pk PK.auth …`.

For QEMU/OVMF, enroll straight into the varstore with
[`virt-fw-vars`](https://gitlab.com/kraxel/virt-firmware):

```sh
virt-fw-vars -i OVMF_VARS.4m.fd \
  --set-pk  "$GUID" PK.crt --add-kek "$GUID" KEK.crt --add-db "$GUID" db.crt \
  --sb -o OVMF_VARS.enrolled.fd
```

## 3. Sign the boot chain

A **disk image** signs itself at build time when a key set is present:

```sh
SECUREBOOT_KEYDIR=/etc/blueberry/secureboot tools/image/mkdisk.sh out.img
```

On an **installed system** (e.g. after a kernel update), re-sign in place:

```sh
blueberry-secureboot sign-boot          # sbsign GRUB+kernel, gpg-sign kernel/initramfs
blueberry-secureboot verify             # sbverify + gpg --verify the chain
blueberry-secureboot status             # firmware SB state + key/signature status
```

> `sign-boot` re-signs what is on the ESP; rebuilding GRUB itself (with the
> embedded GPG pubkey + `--disable-shim-lock`) happens at image-build time in
> `mkdisk.sh`.

## Why own keys, not a shim

A Microsoft-signed shim would let Blueberry Secure-Boot on any stock machine
without enrollment, but obtaining that signature is an external, months-long
process and is out of scope. The own-keys model is fully self-hosted and gives
*you* control of the trust root — at the cost of a one-time enrollment per
machine. If a signed shim is ever added, it slots in front of GRUB without
changing the rest of the chain.
