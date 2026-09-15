#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read aidevops OpenCode runtime profiles for shell and setup adapters."""

import json
import os
import re
import sys
from pathlib import Path


def profile_document():
    configured = os.environ.get('AIDEVOPS_OPENCODE_PROFILE_FILE')
    candidates = [
        Path(configured).expanduser() if configured else None,
        Path(__file__).resolve().parent.parent / 'configs' / 'opencode-runtime-profiles.json',
        Path.home() / '.aidevops' / 'agents' / 'configs' / 'opencode-runtime-profiles.json',
    ]
    for candidate in filter(None, candidates):
        try:
            with candidate.open('r', encoding='utf-8') as handle:
                document = json.load(handle)
            if document.get('schema') == 'aidevops-opencode-runtime-profiles/v1':
                return document
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            continue
    raise SystemExit('OpenCode runtime profile document not found or invalid')


def selected_id(document):
    profile_id = os.environ.get('AIDEVOPS_OPENCODE_PROFILE', document['default'])
    if profile_id not in document['profiles']:
        raise SystemExit(f'Unknown OpenCode runtime profile: {profile_id}')
    return profile_id


def profile_for_version(document, version):
    match = re.search(r'\d+', version)
    if not match:
        return selected_id(document)
    profile_id = f'v{match.group(0)}'
    return profile_id if profile_id in document['profiles'] else selected_id(document)


def main(argv):
    document = profile_document()
    command = argv[1] if len(argv) > 1 else 'selected'
    if command == 'default':
        print(document['default'])
        return
    if command == 'detect' and len(argv) == 3:
        print(profile_for_version(document, argv[2]))
        return
    if command == 'selected':
        profile_id = selected_id(document)
        if len(argv) == 2:
            print(profile_id)
            return
        field = argv[2]
    elif command == 'get' and len(argv) == 4:
        profile_id, field = argv[2], argv[3]
    else:
        raise SystemExit('Usage: opencode-runtime-profile.py default | selected [FIELD] | detect VERSION | get PROFILE FIELD')
    try:
        value = document['profiles'][profile_id][field]
    except KeyError as error:
        raise SystemExit(f'Unknown OpenCode profile field: {error.args[0]}') from error
    if isinstance(value, bool):
        print('true' if value else 'false')
    elif isinstance(value, (dict, list)):
        print(json.dumps(value, separators=(',', ':')))
    else:
        print(value)


if __name__ == '__main__':
    main(sys.argv)
