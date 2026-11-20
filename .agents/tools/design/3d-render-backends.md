---
description: Remote 3D rendering playbook - choose, cost and run Blender Cycles/Eevee renders on rented GPUs, managed render farms or local Metal
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Remote 3D rendering backends

<!-- AI-CONTEXT-START -->

Use when a Blender (Cycles/Eevee) render is too slow or too large for the local
machine. A remote backend is a replaceable job runner: the editable scene, its
parameters and acceptance checks stay in Git (`workflows/creative-production.md`).

1. **Measure first.** Render one representative frame locally at final settings
   and record seconds/frame, peak memory, samples, resolution and Blender version.
2. **Choose a route** from the decision table, then estimate cost with
   `media-gen-cost-helper.sh compare` (frames as assets).
3. **Get approval** for the route, budget ceiling and data handling. Rented GPUs
   also need the billable deployment contract in `tools/infrastructure/cloud-gpu.md`.
4. **Run the job contract** below: pack, bake, pin, test frame, range, verify, tear down.

Evidence, dated prices and sources: `todo/research/t19048-remote-3d-render-backends.md`.
Never quote a price older than 30 days without re-checking the provider page.

<!-- AI-CONTEXT-END -->

## Decision table

| Route | Use when | Avoid when |
|-------|----------|------------|
| **Local Mac (Metal)** | Previews, look-dev, short ranges, private scenes | Deadline needs >1 machine-night, or scene exceeds unified memory |
| **Rented GPU, DIY** (Runpod, Vast.ai, SaladCloud, TensorDock) | Agent-driven batches, cheapest per frame, exact Blender/add-on pinning, parallel frame ranges | Nobody can own SSH/container setup, or scene relies on GUI-only add-ons |
| **Subscription-credit GPU** (Higgsfield via MCP) | Plan has unused monthly credits; want fast L40S/RTX PRO 6000 starts and render-to-video on the same credits | Paying cash for credits (about 3x Runpod per GPU-hour), or a job needs SSH/rsync |
| **Managed farm** (GarageFarm, RebusFarm, Fox, Ranch) | Client/NDA work wanting plugin upload, scene checks, support, ISO 27001 | Automation is required (no public API/CLI found), or budget is tight |
| **Remote workstation** (iRender) | Need a full Windows GPU desktop with arbitrary add-ons | Batch automation; per-hour rates are high and idle time bills |
| **Community farm** (SheepIt) | Free hobby renders with no deadline | Confidential, commercial NDA, custom Python, >2 GB projects |
| **Dedicated monthly** (Hetzner GEX) | Sustained renders most days of the month, EU data location | Bursty work; monthly fee and setup fee dominate |
| **Managed AWS pipeline** (Deadline Cloud) | Studio pipeline already on AWS, need queues/budgets/audit | One-off jobs; setup effort is an AWS project |

Rule of thumb from 2026-11 evidence: rented RTX-class GPUs cost roughly 3-25x
less per GPU-hour than managed farm nodes. Farms buy managed upload, plugin
support, NDA and humans; pick them for those reasons, not speed.

## GPU selection for Cycles

- Prefer **RTX consumer/workstation cards** (RTX 5090/4090, L40S, RTX 6000 Ada,
  RTX Pro 6000): RT cores make OptiX the fastest Cycles backend.
- **A100/H100/H200/B200 have no RT cores**; they are poor value for Cycles. Use
  only when a scene genuinely needs their VRAM, and benchmark OptiX vs CUDA.
- **VRAM is the hard limit.** 24 GB (4090/3090/L4) suits most scenes; 32 GB
  (5090); 48 GB (L40S/A6000/6000 Ada); 96 GB (RTX Pro 6000). Overflow falls back
  to system RAM (much slower). Multiple GPUs do not pool VRAM without NVLink, so
  split by frame across GPUs rather than buying a bigger multi-GPU node.
- **Denoising:** OptiX denoiser needs RTX; OIDN on GPU needs compute capability 7.0+.
- **Eevee** needs an OpenGL/Vulkan-capable display stack; headless servers may
  require EGL support. Test one Eevee frame before committing a range.
- Mac: Docker cannot use Metal. Local renders run in native Blender.

## Cost method

Treat each frame as an asset. Measure GPU-seconds per frame on the target GPU
class (one test frame on the rented GPU, not a Mac estimate):

