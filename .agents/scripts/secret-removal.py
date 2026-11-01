#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Plaintext-loader and registry parts of `aidevops secret rm` (GH#35850).

gopass removal and confirmation stay in secret-helper.sh. This helper prints
secret names only and never reads, prints or stores a secret value.

  plaintext FILE NAME...   remove single-line literal exports from FILE
  warnings NAME            registry record and local dependents (names/counts)
  registry NAME...         drop registry records (and defaults pointing at them)
"""
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from credential_literals import parse, physical_lines, read_source  # noqa: E402
from credential_migration import replace_pruned  # noqa: E402

NAME = re.compile(r'[A-Z][A-Z0-9_]*')


def remove_plaintext(path, names):
    """Remove exports of names; refuse when a target line is unparseable."""
    try:
        original, info = read_source(path, private=True)
    except FileNotFoundError:
        return 0
    lines = physical_lines(original)
    assignments, findings = parse(original, path)
    for name in names:
        if any(f'{name}=' in lines[record['line'] - 1] for record in findings):
            print(f'Cannot safely edit {name}: unsupported shell structure in the store', file=sys.stderr)
            return 1
    removed = {index for index, name, _ in assignments if name in names}
    if removed:
        replace_pruned(path, info, lines, removed)
        for name in sorted({name for index, name, _ in assignments if index in removed}):
            print(f'Removed {name} from the plaintext store')
    return 0


def warnings(name):
    import credential_inventory_dependents as dependents
    import credential_inventory_names as names
    import credential_inventory_store as store

    data = store.load()
    if name in data['credentials']:
        print(f'registry: {name} is still described in the credential registry')
    related = names.related_names(data, name)
    result = dependents.find_dependents(related)
    count = len(result['literal'])
    if count:
        print(f'dependents: {count} literal reference(s) to {name}; see: aidevops secret dependents {name}')
    elif not result['complete']:
        print(f'dependents: scan incomplete for {name}; see: aidevops secret dependents {name}')
    return 0


def remove_registry(names):
    import credential_inventory_store as store

    with store.locked() as data:
        for name in names:
            if data['credentials'].pop(name, None) is None:
                continue
            for provider in [p for p, value in data['defaults'].items() if value == name]:
                data['defaults'].pop(provider)
            print(f'Removed {name} from the credential registry')
    return 0


def main(argv):
    command, args = (argv[0], argv[1:]) if argv else ('', [])
    if command == 'plaintext' and len(args) >= 2 and all(NAME.fullmatch(n) for n in args[1:]):
        return remove_plaintext(args[0], set(args[1:]))
    if command == 'warnings' and len(args) == 1 and NAME.fullmatch(args[0]):
        return warnings(args[0])
    if command == 'registry' and args and all(NAME.fullmatch(n) for n in args):
        return remove_registry(args)
    print('Usage: secret-removal.py plaintext FILE NAME... | warnings NAME | registry NAME...', file=sys.stderr)
    return 2


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as error:  # noqa: BLE001 - report class only, never content
        print(f'Secret removal step failed safely ({type(error).__name__})', file=sys.stderr)
        sys.exit(1)
