## What

Add `blender-render-helper.sh` that turns the job contract in `.agents/tools/design/3d-render-backends.md` into commands: `plan` (frames, ranges, cost via `media-gen-cost-helper.sh compare`), `package` (manifest of Blender version, engine, device, samples, resolution, packed assets, sha256), `submit` (Runpod pod via `runpodctl`, one range per worker, `blender -b -Y -P enable_gpu.py ... -a`), `status`, `fetch` (download, count and hash frames, skip existing for resume), and `teardown` (stop/remove pods and volumes, then confirm nothing billable remains).

## Why

Research for t19048 (GH#38554) found rented RTX GPUs are 3-25x cheaper per GPU-hour than managed farms for agent-driven Blender renders, but the steps are hand-assembled every time. A first-hand Nov 2026 X post showed an agent renting cloud GPUs to render a Blender film, and replies asked for spend ceilings, retry budgets and idle-worker shutdown. Upcoming 3D modelling work needs this repeatedly.

## How

- NEW: `.agents/scripts/blender-render-helper.sh`; follow `.agents/scripts/media-gen-cost-helper.sh` for argument parsing/help style and source `shared-constants.sh`.
- Require `--budget-usd` and `--deadline-minutes` on `submit`; refuse without them. Print the billable deployment contract from `.agents/tools/infrastructure/cloud-gpu.md` and require `--approve-contract` to match it.
- Default `--dry-run` printing the exact `runpodctl` and `blender` commands; live mode needs `RUNPOD_API_KEY` via `aidevops secret RUNPOD_API_KEY -- ...`.
- Provider adapter function boundary so Vast.ai/SaladCloud can be added later.
- EDIT: `.agents/tools/design/3d-render-backends.md` — replace manual steps with helper usage.

## Acceptance

- `shellcheck` zero violations; Bash 3.2 compatible; every function has explicit returns.
- `blender-render-helper.sh plan` and `submit --dry-run` produce correct commands and cost output without network access.
- Live verification is operator-owned (needs a Runpod account and spend approval); note this in the PR rather than skipping silently.

## Files Scope

- .agents/scripts/blender-render-helper.sh
- .agents/tools/design/3d-render-backends.md
