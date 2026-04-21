#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-upgrade-planning-sections.sh — Regression test for t2434 (GH#20077)
#
# Verifies that _upgrade_todo preserves tasks from ALL 6 template sections
# (Ready, Backlog, In Progress, In Review, Done, Declined), not just Backlog.
#
# Bug being regression-tested: prior to t2434, _upgrade_todo extracted tasks
# only from "## Backlog" and silently dropped the other 5 sections into
# TODO.md.bak. On webapp (2026-04-20) this ate 141 completed "[x]" rows —
# audit-trail data NOT reconstructable from GitHub.
#
# Pattern modelled on tests/test-init-scope.sh:
#   - Extract the target functions from aidevops.sh via sed
#   - eval them into the test shell
#   - Stub print_info / print_success / sed_inplace
#   - Build synthetic fixtures in a temp dir
#   - Drive the upgrade and assert survivors

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
AIDEVOPS_SH="$SCRIPT_DIR/../../../aidevops.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1" passed="$2" message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	[[ -n "$message" ]] && printf '       %s\n' "$message"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

cleanup() {
	[[ -n "${TEST_ROOT:-}" && -d "${TEST_ROOT}" ]] && rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

if [[ ! -f "$AIDEVOPS_SH" ]]; then
	echo "ERROR: Cannot find aidevops.sh at $AIDEVOPS_SH" >&2
	exit 1
fi

# Stub the aidevops.sh globals the target functions depend on. The test runs
# purely against the extracted function bodies — no CLI side effects.
print_info() { return 0; }
print_success() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }
sed_inplace() { if [[ "$(uname)" == "Darwin" ]]; then sed -i '' "$@"; else sed -i "$@"; fi; }

# Extract target function bodies from aidevops.sh and eval them into this shell.
_extract_function() {
	local name="$1"
	sed -n "/^${name}() {/,/^}/p" "$AIDEVOPS_SH"
	return 0
}

for fn in _extract_todo_section _filter_todo_placeholders _insert_after_toon_marker \
	_upgrade_todo_preserve_sections _upgrade_todo_reinsert_sections _upgrade_todo; do
	body=$(_extract_function "$fn")
	if [[ -z "$body" ]]; then
		echo "ERROR: could not extract $fn from aidevops.sh" >&2
		exit 1
	fi
	eval "$body"
done

# ---- Fixtures ----

# Old-format TODO.md with tasks in ALL 6 sections. Includes Format-block
# placeholders (tXXX/tYYY/tZZZ) that must be filtered out.
write_old_todo() {
	local path="$1"
	cat >"$path" <<'EOF'
# TODO

Header text.

## Format

<!-- Placeholders that must be filtered out during upgrade -->
- [ ] tXXX Placeholder task @user #tag ~30m logged:2026-01-01
- [ ] tYYY Another placeholder ~15m
- [x] tZZZ Fake completed placeholder

```
- [ ] tAAA Code-block content also filtered
```

<!--TOON:meta{version,format,updated}:
1.0,todo-md+toon,2026-01-01
-->

## Ready

- [ ] t100 Ready task one @alice #ready ~1h logged:2026-04-01
- [ ] t101 Ready task two @bob #ready ~30m logged:2026-04-02

## Backlog

- [ ] t200 Backlog task one @alice #feat ~2h logged:2026-04-03
- [ ] t201 Backlog task two @bob #bug ~45m logged:2026-04-04
- [ ] t202 Backlog task three @alice ~1h logged:2026-04-05

## In Progress

- [ ] t300 Work in progress @alice ~4h started:2026-04-10T09:00:00Z

## In Review

- [ ] t400 PR open @bob ~3h pr:#9001 started:2026-04-11

## Done

- [x] t500 Done task one @alice ~2h actual:1h45m completed:2026-04-12
- [x] t501 Done task two @bob ~30m actual:25m completed:2026-04-13
- [x] t502 Done task three @alice ~1h completed:2026-04-14

## Declined

- [-] t600 Declined as scope creep @alice reason:scope

EOF
	return 0
}

# Minimal new-format template with all 6 TOON section markers plus the front
# matter separators aidevops.sh expects (two --- lines).
write_new_template() {
	local path="$1"
	cat >"$path" <<'EOF'
---
mode: subagent
---

# TODO

Template intro.

## Format

<!-- Format-block placeholders. Upgrade must NOT promote these into real sections. -->
- [ ] tXXX Template placeholder ~30m
- [ ] tYYY Another placeholder

<!--TOON:meta{version,format,updated}:
1.1,todo-md+toon,{{DATE}}
-->

## Ready

<!--TOON:ready[0]{id,desc,owner,tags,est,risk,logged,status}:
-->

## Backlog

<!--TOON:backlog[0]{id,desc,owner,tags,est,risk,logged,status}:
-->

## In Progress

<!--TOON:in_progress[0]{id,desc,owner,tags,est,risk,logged,started,status}:
-->

## In Review

<!--TOON:in_review[0]{id,desc,owner,tags,est,pr_url,started,pr_created,status}:
-->

## Done

<!--TOON:done[0]{id,desc,owner,tags,est,actual,logged,started,completed,status}:
-->

## Declined

<!--TOON:declined[0]{id,desc,reason,logged,status}:
-->
EOF
	return 0
}

