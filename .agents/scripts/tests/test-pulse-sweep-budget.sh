#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-sweep-budget.sh — t2041 regression guard.
#
# Asserts the budget-aware LLM sweep primitives work:
#
#   Part 1 — _compute_repo_state_fingerprint produces:
#            * Stable output (identical input → identical hash)
#            * Sensitive to label/assignee/updatedAt changes
#            * 16-char hex output
#            * Empty string on gh failure (fail-open)
#
#   Part 2 — _verify_repo_state_unchanged:
#            * Returns 0 when search returns zero results
#            * Returns 1 when search returns any hits
#            * Returns 1 on gh failure (fail-closed)
#
#   Part 3 — _prefetch_detect_cache_hit:
#            * Cache hit when fingerprint matches AND verification clean
#            * Cache miss when fingerprint differs
#            * Cache miss when no cached fingerprint exists
#            * Always sets PREFETCH_CURRENT_FINGERPRINT
#
#   Part 4 — prefetch_hygiene_anomalies output:
#            * "None — label invariants clean" when all counters zero
#            * Actionable lines when any counter is non-zero
#            * "First cycle" message when counter file is absent
#
#   Part 5 — pulse-sweep-budget.json validates as JSON with expected fields

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/cache" "${HOME}/.aidevops/.agent-workspace/supervisor"
export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
: >"$LOGFILE"
export PULSE_QUEUED_SCAN_LIMIT=100
export PULSE_PREFETCH_CACHE_FILE="${TEST_ROOT}/prefetch-cache.json"

# =============================================================================
# Setup — stub gh CLI
# =============================================================================
STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"

# Each test may write GH_ISSUE_LIST_PAYLOAD / GH_SEARCH_LIST_PAYLOAD to
# control what the stub returns. Empty = return []. GH_STUB_FAIL=1 makes
# the stub exit non-zero.
GH_CALLS_LOG="${TEST_ROOT}/gh-calls.log"
export GH_CALLS_LOG

cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_CALLS_LOG}"
if [[ "${GH_STUB_FAIL:-}" == "1" ]]; then
	exit 2
fi
case "$1" in
	api)
		if [[ "$2" == "user" ]]; then
			echo '{"login":"test-user"}'
			exit 0
		fi
		;;
	issue)
		case "$2" in
			list)
				# Detect --search (verification query) vs plain list
				has_search="false"
				for arg in "$@"; do
					if [[ "$arg" == --search* || "$arg" == "--search" ]]; then
						has_search="true"
					fi
				done
				if [[ "$has_search" == "true" ]]; then
					printf '%s' "${GH_SEARCH_LIST_PAYLOAD:-[]}"
				else
					printf '%s' "${GH_ISSUE_LIST_PAYLOAD:-[]}"
				fi
				exit 0
				;;
			edit) exit 0 ;;
			view) echo '{"state":"OPEN","labels":[]}'; exit 0 ;;
		esac
		;;
	label) exit 0 ;;
esac
exit 0
STUB
chmod +x "${STUB_DIR}/gh"

# Source prefetch. IMPORTANT: set PATH after sourcing — issue-sync-helper
# resets PATH on source, and pulse-prefetch.sh may transitively include it.
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/shared-constants.sh"
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/pulse-prefetch.sh" >/dev/null 2>&1
set +e
export PATH="${STUB_DIR}:${PATH}"

# =============================================================================
# Part 1 — _compute_repo_state_fingerprint
# =============================================================================
ISSUES_A='[{"number":1,"labels":[{"name":"tier:standard"}],"assignees":[{"login":"alice"}],"updatedAt":"2026-04-13T10:00:00Z"},{"number":2,"labels":[{"name":"tier:simple"}],"assignees":[],"updatedAt":"2026-04-13T11:00:00Z"}]'

