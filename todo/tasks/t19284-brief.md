## What

Add t2449 linked-issue trust waits to the maintainer decision queue (`maintainer-decisions-helper.sh list`). A t2449 wait is an open worker PR that only a signed maintainer approval (`sudo aidevops approve issue <N> <repo>`) can unblock. List each one as a `kind=approve` record with that exact command. Also stop the trust-parity test from writing a fixture marker into the live pulse state directory.

## Why

- The pulse already records these waits. In the trust check behind `worker_briefed_trust_verdict`, `.agents/scripts/pulse-merge-process-worker-briefed.sh:552-561` sets `_WORKER_BRIEFED_PERMANENT_BLOCK=untrusted_issue_author_no_crypto_approval`. `_worker_briefed_sync_permanent_block_marker` (line 844) then writes `<head_sha>\t<block_class>\t<epoch>` to `${PULSE_T2449_BLOCK_STATE_DIR:-~/.aidevops/.agent-workspace/pulse-t2449-permanent-blocks}/<owner>--<repo>--pr-<N>` (the path is built at line 701). For workflow-bot issues, `_worker_briefed_record_bot_decision` (line 610) posts the approval command once, as a comment on the linked issue.
- The queue cannot see these waits. `maintainer-decisions-helper.sh` finds issues through `MD_HOLD_LABELS`/`MD_ASK_LABELS` (lines 79-82) and PRs through `hold-for-review` only (line 296). `_md_classify_pr` drops any PR without that label (line 191), and its `approve` kind covers only `release-approval-required` PRs (lines 192-194, 226). A t2449-blocked worker PR and its linked issue carry none of these labels.
- Observed 2026-11-22: in a managed product repo, a worker PR that was CLEAN and APPROVED had waited 6 days on `sudo aidevops approve issue <N>`. Its linked issue was authored by `app/github-actions` (TODO sync), so `author_association=NONE`. The command appeared only in an issue comment and a PR comment, and the PR was absent from `maintainer-decisions-helper.sh list --repo <that repo>`. Two PRs in other managed repos were in the same state, and the marker directory held 16 markers, some of them stale. The maintainer should not have to read issues to find a merge only they can unblock; `/decisions` should be the single place to look.
- Fixture leak: `.agents/scripts/tests/test-worker-briefed-trust-parity.sh` isolates only `TMPDIR` (lines 17-20). Its call to `_attempt_worker_briefed_auto_merge 100 owner/repo ...` (line 172) writes `owner--repo--pr-100` into the real state directory; one was observed with mtime 2026-11-22 04:07. Once the queue reads that directory, a leaked marker becomes a bogus queue row.

## How

1. Add `MD_T2449_DIR="${PULSE_T2449_BLOCK_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/pulse-t2449-permanent-blocks}"`. This is the same default as `.agents/scripts/pulse-dispatch-current-state-guardrails.sh:132`.
2. Add `_md_t2449_refs`, which prints `owner/repo\tnumber\thead_sha\tepoch`, one line per marker. Keep only regular files whose name matches `^[A-Za-z0-9_.-]+--[A-Za-z0-9_.-]+--pr-[0-9]+$`, whose first field is a 40-hex SHA, and whose second field is `untrusted_issue_author_no_crypto_approval`. Skip the `non_closing_reference_not_open` class; it is AI-repairable and GH#39873/t19282 owns it. Map the name to a slug by splitting on the first `--`, then require the slug to be in `_md_managed_slugs`, or equal to `MD_REPO` when `--repo` is set.
3. Add `_md_classify_trust_pr repo number head epoch now`, modelled on `_md_classify_pr` (line 461). It reads `gh pr view N --repo R --json number,title,url,state,isDraft,headRefOid,closingIssuesReferences` and prints nothing unless the PR is OPEN, non-draft, and `headRefOid == head`; a newer push means the pulse re-evaluates it. If `closingIssuesReferences` does not hold exactly one issue, emit `_md_error_record`. Otherwise emit one record in the existing PR schema: `kind: "approve"`, `type: "pr"`, `reason: "t2449_issue_trust"`, `asked_src: "t2449_marker"`, `age_days` from the marker epoch, a question naming the linked issue (for example "linked issue #N is not maintainer-authored; sign it so pulse can merge this PR"), and `command: "<approval_cli_prefix> approve issue <N> <repo>"` (`approval_cli_prefix` comes from `shared-approval-cli.sh` through `shared-constants.sh`; keep the `sudo aidevops` fallback used at line 491).
4. In `_md_list` (line 551), after the held-PR loop, classify each t2449 ref whose `repo\tnumber` is not already in `pr_refs`. A PR that also carries `hold-for-review` stays a `held-pr`, because approving the issue alone cannot merge it. Apply the same `MD_MAX` cap.
5. Rename the `approve` heading (line 238) to "Needs your signed approval (held PRs)", and add the t2449 source to `_md_usage` and the header comment (lines 26-28).
6. In `test-worker-briefed-trust-parity.sh`, export `PULSE_T2449_BLOCK_STATE_DIR="${TEST_ROOT}/t2449-blocks"` next to `TMPDIR` (line 20). Run `rg -ln "_attempt_worker_briefed_auto_merge|worker_briefed_trust_verdict|_worker_briefed_sync_permanent_block_marker" .agents/scripts/tests` and add the same export to each test that reaches the marker sync without setting it. `test-pulse-merge-not-open-reference-flag.sh` already sets it.

### Complexity Impact

`_md_list` is 41 lines and grows by about 8. The new functions should each stay under 40 lines. No function should come near the 100-line gate.

### Non-goals

- Signing or auto-approving anything. The helper stays read-only and never writes to GitHub, and the t2449 trust gate is unchanged.
- Cross-runner visibility. Markers are local to the runner whose pulse evaluated the PR, as the recovery decisions already are.

### Files Scope

- `.agents/scripts/maintainer-decisions-helper.sh`
- `.agents/scripts/tests/test-worker-briefed-trust-parity.sh`
- `.agents/scripts/tests/test-pulse-merge-worker-briefed.sh`
- `.agents/scripts/tests/test-pulse-merge-pr-context.sh`
- `.agents/scripts/tests/test-pulse-merge-issue-sync-authority.sh`
- `.agents/scripts/tests/test-pulse-merge-ci-repair-routing-cases.sh`

## Acceptance

- `maintainer-decisions-helper.sh list --format md` lists every open, non-draft PR that has a current-head `untrusted_issue_author_no_crypto_approval` marker as an `approve` item with the exact `approve issue <N> <repo>` command, and does not list it twice.
- Merged or closed PRs, drafts, PRs with a newer head, unmanaged slugs, and `non_closing_reference_not_open` markers are not listed.
- After the affected tests run, the real `~/.aidevops/.agent-workspace/pulse-t2449-permanent-blocks/` directory has no new `owner--repo--pr-*` file.
- The helper still performs no GitHub writes (`rg -n "gh (issue|pr) (edit|comment|close|merge)|-X (POST|PATCH|PUT|DELETE)" .agents/scripts/maintainer-decisions-helper.sh` has no matches).

## Verification

- `shellcheck -x .agents/scripts/maintainer-decisions-helper.sh` and the edited tests.
- `.agents/scripts/affected-tests-helper.sh run --base origin/main` passes.
- Product path (runner with markers): `maintainer-decisions-helper.sh list --format tsv | rg "^approve"` shows one row per open, current-head marker from `rg -l "untrusted_issue_author_no_crypto_approval" ~/.aidevops/.agent-workspace/pulse-t2449-permanent-blocks/`, and no `owner/repo` row.
