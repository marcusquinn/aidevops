---
description: HuggingFace model discovery - GGUF format, quantization guidance, hardware-tier recommendations, trusted publishers
mode: subagent
model: haiku
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: true
  task: false
---

# HuggingFace Model Discovery

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Find, evaluate, and download GGUF models from HuggingFace for local inference via llama.cpp
- **CLI**: `huggingface-cli download <repo> <file> --local-dir <path>` (resume-capable, large-file safe)
- **Format**: GGUF (GPT-Generated Unified Format) — single-file, self-contained, llama.cpp native
- **Helper**: `local-model-helper.sh search|download|models|recommend` (wraps huggingface-cli)
- **Trusted publishers**: bartowski, lmstudio-community, ggml-org, unsloth, Qwen, meta-llama, deepseek-ai, mistralai, google

**When to use this guide**: Choosing which model to download, understanding quantization trade-offs, finding GGUF versions of new models, evaluating model size vs hardware fit.

**See also**: `tools/local-models/local-models.md` (llama.cpp runtime), `tools/context/model-routing.md` (routing rules)

<!-- AI-CONTEXT-END -->

## GGUF Format

GGUF (GPT-Generated Unified Format) is the standard format for llama.cpp inference. Key properties:

| Property | Detail |
|----------|--------|
| File extension | `.gguf` |
| Structure | Single file containing model weights, tokenizer, and metadata |
| Quantization | Built-in — each file is pre-quantized to a specific precision |
| Compatibility | llama.cpp, Ollama, LM Studio, Jan.ai, GPT4All, kobold.cpp |
| Predecessor | Replaced GGML format (2023) |

A single GGUF file is everything needed to run a model. No separate tokenizer files, no config directories, no framework dependencies.

### How GGUF Files Are Named

Standard naming convention: `{model}-{size}-{quantization}.gguf`

```text
qwen3-8b-q4_k_m.gguf
│      │   └── Quantization: Q4_K_M (4-bit, K-quant, medium)
│      └────── Parameter count: 8 billion
└───────────── Model family: Qwen 3
```

Some publishers use slightly different conventions, but the quantization suffix is consistent.

## Quantization Guide

Quantization reduces model precision to shrink file size and speed up inference. The trade-off is quality — lower precision means slightly less accurate outputs.

### Quantization Tiers

| Quantization | Bits | Size vs FP16 | Quality Loss | Best For |
|-------------|------|-------------|-------------|----------|
| Q4_K_M | 4-bit | ~25% | Minimal | **Default choice** — best size/quality balance |
| Q4_K_S | 4-bit | ~24% | Small | Slightly smaller than Q4_K_M, marginally lower quality |
| Q5_K_M | 5-bit | ~33% | Very small | When you have the RAM and want better quality |
| Q5_K_S | 5-bit | ~32% | Small | Slightly smaller than Q5_K_M |
| Q6_K | 6-bit | ~50% | Negligible | Near-lossless, good for important tasks |
| Q8_0 | 8-bit | ~66% | None measurable | Maximum quality, if RAM allows |
| IQ4_XS | 4-bit | ~22% | Small | Absolute minimum size, still usable |
| IQ3_XXS | 3-bit | ~17% | Moderate | Extreme compression, noticeable quality drop |
| FP16 | 16-bit | 100% | None | Full precision, requires 2x the parameter count in GB |

### Choosing a Quantization

```text
Is RAM tight (model must fit in <60% of available memory)?
  → YES: Q4_K_M (or IQ4_XS if very tight)
  → NO: Do you need maximum quality?
    → YES: Q6_K or Q8_0
    → NO: Q5_K_M (good balance when RAM is not a constraint)
```

**Rule of thumb**: Q4_K_M is the right default for almost everyone. Move to Q5_K_M or Q6_K only when you have confirmed the model fits comfortably in memory at that quantization.

## Hardware-Tier Model Recommendations

Models are recommended by available memory (RAM on Apple Silicon, VRAM on discrete GPUs). Reserve at least 4 GB for the OS and applications.

### 8 GB Available (e.g., MacBook Air M2 8GB, GTX 1070)

