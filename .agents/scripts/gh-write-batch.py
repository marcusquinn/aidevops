#!/usr/bin/env python3
"""Prepare and execute bounded, safety-preserving GitHub write batches."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

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
    os.chmod(path.parent, 0o700)
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


def signature_footer(helper: Path) -> str:
    try:
        result = subprocess.run(
            [str(helper), "footer"], text=True, capture_output=True, timeout=10, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise BatchError(f"signature helper failed: {exc}") from exc
    if result.returncode != 0 or "<!-- aidevops:sig -->" not in result.stdout:
        raise BatchError("signature helper did not return a canonical footer")
    return result.stdout


def copy_body(
    source: Path,
    root: Path,
    kind: str,
    operation_id: str,
    marker_sha: str,
    helper: Path,
) -> tuple[str, str, str]:
    body = source.read_text(encoding="utf-8")
    source_digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
    if len(body.encode("utf-8")) > MAX_BODY_BYTES or not substantive(body):
        raise BatchError(f"operation {operation_id} body is empty or exceeds {MAX_BODY_BYTES} bytes")
    needs_signature = kind in {"issue_comment", "pr_comment", "pr_edit"}
    marker = f"<!-- aidevops:batch:{marker_sha}:{operation_id} -->"
    if kind in {"issue_comment", "pr_comment"} and marker not in body.splitlines():
        signature_at = body.find("<!-- aidevops:sig -->")
        if signature_at >= 0:
            body = f"{body[:signature_at].rstrip()}\n{marker}\n\n{body[signature_at:]}"
        else:
            body = f"{body.rstrip()}\n\n{marker}\n"
    if needs_signature and "<!-- aidevops:sig -->" not in body.splitlines():
        body = f"{body}{signature_footer(helper)}"
    fd, copied = tempfile.mkstemp(prefix="gh-write-batch-body.", dir=root)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(body)
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
    return copied, digest, source_digest


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


def prepare(args: argparse.Namespace) -> int:
    root = private_root(args.temp_root)
    manifest_path = private_input(args.manifest, root, "manifest")
    helper = Path(args.signature_helper).resolve(strict=True)
    manifest_bytes = manifest_path.read_bytes()
    manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
    manifest = load_json(manifest_path, "manifest")
    exact_keys(manifest, {"schema", "repository", "operations", "recovery_of"}, "manifest")
    if manifest.get("schema") != SCHEMA:
        raise BatchError(f"manifest schema must be {SCHEMA}")
    repository = manifest.get("repository")
    if not isinstance(repository, str) or not REPO_RE.fullmatch(repository):
        raise BatchError("manifest repository must be an exact owner/name slug")
    recovery_of = manifest.get("recovery_of")
    recovery_operations: dict[str, dict[str, Any]] = {}
    marker_sha = manifest_sha
    if recovery_of is not None:
        if not isinstance(recovery_of, dict):
            raise BatchError("recovery_of must identify an owner-only receipt")
        exact_keys(recovery_of, {"manifest_sha256", "receipt_file"}, "recovery_of")
        recovery_sha = recovery_of.get("manifest_sha256")
        if not isinstance(recovery_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", recovery_sha):
            raise BatchError("recovery_of manifest_sha256 is invalid")
        receipt_path = private_input(recovery_of.get("receipt_file"), root, "recovery receipt")
        recovery_receipt = load_json(receipt_path, "recovery receipt")
        if (
            recovery_receipt.get("schema") != RECEIPT_SCHEMA
            or recovery_receipt.get("manifest_sha256") != recovery_sha
            or recovery_receipt.get("repository") != repository
        ):
            raise BatchError("recovery receipt does not match this repository and manifest")
        receipt_marker_sha = recovery_receipt.get("marker_sha256")
        if not isinstance(receipt_marker_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", receipt_marker_sha):
            raise BatchError("recovery receipt marker lineage is invalid")
        receipt_operations = recovery_receipt.get("operations")
        if not isinstance(receipt_operations, list):
            raise BatchError("recovery receipt operations are invalid")
        recovery_operations = {
            operation.get("id"): operation
            for operation in receipt_operations
            if isinstance(operation, dict) and isinstance(operation.get("id"), str)
        }
        marker_sha = receipt_marker_sha
    raw_operations = manifest.get("operations")
    if not isinstance(raw_operations, list) or not 1 <= len(raw_operations) <= MAX_OPERATIONS:
        raise BatchError(f"manifest must contain 1-{MAX_OPERATIONS} operations")

    operation_ids: set[str] = set()
    field_owners: set[tuple[str, int, str]] = set()
    operations: list[dict[str, Any]] = []
    copied_files: list[str] = []
    try:
        for index, raw in enumerate(raw_operations):
            if not isinstance(raw, dict):
                raise BatchError(f"operation {index} must be an object")
            exact_keys(raw, {"id", "kind", "number", "body_file", "title", "labels"}, f"operation {index}")
            operation_id = raw.get("id")
            kind = raw.get("kind")
            number = raw.get("number")
            if not isinstance(operation_id, str) or not ID_RE.fullmatch(operation_id):
                raise BatchError(f"operation {index} id is invalid")
            if operation_id in operation_ids:
                raise BatchError(f"duplicate operation id {operation_id}")
            operation_ids.add(operation_id)
            if kind not in KINDS:
                raise BatchError(f"operation {operation_id} kind is unsupported")
            if isinstance(number, bool) or not isinstance(number, int) or number < 1:
                raise BatchError(f"operation {operation_id} number must be a positive integer")
            target_type = "PullRequest" if kind.startswith("pr_") else "Issue"
            operation: dict[str, Any] = {
                "id": operation_id,
                "kind": kind,
                "number": number,
                "target_type": target_type,
            }
            if kind.endswith("_comment"):
                if "body_file" not in raw or "title" in raw or "labels" in raw:
                    raise BatchError(f"operation {operation_id} comment shape is invalid")
                field = "comment"
            elif kind.endswith("_edit"):
                if "labels" in raw or ("body_file" not in raw and "title" not in raw):
                    raise BatchError(f"operation {operation_id} edit shape is invalid")
                title = raw.get("title")
                if title is not None:
                    if (
                        not isinstance(title, str)
                        or not title.strip()
                        or len(title) > 256
                        or re.fullmatch(r"(?:t[0-9]+|GH#[0-9]+):\s*", title.strip())
                    ):
                        raise BatchError(f"operation {operation_id} title is invalid")
                    operation["title"] = title
                field = "scalar"
            else:
                if "labels" not in raw or "body_file" in raw or "title" in raw:
                    raise BatchError(f"operation {operation_id} label shape is invalid")
                operation["labels"] = validate_labels(raw["labels"], operation_id)
                field = "labels"
            owner_key = (target_type, number, field)
            if field != "comment" and owner_key in field_owners:
                raise BatchError(f"dependent operations repeat {field} on {target_type} #{number}")
            field_owners.add(owner_key)
            if "body_file" in raw:
                source = private_input(raw["body_file"], root, f"operation {operation_id} body")
                copied, body_sha, source_sha = copy_body(
                    source, root, kind, operation_id, marker_sha, helper
                )
                copied_files.append(copied)
                operation["body_file"] = copied
                operation["body_sha256"] = body_sha
                operation["source_sha256"] = source_sha
            if recovery_of is not None:
                previous = recovery_operations.get(operation_id)
                if not isinstance(previous, dict) or previous.get("status") != "unknown":
                    raise BatchError(f"operation {operation_id} is not unknown in the recovery receipt")
                if previous.get("kind") != kind or previous.get("number") != number:
                    raise BatchError(f"operation {operation_id} does not match its recovery receipt identity")
                if previous.get("intent_sha256") != operation_intent_sha(operation):
                    raise BatchError(f"operation {operation_id} payload does not match its recovery receipt")
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


def graphql_call(query: str, variables: dict[str, Any], timeout: int) -> tuple[int, str, str, bool]:
    payload = json.dumps({"query": query, "variables": variables})
    try:
        result = subprocess.run(
            ["gh", "api", "graphql", "--input", "-"],
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


def preflight_query(prepared: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    declarations = ["$owner:String!", "$name:String!"]
    fields: list[str] = ["viewerPermission"]
    variables: dict[str, Any] = {}
    owner, name = prepared["repository"].split("/", 1)
    variables.update(owner=owner, name=name)
    labels = sorted({label for op in prepared["operations"] for label in op.get("labels", [])})
    for index, operation in enumerate(prepared["operations"]):
        declarations.append(f"$number{index}:Int!")
        variables[f"number{index}"] = operation["number"]
        comments = ""
        if prepared.get("recovery_of") and operation["kind"].endswith("_comment"):
            comments = " comments(last:100){nodes{body} pageInfo{hasPreviousPage}}"
        fields.append(
            f't{index}:issueOrPullRequest(number:$number{index}){{__typename ... on Issue{{id number title body labels(first:100){{nodes{{id name}} pageInfo{{hasNextPage}}}}{comments}}} ... on PullRequest{{id number title body labels(first:100){{nodes{{id name}} pageInfo{{hasNextPage}}}}{comments}}}}}}}'
        )
    for index, label in enumerate(labels):
        declarations.append(f"$label{index}:String!")
        variables[f"label{index}"] = label
        fields.append(f'l{index}:label(name:$label{index}){{id name}}')
    query = f"query({','.join(declarations)}){{repository(owner:$owner,name:$name){{{' '.join(fields)}}}}}"
    return query, variables


def validate_preflight(prepared: dict[str, Any], payload: dict[str, Any]) -> tuple[dict[str, str], set[str]]:
    if payload.get("errors"):
        raise BatchError("repository preflight returned GraphQL errors")
    repository = payload.get("data", {}).get("repository")
    if not isinstance(repository, dict):
        raise BatchError("repository preflight returned no repository")
    if repository.get("viewerPermission") not in {"ADMIN", "MAINTAIN", "WRITE"}:
        raise BatchError("batch publication requires repository write authority")
    label_ids: dict[str, str] = {}
    label_names = sorted({label for op in prepared["operations"] for label in op.get("labels", [])})
    for index, label in enumerate(label_names):
        node = repository.get(f"l{index}")
        if not isinstance(node, dict) or node.get("name") != label or not isinstance(node.get("id"), str):
            raise BatchError(f"unknown repository label {label}")
        label_ids[label] = node["id"]
    already: set[str] = set()
    for index, operation in enumerate(prepared["operations"]):
        target = repository.get(f"t{index}")
        if not isinstance(target, dict) or target.get("__typename") != operation["target_type"]:
            raise BatchError(f"operation {operation['id']} target does not match {operation['target_type']}")
        if not isinstance(target.get("id"), str) or target.get("number") != operation["number"]:
            raise BatchError(f"operation {operation['id']} target identity is invalid")
        operation["target_id"] = target["id"]
        kind = operation["kind"]
        if prepared.get("recovery_of") and kind.endswith("_comment"):
            comments = target.get("comments")
            if not isinstance(comments, dict):
                raise BatchError(f"operation {operation['id']} recovery comments are unavailable")
            marker = f"<!-- aidevops:batch:{prepared['recovery_of']}:{operation['id']} -->"
            bodies = [node.get("body") for node in comments.get("nodes", []) if isinstance(node, dict)]
            if any(isinstance(body, str) and marker in body.splitlines() for body in bodies):
                already.add(operation["id"])
            elif comments.get("pageInfo", {}).get("hasPreviousPage") is not False:
                raise BatchError(f"operation {operation['id']} cannot prove the recovery marker absent")
        elif kind.endswith("_edit"):
            unchanged = True
            if "title" in operation:
                unchanged = unchanged and target.get("title") == operation["title"]
            if "body_file" in operation:
                body = checked_body(operation)
                target_body = target.get("body")
                if kind == "pr_edit" and isinstance(target_body, str):
                    unchanged = unchanged and unsigned_body(target_body) == unsigned_body(body)
                else:
                    unchanged = unchanged and target_body == body
            if unchanged:
                already.add(operation["id"])
        elif kind.endswith("add_labels") or kind.endswith("remove_labels"):
            labels = target.get("labels")
            if not isinstance(labels, dict) or labels.get("pageInfo", {}).get("hasNextPage") is not False:
                raise BatchError(f"operation {operation['id']} cannot establish exact target labels")
            current = {node.get("name") for node in labels.get("nodes", []) if isinstance(node, dict)}
            requested = set(operation["labels"])
            if (kind.endswith("add_labels") and requested <= current) or (
                kind.endswith("remove_labels") and requested.isdisjoint(current)
            ):
                already.add(operation["id"])
    return label_ids, already


def checked_body(operation: dict[str, Any]) -> str:
    path = Path(operation["body_file"])
    body = path.read_text(encoding="utf-8")
    if hashlib.sha256(body.encode("utf-8")).hexdigest() != operation["body_sha256"]:
        raise BatchError(f"operation {operation['id']} prepared body changed before publication")
    return body


def mutation(prepared: dict[str, Any], label_ids: dict[str, str], already: set[str]) -> tuple[str, dict[str, Any], list[dict[str, Any]]]:
    declarations: list[str] = []
    fields: list[str] = []
    variables: dict[str, Any] = {}
    attempted: list[dict[str, Any]] = []
    for index, operation in enumerate(prepared["operations"]):
        if operation["id"] in already:
            continue
        alias = f"o{index}"
        operation["alias"] = alias
        attempted.append(operation)
        declarations.extend((f"$target{index}:ID!", f"$client{index}:String!"))
        variables[f"target{index}"] = operation["target_id"]
        variables[f"client{index}"] = operation["id"]
        kind = operation["kind"]
        if kind.endswith("_comment"):
            declarations.append(f"$body{index}:String!")
            variables[f"body{index}"] = checked_body(operation)
            fields.append(f'{alias}:addComment(input:{{subjectId:$target{index},body:$body{index},clientMutationId:$client{index}}}){{clientMutationId commentEdge{{node{{id url}}}}}}')
        elif kind.endswith("_edit"):
            mutation_name = "updatePullRequest" if kind == "pr_edit" else "updateIssue"
            inputs = [f"id:$target{index}", f"clientMutationId:$client{index}"]
            if "title" in operation:
                declarations.append(f"$title{index}:String!")
                variables[f"title{index}"] = operation["title"]
                inputs.append(f"title:$title{index}")
            if "body_file" in operation:
                declarations.append(f"$body{index}:String!")
                variables[f"body{index}"] = checked_body(operation)
                inputs.append(f"body:$body{index}")
            result_name = "pullRequest" if kind == "pr_edit" else "issue"
            fields.append(f'{alias}:{mutation_name}(input:{{{",".join(inputs)}}}){{clientMutationId {result_name}{{id number}}}}')
        else:
            declarations.append(f"$labels{index}:[ID!]!")
            variables[f"labels{index}"] = [label_ids[label] for label in operation["labels"]]
            mutation_name = "addLabelsToLabelable" if kind.endswith("add_labels") else "removeLabelsFromLabelable"
            fields.append(f'{alias}:{mutation_name}(input:{{labelableId:$target{index},labelIds:$labels{index},clientMutationId:$client{index}}}){{clientMutationId}}')
    if not attempted:
        return "", {}, []
    return f"mutation({','.join(declarations)}){{{' '.join(fields)}}}", variables, attempted


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


def execute(args: argparse.Namespace) -> int:
    prepared_path = Path(args.prepared)
    prepared = load_json(prepared_path, "prepared manifest")
    if prepared.get("schema") != PREPARED_SCHEMA:
        raise BatchError("prepared manifest schema is invalid")
    receipt = base_receipt(prepared)
    read_timeout = max(1, int(os.environ.get("AIDEVOPS_GH_BATCH_READ_TIMEOUT", "15")))
    default_write_timeout = max(
        1,
        int(os.environ.get("AIDEVOPS_GH_WRITE_TIMEOUT", "45")) - read_timeout - 5,
    )
    write_timeout = max(
        1,
        int(os.environ.get("AIDEVOPS_GH_BATCH_WRITE_TIMEOUT", str(default_write_timeout))),
    )
    query, variables = preflight_query(prepared)
    rc, stdout, stderr, timed_out = graphql_call(query, variables, read_timeout)
    if rc != 0 or timed_out:
        status = "deferred" if rc == 75 else "rejected"
        set_all(receipt, status, "preflight_deferred" if rc == 75 else "preflight_failed")
        receipt["overall"] = receipt_status(receipt)
        write_private_json(Path(args.receipt), receipt)
        print(stderr.strip(), file=sys.stderr)
        return rc or 1
    try:
        preflight = json.loads(stdout)
        label_ids, already = validate_preflight(prepared, preflight)
    except (json.JSONDecodeError, BatchError) as exc:
        set_all(receipt, "rejected", str(exc))
        receipt["overall"] = "failed"
        write_private_json(Path(args.receipt), receipt)
        print(str(exc), file=sys.stderr)
        return 1
    by_id = {operation["id"]: operation for operation in receipt["operations"]}
    for operation_id in already:
        by_id[operation_id]["status"] = "already_succeeded"
        by_id[operation_id]["detail"] = "fresh_state_already_matches"
    query, variables, attempted = mutation(prepared, label_ids, already)
    if not attempted:
        receipt["overall"] = "succeeded"
        write_private_json(Path(args.receipt), receipt)
        print(json.dumps(receipt, sort_keys=True))
        return 0
    rc, stdout, stderr, timed_out = graphql_call(query, variables, write_timeout)
    if timed_out:
        for operation in attempted:
            by_id[operation["id"]]["status"] = "unknown"
            by_id[operation["id"]]["detail"] = "mutation_timeout_no_automatic_replay"
    elif rc == 75:
        for operation in attempted:
            by_id[operation["id"]]["status"] = "deferred"
            by_id[operation["id"]]["detail"] = "mutation_admission_deferred_before_backend_call"
    else:
        try:
            result = json.loads(stdout)
        except json.JSONDecodeError:
            result = None
        if not isinstance(result, dict):
            for operation in attempted:
                by_id[operation["id"]]["status"] = "unknown"
                by_id[operation["id"]]["detail"] = "mutation_result_not_json_no_automatic_replay"
        else:
            data = result.get("data") if isinstance(result.get("data"), dict) else {}
            errors = result.get("errors") if isinstance(result.get("errors"), list) else []
            for operation in attempted:
                alias = operation["alias"]
                scoped_error = any(
                    isinstance(error, dict)
                    and error.get("path")
                    and error.get("path", [None])[0] == alias
                    for error in errors
                )
                alias_data = data.get(alias)
                if isinstance(alias_data, dict) and alias_data.get("clientMutationId") == operation["id"] and not scoped_error:
                    by_id[operation["id"]]["status"] = "succeeded"
                    by_id[operation["id"]]["detail"] = "durable_alias_result"
                    node = alias_data.get("commentEdge", {}).get("node")
                    if isinstance(node, dict):
                        by_id[operation["id"]]["remote_id"] = node.get("id")
                        by_id[operation["id"]]["url"] = node.get("url")
                elif scoped_error:
                    by_id[operation["id"]]["status"] = "failed"
                    by_id[operation["id"]]["detail"] = "graphql_alias_error"
                else:
                    by_id[operation["id"]]["status"] = "unknown"
                    by_id[operation["id"]]["detail"] = "missing_alias_result_no_automatic_replay"
    receipt["overall"] = receipt_status(receipt)
    write_private_json(Path(args.receipt), receipt)
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
