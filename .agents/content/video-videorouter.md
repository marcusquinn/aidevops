---
description: VideoRouter price-routed media API across Fal, WaveSpeed, Atlas Cloud, Replicate, Novita, Kie.ai and closed hosts, plus real-time world models
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

# VideoRouter Media API

<!-- AI-CONTEXT-START -->

## Scope

Use VideoRouter when one upstream model (for example MiniMax H3, Seedance,
Wan, Kling, Veo) is served by several hosts and the job should land on the
cheapest healthy host with automatic failover, behind one key and one bill.
It also exposes real-time world-model, live-edit and live-avatar sessions.

Choose the provider first in `content/media-generation-providers.md`. Prefer a
direct provider when the brief requires its SDK, support contract, data terms
or provider-only parameters. VideoRouter adds a 2.5% fee on top of the routed
host's list price; it is cheaper only when the routed host undercuts the
alternative by more than that.

## Quick Reference

- **Base URL**: `https://videorouter.sh/api/v1` (OpenAI-SDK compatible base URL)
- **Auth**: `Authorization: Bearer $VIDEOROUTER_API_KEY` (keys look like `llmr_sk_live_…`)
- **Video**: `POST /videos` creates an async job; poll `GET /videos/{id}`
  (`pending` → `in_progress` → `completed` with `url`). Billed per requested
  second at creation; polling is free.
- **Image**: `POST /images` is synchronous; edits pass `input_references`.
- **Catalog**: `GET /models` (live); browse `https://videorouter.sh/models`.
- **Model IDs**: `creator/model` routes to the cheapest healthy host;
  `creator/model/host` (e.g. `minimax/h3/fal`) prefers one host and still fails
  over. Video/image have **no** auto-router — always name a model.
- **Pricing**: provider list price + flat 2.5% fee, prepaid credits, per-key
  spend caps. Units pass through (per second, per token, per image, per MP).
- **Errors**: `401` key, `402` credit/spend cap, `429` rate limit with
  `Retry-After`. Retryable upstream failures fail over before surfacing.
- **Extras**: lip sync, face swap, motion control, upscaling, extension, 3D,
  TTS/STT, music, Batch API, Flex Mode, ComfyUI nodes, live-video SDKs
  (`videorouter-live` for JS; Python SDK documented).

<!-- AI-CONTEXT-END -->

## Setup

```bash
aidevops secret set VIDEOROUTER_API_KEY
```

Top up prepaid credits and set a per-key monthly spend cap in the dashboard
before any batch. There is no aidevops helper yet; use `curl` or the OpenAI SDK
with `base_url="https://videorouter.sh/api/v1"`.

## Minimal Request Pattern

```bash
# Create (async). Duration drives billing, so set it deliberately.
curl -s https://videorouter.sh/api/v1/videos \
  -H "Authorization: Bearer $VIDEOROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"minimax/h3","prompt":"Slow dolly-in on a ceramic mug, morning light","duration_secs":6}'

# Poll with bounded backoff; persist the job id for recovery
curl -s https://videorouter.sh/api/v1/videos/VIDEO_ID \
  -H "Authorization: Bearer $VIDEOROUTER_API_KEY"
```

Copy model-specific fields (resolution, references, audio, camera controls)
from the model's page or `GET /models`; do not translate parameter names from
Kie.ai, Fal or Runway.

## When It Wins

| Situation | Why VideoRouter |
|-----------|-----------------|
| Open-weight or multi-host model (H3, Wan, Seedance, LTX, Kling) at volume | Live cheapest-host routing; per-host price differences are often far larger than 2.5% |
| Need uptime across flaky hosts | Ordered host failover inside one model id |
| Comparing hosts before committing | Catalog shows each host's price, latency and benchmark quality per model |
| Real-time world models, live restyle/try-on, live avatars | Decart Lucy, Odyssey, Vidu S2 sessions billed per second |
| `-unrestricted` model variants | Listed separately; confirm the brief's content policy and platform rules before use |

## When to Go Elsewhere

- Single closed model with first-party features (Runway Aleph/Gen-4.5, Veo
  ingredients, Sora remix): use the direct provider or its official gateway.
- Media cannot leave controlled infrastructure: Runpod Serverless with your
  own container (`content/video-runpod.md`) or local ComfyUI.
- One credit pool already funded on Kie.ai/MuAPI/WaveSpeed and the model is
  priced the same there: avoid the extra 2.5%.

## Safety

- Check `https://videorouter.sh/docs/data-privacy` before uploading client or
  personal media; routed hosts differ in retention.
- Download results immediately; treat returned URLs as temporary.
- Never run paid generations to test integration; estimate first with
  `media-gen-cost-helper.sh`.

## First-Party References

- [Quickstart](https://videorouter.sh/docs/quickstart)
- [Pricing](https://videorouter.sh/pricing)
- [Provider selection](https://videorouter.sh/docs/provider-selection)
- [Live video & world models](https://videorouter.sh/docs/live-video)
- [Errors & rate limits](https://videorouter.sh/docs/errors-rate-limits)

Facts verified 2026-10-14 from the pages above. Re-check pricing and catalog
before quoting numbers.

## Related

- `content/media-generation-providers.md` - provider-selection source of truth
- `content/video-kie.md` - Kie.ai Market API (also a VideoRouter upstream)
- `content/video-wavespeed.md` - WaveSpeed direct
- `content/video-runpod.md` - Runpod Public Endpoints and bring-your-own-model GPUs
