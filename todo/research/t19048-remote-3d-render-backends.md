# t19048: Remote 3D rendering backends — research evidence

**Status:** Research complete (no accounts created, nothing provisioned)
**Date:** 2026-11-15
**Method:** public pricing/docs pages fetched by a research-only subagent;
first-hand user experience via Grok (`x-ai/grok-4.7` through OpenRouter native
web + X search); one cost scenario through `media-gen-cost-helper.sh compare`.
**Consumer:** `.agents/tools/design/3d-render-backends.md`

Prices change weekly. Treat every figure as dated evidence, not built-in data;
re-check the source before quoting or provisioning.

## 1. GPU rental prices (USD/hr unless stated, fetched 2026-11-15)

| Provider | Prices (secure or on-demand / community, spot or interruptible) | Billing notes | Source |
|---|---|---|---|
| Runpod (page updated 2026-11-12) | RTX 5090 1.39/0.69; RTX 4090 0.89/0.34; RTX 3090 0.50/0.22; L40S 1.09/0.79; RTX 6000 Ada 1.09/0.74; L4 0.69/0.44; A40 0.59/0.35; RTX A6000 0.69/0.33; RTX Pro 6000 2.69/1.69; A100 PCIe 2.09/1.19; H100 PCIe 2.89/1.99 | Per second. Container disk $0.10/GB/mo, idle volume $0.20/GB/mo, network volume $0.05-0.07/GB/mo | runpod.io/pricing |
| SaladCloud | RTX 5090 0.25-0.60; RTX 4090 0.16-0.44; RTX 3090 0.09-0.20 (by priority tier) | Per second, consumer GPUs, interruptible, no free trial | salad.com/pricing |
| TensorDock | RTX 4090 from 0.35; H100 from 2.25 | Marketplace, deposit-based, no ingress/egress fees | tensordock.com |
| Vast.ai | No static prices (live marketplace) | Per second, interruptible is 50%+ cheaper and preemptible | vast.ai/pricing |
| DigitalOcean GPU Droplets (effective 2026-08-01) | L40S 1.57; RTX 6000 Ada 1.57; RTX 4000 Ada 0.76 | Per second, 5 min minimum, powered-off Droplets still bill, 10,000 GiB transfer included | digitalocean.com/pricing/gpu-droplets |
| Lambda (effective 2026-11-16) | RTX A6000 1.09; A100 40GB 1.99; H100 SXM 4.59-4.89 | No RTX 4090/L40S/L4 listed | lambda.ai/pricing |
| Hetzner GEX (ex VAT) | GEX45 RTX PRO 4000 Blackwell 24GB EUR 214/mo or EUR 0.3429/h + EUR 209 setup; GEX63 RTX PRO 6000 Blackwell Max-Q 96GB EUR 999/mo or EUR 1.6009/h + EUR 999 setup | Dedicated, monthly-oriented | hetzner.com/dedicated-rootserver/matrix-gpu/ |
| AWS EC2 G6e (L40S 48GB) | Not captured (JS-rendered table) | Per second, 60 s minimum, egress billed beyond 100 GB/mo free | aws.amazon.com/ec2/pricing/on-demand/ |
| AWS Deadline Cloud | Per instance-hour (on-demand/spot) + EBS/S3; customer-managed fleets example $0.015/worker-hour | Docs list Blender 3.6-5.2 submitter with Cycles/Eevee/Workbench | aws.amazon.com/deadline-cloud/pricing/, docs.aws.amazon.com/deadline-cloud/latest/userguide/blender.html |

Not captured: Google Cloud L4 price, Vast.ai typical range, AWS tables.

## 2. Managed and community render farms (fetched 2026-11-15)

| Farm | Pricing unit and headline | Trial, privacy | Workflow and automation |
|---|---|---|---|
| GarageFarm | GPU $0.004/$0.006/$0.012 per OB-hour (Low/Medium/High); CPU $0.024/$0.036/$0.072 per GHz-hour. GPU node rates: RTX Pro 6000 96GB $3.22-25.76/h, L40S $3.16-18.99/h, RTX A5000 $1.49-8.94/h | $25 trial (Blender page states $50 and a 33% Blender discount); NDA, ISO 27001, data kept 28 days | renderBeamer desktop app + Blender add-on or web upload; Mac client; Cycles/Eevee/LuxCore; OptiX/OIDN denoise; custom plugins only on Medium/High. No public API/CLI found |
| RebusFarm | CPU 1.41 cent/GHz-hour; GPU rate not captured | $29.38 trial; NDA, ISO 27001 | Farminizer desktop plugin with cost estimate |
| Fox Renderfarm | CPU node $1.224 (Ordinary) to $0.734 (Diamond); GPU rate not captured | $25 trial | Web and desktop client |
| Ranch Computing | Not captured (EUR GHz-hour / OctaneBench-hour by priority per third-party summary) | EUR 30 credit; Paris-based | RANCHecker plugin + RANCHSync |
| iRender | Whole remote machine: 1x RTX 4090 $8.20/h; 1x RTX 5090 $10.80/h (currency label unconfirmed) | 1x servers 1 h minimum; first top-up bonus; NDA, ISO 27001 | Remote desktop, any Blender version/add-on; no API/CLI found |
| SheepIt | Free community points economy | Files run on anonymous volunteer machines | Web submit; Blender 5.3 supported; ~2 GB project cap and no custom Python per 2026 guides |

