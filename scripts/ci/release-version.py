#!/usr/bin/env python3
"""Validate a release tag and select its application version."""
import os
from pathlib import Path
import re

number = r'(?:0|[1-9][0-9]*)'
identifier = rf'(?:{number}|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
semver = re.compile(
    rf'v?(?P<core>{number}\.{number}\.{number})'
    rf'(?:-(?P<prerelease>{identifier}(?:\.{identifier})*))?'
    r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?'
)
tag = os.environ['GITHUB_REF_NAME']
match = semver.fullmatch(tag)
if os.environ.get('GITHUB_REF_TYPE') != 'tag' or not match:
    raise SystemExit('Release builds require a SemVer tag, such as v1.2.3 or v1.2.3-rc.1.')
build = os.environ['GITHUB_RUN_NUMBER']
if not re.fullmatch(r'[1-9][0-9]*', build):
    raise SystemExit('The workflow run number must be a positive integer.')
with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
    output.write(f'version={match["core"]}\n')
    output.write(f'release_version={tag.removeprefix("v").split("+", 1)[0]}\n')
    output.write(f'prerelease={str(match["prerelease"] is not None).lower()}\n')
    output.write(f'build={build}\n')
