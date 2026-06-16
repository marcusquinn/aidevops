#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Contributor Activity -- Session Time Tracking
# =============================================================================
# Queries AI assistant session databases (OpenCode/Claude Code) to compute
# human vs machine time, interactive vs worker session classification,
# and cross-repo aggregation.
#
# Usage: source "${SCRIPT_DIR}/contributor-activity-helper-session.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - sqlite3 (for database queries)
#   - python3 (for JSON processing)
#   - jq (for cross-repo JSON assembly)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CONTRIBUTOR_ACTIVITY_SESSION_LIB_LOADED:-}" ]] && return 0
_CONTRIBUTOR_ACTIVITY_SESSION_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

#######################################
# Auto-detect AI assistant session database path (t1665.5)
#
# Uses runtime registry to find the first available session DB.
# Falls back to hardcoded paths if registry is not loaded.
# Output: database path to stdout, or empty string if not found
#######################################
_session_time_detect_db() {
	# Use runtime registry if available (t1665.5)
	if type rt_list_ids &>/dev/null; then
		local _db_rt_id _db_path _db_fmt
		while IFS= read -r _db_rt_id; do
			_db_path=$(rt_session_db "$_db_rt_id") || continue
			_db_fmt=$(rt_session_db_format "$_db_rt_id") || continue
			# Only return SQLite databases (this function is used for SQL queries)
			if [[ "$_db_fmt" == "sqlite" && -n "$_db_path" && -f "$_db_path" ]]; then
				echo "$_db_path"
				return 0
			fi
		done < <(rt_list_ids)
		echo ""
		return 0
	fi

	# Fallback: hardcoded paths
	if [[ -f "${HOME}/.local/share/opencode/opencode.db" ]]; then
		echo "${HOME}/.local/share/opencode/opencode.db"
	elif [[ -f "${HOME}/.local/share/claude/Claude.db" ]]; then
		echo "${HOME}/.local/share/claude/Claude.db"
	else
		echo ""
	fi
	return 0
}

#######################################
# Resolve the OpenCode archive DB associated with a primary session DB.
# Arguments:
#   $1 - primary db path
# Output: archive database path to stdout, or empty string if unavailable
#######################################
_session_time_archive_db_for() {
	local db_path="$1"
	local archive_path="${OPENCODE_ARCHIVE_DB_PATH:-${OPENCODE_ARCHIVE_DB:-}}"

	if [[ -z "$archive_path" && "$db_path" == */opencode.db ]]; then
		archive_path="${db_path%/opencode.db}/opencode-archive.db"
	fi

	if [[ -n "$archive_path" && "$archive_path" != "$db_path" && -f "$archive_path" ]]; then
		printf '%s\n' "$archive_path"
	fi
	return 0
}

