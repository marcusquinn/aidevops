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
- **License**: Apache 2.0

**When to use Zvec**: You need in-process vector search for a SaaS app where each tenant uploads documents for RAG. Zvec runs in the same process as your app server (zero network hop), supports collection-per-tenant isolation, and ships with built-in embedding functions and rerankers.

**When NOT to use Zvec**:

- Browser/WASM apps (native C++ binary, not WASM)
- Windows servers (Linux and macOS ARM64 only)
- Distributed multi-node clusters (single-process; use Milvus or Qdrant for horizontal scaling)
- You already run Postgres and want to avoid a second data store (use pgvector)
- Datasets >100M vectors per collection where you need distributed sharding

<!-- AI-CONTEXT-END -->

## Installation

### Python

```bash
pip install zvec
```

Requires Python 3.10, 3.11, or 3.12. Installs a native C++ extension via prebuilt wheels.

### Node.js

```bash
npm install @zvec/zvec
```

### Optional dependencies for embedding/reranking

```bash
# Local dense + sparse embeddings (Sentence Transformers)
pip install sentence-transformers

# BM25 sparse embeddings
pip install dashtext

# OpenAI embeddings
pip install openai

# Jina embeddings
pip install openai  # Jina uses OpenAI-compatible API

# Qwen embeddings (DashScope)
pip install dashscope

# ModelScope model source (alternative to Hugging Face for China)
pip install modelscope
```

## Core Concepts

### Architecture

```text
Your App Process
  |
  +-- zvec (in-process C++ library via Python/Node.js bindings)
  |     |
  |     +-- Collection A (tenant_1)  -->  /data/vectors/tenant_1/
  |     +-- Collection B (tenant_2)  -->  /data/vectors/tenant_2/
  |     +-- Collection C (tenant_3)  -->  /data/vectors/tenant_3/
  |
  +-- No network hop, no separate server process
```

### Data Model

- **Collection**: Named container for documents (analogous to a table). Each collection has a schema and lives at a filesystem path.
- **Document** (`Doc`): A record with a string `id`, scalar fields, and one or more vector fields.
- **Schema**: Defines scalar fields (`FieldSchema`) and vector fields (`VectorSchema`) for a collection.

## Collection Schema

### Scalar Data Types

| Type | Constant | Notes |
|------|----------|-------|
| 32-bit int | `DataType.INT32` | |
| 64-bit int | `DataType.INT64` | |
| 32-bit uint | `DataType.UINT32` | |
| 64-bit uint | `DataType.UINT64` | |
| Float | `DataType.FLOAT` | 32-bit |
| Double | `DataType.DOUBLE` | 64-bit |
| String | `DataType.STRING` | |
| Boolean | `DataType.BOOL` | |
| Array types | `DataType.ARRAY_INT32`, `ARRAY_STRING`, etc. | Typed arrays |

### Vector Data Types

| Type | Constant | Use case |
|------|----------|----------|
| FP32 dense | `DataType.VECTOR_FP32` | Default for most embeddings |
| FP16 dense | `DataType.VECTOR_FP16` | Half memory, slight precision loss |
| INT8 dense | `DataType.VECTOR_INT8` | Quantized (4x memory reduction) |
| FP32 sparse | `DataType.SPARSE_VECTOR_FP32` | BM25/SPLADE sparse vectors |
| FP16 sparse | `DataType.SPARSE_VECTOR_FP16` | Sparse with half precision |

### Schema Definition (Python)

```python
import zvec

schema = zvec.CollectionSchema(
    name="documents",
    fields=[
        zvec.FieldSchema("title", zvec.DataType.STRING, nullable=True),
        zvec.FieldSchema("category", zvec.DataType.STRING, nullable=False),
        zvec.FieldSchema("publish_year", zvec.DataType.INT32, nullable=True),
    ],
    vectors=[
        zvec.VectorSchema("dense_emb", zvec.DataType.VECTOR_FP32, dimension=384),
        zvec.VectorSchema("sparse_emb", zvec.DataType.SPARSE_VECTOR_FP32),
    ],
)
```

