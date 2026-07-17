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
	mode=$(stat -c '%a' "$TMPDIR/aidevops-$USER" 2>/dev/null || stat -f '%Lp' "$TMPDIR/aidevops-$USER")
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

# --- Test 10: missing lock tools fail open without stderr noise --------
saved_path="$PATH"
mkdir -p "$TMPDIR/no-lock-tools"
set +e
# shellcheck disable=SC2123 # Intentional empty-tool fixture for fail-open coverage.
PATH="$TMPDIR/no-lock-tools"
_gh_log_lock_acquire 2>"$TMPDIR/no-lock-tools.stderr"
lock_status=$?
PATH="$saved_path"
set -e
assert_eq "missing lock tools fail open" "1" "$lock_status"
lock_stderr_bytes=$(wc -c <"$TMPDIR/no-lock-tools.stderr" | tr -d ' ')
assert_eq "missing lock tools stay silent" "0" "$lock_stderr_bytes"

# --- Test 10b: abandoned empty locks recover instead of wedging telemetry --
export AIDEVOPS_GH_API_LOG="$TMPDIR/stale-lock-calls.log"
export AIDEVOPS_GH_API_REPORT="$TMPDIR/stale-lock-report.json"
export AIDEVOPS_GH_API_EMPTY_LOCK_GRACE_TRIES=0
unset _GH_API_INSTRUMENT_LOADED
# shellcheck source=../gh-api-instrument.sh
source "${PARENT_DIR}/gh-api-instrument.sh"
assert_eq "empty lock grace accepts an environment override" "0" "$_GH_API_EMPTY_LOCK_GRACE_TRIES"
invalid_grace=$(AIDEVOPS_GH_API_EMPTY_LOCK_GRACE_TRIES=invalid bash -c '
	# shellcheck source=/dev/null
	source "$1"
	printf "%s\n" "$_GH_API_EMPTY_LOCK_GRACE_TRIES"
' _ "${PARENT_DIR}/gh-api-instrument.sh")
assert_eq "invalid empty lock grace uses the default" "100" "$invalid_grace"
gh_clear_log
mkdir "${GH_API_LOG}.lock"
gh_record_call rest stale-empty-lock-test
assert_eq "stale empty lock permits the next record" "1" "$(wc -l <"$GH_API_LOG" | tr -d ' ')"
if [[ -d "${GH_API_LOG}.lock" ]]; then
	echo "  FAIL: stale empty telemetry lock survived recovery"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: stale empty telemetry lock was removed"
	PASS=$((PASS + 1))
fi

mkdir "${GH_API_LOG}.lock"
printf '%s\n' 'not-a-pid' >"${GH_API_LOG}.lock/pid"
_GH_API_EMPTY_LOCK_GRACE_TRIES=100
malformed_lock_status=0
_gh_log_lock_reclaim "${GH_API_LOG}.lock" 0 || malformed_lock_status=$?
assert_eq "malformed PID lock is reclaimed without the empty-lock grace" "0" "$malformed_lock_status"
gh_record_call rest stale-malformed-lock-test
assert_eq "stale malformed lock permits the next record" "2" "$(wc -l <"$GH_API_LOG" | tr -d ' ')"

mkdir "${GH_API_LOG}.lock"
printf '%s\n' '999999999' >"${GH_API_LOG}.lock/pid"
_GH_API_EMPTY_LOCK_GRACE_TRIES=100
dead_lock_status=0
_gh_log_lock_reclaim "${GH_API_LOG}.lock" 0 || dead_lock_status=$?
assert_eq "dead PID lock is reclaimed without the empty-lock grace" "0" "$dead_lock_status"

mkdir "${GH_API_LOG}.lock"
printf '%s\n' "${BASHPID:-$$}" >"${GH_API_LOG}.lock/pid"
live_lock_status=0
_gh_log_lock_reclaim "${GH_API_LOG}.lock" 100 || live_lock_status=$?
assert_eq "live PID lock is not reclaimed" "1" "$live_lock_status"
rm -f "${GH_API_LOG}.lock/pid"
rmdir "${GH_API_LOG}.lock"

# --- Test 10c: issue sync keeps the framework gh shim first on PATH -------
issue_sync_scripts_dir="$(cd "$PARENT_DIR" && pwd)"
issue_sync_probe="$TMPDIR/issue-sync-path-probe.sh"
cat >"$issue_sync_probe" <<'EOF_ISSUE_SYNC_PROBE'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../issue-sync-helper.sh
source "$ISSUE_SYNC_HELPER" >/dev/null
printf '%s\n' "${PATH%%:*}"
EOF_ISSUE_SYNC_PROBE
issue_sync_path_head=$(ISSUE_SYNC_HELPER="${PARENT_DIR}/issue-sync-helper.sh" PATH="$FAKE_BIN:$saved_path" "$BASH" "$issue_sync_probe")
assert_eq "issue sync preserves framework gh shim precedence" "$issue_sync_scripts_dir" "$issue_sync_path_head"

# Restore per-test overrides for summary diagnostics if future tests append.
export AIDEVOPS_GH_API_LOG="$TMPDIR/gh-api-calls.log"
export AIDEVOPS_GH_API_REPORT="$TMPDIR/report.json"
unset AIDEVOPS_GH_API_EMPTY_LOCK_GRACE_TRIES

# --- Test 11: exact replay separates events, attempts, pages, and retries --
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
	'endpoint-private?token=do-not-log' 'Authorization: bearer do-not-log' '--body=private-payload'
set +e
gh_run_transport_attempt graphql privacy-caller logical-private 1 1 -- false
transport_status=$?
set -e
assert_eq "transport failure status preserved" "1" "$transport_status"
if grep -Eq 'do-not-log|private-payload|Authorization|endpoint-private' "$AIDEVOPS_GH_API_LOG"; then
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

# --- Test 12b: retained opaque history does not poison a fresh window -------
gh_clear_log
outside_ts=$((now - 120))
inside_ts=$((now - 10))
printf '%s\topaque-caller\trest\tgh-pat\trest-core\tnative-pagination-opaque\t\tv2\tattempt\tlogical-old\tattempt-old\t0\t0\tsuccess\t200\t10\t\n' "$outside_ts" >>"$AIDEVOPS_GH_API_LOG"
printf '%s\texact-caller\trest\tgh-pat\trest-core\trest-selected\t\tv2\tattempt\tlogical-new\tattempt-new\t1\t0\tsuccess\t200\t10\t\n' "$inside_ts" >>"$AIDEVOPS_GH_API_LOG"
gh_aggregate_calls "$AIDEVOPS_GH_API_REPORT" 60
assert_eq "fresh window excludes retained unknown pages" "0" "$(jq -r '._meta.unknown_page_attempts' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "retained unknown page remains auditable" "1" "$(jq -r '._meta.retained_unknown_page_attempts' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "fresh exact window ignores old opaque call" "0" "$(jq -r '._meta.opaque_paginated_attempts' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "fresh window exactness is true" "true" "$(jq -r '._meta.attempts_exact' "$AIDEVOPS_GH_API_REPORT")"

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
cp "${PARENT_DIR}/gh-rest-pagination-lib.sh" "$SHIM_FIXTURE/gh-rest-pagination-lib.sh"
chmod +x "$SHIM_FIXTURE/gh"
cat >"$NATIVE_FIXTURE/gh" <<'EOF_NATIVE_GH'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$NATIVE_ATTEMPT_LOG"
page=1
jq_requested=0
expect_jq=0
slurp_requested=0
template_requested=0
expect_template=0
for arg in "$@"; do
	if [[ "$expect_jq" -eq 1 ]]; then
		expect_jq=0
		continue
	fi
	if [[ "$expect_template" -eq 1 ]]; then
		expect_template=0
		continue
	fi
	case "$arg" in
	--jq | -q)
		jq_requested=1
		expect_jq=1
		;;
	--jq=* | -q*) jq_requested=1 ;;
	--slurp) slurp_requested=1 ;;
	--template | -t)
		template_requested=1
		expect_template=1
		;;
	--template=* | -t*) template_requested=1 ;;
	*)
		if [[ "$arg" =~ (^|[?\&])page=([0-9]+)($|\&) ]]; then
			page="${BASH_REMATCH[2]}"
		fi
		;;
	esac
