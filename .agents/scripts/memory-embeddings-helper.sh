#!/usr/bin/env bash
# memory-embeddings-helper.sh - Semantic memory search using vector embeddings
# Opt-in enhancement for memory-helper.sh (FTS5 remains the default)
#
# Supports two embedding providers:
#   - local: all-MiniLM-L6-v2 via sentence-transformers (~90MB, no API key)
#   - openai: text-embedding-3-small via OpenAI API (requires API key)
#
# Usage:
#   memory-embeddings-helper.sh setup [--provider local|openai]  # Configure provider
#   memory-embeddings-helper.sh index               # Index all existing memories
#   memory-embeddings-helper.sh search "query"      # Semantic similarity search
#   memory-embeddings-helper.sh search "query" --hybrid  # Hybrid FTS5+semantic (RRF)
#   memory-embeddings-helper.sh search "query" --limit 10
#   memory-embeddings-helper.sh add <memory_id>     # Add single memory to index
#   memory-embeddings-helper.sh status              # Show index stats + provider
#   memory-embeddings-helper.sh rebuild             # Rebuild entire index
#   memory-embeddings-helper.sh provider [local|openai]  # Switch provider
#   memory-embeddings-helper.sh help                # Show this help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
readonly MEMORY_BASE_DIR="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}"
readonly LOCAL_MODEL_NAME="all-MiniLM-L6-v2"
readonly LOCAL_EMBEDDING_DIM=384
readonly OPENAI_MODEL_NAME="text-embedding-3-small"
readonly OPENAI_EMBEDDING_DIM=1536

# Namespace support: resolved in main() before command dispatch
EMBEDDINGS_NAMESPACE=""
MEMORY_DIR="$MEMORY_BASE_DIR"
MEMORY_DB="$MEMORY_DIR/memory.db"
EMBEDDINGS_DB="$MEMORY_DIR/embeddings.db"
PYTHON_SCRIPT="$MEMORY_DIR/.embeddings-engine.py"
CONFIG_FILE="$MEMORY_DIR/.embeddings-config"

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

