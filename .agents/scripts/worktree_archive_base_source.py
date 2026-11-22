#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bind independent base recovery to explicit, live repository authority."""

import os
from pathlib import Path
from urllib.parse import urlsplit


MISSING_PROMISOR_BASE = (
    'producer:missing-promisor-object; complete recorded base unavailable locally; '
    'source and archive retained; authorize independent recovery with '
    'AIDEVOPS_WORKTREE_BASE_RECOVERY_SOURCE and AIDEVOPS_WORKTREE_BASE_RECOVERY_COMMON_DIR '
    'matching the current repository origin and common directory; the origin must allow fetching '
    'the exact recorded base by object ID (uploadpack.allowReachableSHA1InWant or '
    'allowAnySHA1InWant) when it is no longer an advertised ref tip; prior scratch requires review')


def authorized_base_source(root, common, run_git):
    """Bind explicit operator consent to live repository context, not archive URLs.

    Both variables are invocation-only authority. SOURCE must exactly equal the
    current origin; COMMON_DIR pins which repository that consent applies to.
    Only HTTPS (no embedded credentials/redirects) and explicit local file URLs
    are supported. Preserve the installed shim, auth routing and Git environment.
    """
    source = os.environ.get('AIDEVOPS_WORKTREE_BASE_RECOVERY_SOURCE', '')
    authorized = Path(os.environ.get('AIDEVOPS_WORKTREE_BASE_RECOVERY_COMMON_DIR', ''))
    if not all((source, authorized.is_absolute(), authorized.resolve() == common.resolve())):
        raise ValueError(MISSING_PROMISOR_BASE)
    live = run_git(common, 'rev-parse', '--path-format=absolute', '--git-common-dir')
    if Path(os.fsdecode(live.strip())).resolve() != authorized.resolve():
        raise ValueError(MISSING_PROMISOR_BASE)
    origin = run_git(common, 'config', '--local', '--get', 'remote.origin.url')
    if origin.decode('utf-8').strip() != source:
        raise ValueError(MISSING_PROMISOR_BASE)
    parsed = urlsplit(source)
    forbidden = (any(ord(character) < 33 for character in source), parsed.query, parsed.fragment,
                 parsed.username is not None, parsed.password is not None)
    if any(forbidden):
        raise ValueError(MISSING_PROMISOR_BASE)
    if all((parsed.scheme == 'https', parsed.hostname, parsed.path.startswith('/'))):
        protocol = 'https'
    elif (parsed.scheme == 'file' and not parsed.netloc and parsed.path.startswith('/')
          and Path(parsed.path).resolve().as_uri() == source):
        protocol = 'file'
    else:
        raise ValueError(MISSING_PROMISOR_BASE)
    # --get-url expands insteadOf without contacting anything. Refuse rewrites,
    # including inherited global policy: explicit consent names the exact URL.
    effective = run_git(root, 'ls-remote', '--get-url', source)
    if effective.decode('utf-8').strip() != source:
        raise ValueError(MISSING_PROMISOR_BASE)
    return source, protocol
