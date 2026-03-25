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
- **Node.js**: `npm install @zvec/zvec`
- **Platforms**: Linux x86_64/ARM64, macOS ARM64
- **Repo**: <https://github.com/alibaba/zvec> (8.4k stars, Apache-2.0)
- **Docs**: <https://zvec.org/en/docs/>

**When to use Zvec**: In-process vector search for a SaaS app where each tenant uploads documents for RAG. Runs in the same process (zero network hop), supports collection-per-tenant isolation, ships with built-in embedding functions and rerankers.

**When NOT to use Zvec**:
- Browser/WASM apps (native C++ binary, not WASM)
- Windows servers (Linux and macOS ARM64 only)
- Distributed multi-node clusters (use Milvus or Qdrant)
- Already on Postgres and want to avoid a second data store (use pgvector)
- Datasets >100M vectors per collection needing distributed sharding

<!-- AI-CONTEXT-END -->

## Installation

```bash
pip install zvec                    # Python 3.10-3.12
npm install @zvec/zvec              # Node.js

# Optional: local embeddings
pip install sentence-transformers   # Dense + sparse (SPLADE)
pip install dashtext                # BM25 sparse embeddings

# Optional: API-based embeddings
pip install openai                  # OpenAI or Jina (OpenAI-compatible)
pip install dashscope               # Qwen embeddings
pip install modelscope              # ModelScope mirror (China)
```

## Core Concepts

```text
Your App Process
  +-- zvec (in-process C++ library via Python/Node.js bindings)
        +-- Collection A (tenant_1)  -->  /data/vectors/tenant_1/
        +-- Collection B (tenant_2)  -->  /data/vectors/tenant_2/
        +-- No network hop, no separate server process
```

- **Collection**: Named container for documents (analogous to a table), lives at a filesystem path
- **Document** (`Doc`): A record with a string `id`, scalar fields, and one or more vector fields
- **Schema**: Defines scalar fields (`FieldSchema`) and vector fields (`VectorSchema`)

## Collection Schema

### Data Types

**Scalar**: `INT32`, `INT64`, `UINT32`, `UINT64`, `FLOAT`, `DOUBLE`, `STRING`, `BOOL`, `ARRAY_INT32`, `ARRAY_STRING`, etc.

**Vector**:

| Type | Constant | Use case |
|------|----------|----------|
| FP32 dense | `DataType.VECTOR_FP32` | Default for most embeddings |
| FP16 dense | `DataType.VECTOR_FP16` | Half memory, slight precision loss |
| INT8 dense | `DataType.VECTOR_INT8` | Quantized (4x memory reduction) |
| FP32 sparse | `DataType.SPARSE_VECTOR_FP32` | BM25/SPLADE sparse vectors |
| FP16 sparse | `DataType.SPARSE_VECTOR_FP16` | Sparse with half precision |

### Schema Definition

```python
import zvec

schema = zvec.CollectionSchema(
    name="documents",
    fields=[
        zvec.FieldSchema("title", zvec.DataType.STRING, nullable=True),
        zvec.FieldSchema("category", zvec.DataType.STRING, nullable=False),
        zvec.FieldSchema(
            name="price",
            data_type=zvec.DataType.INT32,
            index_param=zvec.InvertIndexParam(enable_range_optimization=True),
        ),
    ],
    vectors=[
        zvec.VectorSchema(
            name="embedding",
            data_type=zvec.DataType.VECTOR_FP32,
            dimension=384,
            index_param=zvec.HnswIndexParam(metric_type=zvec.MetricType.COSINE),
        ),
        zvec.VectorSchema("sparse_emb", zvec.DataType.SPARSE_VECTOR_FP32),
    ],
)
```

## Index Types

