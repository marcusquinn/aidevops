#!/usr/bin/env bash
# pulse-wrapper.sh - Wrapper for supervisor pulse with dedup and lifecycle management
#
# Solves: opencode run enters idle state after completing the pulse prompt
# but never exits, blocking all future pulses via the pgrep dedup guard.
#
# This wrapper:
#   1. Uses a PID file with staleness check (not pgrep) for dedup
#   2. Cleans up orphaned opencode processes before each pulse
#   3. Calculates dynamic worker concurrency from available RAM
#   4. Lets the pulse run to completion — no hard timeout
#
# Lifecycle: launchd fires every 120s. If a pulse is still running, the
# dedup check skips. If a pulse has been running longer than PULSE_STALE_THRESHOLD
# (default 30 min), it's assumed stuck (opencode idle bug) and killed so the
# next invocation can start fresh. This is the ONLY kill mechanism — no
# arbitrary timeouts that would interrupt active work.
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

#######################################
# Configuration
#######################################
PULSE_STALE_THRESHOLD="${PULSE_STALE_THRESHOLD:-1800}" # 30 min = definitely stuck (opencode idle bug)

# Validate numeric configuration
if ! [[ "$PULSE_STALE_THRESHOLD" =~ ^[0-9]+$ ]]; then
	echo "[pulse-wrapper] Invalid PULSE_STALE_THRESHOLD: $PULSE_STALE_THRESHOLD — using default 1800" >&2
	PULSE_STALE_THRESHOLD=1800
fi
PIDFILE="${HOME}/.aidevops/logs/pulse.pid"
LOGFILE="${HOME}/.aidevops/logs/pulse.log"
OPENCODE_BIN="${OPENCODE_BIN:-/opt/homebrew/bin/opencode}"
PULSE_DIR="${PULSE_DIR:-${HOME}/Git/aidevops}"
PULSE_MODEL="${PULSE_MODEL:-anthropic/claude-sonnet-4-6}"
ORPHAN_MAX_AGE="${ORPHAN_MAX_AGE:-7200}"       # 2 hours — kill orphans older than this
RAM_PER_WORKER_MB="${RAM_PER_WORKER_MB:-1024}" # 1 GB per worker
RAM_RESERVE_MB="${RAM_RESERVE_MB:-8192}"       # 8 GB reserved for OS + user apps
MAX_WORKERS_CAP="${MAX_WORKERS_CAP:-8}"        # Hard ceiling regardless of RAM
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
STATE_FILE="${HOME}/.aidevops/logs/pulse-state.txt"

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
	if ! kill -0 "$old_pid" 2>/dev/null; then
		# Process is dead, clean up stale PID file
		rm -f "$PIDFILE"
		return 0
	fi

	# Process is running — check how long
	local elapsed_seconds
	elapsed_seconds=$(_get_process_age "$old_pid")

	if [[ "$elapsed_seconds" -gt "$PULSE_STALE_THRESHOLD" ]]; then
		# Process has been running too long — it's stuck
		echo "[pulse-wrapper] Killing stale pulse process $old_pid (running ${elapsed_seconds}s, threshold ${PULSE_STALE_THRESHOLD}s)" >>"$LOGFILE"
		_kill_tree "$old_pid"
		sleep 2
		# Force kill if still alive
		if kill -0 "$old_pid" 2>/dev/null; then
			_force_kill_tree "$old_pid"
		fi
		rm -f "$PIDFILE"
		return 0
	fi

	# Process is running and within time limit — genuine dedup
	echo "[pulse-wrapper] Pulse already running (PID $old_pid, ${elapsed_seconds}s elapsed). Skipping." >>"$LOGFILE"
	return 1
}

#######################################
# Kill a process and all its children (macOS-compatible)
# Arguments:
#   $1 - PID to kill
#######################################
_kill_tree() {
	local pid="$1"
	# Find all child processes recursively (bash 3.2 compatible — no mapfile)
	local child
	while IFS= read -r child; do
		[[ -n "$child" ]] && _kill_tree "$child"
	done < <(pgrep -P "$pid" 2>/dev/null || true)
	kill "$pid" 2>/dev/null || true
	return 0
}

