<!-- aidevops:brief-schema=v2 -->

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `ambiguous explicit issue identities merge association For Ref worker partial PR` → 0 hits — no relevant lessons
- [x] Discovery pass: `prework-discovery-helper.sh` found 0 open related PRs for the target files; last relevant changes are d403c44b14 (explicit association added) and GH#34312 (8b6b30c5ad, partial continuation consumer)
- [x] File refs verified: `.agents/scripts/pulse-merge.sh` (`_extract_pr_work_issue`, explicit mode) and `.agents/scripts/tests/test-pulse-merge-extract-linked-issue.sh` (`test_explicit_merge_association`) checked at origin/main 035691f2f7
- [x] Tier: `tier:standard` — parser change on the merge-association trust path; fail-closed behaviour for genuine multi-target declarations is preserved
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-11
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Found while maximising worker throughput for a managed private repo's enrichment backlog: mergeable worker partial-delivery PRs were skipped by every merge pass on one runner.

## Problem

`_extract_pr_work_issue <pr> <repo> explicit` in `.agents/scripts/pulse-merge.sh` (added by d403c44b14) marks a `For #N` / `Ref #N` declaration line ambiguous when **any** `#N` appears later on the same line:

```awk
sub(/^[0-9]+/, "", line)
# Multiple declarations on one line are not a unique task.
if (line ~ /#[0-9]+/) print "ambiguous"
```

Worker partial-delivery PRs conventionally open with `For #N.` followed by context prose on the same line, for example `For #101. Continuing the merged checkpoint from PR #99.` or `For #101. Ready partial delivery; do not close the issue or tracker #90.` The same sentence on its own line is ignored, but on the declaration line it is counted as a second declaration, so the PR gets no merge association.

Observed on one runner (2026-10-11, a managed private repo):

- `_check_pr_merge_gates` returns 1 for `origin:worker` PRs without a closing target when explicit association fails, before any other merge gate is evaluated. Five open, non-draft worker PRs with `mergeStateStatus=CLEAN` log `has ambiguous explicit issue identities — no merge association` every merge pass (one of them 100 times since 2026-10-09); two drafts carry the same shape.
- Across the 19 declaration lines of open worker PRs in that repo, 7 are ambiguous under the current rule and 0 under the proposed rule. In the last 150 merged worker PRs, 4 more declaration lines have the same false-ambiguity shape.
- The same resolver gates `_pulse_merge_admin_safety_check` (fails closed) and `_pm_restore_partial_continuation` (`|| return 0`, so the GH#34312 return-to-queue path is skipped for this shape).

Genuine multi-target declarations must stay ambiguous, e.g. `For #34125. For #34147.` (PR #34162 in this repo) and a parenthetical target list such as `For #105 (parent gate #89 / t018).`

## Proposed fix

Bound the declaration's target list at the first sentence/clause terminator (`.`, `;`, `!` or `?` followed by whitespace or end of line):

1. Another `#N` inside that clause stays ambiguous: `For #42 and #43`, `For #42, #43`, `For #42 and Ref #43`, `For #42 (see #41).`
2. After the clause, only another `For`/`Ref` `#N` declaration on the same line stays ambiguous: `For #42. Ref #43.`
3. Incidental references in later sentences (`PR #99`, `tracker #90`) are context, exactly as they already are on their own line.
4. No terminator → the whole remainder is the clause (current behaviour).

No change to closing-target precedence, fence/comment/quote/secondary-section handling, multi-line ambiguity, cross-repository rejection, or repair mode.

### Files Scope

- `.agents/scripts/pulse-merge.sh`
- `.agents/scripts/tests/test-pulse-merge-extract-linked-issue.sh`

## Reference pattern

- Explicit-mode awk parser in `_extract_pr_work_issue` (`.agents/scripts/pulse-merge.sh`) and its fixtures in `test_explicit_merge_association` (`.agents/scripts/tests/test-pulse-merge-extract-linked-issue.sh`).
- Consumers: `_check_pr_merge_gates` (`pulse-merge.sh`), `_pulse_merge_admin_safety_check` (`pulse-merge-gates.sh`), `_pm_restore_partial_continuation` (`pulse-merge-partial-continuation.sh`).

## Verification

- `bash .agents/scripts/tests/test-pulse-merge-extract-linked-issue.sh` passes, including new cases: context after `For #N.` associates N; `For #42, #43`, `For #42 and #43.`, `For #42. Ref #43.` and `For #42 (see #41).` fail closed.
- Sibling suites that exercise explicit association pass: `test-pulse-merge-partial-continuation.sh`, `test-pulse-merge-admin-safety-check.sh`, `test-pulse-merge-worker-briefed.sh`.
- ShellCheck clean on changed scripts.
- Runtime: after deploy, the affected PRs no longer log `has ambiguous explicit issue identities` and proceed to the normal merge gates.
