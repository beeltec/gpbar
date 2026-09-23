#!/usr/bin/env python3
"""Check installed native dependencies against the release inventory."""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
expected = json.loads((root / 'Packaging/runtime-inputs.json').read_text())
installed = json.loads(subprocess.check_output(['brew', 'info', '--json=v2', '--installed'], text=True))
for package in expected['native_packages']:
    prefix = subprocess.check_output(['brew', '--prefix', package['full_name']], text=True).strip()
    if Path(prefix).resolve(strict=True).name != package['pkg_version']:
        raise SystemExit(f"Review the native dependency pin before releasing: {package['full_name']} {package['pkg_version']}")
(root / 'build').mkdir(exist_ok=True)
(root / 'build/homebrew.json').write_text(json.dumps(installed, indent=2) + '\n')
