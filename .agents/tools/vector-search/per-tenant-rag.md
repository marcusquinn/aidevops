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
- **Cloudflare Vectorize**: `services/hosting/cloudflare-platform/references/vectorize/README.md`
- **Isolation strategy**: Collection-per-tenant (physical) or namespace/metadata filtering (logical)
- **Pipeline**: Upload -> Chunk -> Embed -> Store -> Query -> Rerank -> LLM Context Assembly

**This document covers SaaS app development** where users/organisations upload their own documents for retrieval-augmented generation. It is NOT for the aidevops internal memory system (which uses SQLite FTS5) or code search (which uses osgrep).

<!-- AI-CONTEXT-END -->

## Architecture Overview

A per-tenant RAG system must solve two problems simultaneously: (1) effective retrieval from unstructured documents, and (2) strict data isolation between tenants. Getting retrieval right but leaking data across tenants is a security incident. Getting isolation right but returning irrelevant chunks is a product failure.

### End-to-End Pipeline

```text
User uploads file (PDF/DOCX/TXT/HTML/CSV)
  |
  v
[1. Ingest] --- Validate file type, size, malware scan
  |              Store original in object storage (R2/S3) keyed by org_id
  |
  v
[2. Parse] ---- Extract text by type:
  |              PDF: Docling / pdf-parse / Apache Tika
  |              DOCX: mammoth / docx-parser
  |              HTML: mozilla/readability / cheerio
  |              CSV: papaparse (row-per-chunk or grouped)
  |              TXT: direct (no parsing needed)
  |
  v
[3. Chunk] ---- Split into retrieval units:
  |              Strategy: recursive character splitting
  |              Chunk size: 512-1024 tokens (model-dependent)
  |              Overlap: 128 tokens (prevents boundary information loss)
  |              Preserve: paragraph/section boundaries where possible
  |
  v
[4. Embed] ---- Convert chunks to vectors:
  |              Model selection per use case (see Embedding Models below)
  |              Batch embedding for throughput (32-128 chunks per call)
  |              Store model ID with vectors (for re-embedding on model change)
  |
  v
[5. Store] ---- Write to tenant-isolated vector collection:
  |              One collection/namespace per org_id
  |              Schema: id, content, dense_embedding, sparse_embedding, metadata
  |              Index type: HNSW (default) or IVF (memory-constrained)
  |
  v
[6. Query] ---- User asks a question:
  |              a. Embed query with same model as storage
  |              b. Search ONLY the tenant's collection (isolation boundary)
  |              c. topK=20 candidates (over-fetch for reranking)
  |              d. Optional: hybrid search (dense + sparse/BM25)
  |
  v
[7. Rerank] --- Re-score candidates for relevance:
  |              Cross-encoder reranker (most accurate, slower)
  |              or RRF (Reciprocal Rank Fusion) for hybrid results
  |              Return top-5 chunks with metadata
  |
  v
[8. Assemble] - Build LLM prompt:
                 System prompt + retrieved chunks + user query
                 Token budget: model_max - response_reserve - system_prompt
                 Fill with chunks in relevance order until budget exhausted
                 Include source attribution metadata per chunk
```

### Why This Order Matters

Each stage has a specific failure mode that the next stage cannot recover from:

| Stage | Failure mode | Impact |
|-------|-------------|--------|
| Parse | Garbled text extraction | All downstream stages work on garbage |
| Chunk | Chunks too large or split mid-sentence | Embeddings capture noise, retrieval degrades |
| Embed | Wrong model or dimension mismatch | Queries return random results |
| Store | Wrong tenant collection | Data leak (security incident) |
| Query | No tenant filter | Cross-tenant data exposure |
| Rerank | Skipped | Top-K results include irrelevant chunks, LLM hallucinates |

## Tenant Isolation Models

### Comparison Matrix

