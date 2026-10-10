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
#   2. <repo_root>/package.json exact declared scripts. Mutating `format`
#      scripts and ambiguous package-manager lockfiles are never inferred.
#   3. .agents/configs/repo-verify-defaults.conf — evidence-based toolchain
#      detection (for example Cargo.toml or committed Ruff configuration)
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
#   - Proven task-ID CAS update: exactly one fast-forward update to
#     refs/heads/task-id-counter that changes only .task-counter to a valid,
#     increasing integer
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
VERIFY_LIB_REPO="${HOOK_DIR}/../scripts/repo-verify-config-lib.sh"
VERIFY_LIB_DEPLOYED="${HOME:+$HOME/.aidevops/agents/scripts/repo-verify-config-lib.sh}"
if [[ -f "$VERIFY_LIB_REPO" ]]; then
	# shellcheck source=../scripts/repo-verify-config-lib.sh
	source "$VERIFY_LIB_REPO"
elif [[ -f "$VERIFY_LIB_DEPLOYED" ]]; then
	# shellcheck source=/dev/null
	source "$VERIFY_LIB_DEPLOYED"
else
	_log INFO "repo verify configuration library unavailable — skipping"
	exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "$REPO_ROOT" ]]; then
	_log INFO "not in a git repo — skipping"
	exit 0
fi

_is_headless_session() {
	[[ -n "${FULL_LOOP_HEADLESS:-}${AIDEVOPS_HEADLESS:-}${OPENCODE_HEADLESS:-}" ]] && return 0
	return 1
}

# Auto-fix default: ON in headless, OFF interactive. AIDEVOPS_PREPUSH_AUTOFIX
# (when set) wins over the heuristic.
_autofix_default() {
	if _is_headless_session || [[ -n "${GITHUB_ACTIONS:-}" ]]; then
		printf '1\n'
	else
		printf '0\n'
	fi
}
AUTOFIX="${AIDEVOPS_PREPUSH_AUTOFIX:-$(_autofix_default)}"

# ----- discovery ----------------------------------------------------------

# Globals consumed by the execution path. The shared detector populates its
# REPO_VERIFY_* namespace; this adapter preserves the hook's established names.
VERIFY_FORMAT=''
VERIFY_FORMAT_FIX=''
VERIFY_LINT=''
VERIFY_LINT_FIX=''
VERIFY_TYPECHECK=''
VERIFY_SOURCE=''

_load_verify_config() {
	repo_verify_detect "$REPO_ROOT" || true
	if [[ "$REPO_VERIFY_STATUS" == "disabled" ]]; then
		VERIFY_SOURCE='aidevops-json-disabled'
		return 0
	fi
	if [[ "$REPO_VERIFY_STATUS" != "ready" ]]; then
		[[ -n "$REPO_VERIFY_WARNING" ]] && _dbg "$REPO_VERIFY_WARNING"
		return 1
	fi
	VERIFY_FORMAT="$REPO_VERIFY_FORMAT"
	VERIFY_FORMAT_FIX="$REPO_VERIFY_FORMAT_FIX"
	VERIFY_LINT="$REPO_VERIFY_LINT"
	VERIFY_LINT_FIX="$REPO_VERIFY_LINT_FIX"
	VERIFY_TYPECHECK="$REPO_VERIFY_TYPECHECK"
	VERIFY_SOURCE="$REPO_VERIFY_SOURCE"
	return 0
}

# ----- Python tool source for inferred defaults (GH#34163) ----------------

# Bin directory prepended to PATH for each check; empty means bare PATH.
VERIFY_TOOL_PATH=''

# Print the distinct Python tools invoked as the first word of the inferred
# commands. Only these names are looked up in a candidate environment.
_default_python_tools() {
	local cmd="" tool="" seen=" "
	for cmd in "$VERIFY_FORMAT" "$VERIFY_FORMAT_FIX" "$VERIFY_LINT" "$VERIFY_LINT_FIX" "$VERIFY_TYPECHECK"; do
		tool="${cmd%% *}"
		[[ -n "$tool" && "$tool" =~ ^(${_PY_VERIFY_TOOLS})$ ]] || continue
		[[ "$seen" == *" $tool "* ]] && continue
		seen+="$tool "
		printf '%s\n' "$tool"
	done
	return 0
}

