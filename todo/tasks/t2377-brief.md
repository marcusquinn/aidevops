<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2377: fix(issue-sync): prevent enrich from wiping issue title/body when TODO entry missing

## Origin

- **Created:** 2026-04-19
- **Session:** opencode:ses_25c7cb662ffeISY17Cr9Xv6TGZ ("Issues missing title/description root cause")
- **Created by:** ai-interactive (investigation triggered by maintainer asking "what's going on with these empty issues")
- **Parent task:** none (leaf)
- **Conversation context:** Three issues (#19778/#19779/#19780) presented as having `"tNNN: "` stub titles and empty bodies. Root cause investigation traced the destruction to the pulse's `_ensure_issue_body_has_brief` → `issue-sync-helper.sh enrich` path, which overwrites issues with empty title/body when `compose_issue_body` fails due to missing TODO.md entry. Confirmed live — #19779 was re-wiped 74 seconds after manual restoration, on the same pulse cycle.

## What

Harden the `issue-sync-helper.sh enrich` code path and the pulse's force-enrich trigger so that:

1. `compose_issue_body` failure is detected and aborts the enrich call (no empty `body=""` reaches the edit).
2. `_enrich_update_issue` refuses to `gh issue edit` with an empty title OR an empty body — even under `FORCE_ENRICH=true`. These are never valid target states.
3. `_build_title` refuses to emit a `"tNNN: "` stub title when description is empty.
4. `_ensure_issue_body_has_brief` (in `pulse-dispatch-core.sh`) no longer mis-classifies bodies containing `## What` / `## Why` / `## How` as "stubs" requiring force-enrichment.
5. `_ensure_issue_body_has_brief` additionally requires a TODO.md entry to exist before it will force-enrich — brief-without-TODO is a legitimate workflow; the pulse should tolerate it, not synthesize-then-destroy.

## Why

**Data loss in progress.** The bug is not theoretical — it is actively destroying content. Observed evidence (`~/.aidevops/logs/pulse.log:85900-85904`):

```
[dispatch_with_dedup] t2063: issue #19778 has brief on disk but stub body — force-enriching
[INFO] Enriching 1 issue(s) in marcusquinn/aidevops
[ERROR] Task t2349 not found in TODO.md       ← compose_issue_body returned 1
[SUCCESS] Enriched #19778 (t2349)              ← gh issue edit --title "t2349: " --body "" succeeded
```

Three restorations required (`#19778` at 02:50:16, re-wiped at 02:51:30; one full cycle = 74s). Maintainer intervention was needed to claim `status:in-review` on all three before restoration would stick. Every `#auto-dispatch` task that has a brief on disk but no TODO.md entry is at risk.

The symptoms shown to the maintainer:

- Title `"t2349: "`, `"t2350: "`, `"t2351: "` (task ID + colon + trailing space, no description)
- Body `null` (not empty string — literally missing)
- All operational labels intact (`auto-dispatch`, `tier:*`, `status:available`)
- Pulse logs show `SUCCESS` (the destructive edit is "succeeding")

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** — no (2 source files + 1 new test file = 3)
- [x] **Every target file under 500 lines?** — no (`issue-sync-helper.sh` = 1572 lines, `pulse-dispatch-core.sh` = 1230 lines)
- [x] **Exact `oldString`/`newString` for every edit?** — no (some edits need judgment on guard placement)
- [x] **No judgment or design decisions?** — no (marker-check heuristic in layer 4 requires a judgment call between body-length threshold vs expanded marker list)
- [x] **No error handling or fallback logic to design?** — no (the layer 1 guard needs to choose between skip and fail-loudly)
- [x] **No cross-package or cross-module changes?** — yes (both files are in `.agents/scripts/`)
- [x] **Estimate 1h or less?** — no (~1.5-2h including test harness)
- [x] **4 or fewer acceptance criteria?** — no (6 criteria below)

**Selected tier:** `tier:standard`

**Tier rationale:** Multi-file hardening across two large source files with a new test harness. Each individual change is well-scoped but the marker-check heuristic in layer 4 requires a judgment call. A skilled Sonnet worker can implement this with the pattern laid out below; a Haiku worker would not reliably choose the right marker-check broadening. Not `tier:thinking` because the design is fully specified and each layer has a direct reference pattern.

## PR Conventions

Leaf task. PR body MUST use `Resolves #<new-issue>` on the fix PR (auto-closes when merged). This brief is filed via a PLANNING-ONLY PR that uses `Ref #<new-issue>, Ref #19778, Ref #19779, Ref #19780` to avoid auto-closing any of those four issues on merge.

## How (Approach)

### Worker Quick-Start

```bash
# 1. Reproduce the bug locally (creates an isolated test environment)
cd .agents/scripts/tests
./test-enrich-no-data-loss.sh    # this test is NEW in this task — write it first

# 2. Verify the fix by running against the 3 previously-affected issues
#    (they are currently claimed via status:in-review to block re-wipe)
for n in 19778 19779 19780; do
  gh api "/repos/marcusquinn/aidevops/issues/$n" --jq '{title, body_len: (.body | length)}'
done
# Expected after fix: titles start with "t234X: feat(...)", body_len > 4000

# 3. Simulate a pulse force-enrich pass against a task with brief but no TODO entry
FORCE_ENRICH=true REPO_SLUG=marcusquinn/aidevops \
  .agents/scripts/issue-sync-helper.sh enrich t9999  # (use a non-existent task)
# Expected after fix: error logged, NO gh issue edit call with empty body
```

### Files to Modify

- `EDIT: .agents/scripts/issue-sync-helper.sh:93-100` — `_build_title`: emit error + return 1 when description is empty (layer 3)
- `EDIT: .agents/scripts/issue-sync-helper.sh:1028-1056` — `_enrich_process_task`: check exit code of `compose_issue_body` at line 1030 before calling `_enrich_update_issue` (layer 1)
- `EDIT: .agents/scripts/issue-sync-helper.sh:925-988` — `_enrich_update_issue`: add empty-title-or-body refusal at the top, BEFORE the `FORCE_ENRICH` check (layer 2 — the "never-delete" invariant)
- `EDIT: .agents/scripts/pulse-dispatch-core.sh:980-1018` — `_ensure_issue_body_has_brief`: broaden the "already enriched" marker check (layer 4) AND require TODO.md entry before force-enrich (layer 5)
- `NEW: .agents/scripts/tests/test-enrich-no-data-loss.sh` — test harness asserting no destructive `gh issue edit --body ""` call ever fires

### Implementation Steps

#### 1. Layer 1 — `_enrich_process_task` checks `compose_issue_body` exit code

At `issue-sync-helper.sh:1030`, replace:

```bash
	local body
	body=$(compose_issue_body "$task_id" "$project_root")
```

with:

```bash
	local body
	local _compose_rc=0
	body=$(compose_issue_body "$task_id" "$project_root") || _compose_rc=$?
	# Layer 1 (t2377): composition failure = no authoritative body available.
	# Skip the enrich entirely rather than emit an empty body. Previous
	# behaviour allowed empty body to reach _enrich_update_issue which, under
	# FORCE_ENRICH=true, executed `gh issue edit --body ""` and DESTROYED
	# the issue's original content (data loss: #19778/#19779/#19780).
	if [[ $_compose_rc -ne 0 || -z "$body" ]]; then
		print_error "Skipping enrich for $task_id — compose_issue_body failed (rc=$_compose_rc). Task ID is not in TODO.md; fix the TODO entry or remove the brief file."
		return 0
	fi
```

#### 2. Layer 2 — `_enrich_update_issue` refuses empty title/body (the never-delete invariant)

At `issue-sync-helper.sh:925-931`, immediately after the `local` declarations and BEFORE the `FORCE_ENRICH` check, insert:

```bash
	# Layer 2 (t2377): never-delete invariant. Regardless of FORCE_ENRICH, refuse
	# to write empty title or empty body. These are never a legitimate target
	# state — `gh issue edit --title "" --body ""` is data loss, full stop.
	# If the caller believes the body should be cleared, they must pass an
	# explicit sentinel (e.g. "<!-- intentionally cleared -->") and this guard
	# will accept it. An accidental empty string is the failure mode we are
	# defending against.
	if [[ -z "$title" ]]; then
		print_error "_enrich_update_issue refused empty title for #$num ($task_id) — data loss guard (t2377)"
		return 1
	fi
	if [[ -z "$body" ]]; then
		print_error "_enrich_update_issue refused empty body for #$num ($task_id) — data loss guard (t2377)"
		return 1
	fi
	# Layer 3b (t2377): refuse stub "tNNN: " titles even when non-empty.
	# _build_title emits these when description is empty; they are the
	# symptom we saw on #19778/#19779/#19780.
	if [[ "$title" =~ ^t[0-9]+:[[:space:]]*$ ]]; then
		print_error "_enrich_update_issue refused stub title '$title' for #$num ($task_id) — data loss guard (t2377)"
		return 1
	fi
```

#### 3. Layer 3 — `_build_title` refuses empty description

At `issue-sync-helper.sh:93-100`, replace:

```bash
_build_title() {
	local task_id="$1" description="$2"
	if [[ "$description" == *" — "* ]]; then
		echo "${task_id}: ${description%% — *}"
	elif [[ ${#description} -gt 80 ]]; then
		echo "${task_id}: ${description:0:77}..."
	else echo "${task_id}: ${description}"; fi
}
```

with:

```bash
_build_title() {
	local task_id="$1" description="$2"
	# Layer 3 (t2377): refuse stub titles. When description is empty, the
	# pre-fix behaviour emitted "tNNN: " (task ID + colon + trailing space)
	# which _enrich_update_issue then wrote to the issue, destroying the
	# real title. Fail loudly so the caller sees the problem.
	if [[ -z "$description" ]]; then
		print_error "_build_title: refusing to emit stub title for ${task_id} — description is empty"
		return 1
	fi
	if [[ "$description" == *" — "* ]]; then
		echo "${task_id}: ${description%% — *}"
	elif [[ ${#description} -gt 80 ]]; then
		echo "${task_id}: ${description:0:77}..."
	else echo "${task_id}: ${description}"; fi
	return 0
}
```

**Follow-up at the call site** (`_enrich_process_task:1028`): check the return code:

```bash
	local title
	if ! title=$(_build_title "$task_id" "$desc"); then
		print_error "Skipping enrich for $task_id — empty description; fix TODO entry before retrying"
		return 0
	fi
```

Apply the same at `_push_process_task:722` (a second call site) to keep behaviour consistent.

#### 4. Layer 4 — broaden "already enriched" marker check

At `pulse-dispatch-core.sh:995-1000`, replace:

```bash
	# Check if body already contains the inline markers
	local current_body
	current_body=$(gh issue view "$issue_number" --repo "$repo_slug" --json body -q .body 2>/dev/null || echo "")
	if [[ "$current_body" == *"## Task Brief"* ]] || [[ "$current_body" == *"## Worker Guidance"* ]]; then
		return 0
	fi
```

with:

```bash
	# Check if body already has substantial content (either framework-synced
	# markers OR an externally-composed brief-style body).
	# Layer 4 (t2377): the narrow marker check mis-classified externally-
	# composed bodies as stubs. #19778/#19779/#19780 had "## What" / "## Why" /
	# "## How" bodies ~5KB each; the old check treated them as stubs and
	# force-enriched them into emptiness.
	local current_body
	current_body=$(gh issue view "$issue_number" --repo "$repo_slug" --json body -q .body 2>/dev/null || echo "")
	if [[ "$current_body" == *"## Task Brief"* ]] || [[ "$current_body" == *"## Worker Guidance"* ]]; then
		return 0
	fi
	# Brief-template-style headings count as substantial content too.
	if [[ "$current_body" == *"## What"* ]] && [[ "$current_body" == *"## How"* ]]; then
		return 0
	fi
	# Fallback length heuristic: 500+ chars is unlikely to be a stub.
	# (Real stubs from claim-task-id.sh are <200 chars.)
	if [[ ${#current_body} -ge 500 ]]; then
		return 0
	fi
```

#### 5. Layer 5 — require TODO.md entry before force-enrich

At `pulse-dispatch-core.sh:1002`, BEFORE the `force-enriching` log line and delegation call, insert:

```bash
	# Layer 5 (t2377): refuse to force-enrich when the task has a brief on disk
	# but no TODO.md entry. This combination makes compose_issue_body fail, and
	# the resulting empty body previously destroyed the issue content. The
	# correct behaviour in this case is: leave the existing (externally-
	# composed) body alone; the worker will read the brief from disk directly.
	local todo_file="${repo_path}/TODO.md"
	if [[ -f "$todo_file" ]]; then
		local task_id_ere
		task_id_ere=$(printf '%s' "$task_id" | sed 's/[.[\*^$()+?{|]/\\&/g')
		if ! grep -qE "^[[:space:]]*- \[.\] ${task_id_ere}( |$)" "$todo_file" 2>/dev/null; then
			echo "[dispatch_with_dedup] t2377: issue #${issue_number} has brief but no TODO.md entry; skipping force-enrich (safe: worker will read brief from disk)" >>"$LOGFILE"
			return 0
		fi
	fi
```

#### 6. NEW — test harness `test-enrich-no-data-loss.sh`

Model on `.agents/scripts/tests/test-brief-inline-classifier.sh` (same module, same mocking pattern). Key assertions:

```bash
# Assertion A: compose_issue_body fails → _enrich_process_task returns 0
#              WITHOUT calling gh issue edit with empty body
test_no_edit_when_compose_fails() {
    # Mock gh to record all args
    gh() {
        if [[ "$1" == "issue" && "$2" == "edit" ]]; then
            # Fail the test if --body "" or --title "tNNN: " is seen
            local args="$*"
            if [[ "$args" == *'--body ""'* ]] || [[ "$args" =~ --title\ \"t[0-9]+:\ *\" ]]; then
                echo "FAIL: destructive gh issue edit called: $args"
                return 1
            fi
        fi
        echo "https://github.com/test/test/issues/9999"
    }
    export -f gh

    # Create fixture: brief exists, no TODO entry
    mkdir -p "$TEST_REPO/todo/tasks"
    echo "# t9999 Brief" > "$TEST_REPO/todo/tasks/t9999-brief.md"
    echo "- [x] other_task" > "$TEST_REPO/TODO.md"  # t9999 NOT here

    # Call enrich — should skip, not call gh issue edit destructively
    cd "$TEST_REPO"
    FORCE_ENRICH=true REPO_SLUG=test/test "$SCRIPT_DIR/../issue-sync-helper.sh" enrich t9999
    # Assertion passes if gh mock never failed
}

# Assertion B: _enrich_update_issue refuses empty title/body
test_never_delete_invariant() {
    # Directly call _enrich_update_issue with empty body, FORCE_ENRICH=true
    # Expect: return 1, no gh issue edit call
    FORCE_ENRICH=true _enrich_update_issue "test/test" 9999 "t9999" "t9999: title" ""
    assert_equals $? 1 "empty body rejected"
    FORCE_ENRICH=true _enrich_update_issue "test/test" 9999 "t9999" "" "body"
    assert_equals $? 1 "empty title rejected"
    FORCE_ENRICH=true _enrich_update_issue "test/test" 9999 "t9999" "t9999: " "body"
    assert_equals $? 1 "stub 'tNNN: ' title rejected"
}

# Assertion C: _build_title returns 1 with empty description
test_build_title_empty_description() {
    _build_title "t9999" "" && fail "empty description should return 1"
    local title
    title=$(_build_title "t9999" "real description") && pass
    [[ "$title" == "t9999: real description" ]] || fail "normal title"
}

# Assertion D: _ensure_issue_body_has_brief skips when no TODO entry
test_skip_force_enrich_no_todo() {
    # Fixture: brief on disk, TODO.md exists but no t9999 line, issue body has "## What"
    # Expected: _ensure_issue_body_has_brief returns 0 without calling enrich
    _ensure_issue_body_has_brief 9999 test/test "$TEST_REPO" "t9999: title"
    assert_log_contains "skipping force-enrich (safe: worker will read brief from disk)"
}

# Assertion E: _ensure_issue_body_has_brief skips when body has brief-template headings
test_skip_force_enrich_brief_style_body() {
    # Mock gh issue view to return body with "## What" and "## How"
    # Expected: _ensure_issue_body_has_brief returns 0
    gh() {
        if [[ "$*" == *"issue view"* ]]; then
            echo "## What\n\nReal content.\n\n## How\n\nReal plan."
        fi
    }
    export -f gh
    _ensure_issue_body_has_brief 9999 test/test "$TEST_REPO" "t9999: title"
    # Assertion: no enrich was called
}
```

### Verification

```bash
# 1. Unit tests pass
bash .agents/scripts/tests/test-enrich-no-data-loss.sh

# 2. ShellCheck clean
shellcheck .agents/scripts/issue-sync-helper.sh
shellcheck .agents/scripts/pulse-dispatch-core.sh
shellcheck .agents/scripts/tests/test-enrich-no-data-loss.sh

# 3. Existing tests still pass
bash .agents/scripts/tests/test-brief-inline-classifier.sh

# 4. End-to-end smoke: release #19778/#19779/#19780 and confirm pulse doesn't re-wipe
bash .agents/scripts/interactive-session-helper.sh release 19778 marcusquinn/aidevops
# (wait 2 minutes, then verify)
gh api /repos/marcusquinn/aidevops/issues/19778 --jq '{title, body_len: (.body | length)}'
# Expected: title still "t2349: feat(...)...", body_len > 6000
```

## Acceptance Criteria

- [ ] Layer 1: `_enrich_process_task` checks `compose_issue_body` exit code and returns 0 (skip) when composition fails
  ```yaml
  verify:
    method: codebase
    pattern: "compose_issue_body.*\\|\\|.*_compose_rc"
    path: ".agents/scripts/issue-sync-helper.sh"
  ```
- [ ] Layer 2: `_enrich_update_issue` refuses empty title AND empty body regardless of `FORCE_ENRICH`
  ```yaml
  verify:
    method: bash
    run: "FORCE_ENRICH=true bash -c 'source .agents/scripts/issue-sync-helper.sh; _enrich_update_issue a 1 t1 \"\" body' 2>&1 | grep -q 'refused empty title'"
  ```
- [ ] Layer 3: `_build_title` returns non-zero on empty description
  ```yaml
  verify:
    method: bash
    run: "bash -c 'source .agents/scripts/issue-sync-helper.sh; _build_title t1 \"\"' 2>&1; [ $? -ne 0 ]"
  ```
- [ ] Layer 4: `_ensure_issue_body_has_brief` recognises `## What` + `## How` bodies as already-enriched
  ```yaml
  verify:
    method: codebase
    pattern: "## What.*## How|length_heuristic|500"
    path: ".agents/scripts/pulse-dispatch-core.sh"
  ```
- [ ] Layer 5: `_ensure_issue_body_has_brief` skips force-enrich when TODO entry missing
  ```yaml
  verify:
    method: codebase
    pattern: "no TODO.md entry.*skipping force-enrich"
    path: ".agents/scripts/pulse-dispatch-core.sh"
  ```
- [ ] New test `test-enrich-no-data-loss.sh` passes
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-enrich-no-data-loss.sh"
  ```
- [ ] ShellCheck clean on all three modified files
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/issue-sync-helper.sh .agents/scripts/pulse-dispatch-core.sh .agents/scripts/tests/test-enrich-no-data-loss.sh"
  ```
- [ ] End-to-end: after PR merges, releasing the claim on #19778/#19779/#19780 (removing `status:in-review`) does not result in the pulse re-wiping them within 2 pulse cycles (~20 minutes)
  ```yaml
  verify:
    method: manual
    prompt: "Release one of the three claims and wait 20 minutes. Confirm title and body remain intact."
  ```

## Context & Decisions

- **Why 5 layers, not 1?** The bug is a cascade: one defect enables the next. Fixing only the top layer (e.g., the compose_issue_body check) leaves the destructive `gh issue edit --body ""` path reachable from any future caller that forgets the check. Layer 2 (never-delete invariant) is the load-bearing guarantee: no code path, under any env var, ever writes empty. Layers 1, 3, 4, 5 prevent the invariant from triggering in normal operation.
- **Why not remove `FORCE_ENRICH=true` from `_ensure_issue_body_has_brief`?** The parameter has legitimate uses (post-creation enrichment when a brief was added after claim-task-id.sh ran). Removing it would regress the t2063 fix. Layer 2 (refuse empty) + layer 5 (require TODO entry) together neutralise the data-loss path while preserving the enrichment path.
- **Why not fix `compose_issue_body` to fall back to brief-only body?** The brief IS already inlined into the body by `compose_issue_body`'s `_compose_issue_sections` call — but only if the task block is found in TODO.md. Making compose_issue_body brief-tolerant duplicates logic already in claim-task-id.sh's `_compose_issue_body`. Instead, layer 5 short-circuits the enrich when TODO is missing; the existing (externally-composed) body stays in place, and the worker reads the brief from disk as it already does.
- **Non-goal: the t2252/GH#19782 Ref-closing-keyword false positive.** Tracked separately. That bug contributed to the cascade observed on 2026-04-18 (issues mis-marked `status:done` → maintainer re-opened → pulse re-dispatched → force-enrich wiped them) but is orthogonal. Fixing GH#19782 is necessary but not sufficient; the enrich path must be hardened regardless.
- **Non-goal: restoring lost content retroactively.** The maintainer session has already restored #19778/#19779/#19780 from the on-disk briefs and applied `status:in-review` to block re-wipe. This task's fix is what allows `status:in-review` to be released safely.

## Relevant Files

- `.agents/scripts/issue-sync-helper.sh:93-100` — `_build_title` (layer 3)
- `.agents/scripts/issue-sync-helper.sh:722` — `_push_process_task` call site of `_build_title` (layer 3 follow-up)
- `.agents/scripts/issue-sync-helper.sh:906-988` — `_enrich_update_issue` (layer 2)
- `.agents/scripts/issue-sync-helper.sh:993-1063` — `_enrich_process_task` (layer 1)
- `.agents/scripts/pulse-dispatch-core.sh:980-1018` — `_ensure_issue_body_has_brief` (layers 4 & 5)
- `.agents/scripts/tests/test-brief-inline-classifier.sh` — reference pattern for new test harness
- `~/.aidevops/logs/pulse.log:85895-85917` — observed evidence of the destructive path (lines may shift over time; `grep "force-enriching.*19778"` to locate)

## Dependencies

- **Blocked by:** none
- **Blocks:** Releasing the `status:in-review` claims on #19778/#19779/#19780 (they are currently held by maintainer to prevent re-wipe)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Re-read the 5 edit sites + reference test harness (~1200 lines total) |
| Layer 1 implementation | 5m | 10-line edit + call-site propagation |
| Layer 2 implementation | 10m | 3 guards at top of `_enrich_update_issue` |
| Layer 3 implementation | 10m | `_build_title` refactor + 2 call sites |
| Layer 4 implementation | 10m | Broader marker check |
| Layer 5 implementation | 15m | TODO.md presence check |
| New test harness | 45m | ~150 lines, 5 assertions, mocking |
| Verification | 20m | Run tests, shellcheck, eyeball PR |
| **Total** | **~2h** | |
