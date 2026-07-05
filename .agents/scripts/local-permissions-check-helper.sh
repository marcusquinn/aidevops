#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
STATUS_UNKNOWN="unknown"
STATUS_MISSING="missing"
STATE_INSTALLED="installed"
PLATFORM_DARWIN="Darwin"
JSON_FIELD_ACTIVE_HOST="active_host"
JSON_FIELD_NAME="name"
JSON_FIELD_PLATFORM="platform"
JSON_FIELD_SUPPORTED="supported"
JSON_FIELD_STATUS="status"

APP_ROWS=$(cat <<'DATA'
aidevops.app|aidevops|sh.aidevops.app,com.aidevops.app|aidevops.app|host|Full Disk Access;Accessibility;Automation: System Events;Screen Recording|Enable privacy permissions for aidevops.app when launching sessions from the desktop app.
Tabby|Tabby|org.tabby,org.tabby-terminal,com.eugeny.tabby|Tabby.app|host|Full Disk Access;Accessibility;Automation: System Events;Screen Recording|Enable permissions for Tabby, because macOS grants privacy access to the terminal host app.
Terminal|Terminal|com.apple.Terminal|Terminal.app|host|Full Disk Access;Accessibility;Automation: System Events;Screen Recording|Enable permissions for Terminal when aidevops is launched from Terminal.
iTerm2|iTerm2|com.googlecode.iterm2,com.googlecode.iterm2.iTerm|iTerm.app,iTerm2.app|host|Full Disk Access;Accessibility;Automation: System Events;Screen Recording|Enable permissions for iTerm or iTerm2 when aidevops is launched there.
OpenCode Desktop|OpenCode|ai.opencode.desktop,sh.opencode.desktop,com.opencode.desktop|OpenCode.app,OpenCode Desktop.app|host|Full Disk Access;Accessibility;Screen Recording|Enable permissions for OpenCode Desktop when it hosts the session.
Cursor|Cursor|com.todesktop.230313mzl4w4u92,com.cursor.Cursor|Cursor.app|editor|Full Disk Access;Accessibility;Screen Recording|Enable permissions for Cursor when its integrated terminal hosts aidevops.
Claude Desktop|Claude|com.anthropic.claudefordesktop,com.anthropic.claude|Claude.app,Claude Desktop.app|host|Full Disk Access;Accessibility;Automation: System Events;Screen Recording;Microphone;Camera|Enable required permissions for Claude only when launching aidevops workflows from Claude.
Claude Code launcher|Claude Code|com.anthropic.claudecode,com.anthropic.claude-code|Claude Code.app|host|Full Disk Access;Accessibility;Screen Recording|Enable permissions for the Claude Code launcher if it is the parent host.
Visual Studio Code|Code|com.microsoft.VSCode|Visual Studio Code.app|editor|Full Disk Access;Accessibility;Screen Recording|Enable permissions for VS Code when its terminal hosts aidevops.
Zed|Zed|dev.zed.Zed|Zed.app|editor|Full Disk Access;Accessibility;Screen Recording|Enable permissions for Zed when its terminal hosts aidevops.
Warp|Warp|dev.warp.Warp-Stable,dev.warp.Warp|Warp.app|host|Full Disk Access;Accessibility;Automation: System Events;Screen Recording|Enable permissions for Warp when aidevops is launched there.
DATA
)

