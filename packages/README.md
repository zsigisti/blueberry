# Blueberry packages

PKGBUILD recipes (Arch `makepkg` format) for software that runs on Blueberry
Linux. Because Blueberry is now built against **glibc**, standard Arch glibc
binaries run on it — so these build with the normal Arch toolchain and the
resulting `.pkg.tar.zst` payloads drop straight onto a Blueberry rootfs.

> A native Blueberry package manager is planned. Until then these are plain
> Arch packages; install them by extracting the payload onto the rootfs
> (see below).

## Layout

```
packages/
  <name>/PKGBUILD      one directory per package
```

Current packages: `zlib`, `ncurses` (base libraries), `wireguard-tools` (`wg`),
`curl`, `nano`, `vim`, `htop`, `tmux`, `jq`.

Dependencies named in each `depends=()` (e.g. `openssl`, `libevent`,
`oniguruma`) are resolved from the **Arch repositories** at build time — they
don't all need a PKGBUILD here.

## Build one locally (on Arch, for testing)

```sh
cd packages/jq
makepkg -si          # build + install into the host (test it)
# or just build the package without installing:
makepkg -f           # -> jq-1.7.1-1-x86_64.pkg.tar.zst
```

`makepkg --verifysource` downloads the sources and checks the `sha256sums`
without building — handy for validating a recipe.

## Build with OBS on an Arch host

[Open Build Service](https://openbuildservice.org/) builds Arch packages via its
`Arch` repository type. Outline:

1. **Create a project** (once) with an Arch repository. In the project's
   `prjconf`/meta, enable the Arch build type and point at an Arch package
   mirror for the build root, e.g.:
   ```
   Type: arch
   Repotype: arch
   ```
   and a repository like `core`/`extra` from a mirror.

2. **Add a package** and put its `PKGBUILD` in the OBS package directory.
   OBS builds the recipe in a clean Arch chroot, resolving `depends`/
   `makedepends` from the configured Arch repos.

3. **Sources.** Either commit the upstream tarball alongside the `PKGBUILD`, or
   add a `_service` that downloads it at build time, e.g.:
   ```xml
   <services>
     <service name="download_url" mode="localonly">
       <param name="url">https://.../foo-1.0.tar.xz</param>
     </service>
   </services>
   ```
   The `sha256sums` in the PKGBUILD must match.

4. **Build:**
   ```sh
   osc co <project> <package>
   cp PKGBUILD <project>/<package>/
   osc add PKGBUILD
   osc commit -m "add foo"          # triggers a build
   osc results                      # watch status
   osc getbinaries <project> <package> <repo> x86_64   # fetch the .pkg.tar.zst
   ```

(For a local OBS build without the server: `osc build arch x86_64 PKGBUILD`.)

## Install onto Blueberry (until the package manager lands)

A `.pkg.tar.zst` is just a tarball with a payload rooted at `/`, plus the
metadata files `.PKGINFO`, `.MTREE`, `.BUILDINFO`, `.INSTALL`. Extract the
payload onto the rootfs and drop the metadata:

```sh
tar --zstd -xf jq-1.7.1-1-x86_64.pkg.tar.zst -C /path/to/blueberry/rootfs \
    --exclude='.PKGINFO' --exclude='.MTREE' --exclude='.BUILDINFO' \
    --exclude='.INSTALL'
```

Then rebuild the initramfs/image (or copy into a running live system). Because
the binaries are glibc and Blueberry bundles the glibc runtime + `ld.so.cache`,
they run as-is. Make sure each package's `depends` are present on the target too.

## Updating a package

1. Bump `pkgver` (reset `pkgrel=1`).
2. Update the `source` URL if the path encodes the version.
3. Refresh the checksum:
   ```sh
   curl -fsSL <new-source-url> | sha256sum
   ```
   and paste it into `sha256sums=()`.
4. `makepkg --verifysource` to confirm, then commit.
