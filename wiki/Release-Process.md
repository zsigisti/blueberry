# Release Process

Blueberry Desktop follows an **Ubuntu-style** stable-release cadence. (Blueberry
Server is rolling and has no releases — it's always "latest.")

## Versioning

| Field | Rule |
|-------|------|
| Version | `YY.MM` — `.04` (April) and `.10` (October), two releases per year |
| LTS | The **April** release of every **even** year — e.g. `26.04 LTS` |
| Support | LTS: **24 months** · standard: **9 months** |
| Codename | Alliterative *adjective + berry* (e.g. *Bright Bilberry*, *Crisp Cranberry*) |
| Kernel | **Pinned** into the release; updated only by upgrading to the next release |

All of this is computed in [`editions/desktop/release.mk`](../editions/desktop/release.mk),
with codenames rolled from [`editions/desktop/codenames`](../editions/desktop/codenames).

```sh
$ make desktop-version
Blueberry Desktop 26.10 (Crisp Cranberry)
  channel : stable   support: 9 months

$ make desktop-version BBD_VERSION=26.04
Blueberry Desktop 26.04 LTS (Bright Bilberry)
  channel : lts   support: 24 months
```

Override any `BBD_*` variable to pin a build; otherwise the version is derived
from the build date.

## What a release pins

A release is a snapshot. Cutting `26.04 LTS` fixes:

- the **kernel** version (the release's stable anchor — see
  [The Kernel Model](The-Kernel-Model)),
- the graphical base (Mesa, Plasma, Qt) versions in the ISO,
- the branding strings templated into Calamares.

Userspace and apps still update from the rolling mirror after install; the
release defines the *floor* and the *kernel*, not a frozen world.

## Cutting a release (outline)

1. Resolve the version: `make desktop-version BBD_VERSION=YY.MM`.
2. Build the package closure: `make desktop-pkgs` (and `DE=gnome`).
3. Build the ISO: `make desktop-iso` — branding tokens (`@@VERSION@@`,
   `@@DEFAULT_DM@@`) are filled from the resolved release.
4. Publish packages to the mirror (`tools/mkrepo.sh`) and the ISO to the
   downloads area.
5. Tag the commit; the website release automation
   ([doc/WEBSITE.md](../doc/WEBSITE.md)) picks it up.

## Support windows

```
26.04 LTS  ████████████████████████  24 months
26.10      █████████                  9 months
27.04 LTS  ████████████████████████  24 months
27.10      █████████                  9 months
```

Run an LTS for stability; run an interim release for newer defaults. Either way,
day-to-day app updates come from the rolling repo via `bpm upgrade`.
