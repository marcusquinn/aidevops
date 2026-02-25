---
description: Local AI model inference via llama.cpp - hardware-aware setup, HuggingFace GGUF models, usage tracking, disk cleanup
mode: subagent
model: haiku
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: false
---

# Local Models - llama.cpp Inference

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Run AI models locally via llama.cpp for free, private, offline inference
- **Runtime**: llama.cpp (MIT, fastest, no daemon, localhost only)
- **Models**: Any GGUF from HuggingFace (Qwen, Llama, DeepSeek, Mistral, Gemma, Phi)
- **Binary**: Download-on-first-use via `local-model-helper.sh setup`
- **API**: OpenAI-compatible at `http://localhost:8080/v1`
- **Helper**: `local-model-helper.sh [setup|start|stop|status|models|download|search|recommend|cleanup|usage|benchmark]` (planned — not yet implemented; tracked in parent task t1338)

**When to use local**: Privacy/compliance, offline work, bulk processing, experimentation, simple tasks where network latency exceeds local inference time. See `tools/context/model-routing.md` for routing rules.

**When NOT to use local**: Complex reasoning, large-context analysis (>32K), architecture decisions, tasks requiring frontier model capabilities.

<!-- AI-CONTEXT-END -->

## Why llama.cpp

| Criterion | llama.cpp | Ollama | LM Studio | Jan.ai |
|-----------|-----------|--------|-----------|--------|
| License | MIT | MIT | Closed frontend | AGPL |
| Speed | Fastest (baseline) | 20-70% slower | Same engine | Same engine |
| Security | No daemon, localhost only | 175k+ exposed instances (Jan 2024), multiple CVEs | Desktop-safe | Desktop-safe |
| Binary size | 23-130 MB (platform-dependent) | ~200 MB | ~500 MB+ | ~300 MB+ |
| HuggingFace access | Direct GGUF download | Walled library | HF browser built-in | HF download |
| Control | Full (quantization, context, sampling) | Abstracted | GUI-mediated | GUI-mediated |

Every other tool wraps llama.cpp. Using it directly gives maximum control, minimum overhead, and no security surface area from unnecessary daemons.

## Installation

llama.cpp releases weekly. The helper downloads the correct platform binary on first use — no bundling.

```bash
# Install llama.cpp + huggingface-cli (one-time)
local-model-helper.sh setup

# What this does:
# 1. Detects platform (macOS ARM/x64, Linux x64/Vulkan/ROCm)
# 2. Downloads latest llama.cpp release binary (23-130 MB depending on platform)
# 3. Installs huggingface-cli if not present (pip install huggingface_hub[cli])
# 4. Creates ~/.aidevops/local-models/ directory structure
```

### Binary Sizes by Platform

| Platform | Size |
|----------|------|
| macOS ARM64 | 29 MB |
| macOS x64 | 82 MB |
| Linux x64 (CPU) | 23 MB |
| Linux Vulkan | 40 MB |
| Linux ROCm | 130 MB |

### Directory Structure

```text
~/.aidevops/local-models/
├── bin/                    # llama.cpp binaries
│   └── llama-server        # Main server binary
├── models/                 # Downloaded GGUF files
│   ├── qwen3-8b-q4_k_m.gguf
│   └── ...
├── usage.db                # SQLite usage tracking
└── config.json             # Server defaults (port, context, threads)
```

## Hardware Detection

The helper detects available hardware and recommends appropriate models:

```bash
# Show hardware capabilities and model recommendations
local-model-helper.sh recommend

# Example output:
# Hardware: Apple M3 Pro, 36GB RAM, 18GB available for models
# GPU: Metal (Apple Silicon - native acceleration)
#
# Recommended models:
#   Small  (fast):  Qwen3-4B-Q4_K_M     (~2.5 GB, ~40 tok/s)
#   Medium (balanced): Qwen3-8B-Q4_K_M  (~5 GB, ~25 tok/s)
#   Large  (capable): Llama-3.1-8B-Q6_K (~6.5 GB, ~18 tok/s)
#
# Your hardware can run models up to ~12 GB comfortably.
```

### VRAM/RAM Guidelines

| Available Memory | Max Model Size | Recommended Quantization |
|-----------------|---------------|-------------------------|
| 8 GB | ~4 GB model | Q4_K_M (4-bit) |
| 16 GB | ~10 GB model | Q4_K_M or Q5_K_M |
| 32 GB | ~20 GB model | Q5_K_M or Q6_K |
| 64 GB | ~45 GB model | Q6_K or Q8_0 |
| 96+ GB | ~70 GB model | Q8_0 or FP16 |

