#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CLI_LIB="$REPO_ROOT/.agents/scripts/aidevops-cli/aidevops-skills-plugin-lib.sh"
LOADER_SOURCE="$REPO_ROOT/.agents/scripts/plugin-loader-helper.sh"
SETUP_MODULE="$REPO_ROOT/.agents/scripts/setup/modules/plugins.sh"
GIT_FIXTURE="$REPO_ROOT/.agents/scripts/tests/plugin-git-fixture.py"
TEST_ROOT=""
AGENTS_DIR=""
CONFIG_DIR=""
PLUGIN_REPO=""
PLUGINS_FILE=""
HOOK_LOG=""
TESTS_RUN=0
TESTS_FAILED=0
COMMIT_ONE=""
COMMIT_TWO=""

print_info() {
	return 0
}

print_success() {
	return 0
}

print_warning() {
	return 0
}

print_error() {
	printf 'ERROR %s\n' "$*" >&2
	return 0
}

print_header() {
	return 0
}

print_skip() {
	return 0
}

setup_track_deferred() {
	return 0
}

record_result() {
	local name="$1"
	local status="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		if [[ -n "$detail" ]]; then
			printf '  %s\n' "$detail"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

assert_equal() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		record_result "$name" 0
	else
		record_result "$name" 1 "expected '$expected', got '$actual'"
	fi
	return 0
}

assert_file_contains() {
	local name="$1"
	local file="$2"
	local expected="$3"
	if [[ -f "$file" ]] && grep -qF "$expected" "$file"; then
		record_result "$name" 0
	else
		record_result "$name" 1 "missing '$expected' in $file"
	fi
	return 0
}

commit_plugin() {
	local message="$1"
	python3 "$GIT_FIXTURE" "$PLUGIN_REPO" "$message"
	return 0
}

write_valid_plugin() {
	local version_text="$1"
	mkdir -p "$PLUGIN_REPO/scripts"
	cat >"$PLUGIN_REPO/plugin.json" <<'JSON'
{
  "name": "example",
  "version": "1.0.0",
  "agents": [
    {"file": "agent.md", "name": "example-agent", "description": "Example", "model": "sonnet"}
  ],
  "hooks": {"init": "scripts/on-init.sh"},
  "scripts": ["scripts/helper.sh"]
}
JSON
	printf '# Example Agent\n\n%s\n' "$version_text" >"$PLUGIN_REPO/agent.md"
	cat >"$PLUGIN_REPO/scripts/on-init.sh" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
printf 'hook-ran\n' >>"${HOOK_LOG:?}"
HOOK
	cat >"$PLUGIN_REPO/scripts/helper.sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
exit 0
HELPER
	chmod +x "$PLUGIN_REPO/scripts/on-init.sh" "$PLUGIN_REPO/scripts/helper.sh"
	return 0
}

setup_fixture() {
	TEST_ROOT=$(mktemp -d)
	AGENTS_DIR="$TEST_ROOT/agents"
	CONFIG_DIR="$TEST_ROOT/config"
	PLUGIN_REPO="$TEST_ROOT/upstream"
	PLUGINS_FILE="$CONFIG_DIR/plugins.json"
	HOOK_LOG="$TEST_ROOT/hook.log"
	mkdir -p "$AGENTS_DIR/scripts" "$CONFIG_DIR" "$PLUGIN_REPO"
	cp "$LOADER_SOURCE" "$AGENTS_DIR/scripts/plugin-loader-helper.sh"
	cp "$REPO_ROOT/.agents/scripts/plugin-source-trust-lib.sh" "$AGENTS_DIR/scripts/"
	cp "$REPO_ROOT/.agents/scripts/portable-stat.sh" "$AGENTS_DIR/scripts/"
	cp "$REPO_ROOT"/.agents/scripts/shared-*.sh "$AGENTS_DIR/scripts/"
	chmod +x "$AGENTS_DIR/scripts/plugin-loader-helper.sh"
	return 0
}

