---
description: "Cloud GPU deployment guide for AI model hosting - provider comparison, SSH setup, Docker deployment, model caching, cost optimization"
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

# Cloud GPU Deployment

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Deploy GPU-intensive AI models (voice, vision, LLMs) to cloud providers
- **Providers**: NVIDIA Cloud, Vast.ai, RunPod, Lambda
- **Pattern**: SSH into instance, Docker deploy, expose API, connect from local machine
- **Cost range**: $0.20/hr (consumer GPUs) to $4.30/hr (H200 SXM)

**When to Use**: Read this when deploying any AI model that requires GPU acceleration and local hardware is insufficient. Referenced by `tools/voice/speech-to-speech.md` and future `tools/vision/` subagents.

<!-- AI-CONTEXT-END -->

## Provider Comparison

| Provider | GPU Options | Pricing | Best For | Signup |
|----------|-----------|---------|----------|--------|
| [RunPod](https://www.runpod.io/) | H200, H100, A100, L40S, RTX 4090/5090 | Per-second billing, $0.40-4.31/hr | General purpose, serverless inference | [runpod.io](https://www.runpod.io/) |
| [Vast.ai](https://vast.ai/) | Consumer + datacenter GPUs, 10,000+ available | Auction + fixed pricing, 5-6x cheaper than hyperscalers | Budget workloads, experimentation | [vast.ai](https://vast.ai/) |
| [Lambda](https://lambdalabs.com/) | GB300 NVL72, B200, H200, H100 | Per-hour, reserved discounts | Research, large-scale training, enterprise | [lambdalabs.com](https://lambdalabs.com/) |
| [NVIDIA Cloud](https://www.nvidia.com/en-us/gpu-cloud/) | A100, H100 (via DGX Cloud) | Per-hour, enterprise contracts | Official NVIDIA stack, production workloads | [nvidia.com/gpu-cloud](https://www.nvidia.com/en-us/gpu-cloud/) |

### Choosing a Provider

```text
Need cheapest possible?           → Vast.ai (auction pricing)
Need reliability + good pricing?  → RunPod (per-second billing, 30+ regions)
Need enterprise / compliance?     → Lambda (SOC 2, single-tenant) or NVIDIA Cloud
Need serverless inference?        → RunPod Serverless
Need multi-GPU clusters?          → Lambda 1-Click Clusters or RunPod Instant Clusters
```

## GPU Selection Guide

Match GPU to workload requirements:

| GPU | VRAM | Use Case | Approx. Cost/hr |
|-----|------|----------|-----------------|
| RTX 3090/4090 | 24GB | Small models, fine-tuning, inference | $0.20-0.70 |
| L4 | 24GB | Inference, cost-effective | $0.40-0.60 |
| L40S | 48GB | Medium models, inference | $0.85-1.22 |
| A100 (80GB) | 80GB | Large models, training + inference | $1.79-2.72 |
| H100 (80GB) | 80GB | High throughput, large-scale training | $2.50-4.18 |
| H200 (141GB) | 141GB | Largest models, maximum throughput | $3.35-5.58 |

### VRAM Requirements by Model Type

| Model Category | Example Models | Min VRAM | Recommended GPU |
|---------------|---------------|----------|-----------------|
| Voice pipeline (STT+TTS) | Whisper + Parler-TTS | 4GB | RTX 3090/4090 |
| Voice pipeline (full S2S) | Whisper + LLM + TTS | 8-16GB | RTX 4090 / L4 |
| 7-8B parameter LLM | Llama 3.1 8B, Phi-3 | 8-16GB | RTX 4090 / L4 |
| 13B parameter LLM | Llama 2 13B | 16-24GB | RTX 4090 / L40S |
| 70B parameter LLM | Llama 3.1 70B | 40-80GB | A100 / H100 |
| Vision models | MiniCPM-o, LLaVA | 8-24GB | RTX 4090 / L40S |
| Diffusion models | Stable Diffusion XL | 8-16GB | RTX 4090 |

## Deployment Workflow

### 1. Provision Instance

All providers follow a similar pattern:

```bash
# RunPod: Create pod via CLI or web console
# Vast.ai: Search and rent via CLI or web console
# Lambda: Launch instance from dashboard
# NVIDIA Cloud: Provision via DGX Cloud portal
```

Select:

- **GPU type** matching your VRAM needs (see table above)
- **Docker image** (most providers support custom images)
- **Storage** for model weights (50-200GB typical)
- **Region** closest to your users

### 2. SSH Setup

```bash
# Generate SSH key if needed
ssh-keygen -t ed25519 -C "gpu-instance"

# Add public key to provider dashboard
# Then connect:
ssh -i ~/.ssh/id_ed25519 root@<instance-ip> -p <port>

# For RunPod (uses custom ports):
ssh root@<pod-ip> -p 22001 -i ~/.ssh/id_ed25519

# For Vast.ai (uses custom ports):
ssh -p <port> root@<host> -i ~/.ssh/id_ed25519
```

Store SSH credentials securely:

```bash
aidevops secret set GPU_SSH_KEY_PATH
aidevops secret set GPU_INSTANCE_IP
```

### 3. Docker Deployment

Most GPU workloads deploy via Docker with NVIDIA runtime:

```bash
# Pull base image with CUDA support
docker pull pytorch/pytorch:2.4.0-cuda12.1-cudnn9-devel

# Run with GPU access
docker run --gpus all -d \
  -p 8000:8000 \
  -v /models:/models \
  --name my-model \
  my-model-image:latest

# Or with docker compose
docker compose up -d
```

Example `docker-compose.yml` for GPU workloads:

```yaml
services:
  model:
    image: pytorch/pytorch:2.4.0-cuda12.1-cudnn9-devel
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    ports:
      - "8000:8000"
    volumes:
      - ./models:/models
      - model-cache:/root/.cache/huggingface
    environment:
      - CUDA_VISIBLE_DEVICES=0

volumes:
  model-cache:
```

### 4. Model Caching

Model downloads are slow and expensive on metered storage. Cache aggressively:

```bash
# Set HuggingFace cache to persistent volume
export HF_HOME=/models/huggingface
export TRANSFORMERS_CACHE=/models/huggingface/hub

# Pre-download models before serving
python -c "
from transformers import AutoModelForCausalLM, AutoTokenizer
model_name = 'microsoft/Phi-3-mini-4k-instruct'
AutoTokenizer.from_pretrained(model_name, cache_dir='/models/huggingface/hub')
AutoModelForCausalLM.from_pretrained(model_name, cache_dir='/models/huggingface/hub')
"

# For RunPod: Use network volumes (persist across pod restarts)
# For Vast.ai: Use persistent disk (survives stop/start)
# For Lambda: Use persistent storage attached to instance
```

### 5. Expose API

Serve models via HTTP for remote access:

```bash
# Option 1: vLLM (recommended for LLM inference)
python -m vllm.entrypoints.openai.api_server \
  --model microsoft/Phi-3-mini-4k-instruct \
  --host 0.0.0.0 --port 8000

# Option 2: Text Generation Inference (TGI)
docker run --gpus all -p 8000:80 \
  -v /models:/data \
  ghcr.io/huggingface/text-generation-inference:latest \
  --model-id microsoft/Phi-3-mini-4k-instruct

# Option 3: Custom FastAPI server
uvicorn serve:app --host 0.0.0.0 --port 8000
```

### 6. Connect from Local Machine

```bash
# Direct API call
curl http://<instance-ip>:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "microsoft/Phi-3-mini-4k-instruct", "prompt": "Hello", "max_tokens": 100}'

# SSH tunnel for secure access
ssh -L 8000:localhost:8000 root@<instance-ip> -p <port>
# Then access at http://localhost:8000

# For speech-to-speech server/client pattern:
# On GPU server:
speech-to-speech-helper.sh start --server
# On local machine:
speech-to-speech-helper.sh client --host <instance-ip>
```

## Cost Optimization

### Strategies

| Strategy | Savings | Trade-off |
|----------|---------|-----------|
| Spot/interruptible instances | 50-80% | Can be terminated mid-job |
| Off-peak hours | 10-30% | Scheduling constraints |
| Smaller GPU + quantization | 40-60% | Slight quality loss |
| Serverless (RunPod) | Pay only for requests | Cold start latency |
| Reserved instances (Lambda) | 20-30% | Commitment required |
| Vast.ai auction pricing | 50-70% vs. fixed | Variable availability |

### Quantization to Reduce GPU Requirements

Quantized models use less VRAM, enabling cheaper GPUs:

```bash
# 4-bit quantization (GPTQ/AWQ) reduces VRAM by ~75%
# Example: Llama 3.1 70B
#   FP16: ~140GB VRAM (needs 2x A100)
#   4-bit: ~35GB VRAM (fits on 1x A100 or L40S)

# Use pre-quantized models from HuggingFace
# Search for: TheBloke/<model>-GPTQ or <model>-AWQ
```

### Auto-Shutdown

Avoid paying for idle instances:

```bash
# Simple idle shutdown (add to crontab)
# Shuts down if no GPU activity for 30 minutes
*/5 * * * * nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader | \
  awk '{if ($1+0 < 5) system("echo idle >> /tmp/gpu_idle"); else system("rm -f /tmp/gpu_idle")}' && \
  [ "$(wc -l < /tmp/gpu_idle 2>/dev/null)" -gt 6 ] && shutdown -h now

# RunPod: Set auto-stop in pod settings
# Vast.ai: Set max idle time when renting
# Lambda: Use API to terminate programmatically
```

## Provider-Specific Notes

### RunPod

- Per-second billing (no minimum commitment)
- Community Cloud (cheaper, shared) vs. Secure Cloud (dedicated)
- Serverless option for inference (auto-scaling, pay-per-request)
- Network volumes persist across pod restarts
- 30+ global regions
- SOC 2 Type II compliant

### Vast.ai

- Marketplace model: hosts set prices, renters bid
- Cheapest option for non-critical workloads
- Variable availability and reliability
- Good for batch processing and experimentation
- DLPerf score helps compare GPU performance
- Supports custom Docker images

### Lambda

- Enterprise-focused with SOC 2 Type II, single-tenant options
- 1-Click Clusters for multi-node training
- Lambda Stack (pre-configured CUDA, cuDNN, PyTorch)
- Reserved capacity with volume discounts
- Latest NVIDIA hardware (GB300 NVL72, B200, H200)
- Research-friendly with academic partnerships

### NVIDIA Cloud (DGX Cloud)

- Official NVIDIA infrastructure
- Tightly integrated with NVIDIA software stack (NeMo, Triton)
- Enterprise contracts and support
- Best for organizations already in the NVIDIA ecosystem
- Access to latest hardware and optimized frameworks

## Common Patterns

### Voice Pipeline (Server/Client)

Deploy the speech-to-speech pipeline on a cloud GPU, connect from local machine for audio I/O:

```bash
# On cloud GPU instance
speech-to-speech-helper.sh setup
speech-to-speech-helper.sh start --server

# On local machine
speech-to-speech-helper.sh client --host <gpu-instance-ip>
```

See `tools/voice/speech-to-speech.md` for full pipeline configuration.

### LLM Inference Server

Deploy a model as an OpenAI-compatible API:

```bash
# On cloud GPU instance
pip install vllm
python -m vllm.entrypoints.openai.api_server \
  --model meta-llama/Llama-3.1-8B-Instruct \
  --host 0.0.0.0 --port 8000

# From any client
export OPENAI_API_BASE=http://<gpu-instance-ip>:8000/v1
export OPENAI_API_KEY=dummy  # vLLM doesn't require auth by default
```

### Batch Processing

For non-interactive workloads (fine-tuning, data processing):

```bash
# Use spot/interruptible instances for cost savings
# Checkpoint frequently to survive interruptions
# Example: fine-tuning with checkpointing
python train.py \
  --checkpoint_dir /models/checkpoints \
  --save_every 500 \
  --resume_from_checkpoint
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| CUDA out of memory | Use smaller model, enable quantization, or upgrade GPU |
| Slow model download | Use persistent storage, pre-cache models, or use provider's model library |
| SSH connection refused | Check provider's SSH port (often non-standard), verify key is added |
| Docker GPU not detected | Ensure NVIDIA Container Toolkit is installed: `nvidia-ctk runtime configure` |
| High latency from client | Choose region closer to you, use SSH tunnel compression: `ssh -C` |
| Instance terminated (spot) | Use checkpointing, switch to on-demand, or use RunPod Serverless |

## Security

- Never expose model APIs to the public internet without authentication
- Use SSH tunnels or VPN for secure access
- Store instance credentials via `aidevops secret set <name>`
- Rotate SSH keys regularly
- Enable provider-level firewalls (security groups)
- For production: use HTTPS with reverse proxy (nginx/caddy)

## See Also

- `tools/voice/speech-to-speech.md` - Voice pipeline with cloud GPU deployment
- `services/hosting/hetzner.md` - Dedicated servers (CPU-only alternative)
- `tools/credentials/api-key-setup.md` - Secure credential storage
