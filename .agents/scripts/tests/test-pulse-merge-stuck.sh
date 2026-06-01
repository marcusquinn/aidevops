#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-stuck.sh — Structural tests for t3193 stuck-merge detector.
#
# Verifies (no live GitHub API calls):
#   1. pulse-merge-stuck.conf exists with the four canonical env-var defaults.
#   2. pulse-merge-stuck.sh sources cleanly and applies positive-integer defaults.
#   3. _pms_iso_to_epoch round-trips a valid ISO timestamp; returns 0 for garbage.
#   4. _pms_hash_fingerprint returns a 16-hex-char digest, deterministic
#      across calls with the same input, and survives empty input.
#   5. pulse_stats_set_gauge / pulse_stats_get_gauge round-trip integer values
#      against an isolated PULSE_STATS_FILE; non-numeric set is rejected.
#   6. pulse_merge_zero_progress_record:
#        merged>0 → gauge reset to 0
#        merged=0 + eligible=0 → gauge reset to 0 (streak broken)
#        merged=0 + eligible>0 → gauge incremented by 1
#   7. _pms_count_eligible_unmerged_for_repo excludes PRs blocked by
#      read-only merge gates (required checks, interactive PRs held for manual
#      merge, worker PR with no linked issue, non-collaborator author without
#      maintainer crypto-approval, and unknown authors that must not bypass the
#      collaborator check) and keeps processing when GitHub returns a null PR
#      author for deleted users.
#   8. _detect_pattern_outage de-duplicates repeated PR observations.
#   9. pulse-merge-stuck.sh and pulse-stats-helper.sh pass shellcheck.
#
# The test never makes real network calls; functions that require gh API
# (_classify_stuck_pr, _escalate_individual_stuck_pr, full pulse_merge_stuck_run_pass)
# are intentionally not exercised here —
# they're integration-level and would need a live fixture repo.

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected: $(printf '%q' "$expected")"
		echo "  actual:   $(printf '%q' "$actual")"
	fi
	return 0
}

assert_match() {
	local label="$1" regex="$2" value="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$value" =~ $regex ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  regex: $regex"
		echo "  value: $(printf '%q' "$value")"
	fi
	return 0
}

