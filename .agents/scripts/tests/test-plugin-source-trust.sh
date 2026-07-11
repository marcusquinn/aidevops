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

main() {
	setup_fixture
	trap teardown_fixture EXIT
	export AGENTS_DIR CONFIG_DIR HOOK_LOG
	# shellcheck source=/dev/null
	source "$CLI_LIB"

	write_valid_plugin "version one"
	local commit_one=""
	commit_one=$(commit_plugin "version one")
	cmd_plugin add "$PLUGIN_REPO" --namespace example --name example >/dev/null

	assert_equal "add records trusted commit" "$commit_one" "$(jq -r '.plugins[0].trusted_commit' "$PLUGINS_FILE")"
	assert_equal "add records deployed commit" "$commit_one" "$(jq -r '.plugins[0].deployed_commit' "$PLUGINS_FILE")"
	assert_equal "hooks default to false" "false" "$(jq -r '.plugins[0].hooks_enabled' "$PLUGINS_FILE")"
	if [[ ! -e "$HOOK_LOG" ]]; then
		record_result "add does not run hooks" 0
	else
		record_result "add does not run hooks" 1
	fi

	if AIDEVOPS_AGENTS_DIR="$AGENTS_DIR" AIDEVOPS_CONFIG_DIR="$CONFIG_DIR" \
		bash "$AGENTS_DIR/scripts/plugin-loader-helper.sh" hooks example init >/dev/null 2>&1; then
		record_result "disabled hook invocation is rejected" 1
	else
		record_result "disabled hook invocation is rejected" 0
	fi
	cmd_plugin hooks example enable >/dev/null
	AIDEVOPS_AGENTS_DIR="$AGENTS_DIR" AIDEVOPS_CONFIG_DIR="$CONFIG_DIR" HOOK_LOG="$HOOK_LOG" \
		bash "$AGENTS_DIR/scripts/plugin-loader-helper.sh" hooks example init >/dev/null
	assert_file_contains "authorized hook requires explicit invocation" "$HOOK_LOG" "hook-ran"

	rm -f "$HOOK_LOG"
	write_valid_plugin "version two"
	local commit_two=""
	commit_two=$(commit_plugin "version two")
	cmd_plugin update example >/dev/null
	assert_equal "update pins new trusted commit" "$commit_two" "$(jq -r '.plugins[0].trusted_commit' "$PLUGINS_FILE")"
	assert_equal "update pins matching deployed commit" "$commit_two" "$(jq -r '.plugins[0].deployed_commit' "$PLUGINS_FILE")"
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
	if [[ ! -e "$HOOK_LOG" ]]; then
		record_result "setup does not run hooks" 0
	else
		record_result "setup does not run hooks" 1
	fi
	local rollback_stage="$AGENTS_DIR/.plugin-rollback-stage"
	mkdir -p "$rollback_stage"
	printf '# Replacement that must roll back\n' >"$rollback_stage/agent.md"
	if _plugin_activate_candidate "$rollback_stage" "$AGENTS_DIR/example" "$TEST_ROOT/missing-registry" "$PLUGINS_FILE" 2>/dev/null; then
		record_result "registry activation failure triggers rollback" 1
	else
		record_result "registry activation failure triggers rollback" 0
	fi
	assert_file_contains "activation rollback preserves previous plugin" "$AGENTS_DIR/example/agent.md" "version two"

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
	assert_equal "failed update preserves trusted commit" "$commit_two" "$(jq -r '.plugins[0].trusted_commit' "$PLUGINS_FILE")"

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
	jq 'del(.plugins[0].trusted_commit, .plugins[0].deployed_commit, .plugins[0].hooks_enabled)' \
		"$PLUGINS_FILE" >"$registry_tmp"
	mv "$registry_tmp" "$PLUGINS_FILE"
	if AIDEVOPS_AGENTS_DIR="$AGENTS_DIR" AIDEVOPS_CONFIG_DIR="$CONFIG_DIR" \
		bash "$AGENTS_DIR/scripts/plugin-loader-helper.sh" load example >/dev/null 2>&1; then
		record_result "legacy unpinned plugin is not loaded" 1
	else
		record_result "legacy unpinned plugin is not loaded" 0
	fi
	cmd_plugin trust example --commit "$commit_two" >/dev/null
	assert_equal "trust command migrates existing entry" "$commit_two" "$(jq -r '.plugins[0].trusted_commit' "$PLUGINS_FILE")"
	assert_equal "trust migration keeps hooks disabled by default" "false" "$(jq -r '.plugins[0].hooks_enabled' "$PLUGINS_FILE")"

	printf '\nTests run: %d\nFailed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
