#!/bin/sh
set -eu
: "${GPBAR_APP:?Set GPBAR_APP to the notarized application path.}"
: "${GPBAR_SIGN_IDENTITY:?Set the Developer ID Application identity.}"
: "${GPBAR_NOTARY_PROFILE:?Set the existing notarytool keychain profile.}"
: "${GPBAR_RELEASE_DMG:?Set a new absolute DMG output path.}"
case "$GPBAR_RELEASE_DMG" in /*.dmg) ;; *) echo 'Choose an absolute .dmg output path.' >&2; exit 1;; esac
if [ -e "$GPBAR_RELEASE_DMG" ]; then echo 'Release output already exists.' >&2; exit 1; fi
case "$GPBAR_SIGN_IDENTITY" in 'Developer ID Application:'*) ;; *) echo 'Developer ID Application signing is required.' >&2; exit 1;; esac
codesign --verify --deep --strict --verbose=2 "$GPBAR_APP"
xcrun stapler validate "$GPBAR_APP"
spctl --assess --type execute --verbose=2 "$GPBAR_APP"
release_work=$(mktemp -d)
trap 'rm -rf -- "$release_work"' EXIT HUP INT TERM
mkdir "$release_work/image"
ditto "$GPBAR_APP" "$release_work/image/GPBar.app"
ln -s /Applications "$release_work/image/Applications"
cat > "$release_work/image/Install.txt" <<'GUIDE'
GPBar requires Apple Silicon and macOS 26 or newer.

Drag GPBar to Applications. Open it and enter your VPN portal address.
Choose Set up to register the VPN helper. Approve it in System Settings when asked.
Click Connect and complete your organization's sign-in.

Before replacing or removing GPBar, disconnect and remove the helper in Diagnostics.
GUIDE
hdiutil create -volname GPBar -srcfolder "$release_work/image" -format UDZO "$release_work/GPBar.dmg"
codesign --sign "$GPBAR_SIGN_IDENTITY" --timestamp "$release_work/GPBar.dmg"
xcrun notarytool submit "$release_work/GPBar.dmg" --keychain-profile "$GPBAR_NOTARY_PROFILE" --wait
xcrun stapler staple "$release_work/GPBar.dmg"
xcrun stapler validate "$release_work/GPBar.dmg"
mkdir -p "$(dirname -- "$GPBAR_RELEASE_DMG")"
mv "$release_work/GPBar.dmg" "$GPBAR_RELEASE_DMG"
