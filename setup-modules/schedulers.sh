#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Scheduler setup functions: supervisor pulse, stats wrapper, process guard,
# memory pressure monitor, screen time snapshot, contribution watch,
# profile README, OAuth token refresh.
# Part of aidevops setup.sh modularization (GH#5793)

# Keep pulse workers alive long enough for opus-tier dispatches.
PULSE_STALE_THRESHOLD_SECONDS=1800

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

# Resolve the user's pulse consent setting from all config layers.
# Priority: env var > jsonc config > legacy .conf. Prints the raw value
# (may be empty if never configured, or "true"/"false").
_resolve_pulse_consent() {
	local _pulse_user_config=""

	# Read explicit user consent from config.jsonc (not merged defaults).
	# Empty = user never configured this; "true"/"false" = explicit choice.
	if type _jsonc_get_raw &>/dev/null && [[ -f "${JSONC_USER:-$HOME/.config/aidevops/config.jsonc}" ]]; then
		_pulse_user_config=$(_jsonc_get_raw "${JSONC_USER:-$HOME/.config/aidevops/config.jsonc}" "orchestration.supervisor_pulse")
	fi

	# Also check legacy .conf user override
	if [[ -z "$_pulse_user_config" && -f "${FEATURE_TOGGLES_USER:-$HOME/.config/aidevops/feature-toggles.conf}" ]]; then
		local _legacy_val
		# Use awk instead of grep|tail|cut — grep exits 1 on no match, which
		# aborts the script under set -euo pipefail. awk always exits 0.
		_legacy_val=$(awk -F= '/^supervisor_pulse=/{val=$2} END{print val}' "${FEATURE_TOGGLES_USER:-$HOME/.config/aidevops/feature-toggles.conf}")
		if [[ -n "$_legacy_val" ]]; then
			_pulse_user_config="$_legacy_val"
		fi
	fi

	# Also check env var override (highest priority)
	if [[ -n "${AIDEVOPS_SUPERVISOR_PULSE:-}" ]]; then
		_pulse_user_config="$AIDEVOPS_SUPERVISOR_PULSE"
	fi

	printf '%s' "$_pulse_user_config"
	return 0
}

# Determine whether to install the pulse based on consent state.
# Handles interactive prompting and persisting the user's choice.
# Args: $1=pulse_user_config (raw), $2=wrapper_script path
# Prints "true" or "false".
_determine_pulse_install() {
	local _pulse_user_config="$1"
	local wrapper_script="$2"
	local _do_install=false
	local _pulse_lower
	_pulse_lower=$(echo "$_pulse_user_config" | tr '[:upper:]' '[:lower:]')

	if [[ "$_pulse_lower" == "false" ]]; then
		# User explicitly declined — never prompt, never install
		_do_install=false
	elif [[ "$_pulse_lower" == "true" ]]; then
		# User explicitly consented — install/regenerate
		_do_install=true
	elif [[ -z "$_pulse_user_config" ]]; then
		# No explicit config — fresh install or never configured
		if [[ "$NON_INTERACTIVE" == "true" ]]; then
			# Non-interactive: default OFF, do not install without consent
			_do_install=false
		elif [[ -f "$wrapper_script" ]]; then
			# Interactive: prompt with default-no
			# All user-facing output goes to stderr so $() captures only the result
			local enable_pulse=""
			echo "" >&2
			echo "The supervisor pulse enables autonomous orchestration." >&2
			echo "It will act under your GitHub identity and consume API credits:" >&2
			echo "  - Dispatches AI workers to implement tasks from GitHub issues" >&2
			echo "  - Creates PRs, merges passing PRs, files improvement issues" >&2
			echo "  - 4-hourly strategic review (opus-tier) for queue health" >&2
			echo "  - Circuit breaker pauses dispatch on consecutive failures" >&2
			echo "" >&2
			setup_prompt enable_pulse "Enable supervisor pulse? [y/N]: " "n"
			if [[ "$enable_pulse" =~ ^[Yy]$ ]]; then
				_do_install=true
				# Record explicit consent
				if type cmd_set &>/dev/null; then
					cmd_set "orchestration.supervisor_pulse" "true" || true
				fi
			else
				_do_install=false
				# Record explicit decline so we never re-prompt on updates
				if type cmd_set &>/dev/null; then
					cmd_set "orchestration.supervisor_pulse" "false" || true
				fi
				print_info "Skipped. Enable later: aidevops config set orchestration.supervisor_pulse true && ./setup.sh" >&2
			fi
		fi
	fi

	# Guard: wrapper must exist
	if [[ "$_do_install" == "true" && ! -f "$wrapper_script" ]]; then
		# Wrapper not deployed yet — skip (will install on next run after rsync)
		_do_install=false
	fi

	printf '%s' "$_do_install"
	return 0
}

# GH#17769: These functions are deprecated — model routing is now derived
# from the OAuth pool + routing table at runtime. Kept as no-ops for one
# release cycle in case external scripts call them.
_resolve_headless_models_override() {
	printf '%s' ""
	return 0
}

_resolve_pulse_model_override() {
	printf '%s' ""
	return 0
}

_is_pulse_installed() {
	local pulse_label="$1"

	if _scheduler_detect_installed \
		"Supervisor pulse" \
		"$pulse_label" \
		"" \
		"pulse-wrapper" \
		"" \
		"" \
		"" \
		"aidevops-supervisor-pulse"; then
		return 0
	fi

	return 1
}

_resolve_pulse_runtime_binary() {
	# GH#18439 Bug 2: Persist the resolved binary path across setup.sh
	# invocations. aidevops-auto-update.timer runs setup.sh under systemd's
	# minimal PATH, so re-resolving from live `$PATH` alone yields the
	# legacy macOS-biased `/opt/homebrew/bin/opencode` fallback on Linux.
	# Reading from persistence first (populated during an interactive
	# setup.sh run with a rich `$PATH`) prevents the auto-update cycle
	# from silently degrading the service file.
	local _persisted_file="$HOME/.config/aidevops/scheduler-runtime-bin"
	local opencode_bin=""

	# 1. Prefer persisted path if it still points at an executable file.
	if [[ -f "$_persisted_file" ]]; then
		local _persisted
		_persisted=$(head -n1 "$_persisted_file" 2>/dev/null || true)
		if [[ -n "$_persisted" ]] && [[ -x "$_persisted" ]]; then
			printf '%s' "$_persisted"
			return 0
		fi
	fi

	# 2. Try runtime-registry lookup via live PATH.
	if type rt_list_headless &>/dev/null; then
		local _sched_rt_id=""
		local _sched_bin=""
		while IFS= read -r _sched_rt_id; do
			_sched_bin=$(rt_binary "$_sched_rt_id") || continue
			if [[ -n "$_sched_bin" ]] && command -v "$_sched_bin" &>/dev/null; then
				opencode_bin=$(command -v "$_sched_bin")
				break
			fi
		done < <(rt_list_headless)
	fi

	# 3. Direct PATH lookup for the default runtime.
	if [[ -z "$opencode_bin" ]]; then
		opencode_bin=$(command -v opencode 2>/dev/null || true)
	fi

	# 4. OS-aware common-install-location sweep. Used when live `$PATH` is
	# minimal (systemd-spawned setup.sh) and persistence hasn't been
	# seeded yet. Covers Homebrew (macOS + Linuxbrew), /usr/local, npm
	# global, Python/uv pipx-style `.local/bin`, and bun.
	if [[ -z "$opencode_bin" ]]; then
		local _candidate
		for _candidate in \
			/opt/homebrew/bin/opencode \
			/usr/local/bin/opencode \
			/home/linuxbrew/.linuxbrew/bin/opencode \
			"$HOME/.npm-global/bin/opencode" \
			"$HOME/.local/bin/opencode" \
			"$HOME/.bun/bin/opencode" \
			/opt/homebrew/bin/claude \
			/usr/local/bin/claude \
			"$HOME/.local/bin/claude"; do
			if [[ -x "$_candidate" ]]; then
				opencode_bin="$_candidate"
				break
			fi
		done
	fi

	# 5. Last-resort legacy fallback (preserves pre-GH#18439 behaviour so
	# setup.sh never exits the resolver empty-handed).
	[[ -z "$opencode_bin" ]] && opencode_bin="/opt/homebrew/bin/opencode"

	# Persist the resolved path for subsequent non-interactive invocations
	# (auto-update timer, cron regeneration). Only write when we actually
	# found a real executable — don't persist the legacy fallback.
	if [[ -x "$opencode_bin" ]]; then
		mkdir -p "$(dirname "$_persisted_file")" 2>/dev/null || true
		printf '%s\n' "$opencode_bin" >"$_persisted_file" 2>/dev/null || true
	fi

	printf '%s' "$opencode_bin"
	return 0
}

