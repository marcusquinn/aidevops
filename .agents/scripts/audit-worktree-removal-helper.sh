#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# audit-worktree-removal-helper.sh — Canonical audit logger for worktree-removal events (t2976).
#
# Every worktree removal event — taken or skipped — should leave exactly one structured
# log line in cleanup_worktrees.log. This helper centralises that write so callers
# never need to construct the format themselves.
#
# Usage (source this file, then call the function):
#   # shellcheck source=audit-worktree-removal-helper.sh
#   source "${SCRIPT_DIR}/audit-worktree-removal-helper.sh"
#   log_worktree_removal_event "$_WTAR_REMOVED" "worktree-helper.sh" "/path/to/wt" "branch-merged" "permanent"
#   log_worktree_removal_event "$_WTAR_SKIPPED" "pulse-cleanup.sh" "/path/to/wt" "owned-skip" "skipped" \
#     "branch=feature/gh123 issue=123 owner_guard=active pr_state=none recovery_path=none"
#
# Event types (use the constants below to avoid repeated literal violations):
#   _WTAR_REMOVED          "removed"        — worktree was actually removed
#   _WTAR_SKIPPED          "skipped"        — removal was blocked
#   _WTAR_FIXTURE_REMOVED  "fixture-removed" — removed during test teardown
#
# Reason values (non-exhaustive — free-form, kept short):
#   branch-merged     — PR/branch has merged; worktree no longer needed
#   age-eligible      — orphan exceeded age threshold (crashed/abandoned worker)
#   manual            — operator called remove directly
#   owned-skip        — owned by another active session (registry or pgrep match)
#   grace-period      — within WORKTREE_CLEAN_GRACE_HOURS, not safe to remove yet
#   open-pr           — branch has an open PR; active work in progress
#   zero-commit-dirty — 0 commits ahead + dirty files = in-progress, not merged
#   empty-branch      — 0 commits ahead = pre-work branch (t3545/GH#22606)
#   active-claim      — interactive-session claim stamp present (t2916/GH#21074)
#   current-worktree  — caller is inside this worktree (GH#22154)
#   dirty-skip        — uncommitted changes present, --force-merged not set
#   fixture           — test fixture teardown path
#
# Environment:
#   AIDEVOPS_CLEANUP_LOG — override log file path (default: ~/.aidevops/logs/cleanup_worktrees.log)
#   AIDEVOPS_WORKTREE_TRASH_ROOT — override recoverable archive root
#   AIDEVOPS_ORPHAN_TRASH_ROOT — legacy fallback archive-root override
#
# Compatibility: bash 3.2+ (macOS default). Uses printf, not echo -e.
# Fail-open: log write failures are silently swallowed — callers must not depend on
# this helper succeeding for their own logic.

# Guard against double-sourcing
[[ "${_AUDIT_WORKTREE_REMOVAL_HELPER_LOADED:-}" == "1" ]] && return 0
_AUDIT_WORKTREE_REMOVAL_HELPER_LOADED=1

# =============================================================================
# Event-type constants — callers should use these instead of inline string
# literals to stay below the pre-commit repeated-literal ratchet threshold.
# =============================================================================
_WTAR_REMOVED="removed"
_WTAR_SKIPPED="skipped"
_WTAR_FIXTURE_REMOVED="fixture-removed"
_WTAR_MODE_SKIPPED="skipped"
_WTAR_BOOL_TRUE="true"
_WT_STATE_COMPLETE="complete"
_WT_STATE_UNAVAILABLE="unavailable"
_WT_CWD_VISIBILITY_COMPLETE="$_WT_STATE_COMPLETE"
_WT_CWD_VISIBILITY_DEGRADED="degraded"
_WT_CWD_VISIBILITY_UNUSABLE="unusable"
_WT_CWD_CAPTURE_DEGRADED_RC=2
_WT_CWD_MATCH_UNUSABLE_RC=3
_WT_CWD_REASON_DEGRADED="cwd-visibility-degraded"
_WT_CWD_REASON_UNUSABLE="cwd-visibility-unusable"
_WT_GIT_STATE_CLEAR="clear"
_WT_GIT_STATE_LOCKED="locked"
_WT_GIT_STATE_NOT_WORKTREE="not-worktree"
_WT_GIT_STATE_UNREADABLE="unreadable"
_WT_GIT_REASON_LOCKED="git-worktree-locked"
_WT_GIT_REASON_UNREADABLE="git-metadata-unreadable"
_WT_GIT_REASON_IDENTITY_CHANGED="git-worktree-identity-changed"
_WT_GIT_REASON_REMOVE_FAILED="git-worktree-remove-failed"
_WT_GIT_STATUS_FIELD_PREFIX="aidevops-git-status "
_WT_RECOVERY_FORMAT_V1="aidevops-worktree-recovery-v1"
_WT_RECOVERY_FORMAT_V2="aidevops-worktree-recovery-v2"
_WT_RECOVERY_FORMAT="$_WT_RECOVERY_FORMAT_V2"
_WT_RECOVERY_DIR_NAME=".aidevops-worktree-recovery"
_WT_RECOVERY_COMPLETE_MARKER="archive-complete"
_WT_RECOVERY_STORAGE_OWNER="framework"
_WT_RECOVERY_STORAGE_OWNER_JOINT="joint"
_WT_RECOVERY_ROOT_UNAVAILABLE="$_WT_STATE_UNAVAILABLE"
_WT_PLATFORM_DARWIN="Darwin"
_WT_RECOVERY_BRANCH_DETACHED="detached"
_WT_RECOVERY_OUTCOME_PENDING="pending"
_WT_RECOVERY_OUTCOME_REMOVED="removed"
_WT_RECOVERY_PRODUCER_LOCK_NAME=".aidevops-worktree-recovery.lock"
_WT_RECOVERY_LOCK_STATE_LIVE="live"
_WT_RECOVERY_LOCK_STATE_STALE="stale"
_WT_RECOVERY_LOCK_STATE_UNCERTAIN="uncertain"
WORKTREE_RECOVERABLE_ARCHIVE_PATH=""
WORKTREE_RECOVERY_PRODUCER_LOCK_PATH=""
WORKTREE_RECOVERY_PRODUCER_LOCK_TOKEN=""
WORKTREE_RECOVERY_PRODUCER_LOCK_LSTART=""

_WT_ID_REAL_GIT=""
_WT_ID_SOURCE_REAL=""
_WT_ID_SOURCE_INODE=""
_WT_ID_ADMIN_REAL=""
_WT_ID_ADMIN_INODE=""
_WT_ID_COMMON_REAL=""
_WT_ID_HEAD=""
_WT_ID_BRANCH=""

# Recoverable-archive functions live in a sibling library (GH#36924).
_wtar_lib_path="${BASH_SOURCE[0]%/*}"
[[ "$_wtar_lib_path" == "${BASH_SOURCE[0]}" ]] && _wtar_lib_path="."
if ! _WTAR_LIB_DIR="$(cd "$_wtar_lib_path" && pwd)"; then
	printf '[audit-worktree-removal-helper] ERROR: cannot resolve library directory: %s\n' \
		"$_wtar_lib_path" >&2
	unset _wtar_lib_path _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED
	return 1