PERMISSION_ROWS=$(cat <<'DATA'
Full Disk Access|kTCCServiceSystemPolicyAllFiles|Trash cleanup, protected Library paths, repo/runtime data access|required|Enable Full Disk Access for the host app in System Settings > Privacy & Security.
Files and Folders|kTCCServiceSystemPolicyDesktopFolder,kTCCServiceSystemPolicyDocumentsFolder,kTCCServiceSystemPolicyDownloadsFolder,kTCCServiceSystemPolicyNetworkVolumes,kTCCServiceSystemPolicyRemovableVolumes|Scoped Desktop/Documents/Downloads/Network/Removable volume access|conditional|Grant scoped file access if workflows touch these locations.
Accessibility|kTCCServiceAccessibility|UI automation and app-control workflows|required|Enable Accessibility for the host app in System Settings > Privacy & Security.
Automation: System Events|kTCCServiceAppleEvents|Finder, System Events, Terminal, iTerm, Tabby, Notes and Calendar control|conditional|Allow Automation prompts for the host app and target app.
Screen Recording|kTCCServiceScreenCapture|Screenshots, browser QA, and UI verification|conditional|Enable Screen Recording for the host app when screenshot workflows are used.
Microphone|kTCCServiceMicrophone|Voice workflows|optional|Grant only when voice workflows need recording.
Camera|kTCCServiceCamera|Video workflows|optional|Grant only when video workflows need camera input.
Contacts|kTCCServiceAddressBook|Contacts productivity integrations|optional|Grant only when Contacts integrations are used.
Calendar|kTCCServiceCalendar|Calendar productivity integrations|optional|Grant only when Calendar integrations are used.
Reminders|kTCCServiceReminders|Reminders productivity integrations|optional|Grant only when Reminders integrations are used.
DATA
)

json_escape() {
	local value="$1"
	value=${value//\\/\\\\}
	value=${value//\"/\\\"}
	value=${value//$'\n'/\\n}
	printf '%s' "$value"
	return 0
}

platform_name() {
	if [[ -n "${LPC_UNAME:-}" ]]; then
		printf '%s\n' "$LPC_UNAME"
		return 0
	fi
	uname 2>/dev/null || printf '%s\n' "$STATUS_UNKNOWN"
	return 0
}

is_macos() {
	local platform
	platform="$(platform_name)"
	[[ "$platform" == "$PLATFORM_DARWIN" ]]
	return $?
}

is_windows_platform() {
	local platform
	platform="$(platform_name)"
	case "$platform" in
		MINGW*|MSYS*|CYGWIN*) return 0 ;;
	esac
	return 1
}

is_wsl_session() {
	if [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]]; then
		return 0
	fi
	if [[ -r /proc/sys/kernel/osrelease ]]; then
		local release
		IFS= read -r release </proc/sys/kernel/osrelease || release=""
		release="$(printf '%s' "$release" | tr '[:upper:]' '[:lower:]')"
		if [[ "$release" == *microsoft* || "$release" == *wsl* ]]; then
			return 0
		fi
	fi
	return 1
}

platform_family() {
	local platform
	platform="$(platform_name)"
	if [[ "$platform" == "$PLATFORM_DARWIN" ]]; then
		printf 'macos'
	elif is_windows_platform; then
		printf 'windows'
	elif [[ "$platform" == "Linux" ]] && is_wsl_session; then
		printf 'wsl'
	elif [[ "$platform" == "Linux" ]]; then
		printf 'linux'
	else
		printf 'unknown'
	fi
	return 0
}

usage() {
	cat <<'USAGE'
Usage: local-permissions-check-helper.sh report|json|doctor|apps [--app APP|--all|--active-host]

Read-only local capability diagnostic for aidevops host/runtime permissions.
macOS reports TCC host-app privacy state; Linux and Windows/WSL report safe
session, sandbox, filesystem, and automation caveats. The helper never resets,
grants, changes policy, or prompts for permissions.
USAGE
	return 0
}

app_field() {
	local row="$1"
	local field="$2"
	IFS='|' read -r display match bundles paths role permissions action <<<"$row"
	case "$field" in
		display) printf '%s' "$display" ;;
		match) printf '%s' "$match" ;;
		bundles) printf '%s' "$bundles" ;;
		paths) printf '%s' "$paths" ;;
		role) printf '%s' "$role" ;;
		permissions) printf '%s' "$permissions" ;;
		action) printf '%s' "$action" ;;
		*) return 1 ;;
	esac
	return 0
}

permission_field() {
	local row="$1"
	local field="$2"
	IFS='|' read -r name services needed tier action <<<"$row"
	case "$field" in
		name) printf '%s' "$name" ;;
		services) printf '%s' "$services" ;;
		needed) printf '%s' "$needed" ;;
		tier) printf '%s' "$tier" ;;
		action) printf '%s' "$action" ;;
		*) return 1 ;;
	esac
	return 0
}

