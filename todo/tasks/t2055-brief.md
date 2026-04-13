<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2055 (parent): interactive session auto-claim of status:in-review for issues

## Origin

- **Created:** 2026-04-13
- **Session:** claude-code (interactive)
- **Created by:** ai-interactive
- **Parent task:** none — this IS the parent
- **Conversation context:** The user asked for a mandatory, unavoidable mechanism so that working on an issue in an interactive session immediately self-assigns and applies a status label that gates headless workers. First design pass proposed a new `status:interactive-session` label plus `pre-edit-check.sh` fallback and a branch-name regex; the user pushed back on all three as unnecessary complexity and instructed to reuse `status:in-review` and drive acquire/release from AI conversation intent rather than user-memorised commands. This brief is the parent tracker for the resulting two-phase plan.

## What

Close the gap where an interactive session working on an existing GitHub issue (one it didn't create) has no mandatory, enforced signal that prevents the pulse from dispatching a parallel worker on the same issue. Today `origin:interactive` only marks issue-creation origin and `status:claimed` only fires on new-task claim; an interactive session picking up an `origin:worker` issue leaves no trace for the dispatch-dedup guard.

Reuse the existing `status:in-review` label — it is already in `_has_active_claim`, already skipped by stale-recovery, already highest-precedence in reconciliation, and already cleared on PR close. The only gap is **timing**: today it lands at PR open (via `full-loop-helper.sh commit-and-pr`); we need it to land at interactive session engage.

The mechanism is split into:

- **Phase 1 (t2056 / GH#18739):** foundation helper `interactive-session-helper.sh` + system-prompt rule telling the AI to call `claim`/`release` from conversation intent. Reversible on its own — nothing becomes mandatory via code wiring until Phase 2.
- **Phase 2 (t2057 / GH#18740):** wire the helper into `worktree-helper.sh`, `claim-task-id.sh`, and `approval-helper.sh` so the sanctioned paths exercise the claim automatically regardless of whether the agent explicitly called it.

## Why

### Direct gap

`_has_active_claim` in `dispatch-dedup-helper.sh:957` already treats `status:in-review` as an active claim that blocks dispatch:

```bash
.labels? // [] | any(.[].name;
  . == "status:queued" or
  . == "status:in-progress" or
  . == "status:in-review" or
  . == "status:claimed" or
  . == "origin:interactive")
```

And `_normalize_stale_should_skip_reset` in `pulse-issue-reconcile.sh:285` only resets `queued`/`in-progress` — `in-review` is already skipped. So the entire dispatch-gating infrastructure is already in place; the only thing missing is a mandatory earlier application point.

### Why reuse `in-review` and not invent `status:interactive-session`

The first design pass added a new label and a new protected-label list and new dedup logic. The user correctly pointed out that `in-review` already means "human attention is here" and already has all the gating behaviour we need. Adding a parallel label would duplicate existing infrastructure for no semantic benefit.

Semantic broadening: today `in-review` = "PR open, awaiting review/merge"; after this = "a human session is engaged, pre-PR or post-PR". Both states need the same treatment from the pulse (don't dispatch a worker), so merging them simplifies the state machine rather than complicating it.

### Why AI-driven, not user-driven

The user explicitly called out that "commands are secondary" — interactive sessions should detect intent and act, not put the burden of remembering release commands on the user. So the primary enforcement layer is a `prompts/build.txt` rule that tells the agent to call the helper from conversation context:

- "let me work on #18700" → `claim 18700`
- "I'm done with this one" / "ship it" / "moving on" → `release N`
- session start → `scan-stale` then prompt to release any dead claims
- PR merge closing an issue → release is already automatic via the existing issue-sync workflow

The code wiring in Phase 2 is the belt-and-braces safety net so that even if the agent misses the intent, the sanctioned paths still do the right thing.

### Why no `pre-edit-check.sh` fallback and no branch-name regex

First design had both. User rejected both as layered fragility. The sanctioned path is already `wt switch -c` → `worktree-helper.sh` (which already parses the branch name) and `claim-task-id.sh` (which already knows the issue number). If someone hand-rolls a worktree outside the framework, that's outside the happy path and we don't try to intercept it.

### Crypto approval (clarified)

First design incorrectly treated crypto approval as "the primary release path." User clarified: `sudo aidevops approve issue <N>` exists to protect against prompt injection on contributor-filed issues (NMR gate), and most interactive sessions work on maintainer-filed issues where no approval is ever required. So the crypto-approval release is purely additive and idempotent — when the command is already being run for NMR clearance, it ALSO clears `status:in-review` if present, adding zero user friction.

### Offline behaviour (clarified)

First design was fail-closed on offline `gh`. User pointed out this defends against a non-problem — if a worker solves something while you're offline, the interactive work just becomes a new issue/PR. Changed to warn-and-continue.

## Tier

**parent-task** — this issue never gets a worker; it exists to coordinate the two phase children. Marked with `#parent` / `parent-task` label.

## How (Approach)

### Phased plan

| Phase | Task ID | Issue | Scope | Reversibility |
|-------|---------|-------|-------|---------------|
| 1 | t2056 | GH#18739 | Helper script + prompt rule + AGENTS.md doc + test harness | Fully reversible |
| 2 | t2057 | GH#18740 | Wire into worktree-helper, claim-task-id, approval-helper | Depends on Phase 1 |

Phase 1 can ship without Phase 2 — the AI will start calling the helper from conversation intent as soon as the build.txt rule loads. Phase 2 adds the code-level safety net for paths the agent might miss.

### Phase boundary rationale

- **Phase 1** is the least-risk slice. The helper script is new code (no regression surface) and the prompt rule is additive. If there's a bug in the helper, it fails at claim time and the agent continues with a warning — no existing workflow breaks.
- **Phase 2** touches three hot paths (`worktree-helper`, `claim-task-id`, `approval-helper`). Shipping it after Phase 1 means Phase 2's integration bugs land against a helper that's already been exercised in interactive use for however long Phase 1 has been merged.

### Non-goals

- No new label.
- No new dispatch-dedup logic — reuse existing `in-review` handling.
- No `pre-edit-check.sh` fallback.
- No branch-name regex beyond what `worktree-helper.sh` already parses.
- No env-var opt-out for offline behaviour.
- No slash command or CLI is the primary path — they exist as fallbacks but the AI should never punt to them.
- Does not change NMR approval semantics — only adds an idempotent label-clearing side effect.

## Acceptance Criteria (parent)

- [ ] Phase 1 (GH#18739) merged — helper, prompt rule, tests, AGENTS.md doc
- [ ] Phase 2 (GH#18740) merged — worktree-helper, claim-task-id, approval-helper wiring + dedup multi-operator test extension
- [ ] Post-Phase-2: manual smoke test — create a worktree for an existing `origin:worker` issue, verify `status:in-review` + self-assignment applied automatically, verify pulse dispatch-dedup blocks a worker on the same issue
- [ ] Post-Phase-2: manual smoke test — `sudo aidevops approve issue <N>` on a contributor-filed issue carrying `status:in-review` clears the label idempotently

## Relevant Files

### Already in place (no change needed)

- `.agents/scripts/dispatch-dedup-helper.sh:957` — `_has_active_claim` already treats `status:in-review` as active claim
- `.agents/scripts/pulse-issue-reconcile.sh:285` — stale-recovery only resets `queued`/`in-progress`, `in-review` already skipped
- `.agents/scripts/shared-constants.sh:979` — `ISSUE_STATUS_LABEL_PRECEDENCE` already ranks `in-review` second after `done`
- `.github/workflows/issue-sync.yml:448` — PR-close cleanup already removes `status:in-review`

### Modified in Phase 1

- NEW: `.agents/scripts/interactive-session-helper.sh`
- NEW: `.agents/scripts/tests/test-interactive-session-claim.sh`
- EDIT: `.agents/prompts/build.txt` (add rule under Git Workflow)
- EDIT: `.agents/AGENTS.md` (document in Git Workflow section)

### Modified in Phase 2

- EDIT: `.agents/scripts/worktree-helper.sh` (call claim on create)
- EDIT: `.agents/scripts/claim-task-id.sh` (call claim after interactive new-task self-assign)
- EDIT: `.agents/scripts/approval-helper.sh` (idempotent release in `_post_issue_approval_updates`)
- EDIT: `.agents/scripts/tests/test-dispatch-dedup-multi-operator.sh` (+1 assertion)

## Dependencies

- **Blocked by:** none
- **Blocks:** none (internal framework improvement)
- **External:** none — reuses existing `gh` CLI and framework helpers

## Decision Log

1. **Reuse `status:in-review` vs new `status:interactive-session`** → reuse. Existing infrastructure already does the gating; broadening the semantics is cleaner than duplicating.
2. **AI-driven vs user-driven release** → AI-driven. The user never types a release command; the agent detects intent and acts.
3. **Offline fail-closed vs warn-and-continue** → warn-and-continue. Collision is harmless.
4. **`pre-edit-check.sh` fallback** → dropped. Fragile layered logic; sanctioned paths are enough.
5. **Branch-name regex** → dropped. `worktree-helper.sh` already parses branch names at `:495`; no new inference logic needed.
6. **Crypto approval release as primary path** → corrected to idempotent side effect. No new user friction.
7. **Phase count** → two, not three. Foundation + wiring. Release-polish folded into each phase as needed.
