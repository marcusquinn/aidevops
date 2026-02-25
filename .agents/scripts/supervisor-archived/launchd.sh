#!/usr/bin/env bash
# launchd.sh - macOS LaunchAgent backend for scheduler abstraction
#
# Provides platform-aware scheduling: launchd on macOS, cron on Linux.
# Called by cron.sh when running on macOS.
#
# Three LaunchAgent plists managed:
#   com.aidevops.aidevops-supervisor-pulse   - StartInterval:120 (every 2 min)
#   com.aidevops.aidevops-auto-update        - StartInterval:600 (every 10 min)
#   com.aidevops.aidevops-todo-watcher       - WatchPaths (replaces fswatch)
#
# Labels are prefixed with "aidevops-" so they appear grouped in
# macOS System Settings > Login Items & Extensions.
#
# Migration: auto-migrates existing cron entries to launchd on macOS.

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
# LaunchAgent directory (user-level, no sudo required)
#######################################
_launchd_dir() {
	echo "$HOME/Library/LaunchAgents"
	return 0
}

#######################################
# Plist path for a given label
# Arguments:
#   $1 - label (e.g., com.aidevops.aidevops-supervisor-pulse)
#######################################
_plist_path() {
	local label="$1"
	echo "$(_launchd_dir)/${label}.plist"
	return 0
}

#######################################
# Check if a LaunchAgent is loaded (running or waiting)
# Arguments:
#   $1 - label
# Returns: 0 if loaded, 1 if not
#######################################
_launchd_is_loaded() {
	local label="$1"
	# Use a variable to avoid SIGPIPE (141) when grep -q exits early
	# under set -o pipefail (t1265)
	local output
	output=$(launchctl list 2>/dev/null) || true
	echo "$output" | grep -qF "$label"
	return $?
}