```bash
media-gen-cost-helper.sh compare --clips <frames> --takes 1.1 \
  --gpu "runpod-4090-community=<hourly>" --gpu "runpod-4090-secure=<hourly>" \
  --gpu "salad-4090=<hourly>" --gpu "farm-node=<hourly>" \
  --api "farm-quote=<price-per-frame>:asset" \
  --gpu-secs-per-clip <measured> --setup-hours 0.5
```

The helper uses one seconds-per-frame value for all `--gpu` routes; run it once
per GPU class when speeds differ. Add storage, egress and idle time separately.
Convert farm units (OB-hour, GHz-hour, node-hour) into your measured frame time
before comparing sticker prices; use the farm's own estimator when available.

## Job contract

1. **Package.** Work on a copy. `File > External Data > Pack Resources` or make
   paths relative and ship the folder. Remove `.DS_Store`, non-ASCII file names
   and unused data. Record linked libraries and textures in the job manifest.
2. **Bake.** Bake fluid/cloth/smoke/particles and Geometry Nodes simulations
   locally; ship caches. Farms and fresh containers will not rerun physics identically.
3. **Pin.** Record Blender version (exact build), render engine, device, samples,
   seed, resolution, colour management, denoiser and add-ons with licences.
   Commercial add-ons need a licence on the remote machine.
4. **Untrusted Python.** Render with `-Y` (disable auto-run scripts) unless the
   scene's drivers require Python and the file is trusted.
5. **Test frame.** Render one frame remotely, download it, compare with the local
   frame, and read the log for missing textures, CPU fallback or out-of-memory.
6. **Range.** Split frames across workers by contiguous ranges; write to unique
   per-frame paths with overwrite off. Spot/community instances can stop: make
   jobs resumable by skipping existing frames.
7. **Budget and cancel.** Set a hard spend ceiling and a wall-clock deadline;
   confirm you can stop every worker. Use auto-stop or the idle shutdown in
   `cloud-gpu.md`.
8. **Verify.** Count frames, check sizes and hashes, spot-check images, then
   assemble. Render success is not aesthetic or geometric acceptance.
9. **Tear down.** Stop and remove pods/instances and volumes; confirm no
   billable resource remains. Delete uploaded scenes where the provider allows.

## Headless Blender on a rented GPU

Use the official Linux tarball of the pinned Blender version on an NVIDIA CUDA
base image (Runpod/Vast.ai/Salad accept custom images). Community Blender images
exist; verify maintenance and version before relying on one.

Enable GPU devices with a short script (`enable_gpu.py`):

```python
import bpy

prefs = bpy.context.preferences.addons["cycles"].preferences
prefs.compute_device_type = "OPTIX"  # "CUDA" for non-RTX or comparison
prefs.get_devices()
for device in prefs.devices:
    device.use = device.type != "CPU"
bpy.context.scene.cycles.device = "GPU"
```

Arguments run in order, so set output and range before `-a`:

```bash
blender -b scene.blend -Y -P enable_gpu.py -E CYCLES \
  -o //frames/frame_#### -F PNG -s 1 -e 250 -a
```

Blender 3.0+ also accepts `-- --cycles-device OPTIX` after the frame flags.
Check the log for the chosen device; a silent CPU fallback is the most common
cause of slow, expensive remote renders.

## Helper: `blender-render-helper.sh` (Runpod)

`scripts/blender-render-helper.sh` runs the job contract on Runpod. Every
command prints its `runpodctl`/`rsync`/`ssh` calls and does nothing until
`--live`; live mode needs `RUNPOD_API_KEY`
(`aidevops secret RUNPOD_API_KEY -- blender-render-helper.sh <cmd> --live`).
Providers sit behind `_brh_provider_call`; Vast.ai and SaladCloud adapters are not
implemented.

```bash
H=~/.aidevops/agents/scripts/blender-render-helper.sh
# 1. Estimate (calls media-gen-cost-helper.sh; setup hours are per worker)
$H plan --frames 1-240 --workers 4 --gpu-rate <hourly> --gpu-secs-per-frame <measured> --setup-hours 0.25
# 2. Package: manifest.json, enable_gpu.py, scene_overrides.py (settings + Blender pin),
#    render_worker.sh, file hashes. --blender-sha256 (Blender's published hash of
#    blender-<X.Y.Z>-linux-x64.tar.xz) makes workers install the pinned official build
#    and verify it, so any CUDA image works (e.g. runpod/pytorch)
$H package --blend scene.blend --out job/ --frames 1-240 --blender-version 5.3.0 \
  --blender-sha256 <published-sha256> --samples 128 --asset textures/wood.png
# 3. Submit: prints the billable contract and an approval token; re-run with the token after approval
$H submit --manifest job/manifest.json --workers 4 --gpu-rate <hourly-for-cloud-type> --budget-usd <ceiling> \
  --deadline-minutes <minutes> --cloud-type COMMUNITY --image runpod/pytorch:<tag> --approve-contract <token> --live
# 4. Per pod (host/port from status): stage inputs, monitor (BRH_ log lines), fetch (re-runs resume)
$H stage --job job/ --host <pod-ip> --port <ssh-port> --live
$H status --job job/ --live
$H fetch --job job/ --host <pod-ip> --port <ssh-port> --live
# 5. Tear down and confirm nothing billable remains
$H teardown --job job/ --live
```

