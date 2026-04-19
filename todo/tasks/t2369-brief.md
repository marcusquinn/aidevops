<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2369: Pulse TODO auto-complete false-positive on range-syntax PR titles and For-keyword planning PRs

## Origin

- **Created:** 2026-04-19
- **Session:** Claude Code (interactive, t2249 session follow-up — 7th framework observation from t2249 batch)
- **Observation:** The pulse's TODO auto-complete matched the first task ID in PR #19814's title (`t2259..t2264: plan framework observations`) and marked t2259 `[x]` in TODO.md even though the PR was planning-only (brief files + TODO entries, no code). Cost a revert PR (#19818). GitHub's own `Resolves`/`Closes` parser correctly left all 6 linked issues OPEN — the bug is in the pulse's internal logic, which ignores PR body keywords.

## What

Two false-positive patterns in pulse TODO auto-complete on PR merge:

1. **Range-syntax titles:** `t2259..t2264: plan framework observations from t2249 session` should signal "planning for multiple tasks" but the pulse matches only the first ID and marks that one task complete.
2. **`For`/`Ref` keyword ignored:** the same PR body used `For #NNN` (the AGENTS.md-mandated keyword for planning-only commits that should NOT close issues). The pulse never reads PR body keywords — it only reads the title.

## Why

The canonical invariant — `[x] tNNN` in TODO.md means "the code for tNNN shipped" — is violated on every planning-only PR whose title starts with a task ID. Trust erosion on the audit trail itself.

Per AGENTS.md "Traceability":

- Planning-only commits MUST use `For #NNN` or `Ref #NNN`.
- Code fix commits MAY use `Fixes/Resolves/Closes #NNN` (auto-closes on merge).

The pulse's auto-complete should honour this distinction. Currently it treats all merges as implementation merges.

## How

### Files to investigate

- `EDIT: .agents/scripts/pulse-merge.sh` — likely site of the mark-complete trigger. Grep for: `completed:`, `mark.*complete`, `pr:#`, `auto-complete`, `\[x\]`.
- `EDIT: .agents/scripts/task-complete-helper.sh` — user-facing completion helper; may share logic.
- `REFERENCE: .agents/scripts/commands/pulse.md` — pulse command doc with templates.
- `REFERENCE: templates/brief-template.md` — keyword rules (`For`/`Ref` vs `Resolves`/`Closes`/`Fixes`).

### Design — two-layer fix

**Layer 1 — parse PR body keywords, not title task IDs:**

Scan the merged PR body for GitHub-native closing keywords at word boundaries:

```bash
# Approximate regex (bash ERE):
# (Resolves|Closes|Fixes)\s+#([0-9]+)
# case-insensitive
```

For each `#NNN` matched, look up the corresponding TODO task via `ref:GH#NNN`. Mark ONLY those tasks complete. Title task IDs may continue to drive other pulse signals (dispatch dedup, task-ID collision guard), but must NOT drive completion state.

**Layer 2 — range-syntax detector as a second filter:**

Even if someone accidentally uses `Resolves #NNN` in a planning PR body, detect title patterns like `tNNN\.\.tNNN:` or `tNNN,\s*tNNN:` and treat the PR as planning-only — skip auto-complete entirely. The implementer PR for each task will trigger completion later when the actual code lands.

### Verification

New regression test at `.agents/scripts/tests/test-pulse-auto-complete-keywords.sh`:

- **Case A:** PR body `Resolves #19802`, title `fix(biome): batch-fix JS/MJS` → task mapped to `ref:GH#19802` marked `[x]`. Baseline case.
- **Case B:** PR body `For #19802`, title `plan: batch-fix JS/MJS` → NO `[x]` change. Planning-only keyword.
- **Case C:** PR title `t2259..t2264: plan`, body `For #19802` → NO `[x]` change. Range-syntax title filter.
- **Case D:** PR body `Closes #19802`, title `t2259..t2264: plan` → NO `[x]` change. Range-syntax wins even over `Closes` (belt-and-braces).
- **Case E:** PR body `Resolves #19802`, title `t2259: fix(biome) implement proper fix` → mark complete. Normal single-task implementation.

Dry-run against real merge state:

- Replay the pulse's auto-complete logic against PR #19814's merge payload. Assert that under the new logic, t2259 would NOT have been marked complete.

Shellcheck clean on any modified scripts.

## Tier

Tier:standard. Small logic change but blast radius is every merged PR on every pulse-enabled repo — needs careful regression testing.

Not `tier:simple` because the logic involves:

- Multi-line regex on PR body with case-insensitivity and word boundaries.
- Mapping `#NNN` → task IDs via TODO.md `ref:GH#NNN` lookup (file parsing).
- Range-syntax title pattern detection.
- Cascade of test cases to verify no regression on the many legitimate auto-complete paths.

Not `tier:thinking` because the design is fully specified; no open architectural questions.

## Acceptance

- [ ] PR auto-complete only fires when the PR body contains `Resolves`/`Closes`/`Fixes` (case-insensitive) for an issue mapped to a TODO task ID via `ref:GH#NNN`.
- [ ] Range-syntax titles (`tNNN\.\.tNNN`, `tNNN,\s*tNNN`) suppress auto-complete regardless of body keywords.
- [ ] `For #NNN` and `Ref #NNN` in PR body never trigger auto-complete.
- [ ] Regression test `.agents/scripts/tests/test-pulse-auto-complete-keywords.sh` covers cases A-E above and passes.
- [ ] Shellcheck clean on modified files.
- [ ] Existing legitimate auto-complete paths verified unchanged (grep for existing test cases using the auto-complete path).

## Context

- **Direct evidence:** PR #19814 merged 2026-04-19 00:47 UTC. Auto-marked t2259 `[x]`. Reverted via PR #19818.
- **Memory:** `mem_20260419020126_e137cd2a` captures the observation from the filing session.
- **Related:**
  - PR #19814 (batch planning that triggered the bug)
  - PR #19818 (the revert)
  - AGENTS.md "Traceability" section (canonical keyword rules)
  - GH#18352 / t2157 (related but different — `auto-dispatch` self-assignment; different code path)
- **Not a duplicate:** searched open issues for "auto-complete", "pulse TODO", "planning PR" — no existing report as of 2026-04-19.

## Relevant files

- `.agents/scripts/pulse-merge.sh` — likely primary edit site
- `.agents/scripts/task-complete-helper.sh` — possible secondary edit site (shared logic)
- `.agents/scripts/commands/pulse.md` — reference doc
- `templates/brief-template.md` — reference for keyword rules
- `.agents/scripts/tests/test-pulse-auto-complete-keywords.sh` — NEW regression test