match_app_row() {
	local query="$1"
	local lowered_query
	lowered_query="$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')"
	while IFS= read -r row; do
		local display match bundles paths lowered_blob
		display="$(app_field "$row" display)"
		match="$(app_field "$row" match)"
		bundles="$(app_field "$row" bundles)"
		paths="$(app_field "$row" paths)"
		lowered_blob="$(printf '%s' "$display $match $bundles $paths" | tr '[:upper:]' '[:lower:]')"
		if [[ "$lowered_blob" == *"$lowered_query"* ]]; then
			printf '%s\n' "$row"
			return 0
		fi
	done <<<"$APP_ROWS"
	return 1
}

detect_active_host() {
	if [[ -n "${LPC_ACTIVE_HOST:-}" ]]; then
		printf '%s\n' "$LPC_ACTIVE_HOST"
		return 0
	fi

	local pid="$$"
	local depth=0
	while [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 && "$depth" -lt 20 ]]; do
		local comm parent candidate
		comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
		candidate="$(basename "$comm" 2>/dev/null || printf '%s' "$comm")"
		case "$candidate" in
			Tabby|Terminal|iTerm|iTerm2|OpenCode|Cursor|Claude|Code|Zed|Warp)
				printf '%s\n' "$candidate"
				return 0
				;;
		esac
		parent="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ' || true)"
		pid="$parent"
		depth=$((depth + 1))
	done
	printf '%s\n' "$STATUS_UNKNOWN"
	return 0
}

app_is_installed() {
	local row="$1"
	local paths roots app_name root
	paths="$(app_field "$row" paths)"
	roots="${LPC_APP_ROOTS:-/Applications:/System/Applications:${HOME:+$HOME/Applications}}"
	IFS=',' read -r -a app_names <<<"$paths"
	IFS=':' read -r -a root_names <<<"$roots"
	for app_name in "${app_names[@]}"; do
		for root in "${root_names[@]}"; do
			if [[ -d "$root/$app_name" ]]; then
				return 0
			fi
		done
	done
	return 1
}

bundle_for_row() {
	local row="$1"
	local bundles first_bundle
	bundles="$(app_field "$row" bundles)"
	first_bundle="${bundles%%,*}"
	printf '%s' "$first_bundle"
	return 0
}

tcc_fixture_status() {
	local service="$1"
	local bundle_id="$2"
	local fixture="${LPC_TCC_ROWS:-}"
	[[ -n "$fixture" && -r "$fixture" ]] || return 2
	while IFS='|' read -r row_service row_client row_auth row_allowed; do
		[[ -n "${row_service:-}" ]] || continue
		if [[ "$row_service" == "$service" && "$row_client" == "$bundle_id" ]]; then
			if [[ "$row_auth" == "2" || "$row_allowed" == "1" ]]; then
				printf 'granted'
				return 0
			fi
			if [[ "$row_auth" == "0" || "$row_allowed" == "0" ]]; then
				printf 'denied'
				return 0
			fi
			printf '%s' "$STATUS_UNKNOWN"
			return 0
		fi
	done <"$fixture"
	printf 'missing'
	return 0
}

tcc_db_path() {
	if [[ -n "${LPC_TCC_DB:-}" ]]; then
		printf '%s' "$LPC_TCC_DB"
		return 0
	fi
	printf '%s' "${HOME:+$HOME/Library/Application Support/com.apple.TCC/TCC.db}"
	return 0
}

sqlite_has_column() {
	local db="$1"
	local column="$2"
	sqlite3 "$db" 'PRAGMA table_info(access);' 2>/dev/null | awk -F'|' -v column="$column" '$2 == column { found = 1 } END { exit found ? 0 : 1 }'
	return $?
}

