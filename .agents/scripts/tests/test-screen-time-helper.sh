#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."
HELPER="${SCRIPTS_DIR}/screen-time-helper.sh"
TMPDIR_TEST=""

cleanup() {
	if [[ -n "$TMPDIR_TEST" ]]; then
		rm -rf "$TMPDIR_TEST"
	fi
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

core_data_offset() {
	local epoch="$1"
	printf '%s\n' "$((epoch - 978307200))"
	return 0
}

insert_backlit_pair() {
	local db="$1"
	local on_epoch="$2"
	local off_epoch="$3"
	sqlite3 "$db" "
		INSERT INTO ZOBJECT (ZSTREAMNAME, ZCREATIONDATE, ZVALUEINTEGER) VALUES ('/display/isBacklit', $(core_data_offset "$on_epoch"), 1);
		INSERT INTO ZOBJECT (ZSTREAMNAME, ZCREATIONDATE, ZVALUEINTEGER) VALUES ('/display/isBacklit', $(core_data_offset "$off_epoch"), 0);"
	return 0
}

insert_app_usage() {
	local db="$1"
	local start_epoch="$2"
	local end_epoch="$3"
	sqlite3 "$db" "
		INSERT INTO ZOBJECT (ZSTREAMNAME, ZSTARTDATE, ZENDDATE) VALUES ('/app/usage', $(core_data_offset "$start_epoch"), $(core_data_offset "$end_epoch"));"
	return 0
}

query_hours() {
	local db="$1"
	local days="$2"
	AIDEVOPS_SCREEN_TIME_OS_TYPE=Darwin AIDEVOPS_KNOWLEDGE_DB="$db" "$HELPER" query "$days" | awk '{print $1}' | tr -d 'h'
	return 0
}

profile_stats() {
	local db="$1"
	AIDEVOPS_SCREEN_TIME_OS_TYPE=Darwin AIDEVOPS_KNOWLEDGE_DB="$db" "$HELPER" profile-stats
	return 0
}

create_knowledge_db() {
	local db="$1"
	sqlite3 "$db" "
		CREATE TABLE ZOBJECT (
			ZSTREAMNAME TEXT,
			ZCREATIONDATE REAL,
			ZVALUEINTEGER INTEGER,
			ZSTARTDATE REAL,
			ZENDDATE REAL,
			ZVALUESTRING TEXT
		);"
	return 0
}

test_union_clipping_and_failure_status() {
	local tmpdir="$1"
	local now="$2"
	local one_hour=3600
	local overlap_db="${tmpdir}/overlap.db"
	create_knowledge_db "$overlap_db"

	# Force app fallback with overlapping/repeated intervals. The union is 5h,
	# not the additive 9h, and the 30h interval is clipped to the 24h window.
	insert_app_usage "$overlap_db" "$((now - one_hour * 6))" "$((now - one_hour))"
	insert_app_usage "$overlap_db" "$((now - one_hour * 5))" "$((now - one_hour * 2))"
	insert_app_usage "$overlap_db" "$((now - one_hour * 6))" "$((now - one_hour))"
	local overlap_hours
	overlap_hours=$(query_hours "$overlap_db" 1)
	[[ "$overlap_hours" == "5.0" ]] || fail "expected app intervals to union to 5.0h, got ${overlap_hours}"
	sqlite3 "$overlap_db" "UPDATE ZOBJECT SET ZVALUESTRING='app.one' WHERE ZSTREAMNAME='/app/usage';"
	local app_json app_seconds
	app_json=$(AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" python3 "${SCRIPTS_DIR}/screen-time-interval-engine.py" apps --os-type Darwin --db "$overlap_db")
	app_seconds=$(printf '%s' "$app_json" | jq -r '.[0].month_seconds')
	[[ "$app_seconds" == "18000" ]] || fail "expected repeated/overlapping top-app intervals to union to 18000s, got ${app_seconds}"

	local clip_db="${tmpdir}/clip.db"
	create_knowledge_db "$clip_db"
	insert_app_usage "$clip_db" "$((now - one_hour * 30))" "$now"
	local clipped_hours
	clipped_hours=$(query_hours "$clip_db" 1)
	[[ "$clipped_hours" == "24.0" ]] || fail "expected one-day result capped by clipping at 24.0h, got ${clipped_hours}"

	local repeated_db="${tmpdir}/repeated.db"
	create_knowledge_db "$repeated_db"
	sqlite3 "$repeated_db" "
		INSERT INTO ZOBJECT VALUES('/display/isBacklit', $(core_data_offset "$((now - one_hour * 3))"), 1, NULL, NULL, NULL);
		INSERT INTO ZOBJECT VALUES('/display/isBacklit', $(core_data_offset "$((now - one_hour * 2))"), 1, NULL, NULL, NULL);
		INSERT INTO ZOBJECT VALUES('/display/isBacklit', $(core_data_offset "$((now - one_hour))"), 0, NULL, NULL, NULL);"
	local repeated_hours
	repeated_hours=$(query_hours "$repeated_db" 1)
	[[ "$repeated_hours" == "2.0" ]] || fail "expected repeated ON events not to double count, got ${repeated_hours}"

	local invalid_db="${tmpdir}/invalid.db"
	printf '%s\n' 'not sqlite' >"$invalid_db"
	local failure_json
	failure_json=$(profile_stats "$invalid_db")
	[[ "$(printf '%s' "$failure_json" | jq -r '.collection_status')" == "unavailable" ]] || fail "database access failure was not surfaced"
	[[ "$(printf '%s' "$failure_json" | jq -r '.today_hours')" == "null" ]] || fail "database failure was rendered as a zero"
	pass "macOS intervals union, clip, deduplicate, and surface access failures"
	return 0
}

test_linux_state_machine() {
	local tmpdir="$1"
	local now=2000000000
	local fixture="${tmpdir}/logind.txt"
	python3 - "$fixture" "$now" <<'PY'
import datetime as dt
import sys

target = sys.argv[1]
now = int(sys.argv[2])
events = [
    (-6, "New session c1 of user fixture."),
    (-5, "Session c1 locked."),
    (-4, "Session c1 unlocked."),
    (-3, "Lid closed."),
    (-2, "Lid opened."),
    (-1, "Removed session c1."),
]
with open(target, "w", encoding="utf-8") as handle:
    for hours, message in events:
        stamp = dt.datetime.fromtimestamp(now + hours * 3600, dt.timezone.utc).isoformat()
        handle.write(f"{stamp} host systemd-logind[1]: {message}\n")
PY
	local output hours source
	output=$(AIDEVOPS_SCREEN_TIME_OS_TYPE=Linux AIDEVOPS_LOGIND_FIXTURE="$fixture" \
		AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" AIDEVOPS_SCREEN_TIME_USER=fixture "$HELPER" profile-stats)
	hours=$(printf '%s' "$output" | jq -r '.today_hours')
	source=$(printf '%s' "$output" | jq -r '.periods.day.source')
	[[ "$hours" == "3" || "$hours" == "3.0" ]] || fail "expected lock/lid/session state to produce 3.0h, got ${hours}"
	[[ "$source" == *"session-lid-lock-state"* ]] || fail "Linux provenance missing state semantics: ${source}"
	pass "Linux state retains username-less session OFF events and clips active windows"

	local missing_journal="${tmpdir}/missing-journal"
	local wtmp_fixture="${tmpdir}/wtmp.txt"
	printf '%s|%s\n' "$((now - 7200))" "$((now - 3600))" >"$wtmp_fixture"
	local fallback
	fallback=$(AIDEVOPS_SCREEN_TIME_OS_TYPE=Linux AIDEVOPS_LOGIND_FIXTURE="$missing_journal" \
		AIDEVOPS_LAST_FIXTURE="$wtmp_fixture" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" \
		AIDEVOPS_SCREEN_TIME_USER=fixture "$HELPER" profile-stats)
	[[ "$(printf '%s' "$fallback" | jq -r '.today_hours')" == "1" || "$(printf '%s' "$fallback" | jq -r '.today_hours')" == "1.0" ]] || fail "wtmp fallback hours were not parsed"
	[[ "$(printf '%s' "$fallback" | jq -r '.periods.day.source')" == "linux-wtmp:login-session-proxy" ]] || fail "wtmp fallback provenance was not truthful"
	pass "Linux collection failure falls back to clipped wtmp sessions with proxy provenance"
	return 0
}

test_history_calendar_coverage_and_staleness() {
	local tmpdir="$1"
	local fixture_home="${tmpdir}/history-home"
	mkdir -p "${fixture_home}/.aidevops/.agent-workspace/observability"
	local history="${fixture_home}/.aidevops/.agent-workspace/observability/screen-time.jsonl"
	python3 - "$history" <<'PY'
import datetime as dt
import json
import sys

today = dt.datetime.now(dt.timezone.utc).date()
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    for age, hours in ((20, 30), (10, 12), (5, 6)):
        handle.write(json.dumps({"date": str(today - dt.timedelta(days=age)), "screen_hours": hours}) + "\n")
PY
	local output estimate span status
	output=$(HOME="$fixture_home" AIDEVOPS_SCREEN_TIME_OS_TYPE=Unsupported "$HELPER" profile-stats)
	estimate=$(printf '%s' "$output" | jq -r '.year_hours')
	span=$(printf '%s' "$output" | jq -r '.periods.year.calendar_span_days')
	status=$(printf '%s' "$output" | jq -r '.periods.year.status')
	[[ "$span" == "16" ]] || fail "expected calendar span 16 rather than active row count 3, got ${span}"
	[[ "$estimate" == "958.1" ]] || fail "expected clamped 24h rows and calendar-span estimate 958.1h, got ${estimate}"
	[[ "$status" == "stale" ]] || fail "expected stale history estimate to remain visibly stale"
	pass "history estimates use calendar coverage, clamp daily values, and expose staleness"
	return 0
}

main() {
	local tmpdir
	tmpdir=$(mktemp -d)
	TMPDIR_TEST="$tmpdir"
	trap cleanup EXIT

	local db="${tmpdir}/knowledgeC.db"
	create_knowledge_db "$db"

	local now
	now=$(date +%s)
	local one_hour=3600
	local one_day=86400

	# Sparse backlit: one recent day only. App usage spans multiple active days.
	insert_backlit_pair "$db" "$((now - one_hour * 8))" "$((now - one_hour))"
	insert_app_usage "$db" "$((now - one_hour * 8))" "$((now - one_hour))"
	insert_app_usage "$db" "$((now - one_day * 2))" "$((now - one_day * 2 + one_hour * 6))"
	insert_app_usage "$db" "$((now - one_day * 4))" "$((now - one_day * 4 + one_hour * 5))"

	local day_hours
	local week_hours
	day_hours=$(query_hours "$db" 1)
	week_hours=$(query_hours "$db" 7)

	[[ "$day_hours" == "7.0" ]] || fail "expected 1d backlit hours to stay primary at 7.0, got ${day_hours}"
	[[ "$week_hours" == "18.0" ]] || fail "expected sparse 7d backlit window to fall back to app usage at 18.0, got ${week_hours}"

	# Healthy backlit: events on multiple days should remain primary even when app usage exists.
	local healthy_db="${tmpdir}/healthy-knowledgeC.db"
	create_knowledge_db "$healthy_db"
	insert_backlit_pair "$healthy_db" "$((now - one_hour * 8))" "$((now - one_hour))"
	insert_backlit_pair "$healthy_db" "$((now - one_day * 2))" "$((now - one_day * 2 + one_hour * 4))"
	insert_app_usage "$healthy_db" "$((now - one_hour * 8))" "$((now - one_hour))"
	insert_app_usage "$healthy_db" "$((now - one_day * 2))" "$((now - one_day * 2 + one_hour * 4))"

	local healthy_week_hours
	healthy_week_hours=$(query_hours "$healthy_db" 7)
	[[ "$healthy_week_hours" == "11.0" ]] || fail "expected healthy 7d backlit stream to remain primary at 11.0, got ${healthy_week_hours}"

	pass "screen-time helper falls back only for sparse backlit windows"
	test_union_clipping_and_failure_status "$tmpdir" "$now"
	test_linux_state_machine "$tmpdir"
	test_history_calendar_coverage_and_staleness "$tmpdir"
	return 0
}

main "$@"
