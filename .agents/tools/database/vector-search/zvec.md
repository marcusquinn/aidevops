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

- **Purpose**: Embedded C++ vector database (Proxima engine) for server-side similarity search without a separate DB service
- **Python**: `pip install zvec` (Python 3.10-3.12)
- **Node.js**: `npm install @zvec/zvec` (early stage — core ops only, no extension ecosystem)
- **Platforms**: Linux x86_64/ARM64, macOS ARM64. No Windows.
- **Repo**: <https://github.com/alibaba/zvec> (8.4k stars, Apache-2.0)
- **Docs**: <https://zvec.org/en/docs/>
- **Parent guide**: `tools/database/vector-search.md` — decision flowchart, comparison matrix, per-tenant isolation patterns, platform support matrix

**When to use**: In-process vector search for SaaS RAG where each tenant uploads documents. Zero network hop, collection-per-tenant isolation, built-in embedding functions and rerankers.

**When NOT to use**: Browser/WASM (native C++ binary), Windows servers, distributed multi-node clusters (use Milvus/Qdrant), already on Postgres (use pgvector), datasets >100M vectors needing distributed sharding.

<!-- AI-CONTEXT-END -->

## Installation

```bash
pip install zvec                    # Python 3.10-3.12
npm install @zvec/zvec              # Node.js (early stage)
pip install sentence-transformers   # Local dense + sparse (SPLADE), ~80-100MB models
pip install dashtext                # BM25 sparse embeddings
pip install openai                  # OpenAI or Jina (OpenAI-compatible)
pip install dashscope               # Qwen embeddings
```

## Core Concepts

- **Collection**: Named container for documents (analogous to a table), lives at a filesystem path. One process per collection.
- **Document** (`Doc`): A record with a string `id`, scalar fields, and one or more vector fields
- **Schema**: Defines scalar fields (`FieldSchema`) and vector fields (`VectorSchema`)

```text
Your App Process
  +-- zvec (in-process C++ library)
        +-- Collection A (tenant_1)  -->  /data/vectors/tenant_1/
        +-- Collection B (tenant_2)  -->  /data/vectors/tenant_2/
```

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

### Schema Evolution (DDL)

No downtime, data re-ingestion, or reindexing required.

```python
collection.add_column(field_schema=zvec.FieldSchema("rating", zvec.DataType.INT32), expression="5")
collection.drop_column(field_name="old_field")          # Irreversible
collection.alter_column(old_name="publish_year", new_name="release_year")
collection.alter_column(field_schema=zvec.FieldSchema("rating", zvec.DataType.FLOAT))
```

**Limitations**: Cannot add or drop vector fields (coming soon). `add_column()` supports numerical scalar types only.

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

All writes are immediately visible — real-time, no eventual consistency delay.

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

## Embedding Functions

No separate embedding service needed. All functions are thread-safe. Local models download on first use. Text modality only.

### Local (No API Key)

| Function | Model | Dimensions | Dependency |
|----------|-------|------------|------------|
| `DefaultLocalDenseEmbedding` | all-MiniLM-L6-v2 | 384 | `sentence-transformers` (~80MB) |
| `DefaultLocalSparseEmbedding` | SPLADE cocondenser | ~30k (sparse) | `sentence-transformers` (~100MB) |
| `BM25EmbeddingFunction` | DashText BM25 | variable (sparse) | `dashtext` |

```python
from zvec.extension import DefaultLocalDenseEmbedding, DefaultLocalSparseEmbedding, BM25EmbeddingFunction

emb    = DefaultLocalDenseEmbedding()                                  # Downloads ~80MB on first run
emb_ms = DefaultLocalDenseEmbedding(model_source="modelscope")         # China mirror
DefaultLocalDenseEmbedding.clear_cache()                               # Release model memory

# SPLADE — asymmetric: separate query/document encoders
query_emb = DefaultLocalSparseEmbedding(encoding_type="query")
doc_emb   = DefaultLocalSparseEmbedding(encoding_type="document")

bm25 = BM25EmbeddingFunction(corpus=["doc1...", "doc2..."], encoding_type="document", b=0.75, k1=1.2)
```

### API-Based

| Function | Provider | Dimensions | Env var |
|----------|----------|------------|---------|
| `OpenAIDenseEmbedding` | OpenAI | 1536 (default) | `OPENAI_API_KEY` |
| `JinaDenseEmbedding` | Jina AI | 768-1024 (Matryoshka) | `JINA_API_KEY` |
| `QwenDenseEmbedding` | Alibaba Qwen | varies | `DASHSCOPE_API_KEY` |
| `QwenSparseEmbedding` | Alibaba Qwen | sparse | `DASHSCOPE_API_KEY` |