teardown_fixture() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

loader_command() {
	local command="$1"
	shift
	AIDEVOPS_AGENTS_DIR="$AGENTS_DIR" AIDEVOPS_CONFIG_DIR="$CONFIG_DIR" HOOK_LOG="$HOOK_LOG" \
		bash "$AGENTS_DIR/scripts/plugin-loader-helper.sh" "$command" "$@"
	return $?
}

assert_loader_rejects() {
	local name="$1"
	local command="$2"
	shift 2
	if loader_command "$command" "$@" >/dev/null 2>&1; then
		record_result "$name" 1
	else
		record_result "$name" 0
	fi
	return 0
}

assert_stage_rejected() {
	local name="$1"
	local stage_dir="$2"
	if loader_command validate-path "$stage_dir" example >/dev/null 2>&1; then
		record_result "$name" 1
	else
		record_result "$name" 0
	fi
	return 0
}

test_shared_library_wiring() {
	local failed=0
	grep -q 'plugin-source-trust-lib.sh' "$CLI_LIB" || failed=1
	grep -q 'plugin-source-trust-lib.sh' "$SETUP_MODULE" || failed=1
	grep -q 'plugin-source-trust-lib.sh' "$LOADER_SOURCE" || failed=1
	record_result "CLI, setup, and loader source the shared trust library" "$failed"
	if declare -F _plugin_materialize_commit >/dev/null || declare -F setup_plugin_materialize_commit >/dev/null; then
		record_result "duplicated caller materialize functions are removed" 1
	else
		record_result "duplicated caller materialize functions are removed" 0
	fi
	return 0
}

test_add_and_explicit_hooks() {
	write_valid_plugin "version one"
	COMMIT_ONE=$(commit_plugin "version one")
	cmd_plugin add "$PLUGIN_REPO" --namespace example --name example >/dev/null
	assert_equal "add records trusted commit" "$COMMIT_ONE" "$(jq -r '.plugins[0].trusted_commit' "$PLUGINS_FILE")"
	assert_equal "add records deployed commit" "$COMMIT_ONE" "$(jq -r '.plugins[0].deployed_commit' "$PLUGINS_FILE")"
	assert_equal "add records SHA-256 tree digest" "64" "$(jq -r '.plugins[0].deployed_tree_digest | length' "$PLUGINS_FILE")"
	if [[ "$(jq '.plugins[0].deployed_tree_inventory | length' "$PLUGINS_FILE")" -gt 0 ]]; then
		record_result "add records canonical tree inventory" 0
	else
		record_result "add records canonical tree inventory" 1
	fi
	assert_equal "hooks default to false" "false" "$(jq -r '.plugins[0].hooks_enabled' "$PLUGINS_FILE")"
	if [[ ! -e "$HOOK_LOG" ]]; then
		record_result "add does not run hooks" 0
	else
		record_result "add does not run hooks" 1
	fi

	assert_loader_rejects "disabled hook invocation is rejected" hooks example init
	cmd_plugin hooks example enable >/dev/null
	loader_command hooks example init >/dev/null
	assert_file_contains "authorized hook requires explicit invocation" "$HOOK_LOG" "hook-ran"
	return 0
}