fi
unset _wtar_lib_path
# shellcheck source=./audit-worktree-removal-recovery.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime
if ! source "${_WTAR_LIB_DIR}/audit-worktree-removal-recovery.sh"; then
	printf '[audit-worktree-removal-helper] ERROR: cannot source recovery library: %s\n' \
		"${_WTAR_LIB_DIR}/audit-worktree-removal-recovery.sh" >&2
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED _AUDIT_WORKTREE_REMOVAL_RECOVERY_LIB_LOADED
	return 1
fi


# =============================================================================
# log_worktree_removal_event — write one structured log line per event
#
# Args:
#   $1  event_type  — use $_WTAR_REMOVED / $_WTAR_SKIPPED / $_WTAR_FIXTURE_REMOVED
#   $2  caller      — basename of the calling script (e.g. "worktree-helper.sh")
#   $3  wt_path     — absolute path to the worktree
#   $4  reason      — short reason string (see Reason values above)
#   $5  mode        — optional removal mode: trash, permanent, fixture, skipped
#   $6  context     — optional safe key=value context for guard predicates/recovery
#
# Output format (append to AIDEVOPS_CLEANUP_LOG):
#   [2026-04-27T11:22:33Z] [worktree-helper.sh] worktree-removed: /path/to/wt — branch-merged — mode=permanent
#   [2026-05-07T12:00:00Z] [pulse-cleanup.sh] worktree-skipped: /path/to/wt — owned-skip — mode=skipped — branch=feature/gh123 issue=123 owner_guard=active
#
# Returns 0 always (fail-open).
# =============================================================================
log_worktree_removal_event() {
	local event_type="$1"
	local caller="$2"
	local wt_path="$3"
	local reason="$4"
	local mode="${5:-unknown}"
	local context="${6:-}"
	local log_file="${AIDEVOPS_CLEANUP_LOG:-${HOME}/.aidevops/logs/cleanup_worktrees.log}"

	# Ensure log directory exists (silent; don't fail callers on permission errors)
	mkdir -p "$(dirname "$log_file")" 2>/dev/null || true

	# Write one structured line and swallow any write error (fail-open)
	if [[ -n "$context" ]]; then
		printf '[%s] [%s] worktree-%s: %s — %s — mode=%s — %s\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			"$caller" \
			"$event_type" \
			"$wt_path" \
			"$reason" \
			"$mode" \
			"$context" \
			>>"$log_file" 2>/dev/null || true
	else
		printf '[%s] [%s] worktree-%s: %s — %s — mode=%s\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			"$caller" \
			"$event_type" \
			"$wt_path" \
			"$reason" \
			"$mode" \
			>>"$log_file" 2>/dev/null || true
	fi

	return 0
}

_worktree_proc_entry_is_provably_foreign_uid() {
	local proc_dir="$1"
	local current_uid="$2"
	local field=""
	local real_uid=""
	local effective_uid=""
	local saved_uid=""
	local filesystem_uid=""
	local process_uid=""
	local proc_owner_uid=""

	[[ "$current_uid" =~ ^[0-9]+$ ]] || return 1
	if [[ ! -r "$proc_dir/status" ]]; then
		proc_owner_uid=$(_worktree_proc_entry_owner_uid "$proc_dir" 2>/dev/null || true)
		if [[ "$proc_owner_uid" =~ ^[0-9]+$ && "$proc_owner_uid" != "$current_uid" ]]; then
			return 0
		fi
		return 1
	fi
	while IFS=$' \t' read -r field real_uid effective_uid saved_uid filesystem_uid _; do
		[[ "$field" == "Uid:" ]] || continue
		for process_uid in "$real_uid" "$effective_uid" "$saved_uid" "$filesystem_uid"; do
			[[ "$process_uid" =~ ^[0-9]+$ ]] || return 1
			[[ "$process_uid" != "$current_uid" ]] || return 1
		done
		return 0
	done <"$proc_dir/status"
	return 1
}

# Mirror of uid_fields_accepted() in worktree-cwd-inspect.py (GH#32871): the
# opt-in inspector can read a process whose real UID is the caller and whose
# effective, saved and filesystem UIDs are the caller or root. Used only to
# label the operator diagnostic; the installed inspector alone decides reads.
_worktree_proc_entry_is_inspectable_uid() {
	local proc_dir="$1"
	local current_uid="$2"
	local field=""
	local real_uid=""
	local effective_uid=""
	local saved_uid=""
	local filesystem_uid=""
	local process_uid=""

	[[ "$current_uid" =~ ^[1-9][0-9]*$ && -r "$proc_dir/status" ]] || return 1
	while IFS=$' \t' read -r field real_uid effective_uid saved_uid filesystem_uid _; do
		[[ "$field" == "Uid:" ]] || continue
		[[ "$real_uid" == "$current_uid" ]] || return 1
		for process_uid in "$effective_uid" "$saved_uid" "$filesystem_uid"; do
			[[ "$process_uid" == "$current_uid" || "$process_uid" == "0" ]] || return 1
		done
		return 0
	done <"$proc_dir/status"
	return 1
}

_worktree_proc_entry_owner_uid() {
	local proc_dir="$1"

	python3 - "$proc_dir" <<'PY'
import os
import sys

try:
    print(os.stat(sys.argv[1], follow_symlinks=False).st_uid)
except OSError:
    raise SystemExit(1)
PY
	return $?
}

_worktree_proc_entry_is_zombie() {
	local proc_dir="$1"
	local field=""
	local state=""

	[[ -r "$proc_dir/status" ]] || return 1
	while IFS=$' \t' read -r field state _; do
		[[ "$field" == "State:" ]] || continue
		[[ "$state" == Z* ]]
		return $?
	done <"$proc_dir/status"
	return 1
}

# Optional, read-only escalation for protected same-UID process CWDs. The
# installed inspector must be root-owned and sudoers must allow only that
# executable; neither a failed sudo call nor an untrusted /proc root grants
# removal permission. See .agents/reference/worktree-cwd-visibility.md.
# shellcheck source=worktree-process-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/worktree-process-policy.sh"

