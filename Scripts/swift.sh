#!/bin/bash
# Use full Xcode for every project Swift command.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcode_swift="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"

if [[ ! -x "$xcode_swift" || ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    echo "Full Xcode is required. Set DEVELOPER_DIR to its Contents/Developer directory." >&2
    echo "Current DEVELOPER_DIR: $DEVELOPER_DIR" >&2
    exit 1
fi

export PATH="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH"

# Keep every documented build/test/package entry point from linking a stale Rust archive.
case "${1:-}" in
    build|run|test)
        rust_profile=debug
        previous_argument=""
        for argument in "$@"; do
            if [[ "$previous_argument" == -c || "$previous_argument" == --configuration ]]; then
                rust_profile="$argument"
            fi
            case "$argument" in --configuration=*) rust_profile="${argument#*=}" ;; esac
            previous_argument="$argument"
        done
        bash "$(dirname "${BASH_SOURCE[0]}")/build_rust.sh" "$rust_profile"
        project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        rust_archive="$project_root/.build/rust/$rust_profile/libquotabar_core.a"
        rust_digest="$(shasum -a 256 "$rust_archive" | cut -d ' ' -f 1)"
        swift_command="$1"
        shift
        # A content-dependent compiler flag invalidates SwiftPM's link cache even
        # when only Rust sources changed. Archives remain profile-specific.
        exec "$xcode_swift" "$swift_command" \
            -Xlinker "$rust_archive" -Xswiftc "-DQUOTABAR_RUST_$rust_digest" "$@"
        ;;
esac
exec "$xcode_swift" "$@"
