---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2038: research: pick path to bypass branch protection for github-actions[bot] — rulesets vs fine-grained PAT

## Origin

- **Created:** 2026-04-13
- **Session:** OpenCode:interactive (gap-closing pass that shipped t2015/t2018/t2027–t2030/t2034)
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** none
- **Conversation context:** During the gap-closing session I shipped t2029 (make `sync-on-pr-merge` push failure visible) + t2034 (add GH_TOKEN to the PR comment fallback). Together they convert a silent 3-week failure into a loud one with a user-friendly manual fallback. **They are NOT a fix for the root cause.** The root cause: classic branch protection on personal-account public repos cannot bypass `required_pull_request_reviews` for `github-actions[bot]` — confirmed by direct API test (HTTP 500 on PATCH `bypass_pull_request_allowances`). Until the real fix ships, every merged PR with a TODO entry continues to fire the loud-failure path and require a manual `task-complete-helper.sh` call. Two viable real-fix paths exist with very different trade-offs. This task picks the path BEFORE writing any implementation.

## What

A documented decision (recorded in this brief's "Decision" section, plus a comment in `.agents/AGENTS.md` and a follow-up implementation brief) on which of the two paths to take for unblocking `github-actions[bot]` pushes to main:

1. **Migrate classic branch protection to GitHub Rulesets** with `bypass_actors` containing `github-actions`.
2. **Set up a fine-grained PAT** stored as a repo secret, used by the relevant workflows for the push.

Out of scope for this task: the actual implementation of whichever path is chosen. That is a downstream task (t2039 or whatever the next available ID is) filed by this task as part of its deliverable.

End-state: a decision note in the brief, an updated AGENTS.md "Known limitation" paragraph reflecting the chosen path, and a child implementation task ready to dispatch.

## Why

**Why this is a research task and not an implementation task.** The two paths have non-trivially different cost profiles, security surfaces, and ongoing maintenance burdens. Picking the wrong one creates either ongoing rotation fatigue (PAT) or a moderately risky migration that needs to preserve every existing classic protection rule (rulesets). The decision belongs to the maintainer, not to an LLM working off a one-line hint.

**Why it's worth doing now and not deferring indefinitely.** The t2029+t2034 fix makes the failure VISIBLE but does not REMOVE the friction. Every merged PR with a tNNN title currently produces:

1. A failed workflow step in the Actions UI (visible noise)
2. A `<!-- t2029:auto-complete-blocked -->` comment on the PR (additional noise)
3. A required manual `task-complete-helper.sh tNNN --pr NNN` call from the maintainer's local machine

Multiplied across the ~5-15 PRs/day this repo currently ships, the maintainer is paying ~10-30 manual command-runs per day. That's the daily cost of NOT picking a path. Even the worse path (PAT) eliminates this friction in ~30 minutes of setup.

**Why the decision matters for the security boundary.** Classic protection's `enforce_admins: false` already lets human admins bypass via `--admin` merge. The question is who else gets that power:

- **Rulesets path**: `github-actions` (the GitHub Actions app, including ALL workflows in this repo) gets bypass. Trust boundary becomes "every workflow file in `.github/workflows/`". Admin = me only, app bypass = all repo workflows.
- **PAT path**: The PAT identity (a specific user, e.g., me) gets bypass. Trust boundary becomes "anyone who can read the secret". Stored secret implies anyone with `contents: write` on the repo can exfiltrate it via a malicious workflow PR.

Both paths broaden the bypass list beyond just human admin. The question is which broadening is safer — and "safer" here is a maintainer judgment about repository threat model, not a technical fact.

## Tier

### Tier checklist

- [ ] **≤2 files to modify?** — research task; the deliverable is a decision + AGENTS.md note + child implementation task. Three artifacts.
- [ ] **Complete code blocks for every edit?** — N/A, this is research.
- [ ] **No judgment or design decisions?** — judgment is the entire point.
- [ ] **No error handling or fallback logic to design?** — error path is "what if neither option works on a personal-account repo", which needs to be explored.
- [x] **≤1h estimate?** — actually 2-3h: 30-60m research + 30-60m write-up + 30m draft-implementation-brief.
- [x] **≤4 acceptance criteria?** — exactly 4

**Selected tier:** `tier:reasoning`

**Tier rationale:** Research/decide tasks live in the reasoning tier because they require:
1. **Reading external documentation** (GitHub Rulesets docs, fine-grained PAT scoping rules, classic-vs-rulesets feature parity matrix).
2. **Holding multiple viable paths in mind simultaneously** while comparing trade-offs across security, ongoing cost, migration risk, and feature parity.
3. **Recommending a specific path with rationale** that the maintainer can either accept or reject without re-doing the research.
4. **Drafting a child implementation brief** that's executable at a lower tier once the path is chosen.

Sonnet COULD do this but would tend toward enumerating options without committing. Opus is more likely to land on a specific recommendation. Reserve this for the higher tier.

## How (Approach)

### Phase 1: Research (~30-60 minutes)

**1.1 Verify the current limitation is real and not a configuration error.**

```bash
# Confirm the HTTP 500 reproduces (this was the t2029 finding)
cat > /tmp/bypass.json <<'EOF'
{
  "dismiss_stale_reviews": true,
  "require_code_owner_reviews": false,
  "required_approving_review_count": 1,
  "bypass_pull_request_allowances": {
    "users": [],
    "teams": [],
    "apps": ["github-actions"]
  }
}
EOF
curl -sS -i -X PATCH "https://api.github.com/repos/marcusquinn/aidevops/branches/main/protection/required_pull_request_reviews" \
  -H "Authorization: Bearer $(gh auth token)" \
  -H "Accept: application/vnd.github+json" \
  -d @/tmp/bypass.json
```

If this returns HTTP 500 with empty body (as it did on 2026-04-13), classic-protection bypass is genuinely unsupported on this plan. If it returns 200 OK, GitHub silently fixed the limitation and Path 0 ("just use the bypass list") becomes available — short-circuit the rest of this task.

**1.2 Research GitHub Rulesets feature parity with classic protection.**

Read:

- <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets>
- <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository>
- <https://docs.github.com/en/rest/repos/rules>

Verify rulesets support EVERY rule currently in classic protection on this repo:

```bash
gh api "repos/marcusquinn/aidevops/branches/main/protection" --jq '
  {
    required_status_checks: .required_status_checks.contexts,
    required_pull_request_reviews: .required_pull_request_reviews,
    required_signatures: .required_signatures.enabled,
    enforce_admins: .enforce_admins.enabled,
    required_linear_history: .required_linear_history.enabled,
    allow_force_pushes: .allow_force_pushes.enabled,
    allow_deletions: .allow_deletions.enabled,
    required_conversation_resolution: .required_conversation_resolution.enabled,
    lock_branch: .lock_branch.enabled,
    allow_fork_syncing: .allow_fork_syncing.enabled,
    block_creations: .block_creations.enabled,
    restrictions: .restrictions
  }
'
```

For each present rule, find the equivalent rule type in rulesets (`rules` array). If any rule has no equivalent, that's a blocker for the rulesets path — flag it as a finding.

**1.3 Research fine-grained PAT capabilities.**

Read:

- <https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens>
- <https://docs.github.com/en/rest/overview/permissions-required-for-fine-grained-personal-access-tokens>

Verify:

- A fine-grained PAT scoped to a single repo with `Contents: Write` permission can push to main when the user identity has admin bypass via `enforce_admins: false`. (Test by creating a throwaway PAT and trying a no-op push.)
- The PAT can be stored as a repo Actions secret and consumed by the relevant workflows.
- The PAT respects `secret_scanning` so accidental commits don't leak it.

**1.4 Identify rotation cost and threat model differences.**

For each path, document:

- Setup time (one-time)
- Ongoing rotation cost (yearly, monthly, never)
- Failure mode if the credential expires unnoticed (loud vs silent)
- Worst-case compromise impact (what can an attacker do if they get the credential)

### Phase 2: Decision Write-Up (~30-60 minutes)

In this brief's "Decision" section below, document:

- **The chosen path** (rulesets / PAT / neither viable).
- **Why** this path was preferred (security, cost, future-proofing).
- **What was rejected** about the other path.
- **Failure mode** if the chosen path doesn't work as expected (rollback plan).

### Phase 3: Child Implementation Task (~30 minutes)

File a downstream task implementing the chosen path:

```bash
~/.aidevops/agents/scripts/claim-task-id.sh \
  --repo-path /Users/marcusquinn/Git/aidevops \
  --title "<implementation title for chosen path>"
```

Write the child implementation brief at the appropriate tier (likely `tier:standard` for either path). Reference t2038's decision section in the child brief's "Context & Decisions".

Then update `.agents/AGENTS.md`'s "Known limitation — sync-on-pr-merge TODO auto-completion (t2029)" paragraph to reflect:

- Which path was chosen
- The child implementation task ID and PR number (when available)

### Verification

```bash
# Decision is documented
grep -c "## Decision" todo/tasks/t2038-brief.md  # expect ≥1

# Child task ID exists
grep -E "Implementation task: t[0-9]+" todo/tasks/t2038-brief.md

# AGENTS.md updated to point at the chosen path
grep "Known limitation — sync-on-pr-merge" .agents/AGENTS.md | grep -E "(rulesets|fine-grained PAT)"
```

## Acceptance Criteria

- [ ] The brief contains a `## Decision` section naming the chosen path with explicit rationale.
  ```yaml
  verify:
    method: codebase
    pattern: "^## Decision"
    path: "todo/tasks/t2038-brief.md"
  ```
- [ ] A child implementation task is filed with its own task ID and brief.
  ```yaml
  verify:
    method: codebase
    pattern: "Implementation task: t[0-9]+"
    path: "todo/tasks/t2038-brief.md"
  ```
- [ ] `.agents/AGENTS.md` "Known limitation" paragraph references the chosen path and the child task ID.
  ```yaml
  verify:
    method: codebase
    pattern: "Known limitation.*sync-on-pr-merge.*(rulesets|fine-grained PAT)"
    path: ".agents/AGENTS.md"
  ```
- [ ] The classic-protection HTTP 500 limitation is verified still present (or documented as resolved by GitHub).
  ```yaml
  verify:
    method: manual
    prompt: "Re-run the curl PATCH call from Phase 1.1. If it returns HTTP 500, the limitation persists. If it returns 200 OK, document that GitHub silently fixed it and short-circuit the rest of the task."
  ```

## Decision

> **TBD — fill in during Phase 2 once research is complete.**
>
> Template:
>
> **Chosen path:** `<rulesets | PAT | neither>`
>
> **Why:**
> - <reason 1>
> - <reason 2>
> - <reason 3>
>
> **Rejected because:**
> - <other path>: <reason>
>
> **Implementation task:** `t<NNNN>` — `<title>`
>
> **Failure-mode rollback:** `<what to do if the chosen path breaks something>`

## Context & Decisions (research-time)

**Why a research task instead of just picking one and implementing it.** I noted both paths in my session summary as "tracked for later, neither fits this session's budget". But "tracked for later" is invisible without a brief. The user explicitly asked whether to file a TODO for this — meaning they want the decision visible and dispatchable, not buried in a session summary.

**Why tier:reasoning instead of standard.** Two reasons. (1) The deliverable is a decision with rationale, which Sonnet tends to enumerate without committing — Opus is more likely to land on a specific recommendation. (2) The implementation that follows from the decision is downstream (a child task), so this task's value is concentrated entirely in the quality of the chosen path, not the volume of work done.

**Why include the "verify HTTP 500 still reproduces" step.** GitHub frequently relaxes API limitations between versions. If `bypass_pull_request_allowances` started working on personal-account public repos between when I tested (2026-04-13) and when this task is dispatched, the entire problem disappears and Path 0 ("just use the existing bypass field") becomes the trivially correct answer. Re-verifying is 30 seconds of work and saves potentially hours of unnecessary migration.

**Threat model context for the decision.** This repo has 6 non-admin collaborators with `push` permission (vladimirdulov, alex-solovyev, zzhovo, optimizewp, Bartek532, B-Novembit). The `required_approving_review_count: 1` rule exists primarily to prevent these collaborators from pushing directly to main without review. Any bypass mechanism we add must NOT widen the bypass list to include these accounts. Both rulesets and PAT can be scoped narrowly enough to satisfy this — but verifying the scoping is part of the research.

**Non-goals (research-time):**

- Picking a third option (e.g., GitHub App with installation-scoped credentials). That's worth exploring only if both rulesets AND PAT have disqualifying issues, which would be surprising.
- Implementing the chosen path. That's the child task.
- Updating any workflow files in this repo.
- Rotating any existing PATs.

## Relevant Files

- `.github/workflows/issue-sync.yml:507-563` — the t2029+t2034 loud-failure block whose root cause this task addresses.
- `.agents/AGENTS.md` "Known limitation — sync-on-pr-merge TODO auto-completion (t2029)" — the paragraph to update once a path is chosen.
- `todo/tasks/t2029-brief.md` — context on why the silent-failure-fix was scoped narrowly.
- `todo/tasks/t2034-brief.md` — context on the GH_TOKEN follow-up that completes the visible-failure path.
- <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets>
- <https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens>

## Dependencies

- **Blocked by:** none (t2029 + t2034 are both merged, this task is pure follow-up research)
- **Blocks:** the eventual elimination of manual `task-complete-helper.sh` calls after every merge. Until t2038 ships AND its child implementation task ships, every merge continues to require manual TODO completion.
- **External:** GitHub may silently fix the classic-protection bypass limitation, in which case this task short-circuits.

## Estimate Breakdown

| Phase | Time |
|-------|------|
| 1.1 Verify HTTP 500 still reproduces | 5m |
| 1.2 Research rulesets feature parity | 30-45m |
| 1.3 Research fine-grained PAT | 15-30m |
| 1.4 Document threat model differences | 15m |
| 2 Decision write-up | 30m |
| 3 Child implementation brief + AGENTS.md update | 30m |
| **Total** | **~2-3h hands-on, no CI (research only)** |
