---
description: Per-tenant RAG pipeline architecture for multi-tenant SaaS applications
mode: subagent
model: sonnet
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

# Per-Tenant RAG Architecture

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Multi-org schema**: `services/database/multi-org-isolation.md`
- **Tenant context model**: `services/database/schemas/tenant-context.ts`
- **Multi-org schema (Drizzle)**: `services/database/schemas/multi-org.ts`
- **Cloudflare Vectorize**: `services/hosting/cloudflare-platform-skill/vectorize.md`
- **Isolation strategy**: Collection-per-tenant (physical) or namespace/metadata filtering (logical)
- **Pipeline**: Upload → Chunk → Embed → Store → Query → Rerank → LLM Context Assembly

**This document covers SaaS app development** where users/organisations upload their own documents for RAG. It is NOT for the aidevops internal memory system (SQLite FTS5) or code search (osgrep).

<!-- AI-CONTEXT-END -->

## Architecture Overview

A per-tenant RAG system must solve two problems simultaneously: (1) effective retrieval from unstructured documents, and (2) strict data isolation between tenants. Getting retrieval right but leaking data across tenants is a security incident. Getting isolation right but returning irrelevant chunks is a product failure.

### End-to-End Pipeline

```text
User uploads file (PDF/DOCX/TXT/HTML/CSV)
  → [1. Ingest]  Validate type/size/malware; store original in R2/S3 keyed by org_id
  → [2. Parse]   PDF: Docling | DOCX: mammoth | HTML: readability | CSV: papaparse | TXT: direct
  → [3. Chunk]   512-1024 tokens, 128 overlap, recursive character splitting
  → [4. Embed]   Batch 32-128 chunks; store model ID with vectors
  → [5. Store]   One collection/namespace per org_id; HNSW index
  → [6. Query]   Embed query; search ONLY tenant's collection; topK=20 candidates
  → [7. Rerank]  Cross-encoder or RRF; return top-5 with metadata
  → [8. Assemble] System prompt + chunks + query; manage token budget
```

### Stage Failure Modes

| Stage | Failure mode | Impact |
|-------|-------------|--------|
| Parse | Garbled text extraction | All downstream stages work on garbage |
| Chunk | Chunks too large or split mid-sentence | Embeddings capture noise |
| Embed | Wrong model or dimension mismatch | Queries return random results |
| Store | Wrong tenant collection | Data leak (security incident) |
| Query | No tenant filter | Cross-tenant data exposure |
| Rerank | Skipped | Irrelevant chunks, LLM hallucinates |

## Tenant Isolation Models

| Approach | Isolation level | Query overhead | Tenant limit | Best for |
|----------|----------------|---------------|-------------|----------|
| Collection-per-tenant | Physical | None | ~10K | **Default recommendation** |
| Namespace-per-tenant | Logical (partition) | Namespace filter (fast) | ~50K | Cloudflare Vectorize |
| Metadata filter | Logical (row-level) | Filter during search | Unlimited | Simple cases, few tenants |
| pgvector + RLS | Logical (DB-level) | RLS policy check | Unlimited | Already on PostgreSQL |
| Separate DB/index | Physical (full) | None | ~100 | Regulated/enterprise |

### Recommended: Collection-Per-Tenant

**Why it wins**: A query against tenant A's collection cannot return tenant B's data even with an application bug — there is no filter to forget. Creating/deleting a tenant = creating/dropping a collection. No orphaned vectors.

**When NOT to use**: >10K tenants (collection metadata overhead), tenants with <100 vectors each, or cross-tenant search is a product requirement.

### Integration with Multi-Org Schema

```text
organisations.id (UUID)
  → Vector collection: "rag_{org_id}"
  → Object storage prefix: "uploads/{org_id}/"
  → Metadata in vector store: org_id, uploaded_by, source_file, chunk_index
```

```typescript
import type { TenantContext } from './tenant-context';

async function searchDocuments(ctx: TenantContext, query: string, topK = 5): Promise<RetrievedChunk[]> {
  const collectionName = `rag_${ctx.orgId}`;
  const queryEmbedding = await embedQuery(query);
  const candidates = await vectorDb.search(collectionName, { vector: queryEmbedding, topK: topK * 4 });
  return (await rerank(query, candidates)).slice(0, topK);
}
```

**Audit logging**: Log all RAG operations (upload, delete, search) to `audit_log` with `org_id`, `userId`, `action`, and metadata.

## Pipeline Stage Details

### Stage 1: Ingest

```typescript
const DEFAULT_INGEST_CONFIG = {
  maxFileSize: 50 * 1024 * 1024,  // 50MB
  allowedTypes: ['application/pdf', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
                 'text/plain', 'text/html', 'text/csv', 'text/markdown'],
  storagePrefix: (orgId: string) => `uploads/${orgId}/`,
};
```

