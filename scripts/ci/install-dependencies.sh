#!/bin/bash
set -euo pipefail
if [ "$(uname -m)" != arm64 ] || [ "$(xcodebuild -version | head -n 1)" != 'Xcode 26.6' ]; then
    echo 'The release job requires Apple Silicon and Xcode 26.6.' >&2
    exit 1
fi
brew install lz4 json-c gnutls gettext gmp nettle p11-kit stoken pkgconf xcodegen
if [ "$(xcodegen --version)" != 'Version: 2.46.0' ]; then
    echo 'The release job requires XcodeGen 2.46.0. Review the toolchain before changing this pin.' >&2
    exit 1
fi
python3 scripts/check-native-inputs.py
rustup toolchain install 1.95.0 --profile minimal --target aarch64-apple-darwin
