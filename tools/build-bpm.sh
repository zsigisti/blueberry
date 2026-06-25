#!/bin/sh
# build-bpm.sh — build the (Rust) bpm and install the binary to $1.
#
# Used by the image build (installed rootfs) and the initramfs build so both
# ship the same bpm the repo distributes. The release binary links only glibc +
# libgcc_s (libzstd is bundled statically), and needs glibc <= the build host's
# — Blueberry ships the same glibc, so a host build runs as-is.
set -eu

OUT=${1:?usage: build-bpm.sh <out-binary>}
DIR=$(cd "$(dirname "$0")/../src/bpm-rs" && pwd)

command -v cargo >/dev/null 2>&1 || {
    echo "build-bpm: cargo not found — install the Rust toolchain" >&2
    exit 1
}

cd "$DIR"
cargo build --release --locked
bin="$DIR/target/release/bpm"

install -Dm755 "$bin" "$OUT"
echo "build-bpm: installed $("$bin" --version 2>/dev/null || echo bpm) -> $OUT"
