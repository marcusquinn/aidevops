#!/usr/bin/env bash
# launchd.sh - macOS LaunchAgent backend for scheduler abstraction
#
# Provides platform-aware scheduling: launchd on macOS, cron on Linux.
# Called by cron.sh when running on macOS.
#
# Three LaunchAgent plists managed:
#   com.aidevops.supervisor-pulse   - StartInterval:120 (every 2 min)
#   com.aidevops.auto-update        - StartInterval:600 (every 10 min)
#   com.aidevops.todo-watcher       - WatchPaths (replaces fswatch)
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
#   $1 - label (e.g., com.aidevops.supervisor-pulse)
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
	launchctl list 2>/dev/null | grep -qF "$label"
	return $?
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
#   $6 - gh_token (optional GH_TOKEN value)
#######################################
_generate_supervisor_pulse_plist() {
	local script_path="$1"
	local interval_seconds="${2:-120}"
	local log_path="$3"
	local batch_arg="${4:-}"
	local env_path="${5:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
	local gh_token="${6:-}"

	local label="com.aidevops.supervisor-pulse"

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
		<string>${env_path}</string>"
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

	local label="com.aidevops.auto-update"

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

	local label="com.aidevops.todo-watcher"

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

	local label="com.aidevops.supervisor-pulse"
	local plist_path
	plist_path="$(_plist_path "$label")"
	local launchd_dir
	launchd_dir="$(_launchd_dir)"

	mkdir -p "$launchd_dir"

	# Detect PATH and GH_TOKEN for launchd environment
	local env_path="${PATH}"
	local gh_token=""
	if command -v gh &>/dev/null; then
		gh_token=$(gh auth token 2>/dev/null || true)
	fi

	# Check if already loaded
	if _launchd_is_loaded "$label"; then
		log_warn "LaunchAgent $label already loaded. Unload first to change settings."
		launchd_status_supervisor_pulse
		return 0
	fi

	# Generate and write plist
	_generate_supervisor_pulse_plist \
		"$script_path" \
		"$interval_seconds" \
		"$log_path" \
		"$batch_arg" \
		"$env_path" \
		"$gh_token" >"$plist_path"

	# Load into launchd
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
	local label="com.aidevops.supervisor-pulse"
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
	local label="com.aidevops.supervisor-pulse"
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

	local label="com.aidevops.auto-update"
	local plist_path
	plist_path="$(_plist_path "$label")"
	local launchd_dir
	launchd_dir="$(_launchd_dir)"

	mkdir -p "$launchd_dir"

	local env_path="${PATH}"

	# Check if already loaded
	if _launchd_is_loaded "$label"; then
		log_warn "LaunchAgent $label already loaded. Unload first to change settings."
		return 0
	fi

	# Generate and write plist
	_generate_auto_update_plist \
		"$script_path" \
		"$interval_seconds" \
		"$log_path" \
		"$env_path" >"$plist_path"

	# Load into launchd
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
	local label="com.aidevops.auto-update"
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
	local label="com.aidevops.auto-update"
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

	local label="com.aidevops.todo-watcher"
	local plist_path
	plist_path="$(_plist_path "$label")"
	local launchd_dir
	launchd_dir="$(_launchd_dir)"

	mkdir -p "$launchd_dir"

	local env_path="${PATH}"

	# Check if already loaded
	if _launchd_is_loaded "$label"; then
		log_warn "LaunchAgent $label already loaded."
		return 0
	fi

	# Generate and write plist
	_generate_todo_watcher_plist \
		"$script_path" \
		"$todo_path" \
		"$repo_path" \
		"$log_path" \
		"$env_path" >"$plist_path"

	# Load into launchd
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
	local label="com.aidevops.todo-watcher"
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
