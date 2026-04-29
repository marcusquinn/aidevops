#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# install-pre-push-guards.sh — Install aidevops git pre-push/pre-commit hooks (t2198, t2446, t2458, t2745, t3020).
#
# Manages six guards in the current repository:
#
# Pre-push guards (installed to .git/hooks/pre-push):
#   - privacy-guard        blocks pushes leaking private repo slugs
#   - complexity-guard     blocks pushes introducing complexity regressions
#   - scope-guard          blocks pushes touching files outside the brief's Files Scope
#   - credential-guard     blocks pushes emitting unsanitised remote URLs (t2458)
#   - dup-todo-guard       blocks pushes where TODO.md has duplicate task-ID checkbox lines (t2745)
#
# Pre-commit guards (installed to .git/hooks/pre-commit):
#   - brief-filename-guard blocks commits adding todo/tasks/tNNN-brief.md with unclaimed t-IDs (t3020)
#
# Usage:
#   install-pre-push-guards.sh install [--guard <name>]
#         Install (or refresh) guard(s).
#         --guard: privacy|complexity|scope|credential|dup-todo|brief-filename|all (default: all)
#
#   install-pre-push-guards.sh uninstall [--guard <name>]
#         Remove guard entry/entries.
#         --guard: privacy|complexity|scope|credential|dup-todo|brief-filename|all (default: all)
#
#   install-pre-push-guards.sh status
#         Report which guards are present and their hook source locations.
#
# Pre-push installer writes .git/hooks/pre-push targeting `git rev-parse
# --git-common-dir` so worktrees share the hook with the parent repo.
# Pre-commit installer writes .git/hooks/pre-commit (same common-dir logic).
#
# Existing hooks NOT managed by aidevops are refused and left untouched.
#
# Runtime bypass per-guard:
#   PRIVACY_GUARD_DISABLE=1          skip privacy check for this push
#   COMPLEXITY_GUARD_DISABLE=1       skip complexity check for this push
#   SCOPE_GUARD_DISABLE=1            skip scope check for this push
#   CREDENTIAL_GUARD_DISABLE=1       skip credential check for this push
#   DUP_TODO_GUARD_DISABLE=1         skip duplicate TODO check for this push
#   BRIEF_FILENAME_GUARD_DISABLE=1   skip brief-filename check for this commit
#   git push --no-verify             skip all pre-push hooks
#   git commit --no-verify           skip all pre-commit hooks

set -euo pipefail

