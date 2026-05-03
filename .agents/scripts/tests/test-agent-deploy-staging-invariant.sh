#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#22014: _atomic_stage_and_deploy_agents must not
# return 0 with $target_dir absent when a mv in the atomic swap fails.
#
# Root cause: the function is called via `|| return 1` which disables set -e
# inside the function body. Without explicit error checks on the mv commands,
# a failed mv falls through, the backup is deleted, and the function returns 0
# — leaving the deployed agents directory absent while setup reports success.
#
# Tests exercise the four invariants:
#   1. Happy path: swap succeeds, target_dir exists and contains scripts/
#   2. mv-to-old fails: function returns 1, live target_dir preserved
#   3. mv-staging-to-live fails: function returns 1, rollback restores target
#   4. concurrent fixed staging cleanup: unique staging avoids stale path races
#   5. deploy_aidevops_agents postcondition: returns 1 when scripts/ missing
#   6. no-change deploy with corrupt live scripts/ and reserved plugin namespace
#      still copies canonical scripts/ instead of excluding them from staging
#   7. stale core OpenCode plugin content blocks .deployed-sha advancement

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
AGENT_DEPLOY="${SCRIPT_DIR}/../../../.agents/scripts/setup/modules/agent-deploy.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_DIR=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Stub print_* so sourced code does not produce noise in test output.
print_info() { return 0; }
print_warning() { return 0; }
print_success() { return 0; }
print_error() { return 0; }

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

# Build a minimal source dir with a scripts/ subdir so postcondition checks pass.
_make_source_dir() {
	local dir="$1"
	mkdir -p "$dir/scripts"
	printf 'test content\n' >"$dir/scripts/hello.sh"
	return 0
}

# Build a minimal live target dir.
_make_live_target() {
	local dir="$1"
	mkdir -p "$dir/scripts"
	printf 'old content\n' >"$dir/scripts/old.sh"
	return 0
}

# ─── source the module under test ───────────────────────────────────────────

# shellcheck source=/dev/null
source "$AGENT_DEPLOY"

# ─── tests ──────────────────────────────────────────────────────────────────

# Test 1: happy path — swap succeeds, target contains scripts/
test_happy_path_target_exists_with_scripts() {
	local src="${TEST_DIR}/src1"
	local tgt="${TEST_DIR}/tgt1"
	_make_source_dir "$src"

	local rc=0
	_atomic_stage_and_deploy_agents "$src" "$tgt" || rc=$?

	if [[ "$rc" -ne 0 ]]; then
		print_result "happy path: function returns 0" 1 "rc=$rc"
		return 0
	fi
	print_result "happy path: function returns 0" 0

	if [[ -d "$tgt/scripts" ]]; then
		print_result "happy path: target scripts/ exists after swap" 0
	else
		print_result "happy path: target scripts/ exists after swap" 1 "$tgt/scripts missing"
	fi

	if ! compgen -G "${tgt}.staging*" >/dev/null && ! compgen -G "${tgt}.old*" >/dev/null; then
		print_result "happy path: staging and old dirs cleaned up" 0
	else
		print_result "happy path: staging and old dirs cleaned up" 1 \
			"staging/old temp dirs still present"
	fi
	return 0
}

# Test 2: mv target→old.* fails — function returns 1, live target preserved.
# Override mv for the generated backup path so the test remains independent of
# the per-process suffix used to avoid concurrent setup collisions.
test_mv_to_old_fails_preserves_live_target() {
	local src="${TEST_DIR}/src2"
	local tgt="${TEST_DIR}/tgt2"
	_make_source_dir "$src"
	_make_live_target "$tgt"

	# Override mv to fail when the destination is the .old path.
	mv() {
		local dst="${*: -1}"
		if [[ "$dst" == "${tgt}.old."* ]]; then
			return 1
		fi
		command mv "$@"
		return $?
	}

	local rc=0
	_atomic_stage_and_deploy_agents "$src" "$tgt" || rc=$?

	unset -f mv

	if [[ "$rc" -ne 0 ]]; then
		print_result "mv-to-old fails: function returns non-zero" 0
	else
		print_result "mv-to-old fails: function returns non-zero" 1 "returned 0 (false success)"
	fi

	if [[ -d "$tgt/scripts" ]]; then
		print_result "mv-to-old fails: live target preserved" 0
	else
		print_result "mv-to-old fails: live target preserved" 1 "$tgt/scripts missing (live dir was removed)"
	fi
	return 0
}

