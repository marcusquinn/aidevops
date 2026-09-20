#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Typed, provider-neutral records for the private prospecting read model."""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any, Mapping

SCHEMA = "aidevops.prospecting/v1"
DISPOSITIONS = frozenset({"new", "saved", "hidden", "not-fit", "reviewed", "responded"})
OBJECT_TYPES = frozenset({"post", "comment"})
DOCUMENT_FIELDS = frozenset({"schema", "project", "objects", "leads"})
PROJECT_FIELDS = frozenset({"project_id", "name", "profile_version", "discovery_version", "profile", "discovery"})
PROFILE_FIELDS = frozenset({"facts", "claims", "competitors", "budgets", "secret_profile_refs"})
DISCOVERY_FIELDS = frozenset({"keywords", "communities", "source_preferences", "budgets", "daily_result_limit"})
OBJECT_FIELDS = frozenset({"provider", "object_id", "object_type", "parent_object_id", "evidence_id", "corpus_id", "canonical_plane", "authority", "observed_at"})
LEAD_FIELDS = frozenset({"lead_id", "provider", "object_id", "score", "matching_phrase", "explanation", "intent", "stage", "suitability", "unknowns", "rubric_version", "model_version", "evidence_version"})


class ContractError(ValueError):
    """Raised when an import violates the prospecting contract."""


def exact_fields(value: Mapping[str, Any], allowed: frozenset[str], field: str) -> None:
    extras = sorted(set(value) - allowed)
    if extras:
        raise ContractError(f"{field} contains unsupported fields: {', '.join(extras)}")


def required_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ContractError(f"{field} must be a non-empty string")
    return value.strip()