Guardrails: `submit` refuses without `--budget-usd`, `--deadline-minutes`, `--image`
and a matching token. The worst case, workers × rate × (deadline + `--fetch-minutes`
(default 10) + `--overhead-minutes` (default 15)) + `--storage-usd`, must fit the
budget. The token covers the manifest hash (scene, assets, Blender pin and SHA256,
worker script), the image, GPU, `--cloud-type` (default SECURE, runpodctl's
default, so quote that rate) and the time limits. Changed scene, asset or worker
files are refused.

Pod lifecycle:
- Each pod starts the image's `/start.sh` (sshd) and waits for `stage`.
- Under the deadline `timeout`, it runs `render_worker.sh`, which installs and
  verifies Blender when packaged with a SHA256, checks the pin and renders.
- It then writes `.rendered` and waits up to `--fetch-minutes`.
- A `fetch` that starts after `.rendered` releases the pod, which then tries to
  delete itself. In every 2026-11-17 live run the pod ended `EXITED` but not
  deleted, and a stopped pod can still bill storage, so always run `teardown --live`.

GPU fallback lists: one approved budget can cover several GPU/cloud options tried in
order (for example RTX 4090 community, then A40 secure, then RTX 4090 secure).
Give each option its own `--deadline-minutes` from its expected speed, and set its
`--budget-usd` to the approved cap minus any spend already incurred, so the total
cannot exceed the cap. Before trying the next option, check `jobs.tsv` and
`status --live`: with several workers, a refusal can follow pods that were already
created and are billing. Fetch their frames, or accept the loss with
`teardown --live --force-discard`, and tear them down first. A single-worker refusal
creates nothing.

`stage` copies without owner or group (`rsync -rtL`). SECURE pods mount `/workspace`
on MooseFS (FUSE), where `rsync -a` fails to `chown` (exit 23). `-L` sends symlinked
inputs as their target contents.

`status --live` prints each pod's `BRH_STAGE`/`BRH_GPU`/`BRH_RESULT`/`BRH_FAIL` log
lines, so progress needs no SSH. Community pods do not guarantee a public port 22,
and `stage`/`fetch` need one, so check `status` before staging. A no-capacity
refusal creates nothing and is retried 3 times (`BRH_CAPACITY_RETRIES`,
`BRH_CAPACITY_RETRY_SECS`); after that, retry later or approve a new contract.

`fetch` lists missing frame numbers and writes `frames/SHA256SUMS`. `teardown --live`
refuses while frames are missing (`--force-discard` overrides) and fails if pods
remain listed. The rate is the quoted rate: confirm it in `status`. Network volumes
created outside the helper need a dashboard check. Live verification needs a Runpod
account and spend approval and is operator-owned.

Measured on 2026-11-17 (smoke scene, 960×540, 128 samples):
- Runpod RTX 4090 community: Blender 5.3.0 download, checksum and extract in 120 s,
  then OptiX render in 1.7 s, for about $0.02 in total.
- Runpod A40 secure ($0.59/hr), full helper flow (`submit` → `stage` → `fetch` →
  `teardown`): created on the 3rd capacity attempt (RTX 4090 and 3090 were refused
  on both tiers); Blender 5.3.0 verified in 85 s; OptiX render at 64 samples in
  under 2 s; pod lived about 4 minutes, roughly $0.04.
- SaladCloud RTX 3090 low priority: Blender installed in 30 s; CUDA render in 1.4 s
  (OptiX is unavailable there, see `tools/infrastructure/saladcloud.md`).
- Local M3 Max Metal: 1.8 s warm, but 280 s on the first run, which compiles the
  Metal kernels.

Measured on 2026-11-17 (animated sunflower scenes, 120 frames, 1920×1080, 128 samples,
OIDN, Runpod A40 secure at $0.59/hr; RTX 4090 community was refused on every attempt):
- Simple scene (142 objects): 10 s/frame on the A40 against 8.1 s on an M3 Max;
  21 minutes of rendering, $0.22 in total.
