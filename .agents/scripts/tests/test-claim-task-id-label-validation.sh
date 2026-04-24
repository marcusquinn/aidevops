#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-task-id-label-validation.sh — t2800 regression guard.
#
# Validates pre-flight label validation added to claim-task-id.sh:
#   A. Invalid label → exit 3, counter NOT advanced (primary acceptance criterion)
#   B. Valid label → exit 0, counter advances by 1
#   C. gh label list API fails → fail-open, counter advances
#   D. --skip-label-validation bypasses check, invalid label → counter advances
#   E. _validate_labels_exist unit — invalid label returns 1 (core logic)
#   F. _validate_labels_exist unit — valid labels returns 0 (core logic)
#
# Integration test strategy (A-D):
#   - fake "gh" binary in tmpdir prepended to PATH
#   - git bare-repo with a path containing "github.com" so detect_platform()
#     correctly classifies it (regex match, no actual network required)
#   - commit.gpgsign=false in test repo config so CAS commits succeed
#     in isolated test environments without SSH/GPG key access
#
# Unit test strategy (E-F):
#   - source claim-task-id.sh and call _validate_labels_exist directly

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CLAIM_SCRIPT="${SCRIPT_DIR}/../claim-task-id.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

# ---------------------------------------------------------------------------
# Test framework helpers
# ---------------------------------------------------------------------------

pass() {
	local name="${1:-}"
	printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="${1:-}"
	local detail="${2:-}"
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$name"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  - ${name}: ${detail}"
	return 0
}

# Source claim-task-id.sh to gain access to _validate_labels_exist.
# The BASH_SOURCE guard prevents main() from running on source.
_source_claim_script() {
	# shellcheck disable=SC1090
	if ! source "$CLAIM_SCRIPT" 2>/dev/null; then
		printf '%s[FATAL]%s Failed to source %s\n' "$RED" "$NC" "$CLAIM_SCRIPT" >&2
		exit 1
	fi
	return 0
}

# Create a fake "gh" binary in $1/gh:
#   - "gh auth status"    → exit 0 (authenticated)
#   - "gh label list ..." → prints fixture $GH_LABEL_MOCK_FIXTURE, exit 0
#   - "gh pr list ..."    → prints [] (no similar PRs), exit 0
#   - "gh issue create"  → prints mock URL, exit 0
#   - anything else      → exit 0
_make_gh_mock() {
	local bindir="$1"
	local label_fixture="$2"
	local gh_bin="${bindir}/gh"

	cat >"$gh_bin" <<'MOCK_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
	exit 0
fi
if [[ "${1:-}" == "label" && "${2:-}" == "list" ]]; then
	cat "${GH_LABEL_MOCK_FIXTURE}"
	exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
	printf '[]'
	exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "create" ]]; then
	printf 'https://github.com/marcusquinn/aidevops/issues/99999\n'
	exit 0
fi
exit 0
MOCK_EOF
	chmod +x "$gh_bin"
	export GH_LABEL_MOCK_FIXTURE="$label_fixture"
	return 0
}

# Create a fake "gh" that returns 1 for "gh label list" (simulates API failure)
_make_gh_mock_label_api_fail() {
	local bindir="$1"
	local gh_bin="${bindir}/gh"

	cat >"$gh_bin" <<'MOCK_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
	exit 0
fi
if [[ "${1:-}" == "label" && "${2:-}" == "list" ]]; then
	exit 1
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
	printf '[]'
	exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "create" ]]; then
	printf 'https://github.com/marcusquinn/aidevops/issues/99999\n'
	exit 0
fi
exit 0
MOCK_EOF
	chmod +x "$gh_bin"
	return 0
}

# Create a minimal git repo for CAS integration tests.
# The upstream bare-repo path contains "github.com" so detect_platform()
# classifies it as "github" via regex match (no actual network needed).
# GPG/SSH commit signing is disabled so test commits succeed in CI without keys.
# Args: $1 tmpdir, $2 start_count (default 500)
# Outputs the working repo path on stdout.
_make_test_repo() {
	local tmpdir="$1"
	local start_count="${2:-500}"

	# Embed "github.com" in the bare-repo path for platform detection
	local upstream="${tmpdir}/github.com/marcusquinn/aidevops.git"
	local repo="${tmpdir}/repo"

	mkdir -p "$upstream"
	# --initial-branch=main requires git 2.28+; fall back to bare init for older git
	git init --bare "$upstream" -q --initial-branch=main 2>/dev/null \
		|| git init --bare "$upstream" -q 2>/dev/null
	git init "$repo" -q 2>/dev/null
	git -C "$repo" config user.email "test@test.test" 2>/dev/null
	git -C "$repo" config user.name "Test" 2>/dev/null
	# Disable signing so CAS commits work without SSH/GPG key access
	git -C "$repo" config commit.gpgsign false 2>/dev/null
	git -C "$repo" config tag.gpgsign false 2>/dev/null
	git -C "$repo" remote add origin "$upstream" 2>/dev/null

	printf '%s\n' "$start_count" >"${repo}/.task-counter"
	git -C "$repo" add .task-counter 2>/dev/null
	git -C "$repo" -c commit.gpgsign=false commit -m "init" -q 2>/dev/null
	git -C "$repo" push origin HEAD:main -q 2>/dev/null

	printf '%s' "$repo"
	return 0
}

