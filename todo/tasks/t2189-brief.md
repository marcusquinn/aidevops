<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2189: feat(pulse-merge): idle interactive PR handover to worker pipeline

## Origin

- **Created:** 2026-04-18
- **Session:** claude-code:interactive
- **Created by:** ai-interactive (maintainer directed)
- **Parent task:** none
- **Conversation context:** PR #19658 (`origin:interactive`) sat idle ~8h with a failing required Complexity Analysis check, but the pulse merge pass's CI/conflict/review fix-worker routing (pulse-merge.sh:840/1121/1154) explicitly gates on `origin:worker`, so interactive-only PRs have no automated rescue path. Existing `origin:interactive` automation stops at a one-time "please rebase" nudge. Root cause: `origin:interactive` is a sticky creation-time label with no staleness semantics.

## What

A handover mechanism that converts idle `origin:interactive` PRs into routable PRs so the existing worker pipelines (CI fix, conflict fix, review fix, collaborator approve + merge) can drive them to merge when the human has walked away.

Three new pieces, all in `.agents/scripts/pulse-merge.sh`:

1. `_interactive_pr_is_stale(pr_number, repo_slug)` — detection helper returning 0 (stale, eligible) or 1 (fresh / ineligible).
2. `_interactive_pr_trigger_handover(pr_number, repo_slug)` — idempotent action: apply `origin:worker-takeover` label + post one marker-guarded comment explaining the handover + announce reclaim path.
3. Update the three existing routing gates at pulse-merge.sh:840, :1121, :1154 to accept `origin:worker-takeover` as an alternative to `origin:worker`, AND to trigger handover on a stale interactive PR before routing.

Rollout is gated by a new env `AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE` with values `off` | `detect` | `enforce`, default `detect`. The mode determines whether the helpers log-only, comment-only, or fully enforce. A follow-up one-line PR flips the default to `enforce` once telemetry is clean.

## Why

Symptom: interactive PRs with failing CI or merge conflicts that the human abandoned sit open indefinitely. The existing rebase-nudge covers conflicts only, passively (comments once, no further action). CI-failure PRs get nothing. No path exists for a worker to pick up an idle interactive PR even when:

- The human is demonstrably gone (no claim stamp, no `status:*` label on linked issue, PR hasn't moved in N hours).
- A worker could trivially fix the blocker (e.g., refactor a 145-line function that tripped the complexity ratchet — #19658).

Cost of the gap: every such PR accumulates operational triage cost (human must decide to admin-bypass, refactor manually, or close). Admin-bypass erodes the ratchet; manual refactor requires context-switching. Neither scales.

This task closes the routing gap without sacrificing human priority — a returning human can always take back control via the reclaim path, and any worker mid-flight self-terminates via the existing `dispatch-dedup-helper.sh` combined signal.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** No — pulse-merge.sh + 2 test files + brief + TODO.md = 5 files.
- [ ] **Every target file under 500 lines?** No — pulse-merge.sh is 2254 lines.
- [ ] **Exact `oldString`/`newString` for every edit?** No — code skeletons, not verbatim strings.
- [ ] **No judgment or design decisions?** No — mode flag behaviour, staleness threshold defaults, comment copy all require design judgment.
- [x] **No error handling or fallback logic to design?** Mostly — fail-open behaviour is standard (follow existing `_post_rebase_nudge_on_interactive_conflicting` pattern).
- [x] **No cross-package or cross-module changes?** Yes — all in `.agents/scripts/`.
- [ ] **Estimate 1h or less?** No — ~2h (design + implement + tests + rollout wiring).
- [ ] **4 or fewer acceptance criteria?** No — 9 criteria below.

**Selected tier:** `tier:standard`

**Tier rationale:** Standard implementation in a familiar subsystem, following well-established patterns (`_post_rebase_nudge_on_interactive_conflicting`, `_dispatch_ci_fix_worker`, `_gh_idempotent_comment`). No novel architecture — the design mirrors existing worker-PR routing with one new gate. Sonnet is the right tier; haiku lacks the judgment budget for mode-flag wiring and test-harness design, opus is overkill.

## PR Conventions

Leaf task (not parent-task labelled). PR body uses `Resolves #<issue>` (to be assigned on issue creation).

## How (Approach)

### Worker Quick-Start

```bash
# Read the three reference patterns (they define the idioms this task extends):
#   pulse-merge.sh:1352  _post_rebase_nudge_on_interactive_conflicting — idempotent interactive comment
#   pulse-merge.sh:1883  _dispatch_ci_fix_worker                       — feedback routing pattern
#   pulse-triage.sh:227  _gh_idempotent_comment                        — marker-guarded comment helper

# Inspect the three current routing gates — these are the exact edit sites:
sed -n '835,850p;1115,1130p;1148,1160p' .agents/scripts/pulse-merge.sh

# Claim stamp location (for staleness detection):
# $CLAIM_STAMP_DIR = ~/.aidevops/.agent-workspace/interactive-claims/
# Stamp filename: ${flattened_slug}-${issue_number}.json  (see interactive-session-helper.sh:91)
```

### Files to Modify

- `EDIT: .agents/scripts/pulse-merge.sh` — add `_interactive_pr_is_stale()` and `_interactive_pr_trigger_handover()` helpers near line 1350 (alongside `_post_rebase_nudge_on_interactive_conflicting`); update routing gates at lines 840, 1121, 1154 to recognise `origin:worker-takeover` and trigger handover on stale interactive PRs.
- `NEW: .agents/scripts/tests/test-pulse-merge-interactive-handover.sh` — model on `tests/test-pulse-merge-fix-worker-dispatch.sh`; cover staleness signal truth table + handover idempotence + mode-flag behaviour.
- `EDIT: .agents/AGENTS.md` — add a short section under "Git Workflow" or "Interactive issue ownership" documenting the handover mechanism + reclaim path + mode flag.
- `EDIT: TODO.md` — add t2189 entry with `ref:GH#<issue>` and task ID claimed.
- `NEW: todo/tasks/t2189-brief.md` — this file.

### Implementation Steps

**Step 1: add `_interactive_pr_is_stale` helper in pulse-merge.sh, just before `_post_rebase_nudge_on_interactive_conflicting` (around line 1330).**

Keep under 100 lines (respect the ratchet). Signature and behaviour:

```bash
#######################################
# Detect whether an origin:interactive PR is idle enough to hand over to
# the worker pipeline. Returns 0 if eligible, 1 otherwise.
#
# Combined signal — ALL must be true:
#   - PR has origin:interactive label
#   - Linked issue has NO active status:{queued,in-progress,in-review,claimed} label
#   - No live claim stamp file in $CLAIM_STAMP_DIR matching the linked issue
#   - PR's last activity (updatedAt) > $AIDEVOPS_INTERACTIVE_PR_HANDOVER_HOURS (default 24)
#   - Linked issue is open
#
# Env:
#   AIDEVOPS_INTERACTIVE_PR_HANDOVER_HOURS — default 24
#   AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE  — off | detect | enforce (default: detect)
#     off:     always returns 1 (feature disabled)
#     detect:  evaluates signal and logs would-handover decisions to $LOGFILE, still returns the signal
#     enforce: evaluates and returns the signal (caller may trigger handover)
#
# Args: $1=pr_number, $2=repo_slug
# Returns: 0=stale (eligible for handover), 1=fresh/ineligible
# Side effects: in "detect" mode, logs "[pulse-wrapper] would-handover: ..." to $LOGFILE
#######################################
_interactive_pr_is_stale() {
    local pr_number="$1" repo_slug="$2"
    local mode="${AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE:-detect}"
    [[ "$mode" == "off" ]] && return 1

    # 1. Fetch PR metadata once (labels + updatedAt + linked issue reference)
    local pr_meta
    pr_meta=$(gh pr view "$pr_number" --repo "$repo_slug" --json labels,updatedAt,body,title 2>/dev/null) || return 1
    printf '%s' "$pr_meta" | jq -e '.labels | map(.name) | index("origin:interactive")' >/dev/null 2>&1 || return 1

    # 2. Check age threshold
    local threshold_hours updated_at pr_age_hours
    threshold_hours="${AIDEVOPS_INTERACTIVE_PR_HANDOVER_HOURS:-24}"
    updated_at=$(printf '%s' "$pr_meta" | jq -r '.updatedAt')
    pr_age_hours=$(( ( $(date +%s) - $(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" +%s 2>/dev/null || date -d "$updated_at" +%s) ) / 3600 ))
    [[ "$pr_age_hours" -lt "$threshold_hours" ]] && return 1

    # 3. Resolve linked issue (reuse _extract_linked_issue)
    local linked_issue
    linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug")
    [[ -z "$linked_issue" ]] && return 1

    # 4. Check issue is open and has no active status label
    local issue_meta
    issue_meta=$(gh api "repos/${repo_slug}/issues/${linked_issue}" --jq '{state, labels: [.labels[].name]}' 2>/dev/null) || return 1
    printf '%s' "$issue_meta" | jq -e '.state == "OPEN"' >/dev/null 2>&1 || return 1
    printf '%s' "$issue_meta" | jq -e '.labels | any(. == "status:queued" or . == "status:in-progress" or . == "status:in-review" or . == "status:claimed")' >/dev/null 2>&1 && return 1

    # 5. Check no live claim stamp
    # Stamp naming: ${flattened_slug}-${issue_number}.json (see interactive-session-helper.sh:91)
    local slug_flat stamp_path
    slug_flat="${repo_slug//\//-}"
    stamp_path="${CLAIM_STAMP_DIR:-$HOME/.aidevops/.agent-workspace/interactive-claims}/${slug_flat}-${linked_issue}.json"
    [[ -f "$stamp_path" ]] && return 1

    # 6. In detect mode, log the would-handover decision; still return stale=true
    if [[ "$mode" == "detect" ]]; then
        echo "[pulse-wrapper] would-handover: PR #${pr_number} in ${repo_slug} (idle ${pr_age_hours}h, threshold ${threshold_hours}h, linked issue #${linked_issue})" >>"$LOGFILE"
    fi

    return 0
}
```

**Step 2: add `_interactive_pr_trigger_handover` helper after `_interactive_pr_is_stale`.**

Idempotent: adds label + posts one marker-guarded comment. Fail-open. In `detect` mode, logs but does nothing.

```bash
#######################################
# Trigger handover of an idle interactive PR to the worker pipeline.
# Idempotent: applies `origin:worker-takeover` label + posts one comment
# guarded by marker `<!-- pulse-interactive-handover -->`. The origin:interactive
# label is NOT removed (origin history is append-only; worker-takeover is the
# routing override).
#
# Honours AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE:
#   off | detect: no-op (caller should not reach here in these modes but guard anyway)
#   enforce: apply label + comment
#
# Fail-open: all gh failures logged, never propagate.
#
# Args: $1=pr_number, $2=repo_slug
# Returns: 0 always (best-effort)
#######################################
_interactive_pr_trigger_handover() {
    local pr_number="$1" repo_slug="$2"
    local mode="${AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE:-detect}"
    [[ "$mode" != "enforce" ]] && return 0

    # Skip if already handed over (label present — idempotent short-circuit)
    local has_label
    has_label=$(gh pr view "$pr_number" --repo "$repo_slug" --json labels --jq '[.labels[].name] | index("origin:worker-takeover")' 2>/dev/null)
    if [[ "$has_label" != "null" && -n "$has_label" ]]; then
        return 0
    fi

    # Apply label (best-effort)
    gh issue edit "$pr_number" --repo "$repo_slug" --add-label "origin:worker-takeover" >/dev/null 2>&1 || \
        echo "[pulse-wrapper] _interactive_pr_trigger_handover: failed to add label on PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"

    # Post marker-guarded comment via _gh_idempotent_comment
    if declare -F _gh_idempotent_comment >/dev/null 2>&1; then
        local marker="<!-- pulse-interactive-handover -->"
        local body
        body="${marker}
## Worker takeover — no interactive session activity

This \`origin:interactive\` PR has been idle past the handover threshold (\`AIDEVOPS_INTERACTIVE_PR_HANDOVER_HOURS=${AIDEVOPS_INTERACTIVE_PR_HANDOVER_HOURS:-24}\`h). The pulse is now routing it through the worker pipeline:

- CI failures → routed to linked issue for worker re-dispatch
- Merge conflicts → routed to linked issue for worker re-dispatch
- Review feedback → routed to linked issue for worker re-dispatch
- Once green: auto-approved and admin-merged (collaborator author only)

### Reclaiming interactively

If you return and want to drive this PR yourself, run in a terminal:

\`\`\`bash
gh issue edit ${pr_number} --repo ${repo_slug} --remove-label origin:worker-takeover
interactive-session-helper.sh claim <linked-issue-number> ${repo_slug}
\`\`\`

Any worker mid-flight will self-terminate on the next pulse cycle (combined assignee + status signal via \`dispatch-dedup-helper.sh\`).

### Opting out permanently

Add the \`no-takeover\` label to this PR at any time.

<sub>Posted once per PR by \`pulse-merge.sh\` (t2189).</sub>"
        _gh_idempotent_comment "$pr_number" "$repo_slug" "$marker" "$body" "pr" || true
    fi

    echo "[pulse-wrapper] handover: PR #${pr_number} in ${repo_slug} handed over to worker pipeline" >>"$LOGFILE"
    return 0
}
```

**Step 3: update the three routing gates to recognise `origin:worker-takeover` and trigger handover on stale interactive PRs.**

The pattern below is applied identically at three sites. Example for the CI gate at line 1154:

```bash
# BEFORE (line 1154):
if [[ ",${_ci_pr_labels}," == *",origin:worker,"* &&
    ",${_ci_pr_labels}," != *",ci-feedback-routed,"* ]]; then
    _dispatch_ci_fix_worker "$pr_number" "$repo_slug" "$_ci_linked_issue" || true
fi

# AFTER:
# Check opt-out label first
if [[ ",${_ci_pr_labels}," == *",no-takeover,"* ]]; then
    : # honour opt-out, no routing
elif [[ ",${_ci_pr_labels}," == *",origin:worker,"* ]] \
     || [[ ",${_ci_pr_labels}," == *",origin:worker-takeover,"* ]]; then
    if [[ ",${_ci_pr_labels}," != *",ci-feedback-routed,"* ]]; then
        _dispatch_ci_fix_worker "$pr_number" "$repo_slug" "$_ci_linked_issue" || true
    fi
elif [[ ",${_ci_pr_labels}," == *",origin:interactive,"* ]] \
     && _interactive_pr_is_stale "$pr_number" "$repo_slug"; then
    _interactive_pr_trigger_handover "$pr_number" "$repo_slug" || true
    if [[ ",${_ci_pr_labels}," != *",ci-feedback-routed,"* ]]; then
        _dispatch_ci_fix_worker "$pr_number" "$repo_slug" "$_ci_linked_issue" || true
    fi
fi
```

Apply the same structural change at lines 1121 (conflict routing → `_dispatch_conflict_fix_worker`, marker `conflict-feedback-routed`) and 840 (review routing → `_dispatch_pr_fix_worker`, marker `review-routed-to-issue`).

**Step 4: verify the collaborator-approval + admin-merge path still fires on takeover'd PRs.**

`_check_pr_merge_gates` at line 796 and `approve_collaborator_pr` at line 277 do NOT currently filter by `origin:interactive`. They fire for any collaborator-authored PR. So once CI passes, a takeover'd PR reaches merge via the existing path automatically — no changes needed here. Verify this assumption is still true at implementation time by reading those functions end-to-end.

**Step 5: tests.**

Model on `test-pulse-merge-fix-worker-dispatch.sh`. Write `test-pulse-merge-interactive-handover.sh` covering:

- **A**: `_interactive_pr_is_stale` returns 1 for PR <24h old
- **B**: `_interactive_pr_is_stale` returns 1 when claim stamp exists
- **C**: `_interactive_pr_is_stale` returns 1 when linked issue has `status:in-review`
- **D**: `_interactive_pr_is_stale` returns 0 for a 48h-old PR with no stamp and no status label
- **E**: `_interactive_pr_trigger_handover` is idempotent — second call finds the label, short-circuits
- **F**: `_interactive_pr_trigger_handover` in `detect` mode is a no-op (no gh calls to label/comment)
- **G**: `_interactive_pr_trigger_handover` in `enforce` mode applies label AND posts exactly one comment
- **H**: `_interactive_pr_is_stale` with mode=`off` returns 1 unconditionally

Use the established mock-gh-stub pattern. All tests must pass cleanly against bash 3.2 (macOS default — see `reference/bash-compat.md`).

**Step 6: documentation.**

Add one paragraph to `.agents/AGENTS.md` in the "Interactive issue ownership" section:

```markdown
**Idle-interactive PR handover (t2189)**: `origin:interactive` PRs that sit idle
past `AIDEVOPS_INTERACTIVE_PR_HANDOVER_HOURS` (default 24h) with no linked-issue
active status and no live claim stamp are automatically handed over to the worker
pipeline by adding `origin:worker-takeover`. The existing CI/conflict/review fix-worker
routing then drives them to merge. To opt out: add the `no-takeover` label. To reclaim
interactively: remove `origin:worker-takeover` and re-claim via
`interactive-session-helper.sh claim <N> <slug>`. Mode flag:
`AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE=off|detect|enforce` (default `detect` for
initial rollout — logs "would-handover" decisions without taking action; flip to
`enforce` via follow-up PR once telemetry confirms no false positives).
```

### Verification

```bash
# Lint
shellcheck .agents/scripts/pulse-merge.sh

# Complexity regression — BOTH new helpers must be under 100 lines each
awk '/^_interactive_pr_is_stale\(\)/,/^}/' .agents/scripts/pulse-merge.sh | wc -l
awk '/^_interactive_pr_trigger_handover\(\)/,/^}/' .agents/scripts/pulse-merge.sh | wc -l

# Tests
bash .agents/scripts/tests/test-pulse-merge-interactive-handover.sh

# Regression — existing tests still pass
bash .agents/scripts/tests/test-pulse-merge-fix-worker-dispatch.sh
bash .agents/scripts/tests/test-pulse-merge-coderabbit-nits-ok.sh

# Confirm required-check budget isn't bumped by this PR
~/Git/aidevops/.agents/scripts/complexity-regression-helper.sh check function-complexity
```

## Acceptance Criteria

- [ ] `_interactive_pr_is_stale()` function exists in pulse-merge.sh, under 100 lines
  ```yaml
  verify:
    method: bash
    run: "awk '/^_interactive_pr_is_stale\\(\\)/,/^}/' ~/Git/aidevops/.agents/scripts/pulse-merge.sh | wc -l | awk '{exit ($1 < 100) ? 0 : 1}'"
  ```
- [ ] `_interactive_pr_trigger_handover()` function exists in pulse-merge.sh, under 100 lines
  ```yaml
  verify:
    method: bash
    run: "awk '/^_interactive_pr_trigger_handover\\(\\)/,/^}/' ~/Git/aidevops/.agents/scripts/pulse-merge.sh | wc -l | awk '{exit ($1 < 100) ? 0 : 1}'"
  ```
- [ ] All three routing gates (lines ~840, ~1121, ~1154) accept `origin:worker-takeover` as an alternative to `origin:worker`
  ```yaml
  verify:
    method: codebase
    pattern: "origin:worker-takeover"
    path: ".agents/scripts/pulse-merge.sh"
  ```
- [ ] Mode flag `AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE` is respected: `off` disables, `detect` logs, `enforce` acts
  ```yaml
  verify:
    method: codebase
    pattern: "AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE"
    path: ".agents/scripts/pulse-merge.sh"
  ```
- [ ] Default mode is `detect` (conservative rollout)
  ```yaml
  verify:
    method: codebase
    pattern: 'AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE:-detect'
    path: ".agents/scripts/pulse-merge.sh"
  ```
- [ ] Opt-out `no-takeover` label is honoured in all three routing gates
  ```yaml
  verify:
    method: codebase
    pattern: "no-takeover"
    path: ".agents/scripts/pulse-merge.sh"
  ```
- [ ] Test harness exists with ≥8 cases covering staleness truth table + idempotence + mode behaviour
  ```yaml
  verify:
    method: bash
    run: "bash ~/Git/aidevops/.agents/scripts/tests/test-pulse-merge-interactive-handover.sh"
  ```
- [ ] shellcheck clean on pulse-merge.sh (no new violations)
  ```yaml
  verify:
    method: bash
    run: "shellcheck ~/Git/aidevops/.agents/scripts/pulse-merge.sh"
  ```
- [ ] Complexity ratchet: new head ≤ current base (no new functions >100 lines introduced)
  ```yaml
  verify:
    method: bash
    run: "bash ~/Git/aidevops/.agents/scripts/complexity-regression-helper.sh check function-complexity"
  ```
- [ ] Documentation paragraph added to `.agents/AGENTS.md` covering mechanism, opt-out, reclaim, mode flag
  ```yaml
  verify:
    method: codebase
    pattern: "Idle-interactive PR handover"
    path: ".agents/AGENTS.md"
  ```

## Context & Decisions

### Design choices

- **Additive label, not replacement** — `origin:interactive` stays on the PR as origin history. `origin:worker-takeover` is the routing signal. Preserves audit trail.
- **24h default, not 12h** — prioritises reliability over reaction time. A human on a short holiday shouldn't have their PR harvested. Tightenable once telemetry justifies it.
- **Three-state mode flag** — `off/detect/enforce` mirrors the framework's existing conservative-rollout pattern (e.g., pulse deterministic merge). Default `detect` ships the detection logic without taking action; a one-line follow-up PR flips to `enforce` after 2-3 pulse cycles of clean "would-handover" logs.
- **No state removal** — handover never unassigns humans, never removes `origin:interactive`, never closes the PR. It only adds routing-enabling signal. The human path back is symmetric (remove label + re-claim) and cheap.
- **Opt-out label `no-takeover`** — for long-running drafts, research PRs, or experiments where handover would be wrong. Cheap escape hatch.
- **Collaborator approval path unchanged** — `approve_collaborator_pr` and `_check_pr_merge_gates` already fire regardless of origin labels. Once CI passes post-handover, merge happens automatically via the existing path. No new code needed there.

### Non-goals

- **Not building `aidevops pr reclaim <N>` in this task** — the two-line reclaim is documented inline in the handover comment and in AGENTS.md. A convenience wrapper can be filed as a follow-up if friction warrants it.
- **Not touching the pre-commit complexity check gap** — the fact that a worker shipped a 145-line function without local complexity enforcement is a separate issue (file as follow-up t-ID: "write-time complexity gate in `full-loop-helper.sh` or pre-commit hook").
- **Not changing the `origin:interactive` dispatch-dedup semantics** — `_has_active_claim` in dispatch-dedup-helper.sh still treats the label as blocking when combined with an assignee. The handover mechanism works at PR-routing time, not issue-dispatch time.

### Prior art consulted

- PR #19205 (`fix(pulse-merge): drop origin:interactive exclusion from feedback routing`) — established `origin:worker` as the routing signal. This task extends that framework with `origin:worker-takeover` as a second routing signal.
- PR #18651 (`_post_rebase_nudge_on_interactive_conflicting`) — reference for the idempotent interactive-PR comment pattern. Handover comment follows the same marker-guarded structure.
- PR #19384 (t2148, stampless interactive claim recovery) — reference for the staleness concept at the issue level. This task lifts the concept to the PR level.
- PR #18334 (`origin:interactive implies maintainer approval`) — reaffirms that `origin:interactive` on a collaborator PR should reach merge automatically. This task removes the "but only if CI is green and human is still around" caveat.

## Relevant Files

- `.agents/scripts/pulse-merge.sh:840` — review feedback routing gate (edit site 1)
- `.agents/scripts/pulse-merge.sh:1121` — conflict feedback routing gate (edit site 2)
- `.agents/scripts/pulse-merge.sh:1154` — CI feedback routing gate (edit site 3)
- `.agents/scripts/pulse-merge.sh:1352` — `_post_rebase_nudge_on_interactive_conflicting` (reference pattern)
- `.agents/scripts/pulse-merge.sh:1883` — `_dispatch_ci_fix_worker` (dispatched helper — signature unchanged)
- `.agents/scripts/pulse-merge.sh:1996` — `_dispatch_conflict_fix_worker` (dispatched helper — signature unchanged)
- `.agents/scripts/pulse-merge.sh:2127` — `_dispatch_pr_fix_worker` (dispatched helper — signature unchanged)
- `.agents/scripts/pulse-merge.sh:1230` — `_extract_linked_issue` (reused for linked-issue resolution)
- `.agents/scripts/pulse-triage.sh:227` — `_gh_idempotent_comment` (reused for the handover comment)
- `.agents/scripts/interactive-session-helper.sh:51` — `CLAIM_STAMP_DIR` constant
- `.agents/scripts/interactive-session-helper.sh:91` — stamp filename pattern
- `.agents/scripts/tests/test-pulse-merge-fix-worker-dispatch.sh` — test pattern to model on

## Dependencies

- **Blocked by:** none
- **Blocks:** first dogfood case is PR #19658 itself (will auto-handover once this lands and is flipped to `enforce`)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | pulse-merge.sh context + 3 reference patterns + 1 test file |
| Implementation | 1h 10m | 2 helpers (~100 lines), 3 routing updates (~30 lines), docs |
| Testing | 30m | 8 test cases + regression runs |
| **Total** | **2h** | Conservative — bash/gh mocking overhead included |