_build_pulse_linux_env() {
	# GH#17546/GH#17769: Model config is derived from pool + routing table at
	# runtime. No model env vars embedded in cron/systemd.
	local opencode_bin="${1:-}"
	local _pulse_env="PULSE_DIR=${HOME}/.aidevops/.agent-workspace
PULSE_STALE_THRESHOLD=${PULSE_STALE_THRESHOLD_SECONDS}"

	# GH#18439 Bug 2: embed resolved runtime binary path so pulse-wrapper.sh
	# and headless-runtime-helper.sh find the correct binary under systemd's
	# minimal PATH (e.g. when aidevops-auto-update.timer regenerates the
	# service file). Mirrors the macOS launchd <OPENCODE_BIN> key.
	if [[ -n "$opencode_bin" ]]; then
		_pulse_env+=$'\n'"OPENCODE_BIN=${opencode_bin}"
	fi

	printf '%s' "$_pulse_env"
	return 0
}

# Read supervisor.pulse_interval_seconds from settings.json.
# Falls back to 120 if the file is missing, the key is absent, or jq is unavailable.
# Clamps to the validated range [30, 3600].
# GH#18018: previously this was hardcoded as "120" in _install_supervisor_pulse.
_read_pulse_interval_seconds() {
	local _settings_file="$HOME/.config/aidevops/settings.json"
	local _interval=120

	if command -v jq >/dev/null 2>&1 && [[ -f "$_settings_file" ]]; then
		local _raw
		_raw=$(jq -r '.supervisor.pulse_interval_seconds // empty' "$_settings_file" 2>/dev/null) || _raw=""
		if [[ -n "$_raw" ]] && [[ "$_raw" =~ ^[0-9]+$ ]]; then
			_interval="$_raw"
		fi
	fi

	# Clamp to validated range (mirrors settings-helper.sh validation: 30-3600)
	if [[ "$_interval" -lt 30 ]]; then
		_interval=30
	elif [[ "$_interval" -gt 3600 ]]; then
		_interval=3600
	fi

	printf '%d' "$_interval"
	return 0
}

# Convert an interval in seconds to a cron schedule expression (e.g. "*/2 * * * *").
# Minimum granularity is 1 minute. Intervals that don't divide evenly into minutes
# are rounded down to whole minutes with a warning.
# Args: $1 = interval_seconds
_seconds_to_cron_schedule() {
	local _interval_sec="$1"
	local _minutes=$((_interval_sec / 60))
	local _remainder=$((_interval_sec % 60))

	# Clamp to at least 1 minute
	if [[ "$_minutes" -lt 1 ]]; then
		_minutes=1
	fi

	# Warn if interval doesn't divide evenly into minutes
	if [[ "$_remainder" -ne 0 ]]; then
		echo "[schedulers] Warning: pulse_interval_seconds=${_interval_sec} does not divide evenly into minutes; rounding down to ${_minutes}min for cron schedule (systemd uses exact seconds)" >&2
	fi

	# cron step values must be 1-59; */60 is invalid. Use @hourly for exactly 60 min,
	# clamp anything above 59 to 59 (the _read_pulse_interval_seconds cap is 3600s=60min).
	if [[ "$_minutes" -ge 60 ]]; then
		printf '@hourly'
	else
		printf '*/%d * * * *' "$_minutes"
	fi
	return 0
}

_install_supervisor_pulse() {
	local _os="$1"
	local pulse_label="$2"
	local wrapper_script="$3"
	local opencode_bin="$4"
	local _pulse_installed="$5"

	mkdir -p "$HOME/.aidevops/logs"

	if [[ "$_os" == "Darwin" ]]; then
		_install_pulse_launchd "$pulse_label" "$wrapper_script" "$opencode_bin" "$_pulse_installed"
		return 0
	fi

	# GH#18018: read user-configured interval instead of hardcoding 120s / */2 cron
	local _pulse_interval_sec
	_pulse_interval_sec=$(_read_pulse_interval_seconds)
	local _pulse_cron_schedule
	_pulse_cron_schedule=$(_seconds_to_cron_schedule "$_pulse_interval_sec")
	# Build a human-readable interval label: show seconds when < 60s, minutes otherwise
	local _pulse_interval_label
	if [[ "$_pulse_interval_sec" -lt 60 ]]; then
		_pulse_interval_label="${_pulse_interval_sec}s"
	else
		_pulse_interval_label="$((_pulse_interval_sec / 60))min"
	fi

	local _pulse_timeout_sec=$((PULSE_STALE_THRESHOLD_SECONDS + 60))
	local _pulse_env=""
	# GH#18439 Bug 2: thread resolved runtime binary path through to the
	# Linux env builder so OPENCODE_BIN is embedded in the systemd service
	# file (parity with the macOS launchd plist at line 415).
	_pulse_env=$(_build_pulse_linux_env "$opencode_bin")
	_install_scheduler_linux \
		"aidevops-supervisor-pulse" \
		"aidevops: supervisor-pulse" \
		"${_pulse_cron_schedule}" \
		"\"${wrapper_script}\"" \
		"${_pulse_interval_sec}" \
		"$HOME/.aidevops/logs/pulse-wrapper.log" \
		"$_pulse_env" \
		"Supervisor pulse enabled (every ${_pulse_interval_label})" \
		"Failed to install supervisor pulse scheduler. See runners.md for manual setup." \
		"true" \
		"false" \
		"" \
		"${_pulse_timeout_sec}"
	return 0
}

# Setup the supervisor pulse scheduler (consent-gated autonomous orchestration).
# Uses pulse-wrapper.sh which handles dedup, orphan cleanup, and RAM-based concurrency.
# macOS: launchd plist invoking wrapper | Linux: cron entry invoking wrapper
# The plist is ALWAYS regenerated on setup.sh to pick up config changes (env vars,
# thresholds). Only the first-install prompt is gated on consent state.
#######################################
# t2119: Record the schedulers.sh template hash to the shared state
# directory. auto-update-helper.sh's check_launchd_plist_drift compares
# this against the current hash on every update cycle — whenever
# schedulers.sh changes without a VERSION bump (PR #19079 scenario),
# drift is detected and setup.sh --non-interactive is re-run to
# regenerate the installed plists.
#
# Called from setup_supervisor_pulse unconditionally so the hash is
# kept current on every setup.sh run, whether pulse is installed,
# upgraded, or disabled. Whole-file hash is the simplest signal that
# any plist-generating change has occurred.
#######################################
_schedulers_record_template_hash() {
	local state_dir="$HOME/.aidevops/.agent-workspace/tmp"
	mkdir -p "$state_dir" 2>/dev/null || return 0
	local hash_file="$state_dir/schedulers-template-hash.state"
	local schedulers_src="${BASH_SOURCE[0]:-}"
	[[ -f "$schedulers_src" ]] || return 0
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$schedulers_src" 2>/dev/null | awk '{print $1}' >"$hash_file" 2>/dev/null || true
	elif command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$schedulers_src" 2>/dev/null | awk '{print $1}' >"$hash_file" 2>/dev/null || true
	fi
	return 0
}

setup_supervisor_pulse() {
	local _os="$1"

	# Record template hash so auto-update can detect drift between
	# schedulers.sh and the installed plists on macOS (t2119).
	_schedulers_record_template_hash

	# Ensure crontab has a global PATH= line (Linux only; macOS uses launchd env).
	# Must run before any cron entries are installed so they inherit the PATH.
	if [[ "$_os" != "Darwin" ]]; then
		_ensure_cron_path
	fi

	# Consent model (GH#2926):
	#   - Default OFF: supervisor_pulse defaults to false in all config layers
	#   - Explicit consent required: user must type "y" (prompt defaults to [y/N])
	#   - Consent persisted: written to config.jsonc so it survives updates
	#   - Never silently re-enabled: if config says false, skip entirely
	#   - Non-interactive: only installs if config explicitly says true
	local wrapper_script="$HOME/.aidevops/agents/scripts/pulse-wrapper.sh"
	local pulse_label="com.aidevops.aidevops-supervisor-pulse"

	local _pulse_user_config
	_pulse_user_config=$(_resolve_pulse_consent)

	local _do_install
	_do_install=$(_determine_pulse_install "$_pulse_user_config" "$wrapper_script")

	local _pulse_lower
	_pulse_lower=$(echo "$_pulse_user_config" | tr '[:upper:]' '[:lower:]')

	# Detect if pulse is already installed (for upgrade messaging)
	# Uses shared helper to check launchd, cron, and systemd (GH#17381)
	local _pulse_installed=false
	if _is_pulse_installed "$pulse_label"; then
		_pulse_installed=true
	fi

	# Detect dispatch backend binary location (t1665.5 — registry-driven)
	local opencode_bin=""
	opencode_bin=$(_resolve_pulse_runtime_binary)

	if [[ "$_do_install" == "true" ]]; then
		_install_supervisor_pulse "$_os" "$pulse_label" "$wrapper_script" "$opencode_bin" "$_pulse_installed"
	elif [[ "$_pulse_lower" == "false" && "$_pulse_installed" == "true" ]]; then
		# User explicitly disabled but pulse is still installed — clean up
		_uninstall_pulse "$_os" "$pulse_label"
	fi

	# Export effective pulse state for setup_stats_wrapper.
	# Use the actual install decision (_do_install), not just the consent string,
	# so stats wrapper tracks the real scheduler state (e.g., wrapper missing → false).
	PULSE_CONSENT_LOWER="$_pulse_lower"
	if [[ "$_do_install" == "true" ]]; then
		PULSE_ENABLED="true"
	else
		PULSE_ENABLED="false"
	fi
	return 0
}

