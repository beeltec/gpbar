#!/bin/bash
set -euo pipefail
: "${APPLE_CERTIFICATE_P12_BASE64:?Add the Developer ID certificate secret.}"
: "${APPLE_CERTIFICATE_PASSWORD:?Add the certificate export password secret.}"
: "${APPLE_NOTARY_KEY_P8:?Add the App Store Connect team API key secret.}"
: "${APPLE_NOTARY_KEY_ID:?Set the notarization key ID variable.}"
: "${APPLE_NOTARY_ISSUER_ID:?Set the notarization issuer ID variable.}"
: "${GPBAR_TEAM:?Set the Apple signing team variable.}"
: "${GPBAR_SIGN_IDENTITY:?Set the Developer ID Application identity variable.}"
: "${RUNNER_TEMP:?Run on a GitHub-hosted runner.}"
case "$GPBAR_SIGN_IDENTITY" in 'Developer ID Application:'*) ;; *) echo 'Developer ID Application signing is required.' >&2; exit 1;; esac
umask 077
signing_dir="$RUNNER_TEMP/gpbar-signing"
mkdir "$signing_dir"
printf '%s' "$APPLE_CERTIFICATE_P12_BASE64" | base64 --decode > "$signing_dir/certificate.p12"
printf '%s' "$APPLE_NOTARY_KEY_P8" > "$signing_dir/notary.p8"
keychain_password=$(openssl rand -base64 32)
printf '::add-mask::%s\n' "$keychain_password"
keychain="$signing_dir/release.keychain-db"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$signing_dir/certificate.p12" -P "$APPLE_CERTIFICATE_PASSWORD" -t cert -f pkcs12 -k "$keychain" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain"
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
security default-keychain -d user -s "$keychain"
xcrun notarytool store-credentials gpbar-release --key "$signing_dir/notary.p8" \
    --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID"
rm "$signing_dir/certificate.p12" "$signing_dir/notary.p8"
