#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Access and bundle Git objects without caller repository overrides."""

import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile


DEFAULT_TIMEOUT = 60
RETAINED_VERIFICATION_SCRATCH = ('archive-verify:retained-scratch; prior verification evidence retained; '
                                 'review required before retry')


def git_executable():
    # Keep PATH's installed policy shim, including for the local upload server.
    executable = shutil.which('git')
    if executable is None:
        raise ValueError('Git executable unavailable')
    return str(Path(executable).absolute())


def base_upload_pack():
    # A local fetch does not forward the receiver's -c options to upload-pack.
    # Disable delta searching there, rather than growing an unbounded per-thread
    # window against the shared source's object population. No source config is
    # changed. Git interprets --upload-pack as a shell command: quote every token.
    return shlex.join([git_executable(), '-c', 'core.hooksPath=/dev/null',
                       '-c', 'pack.window=0', '-c', 'pack.threads=1', 'upload-pack'])


def base_import_failure(error):
    """Classify captured Git stderr without releasing paths, OIDs or raw text."""
    stderr = error.stderr or b''
    if isinstance(stderr, str):
        stderr = stderr.encode('utf-8', errors='replace')
    stderr = stderr.lower()
    packing = 'pack-objects-died' if b'pack-objects died' in stderr else 'git-failed'
    detail = 'unclassified'
    for signatures, category in (
        ((b'out of memory', b'malloc failed', b'cannot allocate memory'), 'allocation-failed'),
        ((b'no space left on device',), 'storage-full'),
        ((b'permission denied',), 'permission-denied'),
        ((b'unable to create thread', b'cannot create thread'), 'thread-failed'),
    ):
        if any(signature in stderr for signature in signatures):
            detail = category
            break
    code = error.returncode if -255 <= error.returncode <= 255 else 'unknown'
    return (f'producer:base-import-failed; stage=base-import; exit={code}; '
            f'stderr={packing}/{detail}; source and archive retained')


def nested_base_import_failure(stderr):
    """Accept only the complete fixed-format diagnostic from a nested CLI."""
    if isinstance(stderr, bytes):
        stderr = stderr.decode('utf-8', errors='replace')
    if not isinstance(stderr, str):
        return None
    lines = stderr.rstrip().splitlines()
    final = lines[-1] if lines else ''
    for prefix in ('ValueError: ', 'archive-snapshot: '):
        final = final.removeprefix(prefix)
    if final == RETAINED_VERIFICATION_SCRATCH:
        return final
    pattern = (r'producer:base-import-failed; stage=base-import; exit=(?:-?[0-9]{1,3}|unknown); '
               r'stderr=(?:pack-objects-died|git-failed)/'
               r'(?:unclassified|allocation-failed|storage-full|permission-denied|thread-failed); '
               r'source and archive retained')
    return final if re.fullmatch(pattern, final) else None


def producer_failure_reason(error):
    """Classify direct/nested archive failures at the shared diagnostic boundary."""
    # Restoration imports Git while initializing; load its CLI classifier only
    # when handling a completed operation's exception, not at module import time.
    from worktree_archive_restore import NOT_ENROLLED, failure_message
    metadata_errors = {
        "ownership, ACLs or extended attributes require separate preservation",
        "special permissions or hard links require separate preservation",
    }
    message = str(error) if isinstance(error, ValueError) else ""
    if isinstance(error, subprocess.TimeoutExpired):
        return ("producer:git-timeout; a local Git operation exceeded its time budget; "
                "source and archive retained; retry when host load is lower")
    if isinstance(error, subprocess.CalledProcessError):
        diagnostic = nested_base_import_failure(error.stderr)
        if diagnostic:
            return diagnostic
    if isinstance(error, subprocess.CalledProcessError) and isinstance(error.stderr, str):
        lines = error.stderr.rstrip().splitlines()
        # source_fingerprint's shell caller adds this fixed failure trailer.
        if lines and lines[-1] == "Error: worktree fingerprint unavailable":
            lines.pop()
        message = failure_message(lines[-1] if lines else "", message)
        if message == NOT_ENROLLED:
            return NOT_ENROLLED
    if message in metadata_errors:
        return ("producer:unsupported-metadata; permissions, ownership, ACLs, extended attributes "
                "or hard links require separate preservation; source retained; "
                "retrying will not resolve this policy refusal")
    return str(error) if isinstance(error, ValueError) else "producer:evidence-unavailable"