assert_gt() {
	local label="$1" lhs="$2" rhs="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$lhs" =~ ^[0-9]+$ && "$rhs" =~ ^[0-9]+$ && "$lhs" -gt "$rhs" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label ($lhs > $rhs ?)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Setup: locate files, isolate PULSE_STATS_FILE, source the modules.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$SCRIPT_DIR/pulse-merge-stuck.sh"
STATS_HELPER="$SCRIPT_DIR/pulse-stats-helper.sh"
MERGE_SCRIPT="$SCRIPT_DIR/pulse-merge.sh"
CONF_FILE="$SCRIPT_DIR/../configs/pulse-merge-stuck.conf"

for required in "$MODULE" "$STATS_HELPER" "$MERGE_SCRIPT"; do
	if [[ ! -f "$required" ]]; then
		echo "${TEST_RED}FATAL${TEST_NC}: $required not found"
		exit 1
	fi
done

# Isolate state writes to a temp file so the live ~/.aidevops/logs/pulse-stats.json
# is not perturbed. Cleanup on exit.
TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/test-pulse-merge-stuck-XXXXXX")
trap 'rm -rf "$TEST_TMPDIR"' EXIT
export PULSE_STATS_FILE="$TEST_TMPDIR/pulse-stats.json"
export LOGFILE="$TEST_TMPDIR/pulse.log"

# Source the helpers. pulse-stats-helper.sh sets -euo pipefail; turn that off
# after source so a single failed assertion doesn't abort the whole suite.
# shellcheck source=/dev/null
source "$MODULE"
set +e
set +o pipefail

echo "${TEST_BLUE}=== t3193: pulse-merge-stuck detector tests ===${TEST_NC}"
echo ""

# ---------------------------------------------------------------------------
# Section 1: conf file integrity.
# ---------------------------------------------------------------------------
echo "--- Section 1: conf file integrity ---"

TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$CONF_FILE" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1a: pulse-merge-stuck.conf exists"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1a: pulse-merge-stuck.conf NOT found at $CONF_FILE"
fi

for entry in \
	AIDEVOPS_MERGE_STUCK_AGE_MINUTES \
	AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES \
	AIDEVOPS_MERGE_PATTERN_MIN_PRS \
	AIDEVOPS_MERGE_STUCK_ENABLED; do
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qE "^${entry}=" "$CONF_FILE" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: 1: conf contains ${entry}"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 1: conf missing ${entry}"
	fi
done
echo ""

# ---------------------------------------------------------------------------
# Section 2: defaults applied as positive integers after sourcing.
# ---------------------------------------------------------------------------
echo "--- Section 2: post-source defaults ---"

assert_match "2a: AIDEVOPS_MERGE_STUCK_AGE_MINUTES is positive int" \
	"^[0-9]+$" "${AIDEVOPS_MERGE_STUCK_AGE_MINUTES:-x}"
assert_match "2b: AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES is positive int" \
	"^[0-9]+$" "${AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES:-x}"
assert_match "2c: AIDEVOPS_MERGE_PATTERN_MIN_PRS is positive int" \
	"^[0-9]+$" "${AIDEVOPS_MERGE_PATTERN_MIN_PRS:-x}"
assert_match "2d: AIDEVOPS_MERGE_STUCK_ENABLED is 0|1" \
	"^[01]$" "${AIDEVOPS_MERGE_STUCK_ENABLED:-x}"

assert_gt "2e: STUCK_AGE_MINUTES > 0" "$AIDEVOPS_MERGE_STUCK_AGE_MINUTES" "0"
assert_gt "2f: ZERO_PROGRESS_CYCLES > 0" "$AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES" "0"
assert_gt "2g: PATTERN_MIN_PRS > 1" "$AIDEVOPS_MERGE_PATTERN_MIN_PRS" "1"
echo ""

# ---------------------------------------------------------------------------
# Section 3: pure-logic helpers.
# ---------------------------------------------------------------------------
echo "--- Section 3: _pms_iso_to_epoch + _pms_hash_fingerprint ---"

# 3a: ISO timestamp → positive epoch
epoch=$(_pms_iso_to_epoch "2026-04-30T14:00:00Z")
assert_gt "3a: valid ISO 2026-04-30T14:00:00Z → epoch > 0" "$epoch" "0"

# 3b: garbage → 0
garbage_epoch=$(_pms_iso_to_epoch "not-a-date")
assert_eq "3b: garbage input → 0" "0" "$garbage_epoch"

# 3c: hash returns 16 hex chars
hash_out=$(_pms_hash_fingerprint "Format,Lint,Typecheck")
assert_match "3c: hash is 16 hex chars" "^[0-9a-f]{16}$" "$hash_out"

# 3d: hash deterministic
hash_a=$(_pms_hash_fingerprint "stable-input")
hash_b=$(_pms_hash_fingerprint "stable-input")
assert_eq "3d: hash deterministic for same input" "$hash_a" "$hash_b"

# 3e: hash differs for different input (collision check, not cryptographic)
hash_x=$(_pms_hash_fingerprint "input-one")
hash_y=$(_pms_hash_fingerprint "input-two")
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$hash_x" != "$hash_y" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 3e: hash differs across distinct inputs"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 3e: hash collision on trivially distinct inputs ($hash_x)"
fi

# 3f: empty input still produces 16 hex chars
hash_empty=$(_pms_hash_fingerprint "")
assert_match "3f: hash of empty string is 16 hex chars" "^[0-9a-f]{16}$" "$hash_empty"
echo ""

# ---------------------------------------------------------------------------
# Section 4: pulse_stats_set_gauge / pulse_stats_get_gauge round-trip.
# ---------------------------------------------------------------------------
echo "--- Section 4: gauge round-trip ---"

# 4a: get on missing file returns "0"
rm -f "$PULSE_STATS_FILE"
got=$(pulse_stats_get_gauge "test_gauge_a")
assert_eq "4a: get on missing file → 0" "0" "$got"

# 4b: set then get round-trip
pulse_stats_set_gauge "test_gauge_a" "7" >/dev/null 2>&1
got=$(pulse_stats_get_gauge "test_gauge_a")
assert_eq "4b: set 7 → get 7" "7" "$got"

# 4c: overwrite
pulse_stats_set_gauge "test_gauge_a" "42" >/dev/null 2>&1
got=$(pulse_stats_get_gauge "test_gauge_a")
assert_eq "4c: overwrite to 42 → get 42" "42" "$got"

# 4d: non-numeric is rejected (silently — gauge stays at prior value)
pulse_stats_set_gauge "test_gauge_a" "not-a-number" >/dev/null 2>&1
got=$(pulse_stats_get_gauge "test_gauge_a")
assert_eq "4d: non-numeric set ignored, prior value retained" "42" "$got"

# 4e: distinct gauges don't collide
pulse_stats_set_gauge "test_gauge_b" "99" >/dev/null 2>&1
got_a=$(pulse_stats_get_gauge "test_gauge_a")
got_b=$(pulse_stats_get_gauge "test_gauge_b")
assert_eq "4e: gauge_a unaffected by gauge_b write" "42" "$got_a"
assert_eq "4e: gauge_b reads back" "99" "$got_b"
echo ""

# ---------------------------------------------------------------------------
# Section 5: pulse_merge_zero_progress_record state transitions.
# ---------------------------------------------------------------------------
echo "--- Section 5: zero_progress_record transitions ---"

GH_CALLS="$TEST_TMPDIR/gh-calls.log"
: >"$GH_CALLS"
PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE=""
export GH_CALLS PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE

gh() {
	local command_name="$1"
	local subcommand="$2"
	if [[ "$command_name" == "issue" && "$subcommand" == "list" ]]; then
		if [[ -n "${PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE:-}" ]]; then
			printf '%s\n' "$PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE"
		fi
		return 0
	fi
	if [[ "$command_name" == "issue" && ( "$subcommand" == "comment" || "$subcommand" == "close" ) ]]; then
		printf '%s\n' "gh $*" >>"$GH_CALLS"
		return 0
	fi
	return 1
}

# Reset gauge for a clean state.
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "0" >/dev/null 2>&1

# 5a: merged>0 + eligible=anything → gauge reset to 0
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "3" >/dev/null 2>&1
pulse_merge_zero_progress_record 5 1 >/dev/null 2>&1
got=$(pulse_stats_get_gauge "pulse_merge_zero_progress_cycles")
assert_eq "5a: merged>0 resets cycles to 0 (was 3)" "0" "$got"

# 5b: merged=0 + eligible=0 → gauge reset to 0 (idle cycle breaks streak)
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "2" >/dev/null 2>&1
pulse_merge_zero_progress_record 0 0 >/dev/null 2>&1
got=$(pulse_stats_get_gauge "pulse_merge_zero_progress_cycles")
assert_eq "5b: merged=0 + eligible=0 resets cycles to 0 (was 2)" "0" "$got"

# 5c: merged=0 + eligible>0 → gauge increments by 1
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "0" >/dev/null 2>&1
pulse_merge_zero_progress_record 4 0 >/dev/null 2>&1
got=$(pulse_stats_get_gauge "pulse_merge_zero_progress_cycles")
assert_eq "5c: merged=0 + eligible=4 → cycles 0→1" "1" "$got"

# 5d: a second consecutive zero-progress cycle increments again.
pulse_merge_zero_progress_record 4 0 >/dev/null 2>&1
got=$(pulse_stats_get_gauge "pulse_merge_zero_progress_cycles")
assert_eq "5d: second consecutive zero-progress → 1→2" "2" "$got"

# 5e: a successful merge then resets the streak to 0.
PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE="23035"
pulse_merge_zero_progress_record 4 1 >/dev/null 2>&1
got=$(pulse_stats_get_gauge "pulse_merge_zero_progress_cycles")
assert_eq "5e: merge during stuck-streak resets cycles to 0" "0" "$got"
if grep -q 'gh issue close 23035 --repo marcusquinn/aidevops --reason completed' "$GH_CALLS"; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 5f: recovered zero-progress meta-issue is auto-closed"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 5f: recovered zero-progress meta-issue is auto-closed"
	echo "  gh calls: $(cat "$GH_CALLS")"
fi
TESTS_RUN=$((TESTS_RUN + 1))
PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE=""
echo ""

# ---------------------------------------------------------------------------
# Section 6: zero-progress eligible count gate parity.
# ---------------------------------------------------------------------------
echo "--- Section 6: zero-progress count gate parity ---"

gh() {
	local command_name="${1:-}"
	local subcommand="${2:-}"
	if [[ "$command_name" == "pr" && "$subcommand" == "list" ]]; then
		printf '%s\n' '[
{"number":101,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"author":{"login":"trusted"}},
{"number":102,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[{"name":"origin:worker"}],"author":{"login":"trusted"}},
{"number":103,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[{"name":"origin:worker"}],"author":{"login":"trusted"}},
{"number":104,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[{"name":"hold-for-review"}],"author":{"login":"trusted"}},
{"number":105,"mergeable":"MERGEABLE","reviewDecision":"CHANGES_REQUESTED","isDraft":false,"labels":[],"author":{"login":"trusted"}},
{"number":106,"mergeable":"CONFLICTING","reviewDecision":"APPROVED","isDraft":false,"labels":[],"author":{"login":"trusted"}},
{"number":107,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"author":{"login":"external"}},
{"number":108,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"author":{"login":"trusted"}},
{"number":109,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"author":null},
{"number":110,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":null,"author":{"login":"external"}},
{"number":111,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[{"name":"origin:interactive"}],"author":{"login":"trusted"}},
{"number":112,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[{"name":"origin:interactive"},{"name":"allow-auto-merge"}],"author":{"login":"trusted"}}
]'
		return 0
	fi
	return 1
}

_check_required_checks_passing() {
	local repo_slug="$1"
	local pr_number="$2"
	[[ -n "$repo_slug" ]] || return 1
	case "$pr_number" in
	101) return 1 ;;
	*) return 0 ;;
	esac
}

