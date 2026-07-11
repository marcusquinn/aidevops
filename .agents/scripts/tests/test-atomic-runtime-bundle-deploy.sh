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
	mkdir -p "$FAKE_REPO/.agents/scripts"
	printf '%s\n' "$version" >"$FAKE_REPO/VERSION"
	printf '#!/usr/bin/env bash\nprintf %s\\n "%s"\n' '%s' "$version" >"$FAKE_REPO/aidevops.sh"
	printf '#!/usr/bin/env bash\nprintf %s\\n "%s"\n' '%s' "$marker" >"$FAKE_REPO/.agents/scripts/helper.sh"
	printf '#!/usr/bin/env bash\nexec git "$@"\n' >"$FAKE_REPO/.agents/scripts/git"
	printf '# test agents\n' >"$FAKE_REPO/.agents/AGENTS.md"
	chmod +x "$FAKE_REPO/aidevops.sh" "$FAKE_REPO/.agents/scripts/helper.sh" "$FAKE_REPO/.agents/scripts/git"
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
	test_macos_and_linux_link_paths

	printf 'Results: %s checks passed\n' "$TESTS_RUN"
	return 0
}

main "$@"