**Security**: Validate MIME type from magic bytes (not extension), scan for malware, set per-tenant storage quotas.

### Stage 2: Parse

| File type | Recommended parser | Notes |
|-----------|-------------------|-------|
| PDF | Docling (IBM, Apache-2.0) | Best for complex layouts, tables, figures |
| DOCX | mammoth | Preserves structure, ignores formatting |
| HTML | mozilla/readability | Extracts article content, strips nav/ads |
| CSV | papaparse | Row-per-chunk or grouped; include header as context |
| TXT/MD | Direct | Split on paragraph boundaries |

### Stage 3: Chunk

**Recommended default: 512 tokens, 128 overlap.** Most embedding models are trained on 256-512 token passages. Larger chunks dilute the embedding signal; smaller chunks lose context. 128-token overlap prevents boundary information loss.

| Strategy | Chunk size | Overlap | Best for |
|----------|-----------|---------|----------|
| Small | 256-512 tokens | 64 tokens | Precise factual retrieval (Q&A) |
| Medium | 512-1024 tokens | 128 tokens | General-purpose RAG (default) |
| Large | 1024-2048 tokens | 256 tokens | Summarisation, long-form context |
| Section-based | Variable | None | Structured documents with clear headings |

Every chunk must carry: `id` (`{document_id}_{chunk_index}`), `content`, `documentId`, `chunkIndex`, `totalChunks`, `sourceFile`, `orgId`, `uploadedBy`, `uploadedAt`, `embeddingModel`.

### Stage 4: Embed

| Model | Dimensions | Quality (MTEB) | Cost | Notes |
|-------|-----------|----------------|------|-------|
| OpenAI text-embedding-3-small | 1536 (or 512/256) | High | $0.02/1M tokens | Best quality/cost ratio |
| OpenAI text-embedding-3-large | 3072 (or 1024/256) | Highest | $0.13/1M tokens | Quality-critical |
| Jina v3 | 1024 (Matryoshka to 256) | High | $0.02/1M tokens | Multilingual |
| Sentence Transformers (local) | 384 | Good | Free (compute) | No API dependency |
| Cloudflare Workers AI bge-base | 768 | Good | Included in Workers | Cloudflare-native |
| BM25 (sparse, local) | Vocabulary-sized | N/A (lexical) | Free | Hybrid search complement |

**Matryoshka embeddings**: Models like OpenAI text-embedding-3-small and Jina v3 support truncating dimensions (1536→512→256) with ~2-5% recall loss. Use when storage cost matters.

**Critical rule**: Store the embedding model ID with every vector. When you change models, old vectors are incompatible with new query embeddings — you must re-embed all existing vectors or maintain separate collections per model version.

### Stage 5: Store

**HNSW parameters by tenant size**:

| Tenant size | M | ef_construction | ef_search |
|------------|---|----------------|-----------|
| <10K vectors | 16 | 100 | 50 |
| 10K-100K | 16 | 200 | 100 |
| 100K-1M | 32 | 200 | 150 |
| >1M | 48 | 400 | 200 |

**Index configuration by vector DB**:

| Vector DB | Tenant isolation | Index type |
|-----------|-----------------|------------|
| zvec | Collection per org | HNSW (default), IVF |
| Cloudflare Vectorize | Namespace per org | Managed |
| pgvector | RLS policy on org_id | IVF or HNSW |
| Qdrant | Collection per org | HNSW |

### Stage 6: Query

```typescript
async function queryTenantRAG(ctx: TenantContext, query: string, config = DEFAULT_QUERY_CONFIG) {
  const collectionName = `rag_${ctx.orgId}`;
  if (!await vectorDb.collectionExists(collectionName)) throw new TenantError('RAG_NOT_ENABLED', ctx.orgId);

  const queryEmbedding = await embed(query, getCollectionModel(collectionName));

  let results: ScoredChunk[];
  if (config.hybrid) {
    const [denseResults, sparseResults] = await Promise.all([
      vectorDb.search(collectionName, { vector: queryEmbedding, topK: config.candidateCount }),
      vectorDb.searchSparse(collectionName, { query, topK: config.candidateCount }),
    ]);
    results = reciprocalRankFusion(denseResults, sparseResults, config.hybridAlpha);
  } else {
    results = await vectorDb.search(collectionName, { vector: queryEmbedding, topK: config.candidateCount });
  }
  return results.filter(r => r.score >= config.minScore);
}
```

**Default config**: `candidateCount: 20`, `minScore: 0.3`, `hybrid: false`, `hybridAlpha: 0.7`.