_extract_linked_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	[[ -n "$repo_slug" ]] || return 1
	case "$pr_number" in
	102) return 0 ;;
	*) printf '77'; return 0 ;;
	esac
}

_is_collaborator_author() {
	local pr_author="$1"
	local repo_slug="$2"
	[[ -n "$repo_slug" ]] || return 1
	if [[ "$pr_author" == "trusted" ]]; then
		return 0
	fi
	return 1
}

_has_maintainer_crypto_approval() {
	local pr_number="$1"
	local repo_slug="$2"
	[[ -n "$pr_number" && -n "$repo_slug" ]] || return 1
	return 1
}

_interactive_pr_auto_merge_allowed() {
	local pr_number="$1"
	local repo_slug="$2"
	local labels_str="$3"
	[[ -n "$pr_number" && -n "$repo_slug" ]] || return 1
	if [[ ",${labels_str}," == *",allow-auto-merge,"* ]]; then
		return 0
	fi
	return 1
}

got=$(_pms_count_eligible_unmerged_for_repo "example/repo")
assert_eq "6a: zero-progress count excludes read-only merge-gate blockers" "3" "$got"

PMS_TEST_COUNT_AUTHORS_FILE="$TEST_TMPDIR/count-authors.log"
: >"$PMS_TEST_COUNT_AUTHORS_FILE"
_pms_pr_counts_for_zero_progress() {
	local repo_slug="$1"
	local pr_number="$2"
	local labels_str="$3"
	local pr_author="$4"
	: "$labels_str"
	[[ -n "$repo_slug" && -n "$pr_number" ]] || return 1
	printf '%s:%s\n' "$pr_number" "$pr_author" >>"$PMS_TEST_COUNT_AUTHORS_FILE"
	return 0
}