| Approach | Isolation level | Ops cost | Query overhead | Tenant limit | Best for |
|----------|----------------|----------|---------------|-------------|----------|
| Collection-per-tenant | Physical | Low | None (query scoped by design) | ~10K tenants | Default recommendation |
| Namespace-per-tenant | Logical (partition) | Low | Namespace filter (fast, pre-search) | ~50K tenants | Cloudflare Vectorize |
| Metadata filter | Logical (row-level) | Low | Filter applied during search (slower) | Unlimited | Simple cases, few tenants |
| pgvector + RLS | Logical (DB-level) | Medium | RLS policy check per row | Unlimited | Already on PostgreSQL |
| Separate DB/index | Physical (full) | High | None | ~100 tenants | Regulated/enterprise |

### Recommended: Collection-Per-Tenant

For most SaaS applications with up to ~10K tenants, **collection-per-tenant** provides the best balance of isolation strength and operational simplicity.

**Why collection-per-tenant wins:**

1. **Physical isolation by default** -- a query against tenant A's collection cannot return tenant B's data, even with a bug in the application layer. There is no filter to forget.
2. **Simple lifecycle** -- creating a tenant = creating a collection. Deleting a tenant = dropping a collection. No orphaned vectors, no partial deletes.
3. **Independent scaling** -- large tenants can have different index parameters (HNSW M, ef_construction) without affecting small tenants.
4. **No shared-index performance degradation** -- a tenant with 10M vectors does not slow down queries for a tenant with 1K vectors.

**When NOT to use collection-per-tenant:**

- More than ~10K tenants (collection metadata overhead)
- Tenants with very few vectors (<100 each) -- namespace or metadata filtering is simpler
- Cross-tenant search is a product requirement (e.g., marketplace search)

### Integration with Multi-Org Schema

The per-tenant RAG system maps directly to the existing multi-org isolation schema defined in `services/database/schemas/multi-org.ts`:

```text
organisations.id (UUID)
       |
       +---> Vector collection name: "rag_{org_id}"
       |     (or namespace in shared-index deployments)
       |
       +---> Object storage prefix: "uploads/{org_id}/"
       |     (original files, keyed by org for lifecycle management)
       |
       +---> Metadata in vector store:
             - org_id: organisations.id (redundant safety check)
             - uploaded_by: users.id
             - source_file: original filename
             - chunk_index: position within source document
```

**TenantContext integration** (from `services/database/schemas/tenant-context.ts`):

```typescript
import type { TenantContext } from './tenant-context';

/**
 * All RAG operations receive TenantContext from middleware.
 * The orgId determines which vector collection to query.
 */
async function searchDocuments(
  ctx: TenantContext,
  query: string,
  topK: number = 5,
): Promise<RetrievedChunk[]> {
  const collectionName = `rag_${ctx.orgId}`;

  // 1. Embed the query
  const queryEmbedding = await embedQuery(query);

  // 2. Search ONLY this tenant's collection
  const candidates = await vectorDb.search(collectionName, {
    vector: queryEmbedding,
    topK: topK * 4, // Over-fetch for reranking
  });

  // 3. Rerank
  const reranked = await rerank(query, candidates);

  // 4. Return top-K with metadata
  return reranked.slice(0, topK);
}
```

**Audit logging** -- all RAG operations (upload, delete, search) should be logged to the `audit_log` table with the tenant's `org_id`:

```typescript
await db.insert(auditLog).values({
  orgId: ctx.orgId,
  userId: ctx.userId,
  action: 'rag:document_uploaded',
  entityType: 'document',
  entityId: documentId,
  metadata: {
    filename: file.name,
    fileSize: file.size,
    chunkCount: chunks.length,
    embeddingModel: modelId,
  },
});
```

## Pipeline Stage Details

### Stage 1: Ingest

Accept file uploads with validation before any processing.

```typescript
interface IngestConfig {
  /** Max file size in bytes (default: 50MB) */
  maxFileSize: number;
  /** Allowed MIME types */
  allowedTypes: string[];
  /** Object storage prefix pattern */
  storagePrefix: (orgId: string) => string;
}

const DEFAULT_INGEST_CONFIG: IngestConfig = {
  maxFileSize: 50 * 1024 * 1024, // 50MB
  allowedTypes: [
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'text/plain',
    'text/html',
    'text/csv',
    'text/markdown',
  ],
  storagePrefix: (orgId) => `uploads/${orgId}/`,
};
```