_worktree_privileged_read_cwd() {
	local proc_root="$1"
	local proc_dir="$2"
	local pid="${proc_dir##*/}"
	local timeout_seconds=5
	[[ "$proc_root" == /proc && "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
	worktree_process_inspector_allowed || return 1
	if declare -F timeout_sec >/dev/null 2>&1; then
		timeout_sec "$timeout_seconds" sudo -n -- \
			/usr/local/libexec/aidevops-worktree-cwd-inspect "$pid" 2>/dev/null
		return $?
	fi
	command -v timeout >/dev/null 2>&1 || return 1
	command timeout "$timeout_seconds" sudo -n -- \
		/usr/local/libexec/aidevops-worktree-cwd-inspect "$pid" 2>/dev/null
	return $?
}

# Providers collect evidence only; ownership, Git and removal policy stay here.
# shellcheck source=worktree-process-providers.sh
source "$(dirname "${BASH_SOURCE[0]}")/worktree-process-providers.sh"

# Operator-invoked diagnostic only (GH#32853). Print "<pid>\t<comm>\t<remedy>"
# for each process that makes _capture_worktree_proc_cwds report degraded
# visibility, applying the same vanished, zombie, provably-foreign-UID, and
# opt-in inspector rules. <remedy> is "inspector" when the opt-in inspector's
# UID rule accepts the process (install or repair it) and "stop-only" when only
# stopping the process clears it (GH#32871). Automatic maintenance output must
# never call this: its results stay free of process names under the #31690
# contract. Returns 0 on a completed scan (even when nothing is listed) and 1
# when proc_root is not a directory.
list_worktree_unreadable_proc_cwds() {
	local proc_root="${1:-/proc}"
	local cwd_link=""
	local cwd_target=""
	local proc_dir=""
	local pid=""
	local comm=""
	local current_uid=""
	local remedy=""

	[[ -d "$proc_root" ]] || return 1
	if [[ "$proc_root" == /proc && "$(worktree_process_platform)" == nixos ]]; then
		_worktree_unprivileged_proc_scan denied
		return $?
	fi
	current_uid=$(id -u 2>/dev/null) || current_uid=""
	for cwd_link in "$proc_root"/[0-9]*/cwd; do
		[[ -L "$cwd_link" || -e "$cwd_link" ]] || continue
		readlink "$cwd_link" >/dev/null 2>&1 && continue
		[[ -L "$cwd_link" || -e "$cwd_link" ]] || continue
		proc_dir="${cwd_link%/cwd}"
		_worktree_proc_entry_is_zombie "$proc_dir" && continue
		_worktree_proc_entry_is_provably_foreign_uid "$proc_dir" "$current_uid" && continue
		if cwd_target=$(_worktree_privileged_read_cwd "$proc_root" "$proc_dir"); then
			[[ "$cwd_target" == /* && "$cwd_target" != *$'\n'* ]] && continue
		fi
		[[ -L "$cwd_link" || -e "$cwd_link" ]] || continue
		pid="${proc_dir##*/}"
		comm=""
		if [[ -r "$proc_dir/comm" ]]; then
			IFS= read -r comm <"$proc_dir/comm" 2>/dev/null || comm=""
		fi
		comm=$(printf '%s' "$comm" | LC_ALL=C tr -cd '[:print:]' | cut -c1-32)
		remedy="stop-only"
		_worktree_proc_entry_is_inspectable_uid "$proc_dir" "$current_uid" && remedy="inspector"
		if ! worktree_process_inspector_allowed; then
			remedy="unprivileged-review"
		fi
		printf '%s\t%s\t%s\n' "$pid" "${comm:-unknown}" "$remedy"
	done
	return 0
}

# Return 0 when a captured cwd is inside the candidate worktree.
_worktree_cwd_snapshot_contains_path() {
	local wt_path="$1"
	local wt_path_real="$2"
	local cwd_snapshot="$3"
	local cwd_target=""

	if [[ -z "$wt_path" || -z "$wt_path_real" || -z "$cwd_snapshot" ]]; then
		return 1
	fi
	while IFS= read -r cwd_target; do
		case "$cwd_target" in
		"$wt_path" | "$wt_path"/* | "$wt_path_real" | "$wt_path_real"/*)
			return 0
			;;
		esac
	done <<<"$cwd_snapshot"
	return 1
}

# Return 0 when any live process has its current working directory inside the
# candidate worktree. `pgrep -f "$path"` only sees argv; commands such as
# linters often run with cwd inside the worktree while their argv contains no
# path, so deletion would make them fail with getcwd/uv_cwd ENOENT.
_worktree_has_process_cwd() {
	local wt_path="$1"
	local wt_path_real="$2"
	local cwd_snapshot=""
	local capture_status=0

	if [[ -z "$wt_path" || -z "$wt_path_real" ]]; then
		return 1
	fi
	if cwd_snapshot=$(capture_worktree_process_cwds); then
		capture_status=0
	else
		capture_status=$?
	fi
	if _worktree_cwd_snapshot_contains_path "$wt_path" "$wt_path_real" "$cwd_snapshot"; then
		return 0
	fi
	case "$capture_status" in
	0) return 1 ;;
	"$_WT_CWD_CAPTURE_DEGRADED_RC") return "$_WT_CWD_CAPTURE_DEGRADED_RC" ;;
	*) return "$_WT_CWD_MATCH_UNUSABLE_RC" ;;
	esac
}

# A porcelain block is complete when it describes either one bare repository or
# one linked worktree with exactly one HEAD and one branch/detached identity.
_worktree_git_block_is_complete() {
	local head_count="$1"
	local branch_count="$2"
	local detached_count="$3"
	local bare_count="$4"

	if [[ "$bare_count" -eq 1 ]]; then
		[[ "$head_count" -eq 0 && "$branch_count" -eq 0 && "$detached_count" -eq 0 ]]
		return $?
	fi
	[[ "$bare_count" -eq 0 && "$head_count" -eq 1 &&
		$((branch_count + detached_count)) -eq 1 ]]
	return $?
}

_worktree_git_head_payload_is_valid() {
	local head_oid="$1"

	[[ "${#head_oid}" -eq 40 || "${#head_oid}" -eq 64 ]] || return 1
	case "$head_oid" in
	*[!0-9a-fA-F]*) return 1 ;;
	esac
	return 0
}

_worktree_git_branch_payload_is_valid() {
	local branch_ref="$1"
	local branch_name=""
	local component=""
	local remaining=""

	case "$branch_ref" in
	refs/heads/*) ;;
	*) return 1 ;;
	esac
	branch_name="${branch_ref#refs/heads/}"
	[[ -n "$branch_name" ]] || return 1
	case "$branch_name" in
	*..* | *@\{* | /* | */ | *//* | *[[:space:]]* | *~* | *^* | *:* | *\?* | *\** | *\[* | *\\*) return 1 ;;
	esac
	remaining="$branch_name"
	while :; do
		component="${remaining%%/*}"
		[[ -n "$component" && "$component" != .* && "$component" != *. &&
			"$component" != *.lock ]] || return 1
		[[ "$remaining" == */* ]] || break
		remaining="${remaining#*/}"
	done
	return 0
}

_worktree_git_list_lock_state() {
	local wt_path="$1"
	local wt_path_real="$2"
	local candidate_root="$3"
	local field="" list_status="" listed_path=""
	local parser_valid=1 in_candidate=0 in_block=0 status_seen=0
	local candidate_seen=0 candidate_complete=0 candidate_locked=0
	local head_count=0 branch_count=0 detached_count=0 bare_count=0

	while IFS= read -r -d '' field; do
		case "$field" in
		"$_WT_GIT_STATUS_FIELD_PREFIX"*)
			[[ "$status_seen" -eq 0 && "$in_block" -eq 0 ]] || parser_valid=0
			list_status="${field#"$_WT_GIT_STATUS_FIELD_PREFIX"}"
			status_seen=1
			;;
		worktree\ *)
			[[ "$status_seen" -eq 0 && "$in_block" -eq 0 ]] || parser_valid=0
			listed_path="${field#worktree }"
			[[ -n "$listed_path" ]] || parser_valid=0
			in_block=1 in_candidate=0
			head_count=0 branch_count=0 detached_count=0 bare_count=0
			if [[ "$listed_path" == "$candidate_root" || "$listed_path" == "$wt_path" ||
				"$listed_path" == "$wt_path_real" ]]; then
				[[ "$candidate_seen" -eq 0 ]] || parser_valid=0
				in_candidate=1 candidate_seen=1
			fi
			;;
		HEAD\ *)
			head_count=$((head_count + 1))
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 && "$head_count" -eq 1 ]] || parser_valid=0
			_worktree_git_head_payload_is_valid "${field#HEAD }" || parser_valid=0
			;;
		branch\ *)
			branch_count=$((branch_count + 1))
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 && "$branch_count" -eq 1 ]] || parser_valid=0
			_worktree_git_branch_payload_is_valid "${field#branch }" || parser_valid=0
			;;
		detached)
			detached_count=$((detached_count + 1))
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 && "$detached_count" -eq 1 ]] || parser_valid=0
			;;
		bare)
			bare_count=$((bare_count + 1))
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 && "$bare_count" -eq 1 ]] || parser_valid=0
			;;
		locked | locked\ *)
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 ]] || parser_valid=0
			[[ "$in_candidate" -eq 0 ]] || candidate_locked=1
			;;
		"")
			if [[ "$status_seen" -eq 1 || "$in_block" -ne 1 ]]; then
				parser_valid=0
			elif _worktree_git_block_is_complete "$head_count" "$branch_count" "$detached_count" "$bare_count"; then
				[[ "$in_candidate" -eq 0 ]] || candidate_complete=1
			else
				parser_valid=0
			fi
			in_block=0 in_candidate=0
			;;
		*) [[ "$in_block" -eq 1 && "$status_seen" -eq 0 ]] || parser_valid=0 ;;
		esac
	done < <(
		git -C "$wt_path" worktree list --porcelain -z 2>/dev/null
		printf '%s%s\0' "$_WT_GIT_STATUS_FIELD_PREFIX" "$?"
	)

	if [[ "$parser_valid" -ne 1 || "$status_seen" -ne 1 || "$in_block" -ne 0 ||
		"$list_status" != "0" || "$candidate_seen" -ne 1 || "$candidate_complete" -ne 1 ]]; then
		printf '%s\n' "$_WT_GIT_STATE_UNREADABLE"
	elif [[ "$candidate_locked" -eq 1 ]]; then
		printf '%s\n' "$_WT_GIT_STATE_LOCKED"
	else
		printf '%s\n' "$_WT_GIT_STATE_CLEAR"
	fi
	return 0
}

