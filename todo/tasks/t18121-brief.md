<!-- aidevops:brief-schema=v2 -->

# t18121: Route pending full-loop CI through delta-aware wait-checks

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `full-loop wait-checks delta-aware CI polling` → 0 hits — no relevant stored lessons
- [x] Discovery pass: 8 recent commits / 5 merged PR search hits / 1 open PR search hit reviewed; PR #27535 introduced the helper but left both full-loop guides without the pending-state command, while open PR #27582 touches session analysis only
- [x] File refs verified: 5 refs checked against current HEAD; both target guides, the reference pattern, and focused wait tests are present
- [x] Tier: `tier:simple` — two 212-line documentation files, one identical exact replacement, no new logic or fallback design
- [x] Seeded draft PR decision recorded: skipped — the issue and exact replacement are sufficient for a mechanical worker change

## Origin

- **Created:** 2026-07-14
- **Session:** `opencode:ses_0a27e6418ffe3GdgcFDjIf8u7z`
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** none; standalone leaf follow-up from #27529
- **Blocked by:** none; the prerequisite helper is merged and available
- **Conversation context:** Session analysis found that a raw required-check watch produced 151,357 bytes and 1,427 lines, including 1,317 duplicate non-empty line occurrences and 27 unchanged refresh snapshots, even though the delta-aware wait helper had already shipped.

## What

Update both full-loop guidance mirrors so a pending merge gate routes through `full-loop-helper.sh wait-checks` and then retries the merge only after terminal-success evidence. The guidance must explicitly prohibit raw repeated `gh pr checks --watch` snapshots for this path while preserving pending, terminal-failure, and indeterminate-API exit semantics.

## Why

Issue #27529 and PR #27535 shipped the token-efficient wait mechanism, but the primary full-loop workflow does not tell agents to use it after `full-loop-helper.sh merge` reports pending checks. In the observed session, that adoption gap injected a large, mostly duplicated check stream into context. Connecting the existing workflow to the existing helper delivers the intended context saving without changing merge safety or helper logic.

## Tier

**Selected tier:** `tier:simple`

**Tier rationale:** Only two mirrored Markdown files change. Both are under 500 lines and receive the same exact replacement block below. No implementation design, shell behavior, or error recovery logic is being created.

## PR Conventions