#######################################
# Detect aidevops OpenCode wrapper-scoped SQLite session DBs.
# Output: zero or more database paths, one per line
#######################################
_session_time_detect_wrapper_db_paths() {
	local work_dir="${AIDEVOPS_WORK_DIR:-${HOME}/.aidevops/.agent-workspace/work}"
	local candidate

	[[ -d "${work_dir}/opencode-interactive" ]] || return 0

	for candidate in "${work_dir}"/opencode-interactive/*/opencode/opencode.db; do
		[[ -f "$candidate" ]] || continue
		printf '%s\n' "$candidate"
	done
	return 0
}

#######################################
# Auto-detect all SQLite session DBs that make up the local history.
# Output: one database path per line, primary first, archive second if present,
# followed by aidevops wrapper-scoped OpenCode DBs.
#######################################
_session_time_detect_db_paths() {
	local primary_db
	primary_db=$(_session_time_detect_db)
	if [[ -n "$primary_db" ]]; then
		printf '%s\n' "$primary_db"

		local archive_db
		archive_db=$(_session_time_archive_db_for "$primary_db")
		if [[ -n "$archive_db" ]]; then
			printf '%s\n' "$archive_db"
		fi
	fi

	_session_time_detect_wrapper_db_paths
	return 0
}

#######################################
# Handle --period all for session_time
#
# Calls session_time for each sub-period and combines into a single table.
#
# Arguments:
#   $1 - repo path
#   $2 - format: "markdown" or "json"
#   $3 - db path (may be empty)
# Output: combined table or JSON to stdout
#######################################
_session_time_all_periods() {
	local repo_path="$1"
	local format="$2"
	local db_path="$3"

	# Build base args before the loop. repo_path may be "--all-dirs" (flag),
	# a real path, or empty. session_time() handles all three cases.
	local -a base_args=("$repo_path")
	[[ -n "$db_path" ]] && base_args+=(--db-path "$db_path")

	local all_periods=("day" "week" "month" "quarter" "year")
	local combined_json="["
	local first_period=true
	local p
	for p in "${all_periods[@]}"; do
		local p_json
		p_json=$(session_time "${base_args[@]}" --period "$p" --format json) || p_json="{}"
		if [[ "$first_period" == "true" ]]; then
			first_period=false
		else
			combined_json+=","
		fi
		combined_json+="{\"period\":\"${p}\",\"data\":${p_json}}"
	done
	combined_json+="]"

	echo "$combined_json" | python3 -c "
import sys
import json

format_type = sys.argv[1]
data = json.load(sys.stdin)

if format_type == 'json':
    result = {}
    for entry in data:
        result[entry['period']] = entry['data']
    print(json.dumps(result, indent=2))
else:
    if not data or all(d['data'].get('total_sessions', 0) == 0 for d in data):
        print('_No session data available._')
    else:
        print('| Period | Human Hours | AI Hours | Total Work | Sessions | Workers |')
        print('| --- | ---: | ---: | ---: | ---: | ---: |')
        for entry in data:
            p = entry['period'].capitalize()
            d = entry['data']
            human_h = d.get('total_human_hours', 0)
            ai_h = d.get('total_machine_hours', 0)
            total_h = round(human_h + ai_h, 1)
            i_sess = d.get('interactive_sessions', 0)
            w_sess = d.get('worker_sessions', 0)
            print(f'| {p} | {human_h}h | {ai_h}h | {total_h}h | {i_sess} | {w_sess} |')
" "$format"
	return 0
}

#######################################
# Query session database for time data
#
# Arguments:
#   $1 - db path
#   $2 - abs repo path (for SQL filtering; empty string = all directories)
#   $3 - since_ms (milliseconds threshold)
# Output: JSON array of session rows to stdout
#######################################
_session_time_query_db() {
	local db_path="$1"
	local abs_repo_path="$2"
	local since_ms="$3"

	# Query per-session human vs machine time using window functions.
	# LAG() compares each message with the previous one in the same session:
	#   human_time = user.created - prev_assistant.completed (reading + thinking + typing)
	#   machine_time = assistant.completed - assistant.created (AI generating)
	# Caps human gaps at 1 hour to exclude idle/abandoned sessions.
	# Worker sessions (headless) have ~0% human time; interactive ~70-85%.
	local query_result
	query_result=$(python3 - "$db_path" "$abs_repo_path" "$since_ms" <<'PY' 2>/dev/null
import json
import sqlite3
import sys

db_path = sys.argv[1]
abs_repo_path = sys.argv[2]
since_ms = int(float(sys.argv[3] or 0))

where = ["s.parent_id IS NULL", "m.time_created > ?"]
params = [since_ms]
if abs_repo_path:
    like_path = (
        abs_repo_path
        .replace('\\', '\\\\')
        .replace('%', '\\%')
        .replace('_', '\\_')
    )
    where.append("""(s.directory = ?
        OR s.directory LIKE ? ESCAPE '\\'
        OR s.directory LIKE ? ESCAPE '\\')""")
    params.extend([
        abs_repo_path,
        f"{like_path}.%",
        f"{like_path}-%",
    ])

query = f"""
    WITH msg_data AS (
        SELECT
            s.id AS session_id,
            s.title,
            s.directory,
            json_extract(m.data, '$.role') AS role,
            m.time_created AS created,
            json_extract(m.data, '$.time.completed') AS completed,
            LAG(json_extract(m.data, '$.role'))
                OVER (PARTITION BY s.id ORDER BY m.time_created) AS prev_role,
            LAG(json_extract(m.data, '$.time.completed'))
                OVER (PARTITION BY s.id ORDER BY m.time_created) AS prev_completed
        FROM session s
        JOIN message m ON m.session_id = s.id
        WHERE {' AND '.join(where)}
    )
    SELECT
        session_id,
        title,
        directory,
        MIN(created) AS first_message_ms,
        MAX(COALESCE(completed, created)) AS last_message_ms,
        SUM(CASE
            WHEN role = 'user' AND prev_role = 'assistant'
                 AND prev_completed IS NOT NULL
                 AND (created - prev_completed) BETWEEN 1 AND 3600000
            THEN created - prev_completed
            ELSE 0
        END) AS human_ms,
        SUM(CASE
            WHEN role = 'assistant' AND completed IS NOT NULL
                 AND (completed - created) > 0
            THEN completed - created
            ELSE 0
        END) AS machine_ms
    FROM msg_data
    GROUP BY session_id
    HAVING human_ms + machine_ms > 5000
"""

with sqlite3.connect(db_path, timeout=5) as conn:
    conn.row_factory = sqlite3.Row
    rows = [dict(row) for row in conn.execute(query, params)]
print(json.dumps(rows))
PY
	) || query_result="[]"

	# t1427: sqlite3 -json returns "" (not "[]") when no rows match.
	if [[ "$query_result" != "["* ]]; then
		query_result="[]"
	fi

	echo "$query_result"
	return 0
}

#######################################
# Query all detected session databases and de-duplicate copied archive rows.
# Arguments:
#   $1 - newline-delimited db paths
#   $2 - abs repo path (empty string = all directories)
#   $3 - since_ms (milliseconds threshold)
# Output: JSON array of session rows to stdout
#######################################
_session_time_query_db_paths() {
	local db_paths="$1"
	local abs_repo_path="$2"
	local since_ms="$3"
	local combined_json=""
	local db_path

	while IFS= read -r db_path; do
		[[ -z "$db_path" || ! -f "$db_path" ]] && continue

		local db_json
		db_json=$(_session_time_query_db "$db_path" "$abs_repo_path" "$since_ms") || db_json="[]"
		if echo "$db_json" | jq -e . >/dev/null 2>&1; then
			combined_json="${combined_json}${db_json}"$'\n'
		fi
	done <<<"$db_paths"

	if [[ -z "$combined_json" ]]; then
		echo "[]"
		return 0
	fi

	printf '%s' "$combined_json" | jq -s '
		add
		| reduce .[] as $row ([];
			if any(.[]; .session_id == $row.session_id) then . else . + [$row] end
		)
	' 2>/dev/null || echo "[]"
	return 0
}

#######################################
# Resolve the shared OpenCode observability database, if available.
# Output: database path to stdout, or empty string if unavailable
#######################################
_session_time_obs_db_path() {
	local obs_db="${AIDEVOPS_OBS_DB_FILE:-${OBS_DB_FILE:-${HOME}/.aidevops/.agent-workspace/observability/llm-requests.db}}"

	if [[ -f "$obs_db" ]]; then
		printf '%s\n' "$obs_db"
	fi
	return 0
}

#######################################
# Query OpenCode plugin observability for total AI generation duration.
# Arguments:
#   $1 - abs repo path (empty string = all directories)
#   $2 - since_ms (milliseconds threshold)
# Output: JSON object with observability_machine_ms and observability_sessions
#######################################
_session_time_query_observability() {
	local abs_repo_path="$1"
	local since_ms="$2"
	local obs_db
	obs_db=$(_session_time_obs_db_path)

	if [[ -z "$obs_db" ]] || ! sqlite3 -cmd ".timeout 5000" "$obs_db" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='llm_requests' LIMIT 1;" >/dev/null 2>&1; then
		printf '%s\n' '{"observability_machine_ms":0,"observability_sessions":0}'
		return 0
	fi

	local result machine_ms sessions
	result=$(python3 - "$obs_db" "$abs_repo_path" "$since_ms" <<'PY' 2>/dev/null
import sqlite3
import sys

db_path = sys.argv[1]
abs_repo_path = sys.argv[2]
since_ms = int(float(sys.argv[3] or 0))

where = ["timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', ? / 1000.0, 'unixepoch')"]
params = [since_ms]
if abs_repo_path:
    like_path = (
        abs_repo_path
        .replace('\\', '\\\\')
        .replace('%', '\\%')
        .replace('_', '\\_')
    )
    where.append("""(project_path = ?
        OR project_path LIKE ? ESCAPE '\\'
        OR project_path LIKE ? ESCAPE '\\'
        OR project_path LIKE ? ESCAPE '\\')""")
    params.extend([
        abs_repo_path,
        f"{like_path}/%",
        f"{like_path}.%",
        f"{like_path}-%",
    ])

query = f"""
    SELECT
        COALESCE(SUM(CASE WHEN duration_ms > 0 THEN duration_ms ELSE 0 END), 0),
        COUNT(DISTINCT session_id)
    FROM llm_requests
    WHERE {' AND '.join(where)};
"""

with sqlite3.connect(db_path, timeout=5) as conn:
    machine_ms, sessions = conn.execute(query, params).fetchone()
print(f"{machine_ms or 0}|{sessions or 0}")
PY
	) || result="0|0"

	IFS='|' read -r machine_ms sessions <<<"$result"
	machine_ms="${machine_ms:-0}"
	sessions="${sessions:-0}"
	printf '{"observability_machine_ms":%s,"observability_sessions":%s}\n' "$machine_ms" "$sessions"
	return 0
}

#######################################
# Merge observability AI-generation totals into session stats.
#
# Session DB timestamps are the best source for attended interactive time and
# title/directory classification. The plugin observability DB is the durable
# source for LLM generation duration across isolated headless workers. To avoid
# double-counting interactive generation already present in session DBs, use
# observability as a floor for total machine time: worker machine duration is
# at least (observability total - interactive machine duration).
#
# Arguments:
#   $1 - aggregated session stats JSON
#   $2 - observability stats JSON
# Output: merged stats JSON object to stdout
#######################################
_session_time_merge_observability_stats() {
	local stats_json="$1"
	local obs_json="$2"

	python3 -c "
import sys
import json

stats = json.loads(sys.argv[1] or '{}')
obs = json.loads(sys.argv[2] or '{}')

def number(value):
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0

def ms_field(name, hours_name):
    if name in stats:
        return int(number(stats.get(name)))
    return int(round(number(stats.get(hours_name)) * 3600000))

def ms_to_h(ms):
    return round(ms / 3600000, 1)

interactive_human_ms = ms_field('interactive_human_ms', 'interactive_human_hours')
interactive_machine_ms = ms_field('interactive_machine_ms', 'interactive_machine_hours')
worker_human_ms = ms_field('worker_human_ms', 'worker_human_hours')
worker_machine_ms = ms_field('worker_machine_ms', 'worker_machine_hours')
obs_machine_ms = int(number(obs.get('observability_machine_ms')))
obs_sessions = int(number(obs.get('observability_sessions')))

observed_worker_machine_ms = max(0, obs_machine_ms - interactive_machine_ms)
worker_machine_ms = max(worker_machine_ms, observed_worker_machine_ms)

interactive_sessions = int(number(stats.get('interactive_sessions')))
worker_sessions = int(number(stats.get('worker_sessions')))
if worker_machine_ms > 0 and worker_sessions == 0:
    worker_sessions = max(1, obs_sessions - interactive_sessions)

total_human_ms = interactive_human_ms + worker_human_ms
total_machine_ms = interactive_machine_ms + worker_machine_ms

stats.update({
    'interactive_human_ms': interactive_human_ms,
    'interactive_machine_ms': interactive_machine_ms,
    'worker_human_ms': worker_human_ms,
    'worker_machine_ms': worker_machine_ms,
    'interactive_sessions': interactive_sessions,
    'worker_sessions': worker_sessions,
    'interactive_human_hours': ms_to_h(interactive_human_ms),
    'interactive_machine_hours': ms_to_h(interactive_machine_ms),
    'worker_human_hours': ms_to_h(worker_human_ms),
    'worker_machine_hours': ms_to_h(worker_machine_ms),
    'total_human_hours': ms_to_h(total_human_ms),
    'total_machine_hours': ms_to_h(total_machine_ms),
    'total_sessions': interactive_sessions + worker_sessions,
    'observability_machine_hours': ms_to_h(obs_machine_ms),
    'observability_sessions': obs_sessions,
})

print(json.dumps(stats, indent=2))
" "$stats_json" "$obs_json"
	return 0
}

#######################################
# Classify and aggregate session rows into stats JSON
#
# Arguments:
#   $1 - JSON array of session rows (from stdin via pipe)
# Input: JSON array on stdin
# Output: aggregated stats JSON object to stdout
#######################################
_session_time_classify_and_aggregate() {
	python3 -c "
import sys
import json
import re

# Worker session title patterns
# Matches headless dispatches, PR fix sessions, CI fix sessions, review feedback,
# task sessions (t123, t123.4, t123-fix:), escalation sessions, health checks
worker_patterns = [
    re.compile(r'^Issue #\d+'),
    re.compile(r'^PR #\d+'),
    re.compile(r'^Fix PR\b', re.IGNORECASE),
    re.compile(r'^Review PR\b', re.IGNORECASE),
    re.compile(r'^Supervisor Pulse'),
    re.compile(r'/full-loop', re.IGNORECASE),
    re.compile(r'^dispatch:', re.IGNORECASE),
    re.compile(r'^Worker:', re.IGNORECASE),
    re.compile(r'^t\d+[\.\-:]', re.IGNORECASE),
    re.compile(r'^escalation-', re.IGNORECASE),
    re.compile(r'^health-check$', re.IGNORECASE),
    re.compile(r'failing CI\b', re.IGNORECASE),
    re.compile(r'CI fail', re.IGNORECASE),
    re.compile(r'CHANGES_REQUESTED', re.IGNORECASE),
    re.compile(r'CodeRabbit review', re.IGNORECASE),
    re.compile(r'address review', re.IGNORECASE),
    re.compile(r'review feedback', re.IGNORECASE),
    re.compile(r'^Fix qlty\b', re.IGNORECASE),
    re.compile(r'^Gemini feedback\b', re.IGNORECASE),
]

runtime_temp_dir_patterns = [
    re.compile(r'^/private/tmp/opencode(?:[.-].*)?$'),
    re.compile(r'^/tmp/opencode(?:[.-].*)?$'),
    re.compile(r'^/var/folders/.*/T/opencode.*$'),
]