gh() {
	local command_name="${1:-}"
	local subcommand="${2:-}"
	if [[ "$command_name" == "pr" && "$subcommand" == "list" ]]; then
		printf '%s\n' '[
{"number":109,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"author":null}
]'
		return 0
	fi
	return 1
}

got=$(_pms_count_eligible_unmerged_for_repo "example/repo")
count_authors=$(<"$PMS_TEST_COUNT_AUTHORS_FILE")
assert_eq "6b: null author does not abort zero-progress candidate parsing" "1" "$got"
assert_eq "6c: null author falls back to unknown" "109:unknown" "$count_authors"
echo ""

# GH#24383: GitHub can return "Merge already in progress" for a PR that a
# previous pulse cycle has already submitted for server-side merge. That is
# progress, not a deterministic merge failure; otherwise the zero-progress
# detector can file false collapse issues while GitHub is completing the merge.
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "Merge already in progress" "$MERGE_SCRIPT" \
	&& grep -Fq "_handle_post_merge_actions \"\$pr_number\" \"\$repo_slug\" \"\$linked_issue\" \"\$merge_summary\" \"\$_ipr_labels\"" "$MERGE_SCRIPT" \
	&& grep -Fq "return \$?" "$MERGE_SCRIPT"; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 6d: merge-in-progress is counted as zero-progress-breaking progress"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 6d: merge-in-progress progress accounting is missing"
