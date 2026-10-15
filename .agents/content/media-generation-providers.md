---
description: Provider-neutral routing for AI image, video, audio, avatar, enhancement, and local generation workflows
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Media Generation Provider Routing

<!-- AI-CONTEXT-START -->

## Purpose

Choose the provider before loading its implementation agent. This is the
canonical comparison surface; provider agents document their own interfaces
and must not maintain competing cross-provider tables.

Provider choice is a workload decision, not a model-name lookup. The same
upstream model can differ by version, parameters, moderation, queueing, price,
retention, and support when accessed through a gateway.

## Routing Order

1. **Privacy and locality**: if source media cannot leave the machine, use
   local ComfyUI and local post-production tools.
2. **Required account or contract**: use the user's named direct provider when
   they require its official SDK, support, billing, or provider-only feature.
3. **Specialized outcome**: route avatar/presenter work to HeyGen, portrait
   enhancement to Enhancor, and code-composed editing to Remotion.
4. **Gateway workflow**: choose among VideoRouter, Kie.ai, MuAPI, WaveSpeed and
   Runpod Public Endpoints based on the control surface below, then verify the
   exact model schema and live price.
5. **Own weights or volume**: when a custom LoRA/checkpoint/ComfyUI graph is
   required, or open-weight volume beats per-output pricing, rent GPUs on
   Runpod Serverless/Pods (`video-runpod.md`) and size them with the cost method
   below.
6. **Production safety**: check credits before batches, preserve task IDs, use
   callbacks where supported, and download temporary results immediately.

## Provider Matrix

| Route | Prefer when | Primary strengths | Main trade-off |
|-------|-------------|-------------------|----------------|
| **VideoRouter** (`video-videorouter.md`) | The same model is sold by several hosts and lowest live price plus failover matters | Cheapest-host routing across Fal, WaveSpeed, Atlas Cloud, Replicate, Novita, Kie.ai and others; 900+ models; real-time world/avatar sessions | Flat 2.5% fee on top; video/image need an explicit model id; routed host retention varies |
| **Runpod** (`video-runpod.md`) | Hosted per-output models with no deployment, or your own weights/ComfyUI graph on rented GPUs | Public Endpoints (no charge for failed generations), Serverless scale-to-zero BYO, Pods for interactive work | BYO needs setup, benchmarking and the billable deployment contract in `tools/infrastructure/cloud-gpu.md` |
| **Kie.ai** (`video-kie.md`) | One generic Market task contract should cover changing image, video, and audio models | JSON pass-through, unified status, uploads, credits, callback HMAC | Model inputs remain provider-specific; gateway stability and retention require defensive handling |
| **MuAPI** (`video-muapi.md`) | The workflow needs creative orchestration beyond single generation calls | VFX, specialized apps, storyboards, workflows, agents, music and lipsync | Large provider-specific surface; use only when those orchestration features matter |
| **WaveSpeed** (`video-wavespeed.md`) | Broad multimodal or 3D access and a queryable current model list are important | Image, video, audio, 3D, utilities, model-list endpoint | Inputs and capabilities vary by routed model |
| **Runway** (`video-runway.md`) | Runway-only models (Gen-4.5, Aleph 2 video editing, Act-Two, Ruby HDR), professional ProRes/HDR/EXR output, or a supported enterprise contract | Official SDKs, Model Routers with price caps, recipes; also resells Kling, Veo, Seedance, Wan, H3 and ElevenLabs at $0.01/credit | Third-party models usually cost more than gateway hosts |
| **Higgsfield API/UI** (`video-higgsfield.md`, `video-higgsfield-ui.md`) | Higgsfield creative tooling, character references, or existing subscription credits drive the task | Multi-model creative workflows; API and browser/subscription routes | API and UI credit pools differ; browser automation is operationally heavier |
| **Gemini web app** (`gemini-image.md`, `gemini-video.md`, `gemini-music.md`) | An authorized Gemini account and its existing plan or allowance should produce a local image, video, or music asset | Persistent per-account Brave profiles, headed login, headless operation, local Downloads delivery | Consumer UI and allowance visibility can change; prefer an official API for unattended production |
| **Direct Sora/Veo** (`production-video.md`) | The production brief already selects Sora or Veo and direct API semantics are required | Focused UGC/cinematic production templates and seed workflows | Not a general provider abstraction |
| **HeyGen** (`heygen-skill.md`) | The deliverable is an avatar, presenter, translation, or talking-head video | Avatar and speech-led video workflows | Specialized rather than general scene generation |
| **ComfyUI** (`tools/ai-generation/comfy-cli.md`) | Local control, privacy, reusable graphs, or custom models dominate | Local execution and explicit workflows | Setup, hardware, model storage, and node maintenance |
| **Enhancor** (`video-enhancor.md`) | Existing portraits need enhancement after generation | Face-aware enhancement and upscale | Post-processing only |
| **Remotion** (`tools/video/remotion/remotion.md`) | Assets need deterministic code-based assembly, captions, or animation | Reproducible React compositions and rendering | Composes media; it is not a generation-model gateway |

## Recommendations by Need

Starting points only (verified 2026-10-14); confirm current model quality with
a small seed-bracketed test before committing a batch.

