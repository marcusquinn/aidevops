#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# routines-health-helper.sh - Diagnose and safely repair aidevops routine schedulers

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/shared-constants.sh"

readonly ROUTINES_TODO_DEFAULT="${HOME}/Git/aidevops-routines/TODO.md"
readonly DEPLOYED_AGENTS_DIR_DEFAULT="${HOME}/.aidevops/agents"
readonly LEGACY_DASHBOARD_LABEL="com.aidevops.dashboard"
readonly DASHBOARD_SYSTEMD_UNIT="sh.aidevops.dashboard"
readonly LEGACY_DASHBOARD_SYSTEMD_UNIT="aidevops-dashboard"
readonly DASHBOARD_ROUTINE_ID="r912"
readonly FORMAT_JSON="json"
readonly PRINT_LINE_FORMAT="%s\n"

MODE="check"
OUTPUT_FORMAT="text"
ROUTINE_FILTER=""

print_usage() {
	cat <<'EOF'
routines-health-helper.sh - Check aidevops routine scheduler health

Usage:
  routines-health-helper.sh check [--json] [--routine rNNN]
  routines-health-helper.sh explain [--routine rNNN]
  routines-health-helper.sh repair-safe [--routine rNNN]

Commands:
  check         Read-only routine scheduler health report (default)
  explain       Read-only report plus repair guidance
  repair-safe   Apply safe self-healing for stale unmanaged scheduler units

Options:
  --json        Emit machine-readable JSON summary
  --routine ID  Focus routine-specific stale-unit checks (for example r912)
EOF
	return 0
}

die() {
	local message="$1"
	printf '[ERROR] %s\n' "$message" >&2
	return 1
}

json_escape() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	value="${value//$'\n'/\\n}"
	printf '%s' "$value"
	return 0
}

platform_name() {
	uname -s 2>/dev/null || printf 'unknown'
	return 0
}

routine_enabled() {
	local routine_id="$1"
	local todo_file="${ROUTINES_TODO:-$ROUTINES_TODO_DEFAULT}"
	if [[ ! -r "$todo_file" ]]; then
		return 1
	fi
	grep -Eq "^[[:space:]]*-[[:space:]]*\\[x\\][[:space:]]+${routine_id}([[:space:]]|$)" "$todo_file"
	return $?
}

count_enabled_routines() {
	local todo_file="${ROUTINES_TODO:-$ROUTINES_TODO_DEFAULT}"
	if [[ ! -r "$todo_file" ]]; then
		printf '0'
		return 0
	fi
	grep -Ec '^[[:space:]]*-[[:space:]]*\[x\][[:space:]]+r[0-9]+' "$todo_file" 2>/dev/null || printf '0'
	return 0
}

deployed_version() {
	local version_file="${DEPLOYED_AGENTS_DIR:-$DEPLOYED_AGENTS_DIR_DEFAULT}/VERSION"
	if [[ -r "$version_file" ]]; then
		tr -d '[:space:]' <"$version_file"
		return 0
	fi
	printf 'missing'
	return 0
}

script_version() {
	local version_file="${SCRIPT_DIR}/../../VERSION"
	if [[ -r "$version_file" ]]; then
		tr -d '[:space:]' <"$version_file"
		return 0
	fi
	printf 'unknown'
	return 0
}

launchd_label_loaded() {
	local label="$1"
	launchctl list 2>/dev/null | grep -qF "$label"
	return $?
}

systemd_unit_active() {
	local unit="$1"
	if ! command -v systemctl >/dev/null 2>&1; then
		return 1
	fi
	systemctl --user is-active --quiet "${unit}.timer" 2>/dev/null || systemctl --user is-active --quiet "${unit}.service" 2>/dev/null
	return $?
}

safe_move_or_remove() {
	local path="$1"
	local stamp
	stamp=$(date -u +%Y%m%d%H%M%S)
	if [[ ! -e "$path" ]]; then
		return 0
	fi
	mv "$path" "${path}.disabled-${stamp}" 2>/dev/null || rm -f "$path"
	return 0
}

repair_legacy_dashboard_launchd() {
	local plist="$HOME/Library/LaunchAgents/${LEGACY_DASHBOARD_LABEL}.plist"
	local domain
	if routine_enabled "$DASHBOARD_ROUTINE_ID" || [[ ! -e "$plist" ]]; then
		return 0
	fi
	domain="gui/$(id -u)"
	launchctl bootout "${domain}/${LEGACY_DASHBOARD_LABEL}" >/dev/null 2>&1 || true
	launchctl unload "$plist" >/dev/null 2>&1 || true
	safe_move_or_remove "$plist"
	print_info "Removed stale dashboard LaunchAgent; r912 is disabled or unmanaged"
	return 0
}

repair_legacy_dashboard_systemd() {
	local user_systemd_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
	local removed=0
	local unit
	if routine_enabled "$DASHBOARD_ROUTINE_ID"; then
		return 0
	fi
	for unit in "$DASHBOARD_SYSTEMD_UNIT" "$LEGACY_DASHBOARD_SYSTEMD_UNIT"; do
		if command -v systemctl >/dev/null 2>&1; then
			systemctl --user disable --now "${unit}.service" >/dev/null 2>&1 || true
			systemctl --user disable --now "${unit}.timer" >/dev/null 2>&1 || true
		fi
		if [[ -e "${user_systemd_dir}/${unit}.service" ]]; then
			safe_move_or_remove "${user_systemd_dir}/${unit}.service"
			removed=$((removed + 1))
		fi
		if [[ -e "${user_systemd_dir}/${unit}.timer" ]]; then
			safe_move_or_remove "${user_systemd_dir}/${unit}.timer"
			removed=$((removed + 1))
		fi
	done
	if [[ "$removed" -gt 0 ]] && command -v systemctl >/dev/null 2>&1; then
		systemctl --user daemon-reload >/dev/null 2>&1 || true
		print_info "Removed stale dashboard systemd unit(s); r912 is disabled or unmanaged"
	fi
	return 0
}

