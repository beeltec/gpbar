#!/bin/bash
set -euo pipefail
: "${RUNNER_TEMP:?Run on a GitHub-hosted runner.}"
signing_dir="$RUNNER_TEMP/gpbar-signing"
status=0
if [ -d "$signing_dir" ]; then
    security default-keychain -d user -s "$HOME/Library/Keychains/login.keychain-db" || status=1
    security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db" || status=1
    if [ -f "$signing_dir/release.keychain-db" ]; then
        security delete-keychain "$signing_dir/release.keychain-db" || status=1
    fi
    rm -rf -- "$signing_dir" || status=1
fi
exit "$status"
