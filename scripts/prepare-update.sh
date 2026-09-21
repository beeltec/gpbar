#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${GPBAR_APP:?Set GPBAR_APP to the notarized application path.}"
: "${GPBAR_UPDATE_OUTPUT:?Set GPBAR_UPDATE_OUTPUT to a new absolute directory.}"
: "${GPBAR_UPDATE_DOWNLOAD_URL:?Set GPBAR_UPDATE_DOWNLOAD_URL to the HTTPS release asset directory, ending in /.}"
sparkle_bin=${GPBAR_SPARKLE_BIN:-$project_root/build/app-derived/SourcePackages/artifacts/sparkle/Sparkle/bin}
account=com.beeltec.GPBar.updates
case "$GPBAR_UPDATE_OUTPUT" in /*) ;; *) echo 'Choose an absolute output directory.' >&2; exit 1;; esac
if [ -e "$GPBAR_UPDATE_OUTPUT" ]; then echo 'Update output already exists.' >&2; exit 1; fi
python3 - "$GPBAR_APP" "$GPBAR_UPDATE_DOWNLOAD_URL" <<'PY'
import plistlib
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

app = Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
for value in (sys.argv[2], info.get('SUFeedURL', '')):
    url = urlsplit(value)
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise SystemExit('Update URLs must be HTTPS without credentials, queries, or fragments.')
if not sys.argv[2].endswith('/'):
    raise SystemExit('The download directory URL must end with /.')
if info.get('CFBundleIdentifier') != 'com.beeltec.GPBar':
    raise SystemExit('Expected the GPBar application bundle.')
if not re.fullmatch(r'[1-9][0-9]*', str(info.get('CFBundleVersion', ''))):
    raise SystemExit('Use a positive, increasing integer build number.')
if info.get('SUVerifyUpdateBeforeExtraction') is not True or info.get('SUAllowsAutomaticUpdates') is not False:
    raise SystemExit('The application must enforce signed archives and user-confirmed installation.')
PY
identity=$(codesign --display --verbose=4 "$GPBAR_APP" 2>&1)
case "$identity" in *'Authority=Developer ID Application:'*) ;; *) echo 'Developer ID Application signing is required.' >&2; exit 1;; esac
codesign --verify --deep --strict --verbose=2 "$GPBAR_APP"
xcrun stapler validate "$GPBAR_APP"
spctl --assess --type execute --verbose=2 "$GPBAR_APP"
public_key=$("$sparkle_bin/generate_keys" --account "$account" -p)
bundle_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$GPBAR_APP/Contents/Info.plist")
if [ "$public_key" != "$bundle_key" ]; then echo 'The signing key does not match the application public key.' >&2; exit 1; fi
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$GPBAR_APP/Contents/Info.plist")
python3 - "$project_root/updates/appcast.xml" "$build_number" <<'PY'
import sys
import xml.etree.ElementTree as ET
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
for item in ET.parse(sys.argv[1]).findall('./channel/item'):
    version = item.findtext(ns + 'version')
    enclosure = item.find('enclosure')
    if version is None and enclosure is not None:
        version = enclosure.get(ns + 'version')
    if version is None or not version.isdecimal() or int(version) >= int(sys.argv[2]):
        raise SystemExit('The build number must exceed every published build.')
PY
mkdir -p "$(dirname -- "$GPBAR_UPDATE_OUTPUT")"
update_work=$(mktemp -d "$(dirname -- "$GPBAR_UPDATE_OUTPUT")/.gpbar-update.XXXXXX")
trap 'rm -rf -- "$update_work"' EXIT HUP INT TERM
cp "$project_root/updates/appcast.xml" "$update_work/appcast.xml"
ditto -c -k --keepParent "$GPBAR_APP" "$update_work/GPBar-$build_number.zip"
"$sparkle_bin/generate_appcast" --account "$account" --maximum-deltas 0 \
    --download-url-prefix "$GPBAR_UPDATE_DOWNLOAD_URL" -o "$update_work/appcast.xml" "$update_work"
mv "$update_work" "$GPBAR_UPDATE_OUTPUT"
printf '%s\n' "$GPBAR_UPDATE_OUTPUT"