def version(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise ContractError(f"{field} must be a positive integer")
    return value


def string_list(value: Any, field: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ContractError(f"{field} must be an array of strings")
    return tuple(value)


def validate_project_payload(kind: str, value: Any) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise ContractError(f"project.{kind} must be an object")
    allowed = PROFILE_FIELDS if kind == "profile" else DISCOVERY_FIELDS if kind == "discovery" else None
    if allowed is None:
        raise ContractError("project payload kind must be profile or discovery")
    exact_fields(value, allowed, f"project.{kind}")
    list_fields = ("facts", "claims", "competitors", "secret_profile_refs") if kind == "profile" else ("keywords", "communities", "source_preferences")
    for field in list_fields:
        if field in value:
            string_list(value[field], f"project.{kind}.{field}")
    if "budgets" in value:
        budgets = value["budgets"]
        if not isinstance(budgets, dict):
            raise ContractError(f"project.{kind}.budgets must be an object")
        for name, amount in budgets.items():
            if not isinstance(name, str) or not name or isinstance(amount, bool) or not isinstance(amount, (int, float)) or not math.isfinite(amount) or amount < 0:
                raise ContractError(f"project.{kind}.budgets must contain non-negative numeric values")
    if kind == "discovery" and "daily_result_limit" in value:
        limit = value["daily_result_limit"]
        if isinstance(limit, bool) or not isinstance(limit, int) or limit < 0:
            raise ContractError("project.discovery.daily_result_limit must be a non-negative integer")
    return value


@dataclass(frozen=True)
class ProjectRecord:
    project_id: str
    name: str
    profile_version: int
    discovery_version: int
    profile: Mapping[str, Any]
    discovery: Mapping[str, Any]

    @classmethod
    def from_mapping(cls, value: Any) -> "ProjectRecord":
        if not isinstance(value, dict):
            raise ContractError("project must be an object")
        exact_fields(value, PROJECT_FIELDS, "project")
        profile = validate_project_payload("profile", value.get("profile"))
        discovery = validate_project_payload("discovery", value.get("discovery"))
        return cls(
            required_text(value.get("project_id"), "project.project_id"),
            required_text(value.get("name"), "project.name"),
            version(value.get("profile_version"), "project.profile_version"),
            version(value.get("discovery_version"), "project.discovery_version"),
            profile,
            discovery,
        )


@dataclass(frozen=True)
class EvidenceObjectRecord:
    provider: str
    object_id: str
    object_type: str
    parent_object_id: str | None
    evidence_id: str
    corpus_id: str
    observed_at: str

    @classmethod
    def from_mapping(cls, value: Any, index: int) -> "EvidenceObjectRecord":
        if not isinstance(value, dict):
            raise ContractError(f"objects[{index}] must be an object")
        exact_fields(value, OBJECT_FIELDS, f"objects[{index}]")
        object_type = required_text(value.get("object_type"), f"objects[{index}].object_type")
        if object_type not in OBJECT_TYPES:
            raise ContractError(f"objects[{index}].object_type is unsupported")
        parent = value.get("parent_object_id")
        if parent is not None:
            parent = required_text(parent, f"objects[{index}].parent_object_id")
        if value.get("canonical_plane") != "_knowledge" or value.get("authority") != "projection":
            raise ContractError(f"objects[{index}] must reference a canonical knowledge projection")
        return cls(
            required_text(value.get("provider"), f"objects[{index}].provider"),
            required_text(value.get("object_id"), f"objects[{index}].object_id"),
            object_type,
            parent,
            required_text(value.get("evidence_id"), f"objects[{index}].evidence_id"),
            required_text(value.get("corpus_id"), f"objects[{index}].corpus_id"),
            required_text(value.get("observed_at"), f"objects[{index}].observed_at"),
        )


@dataclass(frozen=True)
class LeadRecord:
    lead_id: str
    provider: str
    object_id: str
    score: float
    matching_phrase: str
    explanation: str
    intent: str
    stage: str
    suitability: str
    unknowns: tuple[str, ...]
    rubric_version: str
    model_version: str
    evidence_version: str

    @classmethod
    def from_mapping(cls, value: Any, index: int) -> "LeadRecord":
        if not isinstance(value, dict):
            raise ContractError(f"leads[{index}] must be an object")
        exact_fields(value, LEAD_FIELDS, f"leads[{index}]")
        raw_score = value.get("score")
        if isinstance(raw_score, bool) or not isinstance(raw_score, (int, float)):
            raise ContractError(f"leads[{index}].score must be numeric")
        score = float(raw_score)
        if not 0 <= score <= 100:
            raise ContractError(f"leads[{index}].score must be between 0 and 100")
        return cls(
            required_text(value.get("lead_id"), f"leads[{index}].lead_id"),
            required_text(value.get("provider"), f"leads[{index}].provider"),
            required_text(value.get("object_id"), f"leads[{index}].object_id"),
            score,
            required_text(value.get("matching_phrase"), f"leads[{index}].matching_phrase"),
            required_text(value.get("explanation"), f"leads[{index}].explanation"),
            required_text(value.get("intent"), f"leads[{index}].intent"),
            required_text(value.get("stage"), f"leads[{index}].stage"),
            required_text(value.get("suitability"), f"leads[{index}].suitability"),
            string_list(value.get("unknowns"), f"leads[{index}].unknowns"),
            required_text(value.get("rubric_version"), f"leads[{index}].rubric_version"),
            required_text(value.get("model_version"), f"leads[{index}].model_version"),
            required_text(value.get("evidence_version"), f"leads[{index}].evidence_version"),
        )


@dataclass(frozen=True)
class ImportDocument:
    project: ProjectRecord
    objects: tuple[EvidenceObjectRecord, ...]
    leads: tuple[LeadRecord, ...]

    @classmethod
    def from_mapping(cls, value: Any) -> "ImportDocument":
        if not isinstance(value, dict) or value.get("schema") != SCHEMA:
            raise ContractError(f"schema must be {SCHEMA}")
        exact_fields(value, DOCUMENT_FIELDS, "document")
        raw_objects = value.get("objects")
        raw_leads = value.get("leads")
        if not isinstance(raw_objects, list) or not isinstance(raw_leads, list):
            raise ContractError("objects and leads must be arrays")
        objects = tuple(EvidenceObjectRecord.from_mapping(item, i) for i, item in enumerate(raw_objects))
        leads = tuple(LeadRecord.from_mapping(item, i) for i, item in enumerate(raw_leads))
        object_keys = {(item.provider, item.object_id) for item in objects}
        if len(object_keys) != len(objects):
            raise ContractError("objects contain conflicting provider IDs")
        lead_ids = {item.lead_id for item in leads}
        if len(lead_ids) != len(leads):
            raise ContractError("lead IDs must be unique within an import")
        for lead in leads:
            if (lead.provider, lead.object_id) not in object_keys:
                raise ContractError(f"lead {lead.lead_id} references an unknown object")
        return cls(ProjectRecord.from_mapping(value.get("project")), objects, leads)