# ---- Assertion helpers ----

count_tasks() {
	local file="$1"
	[[ -f "$file" ]] || { echo 0; return 0; }
	local n
	# grep -c prints "0" on no-matches AND exits 1; swallow the exit with || true
	# so we don't end up with both grep's "0" and a fallback "0" on stdout.
	n=$(grep -cE '^- \[[ x-]\] t[0-9]' "$file" 2>/dev/null || true)
	echo "${n:-0}"
}

# Confirm the task line with the given ID appears inside the given section.
# "Inside" means: after the `## <section>` header and before the next `## `.
task_in_section() {
	local file="$1" section="$2" task_id="$3"
	if awk -v target="## $section" -v tid="$task_id" '
		$0 == target { found=1; next }
		found && /^## / { found=0 }
		found && $0 ~ ("^- \\[[ x-]\\] " tid "( |$)") { print "HIT"; exit }
	' "$file" | grep -q HIT; then
		return 0
	fi
	return 1
}

# ---- Tests ----

test_extract_todo_section() {
	echo ""
	echo "=== Testing _extract_todo_section ==="
	local src="$TEST_ROOT/fixture.md"
	write_old_todo "$src"

	local out
	out=$(_extract_todo_section "$src" "Backlog")
	echo "$out" | grep -q "t200 Backlog task one" \
		&& print_result "Backlog extraction includes t200" 0 \
		|| print_result "Backlog extraction includes t200" 1 "$(printf '%s' "$out" | head -3)"

	# Must not leak tasks from adjacent sections
	if echo "$out" | grep -q "t300 "; then
		print_result "Backlog extraction stops before In Progress" 1 "t300 leaked in"
	else
		print_result "Backlog extraction stops before In Progress" 0
	fi

	# Format block must be skipped entirely
	out=$(_extract_todo_section "$src" "Ready")
	if echo "$out" | grep -qE "^- \[[ x-]\] tXXX"; then
		print_result "Format placeholders filtered at extraction" 1 "tXXX leaked"
	else
		print_result "Format placeholders filtered at extraction" 0
	fi
	return 0
}

test_filter_placeholders() {
	echo ""
	echo "=== Testing _filter_todo_placeholders ==="
	local out
	out=$(printf '%s\n' \
		"- [ ] tXXX placeholder" \
		"- [ ] tYYY placeholder" \
		"- [ ] t123 real task" \
		"- [x] t456.1 subtask done" \
		"not a task line" \
		| _filter_todo_placeholders)
	echo "$out" | grep -q "t123" && print_result "Real t123 kept" 0 || print_result "Real t123 kept" 1
	echo "$out" | grep -q "t456.1" && print_result "Subtask t456.1 kept" 0 || print_result "Subtask t456.1 kept" 1
	echo "$out" | grep -q "tXXX" && print_result "tXXX filtered" 1 "tXXX leaked" || print_result "tXXX filtered" 0
	echo "$out" | grep -q "tYYY" && print_result "tYYY filtered" 1 "tYYY leaked" || print_result "tYYY filtered" 0
	echo "$out" | grep -q "not a task line" && print_result "Non-task line kept" 0 || print_result "Non-task line kept" 1
	return 0
}

