<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Review Bot Add-on Policy (t1382, GH#3827, GH#17541)

**Permanent default:** required project CI controls merge readiness. Code-quality
add-ons such as CodeRabbit are advisory: absent, pending, unavailable,
rate-limited, or late results never delay a trusted maintainer-controlled PR.
Late feedback is swept after merge and filed as worker-ready follow-up issues.

CodeRabbit posts `COMMENTED` reviews (`.coderabbit.yaml`
`request_changes_workflow: false`, GH#35860), so its findings never set
`reviewDecision=CHANGES_REQUESTED`. Re-enabling formal change requests restores
the t2093 close-and-redispatch loop for every worker PR CodeRabbit comments on.

Gemini Code Assist's retired GitHub review integration is legacy-only. The
framework still recognizes its historical comments, reviews, and threads, but
does not advertise it as active, accept new per-tool policy, or let stale
`gemini-code-assist` wait/strict overrides block current merges. Use
`aidevops review-gate <repo> --tool gemini-code-assist unset` to remove each
legacy field. The retained identity filters make a future restoration reversible.

Repositories with an exceptional sensitivity requirement may explicitly opt into
review-before-merge with `review_gate.completion_behavior: strict`. Strict is
never the framework default. Mirror strict CI intent with the repository Actions
variable `AIDEVOPS_REVIEW_GATE_COMPLETION_BEHAVIOR=strict`.

Review bots never hold merge progress by default, for any author (GH#36931).
Their findings become follow-up issues. The GH#17671 external-contributor trust
boundary is exact-head maintainer cryptographic approval, enforced by Pulse and
full-loop before every merge transport, not by waiting for a bot review.

## Enforcement Layers

1. **CI**: `.github/workflows/review-bot-gate.yml` may remain a required compatibility
   status, but default missing/late review emits `PASS_ADVISORY` and succeeds. It
   blocks for missing completion only under explicit strict policy. Same-repository
   PRs are evaluated on `pull_request`. Fork PRs are evaluated on `pull_request_target`,
   because fork `pull_request` tokens cannot post the status (GH#36961). The fork run
   checks out only `main`'s aidevops scripts, never PR code (GH#36954).
2. **Pulse merge path**: `review-bot-gate-helper.sh status-json` supplies typed,
   exact-head evidence. `PASS_ADVISORY` is valid for every author on a stable
   head; `SKIP` (label) is valid only for trusted authors.
3. **Worker merge path**: `full-loop-helper.sh merge` accepts the same default
   advisory outcome after required CI succeeds.
4. **Branch protection**: a required `review-bot-gate` context is compatible with
   this policy because it reports success for advisory outcomes.

All layers share the same `review-bot-gate-helper.sh` implementation — the settlement
check and completion behaviour are consistent across CI and in-agent merge paths (GH#20493).

## Merge Commands

| Context | Command | Gate |
|---------|---------|------|
| Worker (full-loop) | `full-loop-helper.sh merge <PR> [REPO]` | Advisory by default; strict opt-in blocks |
| Pulse (deterministic) | Internal `_merge_ready_prs_for_repo` | Typed advisory/strict evidence |
| Manual (interactive) | `review-bot-gate-helper.sh check <PR> [REPO]` | Read available feedback without default delay |

Workers MUST use `full-loop-helper.sh merge` — direct `gh pr merge` bypasses the gate (GH#17541).

## Superseded CodeRabbit change requests

The full-loop readiness gate may dismiss a stale CodeRabbit `CHANGES_REQUESTED`
review only when every active blocker is the exact `coderabbitai[bot]` identity,
each blocking review names a non-current commit, and the trusted bot subsequently
posts both the addressed marker and the deterministic “no blocking findings”
message for the exact current SHA. The current SHA must also have a terminal-
success `CodeRabbit` status context from a trusted PR author.

The helper reduces each reviewer's history to their latest state-changing review,
re-reads the head immediately before each dismissal, and re-reads the aggregate
review decision afterward. The merge transport checks the exact-head aggregate
again immediately before mutation. Human or mixed reviewers, current-head
requests, head drift, malformed evidence, missing/failed/pending status, and
untrusted authors remain blocking. This is separate from the maintainer-applied
`coderabbit-nits-ok` cosmetic override; the shared helper independently verifies
that label while reusing reviewer enumeration and dismissal mechanics.

## Workflow

- Before merging, run `review-bot-gate-helper.sh check <PR_NUMBER>` to collect
  available feedback. Default no-response output is `PASS_ADVISORY`, not `WAITING`.
- `WAITING` means the repository explicitly selected strict/wait behavior.
- `skip-review-gate` remains an auditable internal exception for strict setups;
  default advisory repositories do not need it.
- ALWAYS read bot reviews that are available before merging. Address critical/security findings; note non-critical suggestions for follow-up.
- `PASS_ADVISORY` means no completed add-on review was required under the permanent
  default. `PASS_RATE_LIMITED` is the narrower true-rate-limit outcome. Both
  delegate late feedback to the post-merge scanner for exact-head PRs from any
  author. API-exhausted runs do not retry immediately. Explicit `wait` or
  `strict` policies remain fail-closed.
- When many PRs are rate-limited simultaneously, use `request-retry` on the highest-priority PRs first. Stagger retries to avoid re-triggering rate limits.

### External PR review-limit recovery (GH#36900)

Only strict/wait repositories can leave an external PR `WAITING`. There, after
independent author, issue, and approval gates pass, Pulse requests a review
retry when the PR has valid current-head `WAITING` evidence. It verifies
managed-repository write authority and rechecks that the PR is open, non-draft,
not held for review, and still on the observed head before calling the shared
`request-retry` command. That command owns bot-notice detection and idempotency;
historical-review and per-head retry handling is tracked by GH#36899.

Requesting review never clears the gate in the same invocation. Subsequent bot
events or Pulse passes must observe successful review evidence normally. Missing,
malformed, API-error, head-drift, and trusted-author outcomes do not request this
external recovery. No labels, approvals, commit statuses, or branches are changed.

## Additive suggestion decision tree

When a review bot comments with a suggestion that isn't a correctness issue in the PR's own code:

0. **Does the finding target a framework-managed workflow caller?** These
   `.github/workflows/*.yml` files carry a `Managed by aidevops` header and are
   rendered from `.agents/templates/workflows/*-caller.yml`. Other managed
   copies have no shared parity check here; use steps 1-3. From the PR worktree, confirm
   parity with `aidevops check-workflows --workflow <name> --repo <owner/repo>`
   and note the reported evidence source; without `--repo` it reads the
   registered checkout, not the PR worktree.
   - A local content change is drift that `sync-workflows` overwrites. Reply on
     the thread with that parity evidence, then **resolve the thread**. An
     unresolved bot thread blocks merge (GH#27137) even after a reply.
   - A `uses:` `@ref` / `aidevops_ref` pin is not drift: parity ignores refs
     and `sync-workflows` preserves existing pins unless `--force-ref` is set.
     Pinning is a per-repository operator choice; keep the template ref unless
     the operator asked for a pin, say so in the reply, and resolve the thread.
   - Do not file a follow-up for intentional template design, such as a
     template's `@main` reusable-workflow ref.
   - Only a concrete template defect goes to
     `framework-issue-helper.sh log`, targeting the template, not the copy.
   - Not a managed workflow caller → go to 1.

1. **Is the suggestion a correctness fix for code introduced by this PR?**
   - Yes → expand the PR, add a commit, re-request review.
   - No → go to 2.

2. **Is the suggestion adding coverage, generality, new behaviour, or cosmetic improvements?**
   - Yes → file as follow-up task with `ref:GH#<current-PR>`.
   - No → skip (may be a nit; see the `coderabbit-nits-ok` rule in AGENTS.md "Review Bot Gate").

3. **File follow-up via:**
   - Claim task ID (`claim-task-id.sh`).
   - Write brief in the current planning worktree.
   - File issue with worker-ready body + `Source: review comment on PR #<N> by @<bot>` citation.

### Example

PR #19712 (t2209) Gemini review suggested extending the duplicate-ID regex to cover declined tasks and routine IDs. This is additive (broader coverage), not a correctness fix for the PR's shipped behaviour. Filed as t2222 / #19723.

See also: AGENTS.md "Review Bot Gate (t1382)" for the authoritative rule and rationale.

The same follow-up pattern applies to advisory CI: slow E2E, visual, performance,
or integration checks that are not required for the target branch should file
worker-ready follow-up tasks unless they prove a defect introduced by the PR.
See `ci-gate-policy.md`.

## Composition with auto-merge paths

The review add-on check runs after the `origin:interactive` (t2411) and
`origin:worker` worker-briefed (t2449) gates. This means:

- **Default trusted PRs**: `PASS_ADVISORY` clears the add-on check once required
  project CI and independent trust gates pass; bot response time is irrelevant.
- **Strict repositories**: `completion_behavior: strict` requires settled review
  evidence. `min_edit_lag_seconds` still protects CodeRabbit's two-phase pattern.
- **Repository-generated Issue Sync PRs**: GitHub reports the official Actions bot
  as `CONTRIBUTOR`. The reusable CI gate and shared review helper normalize it as
  internal only when the immutable bot ID/type, same-repository head and base,
  deterministic `aidevops/issue-sync-todo` branch, and generated body marker all
  match. For `issue_comment` events that omit head/base metadata, CI asks the
  shared helper to classify one live REST pull payload. This keeps CI,
  interactive merge, and Pulse decisions aligned. Full-loop and Pulse bind the
  same classifier to the already verified merge head before granting generated
  PR authority or approval. Pulse creates approvals with REST `commit_id` bound
  to that head and verifies the response; full-loop refreshes mutable authority
  before every retry or fallback merge transport. Any missing or mismatched
  field remains external and fail-closed.
- **External contributors**: advisory and rate-limit outcomes pass like any
  other author (GH#36931); the skip label is denied. Merge still requires the
  approved linked issue plus V2 maintainer approval of the exact current head,
  re-verified immediately before every merge transport.

The helper is still evaluated and audited on every merge path; advisory is an
explicit successful policy outcome, not a bypass. Draft, `hold-for-review`, human
`CHANGES_REQUESTED`, required CI, exact-head, and maintainer gates remain independent.