test_tamper_and_lock_fail_closed() {
	local backup_agent="$TEST_ROOT/agent.backup"
	local marker=""
	cp "$AGENTS_DIR/example/agent.md" "$backup_agent"
	rm -f "$HOOK_LOG"
	printf '# Byte tamper\n' >"$AGENTS_DIR/example/agent.md"
	assert_loader_rejects "byte tamper blocks load" load example
	assert_loader_rejects "byte tamper blocks index" index
	assert_loader_rejects "byte tamper blocks authorized hook" hooks example init
	[[ ! -e "$HOOK_LOG" ]] && record_result "tampered hook is not executed" 0 || record_result "tampered hook is not executed" 1
	cp "$backup_agent" "$AGENTS_DIR/example/agent.md"
	chmod 755 "$AGENTS_DIR/example/agent.md"
	assert_loader_rejects "mode tamper blocks load" load example
	chmod 644 "$AGENTS_DIR/example/agent.md"
	printf 'unexpected\n' >"$AGENTS_DIR/example/extra.txt"
	assert_loader_rejects "inventory addition blocks load" load example
	rm -f "$AGENTS_DIR/example/extra.txt"
	marker=$(plugin_trust_marker_path "$AGENTS_DIR" example)
	mkdir "$marker"
	assert_loader_rejects "deployment marker blocks load" load example
	assert_loader_rejects "deployment marker blocks index" index
	assert_loader_rejects "deployment marker blocks hooks" hooks example init
	printf '# New content under old metadata\n' >"$AGENTS_DIR/example/agent.md"
	assert_loader_rejects "intermediate content under old metadata stays blocked" load example
	cp "$backup_agent" "$AGENTS_DIR/example/agent.md"
	rmdir "$marker"
	if loader_command load example >/dev/null 2>&1; then
		record_result "restored trusted tree loads" 0
	else
		record_result "restored trusted tree loads" 1
	fi
	return 0
}

test_update_and_setup_pin() {
	write_valid_plugin "version two"
	COMMIT_TWO=$(commit_plugin "version two")
	cmd_plugin update example >/dev/null
	assert_equal "update pins new trusted commit" "$COMMIT_TWO" "$(jq -r '.plugins[0].trusted_commit' "$PLUGINS_FILE")"
	assert_equal "update pins matching deployed commit" "$COMMIT_TWO" "$(jq -r '.plugins[0].deployed_commit' "$PLUGINS_FILE")"
	if [[ ! -e "$HOOK_LOG" ]]; then
		record_result "update does not run authorized hooks automatically" 0
	else
		record_result "update does not run authorized hooks automatically" 1
	fi

	write_valid_plugin "version three"
	commit_plugin "version three" >/dev/null
	printf '# Tampered deployment\n' >"$AGENTS_DIR/example/agent.md"
	# shellcheck source=/dev/null
	source "$SETUP_MODULE"
	deploy_plugins "$AGENTS_DIR" "$PLUGINS_FILE"
	assert_file_contains "setup deploys the pinned commit, not branch tip" "$AGENTS_DIR/example/agent.md" "version two"
	assert_equal "setup persists matching tree digest" "64" "$(jq -r '.plugins[0].deployed_tree_digest | length' "$PLUGINS_FILE")"
	if [[ ! -e "$HOOK_LOG" ]]; then
		record_result "setup does not run hooks" 0
	else
		record_result "setup does not run hooks" 1
	fi
	return 0
}

test_activation_rollback() {
	local rollback_stage="$AGENTS_DIR/.plugin-rollback-stage"
	local marker=""
	mkdir -p "$rollback_stage"
	printf '# Replacement that must roll back\n' >"$rollback_stage/agent.md"
	marker=$(plugin_trust_marker_path "$AGENTS_DIR" example)
	if plugin_trust_activate_candidate "$rollback_stage" "$AGENTS_DIR/example" "$TEST_ROOT/missing-registry" "$PLUGINS_FILE" "$marker" 2>/dev/null; then
		record_result "registry activation failure triggers rollback" 1
	else
		record_result "registry activation failure triggers rollback" 0
	fi
	assert_file_contains "activation rollback preserves previous plugin" "$AGENTS_DIR/example/agent.md" "version two"
	[[ ! -e "$marker" ]] && record_result "successful rollback clears deployment marker" 0 || record_result "successful rollback clears deployment marker" 1
	local locked_stage="$AGENTS_DIR/.plugin-locked-stage"
	local locked_registry="$TEST_ROOT/locked-registry.json"
	local registry_lock=""
	mkdir -p "$locked_stage"
	printf '# Must not activate\n' >"$locked_stage/agent.md"
	cp "$PLUGINS_FILE" "$locked_registry"
	registry_lock=$(plugin_trust_registry_lock_path "$PLUGINS_FILE")
	mkdir "$registry_lock"
	if plugin_trust_activate_candidate "$locked_stage" "$AGENTS_DIR/example" "$locked_registry" "$PLUGINS_FILE" "$marker" 2>/dev/null; then
		record_result "global registry lock blocks concurrent activation" 1
	else
		record_result "global registry lock blocks concurrent activation" 0
	fi
	assert_file_contains "blocked concurrent activation preserves plugin" "$AGENTS_DIR/example/agent.md" "version two"
	rm -rf "$locked_stage"
	rm -f "$locked_registry"
	rmdir "$registry_lock"
	return 0
}


