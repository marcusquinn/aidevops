#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read aidevops OpenCode runtime profiles for shell and setup adapters."""

import json
import os
import re
import shutil
import subprocess  # nosec B404 -- fixed `--version` argv probe only, never a shell
import sys
from pathlib import Path

# GH#38922: OpenCode 2 prints `opencode v2.3.0`; V1 prints a bare `1.19.6`.
# A word boundary cannot separate `v` from the major, so accept the prefix.
VERSION_PATTERN = re.compile(r'(?<![\w.])[vV]?(\d+)\.\d+\.\d+')


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


def profile_for_major(document, major):
    """Map an OpenCode major to a known profile; newer majors use the newest contract."""
    known = {
        profile['major']: profile_id
        for profile_id, profile in document['profiles'].items()
        if isinstance(profile.get('major'), int)
    }
    if major in known:
        return known[major]
    if known and major > max(known):
        return known[max(known)]
    return ''


def installed_profile(document, binary=None):
    """Return the profile of the installed global OpenCode binary, or '' if unknown.

    This is the single installed-major detector shared by plugin setup, binary
    validation, agent config generation and the config verifier (GH#38922).
    """
    binary = binary or shutil.which('opencode')
    if not binary:
        return ''
    try:
        result = subprocess.run([binary, '--version'], capture_output=True, text=True,  # nosec B603
                                timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        return ''
    output = f'{result.stdout}\n{result.stderr}'
    # t2891: a Claude CLI shadowing the `opencode` name is not an OpenCode major.
    if '(Claude Code)' in output:
        return ''
    match = VERSION_PATTERN.search(output)
    return profile_for_major(document, int(match.group(1))) if match else ''


def shared_config_profile(document):
    """Return the profile that governs the shared ~/.config/opencode config.

    An explicit AIDEVOPS_OPENCODE_PROFILE wins, except when it comes from an
    isolated runtime session whose OPENCODE_CONFIG targets another file. Then
    the installed global `opencode` decides, and the document default last.
    """
    override = os.environ.get('AIDEVOPS_OPENCODE_PROFILE')
    if override:
        session_config = os.environ.get('OPENCODE_CONFIG')
        shared_config = os.path.expanduser('~/.config/opencode/opencode.json')
        if not session_config or os.path.realpath(os.path.expanduser(session_config)) == os.path.realpath(
                shared_config):
            return override
        print(f'  Ignoring AIDEVOPS_OPENCODE_PROFILE={override} from isolated runtime session '
              f'(OPENCODE_CONFIG targets another file)', file=sys.stderr)
    return installed_profile(document) or document['default']


def format_value(value):
    """Render a profile field for shell consumers."""
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, (dict, list)):
        return json.dumps(value, separators=(',', ':'))
    return value


def profile_field(document, profile_id, field):
    try:
        return format_value(document['profiles'][profile_id][field])
    except KeyError as error:
        raise SystemExit(f'Unknown OpenCode profile field: {error.args[0]}') from error


def selected_command(document, args):
    profile_id = selected_id(document)
    return profile_field(document, profile_id, args[0]) if args else profile_id


USAGE = ('Usage: opencode-runtime-profile.py default | selected [FIELD] | detect VERSION | '
         'installed [BINARY] | shared | get PROFILE FIELD')

# command -> (accepted argument counts, or None for any; handler(document, args))
COMMANDS = {
    'default': (None, lambda document, _args: document['default']),
    'selected': (None, selected_command),
    'detect': ((1,), lambda document, args: profile_for_version(document, args[0])),
    'installed': ((0, 1), lambda document, args: installed_profile(document, args[0] if args else None)),
    'shared': ((0,), lambda document, _args: shared_config_profile(document)),
    'get': ((2,), lambda document, args: profile_field(document, args[0], args[1])),
}


def main(argv):
    document = profile_document()
    command = argv[1] if len(argv) > 1 else 'selected'
    args = argv[2:]
    arities, handler = COMMANDS.get(command, ((), None))
    if handler is None or (arities is not None and len(args) not in arities):
        raise SystemExit(USAGE)
    print(handler(document, args))


if __name__ == '__main__':
    main(sys.argv)
