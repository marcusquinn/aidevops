---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2703: evaluate extending pulse-routines.sh to tokenize run: fields

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `pulse-routines tokenize run` → 1 hit (my own t2700 note — confirms single-token behaviour is current reality, wrapper pattern is the working workaround)
- [x] Discovery pass: 1 commit (t2700 / PR #20334) touching `pulse-routines.sh` dispatch path in last 48h — relevant context, no collision
- [x] File refs verified: `pulse-routines.sh:107-117` (dispatch), `:234-244` (regex extraction), `core-routines.sh:20-32` (pipe entries) — all present at HEAD
- [x] Tier: `tier:thinking` — design decision with existing working alternative (wrappers); requires trade-off analysis, not transcription

## Origin

- **Created:** 2026-04-21
- **Session:** Claude Code CLI interactive (continuation of t2700)
- **Created by:** marcusquinn (human, via ai-interactive)
- **Parent task:** none — this IS a parent task (research + decomposition into phases)
- **Conversation context:** PR #20334 (t2700) fixed three routines by introducing wrapper shims that hardcode the subcommand argument, bypassing the single-token limitation of `pulse-routines.sh`'s `run:` field. That works but scatters trivial scripts across `.agents/bin/`. This parent task captures the research question: should the dispatcher instead word-split `run:` values so entries can carry args inline? Out-of-scope call from the t2700 brief; this issue tracks the decision.

## What

This is a **parent research task**, not an implementation. The deliverable is a **decision** documented as a comment on this issue (or in a linked PR), with one of three outcomes:

- **Keep the wrapper pattern** (status quo after t2700) — close this issue with rationale; wrapper shims remain the canonical way to bind args to routine entries.
- **Tokenize run:** — split this issue into implementation children (phases below) and proceed with framework-wide changes to `pulse-routines.sh` plus migration of the three t2700 wrappers back to inline entries.
- **Hybrid** — add a new `args:` sibling field to `run:` so entries can carry args without tokenising (avoids breaking custom user routines that have spaces in paths). Split this issue into implementation children for the hybrid approach.

The expected output is enough analysis to make the call confidently, plus — if we pursue either of the tokenize/hybrid paths — filed child issues that can be dispatched to standard-tier workers.

## Why

**Wrapper cost.** PR #20334 added three nearly-identical wrapper scripts (`aidevops-auto-update`, `aidevops-repo-sync`, `aidevops-skills-sync`) that exist only to work around the single-token `run:` field. Each wrapper is ~20 lines of SPDX header + PATH discovery + `exec aidevops <subcmd> <arg>`. Every future routine that needs an argument will add another wrapper. The pattern scales linearly with routine count.

**Tokenize benefit.** If `pulse-routines.sh` tokenised `run:` values, routine entries could carry the args inline (`run:bin/aidevops auto-update check`), eliminating the wrapper overhead and making routine definitions self-documenting.

**Tokenize cost.** Space-as-separator breaks any entry with a path containing spaces. More importantly, it changes behaviour for `custom/scripts/<name>.sh` user routines — users who currently have `run:custom/scripts/my tool.sh` (unlikely but legal today) would suddenly see their routine interpreted as calling `custom/scripts/my` with arg `tool.sh`. Migration requires detecting and warning on existing entries that might be affected.

**Hybrid option.** A separate `args:` field preserves single-token `run:` semantics while adding the arg-binding capability. Trades schema complexity for backwards compatibility.

## Phases

This section is MANDATORY for parent-task issues per t2442 — the auto-decomposer and 7-day NMR escalation scanners require it to distinguish "plan in place" from "backlog rot".

**Phase A — Decision (this issue).**
Owner: marcusquinn (human).
Output: a comment on this issue answering: (1) wrappers good enough? (2) tokenize? (3) hybrid? with rationale. If (1), close this issue. If (2) or (3), file the Phase B and Phase C children and link them here.

**Phase B — Implement (only if Phase A picks tokenize or hybrid).**
Filed as a separate `tier:standard` child issue, blocked-by this one.
Scope: modify `pulse-routines.sh:107-117` (dispatch) and `:234-244` (regex extraction) per chosen approach; add regression tests.
Estimated effort: 2-3h.

**Phase C — Migrate (only if Phase B ships tokenize; skip if hybrid).**
Filed as a separate `tier:standard` child issue, blocked-by Phase B.
Scope: migrate the three t2700 wrappers back to inline entries in `core-routines.sh`; delete the wrapper scripts; update t2700's describe Schedule tables.
Estimated effort: 1h.

If Phase A concludes "wrappers good enough" (option 1), there are no Phase B or C — close this parent with the rationale comment and no children filed.

## Tier

### Tier checklist

- [ ] 2 or fewer files to modify? **No** — for Phase B, 2 files in `pulse-routines.sh`; for Phase C, 4+ files across wrappers and `core-routines.sh`. This parent issue is decision-only (0 files modified).
- [ ] Every target file under 500 lines? **No** — `pulse-routines.sh` is 268 lines, but `core-routines.sh` is 814 lines
- [ ] Exact `oldString`/`newString` for every edit? **No** — design decision, approach not fixed
- [ ] No judgment or design decisions? **No** — the whole point is a judgment call
- [ ] No error handling or fallback logic to design? **No** — migration path needs fallback reasoning
- [ ] No cross-package or cross-module changes? **No** — touches dispatcher + all core routines
- [ ] Estimate 1h or less? **No** — decision ~30m, implementation children ~2-3h each
- [ ] 4 or fewer acceptance criteria? **Yes** — 3 criteria

**Selected tier:** `tier:thinking` for Phase A (decision); Phase B and C children will be `tier:standard`.

**Tier rationale:** the decision requires weighing breaking-change risk against scalability. The dispatcher change has knock-on implications for user routines and cron/launchd scheduling. This is architecture work, not transcription.

## PR Conventions

**This issue is `#parent`.** Any PR filed under this issue — including the initial decision-recording PR, if one is filed — MUST use `For #<this-issue>` or `Ref #<this-issue>`, NEVER `Closes`/`Resolves`/`Fixes`. The final child PR (Phase B or C, whichever merges last) uses `Closes #<this-issue>` to close the parent.

If Phase A concludes "close as wrappers are sufficient", close via UI or `gh issue close --comment "<rationale>"`, not via a PR keyword.

## How (Approach)

### Worker Quick-Start

This is a decision task, not an implementation. The "worker" is a human reader (or a `tier:thinking` dispatch in the pulse). Quick-start for evaluating:

```bash
# 1. Read the current dispatch path (single-token):
sed -n '100,120p' .agents/scripts/pulse-routines.sh

# 2. Read the regex extractor (single-token):
sed -n '230,250p' .agents/scripts/pulse-routines.sh

# 3. Count routines that currently carry args via wrappers:
grep '^r9' .agents/scripts/routines/core-routines.sh | awk -F'|' '{print $6}' | grep '^bin/aidevops-' | wc -l
# Expected: 3 (r902, r906, r910 — the t2700 wrappers)

# 4. Check whether any existing entry already has spaces in the run: field:
grep '^r9' .agents/scripts/routines/core-routines.sh | awk -F'|' '$6 ~ / /'
# Expected: nothing (post-t2700). If this prints anything, tokenize would break those entries.
```

### Files to Modify (for Phase B, if pursued)

For the tokenize approach:

- `EDIT: .agents/scripts/pulse-routines.sh:107-117` — change `"$script_path"` execution from single quoted argv to `read -ra args <<< "$run_script"` then `agents_dir/args[0]` + `"${args[@]:1}"`. Handle empty-arg edge case.
- `EDIT: .agents/scripts/pulse-routines.sh:234-244` — widen regex from `run:([^[:space:]]+)` to `run:([^#]+)` with trim, OR accept explicit `args:` sibling field instead.
- `EDIT: .agents/scripts/tests/test-pulse-routines-cron-extraction.sh` — add regression tests for the new behaviour.

For the hybrid approach (separate `args:` field):

- `EDIT: .agents/scripts/pulse-routines.sh` — add `extract_args_expr` alongside existing `extract_run_expr`; pass both to dispatcher.
- `EDIT: .agents/scripts/pulse-routines.sh:107-117` — append `$args` tokens to the exec call.
- `EDIT: .agents/scripts/routines/core-routines.sh` — add `|args:<value>` to pipe entries that need args.

The Phase B brief, when filed, will make the exact choice and provide full oldString/newString for the chosen path.

### Files to Modify (for Phase C, if pursued — only applies if Phase B is tokenize)

- `DELETE: .agents/bin/aidevops-auto-update`
- `DELETE: .agents/bin/aidevops-repo-sync`
- `DELETE: .agents/bin/aidevops-skills-sync`
- `EDIT: .agents/scripts/routines/core-routines.sh:20` — r902 entry `run:bin/aidevops-auto-update` → `run:bin/aidevops auto-update check`
- `EDIT: .agents/scripts/routines/core-routines.sh:24` — r906 similar
- `EDIT: .agents/scripts/routines/core-routines.sh:28` — r910 similar (`skill generate`)
- `EDIT: .agents/scripts/routines/core-routines.sh:188,392,552` — describe Schedule tables updated to match.

### Implementation Steps (Phase A — this issue)

1. Re-read the t2700 brief (`todo/tasks/t2700-brief.md`) to internalise why wrappers were chosen as the immediate fix.
2. Count current and projected wrapper-pattern usage: grep for `^bin/aidevops-` in core-routines; check `custom/scripts/` for user-owned routines that might need arg-binding in future.
3. Read `reference/routines.md` (if present) for the documented `run:` field contract — determine whether the single-token behaviour was an explicit design choice or an implementation-detail limitation.
4. Weigh the three options against these axes: wrapper-count growth, migration cost, user-facing behaviour change, schema complexity.
5. Post a comment on this issue with the decision and rationale. If pursuing tokenize or hybrid, file Phase B (and optionally Phase C) as `tier:standard` children with `blocked-by: #<this-issue>` and link them in a "## Children" section appended to this issue's body.

### Verification

For Phase A:
- [ ] A decision comment is posted on this issue.
- [ ] If pursuing implementation, Phase B child issue exists with `blocked-by: #<this-issue>` and is linked in a `## Children` section on this issue.
- [ ] If closing as "wrappers sufficient", the issue is closed with the rationale in the close comment.

For Phase B and C (defined in their own briefs when filed):
- [ ] Existing `test-pulse-routines-cron-extraction.sh` still passes.
- [ ] New regression test covering multi-token `run:` (or `args:`) fields passes.
- [ ] All three t2700 wrappers either remain (hybrid) or are deleted and replaced with inline entries (tokenize).

### Files Scope

- `todo/tasks/t2703-brief.md`
- `TODO.md`

Phase A produces no code changes — only a decision comment and (optionally) child issues. If Phase B or C is filed, they declare their own scopes.

## Acceptance Criteria

- [ ] Decision comment posted on this issue covering: (a) which of the three options was chosen, (b) rationale citing wrapper-count projection, migration cost, and backwards-compat risk, (c) next step (close this issue, or link to filed Phase B/C children).
  ```yaml
  verify:
    method: manual
    prompt: "Is the decision comment present and does it pick one of {keep wrappers, tokenize, hybrid} with rationale?"
  ```
- [ ] If decision is "keep wrappers": issue is closed with the rationale comment linked from the close.
- [ ] If decision is "tokenize" or "hybrid": Phase B child issue exists with `blocked-by:#<this-issue>` and is linked here in a `## Children` section appended to the body.
  ```yaml
  verify:
    method: manual
    prompt: "If tokenize/hybrid chosen, is Phase B filed and linked under ## Children?"
  ```

## Out of scope

- **Implementation of tokenize/hybrid.** This issue decides. Implementation is Phase B's job, filed separately.
- **Migrating custom user routines.** If a user has `custom/scripts/<name>.sh` with spaces in the path, that's their problem to handle; framework will emit a warning if the chosen approach would break it.
- **Redesigning routine configuration format.** The scope is the `run:` field specifically. YAML-ising the whole routine catalogue is a separate, much larger question.

## Context & Decisions

- **Why t2700 shipped wrappers instead of tokenize.** Wrappers are a local, reversible change — three new files, zero breakage risk. Tokenize is a framework-wide change affecting every routine on every install. t2700 needed a low-risk fix for a broken-in-production bug; longer-term design question deferred to this parent.
- **Why this is tier:thinking, not tier:standard.** The decision requires weighing schema design trade-offs against backwards compatibility and projected growth. A standard-tier worker doesn't have the context to make that call; a thinking-tier model does, and so does a human.
- **Why parent-task (`#parent`) not plain #auto-dispatch.** Per t2211 and t2442, maintainer-authored research tasks MUST use `#parent` — the `parent-task` label is the only reliable dispatch block against NMR auto-approval overriding "Do NOT #auto-dispatch" body prose. This issue is a decision container that spawns children, never implemented directly.

## Relevant Files

- `.agents/scripts/pulse-routines.sh:107-117` — current single-token dispatch
- `.agents/scripts/pulse-routines.sh:234-244` — current single-token regex extraction
- `.agents/scripts/routines/core-routines.sh:20,24,28` — r902/r906/r910 pipe entries (currently use wrappers)
- `.agents/bin/aidevops-auto-update`, `.agents/bin/aidevops-repo-sync`, `.agents/bin/aidevops-skills-sync` — the t2700 wrapper shims
- `todo/tasks/t2700-brief.md` — the t2700 brief's "Out of scope" section is the source text that motivated this issue
- `.agents/reference/routines.md` — documented `run:` field contract (if present)

## Dependencies

- **Blocked by:** none — decision is self-contained
- **Blocks:** potential Phase B and Phase C children (filed only if decision pursues implementation)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research + decision | 30m | Read referenced files, weigh options, write comment |
| (Phase B implementation, if filed) | 2-3h | Separate task |
| (Phase C migration, if filed) | 1h | Separate task |
| **Total (this issue only)** | **~30m** | Phase B/C tracked separately |