#######################################
# Resolve namespace to correct DB paths
#######################################
resolve_embeddings_namespace() {
    local namespace="$1"

    if [[ -z "$namespace" ]]; then
        MEMORY_DIR="$MEMORY_BASE_DIR"
        MEMORY_DB="$MEMORY_DIR/memory.db"
        EMBEDDINGS_DB="$MEMORY_DIR/embeddings.db"
        PYTHON_SCRIPT="$MEMORY_BASE_DIR/.embeddings-engine.py"
        CONFIG_FILE="$MEMORY_BASE_DIR/.embeddings-config"
        return 0
    fi

    if [[ ! "$namespace" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        log_error "Invalid namespace: '$namespace'"
        return 1
    fi

    EMBEDDINGS_NAMESPACE="$namespace"
    MEMORY_DIR="$MEMORY_BASE_DIR/namespaces/$namespace"
    MEMORY_DB="$MEMORY_DIR/memory.db"
    EMBEDDINGS_DB="$MEMORY_DIR/embeddings.db"
    # Python script and config stay in base dir (shared across namespaces)
    PYTHON_SCRIPT="$MEMORY_BASE_DIR/.embeddings-engine.py"
    CONFIG_FILE="$MEMORY_BASE_DIR/.embeddings-config"
    return 0
}

#######################################
# Read configured provider (default: local)
#######################################
get_provider() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local provider
        provider=$(grep '^provider=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || true)
        if [[ "$provider" == "openai" || "$provider" == "local" ]]; then
            echo "$provider"
            return 0
        fi
    fi
    echo "local"
    return 0
}

#######################################
# Get embedding dimension for current provider
#######################################
get_embedding_dim() {
    local provider
    provider=$(get_provider)
    if [[ "$provider" == "openai" ]]; then
        echo "$OPENAI_EMBEDDING_DIM"
    else
        echo "$LOCAL_EMBEDDING_DIM"
    fi
    return 0
}

#######################################
# Save provider configuration
#######################################
save_config() {
    local provider="$1"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    echo "provider=$provider" > "$CONFIG_FILE"
    echo "configured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$CONFIG_FILE"
    return 0
}

#######################################
# Get OpenAI API key from aidevops secret store
# NEVER prints the key to stdout in normal operation
#######################################
get_openai_key() {
    # Check environment variable first
    if [[ -n "${OPENAI_API_KEY:-}" ]]; then
        echo "$OPENAI_API_KEY"
        return 0
    fi

    # Check aidevops secret store (gopass)
    if command -v gopass &>/dev/null; then
        local key
        key=$(gopass show -o "aidevops/openai-api-key" 2>/dev/null || echo "")
        if [[ -n "$key" ]]; then
            echo "$key"
            return 0
        fi
    fi

    # Check credentials file
    local creds_file="$HOME/.config/aidevops/credentials.sh"
    if [[ -f "$creds_file" ]]; then
        local key
        # shellcheck disable=SC1090
        key=$(source "$creds_file" 2>/dev/null && echo "${OPENAI_API_KEY:-}")
        if [[ -n "$key" ]]; then
            echo "$key"
            return 0
        fi
    fi

    return 1
}

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
# Create the Python embedding engine
# Supports both local and OpenAI providers
#######################################
create_python_engine() {
    mkdir -p "$MEMORY_DIR"
    mkdir -p "$(dirname "$PYTHON_SCRIPT")"
    cat > "$PYTHON_SCRIPT" << 'PYEOF'
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


def cmd_hybrid(provider: str, embeddings_db: str, memory_db: str, query: str, limit: int = 5):
    """Hybrid search: combine FTS5 BM25 + semantic similarity using Reciprocal Rank Fusion."""
    dim = get_embedding_dim(provider)

    # 1. Semantic search (get 3x limit candidates)
    semantic_limit = limit * 3
    query_embedding = embed_text(query, provider)

    emb_conn = init_embeddings_db(embeddings_db)
    rows = emb_conn.execute(
        "SELECT memory_id, embedding, embedding_dim FROM embeddings WHERE provider = ?",
        (provider,)
    ).fetchall()
    emb_conn.close()

    semantic_results = []
    for memory_id, emb_blob, emb_dim in rows:
        actual_dim = emb_dim if emb_dim else dim
        stored_embedding = unpack_embedding(emb_blob, actual_dim)
        score = cosine_similarity(query_embedding, stored_embedding)
        semantic_results.append((memory_id, score))

    semantic_results.sort(key=lambda x: x[1], reverse=True)
    semantic_results = semantic_results[:semantic_limit]

    # 2. FTS5 keyword search (get 3x limit candidates)
    mem_conn = sqlite3.connect(memory_db)
    mem_conn.execute("PRAGMA busy_timeout=5000")

    # Escape query for FTS5 (wrap in double quotes for literal phrase)
    escaped_query = query.replace('"', '""')
    fts_query = f'"{escaped_query}"'

    fts_results = []
    try:
        fts_rows = mem_conn.execute(
            f"""SELECT id, bm25(learnings) as score
                FROM learnings
                WHERE learnings MATCH ?
                ORDER BY score
                LIMIT ?""",
            (fts_query, semantic_limit)
        ).fetchall()
        fts_results = [(row[0], row[1]) for row in fts_rows]
    except sqlite3.OperationalError:
        # FTS5 query failed (e.g., special characters) — fall back to semantic only
        pass

    # 3. Reciprocal Rank Fusion (RRF) with k=60
    k = 60
    rrf_scores: dict[str, float] = {}

    for rank, (memory_id, _score) in enumerate(semantic_results):
        rrf_scores[memory_id] = rrf_scores.get(memory_id, 0.0) + 1.0 / (k + rank + 1)

    for rank, (memory_id, _score) in enumerate(fts_results):
        rrf_scores[memory_id] = rrf_scores.get(memory_id, 0.0) + 1.0 / (k + rank + 1)

    # Sort by combined RRF score
    combined = sorted(rrf_scores.items(), key=lambda x: x[1], reverse=True)[:limit]

    # Build semantic score lookup for output
    semantic_lookup = {mid: score for mid, score in semantic_results}

    # Fetch memory content
    output = []
    for memory_id, rrf_score in combined:
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
                "score": round(rrf_score, 4),
                "semantic_score": round(semantic_lookup.get(memory_id, 0.0), 4),
                "search_method": "hybrid",
            })
    mem_conn.close()
    print(json.dumps(output))


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
    else:
        print(f"Unknown command: {command}")
        sys.exit(1)
PYEOF
    chmod +x "$PYTHON_SCRIPT"
    return 0
}

