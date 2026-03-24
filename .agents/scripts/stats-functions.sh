#!/usr/bin/env bash
# stats-functions.sh - Statistics and health dashboard functions
#
# Extracted from pulse-wrapper.sh (t1431) to separate stats concerns.
# These functions are used exclusively by stats-wrapper.sh for:
#   - Health issue dashboards (per-repo pinned issues)
#   - Daily code quality sweeps (ShellCheck, Qlty, SonarCloud, Codacy, CodeRabbit)
#   - Person-stats cache refresh
#
# After t1429 separated stats into a separate cron process, these 12 functions
# (~1600 lines, 41% of pulse-wrapper) were dead code from the pulse's perspective.
# Extracting them reduces pulse-wrapper's blast radius and avoids stats-wrapper
# sourcing the entire 3500-line pulse-wrapper just to access these functions.
#
# Dependencies:
#   - shared-constants.sh (sourced by caller)
#   - worker-lifecycle-common.sh (sourced by caller)
#   - gh CLI (GitHub API)
#   - jq (JSON processing)

# Include guard — prevent double-sourcing
[[ -n "${_STATS_FUNCTIONS_LOADED:-}" ]] && return 0
_STATS_FUNCTIONS_LOADED=1

#######################################
# Configuration — stats-specific variables
#
# These were previously defined in pulse-wrapper.sh but are only used
# by the functions in this file. Callers can override via environment.
#######################################
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
LOGFILE="${LOGFILE:-${HOME}/.aidevops/logs/stats.log}"
QUALITY_SWEEP_INTERVAL="${QUALITY_SWEEP_INTERVAL:-86400}"
PERSON_STATS_INTERVAL="${PERSON_STATS_INTERVAL:-3600}"
QUALITY_SWEEP_LAST_RUN="${QUALITY_SWEEP_LAST_RUN:-${HOME}/.aidevops/logs/quality-sweep-last-run}"
PERSON_STATS_LAST_RUN="${PERSON_STATS_LAST_RUN:-${HOME}/.aidevops/logs/person-stats-last-run}"
PERSON_STATS_CACHE_DIR="${PERSON_STATS_CACHE_DIR:-${HOME}/.aidevops/logs}"
QUALITY_SWEEP_STATE_DIR="${QUALITY_SWEEP_STATE_DIR:-${HOME}/.aidevops/logs/quality-sweep-state}"
CODERABBIT_ISSUE_SPIKE="${CODERABBIT_ISSUE_SPIKE:-10}"
SESSION_COUNT_WARN="${SESSION_COUNT_WARN:-5}"

# Validate numeric config if _validate_int is available (from worker-lifecycle-common.sh)
if type _validate_int &>/dev/null; then
	QUALITY_SWEEP_INTERVAL=$(_validate_int QUALITY_SWEEP_INTERVAL "$QUALITY_SWEEP_INTERVAL" 86400)
	PERSON_STATS_INTERVAL=$(_validate_int PERSON_STATS_INTERVAL "$PERSON_STATS_INTERVAL" 3600)
	CODERABBIT_ISSUE_SPIKE=$(_validate_int CODERABBIT_ISSUE_SPIKE "$CODERABBIT_ISSUE_SPIKE" 10 1)
	SESSION_COUNT_WARN=$(_validate_int SESSION_COUNT_WARN "$SESSION_COUNT_WARN" 5 1)
fi

#######################################
# Validate a repo slug matches the expected owner/repo format.
# Rejects path traversal, quotes, and other injection vectors.
# Arguments:
#   $1 - repo slug to validate
# Returns: 0 if valid, 1 if invalid
#######################################
_validate_repo_slug() {
	local slug="$1"
	# Must be non-empty, match owner/repo with only alphanumeric, hyphens,
	# underscores, and dots (GitHub's allowed characters)
	if [[ "$slug" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
		return 0
	fi
	echo "[stats] Invalid repo slug rejected: ${slug}" >>"$LOGFILE"
	return 1
}

#######################################
# Count interactive AI sessions (duplicate of pulse-wrapper's check_session_count)
#
# Duplicated here (17 lines) rather than cross-sourcing pulse-wrapper.sh,
# which would defeat the purpose of the extraction. See t1431 brief.
#
# Returns: session count via stdout
#######################################
check_session_count() {
	local interactive_count=0

	# Count opencode processes with a real TTY (interactive sessions).
	# Filter both '?' (Linux) and '??' (macOS) headless TTY entries.
	interactive_count=$(ps axo tty,command | awk '
		/(\.(opencode|claude)|opencode-ai|claude-ai)/ && !/awk/ && $1 != "?" && $1 != "??" { count++ }
		END { print count + 0 }
	') || interactive_count=0

	if [[ "$interactive_count" -gt "$SESSION_COUNT_WARN" ]]; then
		echo "[stats] Session warning: $interactive_count interactive sessions open (threshold: $SESSION_COUNT_WARN)" >>"$LOGFILE"
	fi

	echo "$interactive_count"
	return 0
}

#######################################
# Determine runner role for a repo: supervisor or contributor
#
# Checks the runner's permission on the repo via the GitHub API.
# Maintainers (admin, maintain, write) are "supervisor"; everyone
# else (read, none, 404) is "contributor". API failures default to
# "contributor" (fail closed — never grant elevated status on error).
#
# Results are cached per runner+repo for the duration of the pulse
# to avoid repeated API calls (one call per repo per pulse cycle).
#
# Arguments:
#   $1 - runner GitHub login
#   $2 - repo slug (owner/repo)
# Output: "supervisor" or "contributor" to stdout
#######################################
_get_runner_role() {
	local runner_user="$1"
	local repo_slug="$2"

	# Validate slug before using in API path (defense-in-depth)
	if ! _validate_repo_slug "$repo_slug"; then
		echo "contributor"
		return 0
	fi

	# Check cache (env var keyed by slug — avoids repeated API calls)
	local cache_key="__RUNNER_ROLE_${repo_slug//[^a-zA-Z0-9]/_}"
	local cached_role="${!cache_key:-}"
	if [[ -n "$cached_role" ]]; then
		echo "$cached_role"
		return 0
	fi

	local role="contributor"
	local api_path="repos/${repo_slug}/collaborators/${runner_user}/permission"
	local response
	response=$(gh api "$api_path" --jq '.permission // empty') || response=""

	case "$response" in
	admin | maintain | write)
		role="supervisor"
		;;
	read | none | "")
		role="contributor"
		;;
	*)
		# Unknown permission value — fail closed
		role="contributor"
		;;
	esac

	# Cache for this pulse cycle
	export "$cache_key=$role"

	echo "$role"
	return 0
}

