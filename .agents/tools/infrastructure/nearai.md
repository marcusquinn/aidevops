---
description: "NEAR AI Cloud — TEE-backed private inference, cryptographic verification, OpenAI-compatible API for privacy-sensitive workloads"
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
  webfetch: true
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# NEAR AI Cloud

<!-- AI-CONTEXT-START -->

## Quick Reference

- **API base**: `https://cloud-api.near.ai/v1` (gateway, OpenAI-compat) | `https://{slug}.completions.near.ai/v1` (direct to TEE)
- **Auth**: API key from [cloud.near.ai/dashboard/keys](https://cloud.near.ai/dashboard/keys)
- **Creds**: `NEARAI_API_KEY` env var | `Authorization: Bearer <key>` header
- **Docs**: [Quickstart](https://docs.near.ai/cloud/quickstart) | [Models](https://docs.near.ai/cloud/models/overview) | [API ref](https://cloud-api.near.ai/docs) | [Private inference](https://docs.near.ai/cloud/private-inference)
- **Dashboard**: [cloud.near.ai](https://cloud.near.ai)
- **Status**: Beta (as of March 2026)

<!-- AI-CONTEXT-END -->

TEE-backed private inference platform. All requests execute inside hardware-enforced Trusted Execution Environments with cryptographic attestation. OpenAI SDK compatible — change `base_url` only.

**Best for**: privacy-sensitive workloads (regulated data, PII, healthcare, government), verifiable inference (cryptographic proof of integrity), applications requiring data sovereignty guarantees.
**Not for**: fine-tuning, custom model uploads, dedicated deployments, batch inference, embeddings, image generation at scale (see `fireworks.md`).

## Pricing (March 2026)

| Model | Context | $/M input | $/M output |
|-------|---------|-----------|------------|
| Claude Opus 4.6 * | 200K | $5.00 | $25.00 |
| Claude Sonnet 4.5 * | 200K | $3.00 | $15.50 |
| Gemini 3 Pro Preview * | 1000K | $1.25 | $15.00 |
| OpenAI GPT-5.2 * | 400K | $1.80 | $15.50 |
| DeepSeek V3.1 | 128K | $1.05 | $3.10 |
| GPT OSS 120B | 131K | $0.15 | $0.55 |
| Qwen3 30B A3B | 262K | $0.15 | $0.55 |
| Qwen3.5 122B A10B | 131K | $0.40 | $3.20 |
| GLM 5 | 203K | $0.85 | $3.30 |
| FLUX.2-klein-4B (image) | 128K | $1.00 | $1.00 |

\* Anonymized proxy to original providers — not full TEE isolation. Open-source models (DeepSeek, GPT-OSS, Qwen, GLM) run in actual TEEs.

### Price comparison vs Fireworks (same open-source models)

| Model | Fireworks (in/out) | NEAR AI (in/out) | Notes |
|-------|-------------------|-------------------|-------|
| GPT-OSS 120B | $0.15 / $0.60 | $0.15 / $0.55 | ~same |
| DeepSeek V3 | $0.56 / $1.68 | $1.05 / $3.10 | NEAR ~1.9x more (TEE premium) |
| Qwen3 30B A3B | $0.15 / $0.60 | $0.15 / $0.55 | ~same |
| GLM-5 | $1.00 / $3.20 | $0.85 / $3.30 | ~same |

For non-privacy-sensitive workloads, Fireworks is cheaper and has more features.

NEAR AI also offers Claude, GPT-5.2, and Gemini via anonymized proxy — frontier model quality with identity stripped, not available on Fireworks.

## Usage

### Gateway (recommended)

```bash
curl https://cloud-api.near.ai/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $NEARAI_API_KEY" \
  -d '{"model": "deepseek-ai/DeepSeek-V3.1", "messages": [{"role": "user", "content": "Hello"}]}'
```

```python
import os
import openai
client = openai.OpenAI(base_url="https://cloud-api.near.ai/v1", api_key=os.environ["NEARAI_API_KEY"])
response = client.chat.completions.create(
    model="deepseek-ai/DeepSeek-V3.1",
    messages=[{"role": "user", "content": "Hello, NEAR AI!"}]
)
```

### Direct completions (TLS terminates inside TEE)

No gateway hop — TLS terminates directly in the model enclave.

```bash
curl https://qwen35-122b.completions.near.ai/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $NEARAI_API_KEY" \
  -d '{"model": "Qwen/Qwen3.5-122B-A10B", "messages": [{"role": "user", "content": "Hello"}]}'
```

Available direct endpoints: `qwen35-122b.completions.near.ai`, `qwen3-30b.completions.near.ai`, `gpt-oss-120b.completions.near.ai`, and more. Full list: https://completions.near.ai/endpoints

### Model IDs

Use HuggingFace-style IDs: `deepseek-ai/DeepSeek-V3.1`, `openai/gpt-oss-120b`, `Qwen/Qwen3-30B-A3B-Instruct-2507`, `Qwen/Qwen3.5-122B-A10B`, `zai-org/GLM-5-FP8`, `anthropic/claude-opus-4-6`, `openai/gpt-5.2`, `google/gemini-3-pro`.

## Privacy Architecture

- **TEE isolation**: Open-source models run inside Intel TDX / AMD SEV-SNP enclaves — model providers, cloud providers, and NEAR AI cannot access prompts or responses
- **Cryptographic attestation**: Every inference generates verifiable proof of integrity. Clients can verify: [verification docs](https://docs.near.ai/cloud/verification)
- **TLS in enclave**: Direct completions endpoints terminate TLS inside the TEE — no intermediate can intercept
- **E2EE chat**: End-to-end encrypted chat completions available: [guide](https://docs.near.ai/cloud/guides/e2ee-chat-completions)
- **Anonymized models** (Claude, GPT-5.2, Gemini): Identity stripped, but upstream provider still processes full request content — weaker guarantee than TEE

## When to Use NEAR AI vs Fireworks

| Requirement | Use |
|-------------|-----|
| Privacy-critical inference (PII, healthcare, legal) | NEAR AI |
| Regulatory compliance requiring TEE attestation | NEAR AI |
| Anonymized access to Claude/GPT-5.2/Gemini | NEAR AI |
| Fine-tuning custom models | Fireworks |
| Dedicated GPU deployments with autoscaling | Fireworks |
| Batch inference at scale | Fireworks |
| Custom model uploads from HuggingFace | Fireworks |
| Lowest cost for non-sensitive workloads | Fireworks |
| LoRA adapter deployment | Fireworks |
| Embeddings, reranking, speech-to-text | Fireworks |

## Security

- Store API key: `aidevops secret set NEARAI_API_KEY`
- For maximum privacy, use direct completions endpoints (TLS terminates in TEE)
- Verify attestation reports for high-security workloads
- Credits are prepaid — purchase at [cloud.near.ai](https://cloud.near.ai) dashboard

## See Also

- `tools/infrastructure/fireworks.md` — inference + fine-tuning + custom model hosting
- `tools/infrastructure/cloud-gpu.md` — raw GPU providers (RunPod, Vast.ai, Lambda)
- `tools/local-models/local-models.md` — local model serving
