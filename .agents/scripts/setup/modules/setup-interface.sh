#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Desktop opt-in, setup header, Bash upgrade and legacy configuration helpers.
# Sourced by setup.sh after bootstrap; globals and shared helpers come from it.

[[ -n "${_SETUP_INTERFACE_LOADED:-}" ]] && return 0
_SETUP_INTERFACE_LOADED=1

_setup_gui_desktop_install_opted_in() {
	local flag="${AIDEVOPS_GUI_DESKTOP_INSTALL:-false}"
	case "$flag" in
	1 | true | TRUE | yes | YES | on | ON)
		return 0
		;;
	esac
	return 1
}

_setup_gui_desktop_app_dir() {
	printf '%s' "${AIDEVOPS_GUI_DESKTOP_APP_DIR:-/Applications}"
	return 0
}

_setup_gui_desktop_app_exists() {
	local app_dir="$1"
	[[ -d "${app_dir}/${SETUP_GUI_APP_NAME}" ]]
	return $?
}

setup_gui_desktop_app() {
	local installer="${INSTALL_DIR}/packages/gui-desktop/scripts/install-macos-app.sh"
	local app_dir=""
	local os=""
	local rc=0

	os="$(uname -s)"
	if [[ "$os" != "$SETUP_OS_DARWIN" ]]; then
		print_skip "$SETUP_GUI_APP_NAME" "macOS only" "Run this stage from macOS when the desktop app is needed."
		setup_track_skipped "$SETUP_GUI_APP_NAME" "macOS only"
		return 0
	fi

	if [[ ! -f "$installer" ]]; then
		print_warning "${SETUP_GUI_APP_NAME} installer not found at: $installer"
		setup_track_deferred "$SETUP_GUI_APP_NAME" "Update aidevops, then run: aidevops setup --scope gui-desktop"
		return 0
	fi

	app_dir="$(_setup_gui_desktop_app_dir)"
	bash "$installer" --app-dir "$app_dir" || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		setup_track_configured "$SETUP_GUI_APP_NAME"
		return 0
	fi

	print_warning "${SETUP_GUI_APP_NAME} install skipped after installer exit $rc (non-fatal)"
	setup_track_deferred "$SETUP_GUI_APP_NAME" "Install requirements, then run: aidevops setup --scope gui-desktop"
	return 0
}

_setup_offer_gui_desktop_app() {
	local answer=""
	local app_dir=""

	if _setup_gui_desktop_install_opted_in; then
		setup_gui_desktop_app
		return 0
	fi

	app_dir="$(_setup_gui_desktop_app_dir)"
	if [[ "$(uname -s)" == "$SETUP_OS_DARWIN" ]] && _setup_gui_desktop_app_exists "$app_dir"; then
		print_info "Refreshing existing macOS ${SETUP_GUI_APP_NAME} in ${app_dir}"
		setup_gui_desktop_app
		return 0
	fi

	if [[ "$INTERACTIVE_MODE" == "true" ]]; then
		echo ""
		echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
		echo -e "${BLUE}Optional preview:${NC} Install native macOS ${SETUP_GUI_APP_NAME}"
		echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
		setup_prompt answer "Install ${SETUP_GUI_APP_NAME} now? [y/N]: " "N"
		case "$answer" in
		y | Y | yes | YES)
			setup_gui_desktop_app
			return 0
			;;
		esac
	fi

	setup_track_skipped "$SETUP_GUI_APP_NAME" "opt-in: run aidevops setup --scope gui-desktop or set AIDEVOPS_GUI_DESKTOP_INSTALL=true"
	return 0
}

# GH#18950 (t2087) + GH#18965 (t2094): ensure modern bash is installed
# and up to date on macOS. Runs after platform detection, before deploy.
# Uses the canonical `ensure` subcommand which combines install + upgrade:
#   - Missing → interactive prompt for install (or silent with --yes)
#   - Installed but drifted → silent upgrade (brew upgrade bash)
#   - Current → no-op
# Rate-limits `brew update` to 24h internally. Always fail-open — never
# blocks setup on a bash upgrade failure.
#
# Opt-out: AIDEVOPS_AUTO_UPGRADE_BASH=0 disables install + upgrade entirely.
_setup_check_bash_upgrade() {
	# Only applies to macOS; Linux bash is already modern on any current distro.
	if [[ "${AIDEVOPS_PLATFORM:-}" != "macos" ]]; then
		return 0
	fi

	local helper="${INSTALL_DIR}/.agents/scripts/bash-upgrade-helper.sh"
	[[ -x "$helper" ]] || return 0

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		# Non-interactive: ensure does everything silently (install with
		# --yes, upgrade on drift, no-op when current). Same pattern as
		# `aidevops update` — fire-and-forget.
		"$helper" ensure --yes --quiet || print_warning "bash ensure failed (non-fatal) — advisory written"
		return 0
	fi

	# Interactive: ensure prompts on first install (inherited from
	# _bu_cmd_install's read path), runs silently on upgrade. Users don't
	# see a prompt on every `./setup.sh` run — only the first one.
	"$helper" ensure || print_warning "bash ensure failed (non-fatal) — advisory written"
	return 0
}

