---
description: Manually dispatch a worker against a single GitHub issue (smoke-test the pulse dispatch path).
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Args: `$ARGUMENTS` — `<issue_number> <owner/repo> [--model <id>] [--dry-run]`

Use the issue's `tier:simple`, `tier:standard`, or `tier:thinking` label for
normal routing. `--model` is an advanced compatibility override for operators
who must pin an exact runtime model ID.

## What this does

Bypasses the pulse loop and launches one worker against one issue. The same
worker shape the pulse uses (`headless-runtime-helper.sh run --detach`
producing a `/full-loop` prompt), without:

- Capacity checks
- Throttle / adaptive cadence
- Multi-issue scanning
- Pulse-cycle ledger sweeps

Use this for **smoke-testing**, **debugging dispatch failures**, **brief
worker-readiness validation**, or **manual retries** after fixing an upstream
issue. NOT a replacement for the pulse — the pulse handles concerns this
helper deliberately does not.

## Resolution and execution

1. Resolve `$ARGUMENTS` into `<issue_number>` (numeric) and `<owner/repo>`.
   - If `--repo` is omitted in user prose, default to the current repo's
     `slug` from `~/.config/aidevops/repos.json`.
2. Pre-flight (always, even with `--dry-run`):
   - Issue must exist + be `OPEN`.
   - Reject `needs-maintainer-review` issues; use
     `sudo aidevops approve issue <issue_number> <owner/repo>` or record an
     equivalent maintainer decision before any manual worker dispatch.
   - Reject `parent-task` issues with a clear "use a phase child" message.
3. Dedup pre-check via `dispatch-dedup-helper.sh is-assigned`.
   - Exit 0 (active claim) → real dispatch blocks, exit 0 with explanation.
   - Exit 1 (free) → dispatch proceeds.
   - Other exit code (helper missing, network error, etc.) → fail closed,
     refuse to dispatch, exit 1.
   - Dry-run: surface all three states as info, still print the planned dispatch.
4. Resolve tier/model (mirrors `pulse-model-routing.sh::resolve_dispatch_model_for_labels`):
   - Tier labels request workload complexity: `tier:simple`, `tier:standard`,
     or `tier:thinking`. Default = `standard`.
   - Runtime routing chooses the preferred available provider, model, and
     reasoning level for that workload tier.
   - `--model <id>` wins only when an operator intentionally uses the advanced
     compatibility override to pin an exact runtime model ID.
   - **Known divergence from pulse (t2839):** the pulse applies a dispatch-path
     safety net (t2819) that auto-elevates issues touching self-hosting files
     (pulse-wrapper.sh, headless-runtime-helper.sh, etc.) to `thinking`. This
     CLI does NOT apply that check — it would require parsing the issue body and
     brief file scope. If you're manually dispatching a dispatch-path issue,
     apply the `tier:thinking` label before dispatch so runtime routing can
     select the preferred available provider, model, and reasoning level.
5. Dispatch (real path):
   - Pre-create worktree via `worktree-helper.sh add` (`auto-<ts>-gh<N>`),
     resolve actual path back from `git worktree list` (worktree-helper has
     its own slug logic — recomputing it is fragile).
   - Launch detached worker with prompt
     `/full-loop Implement issue #<N> (<url>)` — `headless-runtime-lib`
     auto-appends `HEADLESS_CONTINUATION_CONTRACT_V6`.
   - Poll worker log for the `Dispatched PID:` line printed by
     `headless-runtime-helper.sh::_detach_worker` (timeout 3s) to extract
     the real worker PID, not the short-lived launch wrapper.
   - Register dispatch in ledger with the real worker PID so subsequent
     `status` and pulse dedup-layer-1 checks see a live process.
   - Print PID, log path, session key.
6. Status check (anytime): `dispatch-issue status <N> <slug>` reports the
   active dispatch ledger entry, including PID liveness.

## Direct invocation

```bash
# Smoke-test (preview only, no worker launched)
dispatch-single-issue-helper.sh dispatch 20882 marcusquinn/aidevops --dry-run

# Real dispatch — tier inferred from the issue's tier:* label
dispatch-single-issue-helper.sh dispatch 20882 marcusquinn/aidevops

# Recommended for complex work: apply tier:thinking to the issue, then dispatch
dispatch-single-issue-helper.sh dispatch 20882 marcusquinn/aidevops

# Check active dispatch state
dispatch-single-issue-helper.sh status 20882 marcusquinn/aidevops
```

## When to choose this over the pulse

- **Pulse hasn't reached this issue yet** and you want to verify the brief.
- **Pulse keeps skipping** the issue (dedup, capacity, label gates) and you
  want to see *why* without scanning logs.
- **You fixed a dispatch-path bug** and want to validate the end-to-end
  worker spawn before letting the pulse cycle catch up.
- **You're debugging worker-side behaviour** and need a controlled, single
  worker (not "whatever the pulse picks next").

## Exit codes

- `0` — Worker launched, dry-run completed, or skipped due to active claim.
- `1` — Validation failure (issue not found, closed, parent-task, etc.).
- `2` — Invalid subcommand or missing required argument.

## Related

- `pulse-dispatch-engine.sh` — what the pulse does on every cycle (this CLI
  mirrors the worker-launch shape but skips dedup ceremony layers).
- `dispatch-dedup-helper.sh is-assigned` — the gate this CLI consults.
- `headless-runtime-helper.sh run --detach` — the actual worker spawner.
- `dispatch-ledger-helper.sh check-issue` — what `status` reads from.
