# t1338: Local AI Model Support (llama.cpp + HuggingFace)

## Origin

- **Created:** 2026-02-25
- **Session:** claude-code:local-models-planning
- **Created by:** human + ai-interactive
- **Parent task:** none
- **Conversation context:** User researched local model runtimes (Ollama, LM Studio, llama.cpp, Jan.ai) and concluded llama.cpp is the best option for aidevops integration based on open-source licensing (MIT), security posture (no daemon by default), raw speed (20-70% faster than Ollama), and full HuggingFace GGUF access. Discussion covered macOS Apple Silicon + Linux support, guided setup, model discovery, usage logging, and disk cleanup recommendations.

## What

Add local AI model inference support to aidevops via llama.cpp as the primary runtime, with HuggingFace as the model source. This includes:

1. **Extend `model-routing.md`** — add `local` as the cheapest tier (cost $0) in the existing routing hierarchy: `local → haiku → flash → sonnet → pro → opus`
2. **New subagent `tools/local-models/local-models.md`** — setup guide, runtime management, model lifecycle, hardware detection, guided model selection
3. **New subagent `tools/local-models/huggingface.md`** — model discovery, GGUF format guidance, quantization selection, recommended models by hardware tier
4. **New script `scripts/local-model-helper.sh`** — CLI for install, serve, status, stop, models, search, pull, recommend, usage, cleanup, update
5. **Usage logging** — SQLite table tracking per-model invocations, tokens, duration for cost comparison and cleanup recommendations
6. **Disk management** — periodic nudge for unused models (30+ day threshold), cleanup command with size reporting

The user/system will experience: `aidevops local install` detects hardware, downloads llama.cpp binary, recommends models → `aidevops local pull <model>` downloads from HuggingFace → `aidevops local serve` starts OpenAI-compatible API on localhost → model-routing can route cheap tasks to local models → periodic cleanup nudges save disk space.

## Why

- **Cost**: Local models are free to run — $0 per token vs cloud API costs. For high-volume tasks (bulk processing, RAG, coding assistance), this is significant savings.
- **Privacy**: Some users/orgs cannot send data to cloud APIs. Local inference keeps everything on-device.
- **Speed for small tasks**: Local models can be faster than cloud round-trips for simple tasks (no network latency).
- **Offline capability**: Works without internet after model download.
- **Model access**: HuggingFace has thousands of GGUF models including Qwen, Llama, DeepSeek, Mistral — users want to try anything available.
- **Framework completeness**: aidevops already routes across 5 cloud tiers. Adding local as tier 0 completes the cost spectrum.

## How (Approach)

### t1338.1 — Extend model-routing.md

- Edit `tools/context/model-routing.md` to add `local` tier to Model Tiers table, Routing Rules, Cost Estimation, Decision Flowchart, and Examples
- Add local tier to fallback routing (local has no fallback — if unavailable, skip to haiku)
- Add `local-model-helper.sh status` to Provider Discovery section
- Pattern: follow existing tier structure exactly

### t1338.2 — Create local-models.md subagent

- New file: `.agents/tools/local-models/local-models.md`
- Cover: llama.cpp overview, why chosen over alternatives (Ollama security issues, LM Studio closed-source), supported platforms (macOS ARM/x64, Linux x64/ARM/Vulkan/ROCm/CUDA), setup flow, server management, integration with model-routing
- Include hardware detection guidance (Apple Silicon unified memory, NVIDIA VRAM, AMD ROCm)
- Reference: `tools/context/model-routing.md` for routing integration

### t1338.3 — Create huggingface.md subagent

- New file: `.agents/tools/local-models/huggingface.md`
- Cover: HuggingFace CLI (`huggingface-cli download`), GGUF format explanation, quantization tiers (Q4_K_M, Q5_K_M, Q6_K, IQ3_XXS etc.), model size vs quality tradeoffs
- Recommended models table by hardware tier (8GB, 16GB, 32GB, 64GB+, 128GB+)
- Model families: Qwen3, Llama3, DeepSeek, Mistral, Gemma, Phi — with use-case guidance (coding, chat, reasoning)
- Search patterns for finding good GGUF repos (bartowski, lmstudio-community, ggml-org)

### t1338.4 — Create local-model-helper.sh

- New file: `.agents/scripts/local-model-helper.sh`
- Subcommands: install, serve, stop, status, models, search, pull, recommend, usage, cleanup, update
- `install`: detect platform (macOS ARM/x64, Linux x64/ARM), download correct llama.cpp binary from GitHub releases, verify checksum, install to `~/.aidevops/bin/`
- `serve [model]`: start `llama-server` on localhost:8080 with sensible defaults (context size, parallel requests, jinja templates)
- `stop`: kill running server gracefully
- `status`: show running server info, loaded model, memory usage
- `models`: list downloaded models with size, last-used date, total invocations
- `search <query>`: search HuggingFace API for GGUF models
- `pull <repo/model>`: download from HuggingFace with progress to `~/.aidevops/models/`
- `recommend`: detect hardware, suggest 2-3 models that fit
- `usage`: show per-model usage stats from SQLite
- `cleanup`: flag models unused 30+ days, show disk savings, prompt removal
- `update`: check for newer llama.cpp release, update binary
- Follow existing helper script patterns: `local var="$1"`, explicit returns, ShellCheck clean

### t1338.5 — Usage logging and disk management