#######################################
# Setup: install dependencies and configure provider
#######################################
cmd_setup() {
    local provider="local"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --provider|-p) provider="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ "$provider" != "local" && "$provider" != "openai" ]]; then
        log_error "Invalid provider: $provider (use 'local' or 'openai')"
        return 1
    fi

    log_info "Setting up semantic memory embeddings (provider: $provider)..."

    if [[ "$provider" == "openai" ]]; then
        # OpenAI provider: needs python3, numpy, and API key
        if ! command -v python3 &>/dev/null; then
            log_error "Python 3 is required. Install it first."
            return 1
        fi

        if ! python3 -c "import numpy" &>/dev/null 2>&1; then
            log_info "Installing numpy..."
            pip install --quiet numpy
        fi

        # Check for API key
        if ! get_openai_key >/dev/null 2>&1; then
            log_warn "OpenAI API key not found."
            echo ""
            echo "Set it with one of:"
            echo "  aidevops secret set openai-api-key"
            echo "  export OPENAI_API_KEY=sk-..."
            echo ""
            echo "Provider configured but key needed before use."
        else
            log_success "OpenAI API key found"
        fi

        save_config "openai"
        create_python_engine

        # Test with a simple embedding if key is available
        if get_openai_key >/dev/null 2>&1; then
            log_info "Testing OpenAI embedding..."
            local api_key
            api_key=$(get_openai_key)
            if OPENAI_API_KEY="$api_key" python3 "$PYTHON_SCRIPT" embed openai "test" > /dev/null 2>&1; then
                log_success "OpenAI embeddings working"
            else
                log_warn "OpenAI test embedding failed. Check your API key."
            fi
        fi
    else
        # Local provider: needs python3, sentence-transformers, numpy
        if ! command -v python3 &>/dev/null; then
            log_error "Python 3 is required. Install it first."
            return 1
        fi

        log_info "Installing Python dependencies..."
        pip install --quiet sentence-transformers numpy

        save_config "local"
        create_python_engine

        log_info "Downloading model ($LOCAL_MODEL_NAME, ~90MB)..."
        python3 "$PYTHON_SCRIPT" embed local "test" > /dev/null
    fi

    log_success "Semantic memory setup complete (provider: $provider)."
    log_info "Run 'memory-embeddings-helper.sh index' to index existing memories."
    return 0
}

