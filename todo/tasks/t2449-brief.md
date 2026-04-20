# t2449: Symmetric auto-merge for maintainer-briefed origin:worker PRs

## Pre-flight

- [x] Memory recall: `pulse-merge auto-merge worker briefed` -> 0 hits — no prior lessons on this topic
- [x] Discovery pass: 8 commits touch target files (`pulse-merge.sh`) since 2026-04-18; t2411 (PR #20103) landed the `origin:interactive` auto-merge gate that this task extends
- [x] File refs verified: `pulse-merge.sh`, `pulse-nmr-approval.sh`, `review-bot-gate.md`, `AGENTS.md` all present at HEAD
- [x] Tier: `tier:thinking` — disqualifier check clean (trust model change, composes with 3+ security gates, no existing pattern to copy)

## Session Origin

Filed from interactive session during post-merge monitoring of t2443 (PR #20158, `fix(pulse): unwrap preflight_daily_scans so each scanner gets independent timeout budget`).

The t2443 PR was maintainer-briefed (user filed the diagnostic issue #20149 with complete 3-option analysis), worker-implemented (picked up by pulse dispatch), fully green on CI (29/29 checks), zero `CHANGES_REQUESTED` human reviews. Every substantive prerequisite for an auto-merge was satisfied — yet the PR sat with `REVIEW_REQUIRED` branch protection blocking merge until the maintainer manually clicked.

The user correctly observed the trust-chain asymmetry: `pulse-merge.sh` auto-merges `origin:interactive` (maintainer typed the code) but NOT `origin:worker` (maintainer briefed + worker typed the code). Both have identical maintainer intent; only the typing hand differs.

Surfaced alongside t2448 (`ai-approved` admin-only hardening) — two related trust-model concerns raised in the same conversation.

## What

Extend `pulse-merge.sh` auto-merge to cover maintainer-briefed `origin:worker` PRs when ALL of the following hold:

1. PR carries `origin:worker` label.
2. Linked issue (via `Resolves #NNN` / `Closes #NNN` / `Fixes #NNN`) was authored by a user with `OWNER` or `MEMBER` association.
3. Linked issue never carried `needs-maintainer-review` OR NMR was cleared via **cryptographic** approval (not via `auto_approve_maintainer_issues`).
4. All required status checks PASS or SKIPPED.
5. No `CHANGES_REQUESTED` review from any reviewer with non-bot association.
6. PR is not a draft.
7. PR does not carry `hold-for-review` label.
8. PR passes `review-bot-gate` (existing t2123/t2139 mechanism — bots settled beyond `min_edit_lag_seconds`).
9. PR does not carry `origin:worker-takeover` (takeover PRs follow normal review flow — see Why/NOT below).

## Why

### Current state

`pulse-merge.sh` lines ~1015-1355 (t2411) implement the `origin:interactive` auto-merge gate: when a PR tagged `origin:interactive` and authored by `OWNER`/`MEMBER` passes all CI and review criteria, the pulse merges it automatically within one pulse cycle (4-10 min).

There is no symmetric gate for `origin:worker` PRs. Every worker-implemented PR requires a manual merge click — even when:
- The underlying issue was filed by the maintainer.
- The maintainer wrote a complete brief before dispatch.
- CI confirms the implementation is correct.
- No reviewer (human or bot) has objected.

### Cost of status quo

- **Redundant merge ceremony** on every worker PR. During active framework development, this is ~5-10 clicks/day.
- **Interactive sessions get slowed** to the speed of human typing a merge command, negating the autonomy value of worker dispatch.
- **Framework autonomy story is undermined** — "workers implement but maintainers still manually merge" ≠ "maintainers brief and the system executes". The user's concern raised this explicitly.
- **Worker idle time** between PR creation and manual merge blocks downstream dependent tasks (stacked PRs, issue chains).

### Trust-chain equivalence argument

`origin:interactive` + OWNER author = "maintainer typed the code" → current auto-merge allows.

`origin:worker` + OWNER-briefed issue + green CI + no human `CHANGES_REQUESTED` = "maintainer briefed; worker faithfully implemented; CI confirms implementation correctness; no human has objected" → equivalent trust chain.

The four cascading gates — maintainer brief, worker dispatch, CI verification, review window — collectively provide MORE scrutiny than a human typing the code in an interactive session (which has exactly one gate: the maintainer's own typing).

### Defence in depth remains intact

- **CI checks still run** (bugs caught at test runtime).
- **Bot review gate still runs** (style/security nits flagged via `review-bot-gate.sh`).
- **Human can ALWAYS apply `hold-for-review`** to opt out on any specific PR.
- **NMR lifecycle still gates** — if any NMR was applied to the issue or PR (whether by scanner, circuit-breaker, or human), the auto-merge path is closed until cryptographic approval clears it.
- **Worker-takeover path excluded** — if an `origin:interactive` PR went stale and got rescued via takeover, that indicates a human-authored attempt that needs scrutiny, not autonomous dispatch.

## How

### Files to modify

- **EDIT**: `.agents/scripts/pulse-merge.sh` — the existing `_attempt_interactive_auto_merge` (or equivalent name; locate via `grep -n "origin:interactive" pulse-merge.sh`). Extend to a **sibling function** `_attempt_worker_briefed_auto_merge` that mirrors the interactive gate with worker-specific criteria. The function must be a clean sibling, NOT an extension of the interactive path, so each gate can be disabled independently via feature flag.

- **NEW**: `.agents/scripts/tests/test-pulse-merge-worker-briefed.sh` — regression test harness. Must cover:
  - (a) `origin:worker` + issue-author-association=OWNER + green CI + no NMR history → auto-merges
  - (b) `origin:worker` + issue-author-association=MEMBER + green + no NMR → auto-merges
  - (c) `origin:worker` + issue-author-association=CONTRIBUTOR → does NOT auto-merge
  - (d) `origin:worker` + issue had NMR auto-approved (via `auto_approve_maintainer_issues`) → does NOT auto-merge (must be cryptographic)
  - (e) `origin:worker` + issue had NMR cleared via `sudo aidevops approve issue N` → auto-merges
  - (f) `origin:worker` + `hold-for-review` label → does NOT auto-merge
  - (g) `origin:worker` + human `CHANGES_REQUESTED` review → does NOT auto-merge
  - (h) `origin:worker` + draft PR → does NOT auto-merge
  - (i) `origin:worker-takeover` label → does NOT auto-merge (takeover always manual)
  - (j) Bot review still in placeholder window (`min_edit_lag_seconds`) → waits, doesn't merge yet

- **EDIT**: `.agents/AGENTS.md` "Auto-merge timing (t2411)" section — add a symmetric "Auto-merge timing (t2449) — `origin:worker`" section documenting the new gate with the same 9-criterion list.

- **EDIT**: `.agents/reference/review-bot-gate.md` — document how the bot gate composes with the new worker-briefed path. The bot gate is a prerequisite, not a replacement.

- **EDIT**: `.agents/prompts/build.txt` — if any user-facing rule mentions `origin:worker` PRs needing human review, update to reflect the new auto-merge path (grep `origin:worker` for any claims about manual-merge requirement).

### Model to copy

`pulse-merge.sh` lines 1015-1355 (t2411 `origin:interactive` path) is the structural template. Copy the gate-by-gate check pattern: each gate is a short function returning 0/1, and the top-level function short-circuits on first failure with an audit-log line naming the failing gate.

### Critical security gate: NMR cryptographic approval check

The MOST CRITICAL gate is **the "NMR was cleared cryptographically, not auto-approved" check**. Here's why:

`auto_approve_maintainer_issues` (in `pulse-nmr-approval.sh`) auto-clears NMR for machine-filed review-scanner issues. Using that as an auto-merge trigger would create a bypass vector: any review-scanner issue could auto-spawn a worker AND auto-merge without human touch — that's a closed loop with no human in the trust chain.

We need the **cryptographic approval signal** specifically. Detection logic:

```bash
# Has the linked issue's NMR ever been cleared, and if so, was it crypto?
if gh api "repos/$REPO/issues/$ISSUE/comments" \
    --jq '.[] | select(.body | test("aidevops:approval-signature:")) | .id' | head -1 >/dev/null; then
  # Crypto approval comment exists → legitimate clearance
  nmr_gate_pass=true
elif gh api "repos/$REPO/issues/$ISSUE/comments" \
    --jq '.[] | select(.body | test("auto-approved-maintainer-issue")) | .id' | head -1 >/dev/null; then
  # Auto-approval fired → NOT a legitimate clearance for auto-merge purposes
  nmr_gate_pass=false
else
  # NMR never applied → legitimate (never needed clearance)
  nmr_gate_pass=true
fi
```

### Feature flag

`AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE` env var, default `1`. Set to `0` to disable the new path and fall back to manual-merge-only for `origin:worker`. Validation window: 48h post-deploy; if any unexpected merge fires, flip to `0`, file follow-up, fix before re-enabling.

### Verification

- **Local dry-run**: `AIDEVOPS_DRY_RUN=1 pulse-merge.sh process-repo <slug>` with synthetic PRs in all 10 coverage cases. Dry-run should print decisions without acting.
- **Integration**: after merge, monitor first 5 `origin:worker` PRs on `marcusquinn/aidevops`. Confirm auto-merge matches expected gate behaviour for each case encountered.
- **Rollback**: if any unexpected merge occurs, flip `AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0` in `~/.aidevops/.env` or the pulse-wrapper defaults; pulse picks up on next cycle start.
- **Audit log**: every auto-merge decision writes a structured line to `~/.aidevops/logs/pulse-merge.log` with PR number, gate decisions, outcome.

## Acceptance Criteria

- [ ] `_attempt_worker_briefed_auto_merge` function implemented in `pulse-merge.sh` as a clean sibling to `_attempt_interactive_auto_merge`
- [ ] All 10 coverage cases in the regression test harness pass
- [ ] Feature flag `AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE` is respected (default: 1, set to 0 to disable)
- [ ] `.agents/AGENTS.md` "Auto-merge timing" section has the symmetric `origin:worker` subsection with full 9-criterion list
- [ ] `.agents/reference/review-bot-gate.md` documents the composition
- [ ] First 5 post-deploy `origin:worker` PRs on the framework repo merge correctly without user intervention (or correctly fail to merge for a documented reason)
- [ ] No regression in existing `origin:interactive` auto-merge path (existing test suite passes unchanged)
- [ ] NMR crypto-vs-auto-approval detection verified against both clearance paths (synthetic test with `auto_approve_maintainer_issues` output and with `approve-helper.sh` output)

## Files Scope

**MODIFY**:
- `.agents/scripts/pulse-merge.sh` — add sibling function
- `.agents/AGENTS.md` — documentation section
- `.agents/reference/review-bot-gate.md` — composition notes

**ADD**:
- `.agents/scripts/tests/test-pulse-merge-worker-briefed.sh` — regression harness

**Out of scope for this task**:
- Changes to NMR lifecycle or cryptographic approval mechanism (they stay as-is; we only consume their signals)
- Changes to `review-bot-gate` itself (composes with this, unchanged)
- Changes to `origin:interactive` auto-merge path (sibling function, not extension)
- Changes to `origin:worker-takeover` behaviour (takeover PRs remain manual-merge-only)

## Tier Checklist

- [x] Tier: **`tier:thinking`** (Opus)
  - Architecture work (trust model change)
  - Composes with 3+ existing gates (NMR crypto-vs-auto, review-bot, branch protection)
  - First-of-kind pattern (not a copy of any existing worker auto-merge)
  - Security-critical: the crypto-vs-auto NMR gate is subtle and easy to get wrong

**NOT `tier:simple`** because: changes trust model, requires reasoning about security composition, 4+ files, architectural judgment, no verbatim oldString/newString to hand to Haiku.

**NOT `tier:standard`** because: the trust-chain equivalence argument needs careful analysis; naive extension of the interactive path (copy-paste with new label check) is WRONG and would miss the NMR crypto-vs-auto gate, opening a bypass vector.

## PR Conventions

This issue is NOT `parent-task`. When implementing, the PR should use `Resolves #20164` as normal. The implementation PR title will be `t2449: symmetric auto-merge for maintainer-briefed origin:worker PRs`.

## Context & Decisions

Key decisions from the filing session:

- **Sibling function, not extension**: the `origin:worker` auto-merge path is a clean sibling of the `origin:interactive` path, NOT an extension. This was a deliberate design decision to keep the two gates independently disableable and independently modifiable. Mixing them creates coupling that makes either path hard to reason about in isolation.
- **Cryptographic approval as the NMR clearance signal**: the pulse's `auto_approve_maintainer_issues` uses the same GitHub token as the pulse itself. If auto-approval were accepted as the NMR clearance for auto-merge purposes, the entire chain (file issue -> auto-approve NMR -> dispatch worker -> auto-merge PR) would have zero human touchpoints. The SSH-signed cryptographic approval (`sudo aidevops approve issue N`) is the only signal that provably required a human with root access.
- **Worker-takeover explicitly excluded**: takeover PRs represent a human-authored attempt that went stale and was rescued by the pulse. The trust model is different from "maintainer briefed from scratch" — auto-merging a takeover would bypass the scrutiny the stale human work deserves.
- **Feature flag defaulting ON**: the 48h validation window with `AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0` as rollback was chosen over defaulting OFF because the entire point is reducing merge friction. Starting OFF would require a second PR to flip it, adding ceremony.
- **Approach A (sibling function) chosen over B (extending existing function with `origin:worker` label check)**: B was rejected because the NMR crypto-vs-auto gate does not exist in the interactive path and bolting it on would add dead-code complexity to a path that doesn't need it.

## Dependencies

- **Blocked by:** None — all prerequisites (t2411 interactive auto-merge, t2386 NMR automation-signature split, t2123/t2139 review-bot-gate) are already merged.
- **Blocks:** None directly — but landing this unblocks fully autonomous end-to-end worker dispatch (brief -> issue -> dispatch -> implement -> PR -> merge) without human merge clicks.
- **External:** None. Consumes existing GitHub API signals (issue author association, review state, check status) and existing framework signals (NMR crypto-approval comments, review-bot-gate).

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Read `_attempt_interactive_auto_merge` in pulse-merge.sh (~340 lines), `pulse-nmr-approval.sh` crypto-approval detection, `review-bot-gate-helper.sh` composition point |
| Implementation | 2h | New sibling function + feature flag + audit logging + AGENTS.md + review-bot-gate.md + build.txt updates |
| Testing | 1h | 10-case regression test harness + dry-run validation |
| **Total** | **~3.5h** | |

## Related

- **t2411** — original `origin:interactive` auto-merge (structural model)
- **t2123 / t2139** — review-bot-gate (prerequisite, composes with this)
- **t2443 / #20158** — motivating example: pulse stage-timeout fix; maintainer-briefed, worker-implemented, green, but required manual merge
- **t2448 / #20163** — ai-approved admin-only hardening (complementary trust-model work filed in same session)
- **t2386** — NMR automation-signature split: the split between "creation-default" NMR (cleared) and "circuit-breaker-trip" NMR (preserved) is what makes the cryptographic-vs-auto approval distinction viable
- **pulse-merge.sh `_release_interactive_claim_on_merge`** — existing lifecycle hook pattern; a `_release_worker_claim_on_merge` sibling may be needed if worker PRs hold claim stamps

## Relevant Files

- `.agents/scripts/pulse-merge.sh:1015-1355` — `_attempt_interactive_auto_merge` (structural template to mirror)
- `.agents/scripts/pulse-merge-lib.sh` — shared pulse-merge utilities
- `.agents/scripts/pulse-nmr-approval.sh:468-470` — `auto_approve_maintainer_issues` (the auto-approval path that must NOT count as legitimate clearance)
- `.agents/scripts/approve-helper.sh` — cryptographic approval implementation (SSH-signed comments)
- `.agents/scripts/review-bot-gate-helper.sh` — bot review gate (prerequisite check)
- `.agents/scripts/shared-constants.sh` — `ORIGIN_LABELS`, `set_origin_label` (label handling patterns)
- `.agents/scripts/tests/test-pulse-merge-interactive-auto-merge.sh` — existing test harness for interactive auto-merge (pattern to mirror)

## Deferred — DO NOT dispatch without maintainer approval

This task is filed without `#auto-dispatch`. The principled-fix brief is the deliverable; implementation is future work. Implementation should only begin when the maintainer:

1. Has had time to review the trust-chain equivalence argument above.
2. Confirms the 10-case test matrix is complete.
3. Decides on the validation window and rollback strategy.
4. Removes any dispatch-blocking label and adds `auto-dispatch` when ready.

The motivating pain (t2443 manual merge) is one data point — more observations during normal framework development will validate or refine the gate criteria.

## Notes

**Why `origin:worker-takeover` is excluded**: takeover happens because an `origin:interactive` PR went stale — that's a human-authored attempt that ran into trouble. Takeover PRs should follow the normal review flow so a human can verify the takeover logic did the right thing. Auto-merging a takeover would mean "the human gave up, and now the pulse is auto-finishing for them" — that's a different trust chain than "maintainer briefed, worker executed from scratch".

**Why cryptographic approval specifically**: the pulse runs as the maintainer's GitHub token. Auto-approval of maintainer-filed NMR'd issues (via `auto_approve_maintainer_issues`) uses the SAME token that the pulse uses — it's indistinguishable from "the maintainer approved" at the API level. Cryptographic approval via `sudo aidevops approve issue` requires the maintainer's root-protected SSH key, which workers cannot access. That key signature is the ONLY reliable human-in-the-loop signal on the maintainer's side.

**Why not extend `origin:interactive` path**: the two gates have subtly different criteria. `origin:interactive` trusts the maintainer's typing implicitly (single gate). `origin:worker` requires explicit verification of brief quality + worker faithfulness + NMR history. Mixing them creates coupling that makes either path hard to modify in isolation. Clean siblings compose better.
