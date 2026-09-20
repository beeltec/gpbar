#!/bin/sh
set -eu
: "${GPCLIENT_APP:?Set GPCLIENT_APP to the signed application path.}"
: "${GPCLIENT_NOTARY_PROFILE:?Set GPCLIENT_NOTARY_PROFILE to an existing notarytool keychain profile.}"
: "${GPCLIENT_RELEASE_ZIP:?Set GPCLIENT_RELEASE_ZIP to a new absolute ZIP path.}"
if [ -e "$GPCLIENT_RELEASE_ZIP" ]; then echo 'Release output already exists.' >&2; exit 1; fi
identity=$(codesign --display --verbose=4 "$GPCLIENT_APP" 2>&1)
case "$identity" in *'Authority=Developer ID Application:'*) ;; *) echo 'Developer ID Application signing is required.' >&2; exit 1;; esac
codesign --verify --deep --strict --verbose=2 "$GPCLIENT_APP"
release_work=$(mktemp -d)
trap 'rm -rf -- "$release_work"' EXIT HUP INT TERM
ditto -c -k --keepParent "$GPCLIENT_APP" "$release_work/submission.zip"
xcrun notarytool submit "$release_work/submission.zip" --keychain-profile "$GPCLIENT_NOTARY_PROFILE" --wait
xcrun stapler staple "$GPCLIENT_APP"
xcrun stapler validate "$GPCLIENT_APP"
spctl --assess --type execute --verbose=2 "$GPCLIENT_APP"
mkdir -p "$(dirname -- "$GPCLIENT_RELEASE_ZIP")"
ditto -c -k --keepParent "$GPCLIENT_APP" "$GPCLIENT_RELEASE_ZIP"