tcc_sqlite_status() {
	local service="$1"
	local bundle_id="$2"
	local db
	db="$(tcc_db_path)"
	[[ -r "$db" ]] || return 2
	command -v sqlite3 >/dev/null 2>&1 || return 2

	local select_expr result escaped_service escaped_bundle
	escaped_service="${service//\'/\'\'}"
	escaped_bundle="${bundle_id//\'/\'\'}"
	if sqlite_has_column "$db" auth_value; then
		select_expr='auth_value'
	elif sqlite_has_column "$db" allowed; then
		select_expr='allowed'
	else
		return 2
	fi
	result="$(sqlite3 "$db" "SELECT ${select_expr} FROM access WHERE service='${escaped_service}' AND client='${escaped_bundle}' ORDER BY last_modified DESC LIMIT 1;" 2>/dev/null)" || return 2
	if [[ -z "$result" ]]; then
		printf 'missing'
		return 0
	fi
	case "$result" in
		2|1) printf 'granted' ;;
		0) printf 'denied' ;;
		*) printf '%s' "$STATUS_UNKNOWN" ;;
	esac
	return 0
}

permission_status() {
	local permission_name="$1"
	local bundle_id="$2"
	local permission_row services service status aggregate
	permission_row="$(printf '%s\n' "$PERMISSION_ROWS" | while IFS= read -r row; do [[ "$(permission_field "$row" name)" == "$permission_name" ]] && printf '%s\n' "$row" && break; done)"
	services="$(permission_field "$permission_row" services)"
	aggregate="$STATUS_MISSING"
	IFS=',' read -r -a service_names <<<"$services"
	for service in "${service_names[@]}"; do
		if status="$(tcc_fixture_status "$service" "$bundle_id")"; then
			:
		elif status="$(tcc_sqlite_status "$service" "$bundle_id")"; then
			:
		else
			printf '%s' "$STATUS_UNKNOWN"
			return 0
		fi
		case "$status" in
			granted) printf 'granted'; return 0 ;;
			denied) aggregate="denied" ;;
			"$STATUS_UNKNOWN") aggregate="$STATUS_UNKNOWN" ;;
		esac
	done
	printf '%s' "$aggregate"
	return 0
}

status_action() {
	local status="$1"
	local app_display="$2"
	local permission_name="$3"
	case "$status" in
		granted) printf 'OK' ;;
		denied) printf 'Re-enable %s for %s in System Settings' "$permission_name" "$app_display" ;;
		missing) printf 'Enable for %s' "$app_display" ;;
		"$STATUS_UNKNOWN") printf 'Check System Settings; TCC database may be unreadable without Full Disk Access' ;;
		*) printf 'Review manually' ;;
	esac
	return 0
}

selected_app_rows() {
	local selector="$1"
	local active row
	case "$selector" in
		all)
			printf '%s\n' "$APP_ROWS"
			return 0
			;;
		active)
			active="$(detect_active_host)"
			if row="$(match_app_row "$active")"; then
				printf '%s\n' "$row"
			else
				match_app_row Tabby || true
			fi
			return 0
			;;
		*)
			match_app_row "$selector" || true
			return 0
			;;
	esac
}

render_unsupported_report() {
	local format="$1"
	local platform
	platform="$(platform_name)"
	if [[ "$format" == "json" ]]; then
		printf '{"%s":"%s","%s":false,"%s":"%s","checks":[{"%s":"platform support","%s":"unknown","needed_for":"local capability diagnostics","action":"Review this platform manually; no safe backend is available yet","evidence":"unrecognized uname"}]}\n' "$JSON_FIELD_PLATFORM" "$(json_escape "$platform")" "$JSON_FIELD_SUPPORTED" "$JSON_FIELD_ACTIVE_HOST" "$(json_escape "$(detect_active_host)")" "$JSON_FIELD_NAME" "$JSON_FIELD_STATUS"
	else
		printf 'local-permissions-check: unsupported platform (%s)\n' "$platform"
		printf 'This diagnostic is read-only; no safe platform backend is available yet.\n'
	fi
	return 0
}

