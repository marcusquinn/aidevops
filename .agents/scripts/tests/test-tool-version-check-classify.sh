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