export GH_ISSUE_LIST_PAYLOAD="$ISSUES_A"
: >"$GH_CALLS_LOG"
fp1=$(_compute_repo_state_fingerprint "test/repo")
fp2=$(_compute_repo_state_fingerprint "test/repo")

if [[ -n "$fp1" && "$fp1" == "$fp2" ]]; then
	print_result "fingerprint is deterministic (same input → same hash)" 0
else
	print_result "fingerprint is deterministic (same input → same hash)" 1 \
		"(fp1='$fp1' fp2='$fp2')"
fi

if [[ "${#fp1}" -eq 16 && "$fp1" =~ ^[0-9a-f]+$ ]]; then
	print_result "fingerprint is 16-char hex" 0
else
	print_result "fingerprint is 16-char hex" 1 "(got: '$fp1' length=${#fp1})"
fi

# Sensitivity: change a label → fingerprint changes
ISSUES_B='[{"number":1,"labels":[{"name":"tier:reasoning"}],"assignees":[{"login":"alice"}],"updatedAt":"2026-04-13T10:00:00Z"},{"number":2,"labels":[{"name":"tier:simple"}],"assignees":[],"updatedAt":"2026-04-13T11:00:00Z"}]'
export GH_ISSUE_LIST_PAYLOAD="$ISSUES_B"
fp3=$(_compute_repo_state_fingerprint "test/repo")
if [[ -n "$fp3" && "$fp3" != "$fp1" ]]; then
	print_result "fingerprint changes when a label changes" 0
else
	print_result "fingerprint changes when a label changes" 1 \
		"(fp1='$fp1' fp3='$fp3')"
fi

# Sensitivity: change updatedAt → fingerprint changes
ISSUES_C='[{"number":1,"labels":[{"name":"tier:standard"}],"assignees":[{"login":"alice"}],"updatedAt":"2026-04-13T12:00:00Z"},{"number":2,"labels":[{"name":"tier:simple"}],"assignees":[],"updatedAt":"2026-04-13T11:00:00Z"}]'
export GH_ISSUE_LIST_PAYLOAD="$ISSUES_C"
fp4=$(_compute_repo_state_fingerprint "test/repo")
if [[ -n "$fp4" && "$fp4" != "$fp1" ]]; then
	print_result "fingerprint changes when updatedAt changes" 0
else
	print_result "fingerprint changes when updatedAt changes" 1 \
		"(fp1='$fp1' fp4='$fp4')"
fi

# Order independence: labels in different order within a single issue
# must yield the same fingerprint (we canonicalize via sort)
ISSUES_D='[{"number":1,"labels":[{"name":"tier:standard"},{"name":"auto-dispatch"}],"assignees":[{"login":"alice"}],"updatedAt":"2026-04-13T10:00:00Z"}]'
ISSUES_D_REORDERED='[{"number":1,"labels":[{"name":"auto-dispatch"},{"name":"tier:standard"}],"assignees":[{"login":"alice"}],"updatedAt":"2026-04-13T10:00:00Z"}]'
export GH_ISSUE_LIST_PAYLOAD="$ISSUES_D"
fp_d1=$(_compute_repo_state_fingerprint "test/repo")
export GH_ISSUE_LIST_PAYLOAD="$ISSUES_D_REORDERED"
fp_d2=$(_compute_repo_state_fingerprint "test/repo")
if [[ -n "$fp_d1" && "$fp_d1" == "$fp_d2" ]]; then
	print_result "fingerprint is label-order independent (sorted)" 0
else
	print_result "fingerprint is label-order independent (sorted)" 1 \
		"(fp_d1='$fp_d1' fp_d2='$fp_d2')"
fi

# Fail-open: gh failure returns empty string
export GH_STUB_FAIL=1
fp_fail=$(_compute_repo_state_fingerprint "test/repo")
unset GH_STUB_FAIL
if [[ -z "$fp_fail" ]]; then
	print_result "fingerprint returns empty string on gh failure (fail-open)" 0
