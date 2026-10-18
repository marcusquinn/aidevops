#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for task-id-normalize-helper.sh (GH#34969): HTML-commented
# format examples are never live tasks, and compound/range IDs normalize as a unit.

set -euo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${TEST_SCRIPTS_DIR}/task-id-normalize-helper.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
FAILURES=0

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message" >&2
	FAILURES=$((FAILURES + 1))
	return 0
}

new_repo() {
	local name="$1"
	local repo="${TEST_ROOT}/${name}"
	mkdir -p "${repo}/todo"
	git -C "$repo" init -q -b main
	printf '%s\n' "$repo"
	return 0
}

test_commented_examples_are_inactive() {
	local repo output
	repo=$(new_repo commented)
	cat >"${repo}/TODO.md" <<'EOF'
# TODO

<!-- GH#17804: Format examples wrapped in HTML comment to prevent parsers
     from extracting them as real tasks during upgrade-planning migrations.
- [ ] t001 Task description @owner #tag ~30m risk:low logged:2025-01-15
- [ ] t002 Dependent task blocked-by:t001 ~15m risk:med
- [ ] t001.1 Subtask of t001 ~10m
- [x] t003 Completed task ~30m actual:25m logged:2025-01-10 completed:2025-01-15
- [-] Declined task
-->
EOF
	output=$(bash "$HELPER" --repo "$repo" --advisory)
	[[ -z "$output" ]] || fail "advisory reported commented examples: ${output}"
	output=$(bash "$HELPER" --repo "$repo" --dry-run)
	if printf '%s\n' "$output" | grep -q '^TODO\.md: '; then
		fail "dry-run proposed rewrites inside an HTML comment: ${output}"
	fi
	return 0
}

test_compound_ranges_normalize_as_unit() {
	local repo output
	repo=$(new_repo ranges)
	printf '%s\n' '# Plans' \
		'(t038.24-t038.25, t038.27, t038.29-t038.30) t065/t066 t004.1-5' \
		'keep feature/t022-x and t005.1-diag-1' \
		'blocks t005.5. and t006.html' >"${repo}/todo/PLANS.md"
	output=$(bash "$HELPER" --repo "$repo" --dry-run)
	printf '%s\n' "$output" | grep -qF -- '-> (t38.24-t38.25, t38.27, t38.29-t38.30) t65/t66 t4.1-5' ||
		fail "compound ranges were not normalized together: ${output}"
	printf '%s\n' "$output" | grep -qF -- '-> blocks t5.5. and t006.html' ||
		fail "sentence-final ID or file-suffix exclusion handled incorrectly: ${output}"
	if printf '%s\n' "$output" | grep -qF 'feature/t022-x'; then
		fail "branch-like or suffixed tokens were rewritten: ${output}"
	fi
	return 0
}

test_range_member_conflict_refused() {
	local repo
	repo=$(new_repo conflict)
	printf '%s\n' '- [ ] t39 Existing task' '- [ ] t100 Covers t039-t040' >"${repo}/TODO.md"
	if bash "$HELPER" --repo "$repo" --dry-run >/dev/null 2>&1; then
		fail "range member t039 alongside t39 did not refuse"
	fi
	return 0
}

test_apply_preserves_comments_and_toon() {
	local repo
	repo=$(new_repo apply)
	cat >"${repo}/TODO.md" <<'EOF'
<!-- example block
- [ ] t007 Example only
-->
- [ ] t008 Live task blocked-by:t007 <!-- inline note t009 -->
<!--TOON:dependencies[1]{id,blocked_by}:
t008,t007
-->
- [ ] t010 After TOON
EOF
	bash "$HELPER" --repo "$repo" --apply >/dev/null
	grep -qxF -- '- [ ] t007 Example only' "${repo}/TODO.md" || fail "commented example was rewritten by --apply"
	grep -qxF -- '- [ ] t8 Live task blocked-by:t7 <!-- inline note t9 -->' "${repo}/TODO.md" ||
		fail "live task with inline single-line comment was not normalized"
	grep -qxF 't8,t7' "${repo}/TODO.md" || fail "TOON block reference was not normalized"
	grep -qxF -- '- [ ] t10 After TOON' "${repo}/TODO.md" || fail "task after TOON block was not normalized"
	return 0
}

test_commented_examples_are_inactive
test_compound_ranges_normalize_as_unit
test_range_member_conflict_refused
test_apply_preserves_comments_and_toon

if [[ "$FAILURES" -gt 0 ]]; then
	printf '%s task-id-normalize test(s) failed\n' "$FAILURES" >&2
	exit 1
fi
printf 'task-id-normalize tests passed\n'
exit 0
