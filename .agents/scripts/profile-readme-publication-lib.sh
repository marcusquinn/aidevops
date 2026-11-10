#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Profile README Publication Library -- Update Lock and Isolated Worktree
# =============================================================================
# Serializes scheduled profile refreshes and publishes each update from a
# registered, detached linked worktree so the canonical profile checkout is
# never mutated:
#   1. Lock        -- acquire/release the profile update lock
#   2. Intent      -- publication intent and provenance marker records
#   3. Recovery    -- guarded archive, cleanup and sweep of prior worktrees
#   4. Boundary    -- canonical cleanliness check and worktree re-entry
#
# Usage: source "${SCRIPT_DIR}/profile-readme-publication-lib.sh"
#        (Sourced automatically by profile-readme-helper.sh)
#
# Dependencies:
#   - SCRIPT_DIR -- set by orchestrator; this file provides a fallback
#   - PROFILE_UPDATE_LOCK_*, PROFILE_PUBLICATION_* -- globals defined in
#     profile-readme-helper.sh (orchestrator)
#   - _resolve_profile_repo -- orchestrator
#   - portable-stat.sh, audit-worktree-removal-helper.sh (via orchestrator)
#   - shared-worktree-create.sh, worktree-helper.sh (resolved via SCRIPT_DIR)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PROFILE_README_PUBLICATION_LIB_LOADED:-}" ]] && return 0
_PROFILE_README_PUBLICATION_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback -- needed when sourced from test harnesses
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Serialize profile refreshes so scheduler overlap cannot duplicate scans/writes ---
_profile_update_lock_dir() {
	printf '%s\n' "${HOME}/.aidevops/cache/profile-readme-update.lock"
	return 0
}

# Print the lock directory's ($1) modification epoch, or zero if unavailable.
_profile_lock_mtime() {
	local lock_dir="$1"
	local modified=""
	modified=$(_file_mtime_epoch "$lock_dir" 2>/dev/null || true)
	[[ "$modified" =~ ^[0-9]+$ ]] || modified=0
	printf '%s\n' "$modified"
	return 0
}

# Print the first owner-record line for lock directory $1, if present.
_profile_lock_owner() {
	local lock_dir="$1"
	local owner_line=""
	if [[ -f "${lock_dir}/owner" ]]; then
		IFS= read -r owner_line <"${lock_dir}/owner" || true
		printf '%s\n' "$owner_line"
	fi
	return 0
}

# Acquire the refresh lock, recovering stale owners only after revalidation.
# Return 0 on acquisition, 2 for benign contention, or 1 for a setup error.
_acquire_profile_update_lock() {
	local lock_dir token now
	lock_dir=$(_profile_update_lock_dir)
	now=$(date +%s)
	token="$$.${RANDOM}.${now}.${RANDOM}"
	mkdir -p "${lock_dir%/*}" || return 1
	if mkdir "$lock_dir" 2>/dev/null; then
		local owner_tmp="${lock_dir}/owner.${token}"
		printf '%s|%s|%s\n' "$token" "$$" "$now" >"$owner_tmp" || return 1
		mv "$owner_tmp" "${lock_dir}/owner" || return 1
		PROFILE_UPDATE_LOCK_TOKEN="$token"
		return 0
	fi

	local owner_before owner_after lock_pid lock_created mtime_before mtime_after age
	owner_before=$(_profile_lock_owner "$lock_dir")
	mtime_before=$(_profile_lock_mtime "$lock_dir")
	IFS='|' read -r _ lock_pid lock_created <<<"$owner_before"
	age=$((now - mtime_before))
	if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
		echo "Profile README update already running; skipping overlapping refresh" >&2
		return 2
	fi
	if [[ -z "$owner_before" || ! "$lock_created" =~ ^[0-9]+$ ]] && [[ "$age" -lt "$PROFILE_UPDATE_LOCK_GRACE_SECONDS" ]]; then
		echo "Profile README lock is being initialized; skipping overlapping refresh" >&2
		return 2
	fi

	# Revalidate immediately before the atomic rename. A changed owner/mtime means
	# another process repaired or replaced the lock while this process inspected it.
	owner_after=$(_profile_lock_owner "$lock_dir")
	mtime_after=$(_profile_lock_mtime "$lock_dir")
	if [[ "$owner_before" != "$owner_after" || "$mtime_before" != "$mtime_after" ]]; then
		echo "Profile README lock changed during stale-owner validation" >&2
		return 2
	fi
	local stale_dir="${lock_dir}.stale.${token}"
	if ! mv "$lock_dir" "$stale_dir" 2>/dev/null; then
		echo "Profile README lock was claimed by another process" >&2
		return 1
	fi
	rm -rf "$stale_dir"
	if ! mkdir "$lock_dir" 2>/dev/null; then
		[[ -d "$lock_dir" ]] || return 1
		echo "Profile README update already running; skipping overlapping refresh" >&2
		return 2
	fi
	local owner_tmp="${lock_dir}/owner.${token}"
	printf '%s|%s|%s\n' "$token" "$$" "$now" >"$owner_tmp" || return 1
	mv "$owner_tmp" "${lock_dir}/owner" || return 1
	PROFILE_UPDATE_LOCK_TOKEN="$token"
	return 0
}

