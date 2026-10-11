#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# install-pre-push-guards.sh — Install aidevops git pre-push/pre-commit hooks (t2198, t2446, t2458, t2745, t3020, t3224).
#
# Manages seven guards in the current repository:
#
# Pre-push guards (installed to .git/hooks/pre-push):
#   - privacy-guard        blocks pushes leaking private repo slugs
#   - complexity-guard     blocks pushes introducing complexity regressions
#   - scope-guard          blocks pushes touching files outside the brief's Files Scope
#   - credential-guard     blocks pushes emitting unsanitised remote URLs (t2458)
#   - dup-todo-guard       blocks pushes where TODO.md has duplicate task-ID checkbox lines (t2745)
#   - repo-verify-guard    runs the target repo's format/lint/typecheck and (optionally) auto-fixes (t3224)
#
# Pre-commit guards (installed to .git/hooks/pre-commit):
#   - brief-filename-guard blocks commits adding todo/tasks/tNNN-brief.md with unclaimed t-IDs (t3020)
#
# Usage:
#   install-pre-push-guards.sh install [--guard <name>]
#         Install (or refresh) guard(s).
#         --guard: privacy|complexity|scope|credential|dup-todo|repo-verify|brief-filename|all (default: all)
#         Also accepted (used by install-hooks-helper.sh so both managers coexist,
#         GH#34411): gh-wrapper|quality (pre-push) and pre-commit-quality.
#         A trailing Beads section is preserved and runs after the guards.
#
#   install-pre-push-guards.sh uninstall [--guard <name>]
#         Remove guard entry/entries.
#         --guard: privacy|complexity|scope|credential|dup-todo|repo-verify|brief-filename|all (default: all)
#
#   install-pre-push-guards.sh status
#         Report which guards are present and their hook source locations.
#
# Hooks are written to the effective hooks directory (`git rev-parse
# --git-path hooks`): core.hooksPath when set (e.g. Beads' .beads/hooks),
# otherwise the common-dir hooks directory shared by all worktrees.
#
# Existing hooks NOT managed by aidevops are refused and left untouched.
#
# Runtime bypass per-guard:
#   PRIVACY_GUARD_DISABLE=1          skip privacy check for this push
#   COMPLEXITY_GUARD_DISABLE=1       skip complexity check for this push
#   SCOPE_GUARD_DISABLE=1            skip scope check for this push
#   CREDENTIAL_GUARD_DISABLE=1       skip credential check for this push
#   DUP_TODO_GUARD_DISABLE=1         skip duplicate TODO check for this push
#   AIDEVOPS_PREPUSH_REPO_VERIFY=0   skip repo-verify check for this push (also: AIDEVOPS_PREPUSH_AUTOFIX=0|1)
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

# shellcheck source=git-hooks-path-lib.sh disable=SC1091
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-hooks-path-lib.sh"

# Marker strings embedded in the managed hook file — used for detect/update.
HOOK_MARKER_MANAGED="# aidevops-pre-push-guards"
HOOK_MARKER_PRECOMMIT_MANAGED="# aidevops-pre-commit-guards"
HOOK_MARKER_PRIVACY="# guard:privacy"
HOOK_MARKER_COMPLEXITY="# guard:complexity"
HOOK_MARKER_SCOPE="# guard:scope"
HOOK_MARKER_CREDENTIAL="# guard:credential"
HOOK_MARKER_DUP_TODO="# guard:dup-todo"
HOOK_MARKER_REPO_VERIFY="# guard:repo-verify"
HOOK_MARKER_BRIEF_FILENAME="# guard:brief-filename"
# Guards owned by install-hooks-helper.sh that share these dispatchers (GH#34411).
# Their markers are recognised, preserved on rewrite, and run with stdin replay.
HOOK_MARKER_GH_WRAPPER="# aidevops-gh-wrapper-guard"
HOOK_MARKER_QUALITY="# aidevops-pre-push-quality-hook"
HOOK_MARKER_PRECOMMIT_QUALITY="# aidevops-pre-commit-hook"
HOOK_RE_PRECOMMIT_QUALITY="^${HOOK_MARKER_PRECOMMIT_QUALITY}\$"