# A candidate is a real virtual environment (pyvenv.cfg) whose bin/ holds an
# executable for every inferred tool. Nothing is executed or installed.
_python_env_provides_tools() {
	local venv="$1"
	local tools="$2"
	local tool=""
	[[ -f "$venv/pyvenv.cfg" && -d "$venv/bin" ]] || return 1
	while IFS= read -r tool; do
		[[ -n "$tool" ]] || continue
		[[ -f "$venv/bin/$tool" && -x "$venv/bin/$tool" ]] || return 1
	done <<<"$tools"
	return 0
}

# Main worktree root for a linked worktree, or nothing. One fixed path derived
# from Git metadata; never a directory scan.
_main_worktree_root() {
	local common_dir="" main_root=""
	common_dir=$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	[[ "$(basename "$common_dir")" == ".git" ]] || return 1
	main_root=$(dirname "$common_dir")
	[[ -d "$main_root" && ! "$main_root" -ef "$REPO_ROOT" ]] || return 1
	printf '%s\n' "$main_root"
	return 0
}

# Inferred Python defaults call bare tool names (repo-verify-defaults.conf).
# Resolve them from the project's own environment in a fixed order:
#   1. <worktree>/.venv
#   2. interactive sessions only: <main worktree>/.venv (linked worktrees do not
#      carry the gitignored environment; headless workers keep PATH containment)
# Explicit .aidevops.json and package.json commands are never altered. When no
# candidate qualifies, bare PATH and the GH#34110 missing-tool diagnosis apply.
_resolve_default_python_tool_path() {
	local tools="" main_root="" candidate=""
	[[ "$VERIFY_SOURCE" == defaults\(PYTHON_* ]] || return 0
	tools=$(_default_python_tools)
	[[ -n "$tools" ]] || return 0
	if _python_env_provides_tools "$REPO_ROOT/.venv" "$tools"; then
		VERIFY_TOOL_PATH="$REPO_ROOT/.venv/bin"
		_log INFO "python tool source: worktree .venv"
		return 0
	fi
	if _is_headless_session; then
		_dbg "headless session: main-worktree environment not consulted"
		return 0
	fi
	main_root=$(_main_worktree_root) || return 0
	candidate="$main_root/.venv"
	if _python_env_provides_tools "$candidate" "$tools"; then
		VERIFY_TOOL_PATH="$candidate/bin"
		_log INFO "python tool source: main-worktree .venv"
	fi
	return 0
}

# Evaluate one declared command from the repo root, with the resolved tool
# source (if any) first on PATH for that command only.
_eval_in_repo() {
	local cmd="$1"
	cd "$REPO_ROOT" || return 1
	if [[ -n "$VERIFY_TOOL_PATH" ]]; then
		export PATH="$VERIFY_TOOL_PATH${PATH:+:$PATH}"
	fi
	eval "$cmd" && return 0
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
	if (_eval_in_repo "$cmd") >"$log" 2>&1; then
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
	if ! (_eval_in_repo "$fix_cmd") >>"${LAST_FAIL_LOG:-/dev/null}" 2>&1; then
		_log WARN "$name autofix command itself failed"
		return 1
	fi

	# Did autofix change any tracked files?
	if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
		_log INFO "$name autofix modified files — amending HEAD"
		# Redirect BOTH streams to the log so the hook never leaks chatter
		# into git's stdout (which gets surfaced in the calling shell).
		if ! git -C "$REPO_ROOT" add -A >>"${LAST_FAIL_LOG:-/dev/null}" 2>&1; then
			_log WARN "$name autofix git add failed"
			return 1
		fi
		if ! git -C "$REPO_ROOT" commit --amend --no-edit --no-verify >>"${LAST_FAIL_LOG:-/dev/null}" 2>&1; then
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

_typecheck_missing_bun_dev_dependencies() {
	local log_file="$1"
	[[ -f "$REPO_ROOT/package.json" && -f "$REPO_ROOT/bun.lock" ]] || return 1
	[[ ! -x "$REPO_ROOT/node_modules/.bin/tsc" && -f "$log_file" ]] || return 1
	grep -Eiq '(tsc([^[:alnum:]_]|$).*(command not found|not found)|(command not found|not found).*tsc([^[:alnum:]_]|$))' \
		"$log_file" 2>/dev/null || return 1
	return 0
}

_emit_missing_bun_dev_dependencies() {
	_log BLOCK "typecheck could not start: missing JavaScript dev dependencies"
	printf '\n' >&2
	printf '  Resolution:\n' >&2
	printf '    1. Run: bun install\n' >&2
	printf '    2. Re-run: %s\n' "$VERIFY_TYPECHECK" >&2
	printf '    3. git push (re-runs repo verification)\n' >&2
	printf '\n' >&2
	return 0
}

# GH#34094: a declared JavaScript lint command that cannot start (linter binary
# absent, or a flat-config plugin/package unresolvable) is unavailable tooling,
# not a demonstrated source defect. Log content is only pattern-matched, never
# executed. Any ESLint problem summary keeps the normal source-failure path.
_lint_missing_js_tooling() {
	local log_file="$1"
	[[ -f "$REPO_ROOT/package.json" && -f "$log_file" ]] || return 1
	if grep -Eq '^[[:space:]]*(✖|x)?[[:space:]]*[0-9]+ problems? \(' "$log_file" 2>/dev/null; then
		return 1
	fi
	if grep -Eq '(^|[[:space:]:])(eslint|biome|oxlint|next)(: command not found|: not found)' \
		"$log_file" 2>/dev/null; then
		return 0
	fi
	if grep -Eq "Cannot find (package|module) '[^']+' imported from [^[:space:]]*eslint\.config\.[cm]?[jt]s" \
		"$log_file" 2>/dev/null; then
		return 0
	fi
	grep -Eq "ESLint couldn't find the (plugin|config)" "$log_file" 2>/dev/null || return 1
	return 0
}

# Name the project-declared install command from the tracked lockfile.
_js_install_command() {
	if [[ -f "$REPO_ROOT/bun.lock" || -f "$REPO_ROOT/bun.lockb" ]]; then
		printf 'bun install --frozen-lockfile'
	elif [[ -f "$REPO_ROOT/pnpm-lock.yaml" ]]; then
		printf 'pnpm install --frozen-lockfile'
	elif [[ -f "$REPO_ROOT/yarn.lock" ]]; then
		printf 'yarn install --frozen-lockfile'
	elif [[ -f "$REPO_ROOT/package-lock.json" ]]; then
		printf 'npm ci'
	else
		printf 'npm install'
	fi
	return 0
}

_emit_missing_js_lint_tooling() {
	_log BLOCK "lint could not start: JavaScript lint tooling or plugins are unavailable in this worktree"
	_log BLOCK "this is not a demonstrated source lint defect; the unchanged lint gate must still run and pass"
	printf '\n' >&2
	printf '  Resolution (keep source, config and lockfile unchanged):\n' >&2
	printf '    1. Provision dev dependencies (downloads need approval): %s\n' "$(_js_install_command)" >&2
	printf '       Interactive alternative: explicitly approved read-only reuse of an\n' >&2
	printf '       existing compatible install — see tools/runtime/node-server-admin.md\n' >&2
	printf '       "Linked-worktree lint tooling". A global eslint binary is not enough\n' >&2
	printf '       when the flat config imports plugins.\n' >&2
	printf '    2. Re-run: %s   (must pass)\n' "$VERIFY_LINT" >&2
	printf '    3. git push (re-runs repo verification)\n' >&2
	printf '\n' >&2
	return 0
}

# GH#34110: a Python verification tool that is not on this PATH (or not
# importable by the selected interpreter) cannot have evaluated the source.
# Print the missing tool name; return 1 when the log shows the tool actually
# ran (ruff/black/mypy summaries) or no missing-tool signature is present.
# Log content is only pattern-matched, never executed.
_PY_VERIFY_TOOLS='ruff|black|flake8|pytest|mypy|isort|pyright|pylint'
_missing_python_tooling() {
	local log_file="$1"
	local match=""
	[[ -f "$log_file" ]] || return 1
	if grep -Eiq '(^Found [0-9]+ errors?|[0-9]+ files? (would be|left) (reformatted|unchanged)|^would reformat)' \
		"$log_file" 2>/dev/null; then
		return 1
	fi
	# bash/sh/env forms: "line 1: ruff: command not found", "sh: 1: ruff: not
	# found", "env: 'ruff': No such file or directory"; zsh: "command not
	# found: ruff"; interpreter: "python: No module named ruff".
	match=$(grep -Eo "(^|[[:space:]:/])'?(${_PY_VERIFY_TOOLS})'?(: command not found|: not found|: No such file or directory)" \
		"$log_file" 2>/dev/null | head -n 1) || match=""
	if [[ -z "$match" ]]; then
		match=$(grep -Eo "command not found: (${_PY_VERIFY_TOOLS})([[:space:]]|$)" "$log_file" 2>/dev/null | head -n 1) || match=""
	fi
	if [[ -z "$match" ]]; then
		match=$(grep -Eo "No module named '?(${_PY_VERIFY_TOOLS})('|[[:space:]]|$)" "$log_file" 2>/dev/null | head -n 1) || match=""
	fi
	[[ -n "$match" ]] || return 1
	match=$(printf '%s' "$match" | grep -Eo "(${_PY_VERIFY_TOOLS})" | head -n 1)
	printf '%s\n' "$match"
	return 0
}

_emit_missing_python_tooling() {
	local name="$1"
	local tool="$2"
	local check_cmd="$3"
	_log BLOCK "$name could not start: Python verification tool '$tool' is unavailable to the selected interpreter/PATH"
	_log BLOCK "this is not a demonstrated source defect; the unchanged $name gate must still run and pass"
	printf '\n' >&2
	printf '  Resolution (keep source and configuration unchanged; never bypass this gate):\n' >&2
	if [[ -x "$REPO_ROOT/.venv/bin/$tool" ]]; then
		printf '    1. This worktree has %s. Declare it explicitly in .aidevops.json\n' ".venv/bin/$tool" >&2
		printf '       .verify, for example: "%s": ".venv/bin/%s ..."\n' "$name" "$tool" >&2
	else
		printf '    1. Reuse an approved existing environment by declaring its interpreter\n' >&2
		printf '       explicitly in .aidevops.json .verify, for example:\n' >&2
		printf '       "%s": "<approved-venv>/bin/python -m %s ..."\n' "$name" "$tool" >&2
		printf '       Do not scan host directories for environments.\n' >&2
	fi
	printf '    2. Otherwise installing %s needs dependency-installation authority.\n' "$tool" >&2
	printf '       Headless workers: report TERMINAL_BLOCKER_REASON=runner_capability_unmet,\n' >&2
	printf '       not permission_required, and name the missing tool in the dossier.\n' >&2
	printf '    3. Re-run: %s   (must pass)\n' "$check_cmd" >&2
	printf '\n' >&2
	return 0
}

# Classify one failed check. Returns 0 (and prints guidance) only for missing
# Python tooling, in which case callers skip autofix: the fixer shares the
# unavailable toolchain.
_check_failed_on_missing_python_tooling() {
	local name="$1"
	local check_cmd="$2"
	local tool=""
	tool=$(_missing_python_tooling "${LAST_FAIL_LOG:-}") || return 1
	_emit_missing_python_tooling "$name" "$tool" "$check_cmd"
	return 0
}

# ----- task-ID counter-only push validation --------------------------------

# A task-ID CAS allocation creates one plumbing commit directly atop the pinned
# task-id-counter tip. It must remain independently safe in a fresh worktree
# before JavaScript dependencies have been bootstrapped (GH#29411, GH#29413).
#
# Read Git's pre-push input and return 0 only when every invariant below is
# proven. Any malformed, multi-ref, non-fast-forward, mixed-file, missing, or
# non-increasing update falls through to normal repository verification.
_is_safe_counter_only_push() {
	local local_ref=''
	local local_sha=''
	local remote_ref=''
	local remote_sha=''
	local extra=''
	local input_local_ref=''
	local input_local_sha=''
	local input_remote_ref=''
	local input_remote_sha=''
	local input_extra=''
	local line_count=0
	local parent_sha=''
	local old_counter=''
	local new_counter=''
	local changed_paths=''

	while IFS=' ' read -r input_local_ref input_local_sha input_remote_ref input_remote_sha input_extra; do
		line_count=$((line_count + 1))
		[[ $line_count -eq 1 ]] || return 1
		[[ -z "$input_extra" ]] || return 1
		local_ref="$input_local_ref"
		local_sha="$input_local_sha"
		remote_ref="$input_remote_ref"
		remote_sha="$input_remote_sha"
	done

	[[ $line_count -eq 1 ]] || return 1
	[[ "$remote_ref" == 'refs/heads/task-id-counter' ]] || return 1
	[[ "$local_sha" =~ ^[0-9a-fA-F]{40,64}$ && "$remote_sha" =~ ^[0-9a-fA-F]{40,64}$ ]] || return 1

	git -C "$REPO_ROOT" cat-file -e "${local_sha}^{commit}" 2>/dev/null || return 1
	git -C "$REPO_ROOT" cat-file -e "${remote_sha}^{commit}" 2>/dev/null || return 1
	parent_sha=$(git -C "$REPO_ROOT" rev-parse "${local_sha}^" 2>/dev/null) || return 1
	[[ "$parent_sha" == "$remote_sha" ]] || return 1

	changed_paths=$(git -C "$REPO_ROOT" diff-tree --no-commit-id --no-renames --name-only -r "$remote_sha" "$local_sha" 2>/dev/null) || return 1
	[[ "$changed_paths" == '.task-counter' ]] || return 1

	old_counter=$(git -C "$REPO_ROOT" show "${remote_sha}:.task-counter" 2>/dev/null | tr -d '[:space:]') || return 1
	new_counter=$(git -C "$REPO_ROOT" show "${local_sha}:.task-counter" 2>/dev/null | tr -d '[:space:]') || return 1
	[[ "$old_counter" =~ ^[0-9]+$ && "$new_counter" =~ ^[0-9]+$ ]] || return 1
	((10#$new_counter > 10#$old_counter)) || return 1

	return 0
}

# ----- main orchestration -------------------------------------------------

main() {
	if _is_safe_counter_only_push; then
		_log OK 'task-id counter-only invariants passed — skipping full repository verification'
		exit 0
	fi

	if _load_verify_config; then
		if [[ "$VERIFY_SOURCE" == "aidevops-json-disabled" ]]; then
			_log INFO "repo opts out via .aidevops.json .verify.enabled=false"
			exit 0
		fi
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
	_resolve_default_python_tool_path
	local overall=0

	if [[ -n "$VERIFY_FORMAT" ]]; then
		if ! _run_check 'format' "$VERIFY_FORMAT"; then
			if _check_failed_on_missing_python_tooling 'format' "$VERIFY_FORMAT"; then
				overall=1
			elif _run_autofix 'format' "$VERIFY_FORMAT_FIX" "$VERIFY_FORMAT"; then
				:
			else
				_emit_mentor_fail 'format' "$VERIFY_FORMAT_FIX" "$VERIFY_FORMAT"
				overall=1
			fi
		fi
	fi

	if [[ -n "$VERIFY_LINT" ]]; then
		if ! _run_check 'lint' "$VERIFY_LINT"; then
			if _lint_missing_js_tooling "${LAST_FAIL_LOG:-}"; then
				# The fixer shares the unavailable toolchain; skip autofix.
				_emit_missing_js_lint_tooling
				overall=1
			elif _check_failed_on_missing_python_tooling 'lint' "$VERIFY_LINT"; then
				overall=1
			elif _run_autofix 'lint' "$VERIFY_LINT_FIX" "$VERIFY_LINT"; then
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
			if _typecheck_missing_bun_dev_dependencies "${LAST_FAIL_LOG:-}"; then
				_emit_missing_bun_dev_dependencies
			elif _check_failed_on_missing_python_tooling 'typecheck' "$VERIFY_TYPECHECK"; then
				:
			else
				_emit_mentor_fail 'typecheck' '' "$VERIFY_TYPECHECK"
			fi
			overall=1
		fi
	fi

	if [[ "$overall" -eq 0 ]]; then
		_log OK "all verify checks passed — allowing push"
	fi
	exit "$overall"
}

main
