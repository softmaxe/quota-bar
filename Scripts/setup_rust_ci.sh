#!/bin/bash
# Install the pinned toolchain without changing the runner's default toolchain.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v rustup >/dev/null 2>&1; then
    brew install rustup
    rustup_bin="$(brew --prefix rustup)/bin"
    export PATH="$rustup_bin:$PATH"
    if [[ -n "${GITHUB_PATH:-}" ]]; then printf '%s\n' "$rustup_bin" >> "$GITHUB_PATH"; fi
fi
toolchain="$(awk -F '"' '/^channel[[:space:]]*=/ { print $2 }' "$root/rust-toolchain.toml")"
rustup toolchain install "$toolchain" --profile minimal --component rustfmt --component clippy
rustup run "$toolchain" rustc --version
