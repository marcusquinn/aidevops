#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Dependency-free workflow self-listen check used by lint-workflows-helper.sh.

Flags a workflow whose on.workflow_run.workflows names its own top-level name.
Handles block lists, flow lists (multi-line, quoted commas) and trailing comments.
"""

import re
import sys

DQ = r'"(?:[^"\\]|\\.)*"'
SQ = r"'(?:[^']|'')*'"
COMMENT = re.compile('(' + DQ + '|' + SQ + r')|(?:(?<=\s)|^)#.*')
ITEM = re.compile('(' + DQ + '|' + SQ + r'|[^,\[\]\s][^,\]]*)')
FLOW = re.compile(r'\[((?:' + DQ + '|' + SQ + r'|[^\]"\'])*)\]')
BLOCK_ITEM = re.compile(r'^\s*-\s*(.+)$')
SCALAR_STOP = re.compile(r'[,}\]]+\s*$')


def uncomment(line):
    """Drop a trailing YAML comment, keeping quoted '#' characters."""
    return COMMENT.sub(lambda m: m.group(1) or '', line)


def unq(text):
    """Strip surrounding YAML quotes and decode their escapes."""
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] == "'":
        return text[1:-1].replace("''", "'")
    if len(text) >= 2 and text[0] == text[-1] == '"':
        return re.sub(r'\\(.)', r'\1', text[1:-1])
    return text


def flow_items(text):
    """Items of the first [...] flow sequence in text."""
    match = FLOW.search(text)
    body = match.group(1) if match else ''
    return [unq(item) for item in ITEM.findall(body)]


def block_items(lines):
    """Items of a block sequence; stops at the first non-item line."""
    items = []
    for line in lines:
        if not line.strip():
            continue
        match = BLOCK_ITEM.match(line)
        if not match:
            break
        items.append(unq(match.group(1)))
    return items


def listed_names(lines, index, value):
    """Workflow names declared by the `workflows:` key at lines[index]."""
    if value.startswith('['):
        return flow_items('\n'.join([value] + lines[index + 1:]))
    if value:
        return [unq(SCALAR_STOP.sub('', value))]
    return block_items(lines[index + 1:])


def declared_names(lines):
    """Names under any `workflows:` key that follows a workflow_run key."""
    names = []
    seen_run = False
    for i, line in enumerate(lines):
        seen_run = seen_run or 'workflow_run' in line
        match = re.search(r'\bworkflows:\s*(.*)$', line)
        if seen_run and match:
            names += listed_names(lines, i, match.group(1).strip())
    return names


def workflow_name(lines):
    for line in lines:
        match = re.match(r'^name:\s*(.+)$', line)
        if match:
            return unq(match.group(1))
    return None


def main(path):
    with open(path, encoding='utf-8') as source:
        lines = [uncomment(line.rstrip('\n')) for line in source]
    name = workflow_name(lines)
    if not name or name not in declared_names(lines):
        return 0
    print(
        path + ': workflow_run.workflows names its own name ' + repr(name)
        + ' (GitHub: cannot listen to itself). Move the listener into a separate workflow.',
        file=sys.stderr,
    )
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
