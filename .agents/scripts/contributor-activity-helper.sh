#!/usr/bin/env bash
# contributor-activity-helper.sh - Compute contributor activity from git history
#
# Sources activity data exclusively from immutable git commit history to prevent
# manipulation. Each contributor's activity is measured by commits, active days,
# and commit type (direct vs PR merges).
#
# Commit type detection uses the committer email field:
#   - committer=noreply@github.com → GitHub squash-merged a PR (automated output)
#   - committer=actions@github.com → GitHub Actions (bot, filtered out)
#   - committer=author's own email → direct push (human or headless CLI)
#
# GitHub noreply emails (NNN+login@users.noreply.github.com) are used to map
# git author names to GitHub logins, normalising multiple author name variants
# (e.g., "Marcus Quinn" and "marcusquinn" both map to "marcusquinn").
#
# Session time tracking uses the AI assistant database (OpenCode/Claude Code)
# to measure interactive (human) vs worker/runner (headless) session hours.
# Session type is classified by title pattern matching.
#
# Usage:
#   contributor-activity-helper.sh summary <repo-path> [--period day|week|month|year]
#   contributor-activity-helper.sh table <repo-path> [--format markdown|json]
#   contributor-activity-helper.sh user <repo-path> <github-login>
#   contributor-activity-helper.sh cross-repo-summary <repo-path1> [<repo-path2> ...] [--period month]
#   contributor-activity-helper.sh session-time <repo-path> [--period month]
#   contributor-activity-helper.sh cross-repo-session-time <path1> [path2 ...] [--period month]
#   contributor-activity-helper.sh person-stats <repo-path> [--period month] [--logins a,b]
#   contributor-activity-helper.sh cross-repo-person-stats <path1> [path2 ...] [--period month]
#
# Output: markdown table or JSON suitable for embedding in health issues.
#
# Exit codes:
#   0  - success (complete results)
#   1  - error (invalid args, missing repo, etc.)
#   75 - partial results (EX_TEMPFAIL from sysexits.h) — rate limit exhausted
#        mid-run. Stdout still contains valid output but may be truncated.
#        JSON output includes "partial": true. Markdown output includes an
#        HTML comment <!-- partial-results --> for machine-readable detection.
#        Callers should cache partial data but mark it as incomplete.

set -euo pipefail

# Distinct exit code for partial results (rate limit exhaustion mid-run).
# Callers can distinguish "complete success" (0) from "valid but truncated" (75)
# from "error" (1). 75 = EX_TEMPFAIL from sysexits.h — a temporary failure
# that may succeed on retry.
readonly EX_PARTIAL=75

# Shared Python helper functions injected into all Python blocks to avoid
# duplication. Defined once here, passed via sys.argv to each invocation.
# shellcheck disable=SC2016
PYTHON_HELPERS='
def email_to_login(email):
    """Map git email to GitHub login. Normalises noreply emails."""
    if email.endswith("@users.noreply.github.com"):
        local_part = email.split("@")[0]
        return local_part.split("+", 1)[1] if "+" in local_part else local_part
    if email in ("actions@github.com", "action@github.com"):
        return "github-actions"
    return email.split("@")[0]

def is_bot(login):
    """Check if a login belongs to a bot account."""
    if login == "github-actions":
        return True
    if login.endswith("[bot]") or login.endswith("-bot"):
        return True
    return False

def is_pr_merge(committer_email):
    """Detect GitHub squash-merge (committer=noreply@github.com)."""
    return committer_email == "noreply@github.com"
'

#######################################
# Compute activity summary for all contributors in a repo
#
# Reads git log and computes per-contributor stats:
#   - Direct commits (committer = author's own email)
#   - PR merges (committer = noreply@github.com, i.e. GitHub squash-merge)
#   - Total commits
#   - Active days (with day list in JSON for cross-repo deduplication)
#   - Average commits per active day
#
# Arguments:
#   $1 - repo path
#   $2 - period: "day", "week", "month", "year" (default: "month")
#   $3 - output format: "markdown" or "json" (default: "markdown")
# Output: formatted table to stdout
#######################################
compute_activity() {
	local repo_path="$1"
	local period="${2:-month}"
	local format="${3:-markdown}"

	if [[ ! -d "$repo_path/.git" && ! -f "$repo_path/.git" ]]; then
		echo "Error: $repo_path is not a git repository" >&2
		return 1
	fi

	# Determine --since based on period.
	# Values are hardcoded from the case statement below — no user input reaches
	# the git command, so word splitting via SC2086 is safe here.
	local since_arg=""
	case "$period" in
	day)
		since_arg="--since=1.day.ago"
		;;
	week)
		since_arg="--since=1.week.ago"
		;;
	month)
		since_arg="--since=1.month.ago"
		;;
	year)
		since_arg="--since=1.year.ago"
		;;
	*)
		since_arg="--since=1.month.ago"
		;;
	esac

	# Get git log: author_email|committer_email|ISO-date (one line per commit)
	# The committer email distinguishes PR merges from direct commits:
	#   noreply@github.com = GitHub squash-merged a PR
	#   author's own email = direct push
	local git_data
	# shellcheck disable=SC2086
	git_data=$(git -C "$repo_path" log --all --format='%ae|%ce|%aI' $since_arg) || git_data=""

	if [[ -z "$git_data" ]]; then
		if [[ "$format" == "json" ]]; then
			echo "[]"
		else
			echo "_No activity in the last ${period}._"
		fi
		return 0
	fi

	# Process with python3 for date arithmetic.
	# Variables passed via sys.argv to avoid shell injection.
	echo "$git_data" | python3 -c "
