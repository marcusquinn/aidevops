#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# install-gh-wrapper-guard.sh — Install the gh_create_issue / gh_create_pr
# wrapper pre-push guard (t2113) into the current repository.
#
# Usage:
#   install-gh-wrapper-guard.sh install     Install into .git/hooks/pre-push
#   install-gh-wrapper-guard.sh uninstall   Remove just the gh-wrapper entry
#   install-gh-wrapper-guard.sh status      Report current state
#
# Models on install-privacy-guard.sh. If an existing aidevops-managed
# pre-push hook (marked `# aidevops-privacy-guard` or similar) is found,
# this installer writes a chain dispatcher that runs both guards in
# sequence so both rules apply. Chain order: privacy-guard → gh-wrapper-guard.
#
# Bypass at push time: GH_WRAPPER_GUARD_DISABLE=1 git push ... or --no-verify.

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

HOOK_MARKER="# aidevops-gh-wrapper-guard"
PRIVACY_MARKER="# aidevops-privacy-guard"
DEPLOYED_HOOK="$HOME/.aidevops/agents/hooks/gh-wrapper-guard-pre-push.sh"

_find_source_hook() {
	local script_dir
	script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	local repo_hook="$script_dir/../hooks/gh-wrapper-guard-pre-push.sh"
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

_git_common_dir() {
	if ! git rev-parse --git-common-dir >/dev/null 2>&1; then
		print_error "not inside a git repository"
		return 1
	fi
	git rev-parse --git-common-dir
}

# _write_standalone: single-guard dispatcher (gh-wrapper-guard only).
_write_standalone() {
	local hook_path="$1"
	cat >"$hook_path" <<HOOKEOF
#!/usr/bin/env bash
$HOOK_MARKER
# Managed by .agents/scripts/install-gh-wrapper-guard.sh — do not edit.
# Dispatcher that calls the aidevops gh-wrapper-guard pre-push hook.
# Bypass with --no-verify or GH_WRAPPER_GUARD_DISABLE=1.

set -u

_repo_hook=""
if git_dir=\$(git rev-parse --show-toplevel 2>/dev/null); then
	_repo_hook="\${git_dir}/.agents/hooks/gh-wrapper-guard-pre-push.sh"
fi
_deployed_hook="$DEPLOYED_HOOK"

if [[ -n "\$_repo_hook" && -f "\$_repo_hook" ]]; then
	exec "\$_repo_hook" "\$@"
elif [[ -f "\$_deployed_hook" ]]; then
	exec "\$_deployed_hook" "\$@"
else
	printf '[gh-wrapper-guard][WARN] hook not installed — allowing push\n' >&2
	exit 0
fi
HOOKEOF
	chmod +x "$hook_path"
}

# _write_chain: dispatcher that runs privacy-guard then gh-wrapper-guard.
# Both must exit 0 for the push to proceed. stdin is re-read for each guard
# by buffering it to a temp file (git pre-push sends ref-line data via stdin
# which the hooks need to consume).
_write_chain() {
	local hook_path="$1"
	cat >"$hook_path" <<HOOKEOF
#!/usr/bin/env bash
$PRIVACY_MARKER
$HOOK_MARKER
# Managed by .agents/scripts/install-gh-wrapper-guard.sh (chain form).
# Runs privacy-guard then gh-wrapper-guard in sequence. Both must pass.

set -u

# Buffer stdin once so both guards see the ref-line data.
_stdin_buf=\$(mktemp)
trap 'rm -f "\$_stdin_buf"' EXIT
cat >"\$_stdin_buf"

_repo_root=\$(git rev-parse --show-toplevel 2>/dev/null || echo "")
_run_guard() {
	local name="\$1" script_rel="\$2" deployed="\$3"
	local repo_hook="\${_repo_root:+\${_repo_root}/\${script_rel}}"
	local target=""
	if [[ -n "\$repo_hook" && -f "\$repo_hook" ]]; then
		target="\$repo_hook"
	elif [[ -f "\$deployed" ]]; then
		target="\$deployed"
	else
		printf '[%s][WARN] hook not installed — skipping\n' "\$name" >&2
		return 0
	fi
	"\$target" "\$@" <"\$_stdin_buf"
}

_run_guard "privacy-guard" ".agents/hooks/privacy-guard-pre-push.sh" \\
	"$HOME/.aidevops/agents/hooks/privacy-guard-pre-push.sh" "\$@" || exit \$?
_run_guard "gh-wrapper-guard" ".agents/hooks/gh-wrapper-guard-pre-push.sh" \\
	"$DEPLOYED_HOOK" "\$@" || exit \$?
exit 0
HOOKEOF
	chmod +x "$hook_path"
}

cmd_install() {
	local common_dir
	common_dir=$(_git_common_dir) || return 1
	local hook_path="${common_dir}/hooks/pre-push"
	mkdir -p "${common_dir}/hooks"

	local source_hook
	if ! source_hook=$(_find_source_hook); then
		print_error "gh-wrapper-guard-pre-push.sh not found in repo or deployed location"
		return 1
	fi

	if [[ -f "$hook_path" ]]; then
		local has_gh_marker=0 has_privacy_marker=0
		grep -q "$HOOK_MARKER" "$hook_path" 2>/dev/null && has_gh_marker=1
		grep -q "$PRIVACY_MARKER" "$hook_path" 2>/dev/null && has_privacy_marker=1

		if [[ "$has_gh_marker" -eq 1 && "$has_privacy_marker" -eq 1 ]]; then
			# Already a chain dispatcher — rewrite as chain to pick up any
			# dispatcher updates without stripping the privacy guard.
			print_info "chain dispatcher present — re-writing in chain form"
			_write_chain "$hook_path"
			print_success "refreshed gh-wrapper-guard + privacy-guard chain at $hook_path"
			print_info "source hook: $source_hook"
			print_info "bypass: GH_WRAPPER_GUARD_DISABLE=1 git push ...  (or git push --no-verify)"
			return 0
		elif [[ "$has_gh_marker" -eq 1 ]]; then
			print_info "gh-wrapper-guard already installed at $hook_path — refreshing (standalone)"
			_write_standalone "$hook_path"
			print_success "refreshed gh-wrapper-guard at $hook_path"
			print_info "source hook: $source_hook"
			print_info "bypass: GH_WRAPPER_GUARD_DISABLE=1 git push ...  (or git push --no-verify)"
			return 0
		elif [[ "$has_privacy_marker" -eq 1 ]]; then
			print_info "privacy-guard present — upgrading to chain dispatcher"
			_write_chain "$hook_path"
			print_success "installed gh-wrapper-guard + privacy-guard chain at $hook_path"
			print_info "source hook: $source_hook"
			print_info "bypass: GH_WRAPPER_GUARD_DISABLE=1 git push ...  (or git push --no-verify)"
			return 0
		else
			print_error "existing pre-push hook at $hook_path is NOT managed by aidevops"
			print_error "Refusing to overwrite. To chain, add this line to your hook:"
			print_error "  ${source_hook} \"\$@\" < /dev/stdin || exit \$?"
			return 1
		fi
	fi

	_write_standalone "$hook_path"
	print_success "installed gh-wrapper-guard at $hook_path"
	print_info "source hook: $source_hook"
	print_info "bypass: GH_WRAPPER_GUARD_DISABLE=1 git push ...  (or git push --no-verify)"
	return 0
}

cmd_uninstall() {
	local common_dir
	common_dir=$(_git_common_dir) || return 1
	local hook_path="${common_dir}/hooks/pre-push"

	if [[ ! -f "$hook_path" ]]; then
		print_info "no pre-push hook installed"
		return 0
	fi

	if ! grep -q "$HOOK_MARKER" "$hook_path" 2>/dev/null; then
		print_info "gh-wrapper-guard not installed at $hook_path"
		return 0
	fi

	# If privacy-guard is also present, downgrade to privacy-guard-only.
	# Otherwise remove the hook entirely.
	if grep -q "$PRIVACY_MARKER" "$hook_path" 2>/dev/null; then
		print_info "privacy-guard still present — downgrading chain to privacy-guard-only"
		# Regenerate the privacy-guard standalone dispatcher.
		cat >"$hook_path" <<PGEOF
#!/usr/bin/env bash
$PRIVACY_MARKER
# Managed by .agents/scripts/install-privacy-guard.sh — do not edit.
set -u
_repo_hook=""
if git_dir=\$(git rev-parse --show-toplevel 2>/dev/null); then
	_repo_hook="\${git_dir}/.agents/hooks/privacy-guard-pre-push.sh"
fi
_deployed_hook="$HOME/.aidevops/agents/hooks/privacy-guard-pre-push.sh"
if [[ -n "\$_repo_hook" && -f "\$_repo_hook" ]]; then
	exec "\$_repo_hook" "\$@"
elif [[ -f "\$_deployed_hook" ]]; then
	exec "\$_deployed_hook" "\$@"
else
	printf '[privacy-guard][WARN] hook not installed — allowing push\n' >&2
	exit 0
fi
PGEOF
		chmod +x "$hook_path"
		print_success "removed gh-wrapper-guard, privacy-guard remains"
		return 0
	fi

	rm -f "$hook_path"
	print_success "removed gh-wrapper-guard pre-push hook"
	return 0
}

cmd_status() {
	local common_dir
	common_dir=$(_git_common_dir) || return 1
	local hook_path="${common_dir}/hooks/pre-push"

	printf 'gh-wrapper-guard pre-push status\n'
	printf '================================\n'

	if [[ ! -f "$hook_path" ]]; then
		print_info "no pre-push hook installed at $hook_path"
		return 0
	fi

	if grep -q "$HOOK_MARKER" "$hook_path" 2>/dev/null; then
		print_success "gh-wrapper-guard active at $hook_path"
	else
		print_warning "pre-push hook exists but gh-wrapper-guard is NOT active"
	fi

	if grep -q "$PRIVACY_MARKER" "$hook_path" 2>/dev/null; then
		print_info "privacy-guard is also active (chain dispatcher)"
	fi
	return 0
}

show_help() {
	cat <<EOF
install-gh-wrapper-guard.sh — install the t2113 pre-push hook.

Usage:
  install-gh-wrapper-guard.sh install
  install-gh-wrapper-guard.sh uninstall
  install-gh-wrapper-guard.sh status

The installer writes a dispatcher at .git/hooks/pre-push (git common dir).
If privacy-guard is already installed, both run as a chain — both must pass.

Bypass at push time:
  GH_WRAPPER_GUARD_DISABLE=1 git push ...
  git push --no-verify
EOF
	return 0
}

case "${1:-install}" in
install) cmd_install ;;
uninstall) cmd_uninstall ;;
status) cmd_status ;;
help | --help | -h) show_help ;;
*)
	print_error "unknown command: ${1:-}"
	show_help
	exit 1
	;;
esac
