#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fingerprint supported recovery contents; refuse states not preserved by archives.

This is read-only evidence, not permission to remove a worktree. Callers must
still establish ownership/quiescence and compare again immediately before removal.
Sampling is not atomic: cooperating-writer exclusion must cover verification and
removal; fingerprints do not fence arbitrary same-user writers.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from worktree_recovery_timing import timed

from worktree_archive_filesystem import fingerprint, supported_directories
from worktree_archive_untracked import (
    untracked_contents,
    verify_untracked_payload as verify_untracked_payload,
)
from worktree_archive_administration import (
    ADMIN_FILES, administration, git, load_administration,
    OPERATIONS as OPERATIONS,
)
from worktree_archive_state import auto_merge, inventories, supported_state
from worktree_archive_state import capture_merge, merge_digest, restore_merge
from worktree_archive_index import (
    archive_policies as archive_policies, git_index_state as git_index_state,
)
from worktree_archive_objects import (
    administration_roots, bundle_roots, capture_auto_merge,
    verify_auto_merge as verify_auto_merge,
    verify_git_objects as verify_git_objects,
)
from worktree_archive_auto_merge import restore_auto_merge as restore_auto_merge
from worktree_archive_git import (
    base_import_failure, base_upload_pack,
    capture_bundle as capture_bundle, fetch_preservation as fetch_preservation,
)


def administration_digest(state):
    # Keep fingerprints small enough for the existing shell/argv interface even
    # when a repository's raw index or reflog is many megabytes.
    payload = json.dumps(state, sort_keys=True, separators=(',', ':')).encode('ascii')
    return hashlib.sha256(payload).hexdigest()


def capture_administration(root, archive, include_ignored, base=''):
    supported_state(root, True, include_ignored)
    inventories(root)
    state = administration(root)
    roots = set(bundle_roots(root, state))
    if base:
        if not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', base):
            raise ValueError('git_admin:invalid_base')
        covered = git(root, 'rev-list', '--objects', '--no-object-names', base)
        roots.difference_update(oid.decode('ascii') for oid in covered.splitlines())
    if roots:
        capture_bundle(root, archive, sorted(roots), base)
    (archive / 'git-admin.json').write_text(json.dumps(state, sort_keys=True) + '\n', encoding='ascii')


def base_import_timeout():
    """Bounded budget for the local base-object import (default 300s, max 1800s)."""
    try:
        value = int(os.environ.get('AIDEVOPS_WORKTREE_BASE_IMPORT_TIMEOUT', '300'))
    except ValueError:
        value = 300
    return max(60, min(value, 1800))


@timed("base-import")
def seed_base(root, manifest):
    """Import only the recorded base graph, never unrelated source objects."""
    base = manifest['base_sha']
    common = Path(manifest.get('source_git_common_dir', ''))
    if not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', base):
        raise ValueError('git_admin:invalid_base')
    if not common.is_absolute() or not common.is_dir():
        raise ValueError('git_admin:base_repository_unavailable')
    try:
        git(root, '-c', 'core.hooksPath=/dev/null', 'fetch', '--quiet', '--no-tags',
            '--no-auto-maintenance', '--upload-pack=' + base_upload_pack(),
            '--no-write-fetch-head', str(common), base, timeout=base_import_timeout())
    except subprocess.CalledProcessError as error:
        raise ValueError(base_import_failure(error)) from error
    except subprocess.TimeoutExpired as error:
        raise ValueError('producer:base-import-timeout; local base import exceeded its time budget; '
                         'source and archive retained; retry when host load is lower or raise '
                         'AIDEVOPS_WORKTREE_BASE_IMPORT_TIMEOUT (seconds, max 1800)') from error
    git(root, 'update-ref', 'refs/archive/base', base)