#######################################
# Switch or show provider
#######################################
cmd_provider() {
    local new_provider="${1:-}"

    if [[ -z "$new_provider" ]]; then
        local current
        current=$(get_provider)
        log_info "Current provider: $current"
        if [[ -f "$CONFIG_FILE" ]]; then
            local configured_at
            configured_at=$(grep '^configured_at=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || true)
            if [[ -n "$configured_at" ]]; then
                log_info "Configured at: $configured_at"
            fi
        fi
        echo ""
        echo "Available providers:"
        echo "  local   - all-MiniLM-L6-v2 (384d, ~90MB, no API key)"
        echo "  openai  - text-embedding-3-small (1536d, requires API key)"
        echo ""
        echo "Switch with: memory-embeddings-helper.sh provider <local|openai>"
        return 0
    fi

    if [[ "$new_provider" != "local" && "$new_provider" != "openai" ]]; then
        log_error "Invalid provider: $new_provider (use 'local' or 'openai')"
        return 1
    fi

    local old_provider
    old_provider=$(get_provider)

    if [[ "$old_provider" == "$new_provider" ]]; then
        log_info "Already using provider: $new_provider"
        return 0
    fi

    save_config "$new_provider"
    log_success "Switched provider: $old_provider -> $new_provider"

    if [[ -f "$EMBEDDINGS_DB" ]]; then
        log_warn "Existing embeddings were created with '$old_provider' provider."
        log_warn "Run 'memory-embeddings-helper.sh rebuild' to re-index with '$new_provider'."
    fi

    return 0
}

#######################################
# Index all existing memories
#######################################
cmd_index() {
    if ! check_deps; then
        print_setup_instructions
        return 1
    fi

    if [[ ! -f "$MEMORY_DB" ]]; then
        log_error "Memory database not found at $MEMORY_DB"
        log_error "Store some memories first with: memory-helper.sh store --content \"...\""
        return 1
    fi

    local provider
    provider=$(get_provider)

    create_python_engine

    log_info "Indexing memories with $provider provider..."

    local env_prefix=""
    if [[ "$provider" == "openai" ]]; then
        local api_key
        api_key=$(get_openai_key) || { log_error "OpenAI API key not found"; return 1; }
        env_prefix="OPENAI_API_KEY=$api_key"
    fi

    local result
    result=$(eval "$env_prefix" python3 "$PYTHON_SCRIPT" index "$provider" "$MEMORY_DB" "$EMBEDDINGS_DB")

    local indexed skipped total
    if command -v jq &>/dev/null; then
        indexed=$(echo "$result" | jq -r '.indexed')
        skipped=$(echo "$result" | jq -r '.skipped')
        total=$(echo "$result" | jq -r '.total')
    else
        indexed=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['indexed'])")
        skipped=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['skipped'])")
        total=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['total'])")
    fi

    log_success "Indexed $indexed new memories ($skipped unchanged, $total total) [provider: $provider]"
    return 0
}

#######################################
# Search memories semantically
#######################################
cmd_search() {
    local query=""
    local limit=5
    local format="text"
    local hybrid=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit|-l) limit="$2"; shift 2 ;;
            --json) format="json"; shift ;;
            --format) format="$2"; shift 2 ;;
            --hybrid) hybrid=true; shift ;;
            *)
                if [[ -z "$query" ]]; then
                    query="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$query" ]]; then
        log_error "Query is required: memory-embeddings-helper.sh search \"your query\""
        return 1
    fi

    if ! check_deps; then
        print_setup_instructions
        return 1
    fi

    if [[ ! -f "$EMBEDDINGS_DB" ]]; then
        log_error "Embeddings index not found. Run: memory-embeddings-helper.sh index"
        return 1
    fi

    local provider
    provider=$(get_provider)

    create_python_engine

    local env_prefix=""
    if [[ "$provider" == "openai" ]]; then
        local api_key
        api_key=$(get_openai_key) || { log_error "OpenAI API key not found"; return 1; }
        env_prefix="OPENAI_API_KEY=$api_key"
    fi

    local search_cmd="search"
    if [[ "$hybrid" == true ]]; then
        search_cmd="hybrid"
    fi

    local result
    result=$(eval "$env_prefix" python3 "$PYTHON_SCRIPT" "$search_cmd" "$provider" "$EMBEDDINGS_DB" "$MEMORY_DB" "$query" "$limit")

    if [[ "$format" == "json" ]]; then
        echo "$result"
    else
        local method_label="Semantic"
        if [[ "$hybrid" == true ]]; then
            method_label="Hybrid (FTS5+Semantic)"
        fi

        echo ""
        echo "=== $method_label Search: \"$query\" [$provider] ==="
        echo ""
        if command -v jq &>/dev/null; then
            echo "$result" | jq -r '.[] | "[\(.type)] (score: \(.score)) \(.confidence)\n  \(.content)\n  Tags: \(.tags // "none")\n  Created: \(.created_at)\n  Method: \(.search_method)\n"'
        else
            python3 -c "
import json, sys
results = json.loads(sys.stdin.read())
for r in results:
    print(f'[{r[\"type\"]}] (score: {r[\"score\"]}) {r[\"confidence\"]}')
    print(f'  {r[\"content\"]}')
    print(f'  Tags: {r.get(\"tags\", \"none\")}')
    print(f'  Created: {r[\"created_at\"]}')
    print(f'  Method: {r.get(\"search_method\", \"semantic\")}')
    print()
