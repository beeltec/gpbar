#!/bin/sh
set -eu
project_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
case "${1:-}" in
    ''|--core|--interactive) ;;
    *) echo 'Usage: scripts/test-authentication.sh [--core|--interactive]' >&2; exit 2 ;;
esac
export MACOSX_DEPLOYMENT_TARGET=26.0
export GPBAR_REQUIRE_OPENCONNECT=1
export PKG_CONFIG_PATH="$project_root/build/native/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CARGO_TARGET_DIR="$project_root/build/engine"
mkdir -p build
fixture=$(mktemp -d "$project_root/build/authentication-fixture.XXXXXX")
server_pid=''
phase_pid=''
run() {
    python3 Tests/Authentication/run.py "$@" &
    phase_pid=$!
    wait "$phase_pid"
    phase_pid=''
}
cleanup() {
    result=$?
    trap '' HUP INT TERM
    if [ -n "$phase_pid" ]; then kill "$phase_pid" 2>/dev/null || true; wait "$phase_pid" 2>/dev/null || true; fi
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
    if [ -x "$fixture/native" ] && [ -f "$fixture/cookie-origin" ]; then
        "$fixture/native" "$fixture" --cleanup-cookies || result=1
    fi
    for keychain in "$fixture/"*.keychain-db "$fixture/"*.keychain; do
        if [ -f "$keychain" ]; then
            /usr/bin/security delete-keychain "$keychain" || result=1
        fi
    done
    if [ "$result" -ne 0 ]; then
        printf 'Authentication checks failed; fixture retained at %s\n' "$fixture" >&2
        exit "$result"
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
run python3 Tests/Authentication/fixtures.py "$fixture"
run swiftc -swift-version 6 -parse-as-library Shared/*.swift \
    GPBar/Services/UserKeychain.swift GPBar/Services/KeychainIdentity.swift GPBar/Services/KeychainAuthentication.swift \
    Tests/Authentication/Native.swift -o "$fixture/native"
run "$fixture/native" "$fixture"
python3 Tests/Authentication/server.py "$fixture" > "$fixture/server.log" 2>&1 &
server_pid=$!
for _ in 1 2 3 4 5; do
    if [ -f "$fixture/origin" ]; then break; fi
    kill -0 "$server_pid"
    sleep 1
done
export GPBAR_AUTHENTICATION_FIXTURE="$fixture"
run --cwd Vendor/openprotect cargo test --locked -p gp-auth authentication_ -- --include-ignored
run --cwd Vendor/openprotect cargo test --locked -p opc authentication_
fixture_app="$fixture/AuthenticationTests.app"
mkdir -p "$fixture_app/Contents/MacOS"
cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.beeltec.GPBar.AuthenticationTests</string>
<key>CFBundleName</key><string>AuthenticationTests</string>
<key>CFBundleExecutable</key><string>AuthenticationTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
run swiftc -swift-version 6 -parse-as-library -framework AppKit -framework WebKit -framework SwiftUI -framework AuthenticationServices \
    Shared/*.swift GPBar/Connection/ConnectionPreferences.swift GPBar/Services/AuthenticationCoordinator.swift \
    GPBar/Views/SignInView.swift Tests/Authentication/UI.swift -o "$fixture_app/Contents/MacOS/AuthenticationTests"
run "$fixture_app/Contents/MacOS/AuthenticationTests" "$@"
if [ -z "${1:-}" ]; then
    run scripts/test-resource-mfa.sh
    run scripts/test-cie-oidc.sh
    run scripts/test-login-sso.sh
    run scripts/test-kerberos.sh
fi
printf '%s\n' 'PASS: requested authentication suites'
