#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# repo-verify-pre-push.sh — git pre-push hook (t3224).
#
# Runs the target repo's declared format/lint/typecheck commands BEFORE the
# push reaches CI. Closes the gap that lets workers ship PRs which fail
# Format/Lint on the next CI cycle and then sit in a CI-feedback loop.
#
# Discovery cascade (first match wins):
#   1. <repo_root>/.aidevops.json `.verify` block
#      { "format": "...", "format_fix": "...", "lint": "...",
#        "lint_fix": "...", "typecheck": "...", "enabled": true }
#   2. <repo_root>/package.json `.scripts.{format,lint,typecheck}`
#      (auto-derives `format_fix`/`lint_fix` by appending --write/--fix when
#      a sibling `format:fix` / `lint:fix` script is not declared)
#   3. .agents/configs/repo-verify-defaults.conf — toolchain auto-detection
#      by sentinel file presence (pnpm-lock.yaml, Cargo.toml, etc.)
#   4. No match: skip silently (exit 0). Repo is not verify-eligible.
#
# Auto-fix policy (FORMAT_FAILURE / LINT_FAILURE only — typecheck never auto-fixes):
#   - AIDEVOPS_PREPUSH_AUTOFIX=1: run `*_fix` on failure; if files changed,
#     `git add -A && git commit --amend --no-edit`; re-run check.
#   - AIDEVOPS_PREPUSH_AUTOFIX=0: emit mentoring failure with exact suggested
#     fix command; exit 1.
#   - Default: 1 in headless contexts (FULL_LOOP_HEADLESS / AIDEVOPS_HEADLESS /
#     OPENCODE_HEADLESS / GITHUB_ACTIONS), 0 in interactive sessions.
#
# Skip conditions (exit 0 fast):
#   - AIDEVOPS_PREPUSH_REPO_VERIFY=0
#   - GITHUB_ACTIONS=true (CI already runs these)
#   - Working tree dirty (warn — uncommitted changes would corrupt the result)
#   - No verify commands resolved
#   - Required tools missing (jq for config parsing)
#
# Exit codes:
#   0 = allow push (verify clean OR skipped OR auto-fixed and re-verified)
#   1 = block push (verify failed AND auto-fix unavailable/disabled/exhausted)
#
# Bypass for one push: AIDEVOPS_PREPUSH_REPO_VERIFY=0 git push ...
#                  or: git push --no-verify

set -u

GUARD_NAME='repo-verify'

# ----- bypass checks ------------------------------------------------------

if [[ "${AIDEVOPS_PREPUSH_REPO_VERIFY:-1}" == "0" ]]; then
	printf '[%s][INFO] AIDEVOPS_PREPUSH_REPO_VERIFY=0 — bypassing\n' "$GUARD_NAME" >&2
	exit 0
fi

if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
	# CI runs these checks itself — running again here is wasted cycles
	exit 0
fi

# ----- helpers ------------------------------------------------------------

_log() {
	local _level="$1"
	local _msg="$2"
	printf '[%s][%s] %s\n' "$GUARD_NAME" "$_level" "$_msg" >&2
}
_dbg() {
	local _msg="$1"
	if [[ "${AIDEVOPS_PREPUSH_REPO_VERIFY_DEBUG:-0}" == "1" ]]; then
		printf '[%s][DBG] %s\n' "$GUARD_NAME" "$_msg" >&2
	fi
}

