---
description: Database foundation for metadata-driven business apps using Postgres, Drizzle, RLS, accounts, and contacts
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Database Foundation

Default to Postgres + Drizzle for durable application data. Add RLS when records are scoped by workspace, organisation, account, or user.

## Naming doctrine

Use conventional business object names:

- `accounts` — organisations, companies, customers, suppliers, vendors, partners, households, or other relationship containers.
- `contacts` — people associated with accounts or independent relationships.

Keep synonyms at the import/integration edge instead of making them canonical table names:

| Incoming term | Canonical target |
|---------------|------------------|
| party, company, organization, customer, supplier, vendor, partner, household | `accounts` |
| person, individual, lead, prospect, stakeholder | `contacts` |
| customer contact, supplier contact, vendor contact | `contacts` with account relationship |

## Kernel object packs

### Always-on kernel

- `workspaces`, memberships, roles, invitations, settings.
- `users` / auth identity mapping.
- `audit_events`, `activity_events`, comments, notifications.
- `files`, attachments, imports, exports.
- `integrations`, external IDs, sync cursors.

### Business relationship pack

- `accounts`, `contacts`, account-contact relationships.
- Addresses, emails, phone numbers, websites, social handles.
- Tags, segments, lifecycle/status, owner assignment.

### Metadata pack

- Entity definitions, field definitions, layouts, views, filters.
- ACL policies, workflow definitions, automations, validation rules.

### Optional packs

- CRM: leads, opportunities, campaigns, cases.
- Accounting: invoices, bills, payments, ledger entries, tax codes.
- Inventory: items, stock movements, locations.
- Projects: projects, tasks, milestones, time entries.
- Collaboration: threads, decisions, approvals.
- AI: prompts, runs, tool calls, memory references, evaluations.

## RLS defaults

- Scope tables by `workspace_id` where possible.
- Use membership/role tables for policy checks.
- Add external IDs per integration, not as primary keys.
- Audit writes with actor, workspace, entity type, entity ID, action, and diff summary.

## Verification

- Draw the object graph before writing migrations.
- Identify every table's workspace boundary and RLS policy.
- Confirm `accounts` and `contacts` cover imported synonyms before adding new party/person tables.
- Run Drizzle generate/migrate checks and inspect generated SQL.
