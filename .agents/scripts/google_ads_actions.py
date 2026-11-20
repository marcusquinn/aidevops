#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Approval-bound Google Ads account actions: validate-only plan, guarded apply, rollback.

Supported kinds are deliberately few and each has an exact recorded inverse:
campaign/ad-group negative keyword add, keyword pause/enable, Maximize Clicks
with a CPC ceiling, and a non-shared campaign budget amount. `apply` and
`rollback` require a root-owned operator record from
`sudo aidevops approve marketing-plan` (see marketing_action_approval.py).
"""

from __future__ import annotations

import fcntl
import getpass
import json
import os
import stat
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import marketing_action_approval as approval_records
import marketing_action_io as action_io
from google_ads_action_kinds import (
    NEGATIVE_LEVELS, GoogleAdsActionError, _numeric, _require, plan_kind, probe, rebuild_check, validate_params,
)
from marketing_account_google import GOOGLE_ADS_API_VERSION

INPUT_SCHEMA = "aidevops.google-ads-action-input/v1"
CONFIG_SCHEMA = "aidevops.google-ads-action-config/v1"
PLAN_SCHEMA = "aidevops.google-ads-action-plan/v1"
RECEIPT_SCHEMA = "aidevops.google-ads-action-receipt/v1"
API_PREFIX = f"https://googleads.googleapis.com/{GOOGLE_ADS_API_VERSION}/customers/"
PLAN_TTL = timedelta(hours=24)
MAX_PAGES = 20
MAX_RESPONSE_BYTES = 4_000_000
MAX_OPERATIONS = 500
LIMIT_FIELDS = ("max_daily_budget_micros", "max_cpc_bid_ceiling_micros", "max_operations")


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _stamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


# ── Transport ────────────────────────────────────────────────────────────────


class AdsClient:
    """Minimal REST transport: fixed endpoints, bounded responses, no credential echo."""

    def __init__(self, access_token: str, developer_token: str = "", login_customer_id: str = "",
                 opener: Callable[[Request], Any] | None = None) -> None:
        _require(bool(access_token), "GOOGLE_ADS_ACCESS_TOKEN is required for live Google Ads calls")
        self._headers = {"Authorization": f"Bearer {access_token}", "Content-Type": "application/json"}
        if developer_token:  # sunset 2026-09-09 and ignored by Google; sent only when configured
            self._headers["developer-token"] = developer_token
        if login_customer_id:
            self._headers["login-customer-id"] = _numeric(login_customer_id, "login_customer_id")
        self._open = opener or (lambda item: urlopen(item, timeout=60))  # nosec B310 -- fixed HTTPS prefix

    def _post(self, customer_id: str, method: str, body: dict[str, Any]) -> dict[str, Any]:
        url = f"{API_PREFIX}{_numeric(customer_id, 'customer_id')}/googleAds:{method}"
        request = Request(url, data=json.dumps(body).encode("utf-8"), headers=self._headers, method="POST")
        try:
            raw = self._open(request).read(MAX_RESPONSE_BYTES + 1)
        except HTTPError as error:
            raise GoogleAdsActionError(_http_error(error)) from None
        except OSError as error:
            raise GoogleAdsActionError("Google Ads request failed") from error
        _require(len(raw) <= MAX_RESPONSE_BYTES, "Google Ads response exceeded byte budget")
        try:
            decoded = json.loads(raw.decode("utf-8") or "{}")
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise GoogleAdsActionError("Google Ads response was not JSON") from error
        _require(isinstance(decoded, dict), "Google Ads response was invalid")
        return decoded

    def search(self, customer_id: str, query: str) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        body: dict[str, Any] = {"query": query}
        for _ in range(MAX_PAGES):
            page = self._post(customer_id, "search", body)
            rows.extend(item for item in page.get("results", []) if isinstance(item, dict))
            token = page.get("nextPageToken")
            if not token:
                return rows
            body = {"query": query, "pageToken": token}
        raise GoogleAdsActionError("Google Ads search exceeded the page budget")

    def mutate(self, customer_id: str, operations: list[dict[str, Any]], validate_only: bool) -> list[dict[str, Any]]:
        body = {"mutateOperations": operations, "partialFailure": False, "validateOnly": validate_only,
                "responseContentType": "RESOURCE_NAME_ONLY"}
        responses = self._post(customer_id, "mutate", body).get("mutateOperationResponses", [])
        _require(isinstance(responses, list), "Google Ads mutate response was invalid")
        return responses


def _http_error(error: HTTPError) -> str:
    try:
        detail = json.loads(error.read(65_536).decode("utf-8"))
        message = str(detail.get("error", {}).get("message", ""))[:300]
    except (OSError, ValueError, AttributeError):
        message = ""
    return f"Google Ads API returned HTTP {error.code}" + (f": {message}" if message else "")


def client_from_environment(login_customer_id: str = "") -> AdsClient:
    return AdsClient(os.environ.get("GOOGLE_ADS_ACCESS_TOKEN", ""),
                     os.environ.get("GOOGLE_ADS_DEVELOPER_TOKEN", ""), login_customer_id)


def _plan_action(client: Any, customer: str, action_id: str, kind: str, params: dict[str, Any]) -> dict[str, Any]:
    """Read live before-state and derive the exact forward operation, after-state and inverse."""
    before, name = probe(client, customer, kind, params)
    try:
        after, forward, inverse, summary = plan_kind(customer, kind, params, before, name)
    except GoogleAdsActionError as error:
        raise GoogleAdsActionError(f"action {action_id}: {error}") from error
    _require(before != after, f"action {action_id} would not change the account")
    return {"id": action_id, "kind": kind, "summary": summary, "params": params, "target": name,
            "before": before, "after": after, "forward": forward, "inverse": inverse}


# ── Plan ─────────────────────────────────────────────────────────────────────


def validate_config(value: Any) -> dict[str, Any]:
    _require(isinstance(value, dict) and value.get("schema") == CONFIG_SCHEMA, "unknown config schema version")
    _require(set(value) == {"schema", "customer_allowlist", *LIMIT_FIELDS}, "config fields are invalid")
    allowlist = value["customer_allowlist"]
    _require(isinstance(allowlist, list) and allowlist, "customer_allowlist must be a non-empty array")
    limits: dict[str, Any] = {"customer_allowlist": sorted({_numeric(item, "customer_allowlist[]") for item in allowlist})}
    for field in LIMIT_FIELDS:
        _require(isinstance(value[field], int) and not isinstance(value[field], bool) and value[field] > 0,
                 f"{field} must be a positive integer")
        limits[field] = value[field]
    _require(limits["max_operations"] <= MAX_OPERATIONS, f"max_operations cannot exceed {MAX_OPERATIONS}")
    return limits


def _validate_input(value: Any, limits: dict[str, Any]) -> tuple[str, str, list[str]]:
    fields = {"schema", "customer_id", "owner", "source_evidence", "actions"}
    _require(isinstance(value, dict) and value.get("schema") == INPUT_SCHEMA, "unknown input schema version")
    _require(fields <= set(value) <= fields | {"login_customer_id"}, "input fields are invalid")
    owner = getpass.getuser() if value["owner"] == "current" else value["owner"]
    _require(owner == getpass.getuser(), "input owner must be the current operator")
    customer = _numeric(value["customer_id"], "customer_id")
    _require(customer in limits["customer_allowlist"], "customer is not in the configured allowlist")
    evidence = value["source_evidence"]
    _require(isinstance(evidence, list) and evidence and all(isinstance(item, str) and item for item in evidence),
             "source_evidence must be a non-empty string array")
    actions = value["actions"]
    _require(isinstance(actions, list) and 0 < len(actions) <= limits["max_operations"],
             "action count exceeds the configured max_operations")
    return owner, customer, evidence


def build_plan(value: Any, config: Any, client: Any, now: datetime | None = None) -> dict[str, Any]:
    """Validate input against caps, read before-state, validate-only mutate, return a digest-bound plan."""
    limits = validate_config(config)
    owner, customer, evidence = _validate_input(value, limits)
    actions: list[dict[str, Any]] = []
    for index, raw in enumerate(value["actions"]):
        _require(isinstance(raw, dict) and isinstance(raw.get("id"), str) and raw["id"], f"actions[{index}] needs an id")
        _require(raw["id"] not in {item["id"] for item in actions}, "action IDs must be unique")
        params = validate_params(raw.get("kind"), raw, limits)
        actions.append(_plan_action(client, customer, raw["id"], raw["kind"], params))
    targets = [item["target"] for item in actions if item["target"]]
    _require(len(targets) == len(set(targets)), "one plan cannot change the same resource twice")
    operations = [item["forward"] for item in actions]
    client.mutate(customer, operations, validate_only=True)
    created = now or _now()
    login = value.get("login_customer_id")
    plan = {
        "schema": PLAN_SCHEMA, "customer_id": customer,
        "login_customer_id": _numeric(login, "login_customer_id") if login else "",
        "owner": owner, "source_evidence": evidence, "limits": limits,
        "action_set": [item["id"] for item in actions], "actions": actions, "operations": operations,
        "validation": {"validate_only": True, "operation_count": len(operations)},
        "created_at": _stamp(created), "expires_at": _stamp(created + PLAN_TTL),
        "rollback": "receipt-bound inverse operations after live after-state verification",
    }
    plan["plan_digest"] = action_io.digest(plan)
    return plan


def validate_plan(plan: Any, now: datetime | None = None) -> dict[str, Any]:
    _require(isinstance(plan, dict) and plan.get("schema") == PLAN_SCHEMA, "unknown plan schema version")
    unsigned = {key: item for key, item in plan.items() if key != "plan_digest"}
    _require(plan.get("plan_digest") == action_io.digest(unsigned), "plan digest is invalid")
    _require(plan.get("owner") == getpass.getuser(), "plan owner does not match the current operator")
    expires = approval_records._parse_time(plan.get("expires_at"), "plan.expires_at")
    _require((now or _now()) < expires, "plan has expired; re-run plan against the live account")
    limits = validate_config({"schema": CONFIG_SCHEMA, **plan.get("limits", {})})
    _require(plan.get("customer_id") in limits["customer_allowlist"], "customer is not in the plan allowlist")
    actions = plan.get("actions")
    _require(isinstance(actions, list) and 0 < len(actions) <= limits["max_operations"], "plan actions exceed bounds")
    for item in actions:
        _require(isinstance(item, dict) and validate_params(item.get("kind"), item.get("params", {}), limits)
                 == item.get("params"), "plan action parameters are invalid or exceed caps")
        rebuild_check(plan["customer_id"], item)
    _require(plan.get("action_set") == [item.get("id") for item in actions], "plan action set is inconsistent")
    targets = [item["target"] for item in actions if item["target"]]
    _require(len(targets) == len(set(targets)), "one plan cannot change the same resource twice")
    _require(plan.get("operations") == [item.get("forward") for item in actions], "plan operations are inconsistent")
    return plan


def write_plan(path: str | Path, plan: dict[str, Any]) -> Path:
    """Exclusive-create the plan file at mode 0600; never overwrite a reviewed plan."""
    target = Path(path).expanduser().absolute()
    handle = os.open(str(target), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.write(handle, json.dumps(plan, indent=2, sort_keys=True).encode("utf-8") + b"\n")
    finally:
        os.close(handle)
    return target


# ── Approval, receipts, locks, audit ─────────────────────────────────────────


def _approval(subject: dict[str, Any], operation: str, receipt_digest: str | None = None) -> dict[str, Any]:
    try:
        return approval_records.verify(subject, operation, PLAN_SCHEMA, receipt_digest)
    except approval_records.ApprovalError as error:
        raise GoogleAdsActionError(str(error)) from error


def _still_approved(approval: dict[str, Any], deadline: str | None = None) -> None:
    """Run immediately before every non-validate mutate: cancellation, approval expiry, plan deadline."""
    try:
        approval_records.verify_cancellation(approval)
        expires = approval_records._parse_time(approval["expires_at"], "approval.expires_at")
        plan_expires = approval_records._parse_time(deadline, "plan.expires_at") if deadline else None
    except approval_records.ApprovalError as error:
        raise GoogleAdsActionError(str(error)) from error
    _require(_now() < expires, "approval is stale; approve again")
    _require(plan_expires is None or _now() < plan_expires, "plan has expired; re-run plan against the live account")


@contextmanager
def _receipt_lock(directory: Path) -> Iterator[None]:
    with (directory / ".google-ads-actions.lock").open("a+", encoding="utf-8") as stream:
        try:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise GoogleAdsActionError("another Google Ads action operation owns this receipt directory") from error
        yield


def _write_receipt(path: Path, receipt: dict[str, Any]) -> None:
    action_io.atomic_write(path, action_io.canonical_json(receipt) + b"\n")


def _audit(directory: Path, path: Path, event: str, receipt: dict[str, Any]) -> None:
    """Append one audit event (at-least-once, keyed by event_id) and record it in the receipt.

    Callers persist the terminal receipt first; a replay finding the event missing from
    `audited` appends it then, so an audit failure never requires a second account write.
    """
    if event in receipt.get("audited", []):
        return
    line = {"at": _stamp(_now()), "event": event, "event_id": f"{event}:{receipt['plan_digest']}",
            "status": receipt["status"], "plan_digest": receipt["plan_digest"],
            "customer_id": receipt["customer_id"], "action_set": receipt["action_set"],
            "approval_nonce": receipt["approval_nonce"]}
    handle = os.open(str(directory / "audit.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    try:
        os.write(handle, action_io.canonical_json(line) + b"\n")
    finally:
        os.close(handle)
    receipt["audited"] = receipt.get("audited", []) + [event]
    _write_receipt(path, receipt)


def _load_receipt(path: Path, plan_digest: str | None = None) -> dict[str, Any]:
    _require(path.is_file() and not path.is_symlink(), "receipt path is unavailable")
    metadata = path.stat()
    _require(metadata.st_uid == os.getuid() and stat.S_IMODE(metadata.st_mode) == 0o600,
             "receipt is not private to the operator")
    receipt = action_io.load_json(path)
    _require(isinstance(receipt, dict) and receipt.get("schema") == RECEIPT_SCHEMA, "receipt schema is invalid")
    _require(receipt.get("owner") == getpass.getuser(), "receipt owner does not match the current operator")
    _require(path.name == f"{str(receipt.get('plan_digest', '')).removeprefix('sha256:')}.json",
             "receipt path does not match its plan")
    _require(plan_digest is None or receipt["plan_digest"] == plan_digest, "receipt plan digest does not match")
    return receipt


def _live_states(client: Any, customer: str, actions: list[dict[str, Any]]) -> list[tuple[dict[str, Any], str]]:
    return [probe(client, customer, item["kind"], item["params"]) for item in actions]


def _receipt_action(item: dict[str, Any], resource_name: str, customer: str) -> dict[str, Any]:
    _require(isinstance(resource_name, str) and resource_name.startswith(f"customers/{customer}/"),
             "Google Ads returned a foreign or missing resource name")
    inverse = item["inverse"]
    if inverse is None:  # created negatives revert by removing exactly the created criterion
        key = next(iter(item["forward"]))
        inverse = {key: {"remove": resource_name}}
    recorded = {key: item[key] for key in ("id", "kind", "summary", "params", "before", "after")}
    recorded.update(resource_name=resource_name, inverse=inverse)
    return recorded


def _result_names(responses: list[Any], count: int) -> list[str]:
    _require(len(responses) == count, "Google Ads mutate response count does not match the plan")
    names = []
    for response in responses:
        values = [value for value in response.values() if isinstance(value, dict)] if isinstance(response, dict) else []
        _require(len(values) == 1 and isinstance(values[0].get("resourceName"), str), "mutate result is invalid")
        names.append(values[0]["resourceName"])
    return names


def _finish(directory: Path, path: Path, receipt: dict[str, Any], plan: dict[str, Any], names: list[str]) -> dict:
    receipt["actions"] = [_receipt_action(item, name, plan["customer_id"]) for item, name in zip(plan["actions"], names)]
    receipt["status"] = "applied"
    receipt["completed_at"] = _stamp(_now())
    _write_receipt(path, receipt)
    _audit(directory, path, "apply", receipt)
    return receipt


def _require_targets(actions: list[dict[str, Any]], names: list[str], field: str) -> None:
    """Existing resources must be the exact resource the plan/receipt named, not merely equal in value."""
    for item, name in zip(actions, names):
        if item["kind"] not in NEGATIVE_LEVELS:
            _require(name == item[field], f"action {item['id']}: live resource {name} is not the planned {item[field]}")


def _new_receipt(plan: dict[str, Any], approval: dict[str, Any]) -> dict[str, Any]:
    return {"schema": RECEIPT_SCHEMA, "status": "applying", "plan_digest": plan["plan_digest"],
            "customer_id": plan["customer_id"], "login_customer_id": plan["login_customer_id"],
            "owner": plan["owner"], "approval_nonce": approval["nonce"], "action_set": plan["action_set"],
            "actions": [], "started_at": _stamp(_now())}


def apply_plan(plan: dict[str, Any], receipt_directory: str | Path, client: Any) -> tuple[dict[str, Any], bool]:
    """Apply one approved plan atomically, or replay/resume its receipt."""
    validate_plan(plan)
    approval = _approval(plan, "apply")
    directory = action_io.private_directory(receipt_directory)
    path = action_io.receipt_path(directory, plan["plan_digest"])
    before = [item["before"] for item in plan["actions"]]
    after = [item["after"] for item in plan["actions"]]
    with _receipt_lock(directory):
        states = _live_states(client, plan["customer_id"], plan["actions"])
        live = [state for state, _ in states]
        _require_targets(plan["actions"], [name for _, name in states], "target")
        receipt = _load_receipt(path, plan["plan_digest"]) if path.exists() else _new_receipt(plan, approval)
        _require(receipt["status"] not in {"rolling_back", "rolled_back"},
                 "plan was rolled back; build a new plan to re-apply")
        if receipt["status"] == "applied":
            _require(live == after, "applied-plan replay found drifted state")
            _audit(directory, path, "apply", receipt)  # repairs a missing audit entry; no account write
            return receipt, True
        if path.exists() and live == after:  # crash after a committed mutate: recover names from live state
            return _finish(directory, path, receipt, plan, [name for _, name in states]), False
        _require(live == before, "live account state drifted since planning")
        receipt["approval_nonce"] = approval["nonce"]
        _write_receipt(path, receipt)
        _still_approved(approval, plan["expires_at"])
        responses = client.mutate(plan["customer_id"], plan["operations"], validate_only=False)
        return _finish(directory, path, receipt, plan, _result_names(responses, len(plan["actions"]))), False


def rollback_receipt(receipt_path: str | Path, client: Any) -> tuple[dict[str, Any], bool]:
    """Revert an applied receipt when every live state still equals its recorded after-state.

    Rollback intent (`rolling_back`) is persisted before the remote write. A retry of a
    `rolling_back` receipt whose live state already equals every before-state (created
    negatives absent) is completed without another write; the inverse is sent only when
    every action is still exactly at its after-state.
    """
    lexical = Path(receipt_path).expanduser().absolute()
    _require(not lexical.is_symlink(), "receipt path cannot be a symlink")
    directory = action_io.private_directory(lexical.parent)
    path = lexical.resolve()
    receipt = _load_receipt(path)
    _require(receipt["status"] in {"applied", "rolling_back", "rolled_back"}, "receipt is not rollback-ready")
    subject = {"plan_digest": receipt["plan_digest"], "owner": receipt["owner"],
               "customer_id": receipt["customer_id"], "action_set": receipt["action_set"]}
    approval = _approval(subject, "rollback", action_io.digest(receipt))
    customer, actions = receipt["customer_id"], receipt["actions"]
    with _receipt_lock(directory):
        if receipt["status"] == "rolled_back":
            _audit(directory, path, "rollback", receipt)  # repairs a missing audit entry; no account write
            return receipt, True
        states = _live_states(client, customer, actions)
        live = [state for state, _ in states]
        names = [name for _, name in states]
        reverted = live == [item["before"] for item in actions]
        if not (receipt["status"] == "rolling_back" and reverted):
            for item, state, name in zip(actions, live, names):
                _require(state == item["after"] and name == item["resource_name"],
                         f"rollback refused: {item['id']} no longer matches its applied state")
            inverse = [item["inverse"] for item in reversed(actions)]
            client.mutate(customer, inverse, validate_only=True)
            receipt["status"] = "rolling_back"
            receipt["approval_nonce"] = approval["nonce"]
            _write_receipt(path, receipt)
            _still_approved(approval)
            client.mutate(customer, inverse, validate_only=False)
        else:
            _require_targets(actions, names, "resource_name")
        receipt["status"] = "rolled_back"
        receipt["rolled_back_at"] = _stamp(_now())
        _write_receipt(path, receipt)
        _audit(directory, path, "rollback", receipt)
    return receipt, False