else
	print_result "fingerprint returns empty string on gh failure (fail-open)" 1 "(got: '$fp_fail')"
fi

# =============================================================================
# Part 2 — _verify_repo_state_unchanged
# =============================================================================
export GH_SEARCH_LIST_PAYLOAD="[]"
if _verify_repo_state_unchanged "test/repo" "2026-04-13T10:00:00Z"; then
	print_result "verify returns 0 on empty search result" 0
else
	print_result "verify returns 0 on empty search result" 1
fi

export GH_SEARCH_LIST_PAYLOAD='[{"number":1}]'
if ! _verify_repo_state_unchanged "test/repo" "2026-04-13T10:00:00Z"; then
	print_result "verify returns 1 when search has hits" 0
else
	print_result "verify returns 1 when search has hits" 1
fi

if ! _verify_repo_state_unchanged "test/repo" ""; then
	print_result "verify returns 1 on empty last_pass_iso" 0
else
	print_result "verify returns 1 on empty last_pass_iso" 1
fi

# Fail-closed: gh failure = miss
export GH_STUB_FAIL=1
if ! _verify_repo_state_unchanged "test/repo" "2026-04-13T10:00:00Z"; then
	print_result "verify returns 1 on gh failure (fail-closed)" 0
else
	print_result "verify returns 1 on gh failure (fail-closed)" 1
fi
unset GH_STUB_FAIL

# =============================================================================
# Part 3 — _prefetch_detect_cache_hit
# =============================================================================
export GH_ISSUE_LIST_PAYLOAD="$ISSUES_A"
export GH_SEARCH_LIST_PAYLOAD="[]"
# Compute the expected fingerprint for this state
expected_fp=$(_compute_repo_state_fingerprint "test/repo")

# Case A: cache has matching fingerprint + clean verification → hit
cache_entry_a=$(jq -n --arg fp "$expected_fp" --arg ts "2026-04-13T10:00:00Z" \
	'{state_fingerprint: $fp, last_prefetch: $ts, last_full_sweep: $ts, prs: [], issues: []}')
if _prefetch_detect_cache_hit "test/repo" "$cache_entry_a"; then
	print_result "cache hit when fingerprint matches and verification clean" 0
else
	print_result "cache hit when fingerprint matches and verification clean" 1
fi

# PREFETCH_CURRENT_FINGERPRINT must be set on the caller
if [[ "${PREFETCH_CURRENT_FINGERPRINT:-}" == "$expected_fp" ]]; then
	print_result "cache hit sets PREFETCH_CURRENT_FINGERPRINT" 0
else
	print_result "cache hit sets PREFETCH_CURRENT_FINGERPRINT" 1 \
		"(expected: '$expected_fp' got: '${PREFETCH_CURRENT_FINGERPRINT:-}')"
fi

# Case B: cache has different fingerprint → miss
cache_entry_b=$(jq -n --arg fp "wrongfingerpr" --arg ts "2026-04-13T10:00:00Z" \
	'{state_fingerprint: $fp, last_prefetch: $ts, last_full_sweep: $ts, prs: [], issues: []}')
if ! _prefetch_detect_cache_hit "test/repo" "$cache_entry_b"; then
	print_result "cache miss when fingerprint differs" 0
else
	print_result "cache miss when fingerprint differs" 1
fi

# Case C: cache has no fingerprint field → miss
cache_entry_c='{"last_prefetch":"2026-04-13T10:00:00Z","last_full_sweep":"2026-04-13T10:00:00Z","prs":[],"issues":[]}'
if ! _prefetch_detect_cache_hit "test/repo" "$cache_entry_c"; then
	print_result "cache miss when fingerprint field absent" 0
else
	print_result "cache miss when fingerprint field absent" 1
fi

# Case D: fingerprint matches but verification fails → miss
export GH_SEARCH_LIST_PAYLOAD='[{"number":42}]'
if ! _prefetch_detect_cache_hit "test/repo" "$cache_entry_a"; then
	print_result "cache miss when fingerprint matches but state changed" 0
