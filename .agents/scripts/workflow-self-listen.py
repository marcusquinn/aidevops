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
    if len(s) >= 2 and s[0] == s[-1] == "'":
        return s[1:-1].replace("''", "'")
    if len(s) >= 2 and s[0] == s[-1] == '"':
        return decode_double(s[1:-1])
    return s


def decode_double(s):
    """Decode common YAML double-quoted escapes."""
    bs = chr(92)
    simple = {'n': '\n', 't': '\t', 'r': '\r', '0': '\0', '/': '/', ' ': ' ',
              '"': '"', bs: bs}
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == bs and i + 1 < len(s):
            n = s[i + 1]
            width = {'x': 2, 'u': 4, 'U': 8}.get(n)
            digits = s[i + 2:i + 2 + width] if width else ''
            if width and re.fullmatch(r'[0-9a-fA-F]{%d}' % width, digits):
                out.append(chr(int(digits, 16)))
                i += 2 + width
                continue
            out.append(simple.get(n, c + n))
            i += 2
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def parse_scalar(s, i, stops):
    while i < len(s) and s[i].isspace():
        i += 1
    start = i
    if i < len(s) and s[i] in '"\'':
        q = s[i]
        i += 1
        while i < len(s):
            if q == '"' and s[i] == chr(92):
                i += 2
                continue
            if s[i] == q:
                if q == "'" and i + 1 < len(s) and s[i + 1] == q:
                    i += 2
                    continue
                i += 1
                break
            i += 1
        return unq(s[start:i]), i
    while i < len(s) and s[i] not in stops:
        i += 1
    return s[start:i].strip(), i


def parse_flow(s, i=0):
    """Parse a YAML flow node at s[i]; return (value, next_index)."""
    while i < len(s) and s[i].isspace():
        i += 1
    if i >= len(s):
        return '', i
    if s[i] == '{':
        out = {}
        i += 1
        while i < len(s):
            while i < len(s) and (s[i].isspace() or s[i] == ','):
                i += 1
            if i >= len(s) or s[i] == '}':
                return out, i + 1
            key, i = parse_scalar(s, i, ':,}')
            while i < len(s) and s[i].isspace():
                i += 1
            val = ''
            if i < len(s) and s[i] == ':':
                val, i = parse_flow(s, i + 1)
            out[key] = val
        return out, i
    if s[i] == '[':
        out = []
        i += 1
        while i < len(s):
            while i < len(s) and (s[i].isspace() or s[i] == ','):
                i += 1
            if i >= len(s) or s[i] == ']':
                return out, i + 1
            val, i = parse_flow(s, i)
            out.append(val)
        return out, i
    return parse_scalar(s, i, ',]}')


def flow_listens(text, name):
    """True if flow text (mapping with workflow_run, or workflow_run body) lists name."""
    tree, _ = parse_flow(text)
    if isinstance(tree, dict) and isinstance(tree.get('workflow_run'), dict):
        tree = tree['workflow_run']
    if not isinstance(tree, dict):
        return False
    wf = tree.get('workflows')
    return name in (wf if isinstance(wf, list) else [wf])


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
        on_match = re.match(r'^[\'\"]?on[\'\"]?:\s*(.*)$', line)
        if not on_match:
            continue
        on_val = on_match.group(1).strip()
        found = False
        if on_val.startswith('{'):
            found = flow_listens('\n'.join([on_val] + lines[i + 1:]), name)
        elif not on_val:
            on_block = block(lines, i)
            for j, event_line in enumerate(on_block):
                ev = re.match(r'^\s+workflow_run:\s*(.*)$', event_line)
                if not ev:
                    continue
                ev_val = ev.group(1).strip()
                if ev_val.startswith('{'):
                    found = found or flow_listens('\n'.join([ev_val] + on_block[j + 1:]), name)
                elif not ev_val:
                    found = found or name in workflow_names(block(on_block, j))
        if found:
            print(
                path + ': workflow_run.workflows names its own name ' + repr(name)
                + ' (GitHub: cannot listen to itself). Move the listener into a separate workflow.',
                file=sys.stderr,
            )
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