import sys
import json
from collections import defaultdict
from datetime import datetime, timezone

${PYTHON_HELPERS}

contributors = defaultdict(lambda: {
    'direct_commits': 0,
    'pr_merges': 0,
    'days': set(),
})

for line in sys.stdin:
    line = line.strip()
    if not line or '|' not in line:
        continue
    parts = line.split('|', 2)
    if len(parts) < 3:
        continue
    author_email, committer_email, date_str = parts
    login = email_to_login(author_email)

    # Skip bot accounts (GitHub Actions, Dependabot, Renovate, etc.)
    if is_bot(login):
        continue

    # Also skip if the committer is a bot (Actions, Dependabot, etc.)
    committer_login = email_to_login(committer_email)
    if is_bot(committer_login):
        continue

    try:
        dt = datetime.fromisoformat(date_str.replace('Z', '+00:00'))
    except ValueError:
        continue

    day = dt.strftime('%Y-%m-%d')
    contributors[login]['days'].add(day)

    if is_pr_merge(committer_email):
        contributors[login]['pr_merges'] += 1
    else:
        contributors[login]['direct_commits'] += 1

results = []
for login, data in sorted(contributors.items(), key=lambda x: -(x[1]['direct_commits'] + x[1]['pr_merges'])):
    active_days = len(data['days'])
    total = data['direct_commits'] + data['pr_merges']
    avg_per_day = total / active_days if active_days > 0 else 0

    entry = {
        'login': login,
        'direct_commits': data['direct_commits'],
        'pr_merges': data['pr_merges'],
        'total_commits': total,
        'active_days': active_days,
        'avg_commits_per_day': round(avg_per_day, 1),
    }
    # JSON includes day list for cross-repo deduplication
    if sys.argv[1] == 'json':
        entry['active_days_list'] = sorted(data['days'])
    results.append(entry)

format_type = sys.argv[1]
period_name = sys.argv[2]

if format_type == 'json':
    print(json.dumps(results, indent=2))
else:
    if not results:
        print(f'_No contributor activity in the last {period_name}._')
    else:
        print('| Contributor | Direct | PR Merges | Total | Active Days | Avg/Day |')
        print('| --- | ---: | ---: | ---: | ---: | ---: |')
        for r in results:
            print(f'| {r[\"login\"]} | {r[\"direct_commits\"]} | {r[\"pr_merges\"]} | {r[\"total_commits\"]} | {r[\"active_days\"]} | {r[\"avg_commits_per_day\"]} |')
" "$format" "$period"

	return 0
}

#######################################
# Get activity for a single user
#
# Arguments:
#   $1 - repo path
#   $2 - GitHub login
# Output: JSON with day/week/month/year breakdown
#######################################
user_activity() {
	local repo_path="$1"
	local target_login="$2"

	if [[ ! -d "$repo_path/.git" && ! -f "$repo_path/.git" ]]; then
		echo "Error: $repo_path is not a git repository" >&2
		return 1
	fi

	# Get all commits with author + committer emails
	local git_data
	git_data=$(git -C "$repo_path" log --all --format='%ae|%ce|%aI' --since='1.year.ago') || git_data=""

	# Target login passed via sys.argv to avoid shell injection.
	echo "$git_data" | python3 -c "
import sys
import json
from collections import defaultdict
from datetime import datetime, timedelta, timezone

${PYTHON_HELPERS}

target = sys.argv[1]
now = datetime.now(timezone.utc)

periods = {
    'today': now.replace(hour=0, minute=0, second=0, microsecond=0),
    'this_week': now - timedelta(days=now.weekday()),
    'this_month': now.replace(day=1, hour=0, minute=0, second=0, microsecond=0),
    'this_year': now.replace(month=1, day=1, hour=0, minute=0, second=0, microsecond=0),
}

counts = {p: {'direct_commits': 0, 'pr_merges': 0, 'days': set()} for p in periods}

for line in sys.stdin:
    line = line.strip()
    if not line or '|' not in line:
        continue
    parts = line.split('|', 2)
    if len(parts) < 3:
        continue
    author_email, committer_email, date_str = parts
    login = email_to_login(author_email)
    if login != target:
        continue

    # Skip if committer is a bot (Actions, Dependabot, etc.)
    committer_login = email_to_login(committer_email)
    if is_bot(committer_login):
        continue

    try:
        dt = datetime.fromisoformat(date_str.replace('Z', '+00:00'))
    except ValueError:
        continue

    day = dt.strftime('%Y-%m-%d')
    for period_name, start in periods.items():
        start_aware = start.replace(tzinfo=timezone.utc) if start.tzinfo is None else start
        if dt >= start_aware:
            counts[period_name]['days'].add(day)
            if is_pr_merge(committer_email):
                counts[period_name]['pr_merges'] += 1
            else:
                counts[period_name]['direct_commits'] += 1

result = {'login': target}
for period_name in ('today', 'this_week', 'this_month', 'this_year'):
    data = counts[period_name]
    total = data['direct_commits'] + data['pr_merges']
    result[period_name] = {
        'direct_commits': data['direct_commits'],
        'pr_merges': data['pr_merges'],
        'total_commits': total,
        'active_days': len(data['days']),
    }

print(json.dumps(result, indent=2))
" "$target_login"

	return 0
}

