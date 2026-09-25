#!/bin/sh
set -eu
project_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
export MACOSX_DEPLOYMENT_TARGET=26.0
mkdir -p build
fixture=$(mktemp -d "$project_root/build/profile-tests.XXXXXX")
cleanup() {
    result=$?
    trap '' HUP INT TERM
    if [ -x "$fixture/keychain" ]; then
        "$fixture/keychain" "$fixture" --cleanup || result=1
    fi
    if [ "$result" -eq 0 ]; then rm -rf -- "$fixture"
    else printf 'Profile fixture retained at %s\n' "$fixture" >&2
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
swiftc -swift-version 6 -parse-as-library Shared/*.swift GPBar/Connection/ConnectionPreferences.swift \
    GPBar/Connection/ConnectionProfiles.swift Tests/Profiles/Main.swift -o "$fixture/profiles"
"$fixture/profiles"
swiftc -swift-version 6 -parse-as-library Shared/*.swift GPBar/Connection/*.swift \
    GPBar/Services/AuthenticationCoordinator.swift GPBar/Services/ResourceAuthenticationCoordinator.swift \
    GPBar/Services/KerberosSession.swift Tests/Profiles/CertificateFixture.swift \
    GPBar/Services/LoginSSOAuthorization.swift GPBar/Views/SignInView.swift GPBar/Views/ResourceAuthenticationView.swift \
    Tests/Profiles/HelperFixture.swift Tests/Profiles/Lifecycle.swift -o "$fixture/lifecycle"
"$fixture/lifecycle"
uuidgen > "$fixture/keychain-ids"
uuidgen >> "$fixture/keychain-ids"
uuidgen >> "$fixture/keychain-ids"
swiftc -swift-version 6 -parse-as-library Shared/*.swift GPBar/Services/UserKeychain.swift \
    GPBar/Services/KeychainAuthentication.swift Tests/Profiles/Keychain.swift -o "$fixture/keychain"
"$fixture/keychain" "$fixture"