def prepare_incremental_restore(archive, target):
    manifest = json.loads((archive / 'manifest.json').read_text(encoding='utf-8'))
    target.mkdir(mode=0o755)
    object_format = 'sha256' if len(manifest['head_sha']) == 64 else 'sha1'
    git(target, 'init', '--quiet', f'--object-format={object_format}')
    if manifest.get('self_contained') is not True:
        seed_base(target, manifest)
    if (manifest.get('capture_policy') == 'git-only'
            and manifest.get('source_fingerprint', {}).get('auto_merge') is None):
        if (archive / 'commits.bundle').is_file():
            git(target, 'fetch', '--quiet', '--no-write-fetch-head',
                str(archive / 'commits.bundle'), 'HEAD:refs/archive/head')
    else:
        fetch_preservation(target, archive)
    git(target, '-c', 'core.hooksPath=/dev/null', 'checkout', '--quiet', '--detach', manifest['head_sha'])


def restore_administration(root, archive):
    state = load_administration(archive)
    # Clone fetches branch tips only. Import all preservation tips explicitly.
    fetch_preservation(root, archive)
    admin = Path(os.fsdecode(git(root, "rev-parse", "--absolute-git-dir").rstrip(b"\n")))
    head = bytes.fromhex(state["files"]["HEAD"])
    if head.startswith(b"ref: "):
        branch = os.fsdecode(head[5:].strip())
        if not branch.startswith("refs/heads/"):
            raise ValueError("git_admin:unsupported_head")
        git(root, "update-ref", branch, git(root, "rev-parse", "HEAD").strip().decode("ascii"))
    for name, oid in state["refs"].items():
        git(root, "update-ref", name, oid)
    for name in ADMIN_FILES - state['files'].keys():
        (admin / name).unlink(missing_ok=True)
    for name, value in state["files"].items():
        target = admin / name
        # Newly reconstructed metadata directories may contain private state.
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        target.write_bytes(bytes.fromhex(value))
    if "config.worktree" in state["files"]:
        git(root, "config", "--file", str(admin / "config"), "extensions.worktreeConfig", "true")


def verify_administration(archive, scratch, manifest):
    """Prove every admin/index object is available without the source database."""
    state = load_administration(archive)
    if administration_digest(state) != manifest.get('source_fingerprint', {}).get('git_admin'):
        raise ValueError('git_admin:fingerprint_mismatch')
    fetch_preservation(scratch, archive)
    git(scratch, 'update-ref', 'HEAD', manifest['head_sha'])
    (scratch / 'index').write_bytes(bytes.fromhex(state['files']['index']))
    roots = administration_roots(scratch, state)
    checked = git(scratch, 'cat-file', '--batch-check', data=('\n'.join(roots) + '\n').encode('ascii'))
    if len(checked.splitlines()) != len(roots) or any(line.endswith(b' missing') for line in checked.splitlines()):
        raise ValueError('git_admin:missing_object')


