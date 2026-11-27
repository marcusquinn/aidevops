#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Profile README Usage Rollup Library — incremental llm-requests aggregates
# =============================================================================
# The profile README model-usage tables used to re-aggregate the whole
# observability DB (17.9 GB, 2.3M rows) twice every hour. Under the routine's
# launchd Background I/O policy those scans exceeded the 300 s read bound, and
# the callers silently published unrelated fallback populations: a 12-request
# legacy JSONL table and a truncated OpenCode history (t19429, GH#40606).
#
# This library keeps a small derived rollup next to llm-requests.db with one
# row per (UTC hour, model, session). Each refresh reads only source rows above
# a rowid watermark, in short chunked transactions bounded by a time budget,
# so steady-state runs read about one hour of rows. The first build resumes
# across runs until it reaches the source head. The source is attached
# read-only and every read transaction is short, so checkpoints of the
# observability WAL are never pinned (t19374).
#
# Usage: sourced lazily by profile-readme-data-lib.sh.
#
# Dependencies:
#   - OBS_DB_FILE (orchestrator); PROFILE_USAGE_ROLLUP_DB_FILE overrides the
#     rollup path (default: profile-usage-rollup.db beside OBS_DB_FILE)
#   - timeout_sec from shared-constants.sh (optional), sqlite3, jq
#
# Tunables (environment):
#   PROFILE_USAGE_ROLLUP_BUDGET_S        catch-up budget per refresh (600)
#   PROFILE_USAGE_ROLLUP_CHUNK_ROWS      source rows per transaction (50000)
#   PROFILE_USAGE_ROLLUP_STEP_TIMEOUT_S  bound for one chunk (120); a timed-out
#                                        chunk rolls back and the next attempt
#                                        uses half the rows
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PROFILE_README_USAGE_ROLLUP_LIB_LOADED:-}" ]] && return 0
_PROFILE_README_USAGE_ROLLUP_LIB_LOADED=1

PROFILE_USAGE_ROLLUP_SCHEMA_VERSION="1"
PROFILE_USAGE_ROLLUP_MIN_CHUNK_ROWS=1000
PROFILE_USAGE_ROLLUP_COMPLETE="complete"
PROFILE_USAGE_ROLLUP_LAGGING="lagging"
PROFILE_USAGE_ROLLUP_INCOMPLETE="incomplete"

# --- Resolve the rollup DB path ---
_profile_usage_rollup_db_file() {
	if [[ -n "${PROFILE_USAGE_ROLLUP_DB_FILE:-}" ]]; then
		printf '%s\n' "$PROFILE_USAGE_ROLLUP_DB_FILE"
		return 0
	fi
	local obs_dir="${OBS_DB_FILE%/*}"
	[[ "$obs_dir" != "$OBS_DB_FILE" ]] || obs_dir="."
	printf '%s/profile-usage-rollup.db\n' "$obs_dir"
	return 0
}

# --- Read a positive integer tunable with a default ---
# Usage: _profile_usage_rollup_int <value> <default>
_profile_usage_rollup_int() {
	local value="$1"
	local default_value="$2"
	if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
		printf '%s\n' "$value"
	else
		printf '%s\n' "$default_value"
	fi
	return 0
}

# --- Build a read-only SQLite URI literal for ATTACH ---
# Percent-encodes the characters SQLite URI parsing treats specially, then
# doubles single quotes for the SQL string literal.
_profile_usage_rollup_source_uri() {
	local path="$1"
	path="${path//%/%25}"
	path="${path//\?/%3F}"
	path="${path//#/%23}"
	path="${path//\'/\'\'}"
	printf 'file:%s?mode=ro\n' "$path"
	return 0
}

# --- Run bounded SQL against the writable rollup DB ---
# Usage: _profile_usage_rollup_sql <rollup_db> <timeout_s> <sql>
# Returns sqlite3's status, or 124 when the bound expired.
_profile_usage_rollup_sql() {
	local rollup_db="$1"
	local timeout_s="$2"
	local sql="$3"
	if declare -F timeout_sec >/dev/null 2>&1; then
		timeout_sec "$timeout_s" sqlite3 -bail -cmd '.timeout 5000' "$rollup_db" "$sql" 2>/dev/null
		return $?
	fi
	sqlite3 -bail -cmd '.timeout 5000' "$rollup_db" "$sql" 2>/dev/null
	return $?
}