### Schema with Index Parameters

```python
schema = zvec.CollectionSchema(
    name="documents",
    fields=[
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
    ],
)
```

## Index Types

### Vector Indexes

| Index | Class | Best for | Trade-off |
|-------|-------|----------|-----------|
| **HNSW** | `HnswIndexParam` | General use, <50M vectors | High recall, higher memory |
| **IVF** | `IVFIndexParam` | Memory-constrained, >10M vectors | Lower memory, slightly lower recall |
| **Flat** | `FlatIndexParam` | Small collections (<100k), exact search | Exact results, O(n) search |

### HNSW Parameters

```python
zvec.HnswIndexParam(
    metric_type=zvec.MetricType.COSINE,  # Distance metric (L2, IP, COSINE)
    ef_construction=200,  # Build-time quality (higher = better recall, slower build)
    m=16,                 # Max connections per node (higher = better recall, more memory)
)

# Query-time parameter
zvec.HnswQueryParam(
    ef=300,  # Search-time quality (higher = better recall, slower query)
)
```

### IVF Parameters

```python
zvec.IVFIndexParam(
    nlist=1024,  # Number of clusters (sqrt(n) is a good starting point)
)

# Query-time parameter
zvec.IVFQueryParam(
    nprobe=64,  # Clusters to search (higher = better recall, slower query)
)
```

### Scalar Indexes

```python
# Inverted index for scalar fields (enables fast filtering)
zvec.InvertIndexParam()
```

### Creating Indexes After Collection Creation

```python
# Replace or create a vector index
collection.create_index(
    field_name="embedding",
    index_param=zvec.HnswIndexParam(metric_type=zvec.MetricType.COSINE),
)

# Create an inverted index on a scalar field for filtering
collection.create_index(
    field_name="category",
    index_param=zvec.InvertIndexParam(),
)

# Drop a scalar field index (vector indexes cannot be dropped)
collection.drop_index(field_name="category")
```

## Quantization

Zvec supports INT8 quantization for reduced memory usage:

```python
# Use VECTOR_INT8 data type in schema for 4x memory reduction
zvec.VectorSchema("embedding", zvec.DataType.VECTOR_INT8, dimension=384)
```

For benchmarks, INT8 quantization is used with a refiner for maintaining recall:

```bash
# Benchmark command showing INT8 + refiner usage
vectordbbench zvec --quantize-type int8 --is-using-refiner
```

INT8 quantization reduces memory by ~4x compared to FP32 while maintaining >95% recall when combined with a refiner pass.

## Dense and Sparse Vectors

Zvec natively supports both dense and sparse vectors in the same collection, enabling hybrid search in a single query.

### Dense Vectors

Standard fixed-dimension float vectors from embedding models (Sentence Transformers, OpenAI, Jina, etc.).

```python
zvec.VectorSchema("dense", zvec.DataType.VECTOR_FP32, dimension=384)
```

### Sparse Vectors

Variable-length vectors where most dimensions are zero (BM25, SPLADE). Stored as `{index: weight}` dictionaries.

```python
zvec.VectorSchema("sparse", zvec.DataType.SPARSE_VECTOR_FP32)
# No dimension needed -- sparse vectors have variable length
```

## Built-in Embedding Functions

Zvec ships with embedding functions that run locally or call APIs. No separate embedding service needed.

### Local Embeddings (No API Key)

| Function | Model | Dimensions | Speed | Dependency |
|----------|-------|------------|-------|------------|
| `DefaultLocalDenseEmbedding` | all-MiniLM-L6-v2 | 384 | ~1k sent/sec CPU | `sentence-transformers` (~80MB) |
| `DefaultLocalSparseEmbedding` | SPLADE cocondenser | ~30k (sparse) | ~500 sent/sec CPU | `sentence-transformers` (~100MB) |
| `BM25EmbeddingFunction` | DashText BM25 | variable (sparse) | Fast | `dashtext` |

### API-Based Embeddings