done
if [[ "${NATIVE_REJECT_SLURP_FILTERS:-0}" == "1" && "$slurp_requested" -eq 1 \
	&& ("$jq_requested" -eq 1 || "$template_requested" -eq 1) ]]; then
	printf 'the --slurp option is not supported with --jq or --template\n' >&2
	exit "${NATIVE_PREFLIGHT_STATUS:-1}"
fi
if [[ "${NATIVE_PAGINATED_RESPONSE:-0}" == "1" ]]; then
	printf 'HTTP/2.0 200 OK\r\n'
	if [[ "$page" -eq 1 ]]; then
		if [[ "${NATIVE_ENTERPRISE_LINK:-0}" == "1" ]]; then
			printf 'Link: <https://ghe.example/api/v3/repos/fixture/items?per_page=100&page=2>; rel="next"\r\n'
		elif [[ "${NATIVE_COMMA_LINK:-0}" == "1" ]]; then
			printf 'Link: <https://api.github.com/repos/fixture/items?labels=bug,help-wanted&page=2>; rel="next"\r\n'
		elif [[ "${NATIVE_QUERY_REL_ONLY:-0}" == "1" ]]; then
			printf 'Link: <https://api.github.com/repos/fixture/items?per_page=100&page=2&rel=next>; rel="prev"\r\n'
		else
			printf 'Link: <repos/fixture/items?per_page=100&page=2>; rel="next"\r\n'
		fi
	elif [[ "$page" -eq 2 && "${NATIVE_CYCLIC_LINK:-0}" == "1" ]]; then
		printf 'Link: <repos/fixture/items?per_page=100&page=2>; rel="next"\r\n'
	fi
	printf '\r\n'
	if [[ "$jq_requested" -eq 1 ]]; then
		printf '%s\n' "$page"
	elif [[ "${NATIVE_NO_FINAL_NEWLINE:-0}" == "1" ]]; then
		printf '[{"page":%s}]' "$page"
	else
		printf '[{"page":%s}]\n' "$page"
	fi