| Use Case | Model Family | Quantization | Approx Size | Notes |
|----------|-------------|-------------|-------------|-------|
| General chat | Qwen3-4B | Q4_K_M | ~2.5 GB | Fast, good quality for size |
| Code completion | Qwen3-4B | Q4_K_M | ~2.5 GB | Strong code understanding |
| Summarization | Phi-4-mini | Q4_K_M | ~2.3 GB | Good at extraction tasks |
| Embeddings | nomic-embed-text-v1.5 | FP16 | ~0.3 GB | For RAG indexing |

**Limit**: Models up to ~4 GB. Stick to 1-4B parameter models at Q4_K_M.

### 16 GB Available (e.g., MacBook Pro M3 16GB, RTX 3060 12GB)

| Use Case | Model Family | Quantization | Approx Size | Notes |
|----------|-------------|-------------|-------------|-------|
| General chat | Qwen3-8B | Q4_K_M | ~5 GB | Excellent all-round |
| Code completion | Qwen3-8B | Q4_K_M | ~5 GB | Strong code + reasoning |
| Reasoning | DeepSeek-R1-Distill-Qwen-7B | Q4_K_M | ~4.5 GB | Chain-of-thought built in |
| Translation | Qwen3-8B | Q4_K_M | ~5 GB | Strong multilingual |
| Summarization | Llama-3.1-8B | Q4_K_M | ~4.7 GB | Fast, reliable |

**Limit**: Models up to ~10 GB. 7-8B parameter models at Q4_K_M or Q5_K_M.

### 32 GB Available (e.g., MacBook Pro M3 Pro 36GB, RTX 4090 24GB)

| Use Case | Model Family | Quantization | Approx Size | Notes |
|----------|-------------|-------------|-------------|-------|
| General chat | Qwen3-14B | Q4_K_M | ~8.5 GB | Noticeably smarter than 8B |
| Code completion | Qwen3-14B | Q5_K_M | ~10.5 GB | Higher quality with room to spare |
| Reasoning | DeepSeek-R1-Distill-Qwen-14B | Q4_K_M | ~8.5 GB | Strong chain-of-thought |
| High-quality chat | Llama-3.1-8B | Q6_K | ~6.6 GB | Near-lossless 8B |
| Long context | Qwen3-8B | Q6_K | ~6.2 GB | 32K context with quality |

**Limit**: Models up to ~20 GB. 14B at Q4_K_M, or 8B at Q6_K/Q8_0.

### 64 GB Available (e.g., MacBook Pro M3 Max 64GB, dual RTX 4090)

| Use Case | Model Family | Quantization | Approx Size | Notes |
|----------|-------------|-------------|-------------|-------|
| General chat | Qwen3-32B | Q4_K_M | ~19 GB | Approaching cloud model quality |
| Code completion | Qwen3-32B | Q5_K_M | ~24 GB | Excellent code generation |
| Reasoning | DeepSeek-R1-Distill-Qwen-32B | Q4_K_M | ~19 GB | Very strong reasoning |
| High-quality 14B | Qwen3-14B | Q8_0 | ~15 GB | Maximum quality at 14B |
| Multilingual | Qwen3-32B | Q4_K_M | ~19 GB | Best multilingual at this tier |

**Limit**: Models up to ~45 GB. 32B at Q4_K_M, or 14B at Q8_0.

### 128 GB+ Available (e.g., Mac Studio M2 Ultra 192GB, multi-GPU server)

| Use Case | Model Family | Quantization | Approx Size | Notes |
|----------|-------------|-------------|-------------|-------|
| General chat | Qwen3-72B | Q4_K_M | ~42 GB | Near-frontier quality |
| Code completion | Qwen3-72B | Q4_K_M | ~42 GB | Competitive with cloud models |
| Reasoning | DeepSeek-R1-70B | Q4_K_M | ~40 GB | Excellent reasoning |
| High-quality 32B | Qwen3-32B | Q8_0 | ~34 GB | Maximum quality at 32B |
| Research | Llama-3.1-70B | Q4_K_M | ~40 GB | Strong general capability |

**Limit**: 70B+ at Q4_K_M, or 32B at FP16.

## Model Families

### Qwen 3 (Alibaba)

Best all-round open model family as of early 2026. Strong at code, multilingual, reasoning.

| Size | Parameters | Strengths |
|------|-----------|-----------|
| Qwen3-4B | 4B | Fast, good for simple tasks, low memory |
| Qwen3-8B | 8B | Excellent balance of speed and capability |
| Qwen3-14B | 14B | Noticeably smarter, good for complex tasks |
| Qwen3-32B | 32B | Approaching cloud model quality |
| Qwen3-72B | 72B | Near-frontier, competitive with GPT-4 class |

