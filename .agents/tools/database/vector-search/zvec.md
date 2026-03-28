---
description: Zvec - In-process embedded vector database for SaaS RAG pipelines
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Zvec - In-Process Embedded Vector Database

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Embedded C++ vector database (Proxima engine) — in-process similarity search, no separate DB service
- **Install**: `pip install zvec` (Python 3.10-3.12) | `npm install @zvec/zvec` (Node.js, early stage — core ops only)
- **Platforms**: Linux x86_64/ARM64, macOS ARM64. No Windows.
- **Repo**: <https://github.com/alibaba/zvec> (Apache-2.0)
- **Docs**: <https://zvec.org/en/docs/>
- **Parent guide**: `tools/database/vector-search.md` — decision flowchart, comparison matrix, per-tenant isolation patterns, platform support matrix

**Use when**: SaaS RAG with per-tenant document uploads. Zero network hop, collection-per-tenant isolation, built-in embeddings and rerankers.

**Do NOT use**: Browser/WASM, Windows, distributed multi-node (use Milvus/Qdrant), already on Postgres (use pgvector), >100M vectors needing sharding.

<!-- AI-CONTEXT-END -->

## Gotchas

1. **Very new** — December 2025. APIs may change. Small community.
2. **Python-first** — Node.js bindings lack extension ecosystem (embeddings, rerankers).
3. **Single-process** — One process per collection.
4. **No ACID** — Application-level locking for concurrent writes.
5. **Memory per collection** — LRU cache to close idle tenant collections.
6. **CPU compatibility** — Wheels require AVX-512; `Illegal instruction` (exit 132) on AMD Zen 2 (AVX2 only). Verified zvec 0.2.0, Python 3.12.3. Use pgvector on AMD Ryzen/EPYC Zen 2.

## Installation

```bash
pip install zvec                    # Python 3.10-3.12
npm install @zvec/zvec              # Node.js (early stage)
pip install sentence-transformers   # Local dense + sparse (SPLADE)
pip install dashtext                # BM25 sparse embeddings
pip install openai                  # OpenAI/Jina embeddings
pip install dashscope               # Qwen embeddings
```

## Core Concepts

```text
Your App Process
  +-- zvec (in-process C++ library)
        +-- Collection A (tenant_1)  -->  /data/vectors/tenant_1/
        +-- Collection B (tenant_2)  -->  /data/vectors/tenant_2/
```

- **Collection**: Named container at a filesystem path (like a table). One process per collection.
- **Document** (`Doc`): Record with string `id`, scalar fields, and vector fields.
- **Schema**: Defines scalar fields (`FieldSchema`) and vector fields (`VectorSchema`).

## Schema & Data Types

**Scalar**: `INT32`, `INT64`, `UINT32`, `UINT64`, `FLOAT`, `DOUBLE`, `STRING`, `BOOL`, `ARRAY_INT32`, `ARRAY_STRING`, etc.

**Vector**: `VECTOR_FP32` (default), `VECTOR_FP16` (half memory), `VECTOR_INT8` (4x memory reduction, >95% recall with refiner), `SPARSE_VECTOR_FP32`, `SPARSE_VECTOR_FP16`

```python
import zvec

schema = zvec.CollectionSchema(
    name="documents",
    fields=[
        zvec.FieldSchema("title", zvec.DataType.STRING, nullable=True),
        zvec.FieldSchema("category", zvec.DataType.STRING),
        zvec.FieldSchema("price", zvec.DataType.INT32,
            index_param=zvec.InvertIndexParam(enable_range_optimization=True)),
    ],
    vectors=[
        zvec.VectorSchema("embedding", zvec.DataType.VECTOR_FP32, dimension=384,
            index_param=zvec.HnswIndexParam(metric_type=zvec.MetricType.COSINE)),
        zvec.VectorSchema("sparse_emb", zvec.DataType.SPARSE_VECTOR_FP32),
    ],
)
```

### Schema Evolution

No downtime or reindexing required. Cannot add/drop vector fields (coming soon). `add_column()` supports numerical scalar types only.

```python
collection.add_column(field_schema=zvec.FieldSchema("rating", zvec.DataType.INT32), expression="5")
collection.drop_column(field_name="old_field")          # Irreversible
collection.alter_column(old_name="publish_year", new_name="release_year")
collection.alter_column(field_schema=zvec.FieldSchema("rating", zvec.DataType.FLOAT))
```

## Index Types

| Index | Class | Best for | Trade-off |
|-------|-------|----------|-----------|
| **HNSW** | `HnswIndexParam` | General use, <50M vectors | High recall, higher memory |
| **IVF** | `IVFIndexParam` | Memory-constrained, >10M vectors | Lower memory, slightly lower recall |
| **Flat** | `FlatIndexParam` | Small collections (<100k), exact search | Exact results, O(n) search |