# Test 3: mv staging→live fails — function returns 1, rollback restores target.
# Simulate by making $target_dir a non-removable destination (replace it with
# a read-only dir after mv target→old succeeds) — actually simpler: override
# mv to fail only when the source is the staging path.
test_mv_staging_to_live_fails_rolls_back() {
	local src="${TEST_DIR}/src3"
	local tgt="${TEST_DIR}/tgt3"
	_make_source_dir "$src"
	_make_live_target "$tgt"

	# Override mv to fail only for the staging→live move.
	mv() {
		local src_arg="$1"
		if [[ "$src_arg" == "${tgt}.staging."* ]]; then
			return 1
		fi
		command mv "$@"
		return $?
	}

	local rc=0
	_atomic_stage_and_deploy_agents "$src" "$tgt" || rc=$?

	unset -f mv

	if [[ "$rc" -ne 0 ]]; then
		print_result "mv-staging-to-live fails: function returns non-zero" 0
	else
		print_result "mv-staging-to-live fails: function returns non-zero" 1 "returned 0 (false success)"
	fi

	# Rollback should have restored the live target from .old
	if [[ -d "$tgt/scripts" ]]; then
		print_result "mv-staging-to-live fails: rollback restores target" 0
	else
		print_result "mv-staging-to-live fails: rollback restores target" 1 "$tgt/scripts missing after rollback"
	fi

	# Staging should be cleaned up
	if ! compgen -G "${tgt}.staging*" >/dev/null; then
		print_result "mv-staging-to-live fails: staging cleaned up" 0
	else
		print_result "mv-staging-to-live fails: staging cleaned up" 1 "staging temp dirs still present"
	fi
	return 0
}

# Test 4: a concurrent cleanup of the legacy fixed staging path must not affect
# the active deploy. Original fixed-path staging used ${target}.staging; if that
# directory was removed during rsync, setup failed with renameat/move_file ENOENT.
test_fixed_staging_cleanup_does_not_abort_copy() {
	local src="${TEST_DIR}/src4"
	local tgt="${TEST_DIR}/tgt4"
	_make_source_dir "$src"
	_make_live_target "$tgt"
	mkdir -p "${tgt}.staging/scripts"
	printf 'stale staging\n' >"${tgt}.staging/scripts/stale.sh"

	_deploy_agents_copy() {
		local copy_source_dir="$1"
		local copy_target_dir="$2"
		if [[ "$copy_target_dir" == "${tgt}.staging" ]]; then
			rm -rf "$copy_target_dir"
			return 1
		fi
		mkdir -p "$copy_target_dir/scripts"
		cp -a "$copy_source_dir/scripts/." "$copy_target_dir/scripts/"
		return 0
	}

	local rc=0
	_atomic_stage_and_deploy_agents "$src" "$tgt" || rc=$?

	unset -f _deploy_agents_copy

	if [[ "$rc" -eq 0 && -f "$tgt/scripts/hello.sh" ]]; then
		print_result "fixed staging cleanup: unique staging deploy succeeds" 0
	else
		print_result "fixed staging cleanup: unique staging deploy succeeds" 1 "rc=$rc"
	fi
	return 0
}