DEPLOYED_PRIVACY_HOOK="$HOME/.aidevops/agents/hooks/privacy-guard-pre-push.sh"
DEPLOYED_COMPLEXITY_HOOK="$HOME/.aidevops/agents/hooks/complexity-regression-pre-push.sh"
DEPLOYED_SCOPE_HOOK="$HOME/.aidevops/agents/hooks/scope-guard-pre-push.sh"
DEPLOYED_CREDENTIAL_HOOK="$HOME/.aidevops/agents/hooks/credential-emission-pre-push.sh"
DEPLOYED_DUP_TODO_HOOK="$HOME/.aidevops/agents/hooks/pre-push-dup-todo-guard.sh"
DEPLOYED_REPO_VERIFY_HOOK="$HOME/.aidevops/agents/hooks/repo-verify-pre-push.sh"
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
	repo-verify)
		_repo_hook="${_sd}/../hooks/repo-verify-pre-push.sh"
		_deployed_hook="$DEPLOYED_REPO_VERIFY_HOOK"
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
# Resolve the effective hooks directory Git will execute from.
# Honours core.hooksPath (e.g. Beads sets .beads/hooks); without it this is
# the common-dir hooks directory shared by all worktrees. Writing to
# <common-dir>/hooks while core.hooksPath points elsewhere installs guards
# that never run. Mirrors _git_hooks_dir in install-canonical-guard.sh.
#######################################
_git_hooks_dir() {
	local _hdir=""
	_hdir=$(aidevops_git_hooks_dir) || {
		print_error "not a git repository"
		return 1
	}
	printf '%s' "$_hdir"
	return 0
}

#######################################
# Return the effective pre-push hook file path.
#######################################
_hook_path() {
	local _hdir
	_hdir=$(_git_hooks_dir) || return 1
	printf '%s/pre-push' "$_hdir"
	return 0
}

#######################################
# Return the effective pre-commit hook file path.
#######################################
_commit_hook_path() {
	local _hdir
	_hdir=$(_git_hooks_dir) || return 1
	printf '%s/pre-commit' "$_hdir"
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
	local _beads_section="" _has_qc=0
	[[ "${AIDEVOPS_PRECOMMIT_ADD_QUALITY:-0}" == "1" ]] && _has_qc=1
	if [[ -f "$_chook_path" ]]; then
		if ! grep -q "$HOOK_MARKER_PRECOMMIT_MANAGED" "$_chook_path" 2>/dev/null &&
			grep -q "$HOOK_RE_PRECOMMIT_QUALITY" "$_chook_path" 2>/dev/null; then
			# Dispatcher owned by install-hooks-helper.sh: chain our guard onto it
			# rather than refusing (GH#34411).
			_chain_brief_filename_onto_quality_hook "$_chook_path"
			return $?
		fi
		if grep -q "$HOOK_MARKER_PRECOMMIT_MANAGED" "$_chook_path" 2>/dev/null; then
			# Rewriting our own dispatcher: keep the hooks-helper quality section
			# and any complete trailing Beads section.
			if ! _beads_section=$(aidevops_beads_section "$_chook_path"); then
				print_error "ambiguous Beads integration; leaving existing pre-commit hook unchanged"
				return 1
			fi
			grep -q "$HOOK_RE_PRECOMMIT_QUALITY" "$_chook_path" 2>/dev/null && _has_qc=1
		else
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

COMMIT_HOOK

	if [[ "$_has_qc" -eq 1 ]]; then
		_precommit_quality_block >>"$_chook_path"
	fi
	# The Beads section stays trailing and decides the final status (see
	# _write_dispatcher); without it the dispatcher exits with the guard status.
	# shellcheck disable=SC2016
	if [[ -n "$_beads_section" ]]; then
		{
			printf '[[ "$_exit_code" -eq 0 ]] || exit "$_exit_code"\n\n'
			printf '%s\n' "$_beads_section"
		} >>"$_chook_path"
	else
		printf 'exit "$_exit_code"\n' >>"$_chook_path"
	fi

	chmod +x "$_chook_path"
	return 0
}

