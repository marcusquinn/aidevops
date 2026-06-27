#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worker-output-classification-head-vs-search.sh — Regression tests for
# t3195 / GH#21889. Pin the contract that `_pr_exists_for_branch_or_issue`
# (and the upstream classifier paths that use it) preferentially probe via
# `gh pr list --head <branch> --state all` so workers are not misclassified
# during the GitHub Search index lag window (5-30 min after PR creation).
#
# Background (canonical incident, t3195):
#
#   - Worker dispatched at 05:43:12Z (issue #21870, repo a/b).
#   - Worker pushed feature/auto-... and opened PR #21885 at 05:47:48Z.
#   - The pulse ran `_worker_produced_output` at 05:52:38Z (5 min later).
#   - Signal 3 was `gh pr list --search 21870 --json number --jq length`.
#   - GitHub Search index had not yet indexed PR #21885 → returned 0.
#   - Classifier emitted `branch_orphan`.
#   - `_attempt_orphan_recovery_pr` then tried `gh pr create --head <same>`
#     which fails because the PR ALREADY exists for that head.
#   - The worker's real output was discarded as orphan recovery noise.
#
# Fix (t3195): probe via `--head <branch> --state all` first (live pulls API,
# no search-index lag); fall back to `--search <issue>` only when --head
# missed (or branch unknown). Pre-check the same in `_attempt_orphan_recovery_pr`
# so the recovery path no-ops cleanly when a PR already exists.
#
# Test cases:
#
#   Case A (search-lag survival): branch=feature/foo, head-probe returns 1,
#     search-probe returns 0 → helper "found", classifier "pr_exists".
#     This is THE regression case from t3195. Pre-fix: `branch_orphan`.
#
#   Case B (definitive absence): branch=feature/foo, head-probe returns 0,
#     search-probe returns 0 → helper "absent", classifier "branch_orphan".
#     Legitimate orphan path stays intact.
#
#   Case C (search fallback for empty branch): branch="", head-probe never
#     fires, search-probe returns 1 → helper "found".
#     Confirms the fallback chain works when branch_name is empty.
#
#   Case D (no inputs / unknown): branch="", issue="", repo="" → "unknown".
#     Caller fail-opens via the `*` arm of the case statement.
#
#   Case E (orphan recovery pre-check): _attempt_orphan_recovery_pr is given
#     a branch whose head-probe returns 1 → returns 0 (PR exists, no
#     duplicate creation attempt). Pre-fix: tried `gh pr create` → failed.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
LIB_SCRIPT="${TEST_SCRIPTS_DIR}/shared-claim-lifecycle.sh"

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local rc="$2"
	local extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s%s\n' "$TEST_RED" "$TEST_RESET" "$name" "${extra:+ — $extra}"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Sandbox
# -----------------------------------------------------------------------------

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

ORIGINAL_HOME="$HOME"
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

# `gh` stub: we partition counts by probe type using STUB_HEAD_COUNT and
# STUB_SEARCH_COUNT. Any other gh invocation prints empty JSON {} and exits 0
# so source-time `gh api user` calls in dependent helpers don't crash.
GH_STUB_DIR="${TEST_ROOT}/stubs"
mkdir -p "$GH_STUB_DIR"
cat >"${GH_STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
# Stub: emit counts based on which probe flag is in argv.
# Recognised:
#   `gh pr list ... --head <branch> ...` → ${STUB_HEAD_COUNT:-0}
#   `gh pr list ... --search <query> ...` → ${STUB_SEARCH_COUNT:-0}
#   `gh pr create ...`                   → record to STUB_PR_CREATE_LOG, exit 0
#   `gh issue view ...`                  → emit OPEN state JSON
#   `gh repo view ...`                   → emit defaultBranchRef.name=main JSON
#   anything else                        → empty JSON `{}`
mode=""
for a in "$@"; do
	case "$a" in
		--head) mode="head" ;;
		--search) mode="search" ;;
	esac
done
case "${1:-}" in
	pr)
		case "${2:-}" in
			list)
				if [[ "$mode" == "head" ]]; then
					printf '%s\n' "${STUB_HEAD_COUNT:-0}"
				elif [[ "$mode" == "search" ]]; then
					printf '%s\n' "${STUB_SEARCH_COUNT:-0}"
				else
					printf '0\n'
				fi
				;;
			create)
				if [[ -n "${STUB_PR_CREATE_LOG:-}" ]]; then
					printf 'gh pr create %s\n' "$*" >> "$STUB_PR_CREATE_LOG"
				fi
				exit 0
				;;
			*) ;;
		esac
		;;
	issue)
		case "${2:-}" in
			view) printf '"OPEN"\n' ;;
			*) ;;
		esac
		;;
	repo)
		case "${2:-}" in
			view) printf '"main"\n' ;;
			*) ;;
		esac
		;;
	api) printf '{}\n' ;;
	*) ;;