#######################################
# Update pinned health issue for a single repo
#
# Creates or updates a pinned GitHub issue with live status:
#   - Open PRs and issues counts
#   - Active headless workers (from ps)
#   - System resources (CPU, RAM)
#   - Last pulse timestamp
#
# One issue per runner (GitHub user) per repo. Uses labels
# "supervisor" or "contributor" + "$runner_user" for dedup.
# Issue number cached in ~/.aidevops/logs/ to avoid repeated lookups.
#
# Maintainers get [Supervisor:user] issues; non-maintainers get
# [Contributor:user] issues. Role determined by _get_runner_role().
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - repo path (local filesystem)
#   $3 - cross-repo activity markdown (pre-computed by update_health_issues)
#   $4 - cross-repo session time markdown (pre-computed by update_health_issues)
#   $5 - cross-repo person stats markdown (pre-computed by update_health_issues)
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
_update_health_issue_for_repo() {
	local repo_slug="$1"
	local repo_path="$2"
	local cross_repo_md="${3:-}"
	local cross_repo_session_time_md="${4:-}"
	local cross_repo_person_stats_md="${5:-}"

	[[ -z "$repo_slug" ]] && return 0

	# Per-runner identity and role
	local runner_user
	runner_user=$(gh api user --jq '.login' || whoami)

	# Determine role: supervisor (maintainer) or contributor (non-maintainer)
	local runner_role
	runner_role=$(_get_runner_role "$runner_user" "$repo_slug")

	local runner_prefix role_label role_label_color role_label_desc role_display
	if [[ "$runner_role" == "supervisor" ]]; then
		runner_prefix="[Supervisor:${runner_user}]"
		role_label="supervisor"
		role_label_color="1D76DB"
		role_label_desc="Supervisor health dashboard"
		role_display="Supervisor"
	else
		runner_prefix="[Contributor:${runner_user}]"
		role_label="contributor"
		role_label_color="A2EEEF"
		role_label_desc="Contributor health dashboard"
		role_display="Contributor"
	fi

	# Cache file for this runner + repo (slug with / replaced by -)
	local slug_safe="${repo_slug//\//-}"
	local cache_dir="${HOME}/.aidevops/logs"
	local health_issue_file="${cache_dir}/health-issue-${runner_user}-${role_label}-${slug_safe}"
	local health_issue_number=""

	mkdir -p "$cache_dir"

	# Try cached issue number first
	if [[ -f "$health_issue_file" ]]; then
		health_issue_number=$(cat "$health_issue_file" 2>/dev/null || echo "")
	fi

	# Validate cached issue still exists and is open
	if [[ -n "$health_issue_number" ]]; then
		local issue_state
		issue_state=$(gh issue view "$health_issue_number" --repo "$repo_slug" --json state --jq '.state' 2>/dev/null || echo "")
		if [[ "$issue_state" != "OPEN" ]]; then
			if [[ "$runner_role" == "supervisor" ]]; then
				_unpin_health_issue "$health_issue_number" "$repo_slug"
			fi
			health_issue_number=""
			rm -f "$health_issue_file" 2>/dev/null || true
		fi
	fi

	# Search by labels (more reliable than title search)
	if [[ -z "$health_issue_number" ]]; then
		local label_results
		label_results=$(gh issue list --repo "$repo_slug" \
			--label "$role_label" --label "$runner_user" \
			--state open --json number,title \
			--jq "[.[] | select(.title | startswith(\"[${role_display}:\"))] | sort_by(.number) | reverse" 2>/dev/null || echo "[]")

		health_issue_number=$(printf '%s' "$label_results" | jq -r '.[0].number // empty' 2>/dev/null || echo "")

		# Dedup: close all but the newest
		local dup_count
		dup_count=$(printf '%s' "$label_results" | jq 'length' 2>/dev/null || echo "0")
		if [[ "${dup_count:-0}" -gt 1 ]]; then
			local dup_numbers
			dup_numbers=$(printf '%s' "$label_results" | jq -r '.[1:][].number' 2>/dev/null || echo "")
			while IFS= read -r dup_num; do
				[[ -z "$dup_num" ]] && continue
				if [[ "$runner_role" == "supervisor" ]]; then
					_unpin_health_issue "$dup_num" "$repo_slug"
				fi
				gh issue close "$dup_num" --repo "$repo_slug" \
					--comment "Closing duplicate ${runner_role} health issue — superseded by #${health_issue_number}." 2>/dev/null || true
			done <<<"$dup_numbers"
		fi
	fi

	# Fallback: title-based search
	if [[ -z "$health_issue_number" ]]; then
		health_issue_number=$(gh issue list --repo "$repo_slug" \
			--search "in:title ${runner_prefix}" \
			--state open --json number,title \
			--jq "[.[] | select(.title | startswith(\"${runner_prefix}\"))][0].number" 2>/dev/null || echo "")
		# Backfill labels
		if [[ -n "$health_issue_number" ]]; then
			gh label create "$runner_user" --repo "$repo_slug" --color "0E8A16" \
				--description "${role_display} runner: ${runner_user}" --force 2>/dev/null || true
			gh issue edit "$health_issue_number" --repo "$repo_slug" \
				--add-label "$role_label" --add-label "$runner_user" 2>/dev/null || true
		fi
	fi

	# Create the issue if it doesn't exist
	if [[ -z "$health_issue_number" ]]; then
		gh label create "$role_label" --repo "$repo_slug" --color "$role_label_color" \
			--description "$role_label_desc" --force 2>/dev/null || true
		gh label create "$runner_user" --repo "$repo_slug" --color "0E8A16" \
			--description "${role_display} runner: ${runner_user}" --force 2>/dev/null || true
		gh label create "source:health-dashboard" --repo "$repo_slug" --color "C2E0C6" \
			--description "Auto-created by stats-functions.sh health dashboard" --force 2>/dev/null || true

		health_issue_number=$(gh issue create --repo "$repo_slug" \
			--title "${runner_prefix} starting..." \
			--body "Live ${runner_role} status for **${runner_user}**. Updated each pulse. Pin this issue for at-a-glance monitoring." \
			--label "$role_label" --label "$runner_user" --label "source:health-dashboard" 2>/dev/null | grep -oE '[0-9]+$' || echo "")

		if [[ -z "$health_issue_number" ]]; then
			echo "[stats] Health issue: could not create for ${repo_slug}" >>"$LOGFILE"
			return 0
		fi

		# Pin only supervisor issues — contributor issues don't pin because
		# GitHub allows max 3 pinned issues per repo and those slots are
		# reserved for maintainer dashboards and the quality review issue.
		if [[ "$runner_role" == "supervisor" ]]; then
			local node_id
			node_id=$(gh issue view "$health_issue_number" --repo "$repo_slug" --json id --jq '.id' 2>/dev/null || echo "")
			if [[ -n "$node_id" ]]; then
				gh api graphql -f query="
					mutation {
						pinIssue(input: {issueId: \"${node_id}\"}) {
							issue { number }
						}
					}" >/dev/null 2>&1 || true
			fi
		fi
		echo "[stats] Health issue: created #${health_issue_number} (${runner_role}) for ${runner_user} in ${repo_slug}" >>"$LOGFILE"
	fi

	# Supervisor-only: unpin closed/stale issues and ensure current is pinned
	if [[ "$runner_role" == "supervisor" ]]; then
		# Unpin closed/stale supervisor issues to free pin slots (max 3 per repo)
		_cleanup_stale_pinned_issues "$repo_slug" "$runner_user"

		# Ensure pinned (idempotent)
		local active_node_id
		active_node_id=$(gh issue view "$health_issue_number" --repo "$repo_slug" --json id --jq '.id' 2>/dev/null || echo "")
		if [[ -n "$active_node_id" ]]; then
			gh api graphql -f query="
				mutation {
					pinIssue(input: {issueId: \"${active_node_id}\"}) {
						issue { number }
					}
				}" >/dev/null 2>&1 || true
		fi
	fi

	# Cache the issue number
	echo "$health_issue_number" >"$health_issue_file"

	# --- Gather stats from gh CLI ---
	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# Open PRs
	local pr_json
	pr_json=$(gh pr list --repo "$repo_slug" --state open \
		--json number,title,headRefName,updatedAt,reviewDecision,statusCheckRollup \
		--limit 20 2>/dev/null) || pr_json="[]"
	local pr_count
	pr_count=$(echo "$pr_json" | jq 'length')

	# Open issues — assigned to this runner (actionable) vs total
	local assigned_issue_count
	assigned_issue_count=$(gh issue list --repo "$repo_slug" --state open \
		--assignee "$runner_user" --json number --jq 'length' 2>/dev/null || echo "0")
	local total_issue_count
	total_issue_count=$(gh issue list --repo "$repo_slug" --state open \
		--json number,labels --jq '[.[] | select(.labels | map(.name) | (index("supervisor") or index("contributor") or index("persistent") or index("quality-review")) | not)] | length' 2>/dev/null || echo "0")

	# Active headless workers (opencode processes for this repo)
	local workers_md=""
	local worker_count=0
	local worker_lines
	worker_lines=$(ps axo pid,tty,etime,command | grep '[.]opencode' | grep -v 'bash-language-server' || true)

	if [[ -n "$worker_lines" ]]; then
		local worker_table=""
		while IFS= read -r line; do
			local w_pid w_tty w_etime w_cmd
			read -r w_pid w_tty w_etime w_cmd <<<"$line"

			# Only count headless workers (no TTY).
			# Exclude both '?' (Linux headless) and '??' (macOS headless).
			[[ "$w_tty" != "?" && "$w_tty" != "??" ]] && continue

			# Extract title if present (--title "...")
			local w_title="headless"
			if [[ "$w_cmd" =~ --title[[:space:]]+\"([^\"]+)\" ]] || [[ "$w_cmd" =~ --title[[:space:]]+([^[:space:]]+) ]]; then
				w_title="${BASH_REMATCH[1]}"
			fi

			# Extract dir if present
			local w_dir=""
			if [[ "$w_cmd" =~ --dir[[:space:]]+([^[:space:]]+) ]]; then
				w_dir="${BASH_REMATCH[1]}"
			fi

			# Only include workers for this repo (or all if dir not detectable)
			if [[ -n "$w_dir" && "$w_dir" != "$repo_path"* ]]; then
				continue
			fi

			local w_title_short="${w_title:0:60}"
			[[ ${#w_title} -gt 60 ]] && w_title_short="${w_title_short}..."
			worker_table="${worker_table}| ${w_pid} | ${w_etime} | ${w_title_short} |
"
			worker_count=$((worker_count + 1))
		done <<<"$worker_lines"

		if [[ "$worker_count" -gt 0 ]]; then
			workers_md="| PID | Uptime | Title |
| --- | --- | --- |
${worker_table}"
		fi
	fi

	if [[ "$worker_count" -eq 0 ]]; then
		workers_md="_No active workers_"
	fi

	# PRs table
	local prs_md=""
	if [[ "$pr_count" -gt 0 ]]; then
		prs_md="| # | Title | Branch | Checks | Review | Updated |
| --- | --- | --- | --- | --- | --- |
"
		prs_md="${prs_md}$(echo "$pr_json" | jq -r '.[] | "| #\(.number) | \(.title[:60]) | `\(.headRefName)` | \(if .statusCheckRollup == null or (.statusCheckRollup | length) == 0 then "none" elif (.statusCheckRollup | all((.conclusion // .state) == "SUCCESS")) then "PASS" elif (.statusCheckRollup | any((.conclusion // .state) == "FAILURE")) then "FAIL" else "PENDING" end) | \(if .reviewDecision == null or .reviewDecision == "" then "NONE" else .reviewDecision end) | \(.updatedAt[:16]) |"')"
	else
		prs_md="_No open PRs_"
	fi

	# System resources
	local sys_cpu_cores sys_load_1m sys_load_5m sys_memory sys_procs
	sys_cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo "?")
	sys_procs=$(ps aux 2>/dev/null | wc -l | tr -d ' ')

	if [[ "$(uname)" == "Darwin" ]]; then
		local load_str
		load_str=$(sysctl -n vm.loadavg 2>/dev/null || echo "{ 0 0 0 }")
		sys_load_1m=$(echo "$load_str" | awk '{print $2}')
		sys_load_5m=$(echo "$load_str" | awk '{print $3}')

		local page_size vm_free vm_inactive
		page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo "16384")
		vm_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
		vm_inactive=$(vm_stat 2>/dev/null | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
		# Validate integers before arithmetic expansion
		[[ "$page_size" =~ ^[0-9]+$ ]] || page_size=16384
		[[ "$vm_free" =~ ^[0-9]+$ ]] || vm_free=0
		[[ "$vm_inactive" =~ ^[0-9]+$ ]] || vm_inactive=0
		if [[ -n "$vm_free" ]]; then
			local avail_mb=$(((${vm_free:-0} + ${vm_inactive:-0}) * page_size / 1048576))
			if [[ "$avail_mb" -lt 1024 ]]; then
				sys_memory="HIGH pressure (${avail_mb}MB free)"
			elif [[ "$avail_mb" -lt 4096 ]]; then
				sys_memory="medium (${avail_mb}MB free)"
			else
				sys_memory="low (${avail_mb}MB free)"
			fi
		else
			sys_memory="unknown"
		fi
	elif [[ -f /proc/loadavg ]]; then
		read -r sys_load_1m sys_load_5m _ </proc/loadavg
		local mem_avail
		mem_avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "")
		if [[ -n "$mem_avail" ]]; then
			if [[ "$mem_avail" -lt 1024 ]]; then
				sys_memory="HIGH pressure (${mem_avail}MB free)"
			elif [[ "$mem_avail" -lt 4096 ]]; then
				sys_memory="medium (${mem_avail}MB free)"
			else
				sys_memory="low (${mem_avail}MB free)"
			fi
		else
			sys_memory="unknown"
		fi
	else
		sys_load_1m="?"
		sys_load_5m="?"
		sys_memory="unknown"
	fi

	local sys_load_ratio="?"
	if [[ -n "${sys_load_1m:-}" && "${sys_cpu_cores:-0}" -gt 0 && "${sys_cpu_cores}" != "?" ]]; then
		# Validate numeric before passing to awk (prevents awk injection)
		if [[ "$sys_load_1m" =~ ^[0-9]+\.?[0-9]*$ ]] && [[ "$sys_cpu_cores" =~ ^[0-9]+$ ]]; then
			sys_load_ratio=$(awk "BEGIN {printf \"%d\", (${sys_load_1m} / ${sys_cpu_cores}) * 100}" || echo "?")
		fi
	fi

	# Worktree count for this repo
	local wt_count=0
	if [[ -d "${repo_path}/.git" ]]; then
		wt_count=$(git -C "$repo_path" worktree list 2>/dev/null | wc -l | tr -d ' ')
	fi

	# Max workers
	local max_workers="?"
	local max_workers_file="${HOME}/.aidevops/logs/pulse-max-workers"
	if [[ -f "$max_workers_file" ]]; then
		max_workers=$(cat "$max_workers_file" 2>/dev/null || echo "?")
	fi

	# Interactive session count (t1398)
	local session_count
	session_count=$(check_session_count)
	local session_warning=""
	if [[ "$session_count" -gt "$SESSION_COUNT_WARN" ]]; then
		session_warning=" **WARNING: exceeds threshold of ${SESSION_COUNT_WARN}**"
	fi

	# --- Contributor activity from git history (per-repo only) ---
	# Cross-repo totals are pre-computed once in update_health_issues() and
	# passed via $3 to avoid redundant git log walks (N repos × N repos).
	# Session time stats are passed via $4 (also pre-computed once).
	local activity_md=""
	local session_time_md=""
	local person_stats_md=""
	local activity_helper="${HOME}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	if [[ -x "$activity_helper" ]]; then
		activity_md=$(bash "$activity_helper" summary "$repo_path" --period month --format markdown || echo "_Activity data unavailable._")
		session_time_md=$(bash "$activity_helper" session-time "$repo_path" --period all --format markdown || echo "_Session data unavailable._")
	else
		activity_md="_Activity helper not installed._"
		session_time_md="_Activity helper not installed._"
	fi
	# t1426: person-stats from hourly cache (see _refresh_person_stats_cache)
	local ps_cache="${PERSON_STATS_CACHE_DIR}/person-stats-cache-${slug_safe}.md"
	if [[ -f "$ps_cache" ]]; then
		person_stats_md=$(cat "$ps_cache")
	else
		person_stats_md="_Person stats not yet cached._"
	fi

	# --- Assemble body ---
	local body
	body="## Queue Health Dashboard

**Last pulse**: \`${now_iso}\`
**${role_display}**: \`${runner_user}\`
**Repo**: \`${repo_slug}\`

### Summary

| Metric | Count |
| --- | --- |
| Open PRs | ${pr_count} |
| Assigned Issues | ${assigned_issue_count} |
| Total Issues | ${total_issue_count} |
| Active Workers | ${worker_count} |
| Max Workers | ${max_workers} |
| Worktrees | ${wt_count} |
| Interactive Sessions | ${session_count}${session_warning} |

### Open PRs

${prs_md}

### Active Workers

${workers_md}

### GitHub activity on this project (last 30 days)

${person_stats_md:-_Person stats unavailable._}

### GitHub activity on all projects (last 30 days)

${cross_repo_person_stats_md:-_Cross-repo person stats unavailable._}

### Work with AI sessions on this project (${runner_user})

${session_time_md}

### Work with AI sessions on all projects (${runner_user})

${cross_repo_session_time_md:-_Single repo or cross-repo session data unavailable._}

### Commits to this project (last 30 days)

${activity_md}

### Commits to all projects (last 30 days)

${cross_repo_md:-_Single repo or cross-repo data unavailable._}

### System Resources

| Metric | Value |
| --- | --- |
| CPU | ${sys_load_ratio}% used (${sys_cpu_cores} cores, load: ${sys_load_1m}/${sys_load_5m}) |
| Memory | ${sys_memory} |
| Processes | ${sys_procs} |

---
_Auto-updated by ${runner_role} stats process. Do not edit manually._"

	# Update the issue body — capture stderr for debugging auth/API failures
	local body_edit_stderr
	body_edit_stderr=$(gh issue edit "$health_issue_number" --repo "$repo_slug" --body "$body" 2>&1 >/dev/null) || {
		echo "[stats] Health issue: failed to update body for #${health_issue_number}: ${body_edit_stderr}" >>"$LOGFILE"
		return 0
	}

	# Build title with stats (correct pluralization)
	local pr_label="PRs"
	[[ "$pr_count" -eq 1 ]] && pr_label="PR"
	local assigned_label="assigned"
	local worker_label="workers"
	[[ "$worker_count" -eq 1 ]] && worker_label="worker"
	local title_parts="${pr_count} ${pr_label}, ${assigned_issue_count} ${assigned_label}, ${worker_count} ${worker_label}"
	local title_time
	title_time=$(date -u +"%H:%M")
	local health_title="${runner_prefix} ${title_parts} at ${title_time} UTC"

	# Only update title if stats changed
	local current_title=""
	local view_output
	view_output=$(gh issue view "$health_issue_number" --repo "$repo_slug" --json title --jq '.title' 2>&1)
	local view_exit_code=$?
	if [[ $view_exit_code -eq 0 ]]; then
		current_title="$view_output"
	else
		echo "[stats] Health issue: failed to view title for #${health_issue_number}: ${view_output}" >>"$LOGFILE"
	fi
	local current_stats="${current_title% at [0-9][0-9]:[0-9][0-9] UTC}"
	local new_stats="${health_title% at [0-9][0-9]:[0-9][0-9] UTC}"
	if [[ "$current_stats" != "$new_stats" ]]; then
		local title_edit_stderr
		title_edit_stderr=$(gh issue edit "$health_issue_number" --repo "$repo_slug" --title "$health_title" 2>&1 >/dev/null)
		local title_edit_exit_code=$?
		if [[ $title_edit_exit_code -ne 0 ]]; then
			echo "[stats] Health issue: failed to update title for #${health_issue_number}: ${title_edit_stderr}" >>"$LOGFILE"
		fi
	fi

	return 0
}

#######################################
# Unpin closed/stale supervisor issues to free pin slots
#
# GitHub allows max 3 pinned issues per repo. Old supervisor issues
# that were closed (manually or by dedup) may still be pinned, blocking
# the active health issue from being pinned. This function finds all
# pinned issues in the repo and unpins any that are closed.
#
# Arguments:
#   $1 - repo slug
#   $2 - runner user (for logging)
#######################################
_cleanup_stale_pinned_issues() {
	local repo_slug="$1"
	local runner_user="$2"
	local owner="${repo_slug%%/*}"
	local name="${repo_slug##*/}"

	# Query all pinned issues via GraphQL (parameterized to prevent injection)
	local pinned_json
	pinned_json=$(gh api graphql -F owner="$owner" -F name="$name" -f query="
		query(\$owner: String!, \$name: String!) {
			repository(owner: \$owner, name: \$name) {
				pinnedIssues(first: 10) {
					nodes {
						issue {
							id
							number
							state
							title
						}
					}
				}
			}
		}
		" 2>>"$LOGFILE" || echo "")

	[[ -z "$pinned_json" ]] && return 0

	# Unpin any closed issues
	local closed_pinned
	closed_pinned=$(echo "$pinned_json" | jq -r '.data.repository.pinnedIssues.nodes[] | select(.issue.state == "CLOSED") | "\(.issue.id)|\(.issue.number)"' 2>/dev/null || echo "")

	[[ -z "$closed_pinned" ]] && return 0

	while IFS='|' read -r node_id issue_num; do
		[[ -z "$node_id" ]] && continue
		gh api graphql -f query="
			mutation {
				unpinIssue(input: {issueId: \"${node_id}\"}) {
					issue { number }
				}
			}" >/dev/null 2>&1 || true
		echo "[stats] Health issue: unpinned closed issue #${issue_num} in ${repo_slug}" >>"$LOGFILE"
	done <<<"$closed_pinned"

	return 0
}

#######################################
# Unpin a health issue (best-effort)
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#######################################
_unpin_health_issue() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ -z "$issue_number" || -z "$repo_slug" ]] && return 0

	local issue_node_id
	issue_node_id=$(gh issue view "$issue_number" --repo "$repo_slug" --json id --jq '.id' 2>/dev/null || echo "")
	[[ -z "$issue_node_id" ]] && return 0

	gh api graphql -f query="
		mutation {
			unpinIssue(input: {issueId: \"${issue_node_id}\"}) {
				issue { number }
			}
		}" >/dev/null 2>&1 || true

	return 0
}

#######################################
# Refresh person-stats cache (t1426)
#
# Runs at most once per PERSON_STATS_INTERVAL (default 1h).
# Computes per-repo and cross-repo person-stats, writes markdown
# to cache files. Health issue updates read from cache.
#######################################
_refresh_person_stats_cache() {
	if [[ -f "$PERSON_STATS_LAST_RUN" ]]; then
		local last_run
		last_run=$(cat "$PERSON_STATS_LAST_RUN" 2>/dev/null || echo "0")
		last_run="${last_run//[^0-9]/}"
		last_run="${last_run:-0}"
		local now
		now=$(date +%s)
		if [[ $((now - last_run)) -lt "$PERSON_STATS_INTERVAL" ]]; then
			return 0
		fi
	fi

	local activity_helper="${HOME}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	[[ -x "$activity_helper" ]] || return 0

	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	mkdir -p "$PERSON_STATS_CACHE_DIR"

	# t1426: Estimate Search API cost before calling person_stats().
	# person_stats() burns ~4 Search API requests per contributor per repo.
	# GitHub Search API limit is 30 req/min. Check remaining budget against
	# estimated cost to avoid blocking the pulse with rate-limit sleeps.
	local search_remaining
	search_remaining=$(gh api rate_limit --jq '.resources.search.remaining' 2>/dev/null) || search_remaining=0

	# Per-repo person-stats
	local repo_entries
	repo_entries=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null || echo "")

	# Count repos to estimate minimum cost (at least 1 contributor × 4 queries per repo)
	local repo_count=0
	local search_api_cost_per_contributor=4
	while IFS='|' read -r _slug _path; do
		[[ -z "$_slug" ]] && continue
		repo_count=$((repo_count + 1))
	done <<<"$repo_entries"

	# Minimum budget: repo_count × 1 contributor × 4 queries. In practice,
	# repos have 2-3 contributors, so this is a conservative lower bound.
	local min_budget_needed=$((repo_count * search_api_cost_per_contributor))
	if [[ "$search_remaining" -lt "$min_budget_needed" ]]; then
		echo "[stats] Person stats cache refresh skipped: Search API budget ${search_remaining} < estimated cost ${min_budget_needed} (${repo_count} repos × ${search_api_cost_per_contributor} queries/contributor)" >>"$LOGFILE"
		return 0
	fi

	while IFS='|' read -r slug path; do
		[[ -z "$slug" ]] && continue

		# Re-check budget before each repo — bail early if exhausted mid-refresh
		search_remaining=$(gh api rate_limit --jq '.resources.search.remaining' 2>/dev/null) || search_remaining=0
		if [[ "$search_remaining" -lt "$search_api_cost_per_contributor" ]]; then
			echo "[stats] Person stats cache refresh stopped mid-run: Search API budget exhausted (${search_remaining} remaining)" >>"$LOGFILE"
			break
		fi

		local slug_safe="${slug//\//-}"
		local cache_file="${PERSON_STATS_CACHE_DIR}/person-stats-cache-${slug_safe}.md"
		local md
		md=$(bash "$activity_helper" person-stats "$path" --period month --format markdown 2>/dev/null) || md=""
		if [[ -n "$md" ]]; then
			echo "$md" >"$cache_file"
		fi
	done <<<"$repo_entries"

	# Cross-repo person-stats — also gated on remaining budget
	search_remaining=$(gh api rate_limit --jq '.resources.search.remaining' 2>/dev/null) || search_remaining=0
	local all_repo_paths
	all_repo_paths=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false) | .path' "$repos_json" 2>/dev/null || echo "")
	if [[ -n "$all_repo_paths" && "$search_remaining" -ge "$search_api_cost_per_contributor" ]]; then
		local -a cross_args=()
		while IFS= read -r rp; do
			[[ -n "$rp" ]] && cross_args+=("$rp")
		done <<<"$all_repo_paths"
		if [[ ${#cross_args[@]} -gt 1 ]]; then
			local cross_md
			cross_md=$(bash "$activity_helper" cross-repo-person-stats "${cross_args[@]}" --period month --format markdown 2>/dev/null) || cross_md=""
			if [[ -n "$cross_md" ]]; then
				echo "$cross_md" >"${PERSON_STATS_CACHE_DIR}/person-stats-cache-cross-repo.md"
			fi
		fi
	fi

	date +%s >"$PERSON_STATS_LAST_RUN"
	echo "[stats] Person stats cache refreshed" >>"$LOGFILE"
	return 0
}

#######################################
# Update health issues for ALL pulse-enabled repos
#
# Iterates repos.json and calls _update_health_issue_for_repo for each
# non-local-only repo with a slug. Runs sequentially to avoid gh API
# rate limiting. Best-effort — failures in one repo don't block others.
#######################################
update_health_issues() {
	command -v gh &>/dev/null || return 0
	gh auth status &>/dev/null 2>&1 || return 0

	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local repo_entries
	repo_entries=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null || echo "")

	if [[ -z "$repo_entries" ]]; then
		return 0
	fi

	# Refresh person-stats cache if stale (t1426: hourly, not every pulse)
	_refresh_person_stats_cache || true

	# Pre-compute cross-repo summaries ONCE for all health issues.
	# This avoids N×N git log walks (one cross-repo scan per repo dashboard)
	# and redundant DB queries for session time.
	# Person stats read from cache (refreshed hourly by _refresh_person_stats_cache).
	local cross_repo_md=""
	local cross_repo_session_time_md=""
	local cross_repo_person_stats_md=""
	local activity_helper="${HOME}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	if [[ -x "$activity_helper" ]]; then
		local all_repo_paths
		all_repo_paths=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false) | .path' "$repos_json" || echo "")
		if [[ -n "$all_repo_paths" ]]; then
			local -a cross_args=()
			while IFS= read -r rp; do
				[[ -n "$rp" ]] && cross_args+=("$rp")
			done <<<"$all_repo_paths"
			if [[ ${#cross_args[@]} -gt 1 ]]; then
				cross_repo_md=$(bash "$activity_helper" cross-repo-summary "${cross_args[@]}" --period month --format markdown || echo "_Cross-repo data unavailable._")
				cross_repo_session_time_md=$(bash "$activity_helper" cross-repo-session-time "${cross_args[@]}" --period all --format markdown || echo "_Cross-repo session data unavailable._")
			fi
		fi
	fi
	local cross_repo_cache="${PERSON_STATS_CACHE_DIR}/person-stats-cache-cross-repo.md"
	if [[ -f "$cross_repo_cache" ]]; then
		cross_repo_person_stats_md=$(cat "$cross_repo_cache")
	fi

	local updated=0
	while IFS='|' read -r slug path; do
		[[ -z "$slug" ]] && continue
		_update_health_issue_for_repo "$slug" "$path" "$cross_repo_md" "$cross_repo_session_time_md" "$cross_repo_person_stats_md" || true
		updated=$((updated + 1))
	done <<<"$repo_entries"

	if [[ "$updated" -gt 0 ]]; then
		echo "[stats] Health issues: updated $updated repo(s)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Daily Code Quality Sweep
#
# Runs once per 24h (guarded by timestamp file). For each pulse-enabled
# repo, ensures a persistent "Daily Code Quality Review" issue exists,
# then runs available quality tools and posts a summary comment.
#
# Tools checked (in order):
#   1. ShellCheck — local, always available for repos with .sh files
#   2. Qlty CLI — local, if installed (~/.qlty/bin/qlty)
#   3. CodeRabbit — via @coderabbitai mention on the persistent issue
#   4. Codacy — via API if CODACY_API_TOKEN available
#   5. SonarCloud — via API if sonar-project.properties exists
#
# The supervisor (LLM) reads the comment on the next pulse and creates
# actionable GitHub issues for findings that warrant fixes.
#######################################
run_daily_quality_sweep() {
	# Time-of-day gate — only run during off-peak hours (18:00-23:59 local).
	# Anthropic doubles token allowance during off-peak (6 PM-12 AM UK time),
	# and model demand is lower. Quality sweep findings trigger LLM worker
	# dispatch via the pulse, so landing findings in this window means the
	# resulting workers also run at 2x rates. Override: QUALITY_SWEEP_OFFPEAK=0
	local current_hour
	current_hour=$(date +%H)
	if [[ "${QUALITY_SWEEP_OFFPEAK:-1}" == "1" ]] && ((10#$current_hour < 18)); then
		echo "[stats] Quality sweep deferred: hour ${current_hour} is outside off-peak window (18:00-23:59)" >>"$LOGFILE"
		return 0
	fi

	# Timestamp guard — run at most once per QUALITY_SWEEP_INTERVAL
	if [[ -f "$QUALITY_SWEEP_LAST_RUN" ]]; then
		local last_run
		last_run=$(cat "$QUALITY_SWEEP_LAST_RUN" || echo "0")
		# Strip whitespace/newlines and validate integer (t1397)
		last_run="${last_run//[^0-9]/}"
		last_run="${last_run:-0}"
		local now
		now=$(date +%s)
		local elapsed=$((now - last_run))
		if [[ "$elapsed" -lt "$QUALITY_SWEEP_INTERVAL" ]]; then
			return 0
		fi
	fi

	command -v gh &>/dev/null || return 0
	gh auth status &>/dev/null 2>&1 || return 0

	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local repo_entries
	repo_entries=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null || echo "")

	if [[ -z "$repo_entries" ]]; then
		return 0
	fi

	echo "[stats] Starting daily code quality sweep..." >>"$LOGFILE"

	local swept=0
	while IFS='|' read -r slug path; do
		[[ -z "$slug" ]] && continue
		[[ ! -d "$path" ]] && continue
		_quality_sweep_for_repo "$slug" "$path" || true
		swept=$((swept + 1))
	done <<<"$repo_entries"

	# Update timestamp
	date +%s >"$QUALITY_SWEEP_LAST_RUN"

	echo "[stats] Quality sweep complete: $swept repo(s) swept" >>"$LOGFILE"
	return 0
}

#######################################
# Ensure persistent quality review issue exists for a repo
#
# Creates or finds the "Daily Code Quality Review" issue. Uses labels
# "quality-review" + "persistent" for dedup. Pins the issue.
#
# Arguments:
#   $1 - repo slug
# Output: issue number to stdout
# Returns: 0 on success, 1 if issue could not be created/found
#######################################
_ensure_quality_issue() {
	local repo_slug="$1"
	local slug_safe="${repo_slug//\//-}"
	local cache_file="${HOME}/.aidevops/logs/quality-issue-${slug_safe}"

	mkdir -p "${HOME}/.aidevops/logs"

	# Try cached issue number
	local issue_number=""
	if [[ -f "$cache_file" ]]; then
		issue_number=$(cat "$cache_file" 2>/dev/null || echo "")
	fi

	# Validate cached issue is still open
	if [[ -n "$issue_number" ]]; then
		local state
		state=$(gh issue view "$issue_number" --repo "$repo_slug" --json state --jq '.state' 2>/dev/null || echo "")
		if [[ "$state" != "OPEN" ]]; then
			issue_number=""
			rm -f "$cache_file" 2>/dev/null || true
		fi
	fi

	# Search by labels
	if [[ -z "$issue_number" ]]; then
		issue_number=$(gh issue list --repo "$repo_slug" \
			--label "quality-review" --label "persistent" \
			--state open --json number \
			--jq '.[0].number // empty' 2>/dev/null || echo "")
	fi

	# Create if missing
	if [[ -z "$issue_number" ]]; then
		# Ensure labels exist
		gh label create "quality-review" --repo "$repo_slug" --color "7057FF" \
			--description "Daily code quality review" --force 2>/dev/null || true
		gh label create "persistent" --repo "$repo_slug" --color "FBCA04" \
			--description "Persistent issue — do not close" --force 2>/dev/null || true
		gh label create "source:quality-sweep" --repo "$repo_slug" --color "C2E0C6" \
			--description "Auto-created by stats-functions.sh quality sweep" --force 2>/dev/null || true

		issue_number=$(gh issue create --repo "$repo_slug" \
			--title "Daily Code Quality Review" \
			--body "Persistent issue for daily code quality sweeps across multiple tools (CodeRabbit, Qlty, ShellCheck, Codacy, SonarCloud). The supervisor posts findings here and creates actionable issues from them. **Do not close this issue.**" \
			--label "quality-review" --label "persistent" --label "source:quality-sweep" 2>/dev/null | grep -oE '[0-9]+$' || echo "")

		if [[ -z "$issue_number" ]]; then
			echo "[stats] Quality sweep: could not create issue for ${repo_slug}" >>"$LOGFILE"
			return 1
		fi

		# Pin (best-effort)
		local node_id
		node_id=$(gh issue view "$issue_number" --repo "$repo_slug" --json id --jq '.id' 2>/dev/null || echo "")
		if [[ -n "$node_id" ]]; then
			gh api graphql -f query="
				mutation {
					pinIssue(input: {issueId: \"${node_id}\"}) {
						issue { number }
					}
				}" >/dev/null 2>&1 || true
		fi

		echo "[stats] Quality sweep: created and pinned issue #${issue_number} in ${repo_slug}" >>"$LOGFILE"
	fi

	# Cache
	echo "$issue_number" >"$cache_file"
	echo "$issue_number"
	return 0
}

#######################################
# Load previous quality sweep state for a repo
#
# Reads gate_status and total_issues from the per-repo state file.
# Returns defaults if no state file exists (first run).
#
# Arguments:
#   $1 - repo slug
# Output: "gate_status|total_issues|high_critical_count" to stdout
#######################################
_load_sweep_state() {
	local repo_slug="$1"
	local slug_safe="${repo_slug//\//-}"
	local state_file="${QUALITY_SWEEP_STATE_DIR}/${slug_safe}.json"

	if [[ -f "$state_file" ]]; then
		local prev_gate prev_issues prev_high_critical
		prev_gate=$(jq -r '.gate_status // "UNKNOWN"' "$state_file" 2>/dev/null || echo "UNKNOWN")
		prev_issues=$(jq -r '.total_issues // 0' "$state_file" 2>/dev/null || echo "0")
		prev_high_critical=$(jq -r '.high_critical_count // 0' "$state_file" 2>/dev/null || echo "0")
		echo "${prev_gate}|${prev_issues}|${prev_high_critical}"
	else
		echo "UNKNOWN|0|0"
	fi
	return 0
}

#######################################
# Save current quality sweep state for a repo
#
# Persists gate_status, total_issues, and high/critical severity
# count so the next sweep can compute deltas.
#
# Arguments:
#   $1 - repo slug
#   $2 - gate status (OK/ERROR/UNKNOWN)
#   $3 - total issue count
#   $4 - high+critical severity count
#######################################
_save_sweep_state() {
	local repo_slug="$1"
	local gate_status="$2"
	local total_issues="$3"
	local high_critical_count="$4"
	local qlty_smells="${5:-0}"
	local qlty_grade="${6:-UNKNOWN}"
	local slug_safe="${repo_slug//\//-}"

	mkdir -p "$QUALITY_SWEEP_STATE_DIR"

	local state_file="${QUALITY_SWEEP_STATE_DIR}/${slug_safe}.json"
	printf '{"gate_status":"%s","total_issues":%d,"high_critical_count":%d,"qlty_smells":%d,"qlty_grade":"%s","updated_at":"%s"}\n' \
		"$gate_status" "$total_issues" "$high_critical_count" "$qlty_smells" "$qlty_grade" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		>"$state_file"
	return 0
}

#######################################
# Run quality sweep for a single repo
#
# Gathers findings from all available tools and posts a single
# summary comment on the persistent quality review issue.
#######################################
# Create simplification-debt issues for files with high Qlty smell density.
# Bridges the daily quality sweep to the code-simplifier's human-gated
# dispatch pipeline. Issues are created with simplification-debt +
# needs-maintainer-review labels and assigned to the repo maintainer.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - SARIF JSON string from qlty smells
#
# Behaviour:
#   - Only creates issues for files with >5 smells
#   - Max 3 new issues per sweep (rate limiting)
#   - Deduplicates: skips files that already have an open simplification-debt issue
#   - Issues follow the code-simplifier.md format (needs-maintainer-review gate)
#######################################
_create_simplification_issues() {
	local repo_slug="$1"
	local sarif_json="$2"
	local max_issues_per_sweep=3
	local min_smells_threshold=5
	local issues_created=0

	# Ensure required labels exist (gh issue create fails if labels are missing)
	gh label create "simplification-debt" --repo "$repo_slug" \
		--description "Code simplification opportunity (human-gated via code-simplifier)" \
		--color "C5DEF5" 2>/dev/null || true
	gh label create "needs-maintainer-review" --repo "$repo_slug" \
		--description "Requires maintainer approval before automated dispatch" \
		--color "FBCA04" 2>/dev/null || true
	gh label create "source:quality-sweep" --repo "$repo_slug" \
		--description "Auto-created by stats-functions.sh quality sweep" \
		--color "C2E0C6" --force 2>/dev/null || true

	# Extract files with smell count > threshold, sorted by count descending
	local high_smell_files
	high_smell_files=$(echo "$sarif_json" | jq -r --argjson threshold "$min_smells_threshold" '
		[.runs[0].results[] | .locations[0].physicalLocation.artifactLocation.uri] |
		group_by(.) | map({file: .[0], count: length}) |
		[.[] | select(.count > $threshold)] | sort_by(-.count)[:10] |
		.[] | "\(.count)\t\(.file)"
	' 2>/dev/null) || high_smell_files=""

	if [[ -z "$high_smell_files" ]]; then
		return 0
	fi

	# Resolve maintainer for issue assignment
	local maintainer=""
	maintainer=$(jq -r --arg slug "$repo_slug" \
		'.initialized_repos[]? | select(.slug == $slug) | .maintainer // empty' \
		"${HOME}/.config/aidevops/repos.json" 2>/dev/null) || maintainer=""
	if [[ -z "$maintainer" ]]; then
		maintainer="${repo_slug%%/*}"
	fi

	# Fetch existing open simplification-debt issues to deduplicate
	local existing_issues
	existing_issues=$(gh issue list --repo "$repo_slug" \
		--label "simplification-debt" --state open \
		--json title --jq '.[].title' 2>/dev/null) || existing_issues=""

	while IFS=$'\t' read -r smell_count file_path; do
		[[ -z "$file_path" ]] && continue
		[[ "$issues_created" -ge "$max_issues_per_sweep" ]] && break

		# Deduplicate: check if an issue already exists for this file
		local file_basename
		file_basename=$(basename "$file_path")
		if echo "$existing_issues" | grep -qF "$file_basename"; then
			continue
		fi

		# Build per-rule breakdown for this file
		local rule_breakdown
		rule_breakdown=$(echo "$sarif_json" | jq -r --arg fp "$file_path" '
			[.runs[0].results[] |
			 select(.locations[0].physicalLocation.artifactLocation.uri == $fp) |
			 .ruleId] | group_by(.) | map("\(.[0]): \(length)") | join(", ")
		' 2>/dev/null) || rule_breakdown="(could not parse)"

		# Create the issue with code-simplifier label convention
		local issue_title="simplification: reduce ${smell_count} Qlty smells in ${file_basename}"
		local issue_body
		issue_body="## Qlty Maintainability — ${file_path}

**Smells detected**: ${smell_count}
**Rules**: ${rule_breakdown}

This file was flagged by the daily quality sweep for high smell density. The smells are primarily function complexity, nested control flow, and return statement count — all reducible via extract-function refactoring.

### Suggested approach

1. Read the file and identify the highest-complexity functions
2. Extract helper functions to reduce per-function complexity below the threshold (~17)
3. Verify with \`qlty smells ${file_path}\` after each change
4. No behavior changes — pure structural refactoring

### Verification

- Syntax check: \`python3 -c \"import ast; ast.parse(open('${file_path}').read())\"\` (Python) or \`node --check ${file_path}\` (JS/TS)
- Smell check: \`qlty smells ${file_path} --no-snippets --quiet\`
- No public API changes

---
**To approve or decline**, comment on this issue:
- \`approved\` — removes the review gate and queues for automated dispatch
- \`declined: <reason>\` — closes this issue (include your reason after the colon)"

		if gh issue create --repo "$repo_slug" \
			--title "$issue_title" \
			--label "simplification-debt" --label "needs-maintainer-review" --label "source:quality-sweep" \
			--assignee "$maintainer" \
			--body "$issue_body" >/dev/null 2>&1; then
			issues_created=$((issues_created + 1))
		fi
	done <<<"$high_smell_files"

	if [[ "$issues_created" -gt 0 ]]; then
		qlty_section="${qlty_section}
_Created ${issues_created} simplification-debt issue(s) for high-smell files (needs maintainer review)._
"
	fi

	return 0
}

#
# Arguments:
#   $1 - repo slug
#   $2 - repo path
#######################################
_quality_sweep_for_repo() {
	local repo_slug="$1"
	local repo_path="$2"

	local issue_number
	issue_number=$(_ensure_quality_issue "$repo_slug") || return 0

	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	local findings=""
	local tool_count=0

	# Function-scoped variables for cross-section use (CodeRabbit conditional logic)
	local sweep_gate_status="UNKNOWN"
	local sweep_total_issues=0
	local sweep_high_critical=0

	# --- 1. ShellCheck ---
	# SC1091 is disabled globally in .shellcheckrc and source-path=SCRIPTDIR
	# has been removed (it caused 11 GB RSS / kernel panics — GH#2915).
	# The quality sweep uses --norc + no -x for maximum isolation.
	# Per-file timeout + ulimit + guard_child_processes() remain as
	# defense-in-depth.
	local shellcheck_section=""
	if command -v shellcheck &>/dev/null; then
		local sh_files
		# GH#5663: Use git ls-files to discover only tracked shell scripts.
		# find can return deleted files still on disk, stale worktree paths, or
		# build artifacts — causing false ShellCheck findings on non-existent files.
		if git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
			sh_files=$(git -C "$repo_path" ls-files '*.sh' 2>/dev/null | head -100)
		else
			# Fallback for non-git directories (should not occur for pulse repos)
			sh_files=$(find "$repo_path" -name "*.sh" -not -path "*/archived/*" -not -path "*/node_modules/*" -not -path "*/.git/*" -type f 2>/dev/null | head -100)
		fi

		if [[ -n "$sh_files" ]]; then
			local sc_errors=0
			local sc_warnings=0
			local sc_summary=""
			local sc_details=""

			# timeout_sec (from shared-constants.sh) handles macOS + Linux portably,
			# providing a background + kill fallback on bare macOS so we no longer
			# need to skip ShellCheck when no timeout utility is installed.
			# GH#5663: git ls-files returns relative paths — resolve to absolute
			# before running ShellCheck, and guard against tracked-but-deleted files
			# (index vs working tree mismatch) by skipping missing paths with a log
			# entry rather than passing a non-existent path to ShellCheck.

			while IFS= read -r shfile; do
				[[ -z "$shfile" ]] && continue
				if [[ ! "$shfile" =~ ^/ ]]; then
					shfile="${repo_path}/${shfile}"
				fi
				if [[ ! -f "$shfile" ]]; then
					printf '%s [stats] ShellCheck: skipping missing file: %s\n' \
						"$(date '+%Y-%m-%d %H:%M:%S')" "${shfile}" >>"$LOGFILE"
					continue
				fi
				local result
				# t1398.2: hardened invocation — no -x, --norc, per-file timeout,
				# ulimit -v in subshell to cap RSS per shellcheck process.
				# t1402: stderr merged into stdout (2>&1) so diagnostic messages
				# (parse errors, timeouts, permission failures) are captured in
				# $result and appear in the sweep summary.
				result=$(
					ulimit -v 1048576 2>/dev/null || true
					timeout_sec 30 shellcheck --norc -f gcc "$shfile" 2>&1 || true
				)
				if [[ -n "$result" ]]; then
					local file_errors
					file_errors=$(grep -c ':.*: error:' <<<"$result") || file_errors=0
					local file_warnings
					file_warnings=$(grep -c ':.*: warning:' <<<"$result") || file_warnings=0
					sc_errors=$((sc_errors + file_errors))
					sc_warnings=$((sc_warnings + file_warnings))

					# Capture first 3 findings per file for the summary
					local rel_path="${shfile#"$repo_path"/}"
					local top_findings
					top_findings=$(head -3 <<<"$result" | while IFS= read -r line; do
						echo "  - \`${rel_path}\`: ${line##*: }"
					done)
					if [[ -n "$top_findings" ]]; then
						sc_details="${sc_details}${top_findings}
"
					fi
				fi
			done <<<"$sh_files"

			local file_count
			file_count=$(echo "$sh_files" | wc -l | tr -d ' ')
			shellcheck_section="### ShellCheck ($file_count files scanned)

- **Errors**: ${sc_errors}
- **Warnings**: ${sc_warnings}
"
			if [[ -n "$sc_details" ]]; then
				shellcheck_section="${shellcheck_section}
**Top findings:**
${sc_details}"
			fi
			if [[ "$sc_errors" -eq 0 && "$sc_warnings" -eq 0 ]]; then
				shellcheck_section="${shellcheck_section}
_All clear — no issues found._
"
			fi
			tool_count=$((tool_count + 1))

		fi
	fi

	# --- 2. Qlty CLI (structured SARIF analysis + badge grade) ---
	local qlty_section=""
	local qlty_smell_count=0
	local qlty_grade="UNKNOWN"
	local qlty_bin="${HOME}/.qlty/bin/qlty"
	if [[ -x "$qlty_bin" ]] && [[ -f "${repo_path}/.qlty/qlty.toml" || -f "${repo_path}/.qlty.toml" ]]; then
		# Use SARIF output for machine-parseable smell data (structured by rule, file, location)
		local qlty_sarif
		qlty_sarif=$("$qlty_bin" smells --all --sarif --no-snippets --quiet 2>/dev/null) || qlty_sarif=""

		if [[ -n "$qlty_sarif" ]] && echo "$qlty_sarif" | jq -e '.runs' &>/dev/null; then
			# Single jq pass: extract total count, per-rule breakdown, and top files
			local qlty_data
			qlty_data=$(echo "$qlty_sarif" | jq -r '
				(.runs[0].results | length) as $total |
				([.runs[0].results[] | .ruleId] | group_by(.) | map({rule: .[0], count: length}) | sort_by(-.count)[:8] |
					map("  - \(.rule): \(.count)") | join("\n")) as $rules |
				([.runs[0].results[] | .locations[0].physicalLocation.artifactLocation.uri] |
					group_by(.) | map({file: .[0], count: length}) | sort_by(-.count)[:10] |
					map("  - `\(.file)`: \(.count) smells") | join("\n")) as $files |
				"\($total)|\($rules)|\($files)"
			') || qlty_data="0||"
			qlty_smell_count="${qlty_data%%|*}"
			local qlty_remainder="${qlty_data#*|}"
			local qlty_rules_breakdown="${qlty_remainder%%|*}"
			local qlty_files_breakdown="${qlty_remainder#*|}"
			[[ "$qlty_smell_count" =~ ^[0-9]+$ ]] || qlty_smell_count=0
			qlty_rules_breakdown=$(_sanitize_markdown "$qlty_rules_breakdown")
			qlty_files_breakdown=$(_sanitize_markdown "$qlty_files_breakdown")

			qlty_section="### Qlty Maintainability

- **Total smells**: ${qlty_smell_count}
- **By rule (fix these for maximum grade improvement)**:
${qlty_rules_breakdown}
- **Top files (highest smell density)**:
${qlty_files_breakdown}
"
			if [[ "$qlty_smell_count" -eq 0 ]]; then
				qlty_section="### Qlty Maintainability

_No smells detected — clean codebase._
"
			fi
		else
			qlty_section="### Qlty Maintainability

_Qlty analysis returned empty or failed to parse._
"
		fi

		# Fetch the Qlty Cloud badge grade (A/B/C/D/F) from the badge SVG.
		# The grade is determined by Qlty Cloud's analysis (not local CLI),
		# so we parse the badge colour which maps to the grade letter.
		local badge_svg
		badge_svg=$(curl -sS --fail --connect-timeout 5 --max-time 10 \
			"https://qlty.sh/gh/${repo_slug}/maintainability.svg" 2>/dev/null) || badge_svg=""
		if [[ -n "$badge_svg" ]]; then
			# Grade colour mapping from Qlty's badge palette
			qlty_grade=$(python3 -c "
import sys, re
svg = sys.stdin.read()
colors = {'#22C55E':'A','#84CC16':'B','#EAB308':'C','#F97316':'D','#EF4444':'F'}
for c in re.findall(r'fill=\"(#[A-F0-9]+)\"', svg):
    if c in colors:
        print(colors[c])
        sys.exit(0)
print('UNKNOWN')
" <<<"$badge_svg" 2>/dev/null) || qlty_grade="UNKNOWN"
		fi

		qlty_section="${qlty_section}
- **Qlty Cloud grade**: ${qlty_grade}
"
		tool_count=$((tool_count + 1))

		# --- 2b. Simplification-debt bridge (code-simplifier pipeline) ---
		# For files with high smell density, auto-create simplification-debt issues
		# with needs-maintainer-review label. This bridges the daily sweep to the
		# code-simplifier's human-gated dispatch pipeline (see code-simplifier.md).
		# Max 3 issues per sweep to avoid flooding. Deduplicates against existing issues.
		if [[ -n "$qlty_sarif" && "$qlty_smell_count" -gt 0 ]]; then
			_create_simplification_issues "$repo_slug" "$qlty_sarif"
		fi
	fi

	# --- 3. SonarCloud (public API — no auth needed for public repos) ---
	local sonar_section=""
	if [[ -f "${repo_path}/sonar-project.properties" ]]; then
		local project_key
		project_key=$(grep '^sonar.projectKey=' "${repo_path}/sonar-project.properties" 2>/dev/null | cut -d= -f2)
		local org_key
		org_key=$(grep '^sonar.organization=' "${repo_path}/sonar-project.properties" 2>/dev/null | cut -d= -f2)

		if [[ -n "$project_key" && -n "$org_key" ]]; then
			# URL-encode project_key to prevent injection via crafted sonar-project.properties
			local encoded_project_key
			encoded_project_key=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$project_key" 2>/dev/null) || encoded_project_key=""
			if [[ -z "$encoded_project_key" ]]; then
				echo "[stats] Failed to URL-encode project_key — skipping SonarCloud" >&2
			fi

			# SonarCloud public API — quality gate status
			local sonar_status=""
			if [[ -n "$encoded_project_key" ]]; then
				sonar_status=$(curl -sS --fail --connect-timeout 5 --max-time 20 \
					"https://sonarcloud.io/api/qualitygates/project_status?projectKey=${encoded_project_key}" || echo "")
			fi

			if [[ -n "$sonar_status" ]] && echo "$sonar_status" | jq -e '.projectStatus' &>/dev/null; then
				# Single jq pass: extract gate status, conditions, and failing conditions with remediation
				local gate_data
				gate_data=$(echo "$sonar_status" | jq -r '
					(.projectStatus.status // "UNKNOWN") as $status |
					[.projectStatus.conditions[]? | "- **\(.metricKey)**: \(.actualValue) (\(.status))"] | join("\n") as $conds |
					"\($status)|\($conds)"
				') || gate_data="UNKNOWN|"
				local gate_status="${gate_data%%|*}"
				local conditions="${gate_data#*|}"
				# Sanitise API data before embedding in markdown comment
				gate_status=$(_sanitize_markdown "$gate_status")
				conditions=$(_sanitize_markdown "$conditions")
				# Feed sweep state for CodeRabbit conditional trigger (section 5)
				sweep_gate_status="$gate_status"

				sonar_section="### SonarCloud Quality Gate

- **Status**: ${gate_status}
${conditions}
"
				# Badge-aware diagnostics: when the gate fails, identify the
				# specific failing conditions and provide actionable remediation.
				# This is the root cause improvement — previously the sweep only
				# reported the gate status without explaining what to fix.
				if [[ "$gate_status" == "ERROR" || "$gate_status" == "WARN" ]]; then
					local failing_diagnostics
					failing_diagnostics=$(echo "$sonar_status" | jq -r '
						[.projectStatus.conditions[]? | select(.status == "ERROR" or .status == "WARN") |
						"- **\(.metricKey)**: actual=\(.actualValue), required \(.comparator) \(.errorThreshold) -- " +
						(if .metricKey == "new_security_hotspots_reviewed" then
							"Review unreviewed security hotspots in SonarCloud UI (mark Safe/Fixed) or fix the flagged code"
						elif .metricKey == "new_reliability_rating" then
							"Fix new bugs introduced in the analysis period"
						elif .metricKey == "new_security_rating" then
							"Fix new vulnerabilities introduced in the analysis period"
						elif .metricKey == "new_maintainability_rating" then
							"Reduce new code smells (extract constants, fix unused vars, simplify conditionals)"
						elif .metricKey == "new_duplicated_lines_density" then
							"Reduce code duplication in new code"
						else
							"Check SonarCloud dashboard for details"
						end)
						] | join("\n")
					') || failing_diagnostics=""
					if [[ -n "$failing_diagnostics" ]]; then
						failing_diagnostics=$(_sanitize_markdown "$failing_diagnostics")
						sonar_section="${sonar_section}
**Failing conditions (badge blockers):**
${failing_diagnostics}
"
					fi

					# Fetch unreviewed security hotspots count — this is the most
					# common quality gate blocker for DevOps repos (false positives
					# from shell patterns like curl, npm install, hash algorithms).
					local hotspots_response=""
					hotspots_response=$(curl -sS --fail --connect-timeout 5 --max-time 20 \
						"https://sonarcloud.io/api/hotspots/search?projectKey=${encoded_project_key}&status=TO_REVIEW&ps=5" || echo "")
					if [[ -n "$hotspots_response" ]] && echo "$hotspots_response" | jq -e '.paging' &>/dev/null; then
						local hotspot_total hotspot_details
						hotspot_total=$(echo "$hotspots_response" | jq -r '.paging.total // 0')
						[[ "$hotspot_total" =~ ^[0-9]+$ ]] || hotspot_total=0
						if [[ "$hotspot_total" -gt 0 ]]; then
							hotspot_details=$(echo "$hotspots_response" | jq -r '
								[.hotspots[:5][] |
								"  - `\(.component | split(":") | last):\(.line)` — \(.ruleKey): \(.message | .[0:100])"]
								| join("\n")
							') || hotspot_details=""
							hotspot_details=$(_sanitize_markdown "$hotspot_details")
							sonar_section="${sonar_section}
**Unreviewed security hotspots (${hotspot_total}):**
${hotspot_details}
_Review these in SonarCloud UI or fix the underlying code to pass the quality gate._
"
						fi
					fi
				fi
			fi

			# Fetch open issues summary with rule-level breakdown for targeted fixes
			local sonar_issues=""
			if [[ -n "$encoded_project_key" ]]; then
				sonar_issues=$(curl -sS --fail --connect-timeout 5 --max-time 20 \
					"https://sonarcloud.io/api/issues/search?componentKeys=${encoded_project_key}&statuses=OPEN,CONFIRMED,REOPENED&ps=1&facets=severities,types,rules" || echo "")
			fi

			if [[ -n "$sonar_issues" ]] && echo "$sonar_issues" | jq -e '.total' &>/dev/null; then
				# Single jq pass: extract total, high/critical count, severity breakdown, type breakdown, and top rules
				local issues_data
				issues_data=$(echo "$sonar_issues" | jq -r '
					(.total // 0) as $total |
					([.facets[]? | select(.property == "severities") | .values[]? | select(.val == "MAJOR" or .val == "CRITICAL" or .val == "BLOCKER") | .count] | add // 0) as $hc |
					([.facets[]? | select(.property == "severities") | .values[]? | "  - \(.val): \(.count)"] | join("\n")) as $sev |
					([.facets[]? | select(.property == "types") | .values[]? | "  - \(.val): \(.count)"] | join("\n")) as $typ |
					"\($total)|\($hc)|\($sev)|\($typ)"
				') || issues_data="0|0||"
				local total_issues="${issues_data%%|*}"
				local remainder="${issues_data#*|}"
				local high_critical_count="${remainder%%|*}"
				remainder="${remainder#*|}"
				local severity_breakdown="${remainder%%|*}"
				local type_breakdown="${remainder#*|}"
				# Validate numeric fields before any arithmetic use
				if ! [[ "$total_issues" =~ ^[0-9]+$ ]]; then
					total_issues=0
				fi
				if ! [[ "$high_critical_count" =~ ^[0-9]+$ ]]; then
					high_critical_count=0
				fi
				# Feed sweep state for CodeRabbit conditional trigger (section 5)
				sweep_total_issues="$total_issues"
				sweep_high_critical="$high_critical_count"
				# Sanitise API data before embedding in markdown comment
				severity_breakdown=$(_sanitize_markdown "$severity_breakdown")
				type_breakdown=$(_sanitize_markdown "$type_breakdown")

				sonar_section="${sonar_section}
- **Open issues**: ${total_issues}
- **By severity**:
${severity_breakdown}
- **By type**:
${type_breakdown}
"
				# Rule-level breakdown: shows which rules produce the most issues,
				# enabling targeted batch fixes (e.g., S1192 string constants, S7688
				# bracket style). This is the key data the supervisor needs to create
				# actionable quality-debt issues grouped by rule rather than by file.
				local rules_breakdown
				rules_breakdown=$(echo "$sonar_issues" | jq -r '
					[.facets[]? | select(.property == "rules") | .values[:10][]? |
					"  - \(.val): \(.count) issues"] | join("\n")
				') || rules_breakdown=""
				if [[ -n "$rules_breakdown" ]]; then
					rules_breakdown=$(_sanitize_markdown "$rules_breakdown")
					sonar_section="${sonar_section}
- **Top rules (fix these for maximum badge improvement)**:
${rules_breakdown}
"
				fi
			fi
			tool_count=$((tool_count + 1))
		fi
	fi

	# --- 4. Codacy (API — requires token from gopass) ---
	local codacy_section=""
	local codacy_token=""
	if command -v gopass &>/dev/null; then
		codacy_token=$(gopass show -o "aidevops/CODACY_API_TOKEN" 2>/dev/null || echo "")
	fi
	if [[ -n "$codacy_token" ]]; then
		local codacy_org="${repo_slug%%/*}"
		local codacy_repo="${repo_slug##*/}"
		local codacy_response
		codacy_response=$(curl -s -H "api-token: ${codacy_token}" \
			"https://app.codacy.com/api/v3/organizations/gh/${codacy_org}/repositories/${codacy_repo}/issues/search" \
			-X POST -H "Content-Type: application/json" -d '{"limit":1}' 2>/dev/null || echo "")

		if [[ -n "$codacy_response" ]] && echo "$codacy_response" | jq -e '.pagination' &>/dev/null; then
			local codacy_total
			codacy_total=$(echo "$codacy_response" | jq -r '.pagination.total // 0')
			[[ "$codacy_total" =~ ^[0-9]+$ ]] || codacy_total=0
			codacy_section="### Codacy

- **Open issues**: ${codacy_total}
- **Dashboard**: https://app.codacy.com/gh/${codacy_org}/${codacy_repo}/dashboard
"
			tool_count=$((tool_count + 1))
		fi
	fi

	# --- 5. CodeRabbit trigger (conditional — t1390, fixed t2851) ---
	# Only trigger @coderabbitai active review when quality degrades:
	#   - Quality Gate fails (ERROR/WARN)
	#   - Issue count increases by CODERABBIT_ISSUE_SPIKE+ since last sweep
	# Otherwise post a passive monitoring line to avoid repetitive requests.
	#
	# Root cause of prior failures (PRs #2806, #2832):
	#   1. No first-run guard: when no state file exists, prev_issues=0 and
	#      the delta from 0 to current count always exceeds the spike threshold.
	#   2. Condition 3 (high_critical_delta > 0) was too sensitive — any +1
	#      fluctuation in MAJOR-severity issues triggered a full review.
	#   Both are fixed below: first run saves baseline without triggering,
	#   and condition 3 is removed per the issue spec.
	local coderabbit_section=""
	local prev_state
	prev_state=$(_load_sweep_state "$repo_slug")
	local prev_gate prev_issues prev_high_critical
	IFS='|' read -r prev_gate prev_issues prev_high_critical <<<"$prev_state"
	# Validate numeric fields from state file before arithmetic — corrupted or
	# missing values would cause $(( )) to fail or produce nonsense deltas.
	[[ "$prev_issues" =~ ^[0-9]+$ ]] || prev_issues=0
	[[ "$prev_high_critical" =~ ^[0-9]+$ ]] || prev_high_critical=0

	# First-run guard: if no previous state exists (prev_gate is UNKNOWN from
	# _load_sweep_state default), skip delta-based triggers. Without this, the
	# delta from 0 to current issue count always exceeds the spike threshold,
	# causing every first run (or run after state loss) to trigger a full review.
	#
	# Refactored (t1401): _save_sweep_state and tool_count are common to all
	# branches — hoisted outside the conditional to reduce duplication.
	local is_baseline_run=false
	[[ "$prev_gate" == "UNKNOWN" ]] && is_baseline_run=true

	if [[ "$is_baseline_run" == true ]]; then
		coderabbit_section="### CodeRabbit

_First sweep run — baseline saved (${sweep_total_issues} issues, gate ${sweep_gate_status}). Review trigger will activate on next sweep if quality degrades._
"
		echo "[stats] CodeRabbit: first run for ${repo_slug} — saved baseline, skipping trigger" >>"$LOGFILE"
	else
		local issue_delta=$((sweep_total_issues - prev_issues))
		local reasons=()

		# Condition 1: Quality Gate is failing
		if [[ "$sweep_gate_status" == "ERROR" || "$sweep_gate_status" == "WARN" ]]; then
			reasons+=("quality gate ${sweep_gate_status}")
		fi

		# Condition 2: Issue count spiked by threshold or more
		if [[ "$issue_delta" -ge "$CODERABBIT_ISSUE_SPIKE" ]]; then
			reasons+=("issue spike +${issue_delta}")
		fi

		local trigger_active=false
		local trigger_reasons=""
		if [[ ${#reasons[@]} -gt 0 ]]; then
			trigger_active=true
			# Use printf -v to avoid subshell overhead (Gemini review on PR #2886)
			printf -v trigger_reasons '%s, ' "${reasons[@]}"
			trigger_reasons="${trigger_reasons%, }"
		fi

		if [[ "$trigger_active" == true ]]; then
			coderabbit_section="### CodeRabbit

**Trigger**: ${trigger_reasons}

@coderabbitai Please run a full codebase review of this repository. Focus on:
- Security vulnerabilities and credential exposure
- Shell script quality (error handling, quoting, race conditions)
- Code duplication and maintainability
- Documentation accuracy
"
			echo "[stats] CodeRabbit: active review triggered for ${repo_slug} (${trigger_reasons})" >>"$LOGFILE"
		else
			coderabbit_section="### CodeRabbit

_Monitoring: ${sweep_total_issues} issues (delta: ${issue_delta}), gate ${sweep_gate_status} — no active review needed._
"
		fi
	fi

	# Common to all branches: save state for next sweep and count the tool
	_save_sweep_state "$repo_slug" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" "$qlty_smell_count" "$qlty_grade"
	tool_count=$((tool_count + 1))

	# --- 6. Merged PR review scanner ---
	# Scans recently merged PRs for unactioned review feedback from bots
	# (CodeRabbit, Gemini Code Assist) and humans. Creates quality-debt
	# issues for findings above medium severity.
	local review_scan_section=""
	local review_helper="${SCRIPT_DIR}/quality-feedback-helper.sh"
	if [[ -x "$review_helper" ]]; then
		local scan_output
		scan_output=$("$review_helper" scan-merged \
			--repo "$repo_slug" \
			--batch 30 \
			--create-issues \
			--min-severity medium \
			--json) || scan_output=""

		if [[ -n "$scan_output" ]] && echo "$scan_output" | jq -e '.scanned' &>/dev/null; then
			# Single jq pass: extract all three fields at once
			local scan_data
			scan_data=$(echo "$scan_output" | jq -r '"\(.scanned // 0)|\(.findings // 0)|\(.issues_created // 0)"') || scan_data="0|0|0"
			local scanned="${scan_data%%|*}"
			local remainder="${scan_data#*|}"
			local scan_findings="${remainder%%|*}"
			local scan_issues="${remainder#*|}"
			# Validate integers before any arithmetic comparison
			[[ "$scanned" =~ ^[0-9]+$ ]] || scanned=0
			[[ "$scan_findings" =~ ^[0-9]+$ ]] || scan_findings=0
			[[ "$scan_issues" =~ ^[0-9]+$ ]] || scan_issues=0

			review_scan_section="### Merged PR Review Scanner

- **PRs scanned**: ${scanned}
- **Findings**: ${scan_findings}
- **Issues created**: ${scan_issues}
"
			if [[ "$scan_findings" -gt 0 ]]; then
				review_scan_section="${review_scan_section}
_Issues labelled \`quality-debt\` — capped at 30% of dispatch concurrency._
"
			fi
			tool_count=$((tool_count + 1))
		fi
	fi

	# --- Assemble comment ---
	if [[ "$tool_count" -eq 0 ]]; then
		echo "[stats] Quality sweep: no tools available for ${repo_slug}" >>"$LOGFILE"
		return 0
	fi

	local comment_body="## Daily Code Quality Sweep

**Date**: ${now_iso}
**Repo**: \`${repo_slug}\`
**Tools run**: ${tool_count}

---

${shellcheck_section}
${qlty_section}
${sonar_section}
${codacy_section}
${coderabbit_section}
${review_scan_section}

---
_Auto-generated by stats-wrapper.sh daily quality sweep. The supervisor will review findings and create actionable issues._"

	# --- 7. Update issue body with stats dashboard (t1411) ---
	# Mirrors the supervisor health issue pattern: the issue body is a live
	# dashboard updated each sweep, while comments preserve the daily history.
	# Runs before the comment post so a transient comment failure doesn't
	# leave the dashboard stale (CodeRabbit review feedback).
	_update_quality_issue_body "$repo_slug" "$issue_number" \
		"$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" \
		"$now_iso" "$tool_count" "$qlty_smell_count" "$qlty_grade"

	# Post comment (best-effort — dashboard already updated above)
	local comment_stderr=""
	local comment_posted=false
	comment_stderr=$(gh issue comment "$issue_number" --repo "$repo_slug" --body "$comment_body" 2>&1 >/dev/null) && comment_posted=true || {
		echo "[stats] Quality sweep: failed to post comment on #${issue_number} in ${repo_slug}: ${comment_stderr}" >>"$LOGFILE"
	}

	if [[ "$comment_posted" == true ]]; then
		echo "[stats] Quality sweep: posted findings on #${issue_number} in ${repo_slug} (${tool_count} tools)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Update the quality review issue body with a stats dashboard
#
# Mirrors the supervisor health issue pattern: the body shows at-a-glance
# stats (gate status, backlog, bot coverage, scan history), while daily
# sweep comments preserve the full history.
#
# Arguments:
#   $1 - repo slug
#   $2 - issue number
#   $3 - gate status (OK/ERROR/WARN/UNKNOWN)
#   $4 - total SonarCloud issues
#   $5 - high/critical count
#   $6 - sweep timestamp (ISO)
#   $7 - tool count
#   $8 - qlty smell count (optional)
#   $9 - qlty grade (optional)
#######################################
_update_quality_issue_body() {
	local repo_slug="$1"
	local issue_number="$2"
	local gate_status="$3"
	local total_issues="$4"
	local high_critical="$5"
	local sweep_time="$6"
	local tool_count="$7"
	local qlty_smell_count="${8:-0}"
	local qlty_grade="${9:-UNKNOWN}"

	# --- Quality-debt backlog stats ---
	# Use GraphQL issueCount for accurate totals without pagination limits
	# (CodeRabbit review feedback — gh issue list defaults to 30 results).
	local debt_open=0
	local debt_closed=0
	debt_open=$(gh api graphql \
		-F searchQuery="repo:${repo_slug} is:issue is:open label:quality-debt" \
		-f query="
		query(\$searchQuery: String!) {
			search(query: \$searchQuery, type: ISSUE, first: 1) {
				issueCount
			}
		}" --jq '.data.search.issueCount' 2>>"$LOGFILE" || echo "0")
	debt_closed=$(gh api graphql \
		-F searchQuery="repo:${repo_slug} is:issue is:closed label:quality-debt" \
		-f query="
		query(\$searchQuery: String!) {
			search(query: \$searchQuery, type: ISSUE, first: 1) {
				issueCount
			}
		}" --jq '.data.search.issueCount' 2>>"$LOGFILE" || echo "0")
	# Validate integers
	[[ "$debt_open" =~ ^[0-9]+$ ]] || debt_open=0
	[[ "$debt_closed" =~ ^[0-9]+$ ]] || debt_closed=0
	local debt_total=$((debt_open + debt_closed))
	local debt_resolution_pct=0
	if [[ "$debt_total" -gt 0 ]]; then
		debt_resolution_pct=$((debt_closed * 100 / debt_total))
	fi

	# --- PR scan lifetime stats from state file ---
	local slug_safe="${repo_slug//\//-}"
	local scan_state_file="${HOME}/.aidevops/logs/review-scan-state-${slug_safe}.json"
	local prs_scanned_lifetime=0
	local issues_created_lifetime=0
	if [[ -f "$scan_state_file" ]]; then
		prs_scanned_lifetime=$(jq -r '.scanned_prs | length // 0' "$scan_state_file" 2>>"$LOGFILE" || echo "0")
		issues_created_lifetime=$(jq -r '.issues_created // 0' "$scan_state_file" 2>>"$LOGFILE" || echo "0")
	fi
	[[ "$prs_scanned_lifetime" =~ ^[0-9]+$ ]] || prs_scanned_lifetime=0
	[[ "$issues_created_lifetime" =~ ^[0-9]+$ ]] || issues_created_lifetime=0

	# --- Bot review coverage on open PRs (t1411) ---
	# Check which open PRs have bot reviews and which are still waiting.
	# This surfaces PRs where bots were rate-limited or never posted.
	local bot_coverage_section=""
	local open_prs_json
	open_prs_json=$(gh pr list --repo "$repo_slug" --state open \
		--limit 1000 --json number,title,createdAt 2>>"$LOGFILE") || open_prs_json="[]"
	local open_pr_count
	open_pr_count=$(echo "$open_prs_json" | jq 'length' || echo "0")
	[[ "$open_pr_count" =~ ^[0-9]+$ ]] || open_pr_count=0

	local prs_with_reviews=0
	local prs_waiting=0
	local prs_stale_waiting=""
	local review_helper="${SCRIPT_DIR}/review-bot-gate-helper.sh"

	local helper_available=false
	if [[ "$open_pr_count" -gt 0 && -x "$review_helper" ]]; then
		helper_available=true
	elif [[ "$open_pr_count" -gt 0 ]]; then
		# Helper unavailable but PRs exist — use UNKNOWN sentinel to avoid
		# misleading zero counts (CodeRabbit review feedback)
		prs_with_reviews="UNKNOWN"
		prs_waiting="UNKNOWN"
	fi
	if [[ "$helper_available" == true ]]; then
		# Parse open_prs_json once into per-PR objects to avoid re-parsing the
		# full JSON array on every iteration (Gemini review feedback — GH#3153).
		# Each line is a compact JSON object: {"number":N,"title":"...","createdAt":"..."}
		local pr_objects
		pr_objects=$(echo "$open_prs_json" | jq -c '.[]')
		while IFS= read -r pr_obj; do
			[[ -z "$pr_obj" ]] && continue
			local pr_num
			pr_num=$(echo "$pr_obj" | jq -r '.number')
			[[ -z "$pr_num" || "$pr_num" == "null" ]] && continue
			local gate_result
			gate_result=$("$review_helper" check "$pr_num" "$repo_slug" 2>>"$LOGFILE" || echo "UNKNOWN")
			case "$gate_result" in
			PASS*)
				prs_with_reviews=$((prs_with_reviews + 1))
				;;
			WAITING* | UNKNOWN*)
				prs_waiting=$((prs_waiting + 1))
				# Check if PR is older than 2 hours (stale waiting).
				# Fields already extracted from pr_obj — no re-parse of open_prs_json.
				local pr_created
				pr_created=$(echo "$pr_obj" | jq -r '.createdAt // empty')
				if [[ -n "$pr_created" ]]; then
					local pr_epoch
					pr_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pr_created" +%s 2>/dev/null || date -d "$pr_created" +%s 2>/dev/null || echo "0")
					# Validate epoch is numeric and non-zero — a failed parse
					# falls back to "0" which would produce a huge age (CodeRabbit review)
					[[ "$pr_epoch" =~ ^[0-9]+$ ]] || pr_epoch=0
					if [[ "$pr_epoch" -gt 0 ]]; then
						local now_epoch
						now_epoch=$(date +%s)
						local pr_age_hours=$(((now_epoch - pr_epoch) / 3600))
						if [[ "$pr_age_hours" -ge 2 ]]; then
							local pr_title
							pr_title=$(echo "$pr_obj" | jq -r '.title[:50] // empty')
							# Sanitise PR title — untrusted GitHub content could
							# contain @ mentions or markdown that leaks into the dashboard
							pr_title=$(_sanitize_markdown "$pr_title")
							prs_stale_waiting="${prs_stale_waiting}  - #${pr_num}: ${pr_title} (${pr_age_hours}h old)
"
						fi
					fi
				fi
				;;
			SKIP*)
				prs_with_reviews=$((prs_with_reviews + 1))
				;;
			esac
		done <<<"$pr_objects"
	fi

	# Build bot coverage section — show N/A when helper is unavailable
	# to avoid misleading zero counts (CodeRabbit review feedback)
	if [[ "$helper_available" == true ]]; then
		bot_coverage_section="### Bot Review Coverage

| Metric | Count |
| --- | --- |
| Open PRs | ${open_pr_count} |
| With bot reviews | ${prs_with_reviews} |
| Awaiting bot review | ${prs_waiting} |
"
	elif [[ "$open_pr_count" -gt 0 ]]; then
		bot_coverage_section="### Bot Review Coverage

| Metric | Count |
| --- | --- |
| Open PRs | ${open_pr_count} |
| With bot reviews | N/A |
| Awaiting bot review | N/A |

_review-bot-gate-helper.sh not available — install to enable bot coverage tracking._
"
	else
		bot_coverage_section="### Bot Review Coverage

_No open PRs._
"
	fi

	if [[ -n "$prs_stale_waiting" ]]; then
		bot_coverage_section="${bot_coverage_section}
**PRs waiting >2h for bot review (may need re-trigger):**
${prs_stale_waiting}"
	fi

	# --- Badge status indicator ---
	# Translate gate status + Qlty grade to a human-readable badge indicator
	# so the dashboard immediately shows whether the repo's public badges are green.
	local badge_indicator="UNKNOWN"
	# Qlty grade comes from the function-scoped variable set in section 2
	local sweep_qlty_grade="${qlty_grade:-UNKNOWN}"
	local sweep_qlty_smells="${qlty_smell_count:-0}"

	local sonar_badge="UNKNOWN"
	case "$gate_status" in
	OK) sonar_badge="GREEN" ;;
	ERROR) sonar_badge="RED" ;;
	WARN) sonar_badge="YELLOW" ;;
	esac

	local qlty_badge="UNKNOWN"
	case "$sweep_qlty_grade" in
	A) qlty_badge="GREEN" ;;
	B) qlty_badge="GREEN" ;;
	C) qlty_badge="YELLOW" ;;
	D) qlty_badge="RED" ;;
	F) qlty_badge="RED" ;;
	esac

	if [[ "$sonar_badge" == "GREEN" && "$qlty_badge" == "GREEN" ]]; then
		badge_indicator="GREEN (all badges passing)"
	elif [[ "$sonar_badge" == "RED" || "$qlty_badge" == "RED" ]]; then
		local failing=""
		[[ "$sonar_badge" == "RED" ]] && failing="SonarCloud"
		[[ "$qlty_badge" == "RED" ]] && failing="${failing:+$failing + }Qlty"
		badge_indicator="RED (${failing} failing)"
	elif [[ "$sonar_badge" == "YELLOW" || "$qlty_badge" == "YELLOW" ]]; then
		local warning=""
		[[ "$sonar_badge" == "YELLOW" ]] && warning="SonarCloud"
		[[ "$qlty_badge" == "YELLOW" ]] && warning="${warning:+$warning + }Qlty"
		badge_indicator="YELLOW (${warning} needs improvement)"
	fi

	# --- Assemble dashboard body ---
	local body="## Quality Review Dashboard

**Last sweep**: \`${sweep_time}\`
**Repo**: \`${repo_slug}\`
**Tools run**: ${tool_count}
**Badge status**: ${badge_indicator}

### Summary

| Metric | Value |
| --- | --- |
| SonarCloud gate | ${gate_status} |
| SonarCloud issues | ${total_issues} (${high_critical} high/critical) |
| Qlty grade | ${sweep_qlty_grade} |
| Qlty smells | ${sweep_qlty_smells} |
| Quality-debt open | ${debt_open} |
| Quality-debt closed | ${debt_closed} |
| Quality-debt total | ${debt_total} |
| Resolution rate | ${debt_resolution_pct}% |
| PRs scanned (lifetime) | ${prs_scanned_lifetime} |
| Issues created (lifetime) | ${issues_created_lifetime} |

${bot_coverage_section}

---
_Auto-updated by daily quality sweep. Comments below contain detailed findings per sweep. Do not edit manually._"

	# Update issue body — redirect stderr to log for debugging on failure
	local edit_stderr
	edit_stderr=$(gh issue edit "$issue_number" --repo "$repo_slug" --body "$body" 2>&1 >/dev/null) || {
		echo "[stats] Quality sweep: failed to update body on #${issue_number} in ${repo_slug}: ${edit_stderr}" >>"$LOGFILE"
		return 0
	}

	# Update issue title with stats (like supervisor health issues)
	local debt_label="debt"
	local title_gate="${gate_status}"
	[[ "$gate_status" == "UNKNOWN" ]] && title_gate="--"
	local qlty_title="${sweep_qlty_grade}"
	[[ "$sweep_qlty_grade" == "UNKNOWN" ]] && qlty_title="--"
	local quality_title="Daily Code Quality Review — ${title_gate}, qlty:${qlty_title}, ${debt_open} ${debt_label}, ${total_issues} sonar"
	# Only update title if it changed (avoid unnecessary API calls)
	local current_title
	current_title=$(gh issue view "$issue_number" --repo "$repo_slug" --json title --jq '.title' 2>>"$LOGFILE" || echo "")
	if [[ "$current_title" != "$quality_title" ]]; then
		gh issue edit "$issue_number" --repo "$repo_slug" --title "$quality_title" 2>>"$LOGFILE" >/dev/null || true
	fi

	echo "[stats] Quality sweep: updated dashboard on #${issue_number} in ${repo_slug}" >>"$LOGFILE"
	return 0
}
