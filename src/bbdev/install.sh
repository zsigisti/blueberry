#!/bin/sh
# Builds and installs bbdev from source on Arch, Debian/Ubuntu, Fedora or
# openSUSE. Pulls in git, cargo and podman itself; clones the repo if you're
# not already in a checkout.
#
#   curl -fsSL https://raw.githubusercontent.com/zsigisti/blueberry/master/src/bbdev/install.sh | sh
#   # or, in a checkout:  sh src/bbdev/install.sh
#
# Env: PREFIX (default /usr/local), REPO_URL, ENGINE (podman|docker).
set -eu

REPO_URL="${REPO_URL:-https://github.com/zsigisti/blueberry.git}"
PREFIX="${PREFIX:-/usr/local}"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> %s\033[0m\n' "$*" >&2; }

if [ "$(id -u)" -eq 0 ]; then SUDO=; else SUDO="sudo"; command -v sudo >/dev/null 2>&1 || SUDO="doas"; fi

say "installing build dependencies (git, rust/cargo, a container engine)"
if command -v pacman >/dev/null 2>&1; then
    $SUDO pacman -Sy --needed --noconfirm git rust podman
elif command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update
    $SUDO apt-get install -y --no-install-recommends git ca-certificates cargo rustc podman
elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y git cargo rust podman
elif command -v zypper >/dev/null 2>&1; then
    $SUDO zypper --non-interactive install git cargo podman
else
    warn "unknown distro, make sure git, cargo and podman/docker are installed"
fi

command -v cargo >/dev/null 2>&1 || { warn "cargo not found; install Rust (https://rustup.rs) and re-run"; exit 1; }
command -v git   >/dev/null 2>&1 || { warn "git not found"; exit 1; }

if [ -f "src/bbdev/Cargo.toml" ]; then
    ROOT="$(pwd)"
elif ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -f "$ROOT/src/bbdev/Cargo.toml" ]; then
    :
else
    TMP="$(mktemp -d)"
    say "cloning $REPO_URL"
    git clone --depth 1 "$REPO_URL" "$TMP/blueberry"
    ROOT="$TMP/blueberry"
fi

say "building bbdev"
cargo build --release --manifest-path "$ROOT/src/bbdev/Cargo.toml"

say "installing to $PREFIX/bin/bbdev"
$SUDO install -Dm755 "$ROOT/src/bbdev/target/release/bbdev" "$PREFIX/bin/bbdev"

if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
    warn "no podman or docker found, bbdev needs one to build packages (ENGINE=docker if that's yours)"
fi

say "done. run 'bbdev' in a Blueberry checkout after editing recipes"
