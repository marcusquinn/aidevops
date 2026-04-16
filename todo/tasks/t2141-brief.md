<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2141: full-loop-helper merge — auto-resolve --admin/--auto mutual exclusion

## Origin

- **Created:** 2026-04-16
- **Session:** opencode (interactive, claude-opus-4-6)
- **Created by:** marcusquinn (ai-interactive)
- **Conversation context:** Discovered live during the t2139 merge — `full-loop-helper.sh merge ... --admin --auto` failed because `gh pr merge` rejects the flag combination. The agent had no signal these flags conflict at the CLI level (they read as compatible English: "use admin AND auto"). Stored as a memory lesson; user agreed to fix in-session.

## What

`cmd_merge` in `full-loop-helper.sh` detects when both `--admin` and `--auto` are set and silently resolves in favour of `--admin` (dropping `--auto`) with an informational message. Help text documents the mutual exclusion. Single-line regression test asserts the resolution.

User-visible effect: callers can pass both flags without the wrapper failing. `--admin` is preferred because it already implies "merge now"; `--auto` adds no value when `--admin` is set.

## Why

Discovered during t2139 merge today. `gh pr merge` rejects `--admin` + `--auto` together with: `specify only one of '--auto', '--disable-auto', or '--admin'`. The wrapper passed both through verbatim and the merge failed. Agents (and humans) plausibly type both flags expecting compounded intent — there is no English-level signal that they conflict.

Cost-benefit: ~5 lines of code, prevents a class of merge failures that look unrelated to the actual flag combination problem.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** — Yes (helper + test)
- [x] **Every target file under 500 lines?** — `full-loop-helper.sh` is 1211 lines, but the change is localised to a 30-line region; verbatim oldString/newString provided below
- [x] **Exact `oldString`/`newString` for every edit?** — Yes
- [x] **No judgment or design decisions?** — Yes (resolution direction is specified)
- [x] **No error handling or fallback logic to design?** — Yes
- [x] **No cross-package or cross-module changes?**
- [x] **Estimate 1h or less?** — ~25m
- [x] **4 or fewer acceptance criteria?**

All checked → eligible for `tier:simple`. Marking `tier:simple`.

**Selected tier:** `tier:simple`

**Tier rationale:** Single-file local change with verbatim diff blocks below; deterministic resolution direction; no judgement. The helper file is large but the edit context is fully self-contained.

## PR Conventions

Leaf issue (`bug`, not `parent-task`) → PR body uses `Resolves #19310`.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/full-loop-helper.sh:1099-1131` — `cmd_merge` flag parsing: add conflict detection after the for-loop
- `EDIT: .agents/scripts/full-loop-helper.sh:1085-1094` — `cmd_merge` docstring: note the resolution
- `EDIT: .agents/scripts/full-loop-helper.sh:1169-1172` — `show_help` text: note the resolution
- `NEW: .agents/scripts/tests/test-full-loop-merge-flag-conflict.sh` — regression test that calls cmd_merge with both flags and asserts the resolution

### Implementation Steps

1. After the `for arg in "$@"; do … done` block in `cmd_merge`, add:

   ```bash
   # GH#19310 (t2141): --admin and --auto are mutually exclusive in `gh pr merge`.
   # Resolve in favour of --admin: it already implies "merge now via owner override",
   # so --auto (queue and wait) becomes functionally redundant when --admin is set.
   if [[ "$has_admin" -eq 1 && "$has_auto" -eq 1 ]]; then
       print_info "Both --admin and --auto were specified; gh pr merge rejects this combination."
       print_info "Resolving in favour of --admin (overrides branch protection now); dropping --auto."
       has_auto=0
   fi
   ```

2. Update the cmd_merge docstring (lines 1088-1094) to mention the resolution.

3. Update `show_help` (lines 1169-1172) to mention the mutual exclusion.

4. Write the regression test that sources the helper, calls `cmd_merge` with mocked `gh`, and asserts (a) `--admin` survives, (b) `--auto` is dropped, (c) informational message is printed.

### Verification

```bash
shellcheck .agents/scripts/full-loop-helper.sh .agents/scripts/tests/test-full-loop-merge-flag-conflict.sh
bash .agents/scripts/tests/test-full-loop-merge-flag-conflict.sh
```

## Acceptance Criteria

- [ ] `cmd_merge` detects `--admin` + `--auto` together and drops `--auto` with informational message
  ```yaml
  verify:
    method: codebase
    pattern: "Resolving in favour of --admin"
    path: ".agents/scripts/full-loop-helper.sh"
  ```
- [ ] Test asserts the resolution: `bash .agents/scripts/tests/test-full-loop-merge-flag-conflict.sh`
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-full-loop-merge-flag-conflict.sh"
  ```
- [ ] shellcheck clean on helper and test
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/full-loop-helper.sh .agents/scripts/tests/test-full-loop-merge-flag-conflict.sh"
  ```
- [ ] `show_help` text mentions the mutual-exclusion resolution
  ```yaml
  verify:
    method: codebase
    pattern: "mutually exclusive|--admin wins|drop"
    path: ".agents/scripts/full-loop-helper.sh"
  ```

## Context & Decisions

- **Resolution direction**: `--admin` wins because it already implies "merge now". `--auto` adds nothing when an admin override is in play.
- **Silent vs error**: Silent (with info message) preferred over error — the user/agent's intent is clear (they want the PR merged), and erroring would be unhelpful nitpicking.
- **Why not just sanitise to `--admin --auto-disable`?** Overcomplicated; we don't actually want to disable any pre-existing auto-merge state, just to not pass `--auto` this call.
- **Non-goals**: Don't change `_merge_execute` semantics. Don't add new flags. Don't change the `--admin` fallback path (which already only fires when neither flag was explicitly passed).

## Relevant Files

- `.agents/scripts/full-loop-helper.sh:1095-1145` — `cmd_merge`
- `.agents/scripts/full-loop-helper.sh:1004-1056` — `_merge_execute` (downstream consumer of has_admin/has_auto)
- Memory: PR #18757 (GH#18731) — origin of the `--admin`/`--auto` pass-through

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 15m | Verbatim diff |
| Test | 10m | Mock gh, assert info message |
| **Total** | **~25m** | |