# Clean up old/legacy pulse launchd plists before reinstalling.
# Args: $1=pulse_label, $2=pulse_plist path
_cleanup_old_pulse_plists() {
	local pulse_label="$1"
	local pulse_plist="$2"

	# Unload old plist if upgrading
	if _launchd_has_agent "$pulse_label"; then
		launchctl unload "$pulse_plist" || true
		pkill -f 'Supervisor Pulse' 2>/dev/null || true
	fi

	# Also clean up old label if present
	local old_plist="$HOME/Library/LaunchAgents/com.aidevops.supervisor-pulse.plist"
	if [[ -f "$old_plist" ]]; then
		launchctl unload "$old_plist" || true
		rm -f "$old_plist"
	fi
	return 0
}

# Build XML environment variable fragment for headless model overrides.
# GH#17546: Model config was removed from plist embedding.
# GH#17769: Model routing is now derived from pool + routing table at runtime.
# No env vars needed — pulse-wrapper.sh reads the routing table directly.
_build_pulse_headless_env_xml() {
	# Intentionally empty — model config read from credentials.sh at runtime.
	printf '%s' ""
	return 0
}

# Generate the full pulse launchd plist XML content.
# Args: $1=pulse_label, $2=wrapper_script, $3=opencode_bin
# Prints the complete plist XML to stdout.
_generate_pulse_plist_content() {
	local pulse_label="$1"
	local wrapper_script="$2"
	local opencode_bin="$3"

	# XML-escape paths for safe plist embedding (prevents injection
	# if $HOME or paths contain &, <, > characters)
	local _xml_wrapper_script _xml_home _xml_opencode_bin _xml_pulse_dir _xml_path
	_xml_wrapper_script=$(_xml_escape "$wrapper_script")
	_xml_home=$(_xml_escape "$HOME")
	_xml_opencode_bin=$(_xml_escape "$opencode_bin")
	# Use neutral workspace path for PULSE_DIR so supervisor sessions
	# are not associated with any specific managed repo (GH#5136).
	_xml_pulse_dir=$(_xml_escape "${HOME}/.aidevops/.agent-workspace")
	_xml_path=$(_xml_escape "$PATH")

	local _headless_xml_env
	_headless_xml_env=$(_build_pulse_headless_env_xml)

	cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${pulse_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${_xml_wrapper_script}</string>
	</array>
	<key>StartInterval</key>
	<integer>120</integer>
	<key>StandardOutPath</key>
	<string>${_xml_home}/.aidevops/logs/pulse-wrapper.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_home}/.aidevops/logs/pulse-wrapper.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>${_xml_path}</string>
		<key>HOME</key>
		<string>${_xml_home}</string>
		<key>OPENCODE_BIN</key>
		<string>${_xml_opencode_bin}</string>
		<key>PULSE_DIR</key>
		<string>${_xml_pulse_dir}</string>
		<key>PULSE_STALE_THRESHOLD</key>
		<string>${PULSE_STALE_THRESHOLD_SECONDS}</string>
		${_headless_xml_env}
	</dict>
	<key>SoftResourceLimits</key>
	<dict>
		<key>NumberOfFiles</key>
		<integer>4096</integer>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
PLIST
	return 0
}

# Install supervisor pulse via launchd (macOS)
_install_pulse_launchd() {
	local pulse_label="$1"
	local wrapper_script="$2"
	local opencode_bin="$3"
	local _pulse_installed="$4"
	local pulse_plist="$HOME/Library/LaunchAgents/${pulse_label}.plist"

	_cleanup_old_pulse_plists "$pulse_label" "$pulse_plist"

	# Write the plist (always regenerated to pick up config changes)
	_generate_pulse_plist_content "$pulse_label" "$wrapper_script" "$opencode_bin" >"$pulse_plist"

	# shell-portability: ignore next — _install_pulse_launchd is macOS-only (launchd)
	if launchctl load "$pulse_plist"; then
		if [[ "$_pulse_installed" == "true" ]]; then
			print_info "Supervisor pulse updated (launchd config regenerated)"
		else
			print_info "Supervisor pulse enabled (launchd, every 2 min)"
		fi
	else
		print_warning "Failed to load supervisor pulse LaunchAgent"
	fi
	return 0
}

# Check if systemd user services are available on this Linux system.
# Returns 0 if systemd --user is functional, 1 otherwise.
_systemd_user_available() {
	command -v systemctl >/dev/null 2>&1 || return 1
	systemctl --user status >/dev/null 2>&1 || return 1
	return 0
}

# Escape a value for safe embedding in a systemd unit Environment= or ExecStart=
# directive. systemd interprets % as specifiers (%h, %n, %t, etc.) and spaces
# as key-value separators. This helper:
#   1. Escapes \ → \\ (must be first to avoid double-escaping)
#   2. Doubles % → %% (escape specifiers)
#   3. Escapes embedded " → \"
#   4. Wraps the result in "..." (handles spaces and other shell metacharacters)
# Usage: escaped=$(_systemd_escape "$value")
#
# WARNING: Do NOT use for StandardOutput= or StandardError= directives.
# systemd does not strip outer quotes from those values — "append:/path" is
# treated as a literal filename with quote characters, failing silently.
# Use bare values for StandardOutput=/StandardError=:
#   StandardOutput=append:${log_file}  ← correct
#   StandardOutput=$(_systemd_escape "append:${log_file}")  ← WRONG
_systemd_escape() {
	local _val="$1"
	# Step 1: escape backslashes
	_val="${_val//\\/\\\\}"
	# Step 2: escape % specifiers
	_val="${_val//%/%%}"
	# Step 3: escape embedded double-quotes
	_val="${_val//\"/\\\"}"
	# Step 4: wrap in double-quotes
	printf '"%s"' "$_val"
	return 0
}

# Build systemd Environment= lines from newline-separated KEY=VALUE pairs.
# Always appends HOME and PATH for parity with launchd and cron execution.
_scheduler_systemd_env_lines() {
	local env_vars="$1"
	local _env_lines=""

	if [[ -n "$env_vars" ]]; then
		while IFS= read -r _kv; do
			[[ -z "$_kv" ]] && continue
			local _key="${_kv%%=*}"
			local _raw_val="${_kv#*=}"
			local _escaped_val
			_escaped_val=$(_systemd_escape "$_raw_val")
			_env_lines+="Environment=${_key}=${_escaped_val}"$'\n'
		done <<<"$env_vars"
	fi

	_env_lines+="Environment=HOME=$(_systemd_escape "$HOME")"$'\n'
	_env_lines+="Environment=PATH=$(_systemd_escape "$PATH")"$'\n'
	printf '%s' "$_env_lines"
	return 0
}

# Build inline cron environment assignments from newline-separated KEY=VALUE pairs.
_scheduler_cron_env_prefix() {
	local env_vars="$1"
	local _env_prefix=""

	if [[ -n "$env_vars" ]]; then
		while IFS= read -r _kv; do
			[[ -z "$_kv" ]] && continue
			local _key="${_kv%%=*}"
			local _raw_val="${_kv#*=}"
			local _escaped_val
			_escaped_val=$(_cron_escape "$_raw_val")
			_env_prefix+="${_key}=${_escaped_val} "
		done <<<"$env_vars"
	fi

	printf '%s' "$_env_prefix"
	return 0
}

