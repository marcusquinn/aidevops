<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1986: systemic fix — parent-task dispatch guard

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human, interactive)
- **Parent incident:** GH#18356 (t1962 decomposition) — observed dispatch loop on parent task during Phase 3, burned ~20K opus tokens across 2 worker attempts before maintainer intervention. See the parent issue's final comment for the full root-cause analysis.
- **Conversation context:** During Phase 3 of the pulse-wrapper decomposition, the parent task (#18356) was dispatched twice by a secondary pulse runner (`alex-solovyev`) despite being a planning-only meta-task. The worker attempted to implement the entire 10-phase plan in one shot and burned opus-4-6 tokens. Manual label additions to block dispatch were auto-stripped by the label reconciler. This task closes the four independent holes that made the dispatch loop possible.

## What

Systemic fix for parent-task dispatch protection. Three code changes + documentation + test:

1. **Survive reconciliation** — add `parent-task` to the `_is_protected_label` allow-list so the label persists across issue-sync runs.
2. **Declarative via TODO tag** — add `#parent` → `parent-task` alias in `map_tags_to_labels` so parent tasks can be marked directly in `TODO.md`.
3. **Dispatch-time short-circuit** — make `is_assigned()` in `dispatch-dedup-helper.sh` treat the `parent-task` label as a hard block (return "blocked by parent-task" signal equivalent to an active claim), regardless of assignees.
4. **Test coverage** — new test asserting all three behaviours via stubbed `gh` calls.
5. **Docs** — document `#parent` tag usage in `AGENTS.md` (or `reference/planning-detail.md`) alongside other origin/status tags.

## Why

- **Observed cost:** two opus-4-6 dispatches to GH#18356 this session (~20K tokens wasted) with no possible productive output because the task is plan-only.
- **Observed frequency:** the dispatch loop will repeat every stale-recovery cycle (~30 min after claim expiry) until someone manually closes the issue or adds a protected-namespace label like `needs-maintainer-review`. In the current state, **every parent task is a token bomb**.
- **Scope of impact:** any repo with a `tier:reasoning` parent task and two or more pulse runners. The aidevops repo has parent tasks for roadmap epics — this pattern will recur.
- **Existing partial mitigation:** self-assigning the parent to a maintainer (GH#18352 guard) works but is easy to forget, and doesn't prevent the initial burn before someone notices.
- **Why protected-namespace labels don't help:** `needs-maintainer-review` blocks dispatch but has different semantics (implies the issue needs review before any work, including child task dispatch). `parent-task` is specifically "never dispatch this issue directly" without implying anything about children.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** — 3 code files + 1 new test + 1 doc = 5 files. **Failed.**
- [x] **Complete code blocks for every edit?** — yes, all verbatim below
- [x] **No judgment or design decisions?** — one small decision point on `is_assigned()` return signal (noted in §How)
- [x] **No error handling or fallback logic to design?** — none
- [ ] **Estimate 1h or less?** — estimated 1.5-2h with test coverage. **Failed.**
- [x] **4 or fewer acceptance criteria?** — 6 criteria. **Failed.**

Three checkboxes failed → `tier:standard`.

**Selected tier:** `tier:standard` (Sonnet)

**Rationale:** Three small code changes with one judgment call (exactly how `is_assigned()` signals parent-task — see §How). The test harness is ~150 lines with `gh` stubbing (not trivial). Worker must understand the label reconciliation flow and the active-claim signalling pattern.

## How (Approach)

### Files to modify

- **EDIT:** `.agents/scripts/issue-sync-helper.sh:122` — `_is_protected_label` exact-match list
- **EDIT:** `.agents/scripts/issue-sync-lib.sh:643` — `map_tags_to_labels` alias case statement
- **EDIT:** `.agents/scripts/dispatch-dedup-helper.sh:676` — `is_assigned` function (add parent-task short-circuit)
- **NEW:** `.agents/scripts/tests/test-parent-task-guard.sh` — ~150 lines, end-to-end test
- **EDIT:** `.agents/AGENTS.md` — document `#parent` tag (small addition to existing tag section)

### Step 1 — Protect `parent-task` in `_is_protected_label`

File: `.agents/scripts/issue-sync-helper.sh` lines 122-136

**Current:**

```bash
_is_protected_label() {
	local lbl="$1"
	# Prefix-protected namespaces
	case "$lbl" in
	status:* | origin:* | tier:* | source:*) return 0 ;;
	esac
	# Exact-match protected labels
	case "$lbl" in
	persistent | needs-maintainer-review | not-planned | duplicate | wontfix | \
		already-fixed | "good first issue" | "help wanted")
		return 0
		;;
	esac
	return 1
}
```

**Change to:**

```bash
_is_protected_label() {
	local lbl="$1"
	# Prefix-protected namespaces
	case "$lbl" in
	status:* | origin:* | tier:* | source:*) return 0 ;;
	esac
	# Exact-match protected labels
	case "$lbl" in
	persistent | needs-maintainer-review | not-planned | duplicate | wontfix | \
		already-fixed | "good first issue" | "help wanted" | \
		parent-task | meta)
		return 0
		;;
	esac
	return 1
}
```

**Note:** Include both `parent-task` and `meta` because they serve the same "do not dispatch" function and some projects may prefer one over the other. Both survive reconciliation once added to the allow-list.

### Step 2 — Add `#parent` alias in `map_tags_to_labels`

File: `.agents/scripts/issue-sync-lib.sh` lines 660-670

**Current:**

```bash
		# Alias common synonyms to canonical label names
		local label="$tag"
		case "$tag" in
		bugfix | bug) label="bug" ;;
		feat | feature) label="enhancement" ;;
		hardening) label="quality" ;;
		sync) label="git" ;;
		docs) label="documentation" ;;
		worker) label="origin:worker" ;;
		interactive) label="origin:interactive" ;;
		esac
```

**Change to:**

```bash
		# Alias common synonyms to canonical label names
		local label="$tag"
		case "$tag" in
		bugfix | bug) label="bug" ;;
		feat | feature) label="enhancement" ;;
		hardening) label="quality" ;;
		sync) label="git" ;;
		docs) label="documentation" ;;
		worker) label="origin:worker" ;;
		interactive) label="origin:interactive" ;;
		parent | parent-task | meta) label="parent-task" ;;
		esac
```

### Step 3 — Add parent-task short-circuit in `is_assigned`

File: `.agents/scripts/dispatch-dedup-helper.sh` — `is_assigned` function starts at line 676

**Context to search for** (unique enough to locate without line numbers, which will drift):

```bash
	# Query GitHub for current assignees
	local assignees
	assignees=$(printf '%s' "$issue_meta_json" | jq -r '[.assignees[].login] | join(",")' 2>/dev/null) || assignees=""

	if [[ -z "$assignees" ]]; then
		# No assignees — safe to dispatch
		return 1
	fi
```

**Insert immediately AFTER the `issue_meta_json` fetch and BEFORE the assignee query** (i.e., between the `if [[ -z "$issue_meta_json" ]]; then return 1; fi` block and the `# Query GitHub for current assignees` comment):

```bash
	# t1986: Parent-task label is an unconditional dispatch block.
	# Any issue tagged `parent-task` or `meta` is plan-only and must
	# never receive a dispatched worker, regardless of assignees or
	# status labels. This closes the dispatch loop observed on GH#18356
	# during t1962 Phase 3, where a parent task was dispatched twice
	# with opus-4-6 and burned ~20K tokens for no productive output.
	local is_parent_task
	is_parent_task=$(printf '%s' "$issue_meta_json" | \
		jq -e '[.labels[].name] | any(. == "parent-task" or . == "meta")' >/dev/null 2>&1 && echo "true" || echo "false")
	if [[ "$is_parent_task" == "true" ]]; then
		# Synthesize an assignee signal so callers treat this as blocked.
		# Using "parent-task" as the blocking login is harmless — it's never
		# a real GitHub user, and the caller logs it for audit.
		printf 'parent-task\n'
		return 0
	fi
```

**Decision point for the worker:** The chosen output is `printf 'parent-task\n'` to stdout (mirroring the existing pattern where `is_assigned` prints the blocking login on stdout before returning 0). If the caller treats the stdout value as a user login, this may log oddly — check call sites with `rg 'is_assigned' .agents/scripts/pulse-wrapper.sh` and adjust if needed. If a separate return path is cleaner (e.g., return a distinct exit code), that's acceptable too, but document the decision in the commit message.

### Step 4 — New test `test-parent-task-guard.sh`

Create `.agents/scripts/tests/test-parent-task-guard.sh`. Model on `test-pulse-wrapper-characterization.sh` for style:

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-parent-task-guard.sh — t1986 — assert that the parent-task label
# (a) survives issue-sync reconciliation, (b) is produced by #parent TODO
# tag, and (c) blocks dispatch via is_assigned().

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly RESET='\033[0m'
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$GREEN" "$RESET" "$name"
	else
		printf '%bFAIL%b %s %s\n' "$RED" "$RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
}

# Sandbox HOME so sourcing is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# ---------------------------------------------------------------
# Test 1: _is_protected_label recognises parent-task
# ---------------------------------------------------------------
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/issue-sync-helper.sh" 2>/dev/null || true
# Re-source to pick up functions even if guarded
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/issue-sync-helper.sh"

if _is_protected_label "parent-task"; then
	print_result "_is_protected_label accepts parent-task" 0
else
	print_result "_is_protected_label accepts parent-task" 1 "(should return 0 for parent-task)"
fi

if _is_protected_label "meta"; then
	print_result "_is_protected_label accepts meta" 0
else
	print_result "_is_protected_label accepts meta" 1
fi

if ! _is_protected_label "not-a-real-label"; then
	print_result "_is_protected_label rejects unrelated labels" 0
else
	print_result "_is_protected_label rejects unrelated labels" 1
fi

# ---------------------------------------------------------------
# Test 2: map_tags_to_labels converts #parent → parent-task
# ---------------------------------------------------------------
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/issue-sync-lib.sh"

result=$(map_tags_to_labels "parent")
if [[ "$result" == "parent-task" ]]; then
	print_result "map_tags_to_labels: parent → parent-task" 0
else
	print_result "map_tags_to_labels: parent → parent-task" 1 "got: $result"
fi

result=$(map_tags_to_labels "parent,simplification,pulse")
if [[ "$result" == *"parent-task"* ]]; then
	print_result "map_tags_to_labels: multi-tag with parent" 0
else
	print_result "map_tags_to_labels: multi-tag with parent" 1 "got: $result"
fi

result=$(map_tags_to_labels "parent-task")
if [[ "$result" == "parent-task" ]]; then
	print_result "map_tags_to_labels: parent-task idempotent" 0
else
	print_result "map_tags_to_labels: parent-task idempotent" 1 "got: $result"
fi

# ---------------------------------------------------------------
# Test 3: is_assigned short-circuits on parent-task label
# ---------------------------------------------------------------
# Stub gh to return a fake issue with parent-task label
STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"
cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh for test-parent-task-guard.sh
# Only handles: gh issue view N --repo R --json state,assignees,labels
if [[ "$1" == "issue" && "$2" == "view" ]]; then
	cat <<'JSON'
{"state":"OPEN","assignees":[],"labels":[{"name":"parent-task"},{"name":"pulse"},{"name":"tier:reasoning"}]}
JSON
	exit 0
fi
exit 1
STUB
chmod +x "${STUB_DIR}/gh"
OLD_PATH="$PATH"
export PATH="${STUB_DIR}:${PATH}"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dispatch-dedup-helper.sh"

# Call is_assigned with a fake issue number — should detect parent-task
output=$(is_assigned 99999 "owner/repo" 2>&1 || true)
rc=$?
if [[ "$rc" -eq 0 && "$output" == *"parent-task"* ]]; then
	print_result "is_assigned blocks parent-task labeled issue" 0
else
	print_result "is_assigned blocks parent-task labeled issue" 1 \
		"(expected rc=0 + 'parent-task' in output; got rc=$rc, output='$output')"
fi

# Stub with no parent-task label — should NOT short-circuit
cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "issue" && "$2" == "view" ]]; then
	cat <<'JSON'
{"state":"OPEN","assignees":[],"labels":[{"name":"pulse"},{"name":"tier:standard"}]}
JSON
	exit 0
