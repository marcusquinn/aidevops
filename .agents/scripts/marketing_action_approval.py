#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Operator approval records for marketing action plans.

`mint` runs only as root through `sudo aidevops approve marketing-plan` with an
interactive TTY, so the record it writes into a root-owned directory is evidence
of an operator decision that same-user agent processes cannot forge. `verify`
runs as the operator and accepts only such root-owned, plan-bound, fresh records.

Python 3.9-compatible: sudo may resolve the system interpreter.
"""

from __future__ import annotations

import getpass
import hashlib
import json
import os
import pwd
import secrets
import stat
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

from marketing_action_ceremony import plan_operation_lines, receipt_inverse_lines

APPROVAL_SCHEMA = "aidevops.marketing-action-approval/v2"
MAX_APPROVAL_TTL_SECONDS = 900
MAX_RECORD_BYTES = 16_384
MAX_DOCUMENT_BYTES = 1_048_576
MAX_SUMMARY_LINES = 400
TRUSTED_APPROVAL_UID = 0
OPERATIONS = ("apply", "rollback")
CONFIRMATION = "APPROVE"
# Plan schema -> plan fields that every approval must bind exactly.
PLAN_BINDINGS: Dict[str, Tuple[str, ...]] = {
    "aidevops.marketing-action-plan/v1": ("project_root", "worktree_identity"),
    "aidevops.google-ads-action-plan/v1": ("customer_id",),
}
# Receipt schema -> plan schema it was produced from (rollback approvals).
RECEIPT_PLAN_SCHEMAS: Dict[str, str] = {
    "aidevops.marketing-action-receipt/v1": "aidevops.marketing-action-plan/v1",
    "aidevops.google-ads-action-receipt/v1": "aidevops.google-ads-action-plan/v1",
}
# Extra plan fields shown to the operator before the typed confirmation.
PLAN_SUMMARY_FIELDS: Dict[str, Tuple[str, ...]] = {
    "aidevops.marketing-action-plan/v1": ("branch",),
    "aidevops.google-ads-action-plan/v1": ("login_customer_id", "expires_at", "limits"),
}
RECORD_FIELDS = {
    "schema", "operation", "plan_schema", "plan_digest", "binding", "action_set", "owner",
    "receipt_digest", "issued_at", "expires_at", "nonce", "cancellation_path",
}


class ApprovalError(ValueError):
    """Raised when an approval cannot be minted or does not authorise the operation."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ApprovalError(message)


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def digest(value: Any) -> str:
    return "sha256:" + hashlib.sha256(canonical_json(value)).hexdigest()


def _timestamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_time(value: Any, field: str) -> datetime:
    _require(isinstance(value, str) and value.endswith("Z"), f"{field} must be a UTC timestamp")
    try:
        return datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise ApprovalError(f"{field} must be a UTC timestamp") from error


def _home(owner: str) -> Path:
    """Resolve the operator home through the account database, never $HOME."""
    try:
        return Path(pwd.getpwnam(owner).pw_dir)
    except KeyError as error:
        raise ApprovalError("approval owner is not a local account") from error


def approval_dir(owner: str) -> Path:
    return _home(owner) / ".aidevops" / "approval-keys" / "marketing-actions"


def cancellation_dir(owner: str) -> Path:
    return _home(owner) / ".aidevops" / ".agent-workspace" / "marketing-action-cancellations"


def record_path(owner: str, operation: str, plan_digest: str) -> Path:
    _require(operation in OPERATIONS, "approval operation is unsupported")
    _require(isinstance(plan_digest, str) and plan_digest.startswith("sha256:")
             and len(plan_digest) == 71 and all(c in "0123456789abcdef" for c in plan_digest[7:]),
             "approval plan digest is invalid")
    return approval_dir(owner) / f"{operation}-{plan_digest[7:]}.json"


def _binding(plan: Dict[str, Any], plan_schema: str) -> Dict[str, Any]:
    _require(plan_schema in PLAN_BINDINGS, "plan schema has no approval binding")
    fields = PLAN_BINDINGS[plan_schema]
    _require(all(isinstance(plan.get(field), str) and plan.get(field) for field in fields),
             "plan is missing approval-bound fields")
    return {field: plan[field] for field in fields}


