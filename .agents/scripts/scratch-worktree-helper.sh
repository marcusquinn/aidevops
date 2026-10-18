#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# scratch-worktree-helper.sh — owned, short-lived detached scratch worktrees (GH#35024).
#
# Fetch bootstraps need a linked-worktree Git context when a canonical checkout
# has no linked worktree yet. A scratch worktree created here is locked at
# creation with an owner token (`git worktree add --lock --reason`). The lock:
#   - is ownership evidence every removal fence already honours (locked ⇒ skip);
#   - survives SIGKILL, so an interrupted owner leaves a reclaimable, attributable
#     worktree instead of an anonymous detached checkout;
#   - is verified before removal, so this helper never removes a worktree whose
#     lock it does not own.
# Removal is native and non-force: dirty or untracked state is preserved.
# Every removal or refusal is audited through log_worktree_removal_event.
#
# Usage (source, then call):
#   # shellcheck source=scratch-worktree-helper.sh
#   source "${SCRIPT_DIR}/scratch-worktree-helper.sh"
#   scratch_worktree_add "$repo_path" "$base_dir" fetch HEAD || return 1
#   git -C "$SCRATCH_WORKTREE_PATH" fetch ...
#   scratch_worktree_remove "$SCRATCH_WORKTREE_PATH" "my-script.sh" || true
#
# Environment:
#   AIDEVOPS_SCRATCH_WORKTREE_STALE_MINUTES — idle minutes before a dead owner's
#     scratch worktree is reclaimable (default 30).
#
# Compatibility: bash 3.2+.

[[ "${_SCRATCH_WORKTREE_HELPER_LOADED:-}" == "1" ]] && return 0
_SCRATCH_WORKTREE_HELPER_LOADED=1

_SCRATCH_WT_LIB_DIR="${BASH_SOURCE[0]%/*}"
_SCRATCH_WT_REASON_PREFIX="aidevops-scratch/v1"
_SCRATCH_WT_CALLER="scratch-worktree-helper.sh"
_SCRATCH_WT_MODE="scratch"
_SCRATCH_WT_UNKNOWN="unknown"
SCRATCH_WORKTREE_PATH=""
SCRATCH_WORKTREE_REASON=""

# Audit one event; loads the canonical audit logger lazily (fail-open).
_scratch_wt_log() {
	local event_type="$1"
	local caller="$2"
	local wt_path="$3"
	local reason="$4"
	local context="${5:-}"
	if ! declare -F log_worktree_removal_event >/dev/null 2>&1; then
		# shellcheck source=audit-worktree-removal-helper.sh
		source "${_SCRATCH_WT_LIB_DIR}/audit-worktree-removal-helper.sh" >/dev/null 2>&1 || return 0
	fi
	declare -F log_worktree_removal_event >/dev/null 2>&1 || return 0
	log_worktree_removal_event "$event_type" "$caller" "$wt_path" "$reason" "$_SCRATCH_WT_MODE" "$context"
	return 0
}

_scratch_wt_sanitize() {
	local value="$1"
	printf '%s' "$value" | LC_ALL=C sed 's|[^A-Za-z0-9._-]|-|g'
	return 0
}

# Print a whitespace-free process start stamp, or fail when PID is not live.
_scratch_wt_process_started() {
	local pid="$1"
	local started=""
	[[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
	started=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null) || return 1
	started=$(printf '%s' "$started" | LC_ALL=C tr -s '[:space:]' '_')
	started="${started#_}"
	started="${started%_}"
	[[ -n "$started" ]] || return 1
	printf '%s\n' "$started"
	return 0
}

# Print the value of KEY from a space-separated key=value lock reason.
_scratch_wt_reason_field() {
	local reason="$1"
	local key="$2"
	local word=""
	local -a reason_words=()
	# read -a splits without pathname expansion of untrusted reason text.
	read -r -a reason_words <<<"$reason"
	[[ "${#reason_words[@]}" -gt 0 ]] || return 1
	for word in "${reason_words[@]}"; do
		case "$word" in
		"${key}="*)
			printf '%s\n' "${word#"${key}="}"
			return 0
			;;
		esac
	done
	return 1
}

