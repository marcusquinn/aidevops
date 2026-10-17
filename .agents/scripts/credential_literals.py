#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Conservative literal-only shell parsing and safe credential file reads."""
import os
import re
import stat

SECRET_NAME = re.compile(r'(?:^|_)(?:KEY|TOKEN|SECRET|PASSWORD|PASS|CREDENTIALS?)$')
EXPORT = re.compile(r'export ([A-Z_][A-Z0-9_]*)=(.*)')


def literal(raw):
    """Keep the migration parser's deliberately conservative eligibility rules."""
    if raw.startswith('"') and raw.endswith('"'):
        return quoted_literal(raw)
    if re.fullmatch(r'[A-Za-z0-9_./:@%+,=-]+', raw):
        return raw
    return None


def quoted_literal(raw):
    if len(raw) < 2:
        return None
    raw = raw[1:-1]
    result = []
    index = 0
    while index < len(raw):
        char = raw[index]
        if char == '\\':
            index += 1
            if index == len(raw) or raw[index] not in '\\"':
                return None
            char = raw[index]
        elif char in '"$`':
            return None
        result.append(char)
        index += 1
    return ''.join(result)


def finding(path, line, name, category, **extra):
    return dict(file=str(path), line=line, name=name, category=category, **extra)


def physical_lines(original):
    # Shell terminates lines only at LF, not Python's broader Unicode separators.
    parts = original.split('\n')
    return [part + '\n' for part in parts[:-1]] + ([parts[-1]] if parts[-1] else [])


def parse(original, path):
    assignments, findings = [], []
    for index, line in enumerate(physical_lines(original)):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        match = EXPORT.fullmatch(line.rstrip('\n'))
        name = match[1] if match else ''
        raw = match[2] if match else ''
        category = line_category(line, match, raw)
        if category:
            findings.append(finding(path, index + 1, name, category))
        else:
            assignments.append((index, name, raw))
    return assignments, findings


def line_category(line, match, raw):
    if '\r' in line:
        return 'crlf'
    if re.search(r'export\s+[A-Z_][A-Z0-9_]*=', raw):
        return 'glued-exports'
    if not match or any(char in line for char in '\0\v\f\x1c\x1d\x1e\x85\u2028\u2029'):
        return 'unsupported-structure'
    return value_category(raw)


def value_category(raw):
    if '$' in raw or '`' in raw:
        return 'shell-expansion'
    if raw and literal(raw) is None:
        return 'inner-quote' if '"' in raw[1:-1] else 'unsupported-structure'
    return None


def read_source(path, private=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'r', encoding='utf-8', newline='') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 4 * 1024 * 1024:
            raise ValueError('unsafe source')
        if private and (info.st_uid != os.getuid() or info.st_mode & 0o077):
            raise ValueError('unsafe source')
        return source.read(), info
