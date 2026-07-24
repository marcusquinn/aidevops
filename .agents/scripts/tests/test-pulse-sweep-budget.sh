#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-sweep-budget.sh — t2041 regression guard.
#
# Asserts the budget-aware LLM sweep primitives work:
#
#   Part 1 — _compute_repo_state_fingerprint produces from canonical snapshots:
#            * Stable output (identical input → identical hash)
#            * Sensitive to label/assignee/updatedAt/head SHA changes
#            * 16-char hex output
#            * Empty string for incomplete/incompatible snapshot pairs
#
#   Part 2 — canonical pair validation:
#            * Accepts complete empty collections
#            * Rejects generation/projection/completeness mismatches
#
#   Part 3 — _prefetch_detect_cache_hit:
#            * Cache hit when canonical fingerprint and schema match
#            * Cache miss when fingerprint differs
#            * Cache miss when no cached fingerprint schema exists
#            * Always sets PREFETCH_CURRENT_FINGERPRINT
#            * Makes no GitHub list calls
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

# The stub ledger proves local fingerprint/cache decisions make no GitHub calls.
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
	issue|pr)
		case "$2" in
			list)
				# Keep search-shaped fixtures distinguishable if a regression calls them.
				has_search="false"
				for arg in "$@"; do
					if [[ "$arg" == --search* || "$arg" == "--search" ]]; then
						has_search="true"
					fi
				done
				if [[ "$has_search" == "true" ]]; then
					printf '%s' "${GH_SEARCH_LIST_PAYLOAD:-[]}"
				elif [[ "$1" == "pr" ]]; then
					printf '%s' "${GH_PR_LIST_PAYLOAD:-[]}"
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
ISSUES_A='[{"number":1,"state":"open","labels":[{"name":"tier:standard"}],"assignees":[{"login":"alice"}],"updatedAt":"2026-04-13T10:00:00Z"},{"number":2,"state":"open","labels":[{"name":"tier:simple"}],"assignees":[],"updatedAt":"2026-04-13T11:00:00Z"}]'
PRS_A='[{"number":7,"labels":[{"name":"ready"}],"assignees":[],"updatedAt":"2026-04-13T11:00:00Z","headRefOid":"abc123"}]'

make_snapshot() {
	local kind="$1"
	local items="$2"
	local complete="${3:-true}"
	local generation="${4:-generation-a}"
	local projection=""
	if [[ "$kind" == "issues" ]]; then
		projection="$_PREFETCH_ISSUES_PROJECTION"
	else
		projection="$_PREFETCH_PRS_PROJECTION"
	fi
	jq -cn --arg schema "$_PREFETCH_SNAPSHOT_SCHEMA" --arg repo "test/repo" \
		--arg kind "$kind" --arg projection "$projection" --arg generation "$generation" \
		--argjson complete "$complete" --argjson items "$items" \
		'{schema:$schema,repository:$repo,collection:$kind,projection:$projection,
		  auth_scope:"github.com",generation:$generation,source:"fixture",
		  fetched_at:"2026-04-13T10:00:00Z",
		  complete:$complete,items:$items}'
	return 0
}

: >"$GH_CALLS_LOG"
issues_snapshot_a=$(make_snapshot issues "$ISSUES_A")
prs_snapshot_a=$(make_snapshot prs "$PRS_A")
fp1=$(_compute_repo_state_fingerprint "test/repo" "$issues_snapshot_a" "$prs_snapshot_a")
fp2=$(_compute_repo_state_fingerprint "test/repo" "$issues_snapshot_a" "$prs_snapshot_a")

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
ISSUES_B='[{"number":1,"state":"open","labels":[{"name":"tier:thinking"}],"assignees":[{"login":"alice"}],"updatedAt":"2026-04-13T10:00:00Z"},{"number":2,"state":"open","labels":[{"name":"tier:simple"}],"assignees":[],"updatedAt":"2026-04-13T11:00:00Z"}]'
issues_snapshot_b=$(make_snapshot issues "$ISSUES_B")
fp3=$(_compute_repo_state_fingerprint "test/repo" "$issues_snapshot_b" "$prs_snapshot_a")
if [[ -n "$fp3" && "$fp3" != "$fp1" ]]; then
	print_result "fingerprint changes when a label changes" 0
else
	print_result "fingerprint changes when a label changes" 1 \
		"(fp1='$fp1' fp3='$fp3')"
fi

# Sensitivity: change updatedAt → fingerprint changes
ISSUES_C='[{"number":1,"state":"open","labels":[{"name":"tier:standard"}],"assignees":[{"login":"alice"}],"updatedAt":"2026-04-13T12:00:00Z"},{"number":2,"state":"open","labels":[{"name":"tier:simple"}],"assignees":[],"updatedAt":"2026-04-13T11:00:00Z"}]'
issues_snapshot_c=$(make_snapshot issues "$ISSUES_C")
fp4=$(_compute_repo_state_fingerprint "test/repo" "$issues_snapshot_c" "$prs_snapshot_a")
if [[ -n "$fp4" && "$fp4" != "$fp1" ]]; then
	print_result "fingerprint changes when updatedAt changes" 0
else
	print_result "fingerprint changes when updatedAt changes" 1 \
		"(fp1='$fp1' fp4='$fp4')"
fi

