---
description: Change history, diffs, duplicate-record merges, and relationship cardinality for app data models
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Data History and Relationships

Most business apps eventually need record history, user-readable diffs, duplicate merges, and configurable relationships. Model these as shared platform primitives instead of per-object one-offs.

## Change history and diffs

| Object | Purpose |
|--------|---------|
| `record_revisions` | User-restorable revision for one entity: entity ref, version, actor, source, reason, timestamp |
| `record_revision_fields` | Field-level before/after values, diff metadata, redaction/sensitivity markers |
| `record_snapshots` | Optional full snapshot for rich documents, JSON-heavy records, or restore checkpoints |
| `change_events` | Low-level change stream for sync, search indexing, automation, cache invalidation |
| `audit_events` | Immutable security/business ledger with actor, action, entity, summary, and reason |

Rules:

- Use `audit_events` for accountability; use `record_revisions` when users need compare, restore, or revision browsing.
- Store structured field diffs for normal entity fields. Store patch/snapshot formats for rich text, block content, JSON, or binary-derived metadata.
- Keep full before/after values behind privacy controls; redact or hash sensitive fields when a diff is enough for accountability.
- Link revisions to workflow runs, imports, merge jobs, sync runs, and external events so the source of a change is explainable.
- Content objects can keep specialised `content_revisions`, but the same actor/source/reason/diff rules apply.

## Duplicate-record merge model

| Object | Purpose |
|--------|---------|
| `dedupe_candidates` | Potential duplicate group with confidence, evidence, status, and reviewer |
| `merge_jobs` | Merge execution request: survivor entity, source entities, state, actor, approval, timestamps |
| `merge_plans` | Draft/final plan containing selected survivor, field choices, relationship choices, and validation result |
| `merge_field_choices` | Per-field decision: keep survivor value, take source value, combine, clear, or set manual value |
| `merge_relationship_choices` | Per-relationship decision: move, copy, ignore, dedupe, preserve as related, or flag conflict |
| `merge_events` | Append-only merge lifecycle events and audit/provenance references |
| `entity_aliases` | Redirect/tombstone rows so old IDs, external IDs, URLs, and imports resolve to the survivor |

Rules:

- Merges are planned, validated, then executed; do not perform irreversible row rewrites directly from a duplicate suggestion.
- The merge plan must choose values field-by-field and relationships relationship-by-relationship.
- Validate unique constraints, required fields, RLS/RBAC, workflow state, legal hold, retention policy, and external sync constraints before execution.
- Preserve provenance from every merged source. Link source records, source field values, evidence, reviewer, and merge reason.
- Prefer tombstone/alias rows over hard delete so imports, URLs, audit logs, and external IDs can resolve historical references.
- Relationship merges need a conflict policy: move links to the survivor, copy links, dedupe equivalent links, preserve source as related, or require manual review.
- Human approval is the default for customer, financial, identity, legal, or high-impact merges; automation can suggest and prefill plans.

## Relationship definitions and cardinality

| Object | Purpose |
|--------|---------|
| `relationship_definitions` | Source entity, target entity, cardinality, direction, inverse label, requiredness, lifecycle |
| `relationship_type_definitions` | Governed relationship names such as parent, owner, member, blocks, duplicates, supplier |
| `entity_relationships` | Generic runtime link rows for configurable or cross-object relationships |
| `relationship_attributes` | Optional metadata on a relationship: role, dates, status, weight, source, confidence |
| `relationship_events` | Append-only create/update/delete/merge events for relationship history |

Cardinality rules:

- `one_to_one`: use a unique foreign key or a link table with unique source and target constraints.
- `one_to_many`: use a foreign key on the many/child side; expose the inverse collection as a view/query.
- `many_to_one`: same physical shape as one-to-many, documented from the child/source perspective.
- `many_to_many`: use a join/link table with a unique source/target pair and relationship metadata columns when needed.
- Polymorphic relationships use `entity_type` + `entity_id` only when configurability matters more than database-enforced foreign keys.
- Use typed join tables for high-volume, referentially critical, permission-critical, or heavily indexed relationships.

Definition rules:

- Define source/target entity, cardinality, inverse name, labels, sort order, ownership, delete/cascade behaviour, and permission inheritance explicitly.
- Do not let a relationship imply permission inheritance unless the product models and tests inheritance.
- Distinguish relationship type from label/tag: relationship types connect records; labels classify records.
- Store external relationship IDs and sync handles at the integration edge, not as primary keys.
- For symmetric relationships, define canonical ordering and inverse labels so duplicate links cannot be created in reverse order.

## Verification

- Trace one edit through `record_revisions`, field diff, audit event, workflow/import/source reference, and restore/compare UI.
- Trace one duplicate merge from candidate evidence to reviewed merge plan, field choices, relationship choices, alias/tombstone, audit, and external sync repair.
- Prove one `one_to_one`, `one_to_many`, `many_to_one`, and `many_to_many` relationship with database constraints and UI labels.
- Confirm relationship reads/writes obey RBAC/RLS and do not inherit permissions unless explicitly configured.
- Confirm merge and revision history follow retention, redaction, legal hold, and export policies.
