#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Scheduler setup functions: supervisor pulse, stats wrapper, process guard,
# memory pressure monitor, screen time snapshot, contribution watch,
# profile README, OAuth token refresh.
# Part of aidevops setup.sh modularization (GH#5793)

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

_resolve_headless_models_override() {
	local configured="${AIDEVOPS_HEADLESS_MODELS:-}"
	if [[ -z "$configured" ]] && type config_get &>/dev/null; then
		configured=$(config_get "orchestration.headless_models" "")
		if [[ "$configured" == "null" ]]; then
			configured=""
		fi
	fi
	printf '%s' "$configured"
	return 0
}

_resolve_pulse_model_override() {
	local configured="${PULSE_MODEL:-}"
	if [[ -z "$configured" ]] && type config_get &>/dev/null; then
		configured=$(config_get "orchestration.pulse_model" "")
		if [[ "$configured" == "null" ]]; then
			configured=""
		fi
	fi
	printf '%s' "$configured"
	return 0
}

# Setup the supervisor pulse scheduler (consent-gated autonomous orchestration).
# Uses pulse-wrapper.sh which handles dedup, orphan cleanup, and RAM-based concurrency.
# macOS: launchd plist invoking wrapper | Linux: cron entry invoking wrapper
# The plist is ALWAYS regenerated on setup.sh to pick up config changes (env vars,
# thresholds). Only the first-install prompt is gated on consent state.
setup_supervisor_pulse() {
	local _os="$1"

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
	if _scheduler_detect_installed \
		"Supervisor pulse" \
		"$pulse_label" \
		"" \
		"pulse-wrapper" \
		"" \
		"" \
		"" \
		"aidevops-supervisor-pulse"; then
		_pulse_installed=true
	fi

	# Detect dispatch backend binary location (t1665.5 — registry-driven)
	local opencode_bin
	if type rt_list_headless &>/dev/null; then
		local _sched_rt_id _sched_bin
		while IFS= read -r _sched_rt_id; do
			_sched_bin=$(rt_binary "$_sched_rt_id") || continue
			if [[ -n "$_sched_bin" ]] && command -v "$_sched_bin" &>/dev/null; then
				opencode_bin=$(command -v "$_sched_bin")
				break
			fi
		done < <(rt_list_headless)
	fi
	# Fallback if registry not loaded or no runtime found
	opencode_bin="${opencode_bin:-$(command -v opencode 2>/dev/null || echo "/opt/homebrew/bin/opencode")}"

	if [[ "$_do_install" == "true" ]]; then
		mkdir -p "$HOME/.aidevops/logs"

		if [[ "$_os" == "Darwin" ]]; then
			_install_pulse_launchd "$pulse_label" "$wrapper_script" "$opencode_bin" "$_pulse_installed"
		elif _systemd_user_available; then
			_install_pulse_systemd "aidevops-supervisor-pulse" "$wrapper_script"
		else
			_install_pulse_cron "$wrapper_script"
		fi
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
# Reads configured overrides and emits XML key/string pairs for plist embedding.
# Prints the XML fragment to stdout (may be empty if no overrides configured).
_build_pulse_headless_env_xml() {
	local _headless_xml_env=""
	local _configured_headless_models _configured_pulse_model
	_configured_headless_models=$(_resolve_headless_models_override)
	_configured_pulse_model=$(_resolve_pulse_model_override)

	if [[ -n "$_configured_headless_models" ]]; then
		local _xml_headless_models
		_xml_headless_models=$(_xml_escape "$_configured_headless_models")
		_headless_xml_env+=$'\n'
		_headless_xml_env+=$'\t\t<key>AIDEVOPS_HEADLESS_MODELS</key>'
		_headless_xml_env+=$'\n'
		_headless_xml_env+=$'\t\t'"<string>${_xml_headless_models}</string>"
	fi
	if [[ -n "$_configured_pulse_model" ]]; then
		local _xml_pulse_model
		_xml_pulse_model=$(_xml_escape "$_configured_pulse_model")
		_headless_xml_env+=$'\n'
		_headless_xml_env+=$'\t\t<key>PULSE_MODEL</key>'
		_headless_xml_env+=$'\n'
		_headless_xml_env+=$'\t\t'"<string>${_xml_pulse_model}</string>"
	fi
	if [[ -n "${AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST:-}" ]]; then
		local _xml_headless_allowlist
		_xml_headless_allowlist=$(_xml_escape "$AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST")
		_headless_xml_env+=$'\n'
		_headless_xml_env+=$'\t\t<key>AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST</key>'
		_headless_xml_env+=$'\n'
		_headless_xml_env+=$'\t\t'"<string>${_xml_headless_allowlist}</string>"
	fi

	printf '%s' "$_headless_xml_env"
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
		<string>1800</string>
		${_headless_xml_env}
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

# Install supervisor pulse via cron (Linux)
_install_pulse_cron() {
	local wrapper_script="$1"
	# Shell-escape all interpolated paths to prevent command injection
	# via $(…) or backticks if paths contain shell metacharacters
	# PATH is managed globally by _ensure_cron_path() — do NOT set inline
	# PATH= here, it overrides the global line and breaks nvm/bun/cargo.
	# OPENCODE_BIN removed — resolved from PATH at runtime via command -v.
	# See #4099 and #4240 for history.
	local _cron_pulse_dir _cron_wrapper_script _cron_headless_env=""
	local _configured_headless_models _configured_pulse_model
	_configured_headless_models=$(_resolve_headless_models_override)
	_configured_pulse_model=$(_resolve_pulse_model_override)
	# Use neutral workspace path for PULSE_DIR (GH#5136)
	_cron_pulse_dir=$(_cron_escape "${HOME}/.aidevops/.agent-workspace")
	_cron_wrapper_script=$(_cron_escape "$wrapper_script")
	if [[ -n "$_configured_headless_models" ]]; then
		local _cron_headless_models
		_cron_headless_models=$(_cron_escape "$_configured_headless_models")
		_cron_headless_env+=" AIDEVOPS_HEADLESS_MODELS=${_cron_headless_models}"
	fi
	if [[ -n "$_configured_pulse_model" ]]; then
		local _cron_pulse_model
		_cron_pulse_model=$(_cron_escape "$_configured_pulse_model")
		_cron_headless_env+=" PULSE_MODEL=${_cron_pulse_model}"
	fi
	if [[ -n "${AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST:-}" ]]; then
		local _cron_headless_allowlist
		_cron_headless_allowlist=$(_cron_escape "$AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST")
		_cron_headless_env+=" AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=${_cron_headless_allowlist}"
	fi
	(
		crontab -l 2>/dev/null | grep -v 'aidevops: supervisor-pulse' || true
		echo "*/2 * * * * PULSE_DIR=${_cron_pulse_dir}${_cron_headless_env} /bin/bash ${_cron_wrapper_script} >> \"\$HOME/.aidevops/logs/pulse-wrapper.log\" 2>&1 # aidevops: supervisor-pulse"
	) | crontab - || true
	if crontab -l 2>/dev/null | grep -qF "aidevops: supervisor-pulse"; then
		print_info "Supervisor pulse enabled (cron, every 2 min). Disable: crontab -e and remove the supervisor-pulse line"
	else
		print_warning "Failed to install supervisor pulse cron entry. See runners.md for manual setup."
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

# Install supervisor pulse via systemd user service (Linux with systemd)
# Args: $1=service_name (e.g. "aidevops-supervisor-pulse"), $2=wrapper_script
_install_pulse_systemd() {
	local service_name="$1"
	local wrapper_script="$2"
	local service_dir="$HOME/.config/systemd/user"
	local service_file="${service_dir}/${service_name}.service"
	local timer_file="${service_dir}/${service_name}.timer"

	mkdir -p "$service_dir"

	# Build environment overrides for the service
	local _env_lines=""
	local _configured_headless_models _configured_pulse_model
	_configured_headless_models=$(_resolve_headless_models_override)
	_configured_pulse_model=$(_resolve_pulse_model_override)
	if [[ -n "$_configured_headless_models" ]]; then
		_env_lines+="Environment=AIDEVOPS_HEADLESS_MODELS=${_configured_headless_models}"$'\n'
	fi
	if [[ -n "$_configured_pulse_model" ]]; then
		_env_lines+="Environment=PULSE_MODEL=${_configured_pulse_model}"$'\n'
	fi
	if [[ -n "${AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST:-}" ]]; then
		_env_lines+="Environment=AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=${AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST}"$'\n'
	fi
	_env_lines+="Environment=PULSE_DIR=${HOME}/.aidevops/.agent-workspace"$'\n'
	_env_lines+="Environment=HOME=${HOME}"$'\n'
	# Capture setup-time PATH so systemd workers find user-installed binaries
	# (e.g. ~/.npm-global/bin/opencode, ~/.local/bin/claude). Systemd user
	# services inherit only a minimal default PATH; without this, headless
	# runtime binaries are not found and workers exit 127. Matches launchd
	# plist behaviour (GH#17405).
	_env_lines+="Environment=PATH=${PATH}"$'\n'

	# Write the service unit
	printf '%s' "[Unit]
Description=aidevops Supervisor Pulse
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${wrapper_script}
${_env_lines}StandardOutput=append:${HOME}/.aidevops/logs/pulse-wrapper.log
StandardError=append:${HOME}/.aidevops/logs/pulse-wrapper.log
" >"$service_file"

	# Write the timer unit (every 2 minutes)
	# OnActiveSec=10s fires 10 seconds after the timer is enabled, bootstrapping
	# the first service run on mid-session installs where OnBootSec has already
	# elapsed and OnUnitActiveSec has no prior activation to anchor to (GH#17405).
	printf '%s' "[Unit]
Description=aidevops Supervisor Pulse Timer

[Timer]
OnActiveSec=10s
OnBootSec=2min
OnUnitActiveSec=2min
Persistent=true

[Install]
WantedBy=timers.target
" >"$timer_file"

	systemctl --user daemon-reload 2>/dev/null || true
	if systemctl --user enable --now "${service_name}.timer" 2>/dev/null; then
		print_info "Supervisor pulse enabled (systemd user timer, every 2 min)"
		print_info "Disable: systemctl --user disable --now ${service_name}.timer"
	else
		print_warning "Failed to enable systemd timer — falling back to cron"
		_install_pulse_cron "$wrapper_script"
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
setup_stats_wrapper() {
	local _pulse_lower="$1"
	# Use effective pulse state (PULSE_ENABLED) if available; fall back to consent string.
	# PULSE_ENABLED reflects the actual install decision (e.g., false when wrapper is missing).
	local _pulse_effective="${PULSE_ENABLED:-$_pulse_lower}"
	local stats_script="$HOME/.aidevops/agents/scripts/stats-wrapper.sh"
	local stats_label="com.aidevops.aidevops-stats-wrapper"
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
			local _cron_stats_script
			_cron_stats_script=$(_cron_escape "$stats_script")
			(
				crontab -l 2>/dev/null | grep -v 'aidevops: stats-wrapper' || true
				echo "*/15 * * * * /bin/bash ${_cron_stats_script} >> \"\$HOME/.aidevops/logs/stats.log\" 2>&1 # aidevops: stats-wrapper"
			) | crontab - || true
			if crontab -l 2>/dev/null | grep -qF "aidevops: stats-wrapper"; then
				print_info "Stats wrapper enabled (cron, every 15 min)"
			fi
		fi
	elif [[ "$_pulse_effective" == "false" ]]; then
		# Remove stats scheduler if pulse is disabled
		if [[ "$(uname -s)" == "Darwin" ]]; then
			local stats_plist="$HOME/Library/LaunchAgents/${stats_label}.plist"
			if _launchd_has_agent "$stats_label"; then
				launchctl unload "$stats_plist" || true
				rm -f "$stats_plist"
				print_info "Stats wrapper disabled (launchd agent removed — pulse is off)"
			fi
		else
			if crontab -l 2>/dev/null | grep -qF "aidevops: stats-wrapper"; then
				crontab -l 2>/dev/null | grep -v 'aidevops: stats-wrapper' | crontab - || true
				print_info "Stats wrapper disabled (cron entry removed — pulse is off)"
			fi
		fi
	fi
	return 0
}

# Setup failure miner — mines GitHub CI failure notifications for systemic patterns
# and auto-files root-cause issues. Runs as a pure bash script (no LLM needed).
# Installed when pulse is enabled and the helper script exists.
# macOS: launchd plist (hourly at :15) | Linux: cron (hourly at :15)
setup_failure_miner() {
	local _pulse_lower="$1"
	local _pulse_effective="${PULSE_ENABLED:-$_pulse_lower}"
	local miner_script="$HOME/.aidevops/agents/scripts/gh-failure-miner-helper.sh"
	local miner_label="sh.aidevops.routine-gh-failure-miner"
	if [[ ! -x "$miner_script" ]] || [[ "$_pulse_effective" != "true" ]]; then
		# Remove scheduler if pulse is disabled or script missing
		if [[ "$(uname -s)" == "Darwin" ]]; then
			local miner_plist="$HOME/Library/LaunchAgents/${miner_label}.plist"
			if _launchd_has_agent "$miner_label"; then
				launchctl unload "$miner_plist" 2>/dev/null || true
				rm -f "$miner_plist"
				print_info "Failure miner disabled (pulse is off or script missing)"
			fi
		else
			if crontab -l 2>/dev/null | grep -qF "aidevops: gh-failure-miner"; then
				crontab -l 2>/dev/null | grep -v 'aidevops: gh-failure-miner' | crontab - || true
				print_info "Failure miner disabled (cron entry removed)"
			fi
		fi
		return 0
	fi

	mkdir -p "$HOME/.aidevops/logs"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		local miner_plist="$HOME/Library/LaunchAgents/${miner_label}.plist"

		local _xml_miner_script _xml_miner_home _xml_miner_path _xml_miner_log
		_xml_miner_script=$(_xml_escape "$miner_script")
		_xml_miner_home=$(_xml_escape "$HOME")
		_xml_miner_path=$(_xml_escape "/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}")
		_xml_miner_log=$(_xml_escape "${HOME}/.aidevops/logs/routine-gh-failure-miner.log")

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
		local _cron_miner_script
		_cron_miner_script=$(_cron_escape "$miner_script")
		(
			crontab -l 2>/dev/null | grep -v 'aidevops: gh-failure-miner' || true
			echo "15 * * * * /bin/bash ${_cron_miner_script} create-issues --since-hours 24 --pulse-repos --systemic-threshold 2 --max-issues 3 --label auto-dispatch >> \"\$HOME/.aidevops/logs/routine-gh-failure-miner.log\" 2>&1 # aidevops: gh-failure-miner"
		) | crontab - || true
		if crontab -l 2>/dev/null | grep -qF "aidevops: gh-failure-miner"; then
			print_info "Failure miner enabled (cron, hourly at :15)"
		fi
	fi
	return 0
}

# Setup process guard — kills runaway AI processes (ShellCheck bloat, stuck workers)
# before they exhaust memory and cause kernel panics. Always installed when the
# script exists; no consent needed (safety net, not autonomous action).
# macOS: launchd plist (30s interval, RunAtLoad=true) | Linux: cron (every minute)
setup_process_guard() {
	local guard_script="$HOME/.aidevops/agents/scripts/process-guard-helper.sh"
	local guard_label="sh.aidevops.process-guard"
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
		# Linux: cron entry (every minute — cron minimum granularity)
		# Always regenerate to pick up config changes (matches macOS behavior)
		# Shell-escape path to prevent command injection via metacharacters
		local _cron_guard_script
		_cron_guard_script=$(_cron_escape "$guard_script")
		(
			crontab -l 2>/dev/null | grep -v 'aidevops: process-guard' || true
			echo "* * * * * SHELLCHECK_RSS_LIMIT_KB=524288 SHELLCHECK_RUNTIME_LIMIT=120 CHILD_RSS_LIMIT_KB=8388608 CHILD_RUNTIME_LIMIT=7200 /bin/bash ${_cron_guard_script} kill-runaways >> \"\$HOME/.aidevops/logs/process-guard.log\" 2>&1 # aidevops: process-guard"
		) | crontab - || true
		if crontab -l 2>/dev/null | grep -qF "aidevops: process-guard"; then
			print_info "Process guard enabled (cron, every minute)"
		else
			print_warning "Failed to install process guard cron entry"
		fi
	fi
	return 0
}

# Setup memory pressure monitor — process-focused memory watchdog (t1398.5, GH#2915).
# Monitors individual process RSS, runtime, session count, and aggregate memory.
# Auto-kills runaway ShellCheck (language server respawns them). Always installed
# when the script exists; no consent needed (safety net, not autonomous action).
# macOS: launchd plist (60s interval, RunAtLoad=true) | Linux: cron (every minute)
setup_memory_pressure_monitor() {
	local monitor_script="$HOME/.aidevops/agents/scripts/memory-pressure-monitor.sh"
	local monitor_label="sh.aidevops.memory-pressure-monitor"
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
		# Linux: cron entry (every minute — cron minimum granularity)
		(
			crontab -l 2>/dev/null | grep -v 'aidevops: memory-pressure-monitor' || true
			echo "* * * * * /bin/bash \"${monitor_script}\" >> \"\$HOME/.aidevops/logs/memory-pressure-launchd.log\" 2>&1 # aidevops: memory-pressure-monitor"
		) | crontab - 2>/dev/null || true
		if crontab -l 2>/dev/null | grep -qF "aidevops: memory-pressure-monitor" 2>/dev/null; then
			print_info "Memory pressure monitor enabled (cron, every minute)"
		else
			print_warning "Failed to install memory pressure monitor cron entry"
		fi
	fi
	return 0
}

# Setup screen time snapshot — captures daily screen time for contributor stats.
# Accumulates data in screen-time.jsonl (macOS Knowledge DB retains only ~28 days).
# Always installed when the script exists; no consent needed (data collection only).
# macOS: launchd plist (every 6h, RunAtLoad=true) | Linux: cron (every 6h)
setup_screen_time_snapshot() {
	local st_script="$HOME/.aidevops/agents/scripts/screen-time-helper.sh"
	local st_label="sh.aidevops.screen-time-snapshot"
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
		# Linux: cron entry (every 6 hours)
		local _cron_st_script
		_cron_st_script=$(_cron_escape "$st_script")
		(
			crontab -l 2>/dev/null | grep -v 'aidevops: screen-time-snapshot' || true
			echo "0 */6 * * * /bin/bash ${_cron_st_script} snapshot >> \"\$HOME/.aidevops/.agent-workspace/logs/screen-time-snapshot.log\" 2>&1 # aidevops: screen-time-snapshot"
		) | crontab - 2>/dev/null || true
		if crontab -l 2>/dev/null | grep -qF "aidevops: screen-time-snapshot" 2>/dev/null; then
			print_info "Screen time snapshot enabled (cron, every 6h)"
		else
			print_warning "Failed to install screen time snapshot cron entry"
		fi
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

# Install contribution watch via cron (Linux).
# Args: $1=script path, $2=log dir
_install_cw_cron() {
	local cw_script="$1"
	local _cw_log_dir="$2"
	local _cron_cw_script _cron_cw_log_dir
	_cron_cw_script=$(_cron_escape "$cw_script")
	_cron_cw_log_dir=$(_cron_escape "$_cw_log_dir")
	(
		crontab -l 2>/dev/null | grep -v 'aidevops: contribution-watch' || true
		echo "0 * * * * /bin/bash ${_cron_cw_script} scan >> \"${_cron_cw_log_dir}/contribution-watch.log\" 2>&1 # aidevops: contribution-watch"
	) | crontab - 2>/dev/null || true
	if crontab -l 2>/dev/null | grep -qF "aidevops: contribution-watch" 2>/dev/null; then
		print_info "Contribution watch enabled (cron, hourly scan)"
	else
		print_warning "Failed to install contribution watch cron entry"
	fi
	return 0
}

# Setup contribution watch — monitors external issues/PRs for new activity (t1554).
# Auto-seeds on first run (discovers authored/commented issues/PRs), then installs
# a launchd/cron job to scan periodically. Requires gh CLI authenticated.
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
		_install_cw_cron "$cw_script" "$_cw_log_dir"
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
setup_profile_readme() {
	local pr_script="$HOME/.aidevops/agents/scripts/profile-readme-helper.sh"
	local pr_label="sh.aidevops.profile-readme-update"
	if ! [[ -x "$pr_script" ]] || ! command -v gh &>/dev/null || ! gh auth status &>/dev/null; then
		return 0
	fi

	# Initialize profile repo if not already set up.
	# Always run init — it's idempotent and handles:
	#   - Fresh installs (no profile repo)
	#   - Missing markers (injects them into existing README)
	#   - Diverged history (repo deleted and recreated on GitHub)
	#   - Already-initialized repos (returns early with no changes)
	print_info "Checking GitHub profile README..."
	if bash "$pr_script" init; then
		print_info "Profile README ready."
	else
		print_warning "Profile README setup failed (non-fatal, skipping)"
	fi

	# Profile README auto-update scheduled job.
	# Installed whenever gh CLI is available — the update script self-heals
	# (discovers/creates the profile repo on first run via _resolve_profile_repo).
	# macOS: launchd plist (hourly) | Linux: cron (hourly)
	mkdir -p "$HOME/.aidevops/.agent-workspace/logs"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		local pr_plist="$HOME/Library/LaunchAgents/${pr_label}.plist"

		# XML-escape paths for safe plist embedding
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
	else
		# Linux: cron entry (hourly)
		local _cron_pr_script
		_cron_pr_script=$(_cron_escape "$pr_script")
		(
			crontab -l 2>/dev/null | grep -v 'aidevops: profile-readme-update' || true
			echo "0 * * * * /bin/bash ${_cron_pr_script} update >> \"\$HOME/.aidevops/.agent-workspace/logs/profile-readme-update.log\" 2>&1 # aidevops: profile-readme-update"
		) | crontab - 2>/dev/null || true
		if crontab -l 2>/dev/null | grep -qF "aidevops: profile-readme-update" 2>/dev/null; then
			print_info "Profile README update enabled (cron, hourly)"
		else
			print_warning "Failed to install profile README update cron entry"
		fi
	fi
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
# macOS: launchd plist | Linux/WSL: cron | Windows Git Bash: schtasks
setup_oauth_token_refresh() {
	local tr_script="$HOME/.aidevops/agents/scripts/oauth-pool-helper.sh"
	local tr_label="sh.aidevops.token-refresh"
	if ! [[ -x "$tr_script" ]] || ! [[ -f "$HOME/.aidevops/oauth-pool.json" ]]; then
		return 0
	fi

	local tr_log_dir="$HOME/.aidevops/.agent-workspace/logs"
	mkdir -p "$tr_log_dir"

	if [[ "$(uname -s)" == "Darwin" ]]; then
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
	elif _is_windows; then
		# Windows Git Bash / MINGW64 / MSYS2: use Task Scheduler (schtasks)
		_install_token_refresh_schtasks "$tr_script" "$tr_log_dir"
	else
		# Linux / WSL: cron entry (every 30 min)
		local _cron_tr_script
		_cron_tr_script=$(_cron_escape "$tr_script")
		(
			crontab -l 2>/dev/null | grep -v 'aidevops: token-refresh' || true
			echo "*/30 * * * * /bin/bash ${_cron_tr_script} refresh anthropic >> \"\$HOME/.aidevops/.agent-workspace/logs/token-refresh.log\" 2>&1; /bin/bash ${_cron_tr_script} refresh openai >> \"\$HOME/.aidevops/.agent-workspace/logs/token-refresh.log\" 2>&1 # aidevops: token-refresh"
		) | crontab - 2>/dev/null || true
		if crontab -l 2>/dev/null | grep -qF "aidevops: token-refresh" 2>/dev/null; then
			print_info "OAuth token refresh enabled (cron, every 30 min)"
		else
			print_warning "Failed to install token refresh cron entry"
		fi
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
	elif crontab -l 2>/dev/null | grep -qF "aidevops-repo-sync"; then
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
