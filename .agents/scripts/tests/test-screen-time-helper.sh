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

test_empty_zero_and_sparse_source_semantics() {
	local tmpdir="$1"
	local now="$2"
	local empty_db="${tmpdir}/empty.db"
	create_knowledge_db "$empty_db"
	local empty_json
	empty_json=$(AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" profile_stats "$empty_db")
	[[ "$(printf '%s' "$empty_json" | jq -r '.collection_status')" == "unavailable" ]] || fail "readable empty macOS DB was not unavailable"
	local fallback_home="${tmpdir}/empty-fallback-home"
	mkdir -p "${fallback_home}/.aidevops/.agent-workspace/observability"
	python3 - "${fallback_home}/.aidevops/.agent-workspace/observability/screen-time.jsonl" "$now" <<'PY'
import datetime as dt
import json
import sys
date = dt.datetime.fromtimestamp(int(sys.argv[2])).date() - dt.timedelta(days=1)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(json.dumps({"date": str(date), "screen_hours": 2}) + "\n")
PY
	local empty_fallback
	empty_fallback=$(HOME="$fallback_home" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" AIDEVOPS_SCREEN_TIME_OS_TYPE=Darwin AIDEVOPS_KNOWLEDGE_DB="$empty_db" "$HELPER" profile-stats)
	[[ "$(printf '%s' "$empty_fallback" | jq -r '.today_hours')" == "2" || "$(printf '%s' "$empty_fallback" | jq -r '.today_hours')" == "2.0" ]] || fail "empty readable macOS source did not fall back to history: ${empty_fallback}"
	[[ "$(printf '%s' "$empty_fallback" | jq -r '.periods.day.source')" == "screen-time-history:daily-observations" ]] || fail "empty-source history provenance missing"

	local zero_db="${tmpdir}/observed-zero.db"
	create_knowledge_db "$zero_db"
	sqlite3 "$zero_db" "INSERT INTO ZOBJECT (ZSTREAMNAME,ZCREATIONDATE,ZVALUEINTEGER) VALUES('/display/isBacklit',$(core_data_offset "$((now - 3600))"),0);"
	local zero_json
	zero_json=$(AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" profile_stats "$zero_db")
	[[ "$(printf '%s' "$zero_json" | jq -r '.today_hours')" == "0" || "$(printf '%s' "$zero_json" | jq -r '.today_hours')" == "0.0" ]] || fail "explicit OFF observation was not preserved as legitimate zero: ${zero_json}"
	[[ "$(printf '%s' "$zero_json" | jq -r '.periods.day.status')" == "ok" ]] || fail "explicit zero observation was marked unavailable"

	local sparse_db="${tmpdir}/relative-sparse.db"
	create_knowledge_db "$sparse_db"
	insert_backlit_pair "$sparse_db" "$((now - 2 * 86400))" "$((now - 2 * 86400 + 3600))"
	insert_backlit_pair "$sparse_db" "$((now - 3600))" "$now"
	local day
	for day in 1 2 3 4 5 6 7 8; do
		insert_app_usage "$sparse_db" "$((now - day * 86400))" "$((now - day * 86400 + 4 * 3600))"
	done
	local sparse_json
	sparse_json=$(AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" profile_stats "$sparse_db")
	[[ "$(printf '%s' "$sparse_json" | jq -r '.periods.month.source')" == "macos-knowledge-db:/app/usage-union" ]] || fail "two sparse backlit days incorrectly beat eight app-usage days"
	[[ "$(printf '%s' "$sparse_json" | jq -r '.month_hours')" == "32" || "$(printf '%s' "$sparse_json" | jq -r '.month_hours')" == "32.0" ]] || fail "relative app coverage duration was not selected"
	pass "empty sources, explicit zero, and relative sparse-source selection are distinct"
	return 0
}

test_snapshot_omits_unobserved_stale_dates() {
	local tmpdir="$1"
	local fixture_home="${tmpdir}/snapshot-home"
	local db="${tmpdir}/snapshot-evidence.db"
	mkdir -p "$fixture_home"
	create_knowledge_db "$db"
	local fixture_values observed_date zero_date observed_start observed_end zero_event
	fixture_values=$(python3 -c 'import datetime as d; today=d.date.today(); observed=today-d.timedelta(days=5); zero=today-d.timedelta(days=4); epoch=lambda day,h:int(d.datetime.combine(day,d.time(h)).timestamp()); print(observed,zero,epoch(observed,10),epoch(observed,11),epoch(zero,12))')
	read -r observed_date zero_date observed_start observed_end zero_event <<<"$fixture_values"
	insert_backlit_pair "$db" "$observed_start" "$observed_end"
	sqlite3 "$db" "INSERT INTO ZOBJECT (ZSTREAMNAME,ZCREATIONDATE,ZVALUEINTEGER) VALUES('/display/isBacklit',$(core_data_offset "$zero_event"),0);"
	HOME="$fixture_home" AIDEVOPS_SCREEN_TIME_OS_TYPE=Darwin AIDEVOPS_KNOWLEDGE_DB="$db" "$HELPER" snapshot >/dev/null
	local history="${fixture_home}/.aidevops/.agent-workspace/observability/screen-time.jsonl"
	local rows dates zero_hours
	rows=$(wc -l <"$history" | tr -d ' ')
	dates=$(jq -r '.date' "$history" | sort | tr '\n' ' ')
	zero_hours=$(jq -r --arg date "$zero_date" 'select(.date == $date) | .screen_hours' "$history")
	if [[ "$rows" != "2" || "$dates" != "${observed_date} ${zero_date} " || ("$zero_hours" != "0" && "$zero_hours" != "0.0") ]]; then
		fail "snapshot fabricated stale gap coverage or lost explicit zero: rows=${rows} dates=${dates} zero=${zero_hours}"
	fi
	pass "snapshot omits unobserved stale dates and records explicit zero-event dates"
	return 0
}

test_top_apps_sql_and_sweep_are_bounded() {
	local tmpdir="$1"
	local now="$2"
	local db="${tmpdir}/bounded-apps.db"
	local instrument="${tmpdir}/bounded-apps-instrument.json"
	create_knowledge_db "$db"
	local cd_now=$((now - 978307200))
	sqlite3 "$db" "
		WITH RECURSIVE old_rows(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM old_rows WHERE i < 5000)
		INSERT INTO ZOBJECT (ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUESTRING)
		SELECT '/app/usage', ${cd_now} - 86400*60 - i*60, ${cd_now} - 86400*60 - i*60 + 30, 'old.app' FROM old_rows;
		WITH RECURSIVE recent_rows(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM recent_rows WHERE i < 200)
		INSERT INTO ZOBJECT (ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUESTRING)
		SELECT '/app/usage', ${cd_now} - i*300, ${cd_now} - i*300 + 600, 'recent.' || (i % 3) FROM recent_rows;"
	AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" AIDEVOPS_APP_STATS_INSTRUMENT_FILE="$instrument" \
		python3 "${SCRIPTS_DIR}/screen-time-interval-engine.py" apps --os-type Darwin --db "$db" >/dev/null
	local selected valid boundaries segments elapsed
	selected=$(jq -r '.rows_selected' "$instrument")
	valid=$(jq -r '.valid_intervals' "$instrument")
	boundaries=$(jq -r '.boundaries' "$instrument")
	segments=$(jq -r '.attributed_segments' "$instrument")
	elapsed=$(jq -r '.elapsed_ms' "$instrument")
	if [[ "$selected" != "200" || "$valid" != "200" || "$boundaries" -gt 402 || "$segments" -gt 401 ]] ||
		! awk -v elapsed="$elapsed" 'BEGIN {exit !(elapsed < 5000)}'; then
		fail "top-app query/sweep was unbounded: $(<"$instrument")"
	fi
	pass "top-app SQL excludes 5000 old rows and sweep remains boundary-linear"
	return 0
}

test_local_midnight_dst_boundaries() {
	local tmpdir="$1"
	local db="${tmpdir}/dst.db"
	create_knowledge_db "$db"
	local bounds
	bounds=$(TZ=America/New_York python3 -c 'import datetime as d,time; time.tzset(); dates=(d.date(2026,3,8),d.date(2026,11,1)); print(" ".join(str(int(d.datetime.combine(x,d.time.min).timestamp()))+" "+str(int(d.datetime.combine(x+d.timedelta(days=1),d.time.min).timestamp())) for x in dates))')
	local spring_start spring_end fall_start fall_end
	read -r spring_start spring_end fall_start fall_end <<<"$bounds"
	insert_app_usage "$db" "$spring_start" "$spring_end"
	insert_app_usage "$db" "$fall_start" "$fall_end"
	local spring_hours fall_hours
	spring_hours=$(TZ=America/New_York AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$((fall_end + 3600))" python3 "${SCRIPTS_DIR}/screen-time-interval-engine.py" date --date 2026-03-08 --os-type Darwin --db "$db")
	fall_hours=$(TZ=America/New_York AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$((fall_end + 3600))" python3 "${SCRIPTS_DIR}/screen-time-interval-engine.py" date --date 2026-11-01 --os-type Darwin --db "$db")
	[[ "$((spring_end - spring_start))" == "82800" && "$spring_hours" == "23.0" ]] || fail "spring DST local day was not bounded by consecutive midnights"
	[[ "$((fall_end - fall_start))" == "90000" && "$fall_hours" == "24.0" ]] || fail "fall DST local day was not bounded then capped at 24h"
	pass "date collection uses host-local consecutive-midnight DST boundaries"
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
	local zero_fixture="${tmpdir}/logind-zero.txt"
	python3 - "$zero_fixture" "$now" <<'PY'
import datetime as dt
import sys
stamp = dt.datetime.fromtimestamp(int(sys.argv[2]) - 60, dt.timezone.utc).isoformat()
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(f"{stamp} host systemd-logind[1]: New session z1 of user fixture.\n")
    handle.write(f"{stamp} host systemd-logind[1]: Removed session z1.\n")
PY
	local zero_output
	zero_output=$(AIDEVOPS_SCREEN_TIME_OS_TYPE=Linux AIDEVOPS_LOGIND_FIXTURE="$zero_fixture" \
		AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" AIDEVOPS_SCREEN_TIME_USER=fixture "$HELPER" profile-stats)
	[[ "$(printf '%s' "$zero_output" | jq -r '.today_hours')" == "0" || "$(printf '%s' "$zero_output" | jq -r '.today_hours')" == "0.0" ]] || fail "explicit zero-duration logind events were not preserved"
	[[ "$(printf '%s' "$zero_output" | jq -r '.periods.day.status')" == "ok" ]] || fail "explicit logind zero was treated as source failure"

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

	local empty_journal="${tmpdir}/empty-logind.txt"
	local realistic_last="${tmpdir}/last-F.txt"
	: >"$empty_journal"
	cat >"$realistic_last" <<'EOF'
fixture  pts/0  host  Tue May 17 23:33:20 2033 - Wed May 18 00:33:20 2033  (01:00)
fixture  pts/1  host  Wed May 18 01:33:20 2033   still logged in
EOF
	local empty_fallback
	empty_fallback=$(TZ=UTC AIDEVOPS_SCREEN_TIME_OS_TYPE=Linux AIDEVOPS_LOGIND_FIXTURE="$empty_journal" \
		AIDEVOPS_LAST_FIXTURE="$realistic_last" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" \
		AIDEVOPS_SCREEN_TIME_USER=fixture "$HELPER" profile-stats)
	[[ "$(printf '%s' "$empty_fallback" | jq -r '.today_hours')" == "3" || "$(printf '%s' "$empty_fallback" | jq -r '.today_hours')" == "3.0" ]] || fail "real last -F completed+active records were not clipped to now"
	[[ "$(printf '%s' "$empty_fallback" | jq -r '.periods.day.reason')" == *"journal-readable-no-user-observations"* ]] || fail "empty readable logind did not truthfully fall back"
	pass "empty logind falls back and parses realistic local last -F records"
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
    handle.write("not-json\n")
    handle.write(json.dumps({"date": "bad-date", "screen_hours": 5}) + "\n")
    handle.write(json.dumps({"date": str(today - dt.timedelta(days=4)), "screen_hours": "broken"}) + "\n")
PY
	local output estimate span status skipped
	output=$(HOME="$fixture_home" AIDEVOPS_SCREEN_TIME_OS_TYPE=Unsupported "$HELPER" profile-stats)
	estimate=$(printf '%s' "$output" | jq -r '.year_hours')
	span=$(printf '%s' "$output" | jq -r '.periods.year.calendar_span_days')
	status=$(printf '%s' "$output" | jq -r '.periods.year.status')
	skipped=$(printf '%s' "$output" | jq -r '.history_skipped_rows')
	[[ "$span" == "16" ]] || fail "expected calendar span 16 rather than active row count 3, got ${span}"
	[[ "$estimate" == "958.1" ]] || fail "expected clamped 24h rows and calendar-span estimate 958.1h, got ${estimate}"
	[[ "$status" == "stale" ]] || fail "expected stale history estimate to remain visibly stale"
	[[ "$skipped" == "3" ]] || fail "expected three malformed history rows to be skipped individually, got ${skipped}"
	pass "history skips malformed rows individually and reports provenance"
	return 0
}

test_corrupt_core_data_and_history_paths_are_safe() {
	local tmpdir="$1"
	local now="$2"
	local db="${tmpdir}/corrupt-core-data.db"
	create_knowledge_db "$db"
	insert_app_usage "$db" "$((now - 7200))" "$((now - 3600))"
	sqlite3 "$db" "
		UPDATE ZOBJECT SET ZVALUESTRING='valid.app' WHERE ZSTREAMNAME='/app/usage';
		INSERT INTO ZOBJECT (ZSTREAMNAME,ZCREATIONDATE,ZVALUEINTEGER) VALUES('/display/isBacklit','broken',1);
		INSERT INTO ZOBJECT (ZSTREAMNAME,ZCREATIONDATE,ZVALUEINTEGER) VALUES('/display/isBacklit',1e999,1);
		INSERT INTO ZOBJECT (ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUESTRING) VALUES('/app/usage','broken','also-broken','bad.app');
		INSERT INTO ZOBJECT (ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUESTRING) VALUES('/app/usage',1e999,1e999,'infinite.app');"
	local profile_json app_json
	profile_json=$(AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" profile_stats "$db")
	app_json=$(AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" python3 "${SCRIPTS_DIR}/screen-time-interval-engine.py" apps --os-type Darwin --db "$db")
	local python_ok=0
	PYTHONPATH="$SCRIPTS_DIR" python3 - <<'PY' || python_ok=1
from screen_time_interval_common import local_date, safe_core_epoch

assert local_date(10**500) is None
assert local_date("corrupt") is None
assert safe_core_epoch("corrupt") is None
assert safe_core_epoch(float("inf")) is None
PY
	local history_json
	history_json=$(python3 "${SCRIPTS_DIR}/screen-time-interval-engine.py" history-summary --os-type Unsupported --history "$tmpdir")
	if [[ "$(printf '%s' "$profile_json" | jq -r '.month_hours')" != "1" && "$(printf '%s' "$profile_json" | jq -r '.month_hours')" != "1.0" ]] ||
		[[ "$(printf '%s' "$app_json" | jq -r 'length')" != "1" ]] ||
		[[ "$(printf '%s' "$history_json" | jq -r '.valid_rows')" != "0" || "$python_ok" -ne 0 ]]; then
		fail "corrupt Core Data values or directory history path escaped defensive parsing"
	fi
	pass "corrupt Core Data values, local dates, and directory history paths are safe"
	return 0
}

test_screen_engine_sibling_modules_deploy_together() {
	local tmpdir="$1"
	local deploy_dir="${tmpdir}/deployed-screen-engine"
	mkdir -p "$deploy_dir"
	cp "${SCRIPTS_DIR}/screen-time-interval-engine.py" \
		"${SCRIPTS_DIR}/screen_time_interval_common.py" \
		"${SCRIPTS_DIR}/screen_time_macos.py" \
		"${SCRIPTS_DIR}/screen_time_macos_apps.py" \
		"${SCRIPTS_DIR}/screen_time_linux.py" \
		"${SCRIPTS_DIR}/screen_time_linux_wtmp.py" \
		"${SCRIPTS_DIR}/screen_time_linux_logind.py" \
		"${SCRIPTS_DIR}/screen_time_history.py" "$deploy_dir/"
	local output
	output=$(python3 "${deploy_dir}/screen-time-interval-engine.py" history-summary --os-type Unsupported)
	[[ "$(printf '%s' "$output" | jq -r '.valid_rows')" == "0" ]] || fail "deployed screen engine could not load sibling modules"
	pass "screen engine loads deployed sibling modules"
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
	test_empty_zero_and_sparse_source_semantics "$tmpdir" "$now"
	test_snapshot_omits_unobserved_stale_dates "$tmpdir"
	test_top_apps_sql_and_sweep_are_bounded "$tmpdir" "$now"
	test_local_midnight_dst_boundaries "$tmpdir"
	test_linux_state_machine "$tmpdir"
	test_history_calendar_coverage_and_staleness "$tmpdir"
	test_corrupt_core_data_and_history_paths_are_safe "$tmpdir" "$now"
	test_screen_engine_sibling_modules_deploy_together "$tmpdir"
	return 0
}

main "$@"