def build_record(
    plan: Dict[str, Any], operation: str, plan_schema: str, **options: Any
) -> Dict[str, Any]:
    """Return an unsigned v2 record; authority comes only from where root stores it."""
    receipt_digest: Optional[str] = options.get("receipt_digest")
    issued: datetime = options.get("issued_at") or datetime.now(timezone.utc)
    ttl = int(options.get("ttl_seconds", MAX_APPROVAL_TTL_SECONDS))
    _require(operation in OPERATIONS, "approval operation is unsupported")
    _require((operation == "rollback") == (receipt_digest is not None),
             "rollback approvals, and only rollback approvals, bind a receipt digest")
    _require(0 < ttl <= MAX_APPROVAL_TTL_SECONDS, "approval freshness window is too broad")
    action_set = plan.get("action_set")
    _require(isinstance(action_set, list) and action_set and all(isinstance(item, str) for item in action_set),
             "approval requires a non-empty action set")
    return {
        "schema": APPROVAL_SCHEMA,
        "operation": operation,
        "plan_schema": plan_schema,
        "plan_digest": plan.get("plan_digest"),
        "binding": _binding(plan, plan_schema),
        "action_set": list(action_set),
        "owner": plan.get("owner"),
        "receipt_digest": receipt_digest,
        "issued_at": _timestamp(issued),
        "expires_at": _timestamp(issued + timedelta(seconds=ttl)),
        "nonce": options.get("nonce") or secrets.token_hex(16),
        "cancellation_path": options.get("cancellation_path", ""),
    }


def _directory_fd(path: Path, owner_uid: int, owner_gid: int) -> int:
    """Open `path` component by component without following symlinks.

    The final directory is created root-owned (or caller-owned without root) and
    must not be group/other writable. Holding the descriptor pins the real
    directory, so a later swap of a user-owned parent cannot redirect writes.
    """
    _require(path.is_absolute(), "approval directory must be absolute")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptor = os.open("/", flags)
    parts = path.parts[1:]
    try:
        for index, part in enumerate(parts):
            last = index == len(parts) - 1
            try:
                child = os.open(part, flags, dir_fd=descriptor)
            except FileNotFoundError:
                _require(index >= len(parts) - 2, "operator aidevops directory is missing")
                os.mkdir(part, 0o755 if last else 0o700, dir_fd=descriptor)
                child = os.open(part, flags, dir_fd=descriptor)
                os.fchmod(child, 0o755 if last else 0o700)  # independent of the caller umask
                if not last and os.getuid() == 0:
                    os.fchown(child, owner_uid, owner_gid)
            except OSError as error:
                raise ApprovalError("approval directory path contains a symlink or non-directory") from error
            os.close(descriptor)
            descriptor = child
        metadata = os.fstat(descriptor)
        _require(metadata.st_uid == TRUSTED_APPROVAL_UID and not metadata.st_mode & 0o022,
                 "approval directory is not exclusively writable by the trusted approver")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def store_record(record: Dict[str, Any]) -> Path:
    """Atomically write one record into the trusted approval directory."""
    account = pwd.getpwnam(record["owner"])
    target = record_path(record["owner"], record["operation"], record["plan_digest"])
    directory = _directory_fd(target.parent, account.pw_uid, account.pw_gid)
    temporary = f".{target.name}.{secrets.token_hex(8)}"
    try:
        handle = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644,
                         dir_fd=directory)
        try:
            os.fchmod(handle, 0o644)
            os.write(handle, canonical_json(record) + b"\n")
            os.fsync(handle)
        finally:
            os.close(handle)
        os.replace(temporary, target.name, src_dir_fd=directory, dst_dir_fd=directory)
    except BaseException:
        try:
            os.unlink(temporary, dir_fd=directory)
        except OSError:
            pass
        raise
    finally:
        os.close(directory)
    return target


