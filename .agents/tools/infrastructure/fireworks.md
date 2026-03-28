---
description: "Fireworks AI — fast inference, dedicated GPU deployments, fine-tuning (SFT/DPO/RFT), custom model hosting for open-source models"
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

# Fireworks AI

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI**: `firectl` — `brew tap fw-ai/firectl && brew install firectl` or [manual install](https://docs.fireworks.ai/tools-sdks/firectl/firectl)
- **Auth**: `firectl signin` (browser OAuth) | `firectl set-api-key <key>` (headless) | `firectl whoami`
- **Creds**: `~/.fireworks/auth.ini` (firectl) | `FIREWORKS_API_KEY` env var (API)
- **API base**: `https://api.fireworks.ai/inference/v1` (OpenAI-compat) | `https://api.fireworks.ai/inference` (Anthropic-compat)
- **Docs**: [Getting started](https://docs.fireworks.ai/getting-started/introduction) | [API ref](https://docs.fireworks.ai/api-reference/introduction) | [firectl](https://docs.fireworks.ai/tools-sdks/firectl/firectl) | [Pricing](https://fireworks.ai/pricing)
- **Resource naming**: `accounts/{account_id}/models/{name}`, `accounts/{account_id}/deployments/{id}`

<!-- AI-CONTEXT-END -->

Fast inference and fine-tuning platform for open-source models. OpenAI/Anthropic SDK compatible. 100+ models serverless, or deploy on dedicated GPUs with autoscaling.

**Best for**: production inference (serverless or dedicated), custom model training (SFT/DPO/RFT), LoRA deployment, batch inference at scale.
**Not for**: closed-model hosting (Claude/GPT/Gemini), privacy-critical workloads requiring TEE (see `nearai.md`), static site hosting.

## Pricing (March 2026)

### Serverless (pay-per-token)

| Tier | $/1M tokens |
|------|-------------|
| <4B params | $0.10 |
| 4-16B params | $0.20 |
| >16B params | $0.90 |
| MoE 0-56B (Mixtral 8x7B) | $0.50 |
| MoE 56-176B (DBRX, 8x22B) | $1.20 |
| DeepSeek V3 family | $0.56 in / $1.68 out |
| Kimi K2 Instruct | $0.60 in / $2.50 out |
| GPT-OSS 120B | $0.15 in / $0.60 out |
| GPT-OSS 20B | $0.07 in / $0.30 out |
| GLM-5 | $1.00 in / $3.20 out |

Cached input: 50% of input price. Batch inference: 50% of serverless price.

### Dedicated GPUs (pay-per-second)

| GPU | $/hour |
|-----|--------|
| A100 80GB | $2.90 |
| H100 80GB | $6.00 |
| H200 141GB | $6.00 |
| B200 180GB | $9.00 |

### Fine-tuning (per 1M training tokens)

| Base model size | SFT | DPO |
|----------------|-----|-----|
| Up to 16B | $0.50 | $1.00 |
| 16-80B | $3.00 | $6.00 |
| 80-300B | $6.00 | $12.00 |
| >300B | $10.00 | $20.00 |

RFT: same as on-demand GPU rates. Embeddings: $0.008-$0.10/M tokens.

### Cost comparison

Fireworks serverless is competitive with direct API providers. Dedicated GPUs become cheaper than serverless at sustained high utilization. Batch inference (50% off) is the cheapest option for non-latency-sensitive workloads.

## Models

100+ models across text, vision, audio, image, and embeddings. Key architectures: DeepSeek V1-V3, Qwen family, Llama 1-4, Mistral/Mixtral, Gemma, Phi, GPT-OSS. Full catalog: https://fireworks.ai/models

## Serverless Inference

```bash
# curl
curl https://api.fireworks.ai/inference/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $FIREWORKS_API_KEY" \
  -d '{"model": "accounts/fireworks/models/deepseek-v3p1", "messages": [{"role": "user", "content": "Hello"}]}'

# OpenAI SDK (Python) — just change base_url
import os
from openai import OpenAI
client = OpenAI(api_key=os.environ["FIREWORKS_API_KEY"], base_url="https://api.fireworks.ai/inference/v1")
response = client.chat.completions.create(model="accounts/fireworks/models/deepseek-v3p1", messages=[...])
```

Features: streaming, function calling, structured outputs (JSON schema), reasoning, vision, speech-to-text, embeddings, reranking.

Rate limits: 10 RPM without payment method, up to 6,000 RPM with payment method. Serverless models may be deprecated with 2+ weeks notice.

## Dedicated Deployments

```bash
# Create deployment with shape (fast/throughput/cost)
firectl deployment create accounts/fireworks/models/gpt-oss-120b \
  --deployment-shape fast \
  --min-replica-count 0 --max-replica-count 4 \
  --scale-up-window 30s --scale-down-window 5m --scale-to-zero-window 5m \
  --wait

# Autoscale by RPS or concurrent requests
firectl deployment create accounts/fireworks/models/gpt-oss-120b \
  --deployment-shape fast --max-replica-count 4 \
  --load-targets requests_per_second=5 --wait

# Management
firectl deployment list
firectl deployment get <DEPLOYMENT_ID>
firectl deployment scale <DEPLOYMENT_ID> --replica-count 2
firectl deployment delete <DEPLOYMENT_ID>
firectl deployment undelete <DEPLOYMENT_ID>

# Query deployment (same API, different model string)
curl https://api.fireworks.ai/inference/v1/chat/completions \
  -H "Authorization: Bearer $FIREWORKS_API_KEY" \
  -d '{"model": "accounts/<ACCOUNT_ID>/deployments/<DEPLOYMENT_ID>", "messages": [...]}'
```

**Deployment shapes**: `fast` (low latency), `throughput` (high volume), `cost` (cheapest). List available: `firectl deployment-shape-version list --base-model <model-id>`.

**GPU types**: `--accelerator-type NVIDIA_A100_80GB|NVIDIA_H100_80GB|NVIDIA_H200_141GB`. Multi-GPU: `--accelerator-count 2`.

**Autoscaling**: min/max replicas, scale-up/down/to-zero windows, load targets. Deployments scale to zero after 1h idle by default; auto-deleted after 7 days of no traffic if min replicas = 0.

## Custom Models

```bash
# Upload from local files
firectl model create <MODEL_ID> /path/to/files/

# Upload from S3 (use env vars or IAM role -- never pass credentials as CLI flags)
# Option A: environment variables (preferred)
export AWS_ACCESS_KEY_ID="<KEY>"
export AWS_SECRET_ACCESS_KEY="<SECRET>"
firectl model create <MODEL_ID> s3://<BUCKET>/<PATH>/
# Option B: IAM role/profile (recommended for EC2/ECS -- no credentials needed)
AWS_PROFILE=<PROFILE> firectl model create <MODEL_ID> s3://<BUCKET>/<PATH>/

# Upload LoRA adapter
firectl model create <MODEL_ID> /path/to/adapter/ \
  --base-model "accounts/fireworks/models/<BASE_MODEL_ID>"

# Verify upload
firectl model get accounts/<ACCOUNT_ID>/models/<MODEL_NAME>  # State: READY

# Deploy custom model
firectl deployment create accounts/<ACCOUNT_ID>/models/<MODEL_NAME> --wait

# Publish/unpublish
firectl model update <MODEL_ID> --public
firectl model update <MODEL_ID> --public=false

# Model management
firectl model list
firectl model get <MODEL_ID>
firectl model delete <MODEL_ID>
firectl model prepare <MODEL_ID>  # prepare for different precisions
```

Supported architectures: DeepSeek V1-V3, Qwen/Qwen2/Qwen2.5/Qwen3, Llama 1-4, Mistral/Mixtral, Gemma, Phi, GPT-OSS, and more. Required files: `config.json`, weights (`.safetensors`/`.bin`), tokenizer files.

LoRA adapters: rank 4-64, target modules `q_proj`, `k_proj`, `v_proj`, `o_proj`, `up_proj`, `down_proj`, `gate_proj`. Customize defaults via `fireworks.json`.

## Fine-Tuning

### Supervised Fine-Tuning (SFT)

```bash
# Upload dataset
firectl dataset create <DATASET_ID> /path/to/data.jsonl

# Launch SFT job
firectl supervised-fine-tuning-job create \
  --model accounts/fireworks/models/<BASE_MODEL> \
  --dataset accounts/<ACCOUNT_ID>/datasets/<DATASET_ID>

# Monitor
firectl supervised-fine-tuning-job get <JOB_ID>
firectl supervised-fine-tuning-job list

# Cancel/delete
firectl supervised-fine-tuning-job cancel <JOB_ID>
firectl supervised-fine-tuning-job delete <JOB_ID>
```

### Direct Preference Optimization (DPO)

```bash
firectl dpo-job create --model <MODEL> --dataset <DATASET_ID>
firectl dpo-job get <JOB_ID>
firectl dpo-job list
firectl dpo-job cancel <JOB_ID>
firectl dpo-job resume <JOB_ID>
```

### Reinforcement Fine-Tuning (RFT)

```bash
firectl reinforcement-fine-tuning-job create --model <MODEL> --evaluator <EVALUATOR_ID>
firectl reinforcement-fine-tuning-job get <JOB_ID>
firectl reinforcement-fine-tuning-job list
firectl reinforcement-fine-tuning-job resume <JOB_ID>
```

RFT uses evaluator/reward functions to iteratively improve model outputs. Best for: small datasets (<1000 examples), no ground-truth labels, multi-step reasoning tasks.

### Training SDK

For custom training loops with full Python control over objectives. Install: `pip install --pre fireworks-ai`. Supports custom loss functions, full-parameter tuning, inference-in-the-loop evaluation, per-step control.

### When to use which

- **SFT**: 1000+ labeled examples, straightforward tasks (classification, extraction)
- **DPO**: Preference data (chosen/rejected pairs), alignment tuning
- **RFT**: <1000 examples, no ground truth, verifiable tasks, multi-step reasoning
- **Training SDK**: Custom loss functions, full-parameter tuning, research

## Batch Inference

```bash
firectl batch-inference-job create --model <MODEL> --input-file /path/to/input.jsonl
firectl batch-inference-job get <JOB_ID>
firectl batch-inference-job list
firectl batch-inference-job delete <JOB_ID>
```

50% cheaper than serverless. Async processing for non-latency-sensitive workloads.

## Datasets

```bash
firectl dataset create <DATASET_ID> /path/to/data.jsonl
firectl dataset get <DATASET_ID>
firectl dataset list
firectl dataset download <DATASET_ID> /local/path/
firectl dataset update <DATASET_ID> --display-name "New Name"
firectl dataset delete <DATASET_ID>
```

## Account Management

```bash
firectl whoami
firectl account get
firectl account list
firectl api-key create
firectl api-key list
firectl api-key delete <KEY_ID>
firectl billing export-metrics
firectl billing list-invoices
firectl user list
firectl user create --email <EMAIL>
firectl secret create --name <NAME> --value <VALUE>
firectl secret list
firectl quota list
firectl quota get <QUOTA_ID>
```

## Security

- Store API key: `aidevops secret set FIREWORKS_API_KEY`
- Never expose keys in logs or output
- firectl stores auth at `~/.fireworks/auth.ini` — ensure 600 permissions
- Use service accounts for CI/CD: `firectl user create` + `firectl api-key create`
- Secrets management: `firectl secret create` for values used in evaluators/training

## See Also

- `tools/infrastructure/cloud-gpu.md` — raw GPU providers (RunPod, Vast.ai, Lambda)
- `tools/infrastructure/nearai.md` — TEE-backed private inference
- `tools/local-models/local-models.md` — local model serving
- `tools/deployment/hosting-comparison.md` — app hosting platforms