# Guard against unguarded shared-constants name collisions.
[[ -z "${RED+x}" ]]    && RED=$'\033[0;31m'
[[ -z "${GREEN+x}" ]]  && GREEN=$'\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW=$'\033[1;33m'
[[ -z "${BLUE+x}" ]]   && BLUE=$'\033[0;34m'
[[ -z "${NC+x}" ]]     && NC=$'\033[0m'

print_info() {
	local _m="$1"
	printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$_m"
	return 0
}
print_success() {
	local _m="$1"
	printf '%s[OK]%s %s\n' "$GREEN" "$NC" "$_m"
	return 0
}
print_warning() {
	local _m="$1"
	printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$_m" >&2
	return 0
}
print_error() {
	local _m="$1"
	printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$_m" >&2
	return 0
}

# Marker strings embedded in the managed hook file — used for detect/update.
HOOK_MARKER_MANAGED="# aidevops-pre-push-guards"
HOOK_MARKER_PRECOMMIT_MANAGED="# aidevops-pre-commit-guards"
HOOK_MARKER_PRIVACY="# guard:privacy"
HOOK_MARKER_COMPLEXITY="# guard:complexity"
HOOK_MARKER_SCOPE="# guard:scope"
HOOK_MARKER_CREDENTIAL="# guard:credential"
HOOK_MARKER_DUP_TODO="# guard:dup-todo"
HOOK_MARKER_BRIEF_FILENAME="# guard:brief-filename"

DEPLOYED_PRIVACY_HOOK="$HOME/.aidevops/agents/hooks/privacy-guard-pre-push.sh"
DEPLOYED_COMPLEXITY_HOOK="$HOME/.aidevops/agents/hooks/complexity-regression-pre-push.sh"
DEPLOYED_SCOPE_HOOK="$HOME/.aidevops/agents/hooks/scope-guard-pre-push.sh"
DEPLOYED_CREDENTIAL_HOOK="$HOME/.aidevops/agents/hooks/credential-emission-pre-push.sh"
DEPLOYED_DUP_TODO_HOOK="$HOME/.aidevops/agents/hooks/pre-push-dup-todo-guard.sh"
DEPLOYED_BRIEF_FILENAME_HOOK="$HOME/.aidevops/agents/hooks/brief-filename-guard.sh"

#######################################
# Resolve the script's own directory (symlink-safe).
#######################################
_script_dir() {
	local _src="${BASH_SOURCE[0]}"
	while [[ -L "$_src" ]]; do
		local _dir
		_dir=$(cd -P "$(dirname "$_src")" && pwd)
		_src=$(readlink "$_src")
		[[ "$_src" != /* ]] && _src="$_dir/$_src"
	done
	cd -P "$(dirname "$_src")" && pwd
	return 0
}

#######################################
# Find the source hook file for a named guard.
# Prints path on stdout; returns 1 if not found.
#######################################
_find_hook_src() {
	local _guard="$1"
	local _sd
	_sd=$(_script_dir)
	local _repo_hook="" _deployed_hook=""
	case "$_guard" in
	privacy)
		_repo_hook="${_sd}/../hooks/privacy-guard-pre-push.sh"
		_deployed_hook="$DEPLOYED_PRIVACY_HOOK"
		;;
	complexity)
		_repo_hook="${_sd}/../hooks/complexity-regression-pre-push.sh"
		_deployed_hook="$DEPLOYED_COMPLEXITY_HOOK"
		;;
	scope)
		_repo_hook="${_sd}/../hooks/scope-guard-pre-push.sh"
		_deployed_hook="$DEPLOYED_SCOPE_HOOK"
		;;
	credential)
		_repo_hook="${_sd}/../hooks/credential-emission-pre-push.sh"
		_deployed_hook="$DEPLOYED_CREDENTIAL_HOOK"
		;;
	dup-todo)
		_repo_hook="${_sd}/../hooks/pre-push-dup-todo-guard.sh"
		_deployed_hook="$DEPLOYED_DUP_TODO_HOOK"
		;;
	brief-filename)
		_repo_hook="${_sd}/../hooks/brief-filename-guard.sh"
		_deployed_hook="$DEPLOYED_BRIEF_FILENAME_HOOK"
		;;
	*)
		print_error "_find_hook_src: unknown guard: $_guard"
		return 1
		;;
	esac
	if [[ -f "$_repo_hook" ]]; then
		printf '%s' "$_repo_hook"
		return 0
	fi
	if [[ -f "$_deployed_hook" ]]; then
		printf '%s' "$_deployed_hook"
		return 0
	fi
	return 1
}

#######################################
# Resolve the common git dir (shared across worktrees).
#######################################
_git_common_dir() {
	git rev-parse --git-common-dir 2>/dev/null || {
		print_error "not a git repository"
		return 1
	}
	return 0
}

#######################################
# Return the canonical pre-push hook file path.
#######################################
_hook_path() {
	local _cdir
	_cdir=$(_git_common_dir) || return 1
	printf '%s/hooks/pre-push' "$_cdir"
	return 0
}

#######################################
# Return the canonical pre-commit hook file path.
#######################################
_commit_hook_path() {
	local _cdir
	_cdir=$(_git_common_dir) || return 1
	printf '%s/hooks/pre-commit' "$_cdir"
	return 0
}

#######################################
# Install (or refresh) the pre-commit dispatcher containing the brief-filename guard.
# Creates .git/hooks/pre-commit managed by aidevops.
# Returns 1 if an existing unmanaged pre-commit hook is found.
#######################################
_install_precommit_brief_filename() {
	local _chook_path
	_chook_path=$(_commit_hook_path) || return 1

	# Refuse to overwrite an unmanaged pre-commit hook.
	if [[ -f "$_chook_path" ]]; then
		if ! grep -q "$HOOK_MARKER_PRECOMMIT_MANAGED" "$_chook_path" 2>/dev/null; then
			print_error "existing pre-commit hook at $_chook_path is NOT managed by aidevops"
			print_error "Refusing to overwrite. To chain manually, add the guard to your hook:"
			# shellcheck disable=SC2016
			print_error '  ${REPO}/.agents/hooks/brief-filename-guard.sh "$@"'
			return 1
		fi
	fi

	local _hook_src
	if ! _hook_src=$(_find_hook_src brief-filename 2>/dev/null); then
		print_warning "brief-filename hook source not found — skipping pre-commit guard"
		return 0
	fi

	local _repo_rel=".agents/hooks/brief-filename-guard.sh"

	mkdir -p "$(dirname "$_chook_path")"

	# shellcheck disable=SC2016
	cat >"$_chook_path" <<COMMIT_HOOK
#!/usr/bin/env bash
# aidevops-pre-commit-guards
# Managed by .agents/scripts/install-pre-push-guards.sh — do not edit.
# Chains installed aidevops pre-commit guards in order.
# Bypass all:  git commit --no-verify
# Bypass each: BRIEF_FILENAME_GUARD_DISABLE=1

set -u

_git_root=\$(git rev-parse --show-toplevel 2>/dev/null || true)
_exit_code=0

# guard:brief-filename
_brief_filename_hook=""
if [[ -n "\$_git_root" && -f "\${_git_root}/${_repo_rel}" ]]; then
  _brief_filename_hook="\${_git_root}/${_repo_rel}"
elif [[ -f "${_hook_src}" ]]; then
  _brief_filename_hook="${_hook_src}"
fi
if [[ -n "\$_brief_filename_hook" ]]; then
  "\$_brief_filename_hook" "\$@" || _exit_code=\$?
else
  printf '[pre-commit][WARN] brief-filename hook not found -- skipping\n' >&2
fi

exit "\$_exit_code"
COMMIT_HOOK

	chmod +x "$_chook_path"
	return 0
}

#######################################
# Uninstall the aidevops-managed pre-commit hook.
# No-ops if not installed or not managed by us.
#######################################
_uninstall_precommit_brief_filename() {
	local _chook_path
	_chook_path=$(_commit_hook_path) || return 1

	if [[ ! -f "$_chook_path" ]]; then
		return 0
	fi
	if ! grep -q "$HOOK_MARKER_PRECOMMIT_MANAGED" "$_chook_path" 2>/dev/null; then
		print_warning "pre-commit hook at $_chook_path is NOT managed by aidevops — leaving it alone"
		return 0
	fi
	rm -f "$_chook_path"
	print_success "removed pre-commit hook (brief-filename guard)"
	return 0
}

#######################################
# True if the hook at the path is managed by us.
# Recognises both the current multi-guard marker and the legacy single-guard
# marker from install-privacy-guard.sh (for seamless migration).
#######################################
_hook_is_managed() {
	local _p="$1"
	# Current marker (install-pre-push-guards.sh dispatcher)
	grep -q "$HOOK_MARKER_MANAGED" "$_p" 2>/dev/null && return 0
	# Legacy marker from old install-privacy-guard.sh single-guard dispatcher
	grep -q "# aidevops-privacy-guard" "$_p" 2>/dev/null && return 0
	return 1
}

#######################################
# Append one guard block to the dispatcher hook.
# Args: _hook_path _guard_name _repo_rel_path _deployed_path
#
# The guard block: resolves the hook file from repo or deployed location,
# replays stdin, and accumulates the exit code.
#######################################
_append_guard_block() {
	local _hook_path="$1"
	local _guard_name="$2"
	local _repo_rel_path="$3"
	local _deployed_path="$4"

	# Unquoted heredoc — ${_guard_name} and ${_repo_rel_path} expand here;
	# \$_git_root and \$_stdin_data etc. are escaped so they become literal
	# $-vars in the generated hook script.
	# shellcheck disable=SC2016
	cat >>"$_hook_path" <<GUARD_BLOCK
# guard:${_guard_name}
_${_guard_name}_hook=""
if [[ -n "\$_git_root" && -f "\${_git_root}/${_repo_rel_path}" ]]; then
  _${_guard_name}_hook="\${_git_root}/${_repo_rel_path}"
elif [[ -f "${_deployed_path}" ]]; then
  _${_guard_name}_hook="${_deployed_path}"
fi
if [[ -n "\$_${_guard_name}_hook" ]]; then
  printf '%s\n' "\$_stdin_data" | "\$_${_guard_name}_hook" "\$@" || _exit_code=\$?
else
  printf '[pre-push][WARN] ${_guard_name} hook not found -- skipping\n' >&2
fi

GUARD_BLOCK
	return 0
}

#######################################
# Write (or rewrite) the dispatcher hook.
# Args: _hook_path _inc_privacy _inc_complexity _inc_scope _inc_credential _inc_dup_todo (0|1 each)
#
# The generated script reads all stdin once, then pipes it to each
# installed guard hook. Each guard receives (remote_name, remote_url)
# as positional args, matching the git pre-push protocol.
#######################################
_write_dispatcher() {
	local _hook_path="$1"
	local _inc_privacy="$2"
	local _inc_complexity="$3"
	local _inc_scope="${4:-0}"
	local _inc_credential="${5:-0}"
	local _inc_dup_todo="${6:-0}"

	mkdir -p "$(dirname "$_hook_path")"

	# Write the fixed header (single-quoted heredoc = no expansion)
	cat >"$_hook_path" <<'HOOK_HEADER'
#!/usr/bin/env bash
# aidevops-pre-push-guards
# Managed by .agents/scripts/install-pre-push-guards.sh — do not edit.
# Chains installed aidevops pre-push guards in order.
# Bypass all:  git push --no-verify
# Bypass each: PRIVACY_GUARD_DISABLE=1, COMPLEXITY_GUARD_DISABLE=1,
#              SCOPE_GUARD_DISABLE=1, CREDENTIAL_GUARD_DISABLE=1,
#              or DUP_TODO_GUARD_DISABLE=1

set -u

_git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
_exit_code=0

# Read all ref lines from stdin once; each guard gets a replay.
_stdin_data=$(cat)

HOOK_HEADER

	# Append each enabled guard block via the shared helper.
	[[ "$_inc_privacy" -eq 1 ]] && _append_guard_block "$_hook_path" \
		"privacy" ".agents/hooks/privacy-guard-pre-push.sh" "$DEPLOYED_PRIVACY_HOOK"
	[[ "$_inc_complexity" -eq 1 ]] && _append_guard_block "$_hook_path" \
		"complexity" ".agents/hooks/complexity-regression-pre-push.sh" "$DEPLOYED_COMPLEXITY_HOOK"
	[[ "$_inc_scope" -eq 1 ]] && _append_guard_block "$_hook_path" \
		"scope" ".agents/hooks/scope-guard-pre-push.sh" "$DEPLOYED_SCOPE_HOOK"
	[[ "$_inc_credential" -eq 1 ]] && _append_guard_block "$_hook_path" \
		"credential" ".agents/hooks/credential-emission-pre-push.sh" "$DEPLOYED_CREDENTIAL_HOOK"
	[[ "$_inc_dup_todo" -eq 1 ]] && _append_guard_block "$_hook_path" \
		"dup-todo" ".agents/hooks/pre-push-dup-todo-guard.sh" "$DEPLOYED_DUP_TODO_HOOK"

	# Single-quoted to write literal $-vars into the generated script (not expand here)
	# shellcheck disable=SC2016
	printf 'exit "$_exit_code"\n' >>"$_hook_path"
	chmod +x "$_hook_path"
	return 0
}

#######################################
# _install_parse_guard_filter — parse --guard CLI argument.
# Prints the guard filter name on stdout; returns 1 on error.
#######################################
_install_parse_guard_filter() {
	local _filter="all"
	while [[ $# -gt 0 ]]; do
		local _opt="$1"
		case "$_opt" in
		--guard)
			[[ $# -ge 2 ]] || { print_error "missing value for --guard"; return 1; }
			local _val="$2"
			_filter="$_val"
			shift 2
			;;
		*) print_error "install: unknown argument: $_opt"; return 1 ;;
		esac
	done
	printf '%s' "$_filter"
	return 0
}

#######################################
# _install_reject_unmanaged_hook — abort if hook exists but isn't managed by us.
# Args: _hook_path
# Returns 1 (and prints guidance) if hook exists and is not aidevops-managed.
#######################################
_install_reject_unmanaged_hook() {
	local _hook_path="$1"
	[[ ! -f "$_hook_path" ]] && return 0
	_hook_is_managed "$_hook_path" && return 0
	print_error "existing pre-push hook at $_hook_path is NOT managed by aidevops"
	print_error "Refusing to overwrite. To chain manually, add each guard to your hook:"
	local _gh
	for _gh in "privacy-guard-pre-push.sh" "complexity-regression-pre-push.sh" "scope-guard-pre-push.sh" "credential-emission-pre-push.sh" "pre-push-dup-todo-guard.sh"; do
		# shellcheck disable=SC2016
		print_error '  ${REPO}/.agents/hooks/'"$_gh"' "$@" < /dev/stdin'
	done
	print_error "(pre-commit: brief-filename-guard.sh is installed separately to .git/hooks/pre-commit)"
	return 1
}

#######################################
# cmd_install — install or refresh guard(s)
#######################################
cmd_install() {
	local _guard_filter
	_guard_filter=$(_install_parse_guard_filter "$@") || return 1

	local _hook_path
	_hook_path=$(_hook_path) || return 1

	_install_reject_unmanaged_hook "$_hook_path" || return 1

	# Determine which guards are currently in the hook
	local _cur_privacy=0 _cur_complexity=0 _cur_scope=0 _cur_credential=0 _cur_dup_todo=0
	if [[ -f "$_hook_path" ]]; then
		grep -q "$HOOK_MARKER_PRIVACY" "$_hook_path" 2>/dev/null && _cur_privacy=1
		grep -q "$HOOK_MARKER_COMPLEXITY" "$_hook_path" 2>/dev/null && _cur_complexity=1
		grep -q "$HOOK_MARKER_SCOPE" "$_hook_path" 2>/dev/null && _cur_scope=1
		grep -q "$HOOK_MARKER_CREDENTIAL" "$_hook_path" 2>/dev/null && _cur_credential=1
		grep -q "$HOOK_MARKER_DUP_TODO" "$_hook_path" 2>/dev/null && _cur_dup_todo=1
	fi

	# Determine which guards to add based on filter
	local _want_privacy=0 _want_complexity=0 _want_scope=0 _want_credential=0 _want_dup_todo=0
	local _want_brief_filename=0
	case "$_guard_filter" in
	all)            _want_privacy=1; _want_complexity=1; _want_scope=1; _want_credential=1; _want_dup_todo=1; _want_brief_filename=1 ;;
	privacy)        _want_privacy=1 ;;
	complexity)     _want_complexity=1 ;;
	scope)          _want_scope=1 ;;
	credential)     _want_credential=1 ;;
	dup-todo)       _want_dup_todo=1 ;;
	brief-filename) _want_brief_filename=1 ;;
	*)
		print_error "unknown guard: $_guard_filter (valid: all, privacy, complexity, scope, credential, dup-todo, brief-filename)"
		return 1
		;;
	esac

	# Merge: keep existing + add requested
	local _inc_privacy=0 _inc_complexity=0 _inc_scope=0 _inc_credential=0 _inc_dup_todo=0
	[[ "$_cur_privacy" -eq 1 || "$_want_privacy" -eq 1 ]] && _inc_privacy=1
	[[ "$_cur_complexity" -eq 1 || "$_want_complexity" -eq 1 ]] && _inc_complexity=1
	[[ "$_cur_scope" -eq 1 || "$_want_scope" -eq 1 ]] && _inc_scope=1
	[[ "$_cur_credential" -eq 1 || "$_want_credential" -eq 1 ]] && _inc_credential=1
	[[ "$_cur_dup_todo" -eq 1 || "$_want_dup_todo" -eq 1 ]] && _inc_dup_todo=1

	# Verify sources exist; warn and omit guards whose source is missing
	local _installed_list=""
	if [[ "$_inc_privacy" -eq 1 ]]; then
		if _find_hook_src privacy >/dev/null 2>&1; then
			_installed_list="${_installed_list}privacy "
		else
			print_warning "privacy hook source not found — omitting privacy guard"
			_inc_privacy=0
		fi
	fi
	if [[ "$_inc_complexity" -eq 1 ]]; then
		if _find_hook_src complexity >/dev/null 2>&1; then
			_installed_list="${_installed_list}complexity "
		else
			print_warning "complexity hook source not found — omitting complexity guard"
			_inc_complexity=0
		fi
	fi
	if [[ "$_inc_scope" -eq 1 ]]; then
		if _find_hook_src scope >/dev/null 2>&1; then
			_installed_list="${_installed_list}scope "
		else
			print_warning "scope hook source not found — omitting scope guard"
			_inc_scope=0
		fi
	fi
	if [[ "$_inc_credential" -eq 1 ]]; then
		if _find_hook_src credential >/dev/null 2>&1; then
			_installed_list="${_installed_list}credential "
		else
			print_warning "credential hook source not found — omitting credential guard"
			_inc_credential=0
		fi
	fi
	if [[ "$_inc_dup_todo" -eq 1 ]]; then
		if _find_hook_src dup-todo >/dev/null 2>&1; then
			_installed_list="${_installed_list}dup-todo "
		else
			print_warning "dup-todo hook source not found — omitting dup-todo guard"
			_inc_dup_todo=0
		fi
	fi

	# brief-filename is a pre-commit guard — handled separately from the pre-push dispatcher.
	if [[ "$_want_brief_filename" -eq 1 ]]; then
		if _find_hook_src brief-filename >/dev/null 2>&1; then
			if _install_precommit_brief_filename; then
				_installed_list="${_installed_list}brief-filename(pre-commit) "
			fi
		else
			print_warning "brief-filename hook source not found — omitting brief-filename guard"
		fi
	fi

	if [[ "$_inc_privacy" -eq 0 && "$_inc_complexity" -eq 0 && "$_inc_scope" -eq 0 && "$_inc_credential" -eq 0 && "$_inc_dup_todo" -eq 0 ]]; then
		# Only brief-filename was requested (or all others were missing): acceptable
		if [[ -n "${_installed_list:-}" ]]; then
			print_success "installed guards: ${_installed_list% }"
		else
			print_warning "no guards to install (sources not found)"
		fi
		return 0
	fi

	_write_dispatcher "$_hook_path" "$_inc_privacy" "$_inc_complexity" "$_inc_scope" "$_inc_credential" "$_inc_dup_todo"
	print_success "installed guards: ${_installed_list% }"
	print_info "pre-push hook: $_hook_path"
	print_info "bypass pre-push: git push --no-verify"
	print_info "bypass pre-commit: git commit --no-verify"
	print_info "bypass individual: PRIVACY_GUARD_DISABLE=1, COMPLEXITY_GUARD_DISABLE=1, SCOPE_GUARD_DISABLE=1, CREDENTIAL_GUARD_DISABLE=1, DUP_TODO_GUARD_DISABLE=1, or BRIEF_FILENAME_GUARD_DISABLE=1"
	return 0
}

#######################################
# cmd_uninstall — remove the managed hook (or a single guard from it)
#######################################
cmd_uninstall() {
	local _guard_filter="all"
	while [[ $# -gt 0 ]]; do
		local _opt="$1"
		case "$_opt" in
		--guard)
			[[ $# -ge 2 ]] || { print_error "missing value for --guard"; return 1; }
			local _val="$2"
			_guard_filter="$_val"
			shift 2
			;;
		*) print_error "uninstall: unknown argument: $_opt"; return 1 ;;
		esac
	done

	local _hook_path
	_hook_path=$(_hook_path) || return 1

	if [[ ! -f "$_hook_path" ]]; then
		print_info "no pre-push hook installed"
		return 0
	fi

	if ! _hook_is_managed "$_hook_path"; then
		print_warning "hook at $_hook_path is NOT managed by aidevops — leaving it alone"
		return 1
	fi

	if [[ "$_guard_filter" == "all" ]]; then
		rm -f "$_hook_path"
		print_success "removed pre-push hook"
		_uninstall_precommit_brief_filename
		return 0
	fi

	# brief-filename is a pre-commit guard — uninstall handled separately.
	if [[ "$_guard_filter" == "brief-filename" ]]; then
		_uninstall_precommit_brief_filename
		return 0
	fi

	# Remove one pre-push guard: read current state, rebuild without the removed guard
	local _cur_privacy=0 _cur_complexity=0 _cur_scope=0 _cur_credential=0 _cur_dup_todo=0
	grep -q "$HOOK_MARKER_PRIVACY" "$_hook_path" 2>/dev/null && _cur_privacy=1
	grep -q "$HOOK_MARKER_COMPLEXITY" "$_hook_path" 2>/dev/null && _cur_complexity=1
	grep -q "$HOOK_MARKER_SCOPE" "$_hook_path" 2>/dev/null && _cur_scope=1
	grep -q "$HOOK_MARKER_CREDENTIAL" "$_hook_path" 2>/dev/null && _cur_credential=1
	grep -q "$HOOK_MARKER_DUP_TODO" "$_hook_path" 2>/dev/null && _cur_dup_todo=1

	case "$_guard_filter" in
	privacy)    _cur_privacy=0 ;;
	complexity) _cur_complexity=0 ;;
	scope)      _cur_scope=0 ;;
	credential) _cur_credential=0 ;;
	dup-todo)   _cur_dup_todo=0 ;;
	*)
		print_error "unknown guard: $_guard_filter (valid: all, privacy, complexity, scope, credential, dup-todo, brief-filename)"
		return 1
		;;
	esac

	if [[ "$_cur_privacy" -eq 0 && "$_cur_complexity" -eq 0 && "$_cur_scope" -eq 0 && "$_cur_credential" -eq 0 && "$_cur_dup_todo" -eq 0 ]]; then
		rm -f "$_hook_path"
		print_success "removed last pre-push guard — hook deleted"
	else
		_write_dispatcher "$_hook_path" "$_cur_privacy" "$_cur_complexity" "$_cur_scope" "$_cur_credential" "$_cur_dup_todo"
		print_success "removed $_guard_filter guard from pre-push hook"
	fi
	return 0
}

#######################################
# cmd_status — report hook state
#######################################
cmd_status() {
	local _hook_path
	_hook_path=$(_hook_path) || return 1

	if [[ ! -f "$_hook_path" ]]; then
		printf 'pre-push hook: NOT INSTALLED\n'
		return 0
	fi

	if ! _hook_is_managed "$_hook_path"; then
		printf 'pre-push hook: installed (unknown manager — not managed by aidevops)\n'
		printf '  path: %s\n' "$_hook_path"
		return 0
	fi

	printf 'pre-push hook: installed (aidevops managed)\n'
	printf '  path: %s\n' "$_hook_path"

	local _has_privacy=0 _has_complexity=0 _has_scope=0 _has_credential=0 _has_dup_todo=0
	grep -q "$HOOK_MARKER_PRIVACY" "$_hook_path" 2>/dev/null && _has_privacy=1
	grep -q "$HOOK_MARKER_COMPLEXITY" "$_hook_path" 2>/dev/null && _has_complexity=1
	grep -q "$HOOK_MARKER_SCOPE" "$_hook_path" 2>/dev/null && _has_scope=1
	grep -q "$HOOK_MARKER_CREDENTIAL" "$_hook_path" 2>/dev/null && _has_credential=1
	grep -q "$HOOK_MARKER_DUP_TODO" "$_hook_path" 2>/dev/null && _has_dup_todo=1

	_status_report_guard "privacy"    "$_has_privacy"
	_status_report_guard "complexity" "$_has_complexity"
	_status_report_guard "scope"      "$_has_scope"
	_status_report_guard "credential" "$_has_credential"
	_status_report_guard "dup-todo"   "$_has_dup_todo"

	# Pre-commit guards (separate hook file)
	local _chook_path
	_chook_path=$(_commit_hook_path) || return 1
	local _has_brief_filename=0
	if [[ -f "$_chook_path" ]]; then
		grep -q "$HOOK_MARKER_BRIEF_FILENAME" "$_chook_path" 2>/dev/null && _has_brief_filename=1
	fi
	printf 'pre-commit hook: %s\n' "$(
		if [[ -f "$_chook_path" ]] && grep -q "$HOOK_MARKER_PRECOMMIT_MANAGED" "$_chook_path" 2>/dev/null; then
			printf 'installed (aidevops managed)\n  path: %s' "$_chook_path"
		elif [[ -f "$_chook_path" ]]; then
			printf 'installed (unknown manager — not managed by aidevops)\n  path: %s' "$_chook_path"
		else
			printf 'NOT INSTALLED'
		fi
	)"
	_status_report_guard "brief-filename" "$_has_brief_filename"
	return 0
}

#######################################
# _status_report_guard — print one guard's status line.
# Args: guard_name has_flag(0|1)
#######################################
_status_report_guard() {
	local _name="$1"
	local _has="$2"
	if [[ "$_has" -eq 1 ]]; then
		local _src=""
		_src=$(_find_hook_src "$_name" 2>/dev/null || true)
		if [[ -n "$_src" ]]; then
			printf '  guard %-10s ENABLED  (%s)\n' "$_name:" "$_src"
		else
			printf '  guard %-10s ENABLED  (source not found — will fail-open)\n' "$_name:"
		fi
	else
		printf '  guard %-10s not installed\n' "$_name:"
	fi
	return 0
}

#######################################
# main
#######################################
main() {
	local _cmd="${1:-install}"
	shift || true
	case "$_cmd" in
	install)   cmd_install "$@" ;;
	uninstall) cmd_uninstall "$@" ;;
	status)    cmd_status "$@" ;;
	help | --help | -h)
		sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
		;;
	*)
		print_error "unknown command: $_cmd"
		return 1
		;;
	esac
	return 0
}

main "$@"