#######################################
# Cross-repo activity summary
#
# Aggregates activity across multiple repos without revealing repo names
# (cross-repo privacy). Uses active_days_list from JSON output to
# deduplicate days across repos (set union, not sum).
#
# Arguments:
#   $1..N - repo paths (at least one required)
#   --period day|week|month|year (optional, default: month)
#   --format markdown|json (optional, default: markdown)
# Output: aggregated table to stdout
#######################################
cross_repo_summary() {
	local period="month"
	local format="markdown"
	local -a repo_paths=()

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

	# Collect JSON (with active_days_list) from each repo, then aggregate
	local all_json="["
	local first="true"
	local repo_count=0
	for rp in "${repo_paths[@]}"; do
		if [[ ! -d "$rp/.git" && ! -f "$rp/.git" ]]; then
			echo "Warning: $rp is not a git repository, skipping" >&2
			continue
		fi
		local repo_json
		repo_json=$(compute_activity "$rp" "$period" "json") || repo_json="[]"
		if [[ "$first" == "true" ]]; then
			first="false"
		else
			all_json="${all_json},"
		fi
		all_json="${all_json}{\"data\":${repo_json}}"
		repo_count=$((repo_count + 1))
	done
	all_json="${all_json}]"

	# Aggregate across repos in Python — deduplicate active days via set union
	echo "$all_json" | python3 -c "
import sys
import json

format_type = sys.argv[1]
period_name = sys.argv[2]
repo_count = int(sys.argv[3])

repos = json.load(sys.stdin)

# Aggregate per contributor across all repos.
# active_days uses set union to avoid double-counting days where a
# contributor committed in multiple repos on the same calendar day.
totals = {}
for repo in repos:
    for entry in repo.get('data', []):
        login = entry['login']
        if login not in totals:
            totals[login] = {
                'direct_commits': 0,
                'pr_merges': 0,
                'total_commits': 0,
                'active_days_set': set(),
                'repo_count': 0,
            }
        totals[login]['direct_commits'] += entry.get('direct_commits', 0)
        totals[login]['pr_merges'] += entry.get('pr_merges', 0)
        totals[login]['total_commits'] += entry.get('total_commits', 0)
        # Union of day strings — deduplicates cross-repo overlaps
        for day_str in entry.get('active_days_list', []):
            totals[login]['active_days_set'].add(day_str)
        if entry.get('total_commits', 0) > 0:
            totals[login]['repo_count'] += 1

results = []
for login, data in sorted(totals.items(), key=lambda x: -x[1]['total_commits']):
    active_days = len(data['active_days_set'])
    avg = data['total_commits'] / active_days if active_days > 0 else 0
    results.append({
        'login': login,
        'direct_commits': data['direct_commits'],
        'pr_merges': data['pr_merges'],
        'total_commits': data['total_commits'],
        'active_days': active_days,
        'repos_active': data['repo_count'],
        'avg_commits_per_day': round(avg, 1),
    })

if format_type == 'json':
    print(json.dumps(results, indent=2))
else:
    if not results:
        print(f'_No cross-repo activity in the last {period_name}._')
    else:
        print(f'_Across {repo_count} managed repos:_')
        print()
        print('| Contributor | Direct | PR Merges | Total | Active Days | Repos | Avg/Day |')
        print('| --- | ---: | ---: | ---: | ---: | ---: | ---: |')
        for r in results:
            print(f'| {r[\"login\"]} | {r[\"direct_commits\"]} | {r[\"pr_merges\"]} | {r[\"total_commits\"]} | {r[\"active_days\"]} | {r[\"repos_active\"]} | {r[\"avg_commits_per_day\"]} |')
" "$format" "$period" "$repo_count"

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
# Session type classification (by title pattern):
#   - Worker: "Issue #*", "PR #*", "Supervisor Pulse", "/full-loop", "dispatch:", "Worker:"
#   - Interactive: everything else (root sessions only)
#   - Subagent: sessions with parent_id (excluded — time attributed to parent)
#
# Arguments:
#   $1 - repo path (filters sessions by directory)
#   --period day|week|month|quarter|year|all (optional, default: month)
#   --format markdown|json (optional, default: markdown)
#   --db-path <path> (optional, default: auto-detect)
# Output: markdown table or JSON. "all" shows every period in one table.
#######################################
session_time() {
	local repo_path=""
	local period="month"
	local format="markdown"
	local db_path=""

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
		*)
			if [[ -z "$repo_path" ]]; then
				repo_path="$1"
			fi
			shift
			;;
		esac
	done

	repo_path="${repo_path:-.}"

	# Auto-detect database path
	if [[ -z "$db_path" ]]; then
		if [[ -f "${HOME}/.local/share/opencode/opencode.db" ]]; then
			db_path="${HOME}/.local/share/opencode/opencode.db"
		elif [[ -f "${HOME}/.local/share/claude/Claude.db" ]]; then
			db_path="${HOME}/.local/share/claude/Claude.db"
		else
			if [[ "$format" == "json" ]]; then
				echo '{"interactive_sessions":0,"interactive_human_hours":0,"interactive_machine_hours":0,"worker_sessions":0,"worker_machine_hours":0,"total_human_hours":0,"total_machine_hours":0,"total_sessions":0}'
			else
				echo "_Session database not found._"
			fi
			return 0
		fi
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
		local all_periods=("day" "week" "month" "quarter" "year")
		local combined_json="["
		local first_period=true
		for p in "${all_periods[@]}"; do
			local p_json
			local -a db_args=()
			if [[ -n "$db_path" ]]; then
				db_args+=(--db-path "$db_path")
			fi
			p_json=$(session_time "$repo_path" --period "$p" --format json "${db_args[@]}") || p_json="{}"
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
	fi

	# Determine --since threshold in milliseconds (single Python call)
	local seconds
	case "$period" in
	day) seconds=86400 ;;
	week) seconds=604800 ;;
	month) seconds=2592000 ;;
	quarter) seconds=7776000 ;;
	year) seconds=31536000 ;;
	*) seconds=2592000 ;;
	esac
	local since_ms
	since_ms=$(python3 -c "import time; print(int((time.time() - ${seconds}) * 1000))")

	# Resolve repo_path to absolute for matching against session.directory
	local abs_repo_path
	abs_repo_path=$(cd "$repo_path" 2>/dev/null && pwd) || abs_repo_path="$repo_path"

	# Escape path for safe SQL embedding:
	# - Single quotes doubled per SQL standard (prevents injection)
	# - % and _ escaped for LIKE patterns (prevents wildcard matching)
	# since_ms is always numeric (computed by Python above), no injection risk.
	local safe_path="${abs_repo_path//\'/\'\'}"
	local like_path="${safe_path//%/\\%}"
	like_path="${like_path//_/\\_}"

	# Query per-session human vs machine time using window functions.
	# LAG() compares each message with the previous one in the same session:
	#   human_time = user.created - prev_assistant.completed (reading + thinking + typing)
	#   machine_time = assistant.completed - assistant.created (AI generating)
	# Caps human gaps at 1 hour to exclude idle/abandoned sessions.
	# Worker sessions (headless) have ~0% human time; interactive ~70-85%.
	local query_result
	query_result=$(sqlite3 -json "$db_path" "
		WITH msg_data AS (
			SELECT
				s.id AS session_id,
				s.title,
				json_extract(m.data, '\$.role') AS role,
				m.time_created AS created,
				json_extract(m.data, '\$.time.completed') AS completed,
				LAG(json_extract(m.data, '\$.role'))
					OVER (PARTITION BY s.id ORDER BY m.time_created) AS prev_role,
				LAG(json_extract(m.data, '\$.time.completed'))
					OVER (PARTITION BY s.id ORDER BY m.time_created) AS prev_completed
			FROM session s
			JOIN message m ON m.session_id = s.id
			WHERE s.parent_id IS NULL
			  AND m.time_created > ${since_ms}
			  AND (s.directory = '${safe_path}'
			       OR s.directory LIKE '${like_path}.%' ESCAPE '\\'
			       OR s.directory LIKE '${like_path}-%' ESCAPE '\\')
		)
		SELECT
			session_id,
			title,
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
	") || query_result="[]"

	# t1427: sqlite3 -json returns "" (not "[]") when no rows match.
	if [[ "$query_result" != "["* ]]; then
		query_result="[]"
	fi

	# Process JSON in Python for classification and aggregation
	echo "$query_result" | python3 -c "
import sys
import json
import re

format_type = sys.argv[1]
period_name = sys.argv[2]

# Worker session title patterns
# Matches headless dispatches, PR fix sessions, CI fix sessions, review feedback,
# task-ID-prefixed sessions (t123, t123.4, t123-fix:), escalation sessions, health checks
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

def classify_session(title):
    for pat in worker_patterns:
        if pat.search(title):
            return 'worker'
    return 'interactive'

sessions = json.load(sys.stdin)

stats = {
    'interactive': {'count': 0, 'human_ms': 0, 'machine_ms': 0},
    'worker':      {'count': 0, 'human_ms': 0, 'machine_ms': 0},
}

for row in sessions:
    title = row.get('title', '')
    human_ms = row.get('human_ms', 0)
    machine_ms = row.get('machine_ms', 0)
    stype = classify_session(title)
    stats[stype]['count'] += 1
    stats[stype]['human_ms'] += human_ms
    stats[stype]['machine_ms'] += machine_ms

def ms_to_h(ms):
    return round(ms / 3600000, 1)

i = stats['interactive']
w = stats['worker']
i_human_h = ms_to_h(i['human_ms'])
i_machine_h = ms_to_h(i['machine_ms'])
w_human_h = ms_to_h(w['human_ms'])
w_machine_h = ms_to_h(w['machine_ms'])
total_human_h = ms_to_h(i['human_ms'] + w['human_ms'])
total_machine_h = ms_to_h(i['machine_ms'] + w['machine_ms'])
total_sessions = i['count'] + w['count']

result = {
    'interactive_sessions': i['count'],
    'interactive_human_hours': i_human_h,
    'interactive_machine_hours': i_machine_h,
    'worker_sessions': w['count'],
    'worker_human_hours': w_human_h,
    'worker_machine_hours': w_machine_h,
    'total_human_hours': total_human_h,
    'total_machine_hours': total_machine_h,
    'total_sessions': total_sessions,
}

if format_type == 'json':
    print(json.dumps(result, indent=2))
else:
    if total_sessions == 0:
        print(f'_No session data for the last {period_name}._')
    else:
        total_work_h = round(total_human_h + total_machine_h, 1)
        print(f'| Type | Human Hours | AI Hours | Total Work | Sessions |')
        print(f'| --- | ---: | ---: | ---: | ---: |')
        print(f'| Interactive | {i_human_h}h | {i_machine_h}h | {round(i_human_h + i_machine_h, 1)}h | {i[\"count\"]} |')
        print(f'| Workers/Runners | {w_human_h}h | {w_machine_h}h | {round(w_human_h + w_machine_h, 1)}h | {w[\"count\"]} |')
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
		local all_periods=("day" "week" "month" "quarter" "year")
		local combined_json="["
		local first_period=true
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
	fi

	# Collect JSON from each repo — use jq to assemble a valid JSON array.
	# This is robust against non-JSON responses from session_time (e.g., error strings).
	# Skip invalid repo paths to avoid inflating the repo count.
	local all_json=""
	local repo_count=0
	for rp in "${repo_paths[@]}"; do
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

format_type = sys.argv[1]
period_name = sys.argv[2]
repo_count = int(sys.argv[3])

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

total_human_h = totals['total_human_hours']
total_machine_h = round(totals['interactive_machine_hours'] + totals['worker_machine_hours'], 1)
total_sessions = totals['interactive_sessions'] + totals['worker_sessions']

if format_type == 'json':
    totals['total_human_hours'] = total_human_h
    totals['total_machine_hours'] = total_machine_h
    totals['total_sessions'] = total_sessions
    totals['repo_count'] = repo_count
    print(json.dumps(totals, indent=2))
else:
    if total_sessions == 0:
        print(f'_No session data across {repo_count} repos for the last {period_name}._')
    else:
        print(f'_Across {repo_count} managed repos:_')
        print()
        total_work_h = round(total_human_h + total_machine_h, 1)
        i = totals
        i_work = round(i['interactive_human_hours'] + i['interactive_machine_hours'], 1)
        w_work = round(i['worker_human_hours'] + i['worker_machine_hours'], 1)
        print(f'| Type | Human Hours | AI Hours | Total Work | Sessions |')
        print(f'| --- | ---: | ---: | ---: | ---: |')
        print(f'| Interactive | {i[\"interactive_human_hours\"]}h | {i[\"interactive_machine_hours\"]}h | {i_work}h | {i[\"interactive_sessions\"]} |')
        print(f'| Workers/Runners | {i[\"worker_human_hours\"]}h | {i[\"worker_machine_hours\"]}h | {w_work}h | {i[\"worker_sessions\"]} |')
        print(f'| **Total** | **{total_human_h}h** | **{total_machine_h}h** | **{total_work_h}h** | **{total_sessions}** |')
" "$format" "$period" "$repo_count"

	return 0
}

