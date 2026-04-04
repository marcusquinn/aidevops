---
description: "Cloud GPU deployment - provider comparison, SSH/Docker setup, model caching, cost optimization"
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

# Cloud GPU Deployment

<!-- AI-CONTEXT-START -->

## Quick Reference

Deploy GPU-intensive AI models (voice, vision, LLMs) when local hardware is insufficient. Pattern: SSH -> Docker -> expose API -> connect. Cost: $0.20-$8.64/hr. Referenced by `tools/voice/speech-to-speech.md` and `tools/vision/` subagents.

<!-- AI-CONTEXT-END -->

## Providers

| Provider | GPUs | Pricing | Best For |
|----------|------|---------|----------|
| [RunPod](https://www.runpod.io/) | B200, H200, H100, A100, L40S, RTX 4090 | Per-second, $0.40-8.64/hr | General purpose, serverless |
| [Vast.ai](https://vast.ai/) | Consumer+datacenter, 10k+ | Auction+fixed, 5-6x cheaper | Budget, experimentation |
| [Lambda](https://lambdalabs.com/) | GB300, B200, H200, H100 | Per-hour, reserved discounts | Research, training, enterprise |
| [NVIDIA Cloud](https://www.nvidia.com/en-us/gpu-cloud/) | A100, H100 (DGX) | Per-hour, enterprise | Official NVIDIA stack |

## GPU Selection

VRAM: RTX 4090=24GB, L4=24GB, L40S=48GB, A100=80GB, H100=80GB, H200=141GB, B200=180GB.

| Workload | VRAM | GPU | $/hr |
|----------|------|-----|------|
| Voice STT+TTS (Whisper+Parler-TTS) | 4GB | RTX 3090/4090 | 0.20-0.70 |
| Voice S2S / 7-8B LLM | 8-16GB | RTX 4090 / L4 | 0.40-0.70 |
| 13B LLM / diffusion (SD XL, FLUX) | 16-24GB | RTX 4090 / L40S | 0.70-1.22 |
| Vision / video gen (Wan 2.1, CogVideoX) | 24-80GB | L40S / A100 | 0.85-2.72 |
| 70B LLM (Llama 3.3 70B, Qwen 2.5 72B) | 40-80GB | A100 / H100 | 1.79-4.18 |
| 96GB workloads | 96GB | RTX Pro 6000 | 1.50-2.00 |
| 400B+ quantized (Llama 3.1 405B 4-bit) | 140-180GB | H200 / B200 | 3.35-8.64 |

## Deployment

### 1. Provision

```bash
# RunPod (install: brew install runpod/runpodctl/runpodctl OR wget -qO- cli.runpod.net | sudo bash)
runpodctl config --apiKey "$RUNPOD_API_KEY"
runpodctl create pod --name my-model --gpuType "NVIDIA GeForce RTX 4090" --gpuCount 1 \
  --imageName pytorch/pytorch:2.4.0-cuda12.1-cudnn9-devel --volumeSize 50 --ports "8000/http,22/tcp"
# Vast.ai (install: pip install vastai && vastai set api-key <key>)
vastai search offers 'gpu_name=RTX_4090 num_gpus=1 rentable=true' --order 'dph_total' --limit 10
vastai create instance <offer-id> --image pytorch/pytorch:2.4.0-cuda12.1-cudnn9-devel --disk 50 --ssh
# Lambda (REST API)
LAMBDA_BASE="https://cloud.lambdalabs.com/api/v1"
curl -s -H "Authorization: Bearer $LAMBDA_API_KEY" "$LAMBDA_BASE/instance-types"  # list types
curl -s -X POST -H "Authorization: Bearer $LAMBDA_API_KEY" -H "Content-Type: application/json" \
  "$LAMBDA_BASE/instance-operations/launch" \
  -d '{"region_name":"us-east-1","instance_type_name":"gpu_1x_h100_sxm5","ssh_key_names":["my-key"]}'
```

Lifecycle: RunPod `runpodctl get|stop|remove pod <id>`, Vast.ai `vastai show instances|destroy instance <id>`, Lambda `POST .../terminate {"instance_ids":["<id>"]}`.

### 2. SSH + Deploy

```bash
ssh-keygen -t ed25519 -C "gpu-instance"  # add public key to provider dashboard
ssh -i ~/.ssh/id_ed25519 root@<instance-ip> -p <port>
aidevops secret set GPU_SSH_KEY_PATH && aidevops secret set GPU_INSTANCE_IP
docker run --gpus all -d -p 8000:8000 -v /models:/models --name my-model my-model-image:latest
# Pre-download to persistent volume (RunPod: network volumes, Vast.ai: persistent disk, Lambda: persistent storage)
export HF_HOME=/models/huggingface TRANSFORMERS_CACHE=/models/huggingface/hub
python -c "from transformers import AutoModelForCausalLM, AutoTokenizer; m='microsoft/Phi-3-mini-4k-instruct'; AutoTokenizer.from_pretrained(m, cache_dir='$TRANSFORMERS_CACHE'); AutoModelForCausalLM.from_pretrained(m, cache_dir='$TRANSFORMERS_CACHE')"
```

### 3. Serve + Connect

```bash
python -m vllm.entrypoints.openai.api_server --model microsoft/Phi-3-mini-4k-instruct --host 0.0.0.0 --port 8000  # vLLM (recommended)
# TGI: docker run --gpus all -p 8000:80 -v /models:/data ghcr.io/huggingface/text-generation-inference:latest --model-id <model>
curl http://<instance-ip>:8000/v1/completions -H "Content-Type: application/json" \
  -d '{"model": "microsoft/Phi-3-mini-4k-instruct", "prompt": "Hello", "max_tokens": 100}'
# SSH tunnel (if no public port): ssh -L 8000:localhost:8000 root@<instance-ip> -p <port>
```

## Cost Optimization

Spot instances (50-80% savings, termination risk) | Off-peak (10-30%) | Smaller GPU + quantization (40-60%) | Serverless/RunPod (pay per request, cold starts) | Reserved/Lambda (20-30%, commitment) | Vast.ai auction (50-70% vs fixed).

**Quantization**: 4-bit GPTQ/AWQ cuts VRAM ~75%. Llama 3.1 70B: FP16 ~140GB -> 4-bit ~35GB (1x A100). Search HuggingFace for `TheBloke/<model>-GPTQ` or `<model>-AWQ`.

**Auto-shutdown** (30min idle -- alternatives: RunPod auto-stop, Vast.ai max idle, Lambda API):

```bash
*/5 * * * * GPU_UTIL=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader | awk '{print $1+0}'); \
  IDLE_COUNT=$(cat /tmp/gpu_idle_count 2>/dev/null || echo 0); \
  if [ "$GPU_UTIL" -lt 5 ]; then echo $((IDLE_COUNT + 1)) > /tmp/gpu_idle_count; \
  else echo 0 > /tmp/gpu_idle_count; fi; \
  [ "$(cat /tmp/gpu_idle_count)" -gt 6 ] && shutdown -h now
```

## Monitoring + Troubleshooting

```bash
# Health check
nvidia-smi --query-gpu=name,memory.total,memory.used,temperature.gpu,utilization.gpu --format=csv,noheader
# CUDA check
python3 -c "import torch; print(torch.cuda.is_available(), torch.cuda.device_count())"
# Continuous monitoring (background)
nvidia-smi --query-gpu=timestamp,utilization.gpu,memory.used,temperature.gpu --format=csv -l 30 > /tmp/gpu_metrics.csv &
```

| Issue | Solution |
|-------|----------|
| CUDA out of memory | Smaller model, quantization, or upgrade GPU |
| Slow model download | Persistent storage, pre-cache, or provider model library |
| SSH connection refused | Check provider SSH port (often non-standard), verify key |
| Docker GPU not detected | `nvidia-ctk runtime configure` (NVIDIA Container Toolkit) |
| High latency | Closer region, SSH tunnel compression (`ssh -C`) |
| Spot termination | Checkpointing, on-demand, or RunPod Serverless |

## Security

Never expose model APIs without auth -- use SSH tunnels or VPN. Store keys: `aidevops secret set RUNPOD_API_KEY` / `VASTAI_API_KEY` / `LAMBDA_API_KEY`. Rotate SSH keys regularly; enable provider firewalls; production: HTTPS via nginx/caddy. Full setup: `tools/credentials/api-key-setup.md`.

## See Also

- `tools/infrastructure/fireworks.md` -- managed inference, fine-tuning, and model hosting (Fireworks AI)
- `tools/infrastructure/nearai.md` -- TEE-backed private inference (NEAR AI Cloud)
- `tools/voice/speech-to-speech.md` -- voice pipeline with cloud GPU
- `services/hosting/hetzner.md` -- dedicated servers (CPU-only alternative)
- `tools/ai-orchestration/overview.md` -- AI orchestration for model serving
