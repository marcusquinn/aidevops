<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare AI Search — Gotchas & Troubleshooting

## Indexing

- **R2 source only**: AI Search indexes R2 buckets or websites — not D1, KV, or arbitrary APIs.
- **File size limits**: Individual files must be under the documented size limit; oversized files are silently skipped.
- **Supported formats**: Only supported MIME types are indexed. Unsupported files are ignored without error.
- **Stale index**: Content updates in R2 are not instant — re-indexing is triggered on a schedule or manually. Monitor via Dashboard → Overview.
- **Vectorize quota**: AI Search uses Vectorize under the hood. Check Vectorize index limits if indexing stalls.

## Authentication

- **Token scope**: Use `AI Search - Read` for queries; `AI Search Edit` for index management. Wrong scope returns 403.
- **Token expiry**: Service API tokens do not auto-rotate. Expired tokens cause silent query failures — monitor token validity.
- **Workers binding vs REST**: Workers binding (`env.AI.autorag(...)`) uses the account's AI token automatically. REST API requires an explicit `Authorization: Bearer` header.

## Querying

- **Empty results ≠ no data**: Low `score_threshold` values (default 0.3) may return irrelevant results; high values may return nothing. Tune per use case.
- **`rewrite_query` cost**: Enabling `rewrite_query: true` adds an LLM call — increases latency and token cost.
- **Streaming responses**: `stream: true` returns a `ReadableStream`. Consuming it incorrectly (e.g., `await response.json()`) will throw. Use `response.body` reader.
- **Folder filter syntax**: Filters use exact prefix matching on the `folder` metadata field. Trailing slash required: `tenants/abc/` not `tenants/abc`.

## Dashboard

- **Playground ≠ production**: Playground queries use dashboard credentials, not your app's API token. Test token permissions separately.
- **Instance names**: AutoRAG instance names are immutable after creation. Choose names carefully — renaming requires deleting and recreating.

## Configuration via Dashboard

```
Dashboard → AI Search → Create
→ Choose data source (R2 bucket or Website)
→ Configure settings → Create
```

```
AI Search → Select instance → Use AI Search → API
→ Create API Token
→ Permissions: "AI Search - Read", "AI Search Edit"
```
