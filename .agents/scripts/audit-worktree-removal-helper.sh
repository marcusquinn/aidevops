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
_WT_CWD_VISIBILITY_COMPLETE="complete"
_WT_CWD_VISIBILITY_DEGRADED="degraded"
_WT_CWD_VISIBILITY_UNUSABLE="unusable"
_WT_CWD_CAPTURE_DEGRADED_RC=2
_WT_CWD_MATCH_UNUSABLE_RC=3
_WT_CWD_REASON_DEGRADED="cwd-visibility-degraded"
_WT_CWD_REASON_UNUSABLE="cwd-visibility-unusable"

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

	[[ "$current_uid" =~ ^[0-9]+$ && -r "$proc_dir/status" ]] || return 1
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

_capture_worktree_proc_cwds() {
	local proc_root="$1"
	local cwd_link=""
	local cwd_target=""
	local captured_count=0
	local current_uid=""
	local visibility_degraded=0
	local proc_dir=""

	current_uid=$(id -u 2>/dev/null) || current_uid=""

	for cwd_link in "$proc_root"/[0-9]*/cwd; do
		[[ -L "$cwd_link" || -e "$cwd_link" ]] || continue
		if ! cwd_target=$(readlink "$cwd_link" 2>/dev/null); then
			# Vanished processes are harmless. Linux commonly denies cwd reads for
			# other users, so skip only entries whose four status UIDs prove they
			# are foreign. Persistent same-user or unknown-ownership denials make
			# visibility degraded without discarding readable cwd evidence.
			[[ -L "$cwd_link" || -e "$cwd_link" ]] || continue
			proc_dir="${cwd_link%/cwd}"
			_worktree_proc_entry_is_provably_foreign_uid "$proc_dir" "$current_uid" && continue
			visibility_degraded=1
			continue
		fi
		if [[ -n "$cwd_target" ]]; then
			printf '%s\n' "$cwd_target"
			captured_count=$((captured_count + 1))
		fi
		done
	if [[ "$visibility_degraded" -eq 1 ]]; then
		return "$_WT_CWD_CAPTURE_DEGRADED_RC"
	fi
	[[ "$captured_count" -gt 0 ]] || return 1
	return 0
}

_capture_worktree_lsof_cwds() {
	local cwd_target=""
	local captured_count=0
	local lsof_line=""
	local lsof_output=""
	local lsof_status=0

	if lsof_output=$(lsof -n -F n -d cwd 2>/dev/null); then
		lsof_status=0
	else
		lsof_status=$?
	fi
	while IFS= read -r lsof_line; do
		case "$lsof_line" in
		n*)
			cwd_target="${lsof_line#n}"
			if [[ -n "$cwd_target" ]]; then
				printf '%s\n' "$cwd_target"
				captured_count=$((captured_count + 1))
			fi
			;;
		esac
	done <<<"$lsof_output"
	[[ "$captured_count" -gt 0 ]] || return 1
	if [[ "$lsof_status" -ne 0 ]]; then
		return "$_WT_CWD_CAPTURE_DEGRADED_RC"
	fi
	return 0
}

