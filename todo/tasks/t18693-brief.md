# t18693: Add VideoRouter, Runpod and H3 media-generation provider awareness with cost comparison

## Origin

Interactive maintainer request: add AI media-generation provider awareness for VideoRouter, Kie.ai, GenAIPro, Runway, Runpod (GPU rental, bring-your-own-model, Public Endpoints/Hub) and "H3", plus cost-comparison and need-based recommendations (style, realism, lipsync, motion graphics, editing).

## What

- Add provider agents for VideoRouter (`content/video-videorouter.md`) and Runpod media routes (`content/video-runpod.md`).
- Extend the canonical routing surface `content/media-generation-providers.md` with the new providers, a needs-based recommendation table, a cost-comparison method, and an unverified-candidate entry for GenAIPro.
- Identify "H3" as the MiniMax Hailuo H3 video model family (H3, H3 Max, H3 Fast, H3 Max Turbo, lipsync and camera-control variants) and record where it is available.
- Refresh `content/video-runway.md` with Gen-4.5, Aleph 2, Model Routers and the dev pricing reference.
- Add `scripts/media-gen-cost-helper.sh`: deterministic per-job cost comparison between per-second/per-image APIs and GPU rental (rates supplied by the caller, never hardcoded).

## Why

Kie.ai and Runway exist, but there is no VideoRouter/Runpod media route, no H3 awareness, and no repeatable way to decide between API gateways and rented GPUs as volume changes.

## How (Approach)

### Files to Modify

- NEW: `.agents/content/video-videorouter.md` — model on `.agents/content/video-kie.md` structure
- NEW: `.agents/content/video-runpod.md` — model on `.agents/content/video-kie.md`; link `.agents/tools/infrastructure/cloud-gpu.md`
- NEW: `.agents/scripts/media-gen-cost-helper.sh` — model on existing `*-helper.sh` conventions (`shared-constants.sh`, explicit returns)
- EDIT: `.agents/content/media-generation-providers.md`
- EDIT: `.agents/content/video-runway.md`
- EDIT: `.agents/tools/infrastructure/cloud-gpu.md`
- EDIT: `.agents/content/production-video-01-model-selection.md`
- EDIT: `.agents/content.md`
- EDIT: `.agents/subagent-index.toon` (regenerate via `subagent-index-helper.sh generate`)

### Files Scope

- `.agents/content/video-videorouter.md`
- `.agents/content/video-runpod.md`
- `.agents/scripts/media-gen-cost-helper.sh`
- `.agents/content/media-generation-providers.md`
- `.agents/content/video-runway.md`
- `.agents/tools/infrastructure/cloud-gpu.md`
- `.agents/content/production-video-01-model-selection.md`
- `.agents/content.md`
- `.agents/subagent-index.toon`

## Acceptance Criteria

- Routing doc lists VideoRouter, Runpod (Public Endpoints, Serverless BYO, Pods), GenAIPro (unverified) and H3 with first-party source dates.
- `media-gen-cost-helper.sh compare` prints per-route totals and a break-even volume; ShellCheck clean.
- `verify-agent-discoverability.sh` and markdown lint pass.
