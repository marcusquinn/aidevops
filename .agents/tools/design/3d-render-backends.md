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

These steps are manual until `blender-render-helper.sh` lands (t19049, GH#38556).

## Provider notes

- **Runpod**: per-second billing, community pods cheapest but less stable;
  stopped pods keep billing storage. Provisioning and Serverless rules:
  `tools/infrastructure/cloud-gpu.md`; media-generation routes: `content/video-runpod.md`.
- **Vast.ai**: lowest list prices; host quality varies, interruptible jobs get
  outbid, bandwidth may be billed per byte. Filter by reliability score.
- **SaladCloud**: consumer RTX at the lowest rates; interruptible by design.
  Only for resumable frame jobs with external storage.
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
- `tools/infrastructure/cloud-gpu.md` — providers, provisioning, billable deployment contract
- `workflows/creative-production.md` — brief, quality mode and acceptance checks
