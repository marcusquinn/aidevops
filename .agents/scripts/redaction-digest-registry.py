#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Keyed digest registry for injected credential values (GH#32362).

`secret-helper.sh run` pipes the NUL-delimited KEY=VALUE records it injects
into a child process to `register`. The registry stores only
`<length> <hmac-sha256>` lines under an owner-only directory, never plaintext.
The OpenCode plugin (`registered-value-redaction.mjs`) uses these digests to redact
exact injected values from tool output, for example a provider command line
shown by `ps`, without needing the value itself.

Usage:
  redaction-digest-registry.py register < records    # NUL-delimited KEY=VALUE
  redaction-digest-registry.py status                # entry count only
"""

from __future__ import annotations

import fcntl
import hashlib
import hmac
import os
import re
import secrets
import sys
from pathlib import Path

MIN_LENGTH = 8
MAX_LENGTH = 4096
MAX_ENTRIES = 4096
TOKEN_CHARSET = re.compile(r"[A-Za-z0-9._~+/=-]+")
PLACEHOLDERS = {
    "", "***", "[redacted]", "[redacted-credential]", "<redacted>", "not set",
    "(not set)", "none", "null", "undefined", "missing", "changeme",
}


def registry_dir() -> Path:
    override = os.environ.get("AIDEVOPS_SECRET_REDACTION_DIR", "")
    if override:
        return Path(override)
    return Path.home() / ".aidevops" / ".agent-workspace" / "secret-redaction"


def ensure_dir(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink() or not path.is_dir():
        raise SystemExit("redaction registry directory is not a regular directory")
    os.chmod(path, 0o700)


def reject_symlink(path: Path) -> None:
    if path.is_symlink():
        raise SystemExit("redaction registry file must not be a symlink")


def load_key(path: Path) -> bytes:
    key_path = path / "key"
    if not key_path.exists():
        # Publish a complete key atomically; a concurrent creator wins via link.
        tmp = path / f"key.tmp.{os.getpid()}"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="ascii") as handle:
            handle.write(secrets.token_hex(32) + "\n")
        try:
            os.link(tmp, key_path)
        except FileExistsError:
            pass
        finally:
            os.unlink(tmp)
    reject_symlink(key_path)
    text = key_path.read_text(encoding="ascii").strip()
    if len(text) != 64:
        raise SystemExit("redaction registry key is malformed")
    return bytes.fromhex(text)


def usable(value: str) -> bool:
    # Must mirror TOKEN_RUN in registered-value-redaction.mjs: the plugin only
    # hashes windows made of these characters.
    return (
        MIN_LENGTH <= len(value) <= MAX_LENGTH
        and TOKEN_CHARSET.fullmatch(value) is not None
        and value.lower() not in PLACEHOLDERS
        and "[redacted-credential]" not in value
    )


def read_values(data: bytes) -> list[str]:
    values = []
    for record in data.split(b"\0"):
        if b"=" not in record:
            continue
        raw = record.split(b"=", 1)[1]
        try:
            value = raw.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if usable(value):
            values.append(value)
    return values


def write_atomic(path: Path, lines: list[str]) -> None:
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="ascii") as handle:
        handle.write("".join(line + "\n" for line in lines))
    os.replace(tmp, path)


def register() -> int:
    values = read_values(sys.stdin.buffer.read())
    if not values:
        return 0
    path = registry_dir()
    ensure_dir(path)
    key = load_key(path)
    digest_path = path / "digests"
    lock_fd = os.open(path / "digests.lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        reject_symlink(digest_path)
        existing = []
        if digest_path.exists():
            existing = [line.strip() for line in digest_path.read_text(encoding="ascii").splitlines() if line.strip()]
        entries = list(dict.fromkeys(existing))
        known = set(entries)
        for value in values:
            digest = hmac.new(key, value.encode("utf-8"), hashlib.sha256).hexdigest()
            line = f"{len(value)} {digest}"
            if line not in known:
                entries.append(line)
                known.add(line)
        # Keep the newest entries when the bounded registry is full.
        entries = entries[-MAX_ENTRIES:]
        if entries != existing:
            write_atomic(digest_path, entries)
    finally:
        os.close(lock_fd)
    return 0


def status() -> int:
    digest_path = registry_dir() / "digests"
    count = 0
    if digest_path.exists():
        count = sum(1 for line in digest_path.read_text(encoding="ascii").splitlines() if line.strip())
    print(f"entries: {count}")
    return 0


def main(argv: list[str]) -> int:
    command = argv[1] if len(argv) > 1 else ""
    if command == "register":
        return register()
    if command == "status":
        return status()
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
