#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Regression test for t2902 / GH#21043 / GH#27769: logical gh events and real
# transport attempts remain separately replayable, bounded, privacy-safe, and
# backward-compatible with legacy records.
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
# Bounded retention keeps at most the configured maximum.
assert_eq "trim retained max lines" "4" "$trimmed_count"

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

# --- Test 10: exact replay separates events, attempts, pages, and retries --
unset _GH_API_INSTRUMENT_LOADED
# shellcheck source=../gh-api-instrument.sh
source "${PARENT_DIR}/gh-api-instrument.sh"
gh_clear_log

AIDEVOPS_GH_LOGICAL_ID=logical-replay gh_record_call rest replay-caller github-app rest-core rest-selected 4998
gh_record_attempt rest replay-caller logical-replay attempt-rest-1 1 0 success 200 120 1 github-app rest-core rest-selected 4998
gh_record_attempt rest replay-caller logical-replay attempt-rest-2 2 0 success 200 80 1 github-app rest-core rest-selected 4997
gh_record_attempt graphql replay-caller logical-replay attempt-graphql-1 1 1 error 403 40 1 gh-pat graphql rest-fallback-graphql 0
AIDEVOPS_GH_LOGICAL_ID=logical-cache gh_record_call other replay-cache unknown other hit ""
now=$(date +%s)
printf '%s\tlegacy-caller\trest\tgh-pat\trest-core\tlegacy-route\t4996\n' "$now" >>"$AIDEVOPS_GH_API_LOG"
# Duplicate IDs are rejected from replay totals and surfaced in metadata.
gh_record_attempt rest replay-caller logical-replay attempt-rest-2 2 0 success 200 80 1 github-app rest-core rest-selected 4997
printf 'malformed legacy row\n' >>"$AIDEVOPS_GH_API_LOG"
gh_aggregate_calls

