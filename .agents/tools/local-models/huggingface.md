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
- **CLI**: `huggingface-cli download <repo> <file> --local-dir <path>` (resume-capable)
- **Format**: GGUF — single-file, self-contained, llama.cpp native
- **Helper**: `local-model-helper.sh search|download|models|recommend`
- **Trusted publishers**: bartowski, lmstudio-community, ggml-org, unsloth, Qwen, meta-llama, deepseek-ai, mistralai, google
- **See also**: `tools/local-models/local-models.md` (runtime), `tools/context/model-routing.md` (routing)

<!-- AI-CONTEXT-END -->

## GGUF Format

Single file containing weights, tokenizer, and metadata. No separate config directories. Compatible with llama.cpp, Ollama, LM Studio, Jan.ai, GPT4All, kobold.cpp. Replaced GGML in 2023.

**Naming**: `{model}-{size}-{quantization}.gguf` — e.g., `qwen3-8b-q4_k_m.gguf`

## Quantization

| Quantization | Bits | Size vs FP16 | Quality Loss | Use When |
|-------------|------|-------------|-------------|----------|
| Q4_K_M | 4-bit | ~25% | Minimal | **Default** — best size/quality balance |
| Q4_K_S | 4-bit | ~24% | Small | Slightly smaller than Q4_K_M |
| Q5_K_M | 5-bit | ~33% | Very small | Have RAM headroom, want better quality |
| Q5_K_S | 5-bit | ~32% | Small | Slightly smaller than Q5_K_M |
| Q6_K | 6-bit | ~50% | Negligible | Near-lossless, important tasks |
| Q8_0 | 8-bit | ~66% | None | Maximum quality |
| IQ4_XS | 4-bit | ~22% | Small | Minimum size, still usable |
| IQ3_XXS | 3-bit | ~17% | Moderate | Extreme compression |
| FP16 | 16-bit | 100% | None | Full precision |

**Decision**: RAM tight → Q4_K_M (or IQ4_XS). RAM available + quality matters → Q5_K_M or Q6_K. Q4_K_M is right for almost everyone.

**Size estimate**: `Parameters (B) × Bits / 8 ≈ GB` — e.g., 8B at Q4_K_M (4.5 bits avg) ≈ 4.5 GB. Accurate within ~10%.

## Hardware-Tier Recommendations

Reserve ≥4 GB for OS. Sizes are approximate.

### 8 GB (MacBook Air M2 8GB, GTX 1070) — up to ~4 GB models

| Use Case | Model | Quant | Size |
|----------|-------|-------|------|
| General / Code | Qwen3-4B | Q4_K_M | ~2.5 GB |
| Summarization | Phi-4-mini | Q4_K_M | ~2.3 GB |
| Embeddings | nomic-embed-text-v1.5 | FP16 | ~0.3 GB |

### 16 GB (MacBook Pro M3 16GB, RTX 3060 12GB) — up to ~10 GB models

| Use Case | Model | Quant | Size |
|----------|-------|-------|------|
| General / Code / Translation | Qwen3-8B | Q4_K_M | ~5 GB |
| Reasoning | DeepSeek-R1-Distill-Qwen-7B | Q4_K_M | ~4.5 GB |
| Summarization | Llama-3.1-8B | Q4_K_M | ~4.7 GB |

### 32 GB (MacBook Pro M3 Pro 36GB, RTX 4090 24GB) — up to ~20 GB models

| Use Case | Model | Quant | Size |
|----------|-------|-------|------|
| General chat | Qwen3-14B | Q4_K_M | ~8.5 GB |
| Code | Qwen3-14B | Q5_K_M | ~10.5 GB |
| Reasoning | DeepSeek-R1-Distill-Qwen-14B | Q4_K_M | ~8.5 GB |
| High-quality 8B | Llama-3.1-8B / Qwen3-8B | Q6_K | ~6.2–6.6 GB |

### 64 GB (MacBook Pro M3 Max 64GB, dual RTX 4090) — up to ~45 GB models

| Use Case | Model | Quant | Size |
|----------|-------|-------|------|
| General / Code / Multilingual | Qwen3-32B | Q4_K_M | ~19 GB |
| Code (high quality) | Qwen3-32B | Q5_K_M | ~24 GB |
| Reasoning | DeepSeek-R1-Distill-Qwen-32B | Q4_K_M | ~19 GB |
| High-quality 14B | Qwen3-14B | Q8_0 | ~15 GB |

### 128 GB+ (Mac Studio M2 Ultra, multi-GPU) — 70B+ at Q4_K_M

