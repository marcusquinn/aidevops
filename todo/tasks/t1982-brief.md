---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1982: Fix broken issue consolidation flow — create self-contained child issue, @mention authors, close parent

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) via ai-interactive
- **Parent task:** none
- **Conversation context:** User noticed issue #18365 was tagged `needs-consolidation` with a comment promising a consolidation worker would create a merged child issue, but no child issue ever appeared and the original sat in dispatch limbo. Investigation confirmed `_dispatch_issue_consolidation()` only labels+comments and never creates the promised follow-up.

## What

Fix `_dispatch_issue_consolidation()` in `.agents/scripts/pulse-triage.sh` so that in addition to labelling the parent and posting the "consolidation needed" comment, it **creates a self-contained `consolidation-task` child issue** that contains:

1. The full parent title, body, and substantive comments inline (worker does NOT need to read the parent issue — everything required is on the child).
2. Explicit step-by-step instructions for the worker to produce a merged issue body, file it via `gh issue create`, link both sides, @-mention all contributors, close the parent with a `consolidated` label, and close itself with a summary comment.
3. `auto-dispatch`, `origin:worker`, `tier:standard`, `consolidation-task` labels so the pulse picks it up on the next cycle.
4. An `@` cc line listing every author of the substantive parent comments so they are notified when the merged child issue is produced.

Also:

- Add a one-time backfill pass that sweeps existing `needs-consolidation` labelled issues that never received a child task and dispatches one for each.
- Update `_issue_needs_consolidation()` to skip issues that already have an open linked `consolidation-task` child (avoid double-dispatch when the label exists but the re-evaluation pass clears-and-re-adds it).
- When the worker closes the parent, apply the `consolidated` marker label (already checked for at `pulse-triage.sh:246` as an "already done" marker — nothing currently sets it).

## Why

The current flow is half-built and creates dispatch limbo:

1. `_dispatch_issue_consolidation()` flags the issue with `needs-consolidation` and posts a comment promising four steps ("A consolidation worker reads… creates a new issue… links… closes"), but executes none of them. See `.agents/scripts/pulse-triage.sh:394-428`.
2. `list_dispatchable_issue_candidates_json()` at `.agents/scripts/pulse-repo-meta.sh:151` then filters every `needs-*` labelled issue out of dispatch: `select(([$labels[] | select(startswith("needs-"))] | length) == 0)`.
3. The only escape hatch is `_reevaluate_consolidation_labels()` which auto-clears the label if the substantive-comment filter output changes — but the filter is stable for completed issues, so most flagged issues stay stuck forever.

This is exactly the anti-pattern described in `prompts/build.txt` #8c ("bot comment noise skip") and in the general self-healing principle: we posted a promise we couldn't keep. Compare to the `needs-simplification` gate at `.agents/scripts/pulse-dispatch-core.sh:685-757` which does it correctly — it creates child `simplification-debt` issues that ARE dispatchable and actually reduce the target file.

Issue #18365 is the canonical repro. Any `needs-consolidation` labelled issue currently open is affected.

## Tier

### Tier checklist (verify before assigning)

Answer each question for `tier:simple`. If **any** answer is "no", use `tier:standard` or higher.

- [ ] **2 or fewer files to modify?** → no (pulse-triage.sh + pulse-dispatch-engine.sh + a new test file = 3)
- [ ] **Complete code blocks for every edit?** → no (skeletons + logic to design for comment filtering, body composition, labels)
- [ ] **No judgment or design decisions?** → no (how to format the child issue body, how much content to copy, comment author dedup)
- [ ] **No error handling or fallback logic to design?** → no (what to do if `gh issue create` fails, what to do if backfill finds a zombie issue with no comments)
- [ ] **Estimate 1h or less?** → no (~2h)
- [ ] **4 or fewer acceptance criteria?** → no (7 criteria)

All checked = `tier:simple`. Any unchecked = `tier:standard` (default) or `tier:reasoning` (no existing pattern to follow).

