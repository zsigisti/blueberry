#!/bin/sh
# Sourced by startplasma-wayland BEFORE KWin launches (KDE's session env hook).
# This is the reliable place to force software rendering + a software mouse
# cursor for VMs (QEMU virtio-gpu / QXL / generic KMS) that have no native GBM
# driver and no working hardware cursor plane — /etc/environment via pam_env is
# not consistently honored by the SDDM-started session, but these env scripts
# always reach KWin.
export LIBGL_ALWAYS_SOFTWARE=1
export KWIN_DRM_USE_QPAINTER=1
export KWIN_FORCE_SW_CURSOR=1
export XCURSOR_THEME=breeze_cursors
export XCURSOR_SIZE=24
# breadcrumb so the session log confirms this hook actually ran + the value landed
echo "blueberry-env: KWIN_FORCE_SW_CURSOR=$KWIN_FORCE_SW_CURSOR XCURSOR_THEME=$XCURSOR_THEME"