fi
echo ""

# ---------------------------------------------------------------------------
# Section 7: REST check-run classification helpers.
# ---------------------------------------------------------------------------
echo "--- Section 7: REST check-run classification helpers ---"

gh_pr_view() {
	local pr_number="$1"
	local repo_flag="$2"
	local repo_slug="$3"
	: "$repo_flag"
	[[ -n "$repo_slug" ]] || return 1
	case "$pr_number" in
	201) printf '{"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha-queued"}' ;;
	202) printf '{"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha-failing"}' ;;
	203) printf 'sha-failing' ;;
	204) printf '{"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha-legacy-failing"}' ;;
	205) printf 'sha-legacy-failing' ;;
	206) printf '{"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha-legacy-error"}' ;;
	207) printf 'sha-legacy-error' ;;
	*) printf '{"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha-clean"}' ;;
	esac
	return 0
}

gh_pr_check_runs_rest() {
	local repo_slug="$1"
	local head_sha="$2"
	[[ -n "$repo_slug" ]] || return 1
	case "$head_sha" in
	sha-queued) printf '[{"name":"Build","conclusion":null,"status":"queued"}]' ;;
	sha-failing) printf '[{"name":"Format","conclusion":"failure","status":"completed"},{"name":"Lint","conclusion":"timed_out","status":"completed"}]' ;;
	sha-legacy-failing) printf '[{"context":"legacy-ci","state":"failure"}]' ;;
	sha-legacy-error) printf '[{"context":"legacy-error","state":"error"}]' ;;
	*) printf '[]' ;;
	esac
	return 0
}

gh() {
	local command_name="${1:-}"
	local path_arg="${2:-}"
	if [[ "$command_name" == "api" && "$path_arg" == "repos/example/repo" ]]; then
		printf 'main'
		return 0
	fi
	if [[ "$command_name" == "api" && "$path_arg" == "repos/example/repo/branches/main/protection/required_status_checks" ]]; then
		printf '{}'
		return 0
	fi
	return 1
}

