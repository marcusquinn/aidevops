# t2448: Harden `ai-approved` label to admin-only via workflow gate

## Session Origin

Filed from interactive session during post-merge monitoring of t2443 (PR #20158). User surfaced two framework trust-model concerns:

1. Worker PRs requiring redundant human-click merge even when maintainer-briefed (tracked separately as t2449).
2. The `ai-approved` label is collaborator-applicable via GitHub's native permission model (`triage` permission is sufficient to manage labels), creating an implicit authorization bypass where any triage-level collaborator could authorise AI agent processing on their own content.

User directed "restricting ai-approved application to repo admins via ruleset, or requiring a co-signed comment. This needs solving here and now."

## What

Implement a GitHub Actions workflow (`.github/workflows/ai-approved-label-gate.yml`) that enforces admin/maintain-only application of the `ai-approved` label on issues and PRs. When a non-admin applies the label, the workflow reverses the change and posts a one-time notice explaining why.

## Why

The `ai-approved` label is treated as a maintainer approval gate throughout the framework:

- `.github/workflows/opencode-agent.yml:105-118` — gates whether `@opencode` will act on an issue
- `.agents/tools/git/opencode-github-security.md:25,30,42,53,118` — documents the label as a collaborator+label gate
- `.agents/workflows/review-issue-pr.md:149` — lists it under "Maintainer approval" column
- `.agents/scripts/opencode-github-setup-helper.sh:503,588-595` — same gate in setup helper

But GitHub's permission model bundles label management under `triage`, not `admin`. A triage-level contributor could legitimately add any label — including `ai-approved` — undermining the maintainer-approval semantics the framework assumes.

### Design decision: workflow vs ruleset

The user's initial framing offered two options: ruleset-based or co-signed-comment-based enforcement. On investigation:

- **GitHub rulesets don't support per-label ACLs**. Rulesets cover branches, tags, commits, required checks, PR review rules, deployment environments — labels are NOT a rulesets target. So "restrict via ruleset" isn't a feasible path on the GitHub side.
- **Workflow-based enforcement IS the equivalent mechanism** — post-hoc actor check with automated reversal. This is exactly the pattern `maintainer-gate.yml` Job 5 (`protect-origin-worker-label`, lines 710-793) uses for the `origin:worker` label.
- **Co-signed comment** is meaningful on multi-admin org repos but adds no protection on single-admin personal repos (no second admin exists to co-sign). Admin/maintain-only is the right default; co-sign can be a future extension if/when this framework gets deployed to multi-admin org repos.

## How

See `.github/workflows/ai-approved-label-gate.yml` for the canonical implementation. Key structural decisions:

- **Trigger**: `issues.types: [labeled]` and `pull_request_target.types: [labeled]`. Covers both surfaces even though today only `opencode-agent.yml` consumes the label on issues — defense in depth for future consumers.

- **No unlabeled guard**: removing `ai-approved` is always safe — it withdraws AI authorization, which is restrictive, not permissive. Unlike `needs-maintainer-review` (where unlabeling can create a bypass), unlabeling `ai-approved` just reverts to the default denied state.

- **Three-level allowlist**: (1) `github-actions[bot]` — for future framework automation; (2) repository owner — unambiguous repo authority; (3) users with `admin` or `maintain` permission via the collaborator API.

- **Reversal + notice**: on denied application, remove the label and post a marker-dedup'd comment explaining the gate. Uses the `<!-- ai-approved-gate-notice -->` marker for idempotency across re-application attempts.

- **Modeled on** `maintainer-gate.yml` Job 5 (`protect-origin-worker-label`). Same env-var pattern, same allowlist structure, same comment-dedup pattern, same `set -euo pipefail` discipline.

## Acceptance Criteria

- [x] Workflow file created at `.github/workflows/ai-approved-label-gate.yml`
- [x] Triggers on `labeled` event for both issues and PRs
- [x] Allowlist covers bot, repo owner, admin, and maintain roles
- [x] On denied application: label removed via `gh issue/pr edit --remove-label`
- [x] On denied application: one-time notice comment posted with dedup marker
- [x] Workflow uses `set -euo pipefail` and fail-open comments where API calls can transiently fail (PERM check defaults to "none")
- [x] Respects t2229 workflow-cascade-lint pattern (event-action `if` guard, label-name `if` guard)
- [x] Follows t2231 canonical fast-fail gate pattern (guard written even though action is always 'labeled')

## Files Scope

**ADD**:
- `.github/workflows/ai-approved-label-gate.yml`

**MODIFY**:
- `TODO.md` — add t2448 entry under `## In Review`, add t2449 entry under `## Backlog`
- `todo/tasks/t2448-brief.md` — this file
- `todo/tasks/t2449-brief.md` — brief for the companion deferred task

**NOT MODIFIED**:
- `opencode-agent.yml` — the existing label-check still fires; it just now trusts that anyone who applied the label was authorized
- `maintainer-gate.yml` — the origin:worker protection remains untouched; this is a sibling workflow
- `opencode-github-setup-helper.sh` — the label creation logic is untouched; only the application ACL changed
- Any documentation claiming the label is "maintainer-only" — was aspirational, now enforced

## Tier Checklist

- [x] Tier: **`tier:standard`** (Sonnet)
  - Single new workflow file, ~180 lines
  - Direct structural model available (`maintainer-gate.yml` Job 5)
  - Clear acceptance criteria, verification is "does the gate fire on synthetic test applications"
  - No cross-package changes, no trust-model changes (just enforcing existing assumption)

NOT `tier:simple` because: requires understanding the t2229/t2231 workflow patterns and the existing Job 5 model; needs judgment on when to check permission API vs allowlist.

NOT `tier:thinking` because: the design space is small, the model workflow is established, and the test surface is finite (admin / non-admin / bot / owner / transient API failure).

## Related

- **t2449 / #20164** — companion task (deferred brief): symmetric auto-merge for maintainer-briefed `origin:worker` PRs
- **maintainer-gate.yml Job 5** — structural model (`protect-origin-worker-label`)
- **opencode-agent.yml** — the primary consumer of the `ai-approved` label today
- **.agents/workflows/review-issue-pr.md:149** — documents `ai-approved` as a maintainer-approval signal