#######################################
# Per-person GitHub output stats
#
# Queries GitHub Search API for each contributor's issues, PRs, and comments.
# Contributors are auto-discovered from git history (non-bot authors).
#
# Arguments:
#   $1 - repo path (used to derive slug and discover contributors)
#   --period day|week|month|quarter|year (optional, default: month)
#   --format markdown|json (optional, default: markdown)
#   --logins login1,login2 (optional, override auto-discovery)
# Output: per-person table to stdout
#######################################
person_stats() {
	local repo_path=""
	local period="month"
	local format="markdown"
	local logins_override=""

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
		--logins)
			logins_override="${2:-}"
			shift 2
			;;
		*)
			if [[ -z "$repo_path" ]]; then
				repo_path="$1"
			fi
			shift
			;;
		esac
	done

	repo_path="${repo_path:-.}"

	if [[ ! -d "$repo_path/.git" && ! -f "$repo_path/.git" ]]; then
		echo "Error: $repo_path is not a git repository" >&2
		return 1
	fi

	# Derive repo slug from git remote
	local remote_url
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null) || remote_url=""
	if [[ -z "$remote_url" ]]; then
		echo "Error: no origin remote found" >&2
		return 1
	fi

	# Extract owner/repo from various URL formats
	local slug
	slug=$(echo "$remote_url" | sed -E 's#.*github\.com[:/]##; s/\.git$//')
	if [[ -z "$slug" || "$slug" == "$remote_url" ]]; then
		echo "Error: could not extract repo slug from $remote_url" >&2
		return 1
	fi

	# Calculate date threshold for the period
	local since_date
	case "$period" in
	day) since_date=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d '1 day ago' +%Y-%m-%d) ;;
	week) since_date=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d) ;;
	month) since_date=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d '30 days ago' +%Y-%m-%d) ;;
	quarter) since_date=$(date -v-90d +%Y-%m-%d 2>/dev/null || date -d '90 days ago' +%Y-%m-%d) ;;
	year) since_date=$(date -v-365d +%Y-%m-%d 2>/dev/null || date -d '365 days ago' +%Y-%m-%d) ;;
	*) since_date=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d '30 days ago' +%Y-%m-%d) ;;
	esac

	# Discover contributor logins from git history or use override
	local logins_csv
	if [[ -n "$logins_override" ]]; then
		logins_csv="$logins_override"
	else
		# Extract unique non-bot logins from git history using the same
		# noreply email mapping as compute_activity
		local git_data
		git_data=$(git -C "$repo_path" log --all --format='%ae|%ce' --since="$since_date") || git_data=""
		logins_csv=$(echo "$git_data" | python3 -c "
import sys

${PYTHON_HELPERS}

logins = set()
for line in sys.stdin:
    line = line.strip()
    if not line or '|' not in line:
        continue
    parts = line.split('|', 1)
    if len(parts) < 2:
        continue
    author_email, committer_email = parts
    login = email_to_login(author_email)
    committer_login = email_to_login(committer_email)
    if is_bot(login) or is_bot(committer_login):
        continue
    logins.add(login)

print(','.join(sorted(logins)))
")
	fi

	if [[ -z "$logins_csv" ]]; then
		echo "_No contributors found for the last ${period}._"
		return 0
	fi

	# Query GitHub Search API for each login.
	# Uses gh api with search/issues endpoint — returns total_count without pagination.
	# Rate limit: 30 requests/min for search API. With 4 queries per user,
	# we can handle ~7 users per minute. If budget is exhausted, bail out
	# with partial results instead of blocking (t1429).
	local results_json="["
	local first=true
	local _ps_partial=false
	local IFS=','
	for login in $logins_csv; do
		# Check search API rate limit before each batch of 4 queries per user
		local remaining
		remaining=$(gh api rate_limit --jq '.resources.search.remaining' 2>/dev/null) || remaining=30
		if [[ "$remaining" -lt 5 ]]; then
			# t1429: bail out with partial results instead of sleeping.
			# The old code slept until reset, creating an infinite blocking
			# loop when multiple users × repos exhausted the 30 req/min budget.
			echo "Rate limit exhausted (${remaining} remaining), returning partial results" >&2
			_ps_partial=true
			break
		fi

		# Issues created by this user in this repo since the date
		local issues_created
		issues_created=$(gh api "search/issues?q=author:${login}+repo:${slug}+type:issue+created:>${since_date}&per_page=1" --jq '.total_count' 2>/dev/null) || issues_created=0

		# PRs created
		local prs_created
		prs_created=$(gh api "search/issues?q=author:${login}+repo:${slug}+type:pr+created:>${since_date}&per_page=1" --jq '.total_count' 2>/dev/null) || prs_created=0

		# PRs merged
		local prs_merged
		prs_merged=$(gh api "search/issues?q=author:${login}+repo:${slug}+type:pr+is:merged+merged:>${since_date}&per_page=1" --jq '.total_count' 2>/dev/null) || prs_merged=0

		# Issues/PRs commented on (commenter: qualifier counts unique issues, not comments)
		local commented_on
		commented_on=$(gh api "search/issues?q=commenter:${login}+repo:${slug}+updated:>${since_date}&per_page=1" --jq '.total_count' 2>/dev/null) || commented_on=0

		if [[ "$first" == "true" ]]; then
			first=false
		else
			results_json+=","
		fi
		results_json+="{\"login\":\"${login}\",\"issues_created\":${issues_created},\"prs_created\":${prs_created},\"prs_merged\":${prs_merged},\"commented_on\":${commented_on}}"
	done
	unset IFS
	results_json+="]"

	# Format output (pass partial flag so callers can detect truncated data)
	echo "$results_json" | python3 -c "
import sys
import json

format_type = sys.argv[1]
period_name = sys.argv[2]
is_partial = sys.argv[3] == 'true'

data = json.load(sys.stdin)

# Sort by total output (issues + PRs + comments) descending
for d in data:
    d['total_output'] = d['issues_created'] + d['prs_created'] + d['commented_on']
data.sort(key=lambda x: x['total_output'], reverse=True)

if format_type == 'json':
    result = {'data': data, 'partial': is_partial}
    print(json.dumps(result, indent=2))
else:
    if not data:
        print(f'_No GitHub activity for the last {period_name}._')
    else:
        grand_total = sum(d['total_output'] for d in data) or 1
        print(f'| Contributor | Issues | PRs | Merged | Commented | % of Total |')
        print(f'| --- | ---: | ---: | ---: | ---: | ---: |')
        for d in data:
            pct = round(d['total_output'] / grand_total * 100, 1)
            print(f'| {d[\"login\"]} | {d[\"issues_created\"]} | {d[\"prs_created\"]} | {d[\"prs_merged\"]} | {d[\"commented_on\"]} | {pct}% |')
    if is_partial:
        print()
        print('<!-- partial-results -->')
        print('_Partial results — GitHub Search API rate limit exhausted._')
" "$format" "$period" "$_ps_partial"

	# Return distinct exit code so callers can detect truncated payloads.
	# EX_PARTIAL (75) means "valid output on stdout, but incomplete due to
	# rate limiting". Callers should cache the output but mark it as partial.
	if [[ "$_ps_partial" == "true" ]]; then
		return "$EX_PARTIAL"
	fi
	return 0
}

