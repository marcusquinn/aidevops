#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Cannibalisation and duplicate checks for keyword registries.

Rule: one phrase targets one URL (duplicates are errors). One URL may carry
many phrases of the same intent; mixed intents on one URL, or a live target
ranking with a different URL, are warnings to investigate.
"""

from __future__ import annotations

from collections import defaultdict

import keywords_registry as reg

ACTIVE = {"targeted", "live", "won", "active"}


def _active(row: dict) -> bool:
    return row.get("status") in ACTIVE and bool(row.get("target_url"))


def duplicate_phrases(registry: dict) -> list[str]:
    phrases: dict[tuple, list[str]] = defaultdict(list)
    for row in registry["targets"]:
        if row.get("status") != "retired":
            key = (reg.normalise_phrase(row.get("phrase", "")), row.get("locale", ""), row.get("market", ""))
            phrases[key].append(row["id"])
    return [f"targets: phrase {key[0]!r} duplicated in {', '.join(ids)}"
            for key, ids in phrases.items() if len(ids) > 1]


def duplicate_questions(registry: dict) -> list[str]:
    seen: dict[str, str] = {}
    errors = []
    for row in registry["queries"]:
        key = reg.normalise_phrase(row.get("question", ""))
        if key in seen:
            errors.append(f"queries: question duplicated in {seen[key]}, {row['id']}")
        seen[key] = row["id"]
    return errors


def url_warnings(registry: dict) -> list[str]:
    intents: dict[str, set[str]] = defaultdict(set)
    warnings = []
    for row in filter(_active, registry["targets"]):
        if row.get("classic_intent"):
            intents[row["target_url"]].add(row["classic_intent"])
        ranking = row.get("ranking_url")
        if ranking and ranking != row["target_url"]:
            warnings.append(f"targets {row['id']}: ranks with {ranking} instead of target {row['target_url']}")
    warnings += [f"targets: {url} mixes intents {', '.join(sorted(found))}"
                 for url, found in intents.items() if len(found) > 1]
    return warnings
