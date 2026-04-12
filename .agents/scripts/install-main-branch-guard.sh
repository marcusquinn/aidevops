#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# install-main-branch-guard.sh — Install the main-branch-guard post-checkout hook
# into the current (or specified) repository.
#
# Usage:
#   install-main-branch-guard.sh install [--repo-path <path>] [--force]
#   install-main-branch-guard.sh uninstall [--repo-path <path>]
#   install-main-branch-guard.sh status [--repo-path <path>]
#   install-main-branch-guard.sh test
#
# The hook enforces "canonical worktree stays on main" at the git-operation
# level. It detects branch-level checkouts in the canonical worktree (git-dir
# == git-common-dir), auto-restores main, and prints a guided error message.
#
# Linked worktrees are unaffected — the git-dir discrimination skips them.
#
# The hook target is .git/hooks/post-checkout in the git COMMON dir so all
# worktrees of a repo share one install.
#
# Idempotent: re-runs silently if the marker is already present.
# If an existing post-checkout hook is found that is NOT ours, we refuse to
# overwrite unless --force is given (which backs up the existing hook first).
#
# Opt out: AIDEVOPS_MAIN_BRANCH_GUARD=false (env var honoured by the hook
# itself and by this installer when set before running setup.sh).

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

HOOK_MARKER="# aidevops-main-branch-guard"
DEPLOYED_HOOK="$HOME/.aidevops/agents/hooks/main-branch-guard-post-checkout.sh"

#######################################
# Locate the repo-local copy of the hook (for use before `aidevops update`
# has deployed it) or fall back to the deployed location.
# Returns: path on stdout, 0 on success; nothing + 1 on miss.
#######################################
_find_source_hook() {
	local script_dir
	script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	local repo_hook="$script_dir/../hooks/main-branch-guard-post-checkout.sh"
	if [[ -f "$repo_hook" ]]; then
		printf '%s' "$repo_hook"
		return 0
	fi
	if [[ -f "$DEPLOYED_HOOK" ]]; then
		printf '%s' "$DEPLOYED_HOOK"
		return 0
	fi
	return 1
}

#######################################
# Resolve the git common dir.
# When --repo-path is given, resolve it relative to that path.
# Returns: path on stdout, 0 on success; nothing + 1 on error.
#######################################
_git_common_dir() {
	local repo_path="${1:-}"
	if [[ -n "$repo_path" ]]; then
		git -C "$repo_path" rev-parse --git-common-dir 2>/dev/null || {
			print_error "not a git repository at $repo_path"
			return 1
		}
	else
		git rev-parse --git-common-dir 2>/dev/null || {
			print_error "not a git repository"
			return 1
		}
	fi
	return 0
}

#######################################
# Install the post-checkout hook.
# Args: [--repo-path <path>] [--force]
#######################################
cmd_install() {
	local repo_path="" force=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo-path)
			repo_path="$2"
			shift 2
			;;
		--force)
			force=true
			shift
			;;
		*)
			print_error "unknown option: $1"
			return 1
			;;
		esac
	done

	local common_dir
	common_dir=$(_git_common_dir "$repo_path") || return 1

	# Resolve to absolute path
	local abs_common_dir
	abs_common_dir=$(cd "$common_dir" 2>/dev/null && pwd -P || echo "$common_dir")

	local hook_path="${abs_common_dir}/hooks/post-checkout"
	mkdir -p "$(dirname "$hook_path")"

	local source_hook
	if ! source_hook=$(_find_source_hook); then
		print_error "main-branch-guard-post-checkout.sh not found in repo or deployed location"
		print_error "  checked: \$REPO/.agents/hooks/main-branch-guard-post-checkout.sh"
		print_error "  checked: $DEPLOYED_HOOK"
		return 1
	fi

	if [[ -f "$hook_path" ]]; then
		if grep -q "$HOOK_MARKER" "$hook_path" 2>/dev/null; then
			print_info "main-branch-guard already installed at $hook_path — updating"
		elif [[ "$force" == "true" ]]; then
			local backup
			backup="${hook_path}.bak.$(date +%Y%m%d%H%M%S)"
			cp "$hook_path" "$backup"
			print_warning "existing post-checkout hook backed up to $backup"
		else
			print_error "existing post-checkout hook at $hook_path is NOT managed by aidevops"
			print_error "Refusing to overwrite. Options:"
			print_error "  1. Use --force to back up and replace the existing hook"
			print_error "  2. Manually add this call to your hook:"
			print_error "     ${source_hook} \"\$1\" \"\$2\" \"\$3\""
			return 1
		fi
	fi

	cat >"$hook_path" <<HOOKEOF