#######################################
# Cross-repo per-person GitHub output stats
#
# Aggregates person_stats across multiple repos. Privacy-safe (no repo names).
#
# Arguments:
#   $1..N - repo paths
#   --period day|week|month|quarter|year (optional, default: month)
#   --format markdown|json (optional, default: markdown)
#   --logins login1,login2 (optional, override auto-discovery)
# Output: aggregated per-person table to stdout
#######################################
cross_repo_person_stats() {
	local period="month"
	local format="markdown"
	local logins_override=""
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
		--logins)
			logins_override="${2:-}"
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

	# Collect JSON from each repo
	local all_json=""
	local repo_count=0
	local _crps_any_partial=false
	for rp in "${repo_paths[@]}"; do
		if [[ ! -d "$rp/.git" && ! -f "$rp/.git" ]]; then
			echo "Warning: $rp is not a git repository, skipping" >&2
			continue
		fi
		local repo_json
		local repo_rc=0
		local -a extra_args=()
		if [[ -n "$logins_override" ]]; then
			extra_args+=(--logins "$logins_override")
		fi
		repo_json=$(person_stats "$rp" --period "$period" --format json ${extra_args[@]+"${extra_args[@]}"}) || repo_rc=$?
		if [[ "$repo_rc" -eq "$EX_PARTIAL" ]]; then
			_crps_any_partial=true
		elif [[ "$repo_rc" -ne 0 ]]; then
			repo_json='{"data":[],"partial":false}'
		fi
		# person_stats --format json returns {"data": [...], "partial": bool}.
		# Extract the .data array for aggregation.
		local repo_data
		if repo_data=$(echo "$repo_json" | jq -e '.data // empty' 2>/dev/null); then
			all_json+="${repo_data}"$'\n'
		elif echo "$repo_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
			# Fallback: raw array (shouldn't happen, but defensive)
			all_json+="${repo_json}"$'\n'
		fi
		repo_count=$((repo_count + 1))
	done

	# Merge all repo arrays into one, then aggregate per login
	all_json=$(echo -n "$all_json" | jq -s 'add // []')

	echo "$all_json" | python3 -c "
