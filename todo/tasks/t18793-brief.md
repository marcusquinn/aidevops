<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# t18793: full-loop: implementation intent in maintainer repos finalises interactive draft PRs after verification

## What

Make implementation intent (`/full-loop`, "fix this", "implement", "work on this now", an issue-started implementation) in a repository where the session has maintainer authority count as the finalise/ready consent for its own interactive PR. The session still opens the PR as a draft checkpoint, so work survives interruption or restart. Once local verification passes and the remote head matches local `HEAD`, it runs `gh pr ready` and continues through the normal merge gate. It does not ask again.

## Why

The maintainer chose this on 2026-10-29 while diagnosing stalled pulse/worker work. Currently `workflows/full-loop.md` (Step 4.2), `workflows/pr.md`, `reference/auto-merge.md` and `reference/task-lifecycle.md` require a separate finalise/ready request. Verified interactive fixes therefore wait as drafts until a human replies, even after the human asked for the fix.

## How

- `.agents/workflows/full-loop.md` Step 4.2 (the "Interactive PR creation defaults to draft" sentence): keep the draft creation default as the interruption checkpoint, then define the ready transition.
- `.agents/workflows/pr.md` (the "Interactive aidevops PRs default to draft" paragraph): same rule.
- `.agents/reference/auto-merge.md` criterion 5 and `.agents/reference/task-lifecycle.md` "Auto-merge timing": state that implementation intent in a maintainer repo is a finalise/ready signal.
- Unchanged: the draft creation default in `shared-gh-wrappers-create.sh` (`_gh_create_pr_should_default_draft`), the pulse opt-in for merging interactive PRs (`interactive_pr_auto_merge`), external-contribution stop points, and publication consent.

### Files Scope

- .agents/workflows/full-loop.md
- .agents/workflows/pr.md
- .agents/reference/auto-merge.md
- .agents/reference/task-lifecycle.md

## Acceptance

1. The four documents agree. Draft is the checkpoint while work is in progress. Implementation intent plus passing verification leads to ready and merge in maintainer repos.
2. A PR stays a draft (or the session asks) only when the user requested review-first or draft-only, the work is incomplete or blocked, or the repository is an external contribution.
3. Nothing changes publication or release consent.

## Verification

- `markdownlint-cli2` on the changed files, or the repository's changed-line markdown gate in CI.
- `rg -n -i "finalise/ready|defaults to draft" .agents` shows no contradictory wording.