def is_runtime_temp_directory(directory):
    if not directory:
        return False
    for pat in runtime_temp_dir_patterns:
        if pat.search(directory):
            return True
    return False

def classify_session(title, directory):
    if is_runtime_temp_directory(directory):
        return 'worker'
    for pat in worker_patterns:
        if pat.search(title):
            return 'worker'
    return 'interactive'

sessions = json.load(sys.stdin)
stats = {
    'interactive': {'count': 0, 'human_ms': 0, 'machine_ms': 0},
    'worker':      {'count': 0, 'human_ms': 0, 'machine_ms': 0},
}
first_seen = []
last_seen = []

def number_or_zero(value):
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0

for row in sessions:
    title = row.get('title') or ''
    directory = row.get('directory') or ''
    stype = classify_session(title, directory)
    stats[stype]['count'] += 1
    stats[stype]['human_ms'] += number_or_zero(row.get('human_ms'))
    stats[stype]['machine_ms'] += number_or_zero(row.get('machine_ms'))
    first_ms = number_or_zero(row.get('first_message_ms'))
    last_ms = number_or_zero(row.get('last_message_ms'))
    if first_ms > 0:
        first_seen.append(first_ms)
    if last_ms > 0:
        last_seen.append(last_ms)

def ms_to_h(ms):
    return round(ms / 3600000, 1)