# Capture every visible live-process cwd. stdout always preserves readable
# targets. Return 0 for complete visibility, 2 for degraded visibility with
# same-UID/unknown denials, and 1 when no usable snapshot can be established.
# Callers may supply the resulting snapshot and visibility to the guard so one
# safety check performs only one platform scan.
capture_worktree_process_cwds() {
	if [[ -d /proc ]]; then
		_capture_worktree_proc_cwds /proc
		return $?
	fi

	if command -v lsof >/dev/null 2>&1; then
		# macOS lacks /proc, but `lsof +D <worktree>` recursively walks the
		# whole tree (including node_modules). Query only cwd descriptors once.
		_capture_worktree_lsof_cwds
		return $?
	fi
	return 1
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
# Refuses registered canonical repos, the caller's current working directory,
# and worktrees that still have any live process cwd inside them. On refusal,
# WORKTREE_REMOVAL_GUARD_REASON contains the short audit reason for callers that
# opt into a user-facing diagnostic. The guard itself remains silent.
# Returns 0 for complete no-match, 2 for degraded no-match (recoverable path
# required), and 1 for every hard refusal or unusable snapshot.
# =============================================================================
worktree_removal_guard() {
	local wt_path="$1"
	local caller="$2"
	local reason="$3"
	local cwd_snapshot="${4:-}"
	local cwd_visibility="${5:-$_WT_CWD_VISIBILITY_COMPLETE}"
	local cwd_snapshot_provided=0
	local cwd_match_status=0
	WORKTREE_REMOVAL_GUARD_REASON=""
	WORKTREE_REMOVAL_GUARD_VISIBILITY=""
	[[ "$#" -ge 4 ]] && cwd_snapshot_provided=1

	if [[ -z "$wt_path" ]]; then
		WORKTREE_REMOVAL_GUARD_REASON="empty-path"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "empty-path" "skipped"
		return 1
	fi

	if command -v is_registered_canonical >/dev/null 2>&1; then
		if is_registered_canonical "$wt_path"; then
			WORKTREE_REMOVAL_GUARD_REASON="canonical-skip"
			log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "canonical-skip" "skipped"
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
			log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "current-worktree" "skipped"
			return 1
			;;
		esac
	fi

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
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "active-cwd" "skipped"
		return 1
	fi
	if [[ "$cwd_match_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]]; then
		WORKTREE_REMOVAL_GUARD_VISIBILITY="$_WT_CWD_VISIBILITY_DEGRADED"
		WORKTREE_REMOVAL_GUARD_REASON="$_WT_CWD_REASON_DEGRADED"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "$_WT_CWD_REASON_DEGRADED" "recoverable-required"
		return "$_WT_CWD_CAPTURE_DEGRADED_RC"
	fi
	if [[ "$cwd_match_status" -eq "$_WT_CWD_MATCH_UNUSABLE_RC" ]]; then
		WORKTREE_REMOVAL_GUARD_VISIBILITY="$_WT_CWD_VISIBILITY_UNUSABLE"
		WORKTREE_REMOVAL_GUARD_REASON="$_WT_CWD_REASON_UNUSABLE"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "$_WT_CWD_REASON_UNUSABLE" "skipped"
		return 1
	fi

	WORKTREE_REMOVAL_GUARD_VISIBILITY="$_WT_CWD_VISIBILITY_COMPLETE"
	: "$reason"
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
	[[ ! -e "$wt_path" ]] && return 0

	if rm -rf "$wt_path" 2>/dev/null; then
		log_worktree_removal_event "$_WTAR_REMOVED" "$caller" "$wt_path" "$reason" "permanent" "$context"
		return 0
	fi

	return 1
}

# Resolve native Git without selecting the canonical mutation-guard shim. This
# helper is the audited exception for pruning metadata after a guarded removal
# has already moved a linked worktree directory to trash.
_worktree_cleanup_real_git() {
	local candidate="${AIDEVOPS_REAL_GIT_BIN:-}"

	if [[ -n "$candidate" && -x "$candidate" ]]; then
		printf '%s\n' "$candidate"
		return 0
	fi

	for candidate in /usr/bin/git /usr/local/bin/git /opt/homebrew/bin/git; do
		if [[ -x "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done

	return 1
}

# Return 0 when Git still lists the exact worktree path in its shared metadata.
_worktree_metadata_contains_path() {
	local real_git="$1"
	local repo_context="$2"
	local wt_path="$3"
	local clean_wt_path="$wt_path"
	local list_output=""
	local listed_path=""

	while [[ "$clean_wt_path" != "/" && "$clean_wt_path" == */ ]]; do
		clean_wt_path="${clean_wt_path%/}"
	done
	if ! list_output=$("$real_git" -C "$repo_context" worktree list --porcelain); then
		return 2
	fi

	while IFS= read -r listed_path; do
		listed_path="${listed_path%$'\r'}"
		[[ "$listed_path" == "worktree $clean_wt_path" ]] && return 0
	done <<<"$list_output"

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