# Release only the lock matching this process's saved ownership token.
# Return 1 rather than removing a lock whose owner has changed.
_release_profile_update_lock() {
	local lock_dir
	lock_dir=$(_profile_update_lock_dir)
	if [[ -z "$PROFILE_UPDATE_LOCK_TOKEN" ]]; then
		return 0
	fi
	local owner token
	owner=$(_profile_lock_owner "$lock_dir")
	token="${owner%%|*}"
	if [[ "$token" != "$PROFILE_UPDATE_LOCK_TOKEN" ]]; then
		echo "Profile README lock owner changed; refusing non-owner release" >&2
		return 1
	fi
	rm -rf "$lock_dir"
	PROFILE_UPDATE_LOCK_TOKEN=""
	return 0
}

# Print the configured worktree helper path, defaulting to the bundled helper.
_profile_publication_worktree_helper() {
	printf '%s\n' "${AIDEVOPS_PROFILE_WORKTREE_HELPER:-${SCRIPT_DIR}/worktree-helper.sh}"
	return 0
}

# Register or unregister ($1) worktree $2 in an isolated registry subprocess.
# Registration accepts optional owner PID ($3) and session ($4); return its status.
_profile_publication_registry_update() {
	local operation="$1"
	local worktree_path="$2"
	local owner_pid="${3:-}"
	local owner_session="${4:-}"

	(
		# shellcheck source=shared-constants.sh
		source "${SCRIPT_DIR}/shared-constants.sh" || exit 1
		case "$operation" in
		register)
			register_worktree "$worktree_path" "" --task "$PROFILE_PUBLICATION_REGISTRY_TASK" \
				--session "$owner_session" --owner-pid "$owner_pid"
			;;
		unregister) unregister_worktree "$worktree_path" ;;
		*) exit 1 ;;
		esac
	)
}

# Print the durable intent path for canonical repo $1 and publication tree $2.
# Reject worktree names outside the profile-publication naming convention.
_profile_publication_intent_path() {
	local canonical_repo="$1"
	local worktree_path="$2"
	local common_dir=""
	local worktree_name=""

	common_dir=$(git -C "$canonical_repo" rev-parse --path-format=absolute --git-common-dir) || return 1
	worktree_name=$(basename "$worktree_path")
	[[ "$worktree_name" == "$(basename "$canonical_repo")-profile-readme-"* ]] || return 1
	printf '%s/aidevops-profile-publication-intents/%s.json\n' "$common_dir" "$worktree_name"
	return 0
}

