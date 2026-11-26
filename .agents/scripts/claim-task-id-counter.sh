#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Claim Task ID — Counter/Allocation Sub-Library
# =============================================================================
# CAS (compare-and-swap) counter management and ID allocation functions
# extracted from claim-task-id.sh.
#
# Covers:
#   1. Counter reads (local and remote)
#   2. Counter bootstrap (seed from TODO.md on first use)
#   3. CAS loop (fetch → pin → build → push, with wall-clock timeout)
#   4. Online allocation (with collision-avoidance against existing TODO entries)
#   5. Offline allocation (with +OFFLINE_OFFSET safety gap)
#
# Usage: source "${SCRIPT_DIR}/claim-task-id-counter.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_error, log_success)
#   - Global variables from claim-task-id.sh:
#       REMOTE_NAME, COUNTER_BRANCH, COUNTER_FILE
#       CAS_MAX_RETRIES, CAS_WALL_TIMEOUT_S, CAS_GIT_CMD_TIMEOUT_S
#       CAS_HTTPS_TIMEOUT_S, CAS_SSH_FALLBACK_ENABLED  (GH#21904)
#       CAS_EXHAUSTION_FATAL, OFFLINE_OFFSET
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CLAIM_TASK_ID_COUNTER_LIB_LOADED:-}" ]] && return 0
_CLAIM_TASK_ID_COUNTER_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh:35-41 pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_claim_counter_lib_dir="${BASH_SOURCE[0]%/*}"
[[ "$_claim_counter_lib_dir" == "${BASH_SOURCE[0]}" ]] && _claim_counter_lib_dir="."
# shellcheck source=./task-identity-lib.sh
source "${_claim_counter_lib_dir}/task-identity-lib.sh"
unset _claim_counter_lib_dir

# =============================================================================
# Formatting Helpers
# =============================================================================

# Preserve the public claim-task-id.sh setup-error exit contract through every
# allocation layer. A protected-branch rejection is policy, not contention, so
# callers must not reconcile and attempt the same forbidden push again.
CAS_PROTECTED_BRANCH_RC="${CAS_PROTECTED_BRANCH_RC:-4}"
TASK_COUNTER_SETUP_STATUS="${TASK_COUNTER_SETUP_STATUS:-setup_error}"

# Format a numeric sequence as a canonical legacy task identity.
# Args: $1 numeric sequence.
_format_legacy_task_id() {
	local sequence="$1"
	task_identity_format "legacy" "" "$sequence" ""
	return $?
}

# Format a task ID range for log messages and commit subjects.
# Args: $1 first numeric ID, $2 last numeric ID.
# Outputs: e.g. "t42..t45"
_format_task_range() {
	local first_num="$1"
	local last_num="$2"
	local first_id=""
	local last_id=""
	first_id=$(_format_legacy_task_id "$first_num") || return 1
	last_id=$(_format_legacy_task_id "$last_num") || return 1
	printf '%s..%s' "$first_id" "$last_id"
	return 0
}

# Machine-local coordinator integration. Legacy CAS remains authoritative unless
# AIDEVOPS_TASK_COORDINATOR_MODE is explicitly set to shadow or namespaced.
_task_coordinator_cli() {
	printf '%s/task-coordinator.mjs' "$SCRIPT_DIR"
	return 0
}

_task_coordinator_shadow_legacy() {
	local first_id="$1"
	local count="$2"
	[[ "${AIDEVOPS_TASK_COORDINATOR_MODE:-legacy}" == "shadow" ]] || return 0
	[[ "${AIDEVOPS_TASK_COORDINATOR_SHADOW_ENABLED:-0}" == "1" ]] || return 0
	local cli=""
	cli=$(_task_coordinator_cli)
	local operation_id="legacy-${AIDEVOPS_SESSION_ID:-${BASHPID:-$$}}-${first_id}-${count}"
	local legacy_id=""
	legacy_id=$(_format_legacy_task_id "$first_id") || return 1
	if ! node "$cli" allocate --operation-id "$operation_id" --count "$count" \
		--legacy-id "$legacy_id" --payload '{"source":"legacy-cas-shadow"}' >/dev/null; then
		log_warn "Task coordinator shadow write failed; legacy CAS allocation remains valid"
		return 0
	fi
	log_info "Task coordinator shadow recorded ${legacy_id} without changing emitted identity"
	return 0
}

_task_coordinator_namespaced_allocate() {
	local count="$1"
	[[ "${AIDEVOPS_TASK_COORDINATOR_MODE:-legacy}" == "namespaced" ]] || return 1
	if [[ "${AIDEVOPS_TASK_COORDINATOR_NAMESPACED_EMISSION_ENABLED:-0}" != "1" ]]; then
		log_error "Namespaced coordinator mode requires AIDEVOPS_TASK_COORDINATOR_NAMESPACED_EMISSION_ENABLED=1"
		return 2
	fi
	local cli=""
	cli=$(_task_coordinator_cli)
	node "$cli" allocate --operation-id "${AIDEVOPS_TASK_OPERATION_ID:-$(uuidgen 2>/dev/null || printf 'claim-%s-%s' "${BASHPID:-$$}" "$RANDOM")}" \
		--count "$count" --payload '{"source":"claim-task-id"}'
	return $?
}

# ---------------------------------------------------------------------------
# Append a structured audit log line for a successful CAS claim.
# Format: ISO8601 \t pid \t session_id \t tNNN \t attempt \t elapsed_s
# (tab-separated so later tooling can parse without quoting concerns.)
# Log file: ~/.aidevops/logs/task-claim.log (created on first append).
#
# Phase 3 (t2569 / GH#20001): forensics for CAS-race or reuse incidents.
# ---------------------------------------------------------------------------
_append_claim_audit_log() {
	local first_id="${1:-}"
	local attempt="${2:-1}"
	local elapsed="${3:-0}"

	[[ -z "$first_id" ]] && return 0

	local log_dir="${HOME}/.aidevops/logs"
	local log_file="${log_dir}/task-claim.log"

	mkdir -p "$log_dir" 2>/dev/null || return 0

	local ts pid sid tid
	ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
	pid="${BASHPID:-$$}"
	sid="${AIDEVOPS_SESSION_ID:-${Claude_SESSION_ID:-${OPENCODE_SESSION_ID:-unknown}}}"
	tid=$(_format_legacy_task_id "$first_id") || return 0

	# Tab-separated; single append is atomic on POSIX filesystems for short writes.
	printf '%s\t%s\t%s\t%s\t%s\t%ss\n' \
		"$ts" "$pid" "$sid" "$tid" "$attempt" "$elapsed" >> "$log_file" 2>/dev/null || true
	return 0
}