# --- Create the rollup schema, rebuilding on schema-version mismatch ---
_profile_usage_rollup_init() {
	local rollup_db="$1"
	local version=""
	version=$(sqlite3 -readonly -cmd '.timeout 5000' "$rollup_db" \
		"SELECT value FROM rollup_meta WHERE key = 'schema_version';" 2>/dev/null) || version=""
	[[ "$version" == "$PROFILE_USAGE_ROLLUP_SCHEMA_VERSION" ]] && return 0
	_profile_usage_rollup_sql "$rollup_db" 60 "
		BEGIN IMMEDIATE;
		DROP TABLE IF EXISTS usage_rollup;
		DROP TABLE IF EXISTS rollup_meta;
		CREATE TABLE rollup_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
		CREATE TABLE usage_rollup (
			hour TEXT NOT NULL,
			model_id TEXT NOT NULL,
			session_id TEXT NOT NULL,
			requests INTEGER NOT NULL,
			tokens_input INTEGER NOT NULL,
			tokens_output INTEGER NOT NULL,
			tokens_cache_read INTEGER NOT NULL,
			tokens_cache_write INTEGER NOT NULL,
			cost REAL NOT NULL,
			duration_ms REAL NOT NULL,
			duration_invalid INTEGER NOT NULL,
			PRIMARY KEY (hour, model_id, session_id)
		) WITHOUT ROWID;
		INSERT INTO rollup_meta (key, value) VALUES
			('schema_version', '${PROFILE_USAGE_ROLLUP_SCHEMA_VERSION}'),
			('watermark', '0'),
			('bootstrapped', '0');
		COMMIT;" >/dev/null || return 1
	return 0
}

# --- Reset the rollup after the source shrank below the watermark ---
_profile_usage_rollup_reset() {
	local rollup_db="$1"
	_profile_usage_rollup_sql "$rollup_db" 60 "
		BEGIN IMMEDIATE;
		DELETE FROM usage_rollup;
		UPDATE rollup_meta SET value = '0' WHERE key IN ('watermark', 'bootstrapped');
		COMMIT;" >/dev/null || return 1
	return 0
}

# --- Fold one chunk of source rows into the rollup ---
# Usage: _profile_usage_rollup_step <rollup_db> <chunk_rows> <timeout_s>
# Prints "lo|hi|source_max". The no-op UPDATE takes the rollup write lock
# before the watermark is read, so concurrent refreshes cannot double count.
_profile_usage_rollup_step() {
	local rollup_db="$1"
	local chunk_rows="$2"
	local timeout_s="$3"
	local valid_duration="TYPEOF(duration_ms) IN ('integer', 'real') AND duration_ms >= 0"
	_profile_usage_rollup_sql "$rollup_db" "$timeout_s" "
		ATTACH DATABASE '$(_profile_usage_rollup_source_uri "$OBS_DB_FILE")' AS src;
		BEGIN;
		UPDATE rollup_meta SET value = value WHERE key = 'watermark';
		CREATE TEMP TABLE step AS
			SELECT lo, MAX(lo, MIN(lo + ${chunk_rows}, source_max)) AS hi, source_max
			FROM (SELECT CAST((SELECT value FROM rollup_meta WHERE key = 'watermark') AS INTEGER) AS lo,
				COALESCE((SELECT MAX(rowid) FROM src.llm_requests), 0) AS source_max);
		INSERT INTO usage_rollup (hour, model_id, session_id, requests, tokens_input, tokens_output,
			tokens_cache_read, tokens_cache_write, cost, duration_ms, duration_invalid)
		SELECT COALESCE(SUBSTR(timestamp, 1, 13), ''), model_id, COALESCE(session_id, ''), COUNT(*),
			COALESCE(SUM(tokens_input), 0), COALESCE(SUM(tokens_output), 0),
			COALESCE(SUM(tokens_cache_read), 0), COALESCE(SUM(tokens_cache_write), 0),
			COALESCE(SUM(cost), 0.0),
			COALESCE(SUM(CASE WHEN ${valid_duration} THEN duration_ms ELSE 0 END), 0),
			SUM(CASE WHEN ${valid_duration} THEN 0 ELSE 1 END)
		FROM src.llm_requests
		WHERE rowid > (SELECT lo FROM temp.step) AND rowid <= (SELECT hi FROM temp.step)
			AND model_id IS NOT NULL AND model_id != ''
		GROUP BY 1, 2, 3
		ON CONFLICT (hour, model_id, session_id) DO UPDATE SET
			requests = requests + excluded.requests,
			tokens_input = tokens_input + excluded.tokens_input,
			tokens_output = tokens_output + excluded.tokens_output,
			tokens_cache_read = tokens_cache_read + excluded.tokens_cache_read,
			tokens_cache_write = tokens_cache_write + excluded.tokens_cache_write,
			cost = cost + excluded.cost,
			duration_ms = duration_ms + excluded.duration_ms,
			duration_invalid = duration_invalid + excluded.duration_invalid;
		UPDATE rollup_meta SET value = CAST((SELECT hi FROM temp.step) AS TEXT) WHERE key = 'watermark';
		UPDATE rollup_meta SET value = '1'
			WHERE key = 'bootstrapped' AND (SELECT hi >= source_max AND source_max >= lo FROM temp.step);
		COMMIT;
		SELECT lo || '|' || hi || '|' || source_max FROM temp.step;"
	return $?
}

# --- Read whether the rollup has ever reached the source head ---
_profile_usage_rollup_bootstrapped() {
	local rollup_db="$1"
	local flag=""
	flag=$(sqlite3 -readonly -cmd '.timeout 5000' "$rollup_db" \
		"SELECT value FROM rollup_meta WHERE key = 'bootstrapped';" 2>/dev/null) || flag=""
	[[ "$flag" == "1" ]] && return 0
	return 1
}

