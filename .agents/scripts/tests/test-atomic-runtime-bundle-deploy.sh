#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT=""
FAKE_REPO=""
TESTS_RUN=0

print_info() { local message="$1"; : "$message"; return 0; }
print_success() { local message="$1"; : "$message"; return 0; }
print_warning() { local message="$1"; : "$message"; return 0; }
print_error() { local message="$1"; printf 'ERROR: %s\n' "$message" >&2; return 0; }
print_skip() { local message="$1"; : "$message"; return 0; }
setup_track_deferred() { return 0; }
create_backup_with_rotation() { return 0; }

# shellcheck source=../portable-stat.sh
source "$REPO_ROOT/.agents/scripts/portable-stat.sh"
# shellcheck source=../setup/modules/plugins.sh
source "$REPO_ROOT/.agents/scripts/setup/modules/plugins.sh"
# shellcheck source=../setup/modules/agent-deploy.sh
source "$REPO_ROOT/.agents/scripts/setup/modules/agent-deploy.sh"
# shellcheck source=../setup/modules/agent-runtime.sh
source "$REPO_ROOT/.agents/scripts/setup/modules/agent-runtime.sh"

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

pass() {
	local message="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS: %s\n' "$message"
	return 0
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	[[ "$actual" == "$expected" ]] || fail "$message (expected=$expected actual=$actual)"
	pass "$message"
	return 0
}

assert_file_contains() {
	local file="$1"
	local pattern="$2"
	local message="$3"
	grep -q "$pattern" "$file" || fail "$message"
	pass "$message"
	return 0
}

write_fake_revision() {
	local version="$1"
	local marker="$2"
	rm -rf "$FAKE_REPO/.agents/plugins"
	mkdir -p "$FAKE_REPO/.agents/scripts"
	printf '%s\n' "$version" >"$FAKE_REPO/VERSION"
	printf '#!/usr/bin/env bash\nprintf %s\\n "%s"\n' '%s' "$version" >"$FAKE_REPO/aidevops.sh"
	printf '#!/usr/bin/env bash\nprintf %s\\n "%s"\n' '%s' "$marker" >"$FAKE_REPO/.agents/scripts/helper.sh"
	printf '#!/usr/bin/env bash\nexec git "$@"\n' >"$FAKE_REPO/.agents/scripts/git"
	printf '# test agents\n' >"$FAKE_REPO/.agents/AGENTS.md"
	chmod +x "$FAKE_REPO/aidevops.sh" "$FAKE_REPO/.agents/scripts/helper.sh" "$FAKE_REPO/.agents/scripts/git"
	return 0
}

write_fake_plugin_manifest() {
	mkdir -p "$FAKE_REPO/.agents/plugins/opencode-aidevops"
	printf '{"name":"opencode-aidevops","type":"module"}\n' >"$FAKE_REPO/.agents/plugins/opencode-aidevops/package.json"
	return 0
}

write_fake_plugin_dependencies() {
	local plugin_dir="$FAKE_REPO/.agents/plugins/opencode-aidevops"
	mkdir -p "$plugin_dir/node_modules/@bufbuild/protobuf" "$plugin_dir/node_modules/@opencode-ai/plugin"
	printf '{"name":"@bufbuild/protobuf","type":"module","exports":"./index.mjs"}\n' >"$plugin_dir/node_modules/@bufbuild/protobuf/package.json"
	printf 'export const fixture = true;\n' >"$plugin_dir/node_modules/@bufbuild/protobuf/index.mjs"
	printf '{"name":"@opencode-ai/plugin","type":"module","exports":"./index.mjs"}\n' >"$plugin_dir/node_modules/@opencode-ai/plugin/package.json"
	printf 'export const tool = Object.assign((definition) => definition, { schema: {} });\n' >"$plugin_dir/node_modules/@opencode-ai/plugin/index.mjs"
	return 0
}

stage_revision() {
	local target_dir="$1"
	_runtime_bundle_stage "$FAKE_REPO" "$FAKE_REPO/.agents" "$target_dir" "$TEST_ROOT/plugins.json" || return 1
	return 0
}

