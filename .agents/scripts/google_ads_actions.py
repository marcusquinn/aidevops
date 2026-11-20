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
import re
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
MATCH_TYPES = {"EXACT", "PHRASE", "BROAD"}
KEYWORD_STATUSES = {"ENABLED", "PAUSED"}
REVERSIBLE_BIDDING = {"MANUAL_CPC", "TARGET_SPEND"}
NUMERIC = re.compile(r"^[0-9]{1,20}$")
LIMIT_FIELDS = ("max_daily_budget_micros", "max_cpc_bid_ceiling_micros", "max_operations")
NEGATIVE_LEVELS = {"campaign_negative_keyword": "campaign", "ad_group_negative_keyword": "ad_group"}


class GoogleAdsActionError(ValueError):
    """Raised when a Google Ads action cannot safely proceed (sanitized, credential-free)."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise GoogleAdsActionError(message)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _stamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _numeric(value: Any, field: str) -> str:
    valid = isinstance(value, (str, int)) and not isinstance(value, bool)
    text = str(value).replace("-", "") if valid else ""
    _require(bool(NUMERIC.fullmatch(text)), f"{field} must be a numeric ID")
    return text


def _micros(value: Any, field: str, cap: int) -> str:
    valid = isinstance(value, (int, str)) and not isinstance(value, bool) and str(value).isdigit()
    _require(valid and int(value) > 0, f"{field} must be a positive integer of micros")
    _require(int(value) <= cap, f"{field} exceeds the configured cap")
    return str(int(value))


def _dig(row: Any, *path: str) -> Any:
    for key in path:
        row = row.get(key) if isinstance(row, dict) else None
    return row


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


# ── Kind registry ────────────────────────────────────────────────────────────
# Each kind: params validator, probe -> (comparable state, resource name), and a
# planner -> (after, forward, inverse, summary). States contain only the fields
# the action changes, so drift checks compare exactly what is mutated.


def _negative_params(raw: dict[str, Any], limits: dict[str, Any], kind: str) -> dict[str, Any]:
    parent = f"{NEGATIVE_LEVELS[kind]}_id"
    text = raw.get("text")
    _require(isinstance(text, str) and text.strip() == text and 0 < len(text) <= 80,
             "negative keyword text must be 1-80 trimmed characters")
    _require(raw.get("match_type") in MATCH_TYPES, "match_type must be EXACT, PHRASE or BROAD")
    return {parent: _numeric(raw.get(parent), parent), "text": text, "match_type": raw["match_type"]}


def _status_params(raw: dict[str, Any], limits: dict[str, Any], kind: str) -> dict[str, Any]:
    _require(raw.get("status") in KEYWORD_STATUSES, "keyword status must be ENABLED or PAUSED")
    return {"ad_group_id": _numeric(raw.get("ad_group_id"), "ad_group_id"),
            "criterion_id": _numeric(raw.get("criterion_id"), "criterion_id"), "status": raw["status"]}


def _bidding_params(raw: dict[str, Any], limits: dict[str, Any], kind: str) -> dict[str, Any]:
    return {"campaign_id": _numeric(raw.get("campaign_id"), "campaign_id"),
            "cpc_bid_ceiling_micros": _micros(raw.get("cpc_bid_ceiling_micros"), "cpc_bid_ceiling_micros",
                                              limits["max_cpc_bid_ceiling_micros"])}


def _budget_params(raw: dict[str, Any], limits: dict[str, Any], kind: str) -> dict[str, Any]:
    return {"campaign_id": _numeric(raw.get("campaign_id"), "campaign_id"),
            "amount_micros": _micros(raw.get("amount_micros"), "amount_micros", limits["max_daily_budget_micros"])}


def _negative_probe(client: Any, customer: str, params: dict[str, Any], kind: str) -> tuple[dict[str, Any], str]:
    level = NEGATIVE_LEVELS[kind]
    resource = f"{level}_criterion"
    query = (f"SELECT {resource}.resource_name, {resource}.keyword.text, {resource}.keyword.match_type "
             f"FROM {resource} WHERE {level}.id = {params[level + '_id']} AND {resource}.negative = TRUE "
             f"AND {resource}.type = KEYWORD")  # nosec B608 -- fixed identifiers and numeric IDs only
    key = "campaignCriterion" if level == "campaign" else "adGroupCriterion"
    for row in client.search(customer, query):
        keyword = _dig(row, key, "keyword") or {}
        if (str(keyword.get("text", "")).casefold() == params["text"].casefold()
                and keyword.get("matchType") == params["match_type"]):
            return {"present": True}, str(_dig(row, key, "resourceName") or "")
    return {"present": False}, ""


def _keyword_probe(client: Any, customer: str, params: dict[str, Any], kind: str) -> tuple[dict[str, Any], str]:
    name = f"customers/{customer}/adGroupCriteria/{params['ad_group_id']}~{params['criterion_id']}"
    query = ("SELECT ad_group_criterion.resource_name, ad_group_criterion.status, ad_group_criterion.negative "
             f"FROM ad_group_criterion WHERE ad_group_criterion.resource_name = '{name}'")  # nosec B608 -- numeric
    rows = client.search(customer, query)
    _require(len(rows) == 1, f"keyword {name} was not found")
    _require(not _dig(rows[0], "adGroupCriterion", "negative"), "status changes apply only to positive keywords")
    return {"status": _dig(rows[0], "adGroupCriterion", "status")}, name


def _campaign_row(client: Any, customer: str, campaign_id: str) -> dict[str, Any]:
    query = ("SELECT campaign.resource_name, campaign.bidding_strategy_type, campaign.bidding_strategy, "
             "campaign.manual_cpc.enhanced_cpc_enabled, campaign.target_spend.cpc_bid_ceiling_micros, "
             "campaign_budget.resource_name, campaign_budget.amount_micros, campaign_budget.explicitly_shared "
             f"FROM campaign WHERE campaign.id = {campaign_id}")  # nosec B608 -- numeric ID only
    rows = client.search(customer, query)
    _require(len(rows) == 1, f"campaign {campaign_id} was not found")
    return rows[0]


def _bidding_probe(client: Any, customer: str, params: dict[str, Any], kind: str) -> tuple[dict[str, Any], str]:
    row = _campaign_row(client, customer, params["campaign_id"])
    strategy = _dig(row, "campaign", "biddingStrategyType")
    state: dict[str, Any] = {"bidding_strategy_type": strategy,
                             "portfolio": bool(_dig(row, "campaign", "biddingStrategy"))}
    if strategy == "MANUAL_CPC":
        state["enhanced_cpc_enabled"] = bool(_dig(row, "campaign", "manualCpc", "enhancedCpcEnabled"))
    elif strategy == "TARGET_SPEND":
        ceiling = _dig(row, "campaign", "targetSpend", "cpcBidCeilingMicros")
        state["cpc_bid_ceiling_micros"] = str(int(ceiling)) if ceiling else None
    return state, str(_dig(row, "campaign", "resourceName") or "")


def _budget_probe(client: Any, customer: str, params: dict[str, Any], kind: str) -> tuple[dict[str, Any], str]:
    row = _campaign_row(client, customer, params["campaign_id"])
    _require(not _dig(row, "campaignBudget", "explicitlyShared"), "shared campaign budgets are not supported")
    amount = _dig(row, "campaignBudget", "amountMicros")
    _require(amount is not None, "campaign budget amount is unavailable")
    return {"amount_micros": str(int(amount))}, str(_dig(row, "campaignBudget", "resourceName") or "")


def _status_operation(name: str, status: str) -> dict[str, Any]:
    return {"adGroupCriterionOperation": {"update": {"resourceName": name, "status": status}, "updateMask": "status"}}


def _bidding_operation(name: str, state: dict[str, Any]) -> dict[str, Any]:
    if state["bidding_strategy_type"] == "MANUAL_CPC":
        update = {"resourceName": name, "manualCpc": {"enhancedCpcEnabled": state["enhanced_cpc_enabled"]}}
        return {"campaignOperation": {"update": update, "updateMask": "manual_cpc.enhanced_cpc_enabled"}}
    ceiling = state.get("cpc_bid_ceiling_micros")
    update = {"resourceName": name, "targetSpend": {"cpcBidCeilingMicros": ceiling} if ceiling else {}}
    return {"campaignOperation": {"update": update, "updateMask": "target_spend.cpc_bid_ceiling_micros"}}


def _budget_operation(name: str, amount: str) -> dict[str, Any]:
    return {"campaignBudgetOperation": {"update": {"resourceName": name, "amountMicros": amount},
                                        "updateMask": "amount_micros"}}


def _plan_negative(customer: str, params: dict[str, Any], before: dict[str, Any], name: str, kind: str) -> tuple:
    _require(not before["present"], "an identical negative keyword already exists")
    level = NEGATIVE_LEVELS[kind]
    parent_field = "campaign" if level == "campaign" else "adGroup"
    parent_path = "campaigns" if level == "campaign" else "adGroups"
    create = {parent_field: f"customers/{customer}/{parent_path}/{params[level + '_id']}", "negative": True,
              "keyword": {"text": params["text"], "matchType": params["match_type"]}}
    operation = "campaignCriterionOperation" if level == "campaign" else "adGroupCriterionOperation"
    summary = f"add {params['match_type']} negative \"{params['text']}\" to {level} {params[level + '_id']}"
    return {"present": True}, {operation: {"create": create}}, None, summary


def _plan_status(customer: str, params: dict[str, Any], before: dict[str, Any], name: str, kind: str) -> tuple:
    _require(before["status"] in KEYWORD_STATUSES, f"keyword status {before['status']} is not reversible")
    summary = f"keyword {name}: {before['status']} -> {params['status']}"
    return ({"status": params["status"]}, _status_operation(name, params["status"]),
            _status_operation(name, before["status"]), summary)


def _plan_bidding(customer: str, params: dict[str, Any], before: dict[str, Any], name: str, kind: str) -> tuple:
    _require(before["bidding_strategy_type"] in REVERSIBLE_BIDDING and not before["portfolio"],
             "only standard MANUAL_CPC or TARGET_SPEND campaigns have a recorded inverse")
    after = {"bidding_strategy_type": "TARGET_SPEND", "portfolio": False,
             "cpc_bid_ceiling_micros": params["cpc_bid_ceiling_micros"]}
    summary = (f"campaign {params['campaign_id']}: {before['bidding_strategy_type']} -> Maximize Clicks "
               f"with CPC ceiling {params['cpc_bid_ceiling_micros']} micros")
    return after, _bidding_operation(name, after), _bidding_operation(name, before), summary


def _plan_budget(customer: str, params: dict[str, Any], before: dict[str, Any], name: str, kind: str) -> tuple:
    summary = f"campaign {params['campaign_id']} budget: {before['amount_micros']} -> {params['amount_micros']} micros"
    return ({"amount_micros": params["amount_micros"]}, _budget_operation(name, params["amount_micros"]),
            _budget_operation(name, before["amount_micros"]), summary)


KINDS: dict[str, tuple[Callable[..., Any], Callable[..., Any], Callable[..., Any]]] = {
    "campaign_negative_keyword": (_negative_params, _negative_probe, _plan_negative),
    "ad_group_negative_keyword": (_negative_params, _negative_probe, _plan_negative),
    "keyword_status": (_status_params, _keyword_probe, _plan_status),
    "maximize_clicks": (_bidding_params, _bidding_probe, _plan_bidding),
    "campaign_budget": (_budget_params, _budget_probe, _plan_budget),
}


def validate_params(kind: Any, raw: dict[str, Any], limits: dict[str, Any]) -> dict[str, Any]:
    _require(kind in KINDS, f"unsupported Google Ads action kind: {kind}")
    return KINDS[kind][0](raw, limits, kind)


def probe(client: Any, customer: str, kind: str, params: dict[str, Any]) -> tuple[dict[str, Any], str]:
    return KINDS[kind][1](client, customer, params, kind)


def _plan_action(client: Any, customer: str, action_id: str, kind: str, params: dict[str, Any]) -> dict[str, Any]:
    """Read live before-state and derive the exact forward operation, after-state and inverse."""
    before, name = probe(client, customer, kind, params)
    try:
        after, forward, inverse, summary = KINDS[kind][2](customer, params, before, name, kind)
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
    _require(plan.get("action_set") == [item.get("id") for item in actions], "plan action set is inconsistent")
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


def _still_approved(approval: dict[str, Any]) -> None:
    try:
        approval_records.verify_cancellation(approval)
    except approval_records.ApprovalError as error:
        raise GoogleAdsActionError(str(error)) from error


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


def _audit(directory: Path, event: str, receipt: dict[str, Any]) -> None:
    line = {"at": _stamp(_now()), "event": event, "status": receipt["status"], "plan_digest": receipt["plan_digest"],
            "customer_id": receipt["customer_id"], "action_set": receipt["action_set"],
            "approval_nonce": receipt["approval_nonce"]}
    handle = os.open(str(directory / "audit.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    try:
        os.write(handle, action_io.canonical_json(line) + b"\n")
    finally:
        os.close(handle)


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
    _audit(directory, "apply", receipt)
    return receipt


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
        receipt = _load_receipt(path, plan["plan_digest"]) if path.exists() else _new_receipt(plan, approval)
        _require(receipt["status"] != "rolled_back", "plan was rolled back; build a new plan to re-apply")
        if receipt["status"] == "applied":
            _require(live == after, "applied-plan replay found drifted state")
            return receipt, True
        if path.exists() and live == after:  # crash after a committed mutate: recover names from live state
            return _finish(directory, path, receipt, plan, [name for _, name in states]), False
        _require(live == before, "live account state drifted since planning")
        receipt["approval_nonce"] = approval["nonce"]
        _write_receipt(path, receipt)
        _still_approved(approval)
        responses = client.mutate(plan["customer_id"], plan["operations"], validate_only=False)
        return _finish(directory, path, receipt, plan, _result_names(responses, len(plan["actions"]))), False


def rollback_receipt(receipt_path: str | Path, client: Any) -> tuple[dict[str, Any], bool]:
    """Revert an applied receipt when every live state still equals its recorded after-state."""
    lexical = Path(receipt_path).expanduser().absolute()
    _require(not lexical.is_symlink(), "receipt path cannot be a symlink")
    directory = action_io.private_directory(lexical.parent)
    path = lexical.resolve()
    receipt = _load_receipt(path)
    _require(receipt["status"] in {"applied", "rolled_back"}, "receipt is not rollback-ready")
    subject = {"plan_digest": receipt["plan_digest"], "owner": receipt["owner"],
               "customer_id": receipt["customer_id"], "action_set": receipt["action_set"]}
    approval = _approval(subject, "rollback", action_io.digest(receipt))
    if receipt["status"] == "rolled_back":
        return receipt, True
    customer, actions = receipt["customer_id"], receipt["actions"]
    with _receipt_lock(directory):
        for item, (state, name) in zip(actions, _live_states(client, customer, actions)):
            _require(state == item["after"] and name == item["resource_name"],
                     f"rollback refused: {item['id']} no longer matches its applied state")
        inverse = [item["inverse"] for item in reversed(actions)]
        client.mutate(customer, inverse, validate_only=True)
        _still_approved(approval)
        client.mutate(customer, inverse, validate_only=False)
        receipt["status"] = "rolled_back"
        receipt["rolled_back_at"] = _stamp(_now())
        _write_receipt(path, receipt)
        _audit(directory, "rollback", receipt)
    return receipt, False
