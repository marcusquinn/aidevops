# t2210: fix(pre-commit): restrict duplicate task-id detection to defining lines only

ref: GH#19697
origin: interactive (opencode, maintainer session)
discovered-during: t2204 (GH#19696)

## What

`validate_duplicate_task_ids` in `.agents/scripts/pre-commit-hook.sh:21-50` falsely rejects commits with hundreds of "duplicate task IDs" errors, flagging any `tNNN` whose text appears more than once anywhere in `TODO.md` — even when only one of those occurrences is a defining task line. Task IDs referenced in other tasks' descriptions (e.g. `blocked-by:t001`, "due to t311.3 modularisation rename bug") all trigger the false positive.

Replace the current whole-file `grep -oE '\bt[0-9]+(\.[0-9]+)*\b'` extraction with the t319.5-era pattern that restricts extraction to task-defining lines only.

## Why

- **Real impact:** The t2204 session was blocked at commit time with 500+ false-positive duplicate errors for IDs it neither added nor modified. `--no-verify` was the only viable path. Same blocking applies to any contributor whose change lands in a TODO.md with cross-task references — which is every TODO.md in the project.
- **Silent regression:** A correct implementation existed in the t319.5 session (observed in `~/.aidevops/.agent-workspace/supervisor/logs/t319.5-20260212141318.log` and the t319.6 follow-up); the deployed hook now has the broken form. Somewhere between t319.6 and now the restriction to defining lines was reverted.
- **Trust erosion:** A hook that cries wolf trains operators to reach for `--no-verify` reflexively. The hook loses all value and subsequent legitimate rejections are ignored.

## Evidence

Run in `~/Git/aidevops`:

```bash
# Defining line count for t311.3:
grep -cE '^[[:space:]]*- \[[x ]\] t311\.3 ' TODO.md
# → 1

# All occurrences:
grep -nE 't311\.3' TODO.md | wc -l
# → 4  (defining line + 3 references in other task descriptions)

# The hook flags all four:
bash .agents/scripts/pre-commit-hook.sh  # (with any staged TODO.md change)
# → [ERROR] Duplicate task IDs found in TODO.md:
#   - t311.3     ← false positive
```

The hook reports ~500 "duplicates", none of which are actual duplicate task definitions.

## Tier

### Tier checklist

- [x] 2 or fewer files to modify — `pre-commit-hook.sh` and a new regression test.
- [x] Every target file under 500 lines — `pre-commit-hook.sh` is 636 lines (over 500 but the change is scoped to one 30-line function with exact block given).
- [x] Exact change blocks provided — yes (see How).
- [x] No judgment / design decisions — the fix is a mechanical port of the t319.5 pattern.
- [x] No error handling to design — pattern is defensive (`|| true` preserved).
- [x] No cross-package changes — scoped to `.agents/scripts/`.
- [x] Estimate under 1h — implementation < 20 min, regression test + brief included.
- [x] 4 or fewer acceptance criteria — 4 (see below).

**Selected tier:** `tier:simple`

## How

### File 1 (EDIT): `.agents/scripts/pre-commit-hook.sh:21-50`

Replace the body of `validate_duplicate_task_ids` so that it extracts IDs only from task-defining lines (lines starting with `- [ ]` or `- [x]` followed by a t-ID).

oldString (exact, inside the function):

```bash
	local staged_todo
	staged_todo=$(git show :TODO.md 2>/dev/null || true)
	if [[ -z "$staged_todo" ]]; then
		return 0
	fi

	# Extract all task IDs (including subtasks like t123.1)
	local task_ids
	task_ids=$(echo "$staged_todo" | grep -oE '\bt[0-9]+(\.[0-9]+)*\b' | sort)
```

newString:

```bash
	local staged_todo
	staged_todo=$(git show :TODO.md 2>/dev/null || true)
	if [[ -z "$staged_todo" ]]; then
		return 0
	fi

	# Extract task IDs from task-defining lines only (- [ ] or - [x] or - [-] prefix).
	# Excludes in-description references (blocked-by:tNNN, "due to tNNN …", etc.)
	# which would otherwise appear as false-positive duplicates.
	# Original pattern restored from the t319.5-era implementation.
	local task_ids
	task_ids=$(printf '%s\n' "$staged_todo" |
		grep -E '^[[:space:]]*- \[[x -]\] t[0-9]+' |
		sed -E 's/^[[:space:]]*- \[[x -]\] (t[0-9]+(\.[0-9]+)*).*/\1/' |
		sort)
```

### File 2 (NEW): `.agents/scripts/tests/test-pre-commit-dup-task-id.sh`

Regression test with two cases: a TODO.md containing only cross-references (must pass) and a TODO.md containing a duplicate defining line (must fail). Model on existing tests at `.agents/scripts/tests/test-*.sh`.

## Reference pattern

The correct pattern originated in t319.5. Recovered from the session log at `~/.aidevops/.agent-workspace/supervisor/logs/t319.5-20260212141318.log` (search for `grep -E '^[[:space:]]*- \[[x ]\]`).

## Acceptance criteria

1. `validate_duplicate_task_ids` extracts IDs only from lines matching `^[[:space:]]*- \[[x -]\] t[0-9]+`.
2. Running `bash .agents/scripts/pre-commit-hook.sh` against a staged `TODO.md` that contains cross-task references (current HEAD state) passes with no errors.
3. Running the hook against a `TODO.md` that introduces a duplicate defining line (e.g. two lines each starting with `- [ ] t001 …`) still fails with exit 1.
4. New regression test at `.agents/scripts/tests/test-pre-commit-dup-task-id.sh` covers both cases and passes when run in isolation.

## Verification

```bash
# Case 1 (should pass after fix):
git commit --allow-empty -m "t2210: test hook on current TODO.md"   # no violations

# Case 2 (should still fail):
echo '- [ ] t001 Fake duplicate definition' >> TODO.md
git add TODO.md
git commit -m "trigger dup check"
# → exit 1, reports t001 as duplicate

# Regression test:
bash .agents/scripts/tests/test-pre-commit-dup-task-id.sh
```

## Out of scope

- Not fixing any other pre-existing false positives in the hook.
- Not adding new classes of TODO.md validation — this is a scoped restoration.
- Not modifying the `commit-msg` task-id-collision-guard (separate hook, separate scope).

## Context

Discovered while committing t2204's docs-only diff — the hook rejected the commit with hundreds of pre-existing "duplicates" none of which were new. `--no-verify` was used as a legitimate bypass for the t2204 commit; this task restores the hook to its working form for everyone.
