# fix(task-id-guard): name the malformed token and where it was found

## What

When `task-id-collision-guard.sh` blocks on a malformed task identity, print the offending token and its source (commit subject, commit body, PR title or PR body). Today the report shows only the subject line and the sentinel `__malformed__ — malformed task identity`.

## Why

The `__malformed__` sentinel drops the token that tripped `task_identity_has_malformed_candidate` (`.agents/scripts/task-identity-lib.sh`). `_report_violations` then prints `Subject: <subject or PR title>` under the header "Commit subject references invented or unclaimed task ID(s)". That points the author at a valid subject.

Observed on 2026-11-14, PR #38218. The commit body and later the PR body contained the prose placeholder `tNNN: plan: ...`. The guard reported the valid subject `t18986: fix(dispatch): ...` as the violation. The author rewrote a valid subject twice locally, and CI failed (`Task-ID Collision Guard`, run 43558546885). Removing `tNNN` from the body fixed it. Fail-closed matching of `t[A-Z]...` placeholders is intended. Only the diagnostic is wrong. Every agent that writes a `tNNN`/`tXXX` placeholder in a commit or PR body pays this cost.

## How

- `.agents/scripts/task-identity-lib.sh`: add `task_identity_first_malformed_candidate <text>`. It prints the first candidate that `task_identity_has_malformed_candidate` would reject, using the same brief-path exclusion and trailing-dot rule. Factor the shared loop so the two cannot drift. Keep the `has_` return contract unchanged; `pulse-dep-graph.sh` and its tests consume it.
- `.agents/hooks/task-id-collision-guard.sh`:
  - Keep the `__malformed__` sentinel in `_extract_tids`. Do not change its grammar; pulse-dep-graph uses the same sentinel.
  - Where `_check_tid` handles the sentinel, look up the offending token with the new function. Report `  malformed task identity token '<token>' (in <source>); write <task-id> for placeholders`.
  - In check-pr mode, say whether the token is in the PR title or PR body. `_check_pr_title_body` (around `pr_combined=`) already has both. For commits, say subject or body.
  - Reword the `_report_violations` header so it does not say "Commit subject" when the scanned text was a body or PR text.

### Files Scope

- .agents/scripts/task-identity-lib.sh
- .agents/hooks/task-id-collision-guard.sh

## Acceptance

- A commit or PR body containing `tNNN: plan: ...` is still blocked. The report names `tNNN` and `body`.
- Valid IDs, padded legacy IDs (`t001` → `use t1`), brief paths and trailing-period IDs behave as before.
- `shellcheck -x` is clean on both files. These pass: `.agents/tests/test-pulse-dep-graph-blocked-by.sh`, `.agents/scripts/tests/test-pulse-dep-graph-prose-dependencies.sh`, and the existing `task-id-collision-guard` tests (`git ls-files '*task-id*guard*test*' '*test*task-id*'`).