```python
zvec.HnswIndexParam(metric_type=zvec.MetricType.COSINE, ef_construction=200, m=16)
zvec.HnswQueryParam(ef=300)          # Search-time quality; metric_type: L2, IP, or COSINE
zvec.IVFIndexParam(nlist=1024)       # nlist: sqrt(n) is a good starting point
zvec.IVFQueryParam(nprobe=64)

collection.create_index(field_name="embedding", index_param=zvec.HnswIndexParam(...))
collection.create_index(field_name="category", index_param=zvec.InvertIndexParam())
collection.drop_index(field_name="category")  # Scalar only; vector indexes cannot be dropped
```

## Initialization & Collection Lifecycle

```python
zvec.init()  # Auto-detect resources (call once at startup; subsequent calls raise RuntimeError)

# Production — None values fall back to cgroup-aware defaults (Docker/K8s friendly)
zvec.init(log_type=zvec.LogType.FILE, log_dir="/var/log/zvec", log_level=zvec.LogLevel.WARN,
          query_threads=4, optimize_threads=2, memory_limit_mb=2048)

collection = zvec.create_and_open(path="./my_collection", schema=schema)
collection = zvec.open(path="./my_collection")
collection.schema; collection.stats   # Schema definition; doc count, size, etc.
collection.optimize()                 # Merge segments, rebuild indexes
collection.destroy()                  # Irreversible — deletes all data
```

## CRUD Operations

```python
collection.insert(zvec.Doc(id="doc_1", fields={"title": "Example"}, vectors={"embedding": [0.1, 0.2, ...]}))
collection.insert([doc1, doc2, doc3])                                          # Batch
collection.upsert(zvec.Doc(id="doc_1", fields={"title": "Updated"}))
collection.update(zvec.Doc(id="doc_1", fields={"category": "science"}))        # Partial update

docs = collection.fetch(["doc_1", "doc_2"])                                    # Single ID or list
collection.delete(ids=["doc_1", "doc_2"])                                      # Single ID or list
collection.delete_by_filter(filter="publish_year < 1900")
```

## Query API

Writes are immediately visible — no eventual consistency delay.

```python
# Single-vector search with filter
results = collection.query(
    vectors=zvec.VectorQuery(field_name="embedding", vector=[0.1, 0.2, ...]),
    topk=10,
    filter="category == 'tech' AND publish_year > 2020",
    include_vector=False,
    output_fields=["title"],
)

# Query by stored document ID (reuse stored vector)
results = collection.query(vectors=zvec.VectorQuery(field_name="embedding", id="doc_1"), topk=10)

# Filter-only (no vector search)
results = collection.query(filter="publish_year < 1999", topk=50)
```

## Embeddings & Rerankers

Built-in, thread-safe. Local models download on first use. Text modality only.

| Function | Type | Model/Provider | Dimensions | Dependency / Env var |
|----------|------|----------------|------------|----------------------|
| `DefaultLocalDenseEmbedding` | Local | all-MiniLM-L6-v2 | 384 | `sentence-transformers` (~80MB) |
| `DefaultLocalSparseEmbedding` | Local | SPLADE cocondenser | ~30k (sparse) | `sentence-transformers` (~100MB) |
| `BM25EmbeddingFunction` | Local | DashText BM25 | variable (sparse) | `dashtext` |
| `OpenAIDenseEmbedding` | API | OpenAI | 1536 (default) | `OPENAI_API_KEY` |
| `JinaDenseEmbedding` | API | Jina AI | 768-1024 (Matryoshka) | `JINA_API_KEY` |
| `QwenDenseEmbedding` | API | Alibaba Qwen | varies | `DASHSCOPE_API_KEY` |
| `QwenSparseEmbedding` | API | Alibaba Qwen | sparse | `DASHSCOPE_API_KEY` |

| Reranker | When to use |
|----------|-------------|
| `RrfReRanker` | Multi-vector fusion (dense + sparse). No model needed. |
| `WeightedReRanker` | Multi-vector with configurable weights. No model needed. |
| `DefaultLocalReRanker` | Single-vector deep semantic re-ranking. Local, free. |
| `QwenReRanker` | API-based re-ranking with Qwen models. |

