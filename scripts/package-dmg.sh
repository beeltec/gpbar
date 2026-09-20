#!/bin/sh
set -eu
: "${GPCLIENT_APP:?Set GPCLIENT_APP to the notarized application path.}"
: "${GPCLIENT_SIGN_IDENTITY:?Set the Developer ID Application identity.}"
: "${GPCLIENT_NOTARY_PROFILE:?Set the existing notarytool keychain profile.}"
: "${GPCLIENT_RELEASE_DMG:?Set a new absolute DMG output path.}"
case "$GPCLIENT_RELEASE_DMG" in /*.dmg) ;; *) echo 'Choose an absolute .dmg output path.' >&2; exit 1;; esac
if [ -e "$GPCLIENT_RELEASE_DMG" ]; then echo 'Release output already exists.' >&2; exit 1; fi
case "$GPCLIENT_SIGN_IDENTITY" in 'Developer ID Application:'*) ;; *) echo 'Developer ID Application signing is required.' >&2; exit 1;; esac
codesign --verify --deep --strict --verbose=2 "$GPCLIENT_APP"
xcrun stapler validate "$GPCLIENT_APP"
spctl --assess --type execute --verbose=2 "$GPCLIENT_APP"
release_work=$(mktemp -d)
trap 'rm -rf -- "$release_work"' EXIT HUP INT TERM
mkdir "$release_work/image"
ditto "$GPCLIENT_APP" "$release_work/image/GPClient.app"
ln -s /Applications "$release_work/image/Applications"
cat > "$release_work/image/Install.txt" <<'GUIDE'
GPClient requires Apple Silicon and macOS 26 or newer.

Drag GPClient to Applications. Open it and enter your VPN portal address.
Choose Set up to register the VPN helper. Approve it in System Settings when asked.
Click Connect and complete your organization's sign-in.

Before replacing or removing GPClient, disconnect and remove the helper in Diagnostics.
GUIDE
hdiutil create -volname GPClient -srcfolder "$release_work/image" -format UDZO "$release_work/GPClient.dmg"
codesign --sign "$GPCLIENT_SIGN_IDENTITY" --timestamp "$release_work/GPClient.dmg"
xcrun notarytool submit "$release_work/GPClient.dmg" --keychain-profile "$GPCLIENT_NOTARY_PROFILE" --wait
xcrun stapler staple "$release_work/GPClient.dmg"
xcrun stapler validate "$release_work/GPClient.dmg"
mkdir -p "$(dirname -- "$GPCLIENT_RELEASE_DMG")"
mv "$release_work/GPClient.dmg" "$GPCLIENT_RELEASE_DMG"
