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

**Scope**: SaaS apps where users/organisations upload documents for RAG. NOT for aidevops internal memory (SQLite FTS5) or code search (osgrep).

<!-- AI-CONTEXT-END -->

## End-to-End Pipeline

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

| Stage | Failure mode | Impact |
|-------|-------------|--------|
| Parse | Garbled text extraction | All downstream garbage |
| Chunk | Too large / mid-sentence split | Embeddings capture noise |
| Embed | Wrong model or dimension mismatch | Random results |
| Store | Wrong tenant collection | **Data leak** |
| Query | No tenant filter | **Cross-tenant exposure** |
| Rerank | Skipped | Irrelevant chunks, hallucination |

## Tenant Isolation

| Approach | Isolation | Overhead | Limit | Best for |
|----------|----------|----------|-------|----------|
| Collection-per-tenant | Physical | None | ~10K | **Default** |
| Namespace-per-tenant | Logical (partition) | Filter (fast) | ~50K | Cloudflare Vectorize |
| Metadata filter | Logical (row-level) | Filter on search | Unlimited | Few tenants |
| pgvector + RLS | Logical (DB-level) | RLS check | Unlimited | Already on PostgreSQL |
| Separate DB/index | Physical (full) | None | ~100 | Regulated/enterprise |

**Recommended: Collection-per-tenant.** Queries against tenant A's collection cannot return tenant B's data even with application bugs — no filter to forget. **When NOT to use**: >10K tenants, tenants with <100 vectors, or cross-tenant search required.

**Naming convention**: Collection `rag_{org_id}`, object storage `uploads/{org_id}/`. Metadata on every vector: `org_id`, `uploaded_by`, `source_file`, `chunk_index`.

### Cross-Tenant Prevention (Defence in Depth)

**Layer 1 — Physical**: Collection-per-tenant scopes queries physically.

**Layer 2 — Application**: Collection name from authenticated context, never user input:

```typescript
app.post('/api/search', async (req, res) => {
  const collection = `rag_${req.tenant.orgId}`;  // From auth, not req.body
  const results = await vectorDb.search(collection, ...);
});
```

**Layer 3 — Validation**: Post-query ownership check logs `CROSS_TENANT_LEAK_DETECTED` and filters results where `metadata.org_id !== requesting org_id`.

**Layer 4 — Testing**: Integration test verifying tenant A cannot see tenant B's data after both upload documents.

**Audit logging**: Log all RAG operations (upload, delete, search) to `audit_log` with `org_id`, `userId`, `action`, metadata.

## Pipeline Stage Details

### Stages 1-2: Ingest and Parse

Validate MIME from magic bytes (not extension), scan for malware, enforce per-tenant quotas. Default max 50MB (overridden by plan quotas: `effectiveMaxFileSize = min(globalCap, planCap)`). Parsers: PDF→Docling, DOCX→mammoth, HTML→readability, CSV→papaparse, TXT/MD→direct paragraph split.

### Stage 3: Chunk

**Default: 512 tokens, 128 overlap.** Sizes: 256-512 (Q&A), 512-1024 (general, default), 1024-2048 (summarisation), variable/section-based (structured docs).

Required chunk metadata: `id` (`{document_id}_{chunk_index}`), `content`, `documentId`, `chunkIndex`, `totalChunks`, `sourceFile`, `orgId`, `uploadedBy`, `uploadedAt`, `embeddingModel`.

### Stage 4: Embed

| Model | Dims | Quality | Cost | Notes |
|-------|------|---------|------|-------|
| OpenAI text-embedding-3-small | 1536 (or 512/256) | High | $0.02/1M tok | Best quality/cost |
| OpenAI text-embedding-3-large | 3072 (or 1024/256) | Highest | $0.13/1M tok | Quality-critical |
| Jina v3 | 1024 (Matryoshka→256) | High | $0.02/1M tok | Multilingual |
| Sentence Transformers (local) | 384 | Good | Free | No API dependency |
| Cloudflare Workers AI bge-base | 768 | Good | Included | Cloudflare-native |
| BM25 (sparse, local) | Vocab-sized | Lexical | Free | Hybrid complement |

**Matryoshka embeddings**: Truncate dimensions (1536→512→256) with ~2-5% recall loss. Use when storage cost matters.

**Critical**: Store embedding model ID with every vector. Model changes make old vectors incompatible — re-embed or maintain separate collections per model version.

### Stage 5: Store

**HNSW tuning**: <10K→M:16/ef_c:100/ef_s:50, 10K-100K→16/200/100, 100K-1M→32/200/150, >1M→48/400/200.

**Vector DBs**: zvec (collection/org, HNSW/IVF), Cloudflare Vectorize (namespace/org, managed), pgvector (RLS on org_id, IVF/HNSW), Qdrant (collection/org, HNSW).

### Stage 6: Query

