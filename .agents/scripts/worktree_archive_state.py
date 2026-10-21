#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Check whether a worktree's Git state is supported by archival."""

import os
from pathlib import Path
import hashlib
import json
import re
import stat
import tarfile

from worktree_archive_administration import (
    administration, git,
)
from worktree_archive_auto_merge import auto_merge as auto_merge


MERGE_FILES = {'MERGE_HEAD', 'MERGE_MSG', 'MERGE_MODE', 'ORIG_HEAD', 'AUTO_MERGE'}


def merge_pending(root):
    admin = Path(os.fsdecode(git(root, 'rev-parse', '--absolute-git-dir').rstrip(b'\n')))
    return os.path.lexists(admin / 'MERGE_HEAD')


def merge_path(value):
    raw = bytes.fromhex(value)
    parts = raw.split(b'/')
    if raw.hex() != value or not raw or b'\0' in raw or any(part in (b'', b'.', b'..') or part.lower() == b'.git' for part in parts):
        raise ValueError('merge:unsafe_path')
    return raw


def merge_oid(value):
    if not isinstance(value, str) or not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', value) or set(value) == {'0'}:
        raise ValueError('merge:invalid_oid')
    return value


def merge_entries(root, option):
    result = []
    for entry in git(root, 'ls-files', option, '-z').split(b'\0'):
        if entry:
            metadata, path = entry.split(b'\t', 1)
            mode, oid, stage = metadata.decode('ascii').split()
            result.append([path.hex(), mode, oid, int(stage)])
    return result


def validate_merge(state):
    if not isinstance(state, dict) or set(state) != {'schema', 'head', 'metadata', 'index', 'undo', 'working'} or state['schema'] != 1:
        raise ValueError('merge:invalid_state')
    merge_oid(state['head'])
    metadata = state['metadata']
    if not isinstance(metadata, dict) or not {'MERGE_HEAD', 'MERGE_MSG', 'ORIG_HEAD'}.issubset(metadata) or set(metadata) - MERGE_FILES:
        raise ValueError('merge:invalid_metadata')
    decoded = {name: bytes.fromhex(value) for name, value in metadata.items()}
    parents = decoded['MERGE_HEAD'].splitlines()
    if not parents or len(set(parents)) != len(parents) or decoded['MERGE_HEAD'] != b'\n'.join(parents) + b'\n':
        raise ValueError('merge:invalid_parents')
    from worktree_archive_git import auto_merge_oid
    auto_merge_oid(decoded['ORIG_HEAD'])
    for value in parents:
        merge_oid(value.decode('ascii'))
    if decoded.get('MERGE_MODE', b'') not in (b'', b'no-ff'):
        raise ValueError('merge:unsupported_mode')
    if 'AUTO_MERGE' in decoded:
        auto_merge_oid(decoded['AUTO_MERGE'])
    paths = set()
    for name, stages in (('index', {0, 1, 2, 3}), ('undo', {1, 2, 3})):
        seen = {}
        for path, mode, oid, stage in state[name]:
            raw = merge_path(path)
            if mode not in ('100644', '100755') or type(stage) is not int or stage not in stages:
                raise ValueError('merge:unsupported_index_entry')
            merge_oid(oid)
            current = seen.setdefault(raw, set())
            if stage in current or (current and (stage == 0 or 0 in current)):
                raise ValueError('merge:duplicate_index_entry')
            current.add(stage)
            paths.add(path)
    working = state['working']
    if not isinstance(working, dict) or not paths.issubset(working):
        raise ValueError('merge:incomplete_working_files')
    for path, value in working.items():
        raw = merge_path(path)
        if any(b'/'.join(raw.split(b'/')[:number]).hex() in working for number in range(1, len(raw.split(b'/')))):
            raise ValueError('merge:directory_file_conflict')
        if value is not None:
            if not isinstance(value, list) or len(value) != 2 or value[0] not in (0o644, 0o755):
                raise ValueError('merge:invalid_working_file')
            bytes.fromhex(value[1])
    return state


def merge_roots(state):
    roots = {state['head']}
    for name in ('MERGE_HEAD', 'ORIG_HEAD', 'AUTO_MERGE'):
        for line in bytes.fromhex(state['metadata'].get(name, '')).splitlines():
            roots.add(merge_oid(line.decode('ascii')))
    roots.update(entry[2] for entry in state['index'] + state['undo'])
    return sorted(roots)