**Security considerations:**

- Validate MIME type from file content (magic bytes), not just the extension
- Scan for malware before processing (ClamAV or cloud scanning service)
- Store originals in object storage with org_id prefix for lifecycle management
- Set per-tenant storage quotas (see Storage Sizing below)

### Stage 2: Parse

Extract clean text from each file type. The parser choice significantly affects downstream retrieval quality.

| File type | Recommended parser | Notes |
|-----------|-------------------|-------|
| PDF | Docling (IBM, Apache-2.0) | Best for complex layouts, tables, figures. Falls back to pdf-parse for simple PDFs |
| DOCX | mammoth | Preserves structure (headings, lists). Ignores formatting (bold, italic) |
| HTML | mozilla/readability | Extracts article content, strips nav/ads/boilerplate |
| CSV | papaparse | Row-per-chunk or group by column. Include header as context |
| TXT/MD | Direct | Split on paragraph boundaries. Preserve markdown structure for MD |

**Parser output contract:**

```typescript
interface ParsedDocument {
  /** Extracted text content */
  text: string;
  /** Document structure (if available) */
  sections?: DocumentSection[];
  /** Document metadata extracted during parsing */
  metadata: {
    title?: string;
    author?: string;
    pageCount?: number;
    language?: string;
    createdAt?: string;
  };
}

interface DocumentSection {
  heading: string;
  level: number; // 1-6
  content: string;
  pageNumber?: number;
}
```

### Stage 3: Chunk

Split parsed text into retrieval units. Chunk size is the most impactful parameter for retrieval quality.

**Chunking strategy decision:**

| Strategy | Chunk size | Overlap | Best for |
|----------|-----------|---------|----------|
| Small chunks | 256-512 tokens | 64 tokens | Precise factual retrieval (Q&A) |
| Medium chunks | 512-1024 tokens | 128 tokens | General-purpose RAG (default) |
| Large chunks | 1024-2048 tokens | 256 tokens | Summarisation, long-form context |
| Section-based | Variable | None | Structured documents with clear headings |

**Recommended default: 512 tokens, 128 overlap.**

Rationale: Most embedding models are trained on passages of 256-512 tokens. Larger chunks dilute the embedding signal. Smaller chunks lose context. 128-token overlap ensures no information is lost at boundaries.

```typescript
interface ChunkConfig {
  /** Target chunk size in tokens */
  chunkSize: number;
  /** Overlap between consecutive chunks in tokens */
  chunkOverlap: number;
  /** Minimum chunk size (discard smaller) */
  minChunkSize: number;
  /** Split boundaries (try to split at these, in priority order) */
  separators: string[];
}

const DEFAULT_CHUNK_CONFIG: ChunkConfig = {
  chunkSize: 512,
  chunkOverlap: 128,
  minChunkSize: 50,
  separators: ['\n\n', '\n', '. ', ' '],
};
```

**Chunk metadata** -- every chunk must carry enough metadata to trace back to its source:

```typescript
interface Chunk {
  /** Unique ID: {document_id}_{chunk_index} */
  id: string;
  /** The text content of this chunk */
  content: string;
  /** Metadata for retrieval and attribution */
  metadata: {
    documentId: string;
    chunkIndex: number;
    totalChunks: number;
    sourceFile: string;
    pageNumber?: number;
    sectionHeading?: string;
    orgId: string;
    uploadedBy: string;
    uploadedAt: string;
    embeddingModel: string;
  };
}
```

### Stage 4: Embed

Convert text chunks to vector representations. Model selection depends on quality requirements, cost, and latency constraints.

**Embedding model comparison:**

