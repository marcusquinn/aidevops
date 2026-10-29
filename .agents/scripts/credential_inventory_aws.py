#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Read-only AWS identity verification; values arrive only via secret injection.

The registry contains names only. No AWS response or credential is cached.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import credential_inventory_store as store  # noqa: E402
from credential_inventory_fields import InventoryError  # noqa: E402

SUFFIX = "_ACCESS_KEY_ID"


def credential_names(prefix: str) -> list[str]:
    """Require a recorded, same-account pair, optionally with a session token."""
    if not re.fullmatch(r"AWS_[A-Z0-9_]+", prefix):
        raise InventoryError("Expected an account-tagged AWS credential prefix")
    records = store.load()["credentials"]
    names = [prefix + SUFFIX, prefix + "_SECRET_ACCESS_KEY"]
    token_name = prefix + "_SESSION_TOKEN"
    if token_name in records:
        names.append(token_name)
    account = None
    for name in names:
        record = records.get(name, {})
        if record.get("provider") != "aws" or not record.get("account_ref"):
            raise InventoryError(f"Record {name} with --provider aws --account aws-<account> first")
        if account is not None and record["account_ref"] != account:
            raise InventoryError("AWS credentials must belong to the same recorded account")
        account = record["account_ref"]
    return names


def verify(prefix: str) -> int:
    """Call STS using exactly the injected pair, never another credential chain."""
    names = credential_names(prefix)
    env = os.environ.copy()
    for key in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
                "AWS_SECURITY_TOKEN", "AWS_PROFILE", "AWS_DEFAULT_PROFILE"):
        env.pop(key, None)
    for name in names:
        if not env.get(name):
            raise InventoryError(f"{name} was not injected")
        env["AWS" + name[len(prefix):]] = env[name]
    env["AWS_PAGER"] = ""
    env["AWS_EC2_METADATA_DISABLED"] = "true"
    aws_cli = shutil.which("aws")
    if aws_cli is None:
        raise InventoryError("AWS CLI is not installed; AWS CLI v2 is required")
    try:
        # Fixed read-only argv, no shell or user-provided command; keys stay in env.
        result = subprocess.run(  # nosec B603 -- locally resolved CLI, constant STS arguments
            [str(Path(aws_cli).resolve()), "sts", "get-caller-identity", "--output", "json"],
            env=env, capture_output=True, text=True, timeout=30, check=False,
        )
    except FileNotFoundError:
        raise InventoryError("AWS CLI is not installed; AWS CLI v2 is required") from None
    except subprocess.TimeoutExpired:
        raise InventoryError("AWS identity verification timed out") from None
    if result.returncode:
        # CLI stderr can contain credential material; never forward it.
        raise InventoryError("AWS identity verification failed; check key validity, session expiry and STS connectivity")
    try:
        identity = json.loads(result.stdout)
        account, arn = identity["Account"], identity["Arn"]
        if not re.fullmatch(r"\d{12}", account) or not re.fullmatch(r"arn:[\w-]+:(iam|sts)::\d{12}:[\w+=,.@/:-]+", arn):
            raise ValueError
    except (ValueError, KeyError, TypeError):
        raise InventoryError("AWS returned an invalid identity response") from None
    print(json.dumps({"Account": account, "Arn": arn}))
    return 0


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ("targets", "names", "verify"):
        raise InventoryError("Run via: aidevops secret verify aws [AWS_<ACCOUNT>_ACCESS_KEY_ID...]")
    operation, *args = argv
    if operation == "targets":
        records = store.load()["credentials"]
        selected = args or sorted(name for name, record in records.items()
                                  if record.get("provider") == "aws" and name.endswith(SUFFIX))
        if not selected:
            raise InventoryError("No recorded AWS access-key pairs")
        prefixes = []
        for name in selected:
            if not name.endswith(SUFFIX):
                raise InventoryError("Select AWS_<ACCOUNT>_ACCESS_KEY_ID names")
            prefix = name[:-len(SUFFIX)]
            credential_names(prefix)
            prefixes.append(prefix)
        print("\n".join(dict.fromkeys(prefixes)))
        return 0
    if len(args) != 1:
        raise InventoryError("Expected one AWS credential prefix")
    if operation == "names":
        print("\n".join(credential_names(args[0])))
        return 0
    return verify(args[0])


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except InventoryError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
