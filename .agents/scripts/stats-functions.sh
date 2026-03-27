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
	# Filter both '?' (Linux) and '??' (macOS headless TTY entries.
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
# Find an existing health issue by cache, labels, or title search.
#
# Arguments:
#   $1 - repo slug
#   $2 - runner user
#   $3 - runner role (supervisor|contributor)
#   $4 - runner prefix (e.g. "[Supervisor:user]")
#   $5 - role label (supervisor|contributor)
#   $6 - role display (Supervisor|Contributor)
#   $7 - cache file path
# Output: issue number to stdout (empty if not found)
#######################################
_find_health_issue() {
	local repo_slug="$1"
	local runner_user="$2"
	local runner_role="$3"
	local runner_prefix="$4"
	local role_label="$5"
	local role_display="$6"
	local health_issue_file="$7"

	local health_issue_number=""

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

	# Fallback: title-based search with label backfill
	if [[ -z "$health_issue_number" ]]; then
		health_issue_number=$(gh issue list --repo "$repo_slug" \
			--search "in:title ${runner_prefix}" \
			--state open --json number,title \
			--jq "[.[] | select(.title | startswith(\"${runner_prefix}\"))][0].number" 2>/dev/null || echo "")
		if [[ -n "$health_issue_number" ]]; then
			gh label create "$runner_user" --repo "$repo_slug" --color "0E8A16" \
				--description "${role_display} runner: ${runner_user}" --force 2>/dev/null || true
			gh issue edit "$health_issue_number" --repo "$repo_slug" \
				--add-label "$role_label" --add-label "$runner_user" 2>/dev/null || true
		fi
	fi

	echo "$health_issue_number"
	return 0
}

#######################################
# Create a new health issue for a runner+repo and optionally pin it.
#
# Arguments:
#   $1 - repo slug
#   $2 - runner user
#   $3 - runner role (supervisor|contributor)
#   $4 - runner prefix (e.g. "[Supervisor:user]")
#   $5 - role label (supervisor|contributor)
#   $6 - role label color
#   $7 - role label desc
#   $8 - role display (Supervisor|Contributor)
# Output: new issue number to stdout (empty on failure)
#######################################
_create_health_issue() {
	local repo_slug="$1"
	local runner_user="$2"
	local runner_role="$3"
	local runner_prefix="$4"
	local role_label="$5"
	local role_label_color="$6"
	local role_label_desc="$7"
	local role_display="$8"

	gh label create "$role_label" --repo "$repo_slug" --color "$role_label_color" \
		--description "$role_label_desc" --force 2>/dev/null || true
	gh label create "$runner_user" --repo "$repo_slug" --color "0E8A16" \
		--description "${role_display} runner: ${runner_user}" --force 2>/dev/null || true
	gh label create "source:health-dashboard" --repo "$repo_slug" --color "C2E0C6" \
		--description "Auto-created by stats-functions.sh health dashboard" --force 2>/dev/null || true

	local health_issue_number
	health_issue_number=$(gh issue create --repo "$repo_slug" \
		--title "${runner_prefix} starting..." \
		--body "Live ${runner_role} status for **${runner_user}**. Updated each pulse. Pin this issue for at-a-glance monitoring." \
		--label "$role_label" --label "$runner_user" --label "source:health-dashboard" 2>/dev/null | grep -oE '[0-9]+$' || echo "")

	if [[ -z "$health_issue_number" ]]; then
		echo "[stats] Health issue: could not create for ${repo_slug}" >>"$LOGFILE"
		echo ""
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

	echo "$health_issue_number"
	return 0
}

#######################################
# Resolve (find or create) the health issue number for a runner+repo.
#
# Delegates to _find_health_issue then _create_health_issue if not found.
#
# Arguments:
#   $1 - repo slug
#   $2 - runner user
#   $3 - runner role (supervisor|contributor)
#   $4 - runner prefix (e.g. "[Supervisor:user]")
#   $5 - role label (supervisor|contributor)
#   $6 - role label color
#   $7 - role label desc
#   $8 - role display (Supervisor|Contributor)
#   $9 - cache file path
# Output: issue number to stdout (empty on failure)
#######################################
_resolve_health_issue_number() {
	local repo_slug="$1"
	local runner_user="$2"
	local runner_role="$3"
	local runner_prefix="$4"
	local role_label="$5"
	local role_label_color="$6"
	local role_label_desc="$7"
	local role_display="$8"
	local health_issue_file="$9"

	local health_issue_number
	health_issue_number=$(_find_health_issue \
		"$repo_slug" "$runner_user" "$runner_role" "$runner_prefix" \
		"$role_label" "$role_display" "$health_issue_file")

	if [[ -z "$health_issue_number" ]]; then
		health_issue_number=$(_create_health_issue \
			"$repo_slug" "$runner_user" "$runner_role" "$runner_prefix" \
			"$role_label" "$role_label_color" "$role_label_desc" "$role_display")
	fi

	echo "$health_issue_number"
	return 0
}

#######################################
# Scan active headless worker processes for a repo.
#
# Arguments:
#   $1 - repo path (used to filter workers by --dir)
# Output: "workers_md|worker_count" (newline-delimited fields)
#######################################
_scan_active_workers() {
	local repo_path="$1"

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

	printf '%s\n%s\n' "$workers_md" "$worker_count"
	return 0
}

#######################################
# Collect system resource metrics (CPU, memory, processes).
#
# Output: "sys_load_ratio|sys_cpu_cores|sys_load_1m|sys_load_5m|sys_memory|sys_procs"
#######################################
_gather_system_resources() {
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
		if [[ "$sys_load_1m" =~ ^[0-9]+\.?[0-9]*$ ]] && [[ "$sys_cpu_cores" =~ ^[0-9]+$ ]]; then
			sys_load_ratio=$(awk "BEGIN {printf \"%d\", (${sys_load_1m} / ${sys_cpu_cores}) * 100}" || echo "?")
		fi
	fi

	printf '%s|%s|%s|%s|%s|%s' \
		"$sys_load_ratio" "$sys_cpu_cores" "$sys_load_1m" "$sys_load_5m" "$sys_memory" "$sys_procs"
	return 0
}

