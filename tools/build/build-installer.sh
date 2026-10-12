#!/bin/sh
# build-installer.sh <out-binary>
# Builds blueberry-install (src/installer) for the initramfs. It only links
# glibc + libgcc_s, so a host build runs fine on the shipped glibc.
set -eu

OUT=${1:?usage: build-installer.sh <out-binary>}
DIR=$(cd "$(dirname "$0")/../../src/installer" && pwd)

command -v cargo >/dev/null 2>&1 || {
    echo "build-installer: cargo not found, install the Rust toolchain" >&2
    exit 1
}

cd "$DIR"
cargo build --release --locked
bin="$DIR/target/release/blueberry-install"

install -Dm755 "$bin" "$OUT"
echo "build-installer: installed blueberry-install -> $OUT"