i = stats['interactive']
w = stats['worker']
observed_days = 0
if first_seen and last_seen:
    observed_days = round(max(0, max(last_seen) - min(first_seen)) / 86400000, 1)

print(json.dumps({
    'interactive_sessions': i['count'],
    'interactive_human_ms': i['human_ms'],
    'interactive_machine_ms': i['machine_ms'],
    'interactive_human_hours': ms_to_h(i['human_ms']),
    'interactive_machine_hours': ms_to_h(i['machine_ms']),
    'worker_sessions': w['count'],
    'worker_human_ms': w['human_ms'],
    'worker_machine_ms': w['machine_ms'],
    'worker_human_hours': ms_to_h(w['human_ms']),
    'worker_machine_hours': ms_to_h(w['machine_ms']),
    'total_human_hours': ms_to_h(i['human_ms'] + w['human_ms']),
    'total_machine_hours': ms_to_h(i['machine_ms'] + w['machine_ms']),
    'total_sessions': i['count'] + w['count'],
    'observed_days': observed_days,
}, indent=2))
"
	return 0
}

#######################################
# Format aggregated session stats as table or JSON
#
# Arguments:
#   $1 - aggregated stats JSON object
#   $2 - format: "markdown" or "json"
#   $3 - period name (for empty-state messages)
# Output: formatted table or JSON to stdout
#######################################
_session_time_format_stats() {
	local stats_json="$1"
	local format="$2"
	local period="$3"

	echo "$stats_json" | python3 -c "
import sys
import json

format_type = sys.argv[1]
period_name = sys.argv[2]
result = json.load(sys.stdin)

total_sessions = result.get('total_sessions', 0)
total_human_h = result.get('total_human_hours', 0)
total_machine_h = result.get('total_machine_hours', 0)
i_human_h = result.get('interactive_human_hours', 0)
i_machine_h = result.get('interactive_machine_hours', 0)
w_human_h = result.get('worker_human_hours', 0)
w_machine_h = result.get('worker_machine_hours', 0)
i_count = result.get('interactive_sessions', 0)
w_count = result.get('worker_sessions', 0)

if format_type == 'json':
    print(json.dumps(result, indent=2))
else:
    if total_sessions == 0:
        print(f'_No session data for the last {period_name}._')
    else:
        total_work_h = round(total_human_h + total_machine_h, 1)
        print(f'| Type | Human Hours | AI Hours | Total Work | Sessions |')
        print(f'| --- | ---: | ---: | ---: | ---: |')
        print(f'| Interactive | {i_human_h}h | {i_machine_h}h | {round(i_human_h + i_machine_h, 1)}h | {i_count} |')
        print(f'| Workers/Runners | {w_human_h}h | {w_machine_h}h | {round(w_human_h + w_machine_h, 1)}h | {w_count} |')
        print(f'| **Total** | **{total_human_h}h** | **{total_machine_h}h** | **{total_work_h}h** | **{total_sessions}** |')
" "$format" "$period"

	return 0
}

