---
description: Standard app object packs for issues, labels, chat, CRM activities, document management, accounting, users, teams, and referrals
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Standard Objects

Use boring canonical names so apps, imports, AI agents, and integrations share one vocabulary.

## Standard hierarchy

Avoid competing roots. Prefer a small set of canonical containers, then model product-specific names as types, labels, or views:

```text
workspace
  labels / label_groups / label_assignments
  users / teams / roles / permissions
  accounts / contacts / address_books
  issues / issue_relationships
  conversation_groups / conversations / messages / message_threads / message_reactions
  calendar_collections / activities / activity_participants / activity_alarms
  folders / files / file_versions / file_links
  quotes / invoices / payments / credits / ledger_entries
```

Use separate tables only when the subtype needs distinct validation, lifecycle, permissions, integrations, or high-volume indexes. Otherwise use a typed row plus metadata.

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

## Conversations, chat, and communication

Use one durable conversation model that can attach to issues, accounts, contacts, projects, documents, or standalone workspaces. Channels and chats are conversation types, not competing roots.

| Object | Purpose |
|--------|---------|
| `conversation_groups` | Group conversations by workspace area, team, customer, project, or product |
| `conversations` | Channel, direct chat, group chat, support thread, announcement, or entity-scoped discussion |
| `conversation_memberships` | User/team/contact membership, role, notification preference, last-read pointer |
| `messages` | Durable message body, author, timestamps, edit/delete state, source metadata |
| `message_threads` | Thread root/reply metadata when `messages.thread_root_id` is insufficient |
| `message_reactions` | Emoji/action reactions on messages, comments, or activity events |
| `mentions` | User/team/entity mentions for notification and search |
| `read_receipts` | Per-user read state for conversations, threads, and messages |
| `message_attachments` | Links from messages to files, documents, or external assets |

Rules:

- `conversation_type` covers channel, direct, group, entity, support, and announcement.
- Comments can be implemented as messages in an entity-scoped conversation; do not maintain a separate comment system unless deliberately lighter-weight.
- Keep message bodies append/audit friendly: edits create version/audit events or preserve edited-at metadata.
- Treat typing indicators and transient presence as ephemeral runtime state, not durable business records.
- Use labels on conversations and threads for grouping such as `status:normal`, `topic:sales`, or `visibility:internal`.

## CRM activities and reminders

Use `activities` as the shared timeline/calendar surface. Calls, meetings, tasks, and reminders are activity/calendar types by default, not separate root tables.

| Object | Purpose |
|--------|---------|
| `calendar_collections` | Calendar/task-list grouping, including CalDAV calendar collections |
| `activities` | Shared base: subject, activity type, calendar component, status, parent entity, owner, team |
| `activity_participants` | Users, contacts, accounts, or external attendees |
| `activity_links` | Polymorphic links to accounts, contacts, opportunities, cases, issues, documents |
| `activity_alarms` | Reminder/notification rows: trigger time, delivery channel, snooze/dismiss/completed state; maps to iCalendar alarms |
| Optional detail tables | `call_details`, `meeting_details`, or `task_details` only when subtype fields justify them |

Default activity statuses:

- planned/scheduled, in-progress, completed/held, cancelled/not-held, deferred.

Default activity/calendar types:

- `call`, `meeting`, `task`, `deadline`, `note`, `journal`, `time_block`.

Rules:

- CalDAV-style mapping: meetings/calls/time blocks map to event components; tasks map to todo components; notes/log entries map to journal components; reminders map to alarms.
- Choose typed detail tables only when the subtype needs different validation, UI, integrations, or indexes: e.g. call recording/transcript fields or meeting room/video-link fields.
- Activity alarms are one-to-many rows so one activity can notify multiple people through multiple channels; product UI can label them reminders.
- Use labels for grouping/reporting, but use typed fields for workflow-critical state and dates.

## Document management

Use a file model that separates binary storage from document metadata and object links. WebDAV terms map cleanly: folders are collections, files/file versions are resources, metadata are properties.

| Object | Purpose |
|--------|---------|
| `folders` | Workspace-scoped hierarchy/navigation; maps to WebDAV collections |
| `files` | Logical file/document record: title, mime type, size, checksum, owner, status |
| `file_versions` | Immutable resources with storage key, checksum, size, ETag, created by/at |
| `file_links` | Attach files/folders to any entity type and entity ID |
| `file_properties` | WebDAV/dead properties, custom metadata, retention and sensitivity data |
| `file_locks` | Optional WebDAV-compatible lock tokens, owners, depth, and expiry |
| `file_permissions` | Optional object-specific grants when folder/workspace permissions are insufficient |
| `file_comments` | Document comments/annotations when comments are not global |
| `file_previews` | Derived thumbnails, OCR text, transcripts, embeddings, renditions |

Rules:

- Folders organise records; they are not the only permission boundary unless the product explicitly defines folder inheritance.
- Attachments are links to `files`, not independent binary blobs on each business table.
- Preserve version, checksum, storage provider/key, source/import provenance, retention class, and sensitivity labels.

## DAV sync compatibility

When an app may mirror with WebDAV, CalDAV, or CardDAV, preserve standard sync handles instead of treating sync as a one-off import.

| Standard | Local model |
|----------|-------------|
| WebDAV collections/resources/properties/locks | `folders`, `files`, `file_versions`, `file_properties`, `file_locks` |
| CalDAV calendars/events/todos/journals/alarms | `calendar_collections`, `activities`, `activity_participants`, `activity_alarms` |
| CardDAV address books/vCards/groups | `address_books`, `contacts`, account/contact relationships, contact groups or labels |

Rules:

- Store external UID, source URL/path, ETag, sync token/change tag, component type, last synced time, deletion/tombstone state, and raw payload hash where applicable.
- Keep `contacts` canonical for people; map CardDAV vCards into contacts/contact methods, and map organisation fields to `accounts` when they represent companies.
- Use address books as sync/grouping containers, not replacements for workspace/account/contact boundaries.
- Preserve recurrence, attendee, organizer, timezone, alarm, and free/busy fields for calendar objects even if the product UI starts simpler.

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
- Trace one conversation message through thread replies, reactions, mentions, read receipts, attachments, audit, and retention rules.
- Trace one CRM/calendar activity through participants, alarms/reminders, recurrence, parent entity links, labels, and calendar/timeline output.
- Trace one file through folder placement, versioning, WebDAV-style metadata, attachment to an entity, preview/OCR, permissions, and audit.
- Trace one quote-to-invoice-to-payment/refund path before calling billing/accounting ready.