#######################################
# Gather live stats for the health issue body.
#
# Collects PR counts, issue counts, active workers, system resources,
# worktree count, max workers, and session count for a single repo.
#
# Arguments:
#   $1 - repo slug
#   $2 - repo path
#   $3 - runner user
# Output: newline-delimited fields:
#   pr_count, prs_md, assigned_issue_count, total_issue_count,
#   workers_md, worker_count, sys_load_ratio, sys_cpu_cores,
#   sys_load_1m, sys_load_5m, sys_memory, sys_procs,
#   wt_count, max_workers, session_count, session_warning
#######################################
_gather_health_stats() {
	local repo_slug="$1"
	local repo_path="$2"
	local runner_user="$3"

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

	# Active headless workers
	local worker_raw workers_md worker_count
	worker_raw=$(_scan_active_workers "$repo_path")
	workers_md=$(printf '%s\n' "$worker_raw" | head -1)
	worker_count=$(printf '%s\n' "$worker_raw" | tail -1)

	# System resources
	local sys_raw sys_load_ratio sys_cpu_cores sys_load_1m sys_load_5m sys_memory sys_procs
	sys_raw=$(_gather_system_resources)
	IFS='|' read -r sys_load_ratio sys_cpu_cores sys_load_1m sys_load_5m sys_memory sys_procs <<<"$sys_raw"

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

	# Output all stats as newline-delimited fields
	printf '%s\n' \
		"$pr_count" \
		"$prs_md" \
		"$assigned_issue_count" \
		"$total_issue_count" \
		"$workers_md" \
		"$worker_count" \
		"$sys_load_ratio" \
		"$sys_cpu_cores" \
		"$sys_load_1m" \
		"$sys_load_5m" \
		"$sys_memory" \
		"$sys_procs" \
		"$wt_count" \
		"$max_workers" \
		"$session_count" \
		"$session_warning"
	return 0
}

#######################################
# Build the health issue body markdown.
#
# Arguments:
#   $1  - now_iso
#   $2  - role_display
#   $3  - runner_user
#   $4  - repo_slug
#   $5  - pr_count
#   $6  - assigned_issue_count
#   $7  - total_issue_count
#   $8  - worker_count
#   $9  - max_workers
#   $10 - wt_count
#   $11 - session_count
#   $12 - session_warning
#   $13 - prs_md
#   $14 - workers_md
#   $15 - person_stats_md
#   $16 - cross_repo_person_stats_md
#   $17 - session_time_md
#   $18 - cross_repo_session_time_md
#   $19 - activity_md
#   $20 - cross_repo_md
#   $21 - sys_load_ratio
#   $22 - sys_cpu_cores
#   $23 - sys_load_1m
#   $24 - sys_load_5m
#   $25 - sys_memory
#   $26 - sys_procs
#   $27 - runner_role
# Output: body markdown to stdout
#######################################
_build_health_issue_body() {
	local now_iso="$1"
	local role_display="$2"
	local runner_user="$3"
	local repo_slug="$4"
	local pr_count="$5"
	local assigned_issue_count="$6"
	local total_issue_count="$7"
	local worker_count="$8"
	local max_workers="$9"
	local wt_count="${10}"
	local session_count="${11}"
	local session_warning="${12}"
	local prs_md="${13}"
	local workers_md="${14}"
	local person_stats_md="${15}"
	local cross_repo_person_stats_md="${16}"
	local session_time_md="${17}"
	local cross_repo_session_time_md="${18}"
	local activity_md="${19}"
	local cross_repo_md="${20}"
	local sys_load_ratio="${21}"
	local sys_cpu_cores="${22}"
	local sys_load_1m="${23}"
	local sys_load_5m="${24}"
	local sys_memory="${25}"
	local sys_procs="${26}"
	local runner_role="${27}"

	cat <<BODY
## Queue Health Dashboard

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
_Auto-updated by ${runner_role} stats process. Do not edit manually._
BODY
	return 0
}

