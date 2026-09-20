<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18471: Generalize stale local dev server and browser-process diagnostics

## Pre-flight

- [x] Memory recall: `local dev blank page stale server node runtime browser process guidance` → 0 hits; no existing durable lesson covered the combined failure mode.
- [x] Discovery pass: 0 recent target-file commits, 0 merged related PRs, and 0 open related PRs found by `prework-discovery-helper.sh`.
- [x] File refs verified: 4 refs checked; local hosting, Node runtime, frontend debugging, and live Chromium guidance are present at HEAD.
- [x] Tier: `tier:standard` — established diagnostics need coordinated documentation across four progressive-disclosure surfaces.
- [x] Seeded draft PR decision recorded: skipped — the user requested a saved TODO brief, not current implementation.

## Origin

- **Created:** 2026-09-20
- **Session:** OpenCode interactive
- **Created by:** ai-interactive
- **Issue:** GH#32119
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** A local Next.js application returned successful responses and rendered in isolated automation while a real Chromium-family profile remained blank. Process evidence revealed a long-running, high-RSS server using a Node major outside repository policy; a verified runtime-aligned restart recovered the browser. Name-based macOS automation initially inspected a separate headless browser process.

## What

Add a reusable local-development diagnostic pattern for blank or indefinitely loading web applications where server health, browser-profile state, and isolated automation disagree. The guidance must connect frontend verification, local listener ownership, Node runtime policy, stale-process recovery, and multi-process Chromium inspection without depending on any one project.

## Why

HTTP 200, a listening port, and a green isolated browser do not prove a long-running development server or the user's actual browser profile is healthy. A systematic sequence prevents unnecessary source edits, broad cache deletion, accidental interruption of unrelated processes, and false conclusions caused by inspecting an automation browser instead of the user-owned process.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The safety boundary and diagnostic order are known, but concise placement and cross-linking require normal documentation judgment across several specialist references.

## How (Approach)

### Files to Modify

- `EDIT: .agents/tools/ui/frontend-debugging.md` — around lines 22-81, add the divergent-browser/server-health decision path before code attribution.
- `EDIT: .agents/services/hosting/local-hosting.md` — around lines 94-108 and 235-273, add stale-listener evidence and safe restart guidance beside `serve` and troubleshooting.
- `EDIT: .agents/tools/runtime/node-server-admin.md` — around lines 46-81, include declared-runtime/executable/uptime/RSS/request-duration checks for local SSR blank-page incidents.
- `EDIT: .agents/tools/browser/chromium-debug-use.md` — around lines 167-197, add multi-process browser disambiguation and PID/target verification before macOS UI inspection.

### Complete Write Surface

- **Callers/readers:** Build+ routes local hosting, Node runtime, blank frontend, and live Chromium work to the four references above. `browser-automation.md` already points live-session inspection to `chromium-debug-use`; no always-loaded prompt expansion is needed.
- **Writers/mutation paths:** `.agents/tools/ui/frontend-debugging.md`, `.agents/services/hosting/local-hosting.md`, `.agents/tools/runtime/node-server-admin.md`, and `.agents/tools/browser/chromium-debug-use.md` are the only write paths. Do not change localdev launch semantics, process-management scripts, browser profiles, or runtime installers in this task.
- **Existing verification/tests:** `.agents/scripts/linters-local.sh --changed` covers changed guidance; repository link/reference checks remain the applicable validation path.
- **Tests/fixtures:** N/A because this documentation-only task changes no executable behaviour or fixture; `.agents/scripts/linters-local.sh --changed` is the existing documentation check.
- **Schemas/config:** Evidence should read each target repository's `packageManager`, `engines.node`, runtime-version files, and process executable. No framework config schema changes.
- **Generated/deployed mirrors:** Guidance deploys through normal aidevops setup/release; do not edit installed `~/.aidevops` mirrors directly.
- **Migrations/backfills:** N/A because documentation-only work changes no persisted framework, service, or browser state.
- **Cleanup/rollback paths:** N/A because a normal `git revert` removes the documentation-only edits; operational guidance must use the verified supervisor/process group and preserve logs/state for recovery.

