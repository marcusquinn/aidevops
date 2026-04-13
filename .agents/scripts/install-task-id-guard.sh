#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# install-task-id-guard.sh — Install the task-id collision guard commit-msg hook
# into the current repository.
#
# Usage:
#   install-task-id-guard.sh install      Install (or update) the commit-msg hook
#   install-task-id-guard.sh uninstall    Remove just the task-id guard entry
#   install-task-id-guard.sh status       Report current state
#   install-task-id-guard.sh test         Run the test harness
#
# The installer writes a small dispatcher into .git/hooks/commit-msg that calls
# ~/.aidevops/agents/hooks/task-id-collision-guard.sh (survives aidevops updates).
# If a pre-existing commit-msg hook is found that is NOT ours, we refuse to
# overwrite and print remediation instructions.
#
# The installer targets the git COMMON dir (git rev-parse --git-common-dir)
# so worktrees share the hook with the parent repo.
#
# Bypass: TASK_ID_GUARD_DISABLE=1 git commit ...  or git commit --no-verify

set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

print_info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$1"; }
print_success() { printf '%s[OK]%s %s\n' "$GREEN" "$NC" "$1"; }
print_warning() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$1" >&2; }
print_error() { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$1" >&2; }

HOOK_MARKER="# aidevops-task-id-guard"
DEPLOYED_HOOK="$HOME/.aidevops/agents/hooks/task-id-collision-guard.sh"

#######################################
# Locate the repo-local copy of the hook (for use before aidevops update has
# deployed it) or fall back to the deployed location.
#######################################
_find_source_hook() {
	local script_dir
	script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	local repo_hook="${script_dir}/../hooks/task-id-collision-guard.sh"
	if [[ -f "$repo_hook" ]]; then
		echo "$repo_hook"
		return 0
	fi
	if [[ -f "$DEPLOYED_HOOK" ]]; then
		echo "$DEPLOYED_HOOK"
		return 0
	fi
	return 1
}

#######################################
# Resolve the git common dir (shared between worktrees).
#######################################
_git_common_dir() {
	git rev-parse --git-common-dir 2>/dev/null || {
		print_error "not a git repository"
		return 1
	}
	return 0
}

#######################################
# Install the hook. If an existing commit-msg hook is found that is not ours,
# abort with a clear message. Otherwise write a small dispatcher script.
#######################################
cmd_install() {
	local common_dir
	common_dir=$(_git_common_dir) || return 1

	local hook_path="${common_dir}/hooks/commit-msg"
	mkdir -p "$(dirname "$hook_path")"

	local source_hook
	if ! source_hook=$(_find_source_hook); then
		print_error "task-id-collision-guard.sh not found in repo or deployed location"
		print_error "  checked: \$REPO/.agents/hooks/task-id-collision-guard.sh"
		print_error "  checked: $DEPLOYED_HOOK"
		return 1
	fi

	if [[ -f "$hook_path" ]]; then
		if grep -q "$HOOK_MARKER" "$hook_path" 2>/dev/null; then
			print_info "task-id-guard already installed at $hook_path — updating"
		else
			print_error "existing commit-msg hook at $hook_path is NOT managed by aidevops"
			print_error "Refusing to overwrite. To chain, manually add this line to your hook:"
			print_error "  ${source_hook} \"\$1\" || exit \$?"
			return 1
		fi
	fi

	cat >"$hook_path" <<HOOKEOF
#!/usr/bin/env bash
$HOOK_MARKER
# Managed by .agents/scripts/install-task-id-guard.sh — do not edit.
# Dispatcher that calls the aidevops task-id collision guard.
# Bypass with --no-verify or TASK_ID_GUARD_DISABLE=1.

set -u

# Prefer the repo-local hook when available, fall back to deployed.
_repo_hook=""
if git_dir=\$(git rev-parse --show-toplevel 2>/dev/null); then
	_repo_hook="\${git_dir}/.agents/hooks/task-id-collision-guard.sh"
fi
_deployed_hook="$DEPLOYED_HOOK"

if [[ -n "\$_repo_hook" && -f "\$_repo_hook" ]]; then
	exec "\$_repo_hook" "\$1"
elif [[ -f "\$_deployed_hook" ]]; then
	exec "\$_deployed_hook" "\$1"
else
	printf '[task-id-guard][WARN] hook not installed — allowing commit\n' >&2
	exit 0
fi
HOOKEOF
	chmod +x "$hook_path"
	print_success "installed task-id-guard at $hook_path"
	print_info "source hook: $source_hook"
	print_info "bypass: TASK_ID_GUARD_DISABLE=1 git commit ...  (or git commit --no-verify)"
	return 0
}

#######################################
# Remove the hook if (and only if) it is managed by us.
#######################################
cmd_uninstall() {
	local common_dir
	common_dir=$(_git_common_dir) || return 1
	local hook_path="${common_dir}/hooks/commit-msg"

	if [[ ! -f "$hook_path" ]]; then
		print_info "no commit-msg hook installed"
		return 0
	fi

	if grep -q "$HOOK_MARKER" "$hook_path" 2>/dev/null; then
		rm -f "$hook_path"
		print_success "removed task-id-guard commit-msg hook"
		return 0
	fi

	print_warning "commit-msg hook at $hook_path is NOT managed by aidevops — leaving it alone"
	return 1
}

#######################################
# Report current state.
#######################################
cmd_status() {
	local common_dir
	common_dir=$(_git_common_dir) || return 1
	local hook_path="${common_dir}/hooks/commit-msg"

	if [[ ! -f "$hook_path" ]]; then
		printf 'commit-msg hook: NOT INSTALLED\n'
		return 0
	fi
	if grep -q "$HOOK_MARKER" "$hook_path" 2>/dev/null; then
		printf 'commit-msg hook: installed (aidevops task-id-guard)\n'
		printf '  path: %s\n' "$hook_path"
	else
		printf 'commit-msg hook: installed (unknown manager)\n'
		printf '  path: %s\n' "$hook_path"
	fi
	return 0
}

#######################################
# Run the test harness.
#######################################
cmd_test() {
	local script_dir
	script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	local test_script="${script_dir}/tests/test-task-id-collision-guard.sh"
	if [[ ! -f "$test_script" ]]; then
		print_error "test harness not found: $test_script"
		return 1
	fi
	bash "$test_script" "$@"
	return $?
}

main() {
	local cmd="${1:-install}"
	shift || true
	case "$cmd" in
	install) cmd_install "$@" ;;
	uninstall) cmd_uninstall "$@" ;;
	status) cmd_status "$@" ;;
	test) cmd_test "$@" ;;
	help | --help | -h)
		sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
		;;
	*)
		print_error "unknown command: $cmd"
		return 1
		;;
	esac
}

main "$@"