| Model | Dimensions | Quality (MTEB) | Latency | Cost | Notes |
|-------|-----------|----------------|---------|------|-------|
| OpenAI text-embedding-3-small | 1536 (or 512/256 via Matryoshka) | High | ~50ms/batch | $0.02/1M tokens | Best quality/cost ratio for API |
| OpenAI text-embedding-3-large | 3072 (or 1024/256) | Highest | ~80ms/batch | $0.13/1M tokens | When quality is paramount |
| Jina v3 | 1024 (Matryoshka to 256) | High | ~40ms/batch | $0.02/1M tokens | Multilingual, late interaction |
| Sentence Transformers (local) | 384 | Good | ~10ms/batch | Free (compute only) | No API dependency, privacy |
| Cloudflare Workers AI bge-base | 768 | Good | ~20ms/batch | Included in Workers | Cloudflare-native deployments |
| BM25 (sparse, local) | Vocabulary-sized | N/A (lexical) | <1ms | Free | Hybrid search complement |

**Matryoshka embeddings** -- models like OpenAI text-embedding-3-small and Jina v3 support truncating dimensions (e.g., 1536 -> 512 -> 256) with controlled quality degradation. This reduces storage 3-6x with ~2-5% recall loss. Use when storage cost matters more than marginal retrieval quality.

**Batch embedding for throughput:**

```typescript
interface EmbeddingConfig {
  /** Model identifier */
  modelId: string;
  /** Dimensions (for Matryoshka models, can be less than native) */
  dimensions: number;
  /** Batch size for embedding calls */
  batchSize: number;
  /** Whether to also generate sparse embeddings for hybrid search */
  hybridSearch: boolean;
}

const DEFAULT_EMBEDDING_CONFIG: EmbeddingConfig = {
  modelId: 'text-embedding-3-small',
  dimensions: 1536,
  batchSize: 64,
  hybridSearch: false,
};
```

**Critical rule: store the embedding model ID with every vector.** When you change embedding models, old vectors are incompatible with new query embeddings. You must either re-embed all existing vectors or maintain separate collections per model version.

### Stage 5: Store

Write embedded chunks to the tenant's vector collection.

**Vector record schema:**

```typescript
interface VectorRecord {
  /** Unique ID: {document_id}_{chunk_index} */
  id: string;
  /** Dense embedding vector */
  denseEmbedding: number[];
  /** Sparse embedding (BM25/SPLADE) for hybrid search -- optional */
  sparseEmbedding?: Record<number, number>;
  /** Original text content (for reranking and display) */
  content: string;
  /** Metadata for filtering and attribution */
  metadata: {
    documentId: string;
    chunkIndex: number;
    sourceFile: string;
    orgId: string;
    uploadedBy: string;
    uploadedAt: string;
    embeddingModel: string;
    pageNumber?: number;
    sectionHeading?: string;
  };
}
```

**Index configuration by vector DB:**

| Vector DB | Collection creation | Tenant isolation | Index type |
|-----------|-------------------|-----------------|------------|
| zvec | `db.createCollection(name, { dimension })` | Collection per org | HNSW (default), IVF |
| Cloudflare Vectorize | `wrangler vectorize create` | Namespace per org | Managed |
| pgvector | `CREATE TABLE ... USING ivfflat/hnsw` | RLS policy on org_id | IVF or HNSW |
| Qdrant | `PUT /collections/{name}` | Collection per org | HNSW |

**HNSW parameters** (tune per tenant size):

| Tenant size (vectors) | M | ef_construction | ef_search | Notes |
|----------------------|---|----------------|-----------|-------|
| <10K | 16 | 100 | 50 | Default, good for most |
| 10K-100K | 16 | 200 | 100 | Better recall |
| 100K-1M | 32 | 200 | 150 | Higher connectivity |
| >1M | 48 | 400 | 200 | Maximum recall, more memory |

### Stage 6: Query

Search the tenant's collection for relevant chunks.

