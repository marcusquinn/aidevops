---
description: Runpod for media generation - Public Endpoints (managed per-output pricing), Hub, Serverless bring-your-own-model, and GPU Pods for ComfyUI/open-weight models
mode: subagent
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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Runpod Media Generation

<!-- AI-CONTEXT-START -->

## Scope

Runpod (spelled with one capital since June 2025) covers four media routes on
one account. Pick the lightest route that meets the brief:

| Route | What you pay for | Use when |
|-------|------------------|----------|
| **Public Endpoints** | Per output (image, MP, second, character); failed generations not charged | You want hosted Flux, Qwen Image, Seedream, Nano Banana, Seedance, Sora 2, Wan, Kling, Vidu, Pruna, InfiniteTalk or TTS with no deployment |
| **Hub** | Public Endpoints tab, plus community repos deployable to Serverless | Discover a ready worker or model before building one: `https://console.runpod.io/hub?tabSelected=public_endpoints` |
| **Serverless (BYO)** | GPU-seconds while workers run; scale to zero | Your own model, LoRA, fine-tune or ComfyUI graph as an API with bursty demand |
| **Pods** | GPU-hours while the pod exists (Reserved or Spot) | Interactive ComfyUI, training/fine-tuning, long continuous batches |

Choose the provider first in `content/media-generation-providers.md`. GPU
selection, provisioning commands, and the **billable deployment contract** live
in `tools/infrastructure/cloud-gpu.md`; apply that contract before creating or
changing any Serverless endpoint or Pod.

## Quick Reference

- **Auth**: `Authorization: Bearer $RUNPOD_API_KEY` (`aidevops secret set RUNPOD_API_KEY`)
- **Public Endpoint sync**: `POST https://api.runpod.ai/v2/<endpoint-id>/runsync`
  with `{"input":{...}}`
- **Async**: `POST .../<endpoint-id>/run` returns a job ID; poll
  `GET .../<endpoint-id>/status/<job-id>` with bounded backoff
- **Model list and per-model schema/pricing**: `https://docs.runpod.io/public-endpoints/reference`
- **Serverless ComfyUI worker**: GitHub `runpod-workers/worker-comfyui`
- **CLI**: `runpodctl` (Pods/Serverless lifecycle, see `cloud-gpu.md`)
- **JS/TS**: `@runpod/ai-sdk-provider` integrates Public Endpoints with the Vercel AI SDK

<!-- AI-CONTEXT-END -->

## Public Endpoints

```bash
curl -s -X POST "https://api.runpod.ai/v2/black-forest-labs-flux-1-schnell/runsync" \
  -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"input":{"prompt":"Studio product shot of a ceramic mug","width":1024,"height":1024}}'
```

Endpoint IDs and input fields differ per model; copy them from the model's
reference page. Use `/run` for video and anything that can exceed the sync
window.

Representative list prices (verified 2026-10-14, re-check before quoting):

| Model | Price |
|-------|-------|
| Flux Schnell | $0.0024 / megapixel |
| Flux Dev | $0.02 / megapixel |
| Z-Image Turbo, P-Image T2I | $0.005 / image |
| Nano Banana 2 Edit | $0.0875-$0.175 / image |
| Pruna Video | $0.02/s (720p), $0.04/s (1080p) |
| WAN 2.6 I2V | $0.10/s (720p), $0.15/s (1080p) |
| Vidu Q3 T2V/I2V | $0.15/s |
| Seedance 2.5 T2V/I2V | $0.18/s (480p) to $1.80/s (4K), native audio |
| SORA 2 I2V | $0.40 (4s), $0.80 (8s), $1.20 (12s) |
| Chatterbox Turbo TTS | $0.001/s |

## Bring Your Own Model (Serverless)

Use when the look depends on your own weights (character/brand LoRA,
fine-tuned checkpoint, custom ComfyUI graph) or the media cannot go to a
third-party gateway.

1. Start from `runpod-workers/worker-comfyui` (or a Hub repo) and bake or
   mount model weights. Network volumes avoid re-downloading; Global Volumes
   (beta, Oct 2026) let Serverless workers start in any data center.
2. Record the billable deployment contract from `cloud-gpu.md` (model
   provenance, image, GPU pool, price, min/max workers, idle timeout).
3. Keep `workers.min=0` for bursty work; raise it only when cold starts break
   an SLA and the idle cost is approved.
4. Benchmark **GPU-seconds per finished asset** on one sample before batching;
   that number, not the hourly rate, decides cost.

## Cost Decision

Per asset, BYO GPU cost is:

```text
gpu_rate_per_hour / 3600 * gpu_seconds_per_asset * takes_per_keeper
+ (setup_hours + idle_hours) * gpu_rate_per_hour / assets
```

Compare that with the API's per-second or per-image price times takes. Run
`media-gen-cost-helper.sh compare` with real rates and a measured
`--gpu-secs-per-clip`; it prints both totals and the break-even volume.
Rules of thumb:

- Low volume, closed models (Veo, Sora, Kling, Runway, H3): use an API.
- High volume of an open-weight model you can run efficiently (Wan, LTX,
  Flux, Hunyuan): BYO usually wins once setup is amortised.
- Custom LoRA/graph or privacy constraint: BYO regardless of price.

## First-Party References

- [Public Endpoints overview](https://docs.runpod.io/hub/public-endpoints)
- [Public Endpoints model reference](https://docs.runpod.io/public-endpoints/reference)
- [Pricing](https://www.runpod.io/pricing)
- [Serverless](https://www.runpod.io/product/serverless)

## Related

- `tools/infrastructure/cloud-gpu.md` - GPU selection, provisioning, billable deployment contract
- `tools/ai-generation/comfy-cli.md` - ComfyUI workflows (local or on a Pod)
- `content/media-generation-providers.md` - provider-selection source of truth
- `content/video-videorouter.md` - price-routed API across hosted providers