def _run_as_operator(uid: int, gid: int, action: Callable[[], None]) -> None:
    """Run a write in the operator's own privilege domain (fully dropped under root)."""
    if os.getuid() != 0:
        action()
        return
    child = os.fork()
    if child == 0:  # pragma: no cover - exercised only under real sudo
        code = 1
        try:
            os.setgroups([gid])
            os.setgid(gid)
            os.setuid(uid)
            action()
            code = 0
        finally:
            os._exit(code)
    _, status = os.waitpid(child, 0)
    _require(os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0,
             "could not create the operator cancellation file")


def create_cancellation(owner: str, nonce: str) -> Path:
    """Create the operator-owned 0600 `active:<nonce>` cancellation file."""
    _require(isinstance(nonce, str) and nonce.isalnum(), "approval nonce is invalid")
    account = pwd.getpwnam(owner)
    directory = cancellation_dir(owner)
    path = directory / nonce

    def write() -> None:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        metadata = os.lstat(directory)
        if not stat.S_ISDIR(metadata.st_mode):
            raise OSError("cancellation directory is not a directory")
        handle = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.fchmod(handle, 0o600)
            os.write(handle, f"active:{nonce}\n".encode("utf-8"))
        finally:
            os.close(handle)

    _run_as_operator(account.pw_uid, account.pw_gid, write)
    return path


def verify_cancellation(approval: Dict[str, Any]) -> None:
    """Validate and read the cancellation file through one no-follow, non-blocking descriptor."""
    path = Path(approval["cancellation_path"])
    _require(path.is_absolute(), "cancellation state is unavailable")
    try:
        handle = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise ApprovalError("cancellation state is unavailable") from error
    expected = f"active:{approval['nonce']}\n".encode("utf-8")
    try:
        metadata = os.fstat(handle)
        _require(stat.S_ISREG(metadata.st_mode), "cancellation state is unavailable")
        _require(metadata.st_uid == os.getuid() and stat.S_IMODE(metadata.st_mode) == 0o600,
                 "cancellation state is not private to the operator")
        content = os.read(handle, len(expected) + 1)
    finally:
        os.close(handle)
    _require(content == expected, "operation was cancelled")


def _read_record(path: Path) -> Dict[str, Any]:
    directory = os.lstat(path.parent) if os.path.lexists(path.parent) else None
    _require(directory is not None, "no operator approval record exists for this plan")
    _require(stat.S_ISDIR(directory.st_mode) and directory.st_uid == TRUSTED_APPROVAL_UID
             and not directory.st_mode & 0o022, "approval directory is not trusted")
    try:
        handle = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError as error:
        raise ApprovalError("no operator approval record exists for this plan") from error
    except OSError as error:
        raise ApprovalError("approval record is a symlink or unreadable") from error
    try:
        metadata = os.fstat(handle)
        _require(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == TRUSTED_APPROVAL_UID
                 and not metadata.st_mode & 0o022, "approval record was not written by the trusted approver")
        raw = os.read(handle, MAX_RECORD_BYTES + 1)
    finally:
        os.close(handle)
    _require(len(raw) <= MAX_RECORD_BYTES, "approval record exceeds byte budget")
    try:
        record = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ApprovalError("approval record is not valid JSON") from error
    _require(isinstance(record, dict), "approval record must be an object")
    _require(record.get("schema") == APPROVAL_SCHEMA, "approval schema version is not supported")
    _require(set(record) == RECORD_FIELDS, "approval record fields are invalid")
    return record


