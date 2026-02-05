#!/usr/bin/env bash
# memory-embeddings-helper.sh - Semantic memory search using vector embeddings
# Opt-in enhancement for memory-helper.sh (FTS5 remains the default)
#
# Uses all-MiniLM-L6-v2 (~90MB) for embeddings, SQLite for vector storage.
# Requires: Python 3.9+, sentence-transformers, numpy
#
# Usage:
#   memory-embeddings-helper.sh setup              # Install dependencies + download model
#   memory-embeddings-helper.sh index               # Index all existing memories
#   memory-embeddings-helper.sh search "query"      # Semantic similarity search
#   memory-embeddings-helper.sh search "query" --limit 10
#   memory-embeddings-helper.sh add <memory_id>     # Add single memory to index
#   memory-embeddings-helper.sh status              # Show index stats
#   memory-embeddings-helper.sh rebuild             # Rebuild entire index
#   memory-embeddings-helper.sh help                # Show this help

set -euo pipefail

# Configuration
readonly MEMORY_DIR="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}"
readonly MEMORY_DB="$MEMORY_DIR/memory.db"
readonly EMBEDDINGS_DB="$MEMORY_DIR/embeddings.db"
readonly MODEL_NAME="all-MiniLM-L6-v2"
readonly EMBEDDING_DIM=384
readonly PYTHON_SCRIPT="$MEMORY_DIR/.embeddings-engine.py"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

