## What

Document the Higgsfield MCP (subscription-credit route) and Higgsfield GPU boxes as a Blender render backend, using evidence from the live trial on 2026-11-19.

## Why

Higgsfield's MCP (`https://mcp.higgsfield.ai/mcp`, OAuth) bills the web subscription credits, not the separate platform API, and exposes scriptable GPU rental (`gpu_rent` / `gpu_rental_exec` / `gpu_rental_stop`). For accounts holding unused monthly credits this is the cheapest render route, and render-to-video (image-to-video from a Blender frame) works headless. Current docs only cover the platform API and the Playwright UI automator.

## Evidence (live trial 2026-11-19)

- 120-frame 1920x1080 Cycles OptiX 128-sample sunflower scene on 1x L40S: Blender 5.3.0 verified in 34 s, ~4.1 s/frame warm, box lifetime 13 min 17 s, 15.72 credits; frames hash-verified locally; PSNR 88.7 dB vs the Runpod A40 render of the same frame.
- Runpod A40 secure, same scene (2026-11-17): 8.1 s/frame, $0.21.
- Kling 3.0 Turbo 5 s 720p image-to-video from a Blender frame: 7.5 credits, ~80 s.

### Files Scope

- todo/research/t19048-remote-3d-render-backends.md
- .agents/tools/design/3d-render-backends.md
- .agents/content/video-higgsfield.md
- .agents/content/media-generation-providers.md

## How

Add dated Higgsfield GPU prices and the measured run to the research note; add a decision-table row and provider note in the render playbook; add an "MCP (subscription credits)" section to the Higgsfield doc; note the third billing route in the provider table.

## Acceptance

- Prices dated and sourced to the MCP `gpu_list_gpus` output and the public catalog.
- Docs state that the MCP uses subscription credits, OAuth via `mcporter auth`, and that UI-only unlimited models are not exposed via MCP.
- markdownlint passes on changed files.