Reserve at least 4 GB for the OS and other applications. Apple Silicon uses unified memory — the full RAM is available for model inference via Metal.

## Model Discovery and Download

Models come from HuggingFace. The helper searches, filters, and downloads GGUF files.

```bash
# Search HuggingFace for GGUF models
local-model-helper.sh search "qwen3 8b"

# Download a specific model (with resume support)
local-model-helper.sh download Qwen/Qwen3-8B-GGUF --quant Q4_K_M

# List downloaded models
local-model-helper.sh models

# Example output:
# NAME                          SIZE     QUANT    DOWNLOADED
# qwen3-8b-q4_k_m.gguf        4.9 GB   Q4_K_M   YYYY-MM-DD
# llama-3.1-8b-q6_k.gguf      6.6 GB   Q6_K     YYYY-MM-DD
# deepseek-r1-7b-q4_k_m.gguf  4.1 GB   Q4_K_M   YYYY-MM-DD
```

### Recommended Models by Use Case

Recommend by capability tier, not specific model versions (models release frequently):

| Use Case | Model Family | Size Range | Notes |
|----------|-------------|-----------|-------|
| Code completion | Qwen3, DeepSeek-Coder | 4-8B | Strong code understanding |
| General chat | Llama 3, Qwen3, Gemma 3 | 4-8B | Good all-round capability |
| Reasoning | DeepSeek-R1, Qwen3 (thinking mode) | 7-14B | Chain-of-thought built in |
| Summarization | Llama 3, Phi-4 | 4-8B | Fast, good at extraction |
| Translation | Qwen3, NLLB | 4-8B | Strong multilingual support |
| Embeddings | nomic-embed, bge-large | 0.1-0.3B | For RAG indexing |

### Quantization Guide

| Quantization | Size vs FP16 | Quality Loss | Best For |
|-------------|-------------|-------------|----------|
| Q4_K_M | ~25% | Minimal | Default choice — best size/quality balance |
| Q5_K_M | ~33% | Very small | When you have the RAM and want better quality |
| Q6_K | ~50% | Negligible | Near-lossless, good for important tasks |
| Q8_0 | ~66% | None measurable | Maximum quality, if RAM allows |
| IQ4_XS | ~22% | Small | Absolute minimum size, still usable |

## Running the Server

```bash
# Start server with a model (OpenAI-compatible API)
local-model-helper.sh start --model qwen3-8b-q4_k_m.gguf

# Start with custom settings
local-model-helper.sh start \
  --model qwen3-8b-q4_k_m.gguf \
  --port 8080 \
  --ctx-size 8192 \
  --threads 8 \
  --gpu-layers 99

# Check server status
local-model-helper.sh status

# Example output:
# Server: running (PID 12345)
# Model:  qwen3-8b-q4_k_m.gguf (4.9 GB)
# API:    http://localhost:8080/v1
# Uptime: 2h 15m
# Requests: 142 (avg 24 tok/s)

# Stop server
local-model-helper.sh stop
```

### Server Defaults

Stored in `~/.aidevops/local-models/config.json`:

```json
{
  "port": 8080,
  "host": "127.0.0.1",
  "ctx_size": 8192,
  "threads": "auto",
  "gpu_layers": 99,
  "flash_attn": true
}
```

- `threads: "auto"` uses performance cores count (not efficiency cores)
- `gpu_layers: 99` offloads all layers to GPU (Metal on macOS, CUDA/Vulkan on Linux)
- `flash_attn: true` enables Flash Attention for faster inference

## API Usage

The server exposes an OpenAI-compatible API:

```bash
# Chat completion
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "local",
    "messages": [{"role": "user", "content": "Explain quicksort in one paragraph"}],
    "max_tokens": 256
  }'

# Embeddings (if model supports it)
curl http://localhost:8080/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{
    "model": "local",
    "input": "The quick brown fox"
  }'

# Health check
curl http://localhost:8080/health
```

### Integration with aidevops

When the local server is running, other framework components can use it.

> **Note**: These integrations require the helper scripts to be updated to recognize `local` as a tier. This is tracked in the parent task (t1338) and will be implemented in a follow-up PR.