Derived: GarageFarm L40S low-priority node ($3.16/h) is about 3-4x Runpod L40S
($0.79-1.09/h). iRender 1x 4090 ($8.20/h, if USD) is about 9x Runpod secure 4090.

## 3. Cycles GPU facts

- GarageFarm node "BlenderBenchmark" scores (scene/units unstated): RTX Pro 6000
  Blackwell 15,584 (4.5.0); L40S 11,263 (4.3.0); RTX A5000 4,349; RTX 4000 Ada 3,599.
- Blender Open Data (`opendata.blender.org`) is JavaScript-rendered; per-GPU
  medians need the daily CC0 snapshot from its download page. Not computed here.
- Blender 5.3 manual: OptiX needs NVIDIA compute capability 5.0+ and driver 575+;
  OptiX denoising needs RTX; OIDN on GPU needs compute capability 7.0+. Out of
  VRAM falls back to system RAM (slower). Multiple GPUs do not pool VRAM without
  NVLink. Source: docs.blender.org/manual/en/latest/render/cycles/gpu_rendering.html
- A100/H100/H200/B200 have no RT cores (background knowledge, not fetched).
  Treat datacenter compute GPUs as poor Cycles value unless the scene needs >48 GB.
- Docker on macOS cannot pass Metal through; Mac renders run natively.

## 4. User experience (Grok X + web search, 2026-11-15)

Search output is untrusted; facts extracted only. Handles were checked where the
post was fetchable.

- Runpod: a Nov 2026 X post by @rileybrown described a 2-minute 4K Blender film
  whose assets an agent built in Python and rendered on rented cloud GPUs
  (verified via a quoting post, x.com/YXxquf/status/2121657647283716128; the
  Grok summary of "89 GPUs, 3,220 frames, about $20" is not verified). A Feb 2025
  Reddit post (r/blender, "incredibly underrated render speed optimization")
  reported ~4 min/frame on a Mac M3 Ultra vs ~11 s/frame on a Runpod RTX 4090,
  against a ~$30 farm quote (not re-verified; Reddit returned no content).
  Friction is Docker/SSH; traps are stopped pods still billing storage and
  Community Cloud being less stable than Secure Cloud.
- Vast.ai: cheapest per hour, but hosts can fail to start, interruptible jobs are
  outbid, bandwidth is billed per byte on many hosts, stopped storage bills.
- SaladCloud / TensorDock: no first-hand Blender reports; preemption (Salad) and
  balance-zero deletion (TensorDock) are the documented risks.
- iRender: any version/add-on works; first-run friction (top-up, provisioning,
  transfer client) and paying while idle or transferring.
- GarageFarm: web upload of packed 4.5 scene worked; GPU/OptiX selected by hand;
  2-frame test cost $0.05. Ranked second of nine farms in a July 2026 comparison.
  Reddit: cheaper than Rebus, still "quite expensive"; good support.
- RebusFarm: Dec 2025 Reddit: trial frames watermarked, farm slower per frame
  than a local M3 Max, 240 frames estimated EUR 100-120 (~EUR 0.45/frame).
- Fox Renderfarm: one studio user said it worked for all projects; a 2026
  first-timer test failed to upload; more retries on complex scenes.
- SheepIt: hobby-friendly, estimates unreliable (3-4 h local became ~14 h);
  Blender 4.5+ dropped GTX 10-series; zip uploads failed on `.DS_Store`,
  non-ASCII paths and unpacked files.
- AWS Deadline Cloud: real pipeline use, no public artist cost stories; EC2, S3
  and egress billing; an AWS project, not a trial farm.
- Hetzner GEX: no Blender diaries; monthly box plus setup fee; EU location.