test_full_tree_symlink_policy() {
	local stage_dir="$AGENTS_DIR/.plugin-symlink-stage"
	local outside_target="$AGENTS_DIR/outside-target"
	printf 'outside\n' >"$outside_target"
	mkdir -p "$stage_dir"
	ln -s "$outside_target" "$stage_dir/absolute-link"
	assert_stage_rejected "manifest-less absolute symlink is rejected" "$stage_dir"
	rm -rf "$stage_dir"
	mkdir -p "$stage_dir"
	ln -s missing-target "$stage_dir/dangling-link"
	assert_stage_rejected "manifest-less dangling symlink is rejected" "$stage_dir"
	rm -rf "$stage_dir"
	mkdir -p "$stage_dir"
	ln -s ../outside-target "$stage_dir/escaping-link"
	assert_stage_rejected "manifest-less escaping symlink is rejected" "$stage_dir"
	rm -rf "$stage_dir"
	mkdir -p "$stage_dir"
	printf 'inside\n' >"$stage_dir/inside.txt"
	ln -s inside.txt "$stage_dir/internal-link"
	if loader_command validate-path "$stage_dir" example >/dev/null 2>&1; then
		record_result "contained symlink is accepted and inventoried" 0
	else
		record_result "contained symlink is accepted and inventoried" 1
	fi
	rm -rf "$stage_dir" "$outside_target"
	return 0
}

test_callers_reject_unsafe_upstream_symlinks() {
	local bad_commit=""
	write_valid_plugin "unsafe symlink candidate"
	ln -s /tmp/plugin-absolute-target "$PLUGIN_REPO/unsafe-link"
	bad_commit=$(commit_plugin "absolute symlink")
	if cmd_plugin update example >/dev/null 2>&1; then
		record_result "CLI update rejects absolute upstream symlink" 1
	else
		record_result "CLI update rejects absolute upstream symlink" 0
	fi
	if setup_deploy_plugin_entry "$AGENTS_DIR" "$PLUGINS_FILE" example "$PLUGIN_REPO" example main "$bad_commit" >/dev/null 2>&1; then
		record_result "setup caller rejects absolute upstream symlink" 1
	else
		record_result "setup caller rejects absolute upstream symlink" 0
	fi
	rm -f "$PLUGIN_REPO/unsafe-link"
	ln -s missing-target "$PLUGIN_REPO/unsafe-link"
	commit_plugin "dangling symlink" >/dev/null
	if cmd_plugin update example >/dev/null 2>&1; then
		record_result "CLI update rejects dangling upstream symlink" 1
	else
		record_result "CLI update rejects dangling upstream symlink" 0
	fi
	rm -f "$PLUGIN_REPO/unsafe-link"
	ln -s ../outside-target "$PLUGIN_REPO/unsafe-link"
	commit_plugin "escaping symlink" >/dev/null
	if cmd_plugin update example >/dev/null 2>&1; then
		record_result "CLI update rejects escaping upstream symlink" 1
	else
		record_result "CLI update rejects escaping upstream symlink" 0
	fi
	rm -f "$PLUGIN_REPO/unsafe-link"
	assert_file_contains "unsafe caller failures preserve deployed plugin" "$AGENTS_DIR/example/agent.md" "version two"
	assert_equal "unsafe caller failures preserve trusted commit" "$COMMIT_TWO" "$(jq -r '.plugins[0].trusted_commit' "$PLUGINS_FILE")"
	return 0
}

