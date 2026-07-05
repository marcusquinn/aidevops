#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression checks for routines-health-helper.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)" || exit 1
HELPER="${REPO_ROOT}/scripts/routines-health-helper.sh"

failures=0

print_result() {
	local name="$1"
	local status="$2"
	local detail="${3:-}"
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s %s\n' "$name" "$detail" >&2
		failures=$((failures + 1))
	fi
	return 0
}

test_json_check_outputs_expected_keys() {
	local tmp_home
	local output
	tmp_home="$(mktemp -d)"
	mkdir -p "${tmp_home}/Git/aidevops-routines" "${tmp_home}/.aidevops/agents"
	printf '%s\n' '- [x] r901 Supervisor pulse repeat:daily(@09:00)' >"${tmp_home}/Git/aidevops-routines/TODO.md"
	printf '%s\n' '9.9.9' >"${tmp_home}/.aidevops/agents/VERSION"
	output="$(HOME="$tmp_home" "$HELPER" check --json)"
	rm -rf "$tmp_home"
	if [[ "$output" == *'"platform"'* && "$output" == *'"enabled_routines":1'* && "$output" == *'"deployed_version":"9.9.9"'* ]]; then
		print_result "json check outputs expected keys" 0
		return 0
	fi
	print_result "json check outputs expected keys" 1 "$output"
	return 0
}

test_repair_safe_is_gated_by_r912() {
	local snippet
	snippet="$(sed -n '/repair_legacy_dashboard_systemd()/,/^}/p' "$HELPER")"
	if printf '%s' "$snippet" | grep -qF 'DASHBOARD_ROUTINE_ID' && \
		printf '%s' "$snippet" | grep -qF 'systemctl --user disable --now' && \
		printf '%s' "$snippet" | grep -qF 'daemon-reload'; then
		print_result "repair-safe is gated by r912 and reloads systemd" 0
		return 0
	fi
	print_result "repair-safe is gated by r912 and reloads systemd" 1
	return 0
}

main() {
	test_json_check_outputs_expected_keys
	test_repair_safe_is_gated_by_r912
	if [[ "$failures" -ne 0 ]]; then
		printf 'Tests failed: %s\n' "$failures" >&2
		return 1
	fi
	printf 'All routines-health-helper tests passed\n'
	return 0
}

main "$@"
