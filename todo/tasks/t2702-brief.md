---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2702: disable r912 dashboard routine — server/index.ts never shipped

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `r912 dashboard server` → 0 hits — no relevant prior lessons
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch `server/` in last 48h — `server/index.ts` has never existed in the repo
- [x] File refs verified: `.agents/scripts/routines/core-routines.sh:30` (r912 pipe entry), `:611-652` (describe_r912) — both present at HEAD
- [x] Tier: `tier:simple` — 1 file, 1-character edit (`x` → ` `), verbatim oldString/newString provided, no judgment calls

## Origin

- **Created:** 2026-04-21
- **Session:** Claude Code CLI interactive (continuation of t2700)
- **Created by:** marcusquinn (human, via ai-interactive)
- **Parent task:** none (sibling of t2700, both address GH#20315)
- **Conversation context:** robstiles filed GH#20315 reporting four routines fail every pulse cycle. PR #20334 (t2700) fixed r902/r906/r910 with wrapper shims. r912 is a different problem — the dashboard was never finished, `server/index.ts` does not exist anywhere in the repo or deployed tree, and shipping a web server is out of scope for a routine-fix task. Disable is the conservative path.

## What

After this change, the routine entry for r912 in `.agents/scripts/routines/core-routines.sh` has its enabled flag flipped from `x` (enabled) to ` ` (disabled). The pulse dispatcher skips disabled routines, so the repeating `[pulse-wrapper] routine r912: script not found or not executable: …/server/index.ts` log lines stop.

The describe function (`describe_r912`) and pipe entry remain in the file as a forward-compatible placeholder — future work that ships an actual dashboard server can flip the flag back without rewriting the entry.

## Why

GH#20315 reported r912 pointing at `server/index.ts`. Discovery confirms:

- No `.agents/server/` directory exists anywhere in the repo tree.
- No `server/index.ts` file exists (search scope: full repo tree + deployed `~/.aidevops/agents/`).
- The `~/.aidevops/bin/aidevops-dashboard` symlink target `/Users/marcusquinn/Git/aidevops-dashboard/` is STALE/BROKEN — the directory does not exist.
- `describe_r912` describes the routine as "Persistent web dashboard providing a real-time view of aidevops operations" — type `service`. Aspirational, never shipped.

The routine therefore runs every pulse cycle, fails at the `[[ -x "$script_path" ]]` check in `pulse-routines.sh:110`, and logs a "script not found" error. It has never successfully run on any install. Disabling eliminates the noise without committing to ship the dashboard.

## Tier

### Tier checklist

- [x] 2 or fewer files to modify? **Yes** — 1 file (`core-routines.sh`)
- [x] Every target file under 500 lines? **No** — `core-routines.sh` is 814 lines, BUT verbatim oldString/newString provided, so the 500-line disqualifier does not apply (`reference/task-taxonomy.md` rule)
- [x] Exact `oldString`/`newString` for every edit? **Yes** (see Implementation Steps)
- [x] No judgment or design decisions? **Yes** — disable is the explicitly chosen path; alternatives (remove entry entirely, ship dashboard) are out of scope
- [x] No error handling or fallback logic to design? **Yes**
- [x] No cross-package or cross-module changes? **Yes**
- [x] Estimate 1h or less? **Yes** — ~5 minutes
- [x] 4 or fewer acceptance criteria? **Yes** — 3 criteria

**Selected tier:** `tier:simple`

**Tier rationale:** single-file, 1-character edit with verbatim oldString/newString. No judgment, no design. Cleanest possible simple-tier task.

## PR Conventions

GH#20315 is a leaf issue (no `parent-task` label). The PR body uses `Resolves #<this-issue>` for the t2702 issue, NOT `Resolves #20315` (t2700 already resolves that).

## How (Approach)

### Worker Quick-Start

Not needed — single-character edit.

### Files to Modify

- `EDIT: .agents/scripts/routines/core-routines.sh:30` — flip enabled flag from `x` to ` ` (space)

### Implementation Steps

1. **Flip the r912 enabled flag** in `.agents/scripts/routines/core-routines.sh`. Exact replacement:

```text
oldString:
r912|x|Dashboard server|repeat:persistent|~0s|server/index.ts|service

newString:
r912| |Dashboard server|repeat:persistent|~0s|server/index.ts|service
```

That is: replace the literal `|x|` immediately after `r912` with `| |` (pipe, space, pipe). No other edits needed. `describe_r912` stays untouched — it remains a valid user-facing description of a disabled routine.

### Verification

```bash
# 1. Confirm the flag flipped
grep '^r912|' .agents/scripts/routines/core-routines.sh
# Expected output (exact):
# r912| |Dashboard server|repeat:persistent|~0s|server/index.ts|service

# 2. Confirm shellcheck still clean on the file
shellcheck .agents/scripts/routines/core-routines.sh

# 3. After deploy (setup.sh --non-interactive rsyncs .agents/ to ~/.aidevops/agents/),
#    the next pulse cycle should skip r912. Check pulse log:
tail -100 ~/.aidevops/logs/pulse-wrapper.log | grep 'routine r912:'
# Expected: no new "script not found" lines after deploy timestamp.
```

### Files Scope

- `.agents/scripts/routines/core-routines.sh`
- `todo/tasks/t2702-brief.md`
- `TODO.md`

## Acceptance Criteria

- [ ] r912 pipe entry in `.agents/scripts/routines/core-routines.sh:30` has `| |` (disabled) instead of `|x|` (enabled).
  ```yaml
  verify:
    method: bash
    run: "grep -q '^r912| |Dashboard server' .agents/scripts/routines/core-routines.sh"
  ```
- [ ] The old enabled form is gone from the file (no regression).
  ```yaml
  verify:
    method: bash
    run: "! grep -q '^r912|x|' .agents/scripts/routines/core-routines.sh"
  ```
- [ ] `shellcheck` still passes on the edited file.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/routines/core-routines.sh"
  ```

## Out of scope

- **Removing the r912 entry entirely.** Keep it as a disabled placeholder — future work that ships an actual dashboard server can flip the flag back. Deleting would require also deleting `describe_r912` and adjusting any cross-references.
- **Shipping the dashboard server.** That is a product decision with real scope (web server, UI, data aggregation). Separate task if/when prioritised.
- **Fixing the stale `~/.aidevops/bin/aidevops-dashboard` symlink.** The symlink target `/Users/marcusquinn/Git/aidevops-dashboard/` does not exist. Unrelated broken link; does not affect pulse operation. File separately if it surfaces as user-visible.

## Context & Decisions

- **Disable vs remove.** Disable chosen because it preserves the routine entry and describe block as forward-compatible placeholders. Removing and then re-adding later requires duplicating the describe function (~40 lines) and reasoning about ordering. Single-character flip is cheaper and reversible.
- **Why not ship the dashboard.** Out of scope for "fix the routine runner reporting errors" tracked by GH#20315. Building a web server is a product feature, not a bug fix.
- **Why t2700 did not include this.** t2700 scope was the three routines (r902/r906/r910) that shared a root cause (wrapper path + arg-in-run: bug). r912 has a different root cause (the script legitimately doesn't exist) and needs a different remedy (disable, not a wrapper).

## Relevant Files

- `.agents/scripts/routines/core-routines.sh:30` — pipe entry to edit
- `.agents/scripts/routines/core-routines.sh:611-652` — `describe_r912` (unchanged, kept as forward-compat doc)
- `.agents/scripts/pulse-routines.sh:107-117` — dispatcher path that fails on missing script (unchanged)

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read r912 entry | 1m | Already done in this brief |
| Apply 1-char edit | 1m | Exact oldString/newString in Implementation Steps |
| Verify | 2m | grep + shellcheck |
| **Total** | **~5m** | |