### Implementation Steps

1. Add a decision point to frontend debugging: when an isolated browser renders but the user's real profile is blank or indefinitely loading, keep application code, browser state, and server health as separate hypotheses. Verify the real rendered path; do not trust curl alone or assume the isolated result clears the server.
2. Extend local-hosting troubleshooting with a read-only stale-listener baseline: PID, cwd, PPID/PGID/TTY, elapsed time, RSS, executable/runtime, supervisor, bounded logs, and cold/warm request durations. State explicitly that a successful health URL can coexist with requests stalled by a degraded streaming development server.
3. Cross-link Node Server Admin for runtime comparison. Require reading repository runtime policy and verifying the running process executable, not just the interactive shell's `node --version`. Treat extreme uptime/RSS and multi-minute request durations as evidence for investigation, not universal numeric restart thresholds.
4. Define safe recovery: obtain interruption authority, stop the exact verified supervisor/process group gracefully, relaunch through the repository command under its supported runtime, retain accessible logs and a documented stop path, then repeat real-browser and isolated-browser checks. Do not lead with broad site-data deletion, build-cache deletion, dependency reinstall, or source edits.
5. Add Chromium-family multi-process guidance: list browser PIDs and commands before AppleScript/Accessibility automation; distinguish the user profile from headless Playwright or managed debug browsers; target by Unix PID or explicit CDP target. AppleScript/AX may verify focus, title, address, and navigation state but must not be treated as DOM evidence.
6. Document fallback ordering: inspect service-worker/cache state only after runtime-aligned restart evidence; clear only the affected origin when justified; preserve authenticated browser privacy by avoiding body dumps, full-profile exports, traces, or screenshots containing private data.

### Hazards and Compatibility

- **Concurrency/atomicity:** Multiple local sessions and browsers may coexist. Require owner/PID/target verification before restart or UI automation; never kill by process name alone.
- **Migration/rollback:** Documentation-only. Restart guidance must call the repository's supported launcher so any guarded startup/migration contract remains intact.
- **Mixed-version/backward compatibility:** Derive runtime support from the target repository rather than prescribing one Node major globally. Keep macOS-specific process/UI examples labelled and retain Linux/container alternatives.
- **Idempotency/retry:** Read-only inspection is repeatable; restart retries must be bounded and only follow renewed evidence. Origin-specific browser reset must not become a default loop.
- **Partial failure/recovery:** If the supervisor, runtime, or real browser cannot be verified, report the gap and preserve the objective. Do not convert an evidence failure into cache deletion or a wider process kill.

### Verification Before Dispatch

```bash
git diff --check
bash .agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The diff check validates Markdown hygiene; changed-file lint validates documentation structure and internal references. Manually search the changed files for project-specific names before completion.
- **Recovery:** Revert the documentation-only commit. No runtime, browser, service, or credential state should be mutated during implementation.

## Acceptance Criteria

- [ ] A future agent can follow one linked diagnostic sequence from blank real-browser UI through listener/runtime evidence, safe restart, and two-browser verification.
- [ ] The guidance distinguishes the user's Chromium-family process from automation/headless processes and requires PID or CDP-target evidence before making browser-state claims.
- [ ] The reusable guidance contains no project-specific names, domains, local repository paths, fixed PIDs, secrets, or universal memory/uptime restart thresholds.
- [ ] The sequence preserves unrelated browser data and processes, and it does not recommend source edits, broad cache deletion, or dependency reinstall before stale-runtime evidence is resolved.

## Files Scope

- `.agents/tools/ui/frontend-debugging.md`
- `.agents/services/hosting/local-hosting.md`
- `.agents/tools/runtime/node-server-admin.md`
- `.agents/tools/browser/chromium-debug-use.md`
