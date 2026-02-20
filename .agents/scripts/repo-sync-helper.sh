#!/usr/bin/env bash
# repo-sync-helper.sh - Daily git pull for repos in configured parent directories
#
# Scans configured parent directories for git repos cloned from a remote and
# runs `git pull --ff-only` on repos where:
#   - The working tree is clean (no uncommitted changes)
#   - The current branch is the default branch (main or master)
#   - The repo has a configured remote
#
# Follows the auto-update-helper.sh pattern for scheduler management.
#
# Usage:
#   repo-sync-helper.sh enable           Install daily scheduler (launchd/cron)
#   repo-sync-helper.sh disable          Remove scheduler
#   repo-sync-helper.sh status           Show current state and last sync results
#   repo-sync-helper.sh check            One-shot: sync all configured repos now
#   repo-sync-helper.sh logs [--tail N]  View sync logs
#   repo-sync-helper.sh config           Show/edit configuration
#   repo-sync-helper.sh help             Show this help
#
# Configuration:
#   ~/.config/aidevops/repos.json        Add "git_parent_dirs" array
#   AIDEVOPS_REPO_SYNC=false             Disable even if scheduler is installed
#   AIDEVOPS_REPO_SYNC_INTERVAL=1440     Minutes between syncs (default: 1440 = daily)
#
# Logs: ~/.aidevops/logs/repo-sync.log

set -euo pipefail

