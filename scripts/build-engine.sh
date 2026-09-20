#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root/Vendor/openprotect"
export MACOSX_DEPLOYMENT_TARGET=26.0
export GPCLIENT_REQUIRE_OPENCONNECT=1
export PKG_CONFIG_PATH="$project_root/build/native/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if [ ! -f "$project_root/build/native/lib/libopenconnect.dylib" ]; then
    echo "Build the patched native runtime with scripts/build-native.sh first." >&2
    exit 1
fi
export CARGO_TARGET_DIR="$project_root/build/engine"
if [ "$(uname -m)" != arm64 ] || [ "$(uname -s)" != Darwin ]; then
    echo 'The GPClient engine requires an Apple Silicon Mac.' >&2
    exit 1
fi
if [ "$(pkg-config --modversion openconnect)" != 9.21 ]; then
    echo 'The pinned OpenConnect 9.21 headers and library are required.' >&2
    exit 1
fi
cargo build --locked --release --bin opc --target aarch64-apple-darwin
"$CARGO_TARGET_DIR/aarch64-apple-darwin/release/opc" runtime-info