def git(root, *args, data=None, timeout=DEFAULT_TIMEOUT):
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1")
    for name in ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                 "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"):
        environment.pop(name, None)
    return subprocess.run(  # nosec B603 -- resolved Git, fixed subcommands, argv-only paths and object IDs
                          [git_executable(), "-c", "core.hooksPath=/dev/null", "-C", str(root), *args], input=data, env=environment,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          check=True, timeout=timeout).stdout


def auto_merge_oid(data):
    if not re.fullmatch(rb"(?:[0-9a-f]{40}|[0-9a-f]{64})\n?", data):
        raise ValueError("git_admin:invalid_AUTO_MERGE")
    return data.strip().decode("ascii")


def validate_auto_merge(root, oid):
    try:
        kind = git(root, "cat-file", "-t", oid).strip()
    except subprocess.SubprocessError as error:
        raise ValueError("git_admin:missing_AUTO_MERGE_tree") from error
    if kind != b"tree":
        raise ValueError("git_admin:AUTO_MERGE_not_tree")


def capture_bundle(root, archive, roots, base):
    # Scratch refs make every root (including index-only blobs) a named bundle
    # tip. All writes go to scratch; the source object database is read-only.
    with tempfile.TemporaryDirectory(prefix=".admin-bundle-", dir=archive.parent) as temporary:
        scratch = Path(temporary)
        object_format = git(root, 'rev-parse', '--show-object-format').strip().decode('ascii')
        git(scratch, "init", "--bare", "--quiet", f'--object-format={object_format}')
        objects = git(root, "rev-parse", "--path-format=absolute", "--git-path", "objects").rstrip(b"\n")
        (scratch / "objects/info/alternates").write_bytes(objects + b"\n")
        updates = ''.join(f'update refs/archive/{number} {oid}\n'
                          for number, oid in enumerate(roots))
        git(scratch, "update-ref", "--stdin", data=updates.encode('ascii'))
        git(scratch, "update-ref", "refs/heads/archive-head", git(root, "rev-parse", "HEAD").strip().decode("ascii"))
        git(scratch, "symbolic-ref", "HEAD", "refs/heads/archive-head")
        exclusions = (f'^{base}',) if base else ()
        git(scratch, "bundle", "create", str(archive / "commits.bundle"), "--all", *exclusions)


def fetch_preservation(root, archive):
    """Import preservation objects without changing shared-repository refs.

    Shared-repository callers must supply their owned linked worktree, never
    the canonical checkout. Independent repositories retain their legacy GC roots.
    """
    bundle = archive / 'commits.bundle'
    if bundle.is_file():
        git(root, 'bundle', 'verify', str(bundle))
        admin = git(root, 'rev-parse', '--absolute-git-dir').rstrip(b'\n')
        common = git(root, 'rev-parse', '--path-format=absolute', '--git-common-dir').rstrip(b'\n')
        if Path(os.fsdecode(admin)).resolve() != Path(os.fsdecode(common)).resolve():
            git(root, 'bundle', 'unbundle', str(bundle))
        else:
            # Standalone restores must keep non-commit AUTO_MERGE/index objects
            # reachable across ordinary GC; these refs belong only to that repo.
            git(root, 'fetch', '--quiet', '--no-write-fetch-head', str(bundle),
                '+refs/archive/*:refs/archive/*')


def fetch_head_roots(encoded):
    """Preserve all fetched objects, including not-for-merge entries, as bundle tips."""
    roots = []
    for line in bytes.fromhex(encoded).splitlines():
        fields = line.split(b"\t", 2)
        if len(fields) != 3 or fields[1] not in (b"", b"not-for-merge"):
            raise ValueError("git_admin:invalid_FETCH_HEAD")
        oid = fields[0]
        if (len(oid) not in (40, 64) or not oid.strip(b"0")
                or any(byte not in b"0123456789abcdef" for byte in oid)):
            raise ValueError("git_admin:invalid_FETCH_HEAD_oid")
        roots.append(oid.decode("ascii"))
    return roots
