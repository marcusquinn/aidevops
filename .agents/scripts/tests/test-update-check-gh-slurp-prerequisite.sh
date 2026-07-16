#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_CHECK="${SCRIPT_DIR}/../aidevops-update-check.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_PATH="$PATH"
ORIGINAL_HOME="$HOME"

# Load only the cache helpers so failure paths can be exercised without running
# the update check's main entry point.
# shellcheck source=/dev/null
source <(awk '
	/^_write_cache_contents[[:space:]]*\(\)/,/^}/ { print }
	/^_write_cache[[:space:]]*\(\)/,/^}/ { print }
' "$UPDATE_CHECK")

cleanup() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	PATH="$ORIGINAL_PATH"
	HOME="$ORIGINAL_HOME"
	return 0
}
trap cleanup EXIT

print_result() {
	local name="$1"
	local status="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name" >&2
	[[ -n "$detail" ]] && printf '  %s\n' "$detail" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_fake_tools() {
	local gh_version_line="$1"
	local remote_version="${2:-}"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/home/.aidevops/agents"
	HOME="${TEST_ROOT}/home"
	PATH="${TEST_ROOT}/bin:${ORIGINAL_PATH}"
	printf '1.0.0\n' >"${HOME}/.aidevops/agents/VERSION"

	cat >"${TEST_ROOT}/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '${gh_version_line}'
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/gh"

	cat >"${TEST_ROOT}/bin/curl" <<EOF
#!/usr/bin/env bash
	if [[ -n "${remote_version}" ]]; then
		printf '%s\n' '${remote_version}'
		exit 0
	fi
exit 22
EOF
	chmod +x "${TEST_ROOT}/bin/curl"
	return 0
}

test_setup_fake_tools_removes_previous_root() {
	local previous_root=""
	setup_fake_tools "gh version 2.51.0 (2024-05-29)"
	previous_root="$TEST_ROOT"
	setup_fake_tools "gh version 2.51.0 (2024-05-29)"
	if [[ ! -d "$previous_root" && -d "$TEST_ROOT" ]]; then
		print_result "fake tool setup removes its previous temporary root" 0
	else
		print_result "fake tool setup removes its previous temporary root" 1 "previous='${previous_root}', current='${TEST_ROOT}'"
	fi
	return 0
}

test_old_gh_warns_in_update_check() {
	setup_fake_tools "gh version 2.45.0 (2025-07-18 Ubuntu 2.45.0-1ubuntu0.3)"
	local output=""
	output=$(bash "$UPDATE_CHECK" --interactive 2>/dev/null || true)
	if [[ "$output" == *"[WARN] GitHub CLI prerequisite:"* && "$output" == *"requires gh >= 2.51.0"* ]]; then
		print_result "old gh emits session-start prerequisite warning" 0
	else
		print_result "old gh emits session-start prerequisite warning" 1 "output='${output}'"
	fi
	return 0
}

test_supported_gh_has_no_warning() {
	setup_fake_tools "gh version 2.51.0 (2024-05-29)"
	local output=""
	local cache_file="$HOME/.aidevops/cache/session-greeting.txt"
	output=$(bash "$UPDATE_CHECK" --interactive 2>/dev/null || true)
	if [[ "$output" != *"[WARN] GitHub CLI prerequisite:"* && -s "$cache_file" ]]; then
		print_result "supported gh omits session-start prerequisite warning" 0
	else
		print_result "supported gh omits warning and writes complete cache" 1 "output='${output}', cache='${cache_file}'"
	fi
	return 0
}

test_update_available_preserves_full_session_status() {
	setup_fake_tools "gh version 2.45.0 (2025-07-18 Ubuntu 2.45.0-1ubuntu0.3)" "1.0.1"
	local output=""
	local cache_file="$HOME/.aidevops/cache/session-greeting.txt"
	local warning_count=0
	output=$(OPENCODE=1 bash "$UPDATE_CHECK" --interactive 2>/dev/null || true)
	warning_count=$(printf '%s\n' "$output" | grep -cF "[WARN] GitHub CLI prerequisite:" || true)
	if [[ "$output" == *"UPDATE_AVAILABLE|1.0.0|1.0.1|OpenCode"* ]] &&
		[[ "$output" == *"aidevops v1.0.0 running in OpenCode"* ]] &&
		[[ "$warning_count" -eq 1 ]] &&
		[[ -s "$cache_file" ]] &&
		grep -qF "aidevops v1.0.0 running in OpenCode" "$cache_file"; then
		print_result "update available preserves session status and warns once" 0
	else
		print_result "update available preserves session status and warns once" 1 "count=${warning_count}, output='${output}', cache='${cache_file}'"
	fi
	return 0
}

test_cache_write_propagates_output_failure() {
	local cache_dir=""
	local status=0
	cache_dir=$(mktemp -d)

	set +e
	(
		printf() {
			local value="${2:-}"
			local rc=0
			if [[ "$value" == "fail-write" ]]; then
				return 17
			fi
			builtin printf "$@"
			rc=$?
			return "$rc"
		}
		_write_cache "$cache_dir" "greeting" "fail-write" "" "" "" "" "" ""
	)
	status=$?
	set -e

	if [[ "$status" -eq 17 ]] && [[ -z "$(compgen -G "$cache_dir/session-greeting.*" || true)" ]]; then
		print_result "cache output failure preserves status and removes temp file" 0
	else
		print_result "cache output failure preserves status and removes temp file" 1 "status=${status}"
	fi
	rm -rf "$cache_dir"
	return 0
}

test_cache_write_propagates_move_failure() {
	local cache_dir=""
	local status=0
	cache_dir=$(mktemp -d)

	set +e
	(
		mv() {
			return 23
		}
		_write_cache "$cache_dir" "greeting" "" "" "" "" "" "" ""
	)
	status=$?
	set -e

	if [[ "$status" -eq 23 ]] && [[ -z "$(compgen -G "$cache_dir/session-greeting.*" || true)" ]]; then
		print_result "cache move failure preserves status and removes temp file" 0
	else
		print_result "cache move failure preserves status and removes temp file" 1 "status=${status}"
	fi
	rm -rf "$cache_dir"
	return 0
}

test_setup_fake_tools_removes_previous_root
test_old_gh_warns_in_update_check
test_supported_gh_has_no_warning
test_update_available_preserves_full_session_status
test_cache_write_propagates_output_failure
test_cache_write_propagates_move_failure

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
