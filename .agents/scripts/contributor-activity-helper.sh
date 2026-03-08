#!/usr/bin/env bash
# contributor-activity-helper.sh - Compute contributor activity from git history
#
# Sources activity data exclusively from immutable git commit history to prevent
# manipulation. Each contributor's activity is measured by commits, active days,
# and productive time spans (first-to-last commit per active day).
#
# GitHub noreply emails (NNN+login@users.noreply.github.com) are used to map
# git author names to GitHub logins, normalising multiple author name variants
# (e.g., "Marcus Quinn" and "marcusquinn" both map to "marcusquinn").
#
# Usage:
#   contributor-activity-helper.sh summary <repo-path> [--period day|week|month|year]
#   contributor-activity-helper.sh table <repo-path> [--format markdown|json]
#   contributor-activity-helper.sh user <repo-path> <github-login>
#
# Output: markdown table or JSON suitable for embedding in health issues.

set -euo pipefail

#######################################
# Compute activity summary for all contributors in a repo
#
# Reads git log and computes per-contributor stats:
#   - Total commits (by period)
#   - Active days
#   - Productive hours (sum of daily first-to-last commit spans)
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

	# Determine --since based on period
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

	# Get git log: email|ISO-date (one line per commit)
	local git_data
	# shellcheck disable=SC2086
	git_data=$(git -C "$repo_path" log --all --format='%ae|%aI' $since_arg) || git_data=""

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

def email_to_login(email):
    if email.endswith('@users.noreply.github.com'):
        local = email.split('@')[0]
        return local.split('+', 1)[1] if '+' in local else local
    if email in ('actions@github.com', 'action@github.com'):
        return 'github-actions'
    return email.split('@')[0]

contributors = defaultdict(lambda: {'commits': 0, 'days': set(), 'daily_spans': defaultdict(list)})

for line in sys.stdin:
    line = line.strip()
    if not line or '|' not in line:
        continue
    email, date_str = line.split('|', 1)
    login = email_to_login(email)

    if login in ('github-actions',):
        continue

    try:
        dt = datetime.fromisoformat(date_str.replace('Z', '+00:00'))
    except ValueError:
        continue

    day = dt.strftime('%Y-%m-%d')
    contributors[login]['commits'] += 1
    contributors[login]['days'].add(day)
    contributors[login]['daily_spans'][day].append(dt)

results = []
for login, data in sorted(contributors.items(), key=lambda x: -x[1]['commits']):
    active_days = len(data['days'])
    commits = data['commits']

    total_hours = 0.0
    for day, timestamps in data['daily_spans'].items():
        timestamps.sort()
        span = (timestamps[-1] - timestamps[0]).total_seconds() / 3600
        total_hours += max(span, 0.25)

    avg_per_day = commits / active_days if active_days > 0 else 0

    results.append({
        'login': login,
        'commits': commits,
        'active_days': active_days,
        'productive_hours': round(total_hours, 1),
        'avg_commits_per_day': round(avg_per_day, 1)
    })

format_type = sys.argv[1]
period_name = sys.argv[2]

if format_type == 'json':
    print(json.dumps(results, indent=2))
else:
    if not results:
        print(f'_No contributor activity in the last {period_name}._')
    else:
        print('| Contributor | Commits | Active Days | Productive Hours | Avg/Day |')
        print('| --- | ---: | ---: | ---: | ---: |')
        for r in results:
            print(f'| {r[\"login\"]} | {r[\"commits\"]} | {r[\"active_days\"]} | {r[\"productive_hours\"]}h | {r[\"avg_commits_per_day\"]} |')
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

	# Get all commits (match by noreply email pattern in Python)
	local git_data
	git_data=$(git -C "$repo_path" log --all --format='%ae|%aI' --since='1.year.ago') || git_data=""

	# Target login passed via sys.argv to avoid shell injection.
	echo "$git_data" | python3 -c "
import sys
import json
from collections import defaultdict
from datetime import datetime, timedelta, timezone

def email_to_login(email):
    if email.endswith('@users.noreply.github.com'):
        local = email.split('@')[0]
        return local.split('+', 1)[1] if '+' in local else local
    if email in ('actions@github.com', 'action@github.com'):
        return 'github-actions'
    return email.split('@')[0]

target = sys.argv[1]
now = datetime.now(timezone.utc)

periods = {
    'today': now.replace(hour=0, minute=0, second=0, microsecond=0),
    'this_week': now - timedelta(days=now.weekday()),
    'this_month': now.replace(day=1, hour=0, minute=0, second=0, microsecond=0),
    'this_year': now.replace(month=1, day=1, hour=0, minute=0, second=0, microsecond=0),
}

counts = {p: {'commits': 0, 'days': set(), 'hours': 0.0, 'daily_spans': defaultdict(list)} for p in periods}

for line in sys.stdin:
    line = line.strip()
    if not line or '|' not in line:
        continue
    email, date_str = line.split('|', 1)
    login = email_to_login(email)
    if login != target:
        continue

    try:
        dt = datetime.fromisoformat(date_str.replace('Z', '+00:00'))
    except ValueError:
        continue

    day = dt.strftime('%Y-%m-%d')
    for period_name, start in periods.items():
        start_aware = start.replace(tzinfo=timezone.utc) if start.tzinfo is None else start
        if dt >= start_aware:
            counts[period_name]['commits'] += 1
            counts[period_name]['days'].add(day)
            counts[period_name]['daily_spans'][day].append(dt)

result = {'login': target}
for period_name in ('today', 'this_week', 'this_month', 'this_year'):
    data = counts[period_name]
    total_hours = 0.0
    for day, timestamps in data['daily_spans'].items():
        timestamps.sort()
        span = (timestamps[-1] - timestamps[0]).total_seconds() / 3600
        total_hours += max(span, 0.25)

    result[period_name] = {
        'commits': data['commits'],
        'active_days': len(data['days']),
        'productive_hours': round(total_hours, 1)
    }

print(json.dumps(result, indent=2))
" "$target_login"

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
	help | *)
		echo "Usage: $0 <command> [options]"
		echo ""
		echo "Commands:"
		echo "  summary <repo-path> [--period day|week|month|year] [--format markdown|json]"
		echo "  table   <repo-path> [--period day|week|month|year] [--format markdown|json]"
		echo "  user    <repo-path> <github-login>"
		echo ""
		echo "Computes contributor activity from immutable git commit history."
		echo "GitHub noreply emails are used to normalise author names to logins."
		return 0
		;;
	esac

	return 0
}

main "$@"
