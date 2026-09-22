#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Approval-bound, local-only marketing file mutations."""

from __future__ import annotations

import base64
import difflib
import getpass
import hashlib
import hmac
import json
import os
import stat
from datetime import datetime, timezone
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import marketing_action_io as action_io

INPUT_SCHEMA = "aidevops.marketing-action-input/v1"
PLAN_SCHEMA = "aidevops.marketing-action-plan/v1"
APPROVAL_SCHEMA = "aidevops.marketing-action-approval/v1"
RECEIPT_SCHEMA = "aidevops.marketing-action-receipt/v1"
ALLOWED_ACTIONS = {"title", "meta_description", "internal_link"}
EXCLUDED_ACTIONS = {
    "noindex",
    "canonical",
    "redirect",
    "delete",
    "budget",
    "bid",
    "negative_keyword",
    "campaign",
    "pixel",
    "conversion",
    "community_moderation",
    "community_post",
}
MAX_ACTIONS = 50
MAX_APPROVAL_TTL_SECONDS = 900
ActionError = action_io.ActionError
_require = action_io.require
canonical_json = action_io.canonical_json
digest_bytes = action_io.digest_bytes
digest = action_io.digest
load_json = action_io.load_json
_run_git = action_io.run_git
_validate_worktree = action_io.validate_worktree
_safe_target = action_io.safe_target
_read_target = action_io.read_target
_write_target = action_io.write_target
_private_directory = action_io.private_directory
_atomic_write = action_io.atomic_write
_operation_lock = action_io.operation_lock
_receipt_path = action_io.receipt_path


def _keys(value: dict[str, Any], required: set[str], allowed: set[str], field: str) -> None:
    _require(required <= set(value), f"{field} is missing required fields")
    _require(not set(value) - allowed, f"{field} contains unknown fields")


def _replacement(action: dict[str, Any], before: bytes) -> bytes:
    old = action["old"].encode("utf-8")
    new = action["new"].encode("utf-8")
    _require(old and old != new, f"action {action['id']} must change exact non-empty content")
    count = before.count(old)
    _require(count == action["expected_matches"] == 1, f"action {action['id']} exact match count changed")
    return before.replace(old, new, 1)


def build_plan(value: Any) -> dict[str, Any]:
    """Validate an input proposal and return its exact, current-state-bound plan."""
    _require(isinstance(value, dict), "input must be an object")
    required = {"schema", "project_root", "owner", "source_evidence", "actions"}
    _keys(value, required, required, "input")
    _require(value["schema"] == INPUT_SCHEMA, "unknown input schema version")
    owner = getpass.getuser() if value["owner"] == "current" else value["owner"]
    _require(isinstance(owner, str) and owner == getpass.getuser(), "input owner must be the current operator")
    evidence = value["source_evidence"]
    _require(isinstance(evidence, list) and evidence and all(isinstance(item, str) and item for item in evidence),
             "source_evidence must be a non-empty string array")
    root, branch, worktree_identity = _validate_worktree(value["project_root"])
    actions = value["actions"]
    _require(isinstance(actions, list) and 0 < len(actions) <= MAX_ACTIONS, "actions exceed supported bounds")
    normalized: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    seen_paths: set[str] = set()
    for index, raw in enumerate(actions):
        _require(isinstance(raw, dict), f"actions[{index}] must be an object")
        action_id = raw.get("id")
        kind = raw.get("kind")
        _require(isinstance(action_id, str) and action_id and action_id not in seen_ids, "action IDs must be unique")
        seen_ids.add(action_id)
        if kind in EXCLUDED_ACTIONS:
            _keys(raw, {"id", "kind", "handoff"}, {"id", "kind", "handoff"}, f"actions[{index}]")
            _require(isinstance(raw["handoff"], str) and raw["handoff"], "excluded actions require a handoff")
            normalized.append({"id": action_id, "kind": kind, "status": "handoff_only", "handoff": raw["handoff"]})
            continue
        _require(kind in ALLOWED_ACTIONS, f"action {action_id} has an unsupported kind")
        fields = {"id", "kind", "path", "old", "new", "expected_matches"}
        _keys(raw, fields, fields, f"actions[{index}]")
        relative = raw["path"]
        _require(isinstance(relative, str) and relative not in seen_paths, "mutable action paths must be unique")
        seen_paths.add(relative)
        _require(raw["expected_matches"] == 1, "only one exact replacement per file is supported")
        _safe_target(root, relative)
        before, _, identity = _read_target(root, relative)
        after = _replacement(raw, before)
        try:
            before_text = before.decode("utf-8")
            after_text = after.decode("utf-8")
        except UnicodeDecodeError as error:
            raise ActionError(f"action {action_id} target is not UTF-8 text") from error
        exact_diff = "".join(difflib.unified_diff(
            before_text.splitlines(keepends=True), after_text.splitlines(keepends=True),
            fromfile=f"a/{relative}", tofile=f"b/{relative}",
        ))
        normalized.append({
            "id": action_id, "kind": kind, "status": "ready", "path": relative,
            "before_sha256": digest_bytes(before), "after_sha256": digest_bytes(after),
            "before_size": len(before), "after_size": len(after), "diff": exact_diff,
            "old": raw["old"], "new": raw["new"], "expected_matches": 1,
            "target_identity": [identity[0], identity[1]],
        })
    plan = {
        "schema": PLAN_SCHEMA,
        "project_root": str(root),
        "branch": branch,
        "worktree_identity": worktree_identity,
        "owner": owner,
        "source_evidence": evidence,
        "action_set": [item["id"] for item in normalized if item["status"] == "ready"],
        "limits": {"max_actions": MAX_ACTIONS, "remote_operations": 0, "account_operations": 0},
        "rollback": "receipt-bound exact-byte restore after current-after-hash verification",
        "actions": normalized,
    }
    plan["plan_digest"] = digest(plan)
    return plan


