<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2225: interactive-session-helper.sh post-merge \<PR\> — auto-heal status:done + stale self-assignment after planning PR merge

## Origin

- **Created:** 2026-04-18
- **Session:** Claude Code interactive session (continuation of t2218/t2219 filing session)
- **Created by:** ai-interactive (Marcus Quinn driving)
- **Conversation context:** Across two back-to-back planning sessions on 2026-04-18, the agent had to manually `gh issue edit --remove-assignee` 5 issues (3 + 2 from #19701 and #19724) and manually `gh issue edit --remove-label status:done --add-label status:available` 2 issues (#19692 and #19718). Both cleanup patterns have documented source-bug fixes pending (t2218 for self-assign, t2219 for title-fallback status:done). Rather than rely on the agent to (a) recall the right memory keywords, (b) remember to check post-merge state, and (c) run the right gh commands every single time, add a helper subcommand that does this deterministically as part of the already-required post-merge release flow.

## What

Add a `post-merge <PR_NUMBER> [<slug>]` subcommand to `.agents/scripts/interactive-session-helper.sh` that audits a just-merged PR and auto-heals two known drift patterns from framework bugs currently pending fixes (t2218 + t2219):

1. **`For/Ref`-referenced issues with false `status:done`** (t2219 workaround). Extract issue numbers from PR body lines matching `^For #NNN` / `^Ref #NNN` (case-insensitive, anywhere on a line). For each: if the issue is OPEN and has `status:done`, remove `status:done` and add `status:available`. Post a short comment citing t2219 so the drift is audit-trail-linked.

2. **`auto-dispatch` issues still self-assigned to the PR author** (t2218 workaround). Extract ALL issue references from the PR body (both closing keywords AND `For/Ref`). For each: if the issue has `origin:interactive` + `auto-dispatch` + the PR author as assignee + no `status:in-review`/`status:in-progress` label, unassign the PR author. Post a short comment citing t2218.

Both passes are idempotent (safe to re-run), non-blocking on offline `gh` (fail-open, warn once, exit 0), and use `gh issue edit` atomic edits (single invocation with both `--remove-label` and `--add-label` where applicable).

The agent calls this after `gh pr merge` succeeds, in the same flow where it currently calls `release <N>`. Also consider making the canonical merge helpers (`full-loop-helper.sh merge`, any future pulse-merge equivalents) call this automatically so even sessions that forget the manual call get the heal.

## Why

- **Eliminates the 5+ manual `gh issue edit` calls per planning session** observed in #19701 and #19724.
- **Self-healing that doesn't depend on memory recall or agent discipline** — the knowledge becomes intrinsic to the tool, available even to agents that skip memory queries.
- **Retires itself gracefully** — once t2218 and t2219 both merge and the underlying bugs are gone, this subcommand becomes a no-op (no `For/Ref`-linked issues will receive wrong `status:done`; no `auto-dispatch` issues will get self-assigned via `claim-task-id.sh`). No breaking change; no removal needed.
- **Audit-trail-linked** — the comment it posts cites the bug ID, so any future reader can trace why the label change happened rather than seeing a mystery edit.
- **Pairs with t2227 (AGENTS.md doc) and t2234 (brief-template doc)** — the three together constitute a complete response to the knowledge-gap incident.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** (1 script + 1 test = 2 files, but the script change is ~80-120 lines of new code in an existing file)
- [x] **Every target file under 500 lines?** (interactive-session-helper.sh is under 1000 lines; change is additive)
- [ ] **Exact `oldString`/`newString` for every edit?** (skeleton provided; implementer needs to compose the subcommand dispatch integration into the existing arg-parser)
- [ ] **No judgment or design decisions?** (one design point: comment text to post on corrected issues)
- [x] **No error handling or fallback logic to design?** (established pattern: fail-open, warn once, exit 0)
- [x] **No cross-package or cross-module changes?** (single helper script + colocated test)
- [x] **Estimate 1h or less?** (~1-2h with test)
- [x] **4 or fewer acceptance criteria?** (5 — see below)

**Selected tier:** `tier:standard`

**Tier rationale:** New subcommand added to an existing helper script following the existing subcommand pattern (`claim`, `release`, `scan-stale`). Modest design judgment (comment text, parse approach), regression test required, and the dispatch integration into the existing CLI arg-parser is multi-step. Sonnet-comfortable; Haiku would struggle with the subcommand scaffolding without verbatim oldString/newString for the parser.

## PR Conventions

Leaf (non-parent) issue. PR body MUST use `Resolves #19732`.

## Files to Modify

- `EDIT: .agents/scripts/interactive-session-helper.sh` — add the `post-merge` subcommand dispatch + implementation
- `NEW: .agents/scripts/tests/test-interactive-session-post-merge.sh` — fixture-based test asserting both heal passes behave correctly on a constructed PR body

## Implementation Steps

### Step 1: Add `post-merge` to the subcommand dispatcher

Locate the existing subcommand dispatch block in `interactive-session-helper.sh` (search for `"$cmd" in` or similar). Add a case for `post-merge` that extracts `<PR_NUMBER>` and optional `<slug>` (defaulting to the current repo's slug via `_resolve_slug`).

Model on the existing `release` subcommand's argument parsing.

### Step 2: Implement `cmd_post_merge()`

Structure:

```bash
cmd_post_merge() {
    local pr_number="$1"
    local slug="${2:-$(_resolve_slug 2>/dev/null || echo "")}"

    [[ -n "$pr_number" && -n "$slug" ]] || {
        echo "usage: post-merge <PR_NUMBER> [<slug>]" >&2
        return 1
    }

    # Fetch PR metadata; fail-open on offline gh
    local pr_json
    pr_json=$(gh pr view "$pr_number" --repo "$slug" --json body,author,mergedAt,state 2>/dev/null) || {
        log_warn "post-merge: gh unavailable or PR not accessible; skipping"
        return 0
    }

    local merged_at state body author
    merged_at=$(echo "$pr_json" | jq -r '.mergedAt // ""')
    state=$(echo "$pr_json" | jq -r '.state // ""')
    body=$(echo "$pr_json" | jq -r '.body // ""')
    author=$(echo "$pr_json" | jq -r '.author.login // ""')

    [[ -n "$merged_at" && "$state" == "MERGED" ]] || {
        log_info "post-merge: PR #$pr_number not merged; skipping"
        return 0
    }

    _post_merge_heal_status_done "$pr_number" "$slug" "$body"
    _post_merge_heal_stale_self_assign "$pr_number" "$slug" "$body" "$author"
    return 0
}
```

### Step 3: Implement `_post_merge_heal_status_done()` (t2219 workaround)

```bash
_post_merge_heal_status_done() {
    local pr_number="$1" slug="$2" body="$3"

    # Extract For/Ref issue numbers (case-insensitive, anchored to the issue-number boundary)
    local for_refs
    for_refs=$(printf '%s' "$body" \
        | grep -oiE '(^|[^a-z])(for|ref)[[:space:]]+#[0-9]+' \
        | grep -oE '#[0-9]+' | tr -d '#' | sort -u)

    [[ -n "$for_refs" ]] || return 0

    local healed=0
    while IFS= read -r issue_num; do
        [[ -n "$issue_num" ]] || continue

        local issue_json
        issue_json=$(gh issue view "$issue_num" --repo "$slug" --json state,labels 2>/dev/null) || continue

        local issue_state
        issue_state=$(echo "$issue_json" | jq -r '.state')
        [[ "$issue_state" == "OPEN" ]] || continue

        local has_done
        has_done=$(echo "$issue_json" | jq -r '[.labels[].name] | map(select(. == "status:done")) | length')
        [[ "$has_done" -gt 0 ]] || continue

        log_info "post-merge: healing false status:done on #$issue_num (t2219, referenced via For/Ref in PR #$pr_number)"
        gh issue edit "$issue_num" --repo "$slug" \
            --remove-label "status:done" \
            --add-label "status:available" >/dev/null 2>&1 || continue

        gh issue comment "$issue_num" --repo "$slug" --body \
            "Reset \`status:done\` → \`status:available\` — PR #${pr_number} referenced this via \`For\`/\`Ref\` (planning convention), not \`Closes\`/\`Resolves\`. Workaround for [t2219](../issues/19719) (\`issue-sync.yml\` title-fallback false-positive)." >/dev/null 2>&1 || true

        healed=$((healed + 1))
    done <<< "$for_refs"

    [[ $healed -gt 0 ]] && log_info "post-merge: healed status:done on $healed issue(s)"
    return 0
}
```

### Step 4: Implement `_post_merge_heal_stale_self_assign()` (t2218 workaround)

```bash
_post_merge_heal_stale_self_assign() {
    local pr_number="$1" slug="$2" body="$3" pr_author="$4"

    [[ -n "$pr_author" ]] || return 0

    # Extract ALL issue refs (closing keywords + For/Ref), not just For/Ref
    local all_refs
    all_refs=$(printf '%s' "$body" \
        | grep -oiE '(closes?|fixes?|resolves?|for|ref)[[:space:]]+#[0-9]+' \
        | grep -oE '#[0-9]+' | tr -d '#' | sort -u)

    [[ -n "$all_refs" ]] || return 0

    local healed=0
    while IFS= read -r issue_num; do
        [[ -n "$issue_num" ]] || continue

        local issue_json
        issue_json=$(gh issue view "$issue_num" --repo "$slug" --json state,labels,assignees 2>/dev/null) || continue

        local issue_state
        issue_state=$(echo "$issue_json" | jq -r '.state')
        [[ "$issue_state" == "OPEN" ]] || continue

        local labels_str
        labels_str=$(echo "$issue_json" | jq -r '[.labels[].name] | join(",")')

        # Require origin:interactive + auto-dispatch + not in active state
        [[ ",$labels_str," == *",origin:interactive,"* ]] || continue
        [[ ",$labels_str," == *",auto-dispatch,"* ]] || continue
        [[ ",$labels_str," != *",status:in-review,"* ]] || continue
        [[ ",$labels_str," != *",status:in-progress,"* ]] || continue

        # Check for pr_author in assignees
        local has_author
        has_author=$(echo "$issue_json" | jq -r --arg u "$pr_author" '[.assignees[].login] | map(select(. == $u)) | length')
        [[ "$has_author" -gt 0 ]] || continue

        log_info "post-merge: healing stale self-assignment on #$issue_num (t2218, pr_author=$pr_author)"
        gh issue edit "$issue_num" --repo "$slug" --remove-assignee "$pr_author" >/dev/null 2>&1 || continue

        gh issue comment "$issue_num" --repo "$slug" --body \
            "Unassigned @${pr_author} — this issue has \`auto-dispatch\` and should be pulse-dispatched to a worker. Workaround for [t2218](../issues/19718) (\`claim-task-id.sh\` missing t2157 carve-out in \`_auto_assign_issue\`)." >/dev/null 2>&1 || true

        healed=$((healed + 1))
    done <<< "$all_refs"

    [[ $healed -gt 0 ]] && log_info "post-merge: healed stale self-assignment on $healed issue(s)"
    return 0
}
```

### Step 5: Add the regression test

Create `.agents/scripts/tests/test-interactive-session-post-merge.sh`. Fixture-based: stub `gh` to return constructed responses and assert the helper makes the expected edit calls.

Cover at minimum:
- **Positive t2219:** PR body with `For #X`, #X has `status:done` + OPEN → helper calls `gh issue edit ... --remove-label status:done --add-label status:available` on #X.
- **Negative t2219:** PR body with `Closes #X`, #X has `status:done` → helper does NOT touch #X (closing keyword is legitimate).
- **Positive t2218:** PR body with `For #X`, #X has `origin:interactive + auto-dispatch + assignee=marcusquinn + no status:in-review` → helper calls `gh issue edit ... --remove-assignee marcusquinn`.
- **Negative t2218:** #X has `status:in-review` → helper does NOT unassign (the session is actively working on it).
- **Idempotency:** second run finds nothing to heal, returns 0, makes no edits.

Model stub pattern on existing tests (e.g., `test-dispatch-dedup-multi-operator.sh`).

### Step 6: Update the usage/help text

Extend the `--help` / usage print block to include the new `post-merge` subcommand, one-line description.

## Verification

```bash
# 1. shellcheck clean
shellcheck .agents/scripts/interactive-session-helper.sh
shellcheck .agents/scripts/tests/test-interactive-session-post-merge.sh

# 2. regression test passes
bash .agents/scripts/tests/test-interactive-session-post-merge.sh

# 3. help text includes the new subcommand
.agents/scripts/interactive-session-helper.sh --help | grep -q "post-merge"

# 4. idempotent no-op on already-healthy PR
.agents/scripts/interactive-session-helper.sh post-merge <some-clean-PR> marcusquinn/aidevops
```

## Acceptance Criteria

- [ ] `post-merge <PR>` subcommand exists and is documented in `--help`
- [ ] t2219 heal path: removes `status:done` + adds `status:available` on OPEN `For/Ref`-referenced issues that have `status:done`
- [ ] t2218 heal path: unassigns PR author from OPEN issues with `origin:interactive` + `auto-dispatch` + no active status label
- [ ] Posts short audit-trail comment on each healed issue citing the relevant bug ID
- [ ] Regression test covers positive + negative + idempotency cases and passes
- [ ] Fail-open behaviour: offline `gh`, missing PR, malformed body all return exit 0 without acting

## Context & Decisions

- **Why post-merge as a separate subcommand instead of extending `release`?** `release` is scoped to releasing an interactive-session claim on ONE specific issue. `post-merge` is scoped to auditing downstream side effects of a PR merge across MULTIPLE referenced issues. Different cardinality, different trigger, different semantics. Distinct subcommands match the existing style (each cmd does one thing).

- **Why post a comment on each healed issue?** Without the comment, a future reader sees a mystery label edit in the audit trail and may revert it or mis-diagnose. The comment costs one API call per heal and buys unambiguous attribution.

- **Why include both `Closes/Fixes/Resolves` and `For/Ref` refs in the t2218 heal pass but only `For/Ref` in the t2219 pass?** For t2218: ANY issue referenced in a merged PR that is self-assigned + auto-dispatch + not actively worked is a candidate for heal, regardless of which keyword was used. For t2219: only `For/Ref` is the false-positive signal; `Closes/Fixes/Resolves` + `status:done` is the LEGITIMATE case and must NOT be touched.

- **Why no-op rather than removal when the source bugs ship?** Keeps the audit-trail comments stable; a future re-introduction of either bug would be caught by this helper. Low maintenance cost for defense-in-depth.

- **Not wired into `full-loop-helper.sh merge` in this task.** Agent-facing subcommand first; downstream integration is a separate concern that can be added incrementally (a follow-up task if agent-discipline proves insufficient).

## Relevant files

- **Edit:** `.agents/scripts/interactive-session-helper.sh` (add `post-merge` subcommand + `_post_merge_heal_*` helpers)
- **New:** `.agents/scripts/tests/test-interactive-session-post-merge.sh`
- **Pattern source:** existing `claim`, `release`, `scan-stale` subcommands for arg parsing + fail-open style
- **Model stubs:** `.agents/scripts/tests/test-dispatch-dedup-multi-operator.sh` for `gh` stubbing pattern
- **Related bugs:** t2218 (GH#19718), t2219 (GH#19719)
- **Prompt-rule anchor:** `prompts/build.txt` "Interactive issue ownership (MANDATORY — AI-driven, t2056)"

## Dependencies

- Independent of t2218 and t2219 — this task WORKAROUNDS them, so ships first or in parallel.
- Soft-pair with t2227 (AGENTS.md update should mention this subcommand) and t2234 (brief template update should mention this subcommand). Land t2225 first so the doc updates can reference it as the recommended workaround.