def verify(
    plan: Dict[str, Any], operation: str, plan_schema: str, receipt_digest: Optional[str] = None
) -> Dict[str, Any]:
    """Return the trusted record authorising `operation` on exactly `plan`, or raise."""
    owner = getpass.getuser()
    _require(plan.get("owner") == owner, "plan owner does not match the current operator")
    record = _read_record(record_path(owner, operation, plan.get("plan_digest", "")))
    _require(record["operation"] == operation, "approval operation does not match")
    _require(record["plan_schema"] == plan_schema, "approval plan schema does not match")
    _require(record["plan_digest"] == plan["plan_digest"], "approval plan digest does not match")
    _require(record["binding"] == _binding(plan, plan_schema), "approval binding (project/worktree or account) does not match")
    _require(record["action_set"] == plan["action_set"], "approval action set does not match")
    _require(record["receipt_digest"] == receipt_digest, "approval receipt digest does not match")
    _require(record["owner"] == owner, "approval owner does not match")
    issued = _parse_time(record["issued_at"], "approval.issued_at")
    expires = _parse_time(record["expires_at"], "approval.expires_at")
    now = datetime.now(timezone.utc)
    _require(issued <= now < expires, "approval is stale or not yet valid")
    _require((expires - issued).total_seconds() <= MAX_APPROVAL_TTL_SECONDS, "approval freshness window is too broad")
    _require(isinstance(record["nonce"], str) and record["nonce"].isalnum(), "approval nonce is invalid")
    verify_cancellation(record)
    return record


# ── Operator ceremony (root + TTY) ───────────────────────────────────────────


def _load_operator_document(path: str, owner_uid: int) -> Any:
    """Read a plan/receipt as root without following links or reading foreign files."""
    try:
        handle = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        raise ApprovalError("document is missing, a symlink, or unreadable") from error
    try:
        metadata = os.fstat(handle)
        _require(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == owner_uid,
                 "document must be a regular file owned by the approving operator")
        raw = os.read(handle, MAX_DOCUMENT_BYTES + 1)
    finally:
        os.close(handle)
    _require(len(raw) <= MAX_DOCUMENT_BYTES, "document exceeds byte budget")
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise ApprovalError("document is not valid JSON") from error


def _escape(text: Any) -> str:
    """Render document-derived text inert on a terminal (control, format and bidi characters)."""
    return "".join(char if char.isprintable() else f"\\u{ord(char):04x}" for char in str(text))


def _value_lines(label: str, value: Any) -> List[str]:
    lines = str(value).split("\n")
    return [f"    {label} {line}" for line in lines]


def _plan_subject(plan: Any) -> Tuple[Dict[str, Any], str, List[str]]:
    """Summarise exactly what apply executes, never a stored free-text diff."""
    _require(isinstance(plan, dict), "plan must be an object")
    schema = plan.get("schema")
    _require(schema in PLAN_BINDINGS, "plan schema is not approvable")
    unsigned = {key: value for key, value in plan.items() if key != "plan_digest"}
    _require(plan.get("plan_digest") == digest(unsigned), "plan digest is invalid")
    actions = plan.get("actions")
    _require(isinstance(actions, list) and all(isinstance(item, dict) for item in actions), "plan actions are invalid")
    lines = [f"Plan schema: {schema}", f"Plan digest: {plan['plan_digest']}", f"Owner: {plan.get('owner')}"]
    shown = PLAN_BINDINGS[schema] + PLAN_SUMMARY_FIELDS.get(schema, ())
    lines += [f"{field}: {json.dumps(plan.get(field), sort_keys=True)}" for field in shown if field in plan]
    lines.append(f"Authorised action set: {json.dumps(plan.get('action_set'))}")
    if "operations" in plan:  # remote adapters: show the exact payload apply sends, not prose
        operations = plan.get("operations")
        _require(isinstance(operations, list) and len(operations) == len(actions),
                 "plan operations do not match its actions")
        return plan, schema, lines + plan_operation_lines(actions, operations)
    for item in actions:
        if item.get("status") == "ready":
            # apply replaces exactly `old` with `new` once in `path` after verifying before_sha256.
            lines.append(f"- APPLY {item.get('id')} [{item.get('kind')}] {item.get('path', '')} "
                         f"(before {item.get('before_sha256')})")
            lines += _value_lines("-", item.get("old", "")) + _value_lines("+", item.get("new", ""))
        else:
            lines.append(f"- handoff only (not applied): {item.get('id')} [{item.get('kind')}]")
    return plan, schema, lines