- SQLite table in `~/.aidevops/.agent-workspace/memory/local-models.db`:
  ```sql
  CREATE TABLE model_usage (
      model TEXT NOT NULL,
      timestamp TEXT NOT NULL DEFAULT (datetime('now')),
      tokens_in INTEGER DEFAULT 0,
      tokens_out INTEGER DEFAULT 0,
      duration_ms INTEGER DEFAULT 0
  );
  CREATE TABLE model_inventory (
      model TEXT PRIMARY KEY,
      path TEXT NOT NULL,
      size_bytes INTEGER,
      downloaded TEXT DEFAULT (datetime('now')),
      last_used TEXT
  );
  ```
- Log usage on each `serve` session end (or per-request if feasible)
- `cleanup` command: query models where `last_used < datetime('now', '-30 days')`, show table with model/size/last-used, prompt for removal
- Session-start nudge: if stale models exist and total stale size > 5 GB, show one-line reminder

### t1338.6 — Update AGENTS.md domain index and subagent-index.toon

- Add local-models entry to domain index table in `.agents/AGENTS.md`
- Add entries to `subagent-index.toon`
- Update model-routing related references

## Acceptance Criteria

- [ ] `model-routing.md` includes `local` tier with routing rules, cost table ($0), decision flowchart branch, and examples
  ```yaml
  verify:
    method: codebase
    pattern: "\\| `local`"
    path: ".agents/tools/context/model-routing.md"
  ```
- [ ] `tools/local-models/local-models.md` exists with llama.cpp setup guide, platform support matrix, server management commands
  ```yaml
  verify:
    method: codebase
    pattern: "llama-server"
    path: ".agents/tools/local-models/local-models.md"
  ```
- [ ] `tools/local-models/huggingface.md` exists with model discovery guide, quantization table, hardware-tier recommendations
  ```yaml
  verify:
    method: codebase
    pattern: "Q[456]_K_M"
    path: ".agents/tools/local-models/huggingface.md"
  ```
- [ ] `scripts/local-model-helper.sh` exists with all subcommands (install, serve, stop, status, models, search, pull, recommend, usage, cleanup, update)
  ```yaml
  verify:
    method: bash
    run: "grep -c 'cmd_' .agents/scripts/local-model-helper.sh | awk '{if ($1 >= 10) exit 0; else exit 1}'"
  ```
- [ ] ShellCheck clean on local-model-helper.sh
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/local-model-helper.sh"
  ```
- [ ] Usage logging SQLite schema defined and created on first use
  ```yaml
  verify:
    method: codebase
    pattern: "CREATE TABLE model_usage"
    path: ".agents/scripts/local-model-helper.sh"
  ```
- [ ] Cleanup command identifies models unused for 30+ days with disk size reporting
  ```yaml
  verify:
    method: codebase
    pattern: "-30 days"
    path: ".agents/scripts/local-model-helper.sh"
  ```
- [ ] AGENTS.md domain index includes local-models entry
  ```yaml
  verify:
    method: codebase
    pattern: "local-models"
    path: ".agents/AGENTS.md"
  ```
- [ ] Lint clean (shellcheck, markdownlint)

## Context & Decisions

- **llama.cpp chosen over Ollama** — Ollama has serious security track record (175k+ exposed instances found Jan 2026, multiple CVEs), is 20-70% slower than raw llama.cpp, and is just a wrapper around llama.cpp anyway. llama.cpp is MIT licensed, fastest, most secure (no daemon by default).
- **llama.cpp chosen over LM Studio** — LM Studio's frontend is closed-source. It uses llama.cpp under the hood. For a framework that values open-source, going direct to llama.cpp is cleaner.
- **Not bundling binaries** — llama.cpp releases weekly (b8152 current), binaries are platform-specific (29 MB macOS ARM, 23 MB Linux x64). Download-on-first-use avoids staleness and bloat.
- **HuggingFace as model source** — largest open model repository, GGUF is the standard format, `huggingface-cli` handles auth and large file downloads well. No walled garden like Ollama's library.
- **Single model-routing.md** — local models are just another tier in the same routing decision. Separate files would create false separation.
- **SQLite for usage logging** — consistent with existing framework pattern (memory system, model registry, budget tracker all use SQLite).
- **30-day cleanup threshold** — models are large (2-50+ GB). Unused models waste significant disk space. 30 days is generous enough to avoid premature cleanup.
- **Ollama as optional fallback** — not planned for initial implementation. Users who already have Ollama can point model-routing at its API manually. Future subtask if demand exists.

## Relevant Files

- `.agents/tools/context/model-routing.md` — extend with local tier
- `.agents/scripts/compare-models-helper.sh` — pattern for provider discovery
- `.agents/scripts/model-registry-helper.sh` — pattern for SQLite model tracking
- `.agents/scripts/model-availability-helper.sh` — pattern for health probes
- `.agents/AGENTS.md` — domain index to update
- `.agents/templates/brief-template.md` — this brief follows its format

## Dependencies

- **Blocked by:** nothing
- **Blocks:** future local-model MCP server, Ollama fallback support, local model fine-tuning support
- **External:** llama.cpp GitHub releases (public), HuggingFace API (public, optional auth for gated models)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| t1338.1 Extend model-routing.md | ~1h | Add local tier to existing structure |
| t1338.2 Create local-models.md | ~2h | Subagent doc with setup guide |
| t1338.3 Create huggingface.md | ~2h | Model discovery and recommendation guide |
| t1338.4 Create local-model-helper.sh | ~6h | Main implementation — 11 subcommands |
| t1338.5 Usage logging + disk management | ~2h | SQLite schema, cleanup logic, nudge |
| t1338.6 Update AGENTS.md + index | ~30m | Domain index entries |
| **Total** | **~13.5h** | |
