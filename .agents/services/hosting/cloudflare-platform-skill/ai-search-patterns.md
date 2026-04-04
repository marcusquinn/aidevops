<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# AutoRAG AI Search Patterns

Use cases: enterprise search, customer support chat, knowledge bases, multitenancy SaaS (folder filters), content discovery.

## Workers Binding (Recommended)

**wrangler.toml** or **wrangler.jsonc:**

```toml
[ai]
binding = "AI"
```

```jsonc
{ "ai": { "binding": "AI" } }
```

### AI Search with Generation

```typescript
const answer = await env.AI.autorag("my-autorag").aiSearch({
  query: "How do I configure rate limits?",
  model: "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
  rewrite_query: true,
  max_num_results: 10,
  ranking_options: { score_threshold: 0.3 },
  reranking: { enabled: true, model: "@cf/baai/bge-reranker-base" },
  stream: true
});
```

### Search Only (no generation)

```typescript
const results = await env.AI.autorag("my-autorag").search({
  query: "rate limiting configuration",
  max_num_results: 5,
  ranking_options: { score_threshold: 0.4 },
  reranking: { enabled: true, model: "@cf/baai/bge-reranker-base" }
});
// results.data[].content, results.data[].filename, results.data[].score
```

### Folder Filter (multitenancy)

```typescript
const answer = await env.AI.autorag("my-autorag").aiSearch({
  query: userQuery,
  filters: { type: "eq", field: "folder", value: `tenants/${tenantId}/` }
});
```

## REST API (Alternative)

Use when Workers binding is unavailable or for server-side calls.

```typescript
const response = await fetch(
  "https://api.cloudflare.com/client/v4/accounts/{account_id}/autorag/rags/{autorag_name}/ai-search",
  {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${AI_SEARCH_TOKEN}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      query: "How do I configure rate limits?",
      model: "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
      rewrite_query: true,
      max_num_results: 10
    })
  }
);
const { result } = await response.json();
```

**Token permissions:** `AI Search - Read` (search/aiSearch), `AI Search Edit` (index management).