```bash
# Model routing resolves "local" tier to localhost
model-availability-helper.sh check local
# → Exit 0 if server running, exit 1 if not

# Compare-models can include local in benchmarks
compare-models-helper.sh compare local sonnet haiku

# Response scoring works with local models
response-scoring-helper.sh prompt "Explain X" --models local,haiku,sonnet
```

## Usage Tracking

All requests are logged to SQLite for cost comparison and model evaluation:

```bash
# Show usage statistics
local-model-helper.sh usage

# Example output:
# MODEL                    REQUESTS  TOKENS_IN  TOKENS_OUT  AVG_TOK/S  LAST_USED
# qwen3-8b-q4_k_m.gguf   342       45,210     28,400      24.3       2h ago
# llama-3.1-8b-q6_k.gguf 89        12,100     8,200       18.1       3d ago
#
# Total: 431 requests, 73,310 input tokens, 36,600 output tokens
# Estimated cloud cost saved: $0.82 (vs haiku), $3.29 (vs sonnet)

# Usage for a specific period
local-model-helper.sh usage --since YYYY-MM-01

# Export as JSON for analysis
local-model-helper.sh usage --json
```

The usage database is at `~/.aidevops/local-models/usage.db` (SQLite, consistent with the framework's existing SQLite pattern for memory and pattern tracking).

## Disk Cleanup

Models are 2-50+ GB each. The helper tracks last-used dates and recommends cleanup:

```bash
# Show disk usage and cleanup recommendations
local-model-helper.sh cleanup

# Example output:
# MODEL                          SIZE     LAST USED    STATUS
# qwen3-8b-q4_k_m.gguf         4.9 GB   2h ago       active
# llama-3.1-8b-q6_k.gguf       6.6 GB   3d ago       active
# mistral-7b-q4_k_m.gguf       4.1 GB   45d ago      stale (>30d)
# phi-4-q5_k_m.gguf            8.2 GB   62d ago      stale (>30d)
#
# Total: 23.8 GB (12.3 GB stale)
# Recommendation: Remove 2 stale models to free 12.3 GB

# Remove stale models (>30 days unused)
local-model-helper.sh cleanup --remove-stale

# Remove a specific model
local-model-helper.sh cleanup --remove mistral-7b-q4_k_m.gguf

# Change stale threshold (default: 30 days)
local-model-helper.sh cleanup --threshold 60
```

## Benchmarking

Compare local model performance on your hardware:

```bash
# Benchmark a model (tokens/second, time-to-first-token)
local-model-helper.sh benchmark --model qwen3-8b-q4_k_m.gguf

# Example output:
# Model: qwen3-8b-q4_k_m.gguf
# Hardware: Apple M3 Pro (Metal)
# Prompt eval: 312 tok/s
# Generation:  24.3 tok/s
# Time to first token: 0.8s
# Context: 8192 tokens

# Compare multiple models
local-model-helper.sh benchmark --model qwen3-8b-q4_k_m.gguf --model llama-3.1-8b-q6_k.gguf
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `setup` fails on Linux | Check glibc compatibility (`ldd --version`); for ROCm, ensure ROCm runtime is installed; try `local-model-helper.sh setup --update` |
| Slow inference (no GPU) | Check `gpu_layers` is set; verify Metal/CUDA is detected: `local-model-helper.sh status` |
| Model download interrupted | Re-run `download` — `huggingface-cli` resumes automatically |
| Out of memory | Use a smaller quantization (Q4_K_M) or smaller model; check `local-model-helper.sh recommend` |
| Port already in use | Change port: `local-model-helper.sh start --port 8081` or stop existing: `local-model-helper.sh stop` |
| Server crashes on large context | Reduce `--ctx-size` (default 8192); larger contexts need more RAM |
| Binary outdated | Re-run `local-model-helper.sh setup --update` to fetch latest release |

## Security

- Server binds to `127.0.0.1` only — not accessible from network
- No daemon process — server runs only when explicitly started
- No telemetry or external connections during inference
- Model files are stored locally with user permissions
- No API keys required for local inference

## See Also

- `tools/context/model-routing.md` — Cost-aware routing (local is the free tier)
- `tools/infrastructure/cloud-gpu.md` — Cloud GPU deployment for larger models
- `tools/ai-assistants/compare-models.md` — Model comparison including local
- `tools/voice/speech-to-speech.md` — Voice pipeline (can use local models for LLM step)
