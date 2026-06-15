---
description: Platform kernel object model for notifications, audit, search, imports, integrations, forms, dashboards, settings, localisation, jobs, and retention
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Platform Kernel Objects

Use these cross-cutting objects before each app invents its own notification, search, import, settings, or reporting tables. Scope durable rows by `workspace_id` unless the row is explicitly global system configuration.

## Notifications, inbox, and subscriptions

| Object | Purpose |
|--------|---------|
| `notifications` | User-visible notification row: recipient, type, message, related entity, read state, delivery state |
| `notification_preferences` | User/team/workspace preferences by channel, event type, quiet hours, digest policy |
| `notification_subscriptions` | Follow/watch records, conversations, issues, reports, saved searches, or entities |
| `notification_deliveries` | Email/push/in-app/webhook delivery attempt, provider ID, status, error, retry time |
| `inbox_items` | Unified action inbox for approvals, mentions, assignments, failed jobs, alerts |

Rules:

- Notifications are derived from events; do not use them as the source of truth for workflow state.
- Keep delivery attempts separate from notification intent so retries and provider errors are auditable.
- User search/inbox counts must respect RLS and notification preferences.

## Audit, activity, and provenance

| Object | Purpose |
|--------|---------|
| `audit_events` | Immutable security/business change ledger: actor, action, entity, before/after summary, reason |
| `activity_events` | Human-readable timeline/feed events for records and workspaces |
| `change_events` | Low-level data change stream for sync, search indexing, automation, cache invalidation |
| `provenance_records` | Source, import, AI/tool, external system, confidence, reviewer, and evidence metadata |
| `app_log_events` | Operational logs/errors tied to request/job/user/workspace context |

Rules:

- Security and compliance audit events are append-only and access-controlled.
- Activity feeds can be denormalised/read-optimised, but must link back to authoritative records.
- Capture actor, workspace, entity type, entity ID, request/job ID, IP/session where applicable, and timestamp.

## Imports, exports, and data quality

| Object | Purpose |
|--------|---------|
| `import_jobs` | Import run: source file/provider, target entity, mapping, status, counts, created by |
| `import_mappings` | Source-to-canonical field maps, transform rules, defaults, validation options |
| `import_rows` | Staged source rows with raw payload hash, parsed values, status, matched entity |
| `import_errors` | Row/cell validation, permission, duplicate, integrity, or transform errors |
| `dedupe_candidates` | Potential duplicates with confidence, evidence, decision, reviewer |
| `export_jobs` | Export run: query/scope, format, status, file link, notification preference |
| `export_files` | Links to generated files plus expiry, sensitivity, and access policy |

Rules:

- Imports stage before mutating production rows when validation/dedupe/review is needed.
- Preserve raw row hashes and mapping versions so imports can be replayed or explained.
- Exports need permission checks, audit events, expiry, and sensitivity labels.

## Integrations, sync, and webhooks

| Object | Purpose |
|--------|---------|
| `integrations` | Provider/app connection configuration and enabled state |
| `integration_accounts` | Connected external account/tenant/user metadata without secret values |
| `external_ids` | Entity-to-provider IDs, URLs, ETags, sync tokens, deleted/tombstone state |
| `sync_cursors` | Incremental sync checkpoint by provider, scope, collection, and direction |
| `sync_runs` | Sync execution, status, counts, duration, errors, initiated by |
| `webhooks` | Outbound/inbound webhook definitions, event filters, signing configuration |
| `webhook_events` | Received or outgoing event payload metadata, dedupe key, processing state |
| `outbox_events` | Reliable side-effect queue for webhooks, email, external API calls, AI/tool calls |

Rules:

- Store secret references, not secret values.
- Use idempotency keys and dedupe keys for every external event.
- External IDs are integration fields, never primary keys.

## Search, search history, and discovery

| Object | Purpose |
|--------|---------|
| `search_indexes` | Search scope/config: entities, fields, language, ranking, vector/full-text mode |
| `search_documents` | Denormalised searchable record: entity ref, title, summary, body, language, freshness |
| `search_terms` | Optional normalised term/topic catalog for suggestions and analytics |
| `search_queries` | User/workspace search history: query, filters, result count, latency, source UI |
| `search_result_events` | Impressions, clicks, opens, no-results, refinements, conversion signals |
| `saved_searches` | Named user/team/workspace searches with filters, sort, columns, alerts |
| `search_suggestions` | Curated/generated suggestions, synonyms, boosts, blocked terms |

Rules:

- Search indexes are derived data; source records remain authoritative.
- Search history can contain sensitive terms. Apply retention, privacy controls, redaction, and per-user visibility.
- Store filters separately from raw query text so saved searches and analytics can be explained.
- Vector embeddings reference search documents or files; keep model/version and sensitivity metadata.

## Views, reports, dashboards, and analytics