fi
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

# REST pagination is expanded into one observable native command per page while
# preserving one logical operation and framework-owned caller attribution.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 \
	AIDEVOPS_GH_CALLER=gh-api-instrument.sh \
	"$SHIM_FIXTURE/gh" api '/repos/private-owner/private-repo/issues?per_page=100' --paginate >/dev/null
"${PARENT_DIR}/gh-api-instrument.sh" report "$AIDEVOPS_GH_API_REPORT" >/dev/null 2>&1
assert_eq "explicit pagination invokes native gh once per page" "2" "$(grep -c '^api$' "$NATIVE_ATTEMPT_LOG")"
assert_eq "explicit pagination records page sequence" "1 2" "$(awk -F'\t' '$9 == "attempt" { printf "%s%s", separator, $12; separator=" " } END { print "" }' "$AIDEVOPS_GH_API_LOG")"
assert_eq "explicit pagination uses a framework-owned caller" "2" "$(awk -F'\t' '$9 == "attempt" && $2 == "gh-api-instrument.sh" { count++ } END { print count + 0 }' "$AIDEVOPS_GH_API_LOG")"
assert_eq "explicit pagination has no opaque attempts" "0" "$(jq -r '._meta.opaque_paginated_attempts' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "explicit pagination supports exactness claims" "true" "$(jq -r '._meta.attempts_exact' "$AIDEVOPS_GH_API_REPORT")"
if grep -q -- '--paginate' "$NATIVE_ATTEMPT_LOG"; then
	echo "  FAIL: native gh retained hidden pagination"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: native gh receives only explicit pages"
	PASS=$((PASS + 1))
