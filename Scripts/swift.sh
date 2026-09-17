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
exec "$xcode_swift" "$@"