| Object | Purpose |
|--------|---------|
| `saved_views` | Entity list/table views: filters, columns, sort, grouping, visibility, owner |
| `filter_presets` | Reusable filter definitions for primary, boolean, text, and access-aware filters |
| `report_definitions` | Report metadata: source, measures, dimensions, filters, permissions |
| `report_runs` | Generated report run, parameters, status, result file/cache, created by |
| `dashboard_definitions` | Dashboard layout, widgets, visibility, default scope |
| `dashboard_widgets` | Widget config, data source, refresh interval, position, permissions |

Rules:

- Saved views and reports must apply RBAC/RLS at execution time, not only at creation time.
- Store definition/version separately from generated results.
- Exported reports use export/audit/sensitivity rules.

## Forms, submissions, and surveys

| Object | Purpose |
|--------|---------|
| `form_definitions` | Form key, version, target entity/action, lifecycle, access policy |
| `form_fields` | Field definitions, validation, conditional visibility, mapping to target fields |
| `form_submissions` | Submitted instance, submitter, status, source, spam/risk score, reviewed by |
| `form_submission_values` | Normalised field values or encrypted payload references |
| `survey_definitions` | Survey/questionnaire metadata, scoring, branching, anonymity policy |
| `survey_responses` | Response set, respondent, completion state, score, source |

Rules:

- Version forms before changing fields that affect stored submissions.
- Keep submitted raw payload or hash when legal/privacy policy permits; map to canonical objects through imports/workflows.
- Treat public forms as untrusted input: validation, rate limits, spam checks, and prompt-injection scanning where AI reads submissions.

## Settings, preferences, flags, and entitlements

| Object | Purpose |
|--------|---------|
| `workspace_settings` | Workspace-level configuration, defaults, feature choices |
| `user_preferences` | User locale/timezone/theme/dashboard/import/export/notification preferences |
| `system_settings` | Global platform configuration and operational defaults |
| `feature_flags` | Feature gate key, rollout state, targeting, owner, expiry |
| `entitlements` | Plan/license/capability limits by workspace/account/user |
| `usage_counters` | Metered usage by feature, period, source event, billing/export status |

Rules:

- Prefer typed columns for core settings; use JSON only for low-risk/extensible preferences.
- Feature flags need owner, reason, expiry/review date, and audit events.
- Entitlements gate capabilities; they do not replace RBAC.

## Localisation and translations

| Object | Purpose |
|--------|---------|
| `locales` | Supported locale/language, default, enabled state |
| `translation_keys` | Stable keys for UI/content/system messages |
| `translations` | Locale-specific value, source, status, reviewer, updated at |
| `localized_routes` | Locale-aware route/path mapping when route tables need separate localisation |
| `localized_content` | Content field translations when not stored as separate content entries |

Rules:

- Use stable translation keys; do not key translations by English source text when values change often.
- Route, slug, and content localisation must preserve canonical links and redirects.
- Track translation status: draft, machine, reviewed, approved, stale.

## Jobs, scheduling, and operations

| Object | Purpose |
|--------|---------|
| `jobs` | Background job instance: type, status, queue, attempts, scheduled time, payload |
| `scheduled_jobs` | Recurring schedule definitions, cron/interval, owner, enabled state |
| `job_runs` | Execution history, started/finished time, worker, result, error |
| `job_locks` | Concurrency/advisory locks and leases |
| `operation_logs` | Admin/maintenance operations, actor, scope, outcome, evidence |

Rules:

- Jobs are runtime execution records; workflows are business state machines. Link them but do not collapse them.
- Use idempotency keys and retry/backoff metadata for side effects.
- Long-running jobs should emit progress/activity events.

## Retention, archive, and compliance

| Object | Purpose |
|--------|---------|
| `retention_policies` | Entity/file/log retention rules, legal basis, purge/archive behaviour |
| `archive_records` | Archive operation record and storage reference when rows/files move cold |
| `legal_holds` | Prevent purge/archive for entities/files under hold |
| `deletion_requests` | User/customer deletion/export requests and fulfilment state |
| `redaction_events` | Field/file/message redactions with actor, reason, irreversible marker |

Rules:

- Soft delete uses `deleted_at` / `deleted_by`; archive and legal hold are separate concepts.
- Purge jobs require explicit policy, audit event, and recovery/backup awareness.
- AI/search indexes, exports, and derived files must follow source retention policies.

## Verification

- Trace one search query through saved filters, result permissions, search history retention, click/open event, and index refresh.
- Trace one import through mapping, staged rows, validation errors, dedupe review, production write, provenance, and audit.
- Trace one notification through source event, preference, delivery attempt, read state, and inbox item.
- Trace one integration through external ID, sync cursor, webhook event, outbox retry, and tombstone/delete handling.
- Trace one saved view/report/dashboard through RBAC/RLS execution and export audit.