fi

# The rollback switch preserves native pagination and its honest opaque marker.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	AIDEVOPS_GH_EXPLICIT_PAGINATION_DISABLE=1 \
	"$SHIM_FIXTURE/gh" api '/repos/private-owner/private-repo/issues?per_page=100' --paginate >/dev/null
"${PARENT_DIR}/gh-api-instrument.sh" report "$AIDEVOPS_GH_API_REPORT" >/dev/null 2>&1
assert_eq "pagination rollback retains native flag" "1" "$(grep -c -- '^--paginate$' "$NATIVE_ATTEMPT_LOG")"
assert_eq "pagination rollback remains honestly opaque" "1" "$(jq -r '._meta.opaque_paginated_attempts' "$AIDEVOPS_GH_API_REPORT")"

# Native gh rejects --slurp combined with --jq or --template before issuing an
# HTTP request. Preserve that CLI validation result without misclassifying the
# native process invocation as an opaque transport attempt.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
preflight_jq_rc=0
preflight_jq_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_REJECT_SLURP_FILTERS=1 \
	"$SHIM_FIXTURE/gh" api --method GET --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' -f state=open \
	--slurp --jq '.' 2>&1) || preflight_jq_rc=$?
preflight_template_rc=0
preflight_template_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_REJECT_SLURP_FILTERS=1 \
	"$SHIM_FIXTURE/gh" api --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' --slurp --template '{{.}}' 2>&1) || preflight_template_rc=$?
"${PARENT_DIR}/gh-api-instrument.sh" report "$AIDEVOPS_GH_API_REPORT" >/dev/null 2>&1
assert_eq "slurp/jq native preflight exit is preserved" "1" "$preflight_jq_rc"
assert_eq "slurp/template native preflight exit is preserved" "1" "$preflight_template_rc"
assert_eq "native CLI still validates both invalid invocations" "2" "$(grep -c '^api$' "$NATIVE_ATTEMPT_LOG")"
assert_eq "invalid pagination combinations retain logical events" "2" "$(awk -F'\t' '$9 == "logical" { count++ } END { print count + 0 }' "$AIDEVOPS_GH_API_LOG")"
assert_eq "invalid pagination combinations record zero transport attempts" "0" "$(jq -r '._meta.attempted_requests' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "invalid pagination combinations create no opaque attempts" "0" "$(jq -r '._meta.opaque_paginated_attempts' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "invalid pagination combinations preserve exactness" "true" "$(jq -r '._meta.attempts_exact' "$AIDEVOPS_GH_API_REPORT")"
if [[ "$preflight_jq_output" == *"not supported with --jq or --template"* &&
	"$preflight_template_output" == *"not supported with --jq or --template"* ]]; then
	echo "  PASS: native preflight diagnostics are preserved"
	PASS=$((PASS + 1))
else
	echo "  FAIL: native preflight diagnostics changed"
	FAIL=$((FAIL + 1))
fi

# Streaming jq remains page-local, matching native gh pagination semantics.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
jq_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 \
	"$SHIM_FIXTURE/gh" api --paginate '/repos/private-owner/private-repo/issues?per_page=100' --jq '.[].page')
assert_eq "explicit pagination preserves per-page jq output" $'1\n2' "$jq_output"

# Option values that resemble pagination flags remain values rather than being
# consumed as shim controls.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
option_value_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 \
	"$SHIM_FIXTURE/gh" api -H '--slurp' --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' --jq '.[].page')