test_initial_activation_and_manifest() {
	local target_dir="$HOME/.aidevops/agents"
	local active_root=""
	mkdir -p "$target_dir/scripts" "$target_dir/custom"
	printf '1.0.0\n' >"$target_dir/VERSION"
	printf 'old\n' >"$target_dir/scripts/helper.sh"
	printf 'preserved\n' >"$target_dir/custom/user.txt"

	write_fake_revision "2.0.0" "new"
	stage_revision "$target_dir"
	_runtime_bundle_activate "$target_dir" "$_AIDEVOPS_STAGED_BUNDLE_DIR"
	active_root=$(_runtime_bundle_resolve_root "$target_dir")

	[[ -L "$target_dir" ]] || fail "active agents path is an activation symlink"
	pass "active agents path is an activation symlink"
	_verify_deployed_agents_tree "$target_dir" || fail "post-activation verification follows the active bundle symlink"
	pass "post-activation verification follows the active bundle symlink"
	assert_eq "2.0.0" "$(tr -d '[:space:]' <"$active_root/VERSION")" "CLI and agents activate at one version"
	assert_file_contains "$active_root/.bundle-manifest" '^status=validated$' "validated manifest is inside the active bundle"
	assert_file_contains "$active_root/.bundle-manifest" '^cli_compatibility=2.0.0$' "manifest binds CLI compatibility"
	assert_eq "preserved" "$(tr -d '[:space:]' <"$active_root/custom/user.txt")" "user custom content survives bundle migration"
	[[ -L "$HOME/.aidevops/previous-runtime-bundle" ]] || fail "previous validated bundle is retained"
	pass "previous validated bundle is retained"
	return 0
}

test_interrupted_staging_preserves_active() {
	local target_dir="$HOME/.aidevops/agents"
	local active_before=""
	local active_after=""
	local failure_point=""
	active_before=$(_runtime_bundle_resolve_root "$target_dir")
	write_fake_revision "3.0.0" "interrupted"
	for failure_point in after-stage-copy after-plugin-generation before-activation; do
		if AIDEVOPS_BUNDLE_FAIL_AT="$failure_point" stage_revision "$target_dir"; then
			fail "injected interruption at $failure_point unexpectedly succeeded"
		fi
		active_after=$(_runtime_bundle_resolve_root "$target_dir")
		assert_eq "$active_before" "$active_after" "interruption at $failure_point preserves active bundle"
	done
	return 0
}

test_failed_activation_rolls_back() {
	local target_dir="$HOME/.aidevops/agents"
	local active_before=""
	local active_after=""
	active_before=$(_runtime_bundle_resolve_root "$target_dir")
	write_fake_revision "3.1.0" "rollback"
	stage_revision "$target_dir"
	if AIDEVOPS_BUNDLE_FAIL_AT=after-activation _runtime_bundle_activate "$target_dir" "$_AIDEVOPS_STAGED_BUNDLE_DIR"; then
		fail "injected post-activation validation failure unexpectedly succeeded"
	fi
	active_after=$(_runtime_bundle_resolve_root "$target_dir")
	assert_eq "$active_before" "$active_after" "failed activation rolls back to previous validated bundle"
	return 0
}

test_process_pin_survives_activation() {
	local target_dir="$HOME/.aidevops/agents"
	local pinned_root=""
	pin_aidevops_runtime_bundle_root
	pinned_root="$AIDEVOPS_AGENTS_DIR"
	write_fake_revision "4.0.0" "next"
	stage_revision "$target_dir"
	_runtime_bundle_activate "$target_dir" "$_AIDEVOPS_STAGED_BUNDLE_DIR"
	assert_eq "$pinned_root" "$AIDEVOPS_AGENTS_DIR" "running process remains pinned after activation"
	assert_eq "2.0.0" "$(tr -d '[:space:]' <"$AIDEVOPS_AGENTS_DIR/VERSION")" "pinned process reads its original version"
	assert_eq "4.0.0" "$(tr -d '[:space:]' <"$target_dir/VERSION")" "new process path reads the newly active version"
	return 0
}