#######################################
# Quality-validation section owned by install-hooks-helper.sh, expressed as a
# guard block of the guards dispatcher (accumulates into _exit_code).
#######################################
_precommit_quality_block() {
	cat <<QC_BLOCK
${HOOK_MARKER_PRECOMMIT_QUALITY}
_pch_hook=""
if [[ -f "\${_git_root}/.agents/scripts/pre-commit-hook.sh" ]]; then
  _pch_hook="\${_git_root}/.agents/scripts/pre-commit-hook.sh"
elif [[ -f "\$HOME/.aidevops/agents/scripts/pre-commit-hook.sh" ]]; then
  _pch_hook="\$HOME/.aidevops/agents/scripts/pre-commit-hook.sh"
fi
if [[ -n "\$_pch_hook" ]]; then
  HOOK_MODE=pre-commit "\$_pch_hook" "\$@" || _exit_code=\$?
else
  printf '[pre-commit-hook][WARN] hook not found -- allowing commit\n' >&2
fi

QC_BLOCK
	return 0
}

#######################################
# Append the brief-filename guard to a dispatcher owned by install-hooks-helper.sh
# (no stdin use; the hooks-helper dispatcher has no final exit). Idempotent.
#######################################
_chain_brief_filename_onto_quality_hook() {
	local _chook_path="$1"
	if grep -q "$HOOK_MARKER_BRIEF_FILENAME" "$_chook_path" 2>/dev/null; then
		print_info "brief-filename guard already chained into $_chook_path"
		return 0
	fi
	local _hook_src
	if ! _hook_src=$(_find_hook_src brief-filename 2>/dev/null); then
		print_warning "brief-filename hook source not found — skipping pre-commit guard"
		return 0
	fi
	cat >>"$_chook_path" <<CHAIN_BLOCK

${HOOK_MARKER_BRIEF_FILENAME}
_bfg_hook=""
_bfg_root=\$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -n "\$_bfg_root" && -f "\${_bfg_root}/.agents/hooks/brief-filename-guard.sh" ]]; then
  _bfg_hook="\${_bfg_root}/.agents/hooks/brief-filename-guard.sh"
elif [[ -f "${_hook_src}" ]]; then
  _bfg_hook="${_hook_src}"
fi
if [[ -n "\$_bfg_hook" ]]; then
  "\$_bfg_hook" "\$@" || exit \$?
fi
CHAIN_BLOCK
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
	if grep -q "$HOOK_RE_PRECOMMIT_QUALITY" "$_chook_path" 2>/dev/null ||
		grep -q 'BEADS INTEGRATION' "$_chook_path" 2>/dev/null; then
		print_warning "pre-commit hook at $_chook_path also carries quality/Beads sections — leaving it in place"
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
	# Dispatchers written by install-hooks-helper.sh are adopted so both managers
	# coexist instead of refusing each other (GH#34411).
	grep -q "$HOOK_MARKER_GH_WRAPPER" "$_p" 2>/dev/null && return 0
	grep -q "$HOOK_MARKER_QUALITY" "$_p" 2>/dev/null && return 0
	return 1
}