| Index | Class | Best for | Trade-off |
|-------|-------|----------|-----------|
| **HNSW** | `HnswIndexParam` | General use, <50M vectors | High recall, higher memory |
| **IVF** | `IVFIndexParam` | Memory-constrained, >10M vectors | Lower memory, slightly lower recall |
| **Flat** | `FlatIndexParam` | Small collections (<100k), exact search | Exact results, O(n) search |

```python
# HNSW parameters
zvec.HnswIndexParam(
    metric_type=zvec.MetricType.COSINE,  # L2, IP, or COSINE
    ef_construction=200,  # Build-time quality (higher = better recall, slower build)
    m=16,                 # Max connections per node (higher = better recall, more memory)
)
zvec.HnswQueryParam(ef=300)  # Search-time quality

# IVF parameters
zvec.IVFIndexParam(nlist=1024)  # sqrt(n) is a good starting point
zvec.IVFQueryParam(nprobe=64)   # Clusters to search

# Manage indexes after creation
collection.create_index(field_name="embedding", index_param=zvec.HnswIndexParam(...))
collection.create_index(field_name="category", index_param=zvec.InvertIndexParam())
collection.drop_index(field_name="category")  # Scalar only; vector indexes cannot be dropped
```

## Quantization

INT8 quantization reduces memory by ~4x with >95% recall when combined with a refiner:

```python
zvec.VectorSchema("embedding", zvec.DataType.VECTOR_INT8, dimension=384)
# Benchmark: vectordbbench zvec --quantize-type int8 --is-using-refiner
```

## Built-in Embedding Functions

Zvec ships with embedding functions — no separate embedding service needed.

### Local Embeddings (No API Key)

| Function | Model | Dimensions | Dependency |
|----------|-------|------------|------------|
| `DefaultLocalDenseEmbedding` | all-MiniLM-L6-v2 | 384 | `sentence-transformers` (~80MB) |
| `DefaultLocalSparseEmbedding` | SPLADE cocondenser | ~30k (sparse) | `sentence-transformers` (~100MB) |
| `BM25EmbeddingFunction` | DashText BM25 | variable (sparse) | `dashtext` |

```python
from zvec.extension import DefaultLocalDenseEmbedding, DefaultLocalSparseEmbedding, BM25EmbeddingFunction

# Dense
emb = DefaultLocalDenseEmbedding()  # Downloads ~80MB on first run
emb_ms = DefaultLocalDenseEmbedding(model_source="modelscope")  # China mirror
DefaultLocalDenseEmbedding.clear_cache()  # Release model memory

# Sparse (SPLADE — asymmetric: separate query/document encoders)
query_emb = DefaultLocalSparseEmbedding(encoding_type="query")
doc_emb = DefaultLocalSparseEmbedding(encoding_type="document")

# BM25
bm25 = BM25EmbeddingFunction(language="en", encoding_type="query")
bm25_custom = BM25EmbeddingFunction(
    corpus=["doc1...", "doc2..."],
    encoding_type="document",
    b=0.75, k1=1.2,
)
```

### API-Based Embeddings

| Function | Provider | Dimensions | Env var |
|----------|----------|------------|---------|
| `OpenAIDenseEmbedding` | OpenAI | 1536 (default) | `OPENAI_API_KEY` |
| `JinaDenseEmbedding` | Jina AI | 768-1024 (Matryoshka) | `JINA_API_KEY` |
| `QwenDenseEmbedding` | Alibaba Qwen | varies | `DASHSCOPE_API_KEY` |
| `QwenSparseEmbedding` | Alibaba Qwen | sparse | `DASHSCOPE_API_KEY` |

```python
from zvec.extension import OpenAIDenseEmbedding, JinaDenseEmbedding, QwenDenseEmbedding, QwenSparseEmbedding

# OpenAI
emb = OpenAIDenseEmbedding(model="text-embedding-3-small", dimension=256)

# Jina (Matryoshka: 32, 64, 128, 256, 512, 768, 1024 dims; 32K context)
query_emb = JinaDenseEmbedding(model="jina-embeddings-v5-text-small", dimension=256, task="retrieval.query")
doc_emb   = JinaDenseEmbedding(model="jina-embeddings-v5-text-small", dimension=256, task="retrieval.passage")
# Other tasks: text-matching, classification, separation

# Qwen
dense_emb  = QwenDenseEmbedding(256, model="text-embedding-v3")
sparse_emb = QwenSparseEmbedding(dimension=256)
```

