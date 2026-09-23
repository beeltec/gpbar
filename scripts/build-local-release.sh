#!/bin/sh
set -eu
project_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
: "${GPBAR_VERSION:?Set the release version.}"
: "${GPBAR_BUILD:?Set a positive build number greater than the last published build.}"
: "${GPBAR_RELEASE_ROOT:?Set a new absolute output directory.}"
: "${GPBAR_TEAM:?Set the signing team.}"
: "${GPBAR_SIGN_IDENTITY:?Set the Developer ID Application identity.}"
: "${GPBAR_INSTALLER_SIGN_IDENTITY:?Set the Developer ID Installer identity.}"
: "${GPBAR_NOTARY_PROFILE:?Set the notarytool Keychain profile.}"
case "$GPBAR_RELEASE_ROOT" in /*) ;; *) echo 'Choose an absolute output directory.' >&2; exit 1;; esac
case "$GPBAR_SIGN_IDENTITY" in 'Developer ID Application:'*) ;; *) echo 'Developer ID Application signing is required.' >&2; exit 1;; esac
case "$GPBAR_INSTALLER_SIGN_IDENTITY" in 'Developer ID Installer:'*) ;; *) echo 'Developer ID Installer signing is required.' >&2; exit 1;; esac
case "$GPBAR_BUILD" in ''|0|0*|*[!0-9]*) echo 'Use a positive integer build number without leading zeros.' >&2; exit 1;; esac
if [ -e "$GPBAR_RELEASE_ROOT" ]; then echo 'Release output already exists.' >&2; exit 1; fi
cd "$project_root"
python3 - "$GPBAR_VERSION" <<'PY'
import re
import sys

if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', sys.argv[1]):
    raise SystemExit('Use a numeric application version, such as 0.2.0.')
PY
if ! security find-identity -v -p codesigning | grep -F "\"$GPBAR_SIGN_IDENTITY\"" >/dev/null; then
    echo 'Import and unlock the Developer ID Application identity in Keychain.' >&2
    exit 1
fi
if ! security find-identity -v -p basic | grep -F "\"$GPBAR_INSTALLER_SIGN_IDENTITY\"" >/dev/null; then
    echo 'Import and unlock the Developer ID Installer identity in Keychain.' >&2
    exit 1
fi
xcrun notarytool history --keychain-profile "$GPBAR_NOTARY_PROFILE" --output-format json >/dev/null
python3 scripts/check-native-inputs.py
mkdir -p "$GPBAR_RELEASE_ROOT"
export GPBAR_VERSION GPBAR_BUILD GPBAR_TEAM GPBAR_SIGN_IDENTITY GPBAR_INSTALLER_SIGN_IDENTITY GPBAR_NOTARY_PROFILE
export GPBAR_OUTPUT="$GPBAR_RELEASE_ROOT/GPBar.app"
scripts/build-app.sh
export GPBAR_APP="$GPBAR_OUTPUT"
export GPBAR_RELEASE_ZIP="$GPBAR_RELEASE_ROOT/notarized.zip"
scripts/notarize-app.sh
export GPBAR_RELEASE_OUTPUT="$GPBAR_RELEASE_ROOT/packages"
scripts/package-release.sh
printf 'Local release ready: %s\n' "$GPBAR_RELEASE_ROOT"