import sys
import json

format_type = sys.argv[1]
period_name = sys.argv[2]
repo_count = int(sys.argv[3])
is_partial = sys.argv[4] == 'true'

data = json.load(sys.stdin)

# Aggregate by login
totals = {}
for d in data:
    login = d['login']
    if login not in totals:
        totals[login] = {'login': login, 'issues_created': 0, 'prs_created': 0, 'prs_merged': 0, 'commented_on': 0}
    totals[login]['issues_created'] += d.get('issues_created', 0)
    totals[login]['prs_created'] += d.get('prs_created', 0)
    totals[login]['prs_merged'] += d.get('prs_merged', 0)
    totals[login]['commented_on'] += d.get('commented_on', 0)

results = list(totals.values())
for r in results:
    r['total_output'] = r['issues_created'] + r['prs_created'] + r['commented_on']
results.sort(key=lambda x: x['total_output'], reverse=True)

if format_type == 'json':
    result = {'repo_count': repo_count, 'contributors': results, 'partial': is_partial}
    print(json.dumps(result, indent=2))
else:
    if not results:
        print(f'_No GitHub activity across {repo_count} repos for the last {period_name}._')
    else:
        print(f'_Across {repo_count} managed repos:_')
        print()
        grand_total = sum(r['total_output'] for r in results) or 1
        print(f'| Contributor | Issues | PRs | Merged | Commented | % of Total |')
        print(f'| --- | ---: | ---: | ---: | ---: | ---: |')
        for r in results:
            pct = round(r['total_output'] / grand_total * 100, 1)
            print(f'| {r[\"login\"]} | {r[\"issues_created\"]} | {r[\"prs_created\"]} | {r[\"prs_merged\"]} | {r[\"commented_on\"]} | {pct}% |')
    if is_partial:
        print()
        print('<!-- partial-results -->')
        print('_Partial results — GitHub Search API rate limit exhausted._')
