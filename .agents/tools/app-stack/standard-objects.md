---
description: Standard app object packs for issues, labels, commercial documents, accounting, users, teams, and referrals
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Standard Objects

Use boring canonical names so apps, imports, AI agents, and integrations share one vocabulary.

## Universal labels and tags

Every durable object type should be label/tag capable unless there is a deliberate product reason not to expose it.

Prefer a governed label model for important records:

- `labels`: workspace, key, name, color, description, category, visibility, archived state.
- `label_assignments`: workspace, label, entity type, entity ID, assigned by, assigned at.
- Optional typed join tables for high-volume or referentially critical objects.

Use free-form tags only for low-risk local filtering or imported metadata. Do not rely on array-only tags for permissions, workflow state, billing, or audit-critical classification.

## Issues

Model `issues` after common forge trackers so GitHub, GitLab, Gitea, support tickets, and internal work items map cleanly.

Core fields:

- `workspace_id`, `title`, `body`, `state`, `state_reason`, `issue_type`, `priority`, `severity`.
- `author_id`, `assignee_id`, `team_id`, `milestone_id`, `parent_issue_id`, `due_at`, `closed_at`.
- External mapping: `source_provider`, `source_project`, `source_issue_id`, `source_issue_number`, `source_url`.
- Labels via `label_assignments`; comments, activity, files, and audit via shared collaboration objects.

Support issue relationships:

- `blocks`, `blocked_by`, `duplicates`, `duplicated_by`, `relates_to`, `split_from`, `supersedes`.

Use `issues` for user-visible work, defects, support requests, and change requests. Use `tasks` for schedule/checklist execution when the product needs a lighter sub-work item.

## Access and identity

- `users`: global/auth identity records.
- `workspaces`: data and permission boundary.
- `teams` / `user_groups`: collections of users; distinct from roles.
- `roles`: permission bundles; assigned to users and/or teams within a workspace.
- `invitations`, sessions, auth accounts, API keys, and audit events belong in the always-on kernel.

## Commercial and accounting pack

Add commercial objects deliberately, but keep names conventional:

| Need | Canonical objects |
|------|-------------------|
| Parties | `accounts`, `contacts`, addresses, contact methods |
| Products/services | `items` or `products`, `services`, units, tax categories |
| Pricing | `prices`, `price_lists`, price list items, currencies |
| Discounts | `discount_codes` / `voucher_codes`, pricing rules, redemptions |
| Sales pipeline | leads, opportunities, campaigns, referrers, referrals |
| Quotes | `quotes` / estimates, quote lines, expiry, acceptance state |
| Orders | orders, order lines, fulfilment/status events |
| Invoices | invoices, invoice lines, pro-forma invoices, tax totals |
| Credits | credit notes, account credits, credit allocations |
| Payments | payments, payment allocations, refunds, refund payments |
| Subscriptions | subscriptions, plans, billing periods, renewal events |
| Accounting | ledger entries, journals, tax codes, accounts, reconciliation |

Accounting rules:

- Store money as exact numeric values with explicit currency and tax treatment.
- Keep document numbers stable, sequential where legally required, and workspace/account scoped.
- Treat issued invoices as immutable; correct them with credit notes, adjustments, or reversal documents.
- Pro-forma invoices are non-posting documents until converted/issued; do not mix them with posted ledger entries.
- Payments are separate from invoices; allocate payments/refunds to documents through allocation rows.
- Preserve provider IDs, payment processor event IDs, and import provenance for reconciliation.

## Verification

- Map incoming synonyms to canonical objects before adding new tables.
- Confirm labels/tags are available for each user-facing object type.
- Trace one issue through label assignment, comments, state transition, audit event, and external-provider sync.
- Trace one quote-to-invoice-to-payment/refund path before calling billing/accounting ready.
