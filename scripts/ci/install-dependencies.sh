#!/bin/bash
set -euo pipefail
if [ "$(uname -m)" != arm64 ] || [ "$(xcodebuild -version | head -n 1)" != 'Xcode 26.6' ]; then
    echo 'The release job requires Apple Silicon and Xcode 26.6.' >&2
    exit 1
fi
brew install lz4 json-c gnutls gettext gmp nettle p11-kit stoken pkgconf xcodegen
if [ "$(xcodegen --version)" != 'Version: 2.46.0' ]; then
    echo 'The release job requires XcodeGen 2.46.0. Review the toolchain before changing this pin.' >&2
    exit 1
fi
python3 - <<'PY'
import json
from pathlib import Path
import subprocess

expected = json.loads(Path('Packaging/runtime-inputs.json').read_text())
installed = json.loads(subprocess.check_output(['brew', 'info', '--json=v2', '--installed'], text=True))
for package in expected['native_packages']:
    prefix = subprocess.check_output(['brew', '--prefix', package['full_name']], text=True).strip()
    if Path(prefix).resolve(strict=True).name != package['pkg_version']:
        raise SystemExit(f"Review the native dependency pin before releasing: {package['full_name']} {package['pkg_version']}")
Path('build').mkdir(exist_ok=True)
Path('build/homebrew.json').write_text(json.dumps(installed, indent=2) + '\n')
PY
rustup toolchain install 1.95.0 --profile minimal --target aarch64-apple-darwin
