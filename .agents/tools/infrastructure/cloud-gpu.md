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
- **Cost range**: $0.20/hr (consumer GPUs) to $8.64/hr (B200 SXM)

**When to Use**: Read this when deploying any AI model that requires GPU acceleration and local hardware is insufficient. Referenced by `tools/voice/speech-to-speech.md` and `tools/vision/` subagents.

<!-- AI-CONTEXT-END -->

## Provider Comparison

| Provider | GPU Options | Pricing | Best For |
|----------|-----------|---------|----------|
| [RunPod](https://www.runpod.io/) | B200, H200, H100, A100, L40S, RTX 5090/4090 | Per-second, $0.40-8.64/hr | General purpose, serverless inference |
| [Vast.ai](https://vast.ai/) | Consumer + datacenter, 10,000+ available | Auction + fixed, 5-6x cheaper than hyperscalers | Budget workloads, experimentation |
| [Lambda](https://lambdalabs.com/) | GB300 NVL72, HGX B300, B200, H200, H100 | Per-hour, reserved discounts | Research, large-scale training, enterprise |
| [NVIDIA Cloud](https://www.nvidia.com/en-us/gpu-cloud/) | A100, H100 (via DGX Cloud) | Per-hour, enterprise contracts | Official NVIDIA stack, production workloads |

```text
Need cheapest possible?           → Vast.ai (auction pricing)
Need reliability + good pricing?  → RunPod (per-second billing, 30+ regions)
Need enterprise / compliance?     → Lambda (SOC 2, single-tenant) or NVIDIA Cloud
Need serverless inference?        → RunPod Serverless
Need multi-GPU clusters?          → Lambda 1-Click Clusters or RunPod Instant Clusters
```

## GPU Selection Guide

| GPU | VRAM | Use Case | Approx. Cost/hr |
|-----|------|----------|-----------------|
| RTX 3090/4090 | 24GB | Small models, fine-tuning, inference | $0.20-0.70 |
| RTX 5090 | 32GB | Small-medium models, fast inference | $0.77-1.58 |
| L4 | 24GB | Inference, cost-effective | $0.40-0.60 |
| L40S | 48GB | Medium models, inference | $0.85-1.22 |
| RTX Pro 6000 | 96GB | Large models without datacenter GPUs | $1.50-2.00 |
| A100 (80GB) | 80GB | Large models, training + inference | $1.79-2.72 |
| H100 (80GB) | 80GB | High throughput, large-scale training | $2.50-4.18 |
| H200 (141GB) | 141GB | Largest models, maximum throughput | $3.35-5.58 |
| B200 (180GB) | 180GB | Next-gen training, largest models | $6.84-8.64 |

### VRAM Requirements by Model Type

| Model Category | Example Models | Min VRAM | Recommended GPU |
|---------------|---------------|----------|-----------------|
| Voice pipeline (STT+TTS) | Whisper + Parler-TTS | 4GB | RTX 3090/4090 |
| Voice pipeline (full S2S) | Whisper + LLM + TTS | 8-16GB | RTX 4090 / L4 |
| 7-8B parameter LLM | Llama 3.3 8B, Phi-4 | 8-16GB | RTX 4090 / L4 |
| 13B parameter LLM | Llama 2 13B | 16-24GB | RTX 4090 / L40S |
| 70B parameter LLM | Llama 3.3 70B, Qwen 2.5 72B | 40-80GB | A100 / H100 |
| 400B+ parameter LLM | Llama 3.1 405B (quantized) | 140-180GB | H200 / B200 |
| Vision models | MiniCPM-o, LLaVA, Qwen-VL | 8-24GB | RTX 4090 / L40S |
| Diffusion models | Stable Diffusion XL, FLUX | 8-16GB | RTX 4090 |
| Video generation | Wan 2.1, CogVideoX | 24-80GB | L40S / A100 |

## Deployment Workflow

### 1. Provision Instance

#### RunPod (runpodctl CLI)

```bash
# Install CLI
brew install runpod/runpodctl/runpodctl  # macOS
# Or: wget -qO- cli.runpod.net | sudo bash

# Configure API key (get from runpod.io/console/user/settings)
runpodctl config --apiKey "$RUNPOD_API_KEY"

# Create a pod with RTX 4090, 50GB storage, PyTorch image
runpodctl create pod \
  --name my-model \
  --gpuType "NVIDIA GeForce RTX 4090" \
  --gpuCount 1 \
  --imageName pytorch/pytorch:2.4.0-cuda12.1-cudnn9-devel \
  --volumeSize 50 \
  --ports "8000/http,22/tcp"

# List/stop/start/remove
runpodctl get pod
runpodctl stop pod <pod-id>
runpodctl start pod <pod-id>
runpodctl remove pod <pod-id>
```

#### Vast.ai (vastai CLI)

```bash
pip install vastai
vastai set api-key <your-api-key>

# Search offers: RTX 4090, sorted by price
vastai search offers 'gpu_name=RTX_4090 num_gpus=1 rentable=true' \
  --order 'dph_total' --limit 10

# Rent an instance
vastai create instance <offer-id> \
  --image pytorch/pytorch:2.4.0-cuda12.1-cudnn9-devel \
  --disk 50 --ssh

vastai show instances
vastai ssh-url <instance-id>
vastai destroy instance <instance-id>
```

#### Lambda (REST API)

```bash
export LAMBDA_API_KEY="your-api-key"

# List available instance types
curl -s -H "Authorization: Bearer $LAMBDA_API_KEY" \
  https://cloud.lambdalabs.com/api/v1/instance-types | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)['data']
for k, v in data.items():
    print(f\"{k}: {v['instance_type']['description']}\")
"

# Launch an instance
curl -s -X POST -H "Authorization: Bearer $LAMBDA_API_KEY" \
  -H "Content-Type: application/json" \
  https://cloud.lambdalabs.com/api/v1/instance-operations/launch \
  -d '{
    "region_name": "us-east-1",
    "instance_type_name": "gpu_1x_h100_sxm5",
    "ssh_key_names": ["my-key"],
    "name": "my-model-server"
  }'

# Terminate instance
curl -s -X POST -H "Authorization: Bearer $LAMBDA_API_KEY" \
  -H "Content-Type: application/json" \
  https://cloud.lambdalabs.com/api/v1/instance-operations/terminate \
  -d '{"instance_ids": ["<instance-id>"]}'
```

### 2. SSH Setup

```bash
ssh-keygen -t ed25519 -C "gpu-instance"
# Add public key to provider dashboard, then connect:
ssh -i ~/.ssh/id_ed25519 root@<instance-ip> -p <port>

# Store credentials securely
aidevops secret set GPU_SSH_KEY_PATH
aidevops secret set GPU_INSTANCE_IP
```

### 3. Docker Deployment

```bash
docker run --gpus all -d \
  -p 8000:8000 \
  -v /models:/models \
  --name my-model \
  my-model-image:latest
```

Example `docker-compose.yml`:

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
# RunPod: Use network volumes | Vast.ai: persistent disk | Lambda: persistent storage
```

### 5. Expose API

```bash
# vLLM (recommended for LLM inference)
python -m vllm.entrypoints.openai.api_server \
  --model microsoft/Phi-3-mini-4k-instruct \
  --host 0.0.0.0 --port 8000

# Text Generation Inference (TGI)
docker run --gpus all -p 8000:80 \
  -v /models:/data \
  ghcr.io/huggingface/text-generation-inference:latest \
  --model-id microsoft/Phi-3-mini-4k-instruct

# Custom FastAPI server
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

# Speech-to-speech server/client pattern
speech-to-speech-helper.sh start --server   # On GPU server
speech-to-speech-helper.sh client --host <instance-ip>  # On local machine
```

## Cost Optimization

| Strategy | Savings | Trade-off |
|----------|---------|-----------|
| Spot/interruptible instances | 50-80% | Can be terminated mid-job |
| Off-peak hours | 10-30% | Scheduling constraints |
| Smaller GPU + quantization | 40-60% | Slight quality loss |
| Serverless (RunPod) | Pay only for requests | Cold start latency |
| Reserved instances (Lambda) | 20-30% | Commitment required |
| Vast.ai auction pricing | 50-70% vs. fixed | Variable availability |

**Quantization**: 4-bit (GPTQ/AWQ) reduces VRAM by ~75%. Example: Llama 3.1 70B FP16 needs ~140GB; 4-bit fits on 1x A100 or L40S (~35GB). Search HuggingFace for `TheBloke/<model>-GPTQ` or `<model>-AWQ`.

**Auto-shutdown** (add to crontab):

```bash
*/5 * * * * nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader | \
  awk '{if ($1+0 < 5) system("echo idle >> /tmp/gpu_idle"); else system("rm -f /tmp/gpu_idle")}' && \
  [ "$(wc -l < /tmp/gpu_idle 2>/dev/null)" -gt 6 ] && shutdown -h now
# RunPod: Set auto-stop in pod settings | Vast.ai: Set max idle time | Lambda: Use API
```

## GPU Monitoring

```bash
# Health check on connect
nvidia-smi
nvidia-smi --query-gpu=name,memory.total,memory.used,temperature.gpu,utilization.gpu \
  --format=csv,noheader
watch -n 2 nvidia-smi

# Verify PyTorch sees the GPU
python3 -c "
import torch
print(f'CUDA: {torch.cuda.is_available()}, GPUs: {torch.cuda.device_count()}, Device: {torch.cuda.get_device_name(0)}')
"

# Log metrics every 30 seconds to CSV
nvidia-smi \
  --query-gpu=timestamp,name,utilization.gpu,utilization.memory,memory.used,temperature.gpu,power.draw \
  --format=csv -l 30 > /tmp/gpu_metrics.csv &
```

**Performance benchmark** (validate before long workloads):

```bash
python3 -c "
import torch, time
size = 1024 * 1024 * 256  # 1GB
a = torch.randn(size, device='cuda')
torch.cuda.synchronize()
start = time.time()
for _ in range(100):
    b = a.clone()
torch.cuda.synchronize()
elapsed = time.time() - start
gb_per_sec = (size * 4 * 100) / elapsed / 1e9
print(f'Memory bandwidth: {gb_per_sec:.1f} GB/s')
"
# Vast.ai: check DLPerf score matches listing
# RunPod: Community Cloud GPUs may have lower bandwidth than Secure Cloud
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
- Store credentials: `aidevops secret set RUNPOD_API_KEY` / `VASTAI_API_KEY` / `LAMBDA_API_KEY`
- Rotate SSH keys regularly; enable provider-level firewalls (security groups)
- For production: use HTTPS with reverse proxy (nginx/caddy)

See `tools/credentials/api-key-setup.md` for full credential setup.

## See Also

- `tools/voice/speech-to-speech.md` - Voice pipeline with cloud GPU deployment
- `services/hosting/hetzner.md` - Dedicated servers (CPU-only alternative)
- `tools/credentials/api-key-setup.md` - Secure credential storage
- `tools/ai-orchestration/overview.md` - AI orchestration frameworks for model serving