fi
exit 1
STUB
chmod +x "${STUB_DIR}/gh"

output=$(is_assigned 99998 "owner/repo" 2>&1 || true)
rc=$?
if [[ "$rc" -eq 1 ]]; then
	print_result "is_assigned allows non-parent issues with no assignees" 0
else
	print_result "is_assigned allows non-parent issues with no assignees" 1 \
		"(expected rc=1; got rc=$rc, output='$output')"
fi

export PATH="$OLD_PATH"

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%bAll %d tests passed%b\n' "$GREEN" "$TESTS_RUN" "$RESET"
	exit 0
else
	printf '%b%d / %d tests failed%b\n' "$RED" "$TESTS_FAILED" "$TESTS_RUN" "$RESET"
	exit 1
fi
```

### Step 5 — Update AGENTS.md

File: `.agents/AGENTS.md` — add a one-liner to the "Session origin labels" section or a new "Meta-task labels" subsection.

Search for the existing `#worker` / `#interactive` tag documentation (e.g. `grep -n "#worker\|#interactive" .agents/AGENTS.md`). Add alongside:

```markdown
- `#parent` (or `#parent-task`, `#meta`) — declares a task as a parent/meta/planning-only issue. The pulse will never dispatch a worker to an issue with the `parent-task` label, regardless of assignee or tier. Use this on parent tasks whose children are tracked separately (decomposition epics, roadmap trackers, research summaries with child implementation tasks).
```

## Verification

```bash
# 1. Syntax
bash -n .agents/scripts/issue-sync-helper.sh
bash -n .agents/scripts/issue-sync-lib.sh
bash -n .agents/scripts/dispatch-dedup-helper.sh
bash -n .agents/scripts/tests/test-parent-task-guard.sh

