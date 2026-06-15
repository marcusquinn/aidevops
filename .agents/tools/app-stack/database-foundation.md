---
description: Database foundation for metadata-driven business apps using Postgres, Drizzle, RLS, accounts, and contacts
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Database Foundation

Default to Postgres + Drizzle for durable application data. `workspace_id` is the default tenancy and RLS root; organisation, account, and user scopes are ownership/domain filters unless explicitly promoted to tenancy roots.

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

- `workspaces`, memberships, teams/user groups, roles, role assignments, invitations, settings.
- `users` / auth identity mapping.
- `audit_events`, `activity_events`, comments, notifications.
- `files`, folders, attachments, labels/tags, imports, exports.
- `integrations`, external IDs, sync cursors.

### Collaboration and work pack

- `issues` with forge-compatible fields: title, body, state, type, priority, assignee, labels, milestones, parent/related issues, external provider IDs.
- Content: content types, entries, pages/routes, revisions, blocks, taxonomies, terms, menus, redirects, SEO metadata.
- Conversations: conversation groups, channel/direct/group/entity conversation types, messages, threads, reactions, mentions, read receipts, attachments.
- Calendar/CRM activities: calendar collections, activity types such as calls/meetings/tasks, participants, alarms/reminders, recurrence, calendar/timeline links.
- Workflows: definitions, states, transitions, guards, actions, runs/events, timers, decisions, approvals.
- Tasks, milestones, comments, activity streams.
- Issue relationships: blocks, duplicates, relates-to, split-from, supersedes.

### Business relationship pack

- `accounts`, `contacts`, account-contact relationships.
- Addresses, emails, phone numbers, websites, social handles.
- Tags, segments, lifecycle/status, owner assignment.

### Metadata pack

- Entity definitions, field definitions, layouts, views, filters.
- Labels, ACL/RBAC policies, capability definitions, workflow/state/transition definitions, automations, validation rules.

### Optional packs

- CRM: leads, opportunities, campaigns, cases, referrers, referrals.
- Commercial: products/items, services, prices, price lists, discount/voucher codes, quotes/estimates, orders.
- Accounting: invoices, pro-forma invoices, credit notes, bills, payments, refund payments, payment allocations, `ledger_accounts` / `chart_accounts`, ledger entries, tax codes.
- Content/editorial: content entries, publishing workflows, navigation, taxonomies, forms, search indexes.
- Inventory: items, stock movements, locations.
- Projects: projects, tasks, milestones, time entries.
- Collaboration: threads, decisions, approvals.
- AI: prompts, runs, tool calls, memory references, evaluations.

## Universal labels/tags

- Make labels/tags available to all user-facing object types through a shared assignment model.
- Use governed `label_groups`, `labels`, and `label_assignments` for grouping, workflow, reporting, permissions, and sync.
- Use grouped keys such as `status:normal`, `priority:high`, and `type:support`; make groups exclusive per entity when only one value is valid.
- Use free-form array tags only for local, low-risk filtering or imported metadata.
- Prefer typed join tables for high-volume or referentially critical objects.

## Access model defaults

- Keep teams/user groups distinct from roles: teams group people; roles grant capabilities.
- Use RBAC permission rules across users, teams, roles, objects, panels, fields, workflows, and scopes.
- Model common scopes as `own`, `team`, `workspace`, and `all`, with workspace RLS as the database backstop.

## Migration home

- In TypeScript monorepos, `packages/db` owns schemas, relations, seeds, migration helpers, and `migrations/`.
- Use `packages/db/src/schema/index.ts` as the Drizzle schema entrypoint and `packages/db/migrations/` for generated SQL and metadata snapshots.
- See `app-stack/migration-layout.md` for the full layout.

## RLS defaults

- Scope tables by `workspace_id` where possible.
- Use membership/role tables for policy checks.
- Treat RBAC scope `all` as all records in the current workspace; platform-global access is a separate system capability.
- Add external IDs per integration, not as primary keys.
- Audit writes with actor, workspace, entity type, entity ID, action, and diff summary.

## Verification

- Draw the object graph before writing migrations.
- Identify every table's workspace boundary and RLS policy.
- Confirm `accounts` and `contacts` cover imported synonyms before adding new party/person tables.
- Confirm issues, content/pages, conversations/channels/chats, workflows/approvals, calendar/CRM activities, WebDAV-style files/folders, CardDAV-style contacts/address books, labels/tags, users, teams, roles, prices, quotes, invoices, payments, credits, and refunds are either implemented or intentionally out of scope.
- Run Drizzle generate/migrate checks and inspect generated SQL.