**Use hybrid search when**: Users search for specific terms/names/codes that semantic search misses, or documents contain domain-specific jargon.

### Stage 7: Rerank

Reranking is the highest-ROI improvement to a RAG pipeline — typically improves answer quality by 10-30%.

| Strategy | Accuracy | Latency | Cost | When to use |
|----------|----------|---------|------|-------------|
| Cross-encoder | Highest | 50-200ms/20 candidates | API or GPU | Production, quality-critical |
| RRF | Good | <1ms | Free | Hybrid search result merging |
| Weighted scoring | Moderate | <1ms | Free | Simple cases, metadata boosting |
| None | Baseline | 0ms | Free | Prototyping only |

```typescript
// Cross-encoder
async function rerankWithCrossEncoder(query: string, candidates: ScoredChunk[], topK = 5) {
  const pairs = candidates.map(c => ({ query, document: c.content, ...c }));
  return (await crossEncoder.rank(pairs)).sort((a, b) => b.score - a.score).slice(0, topK);
}

// RRF for hybrid search
function reciprocalRankFusion(denseResults: ScoredChunk[], sparseResults: ScoredChunk[], alpha: number, k = 60) {
  const scores = new Map<string, number>();
  const chunks = new Map<string, ScoredChunk>();
  denseResults.forEach((c, rank) => { scores.set(c.id, (scores.get(c.id) ?? 0) + alpha / (k + rank + 1)); chunks.set(c.id, c); });
  sparseResults.forEach((c, rank) => { scores.set(c.id, (scores.get(c.id) ?? 0) + (1 - alpha) / (k + rank + 1)); if (!chunks.has(c.id)) chunks.set(c.id, c); });
  return Array.from(scores.entries()).sort(([, a], [, b]) => b - a).map(([id, score]) => ({ ...chunks.get(id)!, score }));
}
```

### Stage 8: LLM Context Assembly

```typescript
function assembleContext(query: string, chunks: ScoredChunk[], config: ContextAssemblyConfig): string {
  let budget = config.modelMaxTokens - config.responseReserve - countTokens(config.systemPrompt) - countTokens(query) - 100;
  const includedChunks: string[] = [];

  for (const chunk of chunks) {
    const content = chunk.content + (config.includeAttribution
      ? `\n[Source: ${chunk.metadata.sourceFile}, p.${chunk.metadata.pageNumber ?? '?'}]` : '');
    const tokens = countTokens(content) + (includedChunks.length > 0 ? countTokens('\n\n---\n\n') : 0);
    if (tokens > budget) break;
    includedChunks.push(content);
    budget -= tokens;
  }

  return [config.systemPrompt, '', '## Retrieved Context', '', includedChunks.join('\n\n---\n\n'), '', '## User Question', '', query].join('\n');
}
```

**Token budget (128K model)**: System prompt 500-2000 | Retrieved chunks 4000-16000 | User query 50-500 | Response reserve 2000-4000.

## Tenant Lifecycle

### Onboarding

```typescript
async function onboardTenantRAG(ctx: TenantContext, config?: Partial<EmbeddingConfig>) {
  const collectionName = `rag_${ctx.orgId}`;
  const embeddingConfig = { ...DEFAULT_EMBEDDING_CONFIG, ...config };

  await vectorDb.createCollection(collectionName, {
    dimension: embeddingConfig.dimensions, metric: 'cosine',
    indexType: 'hnsw', hnswConfig: { m: 16, efConstruction: 100 },
  });

  await db.update(organisations).set({
    settings: sql`jsonb_set(COALESCE(settings, '{}'), '{rag}', ${JSON.stringify({
      enabled: true, embeddingModel: embeddingConfig.modelId,
      dimensions: embeddingConfig.dimensions, createdAt: new Date().toISOString(),
    })}::jsonb)`,
  }).where(eq(organisations.id, ctx.orgId));

  await db.insert(auditLog).values({ orgId: ctx.orgId, userId: ctx.userId,
    action: 'rag:tenant_onboarded', entityType: 'rag_collection',
    metadata: { collectionName, embeddingModel: embeddingConfig.modelId, dimensions: embeddingConfig.dimensions } });
}
```

### Deletion

```typescript
async function offboardTenantRAG(ctx: TenantContext) {
  const collectionName = `rag_${ctx.orgId}`;
  await vectorDb.deleteCollection(collectionName);
  await objectStorage.deletePrefix(`uploads/${ctx.orgId}/`);
  await db.update(organisations).set({ settings: sql`settings - 'rag'` }).where(eq(organisations.id, ctx.orgId));
  await db.insert(auditLog).values({ orgId: ctx.orgId, userId: ctx.userId,
    action: 'rag:tenant_offboarded', entityType: 'rag_collection', metadata: { collectionName } });
}
```