#######################################
# Process session query results and format output
#
# Arguments:
#   $1 - JSON array of session rows
#   $2 - format: "markdown" or "json"
#   $3 - period name (for empty-state messages)
#   $4 - abs repo path (empty string = all directories)
#   $5 - since_ms (milliseconds threshold)
# Output: formatted table or JSON to stdout
#######################################
_session_time_process() {
	local query_result="$1"
	local format="$2"
	local period="$3"
	local abs_repo_path="${4:-}"
	local since_ms="${5:-0}"

	local stats_json obs_json
	stats_json=$(echo "$query_result" | _session_time_classify_and_aggregate)
	obs_json=$(_session_time_query_observability "$abs_repo_path" "$since_ms")
	stats_json=$(_session_time_merge_observability_stats "$stats_json" "$obs_json")
	_session_time_format_stats "$stats_json" "$format" "$period"
	return 0
}

#######################################
# Session time stats from AI assistant database
#
# Queries the OpenCode/Claude Code SQLite database to compute time spent
# in interactive sessions vs headless worker/runner sessions, per repo.
#
# Measures ACTUAL human time vs machine time per session using message
# timestamps: human_time = gap between assistant completing and next user
# message (reading + thinking + typing). machine_time = gap between
# assistant message created and completed (AI generating).
#
# Session type classification (by title pattern and runtime temp workdir):
#   - Worker: "Issue #*", "PR #*", "Supervisor Pulse", "/full-loop", "dispatch:", "Worker:"
#     or runtime temp directories used by classifier/headless sessions
#   - Interactive: everything else (root sessions only)
#   - Subagent: sessions with parent_id (excluded — time attributed to parent)
#
# Arguments:
#   $1 - repo path (filters sessions by directory)
#   --period day|week|month|quarter|year|all (optional, default: month)
#   --format markdown|json (optional, default: markdown)
#   --db-path <path> (optional, default: auto-detect)
#   --all-dirs (optional, skip directory filter — aggregate all sessions)
# Output: markdown table or JSON. "all" shows every period in one table.
#######################################
session_time() {
	local repo_path=""
	local period="month"
	local format="markdown"
	local db_path=""
	local all_dirs="false"

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--period)
			period="${2:-month}"
			shift 2
			;;
		--format)
			format="${2:-markdown}"
			shift 2
			;;
		--db-path)
			db_path="${2:-}"
			shift 2
			;;
		--all-dirs)
			all_dirs="true"
			shift
			;;
		*)
			if [[ -z "$repo_path" ]]; then
				repo_path="$1"
			fi
			shift
			;;
		esac
	done

	if [[ "$all_dirs" != "true" ]]; then
		repo_path="${repo_path:-.}"
	fi

	if ! command -v sqlite3 &>/dev/null; then
		if [[ "$format" == "json" ]]; then
			echo '{"interactive_sessions":0,"interactive_human_hours":0,"interactive_machine_hours":0,"worker_sessions":0,"worker_machine_hours":0,"total_human_hours":0,"total_machine_hours":0,"total_sessions":0}'
		else
			echo "_sqlite3 not available._"
		fi
		return 0
	fi

	# Handle --period all: collect JSON for each period and output combined table
	if [[ "$period" == "all" ]]; then
		# Pass "--all-dirs" as repo_path when aggregating all directories;
		# _session_time_all_periods passes it through to session_time().
		local all_repo_arg="$repo_path"
		[[ "$all_dirs" == "true" ]] && all_repo_arg="--all-dirs"
		_session_time_all_periods "$all_repo_arg" "$format" "$db_path"
		return 0
	fi

	local db_paths=""
	if [[ -n "$db_path" ]]; then
		db_paths="$db_path"
	else
		db_paths=$(_session_time_detect_db_paths)
	fi

	# Determine --since threshold in milliseconds (single Python call)
	local seconds
	case "$period" in
	day) seconds=86400 ;;
	week) seconds=604800 ;;
	28d | 28day | 28days) seconds=2419200 ;;
	month) seconds=2592000 ;;
	quarter) seconds=7776000 ;;
	year) seconds=31536000 ;;
	*) seconds=2592000 ;;
	esac
	local since_ms
	since_ms=$(python3 -c "import time; print(int((time.time() - ${seconds}) * 1000))")

	# Resolve repo_path to absolute for matching against session.directory
	# When --all-dirs is set, pass empty string to skip directory filtering
	local abs_repo_path=""
	if [[ "$all_dirs" != "true" ]]; then
		abs_repo_path=$(cd "$repo_path" 2>/dev/null && pwd) || abs_repo_path="$repo_path"
	fi

	local query_result
	if [[ -n "$db_paths" ]]; then
		query_result=$(_session_time_query_db_paths "$db_paths" "$abs_repo_path" "$since_ms")
	else
		query_result="[]"
	fi

	_session_time_process "$query_result" "$format" "$period" "$abs_repo_path" "$since_ms"
	return 0
}