**Notes**: All embedding functions are thread-safe. Local models download on first use. Call `clear_cache()` to release model memory. Text modality only.

## Rerankers

### Selection Guide

| Reranker | When to use |
|----------|-------------|
| `RrfReRanker` | Multi-vector fusion (dense + sparse). No model needed. |
| `WeightedReRanker` | Multi-vector with configurable weights. No model needed. |
| `DefaultLocalReRanker` | Single-vector results needing deep semantic re-ranking. Local, free. |
| `QwenReRanker` | API-based re-ranking with Qwen models. |

```python
from zvec.extension import RrfReRanker, WeightedReRanker, DefaultLocalReRanker, QwenReRanker
from zvec import MetricType

# RRF: score = 1 / (k + rank + 1)
reranker = RrfReRanker(topn=10, rank_constant=60)

# Weighted: normalizes scores by metric type
reranker = WeightedReRanker(topn=10, metric=MetricType.COSINE, weights={"dense_emb": 0.7, "sparse_emb": 0.3})

# Cross-encoder (most accurate, slower; ~80MB model)
reranker = DefaultLocalReRanker(
    query="machine learning algorithms",
    topn=5,
    rerank_field="title",
    model_name="cross-encoder/ms-marco-MiniLM-L6-v2",
    device="cuda",  # Optional GPU
)

# Qwen API
reranker = QwenReRanker(query="search query", model="gte-rerank-v2", topn=10, rerank_field="content")
```

All reranking functions are thread-safe.

## Hybrid Search

Combine dense semantic search with sparse lexical matching in a single query.

```python
import zvec
from zvec.extension import DefaultLocalDenseEmbedding, DefaultLocalSparseEmbedding, RrfReRanker

dense_emb = DefaultLocalDenseEmbedding()
sparse_query_emb = DefaultLocalSparseEmbedding(encoding_type="query")
sparse_doc_emb   = DefaultLocalSparseEmbedding(encoding_type="document")

schema = zvec.CollectionSchema(
    name="hybrid_docs",
    fields=[zvec.FieldSchema("content", zvec.DataType.STRING)],
    vectors=[
        zvec.VectorSchema("dense",  zvec.DataType.VECTOR_FP32, dimension=dense_emb.dimension),
        zvec.VectorSchema("sparse", zvec.DataType.SPARSE_VECTOR_FP32),
    ],
)
collection = zvec.create_and_open(path="./hybrid_example", schema=schema)

# Insert
collection.insert([
    zvec.Doc(id=f"doc_{i}", fields={"content": text},
             vectors={"dense": dense_emb.embed(text), "sparse": sparse_doc_emb.embed(text)})
    for i, text in enumerate(docs)
])

# Hybrid query with RRF
query = "what is deep learning"
results = collection.query(
    vectors=[
        zvec.VectorQuery(field_name="dense",  vector=dense_emb.embed(query)),
        zvec.VectorQuery(field_name="sparse", vector=sparse_query_emb.embed(query)),
    ],
    topk=10,
    reranker=RrfReRanker(topn=5),
)
```

### Two-Stage Retrieval Pattern

```python
# Stage 1: Fast recall (top-100 candidates)
# Stage 2: Precise cross-encoder re-ranking (top-10 final)
reranker = DefaultLocalReRanker(query=query, rerank_field="content", topn=10)
results = collection.query(
    vectors=zvec.VectorQuery(field_name="dense", vector=dense_emb.embed(query)),
    topk=100,
    reranker=reranker,
)
```

## Python API Reference

### Initialization