- Richer scene (about 110k triangles, translucent petals, depth of field): 8.1 s/frame
  warm on the A40, against a 20-31 s cold single frame on the M3 Max; 16 minutes of
  rendering, $0.21 in total.
- After `fetch` released each pod, SSH was refused within a minute, so pod internals
  (for example whether the image has `runpodctl` for self-delete) must be checked
  before `fetch`.
- So one A40 is about as fast as an M3 Max for these scenes. It pays off by running
  in parallel or by freeing the Mac. Prefer an RTX 4090/5090 when capacity allows.
  Estimate from warm timing (`tools/design/blender-scripted-scenes.md`).

Measured on 2026-11-19 (same richer sunflower scene, Higgsfield 1x L40S at
71 credits/h via MCP): box ready in 5 s, Blender 5.3.0 verified in 34 s, 4.1 s/frame
warm (about 2x the A40), 13 minutes of box time, 15.72 credits in total. Details:
`todo/research/t19048-remote-3d-render-backends.md` section 6.

Image hashes vary between runs and devices, so compare renders by eye or with a
tolerance (PSNR), not by hash.

## Provider notes

- **Runpod**: per-second billing, community pods cheapest but less stable;
  stopped pods keep billing storage. Script with `runpodctl` (`pod create
  --wait`, resumable `network-volume upload/download` for scenes and frames);
  inspect interactively with the on-demand `@runpod` MCP. Guide:
  `tools/infrastructure/runpod.md`; provisioning and Serverless rules:
  `tools/infrastructure/cloud-gpu.md`; media-generation routes: `content/video-runpod.md`.
- **Higgsfield GPU** (`content/video-higgsfield.md` "MCP"): L40S to B300 boxes billed
  per second in web-subscription credits through the OAuth MCP; 10-minute idle
  auto-stop. No SSH: run the job contract through `gpu_rental_exec` (60 s per
  call, so start the worker with `nohup` and poll its log), move files through
  MCP media uploads, check SHA-256 both ways, then `gpu_rental_stop` and confirm
  `gpu_my scope=live` is empty. No provider-enforced total spend limit was
  found (`max_credits_per_hour` caps the rate only), and the box cannot call
  `gpu_rental_stop` on itself. Bound spend with a deadline on the box: start the
  worker as `nohup timeout <deadline> bash render_worker.sh ...`, so the box goes
  idle when the deadline passes and the idle auto-stop ends it. Worst case is
  rate × (staging + deadline + 10 idle minutes + fetch); size the deadline so
  that fits the ceiling. "Idle" was not verified to ignore status polls, so
  still watch `credits_spent` and call `gpu_rental_stop` as soon as frames are
  fetched. Without that on-box deadline this route cannot guarantee the ceiling.
- **Vast.ai**: lowest list prices; host quality varies, interruptible jobs get
  outbid, bandwidth may be billed per byte. Filter by reliability score.
- **SaladCloud**: consumer RTX at the lowest rates; interruptible by design.
  Only for resumable frame jobs with external storage; feed frame ranges
  through a job queue. `saladcloud` CLI guide: `tools/infrastructure/saladcloud.md`.
- **TensorDock**: full VMs (including Windows), no egress fees; servers are
  deleted when balance reaches zero.
- **DigitalOcean**: L40S/RTX 6000 Ada Droplets, 5-minute minimum; powered-off
  Droplets still bill.
- **GarageFarm**: Blender add-on/renderBeamer and web upload; priority tiers set
  price and node count; OptiX selected manually; strong support reputation.
- **RebusFarm / Fox / Ranch**: plugin-based managed farms with trials; check
  watermarking of trial frames and per-scene estimates before paying.
- **iRender**: whole remote machine with any add-ons; first-run friction and
  idle billing.
- **SheepIt**: free, public volunteers; never for NDA work.
- **Hetzner GEX / AWS Deadline Cloud**: sustained or pipeline workloads only.

## Related

- `tools/design/creative-execution.md` — local vs remote execution requirements
- `tools/design/blender.md` — Blender Lab MCP and scene inspection
- `tools/design/blender-scripted-scenes.md` — script-built scenes, loops, warm timing, delegated modelling
- `tools/infrastructure/cloud-gpu.md` — providers, provisioning, billable deployment contract
- `workflows/creative-production.md` — brief, quality mode and acceptance checks
