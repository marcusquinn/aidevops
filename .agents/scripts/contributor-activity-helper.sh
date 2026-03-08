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
#
# Output: markdown table or JSON suitable for embedding in health issues.

set -euo pipefail

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
# Session type classification (by title pattern):
#   - Worker: "Issue #*", "Supervisor Pulse", contains "/full-loop"
#   - Interactive: everything else (root sessions only)
#   - Subagent: sessions with parent_id (excluded — time attributed to parent)
#
# Duration: max(message.time_created) - min(message.time_created) per session
# (actual active time between first and last message, not wall clock).
#
# Arguments:
#   $1 - repo path (filters sessions by directory)
#   --period day|week|month|year (optional, default: month)
#   --format markdown|json (optional, default: markdown)
#   --db-path <path> (optional, default: auto-detect)
# Output: markdown table or JSON
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
				echo "[]"
			else
				echo "_Session database not found._"
			fi
			return 0
		fi
	fi

	if ! command -v sqlite3 &>/dev/null; then
		if [[ "$format" == "json" ]]; then
			echo "[]"
		else
			echo "_sqlite3 not available._"
		fi
		return 0
	fi

	# Determine --since threshold in milliseconds
	local since_ms
	case "$period" in
	day)
		since_ms=$(python3 -c "import time; print(int((time.time() - 86400) * 1000))")
		;;
	week)
		since_ms=$(python3 -c "import time; print(int((time.time() - 604800) * 1000))")
		;;
	month)
		since_ms=$(python3 -c "import time; print(int((time.time() - 2592000) * 1000))")
		;;
	year)
		since_ms=$(python3 -c "import time; print(int((time.time() - 31536000) * 1000))")
		;;
	*)
		since_ms=$(python3 -c "import time; print(int((time.time() - 2592000) * 1000))")
		;;
	esac

	# Resolve repo_path to absolute for matching against session.directory
	local abs_repo_path
	abs_repo_path=$(cd "$repo_path" 2>/dev/null && pwd) || abs_repo_path="$repo_path"

	# Query session data with message-based duration using JSON output.
	# JSON avoids pipe-separator issues (session titles can contain '|').
	# Filters: root sessions only (no parent_id), within period, matching directory.
	# Worktree directories (e.g., ~/Git/aidevops.feature-foo) are matched by prefix.
	local query_result
	query_result=$(sqlite3 -json "$db_path" "
		SELECT
			s.title,
			(max(m.time_created) - min(m.time_created)) as duration_ms
		FROM session s
		JOIN message m ON m.session_id = s.id
		WHERE s.parent_id IS NULL
		  AND s.time_created > ${since_ms}
		  AND (s.directory = '${abs_repo_path}'
		       OR s.directory LIKE '${abs_repo_path}.%'
		       OR s.directory LIKE '${abs_repo_path}-%')
		GROUP BY s.id
		HAVING count(m.id) >= 2
		  AND duration_ms > 5000
	" 2>/dev/null) || query_result="[]"

	# Process JSON in Python for classification and aggregation
	echo "$query_result" | python3 -c "
import sys
import json
import re

format_type = sys.argv[1]
period_name = sys.argv[2]

# Worker session title patterns
worker_patterns = [
    re.compile(r'^Issue #\d+'),
    re.compile(r'^Supervisor Pulse'),
    re.compile(r'/full-loop', re.IGNORECASE),
    re.compile(r'^dispatch:', re.IGNORECASE),
    re.compile(r'^Worker:', re.IGNORECASE),
]

def classify_session(title):
    for pat in worker_patterns:
        if pat.search(title):
            return 'worker'
    return 'interactive'

sessions = json.load(sys.stdin)

interactive_ms = 0
worker_ms = 0
interactive_count = 0
worker_count = 0

for row in sessions:
    title = row.get('title', '')
    duration_ms = row.get('duration_ms', 0)

    session_type = classify_session(title)
    if session_type == 'worker':
        worker_ms += duration_ms
        worker_count += 1
    else:
        interactive_ms += duration_ms
        interactive_count += 1

interactive_hours = round(interactive_ms / 1000 / 3600, 1)
worker_hours = round(worker_ms / 1000 / 3600, 1)
total_hours = round((interactive_ms + worker_ms) / 1000 / 3600, 1)

result = {
    'interactive_hours': interactive_hours,
    'interactive_sessions': interactive_count,
    'worker_hours': worker_hours,
    'worker_sessions': worker_count,
    'total_hours': total_hours,
    'total_sessions': interactive_count + worker_count,
}

if format_type == 'json':
    print(json.dumps(result, indent=2))
else:
    if interactive_count == 0 and worker_count == 0:
        print(f'_No session data for the last {period_name}._')
    else:
        print(f'| Type | Sessions | Hours |')
        print(f'| --- | ---: | ---: |')
        print(f'| Interactive (human) | {interactive_count} | {interactive_hours}h |')
        print(f'| Workers/Runners | {worker_count} | {worker_hours}h |')
        print(f'| **Total** | **{interactive_count + worker_count}** | **{total_hours}h** |')
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
#   --period day|week|month|year (optional, default: month)
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

	# Collect JSON from each repo
	local all_json="["
	local first="true"
	local repo_count=0
	for rp in "${repo_paths[@]}"; do
		local repo_json
		repo_json=$(session_time "$rp" --period "$period" --format json) || repo_json="{}"
		if [[ "$first" == "true" ]]; then
			first="false"
		else
			all_json="${all_json},"
		fi
		all_json="${all_json}${repo_json}"
		repo_count=$((repo_count + 1))
	done
	all_json="${all_json}]"

	echo "$all_json" | python3 -c "
import sys
import json

format_type = sys.argv[1]
period_name = sys.argv[2]
repo_count = int(sys.argv[3])

repos = json.load(sys.stdin)

totals = {
    'interactive_hours': 0,
    'interactive_sessions': 0,
    'worker_hours': 0,
    'worker_sessions': 0,
}

for repo in repos:
    totals['interactive_hours'] += repo.get('interactive_hours', 0)
    totals['interactive_sessions'] += repo.get('interactive_sessions', 0)
    totals['worker_hours'] += repo.get('worker_hours', 0)
    totals['worker_sessions'] += repo.get('worker_sessions', 0)

totals['interactive_hours'] = round(totals['interactive_hours'], 1)
totals['worker_hours'] = round(totals['worker_hours'], 1)
total_hours = round(totals['interactive_hours'] + totals['worker_hours'], 1)
total_sessions = totals['interactive_sessions'] + totals['worker_sessions']

if format_type == 'json':
    totals['total_hours'] = total_hours
    totals['total_sessions'] = total_sessions
    totals['repo_count'] = repo_count
    print(json.dumps(totals, indent=2))
else:
    if total_sessions == 0:
        print(f'_No session data across {repo_count} repos for the last {period_name}._')
    else:
        print(f'_Across {repo_count} managed repos:_')
        print()
        print(f'| Type | Sessions | Hours |')
        print(f'| --- | ---: | ---: |')
        print(f'| Interactive (human) | {totals[\"interactive_sessions\"]} | {totals[\"interactive_hours\"]}h |')
        print(f'| Workers/Runners | {totals[\"worker_sessions\"]} | {totals[\"worker_hours\"]}h |')
        print(f'| **Total** | **{total_sessions}** | **{total_hours}h** |')
" "$format" "$period" "$repo_count"

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
	help | *)
		echo "Usage: $0 <command> [options]"
		echo ""
		echo "Commands:"
		echo "  summary <repo-path> [--period day|week|month|year] [--format markdown|json]"
		echo "  table   <repo-path> [--period day|week|month|year] [--format markdown|json]"
		echo "  user    <repo-path> <github-login>"
		echo "  cross-repo-summary <path1> [path2 ...] [--period month] [--format markdown]"
		echo "  session-time <repo-path> [--period month] [--format markdown]"
		echo "  cross-repo-session-time <path1> [path2 ...] [--period month] [--format markdown]"
		echo ""
		echo "Computes contributor activity from immutable git commit history."
		echo "Session time stats from AI assistant database (OpenCode/Claude Code)."
		echo "GitHub noreply emails are used to normalise author names to logins."
		echo ""
		echo "Commit types:"
		echo "  Direct  - committer is the author (push, CLI commit)"
		echo "  PR Merge - committer is noreply@github.com (GitHub squash-merge)"
		echo ""
		echo "Session types:"
		echo "  Interactive - human-driven sessions (conversations, debugging)"
		echo "  Worker      - headless dispatched tasks (Issue #N, Supervisor Pulse)"
		return 0
		;;
	esac

	return 0
}

main "$@"
