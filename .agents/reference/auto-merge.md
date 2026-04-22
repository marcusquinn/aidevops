# Auto-Merge Reference

Full detail for the two pulse auto-merge gates. For the one-line summary, see `AGENTS.md` "Auto-Dispatch and Completion".

## t2411 — `origin:interactive` Auto-Merge

`pulse-merge.sh` automatically merges `origin:interactive` PRs from `OWNER`/`MEMBER` authors once ALL criteria hold:

1. PR carries the `origin:interactive` label.
2. PR author has `admin` or `maintain` permission on the repo (OWNER or org MEMBER — write-only COLLABORATORs go through the normal review gate instead).
3. All required status checks PASS or SKIPPED.
4. No `CHANGES_REQUESTED` review from a human reviewer.
5. PR is **not a draft** — convert to ready (`gh pr ready <PR>`) before the pulse picks it up.
6. PR does **not** carry the `hold-for-review` label.

Merge typically happens within one pulse cycle (4-10 minutes) after all checks go green. Review bots (gemini-code-assist, coderabbitai) post within ~1-3 minutes. Audit log line: `[pulse-merge] auto-merged origin:interactive PR #N (author=<login>, role=<role>)`.

**To opt out of auto-merge on a specific PR:** apply the `hold-for-review` label. Remove it when ready.

**Folding bot nits into the same PR — options:**
- `review-bot-gate-helper.sh check <PR>` before pushing — streams current bot feedback.
- `gh pr create --draft`, wait for reviews to settle, `gh pr ready <PR>` when content is final.
- Accept the window and file a follow-up PR for nits.

**Note:** "pulse never auto-closes `origin:interactive` PRs" applies to AUTO-CLOSE (abandoning stale incremental PRs on the same task ID), NOT to auto-merge of green PRs. These are separate pulse actions.

## t2449 — `origin:worker` (Worker-Briefed) Auto-Merge

`pulse-merge.sh` also auto-merges `origin:worker` PRs when the underlying issue was **maintainer-briefed** (filed by `OWNER`/`MEMBER`). Trust chain is equivalent to interactive: maintainer brief + worker implementation + CI verification + no human objection.

ALL criteria must hold:

1. PR carries the `origin:worker` label.
2. Linked issue (via `Resolves #NNN` / `Closes #NNN` / `Fixes #NNN`) was authored by a user with `OWNER` or `MEMBER` association.
3. Linked issue never carried `needs-maintainer-review` OR NMR was cleared via **cryptographic** approval (`sudo aidevops approve issue N`), not via `auto_approve_maintainer_issues`.
4. All required status checks PASS or SKIPPED.
5. No `CHANGES_REQUESTED` review from any reviewer with non-bot association.
6. PR is **not a draft**.
7. PR does **not** carry the `hold-for-review` label.
8. PR passes `review-bot-gate` (bots settled beyond `min_edit_lag_seconds`).
9. PR does **not** carry `origin:worker-takeover` (takeover PRs follow normal review flow).

Feature flag: `AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE` (default `1`=on). Set to `0` to fall back to manual-merge-only for `origin:worker` PRs.

Audit log: `[pulse-merge] auto-merged origin:worker (worker-briefed) PR #N (author=<login>, linked_issue=#M)`.

Test coverage: `.agents/scripts/tests/test-pulse-merge-worker-briefed.sh` (10 cases).

### Security Gate: NMR Crypto-vs-Auto Distinction (Criterion 3)

`auto_approve_maintainer_issues` runs as the pulse's own GitHub token — if auto-approval were accepted as NMR clearance, any review-scanner issue could auto-spawn a worker AND auto-merge without human touch (closed loop).

Cryptographic approval (`sudo aidevops approve issue N`) requires the maintainer's root-protected SSH key, which workers cannot access — this is the only reliable human-in-the-loop signal.

## NMR Automation Signatures (t2386, Split Semantics)

The pulse runs as the maintainer's GitHub token, so `needs-maintainer-review` label events always record the maintainer as actor. `auto_approve_maintainer_issues` in `pulse-nmr-approval.sh` distinguishes three cases by comment markers:

- **Creation-default** (`source:review-scanner` comment marker, or `review-followup` / `source:review-scanner` label on issue) → scanner applied NMR by default at creation time; auto-approval CLEARS NMR so the issue can dispatch.
- **Circuit-breaker trip** (`stale-recovery-tick:escalated`, `cost-circuit-breaker:fired`, `circuit-breaker-escalated` comment markers) → t2007/t2008 safety mechanism fired after retry/cost limit exceeded; auto-approval PRESERVES NMR. Clear with `sudo aidevops approve issue <N>` once the underlying problem is fixed.
- **Manual hold** (no markers) → genuine maintainer decision to pause the issue; auto-approval PRESERVES NMR.

**Background — why the split matters:** Pre-t2386, both automation cases were conflated. The result was the GH#19756 infinite loop: stale-recovery applied NMR → auto-approve stripped it → worker re-dispatched → crashed → stale-recovery re-applied NMR. 22 watchdog kills + 5 auto-approve cycles in one afternoon. The split prevents this by preserving NMR on circuit-breaker trips.

Two helpers enforce the split: `_nmr_application_has_automation_signature` (creation defaults only) and `_nmr_application_is_circuit_breaker_trip` (breaker trips only). Regression test: `.agents/scripts/tests/test-pulse-nmr-automation-signature.sh::test_19756_loop_prevention_breaker_trip_preserves_nmr`.