test_upgrade_preserves_all_sections() {
	echo ""
	echo "=== Testing _upgrade_todo preserves all 6 sections ==="
	local todo="$TEST_ROOT/TODO.md" template="$TEST_ROOT/template.md"
	write_old_todo "$todo"
	write_new_template "$template"

	local before_count after_count
	before_count=$(count_tasks "$todo")

	_upgrade_todo "$todo" "$template" "true"

	after_count=$(count_tasks "$todo")

	# Before had 4 Format-block placeholders + 11 real tasks = 15 task-like lines.
	# The 4 Format placeholders MUST NOT appear in the upgraded file.
	# Real tasks = 2 Ready + 3 Backlog + 1 In Progress + 1 In Review + 3 Done + 1 Declined = 11.
	if [[ "$after_count" -eq 11 ]]; then
		print_result "All 11 real tasks survived upgrade (${before_count} -> ${after_count})" 0
	else
		print_result "Task count preserved" 1 "expected 11, got ${after_count}"
	fi

	# Every real task must land in its original section
	task_in_section "$todo" "Ready" "t100" \
		&& print_result "t100 in Ready" 0 || print_result "t100 in Ready" 1
	task_in_section "$todo" "Ready" "t101" \
		&& print_result "t101 in Ready" 0 || print_result "t101 in Ready" 1
	task_in_section "$todo" "Backlog" "t200" \
		&& print_result "t200 in Backlog" 0 || print_result "t200 in Backlog" 1
	task_in_section "$todo" "Backlog" "t201" \
		&& print_result "t201 in Backlog" 0 || print_result "t201 in Backlog" 1
	task_in_section "$todo" "Backlog" "t202" \
		&& print_result "t202 in Backlog" 0 || print_result "t202 in Backlog" 1
	task_in_section "$todo" "In Progress" "t300" \
		&& print_result "t300 in In Progress" 0 || print_result "t300 in In Progress" 1
	task_in_section "$todo" "In Review" "t400" \
		&& print_result "t400 in In Review" 0 || print_result "t400 in In Review" 1
	task_in_section "$todo" "Done" "t500" \
		&& print_result "t500 in Done" 0 || print_result "t500 in Done" 1
	task_in_section "$todo" "Done" "t501" \
		&& print_result "t501 in Done" 0 || print_result "t501 in Done" 1
	task_in_section "$todo" "Done" "t502" \
		&& print_result "t502 in Done" 0 || print_result "t502 in Done" 1
	task_in_section "$todo" "Declined" "t600" \
		&& print_result "t600 in Declined" 0 || print_result "t600 in Declined" 1

	# Regression assertion: 141-row Done drop must not recur
	local done_count
	done_count=$(awk '
		$0 == "## Done" { found=1; next }
		found && /^## / { exit }
		found && /^- \[[ x-]\] t[0-9]/ { n++ }
		END { print n+0 }
	' "$todo")
	if [[ "$done_count" -eq 3 ]]; then
		print_result "Done section retains all 3 completed tasks (t2434 regression)" 0
	else
		print_result "Done section retains all 3 completed tasks (t2434 regression)" 1 \
			"expected 3, got $done_count"
	fi

	# Placeholders must not promote into real sections. Note: the NEW template's
	# own ## Format block legitimately contains tXXX/tYYY examples — so a naive
	# grep of the whole file would false-positive. Scope the check to sections
	# after ## Format.
	local leaked
	leaked=$(awk '
		/^## Format/ { in_format=1; next }
		in_format && /^## / { in_format=0 }
		!in_format && /^- \[[ x-]\] t(XXX|YYY|ZZZ)( |$)/ { print }
	' "$todo")
	if [[ -z "$leaked" ]]; then
		print_result "Format placeholders not promoted to sections" 0
	else
		print_result "Format placeholders not promoted to sections" 1 "leaked: ${leaked}"
	fi

	# Backup created
	[[ -f "${todo}.bak" ]] \
		&& print_result "Backup TODO.md.bak created" 0 \
		|| print_result "Backup TODO.md.bak created" 1
	return 0
}

test_upgrade_empty_todo() {
	echo ""
	echo "=== Testing _upgrade_todo on empty TODO.md ==="
	local todo="$TEST_ROOT/empty.md" template="$TEST_ROOT/template.md"
	write_new_template "$template"
	cat >"$todo" <<'EOF'
# TODO

## Backlog

## Done

EOF
	_upgrade_todo "$todo" "$template" "false"
	local n
	n=$(count_tasks "$todo")
	if [[ "$n" -eq 0 ]]; then
		print_result "Empty TODO upgrades to empty TODO" 0
	else
		print_result "Empty TODO upgrades to empty TODO" 1 "unexpected $n tasks after upgrade"
	fi
	# Must still have TOON markers
	grep -q "<!--TOON:backlog" "$todo" \
		&& print_result "New template markers present on empty upgrade" 0 \
		|| print_result "New template markers present on empty upgrade" 1
	return 0
}

# ---- Run all tests ----

echo "test-upgrade-planning-sections.sh — _upgrade_todo multi-section preservation (t2434)"
echo "===================================================================================="

TEST_ROOT=$(mktemp -d)

test_extract_todo_section
test_filter_placeholders
test_upgrade_preserves_all_sections
test_upgrade_empty_todo

echo ""
echo "===================================================================================="
echo "Results: $TESTS_RUN tests, $TESTS_FAILED failures"

[[ $TESTS_FAILED -gt 0 ]] && exit 1
exit 0