# Test 5: deploy_aidevops_agents postcondition check — if scripts/ is absent
# after swap (regression scenario), function returns 1.
# We wire this up by overriding _atomic_stage_and_deploy_agents to return 0
# without populating the target so we isolate the postcondition gate.
test_postcondition_fails_when_scripts_absent() {
	local src="${TEST_DIR}/src5"
	local tgt="${TEST_DIR}/tgt5"
	local plugins_file="${TEST_DIR}/plugins5.json"
	printf '{"plugins":[]}\n' >"$plugins_file"

	mkdir -p "$src/scripts"  # source has scripts/ but we won't copy it
	# Set up the minimum vars deploy_aidevops_agents needs.
	local INSTALL_DIR="$src"

	# Override the inner function to simulate a silent failure: it returns 0
	# but leaves $target_dir empty (no scripts/).
	_atomic_stage_and_deploy_agents() {
		local _src="$1"
		local _tgt="$2"
		# Create an empty target dir — deliberately omit scripts/
		mkdir -p "$_tgt"
		return 0
	}

	# Stub everything else _deploy_agents_post_copy and helpers call.
	_deploy_agents_post_copy() { return 0; }
	_warn_deployed_script_drift() { return 0; }
	create_backup_with_rotation() { return 0; }
	sanitize_plugin_namespace() { return 0; }
	_restart_pulse_if_running() { return 0; }

	local rc=0
	HOME="${TEST_DIR}" INSTALL_DIR="$src" deploy_aidevops_agents || rc=$?

	unset -f _atomic_stage_and_deploy_agents _deploy_agents_post_copy
	unset -f _warn_deployed_script_drift create_backup_with_rotation
	unset -f sanitize_plugin_namespace _restart_pulse_if_running

	if [[ "$rc" -ne 0 ]]; then
		print_result "postcondition: returns non-zero when scripts/ absent after swap" 0
	else
		print_result "postcondition: returns non-zero when scripts/ absent after swap" 1 \
			"returned 0 (false success) — GH#22014 regression"
	fi
	return 0
}

# Test 6: no-change deploy path — if the deployed SHA matches HEAD but the live
# agents tree is corrupt (scripts/ missing), a plugin namespace that collides
# with core scripts/ must not exclude canonical scripts/ from the staged copy.
test_no_change_corrupt_live_scripts_reserved_namespace_recovers() {
	local repo="${TEST_DIR}/repo6"
	local target="${TEST_DIR}/.aidevops/agents"
	local plugins_file="${TEST_DIR}/.config/aidevops/plugins.json"
	local sha="abc123456789"

	mkdir -p "$repo/.agents/scripts" "$target" "$(dirname "$plugins_file")" "${TEST_DIR}/.aidevops"
	printf 'canonical script\n' >"$repo/.agents/scripts/hello.sh"
	printf '%s\n' "$sha" >"${TEST_DIR}/.aidevops/.deployed-sha"
	printf '{"plugins":[{"name":"bad","namespace":"scripts","repo":"unused"}]}\n' >"$plugins_file"

	git() {
		local first_arg="${1:-}"
		local third_arg="${3:-}"
		local fourth_arg="${4:-}"
		if [[ "$first_arg" == "-C" && "$third_arg" == "rev-parse" && "$fourth_arg" == "HEAD" ]]; then
			printf '%s\n' "$sha"
			return 0
		fi
		command git "$@"
		return $?
	}
	sanitize_plugin_namespace() {
		local ns="$1"
		printf '%s\n' "$ns"
		return 0
	}
	_deploy_agents_post_copy() { return 0; }
	_warn_deployed_script_drift() { return 0; }
	create_backup_with_rotation() { return 0; }

	local rc=0
	HOME="${TEST_DIR}" INSTALL_DIR="$repo" AIDEVOPS_AGENT_DEPLOY_MIN_FILES=1 deploy_aidevops_agents || rc=$?

	unset -f git sanitize_plugin_namespace _deploy_agents_post_copy
	unset -f _warn_deployed_script_drift create_backup_with_rotation

	if [[ "$rc" -eq 0 && -f "$target/scripts/hello.sh" ]]; then
		print_result "no-change corrupt live: reserved scripts namespace is ignored" 0
	else
		print_result "no-change corrupt live: reserved scripts namespace is ignored" 1 \
			"rc=$rc, expected $target/scripts/hello.sh"
	fi
	return 0
}