test_invalid_update_preserves_previous() {
	cat >"$PLUGIN_REPO/plugin.json" <<'JSON'
{
  "name": "example",
  "version": "1.0.0",
  "agents": [{"file": "../scripts/shared-constants.sh", "name": "escape"}]
}
JSON
	commit_plugin "invalid traversal" >/dev/null
	if cmd_plugin update example >/dev/null 2>&1; then
		record_result "update rejects escaping manifest member" 1
	else
		record_result "update rejects escaping manifest member" 0
	fi
	assert_file_contains "failed update preserves previous plugin" "$AGENTS_DIR/example/agent.md" "version two"
	assert_equal "failed update preserves trusted commit" "$COMMIT_TWO" "$(jq -r '.plugins[0].trusted_commit' "$PLUGINS_FILE")"
	return 0
}


test_manifest_and_migration_guards() {
	local outside_manifest="$AGENTS_DIR/outside-manifest.json"
	local staged_manifest="$AGENTS_DIR/.plugin-manifest-stage"
	printf '{"name":"example","version":"1.0.0"}\n' >"$outside_manifest"
	mkdir -p "$staged_manifest"
	ln -s "$outside_manifest" "$staged_manifest/plugin.json"
	if AIDEVOPS_AGENTS_DIR="$AGENTS_DIR" AIDEVOPS_CONFIG_DIR="$CONFIG_DIR" \
		bash "$AGENTS_DIR/scripts/plugin-loader-helper.sh" validate-path "$staged_manifest" example >/dev/null 2>&1; then
		record_result "validator rejects manifest symlink escape" 1
	else
		record_result "validator rejects manifest symlink escape" 0
	fi
	rm -rf "$staged_manifest" "$outside_manifest"

	local registry_tmp=""
	registry_tmp=$(mktemp "${PLUGINS_FILE}.tmp.XXXXXX")
	jq 'del(.plugins[0].trusted_commit, .plugins[0].deployed_commit, .plugins[0].deployed_tree_digest,
		.plugins[0].deployed_tree_inventory, .plugins[0].hooks_enabled)' \
		"$PLUGINS_FILE" >"$registry_tmp"
	mv "$registry_tmp" "$PLUGINS_FILE"
	assert_loader_rejects "legacy unpinned plugin is not loaded" load example
	cmd_plugin trust example --commit "$COMMIT_TWO" >/dev/null
	assert_equal "trust command migrates existing entry" "$COMMIT_TWO" "$(jq -r '.plugins[0].trusted_commit' "$PLUGINS_FILE")"
	assert_equal "trust migration restores tree digest" "64" "$(jq -r '.plugins[0].deployed_tree_digest | length' "$PLUGINS_FILE")"
	assert_equal "trust migration keeps hooks disabled by default" "false" "$(jq -r '.plugins[0].hooks_enabled' "$PLUGINS_FILE")"
	return 0
}

main() {
	setup_fixture
	trap teardown_fixture EXIT
	export AGENTS_DIR CONFIG_DIR HOOK_LOG
	# shellcheck source=/dev/null
	source "$CLI_LIB"
	test_shared_library_wiring
	test_add_and_explicit_hooks
	test_tamper_and_lock_fail_closed
	test_update_and_setup_pin
	test_activation_rollback
	test_full_tree_symlink_policy
	test_callers_reject_unsafe_upstream_symlinks
	test_invalid_update_preserves_previous
	test_manifest_and_migration_guards

	printf '\nTests run: %d\nFailed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
