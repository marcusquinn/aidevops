#!/usr/bin/env bash
# pulse-wrapper.sh - Wrapper for supervisor pulse with dedup and lifecycle management
#
# Solves: opencode run enters idle state after completing the pulse prompt
# but never exits, blocking all future pulses via the pgrep dedup guard.
#
# This wrapper:
#   1. Uses a PID file with staleness check (not pgrep) for dedup
#   2. Cleans up orphaned opencode processes before each pulse
#   3. Kills runaway processes exceeding RSS or runtime limits (t1398.1)
#   4. Calculates dynamic worker concurrency from available RAM
#   5. Internal watchdog kills stuck pulses after PULSE_STALE_THRESHOLD (t1397)
#   6. Self-watchdog: idle detection kills pulse when CPU drops to zero (t1398.3)
#   7. Progress-based watchdog: kills if log output stalls for PULSE_PROGRESS_TIMEOUT (GH#2958)
#
# Lifecycle: launchd fires every 120s. If a pulse is still running, the
# dedup check skips. run_pulse() has an internal watchdog that polls every
# 60s and checks three conditions:
#   a) Wall-clock timeout: kills if elapsed > PULSE_STALE_THRESHOLD (60 min)
#   b) Idle detection: kills if CPU usage stays below PULSE_IDLE_CPU_THRESHOLD
#      for PULSE_IDLE_TIMEOUT consecutive seconds (default 5 min). This catches
#      the opencode idle-state bug where the process completes but sits in a
#      file watcher consuming no CPU. Without this, zombies persist until the
#      next launchd invocation detects staleness — which fails if launchd
#      stops firing (sleep, plist unloaded).
#   c) Progress detection (GH#2958): kills if the log file hasn't grown for
#      PULSE_PROGRESS_TIMEOUT seconds. A process that's running but producing
#      no output is stuck — not productive. This catches cases where CPU is
#      nonzero (network I/O, spinning) but no actual work is being done.
# check_dedup() serves as a tertiary safety net for edge cases where the
# wrapper itself gets stuck.
#
# Called by launchd every 120s via the supervisor-pulse plist.

set -euo pipefail

#######################################
# PATH normalisation
# The MCP shell environment may have a minimal PATH that excludes /bin
# and other standard directories, causing `env bash` to fail. Ensure
# essential directories are always present.
#######################################
export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

# Use ${BASH_SOURCE[0]:-$0} for shell portability — BASH_SOURCE is undefined
# in zsh, which is the MCP shell environment. This fallback ensures SCRIPT_DIR
# resolves correctly whether the script is executed directly (bash) or sourced
# from zsh. See GH#3931.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || return 2>/dev/null || exit
source "${SCRIPT_DIR}/shared-constants.sh"
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"

#######################################
# Configuration
#######################################
PULSE_STALE_THRESHOLD="${PULSE_STALE_THRESHOLD:-3600}"    # 60 min hard ceiling (raised from 30 min — GH#2958)
PULSE_IDLE_TIMEOUT="${PULSE_IDLE_TIMEOUT:-300}"           # 5 min idle = process completed, sitting in file watcher (t1398.3)
PULSE_IDLE_CPU_THRESHOLD="${PULSE_IDLE_CPU_THRESHOLD:-5}" # CPU% below this = idle (0-100 scale)
PULSE_PROGRESS_TIMEOUT="${PULSE_PROGRESS_TIMEOUT:-600}"   # 10 min no log output = stuck (GH#2958)
ORPHAN_MAX_AGE="${ORPHAN_MAX_AGE:-7200}"                  # 2 hours — kill orphans older than this
RAM_PER_WORKER_MB="${RAM_PER_WORKER_MB:-1024}"            # 1 GB per worker
RAM_RESERVE_MB="${RAM_RESERVE_MB:-8192}"                  # 8 GB reserved for OS + user apps
MAX_WORKERS_CAP="${MAX_WORKERS_CAP:-8}"                   # Hard ceiling regardless of RAM
QUALITY_SWEEP_INTERVAL="${QUALITY_SWEEP_INTERVAL:-86400}" # 24 hours between sweeps
PERSON_STATS_INTERVAL="${PERSON_STATS_INTERVAL:-3600}"    # 1 hour between person-stats refreshes (t1426)
DAILY_PR_CAP="${DAILY_PR_CAP:-5}"                         # Max PRs created per repo per day (GH#3821)
PRODUCT_RESERVATION_PCT="${PRODUCT_RESERVATION_PCT:-60}"  # % of worker slots reserved for product repos (t1423)

# Process guard limits (t1398)
CHILD_RSS_LIMIT_KB="${CHILD_RSS_LIMIT_KB:-2097152}"           # 2 GB default — kill child if RSS exceeds this
CHILD_RUNTIME_LIMIT="${CHILD_RUNTIME_LIMIT:-1800}"            # 30 min default — raised from 10 min (GH#2958, quality scans need time)
SHELLCHECK_RSS_LIMIT_KB="${SHELLCHECK_RSS_LIMIT_KB:-1048576}" # 1 GB — ShellCheck-specific (lower due to exponential expansion)
SHELLCHECK_RUNTIME_LIMIT="${SHELLCHECK_RUNTIME_LIMIT:-300}"   # 5 min — ShellCheck-specific
SESSION_COUNT_WARN="${SESSION_COUNT_WARN:-5}"                 # Warn when >N concurrent sessions detected

# Validate numeric configuration (uses _validate_int from worker-lifecycle-common.sh)
PULSE_STALE_THRESHOLD=$(_validate_int PULSE_STALE_THRESHOLD "$PULSE_STALE_THRESHOLD" 3600)
PULSE_IDLE_TIMEOUT=$(_validate_int PULSE_IDLE_TIMEOUT "$PULSE_IDLE_TIMEOUT" 300 60)
PULSE_IDLE_CPU_THRESHOLD=$(_validate_int PULSE_IDLE_CPU_THRESHOLD "$PULSE_IDLE_CPU_THRESHOLD" 5)
PULSE_PROGRESS_TIMEOUT=$(_validate_int PULSE_PROGRESS_TIMEOUT "$PULSE_PROGRESS_TIMEOUT" 600 120)
ORPHAN_MAX_AGE=$(_validate_int ORPHAN_MAX_AGE "$ORPHAN_MAX_AGE" 7200)
RAM_PER_WORKER_MB=$(_validate_int RAM_PER_WORKER_MB "$RAM_PER_WORKER_MB" 1024 1)
RAM_RESERVE_MB=$(_validate_int RAM_RESERVE_MB "$RAM_RESERVE_MB" 8192)
MAX_WORKERS_CAP=$(_validate_int MAX_WORKERS_CAP "$MAX_WORKERS_CAP" 8)
QUALITY_SWEEP_INTERVAL=$(_validate_int QUALITY_SWEEP_INTERVAL "$QUALITY_SWEEP_INTERVAL" 86400)
PERSON_STATS_INTERVAL=$(_validate_int PERSON_STATS_INTERVAL "$PERSON_STATS_INTERVAL" 3600)
DAILY_PR_CAP=$(_validate_int DAILY_PR_CAP "$DAILY_PR_CAP" 5 1)
PRODUCT_RESERVATION_PCT=$(_validate_int PRODUCT_RESERVATION_PCT "$PRODUCT_RESERVATION_PCT" 60 0)
CHILD_RSS_LIMIT_KB=$(_validate_int CHILD_RSS_LIMIT_KB "$CHILD_RSS_LIMIT_KB" 2097152 1)
CHILD_RUNTIME_LIMIT=$(_validate_int CHILD_RUNTIME_LIMIT "$CHILD_RUNTIME_LIMIT" 1800 1)
SHELLCHECK_RSS_LIMIT_KB=$(_validate_int SHELLCHECK_RSS_LIMIT_KB "$SHELLCHECK_RSS_LIMIT_KB" 1048576 1)
SHELLCHECK_RUNTIME_LIMIT=$(_validate_int SHELLCHECK_RUNTIME_LIMIT "$SHELLCHECK_RUNTIME_LIMIT" 300 1)
SESSION_COUNT_WARN=$(_validate_int SESSION_COUNT_WARN "$SESSION_COUNT_WARN" 5 1)

# _sanitize_markdown and _sanitize_log_field provided by worker-lifecycle-common.sh

PIDFILE="${HOME}/.aidevops/logs/pulse.pid"
LOGFILE="${HOME}/.aidevops/logs/pulse.log"
SESSION_FLAG="${HOME}/.aidevops/logs/pulse-session.flag"
STOP_FLAG="${HOME}/.aidevops/logs/pulse-session.stop"
OPENCODE_BIN="${OPENCODE_BIN:-/opt/homebrew/bin/opencode}"
PULSE_DIR="${PULSE_DIR:-${HOME}/Git/aidevops}"
PULSE_MODEL="${PULSE_MODEL:-anthropic/claude-sonnet-4-6}"
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
STATE_FILE="${HOME}/.aidevops/logs/pulse-state.txt"
QUALITY_SWEEP_LAST_RUN="${HOME}/.aidevops/logs/quality-sweep-last-run"
PERSON_STATS_LAST_RUN="${HOME}/.aidevops/logs/person-stats-last-run"
PERSON_STATS_CACHE_DIR="${HOME}/.aidevops/logs"
QUALITY_SWEEP_STATE_DIR="${HOME}/.aidevops/logs/quality-sweep-state"
CODERABBIT_ISSUE_SPIKE="${CODERABBIT_ISSUE_SPIKE:-10}" # trigger active review when issues increase by this many

#######################################
# Ensure log directory exists
#######################################
mkdir -p "$(dirname "$PIDFILE")"

#######################################
# Check for stale PID file and clean up
# Returns: 0 if safe to proceed, 1 if another pulse is genuinely running
#######################################
check_dedup() {
	if [[ ! -f "$PIDFILE" ]]; then
		return 0
	fi

	local old_pid
	old_pid=$(cat "$PIDFILE" 2>/dev/null || echo "")

	if [[ -z "$old_pid" ]]; then
		rm -f "$PIDFILE"
		return 0
	fi

	# Check if the process is still running
	if ! ps -p "$old_pid" >/dev/null; then
		# Process is dead, clean up stale PID file
		rm -f "$PIDFILE"
		return 0
	fi

	# Process is running — check how long
	local elapsed_seconds
	elapsed_seconds=$(_get_process_age "$old_pid")

	if [[ "$elapsed_seconds" -gt "$PULSE_STALE_THRESHOLD" ]]; then
		# Process has been running too long — it's stuck.
		# Guard kill commands with || true so set -e doesn't abort cleanup
		# if the target process has already exited between checks.
		echo "[pulse-wrapper] Killing stale pulse process $old_pid (running ${elapsed_seconds}s, threshold ${PULSE_STALE_THRESHOLD}s)" >>"$LOGFILE"
		_kill_tree "$old_pid" || true
		sleep 2
		# Force kill if still alive
		if kill -0 "$old_pid" 2>/dev/null; then
			_force_kill_tree "$old_pid" || true
		fi
		rm -f "$PIDFILE"
		return 0
	fi

	# Process is running and within time limit — genuine dedup
	echo "[pulse-wrapper] Pulse already running (PID $old_pid, ${elapsed_seconds}s elapsed). Skipping." >>"$LOGFILE"
	return 1
}

# Process lifecycle functions (_kill_tree, _force_kill_tree, _get_process_age,
# _get_pid_cpu, _get_process_tree_cpu) provided by worker-lifecycle-common.sh

