<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1981: investigate multi-operator assignee churn — two aidevops sessions fighting over new-issue assignments

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive (observed while opening PRs in the t1968–t1970 session)
- **Created by:** ai-interactive
- **Parent task:** none
- **Conversation context:** During this session I self-assigned issues #18370 and #18371 at claim time via `claim-task-id.sh`. Both were re-assigned to a different collaborator (`alex-solovyev`) within 1–8 minutes, forcing the Maintainer Gate workflow to fail and requiring manual re-assign + rerun. The assignee churn was not caused by spam or a takeover — `alex-solovyev` is a legitimate collaborator with `write` permission on the repo. Both operators (me and alex-solovyev) appear to be running `aidevops update` / pulse cycles concurrently, and something in the pulse or claim flow is re-assigning newly-created issues to whoever's session runs next.

## What

Investigate the assignee-churn root cause and produce either (1) a targeted code fix that stops it, or (2) a design note explaining why it's unavoidable and what the operational workaround is.

The investigation deliverable is a short written report (comment on this issue or a doc at `todo/investigations/t1981-assignee-churn.md`) containing:

1. **Event-level trace:** exact `gh api repos/.../issues/NNN/events` output showing the unassign/assign sequence and which actor performed each
2. **Token / session attribution:** which token (PAT, gh auth, etc.) performed the mutating calls, on which machine, from which code path
3. **Root cause:** the specific line(s) of code that trigger the reassignment, OR the specific workflow/webhook if it's CI-driven
4. **Fix or workaround:** either a PR removing the offending logic, scoping it to the current user only, or a documentation update telling multi-operator setups how to avoid the churn

## Why

**Concrete evidence from this session:**

Issue #18370 (t1969):

```
2026-04-12T17:05:35Z assigned marcusquinn by marcusquinn
2026-04-12T17:12:53Z unassigned marcusquinn by marcusquinn
2026-04-12T17:12:53Z assigned alex-solovyev by alex-solovyev
2026-04-12T17:25:05Z assigned marcusquinn by marcusquinn
```

Issue #18371 (t1970):

```
2026-04-12T17:05:37Z assigned marcusquinn by marcusquinn
2026-04-12T17:06:55Z unassigned marcusquinn by marcusquinn
2026-04-12T17:06:56Z assigned alex-solovyev by alex-solovyev
2026-04-12T17:20:55Z unassigned alex-solovyev by alex-solovyev
2026-04-12T17:24:48Z assigned marcusquinn by marcusquinn
```

Observations:

- **The unassign-then-assign pair is 1 second apart and always in the same order.** This is consistent with a single code path doing `gh issue edit --remove-assignee @me && gh issue edit --add-assignee $new_user`, not with two independent operators happening to collide.
- **The unassign is attributed to `marcusquinn` (me), not to `alex-solovyev`.** That's strange — if alex-solovyev's machine is doing the reassignment, GitHub should attribute the removal to their token. Either:
  1. There's shared credential state (very bad — security issue),
  2. GitHub event attribution is wrong or lagging,
  3. Or a workflow runs under the `GITHUB_TOKEN` identity (which for most workflows is the repository owner, `marcusquinn`).