def verify_merge_objects(root, state):
    roots = merge_roots(state)
    for oid in [state['head']] + [line.decode('ascii') for name in ('MERGE_HEAD', 'ORIG_HEAD')
                               for line in bytes.fromhex(state['metadata'][name]).splitlines()]:
        if git(root, 'cat-file', '-t', oid).strip() != b'commit':
            raise ValueError('merge:parent_not_commit')
    for _, _, oid, _ in state['index'] + state['undo']:
        if git(root, 'cat-file', '-t', oid).strip() != b'blob':
            raise ValueError('merge:index_not_blob')
    if 'AUTO_MERGE' in state['metadata']:
        from worktree_archive_git import validate_auto_merge
        validate_auto_merge(root, bytes.fromhex(state['metadata']['AUTO_MERGE']).strip().decode('ascii'))
    closure = git(root, 'rev-list', '--objects', '--no-object-names', '--stdin',
                  data=('\n'.join(roots) + '\n').encode('ascii'))
    checked = git(root, 'cat-file', '--batch-check', data=closure)
    if len(checked.splitlines()) != len(closure.splitlines()) or any(line.endswith(b' missing') for line in checked.splitlines()):
        raise ValueError('merge:missing_object')


def merge_state(root):
    """Capture a supported merge structurally; never copy a raw index or reflog."""
    from worktree_archive_filesystem import fingerprint, open_parent
    state = administration(root, allow_merge=True)
    if state['refs'] or 'SQUASH_MSG' in state['files'] or 'config.worktree' in state['files']:
        raise ValueError('merge:unsupported_private_state')
    if git(root, 'rev-parse', '--is-shallow-repository').strip() != b'false':
        raise ValueError('merge:shallow_history')
    draft = bytes.fromhex(state['files'].get('COMMIT_EDITMSG', '')).rstrip(b'\n')
    if draft and draft != git(root, 'log', '-1', '--format=%B').rstrip(b'\n'):
        raise ValueError('merge:uncommitted_message_draft')
    if state['files'].get('FETCH_HEAD'):
        raise ValueError('merge:unpreserved_fetch_head')
    entries = merge_entries(root, '--stage')
    undo = merge_entries(root, '--resolve-undo')
    flags = git(root, 'ls-files', '-v', '-z').split(b'\0')
    if any(entry and entry[:1] not in (b'H', b'M') for entry in flags):
        raise ValueError('merge:unsupported_index_flags')
    options = ('--cached', '--raw', '-z', '--no-ext-diff')
    if git(root, 'diff', *options, '--ita-visible-in-index') != git(root, 'diff', *options, '--ita-invisible-in-index'):
        raise ValueError('merge:intent_to_add')
    head = git(root, 'rev-parse', 'HEAD').strip().decode('ascii')
    paths = {entry[0] for entry in entries + undo}
    for entry in git(root, 'ls-tree', '-r', '-z', head).split(b'\0'):
        if entry:
            metadata, path = entry.split(b'\t', 1)
            if metadata.split()[0] not in (b'100644', b'100755'):
                raise ValueError('merge:unsupported_head_entry')
            paths.add(path.hex())
    attributes = git(root, 'check-attr', '-z', '--stdin', 'filter', data=b'\0'.join(bytes.fromhex(path) for path in sorted(paths)) + b'\0')
    if any(value not in (b'unspecified', b'unset') for value in attributes.split(b'\0')[2::3]):
        raise ValueError('merge:unsupported_filter')
    working = {}
    for path in sorted(paths):
        raw = merge_path(path)
        observed = fingerprint(root, raw)
        if observed == ['missing']:
            working[path] = None
        elif observed[0] == 'file':
            relative = Path(os.fsdecode(raw))
            parent = open_parent(root, relative.parts[:-1])
            try:
                descriptor = os.open(relative.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                with os.fdopen(descriptor, 'rb') as stream:
                    if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                        raise ValueError('merge:unsupported_file')
                    content = stream.read()
                if hashlib.sha256(content).hexdigest() != observed[3]:
                    raise ValueError('merge:source_changed')
                working[path] = [observed[1], content.hex()]
            finally:
                os.close(parent)
        else:
            raise ValueError('merge:symlink_not_supported')
    result = validate_merge({'schema': 1, 'head': head, 'metadata': {name: value for name, value in state['files'].items() if name in MERGE_FILES},
                             'index': entries, 'undo': undo, 'working': working})
    verify_merge_objects(root, result)
    return result


def merge_digest(state):
    return hashlib.sha256(json.dumps(state, sort_keys=True, separators=(',', ':')).encode('ascii')).hexdigest()


def load_merge(archive, manifest):
    state = validate_merge(json.loads((archive / 'merge-state-v1.json').read_text(encoding='ascii')))
    saved = manifest.get('source_fingerprint', {})
    if state['head'] != manifest['head_sha'] or merge_digest(state) != saved.get('merge_sha256'):
        raise ValueError('merge:fingerprint_mismatch')
    return state


def capture_merge(root, archive):
    from worktree_archive_git import capture_bundle
    if not merge_pending(root):
        return
    state = merge_state(root)
    # Full closure is intentional: MERGE_HEAD/ORIG_HEAD need not be ancestors of
    # HEAD or of the shared base. This bundle is independent of the source.
    capture_bundle(root, archive, merge_roots(state), '')
    (archive / 'merge-state-v1.json').write_text(json.dumps(state, sort_keys=True) + '\n', encoding='ascii')


def restore_merge(root, archive):
    from worktree_archive_git import fetch_preservation
    from worktree_archive_filesystem import open_parent
    manifest = json.loads((archive / 'manifest.json').read_text(encoding='ascii'))
    state = load_merge(archive, manifest)
    fetch_preservation(root, archive)
    verify_merge_objects(root, state)
    # Rebuild REUC via Git's normal resolve operations, including staged deletes.
    git(root, 'read-tree', '--empty')
    unresolved = state['undo'] + [entry for entry in state['index'] if entry[3] != 0]
    def index_info(entries):
        payload = b''.join(f'{mode} {oid} {stage}\t'.encode('ascii') + merge_path(path) + b'\0'
                           for path, mode, oid, stage in entries)
        if payload:
            git(root, 'update-index', '-z', '--index-info', data=payload)
    index_info(unresolved)
    index_info([entry for entry in state['index'] if entry[3] == 0])
    live = {entry[0] for entry in state['index']}
    for path in sorted({entry[0] for entry in state['undo']} - live):
        git(root, 'update-index', '--force-remove', '--', os.fsdecode(merge_path(path)))
    # Remove the clean checkout first, then create parents using no-follow file
    # descriptors. Symlinks and directory/file conflicts are deliberately refused.
    untracked = set()
    if (archive / 'untracked.tar.gz').exists():
        with tarfile.open(archive / 'untracked.tar.gz', 'r:gz') as payload:
            untracked = {os.fsencode(member.name).hex() for member in payload.getmembers()}
    for path, value in state['working'].items():
        if path in untracked:
            value = None  # The verified untracked payload owns these bytes.
        relative = Path(os.fsdecode(merge_path(path)))
        target = root / relative
        if target.is_symlink():
            raise ValueError('merge:symlink_target')
        if value is not None:
            target.parent.mkdir(parents=True, exist_ok=True)
        try:
            parent = open_parent(root, relative.parts[:-1])
        except FileNotFoundError:
            if value is None:
                continue
            raise
        try:
            if value is None:
                try:
                    os.unlink(relative.name, dir_fd=parent)
                except FileNotFoundError:
                    pass
            else:
                descriptor = os.open(relative.name, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW,
                                     0o600, dir_fd=parent)
                with os.fdopen(descriptor, 'wb') as stream:
                    stream.write(bytes.fromhex(value[1]))
                    os.fchmod(stream.fileno(), value[0])
        finally:
            os.close(parent)
    admin = Path(os.fsdecode(git(root, 'rev-parse', '--absolute-git-dir').rstrip(b'\n')))
    for name in MERGE_FILES:
        target = admin / name
        if os.path.lexists(target):
            if target.is_symlink() or not target.is_file():
                raise ValueError('merge:unsafe_admin_target')
            target.unlink()
        if name in state['metadata']:
            target.write_bytes(bytes.fromhex(state['metadata'][name]))


def inventories(root, include_ignored=False):
    index = git(root, "ls-files", "--stage", "-z")
    paths = set()
    for entry in index.split(b"\0"):
        if not entry:
            continue
        metadata, path = entry.split(b"\t", 1)
        mode, _, stage = metadata.split()
        if stage != b"0" or mode not in (b"100644", b"100755", b"120000"):
            raise ValueError("submodules or unmerged entries require separate preservation")
        paths.add(path)
    attributes = git(root, "check-attr", "-z", "--stdin", "filter", data=b"\0".join(sorted(paths)) + b"\0") if paths else b""
    fields = attributes.split(b"\0")
    if any(value not in (b"unspecified", b"unset") for value in fields[2::3]):
        raise ValueError("Git filters, including local LFS payloads, require separate preservation")
    excludes = () if include_ignored else ("--exclude-standard",)
    paths.update(path for path in git(root, "ls-files", "--others", *excludes, "-z").split(b"\0") if path)
    return index, sorted(paths)


def supported_state(root, preserve_git_admin=False, include_ignored=False):
    admin = Path(os.fsdecode(git(root, "rev-parse", "--absolute-git-dir").rstrip(b"\n")))
    if preserve_git_admin:
        administration(root)
    pending = ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD",
               "rebase-merge", "rebase-apply", "sequencer", "BISECT_LOG", "index.lock", "config.worktree", "SQUASH_MSG")
    if not preserve_git_admin and any((admin / name).exists() for name in pending):
        raise ValueError("unfinished Git operation is not supported for automatic archival")
    if not preserve_git_admin:
        supported_administration(root, admin)
    if git(root, "rev-parse", "--is-shallow-repository").strip() != b"false":
        raise ValueError("shallow history is not self-contained")
    if not include_ignored and git(root, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"):
        raise ValueError("ignored content requires a separate preservation decision")
    flags = git(root, "ls-files", "-v", "-z").split(b"\0")
    if any(entry and entry[:1] != b"H" for entry in flags):
        raise ValueError("special index flags or unmerged entries are unsupported")
    # ls-files --stage cannot distinguish intent-to-add from a staged empty blob.
    visible = git(root, "diff", "--cached", "--raw", "-z", "--no-ext-diff", "--ita-visible-in-index")
    invisible = git(root, "diff", "--cached", "--raw", "-z", "--no-ext-diff", "--ita-invisible-in-index")
    if visible != invisible and not preserve_git_admin:
        raise ValueError("intent-to-add index entries require separate preservation")
    if not preserve_git_admin:
        supported_history(root, admin)


def supported_administration(root, admin):
    if auto_merge(root) is not None:
        raise ValueError('AUTO_MERGE requires the unified metadata preservation path')
    common = Path(os.fsdecode(git(root, "rev-parse", "--path-format=absolute", "--git-common-dir").rstrip(b"\n")))
    if admin.resolve() == common.resolve():
        # Independent restores are full repositories. Managed source enrollment
        # separately refuses canonical repositories; only linked admin is removed.
        return
    allowed = {"HEAD", "index", "commondir", "gitdir", "ORIG_HEAD", "COMMIT_EDITMSG", "logs", "refs"}
    for entry in admin.iterdir():
        if entry.name not in allowed or entry.is_symlink():
            raise ValueError(f"unknown Git administrative state requires separate preservation: {entry.name!r}")
        if entry.name == "logs":
            if not entry.is_dir() or any(child.name != "HEAD" or child.is_symlink()
                                         or not child.is_file() for child in entry.iterdir()):
                raise ValueError("unknown Git administrative log requires separate preservation")
        elif entry.name == "refs":
            # Recent Git creates this empty directory for a new linked worktree.
            if not entry.is_dir() or any(entry.iterdir()):
                raise ValueError("private Git references require separate preservation")
        elif not entry.is_file():
            raise ValueError("unsupported Git administrative entry")


def supported_history(root, admin):
    revisions = git(root, "reflog", "show", "--format=%H", "HEAD")
    previous = admin / "ORIG_HEAD"
    if previous.exists():
        if previous.is_symlink():
            raise ValueError("symlinked Git administrative state")
        revisions += previous.read_bytes() + b"\n"
    # rev-list stops reading revisions at a blank line, so normalize ORIG_HEAD's
    # trailing newline before appending the exclusion.
    revisions = b"\n".join(line for line in revisions.splitlines() if line) + b"\n^HEAD\n"
    if git(root, "rev-list", "--max-count=1", "--stdin", data=revisions):
        raise ValueError("reflog-only or previous HEAD history requires separate preservation")
    if git(root, "for-each-ref", "--format=%(refname)", "refs/worktree/", "refs/bisect/", "refs/rewritten/"):
        raise ValueError("private worktree refs require separate preservation")
    message = admin / "COMMIT_EDITMSG"
    if message.exists():
        if message.is_symlink():
            raise ValueError("uncommitted message draft requires separate preservation")
        draft = message.read_bytes().rstrip(b"\n")
        if draft != git(root, "log", "-1", "--format=%B").rstrip(b"\n"):
            # Switching branches or merging can leave a previously committed
            # message here. Accept only an exact message in the archived ancestry.
            committed = git(root, "log", "-1", "--format=%B", "--fixed-strings",
                            "--grep=" + os.fsdecode(draft), "HEAD").rstrip(b"\n")
            if not draft or committed != draft:
                raise ValueError("uncommitted message draft requires separate preservation")