#######################################
# True if the hook carries sections we must not delete: guards owned by
# install-hooks-helper.sh, or a Beads integration section.
#######################################
_hook_has_foreign_sections() {
	local _p="$1"
	grep -q "$HOOK_MARKER_GH_WRAPPER" "$_p" 2>/dev/null && return 0
	grep -q "$HOOK_MARKER_QUALITY" "$_p" 2>/dev/null && return 0
	grep -q 'BEADS INTEGRATION' "$_p" 2>/dev/null && return 0
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
	local _env_prefix="${5:-}"
	local _extra_marker="${6:-#}"
	local _guard_var="${_guard_name//-/_}"

	# Unquoted heredoc — ${_guard_name} and ${_repo_rel_path} expand here;
	# \$_git_root and \$_stdin_data etc. are escaped so they become literal
	# $-vars in the generated hook script.
	# shellcheck disable=SC2016
	cat >>"$_hook_path" <<GUARD_BLOCK
# guard:${_guard_name}
${_extra_marker}
_${_guard_var}_hook=""
if [[ -n "\$_git_root" && -f "\${_git_root}/${_repo_rel_path}" ]]; then
  _${_guard_var}_hook="\${_git_root}/${_repo_rel_path}"
elif [[ -f "${_deployed_path}" ]]; then
  _${_guard_var}_hook="${_deployed_path}"
fi
if [[ -n "\$_${_guard_var}_hook" ]]; then
  printf '%s\n' "\$_stdin_data" | ${_env_prefix:+$_env_prefix }"\$_${_guard_var}_hook" "\$@" || _exit_code=\$?
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
	local _inc_repo_verify="${7:-0}"

	mkdir -p "$(dirname "$_hook_path")"

	# Capture state from the existing hook BEFORE truncating it: a complete
	# trailing Beads section (fail closed if ambiguous) and the guards owned by
	# install-hooks-helper.sh (GH#34411), plus any requested via CHAIN_ADD.
	local _beads_section="" _inc_ghw=0 _inc_quality=0
	if [[ -f "$_hook_path" ]]; then
		if ! _beads_section=$(aidevops_beads_section "$_hook_path"); then
			print_error "ambiguous Beads integration; leaving existing hook unchanged"
			return 1
		fi
		grep -q "$HOOK_MARKER_GH_WRAPPER" "$_hook_path" 2>/dev/null && _inc_ghw=1
		grep -q "$HOOK_MARKER_QUALITY" "$_hook_path" 2>/dev/null && _inc_quality=1
	fi
	case " ${AIDEVOPS_PREPUSH_CHAIN_ADD:-} " in *" gh-wrapper "*) _inc_ghw=1 ;; esac
	case " ${AIDEVOPS_PREPUSH_CHAIN_ADD:-} " in *" quality "*) _inc_quality=1 ;; esac

	# Write the fixed header (single-quoted heredoc = no expansion)
	cat >"$_hook_path" <<'HOOK_HEADER'
#!/usr/bin/env bash
# aidevops-pre-push-guards
# Managed by .agents/scripts/install-pre-push-guards.sh — do not edit.
# Chains installed aidevops pre-push guards in order.
# Bypass all:  git push --no-verify
# Bypass each: PRIVACY_GUARD_DISABLE=1, COMPLEXITY_GUARD_DISABLE=1,
#              SCOPE_GUARD_DISABLE=1, CREDENTIAL_GUARD_DISABLE=1,
#              DUP_TODO_GUARD_DISABLE=1, or AIDEVOPS_PREPUSH_REPO_VERIFY=0

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
	[[ "$_inc_repo_verify" -eq 1 ]] && _append_guard_block "$_hook_path" \
		"repo-verify" ".agents/hooks/repo-verify-pre-push.sh" "$DEPLOYED_REPO_VERIFY_HOOK"
	[[ "$_inc_ghw" -eq 1 ]] && _append_guard_block "$_hook_path" \
		"gh-wrapper" ".agents/hooks/gh-wrapper-guard-pre-push.sh" \
		"$HOME/.aidevops/agents/hooks/gh-wrapper-guard-pre-push.sh" "" "$HOOK_MARKER_GH_WRAPPER"
	[[ "$_inc_quality" -eq 1 ]] && _append_guard_block "$_hook_path" \
		"quality" ".agents/scripts/pre-commit-hook.sh" \
		"$HOME/.aidevops/agents/scripts/pre-commit-hook.sh" "HOOK_MODE=pre-push" "$HOOK_MARKER_QUALITY"

	# A preserved Beads section stays the TRAILING section (so a later refresh can
	# find it again) and decides the final status: it runs after the guards, with
	# stdin replayed, and only when every guard passed.
	# Single-quoted to write literal $-vars into the generated script (not expand here)
	# shellcheck disable=SC2016
	if [[ -n "$_beads_section" ]]; then
		{
			printf '[[ "$_exit_code" -eq 0 ]] || exit "$_exit_code"\n'
			printf 'exec <<<"$_stdin_data"\n\n'
			printf '%s\n' "$_beads_section"
		} >>"$_hook_path"
	else
		printf 'exit "$_exit_code"\n' >>"$_hook_path"
	fi
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
	for _gh in "privacy-guard-pre-push.sh" "complexity-regression-pre-push.sh" "scope-guard-pre-push.sh" "credential-emission-pre-push.sh" "pre-push-dup-todo-guard.sh" "repo-verify-pre-push.sh"; do
		# shellcheck disable=SC2016
		print_error '  ${REPO}/.agents/hooks/'"$_gh"' "$@" < /dev/stdin'
	done
	print_error "(pre-commit: brief-filename-guard.sh is installed separately to .git/hooks/pre-commit)"
	return 1
}

