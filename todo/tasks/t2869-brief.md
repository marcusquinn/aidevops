<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2869: P2d — pulse digest of stale inbox items + weekly review surface

## Pre-flight

- [x] Memory recall: "pulse digest weekly review stale items" — none directly; adapt from existing pulse-stats reporting
- [x] Discovery pass: no in-flight PRs touching pulse digest path
- [x] File refs verified: `pulse-wrapper.sh` for pulse-stats reporting pattern
- [x] Tier: `tier:standard` — read-only reporting routine over existing data

## Origin

- **Created:** 2026-04-25
- **Session:** Claude Code interactive session (t2840 P2 phase)
- **Created by:** ai-interactive
- **Parent task:** t2840 / GH#20892
- **Conversation context:** GTD-failure-mode mitigation. Without active surfacing of stale items, `_inbox/` becomes a dumping ground that never gets sorted (the canonical "inbox zero" failure). Pulse digest pushes the user the oldest items so they don't get lost.

## What

Implements `aidevops inbox digest [--age-days N]` — reports the oldest unsorted/needs-review items in `_inbox/` across all repos plus the workspace-level inbox. Runs as a pulse routine producing a weekly digest (configurable interval) that surfaces in the session greeting / stale-claim scan output.

Two surfaces:

1. **CLI:** `aidevops inbox digest` — interactive query, returns top N stale items.
2. **Pulse routine:** runs weekly; if stale items > threshold, posts an advisory in `~/.aidevops/advisories/inbox-stale-{repo-slug}.advisory` so the next interactive session greeting includes a nudge.

After completion:

- Items in `_inbox/_drop/` or `_inbox/_needs-review/` older than `age-days` (default 7) surface as stale.
- Pulse posts advisories in repos with stale items.
- User running `aidevops inbox digest` sees a list with file path, age, sub-folder, and any prior triage attempt notes.

## Why

Inbox without escalation = abandoned items. Users need a passive nudge ("you have 14 items > 7 days old in `_inbox/`") rather than having to remember to check.

Advisory mechanism reuses the existing `~/.aidevops/advisories/` flow already used for security and update advisories — consistent UX, no new surface.

## Tier

**Selected tier:** `tier:standard`. Pure reporting on existing data — no LLM calls, no destructive operations.

## PR Conventions

Child of parent-task t2840. Use `For #20892`.

## How

### Files to Modify

- `EDIT: .agents/scripts/inbox-helper.sh` — add `digest` subcommand.
- `NEW: .agents/scripts/inbox-digest-routine.sh` — pulse-callable; writes advisories.
- `EDIT: .agents/scripts/aidevops` — wire `aidevops inbox digest`.
- `EDIT: .agents/scripts/aidevops-update-check.sh` — surface inbox advisories in session greeting alongside existing advisory types.

### Implementation Steps

1. `inbox-helper.sh digest [--age-days N] [--repo PATH] [--include-workspace] [--json]`:
   - Walk `_inbox/_drop/` and `_inbox/_needs-review/` for files older than `--age-days`
   - Cross-reference with `triage.log` to get any prior routing attempt notes
   - Output sorted by age desc, columns: `age_days  sub_folder  file_path  prior_attempts`
   - `--json` for machine-readable output (used by routine)

2. `inbox-digest-routine.sh`:
   - Iterate all `pulse: true` repos in `repos.json` plus workspace inbox
   - For each, run `inbox-helper.sh digest --json --age-days 7 --include-workspace`
   - If count > 0: write `~/.aidevops/advisories/inbox-stale-{repo-slug}-{ts}.advisory` with the digest
   - If count == 0: clean up any existing stale advisories for that repo (resolved)
   - Schedule: weekly default (configurable via env `AIDEVOPS_INBOX_DIGEST_INTERVAL_HOURS`, default 168)

3. Greeting integration:
   - `aidevops-update-check.sh` already reads `~/.aidevops/advisories/*.advisory` for session greeting
   - Inbox advisories follow the same format (just a different filename prefix)
   - Dismiss mechanism: `aidevops security dismiss inbox-stale-{slug}` (reuses existing advisory dismissal)

### Complexity Impact

- **Target function:** none (new file + small CLI extension)
- **Estimated growth:** ~150 lines total
- **Action required:** None.

### Verification

```bash
shellcheck .agents/scripts/inbox-helper.sh .agents/scripts/inbox-digest-routine.sh

# Sanity: drop a stale file, run digest
touch -t 202604010000 _inbox/_drop/old.txt  # 25+ days old
aidevops inbox digest --age-days 7
# Expected: shows old.txt with age ~25 days

# Pulse routine produces advisory
.agents/scripts/inbox-digest-routine.sh
ls ~/.aidevops/advisories/inbox-stale-*.advisory
# Expected: at least one file
```

### Files Scope

- `.agents/scripts/inbox-helper.sh`
- `.agents/scripts/inbox-digest-routine.sh`
- `.agents/scripts/aidevops`
- `.agents/scripts/aidevops-update-check.sh`

## Acceptance Criteria

- [ ] `aidevops inbox digest` lists stale items sorted by age.
- [ ] `--age-days N` and `--include-workspace` flags work.
- [ ] Pulse routine runs weekly and writes advisories when stale items exist.
- [ ] Advisories surface in session greeting alongside existing types.
- [ ] Advisories self-clear when stale items go to zero.
- [ ] Dismissal via existing `aidevops security dismiss` mechanism works.
- [ ] `shellcheck` clean.

## Context & Decisions

- **Why advisory reuse vs new mechanism:** consistent UX. Users already know how to dismiss advisories. Inbox-stale is just another kind.
- **Why weekly default:** daily nudges are noise; monthly is too easy to ignore. Weekly matches the GTD weekly-review cadence.
- **Why include workspace inbox:** captures-not-tied-to-repo can otherwise vanish. Including the workspace inbox in digest closes that gap.
- **Why surface count, not contents in greeting:** privacy. Greeting may be visible to others; just shows count + slug. User runs `aidevops inbox digest` to see actual filenames.

## Relevant Files

- `.agents/scripts/aidevops-update-check.sh` — advisory reader
- `~/.aidevops/advisories/` — advisory store
- `.agents/configs/repos.json` — pulse-enabled repo iteration
- `t2867-brief.md` — capture produces files; this surfaces unprocessed ones

## Dependencies

- **Blocked by:** t2868 (P2c — needs `triage.log` populated to cross-reference prior attempts; can ship without if we accept "no prior attempts" for items)
- **Blocks:** none directly; closes the inbox-zero failure-mode mitigation
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | review existing advisory mechanism |
| Implementation | 2h | digest subcommand + routine + advisory wiring |
| Testing | 1h | manual verification + smoke test |
| **Total** | **~3.5h** | |