```python
from zvec.extension import OpenAIDenseEmbedding, JinaDenseEmbedding, QwenDenseEmbedding, QwenSparseEmbedding

emb = OpenAIDenseEmbedding(model="text-embedding-3-small", dimension=256)

# Jina (Matryoshka: 32-1024 dims; 32K context; tasks: retrieval.query, retrieval.passage, text-matching, classification, separation)
query_emb = JinaDenseEmbedding(model="jina-embeddings-v5-text-small", dimension=256, task="retrieval.query")
doc_emb   = JinaDenseEmbedding(model="jina-embeddings-v5-text-small", dimension=256, task="retrieval.passage")

dense_emb  = QwenDenseEmbedding(256, model="text-embedding-v3")
sparse_emb = QwenSparseEmbedding(dimension=256)
```

## Rerankers

All reranking functions are thread-safe.

| Reranker | When to use |
|----------|-------------|
| `RrfReRanker` | Multi-vector fusion (dense + sparse). No model needed. |
| `WeightedReRanker` | Multi-vector with configurable weights. No model needed. |
| `DefaultLocalReRanker` | Single-vector results needing deep semantic re-ranking. Local, free. |
| `QwenReRanker` | API-based re-ranking with Qwen models. |

```python
from zvec.extension import RrfReRanker, WeightedReRanker, DefaultLocalReRanker, QwenReRanker
from zvec import MetricType

reranker = RrfReRanker(topn=10, rank_constant=60)                     # RRF: score = 1/(k+rank+1)
reranker = WeightedReRanker(topn=10, metric=MetricType.COSINE, weights={"dense_emb": 0.7, "sparse_emb": 0.3})
reranker = DefaultLocalReRanker(query="q", topn=5, rerank_field="title", model_name="cross-encoder/ms-marco-MiniLM-L6-v2", device="cuda")
reranker = QwenReRanker(query="q", model="gte-rerank-v2", topn=10, rerank_field="content")
```

## Hybrid Search

Combine dense semantic search with sparse lexical matching. Schema needs both vector fields (see Schema section); insert docs with both embeddings populated.

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

# Two-stage retrieval: fast recall (top-100) → precise cross-encoder re-ranking (top-10)
results = collection.query(
    vectors=zvec.VectorQuery(field_name="dense", vector=dense_emb.embed(query)),
    topk=100,
    reranker=DefaultLocalReRanker(query=query, rerank_field="content", topn=10),
)
```

## Node.js API

Mirrors Python with camelCase names. The Python extension ecosystem (embedding functions, rerankers) has **no Node.js equivalent** — bring your own embedding pipeline (OpenAI SDK, Transformers.js). For production Node.js needing the full pipeline, pgvector or a hosted option is more practical.

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

Benchmarked using [VectorDBBench](https://github.com/zilliztech/VectorDBBench) on 16 vCPU / 64 GiB (g9i.4xlarge). Highest QPS among tested databases at >95% recall on 10M Cohere benchmark. Sub-millisecond search latency (in-process). INT8 quantization: ~25% memory vs FP32.

```bash
pip install zvec==0.1.1 vectordbbench

vectordbbench zvec --path Performance768D10M --case-type Performance768D10M \
  --num-concurrency 12,14,16,18,20 --quantize-type int8 --m 50 --ef-search 118 --is-using-refiner

vectordbbench zvec --path Performance768D1M --case-type Performance768D1M \
  --num-concurrency 12,14,16,18,20 --quantize-type int8 --m 15 --ef-search 180
```

**Note**: The "billions of vectors in milliseconds" README claim refers to Alibaba's internal Proxima deployment — not publicly verified at that scale.

## Gotchas

1. **Very new** — December 2025. APIs may change. Small community.
2. **Python-first** — Node.js bindings are early stage with no extension ecosystem.
3. **No Windows** — Linux and macOS ARM64 only.
4. **Single-process** — Only one process can open a collection at a time.
5. **No ACID** — Use application-level locking for concurrent writes.
6. **Memory per collection** — Use LRU cache to close idle tenant collections.
7. **CPU compatibility** — Precompiled wheels likely require AVX-512; fails with `Illegal instruction` (exit 132) on AMD Zen 2 (AVX2 only). Verified on zvec 0.2.0, Python 3.12.3. Use pgvector or a hosted alternative on AMD Ryzen/EPYC Zen 2 servers.

## Related Resources

- [Parent: Vector Search Decision Guide](../vector-search.md) — comparison matrix, per-tenant patterns, platform support
- [PGlite - Local-First Embedded Postgres](../pglite-local-first.md) — for apps needing full SQL + pgvector
- [Zvec GitHub](https://github.com/alibaba/zvec) — source code and issues
- [Zvec Documentation](https://zvec.org/en/docs/) — official docs
- [VectorDBBench](https://github.com/zilliztech/VectorDBBench) — benchmark framework