# Resolve the hook's directory through symlinks so config defaults can be
# located regardless of whether installed as a symlink or a copy.
_resolve_self() {
	local src="${BASH_SOURCE[0]}"
	while [[ -L "$src" ]]; do
		local dir
		dir=$(cd -P "$(dirname "$src")" && pwd)
		src=$(readlink "$src")
		[[ "$src" != /* ]] && src="$dir/$src"
	done
	cd -P "$(dirname "$src")" && pwd
}

HOOK_DIR=$(_resolve_self)
DEFAULTS_REPO="${HOOK_DIR}/../configs/repo-verify-defaults.conf"
DEFAULTS_DEPLOYED="${HOME}/.aidevops/agents/configs/repo-verify-defaults.conf"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "$REPO_ROOT" ]]; then
	_log INFO "not in a git repo — skipping"
	exit 0
fi

# Auto-fix default: ON in headless, OFF interactive. AIDEVOPS_PREPUSH_AUTOFIX
# (when set) wins over the heuristic.
_autofix_default() {
	if [[ -n "${FULL_LOOP_HEADLESS:-}${AIDEVOPS_HEADLESS:-}${OPENCODE_HEADLESS:-}${GITHUB_ACTIONS:-}" ]]; then
		printf '1\n'
	else
		printf '0\n'
	fi
}
AUTOFIX="${AIDEVOPS_PREPUSH_AUTOFIX:-$(_autofix_default)}"

# ----- discovery ----------------------------------------------------------

# Globals populated by _load_verify_*: declared at top scope so all functions
# in the call chain see them. Bash 3.2 has no `local -n` (nameref), so we
# couple by convention rather than reference.
VERIFY_FORMAT=''
VERIFY_FORMAT_FIX=''
VERIFY_LINT=''
VERIFY_LINT_FIX=''
VERIFY_TYPECHECK=''
VERIFY_SOURCE=''

# Load .verify block from <repo_root>/.aidevops.json if present and enabled.
# Returns 0 on hit, 1 on miss/disabled.
_load_verify_from_aidevops_json() {
	local cfg="${REPO_ROOT}/.aidevops.json"
	[[ -f "$cfg" ]] || return 1
	command -v jq >/dev/null 2>&1 || { _dbg "jq missing — skipping .aidevops.json"; return 1; }

	local enabled
	enabled=$(jq -r '.verify.enabled // empty' "$cfg" 2>/dev/null || true)
	if [[ "$enabled" == "false" ]]; then
		_dbg ".aidevops.json .verify.enabled=false — opting out"
		VERIFY_SOURCE='aidevops-json-disabled'
		return 0
	fi

	# `--` separates jq query from positional arg
	VERIFY_FORMAT=$(jq -r '.verify.format // empty' "$cfg" 2>/dev/null || true)
	VERIFY_FORMAT_FIX=$(jq -r '.verify.format_fix // empty' "$cfg" 2>/dev/null || true)
	VERIFY_LINT=$(jq -r '.verify.lint // empty' "$cfg" 2>/dev/null || true)
	VERIFY_LINT_FIX=$(jq -r '.verify.lint_fix // empty' "$cfg" 2>/dev/null || true)
	VERIFY_TYPECHECK=$(jq -r '.verify.typecheck // empty' "$cfg" 2>/dev/null || true)

	if [[ -n "$VERIFY_FORMAT$VERIFY_LINT$VERIFY_TYPECHECK" ]]; then
		VERIFY_SOURCE='aidevops-json'
		_dbg ".aidevops.json hit: format=${VERIFY_FORMAT:-<none>} lint=${VERIFY_LINT:-<none>} typecheck=${VERIFY_TYPECHECK:-<none>}"
		return 0
	fi
	return 1
}

# Load scripts from <repo_root>/package.json. We only treat a script as
# present when the value is non-empty; the `format_fix`/`lint_fix` slots
# prefer explicit `format:fix`/`lint:fix` scripts when declared.
_load_verify_from_package_json() {
	local cfg="${REPO_ROOT}/package.json"
	[[ -f "$cfg" ]] || return 1
	command -v jq >/dev/null 2>&1 || { _dbg "jq missing — skipping package.json"; return 1; }

	local fmt fmt_fix_colon fmt_fix_under lnt lnt_fix_colon lnt_fix_under tcheck tcheck_dash
	fmt=$(jq -r '.scripts.format // empty' "$cfg" 2>/dev/null || true)
	fmt_fix_colon=$(jq -r '.scripts."format:fix" // empty' "$cfg" 2>/dev/null || true)
	fmt_fix_under=$(jq -r '.scripts.format_fix // empty' "$cfg" 2>/dev/null || true)
	lnt=$(jq -r '.scripts.lint // empty' "$cfg" 2>/dev/null || true)
	lnt_fix_colon=$(jq -r '.scripts."lint:fix" // empty' "$cfg" 2>/dev/null || true)
	lnt_fix_under=$(jq -r '.scripts.lint_fix // empty' "$cfg" 2>/dev/null || true)
	tcheck=$(jq -r '.scripts.typecheck // empty' "$cfg" 2>/dev/null || true)
	tcheck_dash=$(jq -r '.scripts."type-check" // empty' "$cfg" 2>/dev/null || true)

	if [[ -z "$fmt$lnt$tcheck$tcheck_dash" ]]; then
		return 1
	fi

	# Detect package manager for npm-script invocation
	local pm='npm'
	[[ -f "${REPO_ROOT}/pnpm-lock.yaml" ]] && pm='pnpm'
	[[ -f "${REPO_ROOT}/yarn.lock" ]] && pm='yarn'
	[[ -f "${REPO_ROOT}/bun.lockb" || -f "${REPO_ROOT}/bun.lock" ]] && pm='bun'

	[[ -n "$fmt" ]] && VERIFY_FORMAT="$pm run format"
	if [[ -n "$fmt_fix_colon" ]]; then
		VERIFY_FORMAT_FIX="$pm run format:fix"
	elif [[ -n "$fmt_fix_under" ]]; then
		VERIFY_FORMAT_FIX="$pm run format_fix"
	fi
	[[ -n "$lnt" ]] && VERIFY_LINT="$pm run lint"
	if [[ -n "$lnt_fix_colon" ]]; then
		VERIFY_LINT_FIX="$pm run lint:fix"
	elif [[ -n "$lnt_fix_under" ]]; then
		VERIFY_LINT_FIX="$pm run lint_fix"
	fi
	if [[ -n "$tcheck" ]]; then
		VERIFY_TYPECHECK="$pm run typecheck"
	elif [[ -n "$tcheck_dash" ]]; then
		VERIFY_TYPECHECK="$pm run type-check"
	fi

	VERIFY_SOURCE="package-json($pm)"
	_dbg "package.json hit (pm=$pm): format=${VERIFY_FORMAT:-<none>} lint=${VERIFY_LINT:-<none>} typecheck=${VERIFY_TYPECHECK:-<none>}"
	return 0
}

# Load defaults from .agents/configs/repo-verify-defaults.conf based on
# sentinel file presence at the repo root. First matching toolchain wins.
# Conf format: TOOLCHAIN | DETECTOR_FILE | FORMAT | FORMAT_FIX | LINT | LINT_FIX | TYPECHECK
_load_verify_from_defaults() {
	local conf=''
	if [[ -f "$DEFAULTS_REPO" ]]; then
		conf="$DEFAULTS_REPO"
	elif [[ -f "$DEFAULTS_DEPLOYED" ]]; then
		conf="$DEFAULTS_DEPLOYED"
	else
		_dbg "no defaults conf found"
		return 1
	fi

	local line tc detector fmt fmt_fix lnt lnt_fix tcheck
	while IFS= read -r line; do
		# Skip comments and blanks
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ -z "${line// /}" ]] && continue

		# Split on |, trim whitespace from each field
		IFS='|' read -r tc detector fmt fmt_fix lnt lnt_fix tcheck <<< "$line"
		tc="${tc## }"; tc="${tc%% }"
		detector="${detector## }"; detector="${detector%% }"
		fmt="${fmt## }"; fmt="${fmt%% }"
		fmt_fix="${fmt_fix## }"; fmt_fix="${fmt_fix%% }"
		lnt="${lnt## }"; lnt="${lnt%% }"
		lnt_fix="${lnt_fix## }"; lnt_fix="${lnt_fix%% }"
		tcheck="${tcheck## }"; tcheck="${tcheck%% }"

		[[ -z "$detector" ]] && continue
		[[ -e "${REPO_ROOT}/${detector}" ]] || continue

		[[ "$fmt" != '-' && -n "$fmt" ]] && VERIFY_FORMAT="$fmt"
		[[ "$fmt_fix" != '-' && -n "$fmt_fix" ]] && VERIFY_FORMAT_FIX="$fmt_fix"
		[[ "$lnt" != '-' && -n "$lnt" ]] && VERIFY_LINT="$lnt"
		[[ "$lnt_fix" != '-' && -n "$lnt_fix" ]] && VERIFY_LINT_FIX="$lnt_fix"
		[[ "$tcheck" != '-' && -n "$tcheck" ]] && VERIFY_TYPECHECK="$tcheck"

		VERIFY_SOURCE="defaults($tc)"
		_dbg "defaults hit: $tc (detector=$detector)"
		return 0
	done < "$conf"
	return 1
}

# ----- run a single verify check ------------------------------------------

# _run_check NAME COMMAND -> exit 0 on pass, 1 on fail. Captures output for
# the failure mentor message. Echoes a concise status line on success.
_run_check() {
	local name="$1"
	local cmd="$2"
	local log
	log=$(mktemp -t "aidevops-prepush-${name}.XXXXXX")
	_log INFO "running $name: $cmd"
	if (cd "$REPO_ROOT" && eval "$cmd") >"$log" 2>&1; then
		_log OK "$name passed"
		rm -f "$log"
		return 0
	fi
	_log FAIL "$name failed — last 30 lines:"
	tail -n 30 "$log" >&2 || true
	# Stash log path on global for the autofix path to retain context
	LAST_FAIL_LOG="$log"
	return 1
}

# _run_autofix NAME FIX_COMMAND CHECK_COMMAND
# Returns 0 if check passes after autofix (with possible amend),
# 1 if autofix unavailable/disabled or still fails.
_run_autofix() {
	local name="$1"
	local fix_cmd="$2"
	local check_cmd="$3"

	if [[ -z "$fix_cmd" ]]; then
		_log INFO "$name autofix unavailable (no *_fix command declared)"
		return 1
	fi
	if [[ "$AUTOFIX" != "1" ]]; then
		_log INFO "$name autofix skipped (AIDEVOPS_PREPUSH_AUTOFIX=0)"
		return 1
	fi

	_log INFO "running $name autofix: $fix_cmd"
	if ! (cd "$REPO_ROOT" && eval "$fix_cmd") >>"${LAST_FAIL_LOG:-/dev/null}" 2>&1; then
		_log WARN "$name autofix command itself failed"
		return 1
	fi

	# Did autofix change any tracked files?
	if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
		_log INFO "$name autofix modified files — amending HEAD"
		if ! git -C "$REPO_ROOT" add -A 2>>"${LAST_FAIL_LOG:-/dev/null}"; then
			_log WARN "$name autofix git add failed"
			return 1
		fi
		if ! git -C "$REPO_ROOT" commit --amend --no-edit --no-verify 2>>"${LAST_FAIL_LOG:-/dev/null}"; then
			_log WARN "$name autofix git commit --amend failed"
			return 1
		fi
		_log OK "$name autofix amended into HEAD"
	else
		_dbg "$name autofix produced no diff"
	fi

	# Re-run the check to confirm
	if _run_check "${name}-recheck" "$check_cmd"; then
		return 0
	fi
	return 1
}

# Emit a mentoring failure message for the next push attempt
_emit_mentor_fail() {
	local name="$1"
	local fix_cmd="$2"
	printf '\n' >&2
	printf '[%s][BLOCK] %s failed and autofix is %s.\n' "$GUARD_NAME" "$name" \
		"$([[ -z "$fix_cmd" ]] && printf 'unavailable' || printf 'disabled')" >&2
	printf '\n' >&2
	printf '  Resolution:\n' >&2
	if [[ -n "$fix_cmd" ]]; then
		printf '    1. Run: %s\n' "$fix_cmd" >&2
		printf '    2. git add -A && git commit --amend --no-edit\n' >&2
		printf '    3. git push (re-runs verify on the amended commit)\n' >&2
		printf '\n' >&2
		printf '  Or enable autofix for this push:\n' >&2
		printf '    AIDEVOPS_PREPUSH_AUTOFIX=1 git push\n' >&2
	else
		printf '    1. Read the failing command output above and fix the source\n' >&2
		printf '    2. Re-run: %s   (must pass)\n' "${3:-<original check>}" >&2
		printf '    3. git add -A && git commit --amend --no-edit && git push\n' >&2
	fi
	printf '\n' >&2
	printf '  Bypass once (CI will catch the failure):\n' >&2
	printf '    AIDEVOPS_PREPUSH_REPO_VERIFY=0 git push\n' >&2
	printf '\n' >&2
}

# ----- main orchestration -------------------------------------------------

main() {
	if _load_verify_from_aidevops_json; then
		if [[ "$VERIFY_SOURCE" == "aidevops-json-disabled" ]]; then
			_log INFO "repo opts out via .aidevops.json .verify.enabled=false"
			exit 0
		fi
	elif _load_verify_from_package_json; then
		:
	elif _load_verify_from_defaults; then
		:
	else
		_dbg "no verify config resolved — skipping"
		exit 0
	fi

	if [[ -z "$VERIFY_FORMAT$VERIFY_LINT$VERIFY_TYPECHECK" ]]; then
		_dbg "config resolved but no commands set — skipping"
		exit 0
	fi

	# Working-tree cleanliness check: if the WT is dirty, the verify run
	# would conflate user WIP with the actual push state. Warn + skip.
	if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
		_log WARN "working tree has uncommitted changes — skipping verify"
		_log WARN "commit (or stash) and re-push to verify the push state"
		exit 0
	fi

	_log INFO "verify source: $VERIFY_SOURCE"
	local overall=0

	if [[ -n "$VERIFY_FORMAT" ]]; then
		if ! _run_check 'format' "$VERIFY_FORMAT"; then
			if _run_autofix 'format' "$VERIFY_FORMAT_FIX" "$VERIFY_FORMAT"; then
				:
			else
				_emit_mentor_fail 'format' "$VERIFY_FORMAT_FIX" "$VERIFY_FORMAT"
				overall=1
			fi
		fi
	fi

	if [[ -n "$VERIFY_LINT" ]]; then
		if ! _run_check 'lint' "$VERIFY_LINT"; then
			if _run_autofix 'lint' "$VERIFY_LINT_FIX" "$VERIFY_LINT"; then
				:
			else
				_emit_mentor_fail 'lint' "$VERIFY_LINT_FIX" "$VERIFY_LINT"
				overall=1
			fi
		fi
	fi

	# Typecheck never auto-fixes — semantic failures need code changes
	if [[ -n "$VERIFY_TYPECHECK" ]]; then
		if ! _run_check 'typecheck' "$VERIFY_TYPECHECK"; then
			_emit_mentor_fail 'typecheck' '' "$VERIFY_TYPECHECK"
			overall=1
		fi
	fi

	if [[ "$overall" -eq 0 ]]; then
		_log OK "all verify checks passed — allowing push"
	fi
	exit "$overall"
}

# Consume stdin so the dispatcher doesn't see SIGPIPE if we exit early.
# We don't actually use the ref list (we verify the WT, not a diff).
cat >/dev/null 2>&1 || true

main