" <<< "$result"
        fi
    fi
    return 0
}

#######################################
# Add single memory to index
#######################################
cmd_add() {
    local memory_id="$1"

    if [[ -z "$memory_id" ]]; then
        log_error "Memory ID required: memory-embeddings-helper.sh add <memory_id>"
        return 1
    fi

    if ! check_deps; then
        print_setup_instructions
        return 1
    fi

    local provider
    provider=$(get_provider)

    create_python_engine

    local env_prefix=""
    if [[ "$provider" == "openai" ]]; then
        local api_key
        api_key=$(get_openai_key) || { log_error "OpenAI API key not found"; return 1; }
        env_prefix="OPENAI_API_KEY=$api_key"
    fi

    local result
    result=$(eval "$env_prefix" python3 "$PYTHON_SCRIPT" add "$provider" "$MEMORY_DB" "$EMBEDDINGS_DB" "$memory_id")

    if echo "$result" | grep -q '"error"'; then
        log_error "$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['error'])" 2>/dev/null || echo "$result")"
        return 1
    fi

    log_success "Indexed memory: $memory_id [$provider]"
    return 0
}

#######################################
# Auto-index hook: called by memory-helper.sh after store
# Silently indexes new memory if embeddings are configured
# Designed to be fast and non-blocking
#######################################
cmd_auto_index() {
    local memory_id="${1:-}"

    if [[ -z "$memory_id" ]]; then
        return 0
    fi

    # Quick checks: bail fast if not configured
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 0
    fi

    if [[ ! -f "$EMBEDDINGS_DB" ]]; then
        return 0
    fi

    # Check deps silently
    if ! check_deps 2>/dev/null; then
        return 0
    fi

    local provider
    provider=$(get_provider)

    create_python_engine 2>/dev/null

    local env_prefix=""
    if [[ "$provider" == "openai" ]]; then
        local api_key
        api_key=$(get_openai_key 2>/dev/null) || return 0
        env_prefix="OPENAI_API_KEY=$api_key"
    fi

    # Run in background to avoid slowing down store
    (eval "$env_prefix" python3 "$PYTHON_SCRIPT" add "$provider" "$MEMORY_DB" "$EMBEDDINGS_DB" "$memory_id" >/dev/null 2>&1) &
    disown 2>/dev/null || true

    return 0
}

#######################################
# Show index status
#######################################
cmd_status() {
    local provider
    provider=$(get_provider)

    log_info "Provider: $provider"

    if [[ "$provider" == "local" ]]; then
        log_info "Model: $LOCAL_MODEL_NAME (${LOCAL_EMBEDDING_DIM}d)"
    else
        log_info "Model: $OPENAI_MODEL_NAME (${OPENAI_EMBEDDING_DIM}d)"
    fi

    if [[ ! -f "$EMBEDDINGS_DB" ]]; then
        log_info "Embeddings index: not created"
        log_info "Run 'memory-embeddings-helper.sh setup' to enable semantic search"
        return 0
    fi

    if ! check_deps; then
        log_warn "Dependencies not installed for $provider provider"
        log_info "Run 'memory-embeddings-helper.sh setup --provider $provider' to install"
        return 0
    fi

    create_python_engine

    local result
    result=$(python3 "$PYTHON_SCRIPT" status "$EMBEDDINGS_DB")

    local count size_mb
    if command -v jq &>/dev/null; then
        count=$(echo "$result" | jq -r '.count')
        size_mb=$(echo "$result" | jq -r '.size_mb')
        local providers_info
        providers_info=$(echo "$result" | jq -r '.providers | to_entries | map("\(.key): \(.value)") | join(", ")')
        log_info "Embeddings index: $count memories indexed (${size_mb}MB)"
        if [[ -n "$providers_info" ]]; then
            log_info "By provider: $providers_info"
        fi
    else
        count=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])")
        size_mb=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['size_mb'])")
        log_info "Embeddings index: $count memories indexed (${size_mb}MB)"
    fi

    log_info "Database: $EMBEDDINGS_DB"

    # Compare with memory DB
    if [[ -f "$MEMORY_DB" ]]; then
        local total_memories
        total_memories=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "?")
        local unindexed=$((total_memories - count))
        log_info "Total memories: $total_memories ($unindexed unindexed)"
    fi
    return 0
}