| Priority | Start with | Route | Notes |
|----------|------------|-------|-------|
| Photoreal people/product, cinematic camera | Veo 3.1, Kling 3.0/O3, Seedance 2.5, Gen-4.5 | Runway or VideoRouter; Veo direct for ingredients | Veo/Seedance include native audio; see `production-video.md` |
| Cheap, fast iteration and volume | MiniMax H3 Max/Turbo, Seedance 2.0 Mini, Wan 3.0, LTX 2.x, Grok Imagine 1.5 Lite | VideoRouter (cheapest host) or Kie.ai | Draft cheap, then re-render the keeper on a premium model |
| Stylised, anime, brand look | Own LoRA on Wan/Flux/Qwen Image; Midjourney/Seedream stills then I2V | Runpod Serverless/Pods (BYO) or local ComfyUI | Consistency comes from weights and references, not prompts |
| Lip sync on existing footage | Sync lipsync v3, HeyGen v3 lipsync, H3 Max lipsync, InfiniteTalk | VideoRouter or Runpod Public Endpoints (InfiniteTalk) | Presenter/avatar deliverables: `heygen-skill.md` |
| Talking head or presenter | HeyGen, Runway Characters/GWM avatars, Vidu S2 live avatar | HeyGen direct, Runway, VideoRouter live | Pipeline: `production-video-08-talking-head-pipeline.md` |
| Motion transfer or choreography | Kling motion control, Wan 2.2 Animate, Runway Act-Two | VideoRouter, Runway | Needs a clean driving video |
| Edit existing video (relight, restyle, replace) | Runway Aleph 2, Gemini Omni Flash, Kling O3, Flux 3 edit | Runway or VideoRouter | Aleph is a Runway model, resold on VideoRouter at the same $0.28/s; real-time restyle via Decart Lucy on VideoRouter |
| Motion graphics, captions, explainers | Remotion (deterministic code) plus generated b-roll | `tools/video/remotion/remotion.md`, `tools/video/motion-design.md` | Do not generate text-heavy graphics with diffusion |
| Upscale, frame rate, HDR finishing | Topaz, Magnific, SeedVR2; Runway Ruby (SDR→HDR) | VideoRouter, Runway, `video-enhancor.md` | Finish only keepers |
| Images | Nano Banana 2/Pro, GPT Image 2, Seedream 5, Flux 2, Ideogram (text) | Kie.ai, Runway, VideoRouter, Runpod Public Endpoints | Flux Schnell on Runpod is about $0.0024/MP for bulk drafts |
| Privacy or own weights | Open-weight models on rented or local GPUs | Runpod Serverless/Pods, local ComfyUI | Apply the `cloud-gpu.md` billable deployment contract |

### "H3" = MiniMax Hailuo H3

H3 is MiniMax's Hailuo video family: `h3`, `h3-max`, `h3-fast`, `h3-max-turbo`,
plus `h3-max-lipsync` and `h3-max-camera-controls` variants. It is a low-cost
text/image/reference-to-video option with strong motion for its price.
Observed list prices: about $0.016/s (H3 Max 768p via SandBase on
VideoRouter), $0.04/s (H3 on Kie.ai), $0.05/s (480p) to $0.08/s (768p) on
Runway `h3_max`, and $0.05-$0.16/s by resolution on Fal. VideoRouter's
`model:"auto"` for video defaults to a MiniMax H3 host.

## Cost Comparison Method

1. Fix the deliverable: finished assets `N`, output seconds per asset, and
   expected takes per keeper (3-5 for new prompts; 1-2 once seeds are known).
2. Collect live list prices for 2-4 candidate routes. Gateways often bill in
   credits or by resolution tier; convert to $/output-second or $/image.
3. For a rented GPU route, benchmark one generation and record GPU-seconds.
   Add setup and idle hours; these dominate small batches.
4. Run the deterministic comparison and break-even estimate:

```bash
media-gen-cost-helper.sh compare --clips 200 --secs-per-clip 6 --takes 3 \
  --api "h3-max-videorouter=0.016:sec:2.5" --api "veo3.1-fast-runway=0.10" \
  --gpu "wan-on-l40s=0.86" --gpu-secs-per-clip 240 --setup-hours 3
```

5. Choose on quality fit first, then cost. A cheap model that needs 3x more
   takes is not cheap. Re-check prices before each large batch.

## Decision Checks

- **Reject consumer-subscription resale.** Do not route to a gateway whose
  capacity comes from pooled or shared consumer accounts, such as ChatGPT Plus
  or Google AI Pro/Ultra seats, even when it has a documented API and low
  prices. Use the official API or a gateway that resells official API capacity.

- **Do not translate schemas across providers.** Load the selected provider
  agent and use its exact model ID, authentication, and input fields.
- **Do not select from marketing claims alone.** Confirm current model support,
  price, queue limits, output rights, and retention from first-party sources.
- **Do not test with paid generations by default.** Run mocked transport tests
  for helpers; make a live request only when it resolves material uncertainty
  and the user has authorized the cost.
- **Do not hide asynchronous state.** A submitted task is not a completed asset;
  return task IDs and make timeout recovery explicit.
- **Consume campaign jobs as requirements, not provider selections.** A
  schema-v1 production manifest names asset class, format, rights, disclosure,
  and fallback. Verify current capability evidence before setting its provider
  route; an unavailable capability stays `blocked` rather than silently
  switching providers.
- **Do not preserve stale capability tables.** Update this file when a new
  provider changes routing; keep provider agents focused on their own contract.

## Common Handoffs

| Need | Route |
|------|-------|
| Image generation or editing | `production-image.md` -> this file -> selected provider |
| Generated video shots | `production-video.md` -> this file -> selected provider |
| Voice/music generation | `production-audio.md` -> this file -> selected provider |
| Avatar video | `heygen-skill.md` |
| Post-production assembly | `tools/video/remotion/remotion.md` or `tools/video/video-editor.md` |
| Local/private generation | `tools/ai-generation/comfy-cli.md` |

<!-- AI-CONTEXT-END -->