```python
from zvec.extension import DefaultLocalDenseEmbedding, DefaultLocalSparseEmbedding, BM25EmbeddingFunction
from zvec.extension import OpenAIDenseEmbedding, JinaDenseEmbedding, QwenDenseEmbedding, QwenSparseEmbedding
from zvec.extension import RrfReRanker, WeightedReRanker, DefaultLocalReRanker, QwenReRanker

# Local embeddings
emb    = DefaultLocalDenseEmbedding()                                  # Downloads ~80MB on first run
emb_ms = DefaultLocalDenseEmbedding(model_source="modelscope")         # China mirror
DefaultLocalDenseEmbedding.clear_cache()                               # Release model memory

# SPLADE — asymmetric: separate query/document encoders
query_emb = DefaultLocalSparseEmbedding(encoding_type="query")
doc_emb   = DefaultLocalSparseEmbedding(encoding_type="document")

bm25 = BM25EmbeddingFunction(corpus=["doc1...", "doc2..."], encoding_type="document", b=0.75, k1=1.2)

# API-based embeddings
emb = OpenAIDenseEmbedding(model="text-embedding-3-small", dimension=256)

# Jina (Matryoshka: 32-1024 dims; 32K context; tasks: retrieval.query, retrieval.passage, text-matching, classification, separation)
query_emb = JinaDenseEmbedding(model="jina-embeddings-v5-text-small", dimension=256, task="retrieval.query")
doc_emb   = JinaDenseEmbedding(model="jina-embeddings-v5-text-small", dimension=256, task="retrieval.passage")

dense_emb  = QwenDenseEmbedding(256, model="text-embedding-v3")
sparse_emb = QwenSparseEmbedding(dimension=256)

# Rerankers
reranker = RrfReRanker(topn=10, rank_constant=60)                     # RRF: score = 1/(k+rank+1)
reranker = WeightedReRanker(topn=10, metric=zvec.MetricType.COSINE, weights={"dense_emb": 0.7, "sparse_emb": 0.3})
reranker = DefaultLocalReRanker(query="q", topn=5, rerank_field="title", model_name="cross-encoder/ms-marco-MiniLM-L6-v2", device="cuda")
reranker = QwenReRanker(query="q", model="gte-rerank-v2", topn=10, rerank_field="content")
```

## Hybrid Search

Combine dense semantic + sparse lexical matching. Schema needs both vector fields; insert docs with both embeddings.

```python
from zvec.extension import DefaultLocalDenseEmbedding, DefaultLocalSparseEmbedding, RrfReRanker

dense_emb        = DefaultLocalDenseEmbedding()
sparse_query_emb = DefaultLocalSparseEmbedding(encoding_type="query")
sparse_doc_emb   = DefaultLocalSparseEmbedding(encoding_type="document")

query = "what is deep learning"

# Hybrid query with RRF fusion
results = collection.query(
    vectors=[
        zvec.VectorQuery(field_name="dense",  vector=dense_emb.embed(query)),
        zvec.VectorQuery(field_name="sparse", vector=sparse_query_emb.embed(query)),
    ],
    topk=10, reranker=RrfReRanker(topn=5),
)

# Two-stage retrieval: fast recall (top-100) -> precise cross-encoder re-ranking (top-10)
results = collection.query(
    vectors=zvec.VectorQuery(field_name="dense", vector=dense_emb.embed(query)),
    topk=100,
    reranker=DefaultLocalReRanker(query=query, rerank_field="content", topn=10),
)
```

## Node.js API

camelCase mirror of Python. No extension ecosystem — bring your own embedding pipeline (OpenAI SDK, Transformers.js). For production Node.js needing full pipeline, pgvector or a hosted option is more practical.

```javascript
const zvec = require('@zvec/zvec');
const schema = new zvec.CollectionSchema({
  name: "example",
  vectors: [new zvec.VectorSchema("embedding", zvec.DataType.VECTOR_FP32, 384)],
});
const collection = zvec.createAndOpen("./my_collection", schema);
collection.insert([new zvec.Doc("doc_1", { embedding: [0.1, 0.2, ...] })]);
const results = collection.querySync({ fieldName: "embedding", vector: [...], topk: 10 });
collection.optimize();
collection.destroy();
```

## Performance

Benchmarked on 16 vCPU / 64 GiB (g9i.4xlarge) with [VectorDBBench](https://github.com/zilliztech/VectorDBBench). Highest QPS at >95% recall on 10M Cohere benchmark. Sub-ms latency (in-process). INT8: ~25% memory vs FP32.

```bash
pip install zvec==0.1.1 vectordbbench

vectordbbench zvec --path Performance768D10M --case-type Performance768D10M \
  --num-concurrency 12,14,16,18,20 --quantize-type int8 --m 50 --ef-search 118 --is-using-refiner

vectordbbench zvec --path Performance768D1M --case-type Performance768D1M \
  --num-concurrency 12,14,16,18,20 --quantize-type int8 --m 15 --ef-search 180
```

**Note**: The "billions of vectors in milliseconds" README claim refers to Alibaba's internal Proxima deployment — not publicly verified at that scale.

## Related Resources

- [Parent: Vector Search Decision Guide](../vector-search.md) — comparison matrix, per-tenant patterns, platform support
- [PGlite - Local-First Embedded Postgres](../pglite-local-first.md) — for apps needing full SQL + pgvector
- [Zvec GitHub](https://github.com/alibaba/zvec) — source code and issues
- [Zvec Documentation](https://zvec.org/en/docs/) — official docs
- [VectorDBBench](https://github.com/zilliztech/VectorDBBench) — benchmark framework
