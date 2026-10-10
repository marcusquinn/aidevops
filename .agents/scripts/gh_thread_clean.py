#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Clean a GitHub issue/PR JSON thread for token-efficient reading.

Used by gh-thread-clean-helper.sh. Reads one JSON file path (argv[1]) and
prints the body and comments without aidevops signatures, provenance/ops
blocks, badges, common bot status noise or Code Scanning onboarding text.
"""
import json
import re
import sys

BOT_STATUS = re.compile(r'(review skipped|review failed|quota|configuration error|badge|sonarcloud summary|codacy summary)', re.I)
BLOCKS = [
    re.compile(r'<!--\s*(?:provenance|ops|internal state)\s*:start.*?<!--\s*(?:provenance|ops|internal state)\s*:end\s*-->', re.I | re.S),
    re.compile(r'<!--\s*aidevops:sig\s*-->.*?(?=\n\n|\Z)', re.I | re.S),
]
FOOTER = re.compile(r'\n---\n.*?aidevops\.sh.*?\Z', re.I | re.S)
BADGE = re.compile(r'^\s*!\[[^\]]*\]\([^)]*\)\s*$', re.M)
# Match only the complete informational template, never a security finding or
# a comment with extra text. Repository/PR-specific overview links may vary.
CODE_SCANNING_ONBOARDING = re.compile(
    re.escape('You are seeing this message because GitHub Code Scanning has recently been set up for this repository, or this pull request contains the workflow file for the Code Scanning tool.\n\n'
              '### What Enabling Code Scanning Means:\n\n'
              "- The 'Security' tab will display more code scanning analysis results (e.g., for the default branch).\n"
              '- Depending on your configuration and choice of analysis tool, future pull requests will be annotated with code scanning analysis results.\n'
              "- You will be able to see the analysis results for the pull request's branch on this [overview](")
    + r'[^\s()]+'
    + re.escape(') once the scans have completed and the checks have passed.\n\n'
                'For more information about GitHub Code Scanning, check out [the documentation](https://docs.github.com/code-security/code-scanning/introduction-to-code-scanning/about-code-scanning).')
)


def clean_body(value):
    if not value:
        return ""
    text = str(value)
    for pattern in BLOCKS:
        text = pattern.sub('', text)
    text = FOOTER.sub('', text)
    text = BADGE.sub('', text)
    lines = []
    for line in text.splitlines():
        if BOT_STATUS.search(line) and not re.search(r'\b[\w./-]+:\d+\b', line):
            continue
        lines.append(line.rstrip())
    text = '\n'.join(lines)
    text = re.sub(r'\n{3,}', '\n\n', text).strip()
    return text


def emit_record(prefix, body):
    cleaned = clean_body(body)
    if cleaned:
        print(f'## {prefix}')
        print()
        print(cleaned)
        print()


def list_records(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        nodes = value.get('nodes')
        if isinstance(nodes, list):
            return nodes
        return [value]
    return []


def author_login(item):
    author = item.get('author')
    if isinstance(author, dict):
        return author.get('login')
    user = item.get('user')
    if isinstance(user, dict):
        return user.get('login')
    return None


def main(path):
    with open(path, encoding='utf-8', errors='replace') as handle:
        raw = handle.read()
    if not raw.strip():
        return 0
    data = json.loads(raw)
    if isinstance(data, dict):
        if 'body' in data:
            emit_record('Body', data.get('body'))
        comments = list_records(data.get('comments') or data.get('nodes'))
    elif isinstance(data, list):
        comments = list_records(data)
    else:
        comments = []

    for index, item in enumerate(comments, 1):
        if not isinstance(item, dict):
            continue
        author = author_login(item)
        # Check the original body so generic cleaning cannot erase extra findings
        # and accidentally turn a mixed security comment into onboarding-only noise.
        if author == 'github-advanced-security[bot]' and CODE_SCANNING_ONBOARDING.fullmatch(str(item.get('body') or '').strip()):
            continue
        body = clean_body(item.get('body', ''))
        if not body:
            continue
        if BOT_STATUS.search(body) and not re.search(r'\b[\w./-]+:\d+\b', body):
            continue
        emit_record(f'Comment {index} ({author or "unknown"})', body)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