#######################################
# Handle --period all for cross_repo_session_time
#
# Arguments:
#   $1 - format: "markdown" or "json"
#   $2..N - repo paths
# Output: combined table or JSON to stdout
#######################################
_cross_repo_session_time_all_periods() {
	local format="$1"
	shift
	local -a repo_paths=("$@")

	local all_periods=("day" "week" "month" "quarter" "year")
	local combined_json="["
	local first_period=true
	local p
	for p in "${all_periods[@]}"; do
		local p_json
		p_json=$(cross_repo_session_time "${repo_paths[@]}" --period "$p" --format json) || p_json="{}"
		if [[ "$first_period" == "true" ]]; then
			first_period=false
		else
			combined_json+=","
		fi
		combined_json+="{\"period\":\"${p}\",\"data\":${p_json}}"
	done
	combined_json+="]"

	echo "$combined_json" | python3 -c "
import sys
import json

format_type = sys.argv[1]
data = json.load(sys.stdin)

if format_type == 'json':
    result = {}
    for entry in data:
        result[entry['period']] = entry['data']
    print(json.dumps(result, indent=2))
else:
    repo_count = data[0]['data'].get('repo_count', 0) if data else 0
    if not data or all(d['data'].get('total_sessions', 0) == 0 for d in data):
        print(f'_No session data across {repo_count} repos._')
    else:
        print(f'_Across {repo_count} managed repos:_')
        print()
        print('| Period | Human Hours | AI Hours | Total Work | Sessions | Workers |')
        print('| --- | ---: | ---: | ---: | ---: | ---: |')
        for entry in data:
            p = entry['period'].capitalize()
            d = entry['data']
            human_h = d.get('total_human_hours', 0)
            ai_h = d.get('total_machine_hours', 0)
            total_h = round(human_h + ai_h, 1)
            i_sess = d.get('interactive_sessions', 0)
            w_sess = d.get('worker_sessions', 0)
            print(f'| {p} | {human_h}h | {ai_h}h | {total_h}h | {i_sess} | {w_sess} |')
" "$format"
	return 0
}