#######################################
# Update the health issue title if the stats have changed.
#
# Avoids unnecessary API calls by comparing the stats portion of the
# title (stripping the timestamp) before issuing an edit.
#
# Arguments:
#   $1 - health_issue_number
#   $2 - repo_slug
#   $3 - runner_prefix
#   $4 - pr_count
#   $5 - pr_label
#   $6 - assigned_issue_count
#   $7 - worker_count
#   $8 - worker_label
#######################################
_update_health_issue_title() {
	local health_issue_number="$1"
	local repo_slug="$2"
	local runner_prefix="$3"
	local pr_count="$4"
	local pr_label="$5"
	local assigned_issue_count="$6"
	local worker_count="$7"
	local worker_label="$8"

	local title_parts="${pr_count} ${pr_label}, ${assigned_issue_count} assigned, ${worker_count} ${worker_label}"
	local title_time
	title_time=$(date -u +"%H:%M")
	local health_title="${runner_prefix} ${title_parts} at ${title_time} UTC"

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
# Gather commit activity and session-time markdown for a single repo.
#
# Arguments:
#   $1 - repo path
#   $2 - slug_safe (slug with / replaced by -)
# Output: activity_md to stdout
#######################################
_gather_activity_stats_for_repo() {
	local repo_path="$1"
	local activity_helper="${HOME}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	if [[ -x "$activity_helper" ]]; then
		bash "$activity_helper" summary "$repo_path" --period month --format markdown || echo "_Activity data unavailable._"
	else
		echo "_Activity helper not installed._"
	fi
	return 0
}

#######################################
# Gather session-time markdown for a single repo.
#
# Arguments:
#   $1 - repo path
# Output: session_time_md to stdout
#######################################
_gather_session_time_for_repo() {
	local repo_path="$1"
	local activity_helper="${HOME}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	if [[ -x "$activity_helper" ]]; then
		bash "$activity_helper" session-time "$repo_path" --period all --format markdown || echo "_Session data unavailable._"
	else
		echo "_Activity helper not installed._"
	fi
	return 0
}

#######################################
# Read person-stats from the hourly cache for a repo.
#
# Arguments:
#   $1 - slug_safe (slug with / replaced by -)
# Output: person_stats_md to stdout
#######################################
_read_person_stats_cache() {
	local slug_safe="$1"
	local ps_cache="${PERSON_STATS_CACHE_DIR}/person-stats-cache-${slug_safe}.md"
	if [[ -f "$ps_cache" ]]; then
		cat "$ps_cache"
	else
		echo "_Person stats not yet cached._"
	fi
	return 0
}

#######################################
# Gather all stats and assemble the health issue body markdown.
#
# Combines _gather_health_stats, activity helpers, and _build_health_issue_body
# into a single call to keep _update_health_issue_for_repo under 100 lines.
#
# Arguments:
#   $1  - repo_slug
#   $2  - repo_path
#   $3  - runner_user
#   $4  - slug_safe
#   $5  - now_iso
#   $6  - role_display
#   $7  - runner_role
#   $8  - cross_repo_md
#   $9  - cross_repo_session_time_md
#   $10 - cross_repo_person_stats_md
# Output: body markdown to stdout
#######################################
_assemble_health_issue_body() {
	local repo_slug="$1"
	local repo_path="$2"
	local runner_user="$3"
	local slug_safe="$4"
	local now_iso="$5"
	local role_display="$6"
	local runner_role="$7"
	local cross_repo_md="$8"
	local cross_repo_session_time_md="$9"
	local cross_repo_person_stats_md="${10}"

	# Gather live stats via temp file (avoids subshell variable loss)
	local stats_tmp
	stats_tmp=$(mktemp)
	_gather_health_stats "$repo_slug" "$repo_path" "$runner_user" >"$stats_tmp"

	local pr_count prs_md assigned_issue_count total_issue_count
	local workers_md worker_count sys_load_ratio sys_cpu_cores
	local sys_load_1m sys_load_5m sys_memory sys_procs
	local wt_count max_workers session_count session_warning
	{
		IFS= read -r pr_count
		IFS= read -r prs_md
		IFS= read -r assigned_issue_count
		IFS= read -r total_issue_count
		IFS= read -r workers_md
		IFS= read -r worker_count
		IFS= read -r sys_load_ratio
		IFS= read -r sys_cpu_cores
		IFS= read -r sys_load_1m
		IFS= read -r sys_load_5m
		IFS= read -r sys_memory
		IFS= read -r sys_procs
		IFS= read -r wt_count
		IFS= read -r max_workers
		IFS= read -r session_count
		IFS= read -r session_warning
	} <"$stats_tmp"
	rm -f "$stats_tmp"

	local activity_md session_time_md person_stats_md
	activity_md=$(_gather_activity_stats_for_repo "$repo_path" "$slug_safe")
	session_time_md=$(_gather_session_time_for_repo "$repo_path")
	person_stats_md=$(_read_person_stats_cache "$slug_safe")

	_build_health_issue_body \
		"$now_iso" "$role_display" "$runner_user" "$repo_slug" \
		"$pr_count" "$assigned_issue_count" "$total_issue_count" \
		"$worker_count" "$max_workers" "$wt_count" \
		"$session_count" "$session_warning" \
		"$prs_md" "$workers_md" \
		"$person_stats_md" "$cross_repo_person_stats_md" \
		"$session_time_md" "$cross_repo_session_time_md" \
		"$activity_md" "$cross_repo_md" \
		"$sys_load_ratio" "$sys_cpu_cores" "$sys_load_1m" "$sys_load_5m" \
		"$sys_memory" "$sys_procs" "$runner_role"
	return 0
}

#######################################
# Resolve role-specific config variables for a runner.
#
# Outputs pipe-delimited fields:
#   runner_prefix|role_label|role_label_color|role_label_desc|role_display
#
# Arguments:
#   $1 - runner_user
#   $2 - runner_role (supervisor|contributor)
#######################################
_resolve_runner_role_config() {
	local runner_user="$1"
	local runner_role="$2"

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

	printf '%s|%s|%s|%s|%s' \
		"$runner_prefix" "$role_label" "$role_label_color" \
		"$role_label_desc" "$role_display"
	return 0
}

#######################################
# Ensure the active health issue is pinned (supervisor-only).
#
# Unpins closed/stale issues to free pin slots (max 3 per repo),
# then pins the active issue idempotently.
#
# Arguments:
#   $1 - health_issue_number
#   $2 - repo_slug
#   $3 - runner_user (for _cleanup_stale_pinned_issues)
#######################################
_ensure_health_issue_pinned() {
	local health_issue_number="$1"
	local repo_slug="$2"
	local runner_user="$3"

	_cleanup_stale_pinned_issues "$repo_slug" "$runner_user"

	local active_node_id
	active_node_id=$(gh issue view "$health_issue_number" --repo "$repo_slug" \
		--json id --jq '.id' 2>/dev/null || echo "")
	if [[ -n "$active_node_id" ]]; then
		gh api graphql -f query="
			mutation {
				pinIssue(input: {issueId: \"${active_node_id}\"}) {
					issue { number }
				}
			}" >/dev/null 2>&1 || true
	fi
	return 0
}

#######################################
# Extract headline counts from a rendered health issue body.
#
# Parses the Summary table rows for Open PRs, Assigned Issues,
# and Active Workers to avoid re-running stats queries.
#
# Arguments:
#   $1 - body (multiline markdown string)
# Output: "pr_count|assigned_issue_count|worker_count"
#######################################
_extract_body_counts() {
	local body="$1"

	local pr_count=0
	local assigned_issue_count=0
	local worker_count=0
	local body_line
	while IFS= read -r body_line; do
		if [[ "$body_line" =~ ^\|\ Open\ PRs\ \|\ ([0-9]+)\ \|$ ]]; then
			pr_count="${BASH_REMATCH[1]}"
		elif [[ "$body_line" =~ ^\|\ Assigned\ Issues\ \|\ ([0-9]+)\ \|$ ]]; then
			assigned_issue_count="${BASH_REMATCH[1]}"
		elif [[ "$body_line" =~ ^\|\ Active\ Workers\ \|\ ([0-9]+)\ \|$ ]]; then
			worker_count="${BASH_REMATCH[1]}"
		fi
	done <<<"$body"

	printf '%s|%s|%s' "$pr_count" "$assigned_issue_count" "$worker_count"
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

	local runner_user
	runner_user=$(gh api user --jq '.login' || whoami)

	local runner_role
	runner_role=$(_get_runner_role "$runner_user" "$repo_slug")

	local role_config runner_prefix role_label role_label_color role_label_desc role_display
	role_config=$(_resolve_runner_role_config "$runner_user" "$runner_role")
	IFS='|' read -r runner_prefix role_label role_label_color role_label_desc role_display \
		<<<"$role_config"

	local slug_safe="${repo_slug//\//-}"
	local cache_dir="${HOME}/.aidevops/logs"
	local health_issue_file="${cache_dir}/health-issue-${runner_user}-${role_label}-${slug_safe}"
	mkdir -p "$cache_dir"

	local health_issue_number
	health_issue_number=$(_resolve_health_issue_number \
		"$repo_slug" "$runner_user" "$runner_role" "$runner_prefix" \
		"$role_label" "$role_label_color" "$role_label_desc" \
		"$role_display" "$health_issue_file")
	[[ -z "$health_issue_number" ]] && return 0

	if [[ "$runner_role" == "supervisor" ]]; then
		_ensure_health_issue_pinned "$health_issue_number" "$repo_slug" "$runner_user"
	fi

	echo "$health_issue_number" >"$health_issue_file"

	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	local body
	body=$(_assemble_health_issue_body \
		"$repo_slug" "$repo_path" "$runner_user" "$slug_safe" \
		"$now_iso" "$role_display" "$runner_role" \
		"$cross_repo_md" "$cross_repo_session_time_md" "$cross_repo_person_stats_md")

	local body_edit_stderr
	body_edit_stderr=$(gh issue edit "$health_issue_number" --repo "$repo_slug" \
		--body "$body" 2>&1 >/dev/null) || {
		echo "[stats] Health issue: failed to update body for #${health_issue_number}: ${body_edit_stderr}" \
			>>"$LOGFILE"
		return 0
	}

	# Re-extract headline counts from the rendered body to build the title.
	# Avoids relying on function-local variables from _assemble_health_issue_body.
	local counts_raw pr_count assigned_issue_count worker_count
	counts_raw=$(_extract_body_counts "$body")
	IFS='|' read -r pr_count assigned_issue_count worker_count <<<"$counts_raw"

	local pr_label="PRs"
	[[ "$pr_count" -eq 1 ]] && pr_label="PR"
	local worker_label="workers"
	[[ "$worker_count" -eq 1 ]] && worker_label="worker"

	_update_health_issue_title \
		"$health_issue_number" "$repo_slug" "$runner_prefix" \
		"$pr_count" "$pr_label" "$assigned_issue_count" \
		"$worker_count" "$worker_label"

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
	# Time-of-day gate — only run during Anthropic's 2x usage boost hours.
	# Claude doubles usage allowance outside peak: for UK/GMT that's 18:00-11:59
	# (standard 1x is only 12:00-17:59). Weekends are 2x all day, all timezones.
	# Reference: https://claude.ai — "Claude 2x usage boost" schedule.
	# Peak hours by timezone (standard 1x only):
	#   Pacific PT:  05:00-10:59    UK GMT:     12:00-17:59
	#   Eastern ET:  08:00-13:59    CET:        13:00-18:59
	# Quality sweep findings trigger LLM worker dispatch via the pulse, so
	# landing findings in the 2x window means workers also run at boosted rates.
	# Override: QUALITY_SWEEP_OFFPEAK=0
	local current_hour current_dow
	current_hour=$(date +%H)
	current_dow=$(date +%u) # 1=Monday, 7=Sunday
	# Weekends (Sat=6, Sun=7) are 2x all day — always run
	if [[ "${QUALITY_SWEEP_OFFPEAK:-1}" == "1" ]] && ((current_dow < 6)); then
		# Weekday: defer during peak hours only (12:00-17:59 UK/GMT).
		# Users in other timezones can override via QUALITY_SWEEP_PEAK_START
		# and QUALITY_SWEEP_PEAK_END environment variables.
		local peak_start peak_end
		peak_start="${QUALITY_SWEEP_PEAK_START:-12}"
		peak_end="${QUALITY_SWEEP_PEAK_END:-18}"
		if ((10#$current_hour >= 10#$peak_start && 10#$current_hour < 10#$peak_end)); then
			echo "[stats] Quality sweep deferred: hour ${current_hour} is peak (${peak_start}:00-$((peak_end - 1)):59), 2x boost inactive" >>"$LOGFILE"
			return 0
		fi
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
			--title "Code Audit Routines" \
			--body "Persistent dashboard for automated code quality and simplification routines (ShellCheck, Qlty, SonarCloud, Codacy, CodeRabbit). The supervisor posts findings here and creates actionable issues from them. **Do not close this issue.**" \
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
# Run ShellCheck on all tracked .sh files in a repo.
#
# Arguments:
#   $1 - repo slug
#   $2 - repo path
# Output: shellcheck_section markdown to stdout
#######################################
_sweep_shellcheck() {
	local repo_slug="$1"
	local repo_path="$2"

	command -v shellcheck &>/dev/null || return 0

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

	[[ -z "$sh_files" ]] && return 0

	local sc_errors=0
	local sc_warnings=0
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
	local shellcheck_section="### ShellCheck ($file_count files scanned)

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

	printf '%s' "$shellcheck_section"
	return 0
}

#######################################
# Run Qlty CLI analysis on a repo.
#
# Arguments:
#   $1 - repo slug
#   $2 - repo path
# Sets caller variables via stdout (pipe-delimited):
#   qlty_section|qlty_smell_count|qlty_grade
#######################################
_sweep_qlty() {
	local repo_slug="$1"
	local repo_path="$2"

	local qlty_bin="${HOME}/.qlty/bin/qlty"
	if [[ ! -x "$qlty_bin" ]] || [[ ! -f "${repo_path}/.qlty/qlty.toml" && ! -f "${repo_path}/.qlty.toml" ]]; then
		printf '%s|%s|%s' "" "0" "UNKNOWN"
		return 0
	fi

	# Use SARIF output for machine-parseable smell data (structured by rule, file, location)
	local qlty_sarif
	qlty_sarif=$("$qlty_bin" smells --all --sarif --no-snippets --quiet 2>/dev/null) || qlty_sarif=""

	local qlty_smell_count=0
	local qlty_grade="UNKNOWN"
	local qlty_section=""

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

	# --- 2b. Simplification-debt bridge (code-simplifier pipeline) ---
	# For files with high smell density, auto-create simplification-debt issues
	# with needs-maintainer-review label. This bridges the daily sweep to the
	# code-simplifier's human-gated dispatch pipeline (see code-simplifier.md).
	# Max 3 issues per sweep to avoid flooding. Deduplicates against existing issues.
	if [[ -n "$qlty_sarif" && "$qlty_smell_count" -gt 0 ]]; then
		_create_simplification_issues "$repo_slug" "$qlty_sarif"
	fi

	printf '%s|%s|%s' "$qlty_section" "$qlty_smell_count" "$qlty_grade"
	return 0
}

#######################################
# Run SonarCloud quality gate check for a repo.
#
# Arguments:
#   $1 - repo path
# Output: pipe-delimited "sonar_section|sweep_gate_status|sweep_total_issues|sweep_high_critical"
#######################################
_sweep_sonarcloud() {
	local repo_path="$1"

	local sonar_section=""
	local sweep_gate_status="UNKNOWN"
	local sweep_total_issues=0
	local sweep_high_critical=0

	[[ -f "${repo_path}/sonar-project.properties" ]] || {
		printf '%s|%s|%s|%s' "$sonar_section" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical"
		return 0
	}

	local project_key
	project_key=$(grep '^sonar.projectKey=' "${repo_path}/sonar-project.properties" 2>/dev/null | cut -d= -f2)
	local org_key
	org_key=$(grep '^sonar.organization=' "${repo_path}/sonar-project.properties" 2>/dev/null | cut -d= -f2)

	if [[ -z "$project_key" || -z "$org_key" ]]; then
		printf '%s|%s|%s|%s' "$sonar_section" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical"
		return 0
	fi

	# URL-encode project_key to prevent injection via crafted sonar-project.properties
	local encoded_project_key
	encoded_project_key=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$project_key" 2>/dev/null) || encoded_project_key=""
	if [[ -z "$encoded_project_key" ]]; then
		echo "[stats] Failed to URL-encode project_key — skipping SonarCloud" >&2
		printf '%s|%s|%s|%s' "$sonar_section" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical"
		return 0
	fi

	# SonarCloud public API — quality gate status
	local sonar_status=""
	sonar_status=$(curl -sS --fail --connect-timeout 5 --max-time 20 \
		"https://sonarcloud.io/api/qualitygates/project_status?projectKey=${encoded_project_key}" || echo "")

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
		sweep_gate_status="$gate_status"

		sonar_section="### SonarCloud Quality Gate

- **Status**: ${gate_status}
${conditions}
"
		# Badge-aware diagnostics: when the gate fails, identify the
		# specific failing conditions and provide actionable remediation.
		if [[ "$gate_status" == "ERROR" || "$gate_status" == "WARN" ]]; then
			sonar_section="${sonar_section}$(_sweep_sonarcloud_diagnostics "$sonar_status" "$encoded_project_key")"
		fi
	fi

	# Fetch open issues summary with rule-level breakdown for targeted fixes
	local issues_section total_issues high_critical_count
	issues_section=$(_sweep_sonarcloud_issues "$encoded_project_key")
	total_issues="${issues_section%%|*}"
	local issues_remainder="${issues_section#*|}"
	high_critical_count="${issues_remainder%%|*}"
	local issues_md="${issues_remainder#*|}"
	[[ "$total_issues" =~ ^[0-9]+$ ]] || total_issues=0
	[[ "$high_critical_count" =~ ^[0-9]+$ ]] || high_critical_count=0
	sweep_total_issues="$total_issues"
	sweep_high_critical="$high_critical_count"
	if [[ -n "$issues_md" ]]; then
		sonar_section="${sonar_section}${issues_md}"
	fi

	printf '%s|%s|%s|%s' "$sonar_section" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical"
	return 0
}

#######################################
# Fetch SonarCloud open issues summary with rule-level breakdown.
#
# Arguments:
#   $1 - encoded_project_key
# Output: "total_issues|high_critical_count|issues_md"
#######################################
_sweep_sonarcloud_issues() {
	local encoded_project_key="$1"

	local sonar_issues=""
	sonar_issues=$(curl -sS --fail --connect-timeout 5 --max-time 20 \
		"https://sonarcloud.io/api/issues/search?componentKeys=${encoded_project_key}&statuses=OPEN,CONFIRMED,REOPENED&ps=1&facets=severities,types,rules" || echo "")

	if [[ -z "$sonar_issues" ]] || ! echo "$sonar_issues" | jq -e '.total' &>/dev/null; then
		printf '%s|%s|%s' "0" "0" ""
		return 0
	fi

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
	[[ "$total_issues" =~ ^[0-9]+$ ]] || total_issues=0
	[[ "$high_critical_count" =~ ^[0-9]+$ ]] || high_critical_count=0
	severity_breakdown=$(_sanitize_markdown "$severity_breakdown")
	type_breakdown=$(_sanitize_markdown "$type_breakdown")

	local issues_md="
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
		issues_md="${issues_md}
- **Top rules (fix these for maximum badge improvement)**:
${rules_breakdown}
"
	fi

	printf '%s|%s|%s' "$total_issues" "$high_critical_count" "$issues_md"
	return 0
}

#######################################
# Build SonarCloud failing-condition diagnostics markdown.
#
# Called only when gate_status is ERROR or WARN.
#
# Arguments:
#   $1 - sonar_status JSON
#   $2 - encoded_project_key
# Output: diagnostics markdown to stdout
#######################################
_sweep_sonarcloud_diagnostics() {
	local sonar_status="$1"
	local encoded_project_key="$2"

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
		printf '\n**Failing conditions (badge blockers):**\n%s\n' "$failing_diagnostics"
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
			printf '\n**Unreviewed security hotspots (%s):**\n%s\n_Review these in SonarCloud UI or fix the underlying code to pass the quality gate._\n' \
				"$hotspot_total" "$hotspot_details"
		fi
	fi

	return 0
}

#######################################
# Run Codacy API check for a repo.
#
# Arguments:
#   $1 - repo slug
# Output: codacy_section markdown to stdout (empty if unavailable)
#######################################
_sweep_codacy() {
	local repo_slug="$1"

	local codacy_token=""
	if command -v gopass &>/dev/null; then
		codacy_token=$(gopass show -o "aidevops/CODACY_API_TOKEN" 2>/dev/null || echo "")
	fi
	[[ -z "$codacy_token" ]] && return 0

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
		printf '### Codacy\n\n- **Open issues**: %s\n- **Dashboard**: https://app.codacy.com/gh/%s/%s/dashboard\n' \
			"$codacy_total" "$codacy_org" "$codacy_repo"
	fi

	return 0
}

#######################################
# Build the CodeRabbit trigger section for a quality sweep.
#
# Arguments:
#   $1 - repo slug
#   $2 - sweep_gate_status
#   $3 - sweep_total_issues
# Output: coderabbit_section markdown to stdout
#######################################
_sweep_coderabbit() {
	local repo_slug="$1"
	local sweep_gate_status="$2"
	local sweep_total_issues="$3"

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
	if [[ "$prev_gate" == "UNKNOWN" ]]; then
		echo "[stats] CodeRabbit: first run for ${repo_slug} — saved baseline, skipping trigger" >>"$LOGFILE"
		printf '### CodeRabbit\n\n_First sweep run — baseline saved (%s issues, gate %s). Review trigger will activate on next sweep if quality degrades._\n' \
			"$sweep_total_issues" "$sweep_gate_status"
		return 0
	fi

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

	if [[ ${#reasons[@]} -gt 0 ]]; then
		local trigger_reasons=""
		# Use printf -v to avoid subshell overhead (Gemini review on PR #2886)
		printf -v trigger_reasons '%s, ' "${reasons[@]}"
		trigger_reasons="${trigger_reasons%, }"
		echo "[stats] CodeRabbit: active review triggered for ${repo_slug} (${trigger_reasons})" >>"$LOGFILE"
		printf '### CodeRabbit\n\n**Trigger**: %s\n\n@coderabbitai Please run a full codebase review of this repository. Focus on:\n- Security vulnerabilities and credential exposure\n- Shell script quality (error handling, quoting, race conditions)\n- Code duplication and maintainability\n- Documentation accuracy\n' \
			"$trigger_reasons"
	else
		printf '### CodeRabbit\n\n_Monitoring: %s issues (delta: %s), gate %s — no active review needed._\n' \
			"$sweep_total_issues" "$issue_delta" "$sweep_gate_status"
	fi

	return 0
}

#######################################
# Run merged PR review scanner for a repo.
#
# Arguments:
#   $1 - repo slug
# Output: review_scan_section markdown to stdout (empty if unavailable)
#######################################
_sweep_review_scanner() {
	local repo_slug="$1"

	local review_helper="${SCRIPT_DIR}/quality-feedback-helper.sh"
	[[ -x "$review_helper" ]] || return 0

	local scan_output
	scan_output=$("$review_helper" scan-merged \
		--repo "$repo_slug" \
		--batch 30 \
		--create-issues \
		--min-severity medium \
		--json) || scan_output=""

	[[ -z "$scan_output" ]] && return 0
	echo "$scan_output" | jq -e '.scanned' &>/dev/null || return 0

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

	local review_scan_section="### Merged PR Review Scanner

- **PRs scanned**: ${scanned}
- **Findings**: ${scan_findings}
- **Issues created**: ${scan_issues}
"
	if [[ "$scan_findings" -gt 0 ]]; then
		review_scan_section="${review_scan_section}
_Issues labelled \`quality-debt\` — capped at 30% of dispatch concurrency._
"
	fi

	printf '%s' "$review_scan_section"
	return 0
}

#######################################
# Run quality sweep for a single repo
#
# Gathers findings from all available tools and posts a single
# summary comment on the persistent quality review issue.
#
# Arguments:
#   $1 - repo slug
#   $2 - repo path
#######################################

#######################################
# Build the daily quality sweep comment body.
#
# Arguments:
#   $1  - now_iso
#   $2  - repo_slug
#   $3  - tool_count
#   $4  - shellcheck_section
#   $5  - qlty_section
#   $6  - sonar_section
#   $7  - codacy_section
#   $8  - coderabbit_section
#   $9  - review_scan_section
# Output: comment markdown to stdout
#######################################
_build_sweep_comment() {
	local now_iso="$1"
	local repo_slug="$2"
	local tool_count="$3"
	local shellcheck_section="$4"
	local qlty_section="$5"
	local sonar_section="$6"
	local codacy_section="$7"
	local coderabbit_section="$8"
	local review_scan_section="$9"

	cat <<COMMENT
## Daily Code Quality Sweep

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
_Auto-generated by stats-wrapper.sh daily quality sweep. The supervisor will review findings and create actionable issues._
COMMENT
	return 0
}

#######################################
# Run all quality sweep tools for a repo and return results.
#
# Arguments:
#   $1 - repo slug
#   $2 - repo path
# Output: pipe-delimited
#   tool_count|shellcheck_section|qlty_section|qlty_smell_count|qlty_grade|
#   sonar_section|sweep_gate_status|sweep_total_issues|sweep_high_critical|
#   codacy_section|coderabbit_section|review_scan_section
#######################################
_run_sweep_tools() {
	local repo_slug="$1"
	local repo_path="$2"

	local tool_count=0
	local sweep_gate_status="UNKNOWN"
	local sweep_total_issues=0
	local sweep_high_critical=0

	local shellcheck_section=""
	shellcheck_section=$(_sweep_shellcheck "$repo_slug" "$repo_path")
	[[ -n "$shellcheck_section" ]] && tool_count=$((tool_count + 1))

	local qlty_section="" qlty_smell_count=0 qlty_grade="UNKNOWN"
	local qlty_raw
	qlty_raw=$(_sweep_qlty "$repo_slug" "$repo_path")
	if [[ -n "$qlty_raw" ]]; then
		qlty_section="${qlty_raw%%|*}"
		local qlty_remainder="${qlty_raw#*|}"
		qlty_smell_count="${qlty_remainder%%|*}"
		qlty_grade="${qlty_remainder#*|}"
		[[ -n "$qlty_section" ]] && tool_count=$((tool_count + 1))
	fi

	local sonar_section=""
	local sonar_raw
	sonar_raw=$(_sweep_sonarcloud "$repo_path")
	if [[ -n "$sonar_raw" ]]; then
		sonar_section="${sonar_raw%%|*}"
		local sonar_remainder="${sonar_raw#*|}"
		sweep_gate_status="${sonar_remainder%%|*}"
		sonar_remainder="${sonar_remainder#*|}"
		sweep_total_issues="${sonar_remainder%%|*}"
		sweep_high_critical="${sonar_remainder#*|}"
		[[ -n "$sonar_section" ]] && tool_count=$((tool_count + 1))
	fi

	local codacy_section=""
	codacy_section=$(_sweep_codacy "$repo_slug")
	[[ -n "$codacy_section" ]] && tool_count=$((tool_count + 1))

	local coderabbit_section=""
	coderabbit_section=$(_sweep_coderabbit "$repo_slug" "$sweep_gate_status" "$sweep_total_issues")
	_save_sweep_state "$repo_slug" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" "$qlty_smell_count" "$qlty_grade"
	tool_count=$((tool_count + 1))

	local review_scan_section=""
	review_scan_section=$(_sweep_review_scanner "$repo_slug")
	[[ -n "$review_scan_section" ]] && tool_count=$((tool_count + 1))

	printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
		"$tool_count" "$shellcheck_section" "$qlty_section" \
		"$qlty_smell_count" "$qlty_grade" "$sonar_section" \
		"$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" \
		"$codacy_section" "$coderabbit_section" "$review_scan_section"
	return 0
}

_quality_sweep_for_repo() {
	local repo_slug="$1"
	local repo_path="$2"

	local issue_number
	issue_number=$(_ensure_quality_issue "$repo_slug") || return 0

	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# Run all tools and read results via temp file
	local tools_tmp
	tools_tmp=$(mktemp)
	_run_sweep_tools "$repo_slug" "$repo_path" >"$tools_tmp"

	local tool_count shellcheck_section qlty_section qlty_smell_count qlty_grade
	local sonar_section sweep_gate_status sweep_total_issues sweep_high_critical
	local codacy_section coderabbit_section review_scan_section
	{
		IFS= read -r tool_count
		IFS= read -r shellcheck_section
		IFS= read -r qlty_section
		IFS= read -r qlty_smell_count
		IFS= read -r qlty_grade
		IFS= read -r sonar_section
		IFS= read -r sweep_gate_status
		IFS= read -r sweep_total_issues
		IFS= read -r sweep_high_critical
		IFS= read -r codacy_section
		IFS= read -r coderabbit_section
		IFS= read -r review_scan_section
	} <"$tools_tmp"
	rm -f "$tools_tmp"

	if [[ "${tool_count:-0}" -eq 0 ]]; then
		echo "[stats] Quality sweep: no tools available for ${repo_slug}" >>"$LOGFILE"
		return 0
	fi

	# Update issue body dashboard first (best-effort — comment is secondary)
	_update_quality_issue_body "$repo_slug" "$issue_number" \
		"$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" \
		"$now_iso" "$tool_count" "$qlty_smell_count" "$qlty_grade"

	# Post daily comment with full findings
	local comment_body
	comment_body=$(_build_sweep_comment \
		"$now_iso" "$repo_slug" "$tool_count" \
		"$shellcheck_section" "$qlty_section" "$sonar_section" \
		"$codacy_section" "$coderabbit_section" "$review_scan_section")

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
# Build the simplification-debt issue body for a single file.
#
# Arguments:
#   $1 - file_path
#   $2 - smell_count
#   $3 - rule_breakdown
# Output: issue body markdown to stdout
#######################################
_build_simplification_issue_body() {
	local file_path="$1"
	local smell_count="$2"
	local rule_breakdown="$3"

	cat <<BODY
## Qlty Maintainability — ${file_path}

**Smells detected**: ${smell_count}
**Rules**: ${rule_breakdown}

This file was flagged by the daily quality sweep for high smell density. The smells are primarily function complexity, nested control flow, and return statement count — all reducible via extract-function refactoring.

### Suggested approach

1. Read the file and identify the highest-complexity functions
2. Extract helper functions to reduce per-function complexity below the threshold (~17)
3. Verify with \`qlty smells ${file_path}\` after each change
4. No behavior changes — pure structural refactoring

### Verification

- Syntax check: \`python3 -c "import ast; ast.parse(open('${file_path}').read())"\` (Python) or \`node --check ${file_path}\` (JS/TS)
- Smell check: \`qlty smells ${file_path} --no-snippets --quiet\`
- No public API changes

---
**To approve or decline**, comment on this issue:
- \`approved\` — removes the review gate and queues for automated dispatch
- \`declined: <reason>\` — closes this issue (include your reason after the colon)
BODY
	return 0
}

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

	# Total-open cap: stop creating when backlog is already large
	local total_open
	total_open=$(gh api graphql -f query="query { repository(owner:\"${repo_slug%%/*}\", name:\"${repo_slug##*/}\") { issues(labels:[\"simplification-debt\"], states:OPEN) { totalCount } } }" \
		--jq '.data.repository.issues.totalCount' 2>/dev/null) || total_open="0"
	if [[ "${total_open:-0}" -ge 100 ]]; then
		echo "[stats] Simplification issues: skipping — ${total_open} open (cap: 100)" >>"$LOGFILE"
		return 0
	fi

	while IFS=$'\t' read -r smell_count file_path; do
		[[ -z "$file_path" ]] && continue
		[[ "$issues_created" -ge "$max_issues_per_sweep" ]] && break

		# Deduplicate via server-side title search — accurate across all issues.
		# The file path is in the title, so searching by path is reliable.
		local existing_count
		existing_count=$(gh issue list --repo "$repo_slug" \
			--label "simplification-debt" --state open \
			--search "in:title \"$file_path\"" \
			--json number --jq 'length' 2>/dev/null) || existing_count="0"
		if [[ "${existing_count:-0}" -gt 0 ]]; then
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
		local file_basename="${file_path##*/}"
		local issue_title="simplification: reduce ${smell_count} Qlty smells in ${file_basename}"
		local issue_body
		issue_body=$(_build_simplification_issue_body "$file_path" "$smell_count" "$rule_breakdown")

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

#######################################
# Compute quality-debt backlog stats for the quality issue dashboard.
#
# Arguments:
#   $1 - repo slug
# Output: pipe-delimited "debt_open|debt_closed|debt_total|debt_resolution_pct"
#######################################
_compute_debt_stats() {
	local repo_slug="$1"

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

	printf '%s|%s|%s|%s' "$debt_open" "$debt_closed" "$debt_total" "$debt_resolution_pct"
	return 0
}

#######################################
# Compute bot review coverage stats for open PRs.
#
# Arguments:
#   $1 - repo slug
# Output: bot_coverage_section markdown to stdout
#######################################
#######################################
# Check bot review status for each open PR and accumulate counts.
#
# Arguments:
#   $1 - pr_objects (newline-delimited compact JSON objects)
#   $2 - repo_slug
#   $3 - review_helper path
# Output: "prs_with_reviews|prs_waiting|prs_stale_waiting"
#######################################
_check_pr_bot_coverage() {
	local pr_objects="$1"
	local repo_slug="$2"
	local review_helper="$3"

	local prs_with_reviews=0
	local prs_waiting=0
	local prs_stale_waiting=""

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
			local pr_created
			pr_created=$(echo "$pr_obj" | jq -r '.createdAt // empty')
			if [[ -n "$pr_created" ]]; then
				local pr_epoch
				pr_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pr_created" +%s 2>/dev/null || date -d "$pr_created" +%s 2>/dev/null || echo "0")
				[[ "$pr_epoch" =~ ^[0-9]+$ ]] || pr_epoch=0
				if [[ "$pr_epoch" -gt 0 ]]; then
					local now_epoch
					now_epoch=$(date +%s)
					local pr_age_hours=$(((now_epoch - pr_epoch) / 3600))
					if [[ "$pr_age_hours" -ge 2 ]]; then
						local pr_title
						pr_title=$(echo "$pr_obj" | jq -r '.title[:50] // empty')
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

	printf '%s|%s|%s' "$prs_with_reviews" "$prs_waiting" "$prs_stale_waiting"
	return 0
}

_compute_bot_coverage() {
	local repo_slug="$1"

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
	fi

	if [[ "$helper_available" == true ]]; then
		# Parse open_prs_json once into per-PR objects to avoid re-parsing the
		# full JSON array on every iteration (Gemini review feedback — GH#3153).
		local pr_objects
		pr_objects=$(echo "$open_prs_json" | jq -c '.[]')
		local coverage_raw
		coverage_raw=$(_check_pr_bot_coverage "$pr_objects" "$repo_slug" "$review_helper")
		prs_with_reviews="${coverage_raw%%|*}"
		local cov_remainder="${coverage_raw#*|}"
		prs_waiting="${cov_remainder%%|*}"
		prs_stale_waiting="${cov_remainder#*|}"
	fi

	# Build bot coverage section — show N/A when helper is unavailable
	# to avoid misleading zero counts (CodeRabbit review feedback)
	local bot_coverage_section=""
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

	printf '%s' "$bot_coverage_section"
	return 0
}

#######################################
# Compute badge status indicator from gate status and Qlty grade.
#
# Arguments:
#   $1 - gate_status (OK/ERROR/WARN/UNKNOWN)
#   $2 - qlty_grade (A/B/C/D/F/UNKNOWN)
# Output: badge_indicator string to stdout
#######################################
_compute_badge_indicator() {
	local gate_status="$1"
	local qlty_grade="$2"

	local sonar_badge="UNKNOWN"
	case "$gate_status" in
	OK) sonar_badge="GREEN" ;;
	ERROR) sonar_badge="RED" ;;
	WARN) sonar_badge="YELLOW" ;;
	esac

	local qlty_badge="UNKNOWN"
	case "$qlty_grade" in
	A) qlty_badge="GREEN" ;;
	B) qlty_badge="GREEN" ;;
	C) qlty_badge="YELLOW" ;;
	D) qlty_badge="RED" ;;
	F) qlty_badge="RED" ;;
	esac

	local badge_indicator="UNKNOWN"
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

	printf '%s' "$badge_indicator"
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
	local debt_raw
	debt_raw=$(_compute_debt_stats "$repo_slug")
	local debt_open="${debt_raw%%|*}"
	local debt_remainder="${debt_raw#*|}"
	local debt_closed="${debt_remainder%%|*}"
	debt_remainder="${debt_remainder#*|}"
	local debt_total="${debt_remainder%%|*}"
	local debt_resolution_pct="${debt_remainder#*|}"

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
	local bot_coverage_section
	bot_coverage_section=$(_compute_bot_coverage "$repo_slug")

	# --- Badge status indicator ---
	local badge_indicator
	badge_indicator=$(_compute_badge_indicator "$gate_status" "$qlty_grade")

	# --- Simplification progress ---
	# Count files tracked in simplification state (git-committed registry)
	local simplified_count=0
	local repo_path
	repo_path=$(jq -r --arg slug "$repo_slug" \
		'.initialized_repos[]? | select(.slug == $slug) | .path // empty' \
		"${HOME}/.config/aidevops/repos.json" 2>/dev/null) || repo_path=""
	local state_file=""
	if [[ -n "$repo_path" ]]; then
		state_file="${repo_path}/.agents/configs/simplification-state.json"
	fi
	if [[ -f "$state_file" ]]; then
		simplified_count=$(jq '.files | length' "$state_file" 2>/dev/null) || simplified_count=0
	fi

	# Sanitize all variables to single-line values — prevents multi-line
	# tool output (e.g., ShellCheck findings) from leaking into the dashboard
	# table when the newline-delimited passing from _run_sweep_tools breaks.
	gate_status="${gate_status%%$'\n'*}"
	total_issues="${total_issues%%$'\n'*}"
	high_critical="${high_critical%%$'\n'*}"
	qlty_grade="${qlty_grade%%$'\n'*}"
	qlty_smell_count="${qlty_smell_count%%$'\n'*}"
	# Validate numeric fields — fall back to 0/UNKNOWN if corrupted
	[[ "$total_issues" =~ ^[0-9]+$ ]] || total_issues=0
	[[ "$high_critical" =~ ^[0-9]+$ ]] || high_critical=0
	[[ "$qlty_smell_count" =~ ^[0-9]+$ ]] || qlty_smell_count=0

	# --- Assemble dashboard body ---
	local body="## Code Audit Routines

**Last sweep**: \`${sweep_time}\`
**Repo**: \`${repo_slug}\`
**Tools run**: ${tool_count}
**Badge status**: ${badge_indicator}

### Quality

| Metric | Value |
| --- | --- |
| SonarCloud gate | ${gate_status} |
| SonarCloud issues | ${total_issues} (${high_critical} high/critical) |
| Qlty grade | ${qlty_grade} |
| Qlty smells | ${qlty_smell_count} |

### Simplification

| Metric | Value |
| --- | --- |
| Open | ${debt_open} |
| Closed | ${debt_closed} |
| Simplified (state tracked) | ${simplified_count} |
| Resolution rate | ${debt_resolution_pct}% |

### PR Scanning

| Metric | Value |
| --- | --- |
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

	# Update issue title — clean summary stats only, no raw tool output
	local quality_title="Code Audit Routines — Open: ${debt_open} | Closed: ${debt_closed} | Simplified: ${simplified_count}"
	# Only update title if it changed (avoid unnecessary API calls)
	local current_title
	current_title=$(gh issue view "$issue_number" --repo "$repo_slug" --json title --jq '.title' 2>>"$LOGFILE" || echo "")
	if [[ "$current_title" != "$quality_title" ]]; then
		gh issue edit "$issue_number" --repo "$repo_slug" --title "$quality_title" 2>>"$LOGFILE" >/dev/null || true
	fi

	echo "[stats] Quality sweep: updated dashboard on #${issue_number} in ${repo_slug}" >>"$LOGFILE"
	return 0
}