# Install a generic scheduler via systemd user timer (Linux with systemd).
# Args:
#   $1 = service_name    (e.g. "aidevops-stats-wrapper")
#   $2 = exec_command    (shell command run via /bin/bash -lc)
#   $3 = interval_sec    (OnUnitActiveSec interval in seconds; may be empty for calendar-only)
#   $4 = log_file        (absolute path to log file)
#   $5 = env_vars        (newline-separated KEY=VALUE pairs, may be empty)
#   $6 = run_at_load     ("true" or "false")
#   $7 = low_priority    ("true" or "false")
#   $8 = on_calendar     (optional systemd OnCalendar spec)
#   $9 = timeout_sec     (optional TimeoutStartSec; defaults to interval_sec)
# Returns 0 on success, 1 if systemd enable fails (caller should fall back to cron).
_install_scheduler_systemd() {
	local service_name="$1"
	local exec_command="$2"
	local interval_sec="$3"
	local log_file="$4"
	local env_vars="$5"
	local run_at_load="$6"
	local low_priority="$7"
	local on_calendar="$8"
	local timeout_sec="$9"
	local service_dir="$HOME/.config/systemd/user"
	local service_file="${service_dir}/${service_name}.service"
	local timer_file="${service_dir}/${service_name}.timer"

	mkdir -p "$service_dir"

	# GH#18439 Bug 1: command substitution strips trailing newlines, which
	# would run the final Environment=PATH=... into the following
	# StandardOutput=... directive on the same line. Use a sentinel ('x')
	# to preserve the trailing newline that _scheduler_systemd_env_lines
	# always emits.
	local _env_lines
	_env_lines=$(
		_scheduler_systemd_env_lines "$env_vars"
		printf 'x'
	)
	_env_lines="${_env_lines%x}"

	if [[ -z "$timeout_sec" ]]; then
		timeout_sec="$interval_sec"
	fi
	if [[ -z "$timeout_sec" ]]; then
		timeout_sec="3600"
	fi

	local _service_extra=""
	if [[ "$low_priority" == "true" ]]; then
		_service_extra+="Nice=10"$'\n'
		_service_extra+="IOSchedulingClass=idle"$'\n'
	fi

	printf '%s' "[Unit]
Description=aidevops ${service_name}
After=network.target

[Service]
Type=oneshot
KillMode=process
ExecStart=/bin/bash -lc $(_systemd_escape "$exec_command")
TimeoutStartSec=${timeout_sec}
${_service_extra}${_env_lines}StandardOutput=append:${log_file}
StandardError=append:${log_file}
" >"$service_file"

	local _timer_lines=""
	if [[ "$run_at_load" == "true" ]]; then
		_timer_lines+="OnActiveSec=10s"$'\n'
	fi
	if [[ -n "$interval_sec" ]]; then
		_timer_lines+="OnBootSec=${interval_sec}"$'\n'
		_timer_lines+="OnUnitActiveSec=${interval_sec}"$'\n'
	fi
	if [[ -n "$on_calendar" ]]; then
		_timer_lines+="OnCalendar=${on_calendar}"$'\n'
	fi

	printf '%s' "[Unit]
Description=aidevops ${service_name} Timer

[Timer]
${_timer_lines}Persistent=true

[Install]
WantedBy=timers.target
" >"$timer_file"

	systemctl --user daemon-reload 2>/dev/null || true
	if systemctl --user enable --now "${service_name}.timer" 2>/dev/null; then
		return 0
	fi
	return 1
}

# Install a generic cron entry.
# Args: $1=cron_tag, $2=cron_schedule, $3=exec_command, $4=log_file, $5=env_vars
_install_scheduler_cron() {
	local cron_tag="$1"
	local cron_schedule="$2"
	local exec_command="$3"
	local log_file="$4"
	local env_vars="$5"
	local _cron_exec
	local _cron_log
	local _env_prefix

	_env_prefix=$(_scheduler_cron_env_prefix "$env_vars")
	_cron_exec=$(_cron_escape "$exec_command")
	_cron_log=$(_cron_escape "$log_file")

	(
		crontab -l 2>/dev/null | grep -vF "${cron_tag}" || true
		echo "${cron_schedule} ${_env_prefix}/bin/bash -lc ${_cron_exec} >> ${_cron_log} 2>&1 # ${cron_tag}"
	) | crontab - 2>/dev/null || true
	return 0
}

# Dispatcher: install a scheduler on Linux, preferring systemd over cron.
# Args:
#   $1 = service_name   (systemd service name, e.g. "aidevops-stats-wrapper")
#   $2 = cron_tag       (comment tag for cron line, e.g. "aidevops: stats-wrapper")
#   $3 = cron_schedule  (cron schedule expression, e.g. "*/15 * * * *")
#   $4 = exec_command   (shell command run via /bin/bash -lc)
#   $5 = interval_sec   (systemd OnUnitActiveSec in seconds; may be empty for calendar-only)
#   $6 = log_file       (absolute path to log file)
#   $7 = env_vars       (newline-separated KEY=VALUE pairs for systemd/cron, may be empty)
#   $8 = success_msg    (message to print on success)
#   $9 = fail_msg       (message to print on failure)
#   $10 = run_at_load   ("true" or "false")
#   $11 = low_priority  ("true" or "false")
#   $12 = on_calendar   (optional systemd OnCalendar spec)
#   $13 = timeout_sec   (optional TimeoutStartSec)
# Returns 0 always (failures are warnings, not fatal).
_install_scheduler_linux() {
	local service_name="$1"
	local cron_tag="$2"
	local cron_schedule="$3"
	local exec_command="$4"
	local interval_sec="$5"
	local log_file="$6"
	local env_vars="$7"
	local success_msg="$8"
	local fail_msg="$9"
	local run_at_load="${10}"
	local low_priority="${11}"
	local on_calendar="${12:-}"
	local timeout_sec="${13:-}"

	if _systemd_user_available; then
		if _install_scheduler_systemd \
			"$service_name" \
			"$exec_command" \
			"$interval_sec" \
			"$log_file" \
			"$env_vars" \
			"$run_at_load" \
			"$low_priority" \
			"$on_calendar" \
			"$timeout_sec"; then
			print_info "${success_msg} (systemd user timer)"
			# After systemd install succeeds, remove any pre-existing cron entry
			# to prevent dual-execution (GH#17695 Finding A)
			if command -v crontab >/dev/null 2>&1; then
				local current_cron
				current_cron=$(crontab -l 2>/dev/null) || current_cron=""
				if [[ -n "$current_cron" ]] && echo "$current_cron" | grep -qF "$cron_tag"; then
					echo "$current_cron" | grep -vF "$cron_tag" | crontab -
					echo "[schedulers] Removed pre-existing cron entry for $cron_tag (migrated to systemd)"
				fi
			fi
		else
			print_warning "systemd enable failed for ${service_name} — falling back to cron"
			_install_scheduler_cron "$cron_tag" "$cron_schedule" "$exec_command" "$log_file" "$env_vars"
			if crontab -l 2>/dev/null | grep -qF "${cron_tag}" 2>/dev/null; then
				print_info "${success_msg} (cron fallback)"
			else
				print_warning "${fail_msg}"
			fi
		fi
	else
		_install_scheduler_cron "$cron_tag" "$cron_schedule" "$exec_command" "$log_file" "$env_vars"
		if crontab -l 2>/dev/null | grep -qF "${cron_tag}" 2>/dev/null; then
			print_info "${success_msg} (cron)"
		else
			print_warning "${fail_msg}"
		fi
	fi
	return 0
}

# Uninstall a scheduler across all backends (launchd/systemd/cron).
# Args:
#   $1 = os            (output of uname -s)
#   $2 = launchd_label (e.g. "sh.aidevops.stats-wrapper")
#   $3 = systemd_name  (e.g. "aidevops-stats-wrapper")
#   $4 = cron_tag      (grep pattern for cron line, e.g. "aidevops: stats-wrapper")
#   $5 = success_msg   (message to print on removal)
# Returns 0 always.
_uninstall_scheduler() {
	local _os="$1"
	local launchd_label="$2"
	local systemd_name="$3"
	local cron_tag="$4"
	local success_msg="$5"

	if [[ "$_os" == "Darwin" ]]; then
		local _plist="$HOME/Library/LaunchAgents/${launchd_label}.plist"
		if _launchd_has_agent "$launchd_label"; then
			launchctl unload "$_plist" 2>/dev/null || true
			rm -f "$_plist"
			print_info "${success_msg} (launchd agent removed)"
		fi
	else
		# Check and remove from ALL backends sequentially, not just the first
		# match. Prevents orphan entries when migrating between systemd and cron
		# (GH#17695 Finding A).
		if _systemd_user_available && systemctl --user is-enabled "${systemd_name}.timer" >/dev/null 2>&1; then
			systemctl --user disable --now "${systemd_name}.timer" 2>/dev/null || true
			rm -f "$HOME/.config/systemd/user/${systemd_name}.service"
			rm -f "$HOME/.config/systemd/user/${systemd_name}.timer"
			systemctl --user daemon-reload 2>/dev/null || true
			print_info "${success_msg} (systemd timer removed)"
		fi
		if command -v crontab >/dev/null 2>&1; then
			local current_cron
			current_cron=$(crontab -l 2>/dev/null) || current_cron=""
			if [[ -n "$current_cron" ]] && echo "$current_cron" | grep -qF "${cron_tag}"; then
				echo "$current_cron" | grep -vF "${cron_tag}" | crontab - 2>/dev/null || true
				print_info "${success_msg} (cron entry removed)"
			fi
		fi
	fi
	return 0
}