# 2. ShellCheck clean
shellcheck .agents/scripts/issue-sync-helper.sh \
           .agents/scripts/issue-sync-lib.sh \
           .agents/scripts/dispatch-dedup-helper.sh \
           .agents/scripts/tests/test-parent-task-guard.sh

# 3. New test passes
bash .agents/scripts/tests/test-parent-task-guard.sh

# 4. Existing pulse tests still pass (regression guard)
for t in .agents/scripts/tests/test-pulse-wrapper-characterization.sh \
         .agents/scripts/tests/test-pulse-wrapper-terminal-blockers.sh \
         .agents/scripts/tests/test-pulse-wrapper-main-commit-check.sh; do
  bash "$t"
done

# 5. --self-check still clean (no impact expected)
.agents/scripts/pulse-wrapper.sh --self-check

# 6. Manual end-to-end smoke test on a throwaway issue:
#    a. Create a test issue with --label pulse,tier:reasoning
#    b. Add --label parent-task
#    c. Trigger issue-sync reconciliation — label must survive
#    d. Check that pulse dispatch logic (via dry-run or inspect) skips it
```

## Acceptance Criteria

- [ ] `_is_protected_label "parent-task"` returns 0 (protected)

  ```yaml
  verify:
    method: bash
    run: "source .agents/scripts/issue-sync-helper.sh && _is_protected_label parent-task && echo OK"
  ```

- [ ] `map_tags_to_labels "parent"` returns `parent-task`

  ```yaml
  verify:
    method: bash
    run: "source .agents/scripts/issue-sync-lib.sh && [[ \"$(map_tags_to_labels parent)\" == \"parent-task\" ]]"
  ```

- [ ] `is_assigned` blocks dispatch on any issue with `parent-task` label even when unassigned

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-parent-task-guard.sh"
  ```

