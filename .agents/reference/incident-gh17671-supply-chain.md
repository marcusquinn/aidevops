<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Incident: GH#17671 supply-chain attack via auto-approved PR

**Date:** April 2025 (open) → April 2025 (remediation) → April 2026 (defense-in-depth, this doc).
**Severity:** Critical — would have shipped attacker-controlled GitHub Actions code into the default branch if the merge had completed.
**Status:** Closed without merge. Live exploit gated by PR #17868 + #17877. Function-level regression guard added in t2933 (this doc).

This is the canonical postmortem for the only known supply-chain attempt against this repo. Read it before touching `pulse-merge.sh`, `maintainer-gate.yml`, the review-bot gate, or anything else in the auto-merge cascade. The entire chain is the defense; removing any one layer reopens the hole.

## Threat actor

- **Profile shape:** drive-by external contributor (`authorAssociation: NONE` on every PR filed). Account created within weeks of the attack with a high public-repo count (~1650) — a low-cost reputation-padding pattern. Public profile cross-references a blog → `hashgraph-online` org, which controls the action the malicious PR invoked.
- **Pattern after #17671:** at least seven follow-up PRs (#17865, #17862, #17815, #17743, #17742, #17731, #17718) with similar shape — workflow-file injection, no engagement, fire-and-forget. All closed without merge.
- **Username intentionally redacted:** the public PR/issue numbers above remain the audit trail; identifying labels are out of band per maintainer policy ("don't make bad actors famous").

## What happened

PR #17671 was a single-file change adding a `.github/workflows/*.yml` whose only job was `uses: hashgraph-online/skill-publish@<sha>` — i.e. invoking an action the attacker controlled. Because GitHub Actions configured via `on: push:` and `on: pull_request:` run on every event in the repo, merging that workflow file would have given the attacker arbitrary code execution on every subsequent CI run, including with read access to repository secrets.

The PR was filed against `main`. The auto-merge cascade in `pulse-merge.sh` engaged. Three independent gates would each have stopped the merge IF correctly designed; all three had latent gaps:

| Layer | What it was supposed to do | What it actually did in April 2025 |
|---|---|---|
| `maintainer-gate.yml` Check 0 | Verify a PR with no linked issue, or a linked issue without a `needs-maintainer-review` label, was authored by a collaborator | Did not exist. The gate only inspected linked-issue labels. PR #17671 linked no issue, so the gate trivially passed. |
| `_check_pr_merge_gates` | Inspect PR author collaborator status before invoking `approve_collaborator_pr` | Did not include an author check; trusted the upstream gates. |
| `approve_collaborator_pr` | Auto-approve a PR claimed to be from a collaborator | Trusted its `$pr_author` argument. The body string read "Auto-approved by pulse — collaborator PR" regardless of whether the author was actually a collaborator. |

The PR was approved with a message asserting collaborator status it had never verified. The merge was prevented only because a maintainer noticed the timeline activity in time and intervened manually. There was no automated reason it would have been blocked.

## Remediation timeline

- **PR #17868** (`hotfix/remove-unauthorized-hol-action`): physically removed the malicious workflow that the attacker had attempted to land. The merge of this hotfix was itself reverted as part of the cleanup once the threat was contained — it served to prevent the workflow file from ever existing in `main`.
- **PR #17877** (`hotfix/protect-pr-nmr-label`): made the `needs-maintainer-review` label survive the pulse's automated label cleanup, so a maintainer applying it to a suspicious PR could not be silently overridden by the next pulse cycle.
- **t1958** (`maintainer-gate.yml` Check 0): added a hard gate at the workflow layer that fails the maintainer gate when a PR has no linked issue AND the PR author is not a collaborator. This is the primary surface that closed the live exploit.
- **`_check_pr_merge_gates` line ~1060** (in `pulse-merge.sh`): added an upstream call to `_is_collaborator_author "$pr_author" "$repo_slug"` before invoking `approve_collaborator_pr`. Closes the gap at the merge-cycle layer regardless of what the workflow surface does.
- **External-contributor exclusions** (`review-bot-gate.yml`, `.coderabbit.yaml`): rate-limit grace and prioritised review pathways are now strictly disabled for non-collaborator authors, so reviews from those PRs cannot accidentally feed back into the auto-merge cascade.
- **t2933 (this doc):** added a function-level guard inside `approve_collaborator_pr` itself. The function now refuses to call `gh pr review --approve` when its `$pr_author` argument is not a collaborator, regardless of whether any upstream gate happened to perform the same check. Pinned by `.agents/scripts/tests/test-pulse-merge-approve-collaborator-guard.sh`.

## Root cause