**Thinking mode**: Qwen3 supports a thinking mode (chain-of-thought) that can be enabled via system prompt. Useful for reasoning-heavy tasks.

**HuggingFace repos**: `Qwen/Qwen3-{size}-GGUF` (official), `bartowski/Qwen3-{size}-GGUF` (community quants with more options)

### Llama 3 / 3.1 (Meta)

Strong general-purpose models. Well-tested, widely supported.

| Size | Parameters | Strengths |
|------|-----------|-----------|
| Llama-3.2-3B | 3B | Lightweight, fast |
| Llama-3.1-8B | 8B | Reliable all-round |
| Llama-3.1-70B | 70B | Very capable, well-benchmarked |

**HuggingFace repos**: `meta-llama/Llama-3.1-{size}-Instruct-GGUF` (official, gated — requires HF token), `bartowski/Llama-3.1-{size}-Instruct-GGUF` (community)

### DeepSeek (DeepSeek AI)

Strong at reasoning and code. R1 models have built-in chain-of-thought.

| Size | Parameters | Strengths |
|------|-----------|-----------|
| DeepSeek-R1-Distill-Qwen-7B | 7B | Reasoning distilled into small model |
| DeepSeek-R1-Distill-Qwen-14B | 14B | Strong reasoning at medium size |
| DeepSeek-R1-Distill-Qwen-32B | 32B | Excellent reasoning |
| DeepSeek-Coder-V2-Lite | 16B | Specialized for code |

**HuggingFace repos**: `deepseek-ai/DeepSeek-R1-Distill-Qwen-{size}-GGUF` (official), `bartowski/DeepSeek-R1-Distill-Qwen-{size}-GGUF` (community)

### Mistral / Mixtral (Mistral AI)

Efficient architecture, good at instruction following.

| Size | Parameters | Strengths |
|------|-----------|-----------|
| Mistral-7B | 7B | Fast, efficient |
| Mistral-Small | 22B | Good balance |
| Mixtral-8x7B | 46B (12B active) | MoE — fast for its capability |

**HuggingFace repos**: `mistralai/Mistral-{size}-Instruct-v0.3-GGUF` (official), `bartowski/Mistral-{size}-Instruct-GGUF` (community)

### Gemma 3 (Google)

Good at instruction following, multilingual, and structured output.

| Size | Parameters | Strengths |
|------|-----------|-----------|
| Gemma-3-4B | 4B | Fast, good structured output |
| Gemma-3-12B | 12B | Strong instruction following |
| Gemma-3-27B | 27B | Very capable |

**HuggingFace repos**: `google/gemma-3-{size}-it-GGUF` (official), `bartowski/gemma-3-{size}-it-GGUF` (community)

### Phi 4 (Microsoft)

Small but capable. Good for constrained environments.

| Size | Parameters | Strengths |
|------|-----------|-----------|
| Phi-4-mini | 3.8B | Very capable for size, good at reasoning |
| Phi-4 | 14B | Strong reasoning and code |

**HuggingFace repos**: `microsoft/phi-4-gguf` (official), `bartowski/phi-4-GGUF` (community)

## Trusted GGUF Publishers

Not all GGUF conversions are equal. These publishers consistently produce high-quality quantizations:

| Publisher | HuggingFace Handle | Notes |
|-----------|-------------------|-------|
| bartowski | `bartowski` | Most comprehensive GGUF publisher. Covers nearly every popular model. Multiple quantization options per model. First choice for community quants. |
| LM Studio Community | `lmstudio-community` | High-quality quants optimized for LM Studio (works with llama.cpp too). |
| GGML.org | `ggml-org` | Official llama.cpp project quants. Reference quality. |
| Unsloth | `unsloth` | Known for efficient fine-tuning. Their GGUF exports are well-tested. |
| Official model authors | `Qwen`, `meta-llama`, `google`, `mistralai`, `deepseek-ai`, `microsoft` | Some model authors now publish official GGUF files. Prefer these when available. |

**Avoid**: Random users with few downloads, repos without README or metadata, GGUF files without clear quantization labels.

## Searching for Models

### Via local-model-helper.sh

```bash
# Search by model name
local-model-helper.sh search "qwen3 8b"

# Search with size filter
local-model-helper.sh search "llama 3.1" --max-size 10G

# List downloaded models
local-model-helper.sh models
```