# =============================================================================
# Guard-compatible Git execution context
# =============================================================================
# The repository supplied through --repo-path remains the source of task state
# (TODO.md, project config, and hooks). Online counter discovery and CAS need a
# mutable Git object database, so canonical checkouts use an owned disposable
# bare repository under the approved aidevops temp root. Linked worktrees and
# unmanaged repositories keep using their existing Git context.
CAS_SOURCE_REPO_PATH="${CAS_SOURCE_REPO_PATH:-}"
CAS_GIT_CONTEXT_PATH="${CAS_GIT_CONTEXT_PATH:-}"
_CLAIM_COUNTER_CONTEXT_ROOT="${_CLAIM_COUNTER_CONTEXT_ROOT:-}"

_counter_git() {
	if [[ -n "${CAS_GIT_CONTEXT_PATH:-}" ]]; then
		git -C "$CAS_GIT_CONTEXT_PATH" "$@"
	else
		git "$@"
	fi
	return $?
}

_counter_context_is_isolated() {
	[[ -n "${_CLAIM_COUNTER_CONTEXT_ROOT:-}" && \
		"${CAS_GIT_CONTEXT_PATH:-}" == "${_CLAIM_COUNTER_CONTEXT_ROOT}/repository.git" ]] || return 1
	return 0
}

# Fetch arguments for the isolated bare context only: one commit, no tags and
# no blobs (commits and trees only), so a large tip does not exceed
# CAS_HTTPS_TIMEOUT_S. Never use these against a shared object store: depth
# writes a shallow file and --filter registers the remote as a promisor.
_counter_isolated_fetch_args() {
	printf '%s\n' '--depth=1 --no-tags --filter=blob:none'
	return 0
}

# Read a blob/object spec. In the isolated (blob-less) context this lazily
# fetches one blob over the network, so bound it with the transport timeout.
_counter_show() {
	local spec="$1"

	if _counter_context_is_isolated; then
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" show "$spec" 2>/dev/null
		return $?
	fi
	_counter_git show "$spec"
	return $?
}

# git mktree from stdin. Isolated blob-less trees lack unchanged blobs that
# mktree would otherwise verify; entries come from ls-tree of a real tip.
_counter_mktree() {
	if _counter_context_is_isolated; then
		_counter_git mktree --missing
		return $?
	fi
	_counter_git mktree
	return $?
}

_counter_source_git() {
	if [[ -n "${CAS_SOURCE_REPO_PATH:-}" ]]; then
		git -C "$CAS_SOURCE_REPO_PATH" "$@"
	else
		git "$@"
	fi
	return $?
}

_claim_counter_context_error() {
	local detail="$1"
	local message="$2"
	log_error "COUNTER_GIT_CONTEXT_ERROR: ${message}"
	_task_counter_status "$TASK_COUNTER_SETUP_STATUS" "$detail"
	return "$CAS_PROTECTED_BRANCH_RC"
}

_claim_counter_cleanup_git_context() {
	local context_root="${_CLAIM_COUNTER_CONTEXT_ROOT:-}"
	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME:-}/.aidevops/.agent-workspace/tmp}"
	local resolved_parent=""
	local resolved_temp=""
	local context_name=""

	[[ -n "$context_root" && -n "$temp_root" ]] || return 0
	context_name="${context_root##*/}"
	[[ "$context_name" =~ ^claim-task-id-git\.[A-Za-z0-9]+$ ]] || return 0
	resolved_parent=$(cd "${context_root%/*}" 2>/dev/null && pwd -P) || return 0
	resolved_temp=$(cd "$temp_root" 2>/dev/null && pwd -P) || return 0
	[[ "$resolved_parent" == "$resolved_temp" ]] || return 0
	rm -rf -- "$context_root" 2>/dev/null || true
	_CLAIM_COUNTER_CONTEXT_ROOT=""
	CAS_GIT_CONTEXT_PATH="${CAS_SOURCE_REPO_PATH:-}"
	return 0
}