| Use Case | Model | Quant | Size |
|----------|-------|-------|------|
| General / Code | Qwen3-72B | Q4_K_M | ~42 GB |
| Reasoning | DeepSeek-R1-70B | Q4_K_M | ~40 GB |
| Research | Llama-3.1-70B | Q4_K_M | ~40 GB |
| High-quality 32B | Qwen3-32B | Q8_0 | ~34 GB |

## Model Families

| Family | Sizes | Strengths | HuggingFace Repos |
|--------|-------|-----------|-------------------|
| **Qwen3** (Alibaba) | 4B–72B | Best all-round 2026: code, multilingual, reasoning. Thinking mode (CoT) via system prompt. | `Qwen/Qwen3-{size}-GGUF`, `bartowski/Qwen3-{size}-GGUF` |
| **Llama 3/3.1** (Meta) | 3B–70B | Strong general-purpose, well-tested. Gated — requires HF token. | `meta-llama/Llama-3.1-{size}-Instruct-GGUF`, `bartowski/Llama-3.1-{size}-Instruct-GGUF` |
| **DeepSeek R1** | 7B–70B | Built-in chain-of-thought. Strong reasoning and code. | `deepseek-ai/DeepSeek-R1-Distill-Qwen-{size}-GGUF`, `bartowski/...` |
| **Mistral/Mixtral** | 7B–46B | Efficient, good instruction following. Mixtral-8x7B is MoE (12B active). | `mistralai/Mistral-{size}-Instruct-v0.3-GGUF`, `bartowski/...` |
| **Gemma 3** (Google) | 4B–27B | Instruction following, multilingual, structured output. | `google/gemma-3-{size}-it-GGUF`, `bartowski/gemma-3-{size}-it-GGUF` |
| **Phi 4** (Microsoft) | 3.8B–14B | Capable for size, good reasoning in constrained environments. | `microsoft/phi-4-gguf`, `bartowski/phi-4-GGUF` |

## Trusted GGUF Publishers

| Publisher | Handle | Notes |
|-----------|--------|-------|
| bartowski | `bartowski` | Most comprehensive. Multiple quants per model. First choice for community quants. |
| LM Studio Community | `lmstudio-community` | High-quality, works with llama.cpp. |
| GGML.org | `ggml-org` | Official llama.cpp project quants. Reference quality. |
| Unsloth | `unsloth` | Well-tested GGUF exports. |
| Official authors | `Qwen`, `meta-llama`, `google`, `mistralai`, `deepseek-ai`, `microsoft` | Prefer when available. |

**Avoid**: Few downloads, no README/metadata, unclear quantization labels.

## Searching and Downloading

```bash
# Helper (recommended)
local-model-helper.sh search "qwen3 8b"
local-model-helper.sh search "llama 3.1" --max-size 10G
local-model-helper.sh models

# huggingface-cli
huggingface-cli download Qwen/Qwen3-8B-GGUF qwen3-8b-q4_k_m.gguf \
  --local-dir ~/.aidevops/local-models/models/

# Gated model (requires login)
huggingface-cli login
huggingface-cli download meta-llama/Llama-3.1-8B-Instruct-GGUF \
  llama-3.1-8b-instruct-q4_k_m.gguf \
  --local-dir ~/.aidevops/local-models/models/

# Web: https://huggingface.co/models?library=gguf&sort=trending
```

**Repo patterns**: `bartowski/{Model}-GGUF`, `Qwen/Qwen3-{size}-GGUF`, `meta-llama/Llama-3.1-{size}-Instruct-GGUF`

## Installation and Auth

```bash
pip install huggingface_hub[cli]   # or: pipx install huggingface_hub[cli]
huggingface-cli version
huggingface-cli login              # required for gated models (Llama, etc.)
```

`local-model-helper.sh setup` installs automatically. Token stored at `~/.cache/huggingface/token`. Accept model license on HuggingFace before downloading gated models.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Download interrupted | Re-run same command — resumes automatically |
| "Access denied" | `huggingface-cli login` + accept license on HF page |
| Model too slow | Lower quantization or smaller model |
| Gibberish output | Re-download (corruption check), use instruct/chat variant |
| Can't find GGUF | Search `bartowski/{model-name}-GGUF` |
| "Not enough memory" | Smaller model or lower quant; `local-model-helper.sh recommend` |

## See Also

- `tools/local-models/local-models.md` — llama.cpp runtime setup
- `tools/context/model-routing.md` — cost-aware routing (local = free tier)
- `scripts/local-model-helper.sh` — search, download, recommend, cleanup
- `tools/infrastructure/cloud-gpu.md` — cloud GPU for oversized models