**Deletion guarantees**: Collection deletion is atomic. Object storage deletion must handle pagination (list + delete in batches). Audit log persists after deletion (compliance). Trigger RAG cleanup in a `beforeDelete` hook if org deletion cascades.

## Cross-Tenant Search Prevention

**Layer 1 (primary)**: Collection-per-tenant — queries are physically scoped. No filter to forget.

**Layer 2 (application)**:
```typescript
// NEVER: collection name from user input
// ALWAYS: collection name from authenticated context
app.post('/api/search', async (req, res) => {
  const collection = `rag_${req.tenant.orgId}`;  // Derived from auth, not req.body
  const results = await vectorDb.search(collection, ...);
});
```

**Layer 3 (belt-and-suspenders)**:
```typescript
function validateTenantOwnership(results: ScoredChunk[], orgId: string): ScoredChunk[] {
  return results.filter(r => {
    if (r.metadata.orgId !== orgId) {
      logger.error('CROSS_TENANT_LEAK_DETECTED', { requestingOrg: orgId, resultOrg: r.metadata.orgId, chunkId: r.id });
      return false;
    }
    return true;
  });
}
```

**Layer 4 (testing)**:
```typescript
it('cannot retrieve vectors from another tenant', async () => {
  await uploadDocument(tenantA, 'secret-plans.pdf');
  await uploadDocument(tenantB, 'public-info.pdf');
  const results = await searchDocuments(tenantAContext, 'secret plans');
  expect(results.filter(r => r.metadata.orgId === tenantB.orgId)).toHaveLength(0);
});
```

## Storage Sizing Per Tenant

### Vector Storage Estimation

| Component | Size per vector |
|-----------|----------------|
| Dense embedding (1536d, float32) | 6,144 bytes |
| Dense embedding (384d, float32) | 1,536 bytes |
| Metadata (typical) | 500-2,000 bytes |
| Content text (512 tokens) | ~2,000 bytes |
| HNSW index overhead | ~200-800 bytes |
| **Total per vector (1536d)** | **~9-10 KB** |
| **Total per vector (384d)** | **~4-5 KB** |

| Tenant profile | Chunks (est.) | Storage (1536d) | Storage (384d) |
|---------------|--------------|----------------|----------------|
| Small (100 docs, 50 pages avg) | ~25K | ~250 MB | ~125 MB |
| Medium (1,000 docs) | ~250K | ~2.5 GB | ~1.25 GB |
| Large (10,000 docs) | ~2.5M | ~25 GB | ~12.5 GB |

### Per-Tenant Quotas

```typescript
const PLAN_QUOTAS: Record<OrgPlan, TenantRAGQuotas> = {
  free:       { maxDocuments: 50,      maxStorageBytes: 100 * 1024 * 1024,         maxFileSize: 10 * 1024 * 1024,   maxVectors: 10_000 },
  pro:        { maxDocuments: 5_000,   maxStorageBytes: 5 * 1024 * 1024 * 1024,    maxFileSize: 50 * 1024 * 1024,   maxVectors: 500_000 },
  enterprise: { maxDocuments: 100_000, maxStorageBytes: 100 * 1024 * 1024 * 1024,  maxFileSize: 200 * 1024 * 1024,  maxVectors: 10_000_000 },
};
```

### Cost Optimisation

1. **Matryoshka dimensions** — 512d instead of 1536d saves 3x storage with ~3% recall loss
2. **Local embedding models** — eliminate per-token API costs for high-volume tenants
3. **Lazy embedding** — embed on first query, not on upload (if upload volume >> query volume)
4. **INT8 quantization** — 4x storage reduction with ~1% recall loss (zvec, Qdrant)
5. **TTL on unused vectors** — auto-delete chunks from documents not queried in 90+ days

## Implementation Checklist

- [ ] **Isolation**: Collection/namespace derived from `TenantContext.orgId`, never from user input
- [ ] **Lifecycle**: Tenant onboarding creates collection; tenant deletion destroys it
- [ ] **Embedding model tracked**: Model ID stored with every vector for re-embedding compatibility
- [ ] **Quotas enforced**: Per-plan limits on documents, storage, and vectors
- [ ] **Audit logged**: Upload, delete, and search operations logged with org_id
- [ ] **Cross-tenant test**: Integration test verifying tenant A cannot see tenant B's data
- [ ] **Reranking enabled**: Cross-encoder or RRF for production quality
- [ ] **Token budget managed**: Context assembly respects model limits
- [ ] **Source attribution**: Retrieved chunks include file name and page/section reference
- [ ] **Error handling**: Graceful degradation when vector DB is unavailable
- [ ] **Monitoring**: Per-tenant metrics for vector count, query latency, and storage usage