def validate_plan(value: Any) -> dict[str, Any]:
    """Validate a persisted plan without rebuilding its potentially partial before-state."""
    _require(isinstance(value, dict), "plan must be an object")
    required = {
        "schema", "project_root", "branch", "worktree_identity", "owner", "source_evidence", "action_set",
        "limits", "rollback", "actions", "plan_digest",
    }
    _keys(value, required, required, "plan")
    _require(value["schema"] == PLAN_SCHEMA, "unknown plan schema version")
    claimed = value["plan_digest"]
    unsigned = {key: item for key, item in value.items() if key != "plan_digest"}
    _require(claimed == digest(unsigned), "persisted plan digest is invalid")
    _require(value["owner"] == getpass.getuser(), "plan owner does not match the current operator")
    _require(isinstance(value["actions"], list) and len(value["actions"]) <= MAX_ACTIONS, "plan actions exceed bounds")
    ready_ids = []
    for item in value["actions"]:
        _require(isinstance(item, dict) and item.get("status") in {"ready", "handoff_only"}, "plan action is invalid")
        if item["status"] == "ready":
            _require(item.get("kind") in ALLOWED_ACTIONS and isinstance(item.get("path"), str), "ready action is invalid")
            _require(item.get("expected_matches") == 1, "ready action replacement bound is invalid")
            _require(isinstance(item.get("target_identity"), list) and len(item["target_identity"]) == 2
                     and all(isinstance(part, int) for part in item["target_identity"]),
                     "ready action target identity is invalid")
            ready_ids.append(item.get("id"))
        else:
            _require(item.get("kind") in EXCLUDED_ACTIONS, "handoff action is invalid")
    _require(ready_ids == value["action_set"], "plan action set is inconsistent")
    return value


def _read_inherited_fd(name: str, maximum: int) -> bytes:
    raw_fd = os.environ.get(name)
    _require(raw_fd is not None and raw_fd.isdigit(), f"trusted runtime did not supply {name}")
    fd = int(raw_fd)
    metadata = os.fstat(fd)
    _require(stat.S_ISFIFO(metadata.st_mode) or stat.S_ISSOCK(metadata.st_mode), f"{name} must be an inherited pipe")
    value = os.read(fd, maximum + 1)
    _require(len(value) <= maximum, f"{name} exceeds byte budget")
    return value