esac
exit 0
STUB
chmod +x "${GH_STUB_DIR}/gh"
export PATH="${GH_STUB_DIR}:${PATH}"

# Source the lib. set -e off so transient sourcing failures don't abort.
set +e
# shellcheck source=/dev/null
source "$LIB_SCRIPT" >/dev/null 2>&1
SOURCE_RC=$?
set -e
if [[ "$SOURCE_RC" -ne 0 ]] && ! declare -F _pr_exists_for_branch_or_issue >/dev/null 2>&1; then
	printf '%sFAIL%s sourcing %s — _pr_exists_for_branch_or_issue not defined\n' \
		"$TEST_RED" "$TEST_RESET" "$LIB_SCRIPT"
	exit 1
fi
if ! declare -F _pr_exists_for_branch_or_issue >/dev/null 2>&1; then
	printf '%sFAIL%s _pr_exists_for_branch_or_issue not defined after source\n' \
		"$TEST_RED" "$TEST_RESET"
	exit 1
fi
if ! declare -F _attempt_orphan_recovery_pr >/dev/null 2>&1; then
	printf '%sFAIL%s _attempt_orphan_recovery_pr not defined after source\n' \
		"$TEST_RED" "$TEST_RESET"
	exit 1
fi

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case A: search-lag survival. --head returns 1, --search returns 0.
# This is the regression case from t3195 / GH#21889.
test_case_a_head_wins_over_search_lag() {
	export STUB_HEAD_COUNT=1
	export STUB_SEARCH_COUNT=0
	local got
	got=$(_pr_exists_for_branch_or_issue "feature/auto-foo" "21870" "owner/repo")
	if [[ "$got" == "found" ]]; then
		print_result "case A: --head=1 + --search=0 → found (search-lag survival, t3195)" 0
	else
		print_result "case A: --head=1 + --search=0 → found (search-lag survival, t3195)" 1 \
			"got: '$got' (expected 'found' — search-index lag must NOT mask a real PR)"
	fi
	return 0
}

# Case B: definitive absence. Both probes return 0.
test_case_b_definitive_absence() {
	export STUB_HEAD_COUNT=0
	export STUB_SEARCH_COUNT=0
	local got
	got=$(_pr_exists_for_branch_or_issue "feature/real-orphan" "99999" "owner/repo")
	if [[ "$got" == "absent" ]]; then
		print_result "case B: --head=0 + --search=0 → absent (legitimate orphan)" 0
	else
		print_result "case B: --head=0 + --search=0 → absent (legitimate orphan)" 1 \
			"got: '$got' (expected 'absent')"
	fi
	return 0
}

# Case C: search fallback when branch_name empty.
test_case_c_search_fallback_empty_branch() {
	export STUB_HEAD_COUNT=0  # never queried — branch is empty
	export STUB_SEARCH_COUNT=1
	local got
	got=$(_pr_exists_for_branch_or_issue "" "21870" "owner/repo")
	if [[ "$got" == "found" ]]; then
		print_result "case C: branch='' + --search=1 → found (fallback path)" 0
	else
		print_result "case C: branch='' + --search=1 → found (fallback path)" 1 \
			"got: '$got' (expected 'found')"
	fi
	return 0
}

# Case D: no usable inputs → unknown.
test_case_d_no_inputs_unknown() {
	export STUB_HEAD_COUNT=0
	export STUB_SEARCH_COUNT=0
	local got
	got=$(_pr_exists_for_branch_or_issue "" "" "owner/repo")
	if [[ "$got" == "unknown" ]]; then
		print_result "case D: branch='' + issue='' → unknown (fail-open)" 0
	else
		print_result "case D: branch='' + issue='' → unknown (fail-open)" 1 \
			"got: '$got' (expected 'unknown')"
	fi
	return 0
}