# --- Catch the rollup up with the source within the time budget ---
# Prints complete (at the source head), lagging (bootstrapped but behind after
# the budget or an error; still the same population) or incomplete (never
# reached the head: first build in progress, or the rollup is unusable).
_profile_usage_rollup_refresh() {
	local rollup_db budget_s chunk_rows step_timeout_s deadline
	rollup_db=$(_profile_usage_rollup_db_file)
	budget_s=$(_profile_usage_rollup_int "${PROFILE_USAGE_ROLLUP_BUDGET_S:-}" 600)
	chunk_rows=$(_profile_usage_rollup_int "${PROFILE_USAGE_ROLLUP_CHUNK_ROWS:-}" 50000)
	step_timeout_s=$(_profile_usage_rollup_int "${PROFILE_USAGE_ROLLUP_STEP_TIMEOUT_S:-}" 120)
	if ! _profile_usage_rollup_init "$rollup_db"; then
		printf '[profile-readme] WARN: usage rollup %s is unusable\n' "${rollup_db##*/}" >&2
		printf '%s\n' "$PROFILE_USAGE_ROLLUP_INCOMPLETE"
		return 0
	fi
	deadline=$(($(date +%s) + budget_s))
	local step="" lo="" hi="" source_max="" rc=0 resets=0 caught_up=false
	while [[ "$(date +%s)" -lt "$deadline" ]]; do
		rc=0
		step=$(_profile_usage_rollup_step "$rollup_db" "$chunk_rows" "$step_timeout_s") || rc=$?
		if [[ "$rc" -eq 124 && "$chunk_rows" -gt "$PROFILE_USAGE_ROLLUP_MIN_CHUNK_ROWS" ]]; then
			chunk_rows=$((chunk_rows / 2))
			continue
		fi
		[[ "$rc" -eq 0 ]] || break
		IFS='|' read -r lo hi source_max <<<"$step"
		[[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ && "$source_max" =~ ^[0-9]+$ ]] || break
		if [[ "$source_max" -lt "$lo" && "$resets" -eq 0 ]]; then
			resets=1
			_profile_usage_rollup_reset "$rollup_db" || break
			continue
		fi
		if [[ "$hi" -ge "$source_max" ]]; then
			caught_up=true
			break
		fi
	done
	if [[ "$caught_up" == true ]]; then
		printf '%s\n' "$PROFILE_USAGE_ROLLUP_COMPLETE"
	elif _profile_usage_rollup_bootstrapped "$rollup_db"; then
		printf '[profile-readme] WARN: usage rollup is behind the source (rc=%s, rowid %s of %s); publishing the indexed history\n' \
			"$rc" "${hi:-?}" "${source_max:-?}" >&2
		printf '%s\n' "$PROFILE_USAGE_ROLLUP_LAGGING"
	else
		printf '[profile-readme] WARN: usage rollup is still indexing (rc=%s, rowid %s of %s); keeping the published model usage\n' \
			"$rc" "${hi:-?}" "${source_max:-?}" >&2
		printf '%s\n' "$PROFILE_USAGE_ROLLUP_INCOMPLETE"
	fi
	return 0
}

# --- Aggregate the rollup into the profile model-usage JSON shape ---
# Usage: _profile_usage_rollup_query <30d|all>
# The 30-day window starts at the UTC hour 30 days ago.
_profile_usage_rollup_query() {
	local period="$1"
	local rollup_db window=""
	rollup_db=$(_profile_usage_rollup_db_file)
	[[ "$period" == "all" ]] || window="AND hour >= strftime('%Y-%m-%dT%H', 'now', '-30 days')"
	sqlite3 -readonly -cmd '.timeout 5000' "$rollup_db" "
		WITH filtered AS (
			SELECT * FROM usage_rollup WHERE requests > 0 ${window}
		)
		SELECT COALESCE(json_group_array(json_object(
			'model', model_id,
			'requests', requests,
			'input_tokens', input_tokens,
			'output_tokens', output_tokens,
			'cache_read_tokens', cache_read_tokens,
			'cache_write_tokens', cache_write_tokens,
			'session_count', session_count,
			'total_session_count', total_session_count,
			'session_hours', session_hours,
			'cost_total', ROUND(cost_total, 2)
		)), '[]')
		FROM (
			SELECT model_id,
				SUM(requests) AS requests,
				COUNT(DISTINCT NULLIF(session_id, '')) AS session_count,
				(SELECT COUNT(DISTINCT NULLIF(session_id, '')) FROM filtered) AS total_session_count,
				CASE WHEN SUM(duration_invalid) = 0
					THEN ROUND(SUM(duration_ms) / 3600000.0, 3) ELSE NULL END AS session_hours,
				SUM(tokens_input) AS input_tokens,
				SUM(tokens_output) AS output_tokens,
				SUM(tokens_cache_read) AS cache_read_tokens,
				SUM(tokens_cache_write) AS cache_write_tokens,
				SUM(cost) AS cost_total
			FROM filtered
			GROUP BY model_id
			ORDER BY requests DESC
		);" 2>/dev/null || return 1
	return 0
}