```typescript
interface QueryConfig {
  /** Number of candidates to retrieve (before reranking) */
  candidateCount: number;
  /** Minimum similarity score (0-1 for cosine) */
  minScore: number;
  /** Whether to use hybrid search (dense + sparse) */
  hybrid: boolean;
  /** Weight for dense vs sparse in hybrid (0 = all sparse, 1 = all dense) */
  hybridAlpha: number;
}

const DEFAULT_QUERY_CONFIG: QueryConfig = {
  candidateCount: 20,
  minScore: 0.3,
  hybrid: false,
  hybridAlpha: 0.7, // 70% dense, 30% sparse
};
```

**Hybrid search** combines dense (semantic) and sparse (lexical/BM25) retrieval. Use when:

- Users search for specific terms, names, or codes that semantic search misses
- Documents contain domain-specific jargon not well-represented in embedding models
- You need both "what does this mean?" (semantic) and "where is this exact phrase?" (lexical)

**Query flow with tenant isolation:**

```typescript
async function queryTenantRAG(
  ctx: TenantContext,
  query: string,
  config: QueryConfig = DEFAULT_QUERY_CONFIG,
): Promise<ScoredChunk[]> {
  const collectionName = `rag_${ctx.orgId}`;

  // Verify collection exists (tenant has RAG enabled)
  if (!await vectorDb.collectionExists(collectionName)) {
    throw new TenantError('RAG_NOT_ENABLED', ctx.orgId);
  }

  // Embed query with same model used for storage
  const queryEmbedding = await embed(query, getCollectionModel(collectionName));

  // Search tenant's collection ONLY
  let results: ScoredChunk[];
  if (config.hybrid) {
    const denseResults = await vectorDb.search(collectionName, {
      vector: queryEmbedding,
      topK: config.candidateCount,
    });
    const sparseResults = await vectorDb.searchSparse(collectionName, {
      query: query, // BM25 uses raw text
      topK: config.candidateCount,
    });
    results = reciprocalRankFusion(denseResults, sparseResults, config.hybridAlpha);
  } else {
    results = await vectorDb.search(collectionName, {
      vector: queryEmbedding,
      topK: config.candidateCount,
    });
  }

  // Filter by minimum score
  return results.filter(r => r.score >= config.minScore);
}
```

### Stage 7: Rerank

Re-score candidates using a more expensive but more accurate model. Reranking is the highest-ROI improvement you can make to a RAG pipeline -- it typically improves answer quality by 10-30% with minimal latency cost.

**Reranking strategies:**

| Strategy | Accuracy | Latency | Cost | When to use |
|----------|----------|---------|------|-------------|
| Cross-encoder | Highest | 50-200ms for 20 candidates | API cost or GPU | Production, quality-critical |
| RRF (Reciprocal Rank Fusion) | Good | <1ms | Free | Hybrid search result merging |
| Weighted scoring | Moderate | <1ms | Free | Simple cases, metadata boosting |
| None (skip) | Baseline | 0ms | Free | Prototyping only |

**Cross-encoder reranking:**

```typescript
async function rerankWithCrossEncoder(
  query: string,
  candidates: ScoredChunk[],
  topK: number = 5,
): Promise<ScoredChunk[]> {
  // Cross-encoder scores query-document pairs directly
  // Much more accurate than bi-encoder (embedding) similarity
  const pairs = candidates.map(c => ({
    query: query,
    document: c.content,
    originalScore: c.score,
    metadata: c.metadata,
  }));

  const reranked = await crossEncoder.rank(pairs);

  return reranked
    .sort((a, b) => b.score - a.score)
    .slice(0, topK);
}
```

**Reciprocal Rank Fusion (for hybrid search):**

