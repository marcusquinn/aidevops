#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
	else
		printf 'FAIL %s\n' "$test_name"
		[[ -n "$message" ]] && printf '  %s\n' "$message"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

teardown() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

gh() {
	local command="${1:-}"
	local subcommand="${2:-}"
	local args="$*"
	if [[ "$command" == "pr" && "$subcommand" == "view" ]]; then
		if [[ "$args" == *"headRefName"* ]]; then
			printf '%s\n' "feature/full-loop-cleanup"
			return 0
		fi
		if [[ "$args" == *"body"* ]]; then
			printf '%s\n' "Resolves #42"
			return 0
		fi
	fi
	return 0
}

cmd_pre_merge_gate() {
	local pr_number="${1:-}"
	local repo="${2:-}"
	[[ -n "$pr_number" && -n "$repo" ]] || return 1
	return 0
}

_merge_execute() {
	local pr_number="${1:-}"
	local repo="${2:-}"
	local merge_method="${3:-}"
	local has_admin="${4:-}"
	local has_auto="${5:-}"
	[[ -n "$pr_number" && -n "$repo" && -n "$merge_method" && -n "$has_admin" && -n "$has_auto" ]] || return 1
	return 0
}

_retarget_stacked_children_interactive() {
	local pr_number="${1:-}"
	local repo="${2:-}"
	[[ -n "$pr_number" && -n "$repo" ]] || return 1
	return 0
}

_merge_unlock_resources() {
	local pr_number="${1:-}"
	local repo="${2:-}"
	[[ -n "$pr_number" && -n "$repo" ]] || return 1
	return 0
}

release_interactive_claim_on_merge() {
	local pr_number="${1:-}"
	local repo="${2:-}"
	local issue_number="${3:-}"
	[[ -n "$pr_number" && -n "$repo" && -n "$issue_number" ]] || return 1
	return 0
}

auto_file_next_phase() {
	local issue_number="${1:-}"
	local repo="${2:-}"
	[[ -n "$issue_number" && -n "$repo" ]] || return 1
	return 0
}

install_subject_stubs() {
	# full-loop-helper-merge.sh defines several of these symbols. Reinstall the
	# stubs after sourcing so cmd_merge exercises orchestration and cleanup only.
	cmd_pre_merge_gate() {
		local pr_number="${1:-}"
		local repo="${2:-}"
		[[ -n "$pr_number" && -n "$repo" ]] || return 1
		return 0
	}

	_merge_execute() {
		local pr_number="${1:-}"
		local repo="${2:-}"
		local merge_method="${3:-}"
		local has_admin="${4:-}"
		local has_auto="${5:-}"
		[[ -n "$pr_number" && -n "$repo" && -n "$merge_method" && -n "$has_admin" && -n "$has_auto" ]] || return 1
		return 0
	}

	_retarget_stacked_children_interactive() {
		local pr_number="${1:-}"
		local repo="${2:-}"
		[[ -n "$pr_number" && -n "$repo" ]] || return 1
		return 0
	}

	_merge_unlock_resources() {
		local pr_number="${1:-}"
		local repo="${2:-}"
		[[ -n "$pr_number" && -n "$repo" ]] || return 1
		return 0
	}

	release_interactive_claim_on_merge() {
		local pr_number="${1:-}"
		local repo="${2:-}"
		local issue_number="${3:-}"
		[[ -n "$pr_number" && -n "$repo" && -n "$issue_number" ]] || return 1
		return 0
	}

	auto_file_next_phase() {
		local issue_number="${1:-}"
		local repo="${2:-}"
		[[ -n "$issue_number" && -n "$repo" ]] || return 1
		return 0
	}

	return 0
}

setup_subject() {
	TEST_ROOT=$(mktemp -d)
	trap teardown EXIT
	export HOME="${TEST_ROOT}/home"
	export AIDEVOPS_SKIP_AUTO_CLAIM=1
	mkdir -p "$HOME" "${TEST_ROOT}/bin"
	cat >"${TEST_ROOT}/bin/trash" <<'TRASH'
#!/usr/bin/env bash
exit 1
TRASH
	chmod +x "${TEST_ROOT}/bin/trash"
	export PATH="${TEST_ROOT}/bin:${PATH}"

	local canonical_repo="${TEST_ROOT}/repo"
	local origin_repo="${TEST_ROOT}/origin.git"
	local updater_repo="${TEST_ROOT}/updater"
	local worktree_path="${TEST_ROOT}/worktrees/repo-feature-full-loop-cleanup"
	mkdir -p "$canonical_repo" "${worktree_path%/*}"
	git -C "$canonical_repo" init -q -b main
	git -C "$canonical_repo" config user.email test@example.invalid
	git -C "$canonical_repo" config user.name 'Aidevops Test'
	printf 'base\n' >"${canonical_repo}/README.md"
	git -C "$canonical_repo" add README.md
	git -C "$canonical_repo" commit -q -m 'init'
	git clone -q --bare "$canonical_repo" "$origin_repo"
	git -C "$canonical_repo" remote add origin "$origin_repo"
	git -C "$canonical_repo" push -q -u origin main
	git -C "$canonical_repo" worktree add -q "$worktree_path" -b feature/full-loop-cleanup
	git -C "$canonical_repo" checkout -q -b feature/active
	git clone -q "$origin_repo" "$updater_repo"
	git -C "$updater_repo" config user.email test@example.invalid
	git -C "$updater_repo" config user.name 'Aidevops Test'
	printf 'remote main advance\n' >>"${updater_repo}/README.md"
	git -C "$updater_repo" add README.md
	git -C "$updater_repo" commit -q -m 'advance main'
	git -C "$updater_repo" push -q origin main

	cd "$worktree_path"
	export SCRIPT_DIR="$AGENTS_SCRIPTS_DIR"
	# shellcheck source=../shared-constants.sh
	source "${AGENTS_SCRIPTS_DIR}/shared-constants.sh"
	# shellcheck source=../full-loop-helper-merge.sh
	source "${AGENTS_SCRIPTS_DIR}/full-loop-helper-merge.sh"
	install_subject_stubs
	return 0
}

test_cmd_merge_removes_current_linked_worktree() {
	local canonical_repo="${TEST_ROOT}/repo"
	local worktree_path="${TEST_ROOT}/worktrees/repo-feature-full-loop-cleanup"
	local active_before=""
	active_before=$(git -C "$canonical_repo" rev-parse feature/active)

	cmd_merge "123" "example/repo" --squash

	local rc=0
	if git -C "$canonical_repo" worktree list --porcelain | grep -q "$worktree_path"; then
		rc=1
	fi
	[[ ! -d "$worktree_path" ]] || rc=1
	if git -C "$canonical_repo" show-ref --verify --quiet refs/heads/feature/full-loop-cleanup; then
		rc=1
	fi
	if [[ "$(git -C "$canonical_repo" branch --show-current)" != "feature/active" ]]; then
		rc=1
	fi
	if [[ "$(git -C "$canonical_repo" rev-parse feature/active)" != "$active_before" ]]; then
		rc=1
	fi
	print_result "cmd_merge removes current linked worktree after immediate merge" "$rc"
	return 0
}

main() {
	setup_subject
	test_cmd_merge_removes_current_linked_worktree
	printf '\n%d/%d tests passed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
	[[ "$TESTS_FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