#######################################
# Force kill a process and all its children
# Arguments:
#   $1 - PID to kill
#######################################
_force_kill_tree() {
	local pid="$1"
	local child
	while IFS= read -r child; do
		[[ -n "$child" ]] && _force_kill_tree "$child"
	done < <(pgrep -P "$pid" 2>/dev/null || true)
	kill -9 "$pid" 2>/dev/null || true
	return 0
}

#######################################
# Get process age in seconds
# Arguments:
#   $1 - PID
# Returns: elapsed seconds via stdout
#######################################
_get_process_age() {
	local pid="$1"
	local etime
	# macOS ps etime format: MM:SS or HH:MM:SS or D-HH:MM:SS
	etime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ') || etime=""

	if [[ -z "$etime" ]]; then
		echo "0"
		return 0
	fi

	local days=0 hours=0 minutes=0 seconds=0

	# Parse D-HH:MM:SS format
	if [[ "$etime" == *-* ]]; then
		days="${etime%%-*}"
		etime="${etime#*-}"
	fi

	# Count colons to determine format
	local colon_count
	colon_count=$(echo "$etime" | tr -cd ':' | wc -c | tr -d ' ')

	if [[ "$colon_count" -eq 2 ]]; then
		# HH:MM:SS
		IFS=':' read -r hours minutes seconds <<<"$etime"
	elif [[ "$colon_count" -eq 1 ]]; then
		# MM:SS
		IFS=':' read -r minutes seconds <<<"$etime"
	else
		seconds="$etime"
	fi

	# Remove leading zeros to avoid octal interpretation
	days=$((10#${days}))
	hours=$((10#${hours}))
	minutes=$((10#${minutes}))
	seconds=$((10#${seconds}))

	echo $((days * 86400 + hours * 3600 + minutes * 60 + seconds))
	return 0
}

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

				# PRs
				local pr_json
				pr_json=$(gh pr list --repo "$slug" --state open \
					--json number,title,reviewDecision,statusCheckRollup,updatedAt,headRefName \
					--limit 20 2>/dev/null) || pr_json="[]"

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

				# Issues
				local issue_json
				issue_json=$(gh issue list --repo "$slug" --state open \
					--json number,title,labels,updatedAt \
					--limit 20 2>/dev/null) || issue_json="[]"

				local issue_count
				issue_count=$(echo "$issue_json" | jq 'length')

				if [[ "$issue_count" -gt 0 ]]; then
					echo "### Open Issues ($issue_count)"
					echo "$issue_json" | jq -r '.[] | "- Issue #\(.number): \(.title) [labels: \(if (.labels | length) == 0 then "none" else (.labels | map(.name) | join(", ")) end)] [updated: \(.updatedAt)]"'
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

#######################################
# Pre-fetch active worker processes (t216)
#
# Captures a snapshot of running worker processes so the pulse agent
# can cross-reference open PRs with active workers. This is the
# deterministic data-fetch part — the intelligence about which PRs
# are orphaned stays in pulse.md.
#
# Output: worker summary to stdout (appended to STATE_FILE by caller)
#######################################
prefetch_active_workers() {
	local worker_lines
	worker_lines=$(ps axo pid,etime,command 2>/dev/null | grep '/full-loop' | grep '\.opencode' | grep -v grep || true)

	echo ""
	echo "# Active Workers"
	echo ""
	echo "Snapshot of running worker processes at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
	echo "Use this to determine whether a PR has an active worker (not orphaned)."
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
			pid=$(echo "$line" | awk '{print $1}')
			etime=$(echo "$line" | awk '{print $2}')
			cmd=$(echo "$line" | cut -d' ' -f3-)
			echo "- PID $pid (uptime: $etime): $cmd"
		done
	fi

	echo ""
	return 0
}

#######################################
# Run the pulse — no hard timeout
#
# The pulse runs until opencode exits naturally. If opencode enters its
# idle-state bug (file watcher keeps process alive after session completes),
# the NEXT launchd invocation's check_dedup() will detect the stale process
# (age > PULSE_STALE_THRESHOLD) and kill it. This is correct because:
#   - Active pulses doing real work are never interrupted
#   - Stuck pulses are detected by the next invocation (120s later)
#   - The stale threshold (30 min) is generous enough for any real workload
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

	# Run opencode — blocks until it exits (or is killed by next invocation's stale check)
	"$OPENCODE_BIN" run "$prompt" \
		--dir "$PULSE_DIR" \
		-m "$PULSE_MODEL" \
		--title "Supervisor Pulse" \
		>>"$LOGFILE" 2>&1 &

	local opencode_pid=$!
	echo "$opencode_pid" >"$PIDFILE"

	echo "[pulse-wrapper] opencode PID: $opencode_pid" >>"$LOGFILE"

	# Wait for natural exit
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
# Iterates repos.json and runs worktree-helper.sh clean --auto --force-merged
# in each repo directory. This prevents stale worktrees from accumulating
# on disk after PR merges — including squash merges that git branch --merged
# cannot detect.
#
# --force-merged: uses gh pr list to detect squash merges and force-removes
# dirty worktrees when the PR is confirmed merged (dirty state = abandoned WIP).
#
# Safety: skips worktrees owned by active sessions (handled by worktree-helper.sh).
#######################################
cleanup_worktrees() {
	local helper="${HOME}/.aidevops/agents/scripts/worktree-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	local repos_json="${HOME}/.config/aidevops/repos.json"
	local total_removed=0

	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		# Iterate all repos, skip local_only (no GitHub remote for PR detection)
		local repo_paths
		repo_paths=$(jq -r '.[] | select(.local_only != true) | .path' "$repos_json" 2>/dev/null || echo "")

		local repo_path
		while IFS= read -r repo_path; do
			[[ -z "$repo_path" ]] && continue
			[[ ! -d "$repo_path/.git" ]] && continue

			local cleaned_output
			cleaned_output=$(git -C "$repo_path" worktree list 2>/dev/null | wc -l)
			# Skip repos with only 1 worktree (the main one) — nothing to clean
			if [[ "$cleaned_output" -le 1 ]]; then
				continue
			fi

			# Run helper in a subshell cd'd to the repo (it uses git rev-parse --show-toplevel)
			local clean_result
			clean_result=$(cd "$repo_path" && bash "$helper" clean --auto --force-merged 2>&1) || true

			local count
			count=$(echo "$clean_result" | grep -c 'Removing' || echo "0")
			if [[ "$count" -gt 0 ]]; then
				local repo_name
				repo_name=$(basename "$repo_path")
				echo "[pulse-wrapper] Worktree cleanup ($repo_name): $count worktree(s) removed" >>"$LOGFILE"
				total_removed=$((total_removed + count))
			fi
		done <<<"$repo_paths"
	else
		# Fallback: just clean the current repo (legacy behaviour)
		local cleaned_output
		cleaned_output=$(bash "$helper" clean --auto --force-merged 2>&1) || true
		if echo "$cleaned_output" | grep -q "Removing\|removed"; then
			echo "[pulse-wrapper] Worktree cleanup: $(echo "$cleaned_output" | grep -c 'Removing') worktree(s) removed" >>"$LOGFILE"
		fi
	fi

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
# "supervisor" + "$runner_user" for dedup. Issue number cached
# in ~/.aidevops/logs/ to avoid repeated lookups.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - repo path (local filesystem)
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
_update_health_issue_for_repo() {
	local repo_slug="$1"
	local repo_path="$2"

	[[ -z "$repo_slug" ]] && return 0

	# Per-runner identity
	local runner_user
	runner_user=$(gh api user --jq '.login' 2>/dev/null || whoami)
	local runner_prefix="[Supervisor:${runner_user}]"

	# Cache file for this runner + repo (slug with / replaced by -)
	local slug_safe="${repo_slug//\//-}"
	local cache_dir="${HOME}/.aidevops/logs"
	local health_issue_file="${cache_dir}/health-issue-${runner_user}-${slug_safe}"
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
			_unpin_health_issue "$health_issue_number" "$repo_slug"
			health_issue_number=""
			rm -f "$health_issue_file" 2>/dev/null || true
		fi
	fi

	# Search by labels (more reliable than title search)
	if [[ -z "$health_issue_number" ]]; then
		local label_results
		label_results=$(gh issue list --repo "$repo_slug" \
			--label "supervisor" --label "$runner_user" \
			--state open --json number,title \
			--jq '[.[] | select(.title | startswith("[Supervisor:"))] | sort_by(.number) | reverse' 2>/dev/null || echo "[]")

		health_issue_number=$(printf '%s' "$label_results" | jq -r '.[0].number // empty' 2>/dev/null || echo "")

		# Dedup: close all but the newest
		local dup_count
		dup_count=$(printf '%s' "$label_results" | jq 'length' 2>/dev/null || echo "0")
		if [[ "${dup_count:-0}" -gt 1 ]]; then
			local dup_numbers
			dup_numbers=$(printf '%s' "$label_results" | jq -r '.[1:][].number' 2>/dev/null || echo "")
			while IFS= read -r dup_num; do
				[[ -z "$dup_num" ]] && continue
				_unpin_health_issue "$dup_num" "$repo_slug"
				gh issue close "$dup_num" --repo "$repo_slug" \
					--comment "Closing duplicate supervisor health issue — superseded by #${health_issue_number}." 2>/dev/null || true
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
				--description "Supervisor runner: ${runner_user}" --force 2>/dev/null || true
			gh issue edit "$health_issue_number" --repo "$repo_slug" \
				--add-label "supervisor" --add-label "$runner_user" 2>/dev/null || true
		fi
	fi

	# Create the issue if it doesn't exist
	if [[ -z "$health_issue_number" ]]; then
		gh label create "supervisor" --repo "$repo_slug" --color "1D76DB" \
			--description "Supervisor health dashboard" --force 2>/dev/null || true
		gh label create "$runner_user" --repo "$repo_slug" --color "0E8A16" \
			--description "Supervisor runner: ${runner_user}" --force 2>/dev/null || true

		health_issue_number=$(gh issue create --repo "$repo_slug" \
			--title "${runner_prefix} starting..." \
			--body "Live supervisor status for **${runner_user}**. Updated each pulse. Pin this issue for at-a-glance monitoring." \
			--label "supervisor" --label "$runner_user" 2>/dev/null | grep -oE '[0-9]+$' || echo "")

		if [[ -z "$health_issue_number" ]]; then
			echo "[pulse-wrapper] Health issue: could not create for ${repo_slug}" >>"$LOGFILE"
			return 0
		fi

		# Pin (best-effort — requires admin)
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
		echo "[pulse-wrapper] Health issue: created and pinned #${health_issue_number} for ${runner_user} in ${repo_slug}" >>"$LOGFILE"
	fi

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
		--json number,labels --jq '[.[] | select(.labels | map(.name) | index("supervisor") | not)] | length' 2>/dev/null || echo "0")

	# Active headless workers (opencode processes for this repo)
	local workers_md=""
	local worker_count=0
	local worker_lines
	worker_lines=$(ps axo pid,tty,etime,command 2>/dev/null | grep '\.opencode' | grep -v grep | grep -v 'bash-language-server' || true)

	if [[ -n "$worker_lines" ]]; then
		local worker_table=""
		while IFS= read -r line; do
			local w_pid w_tty w_etime w_cmd
			w_pid=$(echo "$line" | awk '{print $1}')
			w_tty=$(echo "$line" | awk '{print $2}')
			w_etime=$(echo "$line" | awk '{print $3}')
			w_cmd=$(echo "$line" | cut -d' ' -f4-)

			# Only count headless workers (no TTY)
			[[ "$w_tty" != "??" ]] && continue

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
		sys_load_ratio=$(awk "BEGIN {printf \"%d\", (${sys_load_1m} / ${sys_cpu_cores}) * 100}" 2>/dev/null || echo "?")
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

	# --- Assemble body ---
	local body
	body="## Queue Health Dashboard

**Last pulse**: \`${now_iso}\`
**Runner**: \`${runner_user}\`
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

### Open PRs

${prs_md}

### Active Workers

${workers_md}

### System Resources

| Metric | Value |
| --- | --- |
| CPU | ${sys_load_ratio}% used (${sys_cpu_cores} cores, load: ${sys_load_1m}/${sys_load_5m}) |
| Memory | ${sys_memory} |
| Processes | ${sys_procs} |

---
_Auto-updated by supervisor pulse. Do not edit manually._"

	# Update the issue body
	gh issue edit "$health_issue_number" --repo "$repo_slug" --body "$body" >/dev/null 2>&1 || {
		echo "[pulse-wrapper] Health issue: failed to update body for #${health_issue_number}" >>"$LOGFILE"
		return 0
	}

	# Build title with stats
	local title_parts="${pr_count} PRs, ${assigned_issue_count} assigned, ${worker_count} workers"
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

	local updated=0
	while IFS='|' read -r slug path; do
		[[ -z "$slug" ]] && continue
		_update_health_issue_for_repo "$slug" "$path" || true
		updated=$((updated + 1))
	done <<<"$repo_entries"

	if [[ "$updated" -gt 0 ]]; then
		echo "[pulse-wrapper] Health issues: updated $updated repo(s)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Main
#######################################
main() {
	if ! check_dedup; then
		return 0
	fi

	cleanup_orphans
	cleanup_worktrees
	calculate_max_workers
	prefetch_state
	run_pulse
	update_health_issues
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
		pid=$(echo "$line" | awk '{print $1}')
		tty=$(echo "$line" | awk '{print $2}')
		etime=$(echo "$line" | awk '{print $3}')
		rss=$(echo "$line" | awk '{print $4}')
		cmd=$(echo "$line" | cut -d' ' -f5-)

		# Skip interactive sessions (has a real TTY)
		if [[ "$tty" != "??" ]]; then
			continue
		fi

		# Skip active workers, pulse, strategic reviews, and language servers
		if echo "$cmd" | grep -qE '/full-loop|Supervisor Pulse|Strategic Review|language-server|eslintServer'; then
			continue
		fi

		# Skip young processes
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		if [[ "$age_seconds" -lt "$ORPHAN_MAX_AGE" ]]; then
			continue
		fi

		# This is an orphan — kill it
		local mb=$((rss / 1024))
		kill "$pid" 2>/dev/null || true
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axo pid,tty,etime,rss,command | grep '\.opencode' | grep -v grep | grep -v 'bash-language-server')

	# Also kill orphaned node launchers (parent of .opencode processes)
	while IFS= read -r line; do
		local pid tty etime rss cmd
		pid=$(echo "$line" | awk '{print $1}')
		tty=$(echo "$line" | awk '{print $2}')
		etime=$(echo "$line" | awk '{print $3}')
		rss=$(echo "$line" | awk '{print $4}')
		cmd=$(echo "$line" | cut -d' ' -f5-)

		[[ "$tty" != "??" ]] && continue
		echo "$cmd" | grep -qE '/full-loop|Supervisor Pulse|Strategic Review|language-server|eslintServer' && continue

		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		[[ "$age_seconds" -lt "$ORPHAN_MAX_AGE" ]] && continue

		kill "$pid" 2>/dev/null || true
		local mb=$((rss / 1024))
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axo pid,tty,etime,rss,command | grep 'node.*opencode' | grep -v grep | grep -v '\.opencode')

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
		free_mb=$(((free_pages + inactive_pages) * page_size / 1024 / 1024))
	else
		# Linux: use MemAvailable from /proc/meminfo
		free_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 8192)
	fi

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

main "$@"
