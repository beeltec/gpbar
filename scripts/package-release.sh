#!/bin/sh
set -eu
project_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
: "${GPBAR_APP:?Set GPBAR_APP to the notarized application path.}"
: "${GPBAR_RELEASE_OUTPUT:?Set GPBAR_RELEASE_OUTPUT to a new absolute directory.}"
: "${GPBAR_SIGN_IDENTITY:?Set the Developer ID Application identity.}"
: "${GPBAR_INSTALLER_SIGN_IDENTITY:?Set the Developer ID Installer identity.}"
: "${GPBAR_NOTARY_PROFILE:?Set the notarytool keychain profile.}"
case "$GPBAR_RELEASE_OUTPUT" in /*) ;; *) echo 'Choose an absolute output directory.' >&2; exit 1;; esac
case "$GPBAR_SIGN_IDENTITY" in 'Developer ID Application:'*) ;; *) exit 1;; esac
case "$GPBAR_INSTALLER_SIGN_IDENTITY" in 'Developer ID Installer:'*) ;; *) exit 1;; esac
if [ -e "$GPBAR_RELEASE_OUTPUT" ]; then echo 'Release output already exists.' >&2; exit 1; fi
codesign --verify --deep --strict --verbose=2 "$GPBAR_APP"
xcrun stapler validate "$GPBAR_APP"
spctl --assess --type execute --verbose=2 "$GPBAR_APP"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$GPBAR_APP/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$GPBAR_APP/Contents/Info.plist")
case "$build" in ''|*[!0-9]*) echo 'Invalid build number.' >&2; exit 1;; esac
mkdir -p "$(dirname -- "$GPBAR_RELEASE_OUTPUT")"
package_work=$(mktemp -d "$(dirname -- "$GPBAR_RELEASE_OUTPUT")/.gpbar-package.XXXXXX")
trap 'rm -rf -- "$package_work"' EXIT HUP INT TERM
mkdir "$package_work/image" "$package_work/output"
ditto "$GPBAR_APP" "$package_work/image/GPBar.app"
ln -s /Applications "$package_work/image/Applications"
dmg="$package_work/output/GPBar-$build.dmg"
pkg="$package_work/output/GPBar-$build.pkg"
hdiutil create -volname GPBar -srcfolder "$package_work/image" -fs APFS -format ULFO "$dmg"
codesign --sign "$GPBAR_SIGN_IDENTITY" --timestamp "$dmg"
rm "$package_work/image/Applications"
pkgbuild --analyze --root "$package_work/image" "$package_work/components.plist"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$package_work/components.plist"
/usr/libexec/PlistBuddy -c 'Set :0:BundleHasStrictIdentifier true' "$package_work/components.plist"
pkgbuild --root "$package_work/image" --component-plist "$package_work/components.plist" \
    --identifier com.beeltec.GPBar --version "$version.$build" --install-location /Applications \
    --scripts "$project_root/Packaging/Installer/scripts" "$package_work/GPBar.pkg"
productbuild --distribution "$project_root/Packaging/Installer/Distribution.xml" \
    --resources "$project_root/Packaging/Installer/Resources" --package-path "$package_work" \
    --sign "$GPBAR_INSTALLER_SIGN_IDENTITY" --timestamp "$pkg"
for artifact in "$dmg" "$pkg"; do
    xcrun notarytool submit "$artifact" --keychain-profile "$GPBAR_NOTARY_PROFILE" --wait
    xcrun stapler staple "$artifact"
    xcrun stapler validate "$artifact"
done
codesign --verify --strict --verbose=2 "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
pkgutil --check-signature "$pkg"
spctl --assess --type install --verbose=2 "$pkg"
mv "$package_work/output" "$GPBAR_RELEASE_OUTPUT"
