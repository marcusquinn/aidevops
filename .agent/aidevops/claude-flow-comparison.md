---
description: Feature comparison between aidevops and Claude-Flow
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
model: haiku
---

# Claude-Flow vs aidevops Comparison

Selective feature adoption from [ruvnet/claude-flow](https://github.com/ruvnet/claude-flow) v3.

## Philosophy

| Aspect | Claude-Flow | aidevops |
|--------|-------------|----------|
| Language | TypeScript (~340MB) | Shell scripts (~2MB) |
| Dependencies | Heavy (ONNX, WASM, gRPC) | Minimal (sqlite3, curl) |
| Architecture | Monolithic orchestrator | Composable subagents |
| Model routing | Automatic 3-tier | Guided via frontmatter |
| Memory | HNSW vector (built-in) | FTS5 default + embeddings opt-in |
| Coordination | Byzantine fault-tolerant | Async TOON mailbox |

## Feature Adoption Status

| Feature | Claude-Flow | aidevops Adoption | Status |
|---------|-------------|-------------------|--------|
| Vector memory | HNSW (built-in) | Optional embeddings via all-MiniLM-L6-v2 | Done |
| Cost routing | 3-tier automatic (SONA) | Model tier guidance + `model:` frontmatter | Done |
| Self-learning | SONA neural architecture | SUCCESS/FAILURE pattern tracking | Done |
| Swarm consensus | Byzantine/Raft | Skipped (async mailbox sufficient) | Skipped |
| WASM transforms | Agent Booster | Skipped (Edit tool fast enough) | Skipped |

## What We Adopted

### 1. Cost-Aware Model Routing

**Claude-Flow**: Automatic 3-tier routing with SONA neural architecture that learns optimal model selection.

**aidevops**: Documented routing guidance in `tools/context/model-routing.md` with `model:` field in subagent YAML frontmatter. Five tiers: haiku, flash, sonnet, pro, opus. `/route` command suggests optimal tier for a task.

**Why this approach**: aidevops agents run inside existing AI tools (Claude Code, OpenCode, Cursor) which handle model selection. Guidance is more appropriate than automatic routing.

### 2. Semantic Memory with Embeddings

**Claude-Flow**: Built-in HNSW vector index, always-on semantic search.

**aidevops**: Optional `memory-embeddings-helper.sh` using all-MiniLM-L6-v2 (~90MB). FTS5 keyword search remains default. `--semantic` flag on `memory-helper.sh recall` delegates to embeddings when available.

**Why this approach**: Most memory queries work fine with keyword search. Embeddings add ~90MB of dependencies. Opt-in keeps the framework lightweight for users who don't need it.

### 3. Success Pattern Tracking

**Claude-Flow**: SONA neural architecture tracks routing decisions and outcomes.

**aidevops**: `pattern-tracker-helper.sh` records SUCCESS_PATTERN and FAILURE_PATTERN memories tagged with task type and model tier. `/patterns` command surfaces relevant patterns for new tasks.

**Why this approach**: Simple pattern storage in existing SQLite memory is sufficient. No need for neural architecture when the pattern corpus is small (hundreds, not millions).

## What We Skipped

### Swarm Consensus

**Claude-Flow**: Byzantine fault-tolerant coordination for multi-agent consensus.

**Why skipped**: aidevops uses async TOON mailbox for inter-agent communication. Most tasks don't need consensus - they need coordination. The mailbox pattern is simpler and sufficient.

### WASM Transforms (Agent Booster)

**Claude-Flow**: WASM-based code transforms for performance.

**Why skipped**: The Edit tool is already fast enough. WASM adds complexity without meaningful benefit for the file sizes aidevops typically handles.

## Key Insight

Claude-Flow solves problems at scale (thousands of agents, millions of memories, real-time routing). aidevops operates at human scale (1-5 agents, hundreds of memories, session-based routing). The right solution depends on the scale.