#######################################
# Collect and aggregate per-repo session time JSON
#
# Arguments:
#   $1 - period
#   $2..N - repo paths
# Output: aggregated JSON object to stdout
#######################################
_cross_repo_session_time_collect_and_aggregate() {
	local period="$1"
	shift

	# Collect JSON from each repo — use jq to assemble a valid JSON array.
	# This is robust against non-JSON responses from session_time (e.g., error strings).
	# Skip invalid repo paths to avoid inflating the repo count.
	local all_json=""
	local repo_count=0
	local rp
	for rp in "$@"; do
		if [[ ! -d "$rp/.git" && ! -f "$rp/.git" ]]; then
			echo "Warning: $rp is not a git repository, skipping" >&2
			continue
		fi
		local repo_json
		repo_json=$(session_time "$rp" --period "$period" --format json) || repo_json="{}"
		# Only include valid JSON objects in the array
		if echo "$repo_json" | jq -e . >/dev/null 2>&1; then
			all_json+="${repo_json}"$'\n'
		fi
		repo_count=$((repo_count + 1))
	done
	all_json=$(echo -n "$all_json" | jq -s '.')

	echo "$all_json" | python3 -c "
import sys
import json

repo_count = int(sys.argv[1])

repos = json.load(sys.stdin)

totals = {
    'interactive_sessions': 0,
    'interactive_human_hours': 0,
    'interactive_machine_hours': 0,
    'worker_sessions': 0,
    'worker_human_hours': 0,
    'worker_machine_hours': 0,
    'total_human_hours': 0,
}

for repo in repos:
    totals['interactive_sessions'] += repo.get('interactive_sessions', 0)
    totals['interactive_human_hours'] += repo.get('interactive_human_hours', 0)
    totals['interactive_machine_hours'] += repo.get('interactive_machine_hours', 0)
    totals['worker_sessions'] += repo.get('worker_sessions', 0)
    totals['worker_human_hours'] += repo.get('worker_human_hours', 0)
    totals['worker_machine_hours'] += repo.get('worker_machine_hours', 0)
    totals['total_human_hours'] += repo.get('total_human_hours', 0)

for k in ['interactive_human_hours', 'interactive_machine_hours', 'worker_human_hours', 'worker_machine_hours', 'total_human_hours']:
    totals[k] = round(totals[k], 1)

total_machine_h = round(totals['interactive_machine_hours'] + totals['worker_machine_hours'], 1)
total_sessions = totals['interactive_sessions'] + totals['worker_sessions']
totals['total_machine_hours'] = total_machine_h
totals['total_sessions'] = total_sessions
totals['repo_count'] = repo_count

print(json.dumps(totals, indent=2))
" "$repo_count"

	return 0
}