#######################################
# _install_resolve_guard — verify a guard's source exists; print the kept inc flag.
# Args: _guard_name _inc_flag
# Stdout: '0' (drop) or '1' (keep). Stderr: print_warning if requested but missing.
#######################################
_install_resolve_guard() {
	local _name="$1"
	local _flag="$2"
	if [[ "$_flag" -ne 1 ]]; then
		printf '0'
		return 0
	fi
	if _find_hook_src "$_name" >/dev/null 2>&1; then
		printf '1'
		return 0
	fi
	print_warning "$_name hook source not found — omitting $_name guard" >&2
	printf '0'
	return 0
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
	local _cur_privacy=0 _cur_complexity=0 _cur_scope=0 _cur_credential=0 _cur_dup_todo=0 _cur_repo_verify=0
	if [[ -f "$_hook_path" ]]; then
		grep -q "$HOOK_MARKER_PRIVACY" "$_hook_path" 2>/dev/null && _cur_privacy=1
		grep -q "$HOOK_MARKER_COMPLEXITY" "$_hook_path" 2>/dev/null && _cur_complexity=1
		grep -q "$HOOK_MARKER_SCOPE" "$_hook_path" 2>/dev/null && _cur_scope=1
		grep -q "$HOOK_MARKER_CREDENTIAL" "$_hook_path" 2>/dev/null && _cur_credential=1
		grep -q "$HOOK_MARKER_DUP_TODO" "$_hook_path" 2>/dev/null && _cur_dup_todo=1
		grep -q "$HOOK_MARKER_REPO_VERIFY" "$_hook_path" 2>/dev/null && _cur_repo_verify=1
	fi

	# Determine which guards to add based on filter
	local _want_privacy=0 _want_complexity=0 _want_scope=0 _want_credential=0 _want_dup_todo=0 _want_repo_verify=0
	local _want_brief_filename=0 _chain_add=""
	case "$_guard_filter" in
	all)            _want_privacy=1; _want_complexity=1; _want_scope=1; _want_credential=1; _want_dup_todo=1; _want_repo_verify=1; _want_brief_filename=1 ;;
	privacy)        _want_privacy=1 ;;
	complexity)     _want_complexity=1 ;;
	scope)          _want_scope=1 ;;
	credential)     _want_credential=1 ;;
	dup-todo)       _want_dup_todo=1 ;;
	repo-verify)    _want_repo_verify=1 ;;
	brief-filename) _want_brief_filename=1 ;;
	gh-wrapper|quality) _chain_add="$_guard_filter" ;;
	pre-commit-quality)
		# Pre-commit section owned by install-hooks-helper.sh, kept inside this dispatcher.
		AIDEVOPS_PRECOMMIT_ADD_QUALITY=1 _install_precommit_brief_filename || return 1
		print_success "installed guards: pre-commit-quality(pre-commit)"
		return 0
		;;
	*)
		print_error "unknown guard: $_guard_filter (valid: all, privacy, complexity, scope, credential, dup-todo, repo-verify, brief-filename, gh-wrapper, quality, pre-commit-quality)"
		return 1
		;;
	esac

	# Merge: keep existing + add requested
	local _inc_privacy=0 _inc_complexity=0 _inc_scope=0 _inc_credential=0 _inc_dup_todo=0 _inc_repo_verify=0
	[[ "$_cur_privacy" -eq 1 || "$_want_privacy" -eq 1 ]] && _inc_privacy=1
	[[ "$_cur_complexity" -eq 1 || "$_want_complexity" -eq 1 ]] && _inc_complexity=1
	[[ "$_cur_scope" -eq 1 || "$_want_scope" -eq 1 ]] && _inc_scope=1
	[[ "$_cur_credential" -eq 1 || "$_want_credential" -eq 1 ]] && _inc_credential=1
	[[ "$_cur_dup_todo" -eq 1 || "$_want_dup_todo" -eq 1 ]] && _inc_dup_todo=1
	[[ "$_cur_repo_verify" -eq 1 || "$_want_repo_verify" -eq 1 ]] && _inc_repo_verify=1

	# Verify sources exist; warn and omit guards whose source is missing.
	local _installed_list=""
	_inc_privacy=$(_install_resolve_guard privacy "$_inc_privacy")
	[[ "$_inc_privacy" -eq 1 ]] && _installed_list="${_installed_list}privacy "
	_inc_complexity=$(_install_resolve_guard complexity "$_inc_complexity")
	[[ "$_inc_complexity" -eq 1 ]] && _installed_list="${_installed_list}complexity "
	_inc_scope=$(_install_resolve_guard scope "$_inc_scope")
	[[ "$_inc_scope" -eq 1 ]] && _installed_list="${_installed_list}scope "
	_inc_credential=$(_install_resolve_guard credential "$_inc_credential")
	[[ "$_inc_credential" -eq 1 ]] && _installed_list="${_installed_list}credential "
	_inc_dup_todo=$(_install_resolve_guard dup-todo "$_inc_dup_todo")
	[[ "$_inc_dup_todo" -eq 1 ]] && _installed_list="${_installed_list}dup-todo "
	_inc_repo_verify=$(_install_resolve_guard repo-verify "$_inc_repo_verify")
	[[ "$_inc_repo_verify" -eq 1 ]] && _installed_list="${_installed_list}repo-verify "

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

	if [[ -n "$_chain_add" ]]; then
		_installed_list="${_installed_list}${_chain_add} "
	elif [[ "$_inc_privacy" -eq 0 && "$_inc_complexity" -eq 0 && "$_inc_scope" -eq 0 && "$_inc_credential" -eq 0 && "$_inc_dup_todo" -eq 0 && "$_inc_repo_verify" -eq 0 ]]; then
		# Only brief-filename was requested (or all others were missing): acceptable
		if [[ -n "${_installed_list:-}" ]]; then
			print_success "installed guards: ${_installed_list% }"
		else
			print_warning "no guards to install (sources not found)"
		fi
		return 0
	fi

	AIDEVOPS_PREPUSH_CHAIN_ADD="$_chain_add" _write_dispatcher "$_hook_path" "$_inc_privacy" "$_inc_complexity" "$_inc_scope" "$_inc_credential" "$_inc_dup_todo" "$_inc_repo_verify" || return 1
	print_success "installed guards: ${_installed_list% }"
	print_info "pre-push hook: $_hook_path"
	print_info "bypass pre-push: git push --no-verify"
	print_info "bypass pre-commit: git commit --no-verify"
	print_info "bypass individual: PRIVACY_GUARD_DISABLE=1, COMPLEXITY_GUARD_DISABLE=1, SCOPE_GUARD_DISABLE=1, CREDENTIAL_GUARD_DISABLE=1, DUP_TODO_GUARD_DISABLE=1, AIDEVOPS_PREPUSH_REPO_VERIFY=0, or BRIEF_FILENAME_GUARD_DISABLE=1"
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
		if _hook_has_foreign_sections "$_hook_path"; then
			_write_dispatcher "$_hook_path" 0 0 0 0 0 0 || return 1
			print_success "removed pre-push guards (kept hooks-helper guards / Beads section)"
		else
			rm -f "$_hook_path"
			print_success "removed pre-push hook"
		fi
		_uninstall_precommit_brief_filename
		return 0
	fi

	# brief-filename is a pre-commit guard — uninstall handled separately.
	if [[ "$_guard_filter" == "brief-filename" ]]; then
		_uninstall_precommit_brief_filename
		return 0
	fi

	# Remove one pre-push guard: read current state, rebuild without the removed guard
	local _cur_privacy=0 _cur_complexity=0 _cur_scope=0 _cur_credential=0 _cur_dup_todo=0 _cur_repo_verify=0
	grep -q "$HOOK_MARKER_PRIVACY" "$_hook_path" 2>/dev/null && _cur_privacy=1
	grep -q "$HOOK_MARKER_COMPLEXITY" "$_hook_path" 2>/dev/null && _cur_complexity=1
	grep -q "$HOOK_MARKER_SCOPE" "$_hook_path" 2>/dev/null && _cur_scope=1
	grep -q "$HOOK_MARKER_CREDENTIAL" "$_hook_path" 2>/dev/null && _cur_credential=1
	grep -q "$HOOK_MARKER_DUP_TODO" "$_hook_path" 2>/dev/null && _cur_dup_todo=1
	grep -q "$HOOK_MARKER_REPO_VERIFY" "$_hook_path" 2>/dev/null && _cur_repo_verify=1

	case "$_guard_filter" in
	privacy)     _cur_privacy=0 ;;
	complexity)  _cur_complexity=0 ;;
	scope)       _cur_scope=0 ;;
	credential)  _cur_credential=0 ;;
	dup-todo)    _cur_dup_todo=0 ;;
	repo-verify) _cur_repo_verify=0 ;;
	*)
		print_error "unknown guard: $_guard_filter (valid: all, privacy, complexity, scope, credential, dup-todo, repo-verify, brief-filename)"
		return 1
		;;
	esac

	if [[ "$_cur_privacy" -eq 0 && "$_cur_complexity" -eq 0 && "$_cur_scope" -eq 0 && "$_cur_credential" -eq 0 && "$_cur_dup_todo" -eq 0 && "$_cur_repo_verify" -eq 0 ]]; then
		if _hook_has_foreign_sections "$_hook_path"; then
			_write_dispatcher "$_hook_path" 0 0 0 0 0 0 || return 1
			print_success "removed last pre-push guard (kept hooks-helper guards / Beads section)"
		else
			rm -f "$_hook_path"
			print_success "removed last pre-push guard — hook deleted"
		fi
	else
		_write_dispatcher "$_hook_path" "$_cur_privacy" "$_cur_complexity" "$_cur_scope" "$_cur_credential" "$_cur_dup_todo" "$_cur_repo_verify" || return 1
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

	local _has_privacy=0 _has_complexity=0 _has_scope=0 _has_credential=0 _has_dup_todo=0 _has_repo_verify=0
	grep -q "$HOOK_MARKER_PRIVACY" "$_hook_path" 2>/dev/null && _has_privacy=1
	grep -q "$HOOK_MARKER_COMPLEXITY" "$_hook_path" 2>/dev/null && _has_complexity=1
	grep -q "$HOOK_MARKER_SCOPE" "$_hook_path" 2>/dev/null && _has_scope=1
	grep -q "$HOOK_MARKER_CREDENTIAL" "$_hook_path" 2>/dev/null && _has_credential=1
	grep -q "$HOOK_MARKER_DUP_TODO" "$_hook_path" 2>/dev/null && _has_dup_todo=1
	grep -q "$HOOK_MARKER_REPO_VERIFY" "$_hook_path" 2>/dev/null && _has_repo_verify=1

	_status_report_guard "privacy"     "$_has_privacy"
	_status_report_guard "complexity"  "$_has_complexity"
	_status_report_guard "scope"       "$_has_scope"
	_status_report_guard "credential"  "$_has_credential"
	_status_report_guard "dup-todo"    "$_has_dup_todo"
	_status_report_guard "repo-verify" "$_has_repo_verify"
	local _has_ghw=0 _has_quality=0
	grep -q "$HOOK_MARKER_GH_WRAPPER" "$_hook_path" 2>/dev/null && _has_ghw=1
	grep -q "$HOOK_MARKER_QUALITY" "$_hook_path" 2>/dev/null && _has_quality=1
	_status_report_guard "gh-wrapper"  "$_has_ghw"
	_status_report_guard "quality"     "$_has_quality"

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
