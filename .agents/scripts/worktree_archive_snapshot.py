#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fingerprint supported recovery contents; refuse states not preserved by archives.

This is read-only evidence, not permission to remove a worktree. Callers must
still establish ownership/quiescence and compare again immediately before removal.
Sampling is not atomic: cooperating-writer exclusion must cover verification and
removal; fingerprints do not fence arbitrary same-user writers.
"""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from worktree_archive_filesystem import fingerprint, supported_directories

def git(root, *args, data=None):
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1")
    for name in ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                 "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"):
        environment.pop(name, None)
    return subprocess.run(["git", "-C", str(root), *args], input=data, env=environment,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          check=True, timeout=60).stdout


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
        if message.is_symlink() or message.read_bytes().rstrip(b"\n") != git(root, "log", "-1", "--format=%B").rstrip(b"\n"):
            raise ValueError("uncommitted message draft requires separate preservation")


def inventories(root):
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
    paths.update(path for path in git(root, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0") if path)
    return index, sorted(paths)


ADMIN_FILES = {"HEAD", "index", "ORIG_HEAD", "COMMIT_EDITMSG", "SQUASH_MSG", "MERGE_MSG", "config.worktree", "logs/HEAD"}
PRIVATE_PREFIXES = ("refs/worktree/", "refs/bisect/", "refs/rewritten/")
OPERATIONS = {"MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD",
              "rebase-merge", "rebase-apply", "sequencer", "BISECT_LOG"}


def admin_path_allowed(name):
    return name in ADMIN_FILES or any(name.startswith(prefix) for prefix in PRIVATE_PREFIXES)


def validate_admin_entry(entry, name):
    if name == "index.lock":
        raise ValueError("git_admin:index_locked:index.lock")
    if name in OPERATIONS:
        raise ValueError(f"git_admin:unfinished_operation:{name}")
    if entry.is_symlink():
        raise ValueError(f"git_admin:symlink:{name}")


def admin_directory_allowed(name):
    return (name in {"logs", "refs", "refs/worktree", "refs/bisect", "refs/rewritten"}
            or any(name.startswith(prefix) for prefix in PRIVATE_PREFIXES))


def administration_files(admin, directory, linked):
    files = {}
    for entry in sorted(directory.iterdir()):
        name = entry.relative_to(admin).as_posix()
        validate_admin_entry(entry, name)
        if name in {"commondir", "gitdir"} and linked and entry.is_file():
            continue
        if entry.is_dir() and admin_directory_allowed(name):
            files.update(administration_files(admin, entry, linked))
        elif entry.is_file() and admin_path_allowed(name):
            files[name] = entry.read_bytes().hex()
        elif not linked and (name == "logs/refs" or name.split("/")[0] in
                             {"objects", "refs", "config", "description", "hooks", "info", "packed-refs"}):
            # Independent restores contain ordinary repository infrastructure.
            continue
        else:
            raise ValueError(f"git_admin:unknown_entry:{name}")
    return files


def validate_admin_config(root, admin):
    config = admin / 'config.worktree'
    if config.exists():
        entries = git(root, 'config', '--file', str(config), '--no-includes', '--null', '--list')
        for entry in entries.split(b'\0'):
            key = entry.split(b'\n', 1)[0].lower()
            if key == b'core.worktree' or (key.startswith(b'include') and key.endswith(b'.path')):
                raise ValueError('git_admin:location_dependent_config:' + key.decode('ascii'))


def administration(root):
    """Read only explicitly supported per-worktree administration, never common config."""
    admin = Path(os.fsdecode(git(root, "rev-parse", "--absolute-git-dir").rstrip(b"\n")))
    common = Path(os.fsdecode(git(root, "rev-parse", "--path-format=absolute", "--git-common-dir").rstrip(b"\n")))
    files = administration_files(admin, admin, admin.resolve() != common.resolve())
    if git(root, "rev-parse", "--shared-index-path").strip():
        raise ValueError("git_admin:split_index:index")
    validate_admin_config(root, admin)
    refs = git(root, "for-each-ref", "--format=%(refname) %(objectname) %(symref)", *PRIVATE_PREFIXES)
    head = bytes.fromhex(files['HEAD'])
    head_ref = os.fsdecode(head[5:].strip()) if head.startswith(b'ref: ') else None
    references = {}
    for line in refs.splitlines():
        name, oid, symbolic = os.fsdecode(line).split(' ', 2)
        if symbolic and symbolic != head_ref and not any(symbolic.startswith(prefix) for prefix in PRIVATE_PREFIXES):
            raise ValueError(f'git_admin:external_symbolic_ref:{name}')
        references[name] = oid
    return {"files": files, "refs": references}


def administration_digest(state):
    # Keep fingerprints small enough for the existing shell/argv interface even
    # when a repository's raw index or reflog is many megabytes.
    payload = json.dumps(state, sort_keys=True, separators=(',', ':')).encode('ascii')
    return hashlib.sha256(payload).hexdigest()


def administration_roots(root, state):
    roots = {git(root, "rev-parse", "HEAD").strip().decode("ascii")}
    roots.update(state["refs"].values())
    for name, encoded in state["files"].items():
        data = bytes.fromhex(encoded)
        if name == "logs/HEAD":
            for line in data.splitlines():
                roots.update(part.decode("ascii") for part in line.split()[:2] if set(part) != {48})
        elif name == "ORIG_HEAD":
            roots.add(data.strip().decode("ascii"))
    for inventory in ('--stage', '--resolve-undo'):
        for entry in git(root, "ls-files", inventory, "-z").split(b"\0"):
            if entry:
                oid = entry.split(b"\t", 1)[0].split()[1]
                if set(oid) != {48}:
                    roots.add(oid.decode("ascii"))
    return sorted(roots)


def capture_administration(root, archive, include_ignored):
    supported_state(root, True, include_ignored)
    inventories(root)
    state = administration(root)
    # Scratch refs make every root (including index-only blobs) a named bundle
    # tip. All writes go to scratch; the source object database is read-only.
    with tempfile.TemporaryDirectory(prefix=".admin-bundle-", dir=archive.parent) as temporary:
        scratch = Path(temporary)
        object_format = git(root, 'rev-parse', '--show-object-format').strip().decode('ascii')
        git(scratch, "init", "--bare", "--quiet", f'--object-format={object_format}')
        objects = git(root, "rev-parse", "--path-format=absolute", "--git-path", "objects").rstrip(b"\n")
        (scratch / "objects/info/alternates").write_bytes(objects + b"\n")
        for number, oid in enumerate(administration_roots(root, state)):
            git(scratch, "update-ref", f"refs/archive/{number}", oid)
        git(scratch, "update-ref", "refs/heads/archive-head", git(root, "rev-parse", "HEAD").strip().decode("ascii"))
        git(scratch, "bundle", "create", str(archive / "commits.bundle"), "--all")
    (archive / "git-admin.json").write_text(json.dumps(state, sort_keys=True) + "\n", encoding="ascii")


def load_administration(archive):
    state = json.loads((archive / "git-admin.json").read_text(encoding="ascii"))
    if not isinstance(state, dict) or set(state) != {"files", "refs"}:
        raise ValueError("git_admin:invalid_artifact")
    if (not isinstance(state['files'], dict) or not isinstance(state['refs'], dict)
            or not {"HEAD", "index"}.issubset(state['files'])):
        raise ValueError("git_admin:invalid_artifact")
    for name, value in state["files"].items():
        if not admin_path_allowed(name) or ".." in Path(name).parts or Path(name).is_absolute():
            raise ValueError("git_admin:unsafe_path")
        bytes.fromhex(value)
    for name, oid in state["refs"].items():
        if (not any(name.startswith(prefix) for prefix in PRIVATE_PREFIXES)
                or ".." in Path(name).parts or Path(name).is_absolute()):
            raise ValueError("git_admin:unsafe_ref")
        if len(oid) not in (40, 64) or any(char not in "0123456789abcdef" for char in oid):
            raise ValueError("git_admin:invalid_oid")
    return state


def restore_administration(root, archive):
    state = load_administration(archive)
    # Clone fetches branch tips only. Import all preservation tips explicitly.
    git(root, "fetch", "--quiet", "--no-write-fetch-head", str(archive / "commits.bundle"),
        "+refs/archive/*:refs/archive/*")
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
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(bytes.fromhex(value))
    if "config.worktree" in state["files"]:
        git(root, "config", "--file", str(admin / "config"), "extensions.worktreeConfig", "true")


def verify_administration(archive, scratch, manifest):
    """Prove every admin/index object is available without the source database."""
    state = load_administration(archive)
    if administration_digest(state) != manifest.get('source_fingerprint', {}).get('git_admin'):
        raise ValueError('git_admin:fingerprint_mismatch')
    git(scratch, 'fetch', '--quiet', '--no-write-fetch-head', str(archive / 'commits.bundle'),
        '+refs/archive/*:refs/archive/*')
    git(scratch, 'update-ref', 'HEAD', manifest['head_sha'])
    (scratch / 'index').write_bytes(bytes.fromhex(state['files']['index']))
    roots = administration_roots(scratch, state)
    checked = git(scratch, 'cat-file', '--batch-check', data=('\n'.join(roots) + '\n').encode('ascii'))
    if len(checked.splitlines()) != len(roots) or any(line.endswith(b' missing') for line in checked.splitlines()):
        raise ValueError('git_admin:missing_object')


def snapshot(path, preserve_git_admin=False):
    root = Path(path).resolve(strict=True)
    supported_state(root, preserve_git_admin)
    index, paths = inventories(root)
    supported_directories(root)
    head = git(root, "rev-parse", "--verify", "HEAD").strip().decode("ascii")
    contents = [[os.fsdecode(raw), fingerprint(root, raw)] for raw in paths]
    values = [head, index.hex(), contents]
    if preserve_git_admin:
        values.append(administration(root))
    payload = json.dumps(values, ensure_ascii=True, separators=(",", ":")).encode("ascii")
    # Git/index mutations during sampling are not a valid stable snapshot.
    if inventories(root) != (index, paths) or git(root, "rev-parse", "--verify", "HEAD").strip().decode("ascii") != head:
        raise ValueError("Git state changed while fingerprinting")
    supported_state(root, preserve_git_admin)
    working_bytes = sum(value[2] for _, value in contents if value[0] == "file")
    return {"schema": 1, "head": head, "files": len(paths), "bytes": working_bytes,
            "sha256": hashlib.sha256(payload).hexdigest()}


def main(argv):
    if argv and argv[0] == "admin-capture" and len(argv) == 4:
        capture_administration(Path(argv[1]), Path(argv[2]).resolve(), argv[3] == "1")
        return 0
    if argv and argv[0] == "admin-restore" and len(argv) == 3:
        restore_administration(Path(argv[1]), Path(argv[2]).resolve())
        return 0
    if argv and argv[0] == "admin-verify" and len(argv) == 2:
        load_administration(Path(argv[1]))
        return 0
    if len(argv) == 2 and argv[0] == "--preserve-git-admin":
        print(json.dumps(snapshot(argv[1], True), sort_keys=True))
        return 0
    if len(argv) != 1:
        raise ValueError("usage: worktree_archive_snapshot.py WORKTREE")
    print(json.dumps(snapshot(argv[0]), sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, ValueError) else "source evidence unavailable"
        print(f"archive-snapshot: {reason}", file=sys.stderr)
        sys.exit(1)