- [ ] New test-parent-task-guard.sh passes all assertions

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-parent-task-guard.sh"
  ```

- [ ] No regressions in existing pulse tests

  ```yaml
  verify:
    method: bash
    run: "for t in .agents/scripts/tests/test-pulse-wrapper-*.sh; do bash \"$t\" || exit 1; done"
  ```

- [ ] `shellcheck` clean on all four modified shell files

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/issue-sync-helper.sh .agents/scripts/issue-sync-lib.sh .agents/scripts/dispatch-dedup-helper.sh .agents/scripts/tests/test-parent-task-guard.sh"
  ```

## Context & Decisions

- **Why not use `needs-maintainer-review` instead?** It's protected, but carries different semantics (implies a review blocker on the issue's own content). Parent tasks are legitimate plan-only issues, not review-gated work. Using the wrong label pollutes audit searches.
- **Why both `parent-task` and `meta`?** Different projects use different conventions. Both should work. The cost of supporting both is one extra alias line.
- **Why is the short-circuit placed before the assignee query rather than after?** To fail fast — we don't need `_get_repo_owner` + `_get_repo_maintainer` calls when we can reject based on labels alone. Saves a small amount of API work per dispatch cycle.
- **Why `printf 'parent-task\n'` as the "blocking login"?** It fits the existing `is_assigned` output contract (print blocking login, return 0). A human-readable value keeps logs debuggable. Alternative: return a distinct exit code (2) for parent-task blocks — worker may pick whichever is cleaner after reading call sites.
- **Why not automate parent-task label application from title heuristics (`(parent)` in title)?** Deliberately out of scope. Declarative (`#parent` tag or manual label) is safer than magic. A future follow-up can add title heuristics if needed.
- **Why leave the stale-recovery loop un-fixed?** Once parent-task blocks dispatch unconditionally, stale recovery becomes a no-op for parent tasks (there's no worker to recover). The loop is only a problem if dispatch succeeds, which this fix prevents.

## Relevant Files

- `.agents/scripts/issue-sync-helper.sh:117-136` — `_is_protected_label` function
- `.agents/scripts/issue-sync-lib.sh:638-679` — `map_tags_to_labels` function
- `.agents/scripts/dispatch-dedup-helper.sh:676-748` — `is_assigned` function (add short-circuit between issue_meta fetch and assignee check)
- `.agents/scripts/tests/test-pulse-wrapper-characterization.sh` — style reference for new test
- `.agents/AGENTS.md` — tag documentation section
- `todo/plans/t1986-parent-task-guard.md` — optional full plan if worker wants extended context

## Dependencies

- **Blocked by:** none (all referenced code is in main as of commit afdc74130 or later)
- **Blocks:** future parent tasks in any repo managed by this framework
- **Related:** #18356 (parent incident, closed), #18396 (t1970 claim-task fix, merged)

## Estimate

| Step | Time |
|---|---|
| 1. `_is_protected_label` + `map_tags_to_labels` edits | 10m |
| 2. `is_assigned` short-circuit + call site audit | 25m |
| 3. Test harness (~150 lines, gh stubbing) | 45m |
| 4. AGENTS.md documentation | 10m |
| 5. Verification + shellcheck + regression suite | 20m |
| **Total** | **~1h 50m** |