#######################################
# Check if generated plist content matches existing file on disk
# Used to avoid unnecessary plist rewrites that trigger macOS
# "Background Items" notifications (t1265)
# Arguments:
#   $1 - plist_path (existing file)
#   $2 - new_content (generated plist content)
# Returns: 0 if content matches (skip write), 1 if different (needs write)
#######################################
_plist_unchanged() {
	local plist_path="$1"
	local new_content="$2"

	if [[ ! -f "$plist_path" ]]; then
		return 1
	fi

	local existing_content
	existing_content=$(cat "$plist_path" 2>/dev/null) || return 1

	if [[ "$existing_content" == "$new_content" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Load a plist into launchd
# Arguments:
#   $1 - plist path
#######################################
_launchd_load() {
	local plist_path="$1"
	launchctl load -w "$plist_path" 2>/dev/null
	return $?
}

#######################################
# Unload a plist from launchd
# Arguments:
#   $1 - plist path
#######################################
_launchd_unload() {
	local plist_path="$1"
	launchctl unload -w "$plist_path" 2>/dev/null
	return $?
}

#######################################
# Generate supervisor-pulse plist
# Runs supervisor-helper.sh pulse every N seconds
# Arguments:
#   $1 - script_path (absolute path to supervisor-helper.sh)
#   $2 - interval_seconds (default: 120)
#   $3 - log_path
#   $4 - batch_arg (optional, e.g., "--batch my-batch")
#   $5 - env_path (PATH value for launchd environment)
#   $6 - gh_token (deprecated — token now resolved at runtime by pulse.sh)
#######################################
_generate_supervisor_pulse_plist() {
	local script_path="$1"
	local interval_seconds="${2:-120}"
	local log_path="$3"
	local batch_arg="${4:-}"
	local env_path="${5:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
	local gh_token="${6:-}"

	local label="com.aidevops.aidevops-supervisor-pulse"

	# Build ProgramArguments array
	local prog_args
	prog_args="<string>${script_path}</string>
		<string>pulse</string>"
	if [[ -n "$batch_arg" ]]; then
		# batch_arg is "--batch id" — split into two strings
		local batch_id
		batch_id="${batch_arg#--batch }"
		prog_args="${prog_args}
		<string>--batch</string>
		<string>${batch_id}</string>"
	fi

	# Build EnvironmentVariables dict
	local env_dict
	env_dict="<key>PATH</key>
		<string>${env_path}</string>
		<key>SUPERVISOR_PULSE_LOCK_TIMEOUT</key>
		<string>1800</string>
		<key>SUPERVISOR_AI_TIMEOUT</key>
		<string>600</string>"
	# SUPERVISOR_PULSE_LOCK_TIMEOUT=1800s (30 min): prevents concurrent pulses when
	# Phase 14 AI reasoning runs long (108KB+ context can take 6+ min). The default
	# 600s was shorter than the total pulse duration, causing concurrent pulses that
	# interfered with each other via Phase 4e orphan killing (t1301).
	# SUPERVISOR_AI_TIMEOUT=600s (10 min): gives the AI CLI more time to respond to
	# large context prompts before portable_timeout fires (t1301).
	if [[ -n "$gh_token" ]]; then
		env_dict="${env_dict}
		<key>GH_TOKEN</key>
		<string>${gh_token}</string>"
	fi

	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${label}</string>
	<key>ProgramArguments</key>
	<array>
		${prog_args}
	</array>
	<key>StartInterval</key>
	<integer>${interval_seconds}</integer>
	<key>StandardOutPath</key>
	<string>${log_path}</string>
	<key>StandardErrorPath</key>
	<string>${log_path}</string>
	<key>EnvironmentVariables</key>
	<dict>
		${env_dict}
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
# Generate auto-update plist
# Runs auto-update-helper.sh check every N seconds
# Arguments:
#   $1 - script_path (absolute path to auto-update-helper.sh)
#   $2 - interval_seconds (default: 600)
#   $3 - log_path
#   $4 - env_path
#######################################
_generate_auto_update_plist() {
	local script_path="$1"
	local interval_seconds="${2:-600}"
	local log_path="$3"
	local env_path="${4:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"

	local label="com.aidevops.aidevops-auto-update"

	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${script_path}</string>
		<string>check</string>
	</array>
	<key>StartInterval</key>
	<integer>${interval_seconds}</integer>
	<key>StandardOutPath</key>
	<string>${log_path}</string>
	<key>StandardErrorPath</key>
	<string>${log_path}</string>
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
# Generate todo-watcher plist
# Uses WatchPaths to trigger pulse on TODO.md changes
# Replaces fswatch dependency for macOS
# Arguments:
#   $1 - script_path (absolute path to supervisor-helper.sh)
#   $2 - todo_path (absolute path to TODO.md)
#   $3 - repo_path (absolute path to repo)
#   $4 - log_path
#   $5 - env_path
#######################################
_generate_todo_watcher_plist() {
	local script_path="$1"
	local todo_path="$2"
	local repo_path="$3"
	local log_path="$4"
	local env_path="${5:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"

	local label="com.aidevops.aidevops-todo-watcher"

	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${script_path}</string>
		<string>auto-pickup</string>
		<string>--repo</string>
		<string>${repo_path}</string>
	</array>
	<key>WatchPaths</key>
	<array>
		<string>${todo_path}</string>
	</array>
	<key>StandardOutPath</key>
	<string>${log_path}</string>
	<key>StandardErrorPath</key>
	<string>${log_path}</string>
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
# Install supervisor-pulse LaunchAgent on macOS
# Arguments:
#   $1 - script_path
#   $2 - interval_seconds
#   $3 - log_path
#   $4 - batch_arg (optional)
#######################################
launchd_install_supervisor_pulse() {
	local script_path="$1"
	local interval_seconds="${2:-120}"
	local log_path="$3"
	local batch_arg="${4:-}"

	local label="com.aidevops.aidevops-supervisor-pulse"
	local plist_path
	plist_path="$(_plist_path "$label")"
	local launchd_dir
	launchd_dir="$(_launchd_dir)"

	mkdir -p "$launchd_dir"

	# Migrate from old label if present (t1260)
	local old_label="com.aidevops.supervisor-pulse"
	local old_plist
	old_plist="$(_plist_path "$old_label")"
	if _launchd_is_loaded "$old_label"; then
		_launchd_unload "$old_plist" || true
		log_info "Unloaded old LaunchAgent: $old_label"
	fi
	rm -f "$old_plist"

	# Detect PATH for launchd environment
	# GH_TOKEN is resolved at runtime by the pulse script (not baked into plist)
	local env_path="${PATH}"

	# Create named symlink so macOS System Settings shows "aidevops-supervisor-pulse"
	# instead of the raw script name (t1260)
	local bin_dir="$HOME/.aidevops/bin"
	mkdir -p "$bin_dir"
	local display_link="$bin_dir/aidevops-supervisor-pulse"
	ln -sf "$script_path" "$display_link"

	# Generate plist content
	local new_content
	new_content=$(_generate_supervisor_pulse_plist \
		"$display_link" \
		"$interval_seconds" \
		"$log_path" \
		"$batch_arg" \
		"$env_path" \
		"")

	# Skip if already loaded with identical config (t1265 — avoids macOS notification)
	if _launchd_is_loaded "$label" && _plist_unchanged "$plist_path" "$new_content"; then
		log_info "LaunchAgent $label already installed with identical config — skipping"
		return 0
	fi

	# Check if loaded but config changed
	if _launchd_is_loaded "$label"; then
		log_warn "LaunchAgent $label already loaded. Unload first to change settings."
		launchd_status_supervisor_pulse
		return 0
	fi

	# Write plist and load into launchd
	echo "$new_content" >"$plist_path"

	if _launchd_load "$plist_path"; then
		log_success "Installed LaunchAgent: $label (every ${interval_seconds}s)"
		log_info "Plist: $plist_path"
		log_info "Log:   $log_path"
	else
		log_error "Failed to load LaunchAgent: $label"
		return 1
	fi

	return 0
}

#######################################
# Uninstall supervisor-pulse LaunchAgent on macOS
#######################################
launchd_uninstall_supervisor_pulse() {
	local label="com.aidevops.aidevops-supervisor-pulse"
	local plist_path
	plist_path="$(_plist_path "$label")"

	if ! _launchd_is_loaded "$label" && [[ ! -f "$plist_path" ]]; then
		log_info "LaunchAgent $label not installed"
		return 0
	fi

	if _launchd_is_loaded "$label"; then
		_launchd_unload "$plist_path" || true
	fi

	rm -f "$plist_path"
	log_success "Uninstalled LaunchAgent: $label"
	return 0
}

#######################################
# Show status of supervisor-pulse LaunchAgent
#######################################
launchd_status_supervisor_pulse() {
	local label="com.aidevops.aidevops-supervisor-pulse"
	local plist_path
	plist_path="$(_plist_path "$label")"

	echo -e "${BOLD}=== Supervisor LaunchAgent Status ===${NC}"

	if _launchd_is_loaded "$label"; then
		local launchctl_info
		launchctl_info=$(launchctl list 2>/dev/null | grep -F "$label" || true)
		local pid interval exit_code
		pid=$(echo "$launchctl_info" | awk '{print $1}')
		exit_code=$(echo "$launchctl_info" | awk '{print $2}')
		echo -e "  Status:   ${GREEN}loaded${NC}"
		echo "  Label:    $label"
		echo "  PID:      ${pid:--}"
		echo "  Last exit: ${exit_code:--}"
		if [[ -f "$plist_path" ]]; then
			echo "  Plist:    $plist_path"
			# Extract interval from plist
			interval=$(grep -A1 'StartInterval' "$plist_path" 2>/dev/null | grep integer | grep -oE '[0-9]+' || true)
			if [[ -n "$interval" ]]; then
				echo "  Interval: every ${interval}s"
			fi
		fi
	else
		echo -e "  Status:   ${YELLOW}not loaded${NC}"
		if [[ -f "$plist_path" ]]; then
			echo "  Plist:    $plist_path (exists but not loaded)"
			echo "  Load:     launchctl load -w $plist_path"
		else
			echo "  Install:  supervisor-helper.sh cron install [--interval N] [--batch id]"
		fi
	fi

	return 0
}

#######################################
# Install auto-update LaunchAgent on macOS
# Arguments:
#   $1 - script_path (auto-update-helper.sh path)
#   $2 - interval_seconds (default: 600)
#   $3 - log_path
#######################################
launchd_install_auto_update() {
	local script_path="$1"
	local interval_seconds="${2:-600}"
	local log_path="$3"

	local label="com.aidevops.aidevops-auto-update"
	local plist_path
	plist_path="$(_plist_path "$label")"
	local launchd_dir
	launchd_dir="$(_launchd_dir)"

	mkdir -p "$launchd_dir"

	# Migrate from old label if present (t1260)
	local old_label="com.aidevops.auto-update"
	local old_plist
	old_plist="$(_plist_path "$old_label")"
	if _launchd_is_loaded "$old_label"; then
		_launchd_unload "$old_plist" || true
		log_info "Unloaded old LaunchAgent: $old_label"
	fi
	rm -f "$old_plist"

	local env_path="${PATH}"

	# Create named symlink so macOS System Settings shows "aidevops-auto-update"
	# instead of the raw script name (t1260)
	local bin_dir="$HOME/.aidevops/bin"
	mkdir -p "$bin_dir"
	local display_link="$bin_dir/aidevops-auto-update"
	ln -sf "$script_path" "$display_link"

	# Generate plist content
	local new_content
	new_content=$(_generate_auto_update_plist \
		"$display_link" \
		"$interval_seconds" \
		"$log_path" \
		"$env_path")

	# Skip if already loaded with identical config (t1265 — avoids macOS notification)
	if _launchd_is_loaded "$label" && _plist_unchanged "$plist_path" "$new_content"; then
		log_info "LaunchAgent $label already installed with identical config — skipping"
		return 0
	fi

	# Check if loaded but config changed
	if _launchd_is_loaded "$label"; then
		log_warn "LaunchAgent $label already loaded. Unload first to change settings."
		return 0
	fi

	# Write plist and load into launchd
	echo "$new_content" >"$plist_path"

	if _launchd_load "$plist_path"; then
		log_success "Installed LaunchAgent: $label (every ${interval_seconds}s)"
		log_info "Plist: $plist_path"
		log_info "Log:   $log_path"
	else
		log_error "Failed to load LaunchAgent: $label"
		return 1
	fi

	return 0
}

#######################################
# Uninstall auto-update LaunchAgent on macOS
#######################################
launchd_uninstall_auto_update() {
	local label="com.aidevops.aidevops-auto-update"
	local plist_path
	plist_path="$(_plist_path "$label")"

	if ! _launchd_is_loaded "$label" && [[ ! -f "$plist_path" ]]; then
		log_info "LaunchAgent $label not installed"
		return 0
	fi

	if _launchd_is_loaded "$label"; then
		_launchd_unload "$plist_path" || true
	fi

	rm -f "$plist_path"
	log_success "Uninstalled LaunchAgent: $label"
	return 0
}

#######################################
# Show status of auto-update LaunchAgent
#######################################
launchd_status_auto_update() {
	local label="com.aidevops.aidevops-auto-update"
	local plist_path
	plist_path="$(_plist_path "$label")"

	if _launchd_is_loaded "$label"; then
		local launchctl_info
		launchctl_info=$(launchctl list 2>/dev/null | grep -F "$label" || true)
		local pid exit_code interval
		pid=$(echo "$launchctl_info" | awk '{print $1}')
		exit_code=$(echo "$launchctl_info" | awk '{print $2}')
		echo -e "  LaunchAgent: ${GREEN}loaded${NC} ($label)"
		echo "  PID:         ${pid:--}"
		echo "  Last exit:   ${exit_code:--}"
		if [[ -f "$plist_path" ]]; then
			interval=$(grep -A1 'StartInterval' "$plist_path" 2>/dev/null | grep integer | grep -oE '[0-9]+' || true)
			if [[ -n "$interval" ]]; then
				echo "  Interval:    every ${interval}s"
			fi
			echo "  Plist:       $plist_path"
		fi
	else
		echo -e "  LaunchAgent: ${YELLOW}not loaded${NC} ($label)"
		if [[ -f "$plist_path" ]]; then
			echo "  Plist:       $plist_path (exists but not loaded)"
		fi
	fi

	return 0
}

#######################################
# Install todo-watcher LaunchAgent on macOS
# Uses WatchPaths to trigger auto-pickup on TODO.md changes
# Arguments:
#   $1 - script_path (supervisor-helper.sh path)
#   $2 - todo_path (absolute path to TODO.md)
#   $3 - repo_path
#   $4 - log_path
#######################################
launchd_install_todo_watcher() {
	local script_path="$1"
	local todo_path="$2"
	local repo_path="$3"
	local log_path="$4"

	local label="com.aidevops.aidevops-todo-watcher"
	local plist_path
	plist_path="$(_plist_path "$label")"
	local launchd_dir
	launchd_dir="$(_launchd_dir)"

	mkdir -p "$launchd_dir"

	# Migrate from old label if present (t1260)
	local old_label="com.aidevops.todo-watcher"
	local old_plist
	old_plist="$(_plist_path "$old_label")"
	if _launchd_is_loaded "$old_label"; then
		_launchd_unload "$old_plist" || true
		log_info "Unloaded old LaunchAgent: $old_label"
	fi
	rm -f "$old_plist"

	local env_path="${PATH}"

	# Create named symlink so macOS System Settings shows "aidevops-todo-watcher"
	# instead of the raw script name (t1260)
	local bin_dir="$HOME/.aidevops/bin"
	mkdir -p "$bin_dir"
	local display_link="$bin_dir/aidevops-todo-watcher"
	ln -sf "$script_path" "$display_link"

	# Generate plist content
	local new_content
	new_content=$(_generate_todo_watcher_plist \
		"$display_link" \
		"$todo_path" \
		"$repo_path" \
		"$log_path" \
		"$env_path")

	# Skip if already loaded with identical config (t1265 — avoids macOS notification)
	if _launchd_is_loaded "$label" && _plist_unchanged "$plist_path" "$new_content"; then
		log_info "LaunchAgent $label already installed with identical config — skipping"
		return 0
	fi

	# Check if loaded but config changed
	if _launchd_is_loaded "$label"; then
		log_warn "LaunchAgent $label already loaded."
		return 0
	fi

	# Write plist and load into launchd
	echo "$new_content" >"$plist_path"

	if _launchd_load "$plist_path"; then
		log_success "Installed LaunchAgent: $label (WatchPaths: $todo_path)"
		log_info "Plist: $plist_path"
		log_info "Log:   $log_path"
	else
		log_error "Failed to load LaunchAgent: $label"
		return 1
	fi

	return 0
}

#######################################
# Uninstall todo-watcher LaunchAgent on macOS
#######################################
launchd_uninstall_todo_watcher() {
	local label="com.aidevops.aidevops-todo-watcher"
	local plist_path
	plist_path="$(_plist_path "$label")"

	if ! _launchd_is_loaded "$label" && [[ ! -f "$plist_path" ]]; then
		log_info "LaunchAgent $label not installed"
		return 0
	fi

	if _launchd_is_loaded "$label"; then
		_launchd_unload "$plist_path" || true
	fi

	rm -f "$plist_path"
	log_success "Uninstalled LaunchAgent: $label"
	return 0
}

#######################################
# Migrate existing macOS cron entries to launchd
# Detects cron entries with aidevops markers and migrates them.
# Called automatically on macOS when cron install or auto-update enable is run.
# Arguments:
#   $1 - type: "supervisor-pulse" | "auto-update"
#   $2 - script_path
#   $3 - log_path
#   $4 - interval_seconds (optional)
#   $5 - batch_arg (optional, supervisor-pulse only)
#######################################
launchd_migrate_from_cron() {
	local type="$1"
	local script_path="$2"
	local log_path="$3"
	local interval_seconds="${4:-}"
	local batch_arg="${5:-}"

	local cron_marker=""
	case "$type" in
	supervisor-pulse)
		cron_marker="# aidevops-supervisor-pulse"
		;;
	auto-update)
		cron_marker="# aidevops-auto-update"
		;;
	*)
		log_error "launchd_migrate_from_cron: unknown type '$type'"
		return 1
		;;
	esac

	# Check if cron entry exists
	if ! crontab -l 2>/dev/null | grep -qF "$cron_marker"; then
		return 0
	fi

	log_info "Migrating $type from cron to launchd..."

	# Extract interval from existing cron entry if not provided
	if [[ -z "$interval_seconds" ]]; then
		local cron_line
		cron_line=$(crontab -l 2>/dev/null | grep -F "$cron_marker" | head -1 || true)
		# Parse */N from cron expression (first field)
		local cron_interval_min
		cron_interval_min=$(echo "$cron_line" | awk '{print $1}' | grep -oE '[0-9]+' || true)
		if [[ -n "$cron_interval_min" ]]; then
			interval_seconds=$((cron_interval_min * 60))
		fi
	fi

	# Install launchd agent
	case "$type" in
	supervisor-pulse)
		launchd_install_supervisor_pulse \
			"$script_path" \
			"${interval_seconds:-120}" \
			"$log_path" \
			"$batch_arg" || return 1
		;;
	auto-update)
		launchd_install_auto_update \
			"$script_path" \
			"${interval_seconds:-600}" \
			"$log_path" || return 1
		;;
	esac

	# Remove old cron entry
	local temp_cron
	temp_cron=$(mktemp)
	if crontab -l 2>/dev/null | grep -vF "$cron_marker" >"$temp_cron"; then
		crontab "$temp_cron"
		log_success "Removed old cron entry for $type"
	else
		# Crontab would be empty — remove it
		crontab -r 2>/dev/null || true
		log_success "Removed old cron entry for $type (crontab now empty)"
	fi
	rm -f "$temp_cron"

	log_success "Migration complete: $type now managed by launchd"
	return 0
}