#######################################
# Pre-fetch state for ALL pulse-enabled repos
#
# Runs gh pr list + gh issue list for each repo in parallel, formats
# a compact summary, and writes it to STATE_FILE. This is injected
# into the pulse prompt so the agent sees all repos from the start —
# preventing the "only processes first repo" problem.
#
# This is a deterministic data-fetch utility. The intelligence about
# what to DO with this data stays in pulse.md.
#######################################
prefetch_state() {
	local repos_json="$REPOS_JSON"

	if [[ ! -f "$repos_json" ]]; then
		echo "[pulse-wrapper] repos.json not found at $repos_json — skipping prefetch" >>"$LOGFILE"
		echo "ERROR: repos.json not found" >"$STATE_FILE"
		return 1
	fi

	echo "[pulse-wrapper] Pre-fetching state for all pulse-enabled repos..." >>"$LOGFILE"

	# Extract pulse-enabled, non-local-only repos as slug|path pairs
	local repo_entries
	repo_entries=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json")

	if [[ -z "$repo_entries" ]]; then
		echo "[pulse-wrapper] No pulse-enabled repos found" >>"$LOGFILE"
		echo "No pulse-enabled repos found in repos.json" >"$STATE_FILE"
		return 1
	fi

	# Temp dir for parallel fetches
	local tmpdir
	tmpdir=$(mktemp -d)

	# Launch parallel gh fetches for each repo
	local pids=()
	local idx=0
	while IFS='|' read -r slug path; do
		(
			local outfile="${tmpdir}/${idx}.txt"
			{
				echo "## ${slug} (${path})"
				echo ""

				# PRs (createdAt included for daily PR cap — GH#3821)
				local pr_json
				pr_json=$(gh pr list --repo "$slug" --state open \
					--json number,title,reviewDecision,statusCheckRollup,updatedAt,headRefName,createdAt \
					--limit 100 2>/dev/null) || pr_json="[]"

				local pr_count
				pr_count=$(echo "$pr_json" | jq 'length')

				if [[ "$pr_count" -gt 0 ]]; then
					echo "### Open PRs ($pr_count)"
					echo "$pr_json" | jq -r '.[] | "- PR #\(.number): \(.title) [checks: \(if .statusCheckRollup == null or (.statusCheckRollup | length) == 0 then "none" elif (.statusCheckRollup | all((.conclusion // .state) == "SUCCESS")) then "PASS" elif (.statusCheckRollup | any((.conclusion // .state) == "FAILURE")) then "FAIL" else "PENDING" end)] [review: \(if .reviewDecision == null or .reviewDecision == "" then "NONE" else .reviewDecision end)] [branch: \(.headRefName)] [updated: \(.updatedAt)]"'
				else
					echo "### Open PRs (0)"
					echo "- None"
				fi

				echo ""

				# Daily PR cap (GH#3821) — count PRs created today to prevent
				# CodeRabbit quota exhaustion from too many PRs in one day.
				# Reuses pr_json already fetched above (no extra API call).
				local today_utc
				today_utc=$(date -u +%Y-%m-%d)
				local daily_pr_count
				daily_pr_count=$(echo "$pr_json" | jq --arg today "$today_utc" \
					'[.[] | select(.createdAt | startswith($today))] | length') || daily_pr_count=0
				[[ "$daily_pr_count" =~ ^[0-9]+$ ]] || daily_pr_count=0
				local daily_pr_remaining=$((DAILY_PR_CAP - daily_pr_count))
				if [[ "$daily_pr_remaining" -lt 0 ]]; then
					daily_pr_remaining=0
				fi

				echo "### Daily PR Cap"
				if [[ "$daily_pr_count" -ge "$DAILY_PR_CAP" ]]; then
					echo "- **DAILY PR CAP REACHED** — ${daily_pr_count}/${DAILY_PR_CAP} PRs created today (UTC)"
					echo "- **DO NOT dispatch new workers for this repo.** Wait for the next UTC day."
					echo "[pulse-wrapper] Daily PR cap reached for ${slug}: ${daily_pr_count}/${DAILY_PR_CAP}" >>"$LOGFILE"
				else
					echo "- PRs created today: ${daily_pr_count}/${DAILY_PR_CAP} (${daily_pr_remaining} remaining)"
				fi

				echo ""

				# Issues (include assignees for dispatch dedup)
				# Filter out supervisor/contributor/persistent/quality-review issues —
				# these are managed by pulse-wrapper.sh and must not be touched by the
				# pulse agent. Exposing them in pre-fetched state causes the LLM to
				# close them as "stale", creating churn (wrapper recreates on next cycle).
				local issue_json
				issue_json=$(gh issue list --repo "$slug" --state open \
					--json number,title,labels,updatedAt,assignees \
					--limit 50 2>/dev/null) || issue_json="[]"

				# Remove issues with supervisor, contributor, persistent, or quality-review labels
				local filtered_json
				filtered_json=$(echo "$issue_json" | jq '[.[] | select(.labels | map(.name) | (index("supervisor") or index("contributor") or index("persistent") or index("quality-review")) | not)]')

				local issue_count
				issue_count=$(echo "$filtered_json" | jq 'length')

				if [[ "$issue_count" -gt 0 ]]; then
					echo "### Open Issues ($issue_count)"
					echo "$filtered_json" | jq -r '.[] | "- Issue #\(.number): \(.title) [labels: \(if (.labels | length) == 0 then "none" else (.labels | map(.name) | join(", ")) end)] [assignees: \(if (.assignees | length) == 0 then "none" else (.assignees | map(.login) | join(", ")) end)] [updated: \(.updatedAt)]"'
				else
					echo "### Open Issues (0)"
					echo "- None"
				fi

				echo ""
			} >"$outfile"
		) &
		pids+=($!)
		idx=$((idx + 1))
	done <<<"$repo_entries"

	# Wait for all parallel fetches
	for pid in "${pids[@]}"; do
		wait "$pid" 2>/dev/null || true
	done

	# Assemble state file in repo order
	{
		echo "# Pre-fetched Repo State ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
		echo ""
		echo "This state was fetched by pulse-wrapper.sh BEFORE the pulse started."
		echo "Do NOT re-fetch — act on this data directly. See pulse.md Step 2."
		echo ""
		local i=0
		while [[ -f "${tmpdir}/${i}.txt" ]]; do
			cat "${tmpdir}/${i}.txt"
			i=$((i + 1))
		done
	} >"$STATE_FILE"

	# Clean up
	rm -rf "$tmpdir"

	# Append mission state
	prefetch_missions "$repo_entries" >>"$STATE_FILE"

	# Append active worker snapshot for orphaned PR detection (t216)
	prefetch_active_workers >>"$STATE_FILE"

	# Append repo hygiene data for LLM triage (t1417)
	prefetch_hygiene >>"$STATE_FILE"

	# Append priority-class worker allocations (t1423)
	_append_priority_allocations >>"$STATE_FILE"

	# Export PULSE_SCOPE_REPOS — comma-separated list of repo slugs that
	# workers are allowed to create PRs/branches on (t1405, GH#2928).
	# Workers CAN file issues on any repo (cross-repo self-improvement),
	# but code changes (branches, PRs) are restricted to this list.
	local scope_slugs
	scope_slugs=$(echo "$repo_entries" | cut -d'|' -f1 | grep . | paste -sd ',' -)
	export PULSE_SCOPE_REPOS="$scope_slugs"
	echo "[pulse-wrapper] PULSE_SCOPE_REPOS=${scope_slugs}" >>"$LOGFILE"

	local repo_count
	repo_count=$(echo "$repo_entries" | wc -l | tr -d ' ')
	echo "[pulse-wrapper] Pre-fetched state for $repo_count repos → $STATE_FILE" >>"$LOGFILE"
	return 0
}

