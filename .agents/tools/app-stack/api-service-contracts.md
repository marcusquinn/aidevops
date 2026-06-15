---
description: API, service, validation, error, pagination, idempotency, and webhook contract standards for app backends
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# API and Service Contracts

APIs are product contracts. Standardise request/response shapes, validation, errors, pagination, filtering, idempotency, and service boundaries before adding many endpoints.

## Contract objects

| Object | Purpose |
|--------|---------|
| `api_clients` | Registered internal/external clients, owner, scopes, rate limits, enabled state |
| `api_keys` | Hashed key records, prefix, scopes, expiry, last used, rotation state |
| `service_accounts` | Non-human actor used by integrations, automations, jobs, and imports |
| `idempotency_keys` | Request key, actor/client, operation, request hash, result reference, expiry |
| `api_request_logs` | Minimal request audit: actor, route, status, duration, target, correlation ID |
| `error_events` | Normalised operational/application errors with severity, fingerprint, and owner |

Rules:

- Shared validation schemas live in domain/API packages and run at API and service boundaries.
- Prefer typed service functions for app code; HTTP/RPC routes adapt transport to service contracts.
- Do not expose database rows directly. Use DTOs with explicit field privacy and expansion rules.
- Mutating endpoints need idempotency for external clients, retries, imports, webhooks, and payment-like operations.
- Request logs must minimise payload data and redact secrets, tokens, private URLs, and sensitive fields.

## Route and DTO conventions

| Concern | Standard |
|---------|----------|
| Identity | Stable ID in URLs; slugs/paths are routing helpers, not identity |
| Pagination | Cursor pagination by default for large/mutable collections; offset only for small/admin lists |
| Filtering | Typed filter schema; no raw SQL/filter expressions from clients |
| Sorting | Allowlist sort fields and deterministic tie-breaker by stable ID |
| Field selection | Explicit includes/expands; apply RBAC/RLS and field privacy after expansion |
| Errors | Stable error code, message, details, correlation ID, retryability, documentation key |
| Versioning | Version breaking contracts; keep service/domain internals separately evolvable |

Rules:

- List APIs return `items`, `pageInfo`, applied filters/sort, and permission-aware counts only when counts are cheap/safe.
- Write APIs return the canonical saved object, revision/version, and audit/provenance reference when useful.
- Validation errors identify field paths and machine-readable reason codes.
- Use correlation IDs through API, jobs, workflows, outbox events, logs, and audit events.

## Webhook and integration contracts

| Object | Purpose |
|--------|---------|
| `webhooks` | Endpoint/subscription definition, events, target, signing, enabled state |
| `webhook_events` | Inbound/outbound event metadata, status, attempts, dedupe key, next attempt |
| `webhook_deliveries` | Delivery attempts with status, response summary, latency, retry time |
| `event_subscriptions` | Internal event subscribers and filters for jobs, search, sync, and automation |

Rules:

- Use signed webhook payloads, timestamp tolerance, replay protection, and event IDs.
- Persist incoming events before processing and dedupe by provider/event/scope.
- Outbound webhooks use `outbox_events`, retry/backoff, delivery logs, and operator replay controls.
- Webhook payloads use public contract DTOs, not internal table shape.

## Public developer surfaces

- `/api` explains API status, base URLs, auth, versioning, rate limits, SDKs, schemas, and support.
- API reference should be generated from OpenAPI/RPC metadata when possible; prose docs cover concepts and examples.
- `/mcp` documents MCP server URL, tool catalog, auth/scopes, safety rules, and agent examples when an MCP server exists.
- `/cli` documents CLI install, auth, command groups, examples, updates, and support when a CLI exists.
- MCP and CLI integrations use the same service contracts, permissions, audit, rate limits, and idempotency rules as the API.
- Keep `/api`, `/mcp`, and `/cli` stable even if they redirect to docs sections.

## Package defaults

- `packages/api` owns route adapters, transport-specific middleware, API DTOs, and OpenAPI/RPC metadata.
- `packages/domain` owns service contracts, business validation, permissions orchestration, and error taxonomy.
- `packages/sdk` owns typed clients and generated/handwritten API helpers for web/mobile/desktop/extension surfaces.
- `packages/db` stays behind repositories/services; UI and SDK code do not import DB schema directly.

## Verification

- Trace one list route through filter validation, RLS/RBAC, cursor pagination, field expansion, and response DTO.
- Trace one mutation through idempotency key, validation, service call, audit event, outbox/job enqueue, and response.
- Trace one webhook from signature validation to persisted event, dedupe, job processing, retry, and delivery log.
- Confirm `/api`, `/mcp`, and `/cli` pages match implemented endpoints, tools, auth, scopes, and examples.
- Confirm errors are stable, documented, retry-aware, and do not leak internals or secrets.
