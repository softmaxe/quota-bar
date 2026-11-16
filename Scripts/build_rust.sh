#!/bin/bash
# Build the native kernels with the same minimum OS and profile as SwiftPM.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${1:-debug}"
case "$profile" in
    debug) cargo_profile=dev ;;
    release) cargo_profile=release ;;
    *) echo "Unsupported Rust build profile: $profile" >&2; exit 1 ;;
esac

if ! command -v cargo >/dev/null 2>&1; then
    echo "Rust is required. Install rustup and the toolchain pinned in rust-toolchain.toml." >&2
    exit 1
fi

cd "$root"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CARGO_TARGET_DIR="$root/.build/rust"
cargo build --locked --manifest-path "$root/Rust/QuotaBarCore/Cargo.toml" --profile "$cargo_profile"