# Resolve symlinks to find real script location
_resolve_script_path() {
	local src="${BASH_SOURCE[0]}"
	while [[ -L "$src" ]]; do
		local dir
		dir="$(cd "$(dirname "$src")" && pwd)" || return 1
		src="$(readlink "$src")"
		[[ "$src" != /* ]] && src="$dir/$src"
	done
	cd "$(dirname "$src")" && pwd
}
SCRIPT_DIR="$(_resolve_script_path)" || exit
unset -f _resolve_script_path
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

# Configuration
readonly CONFIG_FILE="$HOME/.config/aidevops/repos.json"
readonly LOCK_DIR="$HOME/.aidevops/locks"
readonly LOCK_FILE="$LOCK_DIR/repo-sync.lock"
readonly LOG_FILE="$HOME/.aidevops/logs/repo-sync.log"
readonly STATE_FILE="$HOME/.aidevops/cache/repo-sync-state.json"
readonly CRON_MARKER="# aidevops-repo-sync"
readonly DEFAULT_INTERVAL=1440
readonly LAUNCHD_LABEL="com.aidevops.aidevops-repo-sync"
readonly LAUNCHD_DIR="$HOME/Library/LaunchAgents"
readonly LAUNCHD_PLIST="${LAUNCHD_DIR}/${LAUNCHD_LABEL}.plist"
readonly DEFAULT_PARENT_DIRS=("$HOME/Git")

#######################################
# Logging
#######################################
log() {
	local level="$1"
	shift
	local timestamp
	timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
	echo "[$timestamp] [$level] $*" >>"$LOG_FILE"
	return 0
}

log_info() {
	log "INFO" "$@"
	return 0
}
log_warn() {
	log "WARN" "$@"
	return 0
}
log_error() {
	log "ERROR" "$@"
	return 0
}

#######################################
# Ensure required directories exist
#######################################
ensure_dirs() {
	mkdir -p "$LOCK_DIR" "$HOME/.aidevops/logs" "$HOME/.aidevops/cache" 2>/dev/null || true
	return 0
}

#######################################
# Detect scheduler backend for current platform
# Returns: "launchd" on macOS, "cron" on Linux/other
#######################################
_get_scheduler_backend() {
	if [[ "$(uname)" == "Darwin" ]]; then
		echo "launchd"
	else
		echo "cron"
	fi
	return 0
}

#######################################
# Check if the repo-sync LaunchAgent is loaded
# Returns: 0 if loaded, 1 if not
#######################################
_launchd_is_loaded() {
	# Use a variable to avoid SIGPIPE (141) when grep -q exits early
	# under set -o pipefail (t1265)
	local output
	output=$(launchctl list 2>/dev/null) || true
	echo "$output" | grep -qF "$LAUNCHD_LABEL"
	return $?
}

#######################################
# Generate repo-sync LaunchAgent plist content
# Arguments:
#   $1 - script_path
#   $2 - interval_seconds
#   $3 - env_path
#######################################
_generate_plist() {
	local script_path="$1"
	local interval_seconds="$2"
	local env_path="$3"

	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LAUNCHD_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${script_path}</string>
		<string>check</string>
	</array>
	<key>StartInterval</key>
	<integer>${interval_seconds}</integer>
	<key>StandardOutPath</key>
	<string>${LOG_FILE}</string>
	<key>StandardErrorPath</key>
	<string>${LOG_FILE}</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>${env_path}</string>
	</dict>
	<key>RunAtLoad</key>
	<false/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
EOF
	return 0
}

#######################################
# Lock management (prevents concurrent syncs)
# Uses mkdir for atomic locking (POSIX-safe)
#######################################
acquire_lock() {
	local max_wait=30
	local waited=0

	while [[ $waited -lt $max_wait ]]; do
		if mkdir "$LOCK_FILE" 2>/dev/null; then
			echo $$ >"$LOCK_FILE/pid"
			return 0
		fi

		# Check for stale lock (dead PID)
		if [[ -f "$LOCK_FILE/pid" ]]; then
			local lock_pid
			lock_pid=$(cat "$LOCK_FILE/pid" 2>/dev/null || echo "")
			if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
				log_warn "Removing stale lock (PID $lock_pid dead)"
				rm -rf "$LOCK_FILE"
				continue
			fi
		fi

		# Safety net: remove locks older than 10 minutes
		if [[ -d "$LOCK_FILE" ]]; then
			local lock_age
			if [[ "$(uname)" == "Darwin" ]]; then
				lock_age=$(($(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || echo "0")))
			else
				lock_age=$(($(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo "0")))
			fi
			if [[ $lock_age -gt 600 ]]; then
				log_warn "Removing stale lock (age ${lock_age}s > 600s)"
				rm -rf "$LOCK_FILE"
				continue
			fi
		fi

		sleep 1
		waited=$((waited + 1))
	done

	log_error "Failed to acquire lock after ${max_wait}s"
	return 1
}

release_lock() {
	rm -rf "$LOCK_FILE"
	return 0
}

#######################################
# Read configured parent directories from repos.json
# Falls back to DEFAULT_PARENT_DIRS if not configured
# Outputs one directory per line
#######################################
get_parent_dirs() {
	if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
		local dirs
		dirs=$(jq -r '.git_parent_dirs[]? // empty' "$CONFIG_FILE" 2>/dev/null || true)
		if [[ -n "$dirs" ]]; then
			echo "$dirs"
			return 0
		fi
	fi
	# Fall back to defaults
	for dir in "${DEFAULT_PARENT_DIRS[@]}"; do
		echo "$dir"
	done
	return 0
}

#######################################
# Detect the default branch for a git repo
# Arguments:
#   $1 - repo path
# Returns: branch name (main/master/etc) or empty string on failure
#######################################
get_default_branch() {
	local repo_path="$1"

	# Try to get from remote HEAD reference
	local remote_head
	remote_head=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)
	if [[ -n "$remote_head" ]]; then
		echo "${remote_head##*/}"
		return 0
	fi

	# Fall back to checking common default branch names
	for branch in main master trunk develop; do
		if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
			echo "$branch"
			return 0
		fi
	done

	echo ""
	return 0
}

#######################################
# Check if a git repo's working tree is clean
# Arguments:
#   $1 - repo path
# Returns: 0 if clean, 1 if dirty
#######################################
is_working_tree_clean() {
	local repo_path="$1"
	git -C "$repo_path" diff --quiet 2>/dev/null &&
		git -C "$repo_path" diff --cached --quiet 2>/dev/null
	return $?
}

#######################################
# Sync a single git repo
# Arguments:
#   $1 - repo path
# Returns: 0 on success/skip, 1 on error
# Outputs: status line to stdout
#######################################
sync_repo() {
	local repo_path="$1"
	local repo_name
	repo_name=$(basename "$repo_path")

	# Must be a git repo with a remote
	if [[ ! -d "$repo_path/.git" ]]; then
		return 0
	fi

	# Must have at least one remote configured
	local remote
	remote=$(git -C "$repo_path" remote 2>/dev/null | head -1 || true)
	if [[ -z "$remote" ]]; then
		log_info "SKIP $repo_name: no remote configured"
		return 0
	fi

	# Get current branch
	local current_branch
	current_branch=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	if [[ -z "$current_branch" || "$current_branch" == "HEAD" ]]; then
		log_info "SKIP $repo_name: detached HEAD"
		return 0
	fi

	# Get default branch
	local default_branch
	default_branch=$(get_default_branch "$repo_path")
	if [[ -z "$default_branch" ]]; then
		log_info "SKIP $repo_name: cannot determine default branch"
		return 0
	fi

	# Only sync if on default branch
	if [[ "$current_branch" != "$default_branch" ]]; then
		log_info "SKIP $repo_name: on branch '$current_branch' (default: '$default_branch')"
		return 0
	fi

	# Only sync if working tree is clean
	if ! is_working_tree_clean "$repo_path"; then
		log_warn "SKIP $repo_name: working tree is dirty"
		return 0
	fi

	# Fetch and pull --ff-only
	log_info "SYNC $repo_name: fetching from $remote..."
	if ! git -C "$repo_path" fetch "$remote" "$default_branch" --quiet 2>>"$LOG_FILE"; then
		log_error "FAIL $repo_name: git fetch failed"
		return 1
	fi

	# Check if there are upstream changes
	local local_sha upstream_sha
	local_sha=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || true)
	upstream_sha=$(git -C "$repo_path" rev-parse "${remote}/${default_branch}" 2>/dev/null || true)

	if [[ "$local_sha" == "$upstream_sha" ]]; then
		log_info "OK $repo_name: already up to date"
		return 0
	fi

	# Pull with ff-only (safe: never creates merge commits)
	if git -C "$repo_path" pull --ff-only "$remote" "$default_branch" --quiet 2>>"$LOG_FILE"; then
		local new_sha
		new_sha=$(git -C "$repo_path" rev-parse --short HEAD 2>/dev/null || true)
		log_info "PULLED $repo_name: updated to $new_sha"
		return 0
	else
		log_error "FAIL $repo_name: git pull --ff-only failed (diverged?)"
		return 1
	fi
}

