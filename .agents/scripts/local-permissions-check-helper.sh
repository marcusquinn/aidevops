#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
STATUS_UNKNOWN="unknown"
STATE_INSTALLED="installed"

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
	[[ "$platform" == "Darwin" ]]
	return $?
}

usage() {
	cat <<'USAGE'
Usage: local-permissions-check-helper.sh report|json|doctor|apps [--app APP|--all|--active-host]

Read-only macOS TCC diagnostic for aidevops host-app permissions. The helper
never resets, grants, or prompts for permissions.
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
	roots="${LPC_APP_ROOTS:-/Applications:/System/Applications:${HOME}/Applications}"
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
	printf '%s/Library/Application Support/com.apple.TCC/TCC.db' "$HOME"
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
	result="$(sqlite3 "$db" "SELECT ${select_expr} FROM access WHERE service='${escaped_service}' AND client='${escaped_bundle}' ORDER BY last_modified DESC LIMIT 1;" 2>/dev/null || true)"
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
	aggregate="missing"
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
		printf '{"platform":"%s","supported":false,"status":"unsupported","message":"local-permissions-check is macOS-only and read-only"}\n' "$(json_escape "$platform")"
	else
		printf 'local-permissions-check: unsupported platform (%s)\n' "$platform"
		printf 'This diagnostic reads macOS TCC privacy state and is read-only by default.\n'
	fi
	return 0
}

render_apps() {
	if ! is_macos; then
		render_unsupported_report report
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
		render_unsupported_report report
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
		render_unsupported_report json
		return 0
	fi

	local active first_app=true
	active="$(detect_active_host)"
	printf '{"platform":"Darwin","supported":true,"active_host":"%s","privacy_model":"permissions apply to the host app","apps":[' "$(json_escape "$active")"
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
		printf '{"name":"%s","bundle":"%s","role":"%s","installed":%s,"permissions":[' "$(json_escape "$display")" "$(json_escape "$bundle")" "$(json_escape "$role")" "$installed"
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
			printf '{"name":"%s","status":"%s"}' "$(json_escape "$permission")" "$(json_escape "$status")"
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