### Via huggingface-cli

```bash
# Search HuggingFace for GGUF models
huggingface-cli search "qwen3 8b gguf" --type model

# Download a specific file (with resume support)
huggingface-cli download Qwen/Qwen3-8B-GGUF qwen3-8b-q4_k_m.gguf \
  --local-dir ~/.aidevops/local-models/models/

# Download from a gated repo (requires HF token)
huggingface-cli login
huggingface-cli download meta-llama/Llama-3.1-8B-Instruct-GGUF \
  llama-3.1-8b-instruct-q4_k_m.gguf \
  --local-dir ~/.aidevops/local-models/models/
```

### Via Web Browser

1. Go to `https://huggingface.co/models?library=gguf&sort=trending`
2. Filter by model name or task
3. Look for repos from trusted publishers (see above)
4. Check the "Files and versions" tab for available quantizations
5. Copy the repo ID and filename for `huggingface-cli download`

### Search Patterns for Finding Good GGUF Repos

```text
# Pattern: {publisher}/{model}-GGUF
bartowski/Qwen3-8B-GGUF
bartowski/Llama-3.1-8B-Instruct-GGUF
lmstudio-community/Qwen3-14B-GGUF

# Pattern: {official-org}/{model}-GGUF
Qwen/Qwen3-8B-GGUF
google/gemma-3-12b-it-GGUF
microsoft/phi-4-gguf

# Pattern: {official-org}/{model}-Instruct-GGUF (for instruction-tuned)
meta-llama/Llama-3.1-8B-Instruct-GGUF
mistralai/Mistral-7B-Instruct-v0.3-GGUF
```

## Installing huggingface-cli

The `local-model-helper.sh setup` command installs `huggingface-cli` automatically. For manual installation:

```bash
# Install via pip (recommended)
pip install huggingface_hub[cli]

# Or via pipx (isolated environment)
pipx install huggingface_hub[cli]

# Verify installation
huggingface-cli version

# Login (required for gated models like Llama)
huggingface-cli login
```

### Authentication

Most GGUF models are public and require no authentication. Gated models (e.g., Meta's Llama) require a HuggingFace account and token:

1. Create account at `https://huggingface.co/join`
2. Accept the model's license on its HuggingFace page
3. Run `huggingface-cli login` and paste your token
4. Token is stored at `~/.cache/huggingface/token`

## Model Size Estimation

Quick formula to estimate GGUF file size from parameter count and quantization:

```text
Size (GB) ≈ Parameters (B) × Bits per weight / 8

Examples:
  8B model at Q4_K_M (4.5 bits avg):  8 × 4.5 / 8 ≈ 4.5 GB
  8B model at Q6_K (6.5 bits avg):    8 × 6.5 / 8 ≈ 6.5 GB
  14B model at Q4_K_M:               14 × 4.5 / 8 ≈ 7.9 GB
  32B model at Q4_K_M:               32 × 4.5 / 8 ≈ 18 GB
  70B model at Q4_K_M:               70 × 4.5 / 8 ≈ 39 GB
```

Actual sizes vary slightly due to model architecture overhead, but this formula is accurate within ~10%.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Download interrupted | Re-run the same `huggingface-cli download` command — it resumes automatically |
| "Access denied" on gated model | Run `huggingface-cli login`, then accept the license on the model's HuggingFace page |
| Model too slow | Try a smaller quantization (Q4_K_M instead of Q6_K) or a smaller model |
| Model outputs gibberish | Verify the GGUF file is not corrupted (re-download), check you are using an instruct/chat variant |
| Can't find GGUF for a model | Search `bartowski/{model-name}-GGUF` — bartowski covers most popular models |
| "Not enough memory" | Use a smaller model or lower quantization. Check `local-model-helper.sh recommend` for hardware-appropriate suggestions |
| Slow download speed | HuggingFace CDN is generally fast. If slow, try `--resume-download` flag or check network. Large models (40+ GB) take time even on fast connections |

## See Also

- `tools/local-models/local-models.md` — llama.cpp runtime setup and server management
- `tools/context/model-routing.md` — Cost-aware routing (local is the free tier)
- `scripts/local-model-helper.sh` — CLI for model management (search, download, recommend, cleanup)
- `tools/infrastructure/cloud-gpu.md` — Cloud GPU deployment for models too large for local hardware
