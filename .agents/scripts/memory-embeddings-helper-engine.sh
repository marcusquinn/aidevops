#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Memory Embeddings Engine -- Python engine generation sub-library
# =============================================================================
# Contains dependency checking, setup instructions, and all _write_python_*
# functions that generate the Python embedding engine script.
#
# Usage: source "${SCRIPT_DIR}/memory-embeddings-helper-engine.sh"
#
# Dependencies:
#   - shared-constants.sh (log_error, log_info, log_warn, log_success)
#   - Globals from memory-embeddings-helper.sh (PYTHON_SCRIPT, MEMORY_DIR,
#     CONFIG_FILE, LOCAL_MODEL_NAME, LOCAL_EMBEDDING_DIM, OPENAI_EMBEDDING_DIM)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_MEMORY_EMBEDDINGS_ENGINE_LIB_LOADED:-}" ]] && return 0
_MEMORY_EMBEDDINGS_ENGINE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

#######################################
# Check if dependencies are installed for current provider
#######################################
check_deps() {
	local provider
	provider=$(get_provider)

	if [[ "$provider" == "openai" ]]; then
		# OpenAI provider needs: python3, numpy, curl (for API calls)
		if ! command -v python3 &>/dev/null; then
			return 1
		fi
		if ! python3 -c "import numpy" &>/dev/null 2>&1; then
			return 1
		fi
		if ! get_openai_key >/dev/null 2>&1; then
			return 1
		fi
		return 0
	fi

	# Local provider needs: python3, sentence-transformers, numpy
	local missing=()

	if ! command -v python3 &>/dev/null; then
		missing+=("python3")
	fi

	if ! python3 -c "import sentence_transformers" &>/dev/null 2>&1; then
		missing+=("sentence-transformers")
	fi

	if ! python3 -c "import numpy" &>/dev/null 2>&1; then
		missing+=("numpy")
	fi

	if [[ ${#missing[@]} -gt 0 ]]; then
		return 1
	fi
	return 0
}

#######################################
# Check if embeddings are available (for auto-index hook)
# Returns 0 if embeddings are configured and deps are met
#######################################
is_available() {
	if [[ ! -f "$CONFIG_FILE" ]]; then
		return 1
	fi
	check_deps
	return $?
}

#######################################
# Print missing dependency instructions
#######################################
print_setup_instructions() {
	local provider
	provider=$(get_provider)

	log_error "Missing dependencies for semantic memory ($provider provider)."
	echo ""

	if [[ "$provider" == "openai" ]]; then
		echo "For OpenAI provider:"
		echo "  1. pip install numpy"
		echo "  2. Set API key: aidevops secret set openai-api-key"
		echo "     Or: export OPENAI_API_KEY=sk-..."
	else
		echo "For local provider:"
		echo "  pip install sentence-transformers numpy"
	fi

	echo ""
	echo "Or run:"
	echo "  memory-embeddings-helper.sh setup [--provider local|openai]"
	echo ""
	echo "This is opt-in. FTS5 keyword search (memory-helper.sh recall) works without this."
	return 1
}

#######################################
# Write Python engine header: imports and model loading
#######################################
_write_python_header() {
	cat >>"$PYTHON_SCRIPT" <<'PYEOF'
#!/usr/bin/env python3
"""Embedding engine for aidevops semantic memory.

Supports two providers:
    - local: all-MiniLM-L6-v2 via sentence-transformers (384d)
    - openai: text-embedding-3-small via OpenAI API (1536d)

Commands:
    embed <provider> <text>                          - Output embedding as JSON array
    search <provider> <emb_db> <mem_db> <query> [limit] - Search embeddings DB
    hybrid <provider> <emb_db> <mem_db> <query> [limit] - Hybrid FTS5+semantic (RRF)
    index <provider> <memory_db> <embeddings_db>     - Index all memories
    add <provider> <memory_db> <embeddings_db> <id>  - Index single memory
    find-similar <provider> <emb_db> <mem_db> <text> <type> [threshold] - Semantic dedup
    status <embeddings_db>                           - Show index stats
"""

import hashlib
import json
import os
import sqlite3
import struct
import sys
import urllib.request
from pathlib import Path

import numpy as np

# Lazy-load model to avoid slow imports on every call
_model = None


def get_local_model():
    global _model
    if _model is None:
        from sentence_transformers import SentenceTransformer
        _model = SentenceTransformer("all-MiniLM-L6-v2")
    return _model


def embed_text_local(text: str) -> list[float]:
    model = get_local_model()
    embedding = model.encode(text, normalize_embeddings=True)
    return embedding.tolist()
PYEOF
	return 0
}

#######################################
# Write Python engine: OpenAI embedding and shared embed helpers
#######################################
_write_python_embed_functions() {
	cat >>"$PYTHON_SCRIPT" <<'PYEOF'

def embed_text_openai(text: str) -> list[float]:
    api_key = os.environ.get("OPENAI_API_KEY", "")
    if not api_key:
        print(json.dumps({"error": "OPENAI_API_KEY not set"}), file=sys.stderr)
        sys.exit(1)

    payload = json.dumps({
        "input": text,
        "model": "text-embedding-3-small",
    }).encode("utf-8")

    req = urllib.request.Request(
        "https://api.openai.com/v1/embeddings",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read().decode("utf-8"))
            embedding = result["data"][0]["embedding"]
            # Normalize for cosine similarity
            arr = np.array(embedding)
            norm = np.linalg.norm(arr)
            if norm > 0:
                arr = arr / norm
            return arr.tolist()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(json.dumps({"error": f"OpenAI API error {e.code}: {body}"}), file=sys.stderr)
        sys.exit(1)


def embed_text(text: str, provider: str = "local") -> list[float]:
    if provider == "openai":
        return embed_text_openai(text)
    return embed_text_local(text)


def get_embedding_dim(provider: str) -> int:
    if provider == "openai":
        return 1536
    return 384


def pack_embedding(embedding: list[float]) -> bytes:
    return struct.pack(f"{len(embedding)}f", *embedding)


def unpack_embedding(data: bytes, dim: int) -> list[float]:
    return list(struct.unpack(f"{dim}f", data))


def cosine_similarity(a: list[float], b: list[float]) -> float:
    a_arr = np.array(a)
    b_arr = np.array(b)
    dot = np.dot(a_arr, b_arr)
    norm_a = np.linalg.norm(a_arr)
    norm_b = np.linalg.norm(b_arr)
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return float(dot / (norm_a * norm_b))
PYEOF
	return 0
}

#######################################
# Write Python engine: DB init and cmd_embed/cmd_search
#######################################
_write_python_db_and_search() {
	cat >>"$PYTHON_SCRIPT" <<'PYEOF'

def init_embeddings_db(db_path: str):
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS embeddings (
            memory_id TEXT PRIMARY KEY,
            embedding BLOB NOT NULL,
            content_hash TEXT NOT NULL,
            provider TEXT DEFAULT 'local',
            embedding_dim INTEGER DEFAULT 384,
            indexed_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
    """)
    # Migration: add provider/dim columns if missing
    try:
        conn.execute("SELECT provider FROM embeddings LIMIT 0")
    except sqlite3.OperationalError:
        conn.execute("ALTER TABLE embeddings ADD COLUMN provider TEXT DEFAULT 'local'")
    try:
        conn.execute("SELECT embedding_dim FROM embeddings LIMIT 0")
    except sqlite3.OperationalError:
        conn.execute("ALTER TABLE embeddings ADD COLUMN embedding_dim INTEGER DEFAULT 384")
    conn.commit()
    return conn


def cmd_embed(provider: str, text: str):
    embedding = embed_text(text, provider)
    print(json.dumps(embedding))


def cmd_search(provider: str, embeddings_db: str, memory_db: str, query: str, limit: int = 5):
    dim = get_embedding_dim(provider)
    query_embedding = embed_text(query, provider)

    conn = init_embeddings_db(embeddings_db)
    # Only search embeddings from the same provider (dimensions must match)
    rows = conn.execute(
        "SELECT memory_id, embedding, embedding_dim FROM embeddings WHERE provider = ?",
        (provider,)
    ).fetchall()
    conn.close()

    if not rows:
        print(json.dumps([]))
        return

    results = []
    for memory_id, emb_blob, emb_dim in rows:
        actual_dim = emb_dim if emb_dim else dim
        stored_embedding = unpack_embedding(emb_blob, actual_dim)
        score = cosine_similarity(query_embedding, stored_embedding)
        results.append((memory_id, score))

    results.sort(key=lambda x: x[1], reverse=True)
    top_results = results[:limit]

    # Fetch memory content for top results
    mem_conn = sqlite3.connect(memory_db)
    output = []
    for memory_id, score in top_results:
        row = mem_conn.execute(
            "SELECT content, type, tags, confidence, created_at FROM learnings WHERE id = ?",
            (memory_id,)
        ).fetchone()
        if row:
            output.append({
                "id": memory_id,
                "content": row[0],
                "type": row[1],
                "tags": row[2],
                "confidence": row[3],
                "created_at": row[4],
                "score": round(score, 4),
                "search_method": "semantic",
            })
    mem_conn.close()
    print(json.dumps(output))
PYEOF
	return 0
}

#######################################
# Write Python hybrid helper: _hybrid_semantic_search()
#######################################
_write_python_hybrid_semantic() {
	cat >>"$PYTHON_SCRIPT" <<'PYEOF'

def _hybrid_semantic_search(provider: str, embeddings_db: str, query: str, semantic_limit: int) -> list:
    """Return top semantic candidates as [(memory_id, score)] sorted desc."""
    dim = get_embedding_dim(provider)
    query_embedding = embed_text(query, provider)

    emb_conn = init_embeddings_db(embeddings_db)
    rows = emb_conn.execute(
        "SELECT memory_id, embedding, embedding_dim FROM embeddings WHERE provider = ?",
        (provider,)
    ).fetchall()
    emb_conn.close()

    results = []
    for memory_id, emb_blob, emb_dim in rows:
        actual_dim = emb_dim if emb_dim else dim
        stored_embedding = unpack_embedding(emb_blob, actual_dim)
        score = cosine_similarity(query_embedding, stored_embedding)
        results.append((memory_id, score))

    results.sort(key=lambda x: x[1], reverse=True)
    return results[:semantic_limit]
PYEOF
	return 0
}

#######################################
# Write Python hybrid helper: _hybrid_fts5_search()
#######################################
_write_python_hybrid_fts5() {
	cat >>"$PYTHON_SCRIPT" <<'PYEOF'

def _hybrid_fts5_search(mem_conn, query: str, semantic_limit: int) -> list:
    """Return FTS5 BM25 candidates as [(memory_id, score)]. Falls back to [] on error."""
    escaped_query = query.replace('"', '""')
    fts_query = f'"{escaped_query}"'

    try:
        fts_rows = mem_conn.execute(
            """SELECT id, bm25(learnings) as score
               FROM learnings
               WHERE learnings MATCH ?
               ORDER BY score
               LIMIT ?""",
            (fts_query, semantic_limit)
        ).fetchall()
        return [(row[0], row[1]) for row in fts_rows]
    except sqlite3.OperationalError:
        # FTS5 query failed (e.g., special characters) — fall back to semantic only
        return []
PYEOF
	return 0
}

#######################################
# Write Python hybrid helper: _hybrid_usefulness_lookup()
#######################################
_write_python_hybrid_usefulness() {
	cat >>"$PYTHON_SCRIPT" <<'PYEOF'

def _hybrid_usefulness_lookup(mem_conn, semantic_results: list, fts_results: list) -> dict:
    """Fetch usefulness scores for all candidate IDs. Returns {id: score} dict."""
    usefulness_lookup: dict[str, float] = {}
    try:
        all_ids = set(mid for mid, _ in semantic_results) | set(mid for mid, _ in fts_results)
        if all_ids:
            placeholders = ",".join("?" for _ in all_ids)
            usefulness_rows = mem_conn.execute(
                f"SELECT id, COALESCE(usefulness_score, 0.0) FROM learning_access WHERE id IN ({placeholders})",
                list(all_ids)
            ).fetchall()
            usefulness_lookup = {row[0]: row[1] for row in usefulness_rows}
    except sqlite3.OperationalError:
        # usefulness_score column may not exist on older DBs — graceful fallback
        pass
    return usefulness_lookup
PYEOF
	return 0
}

#######################################
# Write Python hybrid helper: _hybrid_rrf_fuse() and cmd_hybrid()
#######################################
_write_python_hybrid_rrf_and_cmd() {
	cat >>"$PYTHON_SCRIPT" <<'PYEOF'

def _hybrid_rrf_fuse(semantic_results: list, fts_results: list,
                     usefulness_lookup: dict, limit: int) -> list:
    """Reciprocal Rank Fusion (k=60) with usefulness boost. Returns [(id, rrf_score)]."""
    k = 60
    rrf_scores: dict[str, float] = {}

    for rank, (memory_id, _score) in enumerate(semantic_results):
        rrf_scores[memory_id] = rrf_scores.get(memory_id, 0.0) + 1.0 / (k + rank + 1)

    for rank, (memory_id, _score) in enumerate(fts_results):
        rrf_scores[memory_id] = rrf_scores.get(memory_id, 0.0) + 1.0 / (k + rank + 1)

    # Apply usefulness boost: lambda=0.3, normalized to RRF scale.
    # A usefulness_score of 3.0 adds ~0.015 to RRF score (enough to shift
    # 1-2 positions among closely-ranked results without overriding relevance).
    usefulness_lambda = 0.3
    rrf_scale = 1.0 / (k + 1)  # max single-signal RRF contribution
    for memory_id in rrf_scores:
        u_score = usefulness_lookup.get(memory_id, 0.0)
        if u_score != 0.0:
            rrf_scores[memory_id] += u_score * usefulness_lambda * rrf_scale

    return sorted(rrf_scores.items(), key=lambda x: x[1], reverse=True)[:limit]


def cmd_hybrid(provider: str, embeddings_db: str, memory_db: str, query: str, limit: int = 5):
    """Hybrid search: combine FTS5 BM25 + semantic similarity using Reciprocal Rank Fusion."""
    semantic_limit = limit * 3

    semantic_results = _hybrid_semantic_search(provider, embeddings_db, query, semantic_limit)

    mem_conn = sqlite3.connect(memory_db)
    mem_conn.execute("PRAGMA busy_timeout=5000")

    try:
        fts_results = _hybrid_fts5_search(mem_conn, query, semantic_limit)
        usefulness_lookup = _hybrid_usefulness_lookup(mem_conn, semantic_results, fts_results)

        combined = _hybrid_rrf_fuse(semantic_results, fts_results, usefulness_lookup, limit)

        semantic_lookup = {mid: score for mid, score in semantic_results}

        output = []
        for memory_id, rrf_score in combined:
            row = mem_conn.execute(
                "SELECT content, type, tags, confidence, created_at FROM learnings WHERE id = ?",
                (memory_id,)
            ).fetchone()
            if row:
                u_score = usefulness_lookup.get(memory_id, 0.0)
                entry = {
                    "id": memory_id,
                    "content": row[0],
                    "type": row[1],
                    "tags": row[2],
                    "confidence": row[3],
                    "created_at": row[4],
                    "score": round(rrf_score, 4),
                    "semantic_score": round(semantic_lookup.get(memory_id, 0.0), 4),
                    "search_method": "hybrid",
                }
                if u_score != 0.0:
                    entry["usefulness_score"] = round(u_score, 2)
                output.append(entry)
    finally:
        mem_conn.close()
    print(json.dumps(output))
PYEOF
	return 0
}

#######################################
# Write Python engine: cmd_index and cmd_add
#######################################
_write_python_index_add() {
	cat >>"$PYTHON_SCRIPT" <<'PYEOF'

def cmd_index(provider: str, memory_db: str, embeddings_db: str):
    dim = get_embedding_dim(provider)
    mem_conn = sqlite3.connect(memory_db)
    rows = mem_conn.execute("SELECT id, content, type, tags FROM learnings").fetchall()
    mem_conn.close()

    if not rows:
        print(json.dumps({"indexed": 0, "skipped": 0}))
        return

    emb_conn = init_embeddings_db(embeddings_db)

    indexed = 0
    skipped = 0
    for memory_id, content, mem_type, tags in rows:
        content_hash = hashlib.md5(content.encode()).hexdigest()

        # Check if already indexed with same content and same provider
        existing = emb_conn.execute(
            "SELECT content_hash, provider FROM embeddings WHERE memory_id = ?",
            (memory_id,)
        ).fetchone()

        if existing and existing[0] == content_hash and existing[1] == provider:
            skipped += 1
            continue

        # Combine content with type and tags for richer embedding
        combined = f"[{mem_type}] {content}"
        if tags:
            combined += f" (tags: {tags})"

        embedding = embed_text(combined, provider)
        packed = pack_embedding(embedding)

        emb_conn.execute(
            """INSERT OR REPLACE INTO embeddings
               (memory_id, embedding, content_hash, provider, embedding_dim)
               VALUES (?, ?, ?, ?, ?)""",
            (memory_id, packed, content_hash, provider, dim)
        )
        indexed += 1

    emb_conn.commit()
    emb_conn.close()
    print(json.dumps({"indexed": indexed, "skipped": skipped, "total": len(rows)}))


def cmd_add(provider: str, memory_db: str, embeddings_db: str, memory_id: str):
    dim = get_embedding_dim(provider)
    mem_conn = sqlite3.connect(memory_db)
    row = mem_conn.execute(
        "SELECT content, type, tags FROM learnings WHERE id = ?",
        (memory_id,)
    ).fetchone()
    mem_conn.close()

    if not row:
        print(json.dumps({"error": f"Memory {memory_id} not found"}))
        sys.exit(1)

    content, mem_type, tags = row
    content_hash = hashlib.md5(content.encode()).hexdigest()

    combined = f"[{mem_type}] {content}"
    if tags:
        combined += f" (tags: {tags})"

    embedding = embed_text(combined, provider)
    packed = pack_embedding(embedding)

    emb_conn = init_embeddings_db(embeddings_db)
    emb_conn.execute(
        """INSERT OR REPLACE INTO embeddings
           (memory_id, embedding, content_hash, provider, embedding_dim)
           VALUES (?, ?, ?, ?, ?)""",
        (memory_id, packed, content_hash, provider, dim)
    )
    emb_conn.commit()
    emb_conn.close()
    print(json.dumps({"indexed": memory_id}))
PYEOF
	return 0
}

#######################################
# Write Python engine: cmd_status and cmd_find_similar
#######################################
_write_python_status_find_similar() {
	cat >>"$PYTHON_SCRIPT" <<'PYEOF'

def cmd_status(embeddings_db: str):
    db_path = Path(embeddings_db)
    if not db_path.exists():
        print(json.dumps({"exists": False, "count": 0, "size_mb": 0, "providers": {}}))
        return

    conn = sqlite3.connect(embeddings_db)
    count = conn.execute("SELECT COUNT(*) FROM embeddings").fetchone()[0]

    # Count by provider
    providers = {}
    try:
        for row in conn.execute(
            "SELECT COALESCE(provider, 'local'), COUNT(*) FROM embeddings GROUP BY provider"
        ).fetchall():
            providers[row[0]] = row[1]
    except sqlite3.OperationalError:
        providers["unknown"] = count

    conn.close()

    size_mb = round(db_path.stat().st_size / (1024 * 1024), 2)
    print(json.dumps({
        "exists": True,
        "count": count,
        "size_mb": size_mb,
        "providers": providers,
    }))


def cmd_find_similar(provider: str, embeddings_db: str, memory_db: str,
                     content: str, mem_type: str, threshold: float = 0.85):
    """Find semantically similar memory for dedup.

    Returns the most similar existing memory of the same type if its
    cosine similarity exceeds the threshold. Used by check_duplicate()
    in _common.sh to replace exact-string dedup with semantic similarity.

    Output: JSON with {id, score, content} of best match, or {} if none.
    """
    dim = get_embedding_dim(provider)

    # Embed the candidate content (same format as indexing)
    combined = f"[{mem_type}] {content}"
    query_embedding = embed_text(combined, provider)

    db_path = Path(embeddings_db)
    if not db_path.exists():
        print(json.dumps({}))
        return

    emb_conn = init_embeddings_db(embeddings_db)
    rows = emb_conn.execute(
        "SELECT memory_id, embedding, embedding_dim FROM embeddings WHERE provider = ?",
        (provider,)
    ).fetchall()
    emb_conn.close()

    if not rows:
        print(json.dumps({}))
        return

    # Find best match
    best_id = None
    best_score = 0.0
    for memory_id, emb_blob, emb_dim in rows:
        actual_dim = emb_dim if emb_dim else dim
        stored_embedding = unpack_embedding(emb_blob, actual_dim)
        score = cosine_similarity(query_embedding, stored_embedding)
        if score > best_score:
            best_score = score
            best_id = memory_id

    if best_id is None or best_score < threshold:
        print(json.dumps({}))
        return

    # Verify the match is the same type in memory DB
    mem_conn = sqlite3.connect(memory_db)
    row = mem_conn.execute(
        "SELECT id, content, type FROM learnings WHERE id = ? AND type = ?",
        (best_id, mem_type)
    ).fetchone()
    mem_conn.close()

    if not row:
        print(json.dumps({}))
        return

    print(json.dumps({
        "id": row[0],
        "content": row[1][:200],
        "score": round(best_score, 4),
    }))
PYEOF
	return 0
}

#######################################
# Write Python engine: main dispatcher
#######################################
_write_python_main() {
	cat >>"$PYTHON_SCRIPT" <<'PYEOF'

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    command = sys.argv[1]

    if command == "embed":
        cmd_embed(sys.argv[2], sys.argv[3])
    elif command == "search":
        cmd_search(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5],
                   int(sys.argv[6]) if len(sys.argv) > 6 else 5)
    elif command == "hybrid":
        cmd_hybrid(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5],
                   int(sys.argv[6]) if len(sys.argv) > 6 else 5)
    elif command == "index":
        cmd_index(sys.argv[2], sys.argv[3], sys.argv[4])
    elif command == "add":
        cmd_add(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif command == "status":
        cmd_status(sys.argv[2])
    elif command == "find-similar":
        cmd_find_similar(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5],
                         sys.argv[6],
                         float(sys.argv[7]) if len(sys.argv) > 7 else 0.85)
    else:
        print(f"Unknown command: {command}")
        sys.exit(1)
PYEOF
	return 0
}

#######################################
# Create the Python embedding engine
# Delegates to section writers to keep each function under 100 lines
#######################################
create_python_engine() {
	mkdir -p "$MEMORY_DIR"
	mkdir -p "$(dirname "$PYTHON_SCRIPT")"
	# Truncate/create the file before appending sections
	: >"$PYTHON_SCRIPT"
	_write_python_header
	_write_python_embed_functions
	_write_python_db_and_search
	_write_python_hybrid_semantic
	_write_python_hybrid_fts5
	_write_python_hybrid_usefulness
	_write_python_hybrid_rrf_and_cmd
	_write_python_index_add
	_write_python_status_find_similar
	_write_python_main
	chmod +x "$PYTHON_SCRIPT"
	return 0
}
