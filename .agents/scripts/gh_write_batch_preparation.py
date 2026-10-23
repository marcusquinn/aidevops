"""Manifest and body normalization before GitHub batch publication."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from gh_write_batch_common import (
    MAX_BODY_BYTES,
    MAX_OPERATIONS,
    PREPARED_SCHEMA,
    REPO_RE,
    SCHEMA,
    BatchError,
    BodyPreparation,
    exact_keys,
    load_json,
    load_recovery,
    now_iso,
    private_input,
    private_root,
    substantive,
    validate_labels,
    validate_operation_identity,
    validate_recovery_operation,
    write_private_json,
)


def signature_footer(helper: Path) -> str:
    try:
        result = subprocess.run(  # nosec B603 - fixed owner-controlled helper path
            [str(helper), "footer"], text=True, capture_output=True, timeout=10, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise BatchError(f"signature helper failed: {exc}") from exc
    if result.returncode != 0 or "<!-- aidevops:sig -->" not in result.stdout:
        raise BatchError("signature helper did not return a canonical footer")
    return result.stdout


def copy_body(
    source: Path,
    kind: str,
    operation_id: str,
    context: BodyPreparation,
) -> tuple[str, str, str]:
    body = source.read_text(encoding="utf-8")
    source_digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
    if len(body.encode("utf-8")) > MAX_BODY_BYTES or not substantive(body):
        raise BatchError(f"operation {operation_id} body is empty or exceeds {MAX_BODY_BYTES} bytes")
    needs_signature = kind in {"issue_comment", "pr_comment", "pr_edit"}
    marker = f"<!-- aidevops:batch:{context.marker_sha}:{operation_id} -->"
    if kind in {"issue_comment", "pr_comment"} and marker not in body.splitlines():
        signature_at = body.find("<!-- aidevops:sig -->")
        if signature_at >= 0:
            body = f"{body[:signature_at].rstrip()}\n{marker}\n\n{body[signature_at:]}"
        else:
            body = f"{body.rstrip()}\n\n{marker}\n"
    if needs_signature and "<!-- aidevops:sig -->" not in body.splitlines():
        body = f"{body}{signature_footer(context.signature_helper)}"
    fd, copied = tempfile.mkstemp(prefix="gh-write-batch-body.", dir=context.root)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(body)
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
    return copied, digest, source_digest


def load_manifest(args: argparse.Namespace) -> tuple[Path, Path, dict[str, Any], str]:
    root = private_root(args.temp_root)
    manifest_path = private_input(args.manifest, root, "manifest")
    helper = Path(args.signature_helper).resolve(strict=True)
    manifest_sha = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    return root, helper, load_json(manifest_path, "manifest"), manifest_sha


def validate_manifest(manifest: dict[str, Any]) -> tuple[str, list[dict[str, Any]]]:
    exact_keys(manifest, {"schema", "repository", "operations", "recovery_of"}, "manifest")
    if manifest.get("schema") != SCHEMA:
        raise BatchError(f"manifest schema must be {SCHEMA}")
    repository = manifest.get("repository")
    if not isinstance(repository, str) or not REPO_RE.fullmatch(repository):
        raise BatchError("manifest repository must be an exact owner/name slug")
    raw_operations = manifest.get("operations")
    if not isinstance(raw_operations, list) or not 1 <= len(raw_operations) <= MAX_OPERATIONS:
        raise BatchError(f"manifest must contain 1-{MAX_OPERATIONS} operations")
    return repository, raw_operations


def validate_comment_shape(raw: dict[str, Any], operation: dict[str, Any]) -> str:
    if "body_file" not in raw or "title" in raw or "labels" in raw:
        raise BatchError(f"operation {operation['id']} comment shape is invalid")
    return "comment"


def validate_edit_shape(raw: dict[str, Any], operation: dict[str, Any]) -> str:
    if "labels" in raw or ("body_file" not in raw and "title" not in raw):
        raise BatchError(f"operation {operation['id']} edit shape is invalid")
    title = raw.get("title")
    if title is not None:
        stub = isinstance(title, str) and re.fullmatch(r"(?:t[0-9]+|GH#[0-9]+):\s*", title.strip())
        if not isinstance(title, str) or not title.strip() or len(title) > 256 or stub:
            raise BatchError(f"operation {operation['id']} title is invalid")
        operation["title"] = title
    return "scalar"


def validate_label_shape(raw: dict[str, Any], operation: dict[str, Any]) -> str:
    if "labels" not in raw or "body_file" in raw or "title" in raw:
        raise BatchError(f"operation {operation['id']} label shape is invalid")
    operation["labels"] = validate_labels(raw["labels"], operation["id"])
    return "labels"


def normalize_operation(
    raw: Any, index: int, context: BodyPreparation, copied_files: list[str]
) -> tuple[dict[str, Any], str]:
    operation = validate_operation_identity(raw, index)
    kind = operation["kind"]
    if kind.endswith("_comment"):
        field = validate_comment_shape(raw, operation)
    elif kind.endswith("_edit"):
        field = validate_edit_shape(raw, operation)
    else:
        field = validate_label_shape(raw, operation)
    if "body_file" in raw:
        source = private_input(raw["body_file"], context.root, f"operation {operation['id']} body")
        copied, body_sha, source_sha = copy_body(source, kind, operation["id"], context)
        copied_files.append(copied)
        operation.update(body_file=copied, body_sha256=body_sha, source_sha256=source_sha)
    return operation, field


def prepare(args: argparse.Namespace) -> int:
    root, helper, manifest, manifest_sha = load_manifest(args)
    repository, raw_operations = validate_manifest(manifest)
    recovery_of = manifest.get("recovery_of")
    recovery_operations, marker_sha = load_recovery(recovery_of, root, repository, manifest_sha)
    context = BodyPreparation(root, marker_sha, helper)

    operation_ids: set[str] = set()
    field_owners: set[tuple[str, int, str]] = set()
    operations: list[dict[str, Any]] = []
    copied_files: list[str] = []
    try:
        for index, raw in enumerate(raw_operations):
            operation, field = normalize_operation(raw, index, context, copied_files)
            operation_id = operation["id"]
            if operation_id in operation_ids:
                raise BatchError(f"duplicate operation id {operation_id}")
            operation_ids.add(operation_id)
            owner_key = (operation["target_type"], operation["number"], field)
            if field != "comment" and owner_key in field_owners:
                raise BatchError(
                    f"dependent operations repeat {field} on {operation['target_type']} #{operation['number']}"
                )
            field_owners.add(owner_key)
            if recovery_of is not None:
                validate_recovery_operation(operation, recovery_operations)
            operations.append(operation)
        unknown_ids = {
            operation_id
            for operation_id, operation in recovery_operations.items()
            if operation.get("status") == "unknown"
        }
        if recovery_of is not None and operation_ids != unknown_ids:
            raise BatchError("recovery manifest must contain exactly the receipt's unknown operations")
        prepared = {
            "schema": PREPARED_SCHEMA,
            "manifest_sha256": manifest_sha,
            "repository": repository,
            "recovery_of": marker_sha if recovery_of is not None else None,
            "prepared_at": now_iso(),
            "operations": operations,
        }
        write_private_json(Path(args.output), prepared)
    except Exception:
        for copied in copied_files:
            Path(copied).unlink(missing_ok=True)
        raise
    return 0