# Atomically record publication tree $1 and canonical repo $2 before creation.
# Save the intent path in global state; fail rather than overwrite an intent.
_profile_write_publication_intent() {
	local worktree_path="$1"
	local canonical_repo="$2"
	local resolved_parent=""
	local resolved_worktree_path=""
	local common_dir=""
	local canonical_head=""
	local intent_path=""
	local intent_dir=""
	local intent_tmp=""
	local worktree_name=""

	resolved_parent=$(cd "${worktree_path%/*}" 2>/dev/null && pwd -P) || return 1
	worktree_name=$(basename "$worktree_path")
	resolved_worktree_path="${resolved_parent}/${worktree_name}"
	common_dir=$(git -C "$canonical_repo" rev-parse --path-format=absolute --git-common-dir) || return 1
	canonical_head=$(git -C "$canonical_repo" rev-parse HEAD) || return 1
	intent_path=$(_profile_publication_intent_path "$canonical_repo" "$resolved_worktree_path") || return 1
	intent_dir=${intent_path%/*}
	if [[ -e "$intent_dir" ]]; then
		[[ -d "$intent_dir" && ! -L "$intent_dir" ]] || return 1
	else
		mkdir -p "$intent_dir" || return 1
	fi
	chmod 700 "$intent_dir" || return 1
	[[ ! -e "$intent_path" && ! -L "$intent_path" ]] || return 1
	intent_tmp=$(mktemp "${intent_path}.XXXXXX") || return 1
	if ! jq -n \
		--arg schema "$PROFILE_PUBLICATION_INTENT_SCHEMA" \
		--arg producer "$PROFILE_PUBLICATION_REGISTRY_TASK" \
		--arg intent_id "$worktree_name" \
		--arg worktree_path "$resolved_worktree_path" \
		--arg canonical_common_dir "$common_dir" \
		--arg canonical_head "$canonical_head" \
		--arg canonical_status "${PROFILE_PUBLICATION_CANONICAL_STATUS:-}" \
		--argjson created_epoch "$(date +%s)" \
		'{schema:$schema,producer:$producer,intent_id:$intent_id,worktree_path:$worktree_path,canonical_common_dir:$canonical_common_dir,canonical_head:$canonical_head,canonical_status:$canonical_status,created_epoch:$created_epoch}' \
		>"$intent_tmp" || ! chmod 600 "$intent_tmp" || ! mv "$intent_tmp" "$intent_path"; then
		rm -f "$intent_tmp"
		return 1
	fi
	PROFILE_PUBLICATION_INTENT_PATH="$intent_path"
	return 0
}

# Remove this run's intent and clear its saved path; reject symlinks/non-files.
_profile_remove_publication_intent() {
	local intent_path="${PROFILE_PUBLICATION_INTENT_PATH:-}"
	[[ -n "$intent_path" ]] || return 0
	if [[ -e "$intent_path" || -L "$intent_path" ]]; then
		[[ -f "$intent_path" && ! -L "$intent_path" ]] || return 1
		rm -f "$intent_path" || return 1
	fi
	PROFILE_PUBLICATION_INTENT_PATH=""
	return 0
}

# Clear in-memory publication paths and snapshots without changing files.
_profile_clear_publication_state() {
	PROFILE_PUBLICATION_WORKTREE=""
	PROFILE_PUBLICATION_CANONICAL_REPO=""
	PROFILE_PUBLICATION_WORKTREE_BASE=""
	PROFILE_PUBLICATION_CANONICAL_HEAD=""
	PROFILE_PUBLICATION_CANONICAL_STATUS=""
	PROFILE_PUBLICATION_INTENT_PATH=""
	PROFILE_PUBLICATION_LIFECYCLE_PID=""
	PROFILE_PUBLICATION_LIFECYCLE_SESSION=""
	return 0
}

# GH#37591: a producer outside any declared runtime (for example launchd) left
# its tree enrolled without a registered run, so retirement refused it with
# coverage-gap. Declare this producer's shell as the owning runtime for
# creation and for its own later removal, which relinquishes the run. A runtime
# declared by the caller is kept. Sets the two PROFILE_PUBLICATION_LIFECYCLE_*
# globals; they stay empty when the caller already declared an identity.
_profile_declare_lifecycle_owner() {
	local owner_session="$1"

	PROFILE_PUBLICATION_LIFECYCLE_PID=""
	PROFILE_PUBLICATION_LIFECYCLE_SESSION=""
	if [[ -n "${AIDEVOPS_LIFECYCLE_RUNTIME_PID:-}" || -n "${AIDEVOPS_LIFECYCLE_SESSION_ID:-}" ]]; then
		return 0
	fi
	PROFILE_PUBLICATION_LIFECYCLE_PID="$$"
	PROFILE_PUBLICATION_LIFECYCLE_SESSION="$owner_session"
	return 0
}

# Create detached tree $2 of repo $1 at commit $3 with owner session $4.
# GH#37591: declare this producer as the lifecycle runtime so creation registers
# an owner run that its own cleanup can later relinquish.
_profile_create_registered_worktree() {
	local canonical_repo="$1"
	local worktree_path="$2"
	local head_commit="$3"
	local owner_session="$4"

	# shellcheck source=shared-worktree-create.sh
	source "${SCRIPT_DIR}/shared-worktree-create.sh" || return 1
	_profile_declare_lifecycle_owner "$owner_session"
	(
		if [[ -n "$PROFILE_PUBLICATION_LIFECYCLE_PID" ]]; then
			export AIDEVOPS_LIFECYCLE_RUNTIME_PID="$PROFILE_PUBLICATION_LIFECYCLE_PID"
			export AIDEVOPS_LIFECYCLE_SESSION_ID="$PROFILE_PUBLICATION_LIFECYCLE_SESSION"
		fi
		AIDEVOPS_WORKTREE_CREATE_OWNER_PID="$$" \
			AIDEVOPS_WORKTREE_CREATE_SESSION="$owner_session" \
			AIDEVOPS_WORKTREE_CREATE_TASK="$PROFILE_PUBLICATION_REGISTRY_TASK" \
			worktree_create_registered "$canonical_repo" "$worktree_path" "$head_commit" --detach >/dev/null
	)
	return $?
}

# Run the worktree helper's `remove` for $1 in canonical repo $2 under the
# lifecycle identity this producer declared at creation (if any).
_profile_publication_helper_remove() {
	local worktree_path="$1"
	local canonical_repo="$2"
	local worktree_helper=""

	worktree_helper=$(_profile_publication_worktree_helper)
	if [[ -n "${PROFILE_PUBLICATION_LIFECYCLE_PID:-}" && "$worktree_path" == "${PROFILE_PUBLICATION_WORKTREE:-}" ]]; then
		(cd "$canonical_repo" &&
			AIDEVOPS_LIFECYCLE_RUNTIME_PID="$PROFILE_PUBLICATION_LIFECYCLE_PID" \
				AIDEVOPS_LIFECYCLE_SESSION_ID="$PROFILE_PUBLICATION_LIFECYCLE_SESSION" \
				"$worktree_helper" remove "$worktree_path" >/dev/null)
		return $?
	fi
	(cd "$canonical_repo" && "$worktree_helper" remove "$worktree_path" >/dev/null 2>&1)
	return $?
}

# GH#37591: retire an earlier tree enrolled without any registered run through
# the registry's confirmed enrolled-only path. Callers must already have proved
# the tree published, clean and unowned; the registry still archives first,
# verifies and refuses a tree that has bound runs or a creation receipt.
_profile_retire_enrolled_only_worktree() {
	local worktree_path="$1"
	local state_dir=""
	local python=""
	local entry="${SCRIPT_DIR}/../worker-lifecycle/worker-registry.py"
	local archive_root="${AIDEVOPS_WORKTREE_ARCHIVE_ROOT:-${HOME}/.aidevops/recovery/archives}"

	[[ "${AIDEVOPS_LIFECYCLE_DISABLED:-0}" != 1 && -f "$entry" ]] || return 1
	python=$(type -P python3) || return 1
	state_dir=$( (
		# shellcheck source=worker-lifecycle-state.sh
		source "${SCRIPT_DIR}/worker-lifecycle-state.sh" >/dev/null 2>&1 || exit 1
		worker_lifecycle_state_dir 2>/dev/null
	) ) || return 1
	[[ -n "$state_dir" && -d "$state_dir" ]] || return 1
	"$python" -E -s -B "$entry" --state-dir "$state_dir" retire-enrolled-only \
		--repos-config "${HOME}/.config/aidevops/repos.json" \
		--output-root "$archive_root" --path "$worktree_path" --confirm >/dev/null 2>&1
	return $?
}

# Bounded retry for read-only git probes that can transiently time out under
# canonical Git guards. Args: $1=repo, then git arguments. Prints stdout.
_profile_git_probe() {
	local repo="$1"
	shift
	local attempts="${AIDEVOPS_PROFILE_GIT_PROBE_ATTEMPTS:-3}"
	local attempt=0
	local output=""

	[[ "$attempts" =~ ^[1-9]$ ]] || attempts=3
	while [[ "$attempt" -lt "$attempts" ]]; do
		if output=$(git -C "$repo" "$@" 2>/dev/null) && [[ -n "$output" ]]; then
			printf '%s\n' "$output"
			return 0
		fi
		attempt=$((attempt + 1))
		[[ "$attempt" -ge "$attempts" ]] || sleep 1
	done
	return 1
}

# Atomically write a private provenance marker for tree $1 and canonical repo $2.
# Return non-zero if repository resolution or marker publication fails.
_profile_write_publication_marker() {
	local worktree_path="$1"
	local canonical_repo="$2"
	local resolved_worktree_path=""
	local git_dir=""
	local common_dir=""
	local canonical_head=""
	local marker_path=""
	local marker_tmp=""

	resolved_worktree_path=$(cd "$worktree_path" 2>/dev/null && pwd -P) || return 1
	git_dir=$(_profile_git_probe "$resolved_worktree_path" rev-parse --path-format=absolute --git-dir) || return 1
	common_dir=$(_profile_git_probe "$canonical_repo" rev-parse --path-format=absolute --git-common-dir) || return 1
	# Prefer the head captured at run start so a slow canonical probe cannot
	# leave an intent without a marker; fall back to a bounded probe.
	canonical_head="${PROFILE_PUBLICATION_CANONICAL_HEAD:-}"
	if [[ -z "$canonical_head" ]]; then
		canonical_head=$(_profile_git_probe "$canonical_repo" rev-parse HEAD) || return 1
	fi
	marker_path="${git_dir}/aidevops-profile-publication.json"
	marker_tmp="${marker_path}.$$"
	jq -n \
		--arg schema "aidevops-profile-publication/v1" \
		--arg producer "$PROFILE_PUBLICATION_REGISTRY_TASK" \
		--arg worktree_path "$resolved_worktree_path" \
		--arg canonical_common_dir "$common_dir" \
		--arg canonical_head "$canonical_head" \
		--argjson created_epoch "$(date +%s)" \
		'{schema:$schema,producer:$producer,worktree_path:$worktree_path,canonical_common_dir:$canonical_common_dir,canonical_head:$canonical_head,created_epoch:$created_epoch}' \
		>"$marker_tmp" || {
		rm -f "$marker_tmp"
		return 1
	}
	chmod 600 "$marker_tmp" || {
		rm -f "$marker_tmp"
		return 1
	}
	mv "$marker_tmp" "$marker_path" || {
		rm -f "$marker_tmp"
		return 1
	}
	return 0
}

# Return 0 only when the registry finds no other active owner of worktree $1.
# Query in a subprocess to avoid changing the publication helper's globals.
_profile_publication_worktree_has_no_active_owner() {
	local worktree_path="$1"
	local cleanup_owner_pid="$$"
	local owner_state=""

	# Source the registry in a subprocess so its shared command helpers cannot
	# alter this long-running publication helper's globals.
	owner_state=$( (
		# shellcheck source=shared-constants.sh
		source "${SCRIPT_DIR}/shared-constants.sh" || exit 1
		if is_worktree_owned_by_others_for_pid "$worktree_path" "$cleanup_owner_pid"; then
			printf '%s\n' "owned"
		else
			printf '%s\n' "clear"
		fi
	) ) || return 1
	[[ "$owner_state" == "clear" ]] || return 1
	return 0
}

# Producer-owned shape: detached, named for this canonical repo, directly under
# the worktree base and sharing the canonical common dir.
_profile_publication_worktree_shape_is_safe() {
	local worktree_path="$1"
	local canonical_repo="$2"
	local worktree_base="$3"
	local canonical_common_dir=""
	local worktree_common_dir=""
	local worktree_parent=""
	local worktree_basename=""

	[[ -n "$canonical_repo" && -n "$worktree_base" && -d "$worktree_path" && ! -L "$worktree_path" ]] || return 1
	worktree_parent=$(cd "${worktree_path%/*}" 2>/dev/null && pwd -P) || return 1
	[[ "$worktree_parent" == "$worktree_base" ]] || return 1
	worktree_basename="${worktree_path##*/}"
	[[ "$worktree_basename" == "$(basename "$canonical_repo")-profile-readme-"* ]] || return 1
	git -C "$worktree_path" symbolic-ref -q HEAD >/dev/null 2>&1 && return 1
	canonical_common_dir=$(git -C "$canonical_repo" rev-parse --git-common-dir 2>/dev/null) || return 1
	worktree_common_dir=$(git -C "$worktree_path" rev-parse --git-common-dir 2>/dev/null) || return 1
	case "$canonical_common_dir" in
	/*) ;;
	*) canonical_common_dir=$(cd "$canonical_repo/$canonical_common_dir" 2>/dev/null && pwd -P) || return 1 ;;
	esac
	case "$worktree_common_dir" in
	/*) ;;
	*) worktree_common_dir=$(cd "$worktree_path/$worktree_common_dir" 2>/dev/null && pwd -P) || return 1 ;;
	esac
	[[ "$canonical_common_dir" == "$worktree_common_dir" ]] || return 1
	return 0
}

# Allow recovery of current tree $1 only with safe shape, unchanged canonical
# HEAD/status snapshots and no other active owner; return 1 on any mismatch.
_profile_publication_worktree_recovery_is_safe() {
	local worktree_path="$1"
	local canonical_head=""
	local canonical_status=""

	[[ -n "$worktree_path" && "$worktree_path" == "${PROFILE_PUBLICATION_WORKTREE:-}" ]] || return 1
	[[ -n "${PROFILE_PUBLICATION_CANONICAL_HEAD:-}" ]] || return 1
	_profile_publication_worktree_shape_is_safe "$worktree_path" \
		"${PROFILE_PUBLICATION_CANONICAL_REPO:-}" "${PROFILE_PUBLICATION_WORKTREE_BASE:-}" || return 1
	canonical_head=$(git -C "$PROFILE_PUBLICATION_CANONICAL_REPO" rev-parse HEAD 2>/dev/null) || return 1
	[[ "$canonical_head" == "$PROFILE_PUBLICATION_CANONICAL_HEAD" ]] || return 1
	canonical_status=$(git -C "$PROFILE_PUBLICATION_CANONICAL_REPO" status --porcelain --untracked-files=all) || return 1
	# Publication already permits pre-existing untracked files in the canonical
	# mirror. Preserve its captured state instead of requiring unrelated cleanup.
	[[ "$canonical_status" == "$PROFILE_PUBLICATION_CANONICAL_STATUS" ]] || return 1
	_profile_publication_worktree_has_no_active_owner "$worktree_path" || return 1
	return 0
}

# GH#36543: an earlier run's tree has no current-run canonical snapshot to
# compare, so it qualifies only when it holds nothing to preserve: clean
# including untracked files, HEAD already published and no live owner.
_profile_publication_prior_worktree_is_safe() {
	local worktree_path="$1"
	local canonical_repo="$2"
	local worktree_base="$3"
	local worktree_status=""
	local worktree_head=""
	local default_branch=""

	[[ -n "$worktree_path" && "$worktree_path" != "${PROFILE_PUBLICATION_WORKTREE:-}" ]] || return 1
	_profile_publication_worktree_shape_is_safe "$worktree_path" "$canonical_repo" "$worktree_base" || return 1
	worktree_status=$(git -C "$worktree_path" status --porcelain --untracked-files=all 2>/dev/null) || return 1
	[[ -z "$worktree_status" ]] || return 1
	worktree_head=$(git -C "$worktree_path" rev-parse --verify -q HEAD 2>/dev/null) || return 1
	default_branch=$(_profile_default_branch "$canonical_repo")
	git -C "$canonical_repo" merge-base --is-ancestor "$worktree_head" \
		"refs/remotes/origin/${default_branch}" 2>/dev/null || return 1
	_profile_publication_worktree_has_no_active_owner "$worktree_path" || return 1
	return 0
}

# Args: $1=worktree, then an optional safety predicate and its extra arguments
# (default: the current-run predicate). The predicate runs before capture and
# again immediately before guarded removal.
_archive_and_remove_profile_publication_worktree() {
	local worktree_path="$1"
	shift
	local archive_path=""
	local caller="profile-readme-helper.sh"
	local context="recovery_path=profile-publication-archive profile_scratch=true"
	local safety_check="${1:-_profile_publication_worktree_recovery_is_safe}"
	[[ "$#" -eq 0 ]] || shift

	"$safety_check" "$worktree_path" "$@" || return 1
	printf '%s\n' 'Profile publication recovery: capturing completed worktree' >&2
	archive_worktree_path_recoverably "$worktree_path" "$caller" "$context" || return 1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	[[ -n "$archive_path" ]] || return 1
	printf '%s\n' 'Profile publication recovery: checking guarded removal' >&2
	# Recheck after compact verification so a changed canonical checkout or newly claimed
	# worktree remains recoverable instead of being removed.
	"$safety_check" "$worktree_path" "$@" || return 1
	remove_archived_worktree_path "$worktree_path" "$archive_path" "$caller" \
		"profile-publication" "$context" "true" "true" || return 1
	log_worktree_removal_event "$_WTAR_REMOVED" "$caller" "$worktree_path" \
		"profile-publication" "recoverable" "$context"
	return 0
}

# Retire the current publication tree through guarded removal or archival.
# Defer inside managed runs; retain recovery state if tree retirement fails (return 1).
# Registry and intent cleanup errors are ignored; state is cleared on success.
_cleanup_profile_publication_worktree() {
	if [[ -z "$PROFILE_PUBLICATION_WORKTREE" ]]; then
		return 0
	fi
	# The producer and all its descendants must finish before archival/removal.
	# The common runner seals the invocation and calls cleanup-managed outside it.
	if [[ "${AIDEVOPS_MANAGED_WORKTREE_RUN:-0}" == "1" ]]; then
		return 0
	fi
	local worktree_path="$PROFILE_PUBLICATION_WORKTREE"
	local canonical_repo="$PROFILE_PUBLICATION_CANONICAL_REPO"
	local worktree_helper=""
	worktree_helper=$(_profile_publication_worktree_helper)
	if [[ -z "$canonical_repo" || ! -d "$canonical_repo" || ! -x "$worktree_helper" ]]; then
		echo "Warning: profile publication worktree cleanup is unavailable: $worktree_path" >&2
		return 1
	fi
	if _profile_publication_helper_remove "$worktree_path" "$canonical_repo"; then
		_profile_publication_registry_update unregister "$worktree_path" || true
		_profile_remove_publication_intent || true
		_profile_clear_publication_state
		return 0
	fi
	if [[ -e "$worktree_path" ]] &&
		! _archive_and_remove_profile_publication_worktree "$worktree_path"; then
		echo "Warning: profile publication worktree cleanup failed: $worktree_path" >&2
		return 1
	fi
	_profile_publication_registry_update unregister "$worktree_path" || true
	_profile_remove_publication_intent || true
	_profile_clear_publication_state
	return 0
}

# Args: $1=raw value, $2=default, $3=minimum, $4=maximum (decimal integers).
_profile_publication_sweep_setting() {
	local value="${1//[!0-9]/}"
	local default_value="$2"
	local minimum="$3"
	local maximum="$4"

	if [[ -z "$value" || ${#value} -gt 9 ]]; then
		printf '%s\n' "$default_value"
		return 0
	fi
	value=$((10#$value))
	if [[ "$value" -lt "$minimum" || "$value" -gt "$maximum" ]]; then
		value="$default_value"
	fi
	printf '%s\n' "$value"
	return 0
}

# Retire one prior tree through the same sequence as the current run: guarded
# worktree-helper removal first, then recoverable archive and guarded removal.
_profile_retire_prior_publication_worktree() {
	local worktree_path="$1"
	local canonical_repo="$2"
	local worktree_base="$3"
	local intent_path="$4"
	local worktree_helper=""

	worktree_helper=$(_profile_publication_worktree_helper)
	if [[ -x "$worktree_helper" ]] &&
		_profile_publication_helper_remove "$worktree_path" "$canonical_repo"; then
		:
	elif [[ -d "$worktree_path" ]] &&
		_profile_publication_prior_worktree_is_safe "$worktree_path" "$canonical_repo" "$worktree_base" &&
		_profile_retire_enrolled_only_worktree "$worktree_path"; then
		:
	elif ! _archive_and_remove_profile_publication_worktree "$worktree_path" \
		_profile_publication_prior_worktree_is_safe "$canonical_repo" "$worktree_base"; then
		return 1
	fi
	[[ ! -e "$worktree_path" ]] || return 1
	_profile_publication_registry_update unregister "$worktree_path" >/dev/null 2>&1 || true
	if [[ -f "$intent_path" && ! -L "$intent_path" ]]; then
		rm -f "$intent_path" || true
	fi
	return 0
}

# Print intent paths starting after the persisted cursor name, wrapping around.
# Args: $1=intent dir, $2=cursor file.
_profile_sweep_ordered_intents() {
	local intent_dir="$1"
	local cursor_file="$2"
	local cursor=""
	local candidate=""
	local all=()
	local tail_part=()
	local head_part=()

	if [[ -f "$cursor_file" && ! -L "$cursor_file" ]]; then
		cursor=$(head -n 1 "$cursor_file" 2>/dev/null || true)
	fi
	for candidate in "$intent_dir"/*.json; do
		all+=("$candidate")
		# The cursor is a filename boundary even if retirement deleted its file.
		if [[ -n "$cursor" && "${candidate##*/}" > "$cursor" ]]; then
			tail_part+=("$candidate")
		else
			head_part+=("$candidate")
		fi
	done
	if [[ -n "$cursor" ]]; then
		printf '%s\n' ${tail_part[@]+"${tail_part[@]}"} ${head_part[@]+"${head_part[@]}"}
	else
		printf '%s\n' "${all[@]}"
	fi
	return 0
}