got=$(_classify_stuck_pr "201" "example/repo" "1")
assert_eq "7a: saturated queued check classifies as runner saturation" \
	"STUCK_RUNNER_QUEUE_SATURATION" "$got"

got=$(_classify_stuck_pr "202" "example/repo" "0")
assert_eq "7b: REST check-run failure classifies as checks failing" \
	"STUCK_CHECKS_FAILING" "$got"

got=$(_pms_failure_fingerprint "203" "example/repo")
assert_eq "7c: failure fingerprint comes from REST check-runs" \
	"Format,Lint" "$got"

got=$(_classify_stuck_pr "204" "example/repo" "0")
assert_eq "7d: legacy status context state=failure classifies as checks failing" \
	"STUCK_CHECKS_FAILING" "$got"

got=$(_pms_failure_fingerprint "205" "example/repo")
assert_eq "7e: legacy status context fingerprint uses context name" \
	"legacy-ci" "$got"

got=$(_classify_stuck_pr "206" "example/repo" "0")
assert_eq "7f: legacy status context state=error classifies as checks failing" \
	"STUCK_CHECKS_FAILING" "$got"

got=$(_pms_failure_fingerprint "207" "example/repo")
assert_eq "7g: legacy error status context fingerprint uses context name" \
	"legacy-error" "$got"
echo ""

# ---------------------------------------------------------------------------
# Section 8: pattern outage deduplication.
# ---------------------------------------------------------------------------
echo "--- Section 8: pattern outage deduplication ---"

_pms_failure_fingerprint() {
	local pr_number="$1"
	local repo_slug="$2"
	[[ -n "$repo_slug" ]] || return 1
	case "$pr_number" in
	11 | 12) printf 'E2E Shard 1/4,E2E Shard 2/4' ;;
	*) printf '' ;;
	esac
	return 0
}

PMS_TEST_OUTAGE_ARGS=""
_pms_file_outage_issue() {
	local repo_slug="$1"
	local count="$2"
	local fingerprint="$3"
	local prs="$4"
	PMS_TEST_OUTAGE_ARGS="${repo_slug}|${count}|${fingerprint}|${prs}"
	return 0
}

AIDEVOPS_MERGE_PATTERN_MIN_PRS=2
_detect_pattern_outage "example/repo" $'11\n11\n12\n'
assert_eq "7a: duplicate PR observations counted once" \
	"example/repo|2|E2E Shard 1/4,E2E Shard 2/4|11,12" \
	"$PMS_TEST_OUTAGE_ARGS"
echo ""

# ---------------------------------------------------------------------------
# Section 9: default branch guidance.
# ---------------------------------------------------------------------------
echo "--- Section 9: default branch guidance ---"

gh() {
	local command_name="${1:-}"
	local path_arg="${2:-}"
	if [[ "$command_name" == "api" && "$path_arg" == "repos/example/repo" ]]; then
		printf 'develop'
		return 0
	fi
	return 1
}

got=$(_pms_default_branch "example/repo")
assert_eq "8a: default branch resolves from repo API" "develop" "$got"
echo ""

# ---------------------------------------------------------------------------
# Section 10: shellcheck cleanliness.
# ---------------------------------------------------------------------------
echo "--- Section 10: shellcheck ---"

run_shellcheck() {
	local label="$1" file="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if ! command -v shellcheck >/dev/null 2>&1; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label (shellcheck not installed — skipping)"
		return 0
	fi
	local sc_out sc_rc
	sc_out=$(shellcheck "$file" 2>&1)
	sc_rc=$?
	if [[ $sc_rc -eq 0 ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "$sc_out"
	fi
	return 0
}

run_shellcheck "9a: pulse-merge-stuck.sh passes shellcheck" "$MODULE"
run_shellcheck "9b: pulse-stats-helper.sh passes shellcheck" "$STATS_HELPER"
echo ""

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failures ===${TEST_NC}"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