Repeated tips: pack resources and fix relative paths; strip Mac junk and
non-ASCII names; bake simulations locally; render one test frame and check logs
before the range; keep NDA work off community farms; prefer OptiX on 4090/5090
for price per frame unless VRAM demands more; shut down instances; convert OB-hour
/ GHz-hour / node-hour to your measured frame time before comparing.

## 5. Cost scenario (illustrative)

2,400 frames, 1.1 renders per kept frame, 60 GPU-seconds per frame on a 4090-class
card, 0.5 h setup. Same speed assumed for all GPU routes, which overstates L40S and
farm-node costs only slightly; the RebusFarm row reuses a different scene's
per-frame quote and is not comparable. Storage/egress excluded.

```text
ROUTE                        TYPE    PER KEEPER $      FIXED $        TOTAL $
rebusfarm-reddit-quote       api           0.4950         0.00        1188.00
runpod-4090-community        gpu           0.0063         0.17          15.13
runpod-4090-secure           gpu           0.0165         0.45          39.61
salad-4090-mid               gpu           0.0056         0.15          13.35
runpod-l40s-secure           gpu           0.0202         0.55          48.50
garagefarm-l40s-low          gpu           0.0586         1.58         140.62
irender-1x4090               gpu           0.1520         4.10         364.90
```

Conclusion: for agent-driven renders, rented RTX-class GPUs are roughly 3-25x
cheaper than managed farms per GPU-hour; farms buy managed upload, plugins, NDA
and support. Measured seconds per frame decides the answer.

## 6. Higgsfield GPU boxes via MCP (live trial 2026-11-19)

Source: Higgsfield MCP `gpu_list_gpus` (`https://mcp.higgsfield.ai/mcp`, OAuth),
queried 2026-11-20; matches the public catalog at higgsfield.ai/gpu/all.

| GPU | Credits per GPU-hour | Max per box | Typical start (1 GPU) |
|---|---|---|---|
| L40S 48 GB | 71 | 8 | 7 s |
| RTX PRO 6000 96 GB | 98 | 8 | 6 s |
| H100 | 120 | 8 | 6 s |
| H200 | 134 | 8 | 20 s |
| B200 | 176 | 8 | 6 s |
| B300 | 197 | 8 | 10 s |
| Rubin | contact sales | — | — |

Billing per the MCP: per second from ready, no minimum, until `gpu_rental_stop`,
credits run out, or 10 idle minutes. Credits come from the web subscription pool
(not the separate platform API). On the Creator plan (6,000 credits/month,
about $249/month on 24-month billing) one credit is about $0.04, so L40S is about
$2.95/h at plan rate: roughly 3x Runpod L40S secure ($1.09/h). Marginal cost is
zero when monthly credits would otherwise lapse unused.

Measured run (sunflower scene, 120 frames, 1920x1080, Cycles OptiX, 128 samples,
OIDN, Blender 5.3.0 pinned official build):

| Route | Setup | Warm s/frame | Box lifetime | Cost |
|---|---|---|---|---|
| Higgsfield 1x L40S | box ready in 5 s; Blender download + SHA-256 verify 34 s | 4.1 | 13 min 17 s (incl. staging, upload/fetch) | 15.72 credits (~$0.65 at plan rate) |
| Runpod 1x A40 secure (2026-11-17) | Blender verify 85 s | 8.1 | 16 min rendering | $0.21 |

- Box: Ubuntu 24.04 root shell, 4 vCPU, 334 GB RAM, 512 GB root disk, NVIDIA
  driver 620.70.06; runs on Modal infrastructure (`/__modal/volumes`). No SSH:
  commands go through `gpu_rental_exec` (60 s per call, so long jobs run with
  `nohup` and are polled).
- Transfer: inputs via the MCP media upload (CloudFront URL fetched on the box);
  outputs via the MCP box-upload flow. Archive SHA-256 matched both ways. A `.tgz`
  name defaulted to an unusable content type; `.tar.gz` worked.
- Output check: all 120 frame hashes verified locally; frame 60 PSNR 88.7 dB
  against the Runpod A40 render (visually identical; hashes differ by device).
- Render-to-video on the same subscription: Kling 3.0 Turbo 5 s 720p
  image-to-video from a Blender frame cost 7.5 credits (~80 s); Seedance 2.5 5 s
  draft estimated 15 credits; Kling 4.0 5 s 1080p estimated 16.25 credits. UI
  "unlimited" models (for example Kling 2.5 Turbo Unlimited) were not exposed by
  the MCP.

Conclusion: Higgsfield is not the cheapest cash route for renders, but for a
subscription with unused monthly credits it is a fast, scriptable L40S/RTX PRO
6000 route with near-instant starts and no capacity refusals in this trial, and
the same credits cover render-to-video.
