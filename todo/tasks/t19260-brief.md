## What

Make `/decisions` list open pull requests held under `hold-for-review`, not only issues. A runtime-pending PR that a verifier can lift appears as a `verify` item, showing the recorded pending reason and the exact `verify-runtime` command. Any other held PR appears as a `held-pr` item, showing what clears the hold. The maintainer then sees every human-only gate in the one batched queue and never has to read PR threads or `pulse.log` to find them.

## Why

`maintainer-decisions-helper.sh` discovers held work with `is:issue` searches only (`_md_search_scope`, `.agents/scripts/maintainer-decisions-helper.sh:205-216`). Held PRs never reach the queue.

- t19241 (GH#39645) routes a liftable runtime-pending PR to a live interactive session on the same repository. With no such session, it only writes an `ATTENTION` line to `pulse.log`. One private-repo PR logged about 25 `ATTENTION` lines over 7 hours. Its verification needs shop credentials and a test network.
- A legacy hold placed before the runtime-pending route (no `## Runtime Testing` section, no recorded hold scope) is invisible to that notifier too. The merge pass skipped one such billing-path PR 61 times in 20 hours. Its hold comment states exactly what clears it: a review copy with Stripe test mode.
- One runner's log window (about 51 hours): the merge pass skipped 13 distinct PRs for `hold-for-review`. 9 merged later; 4 are open now, aged 1h to 20h. `maintainer-decisions-helper.sh list` reported 332 held issues and zero held PRs.

### Files Scope

- `.agents/scripts/maintainer-decisions-helper.sh`
- `.agents/scripts/commands/decisions.md`

## How

- Discovery: add a PR search `is:open is:pr draft:false label:hold-for-review -label:parent-task <scope>` through the existing `_md_search_query`, for the same managed-repo scopes as `_md_discover`. Keep PR refs separate from issue refs, so the issue `--max` round-robin (`_md_interleave_refs`) is unchanged.
- Classification, per PR:
  - Call the read-only `full-loop-helper.sh runtime-pending-notice <PR> <repo>` (t19241). When it prints its JSON, the record is kind `verify`. The question is its `reason`, the command is its `command`, and the age is taken from `held_since`.
  - Otherwise the record is kind `held-pr`. Its question is the newest trusted (OWNER/MEMBER/COLLABORATOR) comment line `**What clears it:**`, else the PR body's `runtime-pending` Verification text, else none (the title is shown). Age runs from that comment, else from PR creation.
  - Records keep the issue record shape, plus `type: "pr"` and `command`.
- Rendering: add both kinds to `MD_KINDS_JQ` after `credentials`, with the headings "Needs runtime verification (held PRs)" and "Held PRs awaiting maintainer review". The md view prints `verify: <command>` under each `verify` item. TSV columns are unchanged.
- `commands/decisions.md`: tell `/decisions` how to present the two kinds. For a `verify` item, AI runs the check itself when this machine has the required environment and then records it with `verify-runtime`. Otherwise it names the single human action. For a `held-pr` item, it recommends lifting or closing, and acts only on the maintainer's answer.
- Reference pattern: the `_md_recorded_decision` / `_md_classify_issue` pair and t19241's `pulse-merge-runtime-pending-notice.sh` use of `runtime-pending-notice`.

## Acceptance

- `maintainer-decisions-helper.sh list --format md` lists a liftable runtime-pending PR under "Needs runtime verification (held PRs)", with its reason and `verify:` command.
- It lists a held PR with no recorded hold scope under "Held PRs awaiting maintainer review", with its "What clears it" line.
- Draft PRs and PRs without `hold-for-review` are not listed. Issue classification and ordering are unchanged.
- `--repo owner/repo` limits PR discovery too. `--format json` records carry `type: "pr"`.
- The helper stays read-only and ShellCheck is clean.

## Notes

Live product-path check: run `list --format md` on this runner and confirm the currently open held PRs appear, each in the expected kind.

Scope addition found during implementation: a Cloudron release PR is held with `release-approval-required` + `hold-for-review` until the maintainer signs its release issue. Release issues carry no `needs-maintainer-*` label, so neither the PR nor the issue reached the queue. Such a PR is listed as kind `approve`, with the `sudo aidevops approve issue <N> <repo>` command for the open release issue that names it. Without that issue it is listed as `held-pr`, saying that r924 retries the request.