| Function | Provider | Dimensions | Env var |
|----------|----------|------------|---------|
| `OpenAIDenseEmbedding` | OpenAI | 1536 (default) | `OPENAI_API_KEY` |
| `JinaDenseEmbedding` | Jina AI | 768 (nano) / 1024 (small) | `JINA_API_KEY` |
| `QwenDenseEmbedding` | Alibaba Qwen | varies | `DASHSCOPE_API_KEY` |
| `QwenSparseEmbedding` | Alibaba Qwen | sparse | `DASHSCOPE_API_KEY` |

### Local Dense Embedding Example

```python
from zvec.extension import DefaultLocalDenseEmbedding

emb = DefaultLocalDenseEmbedding()  # Downloads all-MiniLM-L6-v2 on first run (~80MB)
vector = emb.embed("Machine learning is a subset of AI")
len(vector)  # 384

# Use ModelScope mirror (recommended for China)
emb_ms = DefaultLocalDenseEmbedding(model_source="modelscope")

# Release model memory when done
DefaultLocalDenseEmbedding.clear_cache()
```

### Local Sparse Embedding (SPLADE)

```python
from zvec.extension import DefaultLocalSparseEmbedding

# Query encoding (asymmetric retrieval)
query_emb = DefaultLocalSparseEmbedding(encoding_type="query")
query_vec = query_emb.embed("what is machine learning")
# Returns: {10: 0.45, 23: 0.87, 56: 0.32, ...}  (only non-zero dims)

# Document encoding
doc_emb = DefaultLocalSparseEmbedding(encoding_type="document")
doc_vec = doc_emb.embed("Machine learning is a branch of artificial intelligence...")
```

### BM25 Embedding

```python
from zvec.extension import BM25EmbeddingFunction

# Built-in encoder (no corpus needed)
bm25 = BM25EmbeddingFunction(language="en", encoding_type="query")
sparse_vec = bm25.embed("vector search algorithms")

# Custom corpus for domain-specific accuracy
bm25_custom = BM25EmbeddingFunction(
    corpus=["doc1 text...", "doc2 text...", "doc3 text..."],
    encoding_type="document",
    b=0.75,   # Length normalization [0,1]
    k1=1.2,   # Term frequency saturation
)
```

### Qwen Dense Embedding

```python
from zvec.extension import QwenDenseEmbedding

emb = QwenDenseEmbedding(
    256,                        # Required: embedding dimension (first positional arg)
    model="text-embedding-v4",  # Specify the model to use, e.g., "text-embedding-v4"
    # api_key="..."            # Or set DASHSCOPE_API_KEY env var
)
vector = emb.embed("Vector database")
```

### Qwen Sparse Embedding

```python
from zvec.extension import QwenSparseEmbedding

emb = QwenSparseEmbedding(
    dimension=256,    # Required by DashScope API
    # api_key="..."  # Or set DASHSCOPE_API_KEY env var
)
sparse_vec = emb.embed("sparse vector search")
```

### OpenAI Embedding

```python
from zvec.extension import OpenAIDenseEmbedding

emb = OpenAIDenseEmbedding(
    model="text-embedding-3-small",  # 1536 dims native, supports shortening
    dimension=256,                    # Required: embedding dimension
    # api_key="sk-..."        # Or set OPENAI_API_KEY env var
)
vector = emb.embed("Hello world")
```

### Jina Embedding (Matryoshka Dimensions)

```python
from zvec.extension import JinaDenseEmbedding

# Jina v5 supports Matryoshka dimensions: 32, 64, 128, 256, 512, 768, 1024
emb = JinaDenseEmbedding(
    model="jina-embeddings-v5-text-small",  # 1024 dims default, 32K context
    dimension=256,  # Reduce to 256 dims (4x storage savings)
    task="retrieval.query",  # Optimize for search queries
    # api_key="jina_..."  # Or set JINA_API_KEY env var
)

# For document indexing, use a separate instance
doc_emb = JinaDenseEmbedding(
    model="jina-embeddings-v5-text-small",
    dimension=256,
    task="retrieval.passage",
)
```

