#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline, owner-signed exact SSH bindings; never resolve SSH configuration."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from command_policy_network import _normalize_host, _run_git_query

NAMESPACE = "aidevops-ssh-binding-v1"
RECOVERY = "Prepare an exact grant with ssh_binding_helper.py prepare; owner-sign it as described in reference/ssh-bindings.md"
_SAFE_OPTIONS = {
    "ProxyCommand=none", "ProxyJump=none", "ClearAllForwardings=yes",
    "PermitLocalCommand=no", "BatchMode=yes", "StrictHostKeyChecking=yes",
}


def binding_command(argv: list[str]) -> dict[str, Any]:
    """Accept only a config-free, non-forwarding command with explicit identity."""
    if not isinstance(argv, list) or not all(isinstance(arg, str) for arg in argv):
        raise ValueError("invalid SSH argv")
    if not argv or argv[0] not in {"ssh", "/usr/bin/ssh"}:
        raise ValueError("unsupported SSH executable")
    options: dict[str, str] = {}
    extended: set[str] = set()
    index = 1
    while index < len(argv) and argv[index].startswith("-"):
        option = argv[index]
        if option not in {"-F", "-o", "-l", "-p"} or index + 1 >= len(argv):
            raise ValueError("unsupported SSH option (proxies and forwarding are not authorized)")
        value = argv[index + 1]
        if option == "-o":
            if value in extended:
                raise ValueError("duplicate SSH option")
            extended.add(value)
        elif option in options:
            raise ValueError("duplicate SSH option")
        else:
            options[option] = value
        index += 2
    hosts = [value[len("HostName="):] for value in extended if value.startswith("HostName=")]
    if len(hosts) != 1 or extended != _SAFE_OPTIONS | {"HostName=" + hosts[0]}:
        raise ValueError("explicit safe SSH options and HostName are required")
    endpoint = hosts[0]
    if _normalize_host(endpoint) != endpoint or not re.fullmatch(r"[a-z0-9.:-]+", endpoint):
        raise ValueError("endpoint must be an exact normalized FQDN or IP")
    if options.get("-F") != "/dev/null" or not re.fullmatch(r"[a-zA-Z0-9_][a-zA-Z0-9_.-]*", options.get("-l", "")):
        raise ValueError("-F /dev/null and an explicit account are required")
    port_text = options.get("-p", "")
    if not port_text.isascii() or not port_text.isdigit() or not 1 <= int(port_text) <= 65535:
        raise ValueError("explicit valid SSH port is required")
    if index >= len(argv) - 1 or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]*", argv[index]):
        raise ValueError("single-label alias and explicit remote command are required")
    if len(argv) != index + 2 or argv[index + 1].startswith("-"):
        raise ValueError("remote command must be one non-option string")
    if any(not arg or any(char in arg for char in "\x00\n\r") for arg in argv):
        raise ValueError("invalid SSH argument")
    return {"alias": argv[index], "endpoint": endpoint, "account": options["-l"], "port": int(port_text)}


def repository_at(cwd: str) -> str:
    urls = _run_git_query(cwd, ["remote", "get-url", "--all", "origin"]) or []
    if len(urls) != 1:
        raise ValueError("repository origin is ambiguous")
    match = re.fullmatch(r"(?:https://github\.com/|git@github\.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?", urls[0])
    if not match:
        raise ValueError("repository origin is unsupported")
    return match.group(1)


def repository_common_dir(cwd: str) -> str:
    """Bind the installed repository, not a worker-editable origin string alone."""
    paths = _run_git_query(cwd, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) or []
    if len(paths) != 1 or not Path(paths[0]).is_dir():
        raise ValueError("repository common directory is unavailable")
    return str(Path(paths[0]).resolve())


def grant_path(repository: str, argv: list[str]) -> Path:
    identity = json.dumps([repository, argv], separators=(",", ":"), ensure_ascii=True)
    digest = hashlib.sha256(identity.encode()).hexdigest()
    return Path.home() / ".aidevops/ssh-bindings" / (digest + ".json")