# Classify the candidate's exact Git worktree metadata block. Git worktree
# locks are an explicit operator/session preservation boundary, so callers must
# not infer "unlocked" from a failed query or an unregistered-looking result.
# Args: $1=worktree path, $2=resolved worktree path
_worktree_git_lock_state() {
	local wt_path="$1"
	local wt_path_real="$2"
	local candidate_root=""

	if [[ ! -e "$wt_path" && ! -L "$wt_path" ]]; then
		printf '%s\n' "$_WT_GIT_STATE_NOT_WORKTREE"
		return 0
	fi
	if [[ ! -d "$wt_path" || ! -r "$wt_path" || ! -x "$wt_path" ]]; then
		printf '%s\n' "$_WT_GIT_STATE_UNREADABLE"
		return 0
	fi
	if ! candidate_root=$(git -C "$wt_path" rev-parse --show-toplevel 2>/dev/null); then
		if [[ -e "$wt_path/.git" || -L "$wt_path/.git" ]]; then
			printf '%s\n' "$_WT_GIT_STATE_UNREADABLE"
		else
			printf '%s\n' "$_WT_GIT_STATE_NOT_WORKTREE"
		fi
		return 0
	fi
	if [[ "$candidate_root" != "$wt_path" && "$candidate_root" != "$wt_path_real" ]]; then
		printf '%s\n' "$_WT_GIT_STATE_UNREADABLE"
		return 0
	fi
	_worktree_git_list_lock_state "$wt_path" "$wt_path_real" "$candidate_root"
	return 0
}

_worktree_git_common_dir() {
	local real_git="$1"
	local wt_path="$2"
	local common_dir=""

	common_dir=$("$real_git" -C "$wt_path" rev-parse --git-common-dir 2>/dev/null) || return 1
	if [[ "$common_dir" != /* ]]; then
		common_dir=$(cd "$wt_path/$common_dir" 2>/dev/null && pwd -P) || return 1
	else
		common_dir=$(cd "$common_dir" 2>/dev/null && pwd -P) || return 1
	fi
	printf '%s\n' "$common_dir"
	return 0
}

# Resolve an existing path physically, or reconstruct a missing path from its
# physical parent. The latter keeps Git's stored path comparable after a
# recoverable move on systems where /var and /private/var alias each other.
_worktree_physical_path() {
	local wt_path="$1"
	local clean_wt_path="$wt_path"
	local parent_path=""
	local parent_real=""
	local path_basename=""

	while [[ "$clean_wt_path" != "/" && "$clean_wt_path" == */ ]]; do
		clean_wt_path="${clean_wt_path%/}"
	done
	if [[ -d "$clean_wt_path" ]]; then
		(cd "$clean_wt_path" 2>/dev/null && pwd -P)
		return $?
	fi
	[[ "$clean_wt_path" == /* && "$clean_wt_path" != "/" ]] || return 1
	parent_path="${clean_wt_path%/*}"
	path_basename="${clean_wt_path##*/}"
	[[ -n "$parent_path" ]] || parent_path="/"
	[[ -n "$path_basename" ]] || return 1
	parent_real=$(cd "$parent_path" 2>/dev/null && pwd -P) || return 1
	if [[ "$parent_real" == "/" ]]; then
		printf '/%s\n' "$path_basename"
	else
		printf '%s/%s\n' "$parent_real" "$path_basename"
	fi
	return 0
}

_worktree_log_git_refusal() {
	local wt_path="$1"
	local caller="$2"
	local git_state="$3"
	local context="${4:-}"
	local refusal_reason="$_WT_GIT_REASON_UNREADABLE"

	if [[ "$git_state" == "$_WT_GIT_STATE_LOCKED" ]]; then
		refusal_reason="$_WT_GIT_REASON_LOCKED"
	elif [[ "$git_state" == "$_WT_GIT_STATE_CLEAR" ]]; then
		refusal_reason="$_WT_GIT_REASON_REMOVE_FAILED"
	fi
	WORKTREE_REMOVAL_GUARD_REASON="$refusal_reason"
	log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "$refusal_reason" "$_WTAR_MODE_SKIPPED" "$context"
	return 0
}

_worktree_log_identity_refusal() {
	local wt_path="$1"
	local caller="$2"
	local context="${3:-}"

	WORKTREE_REMOVAL_GUARD_REASON="$_WT_GIT_REASON_IDENTITY_CHANGED"
	log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" \
		"$_WT_GIT_REASON_IDENTITY_CHANGED" "$_WTAR_MODE_SKIPPED" "$context"
	return 0
}

_worktree_path_identity() {
	local target_path="$1"

	[[ -e "$target_path" && ! -L "$target_path" ]] || return 1
	python3 - "$target_path" <<'PY'
import os
import sys

try:
    st = os.stat(sys.argv[1], follow_symlinks=False)
except OSError:
    raise SystemExit(1)
print(f"{st.st_dev}:{st.st_ino}")
PY
	return $?
}

_worktree_guard_path_is_usable() {
	local wt_path="$1"
	local caller="$2"

	if [[ -z "$wt_path" ]]; then
		WORKTREE_REMOVAL_GUARD_REASON="empty-path"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "empty-path" "$_WTAR_MODE_SKIPPED"
		return 1
	fi
	if [[ -L "$wt_path" ]]; then
		_worktree_log_identity_refusal "$wt_path" "$caller"
		return 1
	fi
	return 0
}

# =============================================================================
# worktree_removal_guard — shared destructive-path guard for production cleanup
#
# Args:
#   $1  wt_path  — absolute path candidate
#   $2  caller   — audit caller constant
#   $3  reason   — reason to log on skip
#   $4  cwd_snapshot — optional newline-separated live-process cwd snapshot
#   $5  cwd_visibility — complete, degraded, or unusable (default: complete)
#
# Refuses registered canonical repos, Git-locked or metadata-unreadable
# worktrees, the caller's current working directory, and worktrees that still
# have any live process cwd inside them. On refusal, WORKTREE_REMOVAL_GUARD_REASON
# contains the short audit reason for callers that opt into a user-facing
# diagnostic. The guard itself remains silent.
# Returns 0 for complete no-match, 2 for degraded no-match (recoverable path
# required), and 1 for every hard refusal or unusable snapshot.
# =============================================================================
worktree_managed_lifetime_proof() {
	local wt_path="$1"
	shift
	local helper="${BASH_SOURCE[0]%/*}/worktree-managed-lifetime.py"
	[[ -f "$helper" ]] || return 1
	WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DB:-}" python3 "$helper" proof "$wt_path" "$@" >/dev/null 2>&1 || return 1
	return 0
}

