#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded, read-only project .env discovery. Emit names and metadata, never values."""
import functools
import json
import os
import re
import time
from pathlib import Path
from subprocess import SubprocessError  # nosec B404

from credential_literals import SECRET_NAME, finding, literal, read_source
from credential_process import run

REGISTRY = '.config/aidevops/repos.json'
SKIP_DIRS = frozenset(('.git', 'node_modules', '.venv'))
# Committed templates (.env.example, .env.local.template, ...) are expected and skipped.
TEMPLATE_SUFFIXES = ('.example', '.sample', '.template', '.dist')
ASSIGNMENT = re.compile(r'\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)')
QUOTED = re.compile(r'''('[^']*'|"(?:\\.|[^"\\])*")\s*(?:#.*)?''')
UNSAFE_BARE = re.compile(r'''[$`'"\x00]''')
MAX_DEPTH = 2
MAX_ENTRIES = 10000
TIME_BUDGET_SECONDS = 15


class Budget:
    """Shared directory-entry and wall-clock bound for the whole sweep."""

    def __init__(self):
        self.deadline = time.monotonic() + TIME_BUDGET_SECONDS
        self.entries = 0

    def spend(self):
        self.entries += 1
        return self.entries <= MAX_ENTRIES and time.monotonic() <= self.deadline


def expand(home, path):
    return Path(str(home) + path[1:]) if path.startswith('~/') else Path(path)


def registered_roots(home):
    """Return repos.json paths; None when the registry exists but cannot be read."""
    try:
        text, _ = read_source(home / REGISTRY)
        repos = json.loads(text).get('initialized_repos', [])
        return [expand(home, repo['path']) for repo in repos
                if isinstance(repo.get('path'), str) and repo['path']]
    except FileNotFoundError:
        return []
    except (OSError, UnicodeError, ValueError, TypeError, AttributeError):
        return None


def is_env_name(name):
    return (name == '.env' or name.startswith('.env.')) and not name.endswith(TEMPLATE_SUFFIXES)


def walk_root(root, budget):
    """Yield candidate paths below root; yield None once if the budget runs out."""
    for directory, dirs, files in os.walk(root, followlinks=False):
        if not budget.spend():
            yield None
            return
        depth = len(Path(directory).relative_to(root).parts)
        dirs[:] = [name for name in dirs if name not in SKIP_DIRS] if depth < MAX_DEPTH else []
        yield from (Path(directory) / name for name in files if is_env_name(name))


def env_paths(roots):
    budget = Budget()
    seen = set()
    for root in dict.fromkeys(roots):
        for path in walk_root(root, budget):
            if path is None:
                yield None
                return
            if path not in seen:
                seen.add(path)
                yield path


def in_work_tree(path):
    # Pure path check: .env files outside any repository have no Git exposure.
    return any(os.path.lexists(parent / '.git') for parent in path.parents)


def git_status(path):
    if not in_work_tree(path):
        return None
    args = ['git', '-C', str(path.parent)]
    try:
        if run(args + ['ls-files', '--error-unmatch', '--', path.name]).returncode == 0:
            return 'tracked-env', 'high'
        ignored = run(args + ['check-ignore', '-q', '--', path.name]).returncode
    except (OSError, SubprocessError):
        return 'env-git-unavailable', 'medium'
    return {0: None, 1: ('unignored-env', 'medium')}.get(ignored, ('env-git-unavailable', 'medium'))


def quoted_value(raw):
    match = QUOTED.fullmatch(raw)
    if not match:
        return None
    quoted = match[1]
    return quoted[1:-1] if quoted.startswith("'") else literal(quoted)


def dotenv_literal(raw):
    """Recognise dotenv quoting/comments without executing or expanding anything."""
    if raw.startswith(("'", '"')):
        return quoted_value(raw)
    raw = re.split(r'\s+#', raw, maxsplit=1)[0].rstrip()
    unsafe = raw.startswith('#') or UNSAFE_BARE.search(raw)
    return None if unsafe else raw


def secret_literals(text):
    """Yield (line, name) for secret-shaped names assigned non-empty literals."""
    for line, source in enumerate(text.split('\n'), 1):
        match = ASSIGNMENT.fullmatch(source)
        if match and SECRET_NAME.search(match[1]) and dotenv_literal(match[2].strip()):
            yield line, match[1]


def gopass_checker(helper):
    @functools.lru_cache(maxsize=None)
    def present(name):
        try:
            return run(['bash', str(helper), 'check', name]).returncode == 0
        except (OSError, SubprocessError):
            return False
    return present


def audit_env_file(path, present):
    status = git_status(path)
    if status:
        yield finding(path, 0, '', status[0], severity=status[1])
    try:
        text, _ = read_source(path)
    except (OSError, UnicodeError, ValueError):
        yield finding(path, 0, '', 'unreadable-env', severity='medium')
        return
    for line, name in secret_literals(text):
        yield finding(path, line, name, 'env-literal', severity='low', in_gopass=present(name))


def env_files(home, helper):
    roots = registered_roots(home)
    if roots is None:
        yield finding(home / REGISTRY, 0, '', 'env-discovery-incomplete', severity='medium')
    present = gopass_checker(helper)
    for path in env_paths([home / 'Git', *(roots or [])]):
        if path is None:
            yield finding(home / 'Git', 0, '', 'env-discovery-incomplete', severity='medium')
        else:
            yield from audit_env_file(path, present)