test_rsync_copy_uses_io_timeout() {
	local src="${TEST_DIR}/src7"
	local tgt="${TEST_DIR}/tgt7"
	local args_file="${TEST_DIR}/rsync-args7.txt"
	_make_source_dir "$src"
	mkdir -p "$tgt"

	rsync() {
		printf '%s\n' "$*" >"$args_file"
		mkdir -p "$tgt/scripts"
		cp -a "$src/scripts/." "$tgt/scripts/"
		return 0
	}

	local rc=0
	AIDEVOPS_RSYNC_TIMEOUT=7 _deploy_agents_copy "$src" "$tgt" || rc=$?

	unset -f rsync

	if [[ "$rc" -eq 0 ]] && grep -q -- '--timeout=7' "$args_file" && [[ -f "$tgt/scripts/hello.sh" ]]; then
		print_result "rsync copy uses bounded I/O timeout" 0
	else
		print_result "rsync copy uses bounded I/O timeout" 1 "rc=$rc args=$(tr '\n' ' ' <"$args_file" 2>/dev/null || true)"
	fi
	return 0
}

test_stale_core_plugin_blocks_deployed_sha_stamp() {
	local repo="${TEST_DIR}/repo8"
	local target="${TEST_DIR}/.aidevops/agents"
	local source_plugin="$repo/.agents/plugins/opencode-aidevops/model-limits.mjs"
	local target_plugin="$target/plugins/opencode-aidevops/model-limits.mjs"
	local sha="fresh-plugin-sha"

	mkdir -p "$repo/.agents/scripts" "$(dirname "$source_plugin")" "$target/scripts" "$(dirname "$target_plugin")"
	rm -f "${TEST_DIR}/.aidevops/.deployed-sha"
	printf 'canonical script\n' >"$repo/.agents/scripts/hello.sh"
	printf 'export const MODEL_LIMITS = { fresh: true };\n' >"$source_plugin"
	printf 'export const MODEL_LIMITS = { fresh: false };\n' >"$target_plugin"

	git() {
		local first_arg="${1:-}"
		local third_arg="${3:-}"
		local fourth_arg="${4:-}"
		if [[ "$first_arg" == "-C" && "$third_arg" == "rev-parse" && "$fourth_arg" == "HEAD" ]]; then
			printf '%s\n' "$sha"
			return 0
		fi
		command git "$@"
		return $?
	}
	_atomic_stage_and_deploy_agents() {
		local _src="$1"
		local _tgt="$2"
		mkdir -p "$_tgt/scripts" "$_tgt/plugins/opencode-aidevops"
		printf 'canonical script\n' >"$_tgt/scripts/hello.sh"
		printf 'export const MODEL_LIMITS = { fresh: false };\n' >"$_tgt/plugins/opencode-aidevops/model-limits.mjs"
		return 0
	}
	_deploy_agents_post_copy() { return 0; }
	_warn_deployed_script_drift() { return 0; }
	create_backup_with_rotation() { return 0; }
	_restore_latest_agents_backup() { return 0; }

	local rc=0
	HOME="${TEST_DIR}" INSTALL_DIR="$repo" AIDEVOPS_AGENT_DEPLOY_MIN_FILES=1 deploy_aidevops_agents || rc=$?

	unset -f git _atomic_stage_and_deploy_agents _deploy_agents_post_copy
	unset -f _warn_deployed_script_drift create_backup_with_rotation _restore_latest_agents_backup

	if [[ "$rc" -ne 0 && ! -f "${TEST_DIR}/.aidevops/.deployed-sha" ]]; then
		print_result "stale core plugin: deploy fails before deployed-sha stamp" 0
	else
		print_result "stale core plugin: deploy fails before deployed-sha stamp" 1 \
			"rc=$rc, deployed-sha present=$([[ -f "${TEST_DIR}/.aidevops/.deployed-sha" ]] && printf yes || printf no)"
	fi
	return 0
}

main() {
	setup

	test_happy_path_target_exists_with_scripts
	test_mv_to_old_fails_preserves_live_target
	test_mv_staging_to_live_fails_rolls_back
	test_no_change_corrupt_live_scripts_reserved_namespace_recovers
	test_rsync_copy_uses_io_timeout
	test_fixed_staging_cleanup_does_not_abort_copy
	test_postcondition_fails_when_scripts_absent
	test_stale_core_plugin_blocks_deployed_sha_stamp

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
