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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Claude-Flow vs aidevops Comparison

Selective feature adoption from [ruvnet/claude-flow](https://github.com/ruvnet/claude-flow) v3.

## Baseline Differences

| Aspect | Claude-Flow | aidevops |
|--------|-------------|----------|
| Language | TypeScript (~340MB) | Shell scripts (~2MB) |
| Dependencies | Heavy (ONNX, WASM, gRPC) | Minimal (sqlite3, curl) |
| Architecture | Monolithic orchestrator | Composable subagents |
| Model routing | Automatic 3-tier | Guided via frontmatter |
| Memory | HNSW vector (built-in) | FTS5 default + embeddings opt-in |
| Coordination | Byzantine fault-tolerant | Async TOON mailbox |

## Adoption Summary

| Area | Claude-Flow | aidevops | Status | Why |
|------|-------------|----------|--------|-----|
| Cost-aware routing | Automatic 3-tier routing via SONA | `model:` frontmatter, `tools/context/model-routing.md`, `/route`, five tiers (haiku, flash, sonnet, pro, opus) | Adopted | Host runtimes already choose models; guidance is a better fit than framework-level automation |
| Semantic memory | Built-in HNSW, always-on semantic search | Optional `memory-embeddings-helper.sh` with all-MiniLM-L6-v2 (~90MB); FTS5 stays default; `memory-helper.sh recall --semantic` opts in | Adopted | Keyword search covers most use; embeddings stay optional to keep the framework lightweight |
| Outcome learning | SONA tracks routing decisions and outcomes | Pulse supervisor observes GitHub outcomes; agents use `/remember`, `/recall`, and `/patterns`; `pattern-tracker-helper.sh` was retired in favour of universal memory | Adopted | SQLite-backed pattern storage is enough for a small corpus |
| Swarm consensus | Byzantine/Raft-style consensus | Not adopted | Skipped | Async TOON mailbox handles coordination without adding consensus machinery |
| WASM transforms | Agent Booster | Not adopted | Skipped | The Edit tool is already fast enough for the file sizes aidevops handles |

## Scale Fit

aidevops keeps the Claude-Flow ideas that improve human-scale agent work and drops the ones aimed at much larger systems. Claude-Flow targets thousands of agents, millions of memories, and real-time routing. aidevops targets 1-5 agents, hundreds of memories, and session-scoped routing, so guidance, optional embeddings, and mailbox coordination are usually enough.