test_live_bundle_lease_survives_three_updates() {
	local target_dir="$HOME/.aidevops/agents"
	local leased_root=""
	local leased_bundle=""
	local version=""
	leased_root=$(_runtime_bundle_resolve_root "$target_dir")
	leased_bundle="${leased_root%/agents}"
	mkdir -p "$HOME/.aidevops/runtime-bundles/.leases/${leased_bundle##*/}"
	printf '%s\n' "$leased_root" >"$HOME/.aidevops/runtime-bundles/.leases/${leased_bundle##*/}/$$"

	for version in 5.0.0 6.0.0 7.0.0; do
		write_fake_revision "$version" "update-$version"
		stage_revision "$target_dir"
		AIDEVOPS_RUNTIME_BUNDLE_RETENTION_SECONDS=0 _runtime_bundle_activate "$target_dir" "$_AIDEVOPS_STAGED_BUNDLE_DIR"
	done
	[[ -x "$leased_root/scripts/helper.sh" ]] || fail "live first bundle helper survives three updates"
	pass "live first bundle helper survives three updates"
	return 0
}

test_stale_lease_and_old_bundle_are_pruned() {
	local target_dir="$HOME/.aidevops/agents"
	local stale_bundle="$HOME/.aidevops/runtime-bundles/stale-crash"
	local stale_pid="99999999"
	mkdir -p "$stale_bundle/agents/scripts" "$HOME/.aidevops/runtime-bundles/.leases/stale-crash"
	printf '#!/usr/bin/env bash\n' >"$stale_bundle/agents/scripts/helper.sh"
	printf '%s\n' "$stale_bundle/agents" >"$HOME/.aidevops/runtime-bundles/.leases/stale-crash/$stale_pid"
	AIDEVOPS_RUNTIME_BUNDLE_RETENTION_SECONDS=0 _runtime_bundle_prune \
		"$HOME/.aidevops/runtime-bundles" "$(_runtime_bundle_resolve_root "$target_dir")" ""
	[[ ! -d "$stale_bundle" ]] || fail "crashed process lease does not retain an old bundle"
	pass "crashed process lease does not retain an old bundle"
	return 0
}

test_macos_and_linux_link_paths() {
	local os_name=""
	local os_root=""
	local link_path=""
	local resolved=""
	local expected=""
	for os_name in Darwin Linux; do
		os_root="$TEST_ROOT/os-$os_name"
		mkdir -p "$os_root/one" "$os_root/two"
		link_path="$os_root/active"
		ln -s "$os_root/one" "$link_path"
		MOCK_UNAME="$os_name"
		uname() { printf '%s\n' "$MOCK_UNAME"; return 0; }
		mv() {
			local first_arg="$1"
			if [[ "$first_arg" == "-Tf" ]]; then
				command rm -f "$3"
				command mv -f "$2" "$3"
				return $?
			fi
			if [[ "$first_arg" == "-f" && "${2:-}" == "-h" ]]; then
				command rm -f "$4"
				command mv -f "$3" "$4"
				return $?
			fi
			command mv "$@"
			return $?
		}
		_runtime_bundle_switch_link "$link_path" "$os_root/two"
		resolved=$(cd "$link_path" && pwd -P)
		expected=$(cd "$os_root/two" && pwd -P)
		assert_eq "$expected" "$resolved" "$os_name activation uses atomic rename semantics"
		unset -f uname mv
	done
	return 0
}

test_plugin_dependency_smoke_check() {
	local plugin_dir=""
	write_fake_revision "7.1.0" "dependency-smoke-check"
	write_fake_plugin_manifest
	write_fake_plugin_dependencies
	plugin_dir="$FAKE_REPO/.agents/plugins/opencode-aidevops"

	_verify_opencode_plugin_deps "$plugin_dir" || fail "complete plugin dependencies pass the import smoke check"
	pass "complete plugin dependencies pass the import smoke check"
	rm -rf "$plugin_dir/node_modules/@opencode-ai/plugin"
	if _verify_opencode_plugin_deps "$plugin_dir" >/dev/null 2>&1; then
		fail "missing @opencode-ai/plugin unexpectedly passed the import smoke check"
	fi
	pass "missing @opencode-ai/plugin fails the import smoke check"
	return 0
}

install_mock_plugin_dependency_hooks() {
	_verify_opencode_plugin_deps() {
		local plugin_dir="$1"
		: "$plugin_dir"
		case "$MOCK_PLUGIN_VERIFY_MODE" in
		available)
			return 0
			;;
		recover)
			[[ -f "$TEST_ROOT/npm-install-complete" ]] && return 0
			return 1
			;;
		failure)
			return 1
			;;
		esac
		return 1
	}

	npm() {
		printf '%s\n' "$MOCK_PLUGIN_VERIFY_MODE" >"$TEST_ROOT/npm-called"
		if [[ "$MOCK_PLUGIN_VERIFY_MODE" == "recover" ]]; then
			printf 'installed\n' >"$TEST_ROOT/npm-install-complete"
			return 0
		fi
		printf 'mock npm install failure\n' >&2
		return 1
	}
	return 0
}

