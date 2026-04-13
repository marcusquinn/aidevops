---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2029: fix(issue-sync): make sync-on-pr-merge push failure visible instead of silent

## Origin

- **Created:** 2026-04-13
- **Session:** OpenCode:interactive (same session as t2015/t2018/t2027/t2028)
- **Created by:** marcusquinn (ai-interactive gap-closing pass)
- **Parent task:** none
- **Conversation context:** While closing G2 (TODO.md post-merge auto-completion gap observed during t2015/t2018) I investigated the `sync-on-pr-merge` job in `issue-sync.yml:288-515`. It DOES try to auto-complete TODO entries on PR merge, but its `git push` has been **silently failing for ~3 weeks** (last successful GA commit mark-* on 2026-03-20) because branch protection blocks `github-actions[bot]` pushes. Root cause: `required_approving_review_count: 1` gates collaborators (6 non-admin collaborators exist on this repo), `enforce_admins: false` lets human admins bypass but not the bot, and the personal-account plan doesn't support `bypass_pull_request_allowances` on classic branch protection (confirmed: HTTP 500 on the PATCH API call). The push retry loop at lines 507-515 has no `exit 1` after the 3 failed attempts, so the workflow reports SUCCESS even though TODO.md was never updated. This task ships the minimum-viable visible-failure fix; the real fix (ruleset migration or PAT) is tracked as a follow-up.

## What

`sync-on-pr-merge`'s TODO.md update step fails LOUDLY (workflow exit code 1, explicit `::error::` message, PR comment with manual instructions) instead of SILENTLY (hidden in retry loop output, workflow reports success) when `git push` is rejected by branch protection.

After the fix:
- A failed push is visible in the workflow UI as a failed step with a clear error message.
- A comment is posted on the just-merged PR explaining that TODO.md was not auto-updated and giving the exact command to run manually.
- Maintainers see the failure immediately instead of discovering it weeks later (like I did when investigating the t2015/t2018 flow).

Not in scope: fixing the root cause (branch protection bypass for bots). That requires either migrating to GitHub Rulesets or setting up a fine-grained PAT, both of which are >1h of careful work plus secret management. Tracked as a follow-up task.

## Why

**The silent-failure cost.** The last successful `chore: mark tNNN complete` commit from `GitHub Actions` was 2026-03-20. Today is 2026-04-13. For ~23 days, every PR merge has silently failed to update TODO.md, and humans have either:

- Noticed the omission and manually run `task-complete-helper.sh` (my path during t2015/t2018)
- NOT noticed, leaving TODO entries as `[ ]` indefinitely (broken audit trail)

Because there was no visible error signal, the breakage accumulated across ~2 dozen merged PRs. A loud failure would have surfaced this the day branch protection changed.

**Why fix the visibility now instead of the root cause.** The root cause fix is non-trivial:

- **Ruleset migration** (~2-3h): replicate the existing classic protection rules in a GitHub Ruleset, add `github-actions` to `bypass_actors`, disable classic protection. Medium risk because it touches the security model.
- **PAT setup** (~30m + ongoing): create a fine-grained PAT, store as a secret, modify the workflow to use it, set up rotation.

Both require more than a quick session patch and neither fits the "close gaps while we have attention" scope. Making the failure visible is a 15-minute fix that ships immediately and prevents the next ~3 weeks of silent accumulation.

## Tier

### Tier checklist

- [x] **≤2 files to modify?** — 2 files: `.github/workflows/issue-sync.yml` and `.agents/AGENTS.md` (documentation)
- [x] **Complete code blocks for every edit?** — yes, verbatim YAML and markdown below
- [x] **No judgment or design decisions?** — the comment body and error format are specified verbatim; no design
- [x] **No error handling or fallback logic to design?** — the fallback IS the visible error; nothing else to design
- [x] **≤1h estimate?** — ~25 minutes
- [x] **≤4 acceptance criteria?** — exactly 4

**Selected tier:** `tier:simple`

## How

### Files to Modify

- `EDIT: .github/workflows/issue-sync.yml:507-515` — change the retry loop to track success explicitly, and add a post-loop block that fails loudly with workflow warning + PR comment if all attempts fail.
- `EDIT: .agents/AGENTS.md` — add a brief note under the "Task Creation" or "Completion" section documenting the current limitation and the manual fallback command.

### Implementation

