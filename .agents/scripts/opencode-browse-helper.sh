#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# OpenCode browse helper (GH#37155).
#
# browse drives the user's existing Chromium-family browser through the browse
# extension (Chrome Web Store id mfnicocicmmlkpjnaffgihfjhdgjkdjg) with
# deterministic Playwright code. This helper installs the CLI, pairs it, and
# runs its MCP server/CLI in a stable environment:
#
#   - aidevops OpenCode sessions redirect XDG_DATA_HOME (and headless runtimes
#     every XDG_* root) into ~/.aidevops/.agent-workspace. browse keeps its relay
#     token in $XDG_DATA_HOME/browse, so inheriting the redirect would give each
#     project a different token for the one relay on 127.0.0.1:19988. Same
#     precedent as localdev-helper-init.sh run_stable_mkcert.
#   - browse acts in the user's real, signed-in browser. Headless and worker
#     runtimes have no person to lend tabs or complete handoffs, so they are
#     refused before any relay starts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

readonly BROWSE_INSTALL_URL="https://opencode.ai/browse/install"
readonly BROWSE_STORE_URL="https://chromewebstore.google.com/detail/mfnicocicmmlkpjnaffgihfjhdgjkdjg"
readonly BROWSE_AIDEVOPS_ROOT="${HOME}/.aidevops/"
# User-facing entry point (aidevops.sh dispatches here; bare command = status).
readonly BROWSE_CLI="aidevops opencode-browse"

show_help() {
	cat <<'EOF'
OpenCode browse helper — drive the user's own Chromium-family browser

Usage:
  aidevops opencode-browse [command] [args]   (no command = status)
  opencode-browse-helper.sh <command> [args]

Commands:
  detect                 List installed browsers that can run the browse extension
                         (exit 1 when none is found)
  installed              Exit 0 when the browse CLI is installed
  install [--no-wait]    Download the checksum-verified browse CLI (official installer,
                         binary only), then pair it without editing agent configs or PATH.
                         --no-wait prints pairing steps instead of waiting for the browser
  pair [browse pair args] Pair (or re-pair) a browser with a one-time code; also
                         --list, --revoke <browser>, --wait-seconds <N>
  status                 Show CLI, relay, extension and session state
  doctor                 Run browse doctor
  mcp                    Run the browse MCP server over stdio (stable env; interactive only)
  run -- <browse args>   Run any browse command in the stable env (interactive only for
                         browser-driving commands)
  help                   Show this help

Examples:
  aidevops opencode-browse install
  aidevops opencode-browse pair            # add another browser, e.g. Chrome
  aidevops opencode-browse pair --list
  aidevops opencode-browse run -- execute --rm 'await page.goto("https://example.com"); return await page.title()'
  aidevops opencode-browse run -- session new github --allow-origin github.com

Extension: https://chromewebstore.google.com/detail/mfnicocicmmlkpjnaffgihfjhdgjkdjg
Docs: ~/.aidevops/agents/tools/browser/opencode-browse.md
EOF
	return 0
}

