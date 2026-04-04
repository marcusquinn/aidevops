<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Vectorize Patterns & Integration

## Workers AI

```typescript
const embeddings = await ai.run("@cf/baai/bge-base-en-v1.5", { text: [userQuery] });
// Pass embeddings.data[0], NOT embeddings or embeddings.data
const matches = await env.VECTORIZE.query(embeddings.data[0], { topK: 3, returnMetadata: "all" });
```

**Common models**: `@cf/baai/bge-base-en-v1.5` (768d), `@cf/baai/bge-large-en-v1.5` (1024d), `@cf/baai/bge-small-en-v1.5` (384d)

## OpenAI

```typescript
const response = await openai.embeddings.create({ model: "text-embedding-ada-002", input: userQuery });
// Pass response.data[0].embedding, NOT response
const matches = await env.VECTORIZE.query(response.data[0].embedding, { topK: 5 });
```

## RAG Pattern

```typescript
// 1. Generate query embedding
const embeddings = await env.AI.run("@cf/baai/bge-base-en-v1.5", { text: [query] });
// 2. Search Vectorize
const matches = await env.VECTORIZE.query(embeddings.data[0], { topK: 5, returnMetadata: "all" });
// 3. Fetch full documents from R2/D1/KV
const documents = await Promise.all(matches.matches.map(m => env.R2_BUCKET.get(m.metadata?.r2_key).then(o => o?.text())));
// 4. Generate response with context
const llmResponse = await env.AI.run("@cf/meta/llama-3-8b-instruct", {
  prompt: `Context: ${documents.filter(Boolean).join("\n\n")}\n\nQuestion: ${query}\n\nAnswer:`
});
```

## Multi-Tenant Architecture

```typescript
// Option 1: Separate indexes per tenant (if < 50K tenants)
const tenantIndex = env[`VECTORIZE_${tenantId.toUpperCase()}`];

// Option 2: Namespaces (up to 50K, fastest)
await env.VECTORIZE.insert([{ id: "doc-1", values: [...], namespace: `tenant-${tenantId}` }]);
const matches = await env.VECTORIZE.query(queryVector, { namespace: `tenant-${tenantId}` });

// Option 3: Metadata filtering (flexible but slower)
const matches = await env.VECTORIZE.query(queryVector, { filter: { tenantId } });
```

## Performance Optimization

### Write Throughput

Vectorize batches up to 200K vectors OR 1000 operations per job. Batch size matters:

```typescript
// BAD: 250,000 individual inserts = 250 jobs = ~1 hour
for (const vector of vectors) { await env.VECTORIZE.insert([vector]); }

// GOOD: 100 batches of 2,500 = 2-3 jobs = minutes
for (let i = 0; i < vectors.length; i += 2500) {
  await env.VECTORIZE.insert(vectors.slice(i, i + 2500));
}
```

### Query Performance

- `returnValues: true` -> high-precision scoring (slower, topK max 20)
- Default -> approximate scoring (faster, topK max 100)
- Namespace filters applied first (fastest); high-cardinality range queries degrade performance
- Track mutations: `npx wrangler vectorize info <index-name>` (compare `processedUpToMutation` with insert `mutationId`)
