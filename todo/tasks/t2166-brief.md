# t2166: SYNC_PAT visibility and scope fix

**Session origin:** interactive (user-directed, companion to t2165)

## What

Three related fixes to the `SYNC_PAT` fallback that t2048 landed in `sync-on-pr-merge` only:

1. **Scope fix**: extend the `${{ secrets.SYNC_PAT || secrets.GITHUB_TOKEN }}` fallback to the other three jobs that push to `main` — `sync-on-push`, `sync-on-issue`, `manual-sync`. t2048 fixed one job; the others still fail silently when `SYNC_PAT` is unset and loudly when it isn't configured at all.
2. **Visibility fix**: promote the existing `::notice::` in `sync-on-pr-merge` to `::warning::` and add the same warning to all four jobs, so operators see on every run — not just after failure — that `SYNC_PAT` is not set.
3. **Actionable-error fix**: rewrite the `TODO.md auto-completion blocked` PR comment (issue-sync.yml:680-692) to include the exact `gh secret set SYNC_PAT` command so the maintainer can fix the root cause in 30 seconds, not chase the symptom forever with `task-complete-helper.sh`.

## Why

Reproducible, recent evidence — run `24545428903` on `2026-04-17T03:00Z` (the sync-on-issue run triggered by **t2165's own issue #19486 creation 5 minutes ago**) failed with:

```
remote: error: GH006: Protected branch update failed for refs/heads/main.
```

Three attempts, three failures. Same signature as runs 24545001220, 24545023322, 24545424016 from earlier today. Pattern: every non-PR-merge run that tries to push TODO.md to main is rejected.

t2048 (PR #18677, merged) added `SYNC_PAT || GITHUB_TOKEN` to `sync-on-pr-merge` ONLY:

- Line 584: `sync-on-pr-merge` checkout token ✓
- Line 602: `sync-on-pr-merge` TODO.md update GH_TOKEN ✓
- Line 607: `SYNC_PAT_PRESENT` env var ✓

But the other three jobs use raw `${{ secrets.GITHUB_TOKEN }}`:

- `sync-on-push` line 64 (checkout), lines 80/88/103/111/141 (GH_TOKEN env)
- `sync-on-issue` line 179 (checkout), line 190 (GH_TOKEN env)
- `manual-sync` line 239 (checkout), line 248 (GH_TOKEN env)

None of them can bypass branch protection even after `SYNC_PAT` is operationally set, because they never read it. This is why issue-opened events still fail and why TODO.md-push events still fail even though the sync-on-pr-merge code path was fixed.

Additionally, the existing visibility signal in sync-on-pr-merge is `::notice::`, which GitHub collapses into the run summary. Operators don't notice until a PR merge exposes the broken push. A `::warning::` surfaces prominently in both the job log and the run summary, and is copy-paste actionable.

## How

### Change 1: extend SYNC_PAT fallback to all three remaining jobs

For each job, swap `secrets.GITHUB_TOKEN` → `secrets.SYNC_PAT || secrets.GITHUB_TOKEN` on:

- `actions/checkout` `token` input (so `git push` uses PAT auth)
- Every `GH_TOKEN` env var on steps that might commit/push or need branch-protection bypass on fallback comment paths

Exact lines (current → replacement):

- `sync-on-push` (line 31-141):
  - Line 64: checkout `token`
  - Line 80: `Close issues` step `GH_TOKEN`
  - Line 88: `Push new tasks` step `GH_TOKEN`
  - Line 103: `Enrich` step `GH_TOKEN`
  - Line 111: `Pull missing refs` step `GH_TOKEN`
  - Line 141: `Show sync status` step `GH_TOKEN`
- `sync-on-issue` (line 143-220):
  - Line 179: checkout `token`
  - Line 190: `Sync issue ref` step `GH_TOKEN`
- `manual-sync` (line 222-274):
  - Line 239: checkout `token`
  - Line 248: `Run sync command` step `GH_TOKEN`

### Change 2: promote visibility signal from `::notice::` to `::warning::` (all jobs)

Add at the start of each job that pushes to main: a dedicated step that prints a `::warning::` when `SYNC_PAT_PRESENT` is empty, listing the exact command to fix. Use the existing `SYNC_PAT_PRESENT` pattern from line 607 (`secrets.SYNC_PAT != '' && 'true' || ''`) — GitHub's `!=` comparison works on secrets without exposing values.

Warning body:

```
SYNC_PAT secret is not set — TODO.md auto-sync to main will fail with GH006.
Fix: gh secret set SYNC_PAT --repo <REPO> --body "<PAT_VALUE>"
See: todo/tasks/t2166-brief.md "How to create SYNC_PAT"
```

In `sync-on-pr-merge`, keep the existing `SYNC_PAT_PRESENT` block but change `::notice::Using GITHUB_TOKEN for push (pre-t2048 fallback...)` → `::warning::SYNC_PAT unset, falling back to GITHUB_TOKEN — push will be rejected by branch protection. Fix with: gh secret set SYNC_PAT --repo REPO --body PAT`.

### Change 3: actionable PR comment on push rejection

Rewrite the `TODO.md auto-completion blocked` comment (issue-sync.yml:680-692) to lead with the root-cause fix (set `SYNC_PAT`), not the symptom workaround (`task-complete-helper.sh`):

Proposed body:

```markdown
### TODO.md auto-completion blocked

The `sync-on-pr-merge` workflow tried to mark `$TASK_ID` complete in `TODO.md` with proof-log `$PROOF` but the push was rejected by branch protection (GH006).

**Root cause:** the `SYNC_PAT` repo secret is not set, so the workflow fell back to `GITHUB_TOKEN`, which cannot bypass `required_approving_review_count` on classic branch protection.

**Fix (maintainer, ~30s):** create a fine-grained PAT with `Contents: Read and write` scoped to this repo, then run:

```bash
gh secret set SYNC_PAT --repo <REPO> --body "<PAT_VALUE>"
```

Retrigger this PR's merge hygiene: `gh workflow run issue-sync.yml --repo <REPO>` (the workflow will re-attempt on the next TODO.md push, or you can re-merge a trivial PR to force it).

**Immediate workaround (until SYNC_PAT is set):** run locally:

```bash
~/.aidevops/agents/scripts/task-complete-helper.sh $TASK_ID --pr $PR_NUMBER --testing-level self-assessed
```

Background: t2048 (PR #18677) landed the `SYNC_PAT || GITHUB_TOKEN` fallback code. t2166 (this PR) extends it to `sync-on-push`/`sync-on-issue`/`manual-sync` and promotes unset-secret notices to warnings. The operational secret still needs to be created — tracked by this comment and the t2029 entry in AGENTS.md.

<!-- t2029:auto-complete-blocked -->
```

### Change 4: update AGENTS.md known-limitation paragraph

Current paragraph (`~/.aidevops/agents/AGENTS.md`, section "Known limitation — sync-on-pr-merge TODO auto-completion (t2029)") says "Implementation tracked in t2048 (GH#18643)." Now that PR #18677 has merged but the secret still isn't operational, update to:

- State: code path landed in t2048, operational setup still pending.
- Point at t2166 (this issue) for scope + visibility work.
- Include the `gh secret set SYNC_PAT ...` command inline so users can fix without reading tickets.

## Acceptance

1. `sync-on-push`, `sync-on-issue`, `manual-sync`, and `sync-on-pr-merge` all read `secrets.SYNC_PAT || secrets.GITHUB_TOKEN` on every token input (checkout + GH_TOKEN env).
2. All four jobs emit a `::warning::` annotation when `SYNC_PAT` is unset — visible in the GitHub Actions UI before the job runs any other logic.
3. The `TODO.md auto-completion blocked` PR comment includes the exact `gh secret set SYNC_PAT ...` command with concrete repo slug and a link back to this brief.
4. `.agents/AGENTS.md` t2029 paragraph is updated to cite t2166 and include the one-line fix command.
5. `actionlint` (if installed) passes on the updated workflow.
6. No behavioural change for repos that already have `SYNC_PAT` set — the fallback order is identical.
7. When `SYNC_PAT` is unset, behaviour is identical to today — same GITHUB_TOKEN fallback, same GH006 on push, plus a loud warning that shows the fix. No regression.

## Risk and rollback

- **Risk to pulse/workers: zero.** Pulse/workers don't invoke this workflow directly — it runs in GitHub Actions on push/issue/PR events. The only change they see is: on TODO.md pushes, the sync workflow runs faster (via t2165) and, once SYNC_PAT is set, actually completes the round-trip. Until SYNC_PAT is set, behaviour is identical to today.
- **Risk to token handling: low.** `SYNC_PAT || GITHUB_TOKEN` is a well-established pattern — t2048 already uses it and has been stable since PR #18677 merged. All tokens go through secret-masking; no values are ever logged. The `SYNC_PAT_PRESENT` boolean-ish var from line 607 is the idiom and cannot leak the value.
- **Risk to PR-comment wording: none.** The comment is cosmetic and only fires on push rejection. Worst case is a stylistic regression if the new wording confuses someone — trivially revertable.
- **Rollback:** revert the single PR. No schema change, no secret creation, no migration.

## Files to modify

- EDIT: `.github/workflows/issue-sync.yml`
  - Lines 64, 179, 239: checkout `token` — add `SYNC_PAT || ` prefix
  - Lines 80, 88, 103, 111, 141, 190, 248: `GH_TOKEN` env — add `SYNC_PAT || ` prefix
  - Each job: add a `SYNC_PAT warning` step at the top emitting `::warning::` when unset
  - `sync-on-pr-merge` lines 615-619: promote `::notice::` → `::warning::` on the unset branch
  - `sync-on-pr-merge` lines 680-692: rewrite `TODO.md auto-completion blocked` comment with root-cause command first
- EDIT: `.agents/AGENTS.md`
  - Section "Known limitation — sync-on-pr-merge TODO auto-completion (t2029)": update to state code landed in t2048, operational secret still pending, include `gh secret set SYNC_PAT` one-liner, link t2166

## Verification

Local:

```bash
# Workflow YAML syntax
bash -n .github/workflows/issue-sync.yml 2>&1 || true   # bash can't validate YAML
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/issue-sync.yml'))"

# actionlint if available
command -v actionlint && actionlint .github/workflows/issue-sync.yml || echo "actionlint not installed (ok)"

# Verify all four jobs reference SYNC_PAT
grep -n "SYNC_PAT" .github/workflows/issue-sync.yml
# Expected: hits in all four job blocks (sync-on-push, sync-on-issue, manual-sync, sync-on-pr-merge)
```

Post-merge (self-verifying):

1. The merge of this PR itself triggers `sync-on-pr-merge`. Because `SYNC_PAT` is still unset, the job should log a `::warning::` (new, from this change) and then fall back to `GITHUB_TOKEN` which will still hit GH006. Expected.
2. The PR comment posted on rejection should contain the new root-cause-first body with the `gh secret set` command.
3. User then runs the one-liner to create `SYNC_PAT`. Next TODO.md push triggers `sync-on-push` — should complete cleanly with no warning, and TODO.md should actually update on main.

## Context

- t2029 (GH#17402-ish) first documented the GH006 breakage after silent ~3-week outage.
- t2034 added explicit `GH_TOKEN` on the PR-comment fallback path.
- t2038 (GH#18522) decided SYNC_PAT as the real fix; t2048 (PR #18677) landed the code. The SYNC_PAT operational secret was never created — this task covers both the scope gap (other jobs) and the visibility gap (operators can't tell why their syncs fail).
- t2165 (PR #19487, in flight) fixes the orthogonal 10-minute timeout problem. Neither depends on the other.
- Fine-grained PAT creation steps are user-actionable only (framework can't create secrets on the user's behalf). That's why visibility matters — this issue surfaces the gap; the user closes it.