```typescript
function reciprocalRankFusion(
  denseResults: ScoredChunk[],
  sparseResults: ScoredChunk[],
  alpha: number = 0.7,
  k: number = 60,
): ScoredChunk[] {
  const scores = new Map<string, number>();
  const chunks = new Map<string, ScoredChunk>();

  // Score from dense results (weighted by alpha)
  denseResults.forEach((chunk, rank) => {
    const rrf = alpha / (k + rank + 1);
    scores.set(chunk.id, (scores.get(chunk.id) ?? 0) + rrf);
    chunks.set(chunk.id, chunk);
  });

  // Score from sparse results (weighted by 1-alpha)
  sparseResults.forEach((chunk, rank) => {
    const rrf = (1 - alpha) / (k + rank + 1);
    scores.set(chunk.id, (scores.get(chunk.id) ?? 0) + rrf);
    if (!chunks.has(chunk.id)) chunks.set(chunk.id, chunk);
  });

  return Array.from(scores.entries())
    .sort(([, a], [, b]) => b - a)
    .map(([id, score]) => ({ ...chunks.get(id)!, score }));
}
```

### Stage 8: LLM Context Assembly

Build the final prompt with retrieved context and manage the token budget.

```typescript
interface ContextAssemblyConfig {
  /** Maximum context window of the target LLM (tokens) */
  modelMaxTokens: number;
  /** Tokens reserved for the LLM response */
  responseReserve: number;
  /** System prompt template */
  systemPrompt: string;
  /** Whether to include source attribution */
  includeAttribution: boolean;
}

function assembleContext(
  query: string,
  chunks: ScoredChunk[],
  config: ContextAssemblyConfig,
): string {
  const systemTokens = countTokens(config.systemPrompt);
  const queryTokens = countTokens(query);
  const overhead = 100; // formatting, separators

  let budget = config.modelMaxTokens
    - config.responseReserve
    - systemTokens
    - queryTokens
    - overhead;

  const includedChunks: string[] = [];

  for (const chunk of chunks) {
    const chunkTokens = countTokens(chunk.content);
    if (chunkTokens > budget) break;

    const attribution = config.includeAttribution
      ? `[Source: ${chunk.metadata.sourceFile}, p.${chunk.metadata.pageNumber ?? '?'}]`
      : '';

    includedChunks.push(`${chunk.content}\n${attribution}`);
    budget -= chunkTokens;
  }

  return [
    config.systemPrompt,
    '',
    '## Retrieved Context',
    '',
    includedChunks.join('\n\n---\n\n'),
    '',
    '## User Question',
    '',
    query,
  ].join('\n');
}
```

**Token budget allocation** (for a 128K context model):

| Component | Tokens | Notes |
|-----------|--------|-------|
| System prompt | 500-2000 | Instructions, persona, output format |
| Retrieved chunks | 4000-16000 | 5-20 chunks at 512-1024 tokens each |
| User query | 50-500 | The actual question |
| Response reserve | 2000-4000 | Space for the LLM to generate |
| **Total used** | **~6500-22500** | Well within 128K, leaves room for conversation history |

## Tenant Lifecycle

### Onboarding: Create Collection

When a new organisation is created (or when RAG is enabled for an existing org), provision the vector storage:

```typescript
async function onboardTenantRAG(
  ctx: TenantContext,
  config?: Partial<EmbeddingConfig>,
): Promise<void> {
  const collectionName = `rag_${ctx.orgId}`;
  const embeddingConfig = { ...DEFAULT_EMBEDDING_CONFIG, ...config };

  // 1. Create vector collection
  await vectorDb.createCollection(collectionName, {
    dimension: embeddingConfig.dimensions,
    metric: 'cosine',
    indexType: 'hnsw',
    hnswConfig: { m: 16, efConstruction: 100 },
  });

  // 2. Create object storage prefix for original files
  // (Most object stores create prefixes implicitly on first write)

  // 3. Store RAG config in org settings
  await db.update(organisations)
    .set({
      settings: sql`jsonb_set(
        COALESCE(settings, '{}'),
        '{rag}',
        ${JSON.stringify({
          enabled: true,
          embeddingModel: embeddingConfig.modelId,
          dimensions: embeddingConfig.dimensions,
          createdAt: new Date().toISOString(),
        })}::jsonb
      )`,
    })
    .where(eq(organisations.id, ctx.orgId));

  // 4. Audit log
  await db.insert(auditLog).values({
    orgId: ctx.orgId,
    userId: ctx.userId,
    action: 'rag:tenant_onboarded',
    entityType: 'rag_collection',
    metadata: {
      collectionName,
      embeddingModel: embeddingConfig.modelId,
      dimensions: embeddingConfig.dimensions,
    },
  });
}
```