```python
zvec.init()  # Auto-detect resources

# Production
zvec.init(
    log_type=zvec.LogType.FILE,
    log_dir="/var/log/zvec",
    log_level=zvec.LogLevel.WARN,
    query_threads=4,       # None = auto-detect from CPU/cgroup
    optimize_threads=2,
    memory_limit_mb=2048,  # None = auto from cgroup
)
```

`init()` can only be called once (subsequent calls raise `RuntimeError`). Parameters set to `None` fall back to cgroup-aware defaults (Docker/K8s friendly). Call at application startup.

### Collection Lifecycle

```python
collection = zvec.create_and_open(path="./my_collection", schema=schema)
collection = zvec.open(path="./my_collection")

print(collection.schema)  # Schema definition
print(collection.stats)   # Doc count, size, etc.
collection.optimize()     # Merge segments, rebuild indexes
collection.destroy()      # Irreversible — deletes all data
```

### CRUD Operations

```python
# Insert / upsert / update
collection.insert(zvec.Doc(id="doc_1", fields={"title": "Example"}, vectors={"embedding": [0.1, 0.2, ...]}))
collection.insert([doc1, doc2, doc3])                          # Batch
collection.upsert(zvec.Doc(id="doc_1", fields={"title": "Updated"}))
collection.update(zvec.Doc(id="doc_1", fields={"category": "science"}))  # Partial

# Fetch / delete
docs = collection.fetch("doc_1")
docs = collection.fetch(["doc_1", "doc_2"])
collection.delete(ids="doc_1")
collection.delete(ids=["doc_1", "doc_2"])
collection.delete_by_filter(filter="publish_year < 1900")
```

### Query API

All writes are immediately visible — real-time, no eventual consistency delay.

```python
# Single-vector search
results = collection.query(
    vectors=zvec.VectorQuery(field_name="embedding", vector=[0.1, 0.2, ...]),
    topk=10,
    filter="category == 'tech' AND publish_year > 2020",
    include_vector=False,
    output_fields=["title"],
    reranker=None,
)

# Query by stored document ID (reuse stored vector)
results = collection.query(
    vectors=zvec.VectorQuery(field_name="embedding", id="doc_1"),
    topk=10,
)

# Multi-vector with index-specific params
results = collection.query(
    vectors=[
        zvec.VectorQuery(field_name="dense",  vector=dense_vec, param=zvec.HnswQueryParam(ef=300)),
        zvec.VectorQuery(field_name="sparse", vector=sparse_vec),
    ],
    topk=50,
    reranker=RrfReRanker(topn=10),
)

# Filter-only (no vector search)
results = collection.query(filter="publish_year < 1999", topk=50)
```

### Schema Evolution (DDL)

Schema changes without downtime, data re-ingestion, or reindexing.

```python
collection.add_column(field_schema=zvec.FieldSchema("rating", zvec.DataType.INT32), expression="5")
collection.drop_column(field_name="old_field")          # Irreversible
collection.alter_column(old_name="publish_year", new_name="release_year")
collection.alter_column(field_schema=zvec.FieldSchema("rating", zvec.DataType.FLOAT))
```

**Limitations**: Cannot add or drop vector fields (coming soon). `add_column()` supports numerical scalar types only.

## Node.js API

The `@zvec/zvec` Node.js API mirrors Python with camelCase names and async operations where applicable.

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

**Note**: Node.js bindings are less mature than Python. Python is recommended for production RAG pipelines.

## Collection-Per-Tenant Pattern

Each tenant gets a dedicated collection with its own data files on disk.

| Property | Benefit |
|----------|---------|
| Physical isolation | Separate files — no data leakage risk |
| Independent lifecycle | Create/destroy with a single function call |
| No metadata filtering | No `WHERE tenant_id = ?` on every query |
| Simple backup/restore | Copy/delete a directory |