**Selected tier:** `tier:standard`

**Tier rationale:** Bug fix + new helper function with a clear reference pattern (the `needs-simplification` gate does the same thing for files). Judgment needed on comment-body composition and backfill scoping. Not novel enough for `tier:reasoning`.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-triage.sh:394-428` — rewrite `_dispatch_issue_consolidation()` to create the self-contained child issue after labelling the parent.
- `EDIT: .agents/scripts/pulse-triage.sh:238-302` — add a "skip if open linked consolidation-task child already exists" guard to `_issue_needs_consolidation()`.
- `EDIT: .agents/scripts/pulse-dispatch-engine.sh:720-730` — add a call to a new `_backfill_stale_consolidation_labels()` helper that dispatches children for any `needs-consolidation` issue that doesn't already have a linked child.
- `NEW: .agents/scripts/tests/test-consolidation-dispatch.sh` — shell-level fixture test covering (a) child issue creation, (b) parent body + comments inlined, (c) author @mentions, (d) dedup against existing children, (e) backfill pass.
- `EDIT: .agents/scripts/pulse-triage.sh` — register new `consolidation-task` GitHub label alongside `needs-consolidation` in the `gh label create` call, and ensure `consolidated` is also a known label.

### Implementation Steps

1. **Rewrite `_dispatch_issue_consolidation()`** following the `needs-simplification` child-issue pattern at `pulse-dispatch-core.sh:685-757`:

```bash
_dispatch_issue_consolidation() {
    local issue_number="$1"
    local repo_slug="$2"
    local repo_path="$3"

    # 1. Dedup: skip if an open consolidation-task child already exists for this parent.
    local existing_child
    existing_child=$(gh issue list --repo "$repo_slug" --state open \
        --label "consolidation-task" \
        --search "in:body \"Supersedes #${issue_number}\" OR in:body \"Consolidation target: #${issue_number}\"" \
        --json number --jq '.[0].number // empty' --limit 1 2>/dev/null) || existing_child=""
    if [[ -n "$existing_child" ]]; then
        echo "[pulse-wrapper] Consolidation skipped for #${issue_number}: child #${existing_child} already exists" >>"$LOGFILE"
        # Still ensure the parent has needs-consolidation label so it stays held
        gh issue edit "$issue_number" --repo "$repo_slug" \
            --add-label "needs-consolidation" 2>/dev/null || true
        return 0
    fi

    # 2. Fetch parent metadata and substantive comments (reusing the filter from _issue_needs_consolidation)
    local parent_title parent_body parent_labels
    parent_title=$(gh issue view "$issue_number" --repo "$repo_slug" --json title --jq '.title' 2>/dev/null) || parent_title=""
    parent_body=$(gh issue view "$issue_number" --repo "$repo_slug" --json body --jq '.body // ""' 2>/dev/null) || parent_body=""
    parent_labels=$(gh issue view "$issue_number" --repo "$repo_slug" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || parent_labels=""

    local comments_json
    comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" --paginate --jq '.' 2>/dev/null) || comments_json="[]"

    local min_chars="$ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS"

    # Same filter as _issue_needs_consolidation substantive_count — extract full comment objects this time.
    local substantive_json
    substantive_json=$(printf '%s' "$comments_json" | jq --argjson min "$min_chars" '
        [.[] | select(
            (.body | length) >= $min
            and (.user.type != "Bot")
            and (.body | test("DISPATCH_CLAIM nonce=") | not)
            and (.body | test("^(<!-- ops:start[^>]*-->\\s*)?Dispatching worker") | not)
            and (.body | test("^<!-- (nmr-hold|aidevops-signed|ops:start|provenance:start)") | not)
            and (.body | test("CLAIM_RELEASED reason=") | not)
            and (.body | test("^(Worker failed:|## Worker Watchdog Kill)") | not)
            and (.body | test("^(\\*\\*)?Stale assignment recovered") | not)
            and (.body | test("^## (Triage Review|Completion Summary|Large File Simplification Gate|Issue Consolidation Needed|Additional Review Feedback|Cascade Tier Escalation)") | not)
            and (.body | test("^This quality-debt issue was auto-generated by") | not)
            and (.body | test("<!-- MERGE_SUMMARY -->") | not)
            and (.body | test("^Closing:") | not)
            and (.body | test("^Worker failed: orphan worktree") | not)
            and (.body | test("sudo aidevops approve") | not)
            and (.body | test("^_Automated by") | not)
        ) | {login: .user.login, created_at: .created_at, body: .body}]
    ' 2>/dev/null) || substantive_json="[]"

    # 3. Dedupe authors, build @mention list
    local authors_csv
    authors_csv=$(printf '%s' "$substantive_json" | jq -r '[.[] | .login] | unique | map("@" + .) | join(" ")' 2>/dev/null) || authors_csv=""

    # 4. Compose the child issue body — SELF-CONTAINED (worker must not need to read parent).
    # Sections:
    #   - Consolidation Target (parent number, title)
    #   - Instructions (exact steps the worker runs)
    #   - Parent Body Verbatim
    #   - Substantive Comments Verbatim (in chronological order, each with author + timestamp)
    #   - Contributors cc line
    local child_body
    child_body=$(_compose_consolidation_child_body \
        "$issue_number" "$repo_slug" "$parent_title" "$parent_body" "$substantive_json" "$authors_csv" "$parent_labels")

    # 5. Ensure labels exist
    gh label create "needs-consolidation" \
        --repo "$repo_slug" \
        --description "Issue held from dispatch pending comment consolidation" \
        --color "FBCA04" --force 2>/dev/null || true
    gh label create "consolidation-task" \
        --repo "$repo_slug" \
        --description "Operational task: merge parent issue body + comments into a new consolidated issue" \
        --color "C5DEF5" --force 2>/dev/null || true
    gh label create "consolidated" \
        --repo "$repo_slug" \
        --description "Issue was superseded by a consolidated child; treated as archived" \
        --color "0E8A16" --force 2>/dev/null || true

    # 6. File the child
    local child_num
    child_num=$(gh issue create --repo "$repo_slug" \
        --title "consolidation-task: merge thread on #${issue_number} into single spec" \
        --label "consolidation-task,auto-dispatch,origin:worker,tier:standard" \
        --body "$child_body" \
        --json number --jq '.number' 2>/dev/null) || child_num=""

    if [[ -z "$child_num" ]]; then
        echo "[pulse-wrapper] ERROR: consolidation child creation FAILED for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
        # Still flag parent so it doesn't keep triggering every cycle
        gh issue edit "$issue_number" --repo "$repo_slug" --add-label "needs-consolidation" 2>/dev/null || true
        return 1
    fi

    # 7. Flag parent + post idempotent comment referencing the child
    gh issue edit "$issue_number" --repo "$repo_slug" --add-label "needs-consolidation" 2>/dev/null || true

    local parent_comment_body="## Issue Consolidation Dispatched

A consolidation task has been filed as **#${child_num}**. It contains the full body and substantive comments of this issue inline, plus instructions for a worker to produce a single merged spec, file it as a new issue, @mention all contributors, and close this issue as superseded.

**What happens next:**
1. A worker picks up #${child_num} on the next pulse cycle
2. It files a new consolidated issue with the merged spec
3. It comments \"Superseded by #NNN\" here and closes this issue with the \`consolidated\` label
4. All contributors (${authors_csv:-no substantive authors detected}) will be @mentioned on the new issue

_Automated by \`_dispatch_issue_consolidation()\` in \`pulse-triage.sh\`_"

    _gh_idempotent_comment "$issue_number" "$repo_slug" \
        "## Issue Consolidation Dispatched" "$parent_comment_body"

    echo "[pulse-wrapper] Consolidation: flagged #${issue_number} in ${repo_slug}, dispatched child #${child_num}" >>"$LOGFILE"
    return 0
}
```

2. **Add `_compose_consolidation_child_body()` helper** that builds the self-contained child issue body. The body must include complete instructions for the worker — no assumptions about what the worker knows:

```bash
_compose_consolidation_child_body() {
    local parent_num="$1" repo_slug="$2" parent_title="$3"
    local parent_body="$4" substantive_json="$5" authors_csv="$6" parent_labels="$7"

    # Build the "verbatim comments" section from substantive_json
    local comments_section
    comments_section=$(printf '%s' "$substantive_json" | jq -r '
        to_entries | map(
            "### Comment " + ((.key + 1) | tostring) + " — @" + .value.login + " at " + .value.created_at +
            "\n\n" + .value.body + "\n"
        ) | join("\n---\n\n")
    ' 2>/dev/null) || comments_section="_No substantive comments captured._"

    cat <<EOF
## Consolidation Target

**Parent issue:** #${parent_num} in ${repo_slug}
**Parent title:** ${parent_title}
**Parent labels:** ${parent_labels}

> You do **NOT** need to read #${parent_num}. Everything required is inline below.
> Reading the parent wastes tokens and is explicitly disallowed for this task.

## What to Do

1. **Read the parent body and substantive comments inlined below.** Identify:
   - The original problem statement
   - Scope modifications added by commenters (additions, corrections, clarifications)
   - Resolved questions, rejected ideas, or superseded decisions
   - The final agreed-upon approach

2. **Compose a single coherent issue body** in the aidevops brief format (see \`templates/brief-template.md\`):
   - \`## What\` — the deliverable
   - \`## Why\` — the problem and rationale
   - \`## How\` — approach with explicit file paths and line references
   - \`## Acceptance Criteria\` — testable checkboxes
   - \`## Context & Decisions\` — what was decided and why, including which commenter contributed which insight (attribution matters)
   - \`## Contributors\` — a cc line @-mentioning every author from the list below

   Start the merged body with: \`_Supersedes #${parent_num} — this issue is the consolidated spec._\`

3. **File the new consolidated issue:**

   \`\`\`bash
   gh issue create --repo "${repo_slug}" \\
     --title "consolidated: <concise description derived from the merged spec>" \\
     --label "consolidated,<copy relevant labels from parent, excluding needs-consolidation>" \\
     --body "<merged body from step 2>"
   \`\`\`

   Capture the new issue number.

4. **Close the parent #${parent_num}:**

   \`\`\`bash
   gh issue comment ${parent_num} --repo "${repo_slug}" \\
     --body "Superseded by #<new>. The merged spec is inline on the new issue — see there for continued discussion."
   gh issue edit ${parent_num} --repo "${repo_slug}" \\
     --add-label "consolidated" --remove-label "needs-consolidation"
   gh issue close ${parent_num} --repo "${repo_slug}" --reason "not planned"
   \`\`\`

5. **Close this consolidation-task issue** with a summary comment:

   \`\`\`bash
   gh issue comment <this-issue-number> --repo "${repo_slug}" \\
     --body "Consolidation complete. Parent: #${parent_num} → New: #<new>. Contributors @-mentioned: ${authors_csv:-none}."
   gh issue close <this-issue-number> --repo "${repo_slug}" --reason "completed"
   \`\`\`

## Constraints

- **Do NOT read #${parent_num}** — it is inlined below. Reading it wastes the token budget.
- **Preserve all substantive content.** Merging is not summarising. If a comment adds a constraint, that constraint must appear in the merged body.
- **Preserve author attribution** for specific contributions: "per @user1: …".
- **No PR is required.** This is an operational task. The completion signal is the new issue number + parent closure. Close this issue yourself when done.
- **Contributors to @-mention** on the new issue: ${authors_csv:-none detected}

## Parent Body (verbatim)

${parent_body}

## Substantive Comments (verbatim, in chronological order)

${comments_section}

---

_Self-contained dispatch packet generated by \`_dispatch_issue_consolidation()\` in \`pulse-triage.sh\`. Everything above is sufficient — do not read #${parent_num}._
EOF
}
```

3. **Update `_issue_needs_consolidation()`** to skip issues that already have an open `consolidation-task` child (prevents the re-evaluation sweep from triggering duplicate dispatches during the window between label application and child creation):

```bash
# After the existing consolidated-label skip and before the substantive_count check
local existing_child_count
existing_child_count=$(gh issue list --repo "$repo_slug" --state open \
    --label "consolidation-task" \
    --search "in:body \"#${issue_number}\"" \
    --json number --jq 'length' --limit 5 2>/dev/null) || existing_child_count=0
if [[ "$existing_child_count" -gt 0 ]]; then
    return 1
fi
```

4. **Add a backfill pass `_backfill_stale_consolidation_labels()`** in `pulse-triage.sh` that runs alongside `_reevaluate_consolidation_labels()`. For every open `needs-consolidation` issue that has **no** open linked `consolidation-task` child, call `_dispatch_issue_consolidation()` to dispatch one retroactively. Wire into the pre-dispatch pass in `pulse-dispatch-engine.sh:721-730`:

```bash
# pulse-dispatch-engine.sh, after _reevaluate_consolidation_labels
_backfill_stale_consolidation_labels
```

5. **Regression test** at `.agents/scripts/tests/test-consolidation-dispatch.sh`. Use mocked `gh` (set `PATH` to a tmpdir with a stub `gh` that echoes canned responses) to cover:
   - Child issue created with parent body + comments inline
   - `@user1 @user2` appears in child body when comments exist
   - Re-running on the same parent does NOT create a second child (dedup)
   - Backfill pass dispatches a child for a `needs-consolidation` issue with no child
   - `_issue_needs_consolidation` returns 1 when a child already exists

### Verification

```bash
cd ~/Git/aidevops-bugfix-consolidation-worker
shellcheck .agents/scripts/pulse-triage.sh .agents/scripts/pulse-dispatch-engine.sh
shellcheck .agents/scripts/tests/test-consolidation-dispatch.sh
bash .agents/scripts/tests/test-consolidation-dispatch.sh
# Spot-check integration against the real test suite:
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
```

## Acceptance Criteria

- [ ] `_dispatch_issue_consolidation()` creates a `consolidation-task` child issue via `gh issue create` when it runs against a parent that doesn't already have one.
  ```yaml
  verify:
    method: codebase
    pattern: "gh issue create --repo"
    path: ".agents/scripts/pulse-triage.sh"
  ```
- [ ] The child issue body contains the parent title, full parent body verbatim, and each substantive comment verbatim (author + timestamp header), so the worker never needs to read the parent.
  ```yaml
  verify:
    method: codebase
    pattern: "You do \\*\\*NOT\\*\\* need to read"
    path: ".agents/scripts/pulse-triage.sh"
  ```
- [ ] The child issue body includes a `Contributors` cc line @-mentioning every unique author of the filtered substantive comments.
  ```yaml
  verify:
    method: codebase
    pattern: "unique \\| map"
    path: ".agents/scripts/pulse-triage.sh"
  ```
- [ ] Calling `_dispatch_issue_consolidation()` twice on the same parent does NOT create a second child (dedup by open `consolidation-task` + parent reference).
  ```yaml
  verify:
    method: codebase
    pattern: "_consolidation_child_exists"
    path: ".agents/scripts/pulse-triage.sh"
  ```
- [ ] A pre-dispatch backfill pass dispatches a child for any open `needs-consolidation` issue that has no linked child, so existing stuck issues (including #18365) self-heal on the next pulse cycle.
  ```yaml
  verify:
    method: codebase
    pattern: "_backfill_stale_consolidation_labels"
    path: ".agents/scripts/pulse-dispatch-engine.sh"
  ```
- [ ] `_issue_needs_consolidation()` returns 1 (skip) when an open `consolidation-task` child already references the parent, preventing dispatch loops.
  ```yaml
  verify:
    method: codebase
    pattern: "if _consolidation_child_exists"
    path: ".agents/scripts/pulse-triage.sh"
  ```
- [ ] `shellcheck` passes for all touched scripts.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-triage.sh .agents/scripts/pulse-dispatch-engine.sh .agents/scripts/tests/test-consolidation-dispatch.sh"
  ```
- [ ] New regression test `.agents/scripts/tests/test-consolidation-dispatch.sh` passes.
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-consolidation-dispatch.sh"
  ```

## Context & Decisions

- **Option A (LLM worker) over Option B (deterministic dump)** — decided in interactive session. The comment posted on flagged issues already promises a "merged spec, body-only, no comment archaeology". A deterministic dump (concat body + comments verbatim under a new header) would not honour the "body-only, no comment archaeology" contract. The LLM worker gets the verbatim content inline so it doesn't spend tokens re-fetching, but it applies judgment to produce the merge.
- **Child issue is self-contained** — user explicit requirement. The child body must include enough content that the worker never needs `gh issue view ${parent}`. This is also a cost optimisation: the child fetch happens once at dispatch time, not once per worker retry.
- **No PR required for the worker task** — this is operational, not code. The worker's completion signal is: new consolidated issue exists + parent closed with `consolidated` label + self-close with summary comment. Need to verify the pulse's worker-completion detection accepts "closed issue, no PR" for `consolidation-task` labelled issues; if not, that's a follow-up task.
- **Backfill rather than manual intervention for existing stuck issues** — issue #18365 is already stuck and will stay stuck without a backfill. A one-shot backfill pass that runs every pulse cycle (cheap: one `gh issue list --label needs-consolidation` per repo) covers both the historical backlog and any future stragglers.
- **Labels:** `consolidation-task` (new, light-blue, on child), `consolidated` (already referenced at `pulse-triage.sh:246` but never applied — now applied on parent closure), `needs-consolidation` (existing, unchanged semantics).
- **Ruled out**: adding a dedicated `consolidator` subagent. The merge is standard brief composition — Build+/Sonnet can handle it with the instructions embedded in the child body.

## Relevant Files

- `.agents/scripts/pulse-triage.sh:238-302` — `_issue_needs_consolidation()` (add child-exists skip)
- `.agents/scripts/pulse-triage.sh:305-346` — `_reevaluate_consolidation_labels()` (pattern to mirror for backfill)
- `.agents/scripts/pulse-triage.sh:394-428` — `_dispatch_issue_consolidation()` (full rewrite target)
- `.agents/scripts/pulse-dispatch-core.sh:685-757` — `needs-simplification` child-issue creation (reference pattern for child dispatch)
- `.agents/scripts/pulse-dispatch-engine.sh:720-730` — where `_reevaluate_consolidation_labels()` is called; add `_backfill_stale_consolidation_labels` alongside
- `.agents/scripts/pulse-repo-meta.sh:145-166` — `list_dispatchable_issue_candidates_json()` filter (reference: why `needs-*` excludes from dispatch)
- `.agents/scripts/tests/test-pulse-wrapper-characterization.sh:230-235` — existing characterisation test covering these function names (update if helper name changes)

## Dependencies

- **Blocked by:** none
- **Blocks:** issue #18365 (stuck behind the broken consolidation gate); any future multi-comment issue that triggers the filter
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read reference pattern (`needs-simplification` gate) | 10m | pulse-dispatch-core.sh:685-757 |
| Rewrite `_dispatch_issue_consolidation()` + helper | 40m | The bulk of the change |
| Add `_backfill_stale_consolidation_labels()` + wire-in | 20m | Mirrors `_reevaluate_consolidation_labels` |
| Add child-exists guard to `_issue_needs_consolidation()` | 10m | Small addition |
| Write regression test with mocked `gh` | 30m | 5 assertions |
| shellcheck + characterisation test | 10m | |
| **Total** | **~2h** | |