**Jina supported tasks:**

| Task | Use case |
|------|----------|
| `retrieval.query` | Encode search queries for retrieval |
| `retrieval.passage` | Encode documents/passages for retrieval |
| `text-matching` | Symmetric similarity (duplicate detection) |
| `classification` | Encode text for classification tasks |
| `separation` | Encode text for clustering/topic separation |

**Available models:**

| Model | Parameters | Max length | Default dims |
|-------|-----------|------------|--------------|
| `jina-embeddings-v5-text-small` | 677M | 32768 | 1024 |
| `jina-embeddings-v5-text-nano` | 239M | 8192 | 768 |

### Embedding Notes

- **Thread safety**: All embedding functions are thread-safe for multi-threaded use.
- **Model download**: Local models download on first use (~80-100MB). Ensure network connectivity.
- **Memory management**: Call `clear_cache()` on local embedding classes to release model memory.
- **Text only**: Zvec currently supports text modality embeddings only.

## Rerankers

Zvec includes built-in rerankers for refining search results, especially useful in multi-vector (hybrid) search.

### Reciprocal Rank Fusion (RRF)

Combines results from multiple vector queries without needing relevance scores. Score formula: `1 / (k + rank + 1)`.

```python
from zvec.extension import RrfReRanker

reranker = RrfReRanker(
    topn=10,
    rank_constant=60,  # Smoothing constant (higher = less impact from early ranks)
)

results = collection.query(
    vectors=[
        zvec.VectorQuery(field_name="dense_emb", vector=dense_vec),
        zvec.VectorQuery(field_name="sparse_emb", vector=sparse_vec),
    ],
    topk=50,
    reranker=reranker,
)
```

### Weighted Reranker

Combines scores from multiple vector fields with configurable weights. Normalizes scores based on metric type.

```python
from zvec.extension import WeightedReRanker
from zvec import MetricType

reranker = WeightedReRanker(
    topn=10,
    metric=MetricType.COSINE,
    weights={"dense_emb": 0.7, "sparse_emb": 0.3},
)
```

### Cross-Encoder Reranker (Local)

Uses a Sentence Transformer cross-encoder model for deep semantic re-ranking. More accurate than bi-encoder similarity but slower (evaluates query-document pairs jointly).

```python
from zvec.extension import DefaultLocalReRanker

reranker = DefaultLocalReRanker(
    query="machine learning algorithms",
    topn=5,
    rerank_field="title",  # Which document field to use for re-ranking
    model_name="cross-encoder/ms-marco-MiniLM-L6-v2",  # ~80MB, fast
    # model_name="BAAI/bge-reranker-large",  # ~560MB, highest quality
    device="cuda",  # Optional GPU acceleration
)

results = collection.query(
    vectors=zvec.VectorQuery(field_name="embedding", vector=query_vec),
    topk=50,  # Retrieve more candidates for re-ranking
    reranker=reranker,
)
```

### Qwen Reranker (API)

```python
from zvec.extension import QwenReRanker

reranker = QwenReRanker(
    query="search query",
    model="gte-rerank-v2",
    topn=10,
    rerank_field="content",
    # api_key="..."  # Or set DASHSCOPE_API_KEY env var
)
```

### Reranker Selection Guide

- **RRF / Weighted**: Use for multi-vector fusion (dense + sparse). No model needed.
- **DefaultLocalReRanker**: Use for single-vector results when you need deep semantic re-ranking. Runs locally, free.
- **QwenReRanker**: Use when you need API-based re-ranking with Qwen models.
- All reranking functions are thread-safe.

## Hybrid Search

Combine dense semantic search with sparse lexical matching in a single query for best retrieval quality.

### Full Hybrid Search Pipeline