# Order independence: labels in different order within a single issue
# must yield the same fingerprint (we canonicalize via sort)
ISSUES_D='[{"number":1,"state":"open","labels":[{"name":"tier:standard"},{"name":"auto-dispatch"}],"assignees":[{"login":"alice"}],"updatedAt":"2026-04-13T10:00:00Z"}]'
ISSUES_D_REORDERED='[{"number":1,"state":"open","labels":[{"name":"auto-dispatch"},{"name":"tier:standard"}],"assignees":[{"login":"alice"}],"updatedAt":"2026-04-13T10:00:00Z"}]'
issues_snapshot_d=$(make_snapshot issues "$ISSUES_D")
issues_snapshot_d_reordered=$(make_snapshot issues "$ISSUES_D_REORDERED")
fp_d1=$(_compute_repo_state_fingerprint "test/repo" "$issues_snapshot_d" "$prs_snapshot_a")
fp_d2=$(_compute_repo_state_fingerprint "test/repo" "$issues_snapshot_d_reordered" "$prs_snapshot_a")
if [[ -n "$fp_d1" && "$fp_d1" == "$fp_d2" ]]; then
	print_result "fingerprint is label-order independent (sorted)" 0
else
	print_result "fingerprint is label-order independent (sorted)" 1 \
		"(fp_d1='$fp_d1' fp_d2='$fp_d2')"
fi

# Incomplete input forces the full-analysis path.
issues_snapshot_incomplete=$(make_snapshot issues "$ISSUES_A" false)
fp_incomplete=$(_compute_repo_state_fingerprint "test/repo" "$issues_snapshot_incomplete" "$prs_snapshot_a")
if [[ -z "$fp_incomplete" ]]; then
	print_result "fingerprint returns empty string for incomplete snapshots" 0
else
	print_result "fingerprint returns empty string for incomplete snapshots" 1 "(got: '$fp_incomplete')"
fi

# =============================================================================
# Part 2 — canonical pair validation
# =============================================================================
empty_issues_snapshot=$(make_snapshot issues '[]')
empty_prs_snapshot=$(make_snapshot prs '[]')
empty_fp=$(_compute_repo_state_fingerprint "test/repo" "$empty_issues_snapshot" "$empty_prs_snapshot")
if [[ "$empty_fp" =~ ^[0-9a-f]{16}$ ]]; then
	print_result "complete empty snapshot pair produces a fingerprint" 0
else
	print_result "complete empty snapshot pair produces a fingerprint" 1
fi

prs_generation_b=$(make_snapshot prs "$PRS_A" true generation-b)
if ! _canonical_snapshot_pair_complete "test/repo" "$issues_snapshot_a" "$prs_generation_b"; then
	print_result "canonical pair rejects mixed generations" 0
else
	print_result "canonical pair rejects mixed generations" 1
fi

issues_wrong_projection=$(printf '%s' "$issues_snapshot_a" | jq '.projection = "narrow"')
if ! _canonical_snapshot_pair_complete "test/repo" "$issues_wrong_projection" "$prs_snapshot_a"; then
	print_result "canonical pair rejects incompatible projections" 0
else
	print_result "canonical pair rejects incompatible projections" 1
fi

if ! _canonical_snapshot_pair_complete "test/repo" "$issues_snapshot_incomplete" "$prs_snapshot_a"; then
	print_result "canonical pair rejects incomplete collections" 0
else
	print_result "canonical pair rejects incomplete collections" 1
fi

# =============================================================================
# Part 3 — _prefetch_detect_cache_hit
# =============================================================================
expected_fp=$(_compute_repo_state_fingerprint "test/repo" "$issues_snapshot_a" "$prs_snapshot_a")

# Case A: cache has matching canonical fingerprint/schema → hit
cache_entry_a=$(jq -n --arg fp "$expected_fp" --arg ts "2026-04-13T10:00:00Z" \
	'{state_fingerprint: $fp, state_fingerprint_schema:"canonical-snapshot-v1",
	  last_prefetch: $ts, last_full_sweep: $ts, prs: [], issues: []}')
if _prefetch_detect_cache_hit "test/repo" "$cache_entry_a" "$issues_snapshot_a" "$prs_snapshot_a"; then
	print_result "cache hit when canonical fingerprint and schema match" 0
else
	print_result "cache hit when canonical fingerprint and schema match" 1
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
	'{state_fingerprint: $fp, state_fingerprint_schema:"canonical-snapshot-v1",
	  last_prefetch: $ts, last_full_sweep: $ts, prs: [], issues: []}')
if ! _prefetch_detect_cache_hit "test/repo" "$cache_entry_b" "$issues_snapshot_a" "$prs_snapshot_a"; then
	print_result "cache miss when fingerprint differs" 0
else
	print_result "cache miss when fingerprint differs" 1
fi

# Case C: cache has no fingerprint field → miss
cache_entry_c='{"last_prefetch":"2026-04-13T10:00:00Z","last_full_sweep":"2026-04-13T10:00:00Z","prs":[],"issues":[]}'
if ! _prefetch_detect_cache_hit "test/repo" "$cache_entry_c" "$issues_snapshot_a" "$prs_snapshot_a"; then
	print_result "cache miss when fingerprint schema is absent" 0
else
	print_result "cache miss when fingerprint schema is absent" 1
fi

# Case D: matching cached value cannot authorize an incomplete current pair.
if ! _prefetch_detect_cache_hit "test/repo" "$cache_entry_a" "$issues_snapshot_incomplete" "$prs_snapshot_a"; then
	print_result "cache miss when current snapshot is incomplete" 0
else
	print_result "cache miss when current snapshot is incomplete" 1
fi

if [[ ! -s "$GH_CALLS_LOG" ]]; then
	print_result "fingerprint and cache-hit decisions make zero GitHub calls" 0
else
	print_result "fingerprint and cache-hit decisions make zero GitHub calls" 1
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
