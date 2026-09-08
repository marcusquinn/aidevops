#!/usr/bin/env python3
"""Prepare and execute bounded, safety-preserving GitHub write batches."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
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


class MutationBuild(NamedTuple):
    """Mutable containers shared while compiling one GraphQL mutation."""

    label_ids: dict[str, str]
    declarations: list[str]
    variables: dict[str, Any]


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


def comment_mutation(
    index: int, alias: str, operation: dict[str, Any], build: MutationBuild
) -> str:
    build.declarations.append(f"$body{index}:String!")
    build.variables[f"body{index}"] = checked_body(operation)
    return f'{alias}:addComment(input:{{subjectId:$target{index},body:$body{index},clientMutationId:$client{index}}}){{clientMutationId commentEdge{{node{{id url}}}}}}'


def edit_mutation(
    index: int, alias: str, operation: dict[str, Any], build: MutationBuild
) -> str:
    mutation_name = "updatePullRequest" if operation["kind"] == "pr_edit" else "updateIssue"
    inputs = [f"id:$target{index}", f"clientMutationId:$client{index}"]
    for field in ("title", "body"):
        operation_key = "body_file" if field == "body" else field
        if operation_key not in operation:
            continue
        build.declarations.append(f"${field}{index}:String!")
        build.variables[f"{field}{index}"] = (
            checked_body(operation) if field == "body" else operation[operation_key]
        )
        inputs.append(f"{field}:${field}{index}")
    result_name = "pullRequest" if operation["kind"] == "pr_edit" else "issue"
    return f'{alias}:{mutation_name}(input:{{{",".join(inputs)}}}){{clientMutationId {result_name}{{id number}}}}'


def label_mutation(
    index: int, alias: str, operation: dict[str, Any], build: MutationBuild
) -> str:
    build.declarations.append(f"$labels{index}:[ID!]!")
    build.variables[f"labels{index}"] = [build.label_ids[label] for label in operation["labels"]]
    mutation_name = (
        "addLabelsToLabelable" if operation["kind"].endswith("add_labels") else "removeLabelsFromLabelable"
    )
    return f'{alias}:{mutation_name}(input:{{labelableId:$target{index},labelIds:$labels{index},clientMutationId:$client{index}}}){{clientMutationId}}'


def mutation_field(
    index: int, alias: str, operation: dict[str, Any], build: MutationBuild
) -> str:
    kind = operation["kind"]
    if kind.endswith("_comment"):
        return comment_mutation(index, alias, operation, build)
    if kind.endswith("_edit"):
        return edit_mutation(index, alias, operation, build)
    return label_mutation(index, alias, operation, build)


def mutation(
    prepared: dict[str, Any], label_ids: dict[str, str], already: set[str]
) -> tuple[str, dict[str, Any], list[dict[str, Any]]]:
    declarations: list[str] = []
    fields: list[str] = []
    variables: dict[str, Any] = {}
    build = MutationBuild(label_ids, declarations, variables)
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
        fields.append(mutation_field(index, alias, operation, build))
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
    query, variables, attempted = mutation(prepared, label_ids, already)
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