assert_eq "pagination-like option values preserve output" $'1\n2' "$option_value_output"
assert_eq "pagination-like option values reach every page" "2" "$(grep -c -- '^--slurp$' "$NATIVE_ATTEMPT_LOG")"

# Explicit GET fields are query parameters, so their page loop remains
# observable. Fields without an explicit method retain native POST semantics.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
get_field_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 \
	"$SHIM_FIXTURE/gh" api --method GET --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' -f since=2026-07-01T00:00:00Z --jq '.[].page')
assert_eq "explicit pagination supports explicit GET query fields" $'1\n2' "$get_field_output"
assert_eq "explicit GET query fields invoke one native command per page" "2" "$(grep -c '^api$' "$NATIVE_ATTEMPT_LOG")"
assert_eq "explicit GET query fields remove native pagination" "0" "$(grep -c -- '^--paginate$' "$NATIVE_ATTEMPT_LOG" || true)"
assert_eq "next-page links do not replay explicit GET fields" "1" "$(grep -c '^since=2026-07-01T00:00:00Z$' "$NATIVE_ATTEMPT_LOG")"

rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	"$SHIM_FIXTURE/gh" api '/repos/private-owner/private-repo/issues?per_page=100' --paginate -f state=open >/dev/null
assert_eq "implicit field method retains native pagination semantics" "1" "$(grep -c -- '^--paginate$' "$NATIVE_ATTEMPT_LOG")"

# Enterprise Link URLs are host-checked and normalized back to gh endpoint
# paths without replaying the /api/v3 prefix.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
enterprise_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 NATIVE_ENTERPRISE_LINK=1 \
	"$SHIM_FIXTURE/gh" api --hostname ghe.example --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' --jq '.[].page')
assert_eq "enterprise Link pagination preserves output" $'1\n2' "$enterprise_output"
assert_eq "enterprise Link pagination strips API prefix" "1" "$(grep -c '^repos/fixture/items?per_page=100&page=2$' "$NATIVE_ATTEMPT_LOG")"
assert_eq "enterprise Link pagination avoids duplicated API prefix" "0" "$(grep -c '^api/v3/' "$NATIVE_ATTEMPT_LOG" || true)"

# Commas inside a Link target are data, not page-link separators.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
comma_link_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 NATIVE_COMMA_LINK=1 \
	"$SHIM_FIXTURE/gh" api --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' --jq '.[].page')
assert_eq "comma-bearing Link pagination preserves output" $'1\n2' "$comma_link_output"
assert_eq "comma-bearing next endpoint remains intact" "1" "$(grep -c '^repos/fixture/items?labels=bug,help-wanted&page=2$' "$NATIVE_ATTEMPT_LOG")"

# A URL query parameter named rel must not override the Link relation declared
# after the closing angle bracket.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
query_rel_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 NATIVE_QUERY_REL_ONLY=1 \
	"$SHIM_FIXTURE/gh" api --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' --jq '.[].page')
assert_eq "URL query rel does not impersonate the Link relation" "1" "$query_rel_output"
assert_eq "non-next Link relation stops after the first page" "1" "$(grep -c '^api$' "$NATIVE_ATTEMPT_LOG")"

# Raw bodies remain byte-for-byte intact, including a missing final newline.
raw_actual="$TMPDIR/raw-pagination.actual"
raw_expected="$TMPDIR/raw-pagination.expected"
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG" "$raw_actual" "$raw_expected"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 NATIVE_NO_FINAL_NEWLINE=1 \
	"$SHIM_FIXTURE/gh" api --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' >"$raw_actual"
printf '[{"page":1}][{"page":2}]' >"$raw_expected"
if cmp -s "$raw_expected" "$raw_actual"; then
	echo "  PASS: explicit pagination preserves raw response bytes"
	PASS=$((PASS + 1))
else
	echo "  FAIL: explicit pagination changed raw response bytes"
	FAIL=$((FAIL + 1))
