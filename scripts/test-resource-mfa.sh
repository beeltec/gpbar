#!/bin/sh
set -eu
project_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
export MACOSX_DEPLOYMENT_TARGET=26.0
export GPBAR_REQUIRE_OPENCONNECT=1
export PKG_CONFIG_PATH="$project_root/build/native/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CARGO_TARGET_DIR="$project_root/build/engine"
if [ ! -f "$project_root/build/native/lib/libopenconnect.dylib" ]; then
    echo 'Run scripts/build-native.sh first.' >&2
    exit 1
fi
if [ "${1:-}" != '--interactive' ]; then
    (cd Vendor/openprotect && cargo test --locked -p gp-proto --test resource_mfa && cargo test --locked -p opc resource_mfa)
fi
fixture_app="$project_root/build/resource-mfa/ResourceMFATests.app"
mkdir -p "$fixture_app/Contents/MacOS"
cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.beeltec.GPBar.ResourceMFATests</string>
<key>CFBundleName</key><string>ResourceMFATests</string>
<key>CFBundleExecutable</key><string>ResourceMFATests</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
swiftc -swift-version 6 -parse-as-library -framework AppKit -framework WebKit -framework SwiftUI \
    Shared/*.swift GPBar/Connection/ConnectionPreferences.swift \
    GPBar/Services/ResourceAuthenticationCoordinator.swift GPBar/Views/ResourceAuthenticationView.swift \
    Tests/ResourceMFA/Main.swift -o "$fixture_app/Contents/MacOS/ResourceMFATests"
"$fixture_app/Contents/MacOS/ResourceMFATests" "$@"
