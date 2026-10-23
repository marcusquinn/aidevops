"""Shared schemas, private storage, identity and recovery for GitHub batches."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, NamedTuple

SCHEMA = "aidevops.github-write-batch/v1"
PREPARED_SCHEMA = "aidevops.github-write-batch-prepared/v1"
RECEIPT_SCHEMA = "aidevops.github-write-batch-receipt/v1"
MAX_OPERATIONS = 10
MAX_BODY_BYTES = 1_000_000
KINDS = {
    "issue_comment",
    "pr_comment",
    "issue_edit",
    "pr_edit",
    "issue_add_labels",
    "issue_remove_labels",
    "pr_add_labels",
    "pr_remove_labels",
}
PROTECTED_LABELS = {
    "needs-maintainer-review",
    "ai-approved",
    "external-contributor",
    "parent-task",
    "auto-dispatch",
    "hold-for-review",
    "no-auto-dispatch",
    "lockdown",
}
PROTECTED_LABEL_PREFIXES = ("origin:", "status:", "solved:", "publication:")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")


class BatchError(Exception):
    """A fail-closed validation or execution error."""


class BodyPreparation(NamedTuple):
    """Trusted context used while normalizing manifest body files."""

    root: Path
    marker_sha: str
    signature_helper: Path


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def private_root(value: str) -> Path:
    root = Path(value).expanduser().resolve(strict=True)
    info = root.stat()
    if not root.is_dir() or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise BatchError("temporary root must be an owner-only directory")
    return root


def private_input(path_value: str, root: Path, label: str) -> Path:
    if not isinstance(path_value, str) or not path_value or any(ord(ch) < 32 for ch in path_value):
        raise BatchError(f"{label} path is invalid")
    raw = Path(path_value).expanduser()
    if not raw.is_absolute() or raw.is_symlink():
        raise BatchError(f"{label} must be an absolute non-symlink file")
    path = raw.resolve(strict=True)
    if path.parent != root and root not in path.parents:
        raise BatchError(f"{label} must be under AIDEVOPS_TEMP_DIR")
    info = path.stat()
    if not path.is_file() or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise BatchError(f"{label} must be an owner-only regular file")
    return path


def write_private_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)  # nosec B103 - owner-only writable directory
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, sort_keys=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise BatchError(f"{label} is not valid UTF-8 JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise BatchError(f"{label} root must be an object")
    return value


def exact_keys(value: dict[str, Any], allowed: set[str], label: str) -> None:
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise BatchError(f"{label} contains unsupported fields: {', '.join(unknown)}")


def substantive(text: str) -> bool:
    return bool(unsigned_body(text))


def unsigned_body(text: str) -> str:
    return text.split("<!-- aidevops:sig -->", 1)[0].rstrip()


def validate_labels(value: Any, operation_id: str) -> list[str]:
    if not isinstance(value, list) or not value or len(value) > 10:
        raise BatchError(f"operation {operation_id} labels must contain 1-10 values")
    labels: list[str] = []
    for label in value:
        if not isinstance(label, str) or not label or len(label) > 100 or label.strip() != label:
            raise BatchError(f"operation {operation_id} has an invalid label")
        if label in PROTECTED_LABELS or label.startswith(PROTECTED_LABEL_PREFIXES):
            raise BatchError(f"operation {operation_id} cannot mutate protected label {label}")
        if label in labels:
            raise BatchError(f"operation {operation_id} repeats label {label}")
        labels.append(label)
    return labels


def operation_intent_sha(operation: dict[str, Any]) -> str:
    intent = {
        key: operation[key]
        for key in ("kind", "number", "source_sha256", "title", "labels")
        if key in operation
    }
    encoded = json.dumps(intent, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def load_recovery(
    recovery_of: Any, root: Path, repository: str, manifest_sha: str
) -> tuple[dict[str, dict[str, Any]], str]:
    if recovery_of is None:
        return {}, manifest_sha
    if not isinstance(recovery_of, dict):
        raise BatchError("recovery_of must identify an owner-only receipt")
    exact_keys(recovery_of, {"manifest_sha256", "receipt_file"}, "recovery_of")
    recovery_sha = recovery_of.get("manifest_sha256")
    if not isinstance(recovery_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", recovery_sha):
        raise BatchError("recovery_of manifest_sha256 is invalid")
    receipt_path = private_input(recovery_of.get("receipt_file"), root, "recovery receipt")
    receipt = load_json(receipt_path, "recovery receipt")
    if (
        receipt.get("schema") != RECEIPT_SCHEMA
        or receipt.get("manifest_sha256") != recovery_sha
        or receipt.get("repository") != repository
    ):
        raise BatchError("recovery receipt does not match this repository and manifest")
    marker_sha = receipt.get("marker_sha256")
    if not isinstance(marker_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", marker_sha):
        raise BatchError("recovery receipt marker lineage is invalid")
    receipt_operations = receipt.get("operations")
    if not isinstance(receipt_operations, list):
        raise BatchError("recovery receipt operations are invalid")
    operations = {
        operation.get("id"): operation
        for operation in receipt_operations
        if isinstance(operation, dict) and isinstance(operation.get("id"), str)
    }
    return operations, marker_sha


def validate_operation_identity(raw: Any, index: int) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise BatchError(f"operation {index} must be an object")
    exact_keys(raw, {"id", "kind", "number", "body_file", "title", "labels"}, f"operation {index}")
    operation_id = raw.get("id")
    kind = raw.get("kind")
    number = raw.get("number")
    if not isinstance(operation_id, str) or not ID_RE.fullmatch(operation_id):
        raise BatchError(f"operation {index} id is invalid")
    if kind not in KINDS:
        raise BatchError(f"operation {operation_id} kind is unsupported")
    if isinstance(number, bool) or not isinstance(number, int) or number < 1:
        raise BatchError(f"operation {operation_id} number must be a positive integer")
    return {
        "id": operation_id,
        "kind": kind,
        "number": number,
        "target_type": "PullRequest" if kind.startswith("pr_") else "Issue",
    }


def validate_recovery_operation(
    operation: dict[str, Any], recovery_operations: dict[str, dict[str, Any]]
) -> None:
    previous = recovery_operations.get(operation["id"])
    if not isinstance(previous, dict) or previous.get("status") != "unknown":
        raise BatchError(f"operation {operation['id']} is not unknown in the recovery receipt")
    if previous.get("kind") != operation["kind"] or previous.get("number") != operation["number"]:
        raise BatchError(f"operation {operation['id']} does not match its recovery receipt identity")
    if previous.get("intent_sha256") != operation_intent_sha(operation):
        raise BatchError(f"operation {operation['id']} payload does not match its recovery receipt")