test_dependency_install_recovery_activates_candidate() {
	local target_dir="$HOME/.aidevops/agents"
	write_fake_revision "8.0.0" "dependency-recovery"
	write_fake_plugin_manifest
	MOCK_PLUGIN_VERIFY_MODE="recover"
	rm -f "$TEST_ROOT/npm-called" "$TEST_ROOT/npm-install-complete"

	stage_revision "$target_dir"
	[[ -f "$TEST_ROOT/npm-called" ]] || fail "missing dependencies invoke npm install"
	pass "missing dependencies invoke npm install"
	_runtime_bundle_activate "$target_dir" "$_AIDEVOPS_STAGED_BUNDLE_DIR"
	assert_eq "8.0.0" "$(tr -d '[:space:]' <"$target_dir/VERSION")" "dependency-complete candidate activates after install"
	return 0
}

test_dependency_install_failure_preserves_active_bundle() {
	local target_dir="$HOME/.aidevops/agents"
	local active_before=""
	local active_after=""
	active_before=$(_runtime_bundle_resolve_root "$target_dir")
	write_fake_revision "9.0.0" "dependency-failure"
	write_fake_plugin_manifest
	MOCK_PLUGIN_VERIFY_MODE="failure"
	rm -f "$TEST_ROOT/npm-called" "$TEST_ROOT/npm-install-complete"

	if stage_revision "$target_dir"; then
		fail "plugin dependency install failure unexpectedly staged a bundle"
	fi
	[[ -f "$TEST_ROOT/npm-called" ]] || fail "failed dependency recovery invokes npm install"
	pass "failed dependency recovery invokes npm install"
	active_after=$(_runtime_bundle_resolve_root "$target_dir")
	assert_eq "$active_before" "$active_after" "plugin dependency install failure preserves active bundle"
	assert_eq "8.0.0" "$(tr -d '[:space:]' <"$target_dir/VERSION")" "failed candidate never becomes active"
	return 0
}

test_older_candidate_cannot_replace_active_bundle() {
	local target_dir="$HOME/.aidevops/agents"
	local active_before=""
	local active_after=""
	active_before=$(_runtime_bundle_resolve_root "$target_dir")
	write_fake_revision "7.9.0" "stale-setup"
	rm -rf "$FAKE_REPO/.agents/plugins"
	stage_revision "$target_dir"
	if _runtime_bundle_activate "$target_dir" "$_AIDEVOPS_STAGED_BUNDLE_DIR" >/dev/null 2>&1; then
		fail "older setup candidate unexpectedly replaced the active bundle"
	fi
	active_after=$(_runtime_bundle_resolve_root "$target_dir")
	assert_eq "$active_before" "$active_after" "older setup candidate cannot replace a newer active bundle"
	assert_eq "8.0.0" "$(tr -d '[:space:]' <"$target_dir/VERSION")" "newer active version survives stale setup activation"
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	HOME="$TEST_ROOT/home"
	FAKE_REPO="$TEST_ROOT/repo"
	export HOME
	unset AIDEVOPS_AGENTS_DIR AGENTS_DIR
	mkdir -p "$HOME/.aidevops" "$FAKE_REPO"
	INSTALL_DIR="$FAKE_REPO"
	export INSTALL_DIR
	AIDEVOPS_AGENT_DEPLOY_MIN_FILES=1
	export AIDEVOPS_AGENT_DEPLOY_MIN_FILES

	test_initial_activation_and_manifest
	test_interrupted_staging_preserves_active
	test_failed_activation_rolls_back
	test_process_pin_survives_activation
	test_live_bundle_lease_survives_three_updates
	test_stale_lease_and_old_bundle_are_pruned
	test_macos_and_linux_link_paths
	test_plugin_dependency_smoke_check
	install_mock_plugin_dependency_hooks
	test_dependency_install_recovery_activates_candidate
	test_older_candidate_cannot_replace_active_bundle
	test_dependency_install_failure_preserves_active_bundle

	printf 'Results: %s checks passed\n' "$TESTS_RUN"
	return 0
}

main "$@"
