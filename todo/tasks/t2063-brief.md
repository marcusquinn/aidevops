<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2063: fix brief-to-issue-body inlining so workers receive full context on first dispatch

## Origin

- **Created:** 2026-04-14
- **Session:** claude-code:interactive (claude-opus-4-6)
- **Created by:** ai-interactive
- **Conversation context:** User observed Sonnet workers failing to solve issues on first pass. Root-cause investigation found two recent examples (GH#18745 t2059, GH#18746 t2060) where issue bodies were 476-char pointers ("See todo/tasks/tNNN-brief.md for details") despite 10-12 KB brief files existing on disk. Traced to an ordering bug in `claim-task-id.sh` + a preservation gate in `issue-sync-helper.sh` that together produce and then protect stub bodies. Full RCA in this session's transcript.

## What

Make the brief file on disk the authoritative source of truth for issue body content. Three coordinated code changes plus a heading-lock in the template:

1. **Claim-task-id bare path** (`claim-task-id.sh:_compose_issue_body`): when a brief file exists at `todo/tasks/${task_id}-brief.md`, always inline Worker Guidance + full Task Brief into the issue body on creation — regardless of whether `--description` was provided. The `--description` becomes the summary paragraph at the top; the brief content follows. Append the same `*Synced from TODO.md by issue-sync-helper.sh*` sentinel footer that the rich path writes, so subsequent enrich calls are allowed to refresh the body.

2. **Enrich gate** (`issue-sync-helper.sh:_enrich_update_issue`): replace the binary sentinel check with a three-case classifier driven by brief-file presence, not body length. If a brief file exists on disk, the brief is authoritative and the body gets refreshed. If no brief exists, the existing sentinel-based preserve/refresh logic stays. Zero character thresholds.

3. **Dispatch-time guard** (`dispatch-dedup-helper.sh:_has_active_claim` path, or the pulse dispatch wrapper): before dispatching a worker, if the issue has a corresponding brief file on disk AND the current issue body lacks the `## Task Brief` marker, force-enrich the body first. This is defense-in-depth — it should never fire once (1) and (2) ship, but it catches any future bypass.

4. **Heading-lock** (`templates/brief-template.md`) + **case-insensitive matcher** (`issue-sync-lib.sh:_compose_issue_worker_guidance`): lock the How-section heading to `## How` (optionally with ` (Approach)` suffix) and lock the subsection headings to `### Files to Modify`, `### Implementation Steps`, `### Verification`. Make the matcher case-insensitive so a lowercase `### files to modify` still activates the Worker Guidance extraction. An adjacent fragility caught during the same investigation.

## Why

Observable failure modes the fix resolves:

- **GH#18746 (t2060)**: issue body is "Flip complete_task() to extract... See todo/tasks/t2060-brief.md for details." — 476 chars. Brief file is 11,205 bytes. Two workers raced the issue producing PR #18760 (open, unmerged) and PR #18769 (merged). Duplicate work, manual cleanup.
- **GH#18745 (t2059)**: identical shape. 476-char pointer body, 10,155-byte brief file. Still in-review.

Causal chain:

1. Interactive `/new-task` or `/define` calls `claim-task-id.sh --title "..." --description "<terse>"`.
2. `claim-task-id.sh:create_github_issue` tries `_try_issue_sync_delegation` first. Delegation calls `issue-sync-helper.sh push $task_id`, which requires the TODO entry to already be in TODO.md. The TODO entry is written AFTER the claim call. Delegation fails silently.
3. Fallback `_compose_issue_body` (claim-task-id.sh:792) uses the `--description` arg verbatim. Issue is created with the 476-char stub body.
4. Caller writes the brief file + TODO entry + pushes (observed: 20 minutes later on t2060).
5. CI `issue-sync.yml` runs on the TODO push → `_enrich_process_task` composes a rich body via `compose_issue_body` (which inlines Worker Guidance + Task Brief) → calls `_enrich_update_issue`.
6. `_enrich_update_issue` at `issue-sync-helper.sh:766` sees the existing body lacks the `"Synced from TODO.md by issue-sync-helper.sh"` sentinel footer → classifies it as "external human content" → `do_body_update=false` → preserves the terse stub and only updates labels/title.
7. Worker dispatched against the stub body. Must burn tokens (observed ~1500-3000 per attempt on Sonnet) discovering the brief path, reading it, re-orienting. Dedup window closes during exploration → second worker dispatched. Two PRs race. Duplicate delivery, noisy audit trail.

Root architectural problem: the brief file and the issue body are **two copies of the same content**, and the enrich gate was built to protect one copy from the other. With the fix, the brief file is the single source of truth and the body is a view — no preservation needed, no drift, no race.

Secondary benefit: briefs edited after issue creation (refining a How section a day later) currently never reach the worker. Under the fix, any subsequent enrich pass refreshes the body from the current brief. No drift.

## Tier

### Tier checklist

- [x] **More than 2 files to modify?** Yes (claim-task-id.sh, issue-sync-helper.sh, issue-sync-lib.sh, dispatch-dedup-helper.sh, templates/brief-template.md, tests) — disqualifies `tier:simple`.
- [ ] Skeleton code blocks? No — every change is explicit with verbatim patterns cited below.
- [ ] Error/fallback logic to design? No — brief-exists-on-disk is a boolean; sentinel logic stays unchanged for the no-brief case.
- [x] Estimate > 1h? Yes (~3-4h) — disqualifies `tier:simple`.
- [ ] More than 4 acceptance criteria? 6 criteria, each mechanically checkable.
- [ ] Judgment keywords? No — the rule is "brief exists → brief wins; no brief → preserve".

**Selected tier:** `tier:standard`

**Tier rationale:** Mechanical implementation following established patterns in the codebase. The new composition logic reuses the existing `_compose_issue_worker_guidance` and `_compose_issue_brief` helpers. The enrich classifier is a 5-line change. No architectural decisions, no novel design.

## How (Approach)

### Files to Modify

- **EDIT:** `.agents/scripts/claim-task-id.sh:792-836` (`_compose_issue_body`) — always inline brief when one exists, append sentinel footer.
- **EDIT:** `.agents/scripts/issue-sync-helper.sh:760-787` (`_enrich_update_issue`) — three-case classifier driven by brief-file presence.
- **EDIT:** `.agents/scripts/issue-sync-lib.sh:971-1005` (`_compose_issue_worker_guidance`) — case-insensitive heading match.
- **EDIT:** `.agents/scripts/dispatch-dedup-helper.sh` or `.agents/scripts/pulse-dispatch-core.sh` — pre-dispatch brief-body guard. Place it in the same Layer 6 path where other dispatch guards live.
- **EDIT:** `.agents/templates/brief-template.md` — lock the How-section and subsection headings with a `<!-- HEADING LOCK -->` comment and normative language.
- **NEW:** `.agents/scripts/tests/test-brief-inline-classifier.sh` — unit test covering:
  - `claim-task-id.sh` path A: terse description + brief exists → body contains `## Task Brief`
  - `claim-task-id.sh` path B: terse description + no brief → body is terse (no regression)
  - `_enrich_update_issue` case 1: brief exists → `do_body_update=true`
  - `_enrich_update_issue` case 2: no brief, no sentinel → `do_body_update=false` (preserve)
  - `_enrich_update_issue` case 3: no brief, sentinel present → `do_body_update=(current != composed)` (refresh on diff)
  - case-insensitive heading match: `### files to modify` lowercase activates Worker Guidance extraction

### Reference patterns

- **`.agents/scripts/issue-sync-lib.sh:1011-1033`** (`_compose_issue_brief`) — canonical brief-append pattern. Reuse by sourcing `issue-sync-lib.sh` from `claim-task-id.sh`, not by duplicating.
- **`.agents/scripts/issue-sync-lib.sh:971-1005`** (`_compose_issue_worker_guidance`) — canonical How-section extractor. The `awk '/^## How/ {capture=1; next} /^## / && capture {exit} capture'` pattern is correct; only the downstream subsection matcher needs the case-insensitive fix.
- **`.agents/scripts/issue-sync-lib.sh:910`** — the sentinel footer string `*Synced from TODO.md by issue-sync-helper.sh*`. Use `_compose_issue_html_notes_and_footer` as the single source of the footer format.
- **`.agents/scripts/tests/test-privacy-guard.sh`** — stub style for new test file.

### Implementation Steps

**Step 1 — Source issue-sync-lib.sh from claim-task-id.sh.** At the top of `claim-task-id.sh`, alongside the existing helper imports, source `issue-sync-lib.sh` so `_compose_issue_worker_guidance`, `_compose_issue_brief`, and `_compose_issue_html_notes_and_footer` become available. Guard with `[[ -z "${ISSUE_SYNC_LIB_SOURCED:-}" ]]` to avoid double-sourcing.

**Step 2 — Rewrite `_compose_issue_body` in claim-task-id.sh** (lines 792-836). New logic:

```bash
_compose_issue_body() {
    local title="$1"
    local description="$2"

    # Extract task ID from title
    local task_id=""
    [[ "$title" =~ ^(t[0-9]+) ]] && task_id="${BASH_REMATCH[1]}"

    local brief_file=""
    if [[ -n "$task_id" ]]; then
        brief_file="${REPO_PATH}/todo/tasks/${task_id}-brief.md"
    fi

    local body=""

    # Summary paragraph: caller's --description, OR brief's What section, OR nothing
    if [[ -n "$description" ]]; then
        body="$description"
    elif [[ -f "$brief_file" ]]; then
        local brief_what
        brief_what=$(_read_brief_what_section "$task_id" "$REPO_PATH") || true
        [[ -n "$brief_what" ]] && body="## Task"$'\n\n'"$brief_what"
    fi

    # If brief exists, inline Worker Guidance + full Task Brief
    if [[ -f "$brief_file" ]]; then
        body=$(_compose_issue_worker_guidance "$body" "$brief_file")
        body=$(_compose_issue_brief "$body" "$brief_file")
        # Append sentinel + signature footer via the shared composer
        body=$(_compose_issue_html_notes_and_footer "$body" "")
    else
        # No brief: existing behavior — refuse to create stub, or use description as-is
        if [[ -z "$body" ]]; then
            log_error "No --description provided and no brief file found at todo/tasks/${task_id}-brief.md"
            log_error "Issue creation skipped — create the brief first, or provide --description"
            echo ""
            return 1
        fi
        # Append signature footer via gh-signature-helper
        local sig_helper="${SCRIPT_DIR}/gh-signature-helper.sh"
        if [[ -x "$sig_helper" ]]; then
            local sig_footer
            sig_footer=$("$sig_helper" footer --body "$body" 2>/dev/null || echo "")
            [[ -n "$sig_footer" ]] && body="$body"$'\n'"$sig_footer"
        fi
    fi

    echo "$body"
    return 0
}
```

**Step 3 — Rewrite `_enrich_update_issue` in issue-sync-helper.sh** (lines 760-787). New logic:

```bash
_enrich_update_issue() {
    local repo="$1" num="$2" task_id="$3" title="$4" body="$5"
    local do_body_update=true

    if [[ "$FORCE_ENRICH" != "true" ]]; then
        # Source of truth: does a brief file exist on disk?
        local project_root brief_file
        project_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
        brief_file="${project_root}/todo/tasks/${task_id}-brief.md"

        local current_body
        current_body=$(gh issue view "$num" --repo "$repo" --json body -q .body 2>/dev/null || echo "")

        if [[ -f "$brief_file" ]]; then
            # Brief exists → brief is authoritative, refresh if different
            if [[ "$current_body" == "$body" ]]; then
                print_info "Body unchanged on #$num ($task_id), skipping API call"
                do_body_update=false
            fi
            # else: refresh
        elif [[ "$current_body" == *"Synced from TODO.md by issue-sync-helper.sh"* ]]; then
            # No brief, has sentinel: previously synced → refresh on diff (existing)
            if [[ "$current_body" == "$body" ]]; then
                print_info "Body unchanged on #$num ($task_id), skipping API call"
                do_body_update=false
            fi
        else
            # No brief, no sentinel: genuine external content → preserve (existing)
            print_info "Preserving external body on #$num ($task_id) — no brief file, no sentinel (use --force to override)"
            do_body_update=false
        fi
    fi

    if [[ "$do_body_update" == "true" ]]; then
        if gh issue edit "$num" --repo "$repo" --title "$title" --body "$body" 2>/dev/null; then
            return 0
        fi
        print_error "Failed to enrich body on #$num ($task_id)"
        return 1
    fi
    # Still update title even when body is preserved/skipped (GH#18411)
    if gh issue edit "$num" --repo "$repo" --title "$title" 2>/dev/null; then
        return 0
    fi
    print_error "Failed to enrich title on #$num ($task_id)"
    return 1
}
```

**Step 4 — Case-insensitive heading match in `_compose_issue_worker_guidance`** (issue-sync-lib.sh:971-1005). Change:

```bash
has_files=$(echo "$how_section" | grep -c '### Files to Modify\|EDIT:\|NEW:' || true)
has_steps=$(echo "$how_section" | grep -c '### Implementation Steps' || true)
has_verify=$(echo "$how_section" | grep -c '### Verification' || true)
```

to:

```bash
has_files=$(echo "$how_section" | grep -ic '### Files to Modify\|EDIT:\|NEW:' || true)
has_steps=$(echo "$how_section" | grep -ic '### Implementation Steps' || true)
has_verify=$(echo "$how_section" | grep -ic '### Verification' || true)
```

`-i` flag makes grep case-insensitive. Also remove the dead `has_verify` assignment if it remains unused, or add it to the condition.

**Step 5 — Pre-dispatch brief-body guard.** Add a small check function somewhere in the dispatch path (recommend adding to `dispatch-dedup-helper.sh` as a sibling of `is_assigned`, or as a new phase in `pulse-dispatch-core.sh` before worker spawn):

```bash
# _ensure_body_has_brief: if a brief exists on disk for the task but the issue
# body lacks the ## Task Brief marker, force-enrich before dispatch.
_ensure_body_has_brief() {
    local issue_num="$1" repo="$2"

    # Resolve task_id from issue title
    local task_id
    task_id=$(gh issue view "$issue_num" --repo "$repo" --json title -q .title 2>/dev/null | grep -oE '^t[0-9]+' | head -1)
    [[ -z "$task_id" ]] && return 0  # No task_id → nothing to check

    # Check for brief file (via gh API on the canonical repo, not local worktree)
    local brief_exists
    brief_exists=$(gh api "repos/${repo}/contents/todo/tasks/${task_id}-brief.md" --jq .name 2>/dev/null || echo "")
    [[ -z "$brief_exists" ]] && return 0  # No brief → nothing to enforce

    # Check if body already has the Task Brief marker
    local body
    body=$(gh issue view "$issue_num" --repo "$repo" --json body -q .body 2>/dev/null || echo "")
    if echo "$body" | grep -q "## Task Brief\|## Worker Guidance"; then
        return 0  # Already upgraded
    fi

    # Force-enrich via issue-sync-helper.sh
    print_warning "Issue #$issue_num has brief on disk but stub body — force-enriching before dispatch"
    FORCE_ENRICH=true "${SCRIPT_DIR}/issue-sync-helper.sh" enrich --task-id "$task_id" 2>&1 | tail -5 || true
    return 0
}
```

Wire it into the dispatch path immediately before the worker spawn (after dedup checks pass, before `headless-runtime-helper.sh run`).

**Step 6 — Template heading-lock.** In `templates/brief-template.md`, above the `## How` section, add:

```markdown
<!-- HEADING LOCK (t2063): the following heading must remain exactly "## How"
     (optionally with " (Approach)" suffix). The subsection headings must be
     exactly "### Files to Modify", "### Implementation Steps", and
     "### Verification". issue-sync-lib.sh:_compose_issue_worker_guidance
     extracts these sections for the Worker Guidance block in the issue body.
     Case-insensitive match is applied, but stick to the canonical casing. -->
```

**Step 7 — Unit tests.** Create `tests/test-brief-inline-classifier.sh` with the six cases listed in "Files to Modify". Use the same stub-project pattern as `tests/test-privacy-guard.sh`: create a temp dir with a fake repo structure, drop a brief file or don't, call the function under test, assert the output.

**Step 8 — Full test suite + shellcheck.**

```bash
bash .agents/scripts/tests/test-brief-inline-classifier.sh
bash .agents/scripts/tests/test-issue-sync.sh  # if it exists; else skip
shellcheck .agents/scripts/claim-task-id.sh
shellcheck .agents/scripts/issue-sync-helper.sh
shellcheck .agents/scripts/issue-sync-lib.sh
shellcheck .agents/scripts/dispatch-dedup-helper.sh
```

### Verification

```bash
# Unit tests pass
bash .agents/scripts/tests/test-brief-inline-classifier.sh

# ShellCheck clean on all touched files
shellcheck .agents/scripts/claim-task-id.sh \
           .agents/scripts/issue-sync-helper.sh \
           .agents/scripts/issue-sync-lib.sh \
           .agents/scripts/dispatch-dedup-helper.sh

# Integration: new issue created via claim-task-id with existing brief
# has rich body
cd /tmp && mkdir -p test-t2063 && cd test-t2063
git init >/dev/null 2>&1
mkdir -p todo/tasks
cat > todo/tasks/t9999-brief.md <<'EOF'
# t9999: test brief

## What
Test task.

## How

### Files to Modify
- EDIT: foo.sh

### Verification
echo done
EOF
# Now simulate the compose path (function call, not full issue creation)
source ~/.aidevops/agents/scripts/issue-sync-lib.sh
REPO_PATH=/tmp/test-t2063 bash -c 'source ~/.aidevops/agents/scripts/claim-task-id.sh; _compose_issue_body "t9999: test" ""' | grep -c "## Task Brief"
# Expected: 1

# Retroactive test: verify GH#18745/18746 would be upgraded on next enrich
# (dry run against the actual stuck issues)
FORCE_ENRICH=true .agents/scripts/issue-sync-helper.sh enrich --dry-run --task-id t2059
FORCE_ENRICH=true .agents/scripts/issue-sync-helper.sh enrich --dry-run --task-id t2060
# Expected: both show "Would enrich" with body length > 5000
```

## Acceptance Criteria

- [ ] `claim-task-id.sh:_compose_issue_body` inlines Worker Guidance + Task Brief sections when a brief file exists, regardless of whether `--description` was provided
- [ ] `claim-task-id.sh:_compose_issue_body` appends the `*Synced from TODO.md by issue-sync-helper.sh*` sentinel footer when composing from a brief, so subsequent enrich calls are allowed to refresh
- [ ] `issue-sync-helper.sh:_enrich_update_issue` uses brief-file presence as the authoritative signal: brief exists → refresh body; no brief + no sentinel → preserve (existing); no brief + sentinel → refresh on diff (existing)
- [ ] `issue-sync-lib.sh:_compose_issue_worker_guidance` uses case-insensitive heading matching (`grep -i`)
- [ ] Pre-dispatch guard detects issues with on-disk brief but stub body and force-enriches before worker spawn
- [ ] `templates/brief-template.md` documents the heading-lock convention
- [ ] New test file `tests/test-brief-inline-classifier.sh` exists and covers all six cases listed in Step 7
- [ ] ShellCheck clean on all four modified shell scripts
- [ ] PR body uses `Resolves #NNN` (this is a leaf issue, not parent-task)

## Relevant Files

- `.agents/scripts/claim-task-id.sh` — Path A fix site (`_compose_issue_body`)
- `.agents/scripts/issue-sync-helper.sh` — Path B fix site (`_enrich_update_issue`)
- `.agents/scripts/issue-sync-lib.sh` — shared composition helpers + case-insensitive matcher
- `.agents/scripts/dispatch-dedup-helper.sh` or `.agents/scripts/pulse-dispatch-core.sh` — Path C dispatch guard
- `.agents/templates/brief-template.md` — heading-lock documentation
- `.agents/scripts/tests/test-brief-inline-classifier.sh` — new unit test
- GH#18745 (t2059), GH#18746 (t2060) — canonical evidence of the failure mode

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing critical, but every non-inlined worker dispatch after this ships is wasted tokens
- **Related:** t1900 (worker-ready implementation context), t1906 (brief What section auto-read), GH#18411 (original sentinel gate)

## Estimate

~3-4h:

- Step 1-2 (claim-task-id refactor + helper sourcing): ~1h
- Step 3 (enrich classifier): ~30m
- Step 4 (case-insensitive matcher): ~10m
- Step 5 (dispatch guard): ~45m
- Step 6 (template lock): ~10m
- Step 7 (tests): ~1h
- Step 8 (verification + shellcheck): ~30m

## Out of scope

- Refactoring `compose_issue_body` itself — it already works correctly on the push path
- Rewriting the sentinel footer format — keep the existing string to preserve backward compatibility with already-synced issues
- Removing the `--force` enrich flag — it's still useful for admin overrides
- Retroactive manual enrich of GH#18745 / GH#18746 — they'll self-heal on next TODO push after merge

---
*Completes the brief-to-body inlining contract that the framework documents in `prompts/build.txt` section 9 (t1900) but doesn't enforce at the issue-creation or enrich boundaries.*