# Separate, present-tense maintenance authorization for legacy observations.
# Never supplies a managed proof to the degraded-CWD fallback above/below.
worktree_maintenance_removal_proof() {
	local wt_path="$1"
	local helper="${BASH_SOURCE[0]%/*}/worktree-maintenance.py"
	[[ -n "${AIDEVOPS_WORKTREE_MAINTENANCE_PLAN:-}" &&
		-n "${AIDEVOPS_WORKTREE_MAINTENANCE_CONFIRM:-}" && -f "$helper" ]] || return 1
	PYTHONDONTWRITEBYTECODE=1 python3 "$helper" proof "$wt_path" \
		--plan "$AIDEVOPS_WORKTREE_MAINTENANCE_PLAN" \
		--confirm "$AIDEVOPS_WORKTREE_MAINTENANCE_CONFIRM" || return 1
	return 0
}

worktree_maintenance_requested() {
	[[ -n "${AIDEVOPS_WORKTREE_MAINTENANCE_PLAN:-}" ||
		-n "${AIDEVOPS_WORKTREE_MAINTENANCE_CONFIRM:-}" ]] || return 1
	return 0
}

worktree_managed_require_removal_proof() {
	local wt_path="$1"
	local helper="${BASH_SOURCE[0]%/*}/worktree-managed-lifetime.py"
	local managed_status=0
	# Missing or changed enrollment must not turn a planned maintenance removal
	# into an ordinary unregistered removal after its initial authorization.
	if worktree_maintenance_requested; then
		worktree_maintenance_removal_proof "$wt_path" || return 1
		return 0
	fi
	WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DB:-}" python3 "$helper" status "$wt_path" >/dev/null 2>&1 || managed_status=$?
	[[ "$managed_status" -ne 3 ]] || return 0
	worktree_managed_lifetime_proof "$wt_path" || return 1
	return 0
}

worktree_managed_prepare_removal() {
	local wt_path="$1"
	local branch="$2"
	local helper="${BASH_SOURCE[0]%/*}/worktree-managed-lifetime.py"
	local managed_status=0
	# Never claim, re-enroll or seal after a failed maintenance authorization.
	if worktree_maintenance_requested; then
		worktree_maintenance_removal_proof "$wt_path" || return 1
		return 0
	fi
	# Only confirmed absence uses legacy guards; unavailable evidence refuses.
	[[ -f "$helper" ]] || return 1
	WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DB:-}" python3 "$helper" status "$wt_path" >/dev/null 2>&1 || managed_status=$?
	[[ "$managed_status" -ne 3 ]] || return 0
	[[ "$managed_status" -eq 0 ]] || return 1
	worktree_managed_lifetime_proof "$wt_path" && return 0
	declare -F claim_worktree_ownership >/dev/null 2>&1 || return 1
	claim_worktree_ownership "$wt_path" "$branch" --owner-pid "$$" \
		--session "cleanup:$$" --task worktree-removal >/dev/null 2>&1 || return 1
	if ! WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DB:-}" python3 "$helper" seal "$wt_path"; then
		unregister_worktree_if_owner_contract "$wt_path" "$$" "cleanup:$$" worktree-removal >/dev/null 2>&1 || true
		return 1
	fi
	return 0
}

_worktree_guard_degraded_cwd() {
	local wt_path="$1"
	local wt_path_real="$2"
	local caller="$3"
	# Maintenance never enters manual degraded recovery or acquires its lease.
	if worktree_maintenance_requested; then
		WORKTREE_REMOVAL_GUARD_VISIBILITY="$_WT_CWD_VISIBILITY_DEGRADED"
		WORKTREE_REMOVAL_GUARD_REASON="maintenance-cwd-visibility-degraded"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" \
			"$WORKTREE_REMOVAL_GUARD_REASON" "$_WTAR_MODE_SKIPPED"
		return 1
	fi
	# Only a sealed, explicitly enrolled Pulse generation can replace the
	# unknown part of a scan. The caller checks readable positive matches first.
	if worktree_managed_lifetime_proof "$wt_path_real"; then
		WORKTREE_REMOVAL_GUARD_VISIBILITY="managed-lifetime"
		return 0
	fi
	WORKTREE_REMOVAL_GUARD_VISIBILITY="$_WT_CWD_VISIBILITY_DEGRADED"
	WORKTREE_REMOVAL_GUARD_REASON="$_WT_CWD_REASON_DEGRADED"
	log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "$_WT_CWD_REASON_DEGRADED" "recoverable-required"
	return "$_WT_CWD_CAPTURE_DEGRADED_RC"
}

