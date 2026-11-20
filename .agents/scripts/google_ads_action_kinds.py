#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Kind registry for approval-bound Google Ads account actions.

Each kind has a params validator, a probe -> (comparable state, resource name), and
a pure planner -> (after, forward, inverse, summary). States contain only the fields
the action changes, so drift checks compare exactly what is mutated. Because the
planners are pure, `rebuild_check` can re-derive every executable field of a stored
plan from its validated params and recorded before-state.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from typing import Any

MATCH_TYPES = {"EXACT", "PHRASE", "BROAD"}
KEYWORD_STATUSES = {"ENABLED", "PAUSED"}
REVERSIBLE_BIDDING = {"MANUAL_CPC", "TARGET_SPEND"}
NUMERIC = re.compile(r"^[0-9]{1,20}$")
MICROS = re.compile(r"[0-9]{1,18}")  # ASCII only: str.isdigit() accepts superscripts int() rejects
NEGATIVE_LEVELS = {"campaign_negative_keyword": "campaign", "ad_group_negative_keyword": "ad_group"}


class GoogleAdsActionError(ValueError):
    """Raised when a Google Ads action cannot safely proceed (sanitized, credential-free)."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise GoogleAdsActionError(message)


def _numeric(value: Any, field: str) -> str:
    valid = isinstance(value, (str, int)) and not isinstance(value, bool)
    text = str(value).replace("-", "") if valid else ""
    _require(bool(NUMERIC.fullmatch(text)), f"{field} must be a numeric ID")
    return text


def _micros(value: Any, field: str, cap: int) -> str:
    valid = isinstance(value, (int, str)) and not isinstance(value, bool) and bool(MICROS.fullmatch(str(value)))
    _require(valid and int(value) > 0, f"{field} must be a positive integer of micros")
    _require(int(value) <= cap, f"{field} exceeds the configured cap")
    return str(int(value))


def _dig(row: Any, *path: str) -> Any:
    for key in path:
        row = row.get(key) if isinstance(row, dict) else None
    return row


# ── Params ───────────────────────────────────────────────────────────────────


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


# ── Probes (fixed GAQL, numeric IDs only) ────────────────────────────────────


def _negative_probe(client: Any, customer: str, params: dict[str, Any], kind: str) -> tuple[dict[str, Any], str]:
    level = NEGATIVE_LEVELS[kind]
    resource = f"{level}_criterion"
    query = (f"SELECT {resource}.resource_name, {resource}.keyword.text, {resource}.keyword.match_type "
             f"FROM {resource} WHERE {level}.id = {params[level + '_id']} AND {resource}.negative = TRUE "
             f"AND {resource}.type = KEYWORD AND {resource}.status != 'REMOVED'")  # nosec B608 -- fixed IDs only
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
             f"FROM ad_group_criterion WHERE ad_group_criterion.resource_name = '{name}' "
             "AND ad_group_criterion.type = KEYWORD")  # nosec B608 -- numeric IDs only
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


# ── Operations and pure planners ─────────────────────────────────────────────


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


def plan_kind(customer: str, kind: str, params: dict[str, Any], before: dict[str, Any], name: str) -> tuple:
    """Pure: (after, forward, inverse, summary) for one action."""
    return KINDS[kind][2](customer, params, before, name, kind)


def rebuild_check(customer: str, item: dict[str, Any]) -> None:
    """Re-derive every executable field from validated params + recorded before-state; stored copies never count."""
    target = item.get("target")
    _require(isinstance(item.get("before"), dict) and isinstance(target, str), "plan action state is invalid")
    if item["kind"] not in NEGATIVE_LEVELS:
        _require(target.startswith(f"customers/{customer}/"), "plan action targets a foreign resource")
    try:
        rebuilt = plan_kind(customer, item["kind"], item["params"], item["before"], target)
    except (KeyError, TypeError) as error:
        raise GoogleAdsActionError(f"action {item.get('id')}: recorded before-state is malformed") from error
    stored = (item.get("after"), item.get("forward"), item.get("inverse"), item.get("summary"))
    _require(rebuilt == stored, f"action {item.get('id')}: operations do not match its validated parameters")
    _require(item["before"] != item["after"], f"action {item.get('id')} would not change the account")
