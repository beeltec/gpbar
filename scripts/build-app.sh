#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${GPBAR_SIGN_IDENTITY:?Set GPBAR_SIGN_IDENTITY to an Apple Development or Developer ID Application identity.}"
: "${GPBAR_TEAM:?Set GPBAR_TEAM to the signing team.}"
: "${GPBAR_OUTPUT:?Set GPBAR_OUTPUT to a new absolute .app path.}"
case "$GPBAR_OUTPUT" in /*.app) ;; *) echo 'Use an absolute .app output path.' >&2; exit 1;; esac
if [ -e "$GPBAR_OUTPUT" ]; then echo 'Output already exists.' >&2; exit 1; fi
cd "$project_root"
scripts/build-native.sh
scripts/build-engine.sh
xcodegen generate
xcodebuild -project GPBar.xcodeproj -scheme GPBar -configuration Release \
    -derivedDataPath build/app-derived CODE_SIGN_IDENTITY="$GPBAR_SIGN_IDENTITY" DEVELOPMENT_TEAM="$GPBAR_TEAM" build
app_work=$(mktemp -d "$project_root/build/app-work.XXXXXX")
trap 'rm -rf -- "$app_work"' EXIT HUP INT TERM
python3 scripts/bundle-runtime.py --output "$app_work/runtime"
cp -R build/app-derived/Build/Products/Release/GPBar.app "$app_work/GPBar.app"
cp -R "$app_work/runtime/Frameworks" "$app_work/GPBar.app/Contents/Frameworks"
cp "$app_work/runtime/MacOS/openprotect" "$app_work/GPBar.app/Contents/MacOS/openprotect"
cp -R "$app_work/runtime/Resources/." "$app_work/GPBar.app/Contents/Resources/"
for library in "$app_work/GPBar.app/Contents/Frameworks/"*.dylib; do
    codesign --force --options runtime --timestamp --sign "$GPBAR_SIGN_IDENTITY" "$library"
done
codesign --force --options runtime --timestamp --identifier com.beeltec.GPBar.engine --sign "$GPBAR_SIGN_IDENTITY" "$app_work/GPBar.app/Contents/MacOS/openprotect"
codesign --force --options runtime --timestamp --sign "$GPBAR_SIGN_IDENTITY" "$app_work/GPBar.app"
codesign --verify --deep --strict --verbose=2 "$app_work/GPBar.app"
mkdir -p "$(dirname -- "$GPBAR_OUTPUT")"
mv "$app_work/GPBar.app" "$GPBAR_OUTPUT"
printf '%s\n' "$GPBAR_OUTPUT"
