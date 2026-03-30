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
- **See also**: `tools/local-models/local-models.md` (runtime), `tools/context/model-routing.md` (routing), `scripts/local-model-helper.sh`, `tools/infrastructure/cloud-gpu.md` (cloud GPU)

<!-- AI-CONTEXT-END -->

## GGUF Format

Single file: weights + tokenizer + metadata. Compatible with llama.cpp, Ollama, LM Studio, Jan.ai, GPT4All, kobold.cpp. Replaced GGML in 2023. Naming: `{model}-{size}-{quantization}.gguf` (e.g., `qwen3-8b-q4_k_m.gguf`).

## Quantization

| Quant | Bits | Size vs FP16 | Quality Loss | Use When |
|-------|------|-------------|-------------|----------|
| Q4_K_M | 4 | ~25% | Minimal | **Default** — best size/quality balance |
| Q5_K_M | 5 | ~33% | Very small | RAM headroom, want better quality |
| Q6_K | 6 | ~50% | Negligible | Near-lossless, important tasks |
| Q8_0 | 8 | ~66% | None | Maximum quality |
| IQ4_XS | 4 | ~22% | Small | Minimum size, still usable |
| IQ3_XXS | 3 | ~17% | Moderate | Extreme compression |
| FP16 | 16 | 100% | None | Full precision |

**Decision**: RAM tight → Q4_K_M (or IQ4_XS). RAM available → Q5_K_M or Q6_K. Q4_K_M is right for almost everyone. K_S variants exist (~1% smaller than K_M, marginal difference).

**Size estimate**: `Parameters (B) × Bits / 8 ≈ GB` — e.g., 8B at Q4_K_M (4.5 bits avg) ≈ 4.5 GB (±10%).

## Hardware-Tier Recommendations

Reserve ≥4 GB for OS. Sizes approximate.

| RAM | Example Hardware | Budget | Recommended |
|-----|-----------------|--------|-------------|
| 8 GB | MacBook Air M2, GTX 1070 | ≤4 GB | Qwen3-4B Q4_K_M (~2.5 GB), Phi-4-mini Q4_K_M (~2.3 GB), nomic-embed-text-v1.5 FP16 (~0.3 GB) |
| 16 GB | MacBook Pro M3, RTX 3060 12GB | ≤10 GB | Qwen3-8B Q4_K_M (~5 GB), DeepSeek-R1-Distill-Qwen-7B Q4_K_M (~4.5 GB), Llama-3.1-8B Q4_K_M (~4.7 GB) |
| 32 GB | MacBook Pro M3 Pro 36GB, RTX 4090 | ≤20 GB | Qwen3-14B Q4_K_M (~8.5 GB), Qwen3-14B Q5_K_M (~10.5 GB), DeepSeek-R1-Distill-Qwen-14B Q4_K_M (~8.5 GB) |
| 64 GB | MacBook Pro M3 Max, dual RTX 4090 | ≤45 GB | Qwen3-32B Q4_K_M (~19 GB), Qwen3-32B Q5_K_M (~24 GB), DeepSeek-R1-Distill-Qwen-32B Q4_K_M (~19 GB) |
| 128 GB+ | Mac Studio M2 Ultra, multi-GPU | 70B+ | Qwen3-72B Q4_K_M (~42 GB), DeepSeek-R1-70B Q4_K_M (~40 GB), Llama-3.1-70B Q4_K_M (~40 GB) |

Higher-quant options per tier: 32 GB → 8B at Q6_K (~6.2–6.6 GB); 64 GB → 14B at Q8_0 (~15 GB); 128 GB+ → 32B at Q8_0 (~34 GB).

## Model Families

| Family | Sizes | Strengths | HuggingFace Repos |
|--------|-------|-----------|-------------------|
| **Qwen3** (Alibaba) | 4B–72B | Best all-round 2026: code, multilingual, reasoning. CoT via system prompt. | `Qwen/Qwen3-{size}-GGUF`, `bartowski/Qwen3-{size}-GGUF` |
| **Llama 3/3.1** (Meta) | 3B–70B | Strong general-purpose. Gated — requires HF token. | `meta-llama/Llama-3.1-{size}-Instruct-GGUF`, `bartowski/...` |
| **DeepSeek R1** | 7B–70B | Built-in chain-of-thought. Strong reasoning and code. | `deepseek-ai/DeepSeek-R1-Distill-Qwen-{size}-GGUF`, `bartowski/...` |
| **Mistral/Mixtral** | 7B–46B | Efficient instruction following. Mixtral-8x7B is MoE (12B active). | `mistralai/Mistral-{size}-Instruct-v0.3-GGUF`, `bartowski/...` |
| **Gemma 3** (Google) | 4B–27B | Instruction following, multilingual, structured output. | `google/gemma-3-{size}-it-GGUF`, `bartowski/...` |
| **Phi 4** (Microsoft) | 3.8B–14B | Capable for size, good reasoning in constrained environments. | `microsoft/phi-4-gguf`, `bartowski/phi-4-GGUF` |

## Trusted GGUF Publishers

- **bartowski** — most comprehensive, multiple quants per model, first choice for community quants
- **lmstudio-community** — high-quality, llama.cpp compatible
- **ggml-org** — official llama.cpp project quants, reference quality
- **unsloth** — well-tested GGUF exports
- **Official authors** (`Qwen`, `meta-llama`, `google`, `mistralai`, `deepseek-ai`, `microsoft`) — prefer when available

**Avoid**: few downloads, no README/metadata, unclear quantization labels.

## Searching, Downloading, and Setup

```bash
# Helper (recommended)
local-model-helper.sh search "qwen3 8b"
local-model-helper.sh search "llama 3.1" --max-size 10G

# Direct download
huggingface-cli download Qwen/Qwen3-8B-GGUF qwen3-8b-q4_k_m.gguf \
  --local-dir ~/.aidevops/local-models/models/

# Gated models (Llama, etc.) — login first
huggingface-cli login
huggingface-cli download meta-llama/Llama-3.1-8B-Instruct-GGUF \
  llama-3.1-8b-instruct-q4_k_m.gguf --local-dir ~/.aidevops/local-models/models/

# Install CLI: pip install huggingface_hub[cli]  (or pipx)
# Web browse: https://huggingface.co/models?library=gguf&sort=trending
```

`local-model-helper.sh setup` installs automatically. Token: `~/.cache/huggingface/token`. Accept model license on HuggingFace before downloading gated models.

**Repo patterns**: `bartowski/{Model}-GGUF`, `Qwen/Qwen3-{size}-GGUF`, `meta-llama/Llama-3.1-{size}-Instruct-GGUF`

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Download interrupted | Re-run same command — resumes automatically |
| "Access denied" | `huggingface-cli login` + accept license on HF page |
| Model too slow | Lower quantization or smaller model |
| Gibberish output | Re-download (corruption), use instruct/chat variant |
| Can't find GGUF | Search `bartowski/{model-name}-GGUF` |
| "Not enough memory" | Smaller model or lower quant; `local-model-helper.sh recommend` |
