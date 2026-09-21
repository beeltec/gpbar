#!/usr/bin/env python3
"""Reject duplicate releases and stable version rollbacks."""
import json
import os
from pathlib import Path
import re
import sys

releases = [release for page in json.loads(Path(sys.argv[1]).read_text()) for release in page]
tag = os.environ['GITHUB_REF_NAME']
if any(release['tag_name'] == tag for release in releases):
    raise SystemExit('This tag already has a release. Resolve or remove its draft before retrying.')
if os.environ['GPBAR_PRERELEASE'] == 'true':
    raise SystemExit(0)
version = tuple(map(int, os.environ['GPBAR_VERSION'].split('.')))
previous = []
for release in releases:
    if release['draft'] or release['prerelease']:
        continue
    match = re.fullmatch(r'v?(\d+)\.(\d+)\.(\d+)(?:\+[0-9A-Za-z.-]+)?', release['tag_name'])
    if match is None:
        raise SystemExit('An existing stable release does not have a supported SemVer tag.')
    previous.append((tuple(map(int, match.groups())), release['tag_name']))
    if tuple(map(int, match.groups())) >= version:
        raise SystemExit('A stable release must be newer than every published stable release.')

with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
    output.write(f"previous_tag={max(previous)[1] if previous else ''}\n")