_claim_counter_prepare_git_context() {
	local repo_path="$1"
	local policy_helper="${SCRIPT_DIR}/canonical-write-policy-helper.py"
	local classification=""
	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME:-}/.aidevops/.agent-workspace/tmp}"
	local context_root=""
	local remote_url=""
	local user_name=""
	local user_email=""

	CAS_SOURCE_REPO_PATH="$repo_path"
	CAS_GIT_CONTEXT_PATH="$repo_path"
	_CLAIM_COUNTER_CONTEXT_ROOT=""
	[[ "${OFFLINE_MODE:-}" != "true" ]] || return 0

	[[ -f "$policy_helper" ]] || {
		_claim_counter_context_error "counter_git_context_policy_missing" \
			"canonical write policy helper is unavailable"
		return "$CAS_PROTECTED_BRANCH_RC"
	}
	classification=$(python3 "$policy_helper" classify --cwd "$repo_path" \
		--field classification 2>/dev/null) || {
		_claim_counter_context_error "counter_git_context_classification_failed" \
			"unable to classify the supplied repository path"
		return "$CAS_PROTECTED_BRANCH_RC"
	}
	[[ "$classification" == "canonical" ]] || return 0

	[[ -n "$temp_root" && "$temp_root" == /* ]] || {
		_claim_counter_context_error "counter_git_context_temp_root_failed" \
			"approved temporary root is unavailable"
		return "$CAS_PROTECTED_BRANCH_RC"
	}
	mkdir -p "$temp_root" || {
		_claim_counter_context_error "counter_git_context_temp_root_failed" \
			"unable to create the approved temporary root"
		return "$CAS_PROTECTED_BRANCH_RC"
	}
	chmod 700 "$temp_root" 2>/dev/null || true
	context_root=$(mktemp -d "${temp_root%/}/claim-task-id-git.XXXXXX") || {
		_claim_counter_context_error "counter_git_context_create_failed" \
			"unable to create isolated Git context"
		return "$CAS_PROTECTED_BRANCH_RC"
	}
	_CLAIM_COUNTER_CONTEXT_ROOT="$context_root"
	CAS_GIT_CONTEXT_PATH="${context_root}/repository.git"

	git -C "$context_root" init --bare --quiet repository.git || {
		_claim_counter_context_error "counter_git_context_init_failed" \
			"unable to initialize isolated Git context"
		return "$CAS_PROTECTED_BRANCH_RC"
	}
	remote_url=$(git -C "$repo_path" remote get-url "$REMOTE_NAME" 2>/dev/null) || {
		_claim_counter_context_error "counter_git_context_remote_failed" \
			"unable to resolve remote ${REMOTE_NAME}"
		return "$CAS_PROTECTED_BRANCH_RC"
	}
	_counter_git remote add "$REMOTE_NAME" "$remote_url" || {
		_claim_counter_context_error "counter_git_context_remote_failed" \
			"unable to configure remote ${REMOTE_NAME}"
		return "$CAS_PROTECTED_BRANCH_RC"
	}
	user_name=$(git -C "$repo_path" config user.name 2>/dev/null || true)
	user_email=$(git -C "$repo_path" config user.email 2>/dev/null || true)
	_counter_git config user.name "${user_name:-aidevops}" || {
		_claim_counter_context_error "counter_git_context_identity_failed" \
			"unable to configure isolated Git author name"
		return "$CAS_PROTECTED_BRANCH_RC"
	}
	_counter_git config user.email "${user_email:-aidevops@local}" || {
		_claim_counter_context_error "counter_git_context_identity_failed" \
			"unable to configure isolated Git author email"
		return "$CAS_PROTECTED_BRANCH_RC"
	}
	log_info "Using isolated Git context for canonical counter discovery and CAS"
	return 0
}

# =============================================================================
# HTTPS timeout + SSH fallback for CAS git operations (GH#21904)
# =============================================================================
# The CAS path (`git fetch`/`git push` against the counter branch) hangs
# indefinitely when git's HTTPS credential helper stalls — observed with
# osxkeychain on macOS, libsecret/manager-core on Linux. The existing
# `http.lowSpeedTime` only fires once bytes start flowing; credential
# negotiation hangs happen BEFORE the transport is established and bypass it.
#
# Mitigation: wrap each call with `timeout_sec` (from shared-constants.sh).
# On timeout (exit 124) OR other git failure against an HTTPS-GitHub remote,
# derive the SSH-equivalent URL and retry once via
# `-c url.<ssh>.insteadOf=<https>` so the original `$REMOTE_NAME` ref-name
# still resolves. Retrying non-timeout failures lets `GIT_ASKPASS=/bin/false`
# and stale/broken credential-helper paths recover without waiting for a hang.
#
# `gh` CLI authenticates via the ssh-protocol preference by default, so SSH
# pushes succeed when the gh-managed token (used by HTTPS) is unreachable.
#
# Memory: mem_20260430054453_5f0d112e (HTTPS push hung; SSH workaround
# verified to complete in <10s on the same network).

# Convert a GitHub HTTPS clone URL to its SSH equivalent.
# Args: $1 — input URL.
# Stdout: SSH-form URL on conversion, empty on no-conversion.
# Returns: 0 on conversion (stdout populated), 1 on no-conversion.
#
# Examples:
#   https://github.com/owner/repo.git → git@github.com:owner/repo.git
#   https://github.com/owner/repo     → git@github.com:owner/repo
#   git@github.com:owner/repo.git     → "" (already SSH; rc=1)
#   https://gitlab.com/owner/repo.git → "" (only GitHub for now; rc=1)
_derive_ssh_url_from_https() {
	local url="${1:-}"
	[[ -z "$url" ]] && return 1
	# Match `https://github.com/<owner>/<repo>` with optional .git suffix.
	# Bash 3.2 compatible regex (no \K, no lookaheads).
	if [[ "$url" =~ ^https://github\.com/([^/[:space:]]+/[^/[:space:]]+)(\.git)?$ ]]; then
		local path="${BASH_REMATCH[1]}"
		local suffix="${BASH_REMATCH[2]}"
		# Trim any trailing slashes from path before the (optional) .git suffix
		path="${path%/}"
		printf 'git@github.com:%s%s' "$path" "$suffix"
		return 0
	fi
	return 1
}

# Detect `ls-remote ... --exit-code ...`, whose rc=2 is a definitive remote
# answer ("no matching refs"), not a transport failure (GH#38493).
# Args: git subcommand and arguments, as passed to _run_git_with_ssh_fallback.
# Returns: 0 when the subcommand is ls-remote with --exit-code before any `--`,
#          1 otherwise.
_git_args_is_ls_remote_exit_code() {
	local subcommand="${1:-}"
	local arg=""
	[[ "$subcommand" == "ls-remote" ]] || return 1
	shift
	for arg in "$@"; do
		[[ "$arg" == "--" ]] && return 1
		[[ "$arg" == "--exit-code" ]] && return 0
	done
	return 1
}

# Run a git command with a wall-clock timeout and HTTPS→SSH fallback.
# Args: $1 — timeout in seconds, $2..$N — git subcommand and its arguments
#       (do NOT include the leading `git`; this helper adds it).
# Returns: the git command's exit code on success or non-timeout failure;
#          124 if both attempts time out (or fallback is disabled / not
#          applicable after a timeout). On HTTPS failure + successful SSH retry,
#          returns 0.
#
# Behaviour matrix:
#   HTTPS succeeds within timeout              → return 0
#   ls-remote --exit-code returns 2 (remote
#     answered: no matching refs)              → return 2 (no fallback, GH#38493)
#   HTTPS fails non-timeout + fallback succeeds → return 0
#   HTTPS fails non-timeout + fallback fails    → return fallback rc
#   HTTPS times out, remote NOT https-github    → return 124 (no fallback)
#   HTTPS times out, fallback disabled          → return 124 (no fallback)
#   HTTPS times out, fallback runs and succeeds → return 0
#   HTTPS times out, fallback also times out    → return 124
_run_git_with_ssh_fallback() {
	local timeout_s="$1"
	shift
	local context_path="${CAS_GIT_CONTEXT_PATH:-}"
	# First attempt — pass through unchanged. Quote "$@" so subcommand args
	# survive whitespace, glob chars, etc.
	local rc=0
	if [[ -n "$context_path" ]]; then
		timeout_sec "$timeout_s" git -C "$context_path" "$@" || rc=$?
	else
		timeout_sec "$timeout_s" git "$@" || rc=$?
	fi
	if [[ $rc -eq 0 ]]; then
		return $rc
	fi
	# The remote answered over HTTPS. Retrying over SSH can only replace that
	# answer with an unrelated transport/auth failure (e.g. rc=128 where no SSH
	# key is available), misreporting an absent branch as a discovery error.
	if [[ $rc -eq 2 ]] && _git_args_is_ls_remote_exit_code "$@"; then
		return $rc
	fi

	# Failure path. Check whether SSH fallback applies.
	if [[ "${CAS_SSH_FALLBACK_ENABLED:-1}" != "1" ]]; then
		if [[ $rc -eq 124 ]]; then
			log_warn "git timed out after ${timeout_s}s (CAS_SSH_FALLBACK_ENABLED=0 — no retry)"
		else
			log_warn "git failed with rc=${rc} (CAS_SSH_FALLBACK_ENABLED=0 — no retry)"
		fi
		return $rc
	fi

	local current_url
	current_url=$(_counter_git remote get-url "${REMOTE_NAME:-origin}" 2>/dev/null) || {
		if [[ $rc -eq 124 ]]; then
			log_warn "git timed out after ${timeout_s}s (could not resolve ${REMOTE_NAME:-origin} URL — no fallback)"
		else
			log_warn "git failed with rc=${rc} (could not resolve ${REMOTE_NAME:-origin} URL — no fallback)"
		fi
		return $rc
	}

	local ssh_url=""
	ssh_url=$(_derive_ssh_url_from_https "$current_url") || true
	if [[ -z "$ssh_url" ]]; then
		# Already SSH, or non-GitHub HTTPS — no fallback applies.
		if [[ $rc -eq 124 ]]; then
			log_warn "git timed out after ${timeout_s}s on ${current_url} (no HTTPS-GitHub → SSH fallback applies)"
		else
			log_warn "git failed with rc=${rc} on ${current_url} (no HTTPS-GitHub → SSH fallback applies)"
		fi
		return $rc
	fi

	if [[ $rc -eq 124 ]]; then
		log_warn "git timed out after ${timeout_s}s on HTTPS — retrying via SSH (${ssh_url})"
	else
		log_warn "git failed with rc=${rc} on HTTPS — retrying via SSH (${ssh_url})"
	fi
	rc=0
	if [[ -n "$context_path" ]]; then
		timeout_sec "$timeout_s" git -C "$context_path" \
			-c "url.${ssh_url}.insteadOf=${current_url}" "$@" || rc=$?
	else
		timeout_sec "$timeout_s" git \
			-c "url.${ssh_url}.insteadOf=${current_url}" "$@" || rc=$?
	fi
	if [[ $rc -eq 0 ]]; then
		log_info "SSH fallback succeeded — HTTPS push hang transparent to caller (GH#21904)"
	elif [[ $rc -eq 124 ]]; then
		log_warn "SSH fallback also timed out after ${timeout_s}s — both transports unavailable"
	fi
	return $rc
}

# Run the pre-push hook once, outside the remote transport timeout. Git normally
# includes hook execution in the `git push` process, which caused a valid but
# slow repo-verify gate to exhaust CAS_HTTPS_TIMEOUT_S and be misreported as
# retriable contention (GH#29417). The subsequent push uses --no-verify.
# Args: $1 local commit SHA, $2 expected remote commit SHA.
# Returns: 0 when no hook exists or it passes; 1 on remote lookup, hook timeout,
# or hook failure. Diagnostics identify the phase and elapsed time.
_cas_run_pre_push_hook() {
	local local_sha="$1"
	local remote_sha="$2"
	local remote_ref="refs/heads/${COUNTER_BRANCH}"
	local started_at=""
	local finished_at=""
	local elapsed=0
	local remote_url=""
	local hook_path=""
	local hook_rc=0
	local object_dir=""

	started_at=$(date +%s)
	remote_url=$(_counter_git remote get-url "$REMOTE_NAME" 2>/dev/null) || {
		finished_at=$(date +%s)
		elapsed=$((finished_at - started_at))
		log_error "CAS remote configuration validation failed after ${elapsed}s for remote ${REMOTE_NAME}"
		return 1
	}
	finished_at=$(date +%s)
	elapsed=$((finished_at - started_at))
	log_info "CAS remote configuration validated in ${elapsed}s"

	hook_path=$(_counter_source_git rev-parse --path-format=absolute --git-path hooks/pre-push 2>/dev/null) || {
		log_error "Could not resolve the pre-push hook path"
		return 1
	}
	[[ -x "$hook_path" ]] || return 0
	if _counter_context_is_isolated; then
		object_dir=$(_counter_git rev-parse --path-format=absolute --git-path objects) || return 1
	fi

	started_at=$(date +%s)
	(
		cd "${CAS_SOURCE_REPO_PATH:-${REPO_PATH:-$PWD}}" || exit 1
		# Keep source refs/config/worktree semantics, but make the plumbing-only
		# counter commit and its parent visible to read-only hook scanners.
		if [[ -n "$object_dir" ]]; then
			export GIT_ALTERNATE_OBJECT_DIRECTORIES="${object_dir}${GIT_ALTERNATE_OBJECT_DIRECTORIES:+:${GIT_ALTERNATE_OBJECT_DIRECTORIES}}"
		fi
		timeout_sec "${CAS_HOOK_TIMEOUT_S:-300}" "$hook_path" "$REMOTE_NAME" "$remote_url" \
			<<<"${local_sha} ${local_sha} ${remote_ref} ${remote_sha}" >/dev/null
	) || hook_rc=$?
	finished_at=$(date +%s)
	elapsed=$((finished_at - started_at))

	if [[ $hook_rc -eq 124 ]]; then
		log_error "Pre-push hook ${hook_path##*/} timed out after ${elapsed}s (limit=${CAS_HOOK_TIMEOUT_S:-300}s); remote push was not attempted"
		return 1
	fi
	if [[ $hook_rc -ne 0 ]]; then
		log_error "Pre-push hook ${hook_path##*/} failed after ${elapsed}s with rc=${hook_rc}; remote push was not attempted"
		return 1
	fi

	log_info "Pre-push hook completed in ${elapsed}s (limit=${CAS_HOOK_TIMEOUT_S:-300}s)"
	return 0
}

