#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
# shellcheck source=shared-constants.sh
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

readonly ADVISORY_ID="tanstack-minishaihulud-2026-05"
readonly ADVISORIES_DIR="${HOME}/.aidevops/advisories"
readonly DISMISSED_FILE="${ADVISORIES_DIR}/dismissed.txt"
readonly IOC_PATTERN='@tanstack/setup|github:tanstack/router#79ac49eedf774dd4b0cfa308722bc463cfe5885c|router_init\.js|tanstack_runner\.js|gh-token-monitor|com\.user\.gh-token-monitor|IfYouRevokeThisTokenItWillWipeTheComputerOfTheOwner|api\.masscan\.cloud|git-tanstack\.com|filev2\.getsession\.org|seed[123]\.getsession\.org'
readonly AFFECTED_PATTERN='(@tanstack/(router-utils|router-core|arktype-adapter|eslint-plugin-router|eslint-plugin-start|history|nitro-v2-vite-plugin|react-router|react-router-devtools|react-router-ssr-query|react-start|react-start-client|react-start-rsc|react-start-server|router-cli|router-devtools|router-devtools-core|router-generator|router-plugin|router-ssr-query-core|router-vite-plugin|solid-router|solid-router-devtools|solid-router-ssr-query|solid-start|solid-start-client|solid-start-server|start-client-core|start-fn-stubs|start-plugin-core|start-server-core|start-static-server-functions|start-storage-context|valibot-adapter|virtual-file-routes|vue-router|vue-router-devtools|vue-router-ssr-query|vue-start|vue-start-client|vue-start-server|zod-adapter)|@opensearch-project/opensearch|@mistralai/mistralai|safe-action|cmux-agent-mcp|nextmove-mcp|git-git-git|git-branch-selector)@?(1\.161\.11|1\.161\.14|1\.169\.5|1\.169\.8|1\.166\.12|1\.166\.15|1\.161\.9|1\.161\.12|0\.0\.4|0\.0\.7|1\.154\.12|1\.154\.15|1\.166\.16|1\.166\.19|1\.166\.18|1\.167\.68|1\.167\.71|1\.166\.51|1\.166\.54|0\.0\.47|0\.0\.50|1\.166\.55|1\.166\.58|1\.166\.46|1\.166\.49|1\.167\.6|1\.167\.9|1\.166\.45|1\.166\.48|1\.167\.38|1\.167\.41|1\.168\.3|1\.168\.6|1\.166\.53|1\.166\.56|1\.167\.65|1\.167\.33|1\.167\.36|1\.166\.44|1\.166\.47|1\.166\.38|1\.166\.41|1\.161\.10|1\.161\.13|1\.167\.61|1\.167\.64|1\.166\.50|1\.166\.57|3\.6\.2|2\.2\.3|2\.2\.4|0\.8\.3|0\.8\.4|0\.1\.[3-8]|1\.0\.(8|9|10|12)|1\.3\.(3|4|5|7))([^0-9]|$)'
SCAN_PATH_FINDINGS=0

print_usage() {
	cat <<EOF
Usage: $(basename "$0") <command> [path...]

Commands:
  scan [path...]       Scan repos.json repositories and ~/Git, or explicit paths
  startup-check        Emit one-line nudge when advisory is not dismissed
  dismiss              Dismiss the TanStack/Mini Shai-Hulud advisory
  help                 Show this help

The scan is read-only. It does not install packages, revoke tokens, or delete files.
EOF
	return 0
}