### Deletion: Destroy Collection

When an organisation is deleted or RAG is disabled, clean up all vector data and original files:

```typescript
async function offboardTenantRAG(
  ctx: TenantContext,
): Promise<void> {
  const collectionName = `rag_${ctx.orgId}`;

  // 1. Delete vector collection (all vectors destroyed)
  await vectorDb.deleteCollection(collectionName);

  // 2. Delete original files from object storage
  const prefix = `uploads/${ctx.orgId}/`;
  await objectStorage.deletePrefix(prefix);

  // 3. Update org settings
  await db.update(organisations)
    .set({
      settings: sql`settings - 'rag'`,
    })
    .where(eq(organisations.id, ctx.orgId));

  // 4. Audit log
  await db.insert(auditLog).values({
    orgId: ctx.orgId,
    userId: ctx.userId,
    action: 'rag:tenant_offboarded',
    entityType: 'rag_collection',
    metadata: { collectionName },
  });
}
```

**Deletion guarantees:**

- Collection deletion is atomic -- all vectors are removed in one operation
- Object storage deletion must handle pagination (list + delete in batches)
- Audit log entry persists after deletion (for compliance)
- If org deletion cascades (from `organisations` table), trigger RAG cleanup in a `beforeDelete` hook or database trigger

### Cross-Tenant Search Prevention

The primary defense is architectural: collection-per-tenant means queries are physically scoped. But defense-in-depth requires additional checks:

**Layer 1: Architecture (primary)**

- Each tenant's vectors live in a separate collection
- Query functions accept `TenantContext` and derive the collection name from `ctx.orgId`
- No API endpoint accepts a collection name directly from the client

**Layer 2: Application (secondary)**

```typescript
// NEVER do this -- collection name from user input
app.post('/api/search', async (req, res) => {
  const results = await vectorDb.search(req.body.collection, ...); // WRONG
});

// ALWAYS do this -- collection name from authenticated context
app.post('/api/search', async (req, res) => {
  const ctx = req.tenant; // Set by tenant middleware
  const collection = `rag_${ctx.orgId}`; // Derived from auth
  const results = await vectorDb.search(collection, ...);
});
```

**Layer 3: Metadata validation (belt-and-suspenders)**

```typescript
// After retrieval, verify every result belongs to the requesting tenant
function validateTenantOwnership(
  results: ScoredChunk[],
  orgId: string,
): ScoredChunk[] {
  return results.filter(r => {
    if (r.metadata.orgId !== orgId) {
      // This should NEVER happen with collection-per-tenant
      // If it does, log a security alert
      logger.error('CROSS_TENANT_LEAK_DETECTED', {
        requestingOrg: orgId,
        resultOrg: r.metadata.orgId,
        chunkId: r.id,
      });
      return false;
    }
    return true;
  });
}
```

**Layer 4: Testing (verification)**

Integration tests must verify cross-tenant isolation:

```typescript
describe('tenant isolation', () => {
  it('cannot retrieve vectors from another tenant', async () => {
    // Setup: two tenants with documents
    await uploadDocument(tenantA, 'secret-plans.pdf');
    await uploadDocument(tenantB, 'public-info.pdf');

    // Query as tenant A
    const results = await searchDocuments(tenantAContext, 'secret plans');

    // Verify: no results from tenant B
    const leakedResults = results.filter(
      r => r.metadata.orgId === tenantB.orgId
    );
    expect(leakedResults).toHaveLength(0);
  });

  it('returns empty results for tenant with no documents', async () => {
    const results = await searchDocuments(emptyTenantContext, 'anything');
    expect(results).toHaveLength(0);
  });
});
```

## Storage Sizing Per Tenant

### Vector Storage Estimation

