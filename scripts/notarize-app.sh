#!/bin/sh
set -eu
: "${GPBAR_APP:?Set GPBAR_APP to the signed application path.}"
: "${GPBAR_NOTARY_PROFILE:?Set GPBAR_NOTARY_PROFILE to an existing notarytool keychain profile.}"
: "${GPBAR_RELEASE_ZIP:?Set GPBAR_RELEASE_ZIP to a new absolute ZIP path.}"
if [ -e "$GPBAR_RELEASE_ZIP" ]; then echo 'Release output already exists.' >&2; exit 1; fi
identity=$(codesign --display --verbose=4 "$GPBAR_APP" 2>&1)
case "$identity" in *'Authority=Developer ID Application:'*) ;; *) echo 'Developer ID Application signing is required.' >&2; exit 1;; esac
codesign --verify --deep --strict --verbose=2 "$GPBAR_APP"
release_work=$(mktemp -d)
trap 'rm -rf -- "$release_work"' EXIT HUP INT TERM
ditto -c -k --keepParent "$GPBAR_APP" "$release_work/submission.zip"
xcrun notarytool submit "$release_work/submission.zip" --keychain-profile "$GPBAR_NOTARY_PROFILE" --wait
xcrun stapler staple "$GPBAR_APP"
xcrun stapler validate "$GPBAR_APP"
spctl --assess --type execute --verbose=2 "$GPBAR_APP"
mkdir -p "$(dirname -- "$GPBAR_RELEASE_ZIP")"
ditto -c -k --keepParent "$GPBAR_APP" "$GPBAR_RELEASE_ZIP"
