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
  notifications / audit_events / integrations / search_queries / saved_views
  record_revisions / entity_relationships / merge_jobs
  accounts / contacts / address_books
  issues / issue_relationships
  content_types / content_entries / content_revisions / routes
  workflow_definitions / workflow_runs / workflow_transition_events / approval_requests
  conversation_groups / conversations / messages / message_threads / message_reactions
  calendar_collections / activities / activity_participants / activity_alarms
  folders / files / file_versions / file_links
  quotes / invoices / payments / credits / ledger_accounts / ledger_entries
```

Use separate tables only when the subtype needs distinct validation, lifecycle, permissions, integrations, or high-volume indexes. Otherwise use a typed row plus metadata.

The hierarchy abbreviates always-on platform/kernel objects; see `app-stack/platform-kernel.md` for the full notification, audit, import/export, integration, search, report, form, settings, job, and retention model.

For cross-object relationships, default to generic link tables with `entity_type` and `entity_id`. Use typed join tables only for high-volume, referentially critical, permission-critical, or heavily indexed relationships. Model cardinality, inverse labels, merge handling, and history using `app-stack/data-history-relationships.md`.

## Slugs, routes, and hierarchy

Use stable IDs for identity. Use slugs and routes for human-readable addressing.

| Concept | Standard meaning |
|---------|------------------|
| `slug` | URL-safe local segment or human-readable key, e.g. `about-us`; not a primary key and not necessarily a full path |
| `path` | Full route/permalink path, e.g. `/company/about-us` |
| `routes` / `content_routes` | URL ownership, canonical target, redirects, previews, locale, and publication state |
| `parent_id` | Single-parent hierarchy for pages, folders, terms, menu items, issues, teams, or accounts when needed |
| `sort_order` | Sibling ordering within the same parent/container |

Slug rules:

- Do not use slugs as primary keys. Store stable IDs and treat slugs as mutable display/routing fields.
- Scope slug uniqueness by workspace plus parent/container plus locale/type, e.g. `(workspace_id, parent_id, slug, locale)`.
- Preserve old slugs as redirect rows when public URLs change.
- Use `slug` for a segment; use `path` on `routes` for the full permalink.

Hierarchy rules:

- Default to an adjacency list: nullable `parent_id`, `sort_order`, and a cycle-prevention check in application/service code.
- Add `depth`, `path`, or materialized-path/cache columns only for fast breadcrumbs, URL generation, tree queries, or sync.
- Add closure tables such as `term_ancestors` or `folder_ancestors` only for deep trees, inherited permissions, or high-volume ancestor queries.
- Parent-child hierarchy is not permission inheritance unless the product explicitly defines inheritance and tests it.
- Use assignment/link tables instead of `parent_id` for many-to-many grouping.

## Universal labels and tags

Every durable object type should be label/tag capable unless there is a deliberate product reason not to expose it.

Prefer a governed label model for important records:

- `label_groups`: workspace, key, name, description, exclusive-per-entity flag, sort order, archived state.
- `labels`: workspace, group, key, value, name, color, description, visibility, archived state.
- `label_assignments`: workspace, label, entity type, entity ID, assigned by, assigned at.
- Optional typed join tables for high-volume or referentially critical objects.

`label_group_definitions` and `label_definitions` are reusable metadata templates/catalog rows. `label_groups` and `labels` are workspace/runtime rows. If a product has no template layer, use only the runtime rows.

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
- Labels via `label_assignments`; entity-scoped messages, activity, files, and audit via shared collaboration objects.

Treat external URLs and paths as sensitive integration metadata: strip credentials and transient query tokens, prefer opaque provider IDs for matching, and avoid exposing private/local paths in public exports or support artifacts.

Support issue relationships:

- `blocks`, `blocked_by`, `duplicates`, `duplicated_by`, `relates_to`, `split_from`, `supersedes`.

Use `issues` for user-visible work, defects, support requests, and change requests. Use `activities` with `activity_type = task` for calendar/todo items. Add a separate task/checklist table only when task-specific lifecycle, nesting, or execution queues justify it.

## Content, posts, and pages

Use WordPress for full editorial/CMS sites where editors need the WordPress ecosystem. In product apps or custom portals, use an app-native content model that mirrors the useful post/post-type/page concepts without adopting WordPress table names.

WordPress concept mapping:

| WordPress concept | App-stack object |
|-------------------|------------------|
| Post type | `content_types` |
| Post/page/custom post record | `content_entries` |
| Slug/post name | `slug` field scoped to parent/container/locale/type |
| Page URL/permalink | `routes` or `content_routes` with full `path` |
| Revisions | `content_revisions` |
| Blocks/patterns | `content_blocks` |
| Categories/tags/custom taxonomies | `taxonomies`, `terms`, `term_assignments` |
| Media library item | `files` with `file_links` |
| Menus | `menus`, `menu_items` |
| SEO fields | `seo_metadata` linked to content/routes |

Core model:

| Object | Purpose |
|--------|---------|
| `content_types` | Editorial/domain content type: page, post, article, help doc, landing page, product page |
| `content_entries` | Typed content record with title, slug, status, owner, locale, dates, summary/body |
| `content_revisions` | Immutable revisions with editor, diff/source snapshot, reason, publish metadata |
| `content_blocks` | Structured page sections or rich-content blocks ordered within an entry/revision |
| `routes` / `content_routes` | Full URL path/permalink, local slug/segment when useful, parent route, canonical target, redirects, locale, route status |
| `taxonomies` | Content classification vocabularies such as category, tag, topic, audience; includes hierarchy and navigation policy |
| `terms` | Values inside a taxonomy, e.g. News, AI, Developers; include slug, description, SEO metadata, and optional `parent_id` |
| `term_assignments` | Entry-to-term assignments with sort/context metadata |
| `menus` / `menu_items` | Navigation structures independent of content storage |
| `seo_metadata` | Title, description, robots, canonical URL, social cards, structured-data hints |

Rules:

- Pages and posts are content entries with different `content_type` values by default; use separate tables only for distinct lifecycle, validation, or performance needs.
- Use `routes` for URL ownership so full paths, redirects, previews, and localized routes do not become hidden fields on unrelated tables.
- Use `slug` for the local content or route segment; use route `path` for the full permalink.
- Use workflows for draft/review/approved/published/archived lifecycles; labels can mirror editorial status but are not the source of truth.
- Use files/file links for media assets; do not create a separate media-blob system for content.
- Use metadata field definitions when content types are editor-configurable; use migrations for core product content tables.
- Use taxonomies/terms for content classification. Use labels for cross-object operational grouping such as `status:normal` or `priority:high`. Only use labels as content tags in deliberately simple flat-tag products with no taxonomy hierarchy, term metadata, or editorial taxonomy UI.

Category/tag taxonomy rules:

- Category-style taxonomies are hierarchical, navigational, and high-level. Use them for primary site/app information architecture, menus, archive pages, breadcrumbs, and broad editorial grouping.
- Tag-style taxonomies are flat keyword/topic facets. Use them for long-tail discovery, search/filtering, related-content matching, and SEO topic coverage.
- Model taxonomy behaviour explicitly with fields such as `is_hierarchical`, `is_navigational`, `has_public_archive`, `allows_multiple`, and `term_description_required`.
- Term descriptions should be editorial content, not keyword stuffing. For public archive pages, a 150-300 character description is a useful default target.
- If term descriptions render on public pages, support safe internal links to relevant canonical content or related terms, with validation/sanitisation and no raw HTML bypass.

Choose WordPress instead when routine editors need posts/pages/media library/revisions/forms/SEO plugins/themes/plugin ecosystem more than product-specific app integration.

## Workflows and automations

Use workflows for repeatable state machines and business processes. Do not hide workflow state in labels, UI-only conditionals, or ad-hoc background jobs.

Core model:

| Object | Purpose |
|--------|---------|
| `workflow_definitions` | Workflow key, version, entity scope, trigger model, active/draft/archived state |
| `workflow_state_definitions` | Initial, normal, terminal, cancelled, error, or approval states |
| `workflow_transition_definitions` | From/to state, label, capability, guard, validation, sort order |
| `workflow_action_definitions` | Side effects: field update, task, approval, notification, webhook, job, document, ledger post |
| `workflow_guard_definitions` | Conditions and predicates evaluated before a transition or action |
| `workflow_runs` | Runtime instance for an entity/process with current state and correlation ID |
| `workflow_transition_events` | Append-only transition history with actor, old/new state, reason, guard result |
| `approval_requests` | Human approval step, approver user/team/role, due date, delegated/rejected/approved state |
| `automation_rules` | Event/schedule triggers that start workflows or execute safe actions |
| `workflow_timers` | SLA, delay, escalation, reminder, and timeout scheduling |

Rules:

- For workflow-managed records, `workflow_runs.current_state` is authoritative. A business-record status field may denormalise current state for fast queries. For simple fixed lifecycles without a workflow engine, a typed status field can be authoritative.
- Version workflow definitions; existing runtime runs keep the definition version they started with unless migrated deliberately.
- Treat transition events as append-only audit records; never infer history only from the current state.
- Keep guards deterministic and side-effect free; actions perform side effects after guards pass.
- Model approvals as workflow steps, not as free-floating messages.
- Automation rules can start workflows, enqueue actions, or create issues/tasks, but should not bypass RBAC or RLS.
- Use outbox/job rows for webhooks, email, AI actions, document generation, ledger posting, and external integration calls.

Relationship to other objects:

- Issues track work; workflows control state and process.
- Activities log or schedule CRM/calendar events; workflows can create activities or wait for them.
- Conversations and entity-scoped messages discuss records; workflows can require or emit messages, but messages are not state.
- Labels group and filter; typed workflow state remains the source of truth.

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
- Comments default to messages in an entity-scoped conversation. Use a separate lightweight comments table only when the product deliberately does not need conversation membership, threads, read receipts, or chat features.
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
- Attachments are links to `files`, not independent binary blobs on each business table. Default to `file_links`; use `message_attachments` only for message-specific ordering, captions, or inline display metadata.
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
- Strip credentials and transient query tokens from URLs, classify sensitive source paths, prefer opaque provider IDs for joins, and avoid raw private/local paths in exportable or public-facing rows.
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
| Accounting | `ledger_accounts` / `chart_accounts`, ledger entries, journals, tax codes, reconciliation |

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
- Trace one issue through label assignment, entity-scoped message, state transition, audit event, and external-provider sync.
- Trace one content entry through type definition, route, revision, block/media link, taxonomy/label assignment, workflow, SEO metadata, and publish/preview output.
- Trace one workflow through definition, state, transition, guard, action, approval, timer, runtime event, and audit record.
- Trace one conversation message through thread replies, reactions, mentions, read receipts, attachments, audit, and retention rules.
- Trace one CRM/calendar activity through participants, alarms/reminders, recurrence, parent entity links, labels, and calendar/timeline output.
- Trace one file through folder placement, versioning, WebDAV-style metadata, attachment to an entity, preview/OCR, permissions, and audit.
- Trace one quote-to-invoice-to-payment/refund path before calling billing/accounting ready.