def _parse_time(value: Any, field: str) -> datetime:
    _require(isinstance(value, str) and value.endswith("Z"), f"{field} must be a UTC timestamp")
    try:
        return datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise ActionError(f"{field} must be a UTC timestamp") from error


def _verify_cancellation(approval: dict[str, Any]) -> None:
    path = Path(approval["cancellation_path"])
    _require(path.is_absolute() and path.is_file() and not path.is_symlink(), "cancellation state is unavailable")
    metadata = path.stat()
    _require(metadata.st_uid == os.getuid() and stat.S_IMODE(metadata.st_mode) == 0o600,
             "cancellation state is not private to the operator")
    expected = f"active:{approval['nonce']}\n".encode("utf-8")
    _require(path.read_bytes() == expected, "operation was cancelled")


def verify_runtime_approval(
    plan: dict[str, Any], operation: str, receipt_digest: str | None = None
) -> dict[str, Any]:
    """Consume and authenticate one runtime-provided approval from inherited pipes."""
    approval_raw = _read_inherited_fd("AIDEVOPS_MARKETING_APPROVAL_FD", 16_384)
    key = _read_inherited_fd("AIDEVOPS_MARKETING_APPROVAL_KEY_FD", 256)
    _require(len(key) >= 32, "runtime approval key is too short")
    try:
        approval = json.loads(approval_raw)
    except json.JSONDecodeError as error:
        raise ActionError("runtime approval is not valid JSON") from error
    _require(isinstance(approval, dict), "runtime approval must be an object")
    fields = {
        "schema", "operation", "plan_digest", "project_root", "worktree_identity", "action_set", "owner",
        "issued_at", "expires_at", "nonce", "cancellation_path", "receipt_digest", "signature",
    }
    _keys(approval, fields, fields, "approval")
    _require(approval["schema"] == APPROVAL_SCHEMA and approval["operation"] == operation,
             "approval version or operation does not match")
    _require(approval["plan_digest"] == plan["plan_digest"], "approval plan digest does not match")
    _require(approval["project_root"] == plan["project_root"], "approval project does not match")
    _require(approval["worktree_identity"] == plan["worktree_identity"], "approval worktree does not match")
    _require(approval["action_set"] == plan["action_set"], "approval action set does not match")
    _require(approval["receipt_digest"] == receipt_digest, "approval receipt digest does not match")
    _require(approval["owner"] == plan["owner"] == getpass.getuser(), "approval owner does not match")
    issued = _parse_time(approval["issued_at"], "approval.issued_at")
    expires = _parse_time(approval["expires_at"], "approval.expires_at")
    now = datetime.now(timezone.utc)
    _require(issued <= now < expires, "approval is stale or not yet valid")
    _require((expires - issued).total_seconds() <= MAX_APPROVAL_TTL_SECONDS, "approval freshness window is too broad")
    signature = approval.pop("signature")
    expected = hmac.new(key, canonical_json(approval), hashlib.sha256).hexdigest()
    _require(isinstance(signature, str) and hmac.compare_digest(signature, expected), "approval signature is invalid")
    approval["signature"] = signature
    _verify_cancellation(approval)
    return approval