worktree_removal_guard() {
	local wt_path="$1"
	local caller="$2"
	local reason="$3"
	local cwd_snapshot="${4:-}"
	local cwd_visibility="${5:-$_WT_CWD_VISIBILITY_COMPLETE}"
	local cwd_snapshot_provided=0
	local cwd_match_status=0
	local git_lock_state=""
	WORKTREE_REMOVAL_GUARD_REASON=""
	WORKTREE_REMOVAL_GUARD_VISIBILITY=""
	[[ "$#" -ge 4 ]] && cwd_snapshot_provided=1

	_worktree_guard_path_is_usable "$wt_path" "$caller" || return 1

	if command -v is_registered_canonical >/dev/null 2>&1; then
		if is_registered_canonical "$wt_path"; then
			WORKTREE_REMOVAL_GUARD_REASON="canonical-skip"
			log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "canonical-skip" "$_WTAR_MODE_SKIPPED"
			return 1
		fi
	fi

	local wt_path_real="$wt_path"
	if [[ -e "$wt_path" ]]; then
		wt_path_real=$(cd "$wt_path" 2>/dev/null && pwd -P) || wt_path_real="$wt_path"
	fi

	local current_dir=""
	current_dir=$(pwd -P 2>/dev/null || true)
	if [[ -n "$current_dir" ]]; then
		case "$current_dir" in
		"$wt_path" | "$wt_path"/* | "$wt_path_real" | "$wt_path_real"/*)
			WORKTREE_REMOVAL_GUARD_REASON="current-worktree"
			log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "current-worktree" "$_WTAR_MODE_SKIPPED"
			return 1
			;;
		esac
	fi

	git_lock_state=$(_worktree_git_lock_state "$wt_path" "$wt_path_real") ||
		git_lock_state="$_WT_GIT_STATE_UNREADABLE"
	case "$git_lock_state" in
	"$_WT_GIT_STATE_LOCKED")
		WORKTREE_REMOVAL_GUARD_REASON="$_WT_GIT_REASON_LOCKED"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "$_WT_GIT_REASON_LOCKED" "$_WTAR_MODE_SKIPPED"
		return 1
		;;
	"$_WT_GIT_STATE_UNREADABLE")
		WORKTREE_REMOVAL_GUARD_REASON="$_WT_GIT_REASON_UNREADABLE"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "$_WT_GIT_REASON_UNREADABLE" "$_WTAR_MODE_SKIPPED"
		return 1
		;;
	esac

	if [[ "$cwd_snapshot_provided" -eq 1 ]]; then
		if _worktree_cwd_snapshot_contains_path "$wt_path" "$wt_path_real" "$cwd_snapshot"; then
			cwd_match_status=0
		else
			case "$cwd_visibility" in
			"$_WT_CWD_VISIBILITY_COMPLETE") cwd_match_status=1 ;;
			"$_WT_CWD_VISIBILITY_DEGRADED") cwd_match_status="$_WT_CWD_CAPTURE_DEGRADED_RC" ;;
			*) cwd_match_status="$_WT_CWD_MATCH_UNUSABLE_RC" ;;
			esac
		fi
	elif _worktree_has_process_cwd "$wt_path" "$wt_path_real"; then
		cwd_match_status=0
	else
		cwd_match_status=$?
	fi

	if [[ "$cwd_match_status" -eq 0 ]]; then
		WORKTREE_REMOVAL_GUARD_VISIBILITY="$cwd_visibility"
		WORKTREE_REMOVAL_GUARD_REASON="active-cwd"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "active-cwd" "$_WTAR_MODE_SKIPPED"
		return 1
	fi
	if [[ "$cwd_match_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]]; then
		_worktree_guard_degraded_cwd "$wt_path" "$wt_path_real" "$caller" || return $?
		return 0
	fi
	if [[ "$cwd_match_status" -eq "$_WT_CWD_MATCH_UNUSABLE_RC" ]]; then
		WORKTREE_REMOVAL_GUARD_VISIBILITY="$_WT_CWD_VISIBILITY_UNUSABLE"
		WORKTREE_REMOVAL_GUARD_REASON="$_WT_CWD_REASON_UNUSABLE"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "$_WT_CWD_REASON_UNUSABLE" "$_WTAR_MODE_SKIPPED"
		return 1
	fi

	WORKTREE_REMOVAL_GUARD_VISIBILITY="$_WT_CWD_VISIBILITY_COMPLETE"
	: "$reason"
	return 0
}

# Succeed only when WT_PATH still matches the source fingerprint recorded in
# COMPACT_DIR by worktree-archive-helper.sh (GH#34943). Any failure, including
# an unavailable helper, preserves the worktree.
_worktree_compact_source_matches() {
	local wt_path="$1"
	local compact_dir="$2"
	local caller="$3"
	local context="$4"
	local helper="${AIDEVOPS_WORKTREE_ARCHIVE_HELPER:-${BASH_SOURCE[0]%/*}/worktree-archive-helper.sh}"

	if "$helper" source-matches "$compact_dir" "$wt_path" >/dev/null 2>&1; then
		return 0
	fi
	log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" \
		"compact-archive-source-changed" "$_WTAR_MODE_SKIPPED" "$context"
	return 1
}

# Args: $1=worktree, $2=caller, $3=context, $4=force, $5=recovery archive
# (optional), $6=compact archive dir (optional; its source fingerprint is
# re-checked after every other probe, immediately before native removal).
_worktree_remove_with_native_git() {
	local wt_path="$1"
	# Compatibility entrypoint only: old proof/force/archive arguments cannot
	# authorize deletion. The registry executor verifies its own preservation.
	# shellcheck source=./worker-lifecycle-state.sh
	source "${BASH_SOURCE[0]%/*}/worker-lifecycle-state.sh" || return 1
	worker_lifecycle_cleanup_worktree "$wt_path" || return 1
	return 0
}

# Remove a registered worktree only after a durable copy exists outside it.
# Native Git remains the final authority, so a lock acquired during the archive
# copy blocks source removal without any temporary lock-release protocol.
# Args: $1=worktree, $2=archive, $3=caller, $4=reason, $5=context,
#       $6=allow degraded CWD evidence, $7=allow one force
remove_archived_worktree_path() {
	local wt_path="$1"
	local archive_path="$2"
	local caller="$3"
	local reason="$4"
	local context="${5:-}"
	local allow_degraded="${6:-false}"
	local force_remove="${7:-false}"
	local archive_path_real=""
	local wt_path_real="$wt_path"
	local guard_status=0

	_worktree_recovery_archive_is_valid "$archive_path" || return 1
	archive_path_real=$(cd "$archive_path" 2>/dev/null && pwd -P) || return 1
	if [[ -e "$wt_path" ]]; then
		wt_path_real=$(cd "$wt_path" 2>/dev/null && pwd -P) || return 1
	fi
	case "$archive_path_real" in
	"$wt_path_real" | "$wt_path_real"/*) return 1 ;;
	esac
	if ! _worktree_archive_source_matches "$wt_path" "$archive_path"; then
		_worktree_log_identity_refusal "$wt_path" "$caller" "$context"
		return 1
	fi
	if worktree_removal_guard "$wt_path" "$caller" "$reason"; then
		guard_status=0
	else
		guard_status=$?
	fi
	if [[ "$guard_status" -ne 0 ]]; then
		[[ "$allow_degraded" == "$_WTAR_BOOL_TRUE" && "$guard_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || return 1
	fi
	_worktree_remove_with_native_git "$wt_path" "$caller" "$context" "$force_remove" "$archive_path" || return 1
	_worktree_recovery_archive_is_valid "$archive_path" || return 1
	_worktree_recovery_record_source_outcome "$archive_path" "$_WT_RECOVERY_OUTCOME_REMOVED" || return 1
	_worktree_recovery_archive_is_valid "$archive_path" || return 1
	return 0
}

# =============================================================================
# remove_worktree_path_permanently — guarded direct delete for verified cleanup
#
# Args:
#   $1  wt_path  — absolute path candidate
#   $2  caller   — audit caller constant
#   $3  reason   — audit reason on removal
#   $4  context  — optional safe key=value guard context
#
# Returns 0 when path is gone, 1 on guard/delete failure.
# =============================================================================
remove_worktree_path_permanently() {
	local wt_path="$1"
	local caller="$2"
	local reason="$3"
	local context="${4:-}"

	worktree_removal_guard "$wt_path" "$caller" "$reason" || return 1
	if _worktree_remove_with_native_git "$wt_path" "$caller" "$context" "false"; then
		log_worktree_removal_event "$_WTAR_REMOVED" "$caller" "$wt_path" "$reason" "permanent" "$context"
		return 0
	fi

	return 1
}

# Resolve native Git without selecting the canonical mutation-guard shim. This
# helper is the audited exception for an already-guarded linked worktree's
# lock-aware removal and missing-metadata prune operations.
_worktree_cleanup_real_git() {
	local candidate=""

	if ! declare -F aidevops_resolve_native_git >/dev/null 2>&1; then
		# shellcheck source=runtime-env.sh
		source "$(dirname "${BASH_SOURCE[0]}")/runtime-env.sh" || return 1
	fi
	candidate=$(aidevops_resolve_native_git) || return 1
	if [[ -n "$candidate" && -x "$candidate" ]]; then
		printf '%s\n' "$candidate"
		return 0
	fi

	return 1
}

# Return 0 when Git still lists the exact worktree path in its shared metadata.
_worktree_metadata_contains_path() {
	local real_git="$1"
	local repo_context="$2"
	local wt_path="$3"
	local clean_wt_path="$wt_path"
	local physical_wt_path="$wt_path"
	local field="" list_status="" listed_path=""
	local parser_valid=1 in_block=0 status_seen=0 target_seen=0
	local head_count=0 branch_count=0 detached_count=0 bare_count=0

	while [[ "$clean_wt_path" != "/" && "$clean_wt_path" == */ ]]; do
		clean_wt_path="${clean_wt_path%/}"
	done
	physical_wt_path=$(_worktree_physical_path "$clean_wt_path") || physical_wt_path="$clean_wt_path"
	while IFS= read -r -d '' field; do
		case "$field" in
		"$_WT_GIT_STATUS_FIELD_PREFIX"*)
			[[ "$status_seen" -eq 0 && "$in_block" -eq 0 ]] || parser_valid=0
			list_status="${field#"$_WT_GIT_STATUS_FIELD_PREFIX"}"
			status_seen=1
			;;
		worktree\ *)
			[[ "$status_seen" -eq 0 && "$in_block" -eq 0 ]] || parser_valid=0
			listed_path="${field#worktree }"
			[[ -n "$listed_path" ]] || parser_valid=0
			in_block=1
			head_count=0 branch_count=0 detached_count=0 bare_count=0
			if [[ "$listed_path" == "$clean_wt_path" || "$listed_path" == "$physical_wt_path" ]]; then
				[[ "$target_seen" -eq 0 ]] || parser_valid=0
				target_seen=1
			fi
			;;
		HEAD\ *)
			head_count=$((head_count + 1))
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 && "$head_count" -eq 1 ]] || parser_valid=0
			_worktree_git_head_payload_is_valid "${field#HEAD }" || parser_valid=0
			;;
		branch\ *)
			branch_count=$((branch_count + 1))
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 && "$branch_count" -eq 1 ]] || parser_valid=0
			_worktree_git_branch_payload_is_valid "${field#branch }" || parser_valid=0
			;;
		detached)
			detached_count=$((detached_count + 1))
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 && "$detached_count" -eq 1 ]] || parser_valid=0
			;;
		bare)
			bare_count=$((bare_count + 1))
			[[ "$in_block" -eq 1 && "$status_seen" -eq 0 && "$bare_count" -eq 1 ]] || parser_valid=0
			;;
		"")
			if [[ "$status_seen" -eq 1 || "$in_block" -ne 1 ]] ||
				! _worktree_git_block_is_complete "$head_count" "$branch_count" "$detached_count" "$bare_count"; then
				parser_valid=0
			fi
			in_block=0
			;;
		*) [[ "$in_block" -eq 1 && "$status_seen" -eq 0 ]] || parser_valid=0 ;;
		esac
	done < <(
		"$real_git" -C "$repo_context" worktree list --porcelain -z 2>/dev/null
		printf '%s%s\0' "$_WT_GIT_STATUS_FIELD_PREFIX" "$?"
	)
	if [[ "$parser_valid" -ne 1 || "$status_seen" -ne 1 || "$in_block" -ne 0 || "$list_status" != "0" ]]; then
		return 2
	fi
	[[ "$target_seen" -eq 0 ]] || return 0

	return 1
}

