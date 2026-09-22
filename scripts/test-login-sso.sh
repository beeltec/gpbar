#!/bin/sh
set -eu
project_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
export MACOSX_DEPLOYMENT_TARGET=26.0
export GPBAR_REQUIRE_OPENCONNECT=1
export PKG_CONFIG_PATH="$project_root/build/native/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CARGO_TARGET_DIR="$project_root/build/engine"
mkdir -p build
fixture=$(mktemp -d "$project_root/build/login-sso-fixture.XXXXXX")
server_pid=''
cleanup() {
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT HUP INT TERM
swiftc -swift-version 6 -parse-as-library Shared/*.swift GPBarHelper/LoginCredentialCache.swift \
    Tests/LoginSSO/Main.swift -o "$fixture/checks"
"$fixture/checks"
clang -fobjc-arc -framework Foundation -framework Security Tests/LoginSSO/Plugin.m -o "$fixture/plugin-checks"
"$fixture/plugin-checks"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=localhost' \
    -addext 'subjectAltName=DNS:localhost' -addext 'basicConstraints=critical,CA:FALSE' \
    -keyout "$fixture/key.pem" -out "$fixture/cert.pem" > "$fixture/openssl.log" 2>&1
python3 Tests/LoginSSO/server.py "$fixture" > "$fixture/server.log" 2>&1 &
server_pid=$!
for _ in 1 2 3 4 5; do
    if [ -f "$fixture/origin" ]; then break; fi
    sleep 1
done
GPBAR_LOGIN_SSO_TEST_ORIGIN=$(cat "$fixture/origin")
export GPBAR_LOGIN_SSO_TEST_ORIGIN
export GPBAR_LOGIN_SSO_TEST_CERT="$fixture/cert.pem"
(cd Vendor/openprotect && cargo test --locked -p gp-auth login_sso_ -- --include-ignored && cargo test --locked -p opc login_sso_)
if [ "${1:-}" = '--interactive' ]; then
    fixture_app="$project_root/build/login-sso-native/LoginSSOTests.app"
    mkdir -p "$fixture_app/Contents/MacOS"
    cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.beeltec.GPBar.LoginSSOTests</string>
<key>CFBundleExecutable</key><string>LoginSSOTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
    swiftc -swift-version 6 -parse-as-library -framework SwiftUI Shared/LoginSSO.swift \
        GPBar/Views/LoginSSOSettings.swift Tests/LoginSSO/Native.swift -o "$fixture_app/Contents/MacOS/LoginSSOTests"
    "$fixture_app/Contents/MacOS/LoginSSOTests"
fi