ensure_advisory() {
	mkdir -p "$ADVISORIES_DIR"
	local advisory_file="${ADVISORIES_DIR}/${ADVISORY_ID}.advisory"
	if [[ ! -f "$advisory_file" ]]; then
		cat >"$advisory_file" <<EOF
[SECURITY ADVISORY] TanStack / Mini Shai-Hulud npm compromise — run \`aidevops security supply-chain scan\`

Dismiss after scanning and mitigating: aidevops security dismiss ${ADVISORY_ID}
EOF
	fi
	return 0
}

is_dismissed() {
	if [[ -f "$DISMISSED_FILE" ]] && grep -qxF "$ADVISORY_ID" "$DISMISSED_FILE" 2>/dev/null; then
		return 0
	fi
	return 1
}

cmd_startup_check() {
	if is_dismissed; then
		echo ""
		return 0
	fi
	ensure_advisory
	echo "[SECURITY ADVISORY] TanStack/Mini Shai-Hulud npm compromise: run \`aidevops security supply-chain scan\`; dismiss with \`aidevops security dismiss ${ADVISORY_ID}\` after mitigation."
	return 0
}

cmd_dismiss() {
	mkdir -p "$ADVISORIES_DIR"
	if ! is_dismissed; then
		printf '%s\n' "$ADVISORY_ID" >>"$DISMISSED_FILE"
	fi
	echo "Dismissed ${ADVISORY_ID}"
	return 0
}

collect_default_paths() {
	local repos_json="${HOME}/.config/aidevops/repos.json"
	if [[ -f "$repos_json" ]] && command -v jq >/dev/null 2>&1; then
		jq -r '.. | objects | .path? // empty' "$repos_json" 2>/dev/null | while IFS= read -r repo_path; do
			[[ -n "$repo_path" && -d "$repo_path" ]] && printf '%s\n' "$repo_path"
		done
	fi
	if command -v fd >/dev/null 2>&1 && [[ -d "${HOME}/Git" ]]; then
		fd -td -d 2 '^\.git$' "${HOME}/Git" 2>/dev/null | while IFS= read -r git_dir; do
			printf '%s\n' "${git_dir%/.git}"
		done
	elif [[ -d "${HOME}/Git" ]]; then
		echo -e "${YELLOW}[WARN]${NC} fd not installed; skipping automatic ~/Git repository discovery." >&2
	fi
	return 0
}

scan_path() {
	local target_path="$1"
	local findings=0
	local rg_status=0
	local scan_error=0
	SCAN_PATH_FINDINGS=0
	if [[ ! -e "$target_path" ]]; then
		echo -e "${YELLOW}[WARN]${NC} Missing path: ${target_path}"
		return 0
	fi

	echo -e "${BLUE}Scanning:${NC} ${target_path}"
	if command -v rg >/dev/null 2>&1; then
		if rg -n --hidden --glob '!node_modules/.cache/**' --glob '!dist/**' --glob '!build/**' --glob '!.git/**' "$IOC_PATTERN" "$target_path"; then
			findings=$((findings + 1))
		else
			rg_status=$?
			if [[ "$rg_status" -gt 1 ]]; then
				echo -e "${YELLOW}[WARN]${NC} ripgrep IOC scan failed for ${target_path} (exit ${rg_status})."
				scan_error="$rg_status"
			fi
		fi
		if rg -n --hidden --glob '!node_modules/**' --glob '!.git/**' --glob 'pnpm-lock.yaml' --glob 'package-lock.json' --glob 'yarn.lock' --glob 'bun.lock*' --glob 'package.json' "$AFFECTED_PATTERN" "$target_path"; then
			findings=$((findings + 1))
		else
			rg_status=$?
			if [[ "$rg_status" -gt 1 ]]; then
				echo -e "${YELLOW}[WARN]${NC} ripgrep affected-package scan failed for ${target_path} (exit ${rg_status})."
				scan_error="$rg_status"
			fi
		fi
	else
		echo -e "${YELLOW}[WARN]${NC} ripgrep not installed; install rg for supply-chain scans."
		return 127
	fi
	if [[ "$scan_error" -ne 0 ]]; then
		return "$scan_error"
	fi
	SCAN_PATH_FINDINGS="$findings"
	if [[ "$findings" -gt 0 ]]; then
		return 1
	fi
	return 0
}

check_home_persistence() {
	local findings=0
	local path
	for path in \
		"${HOME}/Library/LaunchAgents/com.user.gh-token-monitor.plist" \
		"${HOME}/.local/bin/gh-token-monitor.sh" \
		"${HOME}/.config/gh-token-monitor/token" \
		"${HOME}/.config/systemd/user/gh-token-monitor.service"; do
		if [[ -e "$path" ]]; then
			echo -e "${RED}[IOC]${NC} Persistence artifact present: ${path}"
			findings=$((findings + 1))
		fi
	done
	return "$findings"
}

cmd_scan() {
	ensure_advisory
	local total_findings=0
	local scan_errors=0
	local scan_status=0
	local paths=()
	if [[ "$#" -gt 0 ]]; then
		paths=("$@")
	else
		while IFS= read -r path; do
			paths+=("$path")
		done < <(collect_default_paths | sort -u)
	fi

	check_home_persistence || total_findings=$((total_findings + $?))
	local path
	for path in "${paths[@]}"; do
		scan_path "$path" || {
			scan_status=$?
			if [[ "$scan_status" -eq 1 ]]; then
				total_findings=$((total_findings + SCAN_PATH_FINDINGS))
			else
				scan_errors=$((scan_errors + 1))
			fi
		}
	done

	if [[ "$total_findings" -gt 0 ]]; then
		echo -e "${RED}Potential supply-chain compromise indicators found.${NC}"
		echo "Isolate affected hosts before revoking tokens; then rotate credentials from a trusted machine."
		return 1
	fi
	if [[ "$scan_errors" -gt 0 ]]; then
		echo -e "${YELLOW}[WARN]${NC} Supply-chain scan incomplete due to ${scan_errors} scan error(s)."
		return 2
	fi

	echo -e "${GREEN}No TanStack/Mini Shai-Hulud indicators found in scanned paths.${NC}"
	echo "Dismiss after any separate CI/log review: aidevops security dismiss ${ADVISORY_ID}"
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	scan | check)
		cmd_scan "$@"
		;;
	startup-check)
		cmd_startup_check "$@"
		;;
	dismiss)
		cmd_dismiss "$@"
		;;
	help | --help | -h)
		print_usage
		;;
	*)
		echo -e "${RED}Unknown command:${NC} ${command}"
		print_usage
		return 1
		;;
	esac
	return 0
}

main "$@"