The single primary lesson is **trust boundaries inside a deep helper chain are invisible to readers and silent to refactoring tools**. `approve_collaborator_pr` was named as if it had verified collaborator status; in fact it trusted its caller to have done so. Three years of accumulated callers all complied with that contract because none of them were adversarial; the moment one external author got past one upstream gate, the function happily attached a misleading approval body asserting a property it had never checked.

This is a general pattern. Helpers named `do_X_for_authorized_Y` whose body contains no check that Y is actually authorized are a structural red flag. The name encodes the contract; the body must enforce it, or the contract is documentation, not code. The hardening in t2933 is the function self-enforcing the property its name asserts.

The secondary lesson is **the misleading approval body** ("Auto-approved by pulse — collaborator PR") was itself part of the failure surface. When the PR was reviewed in the timeline, the body sounded authoritative; a human glancing at the cascade saw no obvious flag. Approval messages MUST describe the checks actually performed, not the property the function is named for. The t2933 fix changes the body to "Auto-approved by pulse runner @USER — author @AUTHOR confirmed collaborator, pre-merge gates passed." which can only be true if the new guard let it through.

## Defense-in-depth layers (current state)

```text
External PR opens
       │
       ▼
maintainer-gate.yml Check 0 ──── fail if (no linked issue) AND (author not collaborator)
  [Layer 1 — workflow level]      t2937/GH#21154: now propagated to ALL pulse: true repos
       │                          via aidevops sync-workflows (maintainer-gate-reusable.yml
       │                          + per-repo caller). Before t2937, only the aidevops repo
       │                          itself carried this layer.
       ▼
review-bot-gate.yml ──────────── external-contributor exclusion blocks rate-limit grace
  [Layer 2 — workflow level]
       │
       ▼
_check_pr_merge_gates ────────── _is_collaborator_author on PR author (line ~1060)
  [Layer 3 — pulse-side]
       │
       ▼
approve_collaborator_pr ──────── self-check: refuses approval if author not collaborator (t2933)
  [Layer 4 — function level]      pinned by test-pulse-merge-approve-collaborator-guard.sh
       │
       ▼
gh pr merge --admin
```

Each layer is independently sufficient to block a non-collaborator PR. The layered design is intentional: any single layer can be removed by future work without re-opening the hole.

**Layer 1 generalisation (t2937):** before this task, only the aidevops repo carried `maintainer-gate.yml` at the workflow layer. Every other `pulse: true` repo was protected by layers 3 and 4 (pulse-side) only. t2937 converts the gate to a reusable workflow (`maintainer-gate-reusable.yml`) and propagates a caller template to all downstream repos via `aidevops sync-workflows`. See `reference/reusable-workflows.md` §"maintainer-gate (t2937 — security layer 1)".

## Test pinning

`.agents/scripts/tests/test-pulse-merge-approve-collaborator-guard.sh` pins the function-level contract with four cases:

- **Case A:** collaborator author + collaborator runner + runner ≠ author → approval fires with the t2933-corrected body.
- **Case B (regression of GH#17671):** non-collaborator author + collaborator runner → guard refuses approval, logs the GH#17671/t2933 audit attribution. **This case fails immediately if the function-level guard is removed**, regardless of the state of upstream gates.
- **Case C:** self-authored PR (runner == author) → skipped; `--admin` merge handles it.
- **Case D:** runner lacks write access → skipped (predates t2933, still required).

The test is registered in `.github/workflows/code-quality.yml` so a regression cannot land without a CI failure.

## Generalising

Apply this pattern whenever a helper claims a property in its name (`approve_X`, `merge_X`, `delete_X` for authorized `X`) but inherits the property from caller arguments. Two minimum requirements:

1. **The function self-validates.** If the function name claims `X is authorized`, the function body must check that, even when callers also do.
2. **Output reflects checks actually performed.** Approval bodies, audit logs, success messages must not assert properties that the function did not verify in the current invocation.

This is one specific application of the broader "Worker scope enforcement" rule (`AGENTS.md` § 7b) and the "Defense-in-depth" principle in security-critical paths.

## Cross-references

- Prior hardening: PRs #17868, #17877, t1958.
- Function-level fix: t2933, `pulse-merge.sh:331-399`, `_is_collaborator_author` at `pulse-merge.sh:1544-1558`.
- Regression test: `.agents/scripts/tests/test-pulse-merge-approve-collaborator-guard.sh`.
- CI registration: `.github/workflows/code-quality.yml` ("Approve Collaborator Author Guard" step).
- Public-repo coverage gap: 13 pulse-enabled public repos still lack `maintainer-gate.yml` (see `aidevops check-workflows`). Tracking issue to make `maintainer-gate.yml` reusable and add to `aidevops sync-workflows` is filed separately.