This is a leaf issue. The implementation PR must use `Resolves #27585`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The exact replacement and executable verification are fully specified; a seed would add coordination overhead without reducing worker discovery.
- **Status:** `not-created`
- **Freshness evidence:** Targets and references verified against current HEAD after reviewing PR #27535 and open PR #27582.
- **Verification run:** Brief readiness only; implementation checks remain for the worker.
- **Stale-assumption warning:** Re-run discovery if either full-loop guide already contains `wait-checks` or if another open PR begins touching either target.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/commands/full-loop.md:175-185` — add the pending-check reroute to the command-facing full-loop guide.
- `EDIT: .agents/workflows/full-loop.md:175-185` — apply the identical change to the workflow mirror.

### Complete Write Surface

- **Callers/readers:** OpenCode and Claude Code full-loop command/workflow loaders read the two target Markdown files; `.agents/reference/context-efficient-output.md:37-50` defines the canonical wait contract.
- **Writers/mutation paths:** N/A because repository search shows this is documentation-only guidance; `.agents/scripts/commands/full-loop.md` and `.agents/workflows/full-loop.md` do not write runtime state.
- **Tests/fixtures:** `.agents/scripts/tests/test-gh-checks-wait-helper.sh` already covers initial state, transition-only output, terminal failures, timeout exit `8`, API recovery, and heartbeat behavior. No fixture behavior changes.
- **Schemas/config:** Search of the target scope found no schema or config consumer; the command syntax is already exposed by `full-loop-helper.sh wait-checks`.
- **Generated/deployed mirrors:** The two tracked guides are the complete repository write surface and must remain aligned. Deployed `~/.aidevops` copies are release/setup outputs and must not be edited directly.
- **Migrations/backfills:** N/A because the two Markdown guides store no data and repository search found no migration or backfill consumer for them.
- **Cleanup/rollback paths:** Revert the same inserted paragraph in `.agents/scripts/commands/full-loop.md` and `.agents/workflows/full-loop.md`; existing merge and wait helpers remain unchanged throughout.

### Implementation Steps

1. In both target files, replace this exact block:

**oldString:**

````markdown
**4.4 Review Bot Gate (t1382 + GH#17541 — CODE-ENFORCED):**

```bash
full-loop-helper.sh merge "$PR_NUMBER" "$REPO"
```

Verifies the exact PR head is open, non-draft, free of changes-requested reviews, and has terminal-success required checks before running `review-bot-gate-helper.sh wait`.
````

with this block, retaining the remainder of the existing verification paragraph after its first sentence:

**newString:**

````markdown
**4.4 Review Bot Gate (t1382 + GH#17541 — CODE-ENFORCED):**

```bash
full-loop-helper.sh merge "$PR_NUMBER" "$REPO"
```

If the merge command reports that required checks are pending, do not run raw `gh pr checks --watch` or replay unchanged snapshots. Wait through the delta-aware exact-head path, then rerun `merge` only after terminal success:

```bash
full-loop-helper.sh wait-checks "$PR_NUMBER" --repo "$REPO"
```

Exit `8` remains pending and must resume through the same bounded wait path; exit `1` is terminal check failure and requires exact failed-check diagnostics; exit `2` is indeterminate API failure and must not be treated as success.

Verifies the exact PR head is open, non-draft, free of changes-requested reviews, and has terminal-success required checks before running `review-bot-gate-helper.sh wait`.
````

2. Keep all existing merge-wrapper, review-bot, exact-head, admin-fallback, release, and cleanup guidance unchanged.
3. Do not modify `full-loop-helper.sh`, `gh-checks-wait-helper.sh`, tests, or `.agents/reference/context-efficient-output.md`; they are reference evidence, not write scope.

### Hazards and Compatibility

- **Concurrency/atomicity:** No runtime concurrency changes. Updating only one mirror would create inconsistent agent behavior, so both files must change in one commit and remain byte-identical.
- **Migration/rollback:** No migration. A revert must remove the identical paragraph from both files.
- **Mixed-version/backward compatibility:** The documented command shipped in v3.32.101. Current workers support it; no CLI contract changes are introduced.
- **Idempotency/retry:** The guidance preserves helper exit `8` as pending and directs retries through the same bounded wait path, avoiding duplicate raw snapshots.
- **Partial failure/recovery:** If one file fails validation or drifts during rebase, restore mirror equality before push. Never weaken the merge gate to work around a wait failure.

### Verification Before Dispatch

```bash
.agents/scripts/tests/test-gh-checks-wait-helper.sh
rg -n 'full-loop-helper\.sh wait-checks "\$PR_NUMBER" --repo "\$REPO"' .agents/scripts/commands/full-loop.md .agents/workflows/full-loop.md
! rg -n 'gh pr checks --watch' .agents/scripts/commands/full-loop.md .agents/workflows/full-loop.md
diff -u .agents/scripts/commands/full-loop.md .agents/workflows/full-loop.md
.agents/scripts/linters-local.sh
```

- **Surface mapping:** The focused helper test preserves the referenced exit/transition contract; the positive search proves both readers gained the command; the negative search prevents the observed noisy fallback; `diff` proves mirror consistency; local linters cover Markdown and repository policy.
- **Broad verification trigger:** Not required beyond normal changed-scope local linters because this is a two-file documentation-only change with no code, config, dependency, or release-infrastructure mutation.

### Files Scope

- `.agents/scripts/commands/full-loop.md`
- `.agents/workflows/full-loop.md`

## Acceptance Criteria

- [ ] Both full-loop guides route pending required checks through the delta-aware exact-head wait command before retrying merge.

  ```yaml
  verify:
    method: bash
    run: "test \"$(rg -l 'full-loop-helper\\.sh wait-checks' .agents/scripts/commands/full-loop.md .agents/workflows/full-loop.md | wc -l | tr -d ' ')\" -eq 2"
  ```

- [ ] Neither full-loop guide recommends raw `gh pr checks --watch` or repeated unchanged snapshots for the pending path.

  ```yaml
  verify:
    method: codebase
    pattern: "gh pr checks --watch"
    path: ".agents/scripts/commands/full-loop.md .agents/workflows/full-loop.md"
    expect: absent
  ```

- [ ] The guidance preserves exit `8` as pending, exit `1` as terminal failure, exit `2` as indeterminate, and never treats any of them as successful merge evidence.

  ```yaml
  verify:
    method: bash
    run: "for f in .agents/scripts/commands/full-loop.md .agents/workflows/full-loop.md; do rg -q 'Exit `8` remains pending' \"$f\" && rg -q 'exit `1` is terminal' \"$f\" && rg -q 'exit `2` is indeterminate' \"$f\" || exit 1; done"
  ```

- [ ] The two mirrors remain identical and the existing wait-helper regression suite passes.

  ```yaml
  verify:
    method: bash
    run: "diff -u .agents/scripts/commands/full-loop.md .agents/workflows/full-loop.md && .agents/scripts/tests/test-gh-checks-wait-helper.sh"
  ```

## Context & Decisions

- Reuse the mechanism delivered by #27529 / PR #27535; do not create another output or polling layer.
- Preserve every safety property of `full-loop-helper.sh merge`; this task changes adoption guidance only.
- Open PR #27582 fixes exact current-session output analysis and does not touch this task's two-file write scope.
- The measured session evidence establishes a real output-noise problem but is not a runtime-performance claim.

## Relevant Files

- `.agents/scripts/commands/full-loop.md:175-185` — command-facing insertion point.
- `.agents/workflows/full-loop.md:175-185` — mirrored workflow insertion point.
- `.agents/reference/context-efficient-output.md:37-50` — authoritative delta-aware wait semantics.
- `.agents/scripts/tests/test-gh-checks-wait-helper.sh:61-123` — existing behavior coverage; read-only for this task.

## Dependencies

- **Blocked by:** none.
- **Blocks:** consistent token-efficient full-loop CI waiting in future interactive and worker sessions.
- **External:** GitHub CLI access for normal PR verification only; no credentials or purchases required.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Confirm targets still lack the command and no colliding PR exists |
| Implementation | 10m | Apply the identical exact replacement in two files |
| Testing | 15m | Focused wait test, positive/negative searches, mirror diff, local linters |
| **Total** | **30m** | Mechanical documentation adoption change |