env_status() {
	local value="$1"
	if [[ -n "$value" && "$value" != "$STATUS_UNKNOWN" ]]; then
		printf 'conditional'
	else
		printf '%s' "$STATUS_UNKNOWN"
	fi
	return 0
}

linux_desktop_evidence() {
	local desktop="${XDG_CURRENT_DESKTOP:-}"
	local session="${XDG_SESSION_TYPE:-}"
	local display="$STATUS_MISSING"
	if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
		display="Wayland display variable present"
	elif [[ -n "${DISPLAY:-}" ]]; then
		display="X11 display variable present"
	fi
	if [[ -n "$desktop" || -n "$session" ]]; then
		printf 'desktop=%s session=%s; %s' "${desktop:-unknown}" "${session:-unknown}" "$display"
	else
		printf 'desktop/session variables missing; %s' "$display"
	fi
	return 0
}

linux_desktop_status() {
	if [[ -n "${XDG_CURRENT_DESKTOP:-}" || -n "${XDG_SESSION_TYPE:-}" || -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" ]]; then
		printf 'conditional'
	else
		printf '%s' "$STATUS_UNKNOWN"
	fi
	return 0
}

sandbox_evidence() {
	local evidence="none detected"
	if [[ -n "${FLATPAK_ID:-}" || -e /.flatpak-info ]]; then
		evidence="Flatpak indicator present"
	elif [[ -n "${SNAP:-}" || -n "${SNAP_NAME:-}" ]]; then
		evidence="Snap indicator present"
	elif [[ -f /.dockerenv || -n "${container:-}" ]]; then
		evidence="container indicator present"
	elif is_wsl_session; then
		evidence="WSL indicator present"
	fi
	printf '%s' "$evidence"
	return 0
}

sandbox_status() {
	if [[ -n "${FLATPAK_ID:-}" || -e /.flatpak-info || -n "${SNAP:-}" || -n "${SNAP_NAME:-}" || -f /.dockerenv || -n "${container:-}" ]] || is_wsl_session; then
		printf 'conditional'
	else
		printf 'missing'
	fi
	return 0
}

trash_status() {
	if [[ -n "${XDG_DATA_HOME:-}" && -d "${XDG_DATA_HOME}/Trash" ]]; then
		printf 'granted'
	elif [[ -n "${HOME:-}" && -d "${HOME}/.local/share/Trash" ]]; then
		printf 'granted'
	else
		printf '%s' "$STATUS_UNKNOWN"
	fi
	return 0
}

systemd_user_status() {
	if [[ -n "${XDG_RUNTIME_DIR:-}" && -S "${XDG_RUNTIME_DIR}/systemd/private" ]]; then
		printf 'granted'
	elif command -v systemctl >/dev/null 2>&1; then
		printf 'conditional'
	else
		printf '%s' "$STATUS_UNKNOWN"
	fi
	return 0
}

windows_host_evidence() {
	local evidence
	evidence="shell=$(platform_name)"
	if [[ -n "${WT_SESSION:-}" ]]; then
		evidence="${evidence}; Windows Terminal session variable present"
	fi
	if [[ -n "${TERM_PROGRAM:-}" ]]; then
		evidence="${evidence}; TERM_PROGRAM=$(json_escape "$TERM_PROGRAM")"
	fi
	if [[ -n "${VSCODE_PID:-}" ]]; then
		evidence="${evidence}; VS Code host variable present"
	fi
	printf '%s' "$evidence"
	return 0
}

powershell_policy_evidence() {
	local shell_name=""
	if command -v pwsh >/dev/null 2>&1; then
		shell_name="pwsh"
	elif command -v powershell.exe >/dev/null 2>&1; then
		shell_name="powershell.exe"
	elif command -v powershell >/dev/null 2>&1; then
		shell_name="powershell"
	fi
	if [[ -n "$shell_name" ]]; then
		printf 'PowerShell available for non-mutating Get-ExecutionPolicy checks (%s)' "$shell_name"
	else
		printf 'PowerShell not found in current PATH'
	fi
	return 0
}

linux_check_rows() {
	local platform active desktop_status desktop_evidence sandbox_status_value sandbox_evidence_value trash_status_value systemd_status_value
	platform="$(platform_name)"
	active="$(detect_active_host)"
	desktop_status="$(linux_desktop_status)"
	desktop_evidence="$(linux_desktop_evidence)"
	sandbox_status_value="$(sandbox_status)"
	sandbox_evidence_value="$(sandbox_evidence)"
	trash_status_value="$(trash_status)"
	systemd_status_value="$(systemd_user_status)"
	printf 'platform/session|conditional|runtime-specific aidevops workflows|Use platform/session evidence to decide whether desktop automation, shell, or service workflows are available|uname=%s\n' "$platform"
	printf 'active host|%s|host-specific troubleshooting|Grant or debug permissions on the terminal/editor host when the OS attaches permissions to the host|active_host=%s\n' "$(env_status "$active")" "$active"
	printf 'desktop session|%s|screenshots and UI automation|Wayland often requires desktop portals; X11 behaviour differs by compositor and tool|%s\n' "$desktop_status" "$desktop_evidence"
	printf 'sandbox boundary|%s|filesystem, browser, and UI automation|If sandbox indicators are present, check Flatpak/Snap/container/WSL portal and filesystem grants separately|%s\n' "$sandbox_status_value" "$sandbox_evidence_value"
	printf 'XDG Trash|%s|safe cleanup of temporary worktrees|Ensure the host session exposes an XDG Trash location; this helper only checks common marker directories|common XDG Trash marker check\n' "$trash_status_value"
	printf 'systemd user manager|%s|scheduled/background local services|Use systemctl --user diagnostics manually when service workflows fail; helper does not start services|systemd user socket or command availability check\n' "$systemd_status_value"
	return 0
}

windows_check_rows() {
	local platform active wsl_status wsl_evidence ps_status ps_evidence host_evidence
	platform="$(platform_name)"
	active="$(detect_active_host)"
	wsl_status="$STATUS_MISSING"
	wsl_evidence="not detected"
	if is_wsl_session; then
		wsl_status="conditional"
		wsl_evidence="WSL environment indicator present; Windows app privacy and Linux filesystem permissions are separate"
	fi
	ps_status="$(if command -v pwsh >/dev/null 2>&1 || command -v powershell.exe >/dev/null 2>&1 || command -v powershell >/dev/null 2>&1; then printf 'conditional'; else printf '%s' "$STATUS_UNKNOWN"; fi)"
	ps_evidence="$(powershell_policy_evidence)"
	host_evidence="$(windows_host_evidence)"
	printf 'platform/runtime|conditional|Windows shell and filesystem workflows|Interpret results according to the current shell: Git Bash, MSYS, Cygwin, PowerShell, or WSL|uname=%s OS=%s\n' "$platform" "${OS:-unknown}"
	printf 'active host|%s|host-specific troubleshooting|Check permissions and terminal privacy on the parent terminal/editor host when applicable|active_host=%s\n' "$(env_status "$active")" "$active"
	printf 'WSL boundary|%s|cross-boundary file, browser, and Windows app automation|Keep Windows privacy permissions separate from Linux filesystem and WSL distribution permissions|%s\n' "$wsl_status" "$wsl_evidence"
	printf 'PowerShell execution policy|%s|script execution from PowerShell-adjacent workflows|Query Get-ExecutionPolicy manually if PowerShell scripts fail; this helper does not change policy|%s\n' "$ps_status" "$ps_evidence"
	printf 'Protected folders / Defender CFA|%s|writes to Desktop, Documents, and protected folders|Check Windows Security Controlled Folder Access manually when writes are blocked; no safe shell signal was assumed|manual check required\n' "$STATUS_UNKNOWN"
	printf 'Windows host hints|conditional|terminal/editor-specific permissions|Use exposed environment hints to identify Windows Terminal, VS Code, Cursor, or another host|%s\n' "$host_evidence"
	return 0
}

render_check_table() {
	local rows="$1"
	printf '%-32s %-11s %-38s %s\n' 'Check' 'Status' 'Needed for' 'Action'
	printf '%-32s %-11s %-38s %s\n' '-----' '------' '----------' '------'
	while IFS='|' read -r name status needed action evidence; do
		[[ -n "${name:-}" ]] || continue
		printf '%-32s %-11s %-38s %s\n' "$name" "$status" "$needed" "$action"
		printf '  evidence: %s\n' "$evidence"
	done <<<"$rows"
	return 0
}

render_platform_report() {
	local family="$1"
	local rows active platform
	active="$(detect_active_host)"
	platform="$(platform_name)"
	case "$family" in
		linux) rows="$(linux_check_rows)" ;;
		wsl|windows) rows="$(windows_check_rows)" ;;
		*) render_unsupported_report report; return 0 ;;
	esac
	printf 'local-permissions-check: %s capability report (%s)\n' "$family" "$platform"
	printf 'Active host: %s\n' "$active"
	printf 'Safety: read-only; no permission resets, policy changes, sudo/admin actions, or private directory listings.\n\n'
	render_check_table "$rows"
	return 0
}

