<p align="center">
  <img src="assets/banner.png" alt="Blueberry Linux" width="620">
</p>

<h1 align="center">Blueberry Linux</h1>

<p align="center">
  Una distribución de <strong>servidor CLI</strong> autoalojada, construida desde el código fuente y rolling — mínima, en la tradición BSD.
</p>

<p align="center">
  <a href="https://blueberrylinux.org">Sitio web</a> ·
  <a href="https://repo.blueberrylinux.org">Repositorio</a> ·
  <a href="https://bur.blueberrylinux.org">BUR</a> ·
  <a href="../../releases">Versiones</a>
</p>

---

Un único árbol de fuentes produce la base — un kernel **6.18 LTS** (reforzado), glibc, el gestor de paquetes `bpm` y el sistema de compilación — y cada paquete es una receta en `packages/`, construida desde el código fuente y servida desde el propio repositorio **firmado** del proyecto en [repo.blueberrylinux.org](https://repo.blueberrylinux.org). No hay espejos binarios de terceros. Toda la base está controlada por bpm, por lo que `bpm upgrade` mantiene un sistema instalado parcheado in situ.

## Lo que encontrarás aquí

```
packages/     recetas de paquetes (bpm.toml, un directorio por paquete)
src/          el sistema base: configuración del kernel, initramfs, instalador, bpm
tools/        herramientas de compilación, imagen y repositorio (pkg/ kernel/ image/ test/ …)
doc/          documentación
wiki/         la wiki de usuario
assets/       marca (logo, banner, fondo de pantalla)
```

## Documentación

Empieza con `doc/BUILD.md`. En resumen:

- `doc/BUILD.md` — construcción del sistema y la ISO
- `doc/ARCHITECTURE.md` — cómo se compone el sistema
- `doc/BPM.md` — el gestor de paquetes y el formato de paquete
- `doc/KERNEL.md` — el modelo de kernel LTS con versión fijada
- `doc/CI.md` — la compuerta de CI y cómo se cortan las versiones
- `doc/ROADMAP.md` — qué está consolidado, qué está abierto, qué está fuera del alcance
- `wiki/` — guías para usuarios (instalación, redes, espejos)

## Estado

Beta, y usable: un sistema servidor con systemd arrancable, ~190 paquetes construidos desde el código fuente, un gestor de paquetes de repositorio firmado (`bpm`) con reversión, un instalador, una consola web y un repositorio de recetas comunitarias (BUR). Cada envío ejecuta una compuerta de CI (cierre de recetas, pruebas unitarias y de ciclo de vida de bpm, detección de manipulación de `.bpm`, un informe de frescura de avisos). Los elementos abiertos conocidos — Secure Boot, aarch64, reconstrucciones del lado del servidor de BUR — y el panorama completo están en [`doc/ROADMAP.md`](doc/ROADMAP.md).

## Instalación

Descarga la ISO del instalador desde la página de [Versiones](../../releases) y escríbela en una unidad USB con `dd` (en el dispositivo completo, no en una partición):

```sh
dd if=blueberry-<...>.iso of=/dev/sdX bs=4M oflag=sync
```

Al arrancar, se accede al instalador TUI (BIOS y UEFI). Instala un servidor CLI rolling: systemd, OpenSSH, systemd-networkd (wpa_supplicant para wifi), ufw y un entorno GNU completo.

## Compilación

```sh
make world          # construir el sistema base
make run            # arrancarlo en QEMU, desde RAM
make iso            # construir la ISO del instalador
make install        # instalar el sistema compilado en DESTDIR
```

Consulta `doc/BUILD.md` para los requisitos y la lista completa de objetivos.

## Paquetes comunitarios — BUR

Más allá del repositorio base curado, el **Repositorio de Usuarios de Blueberry**
([bur.blueberrylinux.org](https://bur.blueberrylinux.org)) es el sitio de recetas comunitarias: cualquiera puede enviar un `bpm.toml`, que sea revisado y publicado para que otros puedan instalarlo con `bpm install`. Su espejo es `repo1.blueberrylinux.org`.

## Versiones

Las versiones se cortan desde este repositorio; las ISOs se adjuntan directamente como recursos de la versión. Las versiones actuales son **beta** — espera imperfecciones e informa lo que encuentres.

## Licencia

GPL-3.0-or-later — consulta `LICENSE`. Los componentes incluidos mantienen sus propias licencias (kernel Linux GPL-2.0 + nota de syscall, glibc LGPL-2.1, busybox GPL-2.0, …).

## Discord

Nuestros desarrolladores usan Discord a diario, así que únete si quieres contribuir, o si simplemente quieres estar al tanto de Blueberry Linux.

[Discord](https://discord.gg/GPfBnbDPHE)
