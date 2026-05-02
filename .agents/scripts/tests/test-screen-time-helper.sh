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

main() {
	local tmpdir
	tmpdir=$(mktemp -d)
	TMPDIR_TEST="$tmpdir"
	trap cleanup EXIT

	local db="${tmpdir}/knowledgeC.db"
	sqlite3 "$db" "
		CREATE TABLE ZOBJECT (
			ZSTREAMNAME TEXT,
			ZCREATIONDATE REAL,
			ZVALUEINTEGER INTEGER,
			ZSTARTDATE REAL,
			ZENDDATE REAL
		);"

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
	sqlite3 "$healthy_db" "
		CREATE TABLE ZOBJECT (
			ZSTREAMNAME TEXT,
			ZCREATIONDATE REAL,
			ZVALUEINTEGER INTEGER,
			ZSTARTDATE REAL,
			ZENDDATE REAL
		);"
	insert_backlit_pair "$healthy_db" "$((now - one_hour * 8))" "$((now - one_hour))"
	insert_backlit_pair "$healthy_db" "$((now - one_day * 2))" "$((now - one_day * 2 + one_hour * 4))"
	insert_app_usage "$healthy_db" "$((now - one_hour * 8))" "$((now - one_hour))"
	insert_app_usage "$healthy_db" "$((now - one_day * 2))" "$((now - one_day * 2 + one_hour * 4))"

	local healthy_week_hours
	healthy_week_hours=$(query_hours "$healthy_db" 7)
	[[ "$healthy_week_hours" == "11.0" ]] || fail "expected healthy 7d backlit stream to remain primary at 11.0, got ${healthy_week_hours}"

	pass "screen-time helper falls back only for sparse backlit windows"
	return 0
}

main "$@"