def _receipt_subject(receipt: Any) -> Tuple[Dict[str, Any], str, List[str], str]:
    _require(isinstance(receipt, dict), "receipt must be an object")
    plan_schema = RECEIPT_PLAN_SCHEMAS.get(receipt.get("schema", ""))
    _require(plan_schema is not None, "receipt schema is not approvable")
    # rolling_back: a remote adapter persisted rollback intent and is reconciling an interrupted rollback.
    _require(receipt.get("status") in {"applied", "rolling_back", "rolled_back"}, "receipt is not rollback-ready")
    subject = {field: receipt.get(field) for field in ("plan_digest", "owner") + PLAN_BINDINGS[plan_schema]}
    lines = [f"Rollback of plan: {receipt.get('plan_digest')}", f"Owner: {receipt.get('owner')}"]
    lines += [f"{field}: {receipt.get(field)}" for field in PLAN_BINDINGS[plan_schema]]
    if "actions" in receipt:  # remote adapters record their own ordered action set
        actions = receipt.get("actions")
        _require(isinstance(actions, list) and all(isinstance(item, dict) for item in actions),
                 "receipt actions are invalid")
        subject["action_set"] = receipt.get("action_set")
        lines.append(f"Authorised action set: {json.dumps(subject['action_set'])}")
        lines += receipt_inverse_lines(actions)
    else:
        files = receipt.get("files")
        _require(isinstance(files, list) and all(isinstance(item, dict) for item in files),
                 "receipt files are invalid")
        subject["action_set"] = [item.get("action_id") for item in files]
        lines.append(f"Authorised action set: {json.dumps(subject['action_set'])}")
        lines += [f"- RESTORE {item.get('action_id')} {item.get('path')} (to {item.get('before_sha256')})"
                  for item in files]
    return subject, plan_schema, lines, digest(receipt)


def mint(
    plan_path: Optional[str] = None, receipt_path: Optional[str] = None,
    stream: Any = None, prompt: Callable[[str], str] = input,
) -> Dict[str, Any]:
    """Interactive root-only approval ceremony; returns the stored record summary."""
    output = stream or sys.stderr
    _require(os.geteuid() == 0, "marketing-plan approval must run as root via sudo aidevops approve")
    operator = os.environ.get("SUDO_USER", "")
    _require(bool(operator) and operator != "root", "marketing-plan approval requires sudo from the operator account")
    _require(sys.stdin.isatty(), "marketing-plan approval requires an interactive terminal")
    _require((plan_path is None) != (receipt_path is None), "approve exactly one plan or one receipt")
    account = pwd.getpwnam(operator)
    if plan_path is not None:
        operation, receipt_digest = "apply", None
        subject, plan_schema, lines = _plan_subject(_load_operator_document(plan_path, account.pw_uid))
    else:
        operation = "rollback"
        subject, plan_schema, lines, receipt_digest = _receipt_subject(
            _load_operator_document(str(receipt_path), account.pw_uid))
    _require(subject.get("owner") == operator, "plan owner is not the approving operator")
    # Never approve what was not shown: an oversized review is refused, not truncated.
    _require(len(lines) <= MAX_SUMMARY_LINES,
             f"plan review exceeds {MAX_SUMMARY_LINES} lines; split it into smaller plans")
    print("\n".join(_escape(line) for line in lines), file=output)
    ttl_minutes = MAX_APPROVAL_TTL_SECONDS // 60
    answer = prompt(f"Type {CONFIRMATION} to authorise {operation} for {ttl_minutes} minutes: ")
    _require(answer.strip() == CONFIRMATION, "approval was not confirmed")
    nonce = secrets.token_hex(16)
    cancellation = create_cancellation(operator, nonce)
    record = build_record(subject, operation, plan_schema, receipt_digest=receipt_digest, nonce=nonce,
                          cancellation_path=str(cancellation))
    path = store_record(record)
    return {
        "status": "approved", "operation": operation, "plan_digest": record["plan_digest"],
        "expires_at": record["expires_at"], "record_path": str(path), "cancellation_path": str(cancellation),
    }