# GH#36543: a failed retirement used to leak its tree permanently because only
# the current run's tree was ever cleaned. Before creating a new tree, retry
# earlier ones named by the producer's durable intents. Never blocks publication.
_profile_sweep_prior_publication_worktrees() {
	local canonical_repo="$1"
	local worktree_base="$2"
	local common_dir=""
	local intent_dir=""
	local intent_path=""
	local intent_values=""
	local intent_id=""
	local worktree_path=""
	local intent_common_dir=""
	local created_epoch=0
	local now_epoch=0
	local min_age=0
	local cap=0
	local attempts=0
	local retired=0
	local preserved=0
	local budget=0
	local deadline=0
	local examined=0
	local max_examined=0
	local cursor_file=""
	local last_name=""
	local ordered=()
	local candidate=""

	common_dir=$(git -C "$canonical_repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
	intent_dir="${common_dir}/aidevops-profile-publication-intents"
	[[ -d "$intent_dir" && ! -L "$intent_dir" ]] || return 0
	# The age floor keeps a just-finished managed run's own cleanup-managed
	# callback from racing this sweep; hourly runs still clear the previous tree.
	min_age=$(_profile_publication_sweep_setting "${AIDEVOPS_PROFILE_PUBLICATION_SWEEP_MIN_AGE_SECS:-}" 1800 0 604800)
	cap=$(_profile_publication_sweep_setting "${AIDEVOPS_PROFILE_PUBLICATION_SWEEP_CAP:-}" 10 1 100)
	# Bound recovery by time and by examined trees so a large backlog never holds
	# the overlap lock or starves the refresh; the remainder waits for next run.
	budget=$(_profile_publication_sweep_setting "${AIDEVOPS_PROFILE_PUBLICATION_SWEEP_BUDGET_SECS:-}" 120 1 3600)
	max_examined=$((cap * 3))
	now_epoch=$(date +%s)
	deadline=$((now_epoch + budget))
	cursor_file="${common_dir}/aidevops-profile-publication-sweep-cursor"
	while IFS= read -r candidate; do
		ordered+=("$candidate")
	done < <(_profile_sweep_ordered_intents "$intent_dir" "$cursor_file")
	for intent_path in "${ordered[@]}"; do
		[[ -f "$intent_path" && ! -L "$intent_path" ]] || continue
		if [[ "$examined" -ge "$max_examined" || "$(date +%s)" -ge "$deadline" ]]; then
			printf 'Profile publication sweep: bound reached (examined=%s budget=%ss); remaining trees deferred\n' \
				"$examined" "$budget" >&2
			break
		fi
		intent_values=$(jq -er --arg producer "$PROFILE_PUBLICATION_REGISTRY_TASK" \
			--arg schema "$PROFILE_PUBLICATION_INTENT_SCHEMA" '
			select(.schema == $schema)
			| select(.producer == $producer)
			| select(.created_epoch | numbers | . > 0 and floor == .)
			| select((.intent_id | strings | length > 0) and (.worktree_path | strings | length > 0))
			| [.intent_id, .worktree_path, .canonical_common_dir, .created_epoch] | @tsv
		' "$intent_path" 2>/dev/null) || continue
		IFS=$'\t' read -r intent_id worktree_path intent_common_dir created_epoch <<<"$intent_values"
		[[ "$intent_id" == "$(basename "$intent_path" .json)" &&
			"$intent_common_dir" == "$common_dir" &&
			"$worktree_path" == "${worktree_base}/${intent_id}" &&
			"$worktree_path" != "${PROFILE_PUBLICATION_WORKTREE:-}" ]] || continue
		# Intents whose tree is gone stay with Pulse's dated stale-intent cleanup.
		[[ -d "$worktree_path" ]] || continue
		[[ "$now_epoch" -ge "$created_epoch" && $((now_epoch - created_epoch)) -ge "$min_age" ]] || continue
		examined=$((examined + 1))
		last_name=$(basename "$intent_path")
		if [[ "$attempts" -ge "$cap" ]] ||
			! _profile_publication_prior_worktree_is_safe "$worktree_path" "$canonical_repo" "$worktree_base"; then
			preserved=$((preserved + 1))
			continue
		fi
		attempts=$((attempts + 1))
		if _profile_retire_prior_publication_worktree "$worktree_path" "$canonical_repo" \
			"$worktree_base" "$intent_path"; then
			retired=$((retired + 1))
		else
			preserved=$((preserved + 1))
		fi
	done
	if [[ -n "$last_name" && ! -L "$cursor_file" ]]; then
		printf '%s\n' "$last_name" >"$cursor_file" 2>/dev/null || true
	fi
	if [[ "$retired" -gt 0 || "$preserved" -gt 0 ]]; then
		printf 'Profile publication sweep: retired %s earlier worktree(s); %s preserved for guarded recovery\n' \
			"$retired" "$preserved" >&2
	fi
	return 0
}

# Best-effort EXIT cleanup: retire the publication tree, then release the lock.
_profile_update_exit_cleanup() {
	_cleanup_profile_publication_worktree || true
	_release_profile_update_lock || true
	return 0
}

# Reuse an inherited lock or acquire one and install EXIT cleanup.
# Propagate acquisition status (2 for benign contention, 1 for setup failure).
_ensure_profile_update_lock() {
	if [[ "${AIDEVOPS_PROFILE_UPDATE_LOCK_HELD:-0}" == "1" ]]; then
		return 0
	fi
	# 2 means benign contention, 1 remains an actual lock/setup error.
	_acquire_profile_update_lock || return $?
	export AIDEVOPS_PROFILE_UPDATE_LOCK_HELD=1
	trap _profile_update_exit_cleanup EXIT
	return 0
}

# --- Resolve the profile repository's push branch ---
_profile_default_branch() {
	local profile_repo="$1"
	local default_branch=""
	default_branch=$(git -C "$profile_repo" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
	if [[ -z "$default_branch" ]]; then
		default_branch=$(git -C "$profile_repo" branch --show-current 2>/dev/null || true)
	fi
	printf '%s\n' "${default_branch:-main}"
	return 0
}

# Return 0 only if canonical repo $1 has no tracked changes or unpushed commits.
# Untracked files are permitted; unverifiable state fails closed.
_profile_assert_canonical_clean() {
	local canonical_repo="$1"
	local status_output=""
	if ! status_output=$(git -C "$canonical_repo" status --porcelain --untracked-files=no); then
		echo "Error: could not verify canonical profile checkout state" >&2
		return 1
	fi
	if [[ -n "$status_output" ]]; then
		echo "Error: canonical profile checkout has tracked changes; refusing automated publication" >&2
		return 1
	fi
	local default_branch=""
	local ahead_count=""
	default_branch=$(_profile_default_branch "$canonical_repo")
	if ! ahead_count=$(git -C "$canonical_repo" rev-list --count "origin/${default_branch}..HEAD" 2>/dev/null); then
		echo "Error: could not verify canonical profile branch state" >&2
		return 1
	fi
	if [[ "$ahead_count" -gt 0 ]]; then
		echo "Error: canonical profile checkout has unpushed commits; refusing automated publication" >&2
		return 1
	fi
	return 0
}

# Run publication command $1 (remaining args forwarded) in a detached worktree.
# Track provenance and cleanup, verify the canonical snapshot is unchanged,
# and return the inner command's status unless setup or safety checks fail.
_profile_run_in_worktree() {
	local publication_command="$1"
	shift
	local canonical_repo=""
	canonical_repo=$(_resolve_profile_repo) || return 1
	_profile_assert_canonical_clean "$canonical_repo" || return 1

	local worktree_helper=""
	worktree_helper=$(_profile_publication_worktree_helper)
	if [[ ! -x "$worktree_helper" ]]; then
		echo "Error: worktree-helper.sh is required for canonical-safe profile publication" >&2
		return 1
	fi

	local canonical_head_before=""
	local canonical_status_before=""
	canonical_head_before=$(git -C "$canonical_repo" rev-parse HEAD) || return 1
	canonical_status_before=$(git -C "$canonical_repo" status --porcelain --untracked-files=all) || return 1

	local worktree_base="${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}"
	local worktree_name=""
	worktree_name="$(basename "$canonical_repo")-profile-readme-$(date -u +%Y%m%d%H%M%S)-$$-${RANDOM}"
	mkdir -p "$worktree_base" || return 1
	PROFILE_PUBLICATION_WORKTREE_BASE=$(cd "$worktree_base" 2>/dev/null && pwd -P) || return 1
	_profile_sweep_prior_publication_worktrees "$canonical_repo" "$PROFILE_PUBLICATION_WORKTREE_BASE" || true
	local worktree_path="${PROFILE_PUBLICATION_WORKTREE_BASE}/${worktree_name}"
	PROFILE_PUBLICATION_WORKTREE="$worktree_path"
	PROFILE_PUBLICATION_CANONICAL_REPO="$canonical_repo"
	PROFILE_PUBLICATION_CANONICAL_HEAD="$canonical_head_before"
	PROFILE_PUBLICATION_CANONICAL_STATUS="$canonical_status_before"
	if ! _profile_write_publication_intent "$worktree_path" "$canonical_repo"; then
		echo "Error: could not write profile publication intent" >&2
		_profile_clear_publication_state
		return 1
	fi
	local owner_session="profile-readme-${PROFILE_UPDATE_LOCK_TOKEN:-$$}"
	if ! _profile_create_registered_worktree "$canonical_repo" "$worktree_path" \
		"$canonical_head_before" "$owner_session"; then
		echo "Error: could not create profile publication worktree" >&2
		# A failed registration may leave a tree. Try guarded cleanup now so
		# it is not retained unenrolled; otherwise keep its intent for recovery.
		if [[ -e "$worktree_path" ]]; then
			_cleanup_profile_publication_worktree || true
		fi
		if [[ ! -e "$worktree_path" ]]; then
			_profile_remove_publication_intent || true
			_profile_clear_publication_state
		fi
		return 1
	fi
	if ! _profile_write_publication_marker "$worktree_path" "$canonical_repo"; then
		echo "Error: could not write profile publication provenance marker" >&2
		_cleanup_profile_publication_worktree || true
		return 1
	fi
	local default_branch=""
	default_branch=$(_profile_default_branch "$canonical_repo")
	if ! git -C "$worktree_path" fetch --quiet origin "$default_branch" ||
		! git -C "$worktree_path" reset --hard FETCH_HEAD >/dev/null; then
		echo "Error: could not prepare profile publication worktree from origin/${default_branch}" >&2
		_cleanup_profile_publication_worktree || true
		return 1
	fi

	local inner_status=0
	if AIDEVOPS_PROFILE_PUBLICATION_WORKTREE=1 \
		AIDEVOPS_PROFILE_REPO_OVERRIDE="$worktree_path" \
		AIDEVOPS_PROFILE_CANONICAL_REPO="$canonical_repo" \
		AIDEVOPS_PROFILE_UPDATE_LOCK_HELD=1 \
		bash "${SCRIPT_DIR}/profile-readme-helper.sh" "$publication_command" "$@"; then
		inner_status=0
	else
		inner_status=$?
	fi

	if ! _cleanup_profile_publication_worktree; then
		echo "Error: profile publication worktree remains for guarded recovery: $worktree_path" >&2
		return 1
	fi

	local canonical_head_after=""
	local canonical_status_after=""
	canonical_head_after=$(git -C "$canonical_repo" rev-parse HEAD) || return 1
	canonical_status_after=$(git -C "$canonical_repo" status --porcelain --untracked-files=all) || return 1
	if [[ "$canonical_head_after" != "$canonical_head_before" ||
		"$canonical_status_after" != "$canonical_status_before" ]]; then
		echo "Error: canonical profile checkout changed during isolated publication" >&2
		return 1
	fi
	return "$inner_status"
}