fi

# Repeated next links stop before a duplicate request and remove private temp
# responses on the error path.
cycle_temp="$TMPDIR/cycle-temp"
mkdir -p "$cycle_temp"
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
if PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	AIDEVOPS_TEMP_DIR="$cycle_temp" NATIVE_PAGINATED_RESPONSE=1 NATIVE_CYCLIC_LINK=1 \
	"$SHIM_FIXTURE/gh" api --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' >/dev/null 2>/dev/null; then
	echo "  FAIL: cyclic next link unexpectedly succeeded"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: cyclic next link fails closed"
	PASS=$((PASS + 1))
fi
assert_eq "cyclic next link stops before duplicate request" "2" "$(grep -c '^api$' "$NATIVE_ATTEMPT_LOG")"
shopt -s nullglob
cycle_leftovers=("$cycle_temp"/gh-rest-pages.*)
shopt -u nullglob
assert_eq "pagination error removes private temp responses" "0" "${#cycle_leftovers[@]}"

# Pre-transport temp setup failures fall back to native pagination; once the
# first page starts, page-budget failures remain explicit errors.
blocked_temp="$TMPDIR/not-a-directory"
printf 'blocked' >"$blocked_temp"
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	AIDEVOPS_TEMP_DIR="$blocked_temp" \
	"$SHIM_FIXTURE/gh" api --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' >/dev/null
assert_eq "temp setup failure falls back to native pagination" "1" "$(grep -c -- '^--paginate$' "$NATIVE_ATTEMPT_LOG")"

rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
if PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	AIDEVOPS_GH_REST_MAX_PAGES=1 NATIVE_PAGINATED_RESPONSE=1 \
	"$SHIM_FIXTURE/gh" api --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' >/dev/null 2>/dev/null; then
	echo "  FAIL: page-budget exhaustion unexpectedly succeeded"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: page-budget exhaustion fails closed"
	PASS=$((PASS + 1))
fi
assert_eq "page budget prevents an excess request" "1" "$(grep -c '^api$' "$NATIVE_ATTEMPT_LOG")"

# Silent output remains on native pagination because explicit header parsing
# requires response bytes that --silent intentionally suppresses.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	"$SHIM_FIXTURE/gh" api --paginate --silent \
	'/repos/private-owner/private-repo/issues?per_page=100'
assert_eq "silent pagination retains native semantics" "1" "$(grep -c -- '^--paginate$' "$NATIVE_ATTEMPT_LOG")"

# Slurp buffers raw page objects into the same outer-array contract as gh.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
slurp_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 \
	"$SHIM_FIXTURE/gh" api --paginate '/repos/private-owner/private-repo/issues?per_page=100' --slurp | jq -c '.')
assert_eq "explicit pagination preserves slurp output" '[[{"page":1}],[{"page":2}]]' "$slurp_output"

# Parent attribution tolerates shell interpreter flags without scanning
# arbitrary non-interpreter command arguments for coincidental basenames.
cat >"$SHIM_FIXTURE/parent-caller.sh" <<'EOF_PARENT_CALLER'
#!/usr/bin/env bash
"$GH_SHIM_FIXTURE" api '/repos/private-owner/private-repo/issues?per_page=100' --paginate >/dev/null
EOF_PARENT_CALLER
chmod +x "$SHIM_FIXTURE/parent-caller.sh"
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 \
	GH_SHIM_FIXTURE="$SHIM_FIXTURE/gh" \
	bash -euo pipefail "$SHIM_FIXTURE/parent-caller.sh"
assert_eq "interpreter flags preserve framework caller attribution" "2" "$(awk -F'\t' '$9 == "attempt" && $2 == "parent-caller.sh" { count++ } END { print count + 0 }' "$AIDEVOPS_GH_API_LOG")"

# --- Summary ----------------------------------------------------------
echo ""
echo "===================================================="
echo "Result: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
