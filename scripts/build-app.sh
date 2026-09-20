#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${GPCLIENT_SIGN_IDENTITY:?Set GPCLIENT_SIGN_IDENTITY to an Apple Development or Developer ID Application identity.}"
: "${GPCLIENT_TEAM:?Set GPCLIENT_TEAM to the signing team.}"
: "${GPCLIENT_OUTPUT:?Set GPCLIENT_OUTPUT to a new absolute .app path.}"
case "$GPCLIENT_OUTPUT" in /*.app) ;; *) echo 'Use an absolute .app output path.' >&2; exit 1;; esac
if [ -e "$GPCLIENT_OUTPUT" ]; then echo 'Output already exists.' >&2; exit 1; fi
cd "$project_root"
scripts/build-native.sh
scripts/build-engine.sh
xcodegen generate
xcodebuild -project GPClient.xcodeproj -scheme GPClient -configuration Release \
    -derivedDataPath build/app-derived CODE_SIGN_IDENTITY="$GPCLIENT_SIGN_IDENTITY" DEVELOPMENT_TEAM="$GPCLIENT_TEAM" build
app_work=$(mktemp -d "$project_root/build/app-work.XXXXXX")
trap 'rm -rf -- "$app_work"' EXIT HUP INT TERM
python3 scripts/bundle-runtime.py --output "$app_work/runtime"
cp -R build/app-derived/Build/Products/Release/GPClient.app "$app_work/GPClient.app"
cp -R "$app_work/runtime/Frameworks" "$app_work/GPClient.app/Contents/Frameworks"
cp "$app_work/runtime/MacOS/openprotect" "$app_work/GPClient.app/Contents/MacOS/openprotect"
cp -R "$app_work/runtime/Resources/." "$app_work/GPClient.app/Contents/Resources/"
for library in "$app_work/GPClient.app/Contents/Frameworks/"*.dylib; do
    codesign --force --options runtime --timestamp --sign "$GPCLIENT_SIGN_IDENTITY" "$library"
done
codesign --force --options runtime --timestamp --identifier com.beelte.gpclient.engine --sign "$GPCLIENT_SIGN_IDENTITY" "$app_work/GPClient.app/Contents/MacOS/openprotect"
codesign --force --options runtime --timestamp --sign "$GPCLIENT_SIGN_IDENTITY" "$app_work/GPClient.app"
codesign --verify --deep --strict --verbose=2 "$app_work/GPClient.app"
mkdir -p "$(dirname -- "$GPCLIENT_OUTPUT")"
mv "$app_work/GPClient.app" "$GPCLIENT_OUTPUT"
printf '%s\n' "$GPCLIENT_OUTPUT"
