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

local_day_epoch() {
	local now="$1"
	local days_ago="$2"
	local hour="$3"
	python3 -c 'import datetime as d,sys; day=d.datetime.fromtimestamp(int(sys.argv[1])).date()-d.timedelta(days=int(sys.argv[2])); print(int(d.datetime.combine(day,d.time(int(sys.argv[3]))).timestamp()))' "$now" "$days_ago" "$hour"
	return 0
}

# knowledgeC writes each /display/isBacklit row when its span ends: the display
# held ZVALUEINTEGER from ZSTARTDATE to ZENDDATE (GH#37492).
insert_backlit_span() {
	local db="$1"
	local start_epoch="$2"
	local end_epoch="$3"
	local state="$4"
	sqlite3 "$db" "
		INSERT INTO ZOBJECT (ZSTREAMNAME, ZCREATIONDATE, ZSTARTDATE, ZENDDATE, ZVALUEINTEGER) VALUES ('/display/isBacklit', $(core_data_offset "$end_epoch"), $(core_data_offset "$start_epoch"), $(core_data_offset "$end_epoch"), ${state});"
	return 0
}

insert_backlit_pair() {
	local db="$1"
	local on_epoch="$2"
	local off_epoch="$3"
	insert_backlit_span "$db" "$on_epoch" "$off_epoch" 1
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
	# not the additive 9h. Use a 48h query so yesterday noon remains in the
	# rolling window regardless of the local time when this test runs.
	local previous_noon
	previous_noon=$(local_day_epoch "$now" 1 12)
	insert_app_usage "$overlap_db" "$previous_noon" "$((previous_noon + one_hour * 5))"
	insert_app_usage "$overlap_db" "$((previous_noon + one_hour))" "$((previous_noon + one_hour * 4))"
	insert_app_usage "$overlap_db" "$previous_noon" "$((previous_noon + one_hour * 5))"
	local overlap_hours
	overlap_hours=$(query_hours "$overlap_db" 2)
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
	insert_backlit_span "$repeated_db" "$((now - one_hour * 3))" "$((now - one_hour))" 1
	insert_backlit_span "$repeated_db" "$((now - one_hour * 2))" "$((now - one_hour))" 1
	insert_backlit_span "$repeated_db" "$((now - one_hour))" "$now" 0
	local repeated_hours
	repeated_hours=$(query_hours "$repeated_db" 1)
	[[ "$repeated_hours" == "2.0" ]] || fail "expected overlapping ON spans not to double count, got ${repeated_hours}"

	local invalid_db="${tmpdir}/invalid.db"
	printf '%s\n' 'not sqlite' >"$invalid_db"
	local failure_json
	mkdir -p "${tmpdir}/failure-home"
	failure_json=$(HOME="${tmpdir}/failure-home" profile_stats "$invalid_db")
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
	insert_backlit_span "$zero_db" "$((now - 7200))" "$((now - 3600))" 0
	local zero_json
	zero_json=$(AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" profile_stats "$zero_db")
	[[ "$(printf '%s' "$zero_json" | jq -r '.today_hours')" == "0" || "$(printf '%s' "$zero_json" | jq -r '.today_hours')" == "0.0" ]] || fail "explicit OFF observation was not preserved as legitimate zero: ${zero_json}"
	[[ "$(printf '%s' "$zero_json" | jq -r '.periods.day.status')" == "ok" ]] || fail "explicit zero observation was marked unavailable"

	local stale_db="${tmpdir}/unobserved-stale.db"
	create_knowledge_db "$stale_db"
	insert_backlit_pair "$stale_db" "$((now - 6 * 86400))" "$((now - 6 * 86400 + 3600))"
	local stale_json
	mkdir -p "${tmpdir}/unobserved-stale-home"
	stale_json=$(HOME="${tmpdir}/unobserved-stale-home" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" profile_stats "$stale_db")
	[[ "$(printf '%s' "$stale_json" | jq -r '.periods.day.status')" == "unavailable" ]] || fail "unobserved stale day was not unavailable: ${stale_json}"
	[[ "$(printf '%s' "$stale_json" | jq -r '.periods.day.reason')" == "no-observations-in-period" ]] || fail "unobserved stale day reason missing: ${stale_json}"
	[[ "$(printf '%s' "$stale_json" | jq -r '.periods.day.hours')" == "null" ]] || fail "unobserved stale day was rendered as zero: ${stale_json}"

	# Midday anchor: 4h app spans from a wall-clock "now" after 20:00 would cross
	# local midnight into the excluded current day and break the 32h expectation.
	local sparse_now
	sparse_now=$(python3 -c 'import datetime as d; print(int(d.datetime(2026,7,12,12).astimezone().timestamp()))')
	local sparse_db="${tmpdir}/relative-sparse.db"
	create_knowledge_db "$sparse_db"
	insert_backlit_pair "$sparse_db" "$((sparse_now - 2 * 86400))" "$((sparse_now - 2 * 86400 + 3600))"
	insert_backlit_pair "$sparse_db" "$((sparse_now - 3600))" "$sparse_now"
	local day
	for day in 1 2 3 4 5 6 7 8; do
		insert_app_usage "$sparse_db" "$((sparse_now - day * 86400))" "$((sparse_now - day * 86400 + 4 * 3600))"
	done
	local sparse_json
	mkdir -p "${tmpdir}/sparse-home"
	sparse_json=$(HOME="${tmpdir}/sparse-home" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$sparse_now" profile_stats "$sparse_db")
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
	insert_backlit_span "$db" "$((zero_event - 600))" "$zero_event" 0
	HOME="$fixture_home" AIDEVOPS_SCREEN_TIME_OS_TYPE=Darwin AIDEVOPS_KNOWLEDGE_DB="$db" "$HELPER" snapshot >/dev/null
	local history="${fixture_home}/.aidevops/.agent-workspace/observability/screen-time.jsonl"
	local rows dates zero_hours
	rows=$(wc -l <"$history" | tr -d ' ')
	dates=$(jq -r '.date' "$history" | sort | tr '\n' ' ')
	zero_hours=$(jq -r --arg date "$zero_date" 'select(.date == $date) | .screen_hours' "$history")
	if [[ "$rows" != "2" || "$dates" != "${observed_date} ${zero_date} " || ("$zero_hours" != "0" && "$zero_hours" != "0.0") ]]; then
		fail "snapshot fabricated stale gap coverage or lost explicit zero: rows=${rows} dates=${dates} zero=${zero_hours}"
	fi

	# GH#37492: a recent day recorded while its display span was still open is
	# raised once the span is written; older recorded days stay final.
	local revise_values recent_date
	revise_values=$(python3 -c 'import datetime as d; day=d.date.today()-d.timedelta(days=1); epoch=lambda h:int(d.datetime.combine(day,d.time(h)).timestamp()); print(day,epoch(9),epoch(10),epoch(14),epoch(16))')
	local first_start first_end second_start second_end
	read -r recent_date first_start first_end second_start second_end <<<"$revise_values"
	insert_backlit_pair "$db" "$first_start" "$first_end"
	HOME="$fixture_home" AIDEVOPS_SCREEN_TIME_OS_TYPE=Darwin AIDEVOPS_KNOWLEDGE_DB="$db" "$HELPER" snapshot >/dev/null
	insert_backlit_pair "$db" "$second_start" "$second_end"
	insert_backlit_pair "$db" "$((observed_end + 600))" "$((observed_end + 1200))"
	HOME="$fixture_home" AIDEVOPS_SCREEN_TIME_OS_TYPE=Darwin AIDEVOPS_KNOWLEDGE_DB="$db" "$HELPER" snapshot >/dev/null
	HOME="$fixture_home" AIDEVOPS_SCREEN_TIME_OS_TYPE=Darwin AIDEVOPS_KNOWLEDGE_DB="$db" "$HELPER" snapshot >/dev/null
	local recent_values observed_rows
	recent_values=$(jq -r --arg date "$recent_date" 'select(.date == $date) | .screen_hours * 10 | round' "$history" | tr '\n' ' ')
	observed_rows=$(jq -r --arg date "$observed_date" 'select(.date == $date) | .date' "$history" | wc -l | tr -d ' ')
	[[ "$recent_values" == "10 30 " && "$observed_rows" == "1" ]] ||
		fail "snapshot did not raise the recent day once, or revised a final day: recent=${recent_values} observed_rows=${observed_rows}"
	pass "snapshot omits unobserved stale dates, records explicit zeros, and raises grown recent days"
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
		SELECT '/app/usage', ${cd_now} - 86400 - i*300, ${cd_now} - 86400 - i*300 + 600, 'recent.' || (i % 3) FROM recent_rows;"
	AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" AIDEVOPS_APP_STATS_INSTRUMENT_FILE="$instrument" \
		python3 "${SCRIPTS_DIR}/screen-time-interval-engine.py" apps --os-type Darwin --db "$db" >/dev/null
	local selected valid boundaries segments elapsed
	selected=$(jq -r '.rows_selected' "$instrument")
	valid=$(jq -r '.valid_intervals' "$instrument")
	boundaries=$(jq -r '.boundaries' "$instrument")
	segments=$(jq -r '.attributed_segments' "$instrument")
	elapsed=$(jq -r '.elapsed_ms' "$instrument")
	if [[ "$selected" -lt 1 || "$selected" -gt 200 || "$valid" != "$selected" || "$boundaries" -gt 402 || "$segments" -gt 401 ]] ||
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

test_profile_completed_day_dst_semantics() {
	local tmpdir="$1"
	local db="${tmpdir}/profile-dst.db"
	create_knowledge_db "$db"
	local values spring_start spring_end spring_now fall_start fall_end fall_now
	values=$(TZ=America/New_York python3 -c 'import datetime as d,time; time.tzset(); epoch=lambda x:int(x.timestamp()); s=d.date(2026,3,8); f=d.date(2026,11,1); print(epoch(d.datetime.combine(s,d.time.min)),epoch(d.datetime.combine(s+d.timedelta(days=1),d.time.min)),epoch(d.datetime(2026,3,9,12)),epoch(d.datetime.combine(f,d.time.min)),epoch(d.datetime.combine(f+d.timedelta(days=1),d.time.min)),epoch(d.datetime(2026,11,2,12)))')
	read -r spring_start spring_end spring_now fall_start fall_end fall_now <<<"$values"
	insert_app_usage "$db" "$spring_start" "$spring_end"
	insert_app_usage "$db" "$fall_start" "$fall_end"
	local spring_json fall_json
	spring_json=$(TZ=America/New_York AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$spring_now" profile_stats "$db")
	fall_json=$(TZ=America/New_York AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$fall_now" profile_stats "$db")
	[[ "$(printf '%s' "$spring_json" | jq -r '.today_hours')" == "23" || "$(printf '%s' "$spring_json" | jq -r '.today_hours')" == "23.0" ]] || fail "spring profile day was not the completed 23-hour local day"
	[[ "$(printf '%s' "$fall_json" | jq -r '.today_hours')" == "25" || "$(printf '%s' "$fall_json" | jq -r '.today_hours')" == "25.0" ]] || fail "fall profile day was not the completed 25-hour local day"
	[[ "$(printf '%s' "$spring_json" | jq -r '.periods.day.period_semantics')" == "completed-local-calendar-days" ]] || fail "screen profile omitted completed-day semantics"
	[[ "$(printf '%s' "$spring_json" | jq -r '.periods.day.period_start_epoch | floor')" == "$spring_start" && "$(printf '%s' "$spring_json" | jq -r '.periods.day.period_end_epoch | floor')" == "$spring_end" ]] || fail "screen profile exposed incorrect completed-day bounds"
	pass "profile screen periods use completed local days across DST"
	return 0
}

test_pmset_permission_free_fallback() {
	local tmpdir="$1"
	local now db fixture yesterday_start
	now=$(python3 -c 'import datetime as d; print(int(d.datetime(2026,7,12,12).astimezone().timestamp()))')
	yesterday_start=$(local_day_epoch "$now" 1 0)
	db="${tmpdir}/unreadable-knowledge.db"
	fixture="${tmpdir}/pmset.log"
	printf '%s\n' 'not sqlite' >"$db"
	python3 - "$fixture" "$yesterday_start" <<'PY'
import datetime as dt
import sys

target, start = sys.argv[1], int(sys.argv[2])
def display_row(offset, state):
    stamp = dt.datetime.fromtimestamp(start + offset).astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
    return f"{stamp} Notification         Display is turned {state}"
def assertion_row(offset, duration):
    stamp = dt.datetime.fromtimestamp(start + offset).astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
    return f'{stamp} Assertions PID 592(powerd) Released PreventUserIdleSystemSleep "Powerd - Prevent sleep while display is on" {duration}  id:0x1'
with open(target, "w", encoding="utf-8") as handle:
    # This unmatched state event previously remained open across the overnight
    # gap and inflated the completed day. Assertion durations are authoritative.
    handle.write(display_row(-2 * 3600, "on") + "\n")
    handle.write("malformed Display is turned on\n")
    handle.write(assertion_row(12 * 3600, "04:00:00") + "\n")
    handle.write(assertion_row(15 * 3600, "02:00:00") + "\n")
PY
	local fixture_home="${tmpdir}/pmset-home"
	mkdir -p "${fixture_home}/.aidevops/.agent-workspace/observability"
	python3 - "${fixture_home}/.aidevops/.agent-workspace/observability/screen-time.jsonl" "$now" <<'PY'
import datetime as dt
import json
import sys

today = dt.datetime.fromtimestamp(int(sys.argv[2])).date()
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    for age in range(2, 30):
        handle.write(json.dumps({"date": str(today - dt.timedelta(days=age)), "screen_hours": 1}) + "\n")
PY
	local output
	output=$(HOME="$fixture_home" AIDEVOPS_PMSET_FIXTURE="$fixture" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" profile_stats "$db")
	[[ "$(printf '%s' "$output" | jq -r '.today_hours')" == "6" || "$(printf '%s' "$output" | jq -r '.today_hours')" == "6.0" ]] || fail "pmset fallback did not union completed-day display intervals"
	[[ "$(printf '%s' "$output" | jq -r '.periods.day.source')" == "macos-pmset-display-assertions" ]] || fail "pmset fallback provenance missing"
	[[ "$(printf '%s' "$output" | jq -r '.periods.day.period_semantics')" == "completed-local-calendar-days" ]] || fail "pmset fallback changed profile period semantics"
	[[ "$(printf '%s' "$output" | jq -r '.periods.month.source')" == "screen-time-history:daily-observations" ]] || fail "short pmset coverage displaced richer month history"
	[[ "$(printf '%s' "$output" | jq -r '.periods.month.reason')" == "richer-calendar-coverage" ]] || fail "richer history selection reason missing"

	# GH#37492: the assertion still held (display on since yesterday 20:00) has
	# no log line until released, so it is read live from `pmset -g assertions`.
	local held_fixture="${tmpdir}/pmset-assertions.txt"
	printf '   pid 390(powerd): [0x000153bb000181aa] 16:00:00 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"  \n' >"$held_fixture"
	output=$(HOME="$fixture_home" AIDEVOPS_PMSET_FIXTURE="$fixture" AIDEVOPS_PMSET_ASSERTIONS_FIXTURE="$held_fixture" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" profile_stats "$db")
	[[ "$(printf '%s' "$output" | jq -r '.today_hours')" == "10" || "$(printf '%s' "$output" | jq -r '.today_hours')" == "10.0" ]] ||
		fail "held display assertion was not counted until release: ${output}"

	# A readable backlit stream with gaps is unioned with pmset, not replaced.
	local readable_db="${tmpdir}/pmset-union-knowledge.db"
	create_knowledge_db "$readable_db"
	insert_backlit_pair "$readable_db" "$((yesterday_start + 16 * 3600))" "$((yesterday_start + 17 * 3600))"
	insert_backlit_pair "$readable_db" "$((yesterday_start + 9 * 3600))" "$((yesterday_start + 10 * 3600))"
	output=$(HOME="$fixture_home" AIDEVOPS_PMSET_FIXTURE="$fixture" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" profile_stats "$readable_db")
	[[ "$(printf '%s' "$output" | jq -r '.today_hours')" == "7" || "$(printf '%s' "$output" | jq -r '.today_hours')" == "7.0" ]] ||
		fail "backlit spans and pmset assertions did not union to 7h: ${output}"
	[[ "$(printf '%s' "$output" | jq -r '.periods.day.source')" == "macos-knowledge-db:/display/isBacklit+macos-pmset-display-assertions" ]] ||
		fail "union provenance missing: ${output}"
	pass "permission-free pmset fallback supplies completed-day screen time, held assertions and backlit union"
	return 0
}

linux_helper() {
	local home="$1"
	local now="$2"
	shift 2
	HOME="$home" AIDEVOPS_SCREEN_TIME_OS_TYPE=Linux AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" "$HELPER" "$@"
	return $?
}

test_linux_input_activity_intervals() {
	local tmpdir="$1"
	local home="${tmpdir}/linux-activity-home"
	local observability="${home}/.aidevops/.agent-workspace/observability"
	mkdir -p "$observability"
	local base now yesterday
	read -r base now yesterday <<<"$(python3 -c 'import datetime as d; t=d.date.today(); y=t-d.timedelta(days=1); e=lambda day,h:int(d.datetime.combine(day,d.time(h)).timestamp()); print(e(y,9), e(t,12), y)')"
	# Legacy login-session proxy rows (24h/day, no collector) must never count.
	python3 - "${observability}/screen-time.jsonl" "$now" <<'PY'
import datetime as dt
import json
import sys
today = dt.datetime.fromtimestamp(int(sys.argv[2])).date()
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    for age in range(1, 7):
        handle.write(json.dumps({"date": str(today - dt.timedelta(days=age)), "screen_hours": 24}) + "\n")
PY
	local unsampled
	unsampled=$(linux_helper "$home" "$now" profile-stats)
	[[ "$(printf '%s' "$unsampled" | jq -r '[.collection_status, .today_hours, .week_hours] | map(tostring) | join(",")')" == "unavailable,null,null" ]] ||
		fail "Linux without input samples reported proxy or history hours: ${unsampled}"

	# GH#36709: completed days before the first sample are unknown, not 0h.
	local fresh_home="${tmpdir}/linux-fresh-sampler-home"
	mkdir -p "${fresh_home}/.aidevops/.agent-workspace/observability"
	PYTHONPATH="$SCRIPTS_DIR" python3 - "${fresh_home}/.aidevops/.agent-workspace/observability" "$((now - 7200))" <<'PY'
import sys
from screen_time_linux_activity import record_sample
directory, start = sys.argv[1], int(sys.argv[2])
for minute in range(0, 61):
    record_sample(directory, start + minute * 60, {"last_input": start + minute * 60, "kinds": ["tty-atime"]})
PY
	local fresh
	fresh=$(linux_helper "$fresh_home" "$now" profile-stats)
	[[ "$(printf '%s' "$fresh" | jq -r '[.collection_status, .today_hours, .week_hours, .month_hours, .year_hours, .periods.month.reason] | map(tostring) | join(",")')" == "ok,null,null,null,null,before-first-sample" ]] ||
		fail "Linux periods before the first sample rendered as observed zero: ${fresh}"

	# 09:00-10:00 typing, idle, one key at 10:58, suspended 11:00-13:00, one key at 13:10.
	PYTHONPATH="$SCRIPTS_DIR" python3 - "$observability" "$base" <<'PY'
import sys
from screen_time_linux_activity import record_sample
directory, base = sys.argv[1], int(sys.argv[2])
def last_input(minute):
    if minute <= 60:
        return minute * 60
    if minute < 118:
        return 3600
    return 118 * 60 if minute < 250 else 250 * 60
for minute in list(range(0, 121)) + list(range(240, 271)):
    record_sample(directory, base + minute * 60, {"last_input": base + last_input(minute), "kinds": ["tty-atime"]})
PY
	local output
	output=$(linux_helper "$home" "$now" profile-stats)
	# 65m (input + 5m cut-off) + 2m (tail clipped at suspend) + 5m = 1.2h.
	[[ "$(printf '%s' "$output" | jq -r '.today_hours')" == "1.2" ]] || fail "input activity intervals were not 1.2h: ${output}"
	[[ "$(printf '%s' "$output" | jq -r '.week_hours')" == "1.2" ]] || fail "legacy Linux proxy history displaced activity data: ${output}"
	[[ "$(printf '%s' "$output" | jq -r '.periods.day.source')" == "linux-input-activity:idle-cutoff-300s" ]] || fail "Linux activity provenance missing: ${output}"
	# Coverage starts at the first sample (yesterday 09:00), not 28 days ago.
	[[ "$(printf '%s' "$output" | jq -r '.periods.month.coverage_days')" == "0.6" ]] || fail "Linux month coverage was not clipped to sampling start: ${output}"

	linux_helper "$home" "$now" snapshot >/dev/null
	local snapshot_hours
	snapshot_hours=$(jq -r --arg date "$yesterday" 'select(.date == $date and ((.collector // "") | startswith("linux-input-activity"))) | .screen_hours' "${observability}/screen-time.jsonl")
	[[ "$snapshot_hours" == "1.2" ]] || fail "snapshot did not record the activity day beside legacy rows: ${snapshot_hours}"
	[[ "$(linux_helper "$home" "$now" history)" == *"1 valid day(s)"* ]] || fail "Linux history counted legacy proxy rows"
	# GH#36737: the snapshot's whole-day row must not displace partial live
	# coverage, and under 7 sampled days there is no 365-day projection.
	output=$(linux_helper "$home" "$now" profile-stats)
	[[ "$(printf '%s' "$output" | jq -r '[.periods.month.source, .periods.month.coverage_days, (.periods.month.observed_since_epoch | type), .year_hours, .periods.year.reason] | map(tostring) | join(",")')" == "linux-input-activity:idle-cutoff-300s,0.6,number,null,fewer-than-7-sampled-days" ]] ||
		fail "Linux snapshot history displaced live sampler coverage or projected a year: ${output}"
	pass "Linux input activity clips idle and suspend gaps and ignores legacy proxy history"
	return 0
}

write_probe_fixture() {
	local fixture="$1"
	local now="$2"
	local idle="$3"
	python3 - "$fixture" "$now" "$idle" <<'PY'
import json
import sys
now, idle = int(sys.argv[2]), sys.argv[3]
payload = {
    "sessions": [
        {"Type": "tty", "Class": "user", "State": "active", "TTY": "pts/7", "LockedHint": "no"},
        {"Type": "wayland", "Class": "user", "State": "active", "TTY": "tty2", "LockedHint": "yes"},
        {"Type": "x11", "Class": "user", "State": "online", "TTY": "", "LockedHint": "no", "IdleHint": "no", "IdleSinceHint": "0"},
        {"Type": "tty", "Class": "user", "State": "closing", "TTY": "pts/9", "LockedHint": "no"},
    ],
    "tty_atime": {"pts/7": now - 30, "pts/9": now - 5, "tty2": now - 1, "pts/3": now - 90},
    "who": ["pts/3", "tty2"],
}
if idle:
    payload["desktop_idle_seconds"] = int(idle)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
	return 0
}

test_linux_input_evidence_probe() {
	local tmpdir="$1"
	local now="$2"
	local home="${tmpdir}/linux-probe-home"
	local fixture="${tmpdir}/linux-probe.json"
	local state="${home}/.aidevops/.agent-workspace/observability/screen-activity-state.json"
	write_probe_fixture "$fixture" "$now" ""
	AIDEVOPS_SCREEN_ACTIVITY_FIXTURE="$fixture" linux_helper "$home" "$now" sample >/dev/null
	# Closing sessions, locked desktops and their VT are ignored; an unmanaged
	# desktop is reported as unobservable rather than active.
	[[ "$(jq -r '.last_input | floor' "$state")" == "$((now - 30))" ]] || fail "probe did not take the latest live tty input: $(<"$state")"
	[[ "$(jq -r '.evidence | join(",")' "$state")" == "graphical-idle-unavailable,locked,tty-atime" ]] || fail "probe evidence kinds wrong: $(<"$state")"
	[[ "$(linux_helper "$home" "$now" profile-stats | jq -r '.collection_status')" == "partial" ]] || fail "unobservable desktop was not surfaced as partial"
	write_probe_fixture "$fixture" "$now" 20
	AIDEVOPS_SCREEN_ACTIVITY_FIXTURE="$fixture" linux_helper "$home" "$((now + 60))" sample >/dev/null
	[[ "$(jq -r '.last_input | floor' "$state")" == "$((now + 40))" ]] || fail "desktop idle time was not used for graphical input: $(<"$state")"
	pass "Linux probe reads tty atime and desktop idle, ignoring locked and closing sessions"
	return 0
}

macos_input_helper() {
	local home="$1"
	local now="$2"
	shift 2
	if HOME="$home" AIDEVOPS_SCREEN_TIME_OS_TYPE=Darwin AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" "$HELPER" "$@"; then
		return 0
	fi
	return 1
}

test_macos_input_activity_matches_linux_rule() {
	local tmpdir="$1"
	local home="${tmpdir}/macos-input-home"
	local observability="${home}/.aidevops/.agent-workspace/observability"
	local fixture="${tmpdir}/hid-idle.json"
	mkdir -p "$observability"
	local base now
	read -r base now <<<"$(python3 -c 'import datetime as d; t=d.date.today(); y=t-d.timedelta(days=1); e=lambda day,h:int(d.datetime.combine(day,d.time(h)).timestamp()); print(e(y,9), e(t,12))')"
	# Yesterday from 09:00: typing to 09:30, idle to 10:00, locked 10:01-10:10,
	# another console user 10:11-10:20, typing again 10:21-10:30.
	AIDEVOPS_HID_IDLE_FIXTURE="$fixture" PYTHONPATH="$SCRIPTS_DIR" python3 - "$observability" "$base" "$fixture" <<'PY'
import json
import sys
from screen_time_macos_input import macos_input_sample
directory, base, fixture = sys.argv[1], int(sys.argv[2]), sys.argv[3]
for minute in range(0, 91):
    payload = {"idle_seconds": 0, "locked": False, "on_console": True}
    if 30 < minute <= 60:
        payload["idle_seconds"] = (minute - 30) * 60
    elif 60 < minute <= 70:
        payload["locked"] = True
    elif 70 < minute <= 80:
        payload["on_console"] = False
    with open(fixture, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
    macos_input_sample(base + minute * 60, directory)
PY
	local output
	output=$(macos_input_helper "$home" "$now" input-stats)
	# 30m typing + 5m cut-off + 9m after unlock = 44m = 0.7h.
	[[ "$(printf '%s' "$output" | jq -r '[.today_hours, .periods.day.source, (.evidence | join(","))] | map(tostring) | join(",")')" == "0.7,macos-input-activity:idle-cutoff-300s,hid-idle" ]] ||
		fail "macOS input activity did not follow the Linux idle, lock and console rules: ${output}"
	[[ "$(jq -r '.collector' "${observability}/screen-activity.jsonl" | sort -u)" == "macos-input-activity" ]] ||
		fail "macOS activity records were not tagged with the macOS collector"

	# Live sampler path through the helper: lock, unreadable idle, unknown console.
	local state="${observability}/screen-activity-state.json"
	printf '%s\n' '{"idle_seconds": 3, "locked": true, "on_console": true}' >"$fixture"
	AIDEVOPS_HID_IDLE_FIXTURE="$fixture" macos_input_helper "$home" "$now" sample >/dev/null
	[[ "$(jq -r '.evidence | join(",")' "$state")" == "locked" ]] || fail "locked Mac console counted input: $(<"$state")"
	printf '%s\n' '{"locked": false, "on_console": true}' >"$fixture"
	AIDEVOPS_HID_IDLE_FIXTURE="$fixture" macos_input_helper "$home" "$((now + 60))" sample >/dev/null
	[[ "$(macos_input_helper "$home" "$((now + 60))" input-stats | jq -r '.collection_status')" == "partial" ]] ||
		fail "unreadable HIDIdleTime was not surfaced as partial"
	printf '%s\n' '{"idle_seconds": 3}' >"$fixture"
	AIDEVOPS_HID_IDLE_FIXTURE="$fixture" macos_input_helper "$home" "$((now + 120))" sample >/dev/null
	[[ "$(jq -r '[(.last_input | floor), (.evidence | join(","))] | map(tostring) | join(",")' "$state")" == "$((now + 117)),hid-idle,console-state-unknown" ]] ||
		fail "HID idle input without console state was not sampled: $(<"$state")"
	pass "macOS input activity uses HIDIdleTime with the Linux idle cut-off, lock and console rules"
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
	local previous_noon
	previous_noon=$(local_day_epoch "$now" 1 12)
	insert_app_usage "$db" "$previous_noon" "$((previous_noon + 3600))"
	sqlite3 "$db" "
		UPDATE ZOBJECT SET ZVALUESTRING='valid.app' WHERE ZSTREAMNAME='/app/usage';
		INSERT INTO ZOBJECT (ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUEINTEGER) VALUES('/display/isBacklit','broken','broken',1);
		INSERT INTO ZOBJECT (ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUEINTEGER) VALUES('/display/isBacklit',1e999,1e999,1);
		INSERT INTO ZOBJECT (ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUESTRING) VALUES('/app/usage','broken','also-broken','bad.app');
		INSERT INTO ZOBJECT (ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUESTRING) VALUES('/app/usage',1e999,1e999,'infinite.app');"
	local profile_json app_json
	mkdir -p "${tmpdir}/corrupt-home"
	profile_json=$(HOME="${tmpdir}/corrupt-home" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" profile_stats "$db")
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
		"${SCRIPTS_DIR}/screen_time_macos_input.py" \
		"${SCRIPTS_DIR}/screen_time_macos_pmset.py" \
		"${SCRIPTS_DIR}/screen_time_linux.py" \
		"${SCRIPTS_DIR}/screen_time_linux_activity.py" \
		"${SCRIPTS_DIR}/screen_time_sources.py" \
		"${SCRIPTS_DIR}/screen_time_history.py" "$deploy_dir/"
	local output
	output=$(python3 "${deploy_dir}/screen-time-interval-engine.py" history-summary --os-type Unsupported)
	[[ "$(printf '%s' "$output" | jq -r '.valid_rows')" == "0" ]] || fail "deployed screen engine could not load sibling modules"
	pass "screen engine loads deployed sibling modules"
	return 0
}

test_leading_zero_dates_and_malformed_profile_payload_are_safe() {
	local tmpdir="$1"
	local fixture_home="${tmpdir}/leading-zero-home"
	local history="${fixture_home}/.aidevops/.agent-workspace/observability/screen-time.jsonl"
	mkdir -p "${history%/*}"
	printf '%s\n' \
		'{"date":"2026-08-08","screen_hours":1}' \
		'{"date":"2026-08-09","screen_hours":2}' >"$history"

	local now profile_json history_output
	now=$(python3 -c 'import datetime as d; print(int(d.datetime(2026, 8, 10, 12).astimezone().timestamp()))')
	profile_json=$(HOME="$fixture_home" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" \
		AIDEVOPS_SCREEN_TIME_OS_TYPE=Unsupported "$HELPER" profile-stats)
	history_output=$(HOME="$fixture_home" AIDEVOPS_SCREEN_TIME_OS_TYPE=Unsupported "$HELPER" history)
	if ! printf '%s' "$profile_json" | jq -e 'type == "object"' >/dev/null ||
		[[ "$(printf '%s' "$profile_json" | jq -r '.today_hours')" != "2" && "$(printf '%s' "$profile_json" | jq -r '.today_hours')" != "2.0" ]] ||
		[[ "$history_output" != *"Range: 2026-08-08 to 2026-08-09"* ]]; then
		fail "leading-zero history dates did not remain valid through profile-stats/history paths: ${profile_json} ${history_output}"
	fi

	local invalid_dir invalid_json
	invalid_dir="${tmpdir}/invalid-screen-time-helper"
	mkdir -p "$invalid_dir"
	printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" not-json' >"${invalid_dir}/screen-time-helper.sh"
	chmod +x "${invalid_dir}/screen-time-helper.sh"
	invalid_json=$(SCRIPT_DIR="$invalid_dir" bash -c 'source "$1"; _get_screen_time' _ "${SCRIPTS_DIR}/profile-readme-data-lib.sh")
	[[ "$(printf '%s' "$invalid_json" | jq -r '.collection_status')" == "unavailable" ]] ||
		fail "malformed screen-time output was not converted to unavailable JSON: ${invalid_json}"
	pass "leading-zero dates and malformed screen-time output stay JSON-safe"
	return 0
}

main() {
	local tmpdir
	tmpdir=$(mktemp -d)
	TMPDIR_TEST="$tmpdir"
	trap cleanup EXIT

	local db="${tmpdir}/knowledgeC.db"
	create_knowledge_db "$db"
	unset AIDEVOPS_SCREEN_ACTIVITY_DIR AIDEVOPS_SCREEN_ACTIVITY_FIXTURE AIDEVOPS_SCREEN_ACTIVITY_IDLE_SECONDS AIDEVOPS_HID_IDLE_FIXTURE
	: >"${tmpdir}/empty-pmset.log"
	export AIDEVOPS_PMSET_FIXTURE="${tmpdir}/empty-pmset.log"

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
	test_profile_completed_day_dst_semantics "$tmpdir"
	test_pmset_permission_free_fallback "$tmpdir"
	test_linux_input_activity_intervals "$tmpdir"
	test_linux_input_evidence_probe "$tmpdir" "$now"
	test_macos_input_activity_matches_linux_rule "$tmpdir"
	test_history_calendar_coverage_and_staleness "$tmpdir"
	test_corrupt_core_data_and_history_paths_are_safe "$tmpdir" "$now"
	test_screen_engine_sibling_modules_deploy_together "$tmpdir"
	test_leading_zero_dates_and_malformed_profile_payload_are_safe "$tmpdir"
	return 0
}

main "$@"
