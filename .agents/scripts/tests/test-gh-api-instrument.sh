#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Smoke test for t2902 / GH#21043: gh-api-instrument.sh records gh API call
# partitioning and aggregates to JSON correctly. Also verifies the wrapper
# integration: sourcing shared-gh-wrappers.sh defines gh_record_call.
# =============================================================================
#
# Background: t2902 added per-call-site instrumentation to identify the
# heavy GraphQL consumers that were draining the budget despite t2574 +
# t2689 REST fallbacks. The recorder must be:
#   (a) cheap (one append per call, fail-open if log path is unwritable),
#   (b) deterministic in aggregation (sorted keys, stable schema),
#   (c) reachable from every gh wrapper site (sourced from
#       shared-gh-wrappers.sh after the rest-fallback include).
#
# This test exercises all three.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
PARENT_DIR="${SCRIPT_DIR}/.."

PASS=0
FAIL=0

# Use a per-test temp dir so we don't pollute the host's instrumentation log.
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export AIDEVOPS_GH_API_LOG="$TMPDIR/gh-api-calls.log"
export AIDEVOPS_GH_API_REPORT="$TMPDIR/report.json"

assert_eq() {
	local label="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		echo "  PASS: $label"
		PASS=$((PASS + 1))
		return 0
	fi
	echo "  FAIL: $label"
	echo "    expected: $expected"
	echo "    actual:   $actual"
	FAIL=$((FAIL + 1))
	return 1
}

assert_file_exists() {
	local label="$1"
	local path="$2"
	if [[ -f "$path" ]]; then
		echo "  PASS: $label"
		PASS=$((PASS + 1))
		return 0
	fi
	echo "  FAIL: $label (missing: $path)"
	FAIL=$((FAIL + 1))
	return 1
}

echo "Test: gh-api-instrument.sh recording and aggregation"
echo "===================================================="
echo ""

# --- Test 1: source instrumentation directly and record a few calls ----
# shellcheck source=../gh-api-instrument.sh
source "${PARENT_DIR}/gh-api-instrument.sh"

gh_record_call rest test-instrument
gh_record_call graphql test-instrument
gh_record_call search-graphql test-instrument
gh_record_call search-rest test-instrument
gh_record_call rest test-instrument
gh_record_call rest test-instrument github-app rest-core rest-preferred 4999

assert_file_exists "log file created" "$AIDEVOPS_GH_API_LOG"

line_count=$(wc -l <"$AIDEVOPS_GH_API_LOG" | tr -d ' ')
assert_eq "log has 6 lines" "6" "$line_count"

# --- Test 2: aggregate and validate JSON shape -------------------------
gh_aggregate_calls

assert_file_exists "report file created" "$AIDEVOPS_GH_API_REPORT"

if ! jq -e '.' "$AIDEVOPS_GH_API_REPORT" >/dev/null 2>&1; then
	echo "  FAIL: report is not valid JSON"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: report is valid JSON"
	PASS=$((PASS + 1))
fi