#######################################
# Rebuild entire index
#######################################
cmd_rebuild() {
    log_info "Rebuilding embeddings index..."

    if [[ -f "$EMBEDDINGS_DB" ]]; then
        rm "$EMBEDDINGS_DB"
        log_info "Removed old index"
    fi

    cmd_index
    return 0
}

#######################################
# Show help
#######################################
cmd_help() {
    cat <<'EOF'
memory-embeddings-helper.sh - Semantic memory search (opt-in)

PROVIDERS:
  local   - all-MiniLM-L6-v2 (384d, ~90MB download, no API key needed)
  openai  - text-embedding-3-small (1536d, requires OpenAI API key)

USAGE:
  memory-embeddings-helper.sh [--namespace NAME] <command> [options]

COMMANDS:
  setup [--provider local|openai]  Configure and install dependencies
  index                            Index all existing memories
  search "query"                   Semantic similarity search
  search "query" --hybrid          Hybrid FTS5+semantic search (RRF)
  search "query" --limit 10        Search with custom limit
  add <memory_id>                  Index single memory
  auto-index <memory_id>           Auto-index hook (called by memory-helper.sh)
  status                           Show index stats and provider info
  rebuild                          Rebuild entire index
  provider [local|openai]          Show or switch embedding provider
  help                             Show this help

SEARCH MODES:
  --semantic (default)   Pure vector similarity search
  --hybrid               Combines FTS5 keyword + semantic using Reciprocal
                         Rank Fusion (RRF). Best for natural language queries
                         that benefit from both exact keyword and meaning match.

INTEGRATION:
  memory-helper.sh recall "query" --semantic   Delegates to this script
  memory-helper.sh recall "query" --hybrid     Hybrid FTS5+semantic search

AUTO-INDEXING:
  When embeddings are configured, new memories stored via memory-helper.sh
  are automatically indexed in the background. No manual indexing needed
  after initial setup.

EXAMPLES:
  # Setup with local model (no API key needed)
  memory-embeddings-helper.sh setup --provider local

  # Setup with OpenAI (needs API key)
  memory-embeddings-helper.sh setup --provider openai

  # Index all memories
  memory-embeddings-helper.sh index

  # Semantic search
  memory-embeddings-helper.sh search "how to optimize database queries"

  # Hybrid search (best results)
  memory-embeddings-helper.sh search "authentication patterns" --hybrid

  # Switch provider
  memory-embeddings-helper.sh provider openai

  # Check status
  memory-embeddings-helper.sh status

This is opt-in. FTS5 keyword search (memory-helper.sh recall) works without this.
EOF
    return 0
}

#######################################
# Main entry point
#######################################
main() {
    # Parse global flags before command
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --namespace|-n)
                if [[ $# -lt 2 ]]; then
                    log_error "--namespace requires a value"
                    return 1
                fi
                resolve_embeddings_namespace "$2" || return 1
                shift 2
                ;;
            *)
                break
                ;;
        esac
    done

    local command="${1:-help}"
    shift || true

    if [[ -n "$EMBEDDINGS_NAMESPACE" ]]; then
        log_info "Using namespace: $EMBEDDINGS_NAMESPACE"
    fi

    case "$command" in
        setup) cmd_setup "$@" ;;
        index) cmd_index ;;
        search) cmd_search "$@" ;;
        add) cmd_add "${1:-}" ;;
        auto-index) cmd_auto_index "${1:-}" ;;
        status) cmd_status ;;
        rebuild) cmd_rebuild ;;
        provider) cmd_provider "${1:-}" ;;
        help|--help|-h) cmd_help ;;
        *)
            log_error "Unknown command: $command"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
exit $?