def _read_public_file(path: Path) -> bytes:
    # Open once without following leaf symlinks, then inspect that same descriptor.
    # NONBLOCK prevents a replaced FIFO from hanging the offline verifier.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 65536:
            raise ValueError("SSH approval file is missing or unsafe")
        raw = source.read(65537)
    if len(raw) > 65536:
        raise ValueError("SSH approval file grew beyond its size limit")
    return raw


def authorized_binding(argv: list[str], cwd: str) -> dict[str, Any]:
    """Verify exact command/repository/expiry and an owner signature offline."""
    binding = binding_command(argv)
    repository = repository_at(cwd)
    path = grant_path(repository, argv)
    raw = _read_public_file(path)
    grant = json.loads(raw)
    if not isinstance(grant, dict) or grant.get("schema") != NAMESPACE:
        raise ValueError("invalid SSH grant schema")
    if not isinstance(grant.get("binding"), dict) or type(grant["binding"].get("port")) is not int:
        raise ValueError("SSH grant port must be an integer, not a boolean or float")
    if (grant.get("repository") != repository or grant.get("argv") != argv
            or grant.get("binding") != binding or grant.get("common_dir") != repository_common_dir(cwd)):
        raise ValueError("SSH grant command or endpoint mismatch")
    now = datetime.now(timezone.utc)
    issued = datetime.fromisoformat(grant["issued_at"])
    expires = datetime.fromisoformat(grant["expires_at"])
    if issued.tzinfo is None or expires.tzinfo is None or not issued <= now < expires <= issued + timedelta(hours=4):
        raise ValueError("SSH grant is expired or outside its four-hour window")
    signature = _read_public_file(Path(str(path) + ".sig"))
    public_key = _read_public_file(Path.home() / ".aidevops/approval-keys/approval.pub").decode().strip()
    if "\n" in public_key or not public_key.startswith("ssh-ed25519 "):
        raise ValueError("invalid owner approval key")
    # Snapshot all verifier inputs; do not let a concurrent grant change affect verification.
    temp_root = Path(os.environ.get("AIDEVOPS_TEMP_DIR") or Path.home() / ".aidevops/.agent-workspace/tmp")
    temp_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ssh-binding-", dir=temp_root) as temp:
        signers = Path(temp) / "signers"
        sig = Path(temp) / "signature"
        signers.write_text(f'approval@aidevops.sh namespaces="{NAMESPACE}" {public_key}\n')
        sig.write_bytes(signature)
        verified = subprocess.run(  # nosec B603 -- fixed verifier argv, no shell or network.
            ["/usr/bin/ssh-keygen", "-Y", "verify", "-f", str(signers), "-I", "approval@aidevops.sh",
             "-n", NAMESPACE, "-s", str(sig)], input=raw, capture_output=True, timeout=5, check=False,
        )
    if verified.returncode:
        raise ValueError("SSH grant owner signature is invalid")
    return binding


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "verify"))
    parser.add_argument("--argv-json", required=True)
    parser.add_argument("--cwd", default=os.getcwd())
    args = parser.parse_args()
    try:
        argv = json.loads(args.argv_json)
        if args.action == "verify":
            authorized_binding(argv, args.cwd)
            print("SSH binding verified (endpoint tiers still apply)")
        else:
            binding = binding_command(argv)
            repository = repository_at(args.cwd)
            now = datetime.now(timezone.utc)
            grant = {"schema": NAMESPACE, "repository": repository, "common_dir": repository_common_dir(args.cwd),
                     "argv": argv, "binding": binding,
                     "issued_at": now.isoformat(), "expires_at": (now + timedelta(hours=4)).isoformat()}
            path = grant_path(repository, argv)
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            # Do not replace an existing signed grant or follow a symlink.
            with path.open("x") as output:
                json.dump(grant, output, sort_keys=True, indent=2)
                output.write("\n")
            path.chmod(0o600)
            print(f"Unsigned request: {path}\nOwner must review and sign; see reference/ssh-bindings.md")
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        print(f"SSH binding denied: {exc}. {RECOVERY}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
