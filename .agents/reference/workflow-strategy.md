<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Workflow-Strategy Changes

Workflow strategy is the maintainer's decision. An issue that changes it without maintainer direction adds friction for every repository that uses the framework: new holds and waits, or labels with a second meaning. Precedent: GH#40581 reported designed takeover-and-merge behaviour as a bug, and the first review recommended a new hold flag as the fix.

## What counts

A change is a workflow-strategy change when it alters any of these:

- **When work moves on its own**: dispatch, takeover or handover, merge, close, release, and their defaults, opt-ins and opt-outs.
- **What stops work**: new gates, holds, waits, required reviews or approvals, throttles.
- **What a label or marker means**: giving a provenance or status label an action effect (for example treating `origin:interactive` as "do not merge"), or giving one label a second meaning.
- **Who owns work**: the boundaries between interactive sessions, workers and the pulse.

Fixing code so that existing gates and labels behave as documented is not a strategy change; file it as a bug (for example GH#40590, a labeler applying the wrong label, or GH#40580, enforcing an existing rule).

**Maintainer direction** means an OWNER or MEMBER asked for the change, in the current session or on the issue, or signed an approval of a review that recommends it.

## The test

Does the reported behaviour match a documented or deliberate decision? Check `reference/` and `workflows/`, then the change that introduced the behaviour (`git log -S '<symbol>'` and its linked issue). If it does, the request is a strategy change, even when it comes with a reproducer.

Before proposing a new control, point to an existing one:

| Need | Existing control |
|------|------------------|
| Hold one issue or PR for a maintainer decision | `hold-for-review` |
| Keep a PR away from workers | `no-takeover` |
| Keep an issue out of dispatch | `no-auto-dispatch` |
| A task whose deliverable is a PR, not a merge | PR-only completion contract (`workflows/full-loop.md`) |
| Interactive PR merge throughput | opt-ins in `reference/auto-merge.md` |

## Rules

- **Maintainer-directed**: proceed normally. Quote or link the direction in the brief.
- **Interactive, no direction**: do not file it as work. A maintainer gets one recommendation and a yes/no question; anyone else gets the existing control.
- **Headless workers, pulse, ambient self-improvement**: never file a strategy change as `bug` or with `auto-dispatch`. If an observed failure needs one, deduplicate, then file one `enhancement` + `hold-for-review` issue titled `proposal: …`. Name the decision it would change (with a link) and the evidence that its rationale no longer holds. It appears in the maintainer queue (`/decisions`). Otherwise record it in memory or drop it.
- **External reporters (`/log-issue-aidevops`)**: file designed behaviour as `enhancement`, citing the decision and the existing control, never as `bug`. `needs-maintainer-review` still gates it.
- **Reviewers (`workflows/review-issue-pr.md`, `workflows/triage-review.md`)**: recommend Decline (works as designed) and name the existing control. Without maintainer direction, never recommend Approve for a strategy change, and never offer a narrower new hold, flag or guidance route as the fix.

`hold-for-review` is the internal decision hold (`reference/task-lifecycle.md` "Canonical split"). Never use `needs-maintainer-review` for this; it means missing external-author authority. Do not create new labels.
