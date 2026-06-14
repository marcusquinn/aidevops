---
description: Standard app object packs for issues, labels, chat, CRM activities, document management, accounting, users, teams, and referrals
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Standard Objects

Use boring canonical names so apps, imports, AI agents, and integrations share one vocabulary.

## Universal labels and tags

Every durable object type should be label/tag capable unless there is a deliberate product reason not to expose it.

Prefer a governed label model for important records:

- `label_groups`: workspace, key, name, description, exclusive-per-entity flag, sort order, archived state.
- `labels`: workspace, group, key, value, name, color, description, visibility, archived state.
- `label_assignments`: workspace, label, entity type, entity ID, assigned by, assigned at.
- Optional typed join tables for high-volume or referentially critical objects.

Use free-form tags only for low-risk local filtering or imported metadata. Do not rely on array-only tags for permissions, workflow state, billing, or audit-critical classification.

Use grouped label keys for classification and UI grouping:

- `status:normal`, `status:blocked`, `status:archived`.
- `priority:high`, `priority:low`.
- `type:bug`, `type:feature`, `type:support`.

If a value drives workflow or compliance, keep a typed status/state field as the source of truth and mirror it to labels only for filtering/grouping.

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

## Chat and communication

Use one durable communication model that can attach to issues, accounts, contacts, projects, documents, or standalone workspaces.

| Object | Purpose |
|--------|---------|
| `channel_groups` | Group channels by workspace area, team, customer, project, or product |
| `channels` | Named spaces: public, private, team, project, support, announcement |
| `channel_memberships` | User/team membership, role, notification preference, last-read pointer |
| `chats` | Direct, group, or entity-scoped conversations that are not named channels |
| `chat_participants` | Users, contacts, service accounts, or external participants in a chat |
| `messages` | Durable message body, author, timestamps, edit/delete state, source metadata |
| `threads` | Replies anchored to a message or entity record |
| `reactions` | Emoji/action reactions on messages, comments, or activity events |
| `mentions` | User/team/entity mentions for notification and search |
| `read_receipts` | Per-user read state for channels, chats, threads, and messages |
| `message_attachments` | Links from messages to files, documents, or external assets |

Rules:

- Keep message bodies append/audit friendly: edits create version/audit events or preserve edited-at metadata.
- Treat typing indicators and transient presence as ephemeral runtime state, not durable business records.
- Use labels on channels, chats, and threads for grouping such as `status:normal`, `topic:sales`, or `visibility:internal`.

## CRM activities and reminders

Use `activities` as the shared activity/event surface, with typed objects when fields diverge.

| Object | Purpose |
|--------|---------|
| `activities` | Shared timeline/calendar base: subject, type, status, parent entity, owner, team |
| `calls` | Direction, phone/contact links, outcome, recording/transcript links |
| `meetings` | Start/end, location/link, participants, acceptance status, agenda/outcome |
| `tasks` | Due date, priority, status, assignee/team, checklist/subtask links |
| `reminders` | Trigger time, channel, target entity, snooze/dismiss/completed state |
| `activity_participants` | Users, contacts, accounts, or external attendees |
| `activity_links` | Polymorphic links to accounts, contacts, opportunities, cases, issues, documents |

Default activity statuses:

- planned/scheduled, in-progress, completed/held, cancelled/not-held, deferred.

Rules:

- Calls, meetings, and tasks can be first-class tables or typed `activities`; choose typed tables when they need different validation, UI, or integrations.
- Reminders are separate rows so one record can notify multiple people through multiple channels.
- Use labels for grouping/reporting, but use typed fields for workflow-critical state and dates.

## Document management

Use a file model that separates binary storage from document metadata and object links.

| Object | Purpose |
|--------|---------|
| `folders` | Workspace-scoped hierarchy for navigation and grouping |
| `files` | Logical file/document record: title, mime type, size, checksum, owner, status |
| `file_versions` | Immutable versions with storage key, checksum, size, created by/at |
| `file_links` | Attach files/folders to any entity type and entity ID |
| `file_permissions` | Optional object-specific grants when folder/workspace permissions are insufficient |
| `file_comments` | Document comments/annotations when comments are not global |
| `file_previews` | Derived thumbnails, OCR text, transcripts, embeddings, renditions |

Rules:

- Folders organise records; they are not the only permission boundary unless the product explicitly defines folder inheritance.
- Attachments are links to `files`, not independent binary blobs on each business table.
- Preserve version, checksum, storage provider/key, source/import provenance, retention class, and sensitivity labels.

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
- Confirm grouped label keys such as `status:normal` have a label group/category and exclusivity policy.
- Trace one issue through label assignment, comments, state transition, audit event, and external-provider sync.
- Trace one channel/chat message through thread replies, reactions, mentions, read receipts, attachments, audit, and retention rules.
- Trace one CRM activity through participants, reminders, parent entity links, labels, and calendar/timeline output.
- Trace one file through folder placement, versioning, attachment to an entity, preview/OCR, permissions, and audit.
- Trace one quote-to-invoice-to-payment/refund path before calling billing/accounting ready.