Formula: `storage_bytes = num_vectors * (dimensions * bytes_per_float + metadata_bytes + overhead)`

| Component | Size per vector | Notes |
|-----------|----------------|-------|
| Dense embedding (1536d, float32) | 6,144 bytes | `1536 * 4` |
| Dense embedding (384d, float32) | 1,536 bytes | `384 * 4` |
| Metadata (typical) | 500-2,000 bytes | JSON: filename, chunk index, timestamps |
| Content text (512 tokens) | ~2,000 bytes | Stored for reranking/display |
| HNSW index overhead | ~200-800 bytes | Depends on M parameter |
| **Total per vector (1536d)** | **~9-10 KB** | |
| **Total per vector (384d)** | **~4-5 KB** | |

### Sizing Examples

| Tenant profile | Documents | Chunks (est.) | Storage (1536d) | Storage (384d) |
|---------------|-----------|--------------|----------------|----------------|
| Small (startup) | 100 docs, 50 pages avg | ~25K | ~250 MB | ~125 MB |
| Medium (SMB) | 1,000 docs, 50 pages avg | ~250K | ~2.5 GB | ~1.25 GB |
| Large (enterprise) | 10,000 docs, 50 pages avg | ~2.5M | ~25 GB | ~12.5 GB |
| Very large | 100,000 docs | ~25M | ~250 GB | ~125 GB |

Assumptions: 50 pages/doc average, ~5 chunks/page at 512 tokens with 128 overlap.

### Per-Tenant Quotas

Enforce storage limits to prevent runaway costs:

```typescript
interface TenantRAGQuotas {
  /** Maximum number of documents */
  maxDocuments: number;
  /** Maximum total storage in bytes */
  maxStorageBytes: number;
  /** Maximum single file size in bytes */
  maxFileSize: number;
  /** Maximum vectors (chunks) */
  maxVectors: number;
}

const PLAN_QUOTAS: Record<OrgPlan, TenantRAGQuotas> = {
  free: {
    maxDocuments: 50,
    maxStorageBytes: 100 * 1024 * 1024,   // 100 MB
    maxFileSize: 10 * 1024 * 1024,         // 10 MB
    maxVectors: 10_000,
  },
  pro: {
    maxDocuments: 5_000,
    maxStorageBytes: 5 * 1024 * 1024 * 1024, // 5 GB
    maxFileSize: 50 * 1024 * 1024,            // 50 MB
    maxVectors: 500_000,
  },
  enterprise: {
    maxDocuments: 100_000,
    maxStorageBytes: 100 * 1024 * 1024 * 1024, // 100 GB
    maxFileSize: 200 * 1024 * 1024,             // 200 MB
    maxVectors: 10_000_000,
  },
};
```

### Cost Estimation

| Cost component | Typical rate | Per 1M vectors/month |
|---------------|-------------|---------------------|
| Vector storage (managed) | $0.10-0.50/GB/month | $1-5 |
| Embedding API (text-embedding-3-small) | $0.02/1M tokens | ~$10 (initial embed) |
| Embedding API (local model) | Compute only | $0 (API cost) |
| Object storage (originals) | $0.023/GB/month (S3) | Varies by doc size |
| Query cost (embedding) | $0.02/1M tokens | ~$0.001/query |
| Reranking (cross-encoder API) | $0.01-0.05/1K pairs | ~$0.001/query |

**Cost optimisation strategies:**

1. **Use Matryoshka dimensions** -- 512d instead of 1536d saves 3x storage with ~3% recall loss
2. **Local embedding models** -- eliminate per-token API costs for high-volume tenants
3. **Lazy embedding** -- embed on first query, not on upload (if upload volume >> query volume)
4. **INT8 quantization** -- 4x storage reduction with ~1% recall loss (supported by zvec, Qdrant)
5. **TTL on unused vectors** -- auto-delete chunks from documents not queried in 90+ days

## Implementation Checklist

When implementing per-tenant RAG for a SaaS application, verify each item:

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