render_platform_json() {
	local family="$1"
	local rows active platform first_check=true
	active="$(detect_active_host)"
	platform="$(platform_name)"
	case "$family" in
		linux) rows="$(linux_check_rows)" ;;
		wsl|windows) rows="$(windows_check_rows)" ;;
		*) render_unsupported_report json; return 0 ;;
	esac
	printf '{"%s":"%s","family":"%s","%s":true,"%s":"%s","checks":[' "$JSON_FIELD_PLATFORM" "$(json_escape "$platform")" "$(json_escape "$family")" "$JSON_FIELD_SUPPORTED" "$JSON_FIELD_ACTIVE_HOST" "$(json_escape "$active")"
	while IFS='|' read -r name status needed action evidence; do
		[[ -n "${name:-}" ]] || continue
		if [[ "$first_check" == true ]]; then
			first_check=false
		else
			printf ','
		fi
		printf '{"%s":"%s","%s":"%s","needed_for":"%s","action":"%s","evidence":"%s"}' "$JSON_FIELD_NAME" "$(json_escape "$name")" "$JSON_FIELD_STATUS" "$(json_escape "$status")" "$(json_escape "$needed")" "$(json_escape "$action")" "$(json_escape "$evidence")"
	done <<<"$rows"
	printf ']}\n'
	return 0
}

