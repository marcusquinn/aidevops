#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
PASS_COUNT=0
FAIL_COUNT=0
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() {
	local name="$1"
	printf 'PASS %s\n' "$name"
	PASS_COUNT=$((PASS_COUNT + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	printf 'FAIL %s: %s\n' "$name" "$detail" >&2
	FAIL_COUNT=$((FAIL_COUNT + 1))
	return 0
}

extract_function() {
	local function_name="$1"
	local output_file="$2"
	awk -v function_name="$function_name" '
		$0 ~ "^" function_name "\\(\\)[[:space:]]*\\{" { capturing = 1 }
		capturing {
			print
			line = $0
			open_count = gsub(/\{/, "", line)
			line = $0
			close_count = gsub(/\}/, "", line)
			depth += open_count - close_count
			if (depth == 0) exit
		}
	' "$REPO_ROOT/aidevops.sh" >"$output_file"
	[[ -s "$output_file" ]]
	return 0
}

for function_name in _update_verify_deployment_state _run_update_setup_transaction _update_render_changelog cmd_update; do
	extract_function "$function_name" "$TEST_ROOT/$function_name.sh"
	# shellcheck source=/dev/null
	source "$TEST_ROOT/$function_name.sh"
done

print_error() {
	local message="$1"
	printf 'ERROR %s\n' "$message"
	return 0
}

print_info() {
	local message="$1"
	printf 'INFO %s\n' "$message"
	return 0
}

git() {
	/usr/bin/git "$@"
	return $?
}

INSTALL_DIR="$TEST_ROOT/repo"
HOME="$TEST_ROOT/home"
_AIDEVOPS_REAL_HOME="$HOME"
AGENTS_DIR="$HOME/.aidevops/agents"
mkdir -p "$INSTALL_DIR" "$HOME/.aidevops/agents"
printf '1.0.0\n' >"$INSTALL_DIR/VERSION"
printf '1.0.0\n' >"$HOME/.aidevops/agents/VERSION"

SETUP_RC=0
SETUP_SHA=""
_run_update_setup() {
	local output_mode="$1"
	: "$output_mode"
	if [[ "$SETUP_RC" -ne 0 ]]; then
		return "$SETUP_RC"
	fi
	if [[ -n "$SETUP_SHA" ]]; then
		printf '%s\n' "$SETUP_SHA" >"$HOME/.aidevops/.deployed-sha"
	fi
	return 0
}

SETUP_RC=23
if failure_output=$(_run_update_setup_transaction compact expected-sha); then
	fail "setup failure returns nonzero" "unexpected success"
elif [[ "$failure_output" == *"setup exited with code 23"* ]]; then
	pass "setup failure emits explicit deployment receipt"
else
	fail "setup failure emits explicit deployment receipt" "$failure_output"
fi

SETUP_RC=0
SETUP_SHA="stale-sha"
if stale_output=$(_run_update_setup_transaction compact expected-sha); then
	fail "stale activated SHA returns nonzero" "unexpected success"
elif [[ "$stale_output" == *"does not match repository HEAD"* ]]; then
	pass "equal versions cannot hide stale activated SHA"
else
	fail "equal versions cannot hide stale activated SHA" "$stale_output"
fi

SETUP_SHA="expected-sha"
if _run_update_setup_transaction compact expected-sha >/dev/null; then
	pass "matching version and activated SHA succeed"
else
	fail "matching version and activated SHA succeed" "transaction failed"
fi

/usr/bin/git init -q -b main "$INSTALL_DIR"
/usr/bin/git -C "$INSTALL_DIR" config user.email test@example.invalid
/usr/bin/git -C "$INSTALL_DIR" config user.name Test
printf '0\n' >"$INSTALL_DIR/change.txt"
/usr/bin/git -C "$INSTALL_DIR" add change.txt VERSION
/usr/bin/git -C "$INSTALL_DIR" commit -qm "initial"
OLD_SHA=$(/usr/bin/git -C "$INSTALL_DIR" rev-parse HEAD)

if _update_render_changelog "$OLD_SHA" "$OLD_SHA" 1.0.0 >/dev/null; then
	pass "empty changelog range is non-fatal"
else
	fail "empty changelog range is non-fatal" "renderer returned nonzero"
fi

for commit_number in $(seq 1 25); do
	printf '%s\n' "$commit_number" >"$INSTALL_DIR/change.txt"
	/usr/bin/git -C "$INSTALL_DIR" commit -am "t$commit_number: task-prefixed change" -q
done
NEW_SHA=$(/usr/bin/git -C "$INSTALL_DIR" rev-parse HEAD)
if changelog_output=$(_update_render_changelog "$OLD_SHA" "$NEW_SHA" 1.0.0) &&
	[[ "$changelog_output" == *"t25: task-prefixed change"* ]] &&
	[[ "$changelog_output" == *"... and more"* ]]; then
	pass "bounded changelog accepts task-prefixed subjects without SIGPIPE"
else
	fail "bounded changelog accepts task-prefixed subjects without SIGPIPE" "$changelog_output"
fi

print_header() {
	local message="$1"
	printf 'HEADER %s\n' "$message"
	return 0
}

print_warning() {
	local message="$1"
	printf 'WARN %s\n' "$message"
	return 0
}

print_success() {
	local message="$1"
	printf 'OK %s\n' "$message"
	return 0
}

get_version() {
	cat "$INSTALL_DIR/VERSION"
	return 0
}

check_dir() {
	local path="$1"
	if [[ -d "$path" ]]; then
		return 0
	fi
	return 1
}

_update_repo_verify_files_changed() { return 1; }
_update_check_workflow_drift() { return 0; }
_update_verify_signature() { return 0; }
_update_fresh_install() { return 0; }
_update_sync_projects() { return 0; }
_update_reconcile_repo_verify() { return 0; }
_update_check_homebrew() { return 0; }
_update_check_planning() { return 0; }
_update_check_tools() { return 0; }
_update_sweep_opencode_symlinks() { return 0; }
_update_check_setsid() { return 0; }
_migrate_settings_supervisor_to_orchestration() { return 0; }

INTEGRATION_REMOTE="$TEST_ROOT/integration.git"
INTEGRATION_REPO="$TEST_ROOT/integration-repo"
INTEGRATION_PEER="$TEST_ROOT/integration-peer"
SETUP_CALLS="$TEST_ROOT/setup-calls"
/usr/bin/git init -q --bare -b main "$INTEGRATION_REMOTE"
/usr/bin/git init -q -b main "$INTEGRATION_REPO"
/usr/bin/git -C "$INTEGRATION_REPO" config user.email test@example.invalid
/usr/bin/git -C "$INTEGRATION_REPO" config user.name Test
printf '1.0.0\n' >"$INTEGRATION_REPO/VERSION"
printf 'base\n' >"$INTEGRATION_REPO/runtime.txt"
/usr/bin/git -C "$INTEGRATION_REPO" add VERSION runtime.txt
/usr/bin/git -C "$INTEGRATION_REPO" commit -qm "initial"
/usr/bin/git -C "$INTEGRATION_REPO" remote add origin "$INTEGRATION_REMOTE"
/usr/bin/git -C "$INTEGRATION_REPO" push -qu origin main
BASE_SHA=$(/usr/bin/git -C "$INTEGRATION_REPO" rev-parse HEAD)
/usr/bin/git clone -q "$INTEGRATION_REMOTE" "$INTEGRATION_PEER"
/usr/bin/git -C "$INTEGRATION_PEER" config user.email test@example.invalid
/usr/bin/git -C "$INTEGRATION_PEER" config user.name Test
printf 'updated\n' >"$INTEGRATION_PEER/runtime.txt"
/usr/bin/git -C "$INTEGRATION_PEER" commit -am "t18162: task-prefixed update" -q
/usr/bin/git -C "$INTEGRATION_PEER" push -q origin main
REMOTE_SHA=$(/usr/bin/git -C "$INTEGRATION_PEER" rev-parse HEAD)

INSTALL_DIR="$INTEGRATION_REPO"
SETUP_RC=0
SETUP_SHA="$REMOTE_SHA"
printf '%s\n' "$BASE_SHA" >"$HOME/.aidevops/.deployed-sha"
printf '1.0.0\n' >"$HOME/.aidevops/agents/VERSION"
_run_update_setup() {
	local output_mode="$1"
	: "$output_mode"
	printf 'called\n' >>"$SETUP_CALLS"
	printf '%s\n' "$SETUP_SHA" >"$HOME/.aidevops/.deployed-sha"
	return "$SETUP_RC"
}
AGENTS_DIR="$HOME/.aidevops/agents"
AIDEVOPS_SKIP_PULSE_RESTART=1
_AIDEVOPS_UPDATE_TRUE=true

if integration_output=$(cmd_update --skip-project-sync --compact) &&
	[[ "$(/usr/bin/git -C "$INTEGRATION_REPO" rev-parse HEAD)" == "$REMOTE_SHA" ]] &&
	[[ -s "$SETUP_CALLS" ]] &&
	[[ "$integration_output" == *"t18162: task-prefixed update"* ]] &&
	[[ "$integration_output" == *"agents deployed"* ]]; then
	pass "task-prefixed fast-forward reaches setup and verifies activation"
else
	fail "task-prefixed fast-forward reaches setup and verifies activation" "$integration_output"
fi

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
