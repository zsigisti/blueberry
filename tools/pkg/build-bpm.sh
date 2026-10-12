#!/bin/sh
# build-bpm.sh - build bpm (Rust) and install the binary to $1.
#
# The image and initramfs builds both use this so they ship the same bpm as the
# repo. It links only glibc + libgcc_s (zstd is static) and needs glibc <= the
# build host's, which holds since Blueberry ships the same glibc.
set -eu

OUT=${1:?usage: build-bpm.sh <out-binary>}
DIR=$(cd "$(dirname "$0")/../../src/bpm-rs" && pwd)

command -v cargo >/dev/null 2>&1 || {
    echo "build-bpm: cargo not found, install the Rust toolchain" >&2
    exit 1
}

cd "$DIR"
cargo build --release --locked
bin="$DIR/target/release/bpm"

install -Dm755 "$bin" "$OUT"
echo "build-bpm: installed $("$bin" --version 2>/dev/null || echo bpm) -> $OUT"
