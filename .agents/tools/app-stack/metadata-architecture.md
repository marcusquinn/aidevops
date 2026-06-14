---
description: Metadata-driven entity, field, layout, ACL, workflow, audit, and import/export architecture
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Metadata Architecture

Use metadata when the app needs configurable entities, layouts, permissions, imports, workflows, and AI-readable structure.

## Core metadata objects

| Object | Purpose |
|--------|---------|
| `entity_definitions` | Entity key, label, table/source, ownership, lifecycle |
| `field_definitions` | Field key, type, validation, display, indexing, privacy |
| `relationship_definitions` | One-to-many, many-to-many, polymorphic references |
| `layout_definitions` | Detail/edit/create/list layouts and panels |
| `panel_definitions` | Relationship/admin/dashboard panels and visibility rules |
| `view_definitions` | Saved filters, columns, sorting, grouping |
| `label_group_definitions` | Label namespaces/categories such as status, priority, type |
| `label_definitions` | Governed labels available across entity types, e.g. `status:normal` |
| `capability_definitions` | Named product actions beyond CRUD |
| `permission_rules` | Role/user/team/workspace/entity/field/panel/action permissions |
| `workflow_definitions` | States, transitions, guards, actions, timers |
| `automation_rules` | Trigger/action rules and integration hooks |
| `import_mappings` | CSV/API/source-to-canonical field maps |
| `audit_events` | Immutable change/event ledger |

## Design rules

- Metadata augments typed code; it does not replace migrations for core tables.
- Keep entity keys stable and human-readable.
- Put labels/descriptions/help text in metadata so AI agents can explain fields.
- Keep validation close to field definitions and enforce again at API/database boundaries.
- Model layouts separately from fields so the same entity can have role/context-specific views.
- Model panels separately from layouts so related lists, admin panels, and dashboards can have independent permissions.
- Make labels/tags a first-class metadata concern for every user-facing entity; model label groups, exclusivity, display order, colour, and scope.
- Keep roles, teams, capabilities, and permission rules separate so teams do not become roles.
- Make workflows explicit: state, transition, actor, guard, side effects.
- Preserve import provenance: source, source row ID/hash, mapping version, confidence, reviewer.

## When not to use metadata

- The object has one fixed screen and no expected configuration.
- Performance-critical paths need direct typed code and indexes.
- The team cannot support an admin/config UI or migration path.

## Verification

- Demonstrate one entity from definition to list view, detail layout, edit validation, ACL, workflow transition, audit event, and export.
- Demonstrate one grouped label assignment such as `status:normal` and one issue relationship if the app exposes work tracking.
- Confirm field-level privacy and AI exposure rules.
- Confirm role/team permission behaviour for object, panel, field, and workflow actions.
- Confirm imports can be replayed or explained with provenance.