# Uninstall supervisor pulse (user explicitly disabled)
_uninstall_pulse() {
	local _os="$1"
	local pulse_label="$2"
	if [[ "$_os" == "Darwin" ]]; then
		local pulse_plist="$HOME/Library/LaunchAgents/${pulse_label}.plist"
		if _launchd_has_agent "$pulse_label"; then
			launchctl unload "$pulse_plist" || true
			rm -f "$pulse_plist"
			pkill -f 'Supervisor Pulse' 2>/dev/null || true
			print_info "Supervisor pulse disabled (launchd agent removed per config)"
		fi
	elif _systemd_user_available; then
		local service_name="aidevops-supervisor-pulse"
		if systemctl --user is-enabled "${service_name}.timer" >/dev/null 2>&1; then
			systemctl --user disable --now "${service_name}.timer" 2>/dev/null || true
			rm -f "$HOME/.config/systemd/user/${service_name}.service"
			rm -f "$HOME/.config/systemd/user/${service_name}.timer"
			systemctl --user daemon-reload 2>/dev/null || true
			print_info "Supervisor pulse disabled (systemd timer removed per config)"
		fi
	else
		if crontab -l 2>/dev/null | grep -qF "pulse-wrapper"; then
			crontab -l 2>/dev/null | grep -v 'aidevops: supervisor-pulse' | crontab - || true
			print_info "Supervisor pulse disabled (cron entry removed per config)"
		fi
	fi
	return 0
}

# Setup stats-wrapper scheduler — runs quality sweep and health issue updates
# separately from the pulse (t1429). Only installed when the supervisor
# pulse is enabled (stats are useless without it).
# macOS: launchd plist (every 15 min) | Linux: systemd timer or cron (every 15 min)
setup_stats_wrapper() {
	local _pulse_lower="$1"
	# Use effective pulse state (PULSE_ENABLED) if available; fall back to consent string.
	# PULSE_ENABLED reflects the actual install decision (e.g., false when wrapper is missing).
	local _pulse_effective="${PULSE_ENABLED:-$_pulse_lower}"
	local stats_script="$HOME/.aidevops/agents/scripts/stats-wrapper.sh"
	local stats_label="com.aidevops.aidevops-stats-wrapper"
	local stats_systemd="aidevops-stats-wrapper"
	local stats_log="$HOME/.aidevops/logs/stats.log"
	if [[ -x "$stats_script" ]] && [[ "$_pulse_effective" == "true" ]]; then
		# Always regenerate to pick up config/format changes (matches pulse behavior)
		if [[ "$(uname -s)" == "Darwin" ]]; then
			local stats_plist="$HOME/Library/LaunchAgents/${stats_label}.plist"

			local _xml_stats_script _xml_stats_home _xml_stats_path
			_xml_stats_script=$(_xml_escape "$stats_script")
			_xml_stats_home=$(_xml_escape "$HOME")
			_xml_stats_path=$(_xml_escape "$PATH")
			local stats_plist_content
			stats_plist_content=$(
				cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${stats_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${_xml_stats_script}</string>
	</array>
	<key>StartInterval</key>
	<integer>900</integer>
	<key>StandardOutPath</key>
	<string>${_xml_stats_home}/.aidevops/logs/stats.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_stats_home}/.aidevops/logs/stats.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>${_xml_stats_path}</string>
		<key>HOME</key>
		<string>${_xml_stats_home}</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
PLIST
			)
			if _launchd_install_if_changed "$stats_label" "$stats_plist" "$stats_plist_content"; then
				print_info "Stats wrapper enabled (launchd, every 15 min)"
			else
				print_warning "Failed to load stats wrapper LaunchAgent"
			fi
		else
			_install_scheduler_linux \
				"$stats_systemd" \
				"aidevops: stats-wrapper" \
				"*/15 * * * *" \
				"\"${stats_script}\"" \
				"900" \
				"$stats_log" \
				"" \
				"Stats wrapper enabled (every 15 min)" \
				"Failed to install stats wrapper scheduler" \
				"true" \
				"false"
		fi
	elif [[ "$_pulse_effective" == "false" ]]; then
		# Remove stats scheduler if pulse is disabled
		_uninstall_scheduler \
			"$(uname -s)" \
			"$stats_label" \
			"$stats_systemd" \
			"aidevops: stats-wrapper" \
			"Stats wrapper disabled (pulse is off)"
	fi
	return 0
}

