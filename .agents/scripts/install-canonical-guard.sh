#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# install-canonical-guard.sh — Install the canonical-on-main-guard git
# post-checkout hook into the current repository.
#
# Usage:
#   install-canonical-guard.sh install      Install (or refresh) in .git/hooks/post-checkout
#   install-canonical-guard.sh uninstall    Remove just our entry
#   install-canonical-guard.sh status       Report current state
#   install-canonical-guard.sh test         Run the shared test harness
#
# Model: mirrors .agents/scripts/install-privacy-guard.sh (t1965).
#
# The installer targets the git COMMON dir (`git rev-parse --git-common-dir`)
# so worktrees share the hook with the parent repo. If a pre-existing hook
# that is not ours is found, we refuse to overwrite and print chaining
# instructions.

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

HOOK_MARKER="# aidevops-canonical-guard"
# Legacy marker from the pre-framework local install that predates t1995.
# When we see this marker we treat the existing hook as a superseded version
# and replace it with the framework-tracked dispatcher.
LEGACY_MARKER="t1988 session, local install"
DEPLOYED_HOOK="$HOME/.aidevops/agents/hooks/canonical-on-main-guard.sh"

#######################################
# Locate the source hook (repo-local copy or deployed fallback).
#######################################
_find_source_hook() {
	local script_dir
	script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	local repo_hook="$script_dir/../hooks/canonical-on-main-guard.sh"
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
# Install the hook. Refuses to overwrite unmanaged pre-existing hooks.
#######################################
cmd_install() {
	local common_dir
	common_dir=$(_git_common_dir) || return 1

	local hook_path="${common_dir}/hooks/post-checkout"
	mkdir -p "$(dirname "$hook_path")"

	local source_hook
	if ! source_hook=$(_find_source_hook); then
		print_error "canonical-on-main-guard.sh not found in repo or deployed location"
		print_error "  checked: \$REPO/.agents/hooks/canonical-on-main-guard.sh"
		print_error "  checked: $DEPLOYED_HOOK"
		return 1
	fi

	if [[ -f "$hook_path" ]]; then
		if grep -q "$HOOK_MARKER" "$hook_path" 2>/dev/null; then
			print_info "canonical-on-main-guard already installed at $hook_path — refreshing"
		elif grep -q "$LEGACY_MARKER" "$hook_path" 2>/dev/null; then
			# Pre-framework local install (t1988-era). Replace with the
			# framework dispatcher — the framework version is strictly
			# better (headless bypass, repos.json cross-check, warn-by-default).
			print_info "detected legacy local post-checkout hook — migrating to framework version"
			# Save a copy for user reference
			cp "$hook_path" "${hook_path}.t1988-legacy-backup" 2>/dev/null || true
			print_info "  legacy hook backed up to ${hook_path}.t1988-legacy-backup"
		else
			print_error "existing post-checkout hook at $hook_path is NOT managed by aidevops"
			print_error "Refusing to overwrite. To chain, manually add this line to your hook:"
			print_error "  ${source_hook} \"\$@\" || exit \$?"
			return 1
		fi
	fi

	cat >"$hook_path" <<HOOKEOF
#!/usr/bin/env bash
$HOOK_MARKER
# Managed by .agents/scripts/install-canonical-guard.sh — do not edit.
# Dispatcher that calls the aidevops canonical-on-main guard.
# Bypass with: AIDEVOPS_CANONICAL_GUARD=bypass git checkout ...
# Strict mode: AIDEVOPS_CANONICAL_GUARD=strict git checkout ...

set -u

# Prefer the repo-local hook when available, fall back to deployed.
_repo_hook=""
if git_dir=\$(git rev-parse --show-toplevel 2>/dev/null); then
	_repo_hook="\${git_dir}/.agents/hooks/canonical-on-main-guard.sh"
fi
_deployed_hook="$DEPLOYED_HOOK"

if [[ -n "\$_repo_hook" && -f "\$_repo_hook" ]]; then
	exec "\$_repo_hook" "\$@"
elif [[ -f "\$_deployed_hook" ]]; then
	exec "\$_deployed_hook" "\$@"
else
	# No hook available — allow checkout silently.
	exit 0
fi
HOOKEOF
	chmod +x "$hook_path"
	print_success "installed canonical-on-main-guard at $hook_path"
	print_info "source hook: $source_hook"
	print_info "bypass: AIDEVOPS_CANONICAL_GUARD=bypass git checkout ..."
	print_info "strict: AIDEVOPS_CANONICAL_GUARD=strict git checkout ..."
	return 0
}

#######################################
# Remove the hook if (and only if) it is managed by us.
#######################################
cmd_uninstall() {
	local common_dir
	common_dir=$(_git_common_dir) || return 1
	local hook_path="${common_dir}/hooks/post-checkout"

	if [[ ! -f "$hook_path" ]]; then
		print_info "no post-checkout hook installed"
		return 0
	fi

	if grep -q "$HOOK_MARKER" "$hook_path" 2>/dev/null; then
		rm -f "$hook_path"
		print_success "removed canonical-on-main-guard post-checkout hook"
		return 0
	fi

	print_warning "post-checkout hook at $hook_path is NOT managed by aidevops — leaving it alone"
	return 1
}

#######################################
# Report current state.
#######################################
cmd_status() {
	local common_dir
	common_dir=$(_git_common_dir) || return 1
	local hook_path="${common_dir}/hooks/post-checkout"

	if [[ ! -f "$hook_path" ]]; then
		printf 'post-checkout hook: NOT INSTALLED\n'
		return 0
	fi
	if grep -q "$HOOK_MARKER" "$hook_path" 2>/dev/null; then
		printf 'post-checkout hook: installed (aidevops canonical-on-main guard)\n'
		printf '  path: %s\n' "$hook_path"
	else
		printf 'post-checkout hook: installed (unknown manager)\n'
		printf '  path: %s\n' "$hook_path"
	fi
	return 0
}

#######################################
# Run the test harness (delegates to test-canonical-guard.sh).
#######################################
cmd_test() {
	local script_dir
	script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	local test_script="${script_dir}/test-canonical-guard.sh"
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