def git_snapshot(path, patches=None, metadata=None, include_untracked=True):
    """Describe Git changes and ordinary untracked files, excluding Git-ignored files.

    Capture passes its already-written patches, so describing the archive does
    not repeat diffs or verify restoration. Comparison is a separate operation.
    """
    root = Path(path).resolve(strict=True)
    metadata = metadata if metadata is not None else git_index_state(root)
    if 'merge' in metadata:
        state = metadata['merge']
        result = {'schema': 4, 'policy': 'git-only', 'head': state['head'],
                  'files': len(state['working']), 'bytes': sum(len(value[1]) // 2 for value in state['working'].values() if value),
                  'merge_sha256': merge_digest(state)}
        if include_untracked:
            paths = sorted(filter(None, git(root, 'ls-files', '--others', '--exclude-standard', '-z').split(b'\0')))
            contents = untracked_contents(root, paths)
            result.update(untracked_files=len(paths),
                          untracked_sha256=hashlib.sha256(json.dumps(contents, ensure_ascii=True).encode('ascii')).hexdigest())
        return result
    options = ("--binary", "--full-index", "--no-ext-diff", "--no-textconv",
               "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--submodule=short")
    staged = (patches / "staged.patch").read_bytes() if patches else git(root, "diff", "--cached", *options)
    unstaged = (patches / "diff.patch").read_bytes() if patches else git(root, "diff", *options)
    head = metadata["head"]
    values = [head, metadata["index"],
              hashlib.sha256(staged).hexdigest(), hashlib.sha256(unstaged).hexdigest()]
    result = {"schema": 2, "policy": "git-only", "head": head, "files": metadata["files"],
               "bytes": len(staged) + len(unstaged),
               "sha256": hashlib.sha256(json.dumps(values).encode("ascii")).hexdigest()}
    oid = auto_merge(root)
    if oid is not None:
        result['auto_merge'] = oid
    if include_untracked:
        paths = sorted(filter(None, git(root, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0")))
        size = sum((root / os.fsdecode(raw)).lstat().st_size for raw in paths)
        if (len(paths) > int(os.environ.get("AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_FILES", "10000"))
                or size > int(os.environ.get("AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_BYTES", "1073741824"))):
            raise ValueError("untracked payload exceeds configured limit")
        contents = untracked_contents(root, paths)
        result.update(schema=3, untracked_files=len(paths), bytes=result["bytes"] + size,
                      untracked_sha256=hashlib.sha256(json.dumps(contents, ensure_ascii=True).encode("ascii")).hexdigest())
    return result


def snapshot(path, preserve_git_admin=False, include_ignored=False, git_only=False):
    if git_only:
        return git_snapshot(path)
    root = Path(path).resolve(strict=True)
    supported_state(root, preserve_git_admin, include_ignored)
    index, paths = inventories(root, include_ignored)
    supported_directories(root)
    head = git(root, "rev-parse", "--verify", "HEAD").strip().decode("ascii")
    contents = [[os.fsdecode(raw), fingerprint(root, raw)] for raw in paths]
    values = [head, index.hex(), contents]
    if preserve_git_admin:
        values.append(administration(root))
    payload = json.dumps(values, ensure_ascii=True, separators=(",", ":")).encode("ascii")
    # Git/index mutations during sampling are not a valid stable snapshot.
    if inventories(root, include_ignored) != (index, paths) or git(root, "rev-parse", "--verify", "HEAD").strip().decode("ascii") != head:
        raise ValueError("Git state changed while fingerprinting")
    supported_state(root, preserve_git_admin, include_ignored)
    working_bytes = sum(value[2] for _, value in contents if value[0] == "file")
    return {"schema": 1, "head": head, "files": len(paths), "bytes": working_bytes,
            "sha256": hashlib.sha256(payload).hexdigest()}


def main(argv):
    command = argv[0] if argv else ''
    handlers = {
        'auto-merge-capture': ((4,), lambda: capture_auto_merge(Path(argv[1]), Path(argv[2]).resolve(), argv[3])),
        'merge-capture': ((3,), lambda: capture_merge(Path(argv[1]), Path(argv[2]).resolve())),
        'merge-restore': ((3,), lambda: restore_merge(Path(argv[1]), Path(argv[2]).resolve())),
        'auto-merge-restore': ((3,), lambda: restore_auto_merge(Path(argv[1]), Path(argv[2]).resolve())),
        'admin-capture': ((4, 5), lambda: capture_administration(Path(argv[1]), Path(argv[2]).resolve(), argv[3] == '1', *argv[4:])),
        'admin-prepare-restore': ((3,), lambda: prepare_incremental_restore(Path(argv[1]).resolve(), Path(argv[2]).resolve())),
        'admin-restore': ((3,), lambda: restore_administration(Path(argv[1]), Path(argv[2]).resolve())),
        'admin-verify': ((2,), lambda: load_administration(Path(argv[1]))),
    }
    lengths, handler = handlers.get(command, ((), None))
    if len(argv) in lengths:
        handler()
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preserve-git-admin", action="store_true")
    parser.add_argument("--include-ignored", action="store_true")
    parser.add_argument("worktree")
    args = parser.parse_args(argv)
    print(json.dumps(snapshot(args.worktree, args.preserve_git_admin, args.include_ignored), sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, ValueError) else "source evidence unavailable"
        print(f"archive-snapshot: {reason}", file=sys.stderr)
        sys.exit(1)