# Setup failure miner — mines GitHub CI failure notifications for systemic patterns
# and auto-files root-cause issues. Runs as a pure bash script (no LLM needed).
# Installed when pulse is enabled and the helper script exists.
# macOS: launchd plist (hourly at :15) | Linux: systemd timer or cron (hourly at :15)
setup_failure_miner() {
	local _pulse_lower="$1"
	local _pulse_effective="${PULSE_ENABLED:-$_pulse_lower}"
	local miner_script="$HOME/.aidevops/agents/scripts/gh-failure-miner-helper.sh"
	local miner_label="sh.aidevops.routine-gh-failure-miner"
	local miner_systemd="aidevops-gh-failure-miner"
	local miner_log="$HOME/.aidevops/logs/routine-gh-failure-miner.log"
	if [[ ! -x "$miner_script" ]] || [[ "$_pulse_effective" != "true" ]]; then
		# Remove scheduler if pulse is disabled or script missing
		_uninstall_scheduler \
			"$(uname -s)" \
			"$miner_label" \
			"$miner_systemd" \
			"aidevops: gh-failure-miner" \
			"Failure miner disabled (pulse is off or script missing)"
		return 0
	fi

	mkdir -p "$HOME/.aidevops/logs"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		local miner_plist="$HOME/Library/LaunchAgents/${miner_label}.plist"

		local _xml_miner_script _xml_miner_home _xml_miner_path _xml_miner_log
		_xml_miner_script=$(_xml_escape "$miner_script")
		_xml_miner_home=$(_xml_escape "$HOME")
		_xml_miner_path=$(_xml_escape "/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}")
		_xml_miner_log=$(_xml_escape "$miner_log")

		local miner_plist_content
		miner_plist_content=$(
			cat <<MINER_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${miner_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${_xml_miner_script}</string>
		<string>create-issues</string>
		<string>--since-hours</string>
		<string>24</string>
		<string>--pulse-repos</string>
		<string>--systemic-threshold</string>
		<string>2</string>
		<string>--max-issues</string>
		<string>3</string>
		<string>--label</string>
		<string>auto-dispatch</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>${_xml_miner_home}</string>
		<key>PATH</key>
		<string>${_xml_miner_path}</string>
	</dict>
	<key>StartCalendarInterval</key>
	<array>
		<dict>
			<key>Minute</key>
			<integer>15</integer>
		</dict>
	</array>
	<key>StandardOutPath</key>
	<string>${_xml_miner_log}</string>
	<key>StandardErrorPath</key>
	<string>${_xml_miner_log}</string>
	<key>RunAtLoad</key>
	<false/>
</dict>
</plist>
MINER_PLIST
		)

		if _launchd_install_if_changed "$miner_label" "$miner_plist" "$miner_plist_content"; then
			print_info "Failure miner enabled (launchd, hourly at :15)"
		else
			print_warning "Failed to load failure miner LaunchAgent"
		fi
	else
		_install_scheduler_linux \
			"$miner_systemd" \
			"aidevops: gh-failure-miner" \
			"15 * * * *" \
			"\"${miner_script}\" create-issues --since-hours 24 --pulse-repos --systemic-threshold 2 --max-issues 3 --label auto-dispatch" \
			"3600" \
			"$miner_log" \
			"" \
			"Failure miner enabled (hourly at :15)" \
			"Failed to install failure miner scheduler" \
			"false" \
			"false" \
			"*-*-* *:15:00"
	fi
	return 0
}

# Setup process guard — kills runaway AI processes (ShellCheck bloat, stuck workers)
# before they exhaust memory and cause kernel panics. Always installed when the
# script exists; no consent needed (safety net, not autonomous action).
# macOS: launchd plist (30s interval, RunAtLoad=true) | Linux: systemd timer or cron (every minute)
setup_process_guard() {
	local guard_script="$HOME/.aidevops/agents/scripts/process-guard-helper.sh"
	local guard_label="sh.aidevops.process-guard"
	local guard_systemd="aidevops-process-guard"
	local guard_log="$HOME/.aidevops/logs/process-guard.log"
	if [[ ! -x "$guard_script" ]]; then
		return 0
	fi

	mkdir -p "$HOME/.aidevops/logs"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		local guard_plist="$HOME/Library/LaunchAgents/${guard_label}.plist"

		# XML-escape paths for safe plist embedding (prevents injection
		# if $HOME or paths contain &, <, > characters)
		local _xml_guard_script _xml_guard_home _xml_guard_path
		_xml_guard_script=$(_xml_escape "$guard_script")
		_xml_guard_home=$(_xml_escape "$HOME")
		_xml_guard_path=$(_xml_escape "$PATH")

		local guard_plist_content
		guard_plist_content=$(
			cat <<GUARD_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${guard_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${_xml_guard_script}</string>
		<string>kill-runaways</string>
	</array>
	<key>StartInterval</key>
	<integer>30</integer>
	<key>StandardOutPath</key>
	<string>${_xml_guard_home}/.aidevops/logs/process-guard.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_guard_home}/.aidevops/logs/process-guard.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>${_xml_guard_path}</string>
		<key>HOME</key>
		<string>${_xml_guard_home}</string>
		<key>SHELLCHECK_RSS_LIMIT_KB</key>
		<string>524288</string>
		<key>SHELLCHECK_RUNTIME_LIMIT</key>
		<string>120</string>
		<key>CHILD_RSS_LIMIT_KB</key>
		<string>8388608</string>
		<key>CHILD_RUNTIME_LIMIT</key>
		<string>7200</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
GUARD_PLIST
		)

		if _launchd_install_if_changed "$guard_label" "$guard_plist" "$guard_plist_content"; then
			print_info "Process guard enabled (launchd, every 30s, survives reboot)"
		else
			print_warning "Failed to load process guard LaunchAgent"
		fi
	else
		# Linux: systemd timer (30s) or cron fallback (every minute — cron minimum granularity)
		_install_scheduler_linux \
			"$guard_systemd" \
			"aidevops: process-guard" \
			"* * * * *" \
			"\"${guard_script}\" kill-runaways" \
			"30" \
			"$guard_log" \
			"SHELLCHECK_RSS_LIMIT_KB=524288
SHELLCHECK_RUNTIME_LIMIT=120
CHILD_RSS_LIMIT_KB=8388608
CHILD_RUNTIME_LIMIT=7200" \
			"Process guard enabled (every 30s)" \
			"Failed to install process guard scheduler" \
			"true" \
			"false"
	fi
	return 0
}

# Setup memory pressure monitor — process-focused memory watchdog (t1398.5, GH#2915).
# Monitors individual process RSS, runtime, session count, and aggregate memory.
# Auto-kills runaway ShellCheck (language server respawns them). Always installed
# when the script exists; no consent needed (safety net, not autonomous action).
# macOS: launchd plist (60s interval, RunAtLoad=true) | Linux: systemd timer or cron (every minute)
setup_memory_pressure_monitor() {
	local monitor_script="$HOME/.aidevops/agents/scripts/memory-pressure-monitor.sh"
	local monitor_label="sh.aidevops.memory-pressure-monitor"
	local monitor_systemd="aidevops-memory-pressure-monitor"
	local monitor_log="$HOME/.aidevops/logs/memory-pressure-launchd.log"
	if [[ ! -x "$monitor_script" ]]; then
		return 0
	fi

	mkdir -p "$HOME/.aidevops/logs"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		local monitor_plist="$HOME/Library/LaunchAgents/${monitor_label}.plist"

		# XML-escape paths for safe plist embedding
		local _xml_monitor_script _xml_monitor_home
		_xml_monitor_script=$(_xml_escape "$monitor_script")
		_xml_monitor_home=$(_xml_escape "$HOME")

		local monitor_plist_content
		monitor_plist_content=$(
			cat <<MONITOR_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${monitor_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${_xml_monitor_script}</string>
	</array>
	<key>StartInterval</key>
	<integer>60</integer>
	<key>StandardOutPath</key>
	<string>${_xml_monitor_home}/.aidevops/logs/memory-pressure-launchd.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_monitor_home}/.aidevops/logs/memory-pressure-launchd.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>HOME</key>
		<string>${_xml_monitor_home}</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityBackgroundIO</key>
	<true/>
	<key>Nice</key>
	<integer>10</integer>
</dict>
</plist>
MONITOR_PLIST
		)

		if _launchd_install_if_changed "$monitor_label" "$monitor_plist" "$monitor_plist_content"; then
			print_info "Memory pressure monitor enabled (launchd, every 60s, survives reboot)"
		else
			print_warning "Failed to load memory pressure monitor LaunchAgent"
		fi
	else
		# Linux: systemd timer (60s) or cron fallback (every minute — cron minimum granularity)
		_install_scheduler_linux \
			"$monitor_systemd" \
			"aidevops: memory-pressure-monitor" \
			"* * * * *" \
			"\"${monitor_script}\"" \
			"60" \
			"$monitor_log" \
			"" \
			"Memory pressure monitor enabled (every 60s)" \
			"Failed to install memory pressure monitor scheduler" \
			"true" \
			"true"
	fi
	return 0
}

# Setup screen time snapshot — captures daily screen time for contributor stats.
# Accumulates data in screen-time.jsonl (macOS Knowledge DB retains only ~28 days).
# Always installed when the script exists; no consent needed (data collection only).
# macOS: launchd plist (every 6h, RunAtLoad=true) | Linux: systemd timer or cron (every 6h)
setup_screen_time_snapshot() {
	local st_script="$HOME/.aidevops/agents/scripts/screen-time-helper.sh"
	local st_label="sh.aidevops.screen-time-snapshot"
	local st_systemd="aidevops-screen-time-snapshot"
	local st_log="$HOME/.aidevops/.agent-workspace/logs/screen-time-snapshot.log"
	if [[ ! -x "$st_script" ]]; then
		return 0
	fi

	mkdir -p "$HOME/.aidevops/.agent-workspace/logs"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		local st_plist="$HOME/Library/LaunchAgents/${st_label}.plist"

		# XML-escape paths for safe plist embedding
		local _xml_st_script _xml_st_home
		_xml_st_script=$(_xml_escape "$st_script")
		_xml_st_home=$(_xml_escape "$HOME")

		local st_plist_content
		st_plist_content=$(
			cat <<ST_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${st_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${_xml_st_script}</string>
		<string>snapshot</string>
	</array>
	<key>StartInterval</key>
	<integer>21600</integer>
	<key>StandardOutPath</key>
	<string>${_xml_st_home}/.aidevops/.agent-workspace/logs/screen-time-snapshot.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_st_home}/.aidevops/.agent-workspace/logs/screen-time-snapshot.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>HOME</key>
		<string>${_xml_st_home}</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityBackgroundIO</key>
	<true/>
	<key>Nice</key>
	<integer>10</integer>
</dict>
</plist>
ST_PLIST
		)

		if _launchd_install_if_changed "$st_label" "$st_plist" "$st_plist_content"; then
			print_info "Screen time snapshot enabled (launchd, every 6h, survives reboot)"
		else
			print_warning "Failed to load screen time snapshot LaunchAgent"
		fi
	else
		# Linux: systemd timer (every 6h) or cron fallback
		_install_scheduler_linux \
			"$st_systemd" \
			"aidevops: screen-time-snapshot" \
			"0 */6 * * *" \
			"\"${st_script}\" snapshot" \
			"21600" \
			"$st_log" \
			"" \
			"Screen time snapshot enabled (every 6h)" \
			"Failed to install screen time snapshot scheduler" \
			"true" \
			"true"
	fi
	return 0
}

# Resolve and validate the log directory from config for contribution watch.
# Reads paths.log_dir from jsonc config, validates characters, expands tilde.
# Prints the resolved absolute path. Returns 1 on invalid characters.
_resolve_cw_log_dir() {
	local _cw_log_dir
	# shellcheck disable=SC2088  # Tilde is intentionally literal here; expanded below via ${/#\~/$HOME}
	if type _jsonc_get &>/dev/null; then
		_cw_log_dir=$(_jsonc_get "paths.log_dir" "~/.aidevops/logs")
	else
		_cw_log_dir="~/.aidevops/logs"
	fi
	# Whitelist: only allow characters safe in shell paths and cron lines.
	# Reject anything outside [A-Za-z0-9_./ ~-] (tilde allowed before expansion).
	# Store regex in variable — bash [[ =~ ]] requires unquoted RHS for regex,
	# and a variable avoids quoting issues with special chars in the pattern.
	local _cw_log_dir_re='^[A-Za-z0-9_./ ~-]+$'
	if ! [[ "$_cw_log_dir" =~ $_cw_log_dir_re ]]; then
		# Redirect to stderr so $() captures only the path result
		print_error "Invalid characters in paths.log_dir (only [A-Za-z0-9_./ ~-] allowed): $_cw_log_dir" >&2
		return 1
	fi
	_cw_log_dir="${_cw_log_dir/#\~/$HOME}"
	printf '%s' "$_cw_log_dir"
	return 0
}

# Install contribution watch via launchd (macOS).
# Args: $1=label, $2=script path, $3=log dir
_install_cw_launchd() {
	local cw_label="$1"
	local cw_script="$2"
	local _cw_log_dir="$3"
	local cw_plist="$HOME/Library/LaunchAgents/${cw_label}.plist"

	local _xml_cw_script _xml_cw_home _xml_cw_log_dir
	_xml_cw_script=$(_xml_escape "$cw_script")
	_xml_cw_home=$(_xml_escape "$HOME")
	_xml_cw_log_dir=$(_xml_escape "$_cw_log_dir")

	local cw_plist_content
	cw_plist_content=$(
		cat <<CW_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${cw_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${_xml_cw_script}</string>
		<string>scan</string>
	</array>
	<key>StartInterval</key>
	<integer>3600</integer>
	<key>StandardOutPath</key>
	<string>${_xml_cw_log_dir}/contribution-watch.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_cw_log_dir}/contribution-watch.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>HOME</key>
		<string>${_xml_cw_home}</string>
	</dict>
	<key>RunAtLoad</key>
	<false/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityBackgroundIO</key>
	<true/>
	<key>Nice</key>
	<integer>10</integer>
</dict>
</plist>
CW_PLIST
	)

	if _launchd_install_if_changed "$cw_label" "$cw_plist" "$cw_plist_content"; then
		print_info "Contribution watch enabled (launchd, hourly scan)"
	else
		print_warning "Failed to load contribution watch LaunchAgent"
	fi
	return 0
}

# Install contribution watch via systemd or cron (Linux).
# Args: $1=script path, $2=log dir
_install_cw_linux() {
	local cw_script="$1"
	local _cw_log_dir="$2"
	local cw_systemd="aidevops-contribution-watch"
	_install_scheduler_linux \
		"$cw_systemd" \
		"aidevops: contribution-watch" \
		"0 * * * *" \
		"\"${cw_script}\" scan" \
		"3600" \
		"${_cw_log_dir}/contribution-watch.log" \
		"" \
		"Contribution watch enabled (hourly scan)" \
		"Failed to install contribution watch scheduler" \
		"false" \
		"true"
	return 0
}

# Setup contribution watch — monitors external issues/PRs for new activity (t1554).
# Auto-seeds on first run (discovers authored/commented issues/PRs), then installs
# a launchd/systemd/cron job to scan periodically. Requires gh CLI authenticated.
# No consent needed — this is passive monitoring (read-only notifications API),
# not autonomous action. Comment bodies are never processed by LLM in automated context.
# Respects config: aidevops config set orchestration.contribution_watch false
setup_contribution_watch() {
	local cw_script="$HOME/.aidevops/agents/scripts/contribution-watch-helper.sh"
	local cw_label="sh.aidevops.contribution-watch"
	local cw_state="$HOME/.aidevops/cache/contribution-watch.json"
	if ! [[ -x "$cw_script" ]] || ! is_feature_enabled orchestration.contribution_watch 2>/dev/null || ! command -v gh &>/dev/null || ! gh auth status &>/dev/null 2>&1; then
		return 0
	fi

	# Resolve and validate log directory
	local _cw_log_dir
	_cw_log_dir=$(_resolve_cw_log_dir) || return 1
	mkdir -p "$HOME/.aidevops/cache" "$_cw_log_dir"

	# Auto-seed on first run (populates state file with existing contributions)
	if [[ ! -f "$cw_state" ]]; then
		print_info "Discovering external contributions for contribution watch..."
		if bash "$cw_script" seed >/dev/null 2>&1; then
			print_info "Contribution watch seeded (external issues/PRs discovered)"
		else
			print_warning "Contribution watch seed failed (non-fatal, will retry on next run)"
		fi
	fi

	# Install/update scheduled scanner
	if [[ "$(uname -s)" == "Darwin" ]]; then
		_install_cw_launchd "$cw_label" "$cw_script" "$_cw_log_dir"
	else
		_install_cw_linux "$cw_script" "$_cw_log_dir"
	fi
	return 0
}

# Setup draft responses — private repo + local draft storage for reviewing
# AI-drafted replies to external contributions (t1555).
# Respects config: aidevops config set orchestration.draft_responses false
setup_draft_responses() {
	local dr_script="$HOME/.aidevops/agents/scripts/draft-response-helper.sh"
	if [[ -x "$dr_script" ]] && is_feature_enabled orchestration.draft_responses 2>/dev/null && is_feature_enabled orchestration.contribution_watch 2>/dev/null && command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
		mkdir -p "$HOME/.aidevops/.agent-workspace/draft-responses"
		if bash "$dr_script" init >/dev/null 2>&1; then
			print_info "Draft responses ready (private repo + local drafts)"
		else
			print_warning "Draft responses repo setup failed (non-fatal, local drafts still work)"
		fi
	fi
	return 0
}

# Setup profile README — auto-create repo and seed README if not already set up.
# Requires gh CLI authenticated. Creates username/username repo, seeds README
# with stat markers, registers in repos.json with priority: "profile".
_profile_readme_ready() {
	local pr_script="$1"
	if ! [[ -x "$pr_script" ]]; then
		return 1
	fi
	if ! command -v gh &>/dev/null; then
		return 1
	fi
	if ! gh auth status &>/dev/null; then
		return 1
	fi
	return 0
}

_run_profile_readme_init() {
	local pr_script="$1"
	print_info "Checking GitHub profile README..."
	if bash "$pr_script" init; then
		print_info "Profile README ready."
	else
		print_warning "Profile README setup failed (non-fatal, skipping)"
	fi
	return 0
}

_install_profile_readme_launchd() {
	local pr_label="$1"
	local pr_script="$2"
	local pr_plist="$HOME/Library/LaunchAgents/${pr_label}.plist"
	local _xml_pr_script _xml_pr_home
	_xml_pr_script=$(_xml_escape "$pr_script")
	_xml_pr_home=$(_xml_escape "$HOME")

	local pr_plist_content
	pr_plist_content=$(
		cat <<PR_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${pr_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${_xml_pr_script}</string>
		<string>update</string>
	</array>
	<key>StartInterval</key>
	<integer>3600</integer>
	<key>StandardOutPath</key>
	<string>${_xml_pr_home}/.aidevops/.agent-workspace/logs/profile-readme-update.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_pr_home}/.aidevops/.agent-workspace/logs/profile-readme-update.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>HOME</key>
		<string>${_xml_pr_home}</string>
	</dict>
	<key>RunAtLoad</key>
	<false/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityBackgroundIO</key>
	<true/>
	<key>Nice</key>
	<integer>10</integer>
</dict>
</plist>
PR_PLIST
	)

	if _launchd_install_if_changed "$pr_label" "$pr_plist" "$pr_plist_content"; then
		print_info "Profile README update enabled (launchd, hourly)"
	else
		print_warning "Failed to load profile README update LaunchAgent"
	fi
	return 0
}

_install_profile_readme_scheduler() {
	local pr_label="$1"
	local pr_systemd="$2"
	local pr_script="$3"
	local pr_log="$4"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		_install_profile_readme_launchd "$pr_label" "$pr_script"
		return 0
	fi

	_install_scheduler_linux \
		"$pr_systemd" \
		"aidevops: profile-readme-update" \
		"0 * * * *" \
		"\"${pr_script}\" update" \
		"3600" \
		"$pr_log" \
		"" \
		"Profile README update enabled (hourly)" \
		"Failed to install profile README update scheduler" \
		"false" \
		"true"
	return 0
}

setup_profile_readme() {
	local pr_script="$HOME/.aidevops/agents/scripts/profile-readme-helper.sh"
	local pr_label="sh.aidevops.profile-readme-update"
	if ! _profile_readme_ready "$pr_script"; then
		return 0
	fi

	# Initialize profile repo if not already set up.
	# Always run init — it's idempotent and handles:
	#   - Fresh installs (no profile repo)
	#   - Missing markers (injects them into existing README)
	#   - Diverged history (repo deleted and recreated on GitHub)
	#   - Already-initialized repos (returns early with no changes)
	_run_profile_readme_init "$pr_script"

	# Profile README auto-update scheduled job.
	# Installed whenever gh CLI is available — the update script self-heals
	# (discovers/creates the profile repo on first run via _resolve_profile_repo).
	# macOS: launchd plist (hourly) | Linux: systemd timer or cron (hourly)
	local pr_systemd="aidevops-profile-readme-update"
	local pr_log="$HOME/.aidevops/.agent-workspace/logs/profile-readme-update.log"
	mkdir -p "$HOME/.aidevops/.agent-workspace/logs"

	_install_profile_readme_scheduler "$pr_label" "$pr_systemd" "$pr_script" "$pr_log"
	return 0
}

# Detect Windows Git Bash / MINGW64 / MSYS2 environment.
# WSL reports "Linux" from uname -s and uses the cron path — correct behaviour.
# Returns 0 (true) on Windows Git Bash/MINGW/MSYS/Cygwin, 1 otherwise.
_is_windows() {
	case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

# Install OAuth token refresh via Windows Task Scheduler (schtasks).
# Args: $1=tr_script (Unix path), $2=log_dir (Unix path)
# Runs every 30 minutes, matching macOS launchd and Linux cron behaviour.
# Uses bash.exe from Git for Windows to execute the shell script.
_install_token_refresh_schtasks() {
	local tr_script="$1"
	local log_dir="$2"
	local task_name="aidevops-token-refresh"

	# Resolve bash.exe — Git for Windows ships it alongside git.exe
	local bash_exe
	bash_exe=$(command -v bash.exe 2>/dev/null || command -v bash 2>/dev/null || echo "bash")

	# Convert Unix paths to Windows paths for schtasks (requires cygpath from Git Bash)
	local tr_script_win log_dir_win bash_exe_win
	if command -v cygpath &>/dev/null; then
		tr_script_win=$(cygpath -w "$tr_script")
		log_dir_win=$(cygpath -w "$log_dir")
		bash_exe_win=$(cygpath -w "$bash_exe")
	else
		# Fallback: manual conversion (replace /c/ with C:\, forward to backslash)
		tr_script_win=$(echo "$tr_script" | sed 's|^/\([a-zA-Z]\)/|\1:\\|; s|/|\\|g')
		log_dir_win=$(echo "$log_dir" | sed 's|^/\([a-zA-Z]\)/|\1:\\|; s|/|\\|g')
		bash_exe_win="bash.exe"
	fi

	# Remove existing task (idempotent — ignore error if not present)
	schtasks /Delete /TN "$task_name" /F >/dev/null 2>&1 || true

	# Create scheduled task: every 30 minutes, run at logon, run whether logged on or not
	# /SC MINUTE /MO 30 = every 30 minutes
	# /RL HIGHEST = run with highest available privileges (needed for token writes)
	# /F = force creation (overwrite if exists)
	# The action runs bash.exe with -c to chain both refresh calls
	local action_cmd
	action_cmd="\"${bash_exe_win}\" -c \"'${tr_script_win}' refresh anthropic >> '${log_dir_win}\\token-refresh.log' 2>&1; '${tr_script_win}' refresh openai >> '${log_dir_win}\\token-refresh.log' 2>&1\""

	if schtasks /Create \
		/TN "$task_name" \
		/TR "$action_cmd" \
		/SC MINUTE \
		/MO 30 \
		/RL HIGHEST \
		/F \
		>/dev/null 2>&1; then
		print_info "OAuth token refresh enabled (schtasks, every 30 min)"
		# Run immediately to refresh any expired tokens
		schtasks /Run /TN "$task_name" >/dev/null 2>&1 || true
	else
		print_warning "Failed to create token refresh scheduled task. Run manually: schtasks /Create /TN aidevops-token-refresh /TR \"bash '${tr_script_win}' refresh anthropic\" /SC MINUTE /MO 30"
	fi
	return 0
}

# Remove OAuth token refresh Windows scheduled task (uninstall path).
_uninstall_token_refresh_schtasks() {
	local task_name="aidevops-token-refresh"
	if schtasks /Query /TN "$task_name" >/dev/null 2>&1; then
		schtasks /Delete /TN "$task_name" /F >/dev/null 2>&1 || true
		print_info "OAuth token refresh disabled (schtasks task removed)"
	fi
	return 0
}

# Setup OAuth token refresh scheduled job.
# Refreshes expired/expiring tokens every 30 min so sessions never hit
# "invalid x-api-key". Also runs at load to catch tokens that expired
# while the machine was off.
# macOS: launchd plist | Linux/WSL: systemd timer or cron | Windows Git Bash: schtasks
_oauth_token_refresh_ready() {
	local tr_script="$1"
	if ! [[ -x "$tr_script" ]]; then
		return 1
	fi
	if ! [[ -f "$HOME/.aidevops/oauth-pool.json" ]]; then
		return 1
	fi
	return 0
}

_install_token_refresh_launchd() {
	local tr_label="$1"
	local tr_script="$2"
	local tr_plist="$HOME/Library/LaunchAgents/${tr_label}.plist"
	local _xml_tr_script _xml_tr_home
	_xml_tr_script=$(_xml_escape "$tr_script")
	_xml_tr_home=$(_xml_escape "$HOME")

	local tr_plist_content
	tr_plist_content=$(
		cat <<TR_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${tr_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>-c</string>
		<string>&quot;${_xml_tr_script}&quot; refresh anthropic; &quot;${_xml_tr_script}&quot; refresh openai</string>
	</array>
	<key>StartInterval</key>
	<integer>1800</integer>
	<key>StandardOutPath</key>
	<string>${_xml_tr_home}/.aidevops/.agent-workspace/logs/token-refresh.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_tr_home}/.aidevops/.agent-workspace/logs/token-refresh.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>HOME</key>
		<string>${_xml_tr_home}</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityBackgroundIO</key>
	<true/>
	<key>Nice</key>
	<integer>10</integer>
</dict>
</plist>
TR_PLIST
	)

	if _launchd_install_if_changed "$tr_label" "$tr_plist" "$tr_plist_content"; then
		print_info "OAuth token refresh enabled (launchd, every 30 min)"
	else
		print_warning "Failed to load token refresh LaunchAgent"
	fi
	return 0
}

setup_oauth_token_refresh() {
	local tr_script="$HOME/.aidevops/agents/scripts/oauth-pool-helper.sh"
	local tr_label="sh.aidevops.token-refresh"
	if ! _oauth_token_refresh_ready "$tr_script"; then
		return 0
	fi

	local tr_log_dir="$HOME/.aidevops/.agent-workspace/logs"
	mkdir -p "$tr_log_dir"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		_install_token_refresh_launchd "$tr_label" "$tr_script"
	elif _is_windows; then
		# Windows Git Bash / MINGW64 / MSYS2: use Task Scheduler (schtasks)
		_install_token_refresh_schtasks "$tr_script" "$tr_log_dir"
	else
		# Linux / WSL without systemd: systemd timer or cron fallback
		_install_scheduler_linux \
			"aidevops-token-refresh" \
			"aidevops: token-refresh" \
			"*/30 * * * *" \
			"\"${tr_script}\" refresh anthropic; \"${tr_script}\" refresh openai" \
			"1800" \
			"${tr_log_dir}/token-refresh.log" \
			"" \
			"OAuth token refresh enabled (every 30 min)" \
			"Failed to install token refresh scheduler" \
			"true" \
			"true"
	fi
	return 0
}

# Setup repo-sync scheduler if not already installed.
# Keeps local git repos up to date with daily ff-only pulls.
# Respects config: aidevops config set orchestration.repo_sync false
setup_repo_sync() {
	local repo_sync_script="$HOME/.aidevops/agents/scripts/repo-sync-helper.sh"
	if ! [[ -x "$repo_sync_script" ]] || ! is_feature_enabled repo_sync 2>/dev/null; then
		return 0
	fi

	local _repo_sync_installed=false
	if _launchd_has_agent "com.aidevops.aidevops-repo-sync"; then
		_repo_sync_installed=true
	elif _launchd_has_agent "sh.aidevops.repo-sync"; then
		_repo_sync_installed=true
	elif crontab -l 2>/dev/null | grep -qF "aidevops-repo-sync"; then
		_repo_sync_installed=true
	elif command -v systemctl >/dev/null 2>&1 &&
		systemctl --user is-enabled "aidevops-repo-sync.timer" >/dev/null 2>&1; then
		_repo_sync_installed=true
	fi
	if [[ "$_repo_sync_installed" == "false" ]]; then
		if [[ "$NON_INTERACTIVE" == "true" ]]; then
			bash "$repo_sync_script" enable >/dev/null 2>&1 || true
			print_info "Repo sync enabled (daily). Disable: aidevops repo-sync disable"
		else
			echo ""
			echo "Repo sync keeps your local git repos up to date by running"
			echo "git pull --ff-only daily on clean repos on their default branch."
			echo ""
			setup_prompt enable_repo_sync "Enable daily repo sync? [Y/n]: " "Y"
			if [[ "$enable_repo_sync" =~ ^[Yy]?$ || -z "$enable_repo_sync" ]]; then
				bash "$repo_sync_script" enable
			else
				print_info "Skipped. Enable later: aidevops repo-sync enable"
			fi
		fi
	fi
	return 0
}