# Read the counter value from the upstream bare repo (source of truth for CAS)
_read_upstream_counter() {
	local tmpdir="$1"
	local upstream="${tmpdir}/github.com/marcusquinn/aidevops.git"
	local val=""
	val=$(git --git-dir="$upstream" show main:.task-counter 2>/dev/null \
		| tr -d '[:space:]') || val=""
	printf '%s' "$val"
	return 0
}

# Fixture: label names that ARE valid in the repo
_fixture_valid_labels() {
	printf 'bug\nquality-debt\ntier:standard\norigin:interactive\nauto-dispatch\nstatus:available\n'
	return 0
}

# ---------------------------------------------------------------------------
# Source once for unit tests (E and F)
# ---------------------------------------------------------------------------

_source_claim_script

# ---------------------------------------------------------------------------
# Case A: invalid label → exit 3, counter NOT advanced
# ---------------------------------------------------------------------------

test_case_a_invalid_label_exit3() {
	local name="A: invalid label → exit 3, counter NOT advanced"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local fixture="${tmpdir}/labels.txt"
	_fixture_valid_labels >"$fixture"
	_make_gh_mock "$tmpdir" "$fixture"

	local repo
	repo=$(_make_test_repo "$tmpdir" 500)

	unset AIDEVOPS_LABEL_CACHE_FILE 2>/dev/null || true

	local saved_path="$PATH"
	PATH="${tmpdir}:${PATH}"

	local rc=0
	"$CLAIM_SCRIPT" \
		--repo-path "$repo" \
		--title "Test task with invalid label" \
		--labels "debt" \
		2>/dev/null \
		|| rc=$?

	PATH="$saved_path"
	unset AIDEVOPS_LABEL_CACHE_FILE 2>/dev/null || true

	local counter_after
	counter_after=$(_read_upstream_counter "$tmpdir")

	# Must exit with code 3; counter must remain at 500 (not advanced)
	if [[ $rc -eq 3 && "${counter_after}" == "500" ]]; then
		pass "$name"
	else
		fail "$name" "expected rc=3 counter=500, got rc=${rc} counter='${counter_after}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case B: valid label → exit 0, counter advances by 1
# ---------------------------------------------------------------------------

test_case_b_valid_label_proceeds() {
	local name="B: valid label → exit 0, counter advances by 1"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local fixture="${tmpdir}/labels.txt"
	_fixture_valid_labels >"$fixture"
	_make_gh_mock "$tmpdir" "$fixture"

	local repo
	repo=$(_make_test_repo "$tmpdir" 500)

	unset AIDEVOPS_LABEL_CACHE_FILE 2>/dev/null || true

	local saved_path="$PATH"
	PATH="${tmpdir}:${PATH}"

	local rc=0
	"$CLAIM_SCRIPT" \
		--repo-path "$repo" \
		--title "Test task with valid label" \
		--labels "bug,tier:standard" \
		2>/dev/null \
		|| rc=$?

	PATH="$saved_path"
	unset AIDEVOPS_LABEL_CACHE_FILE 2>/dev/null || true

	local counter_after
	counter_after=$(_read_upstream_counter "$tmpdir")

	# Exit 0; counter advances from 500 to 501
	if [[ $rc -eq 0 && "${counter_after}" == "501" ]]; then
		pass "$name"
	else
		fail "$name" "expected rc=0 counter=501, got rc=${rc} counter='${counter_after}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case C: gh label list API fails → fail-open, counter advances
# ---------------------------------------------------------------------------

test_case_c_api_fail_failopen() {
	local name="C: label list API fails → fail-open, counter advances"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# Use mock where label list exits 1 (API error)
	_make_gh_mock_label_api_fail "$tmpdir"

	local repo
	repo=$(_make_test_repo "$tmpdir" 500)

	unset AIDEVOPS_LABEL_CACHE_FILE 2>/dev/null || true

	local saved_path="$PATH"
	PATH="${tmpdir}:${PATH}"

	local rc=0
	"$CLAIM_SCRIPT" \
		--repo-path "$repo" \
		--title "Test task during label API failure" \
		--labels "debt" \
		2>/dev/null \
		|| rc=$?

	PATH="$saved_path"
	unset AIDEVOPS_LABEL_CACHE_FILE 2>/dev/null || true

	local counter_after
	counter_after=$(_read_upstream_counter "$tmpdir")

	# Fail-open: API error → skip validation → claim proceeds → counter advances
	if [[ $rc -eq 0 && "${counter_after}" == "501" ]]; then
		pass "$name"
	else
		fail "$name" "expected rc=0 counter=501 (fail-open), got rc=${rc} counter='${counter_after}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case D: --skip-label-validation bypasses check, invalid label → proceeds
# ---------------------------------------------------------------------------

test_case_d_skip_flag_bypasses() {
	local name="D: --skip-label-validation bypasses check, counter advances"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local fixture="${tmpdir}/labels.txt"
	_fixture_valid_labels >"$fixture"
	_make_gh_mock "$tmpdir" "$fixture"

	local repo
	repo=$(_make_test_repo "$tmpdir" 500)

	unset AIDEVOPS_LABEL_CACHE_FILE 2>/dev/null || true

	local saved_path="$PATH"
	PATH="${tmpdir}:${PATH}"

	local rc=0
	"$CLAIM_SCRIPT" \
		--repo-path "$repo" \
		--title "Test skip-label-validation flag" \
		--labels "debt" \
		--skip-label-validation \
		2>/dev/null \
		|| rc=$?

	PATH="$saved_path"
	unset AIDEVOPS_LABEL_CACHE_FILE 2>/dev/null || true

	local counter_after
	counter_after=$(_read_upstream_counter "$tmpdir")

	# Skip flag → bypass validation → counter advances despite invalid label
	if [[ $rc -eq 0 && "${counter_after}" == "501" ]]; then
		pass "$name"
	else
		fail "$name" "expected rc=0 counter=501 (skipped), got rc=${rc} counter='${counter_after}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case E: _validate_labels_exist unit — invalid label returns 1
# ---------------------------------------------------------------------------

test_case_e_unit_validate_invalid() {
	local name="E: _validate_labels_exist unit — invalid label returns 1"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local fixture="${tmpdir}/labels.txt"
	_fixture_valid_labels >"$fixture"
	_make_gh_mock "$tmpdir" "$fixture"

	unset AIDEVOPS_LABEL_CACHE_FILE 2>/dev/null || true

	local saved_path="$PATH"
	PATH="${tmpdir}:${PATH}"

	local rc=0
	_validate_labels_exist "marcusquinn/aidevops" "bug,debt" 2>/dev/null || rc=$?

	PATH="$saved_path"
	unset AIDEVOPS_LABEL_CACHE_FILE 2>/dev/null || true

	if [[ $rc -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected rc=1 for 'debt' (invalid), got rc=${rc}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case F: _validate_labels_exist unit — valid labels returns 0
# ---------------------------------------------------------------------------

test_case_f_unit_validate_valid() {
	local name="F: _validate_labels_exist unit — all valid labels returns 0"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local fixture="${tmpdir}/labels.txt"
	_fixture_valid_labels >"$fixture"
	_make_gh_mock "$tmpdir" "$fixture"

	unset AIDEVOPS_LABEL_CACHE_FILE 2>/dev/null || true

	local saved_path="$PATH"
	PATH="${tmpdir}:${PATH}"

	local rc=0
	_validate_labels_exist "marcusquinn/aidevops" "bug,tier:standard,auto-dispatch" 2>/dev/null || rc=$?

	PATH="$saved_path"
	unset AIDEVOPS_LABEL_CACHE_FILE 2>/dev/null || true

	if [[ $rc -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected rc=0 for all valid labels, got rc=${rc}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

main() {
	printf 'Running claim-task-id label validation tests (t2800)...\n\n'

	test_case_a_invalid_label_exit3
	test_case_b_valid_label_proceeds
	test_case_c_api_fail_failopen
	test_case_d_skip_flag_bypasses
	test_case_e_unit_validate_invalid
	test_case_f_unit_validate_valid

	printf '\n'
	printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
	if [[ "$FAIL" -gt 0 ]]; then
		printf '\nFailed tests:%b\n' "$ERRORS"
		return 1
	fi
	return 0
}

main "$@"