# GH#17769: Comment out deprecated model env vars in a single credentials file.
_comment_out_deprecated_model_vars() {
	local file="$1"
	local deprecated_vars="AIDEVOPS_HEADLESS_MODELS|PULSE_MODEL"
	local deprecation_note="# DEPRECATED by aidevops v3.7+ — model routing is now automatic (GH#17769)"
	[[ -f "$file" ]] || return 0
	# Only process active assignments/exports (not already commented). Some old
	# credentials used VAR=... followed by export VAR, so clean both shapes.
	if grep -qE "^[[:space:]]*(export[[:space:]]+)?(${deprecated_vars})=" "$file" 2>/dev/null; then
		sed -i.bak -E "s/^([[:space:]]*)((export[[:space:]]+)?(${deprecated_vars})=.*)$/\\1${deprecation_note}\\
\\1# \\2/" "$file"
		rm -f "${file}.bak"
		print_info "Commented out deprecated model env vars in $(basename "$file")"
	fi
	return 0
}

# GH#17769: Comment out deprecated model env vars from credentials.sh.
# Runs on every `aidevops update`. Uses sed to comment out (not delete) lines
# so the user's file history is preserved.
_cleanup_legacy_model_config() {
	local creds_file="${HOME}/.config/aidevops/credentials.sh"
	_comment_out_deprecated_model_vars "$creds_file"

	# Clean up tenant credentials files
	local tenant_dir="${HOME}/.config/aidevops/tenants"
	if [[ -d "$tenant_dir" ]]; then
		local tenant_creds=""
		while IFS= read -r -d '' tenant_creds; do
			_comment_out_deprecated_model_vars "$tenant_creds"
		done < <(find "$tenant_dir" -name "credentials.sh" -print0 2>/dev/null)
	fi
	return 0
}

# Deploy auto-hotfix.conf template to user-level configs if not already present.
# The template ships in .agents/configs/; this copies to ~/.aidevops/configs/
# where user edits survive `aidevops update`. Existing user config is preserved.
_deploy_hotfix_config() {
	local source_conf="${INSTALL_DIR:-.}/.agents/configs/auto-hotfix.conf"
	local target_dir="$HOME/.aidevops/configs"
	local target_conf="$target_dir/auto-hotfix.conf"

	if [[ ! -f "$source_conf" ]]; then
		return 0
	fi

	# Only deploy if the user doesn't have one yet (preserve user edits)
	if [[ -f "$target_conf" ]]; then
		return 0
	fi

	mkdir -p "$target_dir"
	cp "$source_conf" "$target_conf"
	chmod 600 "$target_conf"
	return 0
}

# t2919: Early pulse plist install. The pulse launchd agent is critical
# infrastructure — without it, every other pulse-driven feature (worker
# dispatch, issue routing, cross-repo coordination) is dead. Previously,
# setup_supervisor_pulse only ran inside _setup_post_setup_steps which
# executes AFTER ~25 other migration/setup steps. When `aidevops update`
# runs unattended and any earlier step times out (e.g. brew taps, MCP
# installs, slow repo scans), the pulse plist never gets installed/refreshed
# and the runner falls behind.
#
# Install immediately after deploy_aidevops_agents (so the scripts the plist
# references already exist on disk). The late install in _setup_post_setup_steps
# remains as the canonical regenerate-on-change path — _launchd_install_if_changed
# compares content and skips reload when identical, so the second call is a
# no-op when nothing changed. Failure here is non-fatal: the late path retries.
_setup_install_pulse_plist_early() {
	local _early_os
	_early_os="$(uname -s)"
	if _should_setup_noninteractive_supervisor_pulse; then
		setup_supervisor_pulse "$_early_os" || print_warning "Early pulse plist install failed (will retry late)"
	fi
	return 0
}