**Step 1: Replace the retry loop at `.github/workflows/issue-sync.yml:507-515`.**

Find:

```yaml
          # Commit and push
          git add TODO.md
          git commit -m "chore: mark $TASK_ID complete ($PROOF) [skip ci]"

          for i in 1 2 3; do
            echo "Push attempt $i..."
            git pull --rebase origin main || true
            if git push; then
              echo "Push succeeded on attempt $i"
              break
            fi
            sleep $((i * 3))
          done
```

Replace with:

```yaml
          # Commit and push
          git add TODO.md
          git commit -m "chore: mark $TASK_ID complete ($PROOF) [skip ci]"

          # t2029: track success explicitly so a silent failure becomes a
          # loud failure. Without this, GH006 rejections from branch
          # protection are hidden inside the retry loop and the workflow
          # reports overall success even though TODO.md was never pushed.
          PUSH_SUCCEEDED=false
          for i in 1 2 3; do
            echo "Push attempt $i..."
            git pull --rebase origin main || true
            if git push; then
              echo "Push succeeded on attempt $i"
              PUSH_SUCCEEDED=true
              break
            fi
            sleep $((i * 3))
          done

          if [[ "$PUSH_SUCCEEDED" != "true" ]]; then
            # t2029: branch protection on personal-account repos cannot
            # bypass required_pull_request_reviews for github-actions[bot]
            # (HTTP 500 on the PATCH bypass API, confirmed 2026-04-13).
            # Make the failure loud and post a PR comment with the exact
            # manual command. See todo/tasks/t2029-brief.md for context.
            echo "::error::Failed to push TODO.md update after 3 attempts — branch protection blocked github-actions[bot]"
            echo "::error::Fix locally: task-complete-helper.sh $TASK_ID --pr $PR_NUMBER"

            COMMENT_BODY="### TODO.md auto-completion blocked

            The \`sync-on-pr-merge\` workflow tried to mark \`$TASK_ID\` complete in \`TODO.md\` with proof-log \`$PROOF\` but the push was rejected by branch protection.

            **Run this locally to complete the audit trail:**

            \`\`\`bash
            ~/.aidevops/agents/scripts/task-complete-helper.sh $TASK_ID --pr $PR_NUMBER --testing-level self-assessed
            \`\`\`

            This is a known limitation on personal-account classic branch protection — \`required_approving_review_count\` cannot be bypassed by \`github-actions[bot]\`, and \`bypass_pull_request_allowances\` is not supported on this plan. The real fix is either a Rulesets migration or a fine-grained PAT (tracked in a follow-up task). Until then, this comment is your cue.

            <!-- t2029:auto-complete-blocked -->"

            gh pr comment "$PR_NUMBER" --body "$COMMENT_BODY" 2>/dev/null || \
              echo "::warning::Also failed to post PR comment — run the manual command above"

            exit 1
          fi
```

**Step 2: Add the note to `.agents/AGENTS.md`.**

Find the "Completion:" line in the "Auto-Dispatch and Completion" section (currently near "Code changes need worktree + PR. Workers NEVER edit TODO.md."). After that paragraph, add:

```markdown
**Known limitation — sync-on-pr-merge TODO auto-completion (t2029):** The `sync-on-pr-merge` job in `.github/workflows/issue-sync.yml` tries to auto-mark TODO entries complete on PR merge but its push to `main` is rejected by branch protection on personal-account repos (`required_approving_review_count: 1` + no bypass support for `github-actions[bot]` on classic protection, plan-gated). When the push fails the workflow now (t2029) posts a comment on the just-merged PR with the exact `task-complete-helper.sh` command to run locally. If you merge a PR and see a "TODO.md auto-completion blocked" comment, run the command and push. The real fix (migrate to GitHub Rulesets with `bypass_actors` or use a fine-grained PAT) is tracked separately.
```

**Step 3: File a follow-up task.**

After the PR merges, run:

```bash
~/.aidevops/agents/scripts/claim-task-id.sh --repo-path /Users/marcusquinn/Git/aidevops --title "chore: migrate classic branch protection to Rulesets with github-actions bypass (follow-up to t2029)"
```

This is NOT part of this task's acceptance criteria — it's a tracking note so the real fix doesn't get lost.

### Verification