```typescript
async function queryTenantRAG(ctx: TenantContext, query: string, config = DEFAULT_QUERY_CONFIG) {
  const collectionName = `rag_${ctx.orgId}`;
  if (!await vectorDb.collectionExists(collectionName)) throw new TenantError('RAG_NOT_ENABLED', ctx.orgId);
  const queryEmbedding = await embed(query, getCollectionModel(collectionName));

  let results: ScoredChunk[];
  if (config.hybrid) {
    const [dense, sparse] = await Promise.all([
      vectorDb.search(collectionName, { vector: queryEmbedding, topK: config.candidateCount }),
      vectorDb.searchSparse(collectionName, { query, topK: config.candidateCount }),
    ]);
    results = reciprocalRankFusion(dense, sparse, config.hybridAlpha);
  } else {
    results = await vectorDb.search(collectionName, { vector: queryEmbedding, topK: config.candidateCount });
  }
  return results.filter(r => r.score >= config.minScore);
}
```

**Defaults**: `candidateCount: 20`, `minScore: 0.3`, `hybrid: false`, `hybridAlpha: 0.7`. Enable hybrid when users search specific terms/names/codes or documents contain domain jargon.

### Stage 7: Rerank

Highest-ROI improvement — typically 10-30% answer quality gain.

| Strategy | Accuracy | Latency | Cost |
|----------|----------|---------|------|
| Cross-encoder | Highest | 50-200ms/20 candidates | API/GPU |
| RRF | Good | <1ms | Free |
| Weighted scoring | Moderate | <1ms | Free |
| None | Baseline | 0ms | Free (prototyping only) |

```typescript
function reciprocalRankFusion(dense: ScoredChunk[], sparse: ScoredChunk[], alpha: number, k = 60) {
  const scores = new Map<string, number>();
  const chunks = new Map<string, ScoredChunk>();
  dense.forEach((c, rank) => { scores.set(c.id, (scores.get(c.id) ?? 0) + alpha / (k + rank + 1)); chunks.set(c.id, c); });
  sparse.forEach((c, rank) => { scores.set(c.id, (scores.get(c.id) ?? 0) + (1 - alpha) / (k + rank + 1)); if (!chunks.has(c.id)) chunks.set(c.id, c); });
  return Array.from(scores.entries()).sort(([, a], [, b]) => b - a).map(([id, score]) => ({ ...chunks.get(id)!, score }));
}
```

### Stage 8: LLM Context Assembly

Assemble system prompt + retrieved chunks + user query within token budget. Include source attribution (`[Source: filename, p.N]`) per chunk. Stop adding chunks when budget exhausted.

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

**Deletion guarantees**: Qdrant/pgvector/zvec: synchronous atomic deletion. Cloudflare Vectorize: async (returns immediately, completes in seconds — poll or verify before confirming). Object storage: paginate list+delete. Audit log persists after deletion (compliance). Trigger RAG cleanup in `beforeDelete` hook if org deletion cascades.

## Storage Sizing and Quotas

| Component | 1536d | 384d |
|-----------|-------|------|
| Embedding (float32) | 6,144 B | 1,536 B |
| Metadata + content + HNSW | ~3-4 KB | ~3-4 KB |
| **Total per vector** | **~9-10 KB** | **~4-5 KB** |

| Tenant profile | Chunks | Storage (1536d) | Storage (384d) |
|---------------|--------|----------------|----------------|
| Small (100 docs) | ~25K | ~250 MB | ~125 MB |
| Medium (1K docs) | ~250K | ~2.5 GB | ~1.25 GB |
| Large (10K docs) | ~2.5M | ~25 GB | ~12.5 GB |

```typescript
const PLAN_QUOTAS: Record<OrgPlan, TenantRAGQuotas> = {
  free:       { maxDocuments: 50,      maxStorageBytes: 100 * 1024 * 1024,         maxFileSize: 10 * 1024 * 1024,   maxVectors: 10_000 },
  pro:        { maxDocuments: 5_000,   maxStorageBytes: 5 * 1024 * 1024 * 1024,    maxFileSize: 50 * 1024 * 1024,   maxVectors: 500_000 },
  enterprise: { maxDocuments: 100_000, maxStorageBytes: 100 * 1024 * 1024 * 1024,  maxFileSize: 200 * 1024 * 1024,  maxVectors: 10_000_000 },
};
```

**Cost optimisation**: (1) Matryoshka 512d saves 3x storage, ~3% recall loss. (2) Local models eliminate API costs. (3) Lazy embedding on first query if upload >> query volume. (4) INT8 quantization: 4x storage reduction, ~1% recall loss (zvec, Qdrant). (5) TTL: auto-delete chunks not queried in 90+ days.

## Implementation Checklist

- [ ] **Isolation**: Collection/namespace derived from `TenantContext.orgId`, never user input
- [ ] **Lifecycle**: Onboarding creates collection; deletion destroys it + object storage
- [ ] **Embedding model tracked**: Model ID stored with every vector
- [ ] **Quotas enforced**: Per-plan limits on documents, storage, vectors
- [ ] **Audit logged**: Upload, delete, search with org_id
- [ ] **Cross-tenant test**: Integration test: tenant A cannot see tenant B's data
- [ ] **Reranking enabled**: Cross-encoder or RRF for production
- [ ] **Token budget managed**: Context assembly respects model limits
- [ ] **Source attribution**: Chunks include file name and page/section
- [ ] **Error handling**: Graceful degradation when vector DB unavailable
- [ ] **Monitoring**: Per-tenant vector count, query latency, storage usage