render_apps() {
	if ! is_macos; then
		printf 'Host/runtime app inventory is macOS-specific.\n'
		printf 'Active host: %s\n' "$(detect_active_host)"
		printf 'Use report or json for %s capability checks.\n' "$(platform_family)"
		return 0
	fi
	printf 'Installed aidevops host/editor app inventory:\n\n'
	while IFS= read -r row; do
		local display role installed
		display="$(app_field "$row" display)"
		role="$(app_field "$row" role)"
		installed="not found"
		if app_is_installed "$row"; then
			installed="$STATE_INSTALLED"
		fi
		printf '%-24s %-8s %s\n' "$display" "$role" "$installed"
	done <<<"$APP_ROWS"
	return 0
}

render_report() {
	local selector="$1"
	if ! is_macos; then
		render_platform_report "$(platform_family)"
		return 0
	fi

	local active active_row active_bundle active_display
	active="$(detect_active_host)"
	active_row="$(match_app_row "$active" || true)"
	active_display="$STATUS_UNKNOWN"
	active_bundle="$STATUS_UNKNOWN"
	if [[ -n "$active_row" ]]; then
		active_display="$(app_field "$active_row" display)"
		active_bundle="$(bundle_for_row "$active_row")"
	fi
	printf 'Active host: %s (bundle: %s)\n' "$active_display" "$active_bundle"
	printf 'Note: macOS grants privacy permissions to the host app, not child shell/opencode/aidevops processes.\n\n'
	printf '%-26s %-40s %-9s %s\n' 'Permission' 'Needed for' 'Status' 'Action'
	printf '%-26s %-40s %-9s %s\n' '----------' '----------' '------' '------'

	while IFS= read -r row; do
		[[ -n "$row" ]] || continue
		local display bundle permissions permission permission_row needed status action
		display="$(app_field "$row" display)"
		bundle="$(bundle_for_row "$row")"
		permissions="$(app_field "$row" permissions)"
		IFS=';' read -r -a permission_names <<<"$permissions"
		for permission in "${permission_names[@]}"; do
			permission_row="$(printf '%s\n' "$PERMISSION_ROWS" | while IFS= read -r prow; do [[ "$(permission_field "$prow" name)" == "$permission" ]] && printf '%s\n' "$prow" && break; done)"
			needed="$(permission_field "$permission_row" needed)"
			status="$(permission_status "$permission" "$bundle")"
			action="$(status_action "$status" "$display" "$permission")"
			printf '%-26s %-40s %-9s %s\n' "$permission" "$needed" "$status" "$action"
		done
	done < <(selected_app_rows "$selector")

	printf '\nInstalled host/editor apps:\n'
	while IFS= read -r row; do
		local display marker
		display="$(app_field "$row" display)"
		marker="not found"
		if app_is_installed "$row"; then
			marker="$STATE_INSTALLED"
		fi
		printf '%s\n' "- ${display}: ${marker}"
	done <<<"$APP_ROWS"
	printf '\nTrash cleanup symptom: if a Tabby-launched session cannot move temp clones to Trash, grant Full Disk Access to Tabby.\n'
	return 0
}