```bash
# YAML syntax
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/issue-sync.yml'))"
# Grep checks
grep -c "PUSH_SUCCEEDED" .github/workflows/issue-sync.yml   # expect: ≥2
grep -c "t2029:auto-complete-blocked" .github/workflows/issue-sync.yml   # expect: 1
grep -c "Known limitation — sync-on-pr-merge" .agents/AGENTS.md   # expect: 1
```

Runtime verification: the next merged PR that has branch protection blocking the push should produce (a) a failed workflow step, (b) a PR comment containing the manual command. Either observable via the GitHub UI.

## Acceptance Criteria

- [ ] `.github/workflows/issue-sync.yml` tracks push success in `PUSH_SUCCEEDED` variable and fails with `exit 1` when all attempts fail.
  ```yaml
  verify:
    method: codebase
    pattern: "PUSH_SUCCEEDED"
    path: ".github/workflows/issue-sync.yml"
  ```
- [ ] On push failure, the workflow posts a PR comment containing the exact `task-complete-helper.sh` command.
  ```yaml
  verify:
    method: codebase
    pattern: "task-complete-helper.sh .*--pr"
    path: ".github/workflows/issue-sync.yml"
  ```
- [ ] `.agents/AGENTS.md` documents the limitation and the manual fallback command.
  ```yaml
  verify:
    method: codebase
    pattern: "Known limitation — sync-on-pr-merge"
    path: ".agents/AGENTS.md"
  ```
- [ ] The workflow file still parses as valid YAML.
  ```yaml
  verify:
    method: bash
    run: "python3 -c 'import yaml; yaml.safe_load(open(\".github/workflows/issue-sync.yml\"))'"
  ```

## Context & Decisions

**Why not fix the root cause in this session?** Three options were evaluated during investigation:

1. **Classic branch protection bypass** (`bypass_pull_request_allowances`) — patch HTTP 500 on personal-account plan. Not viable. Confirmed via direct `curl -X PATCH`.
2. **Migrate to GitHub Rulesets** — supports `bypass_actors` including `github-actions` app on personal repos. Estimated 2-3h: replicate existing rules, add bypass, disable classic protection, verify every existing workflow's gate still applies. Medium risk because it touches the security model mid-session.
3. **Fine-grained PAT** — store admin-scoped PAT as secret, modify workflow to use it. ~30m + ongoing rotation. Requires user action to create the PAT and set the secret. Scope creep: a PAT with admin bypass is a powerful secret to manage.

None fit the "close gaps while we have attention" frame. Making the silent failure visible is a 15-minute fix with zero risk.

**Why post a PR comment instead of an issue or email?** The PR is where the maintainer is looking at merge time. Comments on the merged PR show up in notifications, link directly from the PR timeline, and are scoped to the specific task. An issue would require a separate triage pass; an email requires SMTP config this repo doesn't have.

**Why not retry more than 3 times?** The failure mode is branch protection, not a race. More retries won't help. The 3-attempt loop was designed for the race case (concurrent pushes hitting non-fast-forward) which is different and still useful to handle.

**Why include `<!-- t2029:auto-complete-blocked -->` marker?** So future tooling can grep for this specific comment type if we ever add batch remediation (e.g., "find all PRs with the blocked marker and run task-complete for each").

**Non-goals:** Migrating to rulesets, setting up PATs, changing branch protection, changing the set of collaborators with write access.

## Relevant Files

- `.github/workflows/issue-sync.yml:507-515` — the retry loop to modify (no `exit 1`).
- `.github/workflows/issue-sync.yml:467-500` — the TODO.md update step (context).
- `.agents/AGENTS.md` — add the "Known limitation" note near task completion section.
- `.agents/scripts/task-complete-helper.sh` — the manual fallback command referenced in the PR comment.
- https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets — docs for the real fix (rulesets migration).

## Dependencies

- **Blocked by:** none
- **Blocks:** audit-trail visibility on merged PRs (every silent failure to date represents a broken proof-log). Not a hard blocker — humans have been patching manually — but a quality gap.
- **External:** none for this task. The real fix (rulesets/PAT) is tracked separately.

## Estimate Breakdown

| Phase | Time |
|-------|------|
| Write brief | (done) |
| Implementation | 10m |
| YAML lint + verify | 3m |
| AGENTS.md note | 2m |
| Commit + PR + /pr-loop | ~20m incl. CI |
| **Total** | **~15m hands-on + ~20m CI** |