#######################################
# Check if dependencies are installed
#######################################
check_deps() {
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
# Print missing dependency instructions
#######################################
print_setup_instructions() {
    log_error "Missing dependencies for semantic memory."
    echo ""
    echo "Install with:"
    echo "  pip install sentence-transformers numpy"
    echo ""
    echo "Or run:"
    echo "  memory-embeddings-helper.sh setup"
    echo ""
    echo "This is opt-in. FTS5 keyword search (memory-helper.sh recall) works without this."
    return 1
}

#######################################
# Create the Python embedding engine
# Kept as a single file for simplicity
#######################################
create_python_engine() {
    mkdir -p "$MEMORY_DIR"
    cat > "$PYTHON_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""Embedding engine for aidevops semantic memory.

Commands:
    embed <text>           - Output embedding as JSON array
    search <db> <query> [limit] - Search embeddings DB for similar
    index <memory_db> <embeddings_db> - Index all memories
    add <memory_db> <embeddings_db> <id> - Index single memory
    status <embeddings_db> - Show index stats
"""

import json
import sqlite3
import struct
import sys
from pathlib import Path

import numpy as np

# Lazy-load model to avoid slow imports on every call
_model = None

def get_model():
    global _model
    if _model is None:
        from sentence_transformers import SentenceTransformer
        _model = SentenceTransformer("all-MiniLM-L6-v2")
    return _model

def embed_text(text: str) -> list[float]:
    model = get_model()
    embedding = model.encode(text, normalize_embeddings=True)
    return embedding.tolist()

def pack_embedding(embedding: list[float]) -> bytes:
    return struct.pack(f"{len(embedding)}f", *embedding)

def unpack_embedding(data: bytes, dim: int = 384) -> list[float]:
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
    conn.execute("""
        CREATE TABLE IF NOT EXISTS embeddings (
            memory_id TEXT PRIMARY KEY,
            embedding BLOB NOT NULL,
            content_hash TEXT NOT NULL,
            indexed_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
    """)
    conn.commit()
    return conn

def cmd_embed(text: str):
    embedding = embed_text(text)
    print(json.dumps(embedding))

def cmd_search(embeddings_db: str, memory_db: str, query: str, limit: int = 5):
    query_embedding = embed_text(query)

    conn = init_embeddings_db(embeddings_db)
    rows = conn.execute("SELECT memory_id, embedding FROM embeddings").fetchall()
    conn.close()

    if not rows:
        print(json.dumps([]))
        return

    results = []
    for memory_id, emb_blob in rows:
        stored_embedding = unpack_embedding(emb_blob)
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
            })
    mem_conn.close()
    print(json.dumps(output))

def cmd_index(memory_db: str, embeddings_db: str):
    mem_conn = sqlite3.connect(memory_db)
    rows = mem_conn.execute("SELECT id, content, type, tags FROM learnings").fetchall()
    mem_conn.close()

    if not rows:
        print(json.dumps({"indexed": 0, "skipped": 0}))
        return

    emb_conn = init_embeddings_db(embeddings_db)
    existing = set(
        r[0] for r in emb_conn.execute("SELECT memory_id FROM embeddings").fetchall()
    )

    indexed = 0
    skipped = 0
    for memory_id, content, mem_type, tags in rows:
        import hashlib
        content_hash = hashlib.md5(content.encode()).hexdigest()

        # Check if already indexed with same content
        existing_hash = emb_conn.execute(
            "SELECT content_hash FROM embeddings WHERE memory_id = ?",
            (memory_id,)
        ).fetchone()

        if existing_hash and existing_hash[0] == content_hash:
            skipped += 1
            continue

        # Combine content with type and tags for richer embedding
        combined = f"[{mem_type}] {content}"
        if tags:
            combined += f" (tags: {tags})"

        embedding = embed_text(combined)
        packed = pack_embedding(embedding)

        emb_conn.execute(
            """INSERT OR REPLACE INTO embeddings (memory_id, embedding, content_hash)
               VALUES (?, ?, ?)""",
            (memory_id, packed, content_hash)
        )
        indexed += 1

    emb_conn.commit()
    emb_conn.close()
    print(json.dumps({"indexed": indexed, "skipped": skipped, "total": len(rows)}))

def cmd_add(memory_db: str, embeddings_db: str, memory_id: str):
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
    import hashlib
    content_hash = hashlib.md5(content.encode()).hexdigest()

    combined = f"[{mem_type}] {content}"
    if tags:
        combined += f" (tags: {tags})"

    embedding = embed_text(combined)
    packed = pack_embedding(embedding)

    emb_conn = init_embeddings_db(embeddings_db)
    emb_conn.execute(
        """INSERT OR REPLACE INTO embeddings (memory_id, embedding, content_hash)
           VALUES (?, ?, ?)""",
        (memory_id, packed, content_hash)
    )
    emb_conn.commit()
    emb_conn.close()
    print(json.dumps({"indexed": memory_id}))

def cmd_status(embeddings_db: str):
    db_path = Path(embeddings_db)
    if not db_path.exists():
        print(json.dumps({"exists": False, "count": 0, "size_mb": 0}))
        return

    conn = sqlite3.connect(embeddings_db)
    count = conn.execute("SELECT COUNT(*) FROM embeddings").fetchone()[0]
    conn.close()

    size_mb = round(db_path.stat().st_size / (1024 * 1024), 2)
    print(json.dumps({"exists": True, "count": count, "size_mb": size_mb}))

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    command = sys.argv[1]

    if command == "embed":
        cmd_embed(sys.argv[2])
    elif command == "search":
        cmd_search(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]) if len(sys.argv) > 5 else 5)
    elif command == "index":
        cmd_index(sys.argv[2], sys.argv[3])
    elif command == "add":
        cmd_add(sys.argv[2], sys.argv[3], sys.argv[4])
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
# Setup: install dependencies and model
#######################################
cmd_setup() {
    log_info "Setting up semantic memory embeddings..."

    if ! command -v python3 &>/dev/null; then
        log_error "Python 3 is required. Install it first."
        return 1
    fi

    log_info "Installing Python dependencies..."
    pip install --quiet sentence-transformers numpy

    log_info "Creating embedding engine..."
    create_python_engine

    log_info "Downloading model (all-MiniLM-L6-v2, ~90MB)..."
    python3 "$PYTHON_SCRIPT" embed "test" > /dev/null

    log_success "Semantic memory setup complete."
    log_info "Run 'memory-embeddings-helper.sh index' to index existing memories."
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

    create_python_engine

    log_info "Indexing memories with $MODEL_NAME..."
    local result
    result=$(python3 "$PYTHON_SCRIPT" index "$MEMORY_DB" "$EMBEDDINGS_DB")

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

    log_success "Indexed $indexed new memories ($skipped unchanged, $total total)"
    return 0
}

#######################################
# Search memories semantically
#######################################
cmd_search() {
    local query=""
    local limit=5
    local format="text"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit|-l) limit="$2"; shift 2 ;;
            --json) format="json"; shift ;;
            --format) format="$2"; shift 2 ;;
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

    create_python_engine

    local result
    result=$(python3 "$PYTHON_SCRIPT" search "$EMBEDDINGS_DB" "$MEMORY_DB" "$query" "$limit")

    if [[ "$format" == "json" ]]; then
        echo "$result"
    else
        echo ""
        echo "=== Semantic Search: \"$query\" ==="
        echo ""
        if command -v jq &>/dev/null; then
            echo "$result" | jq -r '.[] | "[\(.type)] (score: \(.score)) \(.confidence)\n  \(.content)\n  Tags: \(.tags // "none")\n  Created: \(.created_at)\n"'
        else
            python3 -c "
import json, sys
results = json.loads(sys.stdin.read())
for r in results:
    print(f'[{r[\"type\"]}] (score: {r[\"score\"]}) {r[\"confidence\"]}')
    print(f'  {r[\"content\"]}')
    print(f'  Tags: {r.get(\"tags\", \"none\")}')
    print(f'  Created: {r[\"created_at\"]}')
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

    create_python_engine

    local result
    result=$(python3 "$PYTHON_SCRIPT" add "$MEMORY_DB" "$EMBEDDINGS_DB" "$memory_id")

    if echo "$result" | grep -q '"error"'; then
        log_error "$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['error'])" 2>/dev/null || echo "$result")"
        return 1
    fi

    log_success "Indexed memory: $memory_id"
    return 0
}

#######################################
# Show index status
#######################################
cmd_status() {
    if [[ ! -f "$EMBEDDINGS_DB" ]]; then
        log_info "Embeddings index: not created"
        log_info "Run 'memory-embeddings-helper.sh setup' to enable semantic search"
        return 0
    fi

    if ! check_deps; then
        log_warn "Dependencies not installed but index exists"
        log_info "Run 'memory-embeddings-helper.sh setup' to install dependencies"
        return 0
    fi

    create_python_engine

    local result
    result=$(python3 "$PYTHON_SCRIPT" status "$EMBEDDINGS_DB")

    local count size_mb
    if command -v jq &>/dev/null; then
        count=$(echo "$result" | jq -r '.count')
        size_mb=$(echo "$result" | jq -r '.size_mb')
    else
        count=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])")
        size_mb=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['size_mb'])")
    fi

    log_info "Embeddings index: $count memories indexed (${size_mb}MB)"
    log_info "Model: $MODEL_NAME (${EMBEDDING_DIM}d)"
    log_info "Database: $EMBEDDINGS_DB"

    # Compare with memory DB
    if [[ -f "$MEMORY_DB" ]]; then
        local total_memories
        total_memories=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "?")
        log_info "Total memories: $total_memories ($(( total_memories - count )) unindexed)"
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
    echo "memory-embeddings-helper.sh - Semantic memory search (opt-in)"
    echo ""
    echo "Usage:"
    echo "  memory-embeddings-helper.sh setup              Install dependencies + model"
    echo "  memory-embeddings-helper.sh index              Index all existing memories"
    echo "  memory-embeddings-helper.sh search \"query\"     Semantic similarity search"
    echo "  memory-embeddings-helper.sh search \"q\" -l 10   Search with custom limit"
    echo "  memory-embeddings-helper.sh add <memory_id>    Index single memory"
    echo "  memory-embeddings-helper.sh status             Show index stats"
    echo "  memory-embeddings-helper.sh rebuild            Rebuild entire index"
    echo "  memory-embeddings-helper.sh help               Show this help"
    echo ""
    echo "This is opt-in. FTS5 keyword search (memory-helper.sh recall) works without this."
    echo "Requires: Python 3.9+, sentence-transformers (~90MB model download)"
    return 0
}

#######################################
# Main entry point
#######################################
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        setup) cmd_setup ;;
        index) cmd_index ;;
        search) cmd_search "$@" ;;
        add) cmd_add "${1:-}" ;;
        status) cmd_status ;;
        rebuild) cmd_rebuild ;;
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
