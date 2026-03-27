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

Deploy GPU-intensive AI models (voice, vision, LLMs) when local hardware is insufficient. Pattern: SSH → Docker → expose API → connect. Cost: $0.20–$8.64/hr. Referenced by `tools/voice/speech-to-speech.md` and `tools/vision/` subagents.

<!-- AI-CONTEXT-END -->

## Provider Comparison

| Provider | GPU Options | Pricing | Best For |
|----------|-----------|---------|----------|
| [RunPod](https://www.runpod.io/) | B200, H200, H100, A100, L40S, RTX 5090/4090 | Per-second, $0.40-8.64/hr | General purpose, serverless inference |
| [Vast.ai](https://vast.ai/) | Consumer + datacenter, 10,000+ available | Auction + fixed, 5-6x cheaper than hyperscalers | Budget workloads, experimentation |
| [Lambda](https://lambdalabs.com/) | GB300 NVL72, HGX B300, B200, H200, H100 | Per-hour, reserved discounts | Research, large-scale training, enterprise |
| [NVIDIA Cloud](https://www.nvidia.com/en-us/gpu-cloud/) | A100, H100 (via DGX Cloud) | Per-hour, enterprise contracts | Official NVIDIA stack, production workloads |

## GPU Selection Guide

| Workload | Examples | VRAM | GPU | Cost/hr |
|----------|----------|------|-----|---------|
| Voice STT+TTS | Whisper + Parler-TTS | 4GB | RTX 3090/4090 | $0.20-0.70 |
| Voice full S2S / 7-8B LLM | Whisper+LLM+TTS, Llama 3.3 8B, Phi-4 | 8-16GB | RTX 4090 / L4 | $0.40-0.70 |
| 13B LLM / diffusion | Llama 2 13B, SD XL, FLUX | 16-24GB | RTX 4090 / L40S | $0.70-1.22 |
| Vision / video gen | MiniCPM-o, Wan 2.1, CogVideoX | 24-80GB | L40S / A100 | $0.85-2.72 |
| 70B LLM | Llama 3.3 70B, Qwen 2.5 72B | 40-80GB | A100 / H100 | $1.79-4.18 |
| Large models (96GB) | RTX Pro 6000 workloads | 96GB | RTX Pro 6000 | $1.50-2.00 |
| 400B+ LLM (quantized) | Llama 3.1 405B 4-bit | 140-180GB | H200 / B200 | $3.35-8.64 |

GPU hardware reference: RTX 4090=24GB, L4=24GB, L40S=48GB, A100=80GB, H100=80GB, H200=141GB, B200=180GB.

## Deployment Workflow

### 1. Provision Instance

#### RunPod (runpodctl CLI)

```bash
brew install runpod/runpodctl/runpodctl  # macOS; or: wget -qO- cli.runpod.net | sudo bash
runpodctl config --apiKey "$RUNPOD_API_KEY"
runpodctl create pod --name my-model --gpuType "NVIDIA GeForce RTX 4090" --gpuCount 1 \
  --imageName pytorch/pytorch:2.4.0-cuda12.1-cudnn9-devel --volumeSize 50 --ports "8000/http,22/tcp"
runpodctl get pod | stop pod <id> | start pod <id> | remove pod <id>
```

#### Vast.ai (vastai CLI)

```bash
pip install vastai && vastai set api-key <your-api-key>
vastai search offers 'gpu_name=RTX_4090 num_gpus=1 rentable=true' --order 'dph_total' --limit 10
vastai create instance <offer-id> --image pytorch/pytorch:2.4.0-cuda12.1-cudnn9-devel --disk 50 --ssh
vastai show instances | ssh-url <instance-id> | destroy instance <instance-id>
```

#### Lambda (REST API)

```bash
export LAMBDA_API_KEY="your-api-key" BASE="https://cloud.lambdalabs.com/api/v1"
AUTH="-H \"Authorization: Bearer $LAMBDA_API_KEY\""
# List
curl -s $AUTH "$BASE/instance-types" | python3 -c "import json,sys; [print(k) for k in json.load(sys.stdin)['data']]"
# Launch
curl -s -X POST $AUTH -H "Content-Type: application/json" "$BASE/instance-operations/launch" \
  -d '{"region_name":"us-east-1","instance_type_name":"gpu_1x_h100_sxm5","ssh_key_names":["my-key"],"name":"my-model-server"}'
# Terminate
curl -s -X POST $AUTH -H "Content-Type: application/json" "$BASE/instance-operations/terminate" \
  -d '{"instance_ids":["<instance-id>"]}'
```

### 2. SSH Setup

```bash
ssh-keygen -t ed25519 -C "gpu-instance"  # add public key to provider dashboard
ssh -i ~/.ssh/id_ed25519 root@<instance-ip> -p <port>
aidevops secret set GPU_SSH_KEY_PATH && aidevops secret set GPU_INSTANCE_IP
```

### 3. Docker Deployment

```bash
docker run --gpus all -d -p 8000:8000 -v /models:/models --name my-model my-model-image:latest
```

`docker-compose.yml`:

```yaml
services:
  model:
    image: pytorch/pytorch:2.4.0-cuda12.1-cudnn9-devel
    deploy:
      resources:
        reservations:
          devices: [{driver: nvidia, count: 1, capabilities: [gpu]}]
    ports: ["8000:8000"]
    volumes:
      - ./models:/models
      - model-cache:/root/.cache/huggingface
volumes:
  model-cache:
```

### 4. Model Caching

```bash
export HF_HOME=/models/huggingface TRANSFORMERS_CACHE=/models/huggingface/hub
# Pre-download to persistent volume before serving (RunPod: network volumes | Vast.ai: persistent disk | Lambda: persistent storage)
python -c "from transformers import AutoModelForCausalLM, AutoTokenizer; m='microsoft/Phi-3-mini-4k-instruct'; AutoTokenizer.from_pretrained(m, cache_dir='$TRANSFORMERS_CACHE'); AutoModelForCausalLM.from_pretrained(m, cache_dir='$TRANSFORMERS_CACHE')"
```

### 5. Expose API

```bash
# vLLM (recommended)
python -m vllm.entrypoints.openai.api_server --model microsoft/Phi-3-mini-4k-instruct --host 0.0.0.0 --port 8000
# TGI
docker run --gpus all -p 8000:80 -v /models:/data ghcr.io/huggingface/text-generation-inference:latest \
  --model-id microsoft/Phi-3-mini-4k-instruct
# Custom FastAPI
uvicorn serve:app --host 0.0.0.0 --port 8000
```

### 6. Connect from Local Machine

```bash
# Direct API call
curl http://<instance-ip>:8000/v1/completions -H "Content-Type: application/json" \
  -d '{"model": "microsoft/Phi-3-mini-4k-instruct", "prompt": "Hello", "max_tokens": 100}'
# SSH tunnel
ssh -L 8000:localhost:8000 root@<instance-ip> -p <port>
# Speech-to-speech
speech-to-speech-helper.sh start --server && speech-to-speech-helper.sh client --host <ip>
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

**Auto-shutdown** (crontab):

```bash
*/5 * * * * nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader | \
  awk '{if ($1+0 < 5) system("echo idle >> /tmp/gpu_idle"); else system("rm -f /tmp/gpu_idle")}' && \
  [ "$(wc -l < /tmp/gpu_idle 2>/dev/null)" -gt 6 ] && shutdown -h now
# RunPod: Set auto-stop in pod settings | Vast.ai: Set max idle time | Lambda: Use API
```

## GPU Monitoring

```bash
# Health check
nvidia-smi --query-gpu=name,memory.total,memory.used,temperature.gpu,utilization.gpu --format=csv,noheader
python3 -c "import torch; print(f'CUDA: {torch.cuda.is_available()}, GPUs: {torch.cuda.device_count()}, Device: {torch.cuda.get_device_name(0)}')"
# Log metrics every 30s
nvidia-smi --query-gpu=timestamp,name,utilization.gpu,utilization.memory,memory.used,temperature.gpu,power.draw \
  --format=csv -l 30 > /tmp/gpu_metrics.csv &
# Bandwidth benchmark (validate before long workloads; Vast.ai: verify DLPerf score; RunPod: Community < Secure Cloud)
python3 -c "import torch,time; s=1024*1024*256; a=torch.randn(s,device='cuda'); torch.cuda.synchronize(); t=time.time(); [a.clone() for _ in range(100)]; torch.cuda.synchronize(); print(f'{(s*4*100)/(time.time()-t)/1e9:.1f} GB/s')"
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

- Never expose model APIs without authentication; use SSH tunnels or VPN
- Store credentials: `aidevops secret set RUNPOD_API_KEY` / `VASTAI_API_KEY` / `LAMBDA_API_KEY`
- Rotate SSH keys regularly; enable provider firewalls; production: HTTPS via nginx/caddy
- Full credential setup: `tools/credentials/api-key-setup.md`

## See Also

- `tools/voice/speech-to-speech.md` - Voice pipeline with cloud GPU deployment
- `services/hosting/hetzner.md` - Dedicated servers (CPU-only alternative)
- `tools/credentials/api-key-setup.md` - Secure credential storage
- `tools/ai-orchestration/overview.md` - AI orchestration frameworks for model serving