# Resolve the remote's actual default branch via its HEAD symref, without
# assuming "main". Args: none (uses REMOTE_NAME / CAS_GIT_CONTEXT_PATH).
# Stdout: the branch name (e.g. "develop") on success.
# Returns: 0 on success, 1 when the remote HEAD symref cannot be resolved.
_counter_detect_remote_default_branch() {
	local output=""
	local branch=""

	output=$(_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		ls-remote --symref "$REMOTE_NAME" HEAD 2>/dev/null) || return 1
	branch=$(printf '%s\n' "$output" | awk '/^ref:/{print $2}' | sed 's#^refs/heads/##')
	[[ -n "$branch" ]] || return 1
	printf '%s\n' "$branch"
	return 0
}

# Align DEFAULT_BRANCH (and, when also unset, COUNTER_BRANCH) with the
# remote's actual default branch instead of the historical "main" literal
# (GH#33152). Only runs when .aidevops.json did not set "default_branch" —
# an explicit config value always wins. Fail-open: on detection failure the
# "main" fallback already assigned at variable declaration is kept, and the
# existing protected-branch / stale-branch diagnostics still apply downstream.
_claim_apply_detected_default_branch() {
	local detected=""

	[[ "${OFFLINE_MODE:-false}" == "false" ]] || return 0
	[[ "${_DEFAULT_BRANCH_SET:-false}" == "false" ]] || return 0

	detected=$(_counter_detect_remote_default_branch) || {
		log_warn "Unable to detect ${REMOTE_NAME} default branch (ls-remote failed); DEFAULT_BRANCH remains ${DEFAULT_BRANCH:-main}"
		return 0
	}
	[[ -n "$detected" ]] || return 0

	if [[ "$detected" != "$DEFAULT_BRANCH" ]]; then
		log_info "Default branch detected from ${REMOTE_NAME}: ${detected}"
	fi
	DEFAULT_BRANCH="$detected"

	# COUNTER_BRANCH still carries its literal "main" declaration default —
	# only realign it when nothing (CLI, config, or a prior implicit-branch
	# selection) has already chosen a value.
	if [[ "${_COUNTER_BRANCH_SET:-false}" == "false" && "$COUNTER_BRANCH" == "main" ]]; then
		COUNTER_BRANCH="$detected"
	fi
	return 0
}