def _validate_receipt_for_plan(receipt: Any, plan: dict[str, Any]) -> dict[str, Any]:
    _require(isinstance(receipt, dict) and receipt.get("schema") == RECEIPT_SCHEMA, "receipt schema is invalid")
    required = {
        "schema", "status", "plan_digest", "project_root", "worktree_identity", "owner", "approval_nonce",
        "files", "remaining_action_ids",
    }
    allowed = required | {"completed_at"}
    _keys(receipt, required, allowed, "receipt")
    _require(receipt["status"] in {"applying", "applied"}, "receipt state cannot be resumed")
    for field in ("plan_digest", "project_root", "worktree_identity", "owner"):
        _require(receipt[field] == plan[field], f"receipt {field} does not match the plan")
    ready = {item["id"]: item for item in plan["actions"] if item["status"] == "ready"}
    files = receipt["files"]
    remaining = receipt["remaining_action_ids"]
    _require(isinstance(files, list) and isinstance(remaining, list), "receipt checkpoint arrays are invalid")
    _require(len(remaining) == len(set(remaining)) and set(remaining) <= set(ready),
             "receipt remaining action set is invalid")
    seen: set[str] = set()
    for record in files:
        _require(isinstance(record, dict), "receipt file record is invalid")
        fields = {"action_id", "path", "before_sha256", "after_sha256", "before_base64"}
        _keys(record, fields, fields, "receipt.files[]")
        action_id = record["action_id"]
        _require(action_id in ready and action_id not in seen, "receipt file action is duplicate or foreign")
        seen.add(action_id)
        action = ready[action_id]
        for field in ("path", "before_sha256", "after_sha256"):
            _require(record[field] == action[field], f"receipt file {field} does not match the plan")
        try:
            before = base64.b64decode(record["before_base64"], validate=True)
        except (ValueError, TypeError) as error:
            raise ActionError("receipt before-state is invalid") from error
        _require(digest_bytes(before) == action["before_sha256"], "receipt before-state hash is invalid")
    _require(set(ready) - seen <= set(remaining), "receipt omits an unapplied action")
    if receipt["status"] == "applied":
        _require(seen == set(ready) and not remaining and "completed_at" in receipt,
                 "completed receipt checkpoint is inconsistent")
    else:
        _require("completed_at" not in receipt, "applying receipt cannot be completed")
    return receipt


def _new_receipt(plan: dict[str, Any], identity: str, approval: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema": RECEIPT_SCHEMA, "status": "applying", "plan_digest": plan["plan_digest"],
        "project_root": plan["project_root"], "worktree_identity": identity, "owner": plan["owner"],
        "approval_nonce": approval["nonce"], "files": [], "remaining_action_ids": plan["action_set"].copy(),
    }


def _load_receipt(receipt_path: Path, plan: dict[str, Any], root: Path) -> tuple[dict[str, Any], bool]:
    receipt = _validate_receipt_for_plan(load_json(receipt_path), plan)
    states = [digest_bytes(_read_target(root, item["path"])[0]) for item in receipt["files"]]
    expected = [{item["before_sha256"], item["after_sha256"]} for item in receipt["files"]]
    _require(all(current in allowed for current, allowed in zip(states, expected, strict=True)),
             "interrupted-plan recovery found unrelated content")
    if receipt["status"] != "applied":
        return receipt, False
    _require(all(current == item["after_sha256"] for current, item in zip(states, receipt["files"], strict=True)),
             "applied-plan replay found changed content")
    return receipt, True


def _preflight_ready(root: Path, ready: list[dict[str, Any]], recorded: set[str]) -> None:
    for item in ready:
        state = _read_target(root, item["path"])
        current = digest_bytes(state[0])
        allowed = {item["before_sha256"]} | ({item["after_sha256"]} if item["id"] in recorded else set())
        _require(current in allowed, f"{item['path']} changed after planning")
        if current == item["before_sha256"]:
            _require(list(state[2]) == item["target_identity"], f"{item['path']} identity changed after planning")


def _checkpoint(receipt_path: Path, receipt: dict[str, Any]) -> None:
    _atomic_write(receipt_path, canonical_json(receipt) + b"\n")


@dataclass
class _ApplyContext:
    root: Path
    approval: dict[str, Any]
    receipt: dict[str, Any]
    receipt_path: Path
    recorded: dict[str, dict[str, Any]]


def _apply_ready_action(context: _ApplyContext, item: dict[str, Any]) -> None:
    _verify_cancellation(context.approval)
    before, _, identity_now = _read_target(context.root, item["path"])
    current_digest = digest_bytes(before)
    if current_digest == item["after_sha256"] and item["id"] in context.recorded:
        if item["id"] in context.receipt["remaining_action_ids"]:
            context.receipt["remaining_action_ids"].remove(item["id"])
            _checkpoint(context.receipt_path, context.receipt)
        return
    _require(current_digest == item["before_sha256"], f"{item['path']} changed after planning")
    after = _replacement(item, before)
    _require(digest_bytes(after) == item["after_sha256"], f"{item['path']} after-state is inconsistent")
    if item["id"] not in context.recorded:
        stored = {
            "action_id": item["id"], "path": item["path"],
            "before_sha256": item["before_sha256"], "after_sha256": item["after_sha256"],
            "before_base64": base64.b64encode(before).decode("ascii"),
        }
        context.receipt["files"].append(stored)
        context.recorded[item["id"]] = stored
        _checkpoint(context.receipt_path, context.receipt)
    _write_target(context.root, item["path"], after, item["before_sha256"], identity_now)
    if item["id"] in context.receipt["remaining_action_ids"]:
        context.receipt["remaining_action_ids"].remove(item["id"])
    _checkpoint(context.receipt_path, context.receipt)