#######################################
# Update state file after a sync run
# Arguments:
#   $1 - synced count
#   $2 - skipped count
#   $3 - failed count
#######################################
update_state() {
	local synced="$1"
	local skipped="$2"
	local failed="$3"
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	local tmp_state
	tmp_state=$(mktemp)
	trap 'rm -f "${tmp_state:-}"' RETURN

	if [[ -f "$STATE_FILE" ]]; then
		jq --arg ts "$timestamp" \
			--argjson synced "$synced" \
			--argjson skipped "$skipped" \
			--argjson failed "$failed" \
			'. + {
				last_sync: $ts,
				last_synced: $synced,
				last_skipped: $skipped,
				last_failed: $failed,
				total_synced: ((.total_synced // 0) + $synced),
				total_failed: ((.total_failed // 0) + $failed)
			}' "$STATE_FILE" >"$tmp_state" 2>/dev/null && mv "$tmp_state" "$STATE_FILE"
	else
		jq -n --arg ts "$timestamp" \
			--argjson synced "$synced" \
			--argjson skipped "$skipped" \
			--argjson failed "$failed" \
			'{
				last_sync: $ts,
				last_synced: $synced,
				last_skipped: $skipped,
				last_failed: $failed,
				total_synced: $synced,
				total_failed: $failed
			}' >"$STATE_FILE"
	fi
	return 0
}

#######################################
# One-shot sync of all configured repos
# This is what the scheduler calls
#######################################
cmd_check() {
	ensure_dirs

	# Respect env var override
	if [[ "${AIDEVOPS_REPO_SYNC:-}" == "false" ]]; then
		log_info "Repo sync disabled via AIDEVOPS_REPO_SYNC=false"
		return 0
	fi

	# Acquire lock (prevents concurrent syncs)
	if ! acquire_lock; then
		log_warn "Could not acquire lock, skipping sync"
		return 0
	fi
	trap 'release_lock' EXIT

	local synced=0
	local skipped=0
	local failed=0

	log_info "Starting repo sync..."

	# Read parent directories
	local parent_dirs=()
	while IFS= read -r dir; do
		# Expand ~ in paths
		dir="${dir/#\~/$HOME}"
		parent_dirs+=("$dir")
	done < <(get_parent_dirs)

	if [[ ${#parent_dirs[@]} -eq 0 ]]; then
		log_warn "No parent directories configured. Add 'git_parent_dirs' to $CONFIG_FILE"
		return 0
	fi

	for parent_dir in "${parent_dirs[@]}"; do
		if [[ ! -d "$parent_dir" ]]; then
			log_warn "Parent directory not found: $parent_dir"
			continue
		fi

		log_info "Scanning: $parent_dir"

		# Iterate over immediate subdirectories only (not recursive)
		# Worktrees are excluded — only the main checkout matters
		while IFS= read -r -d '' repo_dir; do
			# Skip if not a git repo
			[[ -d "$repo_dir/.git" ]] || continue

			# Skip git worktrees (they have .git as a file, not a directory)
			[[ -f "$repo_dir/.git" ]] && continue

			if sync_repo "$repo_dir"; then
				# Determine if it was pulled or skipped based on log
				local last_log
				last_log=$(tail -1 "$LOG_FILE" 2>/dev/null || true)
				if [[ "$last_log" == *"PULLED"* ]]; then
					synced=$((synced + 1))
				elif [[ "$last_log" == *"OK"* ]]; then
					: # already up to date — not counted as synced or skipped
				else
					skipped=$((skipped + 1))
				fi
			else
				failed=$((failed + 1))
			fi
		done < <(find "$parent_dir" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
	done

	log_info "Sync complete: ${synced} pulled, ${skipped} skipped, ${failed} failed"
	update_state "$synced" "$skipped" "$failed"

	if [[ $failed -gt 0 ]]; then
		return 1
	fi
	return 0
}

#######################################
# Enable repo-sync scheduler (platform-aware)
# On macOS: installs LaunchAgent plist (daily)
# On Linux: installs crontab entry
#######################################
cmd_enable() {
	ensure_dirs

	local interval="${AIDEVOPS_REPO_SYNC_INTERVAL:-$DEFAULT_INTERVAL}"
	local script_path="$HOME/.aidevops/agents/scripts/repo-sync-helper.sh"

	# Verify the script exists at the deployed location
	if [[ ! -x "$script_path" ]]; then
		# Fall back to repo location
		local install_dir="$HOME/Git/aidevops"
		script_path="$install_dir/.agents/scripts/repo-sync-helper.sh"
		if [[ ! -x "$script_path" ]]; then
			print_error "repo-sync-helper.sh not found"
			return 1
		fi
	fi

	local backend
	backend="$(_get_scheduler_backend)"

	if [[ "$backend" == "launchd" ]]; then
		local interval_seconds=$((interval * 60))

		mkdir -p "$LAUNCHD_DIR"

		# Create named symlink so macOS System Settings shows "aidevops-repo-sync"
		local bin_dir="$HOME/.aidevops/bin"
		mkdir -p "$bin_dir"
		local display_link="$bin_dir/aidevops-repo-sync"
		ln -sf "$script_path" "$display_link"

		# Generate plist content and compare to existing (t1265)
		local new_content
		new_content=$(_generate_plist "$display_link" "$interval_seconds" "${PATH}")

		# Skip if already loaded with identical config (avoids macOS notification)
		if _launchd_is_loaded && [[ -f "$LAUNCHD_PLIST" ]]; then
			local existing_content
			existing_content=$(cat "$LAUNCHD_PLIST" 2>/dev/null) || existing_content=""
			if [[ "$existing_content" == "$new_content" ]]; then
				print_info "Repo sync LaunchAgent already installed with identical config ($LAUNCHD_LABEL)"
				return 0
			fi
			print_info "Repo sync LaunchAgent already loaded ($LAUNCHD_LABEL)"
			return 0
		fi

		echo "$new_content" >"$LAUNCHD_PLIST"

		if launchctl load -w "$LAUNCHD_PLIST" 2>/dev/null; then
			print_success "Repo sync enabled (every ${interval} minutes)"
			echo ""
			echo "  Scheduler: launchd (macOS LaunchAgent)"
			echo "  Label:     $LAUNCHD_LABEL"
			echo "  Plist:     $LAUNCHD_PLIST"
			echo "  Script:    $script_path"
			echo "  Logs:      $LOG_FILE"
			echo ""
			echo "  Disable with: aidevops repo-sync disable"
			echo "  Sync now:     aidevops repo-sync check"
		else
			print_error "Failed to load LaunchAgent: $LAUNCHD_LABEL"
			return 1
		fi
		return 0
	fi

	# Linux: cron backend (daily at 3am)
	local cron_expr="0 3 * * *"
	local cron_line="$cron_expr $script_path check >> $LOG_FILE 2>&1 $CRON_MARKER"

	local temp_cron
	temp_cron=$(mktemp)
	trap 'rm -f "${temp_cron:-}"' RETURN

	crontab -l 2>/dev/null | grep -v "$CRON_MARKER" >"$temp_cron" || true
	echo "$cron_line" >>"$temp_cron"
	crontab "$temp_cron"
	rm -f "$temp_cron"

	print_success "Repo sync enabled (daily at 3am)"
	echo ""
	echo "  Schedule: $cron_expr"
	echo "  Script:   $script_path"
	echo "  Logs:     $LOG_FILE"
	echo ""
	echo "  Disable with: aidevops repo-sync disable"
	echo "  Sync now:     aidevops repo-sync check"
	return 0
}

#######################################
# Disable repo-sync scheduler (platform-aware)
#######################################
cmd_disable() {
	local backend
	backend="$(_get_scheduler_backend)"

	if [[ "$backend" == "launchd" ]]; then
		local had_entry=false

		if _launchd_is_loaded; then
			had_entry=true
			launchctl unload -w "$LAUNCHD_PLIST" 2>/dev/null || true
		fi

		if [[ -f "$LAUNCHD_PLIST" ]]; then
			had_entry=true
			rm -f "$LAUNCHD_PLIST"
		fi

		# Also remove any lingering cron entry
		if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
			local temp_cron
			temp_cron=$(mktemp)
			crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" >"$temp_cron" || true
			crontab "$temp_cron"
			rm -f "$temp_cron"
			had_entry=true
		fi

		if [[ "$had_entry" == "true" ]]; then
			print_success "Repo sync disabled"
		else
			print_info "Repo sync was not enabled"
		fi
		return 0
	fi

	# Linux: cron backend
	local temp_cron
	temp_cron=$(mktemp)
	trap 'rm -f "${temp_cron:-}"' RETURN

	local had_entry=false
	if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
		had_entry=true
	fi

	crontab -l 2>/dev/null | grep -v "$CRON_MARKER" >"$temp_cron" || true
	crontab "$temp_cron"
	rm -f "$temp_cron"

	if [[ "$had_entry" == "true" ]]; then
		print_success "Repo sync disabled"
	else
		print_info "Repo sync was not enabled"
	fi
	return 0
}

#######################################
# Show status
#######################################
cmd_status() {
	ensure_dirs

	local backend
	backend="$(_get_scheduler_backend)"

	echo ""
	echo -e "${BOLD:-}Repo Sync Status${NC}"
	echo "-----------------"
	echo ""

	if [[ "$backend" == "launchd" ]]; then
		if _launchd_is_loaded; then
			local launchctl_info pid exit_code
			launchctl_info=$(launchctl list 2>/dev/null | grep -F "$LAUNCHD_LABEL" || true)
			pid=$(echo "$launchctl_info" | awk '{print $1}')
			exit_code=$(echo "$launchctl_info" | awk '{print $2}')
			echo -e "  Scheduler: launchd (macOS LaunchAgent)"
			echo -e "  Status:    ${GREEN}loaded${NC}"
			echo "  Label:     $LAUNCHD_LABEL"
			echo "  PID:       ${pid:--}"
			echo "  Last exit: ${exit_code:--}"
			if [[ -f "$LAUNCHD_PLIST" ]]; then
				local interval
				interval=$(grep -A1 'StartInterval' "$LAUNCHD_PLIST" 2>/dev/null | grep integer | grep -oE '[0-9]+' || true)
				if [[ -n "$interval" ]]; then
					echo "  Interval:  every ${interval}s ($((interval / 60)) min)"
				fi
				echo "  Plist:     $LAUNCHD_PLIST"
			fi
		else
			echo -e "  Scheduler: launchd (macOS LaunchAgent)"
			echo -e "  Status:    ${YELLOW}not loaded${NC}"
		fi
	else
		if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
			local cron_entry
			cron_entry=$(crontab -l 2>/dev/null | grep "$CRON_MARKER")
			echo -e "  Scheduler: cron"
			echo -e "  Status:    ${GREEN}enabled${NC}"
			echo "  Schedule:  $(echo "$cron_entry" | awk '{print $1, $2, $3, $4, $5}')"
		else
			echo -e "  Scheduler: cron"
			echo -e "  Status:    ${YELLOW}disabled${NC}"
		fi
	fi

	# Show configured parent directories
	echo ""
	echo "  Configured parent directories:"
	while IFS= read -r dir; do
		dir="${dir/#\~/$HOME}"
		if [[ -d "$dir" ]]; then
			local count
			count=$(find "$dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
			echo "    $dir ($count subdirs)"
		else
			echo -e "    ${YELLOW}$dir (not found)${NC}"
		fi
	done < <(get_parent_dirs)

	# Show state file info
	if [[ -f "$STATE_FILE" ]] && command -v jq &>/dev/null; then
		local last_sync last_synced last_skipped last_failed total_synced total_failed
		last_sync=$(jq -r '.last_sync // "never"' "$STATE_FILE" 2>/dev/null)
		last_synced=$(jq -r '.last_synced // 0' "$STATE_FILE" 2>/dev/null)
		last_skipped=$(jq -r '.last_skipped // 0' "$STATE_FILE" 2>/dev/null)
		last_failed=$(jq -r '.last_failed // 0' "$STATE_FILE" 2>/dev/null)
		total_synced=$(jq -r '.total_synced // 0' "$STATE_FILE" 2>/dev/null)
		total_failed=$(jq -r '.total_failed // 0' "$STATE_FILE" 2>/dev/null)

		echo ""
		echo "  Last sync:    $last_sync"
		echo "  Last result:  ${last_synced} pulled, ${last_skipped} skipped, ${last_failed} failed"
		echo "  Lifetime:     ${total_synced} total pulled, ${total_failed} total failed"
	fi

	# Check env var overrides
	if [[ "${AIDEVOPS_REPO_SYNC:-}" == "false" ]]; then
		echo ""
		echo -e "  ${YELLOW}Note: AIDEVOPS_REPO_SYNC=false is set (overrides scheduler)${NC}"
	fi

	echo ""
	return 0
}

#######################################
# Show or edit configuration
#######################################
cmd_config() {
	echo ""
	echo "Repo Sync Configuration"
	echo "-----------------------"
	echo ""
	echo "Config file: $CONFIG_FILE"
	echo ""

	if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
		local dirs
		dirs=$(jq -r '.git_parent_dirs[]? // empty' "$CONFIG_FILE" 2>/dev/null || true)
		if [[ -n "$dirs" ]]; then
			echo "Configured parent directories:"
			while IFS= read -r dir; do
				echo "  $dir"
			done <<<"$dirs"
		else
			echo "No parent directories configured (using default: ~/Git)"
		fi
	else
		echo "No config file found (using default: ~/Git)"
	fi

	echo ""
	echo "To configure parent directories, add to $CONFIG_FILE:"
	echo ""
	echo '  {"git_parent_dirs": ["~/Git", "~/Projects"]}'
	echo ""
	echo "Or use jq to update:"
	echo "  jq '.git_parent_dirs = [\"~/Git\", \"~/Projects\"]' $CONFIG_FILE > /tmp/repos.json && mv /tmp/repos.json $CONFIG_FILE"
	echo ""
	return 0
}

#######################################
# View logs
#######################################
cmd_logs() {
	local tail_lines=50

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--tail | -n)
			[[ $# -lt 2 ]] && {
				print_error "--tail requires a value"
				return 1
			}
			tail_lines="$2"
			shift 2
			;;
		--follow | -f)
			tail -f "$LOG_FILE" 2>/dev/null || print_info "No log file yet"
			return 0
			;;
		*) shift ;;
		esac
	done

	if [[ -f "$LOG_FILE" ]]; then
		tail -n "$tail_lines" "$LOG_FILE"
	else
		print_info "No log file yet (repo-sync hasn't run)"
	fi
	return 0
}

#######################################
# Help
#######################################
cmd_help() {
	cat <<'EOF'
repo-sync-helper.sh - Daily git pull for repos in configured parent directories

USAGE:
    repo-sync-helper.sh <command> [options]
    aidevops repo-sync <command> [options]

COMMANDS:
    enable              Install daily scheduler (launchd on macOS, cron on Linux)
    disable             Remove scheduler
    status              Show current state and last sync results
    check               One-shot: sync all configured repos now
    config              Show configuration and how to edit it
    logs [--tail N]     View sync logs (default: last 50 lines)
    logs --follow       Follow log output in real-time
    help                Show this help

ENVIRONMENT:
    AIDEVOPS_REPO_SYNC=false             Disable even if scheduler is installed
    AIDEVOPS_REPO_SYNC_INTERVAL=1440     Minutes between syncs (default: 1440 = daily)

CONFIGURATION:
    Add "git_parent_dirs" array to ~/.config/aidevops/repos.json:
      {"git_parent_dirs": ["~/Git", "~/Projects"]}
    Default: ~/Git

SAFETY:
    - Only runs git pull --ff-only (never creates merge commits)
    - Skips repos with dirty working trees (uncommitted changes)
    - Skips repos not on their default branch (main/master)
    - Skips repos with no remote configured
    - Logs failures without stopping (other repos still sync)
    - Worktrees are ignored — only main checkouts are synced

SCHEDULER BACKENDS:
    macOS:  launchd LaunchAgent (~/Library/LaunchAgents/com.aidevops.aidevops-repo-sync.plist)
            - Runs daily (every 1440 minutes by default)
    Linux:  cron (daily at 3am, crontab entry with # aidevops-repo-sync marker)

HOW IT WORKS:
    1. Scheduler runs 'repo-sync-helper.sh check' daily
    2. Reads git_parent_dirs from ~/.config/aidevops/repos.json
    3. Scans each parent directory for git repos (maxdepth 1)
    4. For each repo:
       a. Skips if no remote, detached HEAD, or not on default branch
       b. Skips if working tree is dirty
       c. Fetches from remote
       d. Pulls with --ff-only if upstream has new commits
    5. Logs results (pulled/skipped/failed) to ~/.aidevops/logs/repo-sync.log

LOGS:
    ~/.aidevops/logs/repo-sync.log

EOF
	return 0
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	enable) cmd_enable "$@" ;;
	disable) cmd_disable "$@" ;;
	status) cmd_status "$@" ;;
	check) cmd_check "$@" ;;
	config) cmd_config "$@" ;;
	logs) cmd_logs "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return 0
}

main "$@"