# Return 0 only when the recorded owner process is provably gone (absent or a
# reused PID with a different start stamp). Unknown evidence keeps it "alive".
_scratch_wt_owner_is_dead() {
	local reason="$1"
	local pid="" recorded_started="" current_started=""
	pid=$(_scratch_wt_reason_field "$reason" pid) || return 1
	[[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
	recorded_started=$(_scratch_wt_reason_field "$reason" started) || recorded_started="$_SCRATCH_WT_UNKNOWN"
	if ! current_started=$(_scratch_wt_process_started "$pid"); then
		kill -0 "$pid" 2>/dev/null && return 1
		return 0
	fi
	[[ "$recorded_started" != "$_SCRATCH_WT_UNKNOWN" && "$current_started" != "$recorded_started" ]] && return 0
	return 1
}

# Print the lock reason currently recorded for a linked worktree.
_scratch_wt_current_reason() {
	local wt_path="$1"
	local git_dir=""
	local reason=""
	git_dir=$(git -C "$wt_path" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
	[[ -f "${git_dir}/locked" ]] || return 1
	IFS= read -r reason <"${git_dir}/locked" || [[ -n "$reason" ]] || return 1
	printf '%s\n' "$reason"
	return 0
}

# Unlock (as owner) and natively remove a clean scratch worktree. On refusal the
# original lock is restored so the worktree stays attributable and protected.
_scratch_wt_unlock_and_remove() {
	local wt_path="$1"
	local reason="$2"
	local caller="$3"
	local context="$4"
	git -C "$wt_path" worktree unlock "$wt_path" >/dev/null 2>&1 || {
		_scratch_wt_log "${_WTAR_SKIPPED:-skipped}" "$caller" "$wt_path" "scratch-unlock-failed" "$context"
		return 1
	}
	if git -C "$wt_path" worktree remove "$wt_path" >/dev/null 2>&1 && [[ ! -e "$wt_path" ]]; then
		_scratch_wt_log "${_WTAR_REMOVED:-removed}" "$caller" "$wt_path" "scratch-owned" "$context"
		return 0
	fi
	git -C "$wt_path" worktree lock --reason "$reason" "$wt_path" >/dev/null 2>&1 || true
	_scratch_wt_log "${_WTAR_SKIPPED:-skipped}" "$caller" "$wt_path" "scratch-dirty-or-busy" "$context"
	return 1
}

#######################################
# Create a locked, owner-attributed detached scratch worktree.
# Arguments: $1 repo path, $2 base dir, $3 label, $4 commit-ish (default HEAD)
# Sets: SCRATCH_WORKTREE_PATH, SCRATCH_WORKTREE_REASON
# Returns: 0 on success, 1 on failure (nothing left behind by this call)
#######################################
scratch_worktree_add() {
	local repo_path="$1"
	local base_dir="$2"
	local label="$3"
	local commitish="${4:-HEAD}"
	local safe_label="" repo_name="" started="" scratch_path="" reason=""
	SCRATCH_WORKTREE_PATH=""
	SCRATCH_WORKTREE_REASON=""
	[[ -n "$repo_path" && -n "$base_dir" && -n "$label" ]] || return 1
	safe_label=$(_scratch_wt_sanitize "$label")
	repo_name=$(_scratch_wt_sanitize "$(basename "$repo_path")")
	mkdir -p "$base_dir" || return 1
	scratch_worktree_reap_stale "$repo_path" || true
	started=$(_scratch_wt_process_started "$$") || started="$_SCRATCH_WT_UNKNOWN"
	reason="${_SCRATCH_WT_REASON_PREFIX} label=${safe_label} pid=$$ started=${started} nonce=${RANDOM}${RANDOM}"
	scratch_path="${base_dir}/.${repo_name}-${safe_label}-$$-${RANDOM}${RANDOM}"
	[[ ! -e "$scratch_path" && ! -L "$scratch_path" ]] || return 1
	if ! git -C "$repo_path" worktree add -q --detach --lock --reason "$reason" \
		"$scratch_path" "$commitish" >/dev/null 2>&1; then
		# Git < 2.36 lacks `add --reason`: create, then lock before any use.
		[[ ! -e "$scratch_path" ]] || return 1
		git -C "$repo_path" worktree add -q --detach "$scratch_path" "$commitish" >/dev/null 2>&1 || return 1
		if ! git -C "$scratch_path" worktree lock --reason "$reason" "$scratch_path" >/dev/null 2>&1; then
			git -C "$scratch_path" worktree remove "$scratch_path" >/dev/null 2>&1 || true
			return 1
		fi
	fi
	SCRATCH_WORKTREE_PATH="$scratch_path"
	SCRATCH_WORKTREE_REASON="$reason"
	return 0
}

#######################################
# Remove a scratch worktree created by this process.
# Refuses (preserving the worktree) unless the lock reason is still exactly the
# token this process recorded, and unless native non-force removal succeeds.
# Arguments: $1 scratch path, $2 audit caller
# Returns: 0 when removed, 1 when preserved
#######################################
scratch_worktree_remove() {
	local wt_path="$1"
	local caller="${2:-$_SCRATCH_WT_CALLER}"
	local expected_reason="${SCRATCH_WORKTREE_REASON:-}"
	local current_reason=""
	local context="owner_pid=$$ recovery_path=none"
	[[ -n "$wt_path" ]] || return 1
	if [[ "$wt_path" != "${SCRATCH_WORKTREE_PATH:-}" || -z "$expected_reason" || -L "$wt_path" ]]; then
		_scratch_wt_log "${_WTAR_SKIPPED:-skipped}" "$caller" "$wt_path" "scratch-not-owned" "$context"
		return 1
	fi
	if ! current_reason=$(_scratch_wt_current_reason "$wt_path") ||
		[[ "$current_reason" != "$expected_reason" ]]; then
		_scratch_wt_log "${_WTAR_SKIPPED:-skipped}" "$caller" "$wt_path" "scratch-lock-changed" "$context"
		return 1
	fi
	_scratch_wt_unlock_and_remove "$wt_path" "$expected_reason" "$caller" "$context" || return 1
	SCRATCH_WORKTREE_PATH=""
	SCRATCH_WORKTREE_REASON=""
	return 0
}

#######################################
# Reclaim scratch worktrees left by interrupted owners (for example SIGKILL).
# Only entries locked with this helper's token, whose owner is provably gone,
# that have been idle for the stale window, and that remove cleanly qualify.
# Arguments: $1 repo path
# Returns: 0 always (best-effort; never blocks the caller)
#######################################
scratch_worktree_reap_stale() {
	local repo_path="$1"
	local stale_minutes="${AIDEVOPS_SCRATCH_WORKTREE_STALE_MINUTES:-30}"
	local line="" wt_path="" reason="" idle_match=""
	local -a scratch_paths=()
	local -a scratch_reasons=()
	local index=0
	[[ "$stale_minutes" =~ ^[0-9]+$ ]] || stale_minutes=30
	while IFS= read -r line; do
		case "$line" in
		worktree\ *) wt_path="${line#worktree }" ;;
		"locked ${_SCRATCH_WT_REASON_PREFIX} "*)
			scratch_paths+=("$wt_path")
			scratch_reasons+=("${line#locked }")
			;;
		esac
	done < <(git -C "$repo_path" worktree list --porcelain 2>/dev/null)
	while [[ "$index" -lt "${#scratch_paths[@]}" ]]; do
		wt_path="${scratch_paths[$index]}"
		reason="${scratch_reasons[$index]}"
		index=$((index + 1))
		[[ -d "$wt_path" && ! -L "$wt_path" ]] || continue
		_scratch_wt_owner_is_dead "$reason" || continue
		idle_match=$(find "$wt_path" -maxdepth 0 -mmin +"$stale_minutes" 2>/dev/null || true)
		[[ -n "$idle_match" ]] || continue
		[[ "$(_scratch_wt_current_reason "$wt_path" 2>/dev/null || true)" == "$reason" ]] || continue
		_scratch_wt_unlock_and_remove "$wt_path" "$reason" "$_SCRATCH_WT_CALLER" \
			"owner=dead recovery_path=none stale_minutes=${stale_minutes}" || true
	done
	return 0
}
