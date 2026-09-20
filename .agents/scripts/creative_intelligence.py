#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline, evidence-linked creative intelligence; never mutates ad accounts."""

from __future__ import annotations

import hashlib
from collections import defaultdict
from typing import Any


UNKNOWN = "unknown"


def _evidence(asset: dict[str, Any]) -> list[str]:
    return [str(value) for value in asset.get("evidence_ids", []) if value]


def _concept_key(asset: dict[str, Any]) -> str:
    """Group substantive labels, not superficial asset IDs or rendering changes."""
    labels = asset.get("labels", {})
    return "|".join(str(labels.get(name, UNKNOWN)).lower() for name in ("hook", "offer", "awareness"))


def _requirement(asset: dict[str, Any], field: str) -> dict[str, Any]:
    observed = asset.get("evidence", {}).get(field)
    return {"requirement": field, "status": "observed" if observed is True else UNKNOWN,
             "evidence_ids": _evidence(asset) if observed is True else []}


def _asset_records(assets: list[dict[str, Any]], decisions: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, list[str]]]:
    records = []
    concepts: dict[str, list[str]] = defaultdict(list)
    decision_labels = decisions.get("labels", {})
    for asset in assets:
        asset_id = str(asset["asset_id"])
        labels = {**asset.get("labels", {}), **decision_labels.get(asset_id, {})}
        normalized = {name: labels.get(name, UNKNOWN) for name in ("hook", "format", "offer", "awareness", "audience_fit")}
        records.append({"asset_id": asset_id, "labels": normalized, "evidence_ids": _evidence(asset)})
        concepts[_concept_key({"labels": normalized})].append(asset_id)
    return records, concepts


def _grouped_outcomes(assets: list[dict[str, Any]]) -> list[dict[str, Any]]:
    outcomes: dict[tuple[str, str, str], dict[str, float]] = defaultdict(lambda: defaultdict(float))
    for asset in assets:
        for outcome in asset.get("outcomes", []):
            key = (str(outcome.get("audience", UNKNOWN)), str(outcome.get("placement", UNKNOWN)), str(outcome.get("window", UNKNOWN)))
            for name in ("spend", "conversions", "margin", "refunds", "impressions", "clicks"):
                value = outcome.get(name)
                if isinstance(value, (int, float)) and not isinstance(value, bool):
                    outcomes[key][name] += value
    return [{"audience": key[0], "placement": key[1], "window": key[2],
             "spend": values["spend"], "conversions": values["conversions"],
             "cpa": (values["spend"] / values["conversions"]) if values["conversions"] else None,
             "evidence": "owned_ad_snapshot"} for key, values in sorted(outcomes.items())]


def _fatigue_verdict(series: dict[str, Any]) -> tuple[str, str]:
    baseline, current = series.get("baseline_ctr"), series.get("current_ctr")
    decline = (baseline - current) / baseline if isinstance(baseline, (int, float)) and baseline > 0 and isinstance(current, (int, float)) else None
    if series.get("sample_sufficient") is not True or series.get("lag_complete") is not True or decline is None:
        return "review", "insufficient_window_or_sample"
    if series.get("alternative_explanations", []):
        return "review", "alternative_explanations_present"
    if decline >= 0.2:
        return "refresh_hypothesis", "observed_ctr_decline"
    return "leave_hypothesis", "no_supported_fatigue_signal"


def _fatigue_observations(assets: list[dict[str, Any]]) -> list[dict[str, Any]]:
    observations = []
    for asset in assets:
        series = asset.get("fatigue", {})
        verdict, reason = _fatigue_verdict(series)
        observations.append({"asset_id": asset["asset_id"], "verdict": verdict, "reason": reason,
                             "alternative_explanations": series.get("alternative_explanations", []), "non_mutating": True})
    return observations


def analyze(manifest: dict[str, Any], decisions: dict[str, Any]) -> dict[str, Any]:
    """Analyze a snapshot and supplied labels without network or account actions."""
    assets = manifest.get("assets", [])
    result_assets, concepts = _asset_records(assets, decisions)

    competitor = [{"asset_id": item.get("asset_id"), "longevity": item.get("longevity"),
                   "profitability": UNKNOWN, "note": "longevity is not observed profitability"}
                  for item in manifest.get("competitor_ads", [])]
    qa = [{"asset_id": asset["asset_id"], "requirements": [_requirement(asset, field) for field in ("visual_product", "disclosure", "rights")],
           "provider_approval": UNKNOWN, "note": "precheck is not provider approval"} for asset in assets]
    return {"schema": "aidevops.creative-intelligence-report/v1", "authority": "recommendations_only",
            "assets": result_assets, "concept_groups": [{"concept_id": hashlib.sha256(key.encode()).hexdigest()[:12], "asset_ids": ids} for key, ids in sorted(concepts.items())],
             "grouped_outcomes": _grouped_outcomes(assets), "fatigue": _fatigue_observations(assets), "competitor_observations": competitor,
            "policy_and_ugc_precheck": qa,
            "handoffs": [{"kind": "landing_matcher", "status": "typed_handoff", "target": "t18448"}]}