def apply_plan(plan: dict[str, Any], receipt_directory: str | Path) -> tuple[dict[str, Any], bool]:
    """Apply an exact approved plan transactionally, or replay its final receipt."""
    approval = verify_runtime_approval(plan, "apply")
    _require(bool(plan["action_set"]), "handoff-only plans cannot be applied")
    root, branch, identity = _validate_worktree(plan["project_root"])
    _require(branch == plan["branch"] and identity == plan["worktree_identity"], "worktree identity changed")
    receipt_path = _receipt_path(_private_directory(receipt_directory), plan["plan_digest"])
    receipt, replayed = (_load_receipt(receipt_path, plan, root) if receipt_path.exists()
                         else (_new_receipt(plan, identity, approval), False))
    if replayed:
        return receipt, True
    ready = [item for item in plan["actions"] if item["status"] == "ready"]
    recorded = {item["action_id"]: item for item in receipt["files"]}
    context = _ApplyContext(root, approval, receipt, receipt_path, recorded)
    with _operation_lock(root):
        _checkpoint(receipt_path, receipt)
        _preflight_ready(root, ready, set(recorded))
        for item in ready:
            _apply_ready_action(context, item)
        receipt["status"] = "applied"
        receipt["completed_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        _checkpoint(receipt_path, receipt)
    return receipt, False


def rollback_receipt(receipt: dict[str, Any], receipt_path: str | Path) -> tuple[dict[str, Any], bool]:
    """Restore exact owned before-bytes when every current after-hash still matches."""
    _require(receipt.get("schema") == RECEIPT_SCHEMA, "unknown receipt schema version")
    _require(receipt.get("status") in {"applied", "rolled_back"}, "receipt is not rollback-ready")
    plan = {
        "plan_digest": receipt["plan_digest"], "project_root": receipt["project_root"],
        "worktree_identity": receipt["worktree_identity"], "owner": receipt["owner"],
        "action_set": [item["action_id"] for item in receipt["files"]],
    }
    approval = verify_runtime_approval(plan, "rollback", digest(receipt))
    if receipt["status"] == "rolled_back":
        return receipt, True
    root, _, identity = _validate_worktree(receipt["project_root"])
    _require(identity == receipt["worktree_identity"], "rollback worktree identity changed")
    lexical_path = Path(receipt_path).expanduser().absolute()
    _require(lexical_path.is_file() and not lexical_path.is_symlink(), "receipt path is unavailable")
    receipt_dir = _private_directory(lexical_path.parent)
    path = lexical_path.resolve()
    _require(path == _receipt_path(receipt_dir, receipt["plan_digest"]), "receipt path does not match its plan")
    metadata = path.stat()
    _require(metadata.st_uid == os.getuid() and stat.S_IMODE(metadata.st_mode) == 0o600,
             "receipt is not private to the operator")
    _require(load_json(path) == receipt, "receipt content changed before rollback")
    with _operation_lock(root):
        targets = [(item, _read_target(root, item["path"])) for item in receipt["files"]]
        for item, target_state in targets:
            _require(digest_bytes(target_state[0]) == item["after_sha256"],
                     f"rollback refused because {item['path']} has unrelated changes")
        for item, target_state in reversed(targets):
            _verify_cancellation(approval)
            before = base64.b64decode(item["before_base64"], validate=True)
            _require(digest_bytes(before) == item["before_sha256"], "receipt before-state is corrupt")
            _write_target(root, item["path"], before, item["after_sha256"], target_state[2])
        receipt["status"] = "rolled_back"
        receipt["rolled_back_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        _atomic_write(path, canonical_json(receipt) + b"\n")
    return receipt, False
