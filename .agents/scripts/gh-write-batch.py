#!/usr/bin/env python3
"""Prepare and execute bounded, safety-preserving GitHub write batches."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

from gh_write_batch_graphql import mutation, preflight_query
# Explicit re-exports preserve the importlib API while publication stays local.
from gh_write_batch_common import (
    ID_RE as ID_RE,
    KINDS as KINDS,
    MAX_BODY_BYTES as MAX_BODY_BYTES,
    MAX_OPERATIONS as MAX_OPERATIONS,
    PREPARED_SCHEMA as PREPARED_SCHEMA,
    PROTECTED_LABEL_PREFIXES as PROTECTED_LABEL_PREFIXES,
    PROTECTED_LABELS as PROTECTED_LABELS,
    RECEIPT_SCHEMA as RECEIPT_SCHEMA,
    REPO_RE as REPO_RE,
    SCHEMA as SCHEMA,
    BatchError as BatchError,
    BodyPreparation as BodyPreparation,
    exact_keys as exact_keys,
    load_json as load_json,
    load_recovery as load_recovery,
    now_iso as now_iso,
    operation_intent_sha as operation_intent_sha,
    private_input as private_input,
    private_root as private_root,
    substantive as substantive,
    unsigned_body as unsigned_body,
    validate_labels as validate_labels,
    validate_operation_identity as validate_operation_identity,
    validate_recovery_operation as validate_recovery_operation,
    write_private_json as write_private_json,
)
from gh_write_batch_preparation import (
    copy_body as copy_body,
    load_manifest as load_manifest,
    normalize_operation as normalize_operation,
    prepare as prepare,
    signature_footer as signature_footer,
    validate_comment_shape as validate_comment_shape,
    validate_edit_shape as validate_edit_shape,
    validate_label_shape as validate_label_shape,
    validate_manifest as validate_manifest,
)


def graphql_call(query: str, variables: dict[str, Any], timeout: int) -> tuple[int, str, str, bool]:
    payload = json.dumps({"query": query, "variables": variables})
    gh_executable = shutil.which("gh")
    if not gh_executable:
        return 127, "", "gh executable is unavailable", False
    try:
        result = subprocess.run(  # nosec B603 - resolved managed PATH shim or gh executable
            [gh_executable, "api", "graphql", "--input", "-"],
            input=payload,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        return result.returncode, result.stdout, result.stderr, False
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout.decode() if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        stderr = exc.stderr.decode() if isinstance(exc.stderr, bytes) else (exc.stderr or "")
        return 124, stdout, stderr, True


def preflight_label_ids(prepared: dict[str, Any], repository: dict[str, Any]) -> dict[str, str]:
    label_ids: dict[str, str] = {}
    label_names = sorted({label for op in prepared["operations"] for label in op.get("labels", [])})
    for index, label in enumerate(label_names):
        node = repository.get(f"l{index}")
        if not isinstance(node, dict) or node.get("name") != label or not isinstance(node.get("id"), str):
            raise BatchError(f"unknown repository label {label}")
        label_ids[label] = node["id"]
    return label_ids


def preflight_target(
    repository: dict[str, Any], index: int, operation: dict[str, Any]
) -> dict[str, Any]:
    target = repository.get(f"t{index}")
    if not isinstance(target, dict) or target.get("__typename") != operation["target_type"]:
        raise BatchError(f"operation {operation['id']} target does not match {operation['target_type']}")
    if not isinstance(target.get("id"), str) or target.get("number") != operation["number"]:
        raise BatchError(f"operation {operation['id']} target identity is invalid")
    operation["target_id"] = target["id"]
    return target


def recovery_comment_already(
    prepared: dict[str, Any], operation: dict[str, Any], target: dict[str, Any]
) -> bool:
    comments = target.get("comments")
    if not isinstance(comments, dict):
        raise BatchError(f"operation {operation['id']} recovery comments are unavailable")
    marker = f"<!-- aidevops:batch:{prepared['recovery_of']}:{operation['id']} -->"
    bodies = [node.get("body") for node in comments.get("nodes", []) if isinstance(node, dict)]
    if any(isinstance(body, str) and marker in body.splitlines() for body in bodies):
        return True
    if comments.get("pageInfo", {}).get("hasPreviousPage") is not False:
        raise BatchError(f"operation {operation['id']} cannot prove the recovery marker absent")
    return False


def edit_already(operation: dict[str, Any], target: dict[str, Any]) -> bool:
    title_matches = "title" not in operation or target.get("title") == operation["title"]
    if "body_file" not in operation:
        return title_matches
    body = checked_body(operation)
    target_body = target.get("body")
    if operation["kind"] == "pr_edit" and isinstance(target_body, str):
        return title_matches and unsigned_body(target_body) == unsigned_body(body)
    return title_matches and target_body == body


def labels_already(operation: dict[str, Any], target: dict[str, Any]) -> bool:
    labels = target.get("labels")
    if not isinstance(labels, dict) or labels.get("pageInfo", {}).get("hasNextPage") is not False:
        raise BatchError(f"operation {operation['id']} cannot establish exact target labels")
    current = {node.get("name") for node in labels.get("nodes", []) if isinstance(node, dict)}
    requested = set(operation["labels"])
    if operation["kind"].endswith("add_labels"):
        return requested <= current
    return requested.isdisjoint(current)


def operation_already(
    prepared: dict[str, Any], operation: dict[str, Any], target: dict[str, Any]
) -> bool:
    kind = operation["kind"]
    if prepared.get("recovery_of") and kind.endswith("_comment"):
        return recovery_comment_already(prepared, operation, target)
    if kind.endswith("_edit"):
        return edit_already(operation, target)
    if kind.endswith("add_labels") or kind.endswith("remove_labels"):
        return labels_already(operation, target)
    return False


def validate_preflight(prepared: dict[str, Any], payload: dict[str, Any]) -> tuple[dict[str, str], set[str]]:
    if payload.get("errors"):
        raise BatchError("repository preflight returned GraphQL errors")
    repository = payload.get("data", {}).get("repository")
    if not isinstance(repository, dict):
        raise BatchError("repository preflight returned no repository")
    if repository.get("viewerPermission") not in {"ADMIN", "MAINTAIN", "WRITE"}:
        raise BatchError("batch publication requires repository write authority")
    label_ids = preflight_label_ids(prepared, repository)
    already: set[str] = set()
    for index, operation in enumerate(prepared["operations"]):
        target = preflight_target(repository, index, operation)
        if operation_already(prepared, operation, target):
            already.add(operation["id"])
    return label_ids, already


def checked_body(operation: dict[str, Any]) -> str:
    path = Path(operation["body_file"])
    body = path.read_text(encoding="utf-8")
    if hashlib.sha256(body.encode("utf-8")).hexdigest() != operation["body_sha256"]:
        raise BatchError(f"operation {operation['id']} prepared body changed before publication")
    return body


def base_receipt(prepared: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema": RECEIPT_SCHEMA,
        "manifest_sha256": prepared["manifest_sha256"],
        "marker_sha256": prepared.get("recovery_of") or prepared["manifest_sha256"],
        "repository": prepared["repository"],
        "created_at": now_iso(),
        "overall": "unknown",
        "operations": [
            {
                "id": op["id"],
                "kind": op["kind"],
                "number": op["number"],
                "intent_sha256": operation_intent_sha(op),
                "status": "unknown",
            }
            for op in prepared["operations"]
        ],
    }


def set_all(receipt: dict[str, Any], status: str, detail: str) -> None:
    for operation in receipt["operations"]:
        operation["status"] = status
        operation["detail"] = detail


def receipt_status(receipt: dict[str, Any]) -> str:
    statuses = {operation["status"] for operation in receipt["operations"]}
    if statuses <= {"succeeded", "already_succeeded"}:
        return "succeeded"
    if "unknown" in statuses:
        return "unknown"
    if "failed" in statuses or "rejected" in statuses:
        return "failed"
    return "deferred"


def emit_receipt(path: Path, receipt: dict[str, Any]) -> None:
    receipt["overall"] = receipt_status(receipt)
    write_private_json(path, receipt)


def run_preflight(
    prepared: dict[str, Any], receipt: dict[str, Any], receipt_path: Path, timeout: int
) -> tuple[int, dict[str, str], set[str]]:
    query, variables = preflight_query(prepared)
    rc, stdout, stderr, timed_out = graphql_call(query, variables, timeout)
    if rc != 0 or timed_out:
        status = "deferred" if rc == 75 else "rejected"
        set_all(receipt, status, "preflight_deferred" if rc == 75 else "preflight_failed")
        emit_receipt(receipt_path, receipt)
        print(stderr.strip(), file=sys.stderr)
        return rc or 1, {}, set()
    try:
        preflight = json.loads(stdout)
        label_ids, already = validate_preflight(prepared, preflight)
    except (json.JSONDecodeError, BatchError) as exc:
        set_all(receipt, "rejected", str(exc))
        emit_receipt(receipt_path, receipt)
        print(str(exc), file=sys.stderr)
        return 1, {}, set()
    return 0, label_ids, already


def set_attempted(
    attempted: list[dict[str, Any]], by_id: dict[str, dict[str, Any]], status: str, detail: str
) -> None:
    for operation in attempted:
        by_id[operation["id"]]["status"] = status
        by_id[operation["id"]]["detail"] = detail


def classify_alias(
    operation: dict[str, Any], data: dict[str, Any], errors: list[Any], receipt_operation: dict[str, Any]
) -> None:
    alias = operation["alias"]
    scoped_error = any(
        isinstance(error, dict)
        and error.get("path")
        and error.get("path", [None])[0] == alias
        for error in errors
    )
    alias_data = data.get(alias)
    if isinstance(alias_data, dict) and alias_data.get("clientMutationId") == operation["id"] and not scoped_error:
        receipt_operation["status"] = "succeeded"
        receipt_operation["detail"] = "durable_alias_result"
        node = alias_data.get("commentEdge", {}).get("node")
        if isinstance(node, dict):
            receipt_operation["remote_id"] = node.get("id")
            receipt_operation["url"] = node.get("url")
        return
    receipt_operation["status"] = "failed" if scoped_error else "unknown"
    receipt_operation["detail"] = (
        "graphql_alias_error" if scoped_error else "missing_alias_result_no_automatic_replay"
    )


def classify_mutation(
    rc: int,
    stdout: str,
    timed_out: bool,
    attempted: list[dict[str, Any]],
    by_id: dict[str, dict[str, Any]],
) -> None:
    if timed_out:
        set_attempted(attempted, by_id, "unknown", "mutation_timeout_no_automatic_replay")
        return
    if rc == 75:
        set_attempted(attempted, by_id, "deferred", "mutation_admission_deferred_before_backend_call")
        return
    try:
        result = json.loads(stdout)
    except json.JSONDecodeError:
        result = None
    if not isinstance(result, dict):
        set_attempted(attempted, by_id, "unknown", "mutation_result_not_json_no_automatic_replay")
        return
    data = result.get("data") if isinstance(result.get("data"), dict) else {}
    errors = result.get("errors") if isinstance(result.get("errors"), list) else []
    for operation in attempted:
        classify_alias(operation, data, errors, by_id[operation["id"]])


def batch_timeouts() -> tuple[int, int]:
    read_timeout = max(1, int(os.environ.get("AIDEVOPS_GH_BATCH_READ_TIMEOUT", "15")))
    default_write_timeout = max(
        1,
        int(os.environ.get("AIDEVOPS_GH_WRITE_TIMEOUT", "45")) - read_timeout - 5,
    )
    return read_timeout, max(
        1,
        int(os.environ.get("AIDEVOPS_GH_BATCH_WRITE_TIMEOUT", str(default_write_timeout))),
    )


def execute(args: argparse.Namespace) -> int:
    prepared = load_json(Path(args.prepared), "prepared manifest")
    if prepared.get("schema") != PREPARED_SCHEMA:
        raise BatchError("prepared manifest schema is invalid")
    receipt_path = Path(args.receipt)
    receipt = base_receipt(prepared)
    read_timeout, write_timeout = batch_timeouts()
    preflight_rc, label_ids, already = run_preflight(prepared, receipt, receipt_path, read_timeout)
    if preflight_rc != 0:
        return preflight_rc
    by_id = {operation["id"]: operation for operation in receipt["operations"]}
    for operation_id in already:
        by_id[operation_id]["status"] = "already_succeeded"
        by_id[operation_id]["detail"] = "fresh_state_already_matches"
    query, variables, attempted = mutation(prepared, label_ids, already, checked_body)
    if not attempted:
        emit_receipt(receipt_path, receipt)
        print(json.dumps(receipt, sort_keys=True))
        return 0
    rc, stdout, stderr, timed_out = graphql_call(query, variables, write_timeout)
    classify_mutation(rc, stdout, timed_out, attempted, by_id)
    emit_receipt(receipt_path, receipt)
    print(json.dumps(receipt, sort_keys=True))
    if stderr.strip():
        print(stderr.strip(), file=sys.stderr)
    return 0 if receipt["overall"] == "succeeded" else 1


def reject(args: argparse.Namespace) -> int:
    prepared = load_json(Path(args.prepared), "prepared manifest")
    receipt = base_receipt(prepared)
    set_all(receipt, "rejected", args.reason)
    receipt["overall"] = "failed"
    write_private_json(Path(args.receipt), receipt)
    return 1


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    subparsers = result.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--manifest", required=True)
    prepare_parser.add_argument("--temp-root", required=True)
    prepare_parser.add_argument("--signature-helper", required=True)
    prepare_parser.add_argument("--output", required=True)
    prepare_parser.set_defaults(function=prepare)
    execute_parser = subparsers.add_parser("execute")
    execute_parser.add_argument("--prepared", required=True)
    execute_parser.add_argument("--receipt", required=True)
    execute_parser.set_defaults(function=execute)
    reject_parser = subparsers.add_parser("reject")
    reject_parser.add_argument("--prepared", required=True)
    reject_parser.add_argument("--receipt", required=True)
    reject_parser.add_argument("--reason", required=True)
    reject_parser.set_defaults(function=reject)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        return args.function(args)
    except (BatchError, OSError, UnicodeError, ValueError) as exc:
        print(f"gh-write-batch: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