```python
from pathlib import Path
import zvec

VECTOR_DATA_ROOT = Path("/data/vectors")

def create_tenant_collection(org_id: str, dimension: int = 384) -> zvec.Collection:
    schema = zvec.CollectionSchema(
        name=f"tenant_{org_id}",
        fields=[
            zvec.FieldSchema("content_chunk", zvec.DataType.STRING),
            zvec.FieldSchema("source_file",   zvec.DataType.STRING),
            zvec.FieldSchema("chunk_index",   zvec.DataType.INT32),
        ],
        vectors=[zvec.VectorSchema("embedding", zvec.DataType.VECTOR_FP32, dimension=dimension)],
    )
    return zvec.create_and_open(path=str(VECTOR_DATA_ROOT / org_id), schema=schema)

def open_tenant_collection(org_id: str) -> zvec.Collection:
    return zvec.open(path=str(VECTOR_DATA_ROOT / org_id))

def destroy_tenant_collection(org_id: str) -> None:
    open_tenant_collection(org_id).destroy()
```

**Scaling**:
- **<10k tenants**: Collection-per-tenant works well
- **10k-100k tenants**: Lazy loading — open collections for active tenants only (TTL cache)
- **>100k tenants**: Namespace-based isolation or hosted solution (file descriptor limits)

## Performance Benchmarks

Benchmarked using [VectorDBBench](https://github.com/zilliztech/VectorDBBench) on 16 vCPU / 64 GiB (g9i.4xlarge).

| Metric | Value | Notes |
|--------|-------|-------|
| Search latency | Sub-millisecond | In-process, no network hop |
| Index build | Fastest in VectorDBBench | Parallel C++ indexing |
| Memory efficiency | ~4x reduction with INT8 | Quantization + refiner maintains recall |
| Recall | >95% at high QPS | HNSW + INT8 + refiner |

Zvec achieves the highest QPS among tested databases at >95% recall on the 10M Cohere benchmark.

```bash
# Reproduce benchmarks
pip install zvec==0.1.1 vectordbbench

vectordbbench zvec --path Performance768D10M --case-type Performance768D10M \
  --num-concurrency 12,14,16,18,20 --quantize-type int8 --m 50 --ef-search 118 --is-using-refiner

vectordbbench zvec --path Performance768D1M --case-type Performance768D1M \
  --num-concurrency 12,14,16,18,20 --quantize-type int8 --m 15 --ef-search 180
```

## Metric Types

| Metric | Constant | Description |
|--------|----------|-------------|
| L2 (Euclidean) | `MetricType.L2` | Lower = more similar |
| Inner Product | `MetricType.IP` | Higher = more similar |
| Cosine | `MetricType.COSINE` | Higher = more similar |

## Comparison with Alternatives

| Feature | Zvec | pgvector | Qdrant | Milvus | Pinecone |
|---------|------|----------|--------|--------|----------|
| Deployment | In-process | Postgres extension | Server | Distributed | Hosted |
| Network hop | None | Yes | Yes | Yes | Yes |
| Built-in embeddings | Yes | No | No | No | No |
| Built-in rerankers | Yes | No | No | No | No |
| Hybrid search | Native | Via tsvector | Yes | Yes | Yes |
| Tenant isolation | Collection/dir | RLS/schema | Collection | Collection | Namespace |
| Horizontal scaling | No | Limited | Yes | Yes | Yes |
| Ops overhead | None | Postgres admin | Server admin | Complex | None (hosted) |
| License | Apache 2.0 | PostgreSQL | Apache 2.0 | Apache 2.0 | Proprietary |

## Related Resources

- [PGlite - Local-First Embedded Postgres](../pglite-local-first.md) — For apps needing full SQL + pgvector
- [Zvec GitHub](https://github.com/alibaba/zvec) — Source code and issues
- [Zvec Documentation](https://zvec.org/en/docs/) — Official docs
- [VectorDBBench](https://github.com/zilliztech/VectorDBBench) — Benchmark framework