#!/usr/bin/env bash
$HOOK_MARKER
# Managed by .agents/scripts/install-main-branch-guard.sh — do not edit.
# Dispatcher that calls the aidevops main-branch guard.
# Opt out: AIDEVOPS_MAIN_BRANCH_GUARD=false git checkout ...

set -u

# Prefer the repo-local hook when available, fall back to deployed.
_repo_hook=""
if _top=\$(git rev-parse --show-toplevel 2>/dev/null); then
	_repo_hook="\${_top}/.agents/hooks/main-branch-guard-post-checkout.sh"
fi
_deployed_hook="$DEPLOYED_HOOK"

if [[ -n "\$_repo_hook" && -f "\$_repo_hook" ]]; then
	exec "\$_repo_hook" "\$@"
elif [[ -f "\$_deployed_hook" ]]; then
	exec "\$_deployed_hook" "\$@"
else
	printf '[main-branch-guard][WARN] hook source not found — skipping check\n' >&2
	exit 0
fi
HOOKEOF
	chmod +x "$hook_path"
	print_success "installed main-branch-guard at $hook_path"
	print_info "source hook: $source_hook"
	print_info "bypass: AIDEVOPS_MAIN_BRANCH_GUARD=false git checkout ..."
	return 0
}

#######################################
# Remove the hook if (and only if) it is managed by us.
# Restores .bak backup if one exists.
# Args: [--repo-path <path>]
#######################################
cmd_uninstall() {
	local repo_path=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo-path)
			repo_path="$2"
			shift 2
			;;
		*)
			print_error "unknown option: $1"
			return 1
			;;
		esac
	done

	local common_dir
	common_dir=$(_git_common_dir "$repo_path") || return 1
	local abs_common_dir
	abs_common_dir=$(cd "$common_dir" 2>/dev/null && pwd -P || echo "$common_dir")
	local hook_path="${abs_common_dir}/hooks/post-checkout"

	if [[ ! -f "$hook_path" ]]; then
		print_info "no post-checkout hook installed"
		return 0
	fi

	if grep -q "$HOOK_MARKER" "$hook_path" 2>/dev/null; then
		rm -f "$hook_path"
		# Restore most recent backup if one exists
		local newest_bak
		newest_bak=$(ls -t "${hook_path}.bak."* 2>/dev/null | head -n1 || true)
		if [[ -n "$newest_bak" ]]; then
			mv "$newest_bak" "$hook_path"
			print_success "removed main-branch-guard hook and restored backup: $newest_bak"
		else
			print_success "removed main-branch-guard post-checkout hook"
		fi
		return 0
	fi

	print_warning "post-checkout hook at $hook_path is NOT managed by aidevops — leaving it alone"
	return 1
}

#######################################
# Report current state.
# Args: [--repo-path <path>]
#######################################
cmd_status() {
	local repo_path=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo-path)
			repo_path="$2"
			shift 2
			;;
		*)
			print_error "unknown option: $1"
			return 1
			;;
		esac
	done

	local common_dir
	common_dir=$(_git_common_dir "$repo_path") || return 1
	local abs_common_dir
	abs_common_dir=$(cd "$common_dir" 2>/dev/null && pwd -P || echo "$common_dir")
	local hook_path="${abs_common_dir}/hooks/post-checkout"

	if [[ ! -f "$hook_path" ]]; then
		printf 'post-checkout hook: NOT INSTALLED\n'
		return 0
	fi
	if grep -q "$HOOK_MARKER" "$hook_path" 2>/dev/null; then
		printf 'post-checkout hook: installed (aidevops main-branch-guard)\n'
		printf '  path: %s\n' "$hook_path"
		printf '  bypass: AIDEVOPS_MAIN_BRANCH_GUARD=false git checkout ...\n'
	else
		printf 'post-checkout hook: installed (unknown manager)\n'
		printf '  path: %s\n' "$hook_path"
	fi
	return 0
}

#######################################
# Run the test harness (delegates to test-main-branch-guard.sh).
#######################################
cmd_test() {
	local script_dir
	script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	local test_script="${script_dir}/test-main-branch-guard.sh"
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
		sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
		;;
	*)
		print_error "unknown command: $cmd"
		return 1
		;;
	esac
}

main "$@"
