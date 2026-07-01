#!/bin/sh
# build-installer.sh — build the (Rust) blueberry-install and install it to $1.
#
# The guided CLI installer that lays Blueberry down on a disk (see
# src/installer/). Like bpm it links only glibc + libgcc_s, so a host build runs
# on the shipped glibc as-is. Used by the initramfs build.
set -eu

OUT=${1:?usage: build-installer.sh <out-binary>}
DIR=$(cd "$(dirname "$0")/../src/installer" && pwd)

command -v cargo >/dev/null 2>&1 || {
    echo "build-installer: cargo not found — install the Rust toolchain" >&2
    exit 1
}

cd "$DIR"
cargo build --release --locked
bin="$DIR/target/release/blueberry-install"

install -Dm755 "$bin" "$OUT"
echo "build-installer: installed blueberry-install -> $OUT"