```python
import zvec
from zvec.extension import (
    DefaultLocalDenseEmbedding,
    DefaultLocalSparseEmbedding,
    RrfReRanker,
)

# 1. Set up embedding functions
dense_emb = DefaultLocalDenseEmbedding()
sparse_query_emb = DefaultLocalSparseEmbedding(encoding_type="query")
sparse_doc_emb = DefaultLocalSparseEmbedding(encoding_type="document")

# 2. Define schema with both dense and sparse vectors
schema = zvec.CollectionSchema(
    name="hybrid_docs",
    fields=[
        zvec.FieldSchema("content", zvec.DataType.STRING),
    ],
    vectors=[
        zvec.VectorSchema("dense", zvec.DataType.VECTOR_FP32, dimension=dense_emb.dimension),
        zvec.VectorSchema("sparse", zvec.DataType.SPARSE_VECTOR_FP32),
    ],
)

# 3. Create collection and insert documents
collection = zvec.create_and_open(path="./hybrid_example", schema=schema)

docs = [
    "Machine learning is a subset of artificial intelligence.",
    "Neural networks are inspired by biological neurons.",
    "Python is a popular programming language for data science.",
]

collection.insert([
    zvec.Doc(
        id=f"doc_{i}",
        fields={"content": text},
        vectors={
            "dense": dense_emb.embed(text),
            "sparse": sparse_doc_emb.embed(text),
        },
    )
    for i, text in enumerate(docs)
])

# 4. Hybrid query with RRF reranking
query = "what is deep learning"
results = collection.query(
    vectors=[
        zvec.VectorQuery(field_name="dense", vector=dense_emb.embed(query)),
        zvec.VectorQuery(field_name="sparse", vector=sparse_query_emb.embed(query)),
    ],
    topk=10,
    reranker=RrfReRanker(topn=5),
)
```

### Two-Stage Retrieval Pattern

Use fast vector recall first, then apply precise cross-encoder re-ranking:

```python
from zvec.extension import DefaultLocalDenseEmbedding, DefaultLocalReRanker

dense_emb = DefaultLocalDenseEmbedding()
query = "machine learning tutorial"
query_vec = dense_emb.embed(query)

# Stage 1: Fast recall (top-100 candidates)
# Stage 2: Precise re-ranking (top-10 final results)
reranker = DefaultLocalReRanker(
    query=query,
    rerank_field="content",
    topn=10,
)

results = collection.query(
    vectors=zvec.VectorQuery(field_name="dense", vector=query_vec),
    topk=100,
    reranker=reranker,
)
```

## Python API Reference

### Initialization

```python
import zvec

# Initialize with defaults (auto-detect resources)
zvec.init()

# Customize for production
zvec.init(
    log_type=zvec.LogType.FILE,
    log_dir="/var/log/zvec",
    log_level=zvec.LogLevel.WARN,
    query_threads=4,          # None = auto-detect from CPU/cgroup
    optimize_threads=2,       # Background compaction threads
    memory_limit_mb=2048,     # Soft memory cap (None = auto from cgroup)
)
```

`init()` can only be called once. Subsequent calls raise `RuntimeError`. Parameters set to `None` fall back to environment-aware defaults (cgroup-friendly for Docker/K8s). Call at application startup before any collection operations.

### Collection Lifecycle

```python
# Create and open
collection = zvec.create_and_open(path="./my_collection", schema=schema)

# Open existing
collection = zvec.open(path="./my_collection")

# Inspect
print(collection.schema)   # Schema definition
print(collection.stats)    # Doc count, size, etc.
print(collection.path)     # Filesystem path

# Optimize (merge segments, rebuild indexes)
collection.optimize()

# Destroy (irreversible -- deletes all data)
collection.destroy()
```

### CRUD Operations

```python
# Insert
status = collection.insert(zvec.Doc(
    id="doc_1",
    fields={"title": "Example", "category": "tech"},
    vectors={"embedding": [0.1, 0.2, 0.3, 0.4]},
))

# Batch insert
statuses = collection.insert([doc1, doc2, doc3])

# Upsert (insert or update)
collection.upsert(zvec.Doc(id="doc_1", fields={"title": "Updated"}))

# Update (partial -- only specified fields)
collection.update(zvec.Doc(id="doc_1", fields={"category": "science"}))

# Fetch by ID
docs = collection.fetch("doc_1")           # Single
docs = collection.fetch(["doc_1", "doc_2"])  # Batch

# Delete by ID
collection.delete(ids="doc_1")
collection.delete(ids=["doc_1", "doc_2"])

# Delete by filter condition
collection.delete_by_filter(filter="publish_year < 1900")
```

