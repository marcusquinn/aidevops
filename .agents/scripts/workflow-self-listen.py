#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Dependency-free workflow self-listen check used by lint-workflows-helper.sh."""

import re
import sys


def unquoted(s):
    """Yield characters outside YAML quotes, respecting escapes/doubled quotes."""
    quote = None
    i = 0
    while i < len(s):
        c = s[i]
        if quote:
            if quote == '"' and c == chr(92):
                i += 2
                continue
            if c == quote:
                if quote == "'" and i + 1 < len(s) and s[i + 1] == quote:
                    i += 2
                    continue
                quote = None
        elif c in '\"\'' and (i == 0 or s[i - 1].isspace() or s[i - 1] in '[,'):
            quote = c
        else:
            yield i, c
        i += 1


def uncomment(s):
    for i, c in unquoted(s):
        if c == '#' and (i == 0 or s[i - 1].isspace()):
            return s[:i]
    return s


def indent(line):
    return len(line) - len(line.lstrip(' '))


def unq(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in '\"\'':
        return s[1:-1]
    return s


def block(lines, start):
    """Collect child lines without treating comments/blanks as boundaries."""
    base = indent(lines[start])
    out = []
    for line in lines[start + 1:]:
        if line.strip() and indent(line) <= base:
            break
        out.append(line)
    return out


def flow_items(s):
    start = 1
    for i, c in unquoted(s):
        if c in ',]':
            item = s[start:i].strip()
            if item:
                yield unq(item)
            start = i + 1
            if c == ']':
                return


def workflow_names(run_block):
    for k, line in enumerate(run_block):
        match = re.match(r'^\s+workflows:\s*(.*)$', line)
        if not match:
            continue
        val = match.group(1).strip()
        if val.startswith('['):
            yield from flow_items('\n'.join([val] + run_block[k + 1:]))
        elif val:
            yield unq(val)
        else:
            base = indent(line)
            for item_line in run_block[k + 1:]:
                item = re.match(r'^\s*-\s*(.+)$', item_line)
                if item_line.strip() and (
                    indent(item_line) < base or (indent(item_line) == base and not item)
                ):
                    break
                if item:
                    yield unq(item.group(1))


def main(path):
    with open(path, encoding='utf-8') as source:
        lines = [uncomment(line.rstrip('\n')) for line in source]
    name = None
    for line in lines:
        match = re.match(r'^name:\s*(.+)$', line)
        if match:
            name = unq(match.group(1))
            break
    if not name:
        return 0
    for i, line in enumerate(lines):
        if not re.match(r'^[\'\"]?on[\'\"]?:\s*$', line):
            continue
        on_block = block(lines, i)
        for j, event_line in enumerate(on_block):
            if not re.match(r'^\s+workflow_run:\s*$', event_line):
                continue
            if name in workflow_names(block(on_block, j)):
                print(
                    path + ': workflow_run.workflows names its own name ' + repr(name)
                    + ' (GitHub: cannot listen to itself). Move the listener into a separate workflow.',
                    file=sys.stderr,
                )
                return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