# Resolve the browse binary: installer location first, then PATH.
browse_bin() {
	local bin_dir="${XDG_BIN_HOME:-}"
	[[ "$bin_dir" == /* ]] || bin_dir="${HOME}/.local/bin"
	if [[ -x "${bin_dir}/browse" ]]; then
		printf '%s\n' "${bin_dir}/browse"
		return 0
	fi
	if command -v browse >/dev/null 2>&1; then
		command -v browse
		return 0
	fi
	return 1
}

# True inside headless/worker runtimes (mirrors the plugin's
# headlessPlaywrightRuntime signals in mcp-registry.mjs).
is_headless_runtime() {
	local name=""
	local value=""
	for name in FULL_LOOP_HEADLESS AIDEVOPS_HEADLESS OPENCODE_HEADLESS CLAUDE_HEADLESS HEADLESS GITHUB_ACTIONS CI; do
		value="$(printf '%s' "${!name:-}" | tr '[:upper:]' '[:lower:]')"
		case "$value" in
		1 | true | yes) return 0 ;;
		esac
	done
	value="$(printf '%s' "${AIDEVOPS_SESSION_ORIGIN:-}" | tr '[:upper:]' '[:lower:]')"
	[[ "$value" == "worker" ]] && return 0
	[[ -n "${AIDEVOPS_WORKER_ID:-}" ]] && return 0
	return 1
}

refuse_headless() {
	local action="$1"
	if is_headless_runtime; then
		print_error "browse ${action} refused: headless/worker runtimes must not drive the user's own browser."
		print_info "Use isolated Playwright instead (tools/browser/playwright.md)."
		return 1
	fi
	return 0
}

# Drop XDG roots that aidevops redirected into its own workspace so every
# session shares the user's real browse config, relay token, state and cache.
# User-chosen XDG roots outside ~/.aidevops are preserved.
stabilise_browse_env() {
	local name=""
	local value=""
	for name in XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME; do
		value="${!name:-}"
		if [[ -n "$value" && "$value" == "${BROWSE_AIDEVOPS_ROOT}"* ]]; then
			unset "$name"
		fi
	done
	return 0
}

require_browse() {
	if ! browse_bin >/dev/null; then
		print_error "browse CLI is not installed. Run: ${BROWSE_CLI} install"
		return 1
	fi
	return 0
}

# Print supported browsers, one per line. Chrome Web Store extensions run in
# Chromium-family browsers; browse itself checks each profile for the extension.
cmd_detect() {
	local found=0
	local entry=""
	local label=""
	local path=""
	local app_dir=""
	local -a mac_apps=(
		"Google Chrome|Google Chrome.app"
		"Google Chrome Beta|Google Chrome Beta.app"
		"Google Chrome Dev|Google Chrome Dev.app"
		"Google Chrome Canary|Google Chrome Canary.app"
		"Microsoft Edge|Microsoft Edge.app"
		"Brave|Brave Browser.app"
		"Arc|Arc.app"
		"Vivaldi|Vivaldi.app"
		"Chromium|Chromium.app"
	)
	local -a linux_bins=(
		"Google Chrome|google-chrome"
		"Google Chrome|google-chrome-stable"
		"Microsoft Edge|microsoft-edge"
		"Microsoft Edge|microsoft-edge-stable"
		"Brave|brave-browser"
		"Brave|brave"
		"Vivaldi|vivaldi"
		"Chromium|chromium"
		"Chromium|chromium-browser"
	)

	if [[ "$(uname -s)" == "Darwin" ]]; then
		for entry in "${mac_apps[@]}"; do
			label="${entry%%|*}"
			for app_dir in "/Applications" "${HOME}/Applications"; do
				path="${app_dir}/${entry#*|}"
				if [[ -d "$path" ]]; then
					printf '%s\t%s\n' "$label" "$path"
					found=1
					break
				fi
			done
		done
	else
		local seen=""
		for entry in "${linux_bins[@]}"; do
			label="${entry%%|*}"
			[[ "$seen" == *"|${label}|"* ]] && continue
			if path="$(command -v "${entry#*|}" 2>/dev/null)" && [[ -n "$path" ]]; then
				printf '%s\t%s\n' "$label" "$path"
				seen="${seen}|${label}|"
				found=1
			fi
		done
	fi

	[[ "$found" -eq 1 ]] && return 0
	return 1
}

cmd_installed() {
	browse_bin >/dev/null && return 0
	return 1
}

# Download the official installer to a private temp file, check it is the
# browse installer, and run it in binary-only mode. The installer verifies the
# release artifact's size and SHA-256 against the release manifest.
download_and_run_installer() {
	local tmp_dir=""
	tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/aidevops-browse-XXXXXX")" || {
		print_error "Could not create a temp directory for the browse installer"
		return 1
	}
	local installer="${tmp_dir}/install.sh"
	local rc=0

	if ! curl -fsSL --proto '=https' --tlsv1.2 "$BROWSE_INSTALL_URL" -o "$installer"; then
		print_error "Could not download the browse installer from ${BROWSE_INSTALL_URL}"
		rm -rf "$tmp_dir"
		return 1
	fi
	local first_line=""
	IFS= read -r first_line <"$installer" || true
	if [[ "$first_line" != "#!/bin/sh" ]] ||
		! grep -q 'browse installer' "$installer" ||
		! grep -q 'expected_sha' "$installer"; then
		print_error "Downloaded browse installer does not look like the official checksum-verifying script"
		rm -rf "$tmp_dir"
		return 1
	fi

	sh "$installer" --no-setup || rc=$?
	rm -rf "$tmp_dir"
	return "$rc"
}

# Pair the extension without editing agent configs (aidevops registers the MCP
# itself) or shell rc files. Extra args pass through (e.g. --no-open --no-wait).
run_browse_setup() {
	local bin=""
	bin="$(browse_bin)" || return 1
	(
		stabilise_browse_env
		"$bin" install --agent none --no-modify-path "$@"
	)
	return $?
}

cmd_install() {
	local -a setup_args=()
	local arg=""
	for arg in "$@"; do
		case "$arg" in
		--no-wait) setup_args+=(--no-open --no-wait) ;;
		*)
			print_error "Unknown install option: ${arg}"
			return 1
			;;
		esac
	done

	if ! browse_bin >/dev/null; then
		print_info "Installing the OpenCode browse CLI..."
		download_and_run_installer || return 1
	fi
	local bin=""
	bin="$(browse_bin)" || {
		print_error "browse install finished but no browse binary was found in ~/.local/bin or PATH"
		return 1
	}
	print_success "browse $("$bin" --version 2>/dev/null || printf 'unknown') at ${bin}"

	# Pairing needs a person and a browser; never fail the install over it.
	if is_headless_runtime; then
		print_info "Headless runtime: skipped pairing. Pair later from a terminal: ${BROWSE_CLI} pair"
		return 0
	fi
	if ! run_browse_setup ${setup_args[@]+"${setup_args[@]}"}; then
		print_warning "browse is installed but not paired yet. Add the extension, then run: ${BROWSE_CLI} pair"
		print_info "Extension: ${BROWSE_STORE_URL}"
	fi
	return 0
}

# Re-pair, list or revoke via `browse pair` (one-time code; args pass through,
# e.g. --list, --revoke <browser>, --wait-seconds N). First-run extension
# detection and store hand-off stay in cmd_install via run_browse_setup.
cmd_pair() {
	require_browse || return 1
	refuse_headless "pairing" || return 1
	local bin=""
	bin="$(browse_bin)" || return 1
	(
		stabilise_browse_env
		"$bin" pair "$@"
	)
	return $?
}

run_browse() {
	local bin=""
	bin="$(browse_bin)" || return 1
	stabilise_browse_env
	# exec keeps stdio owned by browse (the MCP server needs a clean stdio pipe).
	exec "$bin" "$@"
	return 1
}

cmd_mcp() {
	require_browse || return 1
	refuse_headless "MCP" || return 1
	run_browse mcp "$@"
	return $?
}

cmd_run() {
	[[ "${1:-}" == "--" ]] && shift
	local subcommand="${1:-}"
	require_browse || return 1
	case "$subcommand" in
	status | doctor | skill | extension | --version | -v | --help | -h | "") ;;
	*) refuse_headless "$subcommand" || return 1 ;;
	esac
	run_browse "$@"
	return $?
}

cmd_status() {
	local bin=""
	if ! bin="$(browse_bin)"; then
		print_info "browse CLI: not installed (${BROWSE_CLI} install)"
		cmd_detect >/dev/null || print_info "No supported Chromium-family browser found"
		return 1
	fi
	run_browse status "$@"
	return $?
}

main() {
	local command="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$command" in
	detect) cmd_detect ;;
	installed) cmd_installed ;;
	install) cmd_install "$@" ;;
	pair) cmd_pair "$@" ;;
	status) cmd_status "$@" ;;
	doctor)
		require_browse || return 1
		run_browse doctor "$@"
		;;
	mcp) cmd_mcp "$@" ;;
	run) cmd_run "$@" ;;
	help | --help | -h) show_help ;;
	*)
		print_error "Unknown command: ${command}"
		show_help
		return 1
		;;
	esac
	return $?
}

main "$@"