total_calls=$(jq -r '._meta.total_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "report total_calls = 6" "6" "$total_calls"

rest_count=$(jq -r '.by_caller["test-instrument"].rest_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "rest_calls = 3" "3" "$rest_count"

graphql_count=$(jq -r '.by_caller["test-instrument"].graphql_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "graphql_calls = 1" "1" "$graphql_count"

search_graphql_count=$(jq -r '.by_caller["test-instrument"].search_graphql_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "search_graphql_calls = 1" "1" "$search_graphql_count"

search_rest_count=$(jq -r '.by_caller["test-instrument"].search_rest_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "search_rest_calls = 1" "1" "$search_rest_count"

app_auth_count=$(jq -r '.by_auth_mode["github-app"].total' "$AIDEVOPS_GH_API_REPORT")
assert_eq "github-app auth count = 1" "1" "$app_auth_count"

rest_core_count=$(jq -r '.by_api_pool["rest-core"].total' "$AIDEVOPS_GH_API_REPORT")
assert_eq "rest-core pool count = 3" "3" "$rest_core_count"

budget_min=$(jq -r '.budget_by_pool["rest-core"].min_remaining' "$AIDEVOPS_GH_API_REPORT")
assert_eq "rest-core budget min recorded" "4999" "$budget_min"

# --- Test 3: trim respects max-lines threshold ------------------------
# Set a tiny max so we trigger a trim with our 6-line log.
export AIDEVOPS_GH_API_LOG_MAX_LINES=4
# Re-source so the env override is picked up by the GH_API_LOG_MAX_LINES
# constant (it's evaluated at source time).
unset _GH_API_INSTRUMENT_LOADED
# shellcheck source=../gh-api-instrument.sh
source "${PARENT_DIR}/gh-api-instrument.sh"
gh_trim_log
trimmed_count=$(wc -l <"$AIDEVOPS_GH_API_LOG" | tr -d ' ')
# After trim, should retain max/2 = 2 lines.
assert_eq "trim retained max/2 lines" "2" "$trimmed_count"

# --- Test 4: clear wipes both log and report --------------------------
gh_clear_log
if [[ -f "$AIDEVOPS_GH_API_LOG" ]]; then
	echo "  FAIL: clear left log behind: $AIDEVOPS_GH_API_LOG"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: clear removed log"
	PASS=$((PASS + 1))
fi
if [[ -f "$AIDEVOPS_GH_API_REPORT" ]]; then
	echo "  FAIL: clear left report behind: $AIDEVOPS_GH_API_REPORT"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: clear removed report"
	PASS=$((PASS + 1))
fi

# --- Test 5: integration via shared-gh-wrappers.sh ---------------------
# Sourcing the wrapper must make gh_record_call available — that's the
# integration path the REST translators rely on.
unset _SHARED_GH_WRAPPERS_LOADED _SHARED_GH_WRAPPERS_REST_FALLBACK_LOADED _GH_API_INSTRUMENT_LOADED
# shellcheck source=../shared-gh-wrappers.sh
source "${PARENT_DIR}/shared-gh-wrappers.sh"

if type -t gh_record_call >/dev/null 2>&1; then
	echo "  PASS: gh_record_call defined after sourcing shared-gh-wrappers.sh"
	PASS=$((PASS + 1))
else
	echo "  FAIL: gh_record_call NOT defined after sourcing shared-gh-wrappers.sh"
	FAIL=$((FAIL + 1))
fi

# --- Test 6: disable env var makes record a no-op ---------------------
gh_clear_log
AIDEVOPS_GH_API_INSTRUMENT_DISABLE=1 gh_record_call rest test-disabled
if [[ -f "$AIDEVOPS_GH_API_LOG" ]]; then
	echo "  FAIL: disabled record still wrote log"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: disabled record is a no-op"
	PASS=$((PASS + 1))
fi

# --- Test 7: explicit call-site names partition coarse callers ----------
unset AIDEVOPS_GH_API_INSTRUMENT_DISABLE
gh_clear_log
gh_record_call rest pulse_batch_prefetch_rate_limit
gh_record_call search-graphql pulse_batch_prefetch_search_issues
gh_record_call search-graphql pulse_batch_prefetch_search_prs
gh_record_call rest events_tickle_events
gh_aggregate_calls

rate_limit_count=$(jq -r '.by_caller["pulse_batch_prefetch_rate_limit"].rest_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "explicit caller: rate-limit REST call counted separately" "1" "$rate_limit_count"

search_issue_count=$(jq -r '.by_caller["pulse_batch_prefetch_search_issues"].search_graphql_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "explicit caller: issue search counted separately" "1" "$search_issue_count"

search_pr_count=$(jq -r '.by_caller["pulse_batch_prefetch_search_prs"].search_graphql_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "explicit caller: PR search counted separately" "1" "$search_pr_count"

tickle_count=$(jq -r '.by_caller["events_tickle_events"].rest_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "explicit caller: events tickle REST call counted separately" "1" "$tickle_count"

# --- Test 8: HOME-less temp fallback is owned and private -------------
unset _GH_API_INSTRUMENT_LOADED AIDEVOPS_GH_API_LOG AIDEVOPS_GH_API_REPORT
FAKE_BIN="$TMPDIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/getent" <<'EOF_GETENT'
#!/usr/bin/env bash
exit 2
EOF_GETENT
chmod +x "$FAKE_BIN/getent"
FALLBACK_TMP="$TMPDIR/fallback-root"
set +e
PATH="$FAKE_BIN:$PATH" HOME='' TMPDIR="$FALLBACK_TMP" USER="ghapitest" bash -c '
	set -euo pipefail
	# shellcheck source=../gh-api-instrument.sh
	source "$1"
	gh_record_call rest fallback-test
	mode=$(stat -f %Lp "$TMPDIR/aidevops-$USER" 2>/dev/null || stat -c %a "$TMPDIR/aidevops-$USER")
	[[ "$mode" == "700" ]]
	[[ -f "$TMPDIR/aidevops-$USER/.aidevops/logs/gh-api-calls.log" ]]
' _ "${PARENT_DIR}/gh-api-instrument.sh"
fallback_status="$?"
set -e
assert_eq "HOME-less temp fallback is private" "0" "$fallback_status"

# --- Test 9: HOME-less temp fallback rejects pre-created symlink ------
unset _GH_API_INSTRUMENT_LOADED AIDEVOPS_GH_API_LOG AIDEVOPS_GH_API_REPORT
SYMLINK_TMP="$TMPDIR/symlink-root"
SYMLINK_TARGET="$TMPDIR/symlink-target"
mkdir -p "$SYMLINK_TMP" "$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$SYMLINK_TMP/aidevops-ghapitest"
set +e
PATH="$FAKE_BIN:$PATH" HOME='' TMPDIR="$SYMLINK_TMP" USER="ghapitest" bash -c '
	set -euo pipefail
	# shellcheck source=../gh-api-instrument.sh
	source "$1"
	gh_record_call rest symlink-fallback-test
	[[ "${AIDEVOPS_GH_API_INSTRUMENT_DISABLE:-0}" == "1" ]]
	[[ ! -e "$TMPDIR/aidevops-$USER/.aidevops/logs/gh-api-calls.log" ]]
' _ "${PARENT_DIR}/gh-api-instrument.sh"
symlink_status="$?"
set -e
assert_eq "HOME-less temp fallback rejects symlink" "0" "$symlink_status"

# Restore per-test overrides for summary diagnostics if future tests append.
export AIDEVOPS_GH_API_LOG="$TMPDIR/gh-api-calls.log"
export AIDEVOPS_GH_API_REPORT="$TMPDIR/report.json"

# --- Summary ----------------------------------------------------------
echo ""
echo "===================================================="
echo "Result: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
