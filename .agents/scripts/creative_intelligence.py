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


def analyze(manifest: dict[str, Any], decisions: dict[str, Any]) -> dict[str, Any]:
    """Analyze a snapshot and supplied labels without network or account actions."""
    assets = manifest.get("assets", [])
    decision_labels = decisions.get("labels", {})
    concepts: dict[str, list[str]] = defaultdict(list)
    outcomes: dict[tuple[str, str, str], dict[str, float]] = defaultdict(lambda: defaultdict(float))
    result_assets = []

    for asset in assets:
        asset_id = str(asset["asset_id"])
        labels = {**asset.get("labels", {}), **decision_labels.get(asset_id, {})}
        normalized = {name: labels.get(name, UNKNOWN) for name in ("hook", "format", "offer", "awareness", "audience_fit")}
        record = {"asset_id": asset_id, "labels": normalized, "evidence_ids": _evidence(asset)}
        result_assets.append(record)
        concepts[_concept_key({"labels": normalized})].append(asset_id)
        for outcome in asset.get("outcomes", []):
            key = (str(outcome.get("audience", UNKNOWN)), str(outcome.get("placement", UNKNOWN)), str(outcome.get("window", UNKNOWN)))
            for name in ("spend", "conversions", "margin", "refunds", "impressions", "clicks"):
                value = outcome.get(name)
                if isinstance(value, (int, float)) and not isinstance(value, bool):
                    outcomes[key][name] += value

    grouped = []
    for key, values in sorted(outcomes.items()):
        spend, conversions = values["spend"], values["conversions"]
        grouped.append({"audience": key[0], "placement": key[1], "window": key[2],
                        "spend": spend, "conversions": conversions,
                        "cpa": (spend / conversions) if conversions else None,
                        "evidence": "owned_ad_snapshot"})

    fatigue = []
    for asset in assets:
        series = asset.get("fatigue", {})
        baseline, current = series.get("baseline_ctr"), series.get("current_ctr")
        confounders = series.get("alternative_explanations", [])
        sample_ok = series.get("sample_sufficient") is True and series.get("lag_complete") is True
        decline = (baseline - current) / baseline if isinstance(baseline, (int, float)) and baseline > 0 and isinstance(current, (int, float)) else None
        if not sample_ok or decline is None:
            verdict = "review"
            reason = "insufficient_window_or_sample"
        elif confounders:
            verdict = "review"
            reason = "alternative_explanations_present"
        elif decline >= 0.2:
            verdict = "refresh_hypothesis"
            reason = "observed_ctr_decline"
        else:
            verdict = "leave_hypothesis"
            reason = "no_supported_fatigue_signal"
        fatigue.append({"asset_id": asset["asset_id"], "verdict": verdict, "reason": reason,
                        "alternative_explanations": confounders, "non_mutating": True})

    competitor = [{"asset_id": item.get("asset_id"), "longevity": item.get("longevity"),
                   "profitability": UNKNOWN, "note": "longevity is not observed profitability"}
                  for item in manifest.get("competitor_ads", [])]
    qa = [{"asset_id": asset["asset_id"], "requirements": [_requirement(asset, field) for field in ("visual_product", "disclosure", "rights")],
           "provider_approval": UNKNOWN, "note": "precheck is not provider approval"} for asset in assets]
    return {"schema": "aidevops.creative-intelligence-report/v1", "authority": "recommendations_only",
            "assets": result_assets, "concept_groups": [{"concept_id": hashlib.sha256(key.encode()).hexdigest()[:12], "asset_ids": ids} for key, ids in sorted(concepts.items())],
            "grouped_outcomes": grouped, "fatigue": fatigue, "competitor_observations": competitor,
            "policy_and_ugc_precheck": qa,
            "handoffs": [{"kind": "landing_matcher", "status": "typed_handoff", "target": "t18448"}]}