assert_eq "schema version = 2" "2" "$(jq -r '._meta.schema_version' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "attempt replay excludes duplicate ID" "3" "$(jq -r '._meta.attempted_requests' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "logical routing events remain separate" "1" "$(jq -r '._meta.logical_events' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "cache-only decision has zero attempts" "0" "$(jq -r '.by_caller["replay-cache"].attempted_requests' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "cache event counted separately" "1" "$(jq -r '._meta.cache_events' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "legacy row remains a logical observation" "1" "$(jq -r '._meta.legacy_events' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "one retry linked to logical operation" "1" "$(jq -r '._meta.retries' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "three explicit request pages" "3" "$(jq -r '._meta.pages' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "one additional page" "1" "$(jq -r '._meta.additional_pages' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "quota replay sum" "3" "$(jq -r '._meta.known_quota_cost' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "elapsed replay sum" "240" "$(jq -r '._meta.elapsed_ms' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "REST attempts grouped by path" "2" "$(jq -r '.by_path.rest.attempted_requests' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "attempts grouped by auth pool" "2" "$(jq -r '.by_api_pool["rest-core"].attempted_requests' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "duplicate attempt ID surfaced" "1" "$(jq -r '._meta.duplicate_attempt_ids' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "duplicate makes exactness false" "false" "$(jq -r '._meta.attempts_exact' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "malformed row surfaced" "1" "$(jq -r '._meta.malformed_records' "$AIDEVOPS_GH_API_REPORT")"

# --- Test 11: command arguments remain private and exit status is preserved --
gh_clear_log
gh_run_transport_attempt rest privacy-caller logical-private 1 0 -- true \
	'https://example.invalid/private?token=do-not-log' 'Authorization: bearer do-not-log' '--body=private-payload'
set +e
gh_run_transport_attempt graphql privacy-caller logical-private 1 1 -- false
transport_status=$?
set -e
assert_eq "transport failure status preserved" "1" "$transport_status"
if grep -Eq 'do-not-log|private-payload|Authorization|example\.invalid' "$AIDEVOPS_GH_API_LOG"; then
	echo "  FAIL: transport telemetry exposed command arguments"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: transport telemetry excludes command arguments"
	PASS=$((PASS + 1))
fi
gh_aggregate_calls
assert_eq "success and failure attempts recorded" "2" "$(jq -r '._meta.attempted_requests' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "failed outcome recorded" "1" "$(jq -r '._meta.failed_attempts' "$AIDEVOPS_GH_API_REPORT")"

# --- Test 12: effective window comes from retained attempt timestamps -----
gh_clear_log
first_ts=$((now - 30))
last_ts=$((now - 10))
printf '%s\twindow-caller\trest\tgh-pat\trest-core\trest-selected\t4999\tv2\tattempt\tlogical-window\tattempt-window-1\t1\t0\tsuccess\t200\t10\t1\n' "$first_ts" >>"$AIDEVOPS_GH_API_LOG"
printf '%s\twindow-caller\trest\tgh-pat\trest-core\trest-selected\t4998\tv2\tattempt\tlogical-window\tattempt-window-2\t2\t0\tsuccess\t200\t20\t1\n' "$last_ts" >>"$AIDEVOPS_GH_API_LOG"
gh_aggregate_calls "$AIDEVOPS_GH_API_REPORT" 3600
assert_eq "requested window retained separately" "3600" "$(jq -r '._meta.requested_window_seconds' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "first retained attempt timestamp" "$first_ts" "$(jq -r '._meta.first_retained_ts' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "last retained attempt timestamp" "$last_ts" "$(jq -r '._meta.last_retained_ts' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "effective window uses observed range" "20" "$(jq -r '._meta.effective_window_seconds' "$AIDEVOPS_GH_API_REPORT")"

# --- Test 13: time/line/byte retention is atomic and bounded -------------
export AIDEVOPS_GH_API_LOG_MAX_LINES=3
export AIDEVOPS_GH_API_LOG_MAX_BYTES=10000
export AIDEVOPS_GH_API_RETENTION_SECONDS=100
unset _GH_API_INSTRUMENT_LOADED
# shellcheck source=../gh-api-instrument.sh
source "${PARENT_DIR}/gh-api-instrument.sh"
gh_clear_log
printf '1\told-caller\trest\n' >>"$AIDEVOPS_GH_API_LOG"
for fixture_index in 1 2 3 4; do
	fixture_ts=$((now - 5 + fixture_index))
	printf '%s\tretained-%s\trest\tgh-pat\trest-core\trest-selected\t\tv2\tlogical\tlogical-retained-%s\t\t\t\t\t\t\t\n' \
		"$fixture_ts" "$fixture_index" "$fixture_index" >>"$AIDEVOPS_GH_API_LOG"
done
gh_trim_log
assert_eq "retention applies maximum line count" "3" "$(wc -l <"$AIDEVOPS_GH_API_LOG" | tr -d ' ')"
if grep -q 'old-caller' "$AIDEVOPS_GH_API_LOG"; then
	echo "  FAIL: time retention kept expired record"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: time retention removed expired record"
	PASS=$((PASS + 1))
fi

export AIDEVOPS_GH_API_LOG_MAX_LINES=100
export AIDEVOPS_GH_API_LOG_MAX_BYTES=220
unset _GH_API_INSTRUMENT_LOADED
# shellcheck source=../gh-api-instrument.sh
source "${PARENT_DIR}/gh-api-instrument.sh"
gh_clear_log
for fixture_index in 1 2 3 4 5; do
	gh_record_call rest "byte-retention-${fixture_index}"
done
gh_trim_log
retained_bytes=$(wc -c <"$AIDEVOPS_GH_API_LOG" | tr -d ' ')
if [[ "$retained_bytes" -le 220 ]]; then
	echo "  PASS: byte retention stayed within bound"
	PASS=$((PASS + 1))
else
	echo "  FAIL: byte retention exceeded bound ($retained_bytes > 220)"
	FAIL=$((FAIL + 1))
fi

# --- Test 14: concurrent append keeps one complete record per writer ------
export AIDEVOPS_GH_API_LOG_MAX_BYTES=10000
unset _GH_API_INSTRUMENT_LOADED
# shellcheck source=../gh-api-instrument.sh
source "${PARENT_DIR}/gh-api-instrument.sh"
gh_clear_log
for fixture_index in 1 2 3 4 5 6 7 8 9 10 11 12; do
	(
		unset _GH_API_INSTRUMENT_LOADED
		# shellcheck source=../gh-api-instrument.sh
		source "${PARENT_DIR}/gh-api-instrument.sh"
		gh_record_attempt rest concurrent-caller "logical-${fixture_index}" "attempt-${fixture_index}" 1 0 success 200 1 1 gh-pat rest-core rest-selected 4999
	) &
done
wait
assert_eq "concurrent append retained all complete records" "12" "$(wc -l <"$AIDEVOPS_GH_API_LOG" | tr -d ' ')"
assert_eq "concurrent attempt IDs remain unique" "12" "$(cut -f11 "$AIDEVOPS_GH_API_LOG" | sort -u | wc -l | tr -d ' ')"

# --- Test 15: the shim records exactly one native transport attempt -------
SHIM_FIXTURE="$TMPDIR/shim-fixture"
NATIVE_FIXTURE="$TMPDIR/native-fixture"
mkdir -p "$SHIM_FIXTURE" "$NATIVE_FIXTURE"
cp "${PARENT_DIR}/gh" "$SHIM_FIXTURE/gh"
cp "${PARENT_DIR}/gh-api-instrument.sh" "$SHIM_FIXTURE/gh-api-instrument.sh"
chmod +x "$SHIM_FIXTURE/gh"
cat >"$NATIVE_FIXTURE/gh" <<'EOF_NATIVE_GH'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$NATIVE_ATTEMPT_LOG"
exit "${NATIVE_ATTEMPT_STATUS:-0}"
EOF_NATIVE_GH
chmod +x "$NATIVE_FIXTURE/gh"
export AIDEVOPS_GH_API_LOG="$TMPDIR/shim-attempts.log"
export NATIVE_ATTEMPT_LOG="$TMPDIR/native-attempts.log"
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	"$SHIM_FIXTURE/gh" api '/repos/private-owner/private-repo/issues?page=2&token=private-value' >/dev/null
assert_eq "shim invokes native gh exactly once" "1" "$(grep -c '^api$' "$NATIVE_ATTEMPT_LOG")"
assert_eq "shim emits one logical event" "1" "$(awk -F'\t' '$9 == "logical" { count++ } END { print count + 0 }' "$AIDEVOPS_GH_API_LOG")"
assert_eq "shim emits one transport attempt" "1" "$(awk -F'\t' '$9 == "attempt" { count++ } END { print count + 0 }' "$AIDEVOPS_GH_API_LOG")"
assert_eq "shim records explicit page number" "2" "$(awk -F'\t' '$9 == "attempt" { print $12 }' "$AIDEVOPS_GH_API_LOG")"
if grep -Eq 'private-owner|private-repo|private-value|token=' "$AIDEVOPS_GH_API_LOG"; then
	echo "  FAIL: shim telemetry exposed path/query arguments"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: shim telemetry keeps path/query arguments private"
	PASS=$((PASS + 1))
fi

# --- Summary ----------------------------------------------------------
echo ""
echo "===================================================="
echo "Result: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
