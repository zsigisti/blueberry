# Blueberry Desktop — package build status

Tracks the self-hosted graphical stack as it is built from source into
`packages/`. The framework (release cadence, Calamares, live ISO, initramfs
live-boot) is **complete**; this file tracks the **package tree** that fills it.

Legend: ✅ built & verified · 🔨 recipe written, building/queued · ⬜ recipe TODO

## Layer 0 — foundation (no graphics deps)
| Package | Status | Notes |
|---|---|---|
| libpng | ✅ | |
| libjpeg-turbo | ✅ | |
| libxml2 | ✅ | lzma off (host-provided) |
| libpciaccess | ✅ | |
| pixman | ✅ | non-x86 SIMD disabled |

## Layer 1 — core libs
| Package | Status | Notes |
|---|---|---|
| libdrm | ✅ | cairo-tests off |
| freetype2 | ✅ | harfbuzz-less (cycle break) |
| glib2 | ✅ | introspection/dtrace off |
| fontconfig | ✅ | |
| harfbuzz | ✅ | cairo/icu/graphite/chafa off |
| xkeyboard-config | ✅ | keymap data |
| libxkbcommon | ✅ | Wayland-only (x11 deferred) |
| wayland | ✅ | |
| wayland-protocols | ✅ | |
| libglvnd | ✅ | EGL/GLES only (glx deferred) |

## Layer 2 — session services
| Package | Status | Notes |
|---|---|---|
| pam | ✅ | nis/audit off |
| duktape | ✅ | polkit JS backend |
| polkit | ✅ | duktape + pam + logind |
| pipewire | ⬜ | audio/video server |
| wireplumber | ⬜ | pipewire session manager |
| networkmanager | ⬜ | |
| xdg-desktop-portal | ⬜ | |

## Layer 3 — X11/XCB sub-layer (needed by Xwayland, Qt xcb, mesa GLX)
| Package | Status | Notes |
|---|---|---|
| libxau | ✅ | |
| libxdmcp | ✅ | |
| libxcb | ✅ | xinput + xkb |
| libx11 | ✅ | xcb backend |
| libxext | ✅ | |
| libxrender | ✅ | 0.9.12 (libX11 1.8 BufAlloc fix) |
| libxfixes | ✅ | |
| libxi | ✅ | |
| libxrandr | ✅ | |
| libxcursor | ✅ | |

(xcb-proto/xorgproto/xtrans/util-macros are build-only, pulled from Arch.)
Re-enables x11/glx in libxkbcommon, libglvnd; precondition for xorg-xwayland.

## Layer 4 — GPU / GL
| Package | Status | Notes |
|---|---|---|
| libxshmfence | ✅ | DRI3 fence (mesa dep) |
| llvm | ✅ | X86;AMDGPU shared libLLVM dylib (115M) |
| vulkan-headers | ✅ | |
| vulkan-icd-loader | ✅ | libvulkan.so, wayland/xcb/xlib WSI |
| mesa | ✅ | llvmpipe+softpipe software GL (Wayland+x11). radeonsi/iris + Vulkan deferred (LLVM-19 Triple API / libclc) |
| xorg-xwayland | ⬜ | X11 app compat under Wayland |

## Layer 5 — toolkits
Qt 6 prerequisites — all ✅: xcb-util, xcb-util-image, xcb-util-keysyms,
xcb-util-renderutil, xcb-util-wm, xcb-util-cursor, double-conversion, md4c,
libb2 (+ libxkbcommon rebuilt with X11).

| Package | Status | Notes |
|---|---|---|
| qt6-base | ✅ | Core/Gui/Widgets/Network/DBus, xcb + wayland platforms |
| qt6-declarative | ⬜ | QML/Quick — needed by Plasma, SDDM greeters |
| qt6-wayland | ⬜ | Qt Wayland platform integration |
| qt6-svg / qt6-5compat / qt6-multimedia | ⬜ | |
| gtk4 / libadwaita | ⬜ | GNOME toolkit |

Qt6-base is the gateway to SDDM, Calamares, and Plasma.

## Layer 6 — desktop
KDE Frameworks 6 (~80 pkgs) → Plasma (kwin, plasma-workspace, …) → apps.
GNOME (mutter → gnome-shell → …). SDDM. Calamares (the installer binary). — ⬜

## How to drive it
```
make desktop-pkgs              # build the KDE closure from packages/ (skips fresh)
make desktop-pkgs DE=gnome     # GNOME closure
ENGINE=podman tools/build-pkgs.sh ../blueberry-build/basepkgs <pkg>...   # one-off
```
Each `packages/<name>/PKGBUILD` builds from source via `makepkg -s` in an
ephemeral Arch container; runtime `depends` must be Blueberry packages (or
host-provided: zlib/zstd/xz/lz4/ca-certificates). Build deps come from Arch.