#######################################
# Format cross-repo session time aggregated JSON
#
# Arguments:
#   $1 - aggregated JSON object
#   $2 - format: "markdown" or "json"
#   $3 - period name
# Output: formatted table or JSON to stdout
#######################################
_cross_repo_session_time_format() {
	local aggregated_json="$1"
	local format="$2"
	local period="$3"

	echo "$aggregated_json" | python3 -c "
import sys
import json

format_type = sys.argv[1]
period_name = sys.argv[2]

totals = json.load(sys.stdin)
repo_count = totals.get('repo_count', 0)
total_human_h = totals.get('total_human_hours', 0)
total_machine_h = totals.get('total_machine_hours', 0)
total_sessions = totals.get('total_sessions', 0)

if format_type == 'json':
    print(json.dumps(totals, indent=2))
else:
    if total_sessions == 0:
        print(f'_No session data across {repo_count} repos for the last {period_name}._')
    else:
        print(f'_Across {repo_count} managed repos:_')
        print()
        total_work_h = round(total_human_h + total_machine_h, 1)
        i_work = round(totals['interactive_human_hours'] + totals['interactive_machine_hours'], 1)
        w_work = round(totals['worker_human_hours'] + totals['worker_machine_hours'], 1)
        print(f'| Type | Human Hours | AI Hours | Total Work | Sessions |')
        print(f'| --- | ---: | ---: | ---: | ---: |')
        print(f'| Interactive | {totals[\"interactive_human_hours\"]}h | {totals[\"interactive_machine_hours\"]}h | {i_work}h | {totals[\"interactive_sessions\"]} |')
        print(f'| Workers/Runners | {totals[\"worker_human_hours\"]}h | {totals[\"worker_machine_hours\"]}h | {w_work}h | {totals[\"worker_sessions\"]} |')
        print(f'| **Total** | **{total_human_h}h** | **{total_machine_h}h** | **{total_work_h}h** | **{total_sessions}** |')
" "$format" "$period"

	return 0
}

#######################################
# Cross-repo session time summary
#
# Aggregates session time across multiple repos. Privacy-safe (no repo names).
#
# Arguments:
#   $1..N - repo paths
#   --period day|week|month|quarter|year (optional, default: month)
#   --format markdown|json (optional, default: markdown)
# Output: aggregated table to stdout
#######################################
cross_repo_session_time() {
	local period="month"
	local format="markdown"
	local -a repo_paths=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--period)
			period="${2:-month}"
			shift 2
			;;
		--format)
			format="${2:-markdown}"
			shift 2
			;;
		*)
			repo_paths+=("$1")
			shift
			;;
		esac
	done

	if [[ ${#repo_paths[@]} -eq 0 ]]; then
		echo "Error: at least one repo path required" >&2
		return 1
	fi

	# Handle --period all: call cross_repo_session_time for each period and combine
	if [[ "$period" == "all" ]]; then
		_cross_repo_session_time_all_periods "$format" "${repo_paths[@]}"
		return 0
	fi

	local aggregated_json
	aggregated_json=$(_cross_repo_session_time_collect_and_aggregate "$period" "${repo_paths[@]}")

	_cross_repo_session_time_format "$aggregated_json" "$format" "$period"
	return 0
}