render_json() {
	local selector="$1"
	if ! is_macos; then
		render_platform_json "$(platform_family)"
		return 0
	fi

	local active first_app=true
	active="$(detect_active_host)"
	printf '{"%s":"%s","%s":true,"%s":"%s","privacy_model":"permissions apply to the host app","apps":[' "$JSON_FIELD_PLATFORM" "$PLATFORM_DARWIN" "$JSON_FIELD_SUPPORTED" "$JSON_FIELD_ACTIVE_HOST" "$(json_escape "$active")"
	while IFS= read -r row; do
		[[ -n "$row" ]] || continue
		local display bundle role installed permissions first_perm permission status
		display="$(app_field "$row" display)"
		bundle="$(bundle_for_row "$row")"
		role="$(app_field "$row" role)"
		installed=false
		if app_is_installed "$row"; then
			installed=true
		fi
		if [[ "$first_app" == true ]]; then
			first_app=false
		else
			printf ','
		fi
		printf '{"%s":"%s","bundle":"%s","role":"%s","installed":%s,"permissions":[' "$JSON_FIELD_NAME" "$(json_escape "$display")" "$(json_escape "$bundle")" "$(json_escape "$role")" "$installed"
		permissions="$(app_field "$row" permissions)"
		IFS=';' read -r -a permission_names <<<"$permissions"
		first_perm=true
		for permission in "${permission_names[@]}"; do
			status="$(permission_status "$permission" "$bundle")"
			if [[ "$first_perm" == true ]]; then
				first_perm=false
			else
				printf ','
			fi
			printf '{"%s":"%s","%s":"%s"}' "$JSON_FIELD_NAME" "$(json_escape "$permission")" "$JSON_FIELD_STATUS" "$(json_escape "$status")"
		done
		printf ']}'
	done < <(selected_app_rows "$selector")
	printf ']}\n'
	return 0
}

parse_selector() {
	local selector="active"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--all) selector="all"; shift ;;
			--active-host) selector="active"; shift ;;
			--app)
				shift
				selector="${1:-}"
				shift || true
				;;
			*) shift ;;
		esac
	done
	printf '%s' "$selector"
	return 0
}

main() {
	local command="${1:-report}"
	shift || true
	local selector
	selector="$(parse_selector "$@")"
	case "$command" in
		report) render_report "$selector" ;;
		json) render_json "$selector" ;;
		doctor) render_report "$selector" ;;
		apps) render_apps ;;
		-h|--help|help) usage ;;
		*) usage; return 1 ;;
	esac
	return 0
}

main "$@"