- **The timing is variable (80 seconds for #18371, 7 minutes for #18370)** — inconsistent with a fixed cron cadence. More consistent with an on-demand trigger (workflow-run webhook, or a pulse that sees the new issue at its next sweep).
- **The alex-solovyev reassignment on #18371 was itself later reverted at 17:20:55** (`unassigned alex-solovyev by alex-solovyev`). That's a second round of churn: their session gave it up, then I re-added myself.

This means **two operators running aidevops on the same repo can't both claim issues reliably.** Any issue I claim may be silently reassigned away, causing Maintainer Gate failures on my PRs. The t1970 fix (auto-assign on creation) is necessary but not sufficient — whatever is unassigning me can still fire after creation.

**Relationship to other PRs merged this session:**

- `t1970` / PR #18374 added `issue-sync-helper.sh` auto-assign on interactive creation. That fired correctly (assignment was present at `17:05:35`).
- What removed the assignment a few seconds/minutes later is unknown. It's **not** in `issue-sync-helper.sh` — that code path has no `--remove-assignee` call.

## Tier

### Tier checklist

- [ ] **2 or fewer files to modify?** — unknown until investigation completes
- [ ] **Complete code blocks for every edit?** — no, this is investigation-first
- [ ] **No judgment or design decisions?** — judgment required on whether to scope-out assignment churn or document a workaround
- [ ] **No error handling or fallback logic to design?** — may require a multi-operator coordination design
- [x] **Estimate 1h or less?** — initial investigation phase, yes (~1h)
- [x] **4 or fewer acceptance criteria?** — 4

**Selected tier:** `tier:standard`

**Tier rationale:** Investigation-heavy task with unclear fix scope. Not simple because the code path that's mutating the assignee is not yet identified. Not reasoning-tier because once identified the fix is likely a small scope change (add `if current_user == session_user` guard). If investigation uncovers a larger architectural issue (pulse worker dispatch reassignment, shared credentials, etc.), this task should be decomposed into child tasks.

## How (Approach)

### Investigation Plan

1. **Grep all code paths that write assignees:**

    ```bash
    rg --type sh '(\-\-add-assignee|\-\-remove-assignee|gh issue edit.*assignee)' .agents/ setup.sh aidevops.sh
    rg --type sh 'gh api.*assignees|gh api.*POST.*issues' .agents/
    ```

2. **Grep GitHub workflows for assignee mutations:**

    ```bash
    rg --type yaml '(add-assignee|remove-assignee|set_assignee)' .github/workflows/
    rg --type yaml 'actions/github-script.*assignees' .github/workflows/
    ```

3. **Check if there's a "claim takeover" pattern in pulse-wrapper.sh:**

    ```bash
    rg -n 'assignee|alex-solovyev|claim|takeover' .agents/scripts/pulse-wrapper.sh \
        .agents/scripts/pulse-*.sh
    ```

4. **Verify the token attribution.** Check `~/.config/gh/hosts.yml` and the active `gh auth status` for both operators (if alex-solovyev is a teammate, ask them to run `gh auth status` on their machine and share the token scope). Confirm they have their OWN token, not a shared one.

5. **Look at workflow run ownership around the observed event times:**

    ```bash
    # Runs on marcusquinn/aidevops between 17:05 and 17:13 on 2026-04-12
    gh run list --repo marcusquinn/aidevops --created 2026-04-12T17:05..2026-04-12T17:13 \
        --json databaseId,status,conclusion,workflowName,event,actor,createdAt \
        --limit 50
    ```

6. **Check if `pulse-wrapper.sh` has a "re-dispatch" or "reclaim" flow that removes an assignee to transfer ownership.** The pulse's dispatch-dedup logic treats assignees as blockers — maybe there's a complementary "unblock" path that unassigns before reassigning.

7. **If nothing in code matches, check webhook configuration:**

    ```bash
    gh api repos/marcusquinn/aidevops/hooks --jq '.[] | {id, url: .config.url, events}'
    ```

### Produce the Report

Write findings to `todo/investigations/t1981-assignee-churn.md` with:

- Event trace (copied from `gh api issues/NNN/events`)
- Code path identified (or "not found — needs further investigation")
- Recommended fix (or "operational workaround: use `PULSE_SCOPE_REPOS` to isolate operators per repo")
- Any security concern if shared credentials are discovered

### Fix or Workaround

Based on the root cause:

- **If a code path in `pulse-wrapper.sh` or `claim-task-id.sh` is doing the reassignment:** scope the mutation to the current session's user identity. Never reassign away from another operator. Spawn a child task if the fix is non-trivial.
- **If it's a workflow (e.g., github-actions reassigning via `GITHUB_TOKEN`):** disable the workflow step or add a `current-assignee != current-actor` guard.
- **If it's a legitimate pulse takeover flow (i.e., alex-solovyev's session actively claimed the task for dispatch):** document it in `reference/multi-operator.md` and update the Maintainer Gate workflow to treat any recent assignee as valid, not just the issue opener.

## Acceptance Criteria

- [ ] Investigation report committed at `todo/investigations/t1981-assignee-churn.md` containing the event trace, root cause, and recommended remediation.
- [ ] At least one of: (a) PR that fixes the reassignment at the source, (b) documentation update explaining the multi-operator model and workaround, or (c) child task(s) filed if the fix is too large for this one.
- [ ] Confirmation that both operators on the repo have independent `gh` tokens (no shared credentials).
- [ ] Regression test: open a new issue, self-assign, wait 10 minutes, verify assignment is still yours (manual verification the fix works end-to-end).

## Context & Decisions

- **Why investigate before fixing:** multiple plausible root causes, and the wrong fix (e.g., blindly removing an auto-assign call) could break a legitimate dispatch flow. The event trace is the ground truth — chase that first.
- **Why this is NOT "just a race":** races produce random outcomes. This produced a CONSISTENT outcome (me unassigned, alex-solovyev assigned) across two independent issues within the same minute. That's deterministic behaviour from a specific code path.
- **Security priority:** if the investigation reveals shared credentials (alex-solovyev's machine has access to marcusquinn's gh token), that's a P0 — rotate the token immediately and audit scope. This task should escalate and stop at that point.

## Relevant Files

- `.agents/scripts/claim-task-id.sh` — already audited in this session, has `_auto_assign_issue` (add-only, no remove)
- `.agents/scripts/issue-sync-helper.sh` — t1970 fix added auto-assign; no remove-assignee calls
- `.agents/scripts/pulse-wrapper.sh` — large file, needs grep for assignee mutations
- `.agents/scripts/dispatch-dedup-helper.sh` — reads assignees for blocking, shouldn't mutate
- `.github/workflows/maintainer-gate.yml` — reads assignees for gating, shouldn't mutate
- Evidence: `gh api repos/marcusquinn/aidevops/issues/18370/events` and `gh api repos/marcusquinn/aidevops/issues/18371/events` (both reproducible for ~30 days)

## Dependencies

- **Blocked by:** none
- **Blocks:** reliable multi-operator aidevops usage, which blocks scaling the framework beyond a single machine per repo
- **External:** may need to coordinate with alex-solovyev (or whoever else is running aidevops on this repo) to gather token/session info from their side

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Event trace + grep | 30m | Already have the event data — grep code paths |
| Workflow inspection | 20m | Read .github/workflows files |
| Report drafting | 20m | Write the findings doc |
| Fix or follow-up filing | 30m | Depends on root cause |
| Verification | 20m | Watch a new claim for 10min, confirm stability |

**Total estimate:** ~2h (investigation + narrow fix). If root cause is in pulse-wrapper.sh (likely), decompose into child tasks.