### Query API

All write operations (insert, upsert, update, delete) are immediately visible for querying -- real-time, no eventual consistency delay.

```python
# Single-vector search
results = collection.query(
    vectors=zvec.VectorQuery(
        field_name="embedding",
        vector=[0.1, 0.2, 0.3, 0.4],
    ),
    topk=10,
    filter="category == 'tech' AND publish_year > 2020",
    include_vector=False,       # Whether to return vector data
    output_fields=["title"],    # Specific fields to return (None = all)
    reranker=None,              # Optional reranker
)

# Query by document ID (reuse stored vector)
results = collection.query(
    vectors=zvec.VectorQuery(field_name="embedding", id="doc_1"),
    topk=10,
)

# Multi-vector query with index-specific params
results = collection.query(
    vectors=[
        zvec.VectorQuery(
            field_name="dense",
            vector=dense_vec,
            param=zvec.HnswQueryParam(ef=300),
        ),
        zvec.VectorQuery(field_name="sparse", vector=sparse_vec),
    ],
    topk=50,
    reranker=RrfReRanker(topn=10),
)

# Conditional filtering only (no vector search)
results = collection.query(filter="publish_year < 1999", topk=50)
```

### Schema Evolution (DDL)

Schema changes are performed without downtime, data re-ingestion, or reindexing.

```python
# Add a numerical column (string/bool support coming soon)
new_field = zvec.FieldSchema(name="rating", data_type=zvec.DataType.INT32)
collection.add_column(field_schema=new_field, expression="5")  # Default for existing docs

# Drop a column (irreversible -- deletes field data from all documents)
collection.drop_column(field_name="old_field")

# Rename a column
collection.alter_column(old_name="publish_year", new_name="release_year")

# Change data type (if compatible, e.g., INT32 -> INT64)
updated = zvec.FieldSchema(name="rating", data_type=zvec.DataType.FLOAT)
collection.alter_column(field_schema=updated)
```

**Limitations**: Cannot add or drop vector fields (coming soon). `add_column()` currently only supports numerical scalar types.

## Node.js API

The Node.js API (`@zvec/zvec`) mirrors the Python API. Key differences:

- Uses camelCase method names instead of snake_case
- Async operations where applicable
- Same schema definition pattern

```javascript
const zvec = require('@zvec/zvec');

// Create collection
const schema = new zvec.CollectionSchema({
  name: "example",
  vectors: [
    new zvec.VectorSchema("embedding", zvec.DataType.VECTOR_FP32, 384),
  ],
});

const collection = zvec.createAndOpen("./my_collection", schema);

// Insert
collection.insert([
  new zvec.Doc("doc_1", { embedding: [0.1, 0.2, 0.3, ...] }),
]);

// Query
const results = collection.query(
  new zvec.VectorQuery("embedding", { vector: [0.1, 0.2, 0.3, ...] }),
  { topk: 10 }
);

// Optimize
collection.optimize();

// Destroy
collection.destroy();
```

Note: The Node.js bindings are less mature than Python. The Python API has richer embedding function and reranker support. For production RAG pipelines, Python is the recommended binding.

## Collection-Per-Tenant Pattern

Zvec's collection model maps naturally to multi-tenant SaaS isolation. Each tenant gets a dedicated collection with its own data files on disk.

### Why Collection-Per-Tenant

| Property | Benefit |
|----------|---------|
| Physical isolation | Each tenant's vectors in separate files -- no data leakage risk |
| Independent lifecycle | Create/destroy a tenant's data with a single function call |
| No metadata filtering | No `WHERE tenant_id = ?` on every query -- the collection IS the tenant |
| Independent optimization | Optimize one tenant's index without affecting others |
| Simple backup/restore | Copy/delete a directory to backup/restore a tenant |

