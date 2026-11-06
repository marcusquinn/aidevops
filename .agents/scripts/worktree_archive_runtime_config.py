#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Preserve runtime-local config.worktree bytes without restoring them (GH#36883).

Git-only archives cannot restore per-worktree configuration: doing so would
require enabling extensions.worktreeConfig in the user's shared repository
config. A file whose every key is a known runtime-local binding (the same class
as codex-thread.json) is therefore captured as exact bytes, bound to the source
fingerprint, verified, and deliberately omitted from restoration. Any other key,
a comment-only file, or an unparsable file keeps the fail-closed refusal.
Diagnostics and fingerprints carry key names and digests, never values.
"""

import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys

from worktree_archive_git import git

NAME = "worktree-config-v1"
REFUSAL = "git_admin:requires_preservation:config.worktree"
# Codex binds a worktree to its local environment file; a restored worktree must
# not reconnect to the source session's environment.
RUNTIME_LOCAL_CONFIG_KEYS = frozenset({"codex.localenvironmentconfigpath"})
SHA_FIELD = "config_worktree_sha256"
KEYS_FIELD = "config_worktree_keys"


def runtime_keys(root, data):
    """Return sorted key names when every key is runtime-local, else None."""
    try:
        listed = git(root, "config", "--file", "-", "--no-includes", "--null", "--list", data=data)
    except subprocess.CalledProcessError:
        return None
    keys = set()
    for entry in listed.split(b"\0"):
        if not entry:
            continue
        try:
            key = entry.split(b"\n", 1)[0].decode("ascii").lower()
        except UnicodeDecodeError:
            return None
        if key not in RUNTIME_LOCAL_CONFIG_KEYS:
            return None
        keys.add(key)
    return sorted(keys) or None


def read_config(admin):
    path = Path(admin) / "config.worktree"
    if not os.path.lexists(path):
        return None
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError(REFUSAL)
        return stream.read()


def classify(root, admin):
    """Describe a supported config.worktree; raise for any unsupported content."""
    try:
        data = read_config(admin)
    except OSError:
        raise ValueError(REFUSAL) from None
    if not data:
        return None  # Absent or empty configuration carries no state.
    keys = runtime_keys(root, data)
    if keys is None:
        raise ValueError(REFUSAL)
    return {SHA_FIELD: hashlib.sha256(data).hexdigest(), KEYS_FIELD: keys}, data


def fingerprint_fields(root, admin):
    described = classify(root, admin)
    return described[0] if described else {}


def capture(root, archive):
    root = Path(root).resolve(strict=True)
    admin = Path(os.fsdecode(git(root, "rev-parse", "--absolute-git-dir").rstrip(b"\n")))
    described = classify(root, admin)
    if described is None:
        return
    descriptor = os.open(Path(archive) / NAME, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(described[1])


def verify(archive, manifest):
    """Bind the artifact to the fingerprint and re-run the key classifier."""
    saved = manifest.get("source_fingerprint", {})
    digest, keys = saved.get(SHA_FIELD), saved.get(KEYS_FIELD)
    path = Path(archive) / NAME
    if digest is None and keys is None:
        if os.path.lexists(path):
            raise ValueError("git_admin:unexpected_config_worktree_artifact")
        return None
    if path.is_symlink() or not path.is_file():
        raise ValueError("git_admin:missing_config_worktree_artifact")
    data = path.read_bytes()
    if (hashlib.sha256(data).hexdigest() != digest
            or runtime_keys(Path(archive), data) != keys):
        raise ValueError("git_admin:config_worktree_artifact_mismatch")
    return keys


def inventory(archive, manifest, capture_policy):
    """Archive inventory names this policy requires; exits like verify_archive."""
    if capture_policy != "git-only":
        return set()  # Other policies never list the artifact, so it stays unknown.
    try:
        return {NAME} if verify(archive, manifest) else set()
    except (OSError, ValueError) as error:
        raise SystemExit(str(error) if isinstance(error, ValueError) else "missing config.worktree artifact") from None


def restored_view(snapshot):
    """The fingerprint a faithful restore must reproduce: runtime config is omitted."""
    return {key: value for key, value in snapshot.items() if key not in (SHA_FIELD, KEYS_FIELD)}


def omitted_keys(manifest):
    return list(manifest.get("source_fingerprint", {}).get(KEYS_FIELD) or ())


def main(argv):
    if len(argv) == 3 and argv[0] == "capture":
        capture(Path(argv[1]), Path(argv[2]).resolve())
        return 0
    if len(argv) == 3 and argv[0] == "bind":
        import json
        # An A->B->A rewrite during capture leaves equal fingerprints around a
        # stale artifact; bind the captured bytes to the final fingerprint.
        verify(Path(argv[1]), {"source_fingerprint": json.loads(argv[2])})
        return 0
    if len(argv) == 2 and argv[0] == "restore-note":
        import json
        manifest = json.loads((Path(argv[1]) / "manifest.json").read_text(encoding="utf-8"))
        keys = omitted_keys(manifest)
        if keys:
            print("restore: omitted runtime-local config.worktree keys (bytes kept in "
                  f"{NAME}): {', '.join(keys)}", file=sys.stderr)
        return 0
    print("usage: worktree_archive_runtime_config.py capture WORKTREE ARCHIVE | bind ARCHIVE FINGERPRINT_JSON"
          " | restore-note ARCHIVE", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, ValueError) else "runtime config evidence unavailable"
        print(f"archive-runtime-config: {reason}", file=sys.stderr)
        sys.exit(1)
