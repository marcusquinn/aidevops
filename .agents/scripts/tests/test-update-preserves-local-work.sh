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
	printf 'PASS %s\n' "$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	return 0
}

fail() {
	printf 'FAIL %s: %s\n' "$1" "$2" >&2
	FAIL_COUNT=$((FAIL_COUNT + 1))
	return 0
}

extract_function() {
	local source_file="$1"
	local function_name="$2"
	local output_file="$3"
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
	' "$source_file" >"$output_file"
	[[ -s "$output_file" ]]
	return 0
}

setup_repo() {
	local repo="$1"
	mkdir -p "$repo"
	git init -q "$repo"
	git -C "$repo" checkout -qb main
	git -C "$repo" config core.autocrlf false
	git -C "$repo" config user.email test@example.invalid
	git -C "$repo" config user.name Test
	printf 'upstream\n' >"$repo/VERSION"
	git -C "$repo" add VERSION
	git -C "$repo" commit -qm initial
	return 0
}

setup_diverged_repo() {
	local repo="$1"
	local remote="$2"
	local peer="$3"
	git init -q --bare "$remote"
	setup_repo "$repo"
	git -C "$repo" remote add origin "$remote"
	git -C "$repo" push -qu origin main
	git -C "$remote" symbolic-ref HEAD refs/heads/main
	git clone -q "$remote" "$peer"
	git -C "$peer" config core.autocrlf false
	git -C "$peer" config user.email test@example.invalid
	git -C "$peer" config user.name Test
	printf 'remote\n' >"$peer/VERSION"
	git -C "$peer" commit -am remote -q
	git -C "$peer" push -q origin main
	printf 'local\n' >"$repo/VERSION"
	git -C "$repo" commit -am local -q
	return 0
}

extract_function "$REPO_ROOT/aidevops.sh" cmd_update "$TEST_ROOT/cmd-update.sh"
extract_function "$REPO_ROOT/.agents/scripts/auto-update-helper.sh" _cmd_check_git_update "$TEST_ROOT/auto-update.sh"
# shellcheck source=/dev/null
source "$TEST_ROOT/cmd-update.sh"
# shellcheck source=/dev/null
source "$TEST_ROOT/auto-update.sh"

print_header() { :; }
print_info() { :; }
print_warning() { :; }
print_error() { :; }
print_success() { :; }
get_version() { printf '1.0.0\n'; }
check_dir() { [[ -d "$1" ]]; }
_update_repo_verify_files_changed() { return 1; }
_update_check_workflow_drift() { :; }
_update_verify_signature() { :; }
_run_update_setup() { return 0; }
_update_fresh_install() { return 0; }
_update_sync_projects() { :; }
_update_reconcile_repo_verify() { :; }
_update_check_homebrew() { :; }
_update_check_planning() { :; }
_update_check_tools() { :; }
_update_sweep_opencode_symlinks() { :; }
_update_check_setsid() { :; }
_migrate_settings_supervisor_to_orchestration() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
update_state() { :; }
AGENTS_DIR="$TEST_ROOT/no-agents"
AIDEVOPS_SKIP_PULSE_RESTART=1
_AIDEVOPS_UPDATE_TRUE=true

assert_dirty_change_preserved() {
	local name="$1"
	local repo="$2"
	if git -C "$repo" diff --quiet && git -C "$repo" diff --cached --quiet; then
		fail "$name" "working tree was cleaned"
	elif [[ "$(<"$repo/VERSION")" != 'local change' ]]; then
		fail "$name" "VERSION content changed"
	else
		pass "$name"
	fi
	return 0
}

for mode in staged unstaged; do
	repo="$TEST_ROOT/cmd-update-$mode"
	setup_repo "$repo"
	printf 'local change' >"$repo/VERSION"
	[[ "$mode" == staged ]] && git -C "$repo" add VERSION
	INSTALL_DIR="$repo"
	if cmd_update --skip-project-sync --compact >/dev/null 2>&1; then
		fail "cmd_update $mode changes return nonzero" "unexpected success"
	else
		assert_dirty_change_preserved "cmd_update preserves $mode changes" "$repo"
	fi
done

for mode in staged unstaged; do
	repo="$TEST_ROOT/auto-update-$mode"
	setup_repo "$repo"
	printf 'local change' >"$repo/VERSION"
	[[ "$mode" == staged ]] && git -C "$repo" add VERSION
	INSTALL_DIR="$repo"
	LOG_FILE="$TEST_ROOT/auto-update-$mode.log"
	if _cmd_check_git_update 1.0.1 >/dev/null 2>&1; then
		fail "auto update $mode changes return nonzero" "unexpected success"
	else
		assert_dirty_change_preserved "auto update preserves $mode changes" "$repo"
	fi
done

interactive_repo="$TEST_ROOT/cmd-update-diverged"
interactive_remote="$TEST_ROOT/cmd-update-diverged.git"
interactive_peer="$TEST_ROOT/cmd-update-peer"
setup_diverged_repo "$interactive_repo" "$interactive_remote" "$interactive_peer"
interactive_commit="$(git -C "$interactive_repo" rev-parse HEAD)"
INSTALL_DIR="$interactive_repo"
if cmd_update --skip-project-sync --compact >/dev/null 2>&1; then
	fail 'cmd_update divergence returns nonzero' 'unexpected success'
elif [[ "$(git -C "$interactive_repo" rev-parse HEAD)" != "$interactive_commit" ]]; then
	fail 'cmd_update preserves divergent local commit' 'HEAD changed'
else
	pass 'cmd_update preserves divergent local commit'
fi

auto_repo="$TEST_ROOT/auto-update-diverged"
auto_remote="$TEST_ROOT/auto-update-diverged.git"
auto_peer="$TEST_ROOT/auto-update-peer"
setup_diverged_repo "$auto_repo" "$auto_remote" "$auto_peer"
auto_commit="$(git -C "$auto_repo" rev-parse HEAD)"
INSTALL_DIR="$auto_repo"
LOG_FILE="$TEST_ROOT/auto-update-diverged.log"
if _cmd_check_git_update 1.0.1 >/dev/null 2>&1; then
	fail 'auto update divergence returns nonzero' 'unexpected success'
elif [[ "$(git -C "$auto_repo" rev-parse HEAD)" != "$auto_commit" ]]; then
	fail 'auto update preserves divergent local commit' 'HEAD changed'
else
	pass 'auto update preserves divergent local commit'
fi

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