repair_safe() {
	case "$(platform_name)" in
	Darwin) repair_legacy_dashboard_launchd ;;
	Linux) repair_legacy_dashboard_systemd ;;
	*) print_info "No scheduler repair available for platform: $(platform_name)" ;;
	esac
	return 0
}

emit_text_report() {
	local platform="$1"
	local enabled_count="$2"
	local deployed="$3"
	local source_version="$4"
	local dashboard_enabled="$5"
	local scheduler_note="$6"
	printf 'Routine scheduler health\n'
	printf -- '- Platform: %s\n' "$platform"
	printf -- '- Enabled routines: %s\n' "$enabled_count"
	printf -- '- Deployed agents version: %s\n' "$deployed"
	printf -- '- Source version: %s\n' "$source_version"
	printf -- '- r912 dashboard routine: %s\n' "$dashboard_enabled"
	printf -- '- Scheduler: %s\n' "$scheduler_note"
	return 0
}

emit_json_report() {
	local platform="$1"
	local enabled_count="$2"
	local deployed="$3"
	local source_version="$4"
	local dashboard_enabled="$5"
	local scheduler_note="$6"
	printf '{"platform":"%s","enabled_routines":%s,"deployed_version":"%s","source_version":"%s","r912":"%s","scheduler":"%s"}\n' \
		"$(json_escape "$platform")" \
		"$enabled_count" \
		"$(json_escape "$deployed")" \
		"$(json_escape "$source_version")" \
		"$(json_escape "$dashboard_enabled")" \
		"$(json_escape "$scheduler_note")"
	return 0
}

scheduler_summary() {
	local platform="$1"
	case "$platform" in
	Darwin)
		if launchd_label_loaded "com.aidevops.aidevops-supervisor-pulse"; then
			printf 'launchd pulse loaded'
		else
			printf 'launchd pulse not loaded'
		fi
		;;
	Linux)
		if systemd_unit_active "sh.aidevops.pulse"; then
			printf 'systemd pulse active'
		else
			printf 'systemd pulse not active or unavailable'
		fi
		;;
	*) printf 'unknown platform scheduler' ;;
	esac
	return 0
}

explain_findings() {
	printf '\nRepair guidance\n'
	printf -- "$PRINT_LINE_FORMAT" "- Run \`routines-health-helper.sh repair-safe\` to remove stale unmanaged dashboard scheduler units."
	printf -- "$PRINT_LINE_FORMAT" "- Run \`./setup.sh --non-interactive\` from the canonical aidevops repo to redeploy routine schedulers."
	printf -- "$PRINT_LINE_FORMAT" "- Inspect recent routine logs under \`~/.aidevops/logs/\` when scheduler state and TODO.md disagree."
	return 0
}

run_report() {
	local platform
	local enabled_count
	local deployed
	local source_version
	local dashboard_enabled="disabled-or-unmanaged"
	local scheduler_note
	platform="$(platform_name)"
	enabled_count="$(count_enabled_routines)"
	deployed="$(deployed_version)"
	source_version="$(script_version)"
	scheduler_note="$(scheduler_summary "$platform")"
	if routine_enabled "$DASHBOARD_ROUTINE_ID"; then
		dashboard_enabled="enabled"
	fi
	if [[ "$OUTPUT_FORMAT" == "$FORMAT_JSON" ]]; then
		emit_json_report "$platform" "$enabled_count" "$deployed" "$source_version" "$dashboard_enabled" "$scheduler_note"
	else
		emit_text_report "$platform" "$enabled_count" "$deployed" "$source_version" "$dashboard_enabled" "$scheduler_note"
	fi
	if [[ "$MODE" == "explain" && "$OUTPUT_FORMAT" != "$FORMAT_JSON" ]]; then
		explain_findings
	fi
	return 0
}

parse_args() {
	if [[ "$#" -gt 0 ]]; then
		case "$1" in
		check|explain|repair-safe)
			MODE="$1"
			shift
			;;
		-h|--help)
			print_usage
			exit 0
			;;
		esac
	fi
	while [[ "$#" -gt 0 ]]; do
		case "$1" in
		--json)
			OUTPUT_FORMAT="$FORMAT_JSON"
			shift
			;;
		--routine)
			if [[ "$#" -lt 2 ]]; then
				die "--routine requires a value"
				return 1
			fi
			ROUTINE_FILTER="$2"
			shift 2
			;;
		-h|--help)
			print_usage
			exit 0
			;;
		*)
			die "Unknown argument: $1"
			return 1
			;;
		esac
	done
	return 0
}

main() {
	parse_args "$@" || return 1
	if [[ -n "$ROUTINE_FILTER" && "$ROUTINE_FILTER" != "$DASHBOARD_ROUTINE_ID" ]]; then
		print_info "Focused checks currently include generic health plus r912 stale dashboard cleanup patterns"
	fi
	if [[ "$MODE" == "repair-safe" ]]; then
		repair_safe
	fi
	run_report
	return 0
}

main "$@"