# Case D2: empty repo_slug → unknown regardless of probes.
test_case_d2_empty_repo_unknown() {
	export STUB_HEAD_COUNT=1
	export STUB_SEARCH_COUNT=1
	local got
	got=$(_pr_exists_for_branch_or_issue "feature/foo" "21870" "")
	if [[ "$got" == "unknown" ]]; then
		print_result "case D2: repo_slug='' → unknown (no API target)" 0
	else
		print_result "case D2: repo_slug='' → unknown (no API target)" 1 \
			"got: '$got' (expected 'unknown')"
	fi
	return 0
}

# Case E: orphan recovery pre-check. When a PR exists for the branch
# (--head=1), recovery returns 0 with NO `gh pr create` attempt.
test_case_e_orphan_recovery_skips_when_pr_exists() {
	export STUB_HEAD_COUNT=1
	export STUB_SEARCH_COUNT=0
	local pr_log="${TEST_ROOT}/pr-create.log"
	: >"$pr_log"
	export STUB_PR_CREATE_LOG="$pr_log"

	# Call recovery; should return 0 immediately (PR exists) and NOT log
	# any `gh pr create` invocation.
	if _attempt_orphan_recovery_pr "issue-21870" "/tmp/unused-workdir" \
		"feature/auto-foo" "owner/repo"; then
		if [[ -s "$pr_log" ]]; then
			print_result "case E: orphan recovery short-circuits when --head=1" 1 \
				"recovery returned 0 but ALSO called gh pr create — pre-check ineffective"
		else
			print_result "case E: orphan recovery short-circuits when --head=1" 0
		fi
	else
		print_result "case E: orphan recovery short-circuits when --head=1" 1 \
			"recovery returned non-zero (expected 0 — PR exists, treat as success)"
	fi
	unset STUB_PR_CREATE_LOG
	return 0
}

# Case F: orphan recovery proceeds when no PR exists. Confirms the pre-check
# does NOT block legitimate recovery when the absence is real. We allow the
# stub `gh pr create` to "succeed" so we can observe it being called.
test_case_f_orphan_recovery_proceeds_when_no_pr() {
	export STUB_HEAD_COUNT=0
	export STUB_SEARCH_COUNT=0
	local pr_log="${TEST_ROOT}/pr-create-2.log"
	: >"$pr_log"
	export STUB_PR_CREATE_LOG="$pr_log"
	local origin_dir="${TEST_ROOT}/case-f-origin.git"
	local work_dir="${TEST_ROOT}/case-f-work"
	git init --bare "$origin_dir" >/dev/null 2>&1 || return 1
	git init "$work_dir" >/dev/null 2>&1 || return 1
	git -C "$work_dir" config user.email test@example.invalid || return 1
	git -C "$work_dir" config user.name "Test User" || return 1
	printf 'base\n' >"${work_dir}/README.md"
	git -C "$work_dir" add README.md >/dev/null 2>&1 || return 1
	git -C "$work_dir" commit -m base >/dev/null 2>&1 || return 1
	git -C "$work_dir" branch -M main >/dev/null 2>&1 || return 1
	git -C "$work_dir" remote add origin "$origin_dir" || return 1
	git -C "$work_dir" push origin main >/dev/null 2>&1 || return 1
	git -C "$work_dir" checkout -b feature/real-orphan >/dev/null 2>&1 || return 1
	printf 'change\n' >>"${work_dir}/README.md"
	git -C "$work_dir" add README.md >/dev/null 2>&1 || return 1
	git -C "$work_dir" commit -m change >/dev/null 2>&1 || return 1
	git -C "$work_dir" push origin feature/real-orphan >/dev/null 2>&1 || return 1

	_attempt_orphan_recovery_pr "issue-99999" "$work_dir" \
		"feature/real-orphan" "owner/repo" || true
	# Whether create succeeded matters less than: did we ATTEMPT it?
	if [[ -s "$pr_log" ]]; then
		print_result "case F: orphan recovery proceeds to gh pr create when --head=0" 0
	else
		print_result "case F: orphan recovery proceeds to gh pr create when --head=0" 1 \
			"pre-check incorrectly blocked recovery despite definitive absence"
	fi
	unset STUB_PR_CREATE_LOG
	return 0
}

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------

test_case_a_head_wins_over_search_lag
test_case_b_definitive_absence
test_case_c_search_fallback_empty_branch
test_case_d_no_inputs_unknown
test_case_d2_empty_repo_unknown
test_case_e_orphan_recovery_skips_when_pr_exists
test_case_f_orphan_recovery_proceeds_when_no_pr

printf '\nRan %d test(s), %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

export HOME="$ORIGINAL_HOME"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