#######################################
# Pre-fetch active mission state files
#
# Scans todo/missions/ and ~/.aidevops/missions/ for mission.md files
# with status: active|paused|blocked|validating. Extracts a compact
# summary (id, status, current milestone, pending features) so the
# pulse agent can act on missions without reading full state files.
#
# Arguments:
#   $1 - repo_entries (slug|path pairs, one per line)
# Output: mission summary to stdout (appended to STATE_FILE by caller)
#######################################
prefetch_missions() {
	local repo_entries="$1"
	local found_any=false

	# Collect mission files from repo-attached locations
	local mission_files=()
	while IFS='|' read -r slug path; do
		local missions_dir="${path}/todo/missions"
		if [[ -d "$missions_dir" ]]; then
			while IFS= read -r mfile; do
				[[ -n "$mfile" ]] && mission_files+=("${slug}|${path}|${mfile}")
			done < <(find "$missions_dir" -name "mission.md" -type f 2>/dev/null || true)
		fi
	done <<<"$repo_entries"

	# Also check homeless missions
	local homeless_dir="${HOME}/.aidevops/missions"
	if [[ -d "$homeless_dir" ]]; then
		while IFS= read -r mfile; do
			[[ -n "$mfile" ]] && mission_files+=("|homeless|${mfile}")
		done < <(find "$homeless_dir" -name "mission.md" -type f 2>/dev/null || true)
	fi

	if [[ ${#mission_files[@]} -eq 0 ]]; then
		return 0
	fi

	local active_count=0

	for entry in "${mission_files[@]}"; do
		local slug path mfile
		IFS='|' read -r slug path mfile <<<"$entry"

		# Extract frontmatter status — look for status: in YAML frontmatter
		local status
		status=$(_extract_frontmatter_field "$mfile" "status")

		# Only include active/paused/blocked/validating missions
		case "$status" in
		active | paused | blocked | validating) ;;
		*) continue ;;
		esac

		if [[ "$found_any" == false ]]; then
			echo ""
			echo "# Active Missions"
			echo ""
			echo "Mission state files detected by pulse-wrapper.sh. See pulse.md Step 3.5."
			echo ""
			found_any=true
		fi

		local mission_id
		mission_id=$(_extract_frontmatter_field "$mfile" "id")
		local title
		title=$(_extract_frontmatter_field "$mfile" "title")
		local mode
		mode=$(_extract_frontmatter_field "$mfile" "mode")
		local mission_dir
		mission_dir=$(dirname "$mfile")

		echo "## Mission: ${mission_id} — ${title}"
		echo ""
		echo "- **Status:** ${status}"
		echo "- **Mode:** ${mode}"
		echo "- **Repo:** ${slug:-homeless}"
		echo "- **Path:** ${mfile}"
		echo ""

		# Extract milestone summaries — find lines matching "### Milestone N:"
		# and their status lines
		_extract_milestone_summary "$mfile"

		echo ""
		active_count=$((active_count + 1))
	done

	if [[ "$active_count" -gt 0 ]]; then
		echo "[pulse-wrapper] Found $active_count active mission(s)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Extract a field value from YAML frontmatter
# Arguments:
#   $1 - file path
#   $2 - field name
# Output: field value to stdout (trimmed, comments stripped)
#######################################
_extract_frontmatter_field() {
	local file="$1"
	local field="$2"

	# Read frontmatter (between first --- and second ---)
	local in_frontmatter=false
	local value=""
	while IFS= read -r line; do
		if [[ "$line" == "---" ]]; then
			if [[ "$in_frontmatter" == true ]]; then
				break
			fi
			in_frontmatter=true
			continue
		fi
		if [[ "$in_frontmatter" == true ]]; then
			# Match field: value (strip inline comments and quotes)
			if [[ "$line" =~ ^${field}:[[:space:]]*(.*) ]]; then
				value="${BASH_REMATCH[1]}"
				# Strip inline comments (# ...)
				value="${value%%#*}"
				# Trim whitespace
				value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
				# Strip surrounding quotes
				value="${value#\"}"
				value="${value%\"}"
				break
			fi
		fi
	done <"$file"

	echo "$value"
	return 0
}

#######################################
# Extract milestone summary from a mission state file
# Outputs a compact table of milestones and their feature statuses
# Arguments:
#   $1 - mission.md file path
# Output: milestone summary to stdout
#######################################
_extract_milestone_summary() {
	local file="$1"
	local current_milestone=""
	local milestone_status=""

	while IFS= read -r line; do
		# Detect milestone headers: ### Milestone N: Name
		if [[ "$line" =~ ^###[[:space:]]+Milestone[[:space:]]+([0-9]+):[[:space:]]+(.*) ]]; then
			current_milestone="${BASH_REMATCH[1]}: ${BASH_REMATCH[2]}"
		fi

		# Detect milestone status: **Status:** value
		if [[ -n "$current_milestone" && "$line" =~ \*\*Status:\*\*[[:space:]]*(.*) ]]; then
			milestone_status="${BASH_REMATCH[1]}"
			# Strip HTML comments
			milestone_status="${milestone_status%%<!--*}"
			milestone_status=$(echo "$milestone_status" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
			echo "- **Milestone ${current_milestone}** — ${milestone_status}"
			current_milestone=""
		fi

		# Detect feature rows in tables: | N.N | Feature | tNNN | status | ...
		if [[ "$line" =~ ^\|[[:space:]]*([0-9]+\.[0-9]+)[[:space:]]*\|[[:space:]]*(.*)\|[[:space:]]*(t[0-9.]+)[[:space:]]*\|[[:space:]]*([a-z]+)[[:space:]]*\| ]]; then
			local feat_num="${BASH_REMATCH[1]}"
			local feat_name="${BASH_REMATCH[2]}"
			local task_id="${BASH_REMATCH[3]}"
			local feat_status="${BASH_REMATCH[4]}"
			# Trim feature name
			feat_name=$(echo "$feat_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
			echo "  - F${feat_num}: ${feat_name} (${task_id}) — ${feat_status}"
		fi
	done <"$file"
	return 0
}

# _compute_struggle_ratio provided by worker-lifecycle-common.sh

#######################################
# Check and flag external-contributor PRs (t1391)
#
# Deterministic idempotency guard for the external-contributor comment.
# Moved from pulse.md inline bash to a shell function because the LLM
# kept getting the fail-closed logic wrong (4 prior fix attempts:
# PRs #2794, #2796, #2801, #2803 — all in pulse.md prompt text).
#
# This is exactly the kind of logic that belongs in the harness, not
# the prompt: it has one correct answer regardless of context.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#   $3 - PR author login
#
# Exit codes:
#   0 - already flagged (label or comment exists) — no action needed
#   1 - not yet flagged AND API calls succeeded — caller should post
#   2 - API error (fail closed) — caller must skip, next pulse retries
#
# Side effects when exit=1 (caller invokes with --post):
#   Posts the external-contributor comment and adds the label.
#######################################
check_external_contributor_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="$3"
	local do_post="${4:-}"

	# Validate arguments
	if [[ -z "$pr_number" || -z "$repo_slug" || -z "$pr_author" ]]; then
		echo "[pulse-wrapper] check_external_contributor_pr: missing arguments" >>"$LOGFILE"
		return 2
	fi

	# Step 1: Check for existing label (capture exit code separately from output)
	local label_output
	label_output=$(gh pr view "$pr_number" --repo "$repo_slug" --json labels --jq '.labels[].name')
	local label_exit=$?

	local has_label=false
	if [[ $label_exit -eq 0 ]] && echo "$label_output" | grep -q '^external-contributor$'; then
		has_label=true
	fi

	# Step 2: Check for existing comment
	local comment_output
	comment_output=$(gh pr view "$pr_number" --repo "$repo_slug" --json comments --jq '.comments[].body')
	local comment_exit=$?

	local has_comment=false
	if [[ $comment_exit -eq 0 ]] && echo "$comment_output" | grep -qiF 'external contributor'; then
		has_comment=true
	fi

	# Step 3: Decide action based on results
	if [[ $label_exit -ne 0 || $comment_exit -ne 0 ]]; then
		# API error on label or comment check — fail closed, skip posting entirely.
		# The next pulse cycle will retry. Never post when we can't confirm absence.
		echo "[pulse-wrapper] check_external_contributor_pr: API error (label_exit=$label_exit, comment_exit=$comment_exit) for PR #$pr_number in $repo_slug — skipping (fail closed)" >>"$LOGFILE"
		return 2
	fi

	if [[ "$has_label" == "true" || "$has_comment" == "true" ]]; then
		# Already flagged. Re-add label if missing (comment exists but label doesn't).
		if [[ "$has_label" == "false" ]]; then
			gh api --silent "repos/${repo_slug}/issues/${pr_number}/labels" \
				-X POST -f 'labels[]=external-contributor' || true
		fi
		return 0
	fi

	# Both API calls succeeded AND neither label nor comment exists.
	if [[ "$do_post" == "--post" ]]; then
		# Safe to post — this is the only code path that creates a comment.
		gh pr comment "$pr_number" --repo "$repo_slug" \
			--body "This PR is from an external contributor (@${pr_author}). Auto-merge is disabled for external PRs — a maintainer must review and approve manually.

---
**To approve or decline**, comment on this PR:
- \`approved\` — removes the review gate and allows merge (CI permitting)
- \`declined: <reason>\` — closes this PR (include your reason after the colon)" &&
			gh api --silent "repos/${repo_slug}/issues/${pr_number}/labels" \
				-X POST -f 'labels[]=external-contributor' \
				-f 'labels[]=needs-maintainer-review' || true
		echo "[pulse-wrapper] check_external_contributor_pr: flagged PR #$pr_number in $repo_slug as external contributor (@$pr_author)" >>"$LOGFILE"
	fi
	return 1
}

#######################################
# Check and post permission-failure comment on a PR (t1391)
#
# Companion to check_external_contributor_pr() for the case where the
# collaborator permission API itself fails (403, 429, 5xx, network error).
# Posts a distinct "Permission check failed" comment so a maintainer
# knows to review manually. Idempotent — checks for existing comment
# before posting, fails closed on API errors.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#   $3 - PR author login
#   $4 - HTTP status code from the failed permission check
#
# Exit codes:
#   0 - comment already exists or was just posted
#   2 - API error checking for existing comment (fail closed, skip)
#######################################
check_permission_failure_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="$3"
	local http_status="${4:-unknown}"

	if [[ -z "$pr_number" || -z "$repo_slug" || -z "$pr_author" ]]; then
		echo "[pulse-wrapper] check_permission_failure_pr: missing arguments" >>"$LOGFILE"
		return 2
	fi

	# Check for existing permission-failure comment (fail closed on API error)
	local perm_comments
	perm_comments=$(gh pr view "$pr_number" --repo "$repo_slug" --json comments --jq '.comments[].body' 2>/dev/null)
	local perm_exit=$?

	if [[ $perm_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_permission_failure_pr: API error (exit=$perm_exit) for PR #$pr_number in $repo_slug — skipping (fail closed)" >>"$LOGFILE"
		return 2
	fi

	if echo "$perm_comments" | grep -qF 'Permission check failed'; then
		# Already posted — nothing to do
		return 0
	fi

	# Safe to post — no existing comment and API call succeeded
	gh pr comment "$pr_number" --repo "$repo_slug" \
		--body "Permission check failed for this PR (HTTP ${http_status} from collaborator permission API). Unable to determine if @${pr_author} is a maintainer or external contributor. **A maintainer must review and merge this PR manually.** This is a fail-closed safety measure — the pulse will not auto-merge until the permission API succeeds." \
		2>/dev/null || true

	echo "[pulse-wrapper] check_permission_failure_pr: posted permission-failure comment on PR #$pr_number in $repo_slug (HTTP $http_status)" >>"$LOGFILE"
	return 0
}

#######################################
# Check if a PR modifies GitHub Actions workflow files (t3934)
#
# PRs that modify .github/workflows/ files require the `workflow` scope
# on the GitHub OAuth token. Without it, `gh pr merge` fails with:
#   "refusing to allow an OAuth App to create or update workflow ... without workflow scope"
#
# This function checks the PR's changed files for workflow modifications
# so the pulse can skip auto-merge and post a helpful comment instead of
# failing with a cryptic GraphQL error.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#
# Exit codes:
#   0 - PR modifies workflow files
#   1 - PR does NOT modify workflow files
#   2 - API error (fail open — let merge attempt proceed)
#######################################
check_pr_modifies_workflows() {
	local pr_number="$1"
	local repo_slug="$2"

	if [[ -z "$pr_number" || -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] check_pr_modifies_workflows: missing arguments" >>"$LOGFILE"
		return 2
	fi

	local files_output
	files_output=$(gh pr view "$pr_number" --repo "$repo_slug" --json files --jq '.files[].path')
	local files_exit=$?

	if [[ $files_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_pr_modifies_workflows: API error (exit=$files_exit) for PR #$pr_number in $repo_slug — failing open" >>"$LOGFILE"
		return 2
	fi

	if echo "$files_output" | grep -qE '^\.github/workflows/'; then
		echo "[pulse-wrapper] check_pr_modifies_workflows: PR #$pr_number in $repo_slug modifies workflow files" >>"$LOGFILE"
		return 0
	fi

	return 1
}

#######################################
# Check if the current GitHub token has the `workflow` scope (t3934)
#
# The `workflow` scope is required to merge PRs that modify
# .github/workflows/ files. This function checks the current
# token's scopes via `gh auth status`.
#
# Exit codes:
#   0 - token HAS workflow scope
#   1 - token does NOT have workflow scope
#   2 - unable to determine (fail open)
#######################################
check_gh_workflow_scope() {
	local auth_output
	auth_output=$(gh auth status 2>&1)
	local auth_exit=$?

	if [[ $auth_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_gh_workflow_scope: gh auth status failed (exit=$auth_exit) — failing open" >>"$LOGFILE"
		return 2
	fi

	if echo "$auth_output" | grep -q "'workflow'"; then
		return 0
	fi

	# Also check for the scope without quotes (format varies by gh version)
	if echo "$auth_output" | grep -qiE 'Token scopes:.*workflow'; then
		return 0
	fi

	echo "[pulse-wrapper] check_gh_workflow_scope: token lacks workflow scope" >>"$LOGFILE"
	return 1
}

#######################################
# Guard merge of PRs that modify workflow files (t3934)
#
# Combines check_pr_modifies_workflows() and check_gh_workflow_scope()
# into a single pre-merge guard. If the PR modifies workflow files and
# the token lacks the workflow scope, posts a comment explaining the
# issue and how to fix it. Idempotent — checks for existing comment.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#
# Exit codes:
#   0 - safe to merge (no workflow files, or token has scope)
#   1 - blocked (workflow files + missing scope, comment posted)
#   2 - API error (fail open — let merge attempt proceed)
#######################################
check_workflow_merge_guard() {
	local pr_number="$1"
	local repo_slug="$2"

	if [[ -z "$pr_number" || -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] check_workflow_merge_guard: missing arguments" >>"$LOGFILE"
		return 2
	fi

	# Step 1: Check if PR modifies workflow files
	check_pr_modifies_workflows "$pr_number" "$repo_slug"
	local wf_exit=$?

	if [[ $wf_exit -eq 1 ]]; then
		# No workflow files modified — safe to merge
		return 0
	fi

	if [[ $wf_exit -eq 2 ]]; then
		# API error — fail open, let merge attempt proceed
		return 2
	fi

	# Step 2: PR modifies workflow files — check token scope
	check_gh_workflow_scope
	local scope_exit=$?

	if [[ $scope_exit -eq 0 ]]; then
		# Token has workflow scope — safe to merge
		return 0
	fi

	if [[ $scope_exit -eq 2 ]]; then
		# Unable to determine — fail open
		return 2
	fi

	# Step 3: PR modifies workflows AND token lacks scope — check for existing comment
	local comments_output
	comments_output=$(gh pr view "$pr_number" --repo "$repo_slug" --json comments --jq '.comments[].body')
	local comments_exit=$?

	if [[ $comments_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_workflow_merge_guard: API error reading comments for PR #$pr_number — failing open" >>"$LOGFILE"
		return 2
	fi

	if echo "$comments_output" | grep -qF 'workflow scope'; then
		# Already commented — still blocked
		echo "[pulse-wrapper] check_workflow_merge_guard: PR #$pr_number already has workflow scope comment — skipping merge" >>"$LOGFILE"
		return 1
	fi

	# Post comment explaining the issue
	gh pr comment "$pr_number" --repo "$repo_slug" \
		--body "**Cannot auto-merge: workflow scope required** (GH#3934)

This PR modifies \`.github/workflows/\` files but the GitHub OAuth token used by the pulse lacks the \`workflow\` scope. GitHub requires this scope to merge PRs that modify workflow files.

**To fix:**
1. Run \`gh auth refresh -s workflow\` to add the \`workflow\` scope to your token
2. The next pulse cycle will merge this PR automatically

**Alternatively:** Merge manually via the GitHub UI." ||
		true

	# Add a label for visibility
	gh api --silent "repos/${repo_slug}/issues/${pr_number}/labels" \
		-X POST -f 'labels[]=needs-workflow-scope' || true

	echo "[pulse-wrapper] check_workflow_merge_guard: blocked PR #$pr_number in $repo_slug — workflow files + missing scope" >>"$LOGFILE"
	return 1
}

#######################################
# Pre-fetch active worker processes (t216, t1367)
#
# Captures a snapshot of running worker processes so the pulse agent
# can cross-reference open PRs with active workers. This is the
# deterministic data-fetch part — the intelligence about which PRs
# are orphaned stays in pulse.md.
#
# t1367: Also computes struggle_ratio for each worker with a worktree.
# High ratio = active but unproductive (thrashing). Informational only.
#
# Output: worker summary to stdout (appended to STATE_FILE by caller)
#######################################
prefetch_active_workers() {
	local worker_lines
	worker_lines=$(ps axo pid,etime,command | grep '/full-loop' | grep '[.]opencode' || true)

	echo ""
	echo "# Active Workers"
	echo ""
	echo "Snapshot of running worker processes at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
	echo "Use this to determine whether a PR has an active worker (not orphaned)."
	echo "Struggle ratio: messages/max(1,commits) — high ratio + time = thrashing. See pulse.md."
	echo ""

	if [[ -z "$worker_lines" ]]; then
		echo "- No active workers"
	else
		local count
		count=$(echo "$worker_lines" | wc -l | tr -d ' ')
		echo "### Running Workers ($count)"
		echo ""
		echo "$worker_lines" | while IFS= read -r line; do
			local pid etime cmd
			read -r pid etime cmd <<<"$line"

			# Compute elapsed seconds for struggle ratio
			local elapsed_seconds
			elapsed_seconds=$(_get_process_age "$pid")

			# Compute struggle ratio (t1367)
			local sr_result
			sr_result=$(_compute_struggle_ratio "$pid" "$elapsed_seconds" "$cmd")
			local sr_ratio sr_commits sr_messages sr_flag
			IFS='|' read -r sr_ratio sr_commits sr_messages sr_flag <<<"$sr_result"

			local sr_display=""
			if [[ "$sr_ratio" != "n/a" ]]; then
				sr_display=" [struggle_ratio: ${sr_ratio} (${sr_messages}msgs/${sr_commits}commits)"
				if [[ -n "$sr_flag" ]]; then
					sr_display="${sr_display} **${sr_flag}**"
				fi
				sr_display="${sr_display}]"
			fi

			echo "- PID $pid (uptime: $etime): $cmd${sr_display}"
		done
	fi

	echo ""
	return 0
}

#######################################
# Append priority-class worker allocations to state file (t1423)
#
# Reads the allocation file written by calculate_priority_allocations()
# and formats it as a section the pulse agent can act on.
#
# The pulse agent uses this to enforce soft reservations: product repos
# get a guaranteed minimum share of worker slots, tooling gets the rest.
# When one class has no pending work, the other can use freed slots.
#
# Output: allocation summary to stdout (appended to STATE_FILE by caller)
#######################################
_append_priority_allocations() {
	local alloc_file="${HOME}/.aidevops/logs/pulse-priority-allocations"

	echo ""
	echo "# Priority-Class Worker Allocations (t1423)"
	echo ""

	if [[ ! -f "$alloc_file" ]]; then
		echo "- Allocation data not available — using flat pool (no reservations)"
		echo ""
		return 0
	fi

	# Read allocation values
	local max_workers product_repos tooling_repos product_min tooling_max reservation_pct
	max_workers=$(grep '^MAX_WORKERS=' "$alloc_file" | cut -d= -f2) || max_workers=4
	product_repos=$(grep '^PRODUCT_REPOS=' "$alloc_file" | cut -d= -f2) || product_repos=0
	tooling_repos=$(grep '^TOOLING_REPOS=' "$alloc_file" | cut -d= -f2) || tooling_repos=0
	product_min=$(grep '^PRODUCT_MIN=' "$alloc_file" | cut -d= -f2) || product_min=0
	tooling_max=$(grep '^TOOLING_MAX=' "$alloc_file" | cut -d= -f2) || tooling_max=0
	reservation_pct=$(grep '^PRODUCT_RESERVATION_PCT=' "$alloc_file" | cut -d= -f2) || reservation_pct=60

	echo "Worker pool: **${max_workers}** total slots"
	echo "Product repos (${product_repos}): **${product_min}** reserved slots (${reservation_pct}% minimum)"
	echo "Tooling repos (${tooling_repos}): **${tooling_max}** slots (remainder)"
	echo ""
	echo "**Enforcement rules:**"
	echo "- Before dispatching a tooling-repo worker, check: are product-repo workers using fewer than ${product_min} slots? If yes, the remaining product slots are reserved — do NOT fill them with tooling work."
	echo "- If product repos have no pending work (no open issues, no failing PRs), their reserved slots become available for tooling."
	echo "- If all ${max_workers} slots are needed for product work, tooling gets 0 (product reservation is a minimum, not a maximum)."
	echo "- Merges (priority 1) and CI fixes (priority 2) are exempt — they always proceed regardless of class."
	echo ""

	return 0
}

#######################################
# Pre-fetch repo hygiene data for LLM triage (t1417)
#
# Appends a "Repo Hygiene" section to the state file with:
#   1. Orphan worktrees — branches with 0 commits ahead of main,
#      no PR (open or merged), and no active worker process.
#   2. Stash summary — count of needs-review stashes per repo.
#   3. Uncommitted changes on main — repos with dirty main worktree.
#
# This data enables the pulse LLM to make intelligent triage decisions
# about cleanup. Deterministic cleanup (merged-PR worktrees, safe stashes)
# is handled by cleanup_worktrees() and cleanup_stashes() before this runs.
# What remains here requires judgment.
#
# Output: hygiene summary to stdout (appended to STATE_FILE by caller)
#######################################
prefetch_hygiene() {
	local repos_json="${HOME}/.config/aidevops/repos.json"

	echo ""
	echo "# Repo Hygiene"
	echo ""
	echo "Non-deterministic cleanup candidates requiring LLM assessment."
	echo "Merged-PR worktrees and safe-to-drop stashes were already cleaned by the shell layer."
	echo ""

	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "- repos.json not available — skipping hygiene prefetch"
		echo ""
		return 0
	fi

	local repo_paths
	repo_paths=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path' "$repos_json" || echo "")

	local found_any=false

	local repo_path
	while IFS= read -r repo_path; do
		[[ -z "$repo_path" ]] && continue
		[[ ! -d "$repo_path/.git" ]] && continue

		local repo_name
		repo_name=$(basename "$repo_path")
		local repo_issues=""

		# 1. Orphan worktrees: 0 commits ahead of default branch, no PR
		local default_branch
		default_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || default_branch="main"
		[[ -z "$default_branch" ]] && default_branch="main"

		local wt_branch wt_path
		while IFS= read -r line; do
			if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
				wt_path="${BASH_REMATCH[1]}"
			elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
				wt_branch="${BASH_REMATCH[1]}"
			elif [[ -z "$line" && -n "$wt_branch" ]]; then
				# Skip the default branch
				if [[ "$wt_branch" != "$default_branch" ]]; then
					local commits_ahead
					commits_ahead=$(git -C "$repo_path" rev-list --count "${default_branch}..${wt_branch}" 2>/dev/null) || commits_ahead="?"

					if [[ "$commits_ahead" == "0" ]]; then
						# Check if any PR exists (open or merged)
						local has_pr="false"
						if command -v gh &>/dev/null; then
							local pr_check
							pr_check=$(gh pr list --repo "$(jq -r --arg p "$repo_path" '.initialized_repos[] | select(.path == $p) | .slug' "$repos_json" 2>/dev/null)" \
								--head "$wt_branch" --state all --json number --jq 'length' 2>/dev/null) || pr_check="0"
							[[ "${pr_check:-0}" -gt 0 ]] && has_pr="true"
						fi

						if [[ "$has_pr" == "false" ]]; then
							# Check for dirty state
							local dirty=""
							local change_count
							change_count=$(git -C "${wt_path:-$repo_path}" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || change_count=0
							[[ "${change_count:-0}" -gt 0 ]] && dirty=" (${change_count} uncommitted files)"

							repo_issues="${repo_issues}  - Orphan worktree: \`${wt_branch}\` — 0 commits, no PR${dirty} (${wt_path})\n"
						fi
					fi
				fi
				wt_path=""
				wt_branch=""
			fi
		done < <(
			git -C "$repo_path" worktree list --porcelain 2>/dev/null
			echo ""
		)

		# 2. Stash summary (needs-review count)
		local stash_count
		stash_count=$(git -C "$repo_path" stash list 2>/dev/null | wc -l | tr -d ' ')
		if [[ "${stash_count:-0}" -gt 0 ]]; then
			repo_issues="${repo_issues}  - ${stash_count} stash(es) remaining (safe-to-drop already cleaned; these need review)\n"
		fi

		# 3. Uncommitted changes on main worktree
		local main_wt_path="$repo_path"
		local current_branch
		current_branch=$(git -C "$main_wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null) || current_branch=""
		if [[ "$current_branch" == "$default_branch" ]]; then
			local main_dirty
			main_dirty=$(git -C "$main_wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || main_dirty=0
			if [[ "${main_dirty:-0}" -gt 0 ]]; then
				repo_issues="${repo_issues}  - ${main_dirty} uncommitted file(s) on ${default_branch} branch\n"
			fi
		fi

		# Output repo section if any issues found
		if [[ -n "$repo_issues" ]]; then
			found_any=true
			echo "### ${repo_name}"
			echo -e "$repo_issues"
		fi
	done <<<"$repo_paths"

	if [[ "$found_any" == "false" ]]; then
		echo "- All repos clean — no hygiene issues detected"
		echo ""
	fi

	# PR salvage scan: detect closed-unmerged PRs with recoverable code
	local salvage_helper="${SCRIPT_DIR}/pr-salvage-helper.sh"
	if [[ -x "$salvage_helper" ]]; then
		echo ""
		echo "# PR Salvage (closed-unmerged with recoverable code)"
		echo ""

		local salvage_found=false
		local slug path
		while IFS='|' read -r slug path; do
			[[ -z "$slug" ]] && continue
			local salvage_output
			salvage_output=$("$salvage_helper" prefetch "$slug" "$path" 2>/dev/null) || true
			if [[ -n "$salvage_output" ]]; then
				salvage_found=true
				echo "$salvage_output"
			fi
		done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null)

		if [[ "$salvage_found" == "false" ]]; then
			echo "- No salvageable closed-unmerged PRs detected"
			echo ""
		fi
	fi

	return 0
}

#######################################
# Process guard: kill child processes exceeding RSS or runtime limits (t1398)
#
# Scans all child processes of the current pulse (and their descendants)
# for resource violations. ShellCheck processes get stricter limits due
# to their known exponential expansion risk (see t1398.2).
#
# This is a secondary defense — the primary defense is the hardened
# ShellCheck invocation (no -x, --norc, per-file timeout, ulimit -v).
# This guard catches any ShellCheck process that escapes those limits.
#
# Called from the watchdog loop inside run_pulse() every 60s.
#
# Arguments:
#   $1 - (optional) PID of the primary pulse process to exempt from
#        CHILD_RUNTIME_LIMIT (governed by PULSE_STALE_THRESHOLD instead)
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
guard_child_processes() {
	local pulse_pid="${1:-}"
	local killed=0
	local total_freed_mb=0

	# Get all descendant PIDs of the current shell process.
	# Use 'command' (full command line) instead of 'comm' (basename only)
	# so that patterns like 'node.*opencode' can match. (CodeRabbit review)
	local descendants
	descendants=$(ps -eo pid,ppid,rss,etime,command | awk -v parent=$$ '
		BEGIN { pids[parent]=1 }
		{ if ($2 in pids) { pids[$1]=1; print $0 } }
	') || return 0

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue

		# Fields from ps -eo pid,ppid,rss,etime,command
		# command is last and may contain spaces — read captures the rest
		local pid _ppid rss etime cmd_full
		read -r pid _ppid rss etime cmd_full <<<"$line"

		# Validate numeric fields
		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0

		local age_seconds
		age_seconds=$(_get_process_age "$pid")

		# Extract basename for limit selection (e.g., /usr/bin/shellcheck → shellcheck)
		local cmd_base="${cmd_full%% *}"
		cmd_base="${cmd_base##*/}"

		# Determine limits: ShellCheck gets stricter limits
		local rss_limit="$CHILD_RSS_LIMIT_KB"
		local runtime_limit="$CHILD_RUNTIME_LIMIT"
		if [[ "$cmd_base" == "shellcheck" ]]; then
			rss_limit="$SHELLCHECK_RSS_LIMIT_KB"
			runtime_limit="$SHELLCHECK_RUNTIME_LIMIT"
		fi

		local violation=""
		if [[ "$rss" -gt "$rss_limit" ]]; then
			local rss_mb=$((rss / 1024))
			local limit_mb=$((rss_limit / 1024))
			violation="RSS ${rss_mb}MB > ${limit_mb}MB limit"
		elif [[ -n "$pulse_pid" && "$pid" == "$pulse_pid" ]]; then
			# Primary pulse process — runtime governed by PULSE_STALE_THRESHOLD,
			# not CHILD_RUNTIME_LIMIT. Skip runtime check but keep RSS check.
			:
		elif [[ "$age_seconds" -gt "$runtime_limit" ]]; then
			violation="runtime ${age_seconds}s > ${runtime_limit}s limit"
		fi

		if [[ -n "$violation" ]]; then
			local rss_mb=$((rss / 1024))
			# Sanitise cmd_base before logging to prevent log injection via
			# crafted process names containing control characters. (GH#2892)
			local safe_cmd_base
			safe_cmd_base=$(_sanitize_log_field "$cmd_base")
			echo "[pulse-wrapper] Process guard: killing PID $pid ($safe_cmd_base) — $violation" >>"$LOGFILE"
			_kill_tree "$pid" || true
			sleep 1
			if kill -0 "$pid" 2>/dev/null; then
				_force_kill_tree "$pid" || true
			fi
			killed=$((killed + 1))
			total_freed_mb=$((total_freed_mb + rss_mb))
		fi
	done <<<"$descendants"

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] Process guard: killed $killed process(es), freed ~${total_freed_mb}MB" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Check concurrent session count and warn (t1398)
#
# Counts running opencode/claude interactive sessions (those with a TTY).
# If count exceeds SESSION_COUNT_WARN, logs a warning. This is informational
# — the pulse doesn't kill user sessions, but the health issue will show it.
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
		echo "[pulse-wrapper] Session warning: $interactive_count interactive sessions open (threshold: $SESSION_COUNT_WARN). Each consumes 100-440MB + language servers. Consider closing unused tabs." >>"$LOGFILE"
	fi

	echo "$interactive_count"
	return 0
}

#######################################
# Run the pulse — with internal watchdog timeout (t1397, t1398, t1398.3, GH#2958)
#
# The pulse runs until opencode exits naturally. A watchdog loop checks
# every 60s for three termination conditions:
#
#   1. Wall-clock timeout (t1397): kills if elapsed > PULSE_STALE_THRESHOLD.
#      This is the hard ceiling — no pulse should ever run longer than this.
#      Raised to 60 min (from 30 min) because quality sweeps across 8+ repos
#      legitimately need more time (GH#2958).
#
#   2. Idle detection (t1398.3): tracks consecutive seconds where the
#      process tree's CPU usage is below PULSE_IDLE_CPU_THRESHOLD. When
#      idle time exceeds PULSE_IDLE_TIMEOUT, the process is killed. This
#      catches the opencode idle-state bug much faster than the wall-clock
#      timeout — typically within 5 minutes of the pulse completing, vs
#      60 minutes for the stale threshold.
#
#   3. Progress detection (GH#2958): tracks whether the log file is growing.
#      If the log file size hasn't changed for PULSE_PROGRESS_TIMEOUT seconds,
#      the process is stuck — producing no output despite running. This catches
#      cases where CPU is nonzero (network I/O wait, spinning) but no actual
#      work is being done. Resets whenever new output appears.
#
# The watchdog also runs guard_child_processes() every 60s to kill any
# child process exceeding RSS or runtime limits (t1398).
#
# Previous design relied on the NEXT launchd invocation's check_dedup()
# to kill stale processes. This failed because launchd StartInterval only
# fires when the previous invocation has exited — and the wrapper blocks
# on `wait`, so the next invocation never starts. The watchdog is now
# internal to the same process that spawned opencode.
#######################################
run_pulse() {
	local start_epoch
	start_epoch=$(date +%s)
	echo "[pulse-wrapper] Starting pulse at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$LOGFILE"

	# Build the prompt: /pulse + pre-fetched state
	local prompt="/pulse"
	if [[ -f "$STATE_FILE" ]]; then
		local state_content
		state_content=$(cat "$STATE_FILE")
		prompt="/pulse

--- PRE-FETCHED STATE (from pulse-wrapper.sh) ---
${state_content}
--- END PRE-FETCHED STATE ---"
	fi

	# Run opencode in background
	"$OPENCODE_BIN" run "$prompt" \
		--dir "$PULSE_DIR" \
		-m "$PULSE_MODEL" \
		--title "Supervisor Pulse" \
		>>"$LOGFILE" 2>&1 &

	local opencode_pid=$!
	echo "$opencode_pid" >"$PIDFILE"

	echo "[pulse-wrapper] opencode PID: $opencode_pid" >>"$LOGFILE"

	# Idle detection state (t1398.3)
	# Tracks how long the process tree has been continuously idle (CPU < threshold).
	# Reset to 0 whenever CPU activity is detected. The poll interval (60s) is the
	# granularity — idle_seconds increments by 60 each idle poll.
	local idle_seconds=0

	# Progress detection state (GH#2958)
	# Tracks log file size to detect stalled processes. If the log hasn't grown
	# for PULSE_PROGRESS_TIMEOUT seconds, the process is stuck (running but not
	# producing output). This catches "busy but unproductive" states that idle
	# detection misses (e.g., network I/O wait, API rate limiting loops).
	local last_log_size=0
	local progress_stall_seconds=0
	if [[ -f "$LOGFILE" ]]; then
		last_log_size=$(wc -c <"$LOGFILE" 2>/dev/null || echo "0")
		# Strip whitespace from wc output (macOS wc pads with spaces)
		last_log_size="${last_log_size// /}"
	fi

	# Watchdog loop: check every 60s for stale threshold, idle timeout,
	# progress stall, or runaway children (t1397, t1398, t1398.3, GH#2958).
	# This replaces the bare `wait` that blocked the wrapper indefinitely
	# when opencode hung.
	#
	# Kill logic is deduplicated: all checks set kill_reason, and a single
	# block at the end performs the kill + force-kill sequence. kill commands
	# are guarded with || true to prevent set -e from aborting cleanup if
	# the target process has already exited.
	while ps -p "$opencode_pid" >/dev/null; do
		local now
		now=$(date +%s)
		local elapsed=$((now - start_epoch))

		local kill_reason=""
		# Check 0: Stop flag — user ran `aidevops pulse stop` during this cycle (t2943)
		if [[ -f "$STOP_FLAG" ]]; then
			kill_reason="Stop flag detected during active pulse — user requested stop"
		# Check 1: Wall-clock stale threshold (hard ceiling)
		elif [[ "$elapsed" -gt "$PULSE_STALE_THRESHOLD" ]]; then
			kill_reason="Pulse exceeded stale threshold (${elapsed}s > ${PULSE_STALE_THRESHOLD}s)"
		# Skip checks 2 and 3 during the first 3 minutes to allow startup/init.
		elif [[ "$elapsed" -ge 180 ]]; then
			# Check 2: Idle detection — CPU usage of the process tree (t1398.3)
			local tree_cpu
			tree_cpu=$(_get_process_tree_cpu "$opencode_pid")
			if [[ "$tree_cpu" -lt "$PULSE_IDLE_CPU_THRESHOLD" ]]; then
				idle_seconds=$((idle_seconds + 60))
				if [[ "$idle_seconds" -ge "$PULSE_IDLE_TIMEOUT" ]]; then
					kill_reason="Pulse idle for ${idle_seconds}s (CPU ${tree_cpu}% < ${PULSE_IDLE_CPU_THRESHOLD}%, threshold ${PULSE_IDLE_TIMEOUT}s) (t1398.3)"
				fi
			else
				# Process is active — reset idle counter
				if [[ "$idle_seconds" -gt 0 ]]; then
					echo "[pulse-wrapper] Pulse active again (CPU ${tree_cpu}%) after ${idle_seconds}s idle — resetting idle counter" >>"$LOGFILE"
				fi
				idle_seconds=0
			fi

			# Check 3: Progress detection — is the log file growing? (GH#2958)
			# A process that's running (CPU > 0) but producing no output for
			# PULSE_PROGRESS_TIMEOUT is stuck in a loop (API retries, rate
			# limiting, infinite wait). This is the "busy but unproductive" case.
			if [[ -z "$kill_reason" ]]; then
				local current_log_size=0
				if [[ -f "$LOGFILE" ]]; then
					current_log_size=$(wc -c <"$LOGFILE" 2>/dev/null || echo "0")
					current_log_size="${current_log_size// /}"
				fi
				[[ "$current_log_size" =~ ^[0-9]+$ ]] || current_log_size=0

				if [[ "$current_log_size" -gt "$last_log_size" ]]; then
					# Log grew — process is making progress
					if [[ "$progress_stall_seconds" -gt 0 ]]; then
						echo "[pulse-wrapper] Progress resumed after ${progress_stall_seconds}s stall (log grew by $((current_log_size - last_log_size)) bytes)" >>"$LOGFILE"
					fi
					last_log_size="$current_log_size"
					progress_stall_seconds=0
				else
					# Log hasn't grown — increment stall counter
					progress_stall_seconds=$((progress_stall_seconds + 60))
					if [[ "$progress_stall_seconds" -ge "$PULSE_PROGRESS_TIMEOUT" ]]; then
						kill_reason="Pulse stalled for ${progress_stall_seconds}s — no log output (log size: ${current_log_size} bytes, threshold: ${PULSE_PROGRESS_TIMEOUT}s) (GH#2958)"
					fi
				fi
			fi
		fi

		# Single kill block — avoids duplicating the kill+force-kill sequence.
		# Guard with || true so set -e doesn't abort if the process already exited.
		if [[ -n "$kill_reason" ]]; then
			echo "[pulse-wrapper] ${kill_reason} — killing" >>"$LOGFILE"
			_kill_tree "$opencode_pid" || true
			sleep 2
			if kill -0 "$opencode_pid" 2>/dev/null; then
				_force_kill_tree "$opencode_pid" || true
			fi
			break
		fi

		# Process guard: kill children exceeding RSS/runtime limits (t1398)
		# Pass opencode_pid so the primary pulse process is exempt from
		# CHILD_RUNTIME_LIMIT (it's governed by PULSE_STALE_THRESHOLD above).
		guard_child_processes "$opencode_pid"
		# Sleep 60s then re-check. Portable across bash 3.2+ (macOS default).
		# The process may exit during sleep — ps -p at top of loop catches that.
		sleep 60
	done

	# Reap the process (may already be dead)
	wait "$opencode_pid" 2>/dev/null || true

	# Clean up PID file
	rm -f "$PIDFILE"

	local end_epoch
	end_epoch=$(date +%s)
	local duration=$((end_epoch - start_epoch))
	echo "[pulse-wrapper] Pulse completed at $(date -u +%Y-%m-%dT%H:%M:%SZ) (ran ${duration}s)" >>"$LOGFILE"
	return 0
}

#######################################
# Clean up worktrees for merged/closed PRs across ALL managed repos
#
# Iterates repos.json (.initialized_repos[]) and runs
# worktree-helper.sh clean --auto --force-merged in each repo directory.
# This prevents stale worktrees from accumulating on disk after PR merges
# — including squash merges that git branch --merged cannot detect.
#
# worktree-helper.sh clean internally:
#   1. Runs git fetch --prune origin (prunes deleted remote branches)
#   2. Checks refs/remotes/origin/<branch> for each worktree
#   3. Detects squash merges via gh pr list --state merged
#   4. Removes worktrees + deletes local branches for merged PRs
#
# --force-merged: force-removes dirty worktrees when the PR is confirmed
# merged (dirty state = abandoned WIP from a completed worker).
#
# Safety: skips worktrees owned by active sessions (handled by
# worktree-helper.sh ownership registry, t189).
#######################################
cleanup_worktrees() {
	local helper="${HOME}/.aidevops/agents/scripts/worktree-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	local repos_json="${HOME}/.config/aidevops/repos.json"
	local total_removed=0

	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		# Iterate all initialized repos — clean worktrees for any repo with
		# a git directory, not just pulse-enabled ones. Workers can create
		# worktrees in any managed repo. Skip local_only repos since
		# worktree-helper.sh uses gh pr list for squash-merge detection.
		local repo_paths
		repo_paths=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path' "$repos_json" || echo "")

		local repo_path
		while IFS= read -r repo_path; do
			[[ -z "$repo_path" ]] && continue
			[[ ! -d "$repo_path/.git" ]] && continue

			local wt_count
			wt_count=$(git -C "$repo_path" worktree list | wc -l | tr -d ' ')
			# Skip repos with only 1 worktree (the main one) — nothing to clean
			if [[ "${wt_count:-0}" -le 1 ]]; then
				continue
			fi

			# Run helper in a subshell cd'd to the repo (it uses git rev-parse --show-toplevel)
			local clean_result
			clean_result=$(cd "$repo_path" && bash "$helper" clean --auto --force-merged 2>&1) || true

			local count
			count=$(echo "$clean_result" | grep -c 'Removing') || count=0
			if [[ "$count" -gt 0 ]]; then
				local repo_name
				repo_name=$(basename "$repo_path")
				echo "[pulse-wrapper] Worktree cleanup ($repo_name): $count worktree(s) removed" >>"$LOGFILE"
				total_removed=$((total_removed + count))
			fi
		done <<<"$repo_paths"
	else
		# Fallback: just clean the current repo (legacy behaviour)
		local clean_result
		clean_result=$(bash "$helper" clean --auto --force-merged 2>&1) || true
		local fallback_count
		fallback_count=$(echo "$clean_result" | grep -c 'Removing') || fallback_count=0
		if [[ "$fallback_count" -gt 0 ]]; then
			echo "[pulse-wrapper] Worktree cleanup: $fallback_count worktree(s) removed" >>"$LOGFILE"
			total_removed=$((total_removed + fallback_count))
		fi
	fi

	if [[ "$total_removed" -gt 0 ]]; then
		echo "[pulse-wrapper] Worktree cleanup total: $total_removed worktree(s) removed across all repos" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Clean up safe-to-drop stashes across ALL managed repos (t1417)
#
# Iterates repos.json (.initialized_repos[]) and runs
# stash-audit-helper.sh auto-clean in each repo directory.
# Only drops stashes whose content is already in HEAD — safe
# and deterministic, no judgment needed.
#
# Stashes classified as "needs-review" or "obsolete" are left
# for the LLM hygiene triage (see prefetch_hygiene + pulse.md).
#######################################
cleanup_stashes() {
	local helper="${HOME}/.aidevops/agents/scripts/stash-audit-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	local repos_json="${HOME}/.config/aidevops/repos.json"
	local total_dropped=0

	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local repo_paths
		repo_paths=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path' "$repos_json" || echo "")

		local repo_path
		while IFS= read -r repo_path; do
			[[ -z "$repo_path" ]] && continue
			[[ ! -d "$repo_path/.git" ]] && continue

			# Skip repos with no stashes
			local stash_count
			stash_count=$(git -C "$repo_path" stash list 2>/dev/null | wc -l | tr -d ' ')
			if [[ "${stash_count:-0}" -eq 0 ]]; then
				continue
			fi

			local clean_result
			clean_result=$(cd "$repo_path" && bash "$helper" auto-clean 2>&1) || true

			local count
			count=$(echo "$clean_result" | grep -c 'Dropped') || count=0
			if [[ "$count" -gt 0 ]]; then
				local repo_name
				repo_name=$(basename "$repo_path")
				echo "[pulse-wrapper] Stash cleanup ($repo_name): $count stash(es) dropped" >>"$LOGFILE"
				total_dropped=$((total_dropped + count))
			fi
		done <<<"$repo_paths"
	else
		# Fallback: just clean the current repo
		local clean_result
		clean_result=$(bash "$helper" auto-clean 2>&1) || true
		local fallback_count
		fallback_count=$(echo "$clean_result" | grep -c 'Dropped') || fallback_count=0
		if [[ "$fallback_count" -gt 0 ]]; then
			echo "[pulse-wrapper] Stash cleanup: $fallback_count stash(es) dropped" >>"$LOGFILE"
			total_dropped=$((total_dropped + fallback_count))
		fi
	fi

	if [[ "$total_dropped" -gt 0 ]]; then
		echo "[pulse-wrapper] Stash cleanup total: $total_dropped stash(es) dropped across all repos" >>"$LOGFILE"
	fi

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

		health_issue_number=$(gh issue create --repo "$repo_slug" \
			--title "${runner_prefix} starting..." \
			--body "Live ${runner_role} status for **${runner_user}**. Updated each pulse. Pin this issue for at-a-glance monitoring." \
			--label "$role_label" --label "$runner_user" 2>/dev/null | grep -oE '[0-9]+$' || echo "")

		if [[ -z "$health_issue_number" ]]; then
			echo "[pulse-wrapper] Health issue: could not create for ${repo_slug}" >>"$LOGFILE"
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
		echo "[pulse-wrapper] Health issue: created #${health_issue_number} (${runner_role}) for ${runner_user} in ${repo_slug}" >>"$LOGFILE"
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

### Contributions to this project (last 30 days)

${activity_md}

### Contributions to all projects (last 30 days)

${cross_repo_md:-_Single repo or cross-repo data unavailable._}

### Work with AI sessions on this project (${runner_user})

${session_time_md}

### Work with AI sessions on all projects (${runner_user})

${cross_repo_session_time_md:-_Single repo or cross-repo session data unavailable._}

### Contributor output on this project (last 30 days)

${person_stats_md:-_Person stats unavailable._}

### Contributor output on all projects (last 30 days)

${cross_repo_person_stats_md:-_Cross-repo person stats unavailable._}

### System Resources

| Metric | Value |
| --- | --- |
| CPU | ${sys_load_ratio}% used (${sys_cpu_cores} cores, load: ${sys_load_1m}/${sys_load_5m}) |
| Memory | ${sys_memory} |
| Processes | ${sys_procs} |

---
_Auto-updated by ${runner_role} pulse. Do not edit manually._"

	# Update the issue body
	gh issue edit "$health_issue_number" --repo "$repo_slug" --body "$body" >/dev/null 2>&1 || {
		echo "[pulse-wrapper] Health issue: failed to update body for #${health_issue_number}" >>"$LOGFILE"
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
	local current_title
	current_title=$(gh issue view "$health_issue_number" --repo "$repo_slug" --json title --jq '.title' 2>/dev/null || echo "")
	local current_stats="${current_title% at [0-9][0-9]:[0-9][0-9] UTC}"
	local new_stats="${health_title% at [0-9][0-9]:[0-9][0-9] UTC}"
	if [[ "$current_stats" != "$new_stats" ]]; then
		gh issue edit "$health_issue_number" --repo "$repo_slug" --title "$health_title" >/dev/null 2>&1 || true
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

	# Query all pinned issues via GraphQL
	local pinned_json
	pinned_json=$(gh api graphql -f query="
		query {
			repository(owner: \"${owner}\", name: \"${name}\") {
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
		}" 2>/dev/null || echo "")

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
		echo "[pulse-wrapper] Health issue: unpinned closed issue #${issue_num} in ${repo_slug}" >>"$LOGFILE"
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
		echo "[pulse-wrapper] Person stats cache refresh skipped: Search API budget ${search_remaining} < estimated cost ${min_budget_needed} (${repo_count} repos × ${search_api_cost_per_contributor} queries/contributor)" >>"$LOGFILE"
		return 0
	fi

	while IFS='|' read -r slug path; do
		[[ -z "$slug" ]] && continue

		# Re-check budget before each repo — bail early if exhausted mid-refresh
		search_remaining=$(gh api rate_limit --jq '.resources.search.remaining' 2>/dev/null) || search_remaining=0
		if [[ "$search_remaining" -lt "$search_api_cost_per_contributor" ]]; then
			echo "[pulse-wrapper] Person stats cache refresh stopped mid-run: Search API budget exhausted (${search_remaining} remaining)" >>"$LOGFILE"
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
	echo "[pulse-wrapper] Person stats cache refreshed" >>"$LOGFILE"
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
		echo "[pulse-wrapper] Health issues: updated $updated repo(s)" >>"$LOGFILE"
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

	echo "[pulse-wrapper] Starting daily code quality sweep..." >>"$LOGFILE"

	local swept=0
	while IFS='|' read -r slug path; do
		[[ -z "$slug" ]] && continue
		[[ ! -d "$path" ]] && continue
		_quality_sweep_for_repo "$slug" "$path" || true
		swept=$((swept + 1))
	done <<<"$repo_entries"

	# Update timestamp
	date +%s >"$QUALITY_SWEEP_LAST_RUN"

	echo "[pulse-wrapper] Quality sweep complete: $swept repo(s) swept" >>"$LOGFILE"
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

		issue_number=$(gh issue create --repo "$repo_slug" \
			--title "Daily Code Quality Review" \
			--body "Persistent issue for daily code quality sweeps across multiple tools (CodeRabbit, Qlty, ShellCheck, Codacy, SonarCloud). The supervisor posts findings here and creates actionable issues from them. **Do not close this issue.**" \
			--label "quality-review" --label "persistent" 2>/dev/null | grep -oE '[0-9]+$' || echo "")

		if [[ -z "$issue_number" ]]; then
			echo "[pulse-wrapper] Quality sweep: could not create issue for ${repo_slug}" >>"$LOGFILE"
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

		echo "[pulse-wrapper] Quality sweep: created and pinned issue #${issue_number} in ${repo_slug}" >>"$LOGFILE"
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
	local slug_safe="${repo_slug//\//-}"

	mkdir -p "$QUALITY_SWEEP_STATE_DIR"

	local state_file="${QUALITY_SWEEP_STATE_DIR}/${slug_safe}.json"
	printf '{"gate_status":"%s","total_issues":%d,"high_critical_count":%d,"updated_at":"%s"}\n' \
		"$gate_status" "$total_issues" "$high_critical_count" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		>"$state_file"
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
		sh_files=$(find "$repo_path" -name "*.sh" -not -path "*/archived/*" -not -path "*/node_modules/*" -not -path "*/.git/*" -type f 2>/dev/null | head -100)

		if [[ -n "$sh_files" ]]; then
			local sc_errors=0
			local sc_warnings=0
			local sc_summary=""
			local sc_details=""

			# timeout_sec (from shared-constants.sh) handles macOS + Linux portably.
			# It always provides a timeout mechanism (background + kill fallback on
			# bare macOS), so we no longer need to skip ShellCheck when no timeout
			# utility is installed.

			while IFS= read -r shfile; do
				[[ -z "$shfile" ]] && continue
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

	# --- 2. Qlty CLI ---
	local qlty_section=""
	local qlty_bin="${HOME}/.qlty/bin/qlty"
	if [[ -x "$qlty_bin" ]] && [[ -f "${repo_path}/.qlty.toml" ]]; then
		local qlty_output
		qlty_output=$("$qlty_bin" smells --all 2>/dev/null | head -50) || qlty_output=""

		if [[ -n "$qlty_output" ]]; then
			local smell_count
			smell_count=$(echo "$qlty_output" | wc -l | tr -d ' ')
			qlty_section="### Qlty Maintainability Smells

- **Total smells**: ${smell_count}

\`\`\`
$(echo "$qlty_output" | head -30)
\`\`\`
"
			if [[ "$smell_count" -gt 30 ]]; then
				qlty_section="${qlty_section}
_(showing first 30 of ${smell_count} — run \`qlty smells --all\` for full list)_
"
			fi
		else
			qlty_section="### Qlty Maintainability Smells

_No smells detected or qlty analysis returned empty._
"
		fi
		tool_count=$((tool_count + 1))
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
				echo "[pulse-wrapper] Failed to URL-encode project_key — skipping SonarCloud" >&2
			fi

			# SonarCloud public API — quality gate status
			local sonar_status=""
			if [[ -n "$encoded_project_key" ]]; then
				sonar_status=$(curl -sS --fail --connect-timeout 5 --max-time 20 \
					"https://sonarcloud.io/api/qualitygates/project_status?projectKey=${encoded_project_key}" || echo "")
			fi

			if [[ -n "$sonar_status" ]] && echo "$sonar_status" | jq -e '.projectStatus' &>/dev/null; then
				# Single jq pass: extract gate status and conditions together
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
			fi

			# Fetch open issues summary
			local sonar_issues=""
			if [[ -n "$encoded_project_key" ]]; then
				sonar_issues=$(curl -sS --fail --connect-timeout 5 --max-time 20 \
					"https://sonarcloud.io/api/issues/search?componentKeys=${encoded_project_key}&statuses=OPEN,CONFIRMED,REOPENED&ps=1&facets=severities,types" || echo "")
			fi

			if [[ -n "$sonar_issues" ]] && echo "$sonar_issues" | jq -e '.total' &>/dev/null; then
				# Single jq pass: extract total, high/critical count, severity breakdown, and type breakdown
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
		echo "[pulse-wrapper] CodeRabbit: first run for ${repo_slug} — saved baseline, skipping trigger" >>"$LOGFILE"
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
			echo "[pulse-wrapper] CodeRabbit: active review triggered for ${repo_slug} (${trigger_reasons})" >>"$LOGFILE"
		else
			coderabbit_section="### CodeRabbit

_Monitoring: ${sweep_total_issues} issues (delta: ${issue_delta}), gate ${sweep_gate_status} — no active review needed._
"
		fi
	fi

	# Common to all branches: save state for next sweep and count the tool
	_save_sweep_state "$repo_slug" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical"
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
		echo "[pulse-wrapper] Quality sweep: no tools available for ${repo_slug}" >>"$LOGFILE"
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
_Auto-generated by pulse-wrapper.sh daily quality sweep. The supervisor will review findings and create actionable issues._"

	# --- 7. Update issue body with stats dashboard (t1411) ---
	# Mirrors the supervisor health issue pattern: the issue body is a live
	# dashboard updated each sweep, while comments preserve the daily history.
	# Runs before the comment post so a transient comment failure doesn't
	# leave the dashboard stale (CodeRabbit review feedback).
	_update_quality_issue_body "$repo_slug" "$issue_number" \
		"$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" \
		"$now_iso" "$tool_count"

	# Post comment (best-effort — dashboard already updated above)
	local comment_stderr=""
	local comment_posted=false
	comment_stderr=$(gh issue comment "$issue_number" --repo "$repo_slug" --body "$comment_body" 2>&1 >/dev/null) && comment_posted=true || {
		echo "[pulse-wrapper] Quality sweep: failed to post comment on #${issue_number} in ${repo_slug}: ${comment_stderr}" >>"$LOGFILE"
	}

	if [[ "$comment_posted" == true ]]; then
		echo "[pulse-wrapper] Quality sweep: posted findings on #${issue_number} in ${repo_slug} (${tool_count} tools)" >>"$LOGFILE"
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
#######################################
_update_quality_issue_body() {
	local repo_slug="$1"
	local issue_number="$2"
	local gate_status="$3"
	local total_issues="$4"
	local high_critical="$5"
	local sweep_time="$6"
	local tool_count="$7"

	# --- Quality-debt backlog stats ---
	# Use GraphQL issueCount for accurate totals without pagination limits
	# (CodeRabbit review feedback — gh issue list defaults to 30 results).
	local debt_open=0
	local debt_closed=0
	debt_open=$(gh api graphql -f query="
		query {
			search(
				query: \"repo:${repo_slug} is:issue is:open label:quality-debt\",
				type: ISSUE,
				first: 1
			) {
				issueCount
			}
		}" --jq '.data.search.issueCount' 2>>"$LOGFILE" || echo "0")
	debt_closed=$(gh api graphql -f query="
		query {
			search(
				query: \"repo:${repo_slug} is:issue is:closed label:quality-debt\",
				type: ISSUE,
				first: 1
			) {
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
		local pr_numbers
		pr_numbers=$(echo "$open_prs_json" | jq -r '.[].number')
		while IFS= read -r pr_num; do
			[[ -z "$pr_num" ]] && continue
			local gate_result
			gate_result=$("$review_helper" check "$pr_num" "$repo_slug" 2>>"$LOGFILE" || echo "UNKNOWN")
			case "$gate_result" in
			PASS*)
				prs_with_reviews=$((prs_with_reviews + 1))
				;;
			WAITING* | UNKNOWN*)
				prs_waiting=$((prs_waiting + 1))
				# Check if PR is older than 2 hours (stale waiting)
				local pr_created
				pr_created=$(echo "$open_prs_json" | jq -r --argjson n "$pr_num" '.[] | select(.number == $n) | .createdAt' || echo "")
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
							pr_title=$(echo "$open_prs_json" | jq -r --argjson n "$pr_num" '.[] | select(.number == $n) | .title[:50]' || echo "")
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
		done <<<"$pr_numbers"
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

	# --- Assemble dashboard body ---
	local body="## Quality Review Dashboard

**Last sweep**: \`${sweep_time}\`
**Repo**: \`${repo_slug}\`
**Tools run**: ${tool_count}

### Summary

| Metric | Value |
| --- | --- |
| SonarCloud gate | ${gate_status} |
| SonarCloud issues | ${total_issues} (${high_critical} high/critical) |
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
		echo "[pulse-wrapper] Quality sweep: failed to update body on #${issue_number} in ${repo_slug}: ${edit_stderr}" >>"$LOGFILE"
		return 0
	}

	# Update issue title with stats (like supervisor health issues)
	local debt_label="debt"
	local title_gate="${gate_status}"
	[[ "$gate_status" == "UNKNOWN" ]] && title_gate="--"
	local quality_title="Daily Code Quality Review — ${title_gate}, ${debt_open} ${debt_label}, ${total_issues} sonar"
	# Only update title if it changed (avoid unnecessary API calls)
	local current_title
	current_title=$(gh issue view "$issue_number" --repo "$repo_slug" --json title --jq '.title' 2>>"$LOGFILE" || echo "")
	if [[ "$current_title" != "$quality_title" ]]; then
		gh issue edit "$issue_number" --repo "$repo_slug" --title "$quality_title" 2>>"$LOGFILE" >/dev/null || true
	fi

	echo "[pulse-wrapper] Quality sweep: updated dashboard on #${issue_number} in ${repo_slug}" >>"$LOGFILE"
	return 0
}

#######################################
# Check if the pulse is allowed to run.
#
# Consent model (layered, highest priority first):
#   1. Session stop flag — `aidevops pulse stop` creates this to pause
#      the pulse without uninstalling it. Checked first so stop always wins.
#   2. Session start flag — `aidevops pulse start` creates this. If present,
#      the pulse runs regardless of config (explicit user action).
#   3. Config consent — setup.sh writes orchestration.supervisor_pulse=true
#      when the user consents. This is the persistent, reboot-surviving gate.
#
# If none of the above are set, the pulse was installed without config
# consent (shouldn't happen after GH#2926) — skip as a safety fallback.
#
# Returns: 0 if pulse should run, 1 if not
#######################################
check_session_gate() {
	# Stop flag takes priority — user explicitly paused
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Pulse paused (stop flag present) — resume with: aidevops pulse start" >>"$LOGFILE"
		return 1
	fi

	# Session start flag — explicit user action, always allowed
	if [[ -f "$SESSION_FLAG" ]]; then
		return 0
	fi

	# Config consent — the persistent gate that survives reboots.
	# Delegates to config_enabled from config-helper.sh (sourced via
	# shared-constants.sh), which handles: env var override
	# (AIDEVOPS_SUPERVISOR_PULSE) > user JSONC config > defaults.
	# Single canonical implementation shared with pulse-session-helper.sh.
	if type config_enabled &>/dev/null && config_enabled "orchestration.supervisor_pulse"; then
		return 0
	fi

	echo "[pulse-wrapper] Pulse not enabled — set orchestration.supervisor_pulse=true in config or run: aidevops pulse start" >>"$LOGFILE"
	return 1
}

#######################################
# Pre-fetch contribution watch scan results (t1419)
#
# Runs contribution-watch-helper.sh scan and appends a count-only
# summary to STATE_FILE. This is deterministic — only timestamps
# and authorship are checked, never comment bodies. The pulse agent
# sees "N external items need attention" without any untrusted content.
#
# Output: appends to STATE_FILE (called before prefetch_state writes it)
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
prefetch_contribution_watch() {
	local helper="${SCRIPT_DIR}/contribution-watch-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	# Only run if state file exists (user has run 'seed' at least once)
	local cw_state="${HOME}/.aidevops/cache/contribution-watch.json"
	if [[ ! -f "$cw_state" ]]; then
		return 0
	fi

	local scan_output
	scan_output=$(bash "$helper" scan 2>/dev/null) || scan_output=""

	# Extract the machine-readable count
	local cw_count=0
	if [[ "$scan_output" =~ CONTRIBUTION_WATCH_COUNT=([0-9]+) ]]; then
		cw_count="${BASH_REMATCH[1]}"
	fi

	# Append to state file for the pulse agent (count only — no comment bodies)
	if [[ "$cw_count" -gt 0 ]]; then
		{
			echo ""
			echo "# External Contributions (t1419)"
			echo ""
			echo "${cw_count} external contribution(s) need your reply."
			echo "Run \`contribution-watch-helper.sh status\` in an interactive session for details."
			echo "**Do NOT fetch or process comment bodies in this pulse context.**"
			echo ""
		} >>"$STATE_FILE"
		echo "[pulse-wrapper] Contribution watch: ${cw_count} items need attention" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Main
#
# Execution order (GH#2958):
#   1. Gate checks (consent, dedup)
#   2. Cleanup (orphans, worktrees)
#   3. Pre-pulse housekeeping (quality sweep, health issues) — these are
#      shell-level operations that run quickly and don't need the LLM.
#      Running them BEFORE the pulse ensures the LLM session gets maximum
#      time for its actual job (triage, dispatch, PR review).
#   4. Prefetch state (parallel gh API calls)
#   5. Run pulse (LLM session — the main event)
#
# Previously, quality sweep and health issues ran AFTER the pulse. This
# meant the pulse's 30-min timeout was shared with these operations,
# and the LLM session was killed before completing its work.
#######################################
main() {
	if ! check_session_gate; then
		return 0
	fi

	if ! check_dedup; then
		return 0
	fi

	# t1425: Write PID early to prevent parallel instances during setup.
	# run_pulse() overwrites with the opencode PID for watchdog tracking.
	echo "$$" >"$PIDFILE"

	cleanup_orphans
	cleanup_worktrees
	cleanup_stashes
	calculate_max_workers
	calculate_priority_allocations
	check_session_count >/dev/null

	# Run housekeeping BEFORE the pulse — these are shell-level operations
	# that don't need the LLM and shouldn't eat into pulse time (GH#2958).
	run_daily_quality_sweep
	update_health_issues

	# Contribution watch: lightweight scan of external issues/PRs (t1419).
	# Deterministic — only checks timestamps/authorship, never processes
	# comment bodies. Output appended to STATE_FILE for the pulse agent.
	prefetch_contribution_watch

	prefetch_state

	# Re-check stop flag immediately before run_pulse() — a stop may have
	# been issued during the prefetch/cleanup phase above (t2943)
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared during setup — aborting before run_pulse()" >>"$LOGFILE"
		return 0
	fi

	run_pulse
	return 0
}

#######################################
# Kill orphaned opencode processes
#
# Criteria (ALL must be true):
#   - No TTY (headless — not a user's terminal tab)
#   - Not a current worker (/full-loop not in command)
#   - Not the supervisor pulse (Supervisor Pulse not in command)
#   - Not a strategic review (Strategic Review not in command)
#   - Older than ORPHAN_MAX_AGE seconds
#
# These are completed headless sessions where opencode entered idle
# state with a file watcher and never exited.
#######################################
cleanup_orphans() {
	local killed=0
	local total_mb=0

	while IFS= read -r line; do
		local pid tty etime rss cmd
		read -r pid tty etime rss cmd <<<"$line"

		# Skip interactive sessions (has a real TTY).
		# Exclude both '?' (Linux headless) and '??' (macOS headless) — only
		# those are headless; anything else (pts/N, ttys00N) is interactive.
		if [[ "$tty" != "?" && "$tty" != "??" ]]; then
			continue
		fi

		# Skip active workers, pulse, strategic reviews, and language servers
		if [[ "$cmd" =~ /full-loop|Supervisor\ Pulse|Strategic\ Review|language-server|eslintServer ]]; then
			continue
		fi

		# Skip young processes
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		if [[ "$age_seconds" -lt "$ORPHAN_MAX_AGE" ]]; then
			continue
		fi

		# This is an orphan — kill it
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))
		kill "$pid" 2>/dev/null || true
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axo pid,tty,etime,rss,command | grep '[.]opencode' | grep -v 'bash-language-server')

	# Also kill orphaned node launchers (parent of .opencode processes)
	while IFS= read -r line; do
		local pid tty etime rss cmd
		read -r pid tty etime rss cmd <<<"$line"

		[[ "$tty" != "?" && "$tty" != "??" ]] && continue
		[[ "$cmd" =~ /full-loop|Supervisor\ Pulse|Strategic\ Review|language-server|eslintServer ]] && continue

		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		[[ "$age_seconds" -lt "$ORPHAN_MAX_AGE" ]] && continue

		kill "$pid" 2>/dev/null || true
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axo pid,tty,etime,rss,command | grep 'node.*opencode' | grep -v '[.]opencode')

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] Cleaned up $killed orphaned opencode processes (freed ~${total_mb}MB)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Calculate max workers from available RAM
#
# Formula: (free_ram - RAM_RESERVE_MB) / RAM_PER_WORKER_MB
# Clamped to [1, MAX_WORKERS_CAP]
#
# Writes MAX_WORKERS to a file that pulse.md reads via bash.
#######################################
calculate_max_workers() {
	local free_mb
	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS: use vm_stat for free + inactive (reclaimable) pages
		local page_size free_pages inactive_pages
		page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
		free_pages=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
		inactive_pages=$(vm_stat 2>/dev/null | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
		# Validate integers before arithmetic expansion
		[[ "$page_size" =~ ^[0-9]+$ ]] || page_size=16384
		[[ "$free_pages" =~ ^[0-9]+$ ]] || free_pages=0
		[[ "$inactive_pages" =~ ^[0-9]+$ ]] || inactive_pages=0
		free_mb=$(((free_pages + inactive_pages) * page_size / 1024 / 1024))
	else
		# Linux: use MemAvailable from /proc/meminfo
		free_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 8192)
	fi
	[[ "$free_mb" =~ ^[0-9]+$ ]] || free_mb=8192

	local available_mb=$((free_mb - RAM_RESERVE_MB))
	local max_workers=$((available_mb / RAM_PER_WORKER_MB))

	# Clamp to [1, MAX_WORKERS_CAP]
	if [[ "$max_workers" -lt 1 ]]; then
		max_workers=1
	elif [[ "$max_workers" -gt "$MAX_WORKERS_CAP" ]]; then
		max_workers="$MAX_WORKERS_CAP"
	fi

	# Write to a file that pulse.md can read
	local max_workers_file="${HOME}/.aidevops/logs/pulse-max-workers"
	echo "$max_workers" >"$max_workers_file"

	echo "[pulse-wrapper] Available RAM: ${free_mb}MB, reserve: ${RAM_RESERVE_MB}MB, max workers: ${max_workers}" >>"$LOGFILE"
	return 0
}

#######################################
# Calculate priority-class worker allocations (t1423)
#
# Reads repos.json to count product vs tooling repos, then computes
# per-class slot reservations based on PRODUCT_RESERVATION_PCT.
#
# Product repos get a guaranteed minimum share of worker slots.
# Tooling repos get the remainder. When one class has no pending work,
# the other class can use the freed slots (soft reservation).
#
# Output: writes allocation data to pulse-priority-allocations file
# and appends a summary section to STATE_FILE for the pulse agent.
#
# Depends on: calculate_max_workers() having run first (reads pulse-max-workers)
#######################################
calculate_priority_allocations() {
	local repos_json="${REPOS_JSON}"
	local max_workers_file="${HOME}/.aidevops/logs/pulse-max-workers"
	local alloc_file="${HOME}/.aidevops/logs/pulse-priority-allocations"

	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "[pulse-wrapper] repos.json or jq not available — skipping priority allocations" >>"$LOGFILE"
		return 0
	fi

	local max_workers
	max_workers=$(cat "$max_workers_file" 2>/dev/null || echo 4)
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=4

	# Count pulse-enabled repos by priority class (single jq pass)
	local product_repos tooling_repos
	read -r product_repos tooling_repos < <(jq -r '
		.initialized_repos |
		map(select(.pulse == true and (.local_only // false) == false and .slug != "")) |
		[
			(map(select(.priority == "product")) | length),
			(map(select(.priority == "tooling")) | length)
		] | @tsv
	' "$repos_json" 2>/dev/null) || true
	product_repos=${product_repos:-0}
	tooling_repos=${tooling_repos:-0}
	[[ "$product_repos" =~ ^[0-9]+$ ]] || product_repos=0
	[[ "$tooling_repos" =~ ^[0-9]+$ ]] || tooling_repos=0

	# Calculate reservations
	# product_min = ceil(max_workers * PRODUCT_RESERVATION_PCT / 100)
	# Using integer arithmetic: ceil(a/b) = (a + b - 1) / b
	local product_min tooling_max
	if [[ "$product_repos" -eq 0 ]]; then
		# No product repos — all slots available for tooling
		product_min=0
		tooling_max="$max_workers"
	elif [[ "$tooling_repos" -eq 0 ]]; then
		# No tooling repos — all slots available for product
		product_min="$max_workers"
		tooling_max=0
	else
		product_min=$(((max_workers * PRODUCT_RESERVATION_PCT + 99) / 100))
		# Ensure product_min doesn't exceed max_workers
		if [[ "$product_min" -gt "$max_workers" ]]; then
			product_min="$max_workers"
		fi
		# Ensure at least 1 slot for tooling when tooling repos exist
		# but only when there are multiple slots to distribute (with 1 slot,
		# product keeps it — the reservation is a minimum guarantee)
		if [[ "$max_workers" -gt 1 && "$product_min" -ge "$max_workers" && "$tooling_repos" -gt 0 ]]; then
			product_min=$((max_workers - 1))
		fi
		tooling_max=$((max_workers - product_min))
	fi

	# Write allocation file (key=value, readable by pulse.md)
	{
		echo "MAX_WORKERS=${max_workers}"
		echo "PRODUCT_REPOS=${product_repos}"
		echo "TOOLING_REPOS=${tooling_repos}"
		echo "PRODUCT_MIN=${product_min}"
		echo "TOOLING_MAX=${tooling_max}"
		echo "PRODUCT_RESERVATION_PCT=${PRODUCT_RESERVATION_PCT}"
	} >"$alloc_file"

	echo "[pulse-wrapper] Priority allocations: product_min=${product_min}, tooling_max=${tooling_max} (${product_repos} product, ${tooling_repos} tooling repos, ${max_workers} total slots)" >>"$LOGFILE"
	return 0
}

# Only run main when executed directly, not when sourced.
# The pulse agent sources this file to access helper functions
# (check_external_contributor_pr, check_permission_failure_pr)
# without triggering the full pulse lifecycle.
#
# Shell-portable source detection (GH#3931):
#   bash: BASH_SOURCE[0] differs from $0 when sourced
#   zsh:  BASH_SOURCE is undefined; use ZSH_EVAL_CONTEXT instead
#         (contains "file" when sourced, "toplevel" when executed)
_pulse_is_sourced() {
	if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
		[[ "${BASH_SOURCE[0]}" != "${0}" ]]
	elif [[ -n "${ZSH_EVAL_CONTEXT:-}" ]]; then
		[[ ":${ZSH_EVAL_CONTEXT}:" == *":file:"* ]]
	else
		return 1
	fi
}
if ! _pulse_is_sourced; then
	main "$@"
fi