" "$format" "$period" "$repo_count" "$_crps_any_partial"

	# Propagate partial status to callers
	if [[ "$_crps_any_partial" == "true" ]]; then
		return "$EX_PARTIAL"
	fi
	return 0
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	summary | table)
		local repo_path="${1:-.}"
		shift || true
		local period="month"
		local format="markdown"
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
				shift
				;;
			esac
		done
		compute_activity "$repo_path" "$period" "$format"
		;;
	user)
		local repo_path="${1:-.}"
		local login="${2:-}"
		if [[ -z "$login" ]]; then
			echo "Usage: $0 user <repo-path> <github-login>" >&2
			return 1
		fi
		user_activity "$repo_path" "$login"
		;;
	cross-repo-summary)
		cross_repo_summary "$@"
		;;
	session-time)
		session_time "$@"
		;;
	cross-repo-session-time)
		cross_repo_session_time "$@"
		;;
	person-stats)
		person_stats "$@"
		;;
	cross-repo-person-stats)
		cross_repo_person_stats "$@"
		;;
	help | *)
		echo "Usage: $0 <command> [options]"
		echo ""
		echo "Commands:"
		echo "  summary <repo-path> [--period day|week|month|year] [--format markdown|json]"
		echo "  table   <repo-path> [--period day|week|month|year] [--format markdown|json]"
		echo "  user    <repo-path> <github-login>"
		echo "  cross-repo-summary <path1> [path2 ...] [--period month] [--format markdown]"
		echo "  session-time <repo-path> [--period day|week|month|quarter|year|all] [--format markdown|json]"
		echo "  cross-repo-session-time <path1> [path2 ...] [--period month|all] [--format markdown|json]"
		echo "  person-stats <repo-path> [--period day|week|month|quarter|year] [--format markdown|json] [--logins a,b]"
		echo "  cross-repo-person-stats <path1> [path2 ...] [--period month] [--format markdown|json] [--logins a,b]"
		echo ""
		echo "Computes contributor activity from immutable git commit history."
		echo "Session time stats from AI assistant database (OpenCode/Claude Code)."
		echo "Per-person GitHub output stats from GitHub Search API."
		echo "GitHub noreply emails are used to normalise author names to logins."
		echo ""
		echo "Commit types:"
		echo "  Direct  - committer is the author (push, CLI commit)"
		echo "  PR Merge - committer is noreply@github.com (GitHub squash-merge)"
		echo ""
		echo "Session time (human vs machine):"
		echo "  Human hours   - time spent reading, thinking, typing (between AI responses)"
		echo "  Machine hours - time AI spent generating responses"
		echo "  Interactive   - human-driven sessions (conversations, debugging)"
		echo "  Worker        - headless dispatched tasks (Issue #N, PR #N, Supervisor Pulse)"
		echo ""
		echo "Person stats (GitHub output per contributor):"
		echo "  Issues    - issues created by this person"
		echo "  PRs       - pull requests created by this person"
		echo "  Merged    - pull requests merged (authored by this person)"
		echo "  Commented - unique issues/PRs this person commented on"
		return 0
		;;
	esac

	return 0
}

main "$@"
