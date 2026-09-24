#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#25970: _classify_tool_status must update caller
# by-reference variables even when the caller's latest variable is passed as
# latest_ref.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TOOL_VERSION_CHECK="$REPO_ROOT/.agents/scripts/tool-version-check.sh"

if [[ ! -f "$TOOL_VERSION_CHECK" ]]; then
	printf 'FAIL: cannot find %s\n' "$TOOL_VERSION_CHECK" >&2
	exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/t25970-XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

extract_function() {
	awk '
		/^_classify_tool_status\(\)/, /^}$/ { print; next }
		/^get_apt_candidate\(\)/, /^}$/ { print; next }
		/^_tool_normalize_version\(\)/, /^}$/ { print; next }
		/^_tool_latest_version\(\)/, /^}$/ { print; next }
		/^check_tool\(\)/, /^}$/ { print; next }
		/^_run_outdated_tool_updates\(\)/, /^}$/ { print; next }
		/^_output_summary_and_updates\(\)/, /^}$/ { print; next }
	' "$TOOL_VERSION_CHECK" >"$SANDBOX/extract.sh"
	if ! grep -q '^_classify_tool_status()' "$SANDBOX/extract.sh"; then
		printf 'FAIL: extraction did not capture _classify_tool_status\n' >&2
		exit 1
	fi
	return 0
}

source_extracted() {
	GREEN="green"
	RED="red"
	YELLOW="yellow"
	AIDEVOPS_GH_MIN_SLURP_VERSION="2.67.0"
	INSTALLED_COUNT=0
	OUTDATED_COUNT=0
	NOT_INSTALLED_COUNT=0
	TIMEOUT_COUNT=0
	UNKNOWN_COUNT=0
	OUTDATED_PACKAGES=()
	OUTDATED_TOOL_SPECS=()
	JSON_RESULTS=()
	JSON_OUTPUT=true
	version_lt() {
		local left="$1"
		local right="$2"
		if [[ "$left" < "$right" ]]; then
			return 0
		fi
		return 1
	}
	aidevops_gh_slurp_supported() {
		return 0
	}
	# shellcheck source=/dev/null
	source "$SANDBOX/extract.sh"
	return 0
}

extract_function
source_extracted

PKG_QUERY_TIMEOUT=3
timeout_sec() { shift; "$@"; }
apt-cache() {
	printf 'Installed: %s\nCandidate: %s\n' "${TEST_APT_INSTALLED:-2.100.0-1}" "${TEST_APT_CANDIDATE:-2.100.0-1}"
}
get_npm_latest() { printf '%s\n' 0.7.0; }
get_brew_latest() { printf '%s\n' jq-1.8.2; }
command() {
	if [[ "${1:-}" == -v && "${2:-}" == brew ]]; then return 1; fi
	if [[ "${1:-}" == -v && "${2:-}" == apt-get ]]; then return 0; fi
	builtin command "$@"
}

[[ "$(get_apt_candidate gh)" == channel_current ]]
TEST_APT_CANDIDATE=2.101.0-1
[[ "$(_tool_normalize_version "$(get_apt_candidate gh)")" == 2.101.0 ]]
[[ "$(_tool_normalize_version jq-1.8.2)" == 1.8.2 ]]
[[ "$(_tool_normalize_version '')" == unknown ]]
[[ "$(_tool_latest_version npm playwriter 0.5.0)" == 0.5.0 ]]
TEST_APT_CANDIDATE=2.100.0-1
[[ "$(_tool_latest_version brew gh 2.100.0)" == channel_current ]] || {
	printf 'FAIL: apt-installed tool incorrectly compared to upstream release\n' >&2
	exit 1
}

_tool_installed_version() { printf '%s\n' "${TEST_CLI_VERSION:-0.1.0}"; }
get_npm_pkg_version() { printf '%s\n' "${TEST_PACKAGE_VERSION:-0.3.10}"; }
_append_tool_json_result() { JSON_RESULTS+=("$5"); }
_tool_selected_sudo_command() { return 1; }

# A newer installed package with a stale CLI version is diagnostic, not an
# endless npm reinstall. Empty probes also must never enqueue an update.
TEST_CLI_VERSION=0.1.0
TEST_PACKAGE_VERSION=0.3.10
get_npm_latest() { printf '%s\n' 0.3.10; }
check_tool npm DSPyGround dspyground --version dspyground 'true'
[[ "${JSON_RESULTS[0]}" == metadata_mismatch && ${#OUTDATED_PACKAGES[@]} -eq 0 ]]
get_npm_latest() { printf '\n'; }
check_tool npm Unknown unknown --version unknown 'true'
[[ "${JSON_RESULTS[1]}" == unknown && ${#OUTDATED_PACKAGES[@]} -eq 0 ]]

# A successful command that changes neither binary nor package is not updated.
OUTDATED_PACKAGES=('true')
OUTDATED_TOOL_SPECS=('npm|example|--version|example|0.1.0|0.3.10')
TEST_PACKAGE_VERSION=0.1.0
UPDATE_NOOP_COUNT=0
UPDATE_FAILURE_COUNT=0
SUDO_SKIP_COUNT=0
result=$(_run_outdated_tool_updates)
[[ "$result" == *'No verified update'* && "$result" != *'Updated and verified'* ]]

# Summary language must distinguish verified convergence from unknown,
# deferred, or no-op maintenance outcomes.
BOLD=""
[[ -z "${BLUE+x}" ]] && BLUE=""
[[ -z "${NC+x}" ]] && NC=""
QUIET=false
AUTO_UPDATE=true
OUTDATED_COUNT=0
UNKNOWN_COUNT=2
summary_output=$(_output_summary_and_updates)
[[ "$summary_output" == *'2 installed tool(s) could not be verified'* ]]
[[ "$summary_output" != *'All installed tools are up to date!'* ]]

OUTDATED_COUNT=1
UNKNOWN_COUNT=0
OUTDATED_PACKAGES=('true')
_run_outdated_tool_updates() {
	UPDATE_FAILURE_COUNT=0
	UPDATE_NOOP_COUNT=0
	SUDO_SKIP_COUNT=0
	return 0
}
summary_output=$(_output_summary_and_updates)
[[ "$summary_output" == *'Tool updates applied and verified.'* ]]
[[ "$summary_output" != *'Re-run to verify'* ]]

_run_outdated_tool_updates() {
	UPDATE_FAILURE_COUNT=0
	UPDATE_NOOP_COUNT=1
	SUDO_SKIP_COUNT=0
	return 0
}
set +e
summary_output=$(_output_summary_and_updates)
summary_rc=$?
set -e
[[ "$summary_rc" -ne 0 && "$summary_output" == *'Tool maintenance incomplete:'* ]]

status=""
icon=""
color=""
latest="1.2.3"

_classify_tool_status "example" "1.0.0" "unknown" "upgrade example" status icon color latest

if [[ "$status" != "unknown" ]]; then
	printf 'FAIL: expected status unknown, got %s\n' "$status" >&2
	exit 1
fi

if [[ "$latest" != "unknown" ]]; then
	printf 'FAIL: latest_ref was not updated; expected unknown, got %s\n' "$latest" >&2
	exit 1
fi

printf 'PASS: _classify_tool_status updates caller latest_ref\n'
exit 0