# Never sync an obsolete default-branch pin. Validate before building a commit.
_counter_validate_sync_target() {
	local target_branch="$1" default_branch="$2" target_counter="$3"
	if [[ "$target_branch" == "$default_branch" ]]; then
		local COUNTER_BRANCH="$target_branch" _COUNTER_BRANCH_SET=true
		_cas_validate_explicit_counter_branch "${REMOTE_NAME}/${target_branch}" "$target_counter" || return $?
	fi
	return 0
}

# Explicit, audited fast-forward catch-up for a counter branch (GH#33152 gap
# 4): sets it to max(its own counter, the default branch's counter, the
# TODO.md seed) instead of resolve_implicit_counter_branch's silent refusal
# when it is behind. Never rewrites history — the new commit's parent is the
# branch's current tip, so the push is fast-forward-only.
# Args: $1 repo_path, $2 target counter branch, $3 default branch.
# Stdout: "COUNTER_BRANCH_SYNCED branch=<branch> value=<N>" on success/no-op.
# Returns: 0 on success or already-current no-op, 1 on hard failure,
#          CAS_PROTECTED_BRANCH_RC when the target branch rejects direct pushes.
sync_counter_branch() {
	local repo_path="$1"
	local target_branch="$2"
	local default_branch="${3:-main}"
	local depth_args=()
	local target_counter="0"
	local default_counter="0"
	local todo_seed="0"
	local sync_target=""

	_counter_context_is_isolated && read -r -a depth_args <<<"$(_counter_isolated_fetch_args)"

	if ! _run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		fetch -q "${depth_args[@]}" "$REMOTE_NAME" \
		"+refs/heads/${target_branch}:refs/remotes/${REMOTE_NAME}/${target_branch}" >/dev/null; then
		log_error "COUNTER_BRANCH_SYNC_ERROR: unable to fetch ${REMOTE_NAME}/${target_branch}"
		return 1
	fi
	if ! _run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		fetch -q "${depth_args[@]}" "$REMOTE_NAME" \
		"+refs/heads/${default_branch}:refs/remotes/${REMOTE_NAME}/${default_branch}" >/dev/null; then
		log_error "COUNTER_BRANCH_SYNC_ERROR: unable to fetch ${REMOTE_NAME}/${default_branch}"
		return 1
	fi

	target_counter=$(_counter_show "${REMOTE_NAME}/${target_branch}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]' || true)
	[[ "$target_counter" =~ ^[0-9]+$ ]] || target_counter="0"
	default_counter=$(_counter_show "${REMOTE_NAME}/${default_branch}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]' || true)
	[[ "$default_counter" =~ ^[0-9]+$ ]] || default_counter="0"
	todo_seed=$(_compute_counter_seed "$repo_path")

	_counter_validate_sync_target "$target_branch" "$default_branch" "$target_counter" || return $?
	sync_target="$target_counter"
	((10#$default_counter > 10#$sync_target)) && sync_target="$default_counter"
	((10#$todo_seed > 10#$sync_target)) && sync_target="$todo_seed"

	if [[ "$sync_target" == "$target_counter" ]]; then
		log_info "COUNTER_BRANCH_SYNC_NOOP: ${REMOTE_NAME}/${target_branch} already at or above max(default=${default_counter}, todo=${todo_seed})"
		printf 'COUNTER_BRANCH_SYNCED branch=%s value=%s\n' "$target_branch" "$target_counter"
		return 0
	fi

	local blob_sha="" existing_tree="" tree_sha="" parent_sha="" commit_sha=""
	blob_sha=$(echo "$sync_target" | _counter_git hash-object -w --stdin 2>/dev/null) || {
		log_error "COUNTER_BRANCH_SYNC_ERROR: failed to create blob"
		return 1
	}
	existing_tree=$(_counter_git ls-tree "${REMOTE_NAME}/${target_branch}" 2>/dev/null || true)
	if grep -q "${COUNTER_FILE}$" <<<"$existing_tree"; then
		tree_sha=$(echo "$existing_tree" | sed "s|[0-9a-f]\{40,64\}	${COUNTER_FILE}$|${blob_sha}	${COUNTER_FILE}|" | _counter_mktree 2>/dev/null) || {
			log_error "COUNTER_BRANCH_SYNC_ERROR: failed to build replacement tree"
			return 1
		}
	else
		tree_sha=$(
			{
				echo "$existing_tree"
				printf '100644 blob %s\t%s\n' "$blob_sha" "$COUNTER_FILE"
			} | _counter_mktree 2>/dev/null
		) || {
			log_error "COUNTER_BRANCH_SYNC_ERROR: failed to build tree"
			return 1
		}
	fi
	parent_sha=$(_counter_git rev-parse "${REMOTE_NAME}/${target_branch}" 2>/dev/null) || {
		log_error "COUNTER_BRANCH_SYNC_ERROR: failed to resolve ${REMOTE_NAME}/${target_branch}"
		return 1
	}
	commit_sha=$(_counter_git commit-tree "$tree_sha" -p "$parent_sha" \
		-m "chore: sync-counter-branch ${target_branch} -> ${sync_target} (max of default=${default_counter}, todo=${todo_seed}, prior=${target_counter})" 2>/dev/null) || {
		log_error "COUNTER_BRANCH_SYNC_ERROR: failed to create commit"
		return 1
	}

	local push_err_file="" push_rc=0 stderr_text=""
	push_err_file=$(mktemp "${AIDEVOPS_TEMP_DIR:-${HOME:-}/.aidevops/.agent-workspace/tmp}/sync-counter-push.XXXXXX" 2>/dev/null) || push_err_file=""
	if [[ -n "$push_err_file" ]]; then
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
			push "$REMOTE_NAME" "${commit_sha}:refs/heads/${target_branch}" >/dev/null 2>"$push_err_file" || push_rc=$?
		stderr_text=$(cat "$push_err_file" 2>/dev/null || true)
		rm -f "$push_err_file" 2>/dev/null || true
	else
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
			push "$REMOTE_NAME" "${commit_sha}:refs/heads/${target_branch}" >/dev/null || push_rc=$?
	fi

	if [[ $push_rc -ne 0 ]]; then
		if [[ "$stderr_text" == *"Changes must be made through a pull request"* ]]; then
			log_error "PROTECTED_COUNTER_BRANCH: ${REMOTE_NAME}/${target_branch} rejects direct sync pushes"
			return "$CAS_PROTECTED_BRANCH_RC"
		fi
		log_error "COUNTER_BRANCH_SYNC_ERROR: push failed (rc=${push_rc}); ${stderr_text}"
		return 1
	fi

	_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		fetch -q "$REMOTE_NAME" "$target_branch" >/dev/null 2>&1 || true
	log_info "COUNTER_BRANCH_SYNCED: ${REMOTE_NAME}/${target_branch} fast-forwarded to ${sync_target}"
	printf 'COUNTER_BRANCH_SYNCED branch=%s value=%s\n' "$target_branch" "$sync_target"
	return 0
}

# GH#33527: a repository that has never allocated task IDs has no counter on
# its default branch. Bootstrapping there pushes commits straight to the
# default branch (and can ship .task-counter in release artifacts), so target
# the dedicated branch instead unless the caller opted in. A fetch failure
# leaves the selection unchanged; bootstrap_remote_counter still refuses an
# implicit default-branch bootstrap.
# Args: $1 dedicated candidate branch name.
_counter_redirect_missing_default_counter() {
	local candidate="$1"
	local default_branch="${DEFAULT_BRANCH:-main}"
	local default_counter=""
	local depth_args=()

	if [[ "${AIDEVOPS_COUNTER_BOOTSTRAP_DEFAULT_BRANCH:-0}" == "1" ]]; then
		log_info "Dedicated counter branch ${candidate} not present; using ${default_branch} (AIDEVOPS_COUNTER_BOOTSTRAP_DEFAULT_BRANCH=1)"
		return 0
	fi
	_counter_context_is_isolated && read -r -a depth_args <<<"$(_counter_isolated_fetch_args)"
	if ! _run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		fetch -q "${depth_args[@]}" --no-tags "$REMOTE_NAME" \
		"+refs/heads/${default_branch}:refs/remotes/${REMOTE_NAME}/${default_branch}" >/dev/null; then
		log_info "Dedicated counter branch ${candidate} not present; using ${default_branch}"
		return 0
	fi
	default_counter=$(_counter_show "${REMOTE_NAME}/${default_branch}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]' || true)
	if [[ "$default_counter" =~ ^[0-9]+$ ]]; then
		log_info "Dedicated counter branch ${candidate} not present; using ${default_branch}"
		return 0
	fi

	COUNTER_BRANCH="$candidate"
	_COUNTER_BOOTSTRAP_DEDICATED=true
	log_info "COUNTER_BOOTSTRAP_TARGET: ${REMOTE_NAME}/${default_branch} has no ${COUNTER_FILE}; allocation will create the dedicated branch ${candidate} and leave ${default_branch} untouched (GH#33527)"
	log_info "To keep the counter on ${default_branch} instead, set .aidevops.json counter_branch or AIDEVOPS_COUNTER_BOOTSTRAP_DEFAULT_BRANCH=1"
	return 0
}

# Prefer the conventional dedicated branch when neither CLI nor project config
# selected a counter branch. The candidate is accepted only when its counter is
# at least the default-branch counter and the TODO-derived seed, preventing an
# implicit migration from reusing IDs or introducing a migration gap.
resolve_implicit_counter_branch() {
	local repo_path="$1"
	local candidate="${AIDEVOPS_DEDICATED_COUNTER_BRANCH:-task-id-counter}"
	local candidate_counter=""
	local default_counter="0"
	local todo_seed="0"
	local fetch_rc=0
	local probe_rc=0
	local depth_args=()

	[[ "${_COUNTER_BRANCH_SET:-false}" == "false" ]] || return 0
	[[ "${OFFLINE_MODE:-false}" == "false" ]] || return 0
	[[ "$COUNTER_BRANCH" == "${DEFAULT_BRANCH:-main}" ]] || return 0
	[[ -n "$candidate" && "$candidate" != "$COUNTER_BRANCH" ]] || return 0
	# Limit depth to the isolated bare context: a shallow file in the shared
	# object store truncates history for the canonical checkout and all worktrees.
	# The explicit refspec retains the remote-tracking ref used below.
	_counter_context_is_isolated && read -r -a depth_args <<<"$(_counter_isolated_fetch_args)"
	_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		fetch -q "${depth_args[@]}" --no-tags "$REMOTE_NAME" \
		"+refs/heads/${candidate}:refs/remotes/${REMOTE_NAME}/${candidate}" >/dev/null || fetch_rc=$?
	if [[ $fetch_rc -ne 0 ]]; then
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
			ls-remote --exit-code --heads "$REMOTE_NAME" "refs/heads/${candidate}" \
			>/dev/null || probe_rc=$?
		if [[ $probe_rc -eq 2 ]]; then
			_counter_redirect_missing_default_counter "$candidate"
			return 0
		fi
		log_error "COUNTER_BRANCH_DISCOVERY_ERROR: unable to fetch or classify ${REMOTE_NAME}/${candidate} (fetch_rc=${fetch_rc}, probe_rc=${probe_rc}, CAS_HTTPS_TIMEOUT_S=${CAS_HTTPS_TIMEOUT_S:-30})"
		_task_counter_status "$TASK_COUNTER_SETUP_STATUS" "counter_branch_discovery_failed"
		return "$CAS_PROTECTED_BRANCH_RC"
	fi
	candidate_counter=$(_counter_show "${REMOTE_NAME}/${candidate}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]' || true)
	if ! [[ "$candidate_counter" =~ ^[0-9]+$ ]]; then
		log_warn "Dedicated counter branch ${REMOTE_NAME}/${candidate} has an invalid or missing ${COUNTER_FILE}; refusing implicit migration"
		return 0
	fi

	if ! _run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		fetch -q "${depth_args[@]}" --no-tags "$REMOTE_NAME" \
		"+refs/heads/${DEFAULT_BRANCH:-main}:refs/remotes/${REMOTE_NAME}/${DEFAULT_BRANCH:-main}" >/dev/null; then
		log_error "COUNTER_BRANCH_DISCOVERY_ERROR: unable to validate ${candidate} against ${REMOTE_NAME}/${DEFAULT_BRANCH:-main}; CAS_HTTPS_TIMEOUT_S=${CAS_HTTPS_TIMEOUT_S:-30}"
		_task_counter_status "$TASK_COUNTER_SETUP_STATUS" "counter_branch_discovery_failed"
		return "$CAS_PROTECTED_BRANCH_RC"
	fi
	default_counter=$(_counter_show "${REMOTE_NAME}/${DEFAULT_BRANCH:-main}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]' || true)
	[[ "$default_counter" =~ ^[0-9]+$ ]] || default_counter="0"
	todo_seed=$(_compute_counter_seed "$repo_path")

	if ((10#$candidate_counter < 10#$default_counter || 10#$candidate_counter < 10#$todo_seed)); then
		log_warn "COUNTER_BRANCH_STALE: dedicated counter branch ${REMOTE_NAME}/${candidate} is behind canonical task state; refusing implicit migration"
		if ((10#$candidate_counter > 10#$default_counter)); then
			log_error "Refusing to allocate from the lower default counter; run --sync-counter-branch first"
			return "$CAS_PROTECTED_BRANCH_RC"
		fi
		return 0
	fi

	COUNTER_BRANCH="$candidate"
	log_info "counter branch auto-selected from validated dedicated branch: ${COUNTER_BRANCH}"
	return 0
}

# Resolve the GitHub owner/repository slug from the configured remote without
# applying git url.*.insteadOf rewrites. The raw value lets fixtures route a
# GitHub-shaped URL to a local bare repository while production still queries
# the policy for the configured remote.
_cas_extract_github_slug() {
	local repo_path="$1"
	local remote_url=""
	local slug=""

	if [[ -n "${CAS_SOURCE_REPO_PATH:-}" ]]; then
		remote_url=$(git -C "$repo_path" config --get "remote.${REMOTE_NAME}.url" 2>/dev/null || true)
	else
		remote_url=$(git config --get "remote.${REMOTE_NAME}.url" 2>/dev/null || true)
	fi
	[[ -n "$remote_url" ]] || return 1
	remote_url="${remote_url%.git}"

	case "$remote_url" in
	https://github.com/*)
		slug="${remote_url#https://github.com/}"
		;;
	git@github.com:*)
		slug="${remote_url#git@github.com:}"
		;;
	ssh://git@github.com/*)
		slug="${remote_url#ssh://git@github.com/}"
		;;
	*)
		return 1
		;;
	esac

	[[ "$slug" =~ ^[^/]+/[^/]+$ ]] || return 1
	printf '%s\n' "$slug"
	return 0
}

# Return success only when GitHub reports that the configured counter branch
# requires pull-request updates. Classic protection and modern rulesets expose
# that requirement through separate REST endpoints, so inspect both. API
# failures remain fail-open here; the push-time rejection classifier below is
# retained as the provider-independent final safety net.
_cas_github_branch_requires_pull_request() {
	local slug="$1"
	local protection_json=""
	local rules_json=""
	local protection_rc=0
	local rules_rc=0

	protection_json=$(gh api "repos/${slug}/branches/${COUNTER_BRANCH}/protection" 2>/dev/null) || protection_rc=$?
	if [[ $protection_rc -eq 0 ]] \
		&& jq -e '.required_pull_request_reviews != null' >/dev/null 2>&1 <<<"$protection_json"; then
		return 0
	fi

	rules_json=$(gh api "repos/${slug}/rules/branches/${COUNTER_BRANCH}" 2>/dev/null) || rules_rc=$?
	if [[ $rules_rc -eq 0 ]] \
		&& jq -e 'any(.[]; .type == "pull_request")' >/dev/null 2>&1 <<<"$rules_json"; then
		return 0
	fi

	return 1
}

_cas_log_counter_branch_remediation() {
	log_error "Recovery: initialize a dedicated unprotected counter branch from the current ${COUNTER_FILE} value,"
	log_error "then set .aidevops.json counter_branch to that branch (for example, \"task-id-counter\")."
	log_error "Keep ${DEFAULT_BRANCH:-main} pull-request protection unchanged; do not emulate CAS through a pull request."
	return 0
}

# Reject a known PR-only counter branch before any fetch, object creation, or
# push can advance the allocation state.
preflight_counter_branch_policy() {
	local repo_path="$1"
	local slug=""

	[[ "${OFFLINE_MODE:-false}" == "false" ]] || return 0
	[[ "${DRY_RUN:-false}" == "false" ]] || return 0
	command -v gh >/dev/null 2>&1 || return 0
	command -v jq >/dev/null 2>&1 || return 0
	slug=$(_cas_extract_github_slug "$repo_path") || return 0

	if _cas_github_branch_requires_pull_request "$slug"; then
		log_error "PROTECTED_COUNTER_BRANCH: ${REMOTE_NAME}/${COUNTER_BRANCH} requires pull-request updates"
		log_error "Task ID allocation stopped before reading or advancing ${COUNTER_FILE}."
		_cas_log_counter_branch_remediation
		_task_counter_status "$TASK_COUNTER_SETUP_STATUS" "protected_counter_branch"
		return 1
	fi

	return 0
}

# Detect GitHub protected-branch rejections in git push stderr.
# These are policy failures, not CAS contention, so retrying only burns the
# wall-clock budget and hides the actionable remediation.
_cas_push_rejection_is_protected_branch() {
	local stderr_text="${1:-}"

	[[ -z "$stderr_text" ]] && return 1
	if [[ "$stderr_text" == *"Protected branch update failed"* ]]; then
		return 0
	fi
	if [[ "$stderr_text" == *"GH006"* && "$stderr_text" == *"Changes must be made through a pull request"* ]]; then
		return 0
	fi
	if [[ "$stderr_text" == *"Changes must be made through a pull request"* && "$stderr_text" == *"refs/heads/${COUNTER_BRANCH}"* ]]; then
		return 0
	fi
	return 1
}

# Detect an actual compare-and-swap race. Only these failures are retriable;
# transport, authentication, hook, and provider-policy failures are hard errors.
_cas_push_rejection_is_non_fast_forward() {
	local push_stderr="$1"
	grep -Eiq \
		'non-fast-forward|\(fetch first\)|stale info|remote ref updated since checkout' <<<"$push_stderr"
	return $?
}

_cas_push_rejection_is_auth_failure() {
	local push_stderr="$1"
	grep -Eiq \
		'authentication failed|could not read Username|permission denied \(publickey\)|http[^[:space:]]* 40[13]|repository not found' <<<"$push_stderr"
	return $?
}

# Emit protected-branch guidance without exposing full remote URLs or stderr.
_cas_log_protected_branch_rejection() {
	log_error "PROTECTED_COUNTER_BRANCH: ${REMOTE_NAME}/${COUNTER_BRANCH} rejects direct counter pushes"
	log_error "Task ID allocation cannot advance ${COUNTER_FILE} by direct CAS push on a protected branch."
	_cas_log_counter_branch_remediation
	log_error "The CAS helper used git plumbing only; no working-tree changes or local commits were created."
	return 0
}
# =============================================================================
# Machine-local mutex for CAS serialisation (Phase 2 / t2568 / GH#20001)
# =============================================================================
# macOS has no flock(1); use atomic mkdir as the lock primitive.
# Pattern mirrors pulse-instance-lock.sh (see reference/bash-fd-locking.md).
#
# Lock path: ~/.aidevops/locks/claim-task-id.<remote>.<branch>.lock/
# Shared across repos on the same host so local runners serialise on the
# same remote/branch — they are contending for the same .task-counter anyway.
#
# Bounded wait: poll for up to CAS_LOCAL_LOCK_TIMEOUT_S (default 10s).
# If the timeout elapses, fall through UNLOCKED — the git push is still the
# authoritative CAS gate and must never be blocked by the local mutex.
# =============================================================================

CAS_LOCAL_LOCK_DIR="${CAS_LOCAL_LOCK_DIR:-${HOME}/.aidevops/locks}"
CAS_LOCAL_LOCK_TIMEOUT_S="${CAS_LOCAL_LOCK_TIMEOUT_S:-10}"

# Return the path of the lock directory for the current remote+branch pair.
_cas_local_lock_path() {
	local safe_remote safe_branch
	safe_remote=$(printf '%s' "${REMOTE_NAME:-origin}" | tr -c 'A-Za-z0-9._-' '_')
	safe_branch=$(printf '%s' "${COUNTER_BRANCH:-main}" | tr -c 'A-Za-z0-9._-' '_')
	printf '%s/claim-task-id.%s.%s.lock' "$CAS_LOCAL_LOCK_DIR" "$safe_remote" "$safe_branch"
	return 0
}

# Attempt to acquire the local mutex within CAS_LOCAL_LOCK_TIMEOUT_S seconds.
# Returns: 0 — lock acquired, 1 — timeout elapsed (proceed unlocked).
# Stale-lock reclaim: if pid file points at a dead process the lock is cleared
# and acquisition is retried (mirrors pulse-instance-lock.sh pattern).
_cas_acquire_local_lock() {
	local lock_dir
	lock_dir=$(_cas_local_lock_path)
	mkdir -p "$CAS_LOCAL_LOCK_DIR" 2>/dev/null || true

	local deadline
	deadline=$(( $(date +%s) + CAS_LOCAL_LOCK_TIMEOUT_S ))

	while (( $(date +%s) < deadline )); do
		if mkdir "$lock_dir" 2>/dev/null; then
			printf '%s' "${BASHPID:-$$}" > "${lock_dir}/pid" 2>/dev/null || true
			return 0
		fi

		# Stale-lock reclaim: if pid file points at a dead process, remove
		# the lock dir and retry the mkdir on the next loop iteration.
		local lock_pid=""
		if [[ -r "${lock_dir}/pid" ]]; then
			lock_pid=$(cat "${lock_dir}/pid" 2>/dev/null || true)
		fi
		if [[ -n "$lock_pid" ]] && [[ "$lock_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
			rm -rf "$lock_dir" 2>/dev/null || true
			continue
		fi

		sleep 0.25
	done

	return 1
}

# Release the local mutex unconditionally.
_cas_release_local_lock() {
	local lock_dir
	lock_dir=$(_cas_local_lock_path)
	rm -rf "$lock_dir" 2>/dev/null || true
	return 0
}

# GH#20224: reconciliation and allocation groups live in sub-libraries.
_claim_counter_split_dir="${BASH_SOURCE[0]%/*}"
[[ "$_claim_counter_split_dir" == "${BASH_SOURCE[0]}" ]] && _claim_counter_split_dir="."
# shellcheck source=./claim-task-id-reconcile.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via BASH_SOURCE
source "${_claim_counter_split_dir}/claim-task-id-reconcile.sh"
# shellcheck source=./claim-task-id-alloc.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via BASH_SOURCE
source "${_claim_counter_split_dir}/claim-task-id-alloc.sh"
unset _claim_counter_split_dir
