#!/usr/bin/env python3
"""Build a relocatable development runtime from the pinned engine and libraries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SYSTEM_PREFIXES = ('/usr/lib/', '/System/Library/')


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE).strip()


def dependencies(path):
    lines = run('/usr/bin/otool', '-L', str(path)).splitlines()[1:]
    return [line.strip().split(' (compatibility version', 1)[0] for line in lines]


def inspect(path):
    arch = run('/usr/bin/lipo', '-archs', str(path))
    if arch != 'arm64':
        raise ValueError(f'Expected arm64: {path.name} ({arch})')
    commands = run('/usr/bin/otool', '-l', str(path))
    if not re.search(r'\bplatform (?:1|MACOS)\b', commands):
        raise ValueError(f'Expected a macOS binary: {path.name}')
    minimum = re.search(r'\bminos (\d+(?:\.\d+)*)', commands)
    if minimum is None or tuple(map(int, minimum[1].split('.'))) > (26, 0, 0):
        raise ValueError(f'Unsupported deployment target: {path.name}')
    return minimum[1], re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', commands)


def bundle(engine, output):
    if output.exists():
        raise ValueError('Output already exists. Choose a new directory to preserve the existing runtime.')
    expected = json.loads((ROOT / 'docs/runtime-inputs.json').read_text())
    script = ROOT / 'Vendor/vpnc-script/vpnc-script'
    if hashlib.sha256(script.read_bytes()).hexdigest() != expected['vpnc_script_sha256']:
        raise ValueError('The route script differs from its pinned hash.')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.runtime-', dir=output.parent) as work:
        stage = Path(work) / 'runtime'
        macos = stage / 'MacOS'
        frameworks = stage / 'Frameworks'
        resources = stage / 'Resources'
        for directory in (macos, frameworks, resources):
            directory.mkdir(parents=True)
        queue = [engine.resolve(strict=True)]
        records = {}
        names = {}
        while queue:
            source = queue.pop(0)
            if source in records:
                continue
            minimum, rpaths = inspect(source)
            name = 'openprotect' if source == engine.resolve() else source.name
            if name in names and names[name] != source:
                raise ValueError(f'Conflicting runtime library name: {name}')
            names[name] = source
            dest = (macos if source == engine.resolve() else frameworks) / name
            shutil.copy2(source, dest)
            os.chmod(dest, 0o755)
            linked = []
            for dependency in dependencies(source):
                if dependency.startswith(SYSTEM_PREFIXES):
                    continue
                candidate = Path(dependency)
                if not candidate.is_absolute():
                    raise ValueError(f'Unresolved dependency: {dependency}')
                resolved = candidate.resolve(strict=True)
                if resolved == source:
                    continue
                queue.append(resolved)
                linked.append((dependency, resolved))
            records[source] = (dest, minimum, rpaths, linked)
        manifest = []
        for source, (dest, minimum, rpaths, linked) in records.items():
            if dest.parent == frameworks:
                run('/usr/bin/install_name_tool', '-id', '@rpath/' + dest.name, str(dest))
            for rpath in rpaths:
                run('/usr/bin/install_name_tool', '-delete_rpath', rpath, str(dest))
            prefix = '@executable_path/../Frameworks/' if dest.parent == macos else '@loader_path/'
            for old, resolved in linked:
                run('/usr/bin/install_name_tool', '-change', old, prefix + records[resolved][0].name, str(dest))
            run('/usr/bin/codesign', '--force', '--sign', '-', str(dest))
            for dependency in dependencies(dest):
                if not dependency.startswith((*SYSTEM_PREFIXES, '@loader_path/', '@executable_path/', '@rpath/')):
                    raise ValueError(f'External runtime dependency remains in {dest.name}')
            manifest.append({'file': str(dest.relative_to(stage)), 'minimum_macos': minimum,
                             'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                             'bundled_sha256': hashlib.sha256(dest.read_bytes()).hexdigest()})
        info = json.loads(run(str(macos / 'openprotect'), 'runtime-info'))
        if info.get('openconnect_version') != expected['openconnect_runtime']:
            raise ValueError('The runtime does not report the pinned real OpenConnect version.')
        shutil.copy2(ROOT / 'Packaging/vpnc-script', resources / 'vpnc-script')
        shutil.copy2(script, resources / 'vpnc-script.upstream')
        shutil.copytree(ROOT / 'Packaging/Licenses', resources / 'Licenses')
        (resources / 'runtime-manifest.json').write_text(json.dumps({'engine': info, 'images': manifest}, indent=2) + '\n')
        stage.rename(output)
    print(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', type=Path, default=ROOT / 'build/engine/aarch64-apple-darwin/release/opc')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        bundle(args.engine, args.output.resolve())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Runtime packaging failed: {error}\n')