else
	print_result "cache miss when fingerprint matches but state changed" 1
fi

# =============================================================================
# Part 4 — prefetch_hygiene_anomalies output
# =============================================================================
hostname_short=$(hostname -s 2>/dev/null || echo unknown)
counters_file="${HOME}/.aidevops/cache/pulse-label-invariants.${hostname_short}.json"

# Case A: no counter file → first cycle message
rm -f "$counters_file"
out=$(prefetch_hygiene_anomalies 2>&1)
if [[ "$out" == *"Hygiene Anomalies"* && "$out" == *"first cycle"* ]]; then
	print_result "hygiene anomalies: first-cycle message when counter file absent" 0
else
	print_result "hygiene anomalies: first-cycle message when counter file absent" 1 "(got: $out)"
fi

# Case B: all zero counters → "None — label invariants clean"
cat >"$counters_file" <<JSON
{"timestamp": "2026-04-13T10:00:00Z", "checked": 100, "status_fixed": 0, "tier_fixed": 0, "triage_missing": 0}
JSON
out=$(prefetch_hygiene_anomalies 2>&1)
if [[ "$out" == *"None — label invariants clean"* && "$out" == *"checked=100"* ]]; then
	print_result "hygiene anomalies: 'None' when all counters zero" 0
else
	print_result "hygiene anomalies: 'None' when all counters zero" 1 "(got: $out)"
fi

# Case C: nonzero status_fixed → actionable line with count
cat >"$counters_file" <<JSON
{"timestamp": "2026-04-13T10:00:00Z", "checked": 100, "status_fixed": 3, "tier_fixed": 0, "triage_missing": 0}
JSON
out=$(prefetch_hygiene_anomalies 2>&1)
if [[ "$out" == *"3 issues"* && "$out" == *"status:"* ]]; then
	print_result "hygiene anomalies: emits actionable line for nonzero status_fixed" 0
else
	print_result "hygiene anomalies: emits actionable line for nonzero status_fixed" 1 "(got: $out)"
fi

# Case D: nonzero tier_fixed AND triage_missing
cat >"$counters_file" <<JSON
{"timestamp": "2026-04-13T10:00:00Z", "checked": 200, "status_fixed": 0, "tier_fixed": 5, "triage_missing": 2}
JSON
out=$(prefetch_hygiene_anomalies 2>&1)
if [[ "$out" == *"5 issues"* && "$out" == *"tier:"* && "$out" == *"2 issues"* && "$out" == *"triage"* ]]; then
	print_result "hygiene anomalies: handles multiple nonzero counters" 0
else
	print_result "hygiene anomalies: handles multiple nonzero counters" 1 "(got: $out)"
fi

# =============================================================================
# Part 5 — config file validation
# =============================================================================
CONFIG_FILE="${TEST_SCRIPTS_DIR}/../configs/pulse-sweep-budget.json"
if [[ -f "$CONFIG_FILE" ]] && jq empty "$CONFIG_FILE" 2>/dev/null; then
	print_result "pulse-sweep-budget.json exists and is valid JSON" 0
else
	print_result "pulse-sweep-budget.json exists and is valid JSON" 1
fi

if [[ -f "$CONFIG_FILE" ]]; then
	token_budget=$(jq -r '.default.token_budget' "$CONFIG_FILE" 2>/dev/null)
	max_events=$(jq -r '.default.max_events_per_pass' "$CONFIG_FILE" 2>/dev/null)
	if [[ "$token_budget" =~ ^[0-9]+$ && "$max_events" =~ ^[0-9]+$ ]]; then
		print_result "pulse-sweep-budget.json has numeric token_budget and max_events_per_pass" 0
	else
		print_result "pulse-sweep-budget.json has numeric token_budget and max_events_per_pass" 1 \
			"(token_budget='$token_budget' max_events='$max_events')"
	fi
fi

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