### Implementation

```python
import zvec
from pathlib import Path

VECTOR_DATA_ROOT = Path("/data/vectors")

def create_tenant_collection(org_id: str, dimension: int = 384) -> zvec.Collection:
    """Create a new vector collection for a tenant."""
    tenant_path = VECTOR_DATA_ROOT / org_id
    schema = zvec.CollectionSchema(
        name=f"tenant_{org_id}",
        fields=[
            zvec.FieldSchema("content_chunk", zvec.DataType.STRING),
            zvec.FieldSchema("source_file", zvec.DataType.STRING),
            zvec.FieldSchema("chunk_index", zvec.DataType.INT32),
        ],
        vectors=[
            zvec.VectorSchema("embedding", zvec.DataType.VECTOR_FP32, dimension=dimension),
        ],
    )
    return zvec.create_and_open(path=str(tenant_path), schema=schema)

def open_tenant_collection(org_id: str) -> zvec.Collection:
    """Open an existing tenant's collection."""
    tenant_path = VECTOR_DATA_ROOT / org_id
    return zvec.open(path=str(tenant_path))

def destroy_tenant_collection(org_id: str) -> None:
    """Permanently delete a tenant's vector data."""
    collection = open_tenant_collection(org_id)
    collection.destroy()
```

### Scaling Considerations

- **<10k tenants**: Collection-per-tenant works well. Each collection is a directory with index files.
- **10k-100k tenants**: Consider lazy loading -- only open collections for active tenants. Zvec collections are opened/closed per request or with a TTL cache.
- **>100k tenants**: Consider namespace-based isolation (metadata filtering) or a hosted solution. File descriptor and directory limits become a factor.

## Performance Benchmarks

Benchmarked using [VectorDBBench](https://github.com/zilliztech/VectorDBBench) on a 16 vCPU / 64 GiB instance (g9i.4xlarge).

### Cohere 10M (768-dim, 10M vectors)

Configuration: HNSW with `m=50`, `ef_search=118`, INT8 quantization + refiner.

Zvec achieves the highest QPS among tested databases at >95% recall on the 10M benchmark, with the fastest index build time.

### Cohere 1M (768-dim, 1M vectors)

Configuration: HNSW with `m=15`, `ef_search=180`, INT8 quantization.

### Key Performance Characteristics

| Metric | Value | Notes |
|--------|-------|-------|
| Search latency | Sub-millisecond | In-process, no network hop |
| Index build | Fastest in VectorDBBench | Parallel C++ indexing |
| Memory efficiency | ~4x reduction with INT8 | Quantization + refiner maintains recall |
| Recall | >95% at high QPS | HNSW + INT8 + refiner |

### Reproducing Benchmarks

```bash
pip install zvec==v0.1.1
pip install vectordbbench

# 10M benchmark
vectordbbench zvec --path Performance768D10M --case-type Performance768D10M \
  --num-concurrency 12,14,16,18,20 --quantize-type int8 \
  --m 50 --ef-search 118 --is-using-refiner

# 1M benchmark
vectordbbench zvec --path Performance768D1M --case-type Performance768D1M \
  --num-concurrency 12,14,16,18,20 --quantize-type int8 \
  --m 15 --ef-search 180
```

## Metric Types

| Metric | Constant | Description |
|--------|----------|-------------|
| L2 (Euclidean) | `MetricType.L2` | Euclidean distance (lower = more similar) |
| Inner Product | `MetricType.IP` | Dot product (higher = more similar) |
| Cosine | `MetricType.COSINE` | Cosine similarity (higher = more similar) |

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

- [PGlite - Local-First Embedded Postgres](../pglite-local-first.md) -- For apps needing full SQL + pgvector
- [Zvec GitHub](https://github.com/alibaba/zvec) -- Source code and issues
- [Zvec Documentation](https://zvec.org/en/docs/) -- Official docs
- [VectorDBBench](https://github.com/zilliztech/VectorDBBench) -- Benchmark framework
