---
description: Hybrid MCP and computer-use, independent desktops and bounded rendering
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Creative execution environments

## Three separate properties

Headless execution avoids GUI interaction; independent desktop input avoids
competing with the user; OS isolation restricts application privileges. None
proves the others. A Python venv or an MCP-only container is not an app sandbox.

| Route | Input isolation | Limits |
| --- | --- | --- |
| Native API/headless process | Usually no mouse required | GUI effects/modal dialogs remain possible; host privileges remain |
| Linux desktop in container/VM | Independent when app and controller use its display | App/architecture/GPU support must be tested |
| macOS/Windows VM | Separate guest display/input | GPU, audio, plugins and licences vary |
| Separate workstation | Independent host input | Hardware/hosting and authenticated control required |
| Current human desktop | Shared | Explicit cooperative handoff only |

macOS Spaces, virtual monitors and an extra physical screen still share input and
focus. VNC mirroring the physical desktop does too. Control a VM through its own
virtual input channel, not by clicking the VM window with the host mouse.
Do not assume Metal acceleration passes into Linux containers/VMs on a Mac.
Ableton/Archicad are not Linux-native substitutes; verify actual OS/app support.

## Hybrid operation

Prefer supported vendor APIs/SDKs, then a reviewed MCP adapter. A maintained
community adapter may fill vendor gaps. Assess actual operations, source pin,
privacy, dependencies, error/cancellation behaviour and version compatibility;
an official label or an MCP handshake is not sufficient verification.

Inspect state; perform a bounded API/MCP or authorised UI action; read back the
result. Use UI control for an evidenced API gap, not by default. Only one writer
owns a document. Unknown post-mutation results require inspection before retry.
Local GUI options include `tools/browser/peekaboo.md` and `tools/automation/mac.md`;
browser contexts in `tools/browser/browser-automation.md` do not isolate native apps.

A separate desktop must be provisioned with operator approval, app licences,
restricted mounts/network, a known display identity, private screenshots,
authenticated control, cancellation and an owner/cleanup contract. Verify that
the human can type/move their pointer independently before advertising background
GUI support. This guide does not install or certify such a desktop automatically.
Use a silent/virtual audio sink for unattended audio work, not the user's speakers.

## Rendering

Start with bounded local previews; use Blender's Cycles for final ray tracing when
appropriate. Preserve engine/app versions, seed, samples, resolution, cameras,
colour pipeline, textures, fonts and linked assets. Check available GPU/memory and
human workload. Lower concurrency or pause when interactive resource pressure rises.

Remote rendering is a replaceable job backend. Package dependencies, check licence
and privacy permissions, estimate compute/storage/transfer cost, set a hard budget,
and verify cancellation, partial outputs and returned artifact hashes. Do not send
native projects or buy compute merely because local rendering is slower.

[Cycles](https://www.cycles-renderer.org/) also has standalone/Hydra integration,
but ordinary Blender jobs do not require another renderer agent.
[Higgsfield's official demonstration](https://x.com/higgsfield_ai/status/2096284092593758631)
claims Astra scene code, Blender and Cycles on Supercomputer. Arbitrary-job API,
editable-source export, costs and actual availability remain unverified here.
Existing generation APIs are not automatically general GPU/Blender render services.

Use `tools/infrastructure/cloud-gpu.md` and the selected provider's guide only
when such execution is authorised. Render success is not geometric or aesthetic
acceptance; return the checks from `workflows/creative-production.md`.
