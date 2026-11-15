<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Release-Scope Sweep

A session asked to solve a repository's issues through to release often files
new same-repo issues while it works. Releasing without them leaves the next
session to rebuild context the current session already holds. The sweep solves
eligible session-filed issues first, so one release carries them all.

## When it applies

- Interactive sessions holding trusted release intent for a repository: the
  aidevops snapshot release (`workflows/full-loop.md` step 4.6) or a maintained
  repository's manual release (`workflows/release.md` "Manual Release").
- Interactive objectives framed as solving a repository's backlog, with or
  without release.
- Not headless workers: worker scope enforcement (t1894) limits them to their
  dispatched issue, and their findings remain auto-dispatch issues for pulse.

Filing an issue is still mandatory: it is the durable record. In these sessions
it is not a hand-off.

## At filing time

Record each same-repo issue number in the session todo list or checkpoint. That
record defines "session-filed"; an author search cannot, because every session
and worker shares the account. Review-followup issues generated from this
session's own PRs also count.

Classify immediately. Claim an eligible issue in the same turn with
`interactive-session-helper.sh claim <N> <owner/repo>` so pulse does not
dispatch a duplicate worker, and keep `auto-dispatch` so a claim released
unfinished resumes automatically. Leave an ineligible issue unclaimed for pulse.

## Eligibility

An issue is eligible when all of these hold:

- Open, in the release repository, actionable after bounded discovery, with a
  known verification path.
- Not held or blocked: no `hold-for-review`, `parent-task`, `status:blocked` or
  unresolved native blocker, missing required secret name, durable
  `no-auto-dispatch` intent, or untrusted `needs-maintainer-review`.
- Needs no human taste or decision, credentials, purchase, hardware, or
  external-service setup.
- Not owned elsewhere: no other assignee or claim, no `status:queued` or
  `status:in-progress` worker, no open linked PR, and no live session
  (`aidevops sessions who '#<N>'`). A worker PR that merges before the release
  is included automatically; do not take it over or wait on it.
- Proportionate: its risk tier can be verified here (critical/high require
  runtime verification) and it fits remaining session capacity. Context
  pressure alone is not ineligibility: checkpoint, compact, and continue.

## Process

1. After the primary PR merges, list the session-filed issues and classify each
   `sweep` or `leave:<reason>`.
2. Run the normal loop for each `sweep` issue: `interactive-start-helper.sh
   --issue <N> --repo <owner/repo> --task "..." --auto-dispatch`, implement in
   its own linked worktree, apply every gate, and merge its leaf PR
   (`Resolves #N`) through `full-loop-helper.sh merge`. Do not combine unrelated
   issues in one PR.
3. Issues filed during sweep work join the list. Repeat until no eligible issue
   remains.
4. Run one release covering every merged PR; snapshot releases include them
   without per-PR consent. Do not release once per issue.

## Bounds

- Urgency: when the primary change fixes a security defect, a broken
  release/install, or a user-visible regression, release it first, then sweep
  and publish a follow-up release under the same intent.
- Convergence: if two consecutive sweep rounds each file at least as many new
  eligible issues as they resolve, stop sweeping, release what merged, and
  leave the remainder to pulse.
- Authority: the sweep never widens release authority, bypasses a gate, or
  edits other repositories; cross-repository findings stay filed where they
  belong.

## Reporting

List swept issues with their merged PRs in the release summary. Name each left
issue with its reason and whether pulse will pick it up. Left issues are already
captured, so they are not **Left to capture** items in the `What next` block.