# Prune a missing linked worktree through the narrowly scoped native-Git
# primitive, then verify its exact metadata entry disappeared. The target must
# already be absent so this cannot remove a live worktree directory.
# Args: $1=repository context, $2=missing worktree path
# Returns 0 only when the target metadata is absent after pruning.
prune_missing_worktree_metadata() {
	local repo_context="$1"
	local wt_path="$2"
	local real_git=""
	local metadata_status=0

	[[ -n "$repo_context" && -d "$repo_context" && -n "$wt_path" ]] || return 1
	[[ ! -e "$wt_path" ]] || return 1
	real_git=$(_worktree_cleanup_real_git) || return 1
	[[ -n "$real_git" ]] || return 1

	if _worktree_metadata_contains_path "$real_git" "$repo_context" "$wt_path"; then
		metadata_status=0
	else
		metadata_status=$?
	fi
	if [[ "$metadata_status" -eq 1 ]]; then
		return 0
	elif [[ "$metadata_status" -ne 0 ]]; then
		return 1
	fi

	"$real_git" -C "$repo_context" worktree prune >/dev/null || return 1
	if _worktree_metadata_contains_path "$real_git" "$repo_context" "$wt_path"; then
		metadata_status=0
	else
		metadata_status=$?
	fi
	[[ "$metadata_status" -eq 1 ]] || return 1

	return 0
}

# =============================================================================
# Branch-cleanup transport reclaim (GH#35490)
#
# local-/remote-branch-cleanup-helper.sh create a detached deletion transport
# named `<repo>-{local,remote}-branch-cleanup-<pid>`. Before GH#35490 those
# trees enrolled as owner-cgroup managed generations whose completion receipt
# can never be produced once the creating (unmanaged) process exits, so every
# run leaked one tree into the dispatch worktree cap. A transport never hosts
# handed-off work: it is detached and either has no checkout or an unmodified
# one. Reclaim is therefore based on content, not on a synthetic completion
# receipt: no Pulse-managed record is adopted, a live creator or owner keeps its
# tree, and canonical, locked, current-directory and active-CWD guards still
# veto. The managed record is left untouched as lifetime history.
# =============================================================================
_WT_TRANSPORT_NAME_PATTERN='-(local|remote)-branch-cleanup-([0-9]+)$'
_WT_TRANSPORT_REASON="branch-cleanup-transport-reclaim"

_worktree_transport_pid_is_absent() {
	local pid="$1"
	local helper="${BASH_SOURCE[0]%/*}/shared-worktree-registry-platform.py"
	[[ "$pid" =~ ^[1-9][0-9]*$ && -f "$helper" ]] || return 1
	python3 "$helper" pid-absent "$pid" >/dev/null 2>&1 || return 1
	return 0
}

# Succeed when the creator named by the path and every recorded owner are gone.
# Legacy (unenrolled) and properly sealed generations need only the creator
# check; only an unsealed owner-cgroup record may be considered, never Pulse's.
_worktree_transport_owner_gone() {
	local wt_path_real="$1"
	local creator_pid="$2"
	local helper="${BASH_SOURCE[0]%/*}/worktree-managed-lifetime.py"
	local record="" managed_status=0 owner_pid=""

	_worktree_transport_pid_is_absent "$creator_pid" || return 1
	[[ -f "$helper" ]] || return 1
	record=$(WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DB:-}" python3 "$helper" status "$wt_path_real" 2>/dev/null) ||
		managed_status=$?
	[[ "$managed_status" -ne 3 ]] || return 0
	[[ "$managed_status" -eq 0 && -n "$record" ]] || return 1
	worktree_managed_lifetime_proof "$wt_path_real" && return 0
	command -v jq >/dev/null 2>&1 || return 1
	printf '%s' "$record" | jq -e '.manager == "owner-cgroup" and .state == "running"' >/dev/null 2>&1 || return 1
	# The recorded owner cgroup is often a long-lived session or service scope,
	# so its population is not evidence about this tree. A descendant still
	# using the transport (for example `git -C`) has its CWD inside it, which
	# worktree_removal_guard vetoes.
	while IFS= read -r owner_pid; do
		_worktree_transport_pid_is_absent "$owner_pid" || return 1
	done < <(printf '%s' "$record" | jq -r '.launches[]? | (.owner_pid // 0 | tostring)' 2>/dev/null)
	return 0
}

# Succeed when the transport is detached and holds nothing beyond its Git link
# (no-checkout) or an unmodified checkout with no untracked or ignored files.
_worktree_transport_is_content_free() {
	local real_git="$1"
	local wt_path_real="$2"
	local entry="" status_out=""

	[[ -f "$wt_path_real/.git" && ! -L "$wt_path_real/.git" ]] || return 1
	if "$real_git" -C "$wt_path_real" symbolic-ref -q HEAD >/dev/null 2>&1; then
		return 1
	fi
	for entry in "$wt_path_real"/* "$wt_path_real"/.[!.]* "$wt_path_real"/..?*; do
		[[ -e "$entry" || -L "$entry" ]] || continue
		[[ "${entry##*/}" == ".git" ]] && continue
		status_out=$("$real_git" -C "$wt_path_real" status --porcelain --untracked-files=all --ignored 2>/dev/null) ||
			return 1
		[[ -z "$status_out" ]] || return 1
		return 0
	done
	return 0
}

# Args: $1=repository context, $2=transport path, $3=audit caller,
#       $4=CWD snapshot, $5=CWD visibility (complete|degraded|unusable)
# Returns 0 only when the transport was removed and its path is gone.
reclaim_branch_cleanup_transport() {
	local repo_context="$1"
	local wt_path="$2"
	local caller="$3"
	local cwd_snapshot="$4"
	local cwd_visibility="$5"
	local name="${wt_path##*/}"
	local creator_pid="" wt_path_real="" real_git="" common_dir="" repo_common_dir="" git_state=""

	[[ "$name" =~ $_WT_TRANSPORT_NAME_PATTERN ]] || return 1
	creator_pid="${BASH_REMATCH[2]}"
	[[ -d "$wt_path" && ! -L "$wt_path" ]] || return 1
	wt_path_real=$(cd "$wt_path" 2>/dev/null && pwd -P) || return 1
	if ! _worktree_transport_owner_gone "$wt_path_real" "$creator_pid"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "transport-owner-active-or-unproven" "$_WTAR_MODE_SKIPPED"
		return 1
	fi
	real_git=$(_worktree_cleanup_real_git) || return 1
	if ! _worktree_transport_is_content_free "$real_git" "$wt_path_real"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "transport-has-content" "$_WTAR_MODE_SKIPPED"
		return 1
	fi
	worktree_removal_guard "$wt_path" "$caller" "$_WT_TRANSPORT_REASON" "$cwd_snapshot" "$cwd_visibility" || return 1
	common_dir=$(_worktree_git_common_dir "$real_git" "$wt_path_real") || return 1
	repo_common_dir=$(_worktree_git_common_dir "$real_git" "$repo_context") || return 1
	[[ "$common_dir" == "$repo_common_dir" ]] || return 1
	git_state=$(_worktree_git_lock_state "$wt_path" "$wt_path_real") || git_state="$_WT_GIT_STATE_UNREADABLE"
	if [[ "$git_state" != "$_WT_GIT_STATE_CLEAR" ]]; then
		_worktree_log_git_refusal "$wt_path" "$caller" "$git_state" ""
		return 1
	fi
	# One --force: a no-checkout tree reports its empty index as changes. Git
	# still refuses a lock acquired after the check above.
	if ! "$real_git" --git-dir="$common_dir" worktree remove --force "$wt_path_real" >/dev/null 2>&1; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "$_WT_GIT_REASON_REMOVE_FAILED" "$_WTAR_MODE_SKIPPED"
		return 1
	fi
	[[ ! -e "$wt_path_real" ]] || return 1
	log_worktree_removal_event "$_WTAR_REMOVED" "$caller" "$wt_path" "$_WT_TRANSPORT_REASON" "permanent"
	return 0
}

# Reclaim retained branch-cleanup transports of one repository. Local and
# API-free, so it runs before any GitHub-dependent cleanup can time out.
# Args: $1=repository context, $2=audit caller, $3=optional max removals
# Prints the number of reclaimed transports; always returns 0.
reclaim_branch_cleanup_transports() {
	local repo_context="$1"
	local caller="$2"
	local limit="${3:-${AIDEVOPS_TRANSPORT_RECLAIM_MAX:-250}}"
	local real_git="" field="" wt_path="" detached=0 first=1 candidates="" candidate=""
	local cwd_snapshot="" cwd_status=0 cwd_visibility="$_WT_CWD_VISIBILITY_COMPLETE" reclaimed=0

	[[ "$limit" =~ ^[0-9]+$ ]] || limit=250
	if [[ -z "$repo_context" || ! -d "$repo_context" ]] || ! real_git=$(_worktree_cleanup_real_git); then
		printf '0\n'
		return 0
	fi
	while IFS= read -r -d '' field; do
		case "$field" in
		worktree\ *) wt_path="${field#worktree }" detached=0 ;;
		detached) detached=1 ;;
		"")
			if [[ "$first" -eq 0 && "$detached" -eq 1 && "${wt_path##*/}" =~ $_WT_TRANSPORT_NAME_PATTERN ]]; then
				candidates="${candidates}${wt_path}"$'\n'
			fi
			first=0 wt_path="" detached=0
			;;
		esac
	done < <("$real_git" -C "$repo_context" worktree list --porcelain -z 2>/dev/null || true)
	if [[ -z "$candidates" ]]; then
		printf '0\n'
		return 0
	fi
	# One CWD snapshot per pass; each removal still rechecks Git lock state.
	cwd_snapshot=$(capture_worktree_process_cwds) || cwd_status=$?
	if [[ "$cwd_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]]; then
		cwd_visibility="$_WT_CWD_VISIBILITY_DEGRADED"
	elif [[ "$cwd_status" -ne 0 ]]; then
		cwd_visibility="$_WT_CWD_VISIBILITY_UNUSABLE"
	fi
	while IFS= read -r candidate; do
		[[ -n "$candidate" && "$reclaimed" -lt "$limit" ]] || continue
		if reclaim_branch_cleanup_transport "$repo_context" "$candidate" "$caller" "$cwd_snapshot" "$cwd_visibility"; then
			reclaimed=$((reclaimed + 1))
		fi
	done <<<"$candidates"
	printf '%s\n' "$reclaimed"
	return 0
}
