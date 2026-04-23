#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Intentionally using /bin/bash (not /usr/bin/env bash) for headless compatibility.
# Some MCP/headless runners provide a stripped PATH where env cannot resolve bash.
# Keep this exception aligned with issue #2610 and t135.14 standardization context.
# shellcheck disable=SC2155
# =============================================================================
# aidevops Issue Sync Helper
# =============================================================================
# Stateless bi-directional sync between TODO.md and GitHub Issues via gh CLI.
#
# Relationship sync (blocked-by, sub-issues) extracted to
# issue-sync-relationships.sh (GH#19502).
#
# Removed in t1337.4 refactor (2,405 → ~600 lines):
#   - SQLite supervisor DB / cross-repo guards (stateless now)
#   - Gitea/GitLab adapters + platform dispatch layer (GitHub-only)
#   - AI-based semantic duplicate detection (title-prefix match suffices)
#   - Private repo name sanitization (prevention at source per AGENTS.md)
#
# All parsing, composing, and ref-management lives in issue-sync-lib.sh.
#
# Usage: issue-sync-helper.sh [command] [options]
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

# Use pure-bash parameter expansion instead of dirname (external binary) to avoid
# "dirname: command not found" in headless/MCP environments where PATH is restricted.
# Defensive PATH export ensures downstream tools (gh, git, jq, sed, awk) are findable.
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

_script_path="${BASH_SOURCE[0]%/*}"
[[ "$_script_path" == "${BASH_SOURCE[0]}" ]] && _script_path="."
SCRIPT_DIR="$(cd "$_script_path" && pwd)" || exit
unset _script_path
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=issue-sync-lib.sh
source "${SCRIPT_DIR}/issue-sync-lib.sh"

# =============================================================================
# Configuration & Utility
# =============================================================================

VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
FORCE_CLOSE="${FORCE_CLOSE:-false}"
FORCE_PUSH="${FORCE_PUSH:-false}"
FORCE_ENRICH="${FORCE_ENRICH:-false}"
REPO_SLUG=""

log_verbose() {
	local msg="$1"
	[[ "$VERBOSE" == "true" ]] && print_info "$msg"
	return 0
}

detect_repo_slug() {
	local project_root="$1"
	local remote_url
	remote_url=$(git -C "$project_root" remote get-url origin 2>/dev/null || echo "")
	remote_url="${remote_url%.git}"
	local slug
	slug=$(echo "$remote_url" | sed -E 's|.*[:/]([^/]+/[^/]+)$|\1|' || echo "")
	[[ -z "$slug" ]] && {
		print_error "Could not detect repo slug from git remote"
		return 1
	}
	echo "$slug"
}

verify_gh_cli() {
	command -v gh &>/dev/null || {
		print_error "gh CLI not installed. Install: brew install gh"
		return 1
	}
	[[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]] && return 0
	gh auth status &>/dev/null 2>&1 || {
		print_error "gh CLI not authenticated. Run: gh auth login"
		return 1
	}
	return 0
}

# Common preamble for commands that need project_root, repo, todo_file, gh auth
_init_cmd() {
	_CMD_ROOT=$(find_project_root) || return 1
	_CMD_REPO="${REPO_SLUG:-$(detect_repo_slug "$_CMD_ROOT")}"
	_CMD_TODO="$_CMD_ROOT/TODO.md"
	verify_gh_cli || return 1
}

_build_title() {
	local task_id="$1" description="$2"
	# Layer 3 (t2377): refuse stub titles. When description is empty, the
	# pre-fix behaviour emitted "tNNN: " (task ID + colon + trailing space)
	# which _enrich_update_issue then wrote to the issue, destroying the
	# real title (#19778/#19779/#19780). Fail loudly so the caller sees it.
	if [[ -z "$description" ]]; then
		print_error "_build_title: refusing to emit stub title for ${task_id} — description is empty (t2377)"
		return 1
	fi
	if [[ "$description" == *" — "* ]]; then
		echo "${task_id}: ${description%% — *}"
	elif [[ ${#description} -gt 80 ]]; then
		echo "${task_id}: ${description:0:77}..."
	else echo "${task_id}: ${description}"; fi
	return 0
}

# =============================================================================
# GitHub API (gh CLI wrappers — kept for multi-call functions only)
# =============================================================================

gh_list_issues() {
	local repo="$1" state="$2" limit="$3"
	gh issue list --repo "$repo" --state "$state" --limit "$limit" \
		--json number,title,assignees,state,labels 2>/dev/null || echo "[]"
}

_gh_edit_labels() {
	local action="$1" repo="$2" num="$3" labels="$4"
	local -a args=()
	local IFS=','
	for lbl in $labels; do [[ -n "$lbl" ]] && args+=("--${action}-label" "$lbl"); done
	unset IFS
	[[ ${#args[@]} -gt 0 ]] && gh issue edit "$num" --repo "$repo" "${args[@]}" 2>/dev/null || true
}

# _tier_rank: emit numeric rank for a tier label (t2111).
# Higher rank = more capable model. The ordering is the canonical one
# defined in shared-constants.sh as ISSUE_TIER_LABEL_RANK (thinking >
# standard > simple) and matches _resolve_worker_tier's max-wins pick
# in pulse-dispatch-core.sh and _first_tier_in_rank_order's reconciler
# pick in pulse-issue-reconcile.sh.
#
# A local case statement is used (rather than indexing ISSUE_TIER_LABEL_RANK)
# because (a) it's O(1) without iteration, (b) it explicitly encodes the
# numeric contract the ratchet rule relies on, and (c) the array treats
# "thinking" as index 0 which would invert the comparison semantics here.
#
# Used by the ratchet rule in _apply_tier_label_replace to preserve cascade-
# escalated tier labels that the brief file doesn't yet reflect.
#
# Arguments:
#   $1 - tier label (e.g., tier:simple, tier:standard, tier:thinking)
# Prints:
#   0/1/2 for known tiers, -1 for unknown/empty
_tier_rank() {
	case "${1:-}" in
	tier:simple) printf '0' ;;
	tier:standard) printf '1' ;;
	tier:thinking) printf '2' ;;
	*) printf -- '-1' ;;
	esac
	return 0
}

# _apply_tier_label_replace: set the tier label on an issue, replacing any
# existing tier:* labels. Avoids the collision class observed in t2012/t1997
# where multiple tier:* labels could coexist when issue-sync added a new tier
# without removing old ones (and the protected-prefix rule prevented
# _reconcile_labels from cleaning up the old one).
#
# Re-fetches current labels from gh to defend against stale upstream label
# state (race window between view and edit). Two API calls per tier change is
# acceptable; tier changes are infrequent.
#
# Ratchet rule (t2111, GH#19070): if the issue already carries a tier:* label
# of higher rank than the incoming tier, this is a cascade-escalated issue
# (escalate_issue_tier in worker-lifecycle-common.sh raised it above the
# brief's declared tier after worker failures). In that case the function
# MUST no-op — the brief is a FLOOR, the cascade is a CEILING, and the
# ceiling wins. Without this guard, scheduled enrichment reverts every
# escalation ~5 minutes after it fires, producing a tier:standard ->
# tier:thinking -> tier:standard flip-flop that wastes dispatch cycles on
# the same worker failure. See GH#19038 label event history for the
# canonical symptom.
#
# Arguments:
#   $1 - repo slug
#   $2 - issue number
#   $3 - new tier label (e.g., tier:standard)
_apply_tier_label_replace() {
	local repo="$1" num="$2" new_tier="$3" current_labels_csv="${4:-}"
	[[ -z "$repo" || -z "$num" || -z "$new_tier" ]] && return 0

	# Validate the new tier matches the expected pattern — refuse to push
	# arbitrary labels through this helper.
	if [[ ! "$new_tier" =~ ^tier:(simple|standard|thinking)$ ]]; then
		print_warning "tier replace: refusing to apply non-tier label '$new_tier' to #$num in $repo"
		return 0
	fi

	# t2165: accept pre-fetched labels CSV to avoid a redundant gh issue view.
	# Fall back to fetching when unset — preserves isolated-test behaviour.
	local existing_tiers
	if [[ -n "$current_labels_csv" ]]; then
		existing_tiers=""
		local _saved_ifs_t="$IFS"
		IFS=','
		local _lbl_t
		for _lbl_t in $current_labels_csv; do
			[[ -z "$_lbl_t" ]] && continue
			case "$_lbl_t" in
			tier:*) existing_tiers="${existing_tiers:+$existing_tiers,}$_lbl_t" ;;
			esac
		done
		IFS="$_saved_ifs_t"
	else
		existing_tiers=$(gh issue view "$num" --repo "$repo" --json labels \
			--jq '[.labels[].name | select(startswith("tier:"))] | join(",")' 2>/dev/null || echo "")
	fi

	# Ratchet rule (t2111): compute the max rank among existing tier:* labels
	# and compare against the incoming tier. If the existing max outranks the
	# incoming, this is a cascade-escalated issue — preserve it.
	local new_rank
	new_rank=$(_tier_rank "$new_tier")
	if [[ -n "$existing_tiers" ]]; then
		local _rmax=-1
		local _saved_ifs="$IFS"
		IFS=','
		local _t _r
		for _t in $existing_tiers; do
			[[ -z "$_t" ]] && continue
			_r=$(_tier_rank "$_t")
			((_r > _rmax)) && _rmax=$_r
		done
		IFS="$_saved_ifs"
		if ((_rmax > new_rank)); then
			print_info "tier replace: preserving escalated tier on #$num (existing max rank $_rmax > incoming rank $new_rank for $new_tier) — ratchet rule, see t2111"
			return 0
		fi
	fi

	# Remove any existing tier labels that don't match the new one.
	if [[ -n "$existing_tiers" ]]; then
		local -a remove_args=()
		local _saved_ifs="$IFS"
		IFS=','
		local old
		for old in $existing_tiers; do
			[[ -z "$old" ]] && continue
			[[ "$old" == "$new_tier" ]] && continue
			remove_args+=("--remove-label" "$old")
		done
		IFS="$_saved_ifs"
		if [[ ${#remove_args[@]} -gt 0 ]]; then
			gh issue edit "$num" --repo "$repo" "${remove_args[@]}" 2>/dev/null ||
				print_warning "tier replace: failed to remove stale tier label(s) from #$num in $repo"
		fi
	fi

	# Add the new tier label (idempotent — gh edit silently no-ops if present).
	gh issue edit "$num" --repo "$repo" --add-label "$new_tier" 2>/dev/null || true
	return 0
}

# _is_protected_label: returns 0 if the label must NOT be removed by enrich reconciliation.
# Protected labels are managed by other workflows (lifecycle, closure hygiene, PR labeler)
# and must not be touched by tag-derived label reconciliation.
# Arguments:
#   $1 - label name
_is_protected_label() {
	local lbl="$1"
	# Prefix-protected namespaces
	case "$lbl" in
	status:* | origin:* | tier:* | source:*) return 0 ;;
	esac
	# Exact-match protected labels
	# GH#19856: added no-auto-dispatch and no-takeover — these are coordination
	# signals set by explicit user/session action and must survive enrich.
	# t2754: added hold-for-review and needs-credentials — canonical dispatch-blockers.
	case "$lbl" in
	persistent | needs-maintainer-review | not-planned | duplicate | wontfix | \
		already-fixed | "good first issue" | "help wanted" | \
		parent-task | meta | auto-dispatch | no-auto-dispatch | no-takeover | \
		hold-for-review | needs-credentials | \
		consolidation-in-progress | coderabbit-nits-ok | ratchet-bump | \
		new-file-smell-ok)
		return 0
		;;
	esac
	return 1
}

# _is_tag_derived_label: returns 0 if a label is in the tag-derived domain.
# Tag-derived labels are simple words (no ':' separator). All system/workflow
# labels use ':' namespacing (status:*, origin:*, tier:*, source:*, etc.).
# This prevents reconciliation from removing manually-added or system labels
# that happen to not be in the protected prefix list.
# Arguments:
#   $1 - label name
_is_tag_derived_label() {
	local lbl="$1"
	# Labels with ':' are namespace-scoped — not tag-derived
	[[ "$lbl" == *:* ]] && return 1
	return 0
}

# _reconcile_labels: remove tag-derived labels from a GitHub issue that are no
# longer present in the desired label set. Only labels in the tag-derived domain
# (no ':' separator, not protected) are candidates for removal.
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - issue number
#   $3 - desired labels (comma-separated, already mapped via map_tags_to_labels)
_reconcile_labels() {
	local repo="$1" num="$2" desired_labels="$3" current_labels="${4:-}"
	# t2165: accept pre-fetched labels CSV to avoid a redundant gh issue view.
	# Fall back to fetching when unset — preserves isolated-test behaviour.
	if [[ -z "$current_labels" ]]; then
		current_labels=$(gh issue view "$num" --repo "$repo" --json labels \
			--jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
	fi
	[[ -z "$current_labels" ]] && return 0

	local to_remove=""
	local _saved_ifs="$IFS"
	IFS=','
	for lbl in $current_labels; do
		[[ -z "$lbl" ]] && continue
		# Skip protected labels — they are not in the tag-derived domain
		_is_protected_label "$lbl" && continue
		# Skip labels outside the tag-derived domain (namespaced labels with ':')
		_is_tag_derived_label "$lbl" || continue
		# Check if this label is in the desired set
		local found=false
		for desired in $desired_labels; do
			[[ "$lbl" == "$desired" ]] && {
				found=true
				break
			}
		done
		[[ "$found" == "false" ]] && to_remove="${to_remove:+$to_remove,}$lbl"
	done
	IFS="$_saved_ifs"

	if [[ -n "$to_remove" ]]; then
		local -a rm_args=()
		local _saved_ifs_rm="$IFS"
		IFS=','
		for _lbl in $to_remove; do [[ -n "$_lbl" ]] && rm_args+=("--remove-label" "$_lbl"); done
		IFS="$_saved_ifs_rm"
		if [[ ${#rm_args[@]} -gt 0 ]]; then
			gh issue edit "$num" --repo "$repo" "${rm_args[@]}" 2>/dev/null ||
				print_warning "label reconcile: failed to remove stale labels ($to_remove) from #$num in $repo"
		fi
	fi
	return 0
}

gh_create_label() {
	local repo="$1" name="$2" color="$3" desc="$4"
	gh label create "$name" --repo "$repo" --color "$color" --description "$desc" --force 2>/dev/null || true
}

gh_find_issue_by_title() {
	local repo="$1" prefix="$2" state="${3:-all}" limit="${4:-500}"
	gh issue list --repo "$repo" --state "$state" --limit "$limit" \
		--json number,title --jq "[.[] | select(.title | startswith(\"${prefix}\"))][0].number // empty" 2>/dev/null || echo ""
}

gh_find_merged_pr() {
	local repo="$1" task_id="$2"
	gh pr list --repo "$repo" --state merged --search "$task_id in:title" \
		--limit 1 --json number,url 2>/dev/null | jq -r '.[0] | select(. != null) | "\(.number)|\(.url)"' || true
}

ensure_labels_exist() {
	local labels="$1" repo="$2"
	[[ -z "$labels" || -z "$repo" ]] && return 0

	# Source label-sync-helper for semantic tag colors (color_for_tag function).
	# Falls back to EDEDED if the helper is not available.
	local _label_helper="${SCRIPT_DIR}/label-sync-helper.sh"
	if [[ -f "$_label_helper" ]] && ! declare -F color_for_tag >/dev/null 2>&1; then
		# shellcheck source=label-sync-helper.sh
		source "$_label_helper" 2>/dev/null || true
	fi

	local _saved_ifs="$IFS"
	IFS=','
	for lbl in $labels; do
		if [[ -n "$lbl" ]]; then
			local _color="EDEDED"
			if declare -F color_for_tag >/dev/null 2>&1; then
				_color=$(color_for_tag "$lbl")
			fi
			gh_create_label "$repo" "$lbl" "$_color" "Auto-created from TODO.md tag"
		fi
	done
	IFS="$_saved_ifs"
}

# t2040: _mark_issue_done delegates to set_issue_status which performs the
# add+remove atomically in a single `gh issue edit` call. The previous
# implementation used a non-atomic two-call sequence (add then remove) that
# created a transient window where the issue carried both `status:in-review`
# and `status:done`. The reconciler's label-invariant pass would see two
# status labels and could pick the wrong survivor, potentially losing `done`.
# Precedence (ISSUE_STATUS_LABEL_PRECEDENCE) now treats `done` as terminal,
# but the correct fix is to close the window entirely.
#
# set_issue_status handles every core status:* label in ISSUE_STATUS_LABELS
# (available/queued/claimed/in-progress/in-review/done/blocked) atomically.
# The only extra label to clear is `status:verify-failed` which is an
# out-of-band exception label not managed by set_issue_status — passed
# through via its trailing passthrough flags.
_mark_issue_done() {
	local repo="$1" num="$2"
	set_issue_status "$num" "$repo" "done" \
		--remove-label "status:verify-failed" 2>/dev/null || true
}

# =============================================================================
# Close Helpers
# =============================================================================

# _is_cancelled_or_deferred: returns 0 if the task text indicates it was
# cancelled, deferred, or declined — these states require no PR/verified evidence.
_is_cancelled_or_deferred() {
	local text="$1"
	echo "$text" | grep -qiE 'cancelled:[0-9]{4}-[0-9]{2}-[0-9]{2}|deferred:[0-9]{4}-[0-9]{2}-[0-9]{2}|declined:[0-9]{4}-[0-9]{2}-[0-9]{2}|CANCELLED' && return 0
	return 1
}

_has_evidence() {
	local text="$1" task_id="$2" repo="$3"
	# Cancelled/deferred/declined tasks need no PR or verified: evidence
	_is_cancelled_or_deferred "$text" && return 0
	echo "$text" | grep -qE 'verified:[0-9]{4}-[0-9]{2}-[0-9]{2}|pr:#[0-9]+' && return 0
	echo "$text" | grep -qiE 'PR #[0-9]+ merged|PR.*merged' && return 0
	[[ -n "$repo" ]] && [[ -n "$(gh_find_merged_pr "$repo" "$task_id")" ]] && return 0
	return 1
}

_find_closing_pr() {
	local text="$1" task_id="$2" repo="$3"
	local pr
	pr=$(echo "$text" | grep -oE 'pr:#[0-9]+|PR #[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
	[[ -n "$pr" ]] && {
		echo "${pr}|https://github.com/${repo}/pull/${pr}"
		return 0
	}
	if [[ -n "$repo" ]]; then
		local info
		info=$(gh_find_merged_pr "$repo" "$task_id")
		[[ -n "$info" ]] && {
			echo "$info"
			return 0
		}
		local parent
		parent=$(echo "$task_id" | grep -oE '^t[0-9]+' || echo "")
		[[ -n "$parent" && "$parent" != "$task_id" ]] && {
			info=$(gh_find_merged_pr "$repo" "$parent")
			[[ -n "$info" ]] && {
				echo "$info"
				return 0
			}
		}
	fi
	return 1
}

_close_comment() {
	local task_id="$1" text="$2" pr_num="$3" pr_url="$4"
	# Cancelled/deferred/declined: produce a not-planned comment (no PR needed)
	if _is_cancelled_or_deferred "$text"; then
		local reason
		reason=$(echo "$text" | grep -oiE 'cancelled:[0-9-]+|deferred:[0-9-]+|declined:[0-9-]+|CANCELLED' | head -1 | tr '[:upper:]' '[:lower:]')
		[[ -z "$reason" ]] && reason="cancelled"
		echo "Closing as not planned ($reason). Task $task_id resolved in TODO.md."
		return 0
	fi
	if [[ -n "$pr_num" && -n "$pr_url" ]]; then
		echo "Completed via [PR #${pr_num}](${pr_url}). Task $task_id done in TODO.md."
	elif [[ -n "$pr_num" ]]; then
		echo "Completed via PR #${pr_num}. Task $task_id done in TODO.md."
	else
		local d
		d=$(echo "$text" | grep -oE 'verified:[0-9-]+' | head -1 | sed 's/verified://')
		[[ -n "$d" ]] && echo "Completed (verified: $d). Task $task_id done in TODO.md." || echo "Completed. Task $task_id done in TODO.md."
	fi
}

# Mark a TODO entry as done: [ ] → [x] with completed: date.
# Also handles [-] (cancelled/declined) entries — leaves marker as [-].
_mark_todo_done() {
	local task_id="$1" todo_file="$2"
	local task_id_ere
	task_id_ere=$(_escape_ere "$task_id")
	local today
	today=$(date -u +%Y-%m-%d)

	# Only flip [ ] → [x]; skip if already [x] or [-]
	# Use [[:space:]] not \s for macOS sed compatibility (bash 3.2)
	if grep -qE "^[[:space:]]*- \[ \] ${task_id_ere} " "$todo_file" 2>/dev/null; then
		# Flip checkbox and append completed: date
		sed -i.bak -E "s/^([[:space:]]*- )\[ \] (${task_id_ere} .*)/\1[x] \2 completed:${today}/" "$todo_file"
		rm -f "${todo_file}.bak"
		log_verbose "Marked $task_id as [x] in TODO.md"
	fi
	return 0
}

_do_close() {
	local task_id="$1" issue_number="$2" todo_file="$3" repo="$4"
	local task_id_ere
	task_id_ere=$(_escape_ere "$task_id")
	local task_with_notes task_line pr_info pr_num="" pr_url=""
	task_with_notes=$(extract_task_block "$task_id" "$todo_file")
	task_line=$(strip_code_fences <"$todo_file" | grep -E "^\s*- \[.\] ${task_id_ere} " | head -1 || echo "")
	[[ -z "$task_with_notes" ]] && task_with_notes="$task_line"

	pr_info=$(_find_closing_pr "$task_with_notes" "$task_id" "$repo" 2>/dev/null || echo "")
	if [[ -n "$pr_info" ]]; then
		pr_num="${pr_info%%|*}"
		pr_url="${pr_info#*|}"
		[[ "$DRY_RUN" != "true" && -n "$pr_num" ]] && add_pr_ref_to_todo "$task_id" "$pr_num" "$todo_file"
		task_line=$(strip_code_fences <"$todo_file" | grep -E "^\s*- \[.\] ${task_id_ere} " | head -1 || echo "")
		task_with_notes=$(extract_task_block "$task_id" "$todo_file")
		[[ -z "$task_with_notes" ]] && task_with_notes="$task_line"
	fi

	if [[ "$FORCE_CLOSE" == "true" ]]; then
		print_info "FORCE_CLOSE active — bypassing evidence check for #$issue_number ($task_id) (GH#20146 audit)"
	fi
	if [[ "$FORCE_CLOSE" != "true" ]] && ! _has_evidence "$task_with_notes" "$task_id" "$repo"; then
		print_warning "Skipping #$issue_number ($task_id): no merged PR or verified: field"
		return 1
	fi

	local comment
	comment=$(_close_comment "$task_id" "$task_with_notes" "$pr_num" "$pr_url")
	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] Would close #$issue_number ($task_id)"
		return 0
	fi
	# Cancelled/deferred/declined tasks close as "not planned"; completed tasks use default reason
	local close_args=("issue" "close" "$issue_number" "--repo" "$repo" "--comment" "$comment")
	if _is_cancelled_or_deferred "$task_with_notes"; then
		close_args+=("--reason" "not planned")
		gh_create_label "$repo" "not-planned" "E4E669" "Closed as not planned"
	fi
	if gh "${close_args[@]}" 2>/dev/null; then
		if _is_cancelled_or_deferred "$task_with_notes"; then
			_gh_edit_labels "add" "$repo" "$issue_number" "not-planned"
		fi
		_mark_issue_done "$repo" "$issue_number"
		_mark_todo_done "$task_id" "$todo_file"
		print_success "Closed #$issue_number ($task_id)"
	else
		print_error "Failed to close #$issue_number ($task_id)"
		return 1
	fi
}

# =============================================================================
# Commands
# =============================================================================

# _push_build_task_list: populate tasks array from target or full TODO.md scan.
# Outputs one task ID per line to stdout; caller reads into array.
_push_build_task_list() {
	local target_task="$1" todo_file="$2"
	if [[ -n "$target_task" ]]; then
		echo "$target_task"
		return 0
	fi
	while IFS= read -r line; do
		local tid
		tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		[[ -n "$tid" ]] && ! echo "$line" | grep -qE 'ref:GH#[0-9]+' && echo "$tid"
	done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[ \] t[0-9]+' || true)
	return 0
}

# _push_auto_assign_interactive: self-assign issue to the current user when
# origin is interactive and the task is NOT flagged for worker dispatch.
# t2157: skips assignment when auto-dispatch is in all_labels — the user said
# "let a worker handle it"; assigning the pusher creates the blocking combo
# (origin:interactive + assigned + active status) per GH#18352/t1996.
# t1970: eliminates the race where Maintainer Gate fires before self-assign.
# t1984: uses AIDEVOPS_SESSION_USER when set (workflow env → github.actor).
_push_auto_assign_interactive() {
	local num="$1" repo="$2" all_labels="$3"
	# t2157: skip when auto-dispatch tag present — issue is worker-owned
	if [[ ",${all_labels}," == *",auto-dispatch,"* ]]; then
		print_info "Skipping auto-assign for #${num} — auto-dispatch entry is worker-owned (t2157)"
		return 0
	fi
	local current_user="${AIDEVOPS_SESSION_USER:-}"
	if [[ -z "$current_user" ]]; then
		# GH#18591: cache gh api user to avoid repeated API calls in loops.
		if [[ -z "${_CACHED_GH_USER:-}" ]]; then
			_CACHED_GH_USER=$(gh api user --jq '.login // ""' 2>/dev/null || echo "")
		fi
		current_user="$_CACHED_GH_USER"
	fi
	if [[ -n "$current_user" ]]; then
		if gh issue edit "$num" --repo "$repo" --add-assignee "$current_user" >/dev/null 2>&1; then
			print_info "Auto-assigned #${num} to @${current_user} (origin:interactive)"
		else
			print_warning "Could not self-assign #${num} — assign manually to unblock Maintainer Gate"
		fi
	fi
	return 0
}

# _push_create_issue: create a GitHub issue for task_id with race-condition guard.
# Sets _PUSH_CREATED_NUM on success (empty on failure/skip).
# Returns 0=created, 1=skipped (race), 2=error.
_push_create_issue() {
	local task_id="$1" repo="$2" todo_file="$3" title="$4" body="$5" labels="$6" assignee="$7"
	_PUSH_CREATED_NUM=""

	[[ -n "$labels" ]] && ensure_labels_exist "$labels" "$repo"
	local status_label="status:available"
	[[ -n "$assignee" ]] && {
		status_label="status:claimed"
		gh_create_label "$repo" "status:claimed" "D93F0B" "Task is claimed"
	}
	# Add session origin label (origin:worker or origin:interactive)
	local origin_label
	origin_label=$(session_origin_label)
	gh_create_label "$repo" "$origin_label" "C5DEF5" "Created from ${origin_label#origin:} session"
	local all_labels="${labels:+${labels},}${status_label},${origin_label}"

	# cool — belt-and-suspenders race guard right before creation
	local recheck
	recheck=$(gh_find_issue_by_title "$repo" "${task_id}:" "all" 500)
	if [[ -n "$recheck" && "$recheck" != "null" ]]; then
		add_gh_ref_to_todo "$task_id" "$recheck" "$todo_file"
		return 1
	fi

	local -a args=("issue" "create" "--repo" "$repo" "--title" "$title" "--body" "$body" "--label" "$all_labels")
	[[ -n "$assignee" ]] && args+=("--assignee" "$assignee")

	# GH#15234 Fix 1: gh issue create may return empty stdout (e.g. when label
	# application fails after issue creation) while still creating the issue
	# server-side. Treat empty URL or non-zero exit as a soft failure and attempt
	# a recovery lookup before declaring an error. Stderr is merged into the
	# combined output for diagnostics without requiring a temp file.
	local url gh_exit combined
	{
		combined=$(gh "${args[@]}" 2>&1)
		gh_exit=$?
	} || true
	# Extract URL from combined output (stdout URL appears first on success)
	url=$(echo "$combined" | grep -oE 'https://github\.com/[^ ]+/issues/[0-9]+' | head -1 || echo "")

	if [[ $gh_exit -ne 0 || -z "$url" ]]; then
		# Issue may have been created despite the error — check before failing.
		# Brief pause for API consistency before the recovery lookup.
		sleep 1
		local recovery
		recovery=$(gh_find_issue_by_title "$repo" "${task_id}:" "all" 500)
		if [[ -n "$recovery" && "$recovery" != "null" ]]; then
			print_warning "gh create exited $gh_exit but issue found via recovery: #$recovery"
			log_verbose "gh output: ${combined:0:200}"
			_PUSH_CREATED_NUM="$recovery"
			return 0
		fi
		print_error "Failed to create issue for $task_id (exit $gh_exit): ${combined:0:200}"
		return 2
	fi

	local num
	num=$(echo "$url" | grep -oE '[0-9]+$' || echo "")
	[[ -n "$num" ]] && _PUSH_CREATED_NUM="$num"

	# t1970/t1984/t2157: auto-assign interactive origin issues (not auto-dispatch).
	# Worker issues follow status:claimed + pulse-managed assignment instead.
	[[ -n "$num" && -z "$assignee" && "$origin_label" == "origin:interactive" ]] &&
		_push_auto_assign_interactive "$num" "$repo" "$all_labels"

	# Lock maintainer/worker-created issues at creation to prevent
	# comment prompt-injection across the entire issue lifecycle.
	if [[ -n "$num" ]]; then
		local _lock_owner="${repo%%/*}"
		local _lock_user="${AIDEVOPS_SESSION_USER:-}"
		[[ -z "$_lock_user" ]] && _lock_user=$(gh api user --jq '.login // ""' 2>/dev/null || echo "")
		if [[ -n "$_lock_user" && "$_lock_user" == "$_lock_owner" ]] ||
			[[ "$origin_label" == "origin:worker" ]]; then
			gh issue lock "$num" --repo "$repo" --reason "resolved" >/dev/null 2>&1 || true
		fi
	fi
	return 0
}

# _push_process_task: process a single task_id — skip if existing/completed,
# parse metadata, dry-run or create issue. Updates created/skipped counters
# via stdout tokens "CREATED" or "SKIPPED" for the caller to count.
# GH#18041 (t1957): Collision detection — warn if a merged PR already uses
# this task ID. This catches task ID reuse (counter reset, fabricated IDs)
# before the issue is created, preventing permanent dispatch blocks.
# Extracted from _push_process_task to keep that function under the 100-line
# complexity gate (t2377 refactor).
_push_warn_if_task_id_collides() {
	local repo="$1" task_id="$2"
	local collision_pr
	collision_pr=$(gh_find_merged_pr "$repo" "$task_id")
	if [[ -n "$collision_pr" ]]; then
		local collision_num="${collision_pr%%|*}"
		local collision_url="${collision_pr#*|}"
		print_warning "TASK ID COLLISION: ${task_id} already used by merged PR #${collision_num} (${collision_url}). This issue will be blocked by the dedup guard. Re-ID the task with claim-task-id.sh."
	fi
	return 0
}

_push_process_task() {
	local task_id="$1" repo="$2" todo_file="$3" project_root="$4"
	log_verbose "Processing $task_id..."
	local task_id_ere
	task_id_ere=$(_escape_ere "$task_id")

	# Skip if issue already exists
	local existing
	existing=$(gh_find_issue_by_title "$repo" "${task_id}:" "all" 500)
	if [[ -n "$existing" && "$existing" != "null" ]]; then
		add_gh_ref_to_todo "$task_id" "$existing" "$todo_file"
		echo "SKIPPED"
		return 0
	fi

	local task_line
	task_line=$(strip_code_fences <"$todo_file" | grep -E "^\s*- \[.\] ${task_id_ere} " | head -1 || echo "")
	[[ -z "$task_line" ]] && {
		print_warning "Task $task_id not found in TODO.md"
		return 0
	}

	# GH#5212: Skip tasks already marked [x] (completed) — prevents duplicate
	# issues when push is called with a specific task_id that is already done.
	# The TOON backlog cache in TODO.md can be stale, showing tasks as pending
	# even after [x] completion. The pulse reads the stale cache and calls
	# push <task_id>, which previously matched [x] lines via the [.] pattern.
	# GH#5280: trailing space made optional — matches [x] at end-of-line too.
	if [[ "$task_line" =~ ^[[:space:]]*-[[:space:]]+\[x\]([[:space:]]|$) ]]; then
		print_info "Skipping $task_id — already completed ([x] in TODO.md)"
		echo "SKIPPED"
		return 0
	fi

	local parsed
	parsed=$(parse_task_line "$task_line")
	local description
	description=$(echo "$parsed" | grep '^description=' | cut -d= -f2-)
	local tags
	tags=$(echo "$parsed" | grep '^tags=' | cut -d= -f2-)
	local assignee
	assignee=$(echo "$parsed" | grep '^assignee=' | cut -d= -f2-)
	local title
	if ! title=$(_build_title "$task_id" "$description"); then
		print_error "Skipping push for $task_id — empty description; fix TODO entry before retrying (t2377)"
		echo "SKIPPED"
		return 0
	fi
	local labels
	labels=$(map_tags_to_labels "$tags")

	# Extract and validate tier from brief file. Held aside from the main
	# labels CSV — applied via _apply_tier_label_replace AFTER the issue
	# exists, so any pre-existing tier:* label is removed first (t2012).
	local brief_path="$project_root/todo/tasks/${task_id}-brief.md"
	local tier_label
	tier_label=$(_extract_tier_from_brief "$brief_path")
	if [[ -n "$tier_label" ]]; then
		tier_label=$(_validate_tier_checklist "$brief_path" "$tier_label")
	fi

	local body
	body=$(compose_issue_body "$task_id" "$project_root")

	_push_warn_if_task_id_collides "$repo" "$task_id"

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] Would create: $title"
		echo "CREATED"
		return 0
	fi

	_PUSH_CREATED_NUM=""
	local rc
	_push_create_issue "$task_id" "$repo" "$todo_file" "$title" "$body" "$labels" "$assignee"
	rc=$?
	if [[ $rc -eq 0 && -n "$_PUSH_CREATED_NUM" ]]; then
		print_success "Created #${_PUSH_CREATED_NUM}: $title"
		# Apply tier label via the replace-not-append helper so any existing
		# tier:* label is removed first (t2012). Done after creation so the
		# newly-created issue has a number to address.
		if [[ -n "$tier_label" ]]; then
			_apply_tier_label_replace "$repo" "$_PUSH_CREATED_NUM" "$tier_label"
		fi
		add_gh_ref_to_todo "$task_id" "$_PUSH_CREATED_NUM" "$todo_file"
		# Sync relationships (blocked-by, sub-issues) after creation (t1889)
		sync_relationships_for_task "$task_id" "$todo_file" "$repo"
		# t2442: if the applied labels include `parent-task` AND the body
		# has no decomposition markers, post a one-time warning. This
		# surfaces the no-phase-markers state at creation time — before
		# the 24h nudge + 7d escalation cascade wastes pulse cycles.
		# Non-blocking: the issue was already created successfully, this
		# is pure advisory. Failure is silent (try/true).
		if [[ ",${labels}," == *",parent-task,"* ]] && \
			! _parent_body_has_phase_markers "$body"; then
			_post_parent_task_no_markers_warning "$repo" "$_PUSH_CREATED_NUM" || true
		fi
		echo "CREATED"
	elif [[ $rc -eq 1 ]]; then
		echo "SKIPPED"
	fi
	return 0
}

cmd_push() {
	local target_task="${1:-}"
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO" project_root="$_CMD_ROOT"

	# Guard: issue creation from TODO.md should only happen in ONE place to
	# prevent duplicates. CI (GitHub Actions issue-sync.yml) is the single
	# authority for bulk push. Local sessions use claim-task-id.sh (which
	# creates issues at claim time) or target a single task explicitly.
	#
	# The race condition: when TODO.md merges to main, both CI and local
	# pulse/supervisor run "push" simultaneously. Both see "no existing issue"
	# and both create one — producing duplicates (observed: t1365, t1366,
	# t1367, t1370.x, t1375.x all had duplicate issues).
	#
	# Fix: bulk push (no target_task) is CI-only unless --force-push is passed.
	# Single-task push (claim-task-id.sh path) is always allowed.
	if [[ -z "$target_task" && "${GITHUB_ACTIONS:-}" != "true" && "$FORCE_PUSH" != "true" ]]; then
		print_info "Bulk push skipped — CI is the single authority for issue creation from TODO.md"
		print_info "Use 'issue-sync-helper.sh push <task_id>' for single tasks, or --force-push to override"
		return 0
	fi
	if [[ "$FORCE_PUSH" == "true" && -z "$target_task" ]]; then
		print_info "FORCE_PUSH active — bypassing CI-only gate for bulk push (GH#20146 audit)"
	fi

	local tasks=()
	while IFS= read -r tid; do
		[[ -n "$tid" ]] && tasks+=("$tid")
	done < <(_push_build_task_list "$target_task" "$todo_file")

	[[ ${#tasks[@]} -eq 0 ]] && {
		print_info "No tasks to push"
		return 0
	}

	print_info "Processing ${#tasks[@]} task(s) for push to $repo"
	gh_create_label "$repo" "status:available" "0E8A16" "Task is available for claiming"

	local created=0 skipped=0
	for task_id in "${tasks[@]}"; do
		local result
		result=$(_push_process_task "$task_id" "$repo" "$todo_file" "$project_root")
		[[ "$result" == *"CREATED"* ]] && created=$((created + 1))
		[[ "$result" == *"SKIPPED"* ]] && skipped=$((skipped + 1))
	done
	print_info "Push complete: $created created, $skipped skipped"
	return 0
}

# _enrich_build_task_list: collect task IDs to enrich — single target or all
# TODO tasks that already have a ref:GH# number. Outputs one task ID per line.
_enrich_build_task_list() {
	local target_task="$1" todo_file="$2"
	if [[ -n "$target_task" ]]; then
		echo "$target_task"
		return 0
	fi
	while IFS= read -r line; do
		local tid
		tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		[[ -n "$tid" ]] && echo "$tid"
	done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[ \] t[0-9]+.*ref:GH#[0-9]+' || true)
	return 0
}

# _enrich_apply_labels: add labels, reconcile stale ones, then apply tier label
# via replace-not-append (t2012). Skips add when labels is empty.
# add_ok gates reconciliation to avoid destructive removal after transient API
# failures (GH#17402 CR fix).
_enrich_apply_labels() {
	local repo="$1" num="$2" labels="$3" tier_label="$4" current_labels_csv="${5:-}"
	local add_ok=true
	if [[ -n "$labels" ]]; then
		ensure_labels_exist "$labels" "$repo"
		# t2165: skip the add API call when every desired label is already
		# present in the issue's current labels. gh issue edit --add-label
		# is idempotent but still round-trips ~1.5s per task; at ~145 open
		# tasks this is the bulk of the 10-minute enrich budget.
		local all_present=false
		if [[ -n "$current_labels_csv" ]]; then
			all_present=true
			local _saved_ifs_chk="$IFS"
			IFS=','
			local _lbl_chk _found_chk
			for _lbl_chk in $labels; do
				[[ -z "$_lbl_chk" ]] && continue
				_found_chk=false
				local _saved_ifs_in="$IFS"
				IFS=','
				local _existing
				for _existing in $current_labels_csv; do
					if [[ "$_existing" == "$_lbl_chk" ]]; then
						_found_chk=true
						break
					fi
				done
				IFS="$_saved_ifs_in"
				if [[ "$_found_chk" != "true" ]]; then
					all_present=false
					break
				fi
			done
			IFS="$_saved_ifs_chk"
		fi
		if [[ "$all_present" != "true" ]]; then
			# Build add args and check exit status — _gh_edit_labels masks failures
			# via || true, so we call gh issue edit directly here.
			local -a add_args=()
			local _saved_ifs_add="$IFS"
			IFS=','
			for _lbl in $labels; do [[ -n "$_lbl" ]] && add_args+=("--add-label" "$_lbl"); done
			IFS="$_saved_ifs_add"
			if [[ ${#add_args[@]} -gt 0 ]]; then
				gh issue edit "$num" --repo "$repo" "${add_args[@]}" 2>/dev/null || add_ok=false
			fi
		fi
	fi
	# Reconcile: remove tag-derived labels no longer in desired set (GH#17402).
	# t2165: forward the pre-fetched labels so _reconcile_labels skips its
	# own gh issue view call when we already have the state.
	[[ "$add_ok" == "true" ]] && _reconcile_labels "$repo" "$num" "$labels" "$current_labels_csv"
	# Apply tier label via replace-not-append — protected-prefix rule prevents
	# _reconcile_labels from cleaning up stale tier:* labels on its own.
	if [[ -n "$tier_label" ]]; then
		_apply_tier_label_replace "$repo" "$num" "$tier_label" "$current_labels_csv"
	fi
	return 0
}

# _enrich_update_issue: brief-first authoritative body policy (t2063).
#
# Body update decision tree (in priority order):
#   1. FORCE_ENRICH=true          → always update body
#   2. Brief file exists on disk  → brief is authoritative, update body unless
#                                    current == composed (no-op skip)
#   3. No brief + has sentinel    → previously framework-synced, update on diff
#                                    (existing GH#18411 behaviour)
#   4. No brief + no sentinel     → genuine external content, preserve body
#                                    (existing GH#18411 behaviour)
#
# Rationale (t2063): prior to this change, case 2 fell through to case 4
# whenever the issue was created by `claim-task-id.sh` before the TODO entry
# was pushed — the bare-fallback body had no sentinel, so enrich preserved
# the stub even though a rich brief existed on disk. The brief-file check
# short-circuits that case: if a brief exists, the brief is the source of
# truth and the body is just a view of it.
#
# Returns 0 on successful edit, 1 on failure.
_enrich_update_issue() {
	local repo="$1" num="$2" task_id="$3" title="$4" body="$5"
	# t2165: accept pre-fetched current_title/current_body as optional 6th/7th
	# args. When present, skip the per-helper gh issue view call. Fall back to
	# fetching when empty — preserves isolated-test behaviour.
	local current_title="${6:-}" current_body="${7:-}"
	local do_body_update=true

	# Layer 2 (t2377): never-delete invariant. Regardless of FORCE_ENRICH or any
	# other env override, refuse to write an empty title or empty body. These
	# are never a legitimate target state — `gh issue edit --title "" --body ""`
	# is pure data loss (observed on #19778/#19779/#19780). This guard runs
	# BEFORE any FORCE_ENRICH bypass and cannot be disabled.
	if [[ -z "$title" ]]; then
		print_error "_enrich_update_issue refused empty title for #$num ($task_id) — data loss guard (t2377)"
		return 1
	fi
	if [[ -z "$body" ]]; then
		print_error "_enrich_update_issue refused empty body for #$num ($task_id) — data loss guard (t2377)"
		return 1
	fi
	# Layer 2 (t2377): stub title ("tNNN: " or "tNNN:  " with trailing whitespace)
	# is the symptom seen on #19778/#19779/#19780. Refuse even when non-empty.
	if [[ "$title" =~ ^t[0-9]+:[[:space:]]*$ ]]; then
		print_error "_enrich_update_issue refused stub title '$title' for #$num ($task_id) — data loss guard (t2377)"
		return 1
	fi

	if [[ "$FORCE_ENRICH" == "true" ]]; then
		print_info "FORCE_ENRICH active — skipping content-preservation gate for #$num ($task_id) (GH#20146 audit)"
	fi
	if [[ "$FORCE_ENRICH" != "true" ]]; then
		if [[ -z "$current_body" ]]; then
			current_body=$(gh issue view "$num" --repo "$repo" --json body -q '.body // ""' 2>/dev/null || echo "")
		fi

		# t2063: brief-file presence is the authoritative signal.
		# Resolve project root from the shared PROJECT_ROOT variable if set
		# (normal sync path) or from git rev-parse as a fallback.
		local _project_root="${PROJECT_ROOT:-}"
		[[ -z "$_project_root" ]] && _project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
		local _brief_file=""
		[[ -n "$_project_root" ]] && _brief_file="${_project_root}/todo/tasks/${task_id}-brief.md"

		if [[ -n "$_brief_file" && -f "$_brief_file" ]]; then
			# Case 2: brief exists → authoritative. Refresh unless no-op.
			if [[ "$current_body" == "$body" ]]; then
				print_info "Body unchanged on #$num ($task_id), skipping API call"
				do_body_update=false
			else
				print_info "Refreshing body on #$num ($task_id) — brief file is authoritative (t2063)"
			fi
		elif [[ "$current_body" == *"Synced from TODO.md by issue-sync-helper.sh"* ]]; then
			# Case 3: no brief, has sentinel → framework-synced, refresh on diff
			if [[ "$current_body" == "$body" ]]; then
				print_info "Body unchanged on #$num ($task_id), skipping API call"
				do_body_update=false
			fi
		else
			# Case 4: no brief, no sentinel → genuine external content, preserve
			print_info "Preserving external body on #$num ($task_id) — no brief file, no sentinel (use --force to override)"
			do_body_update=false
		fi
	fi

	if [[ "$do_body_update" == "true" ]]; then
		if gh_issue_edit_safe "$num" --repo "$repo" --title "$title" --body "$body" 2>/dev/null; then
			return 0
		fi
		print_error "Failed to enrich body on #$num ($task_id)"
		return 1
	fi
	# t2165: when the title also already matches, skip the title-only API
	# call entirely. The previous implementation always issued at least one
	# gh issue edit per task even when nothing had changed — on a
	# steady-state TODO.md this was the dominant per-task cost.
	if [[ -n "$current_title" && "$current_title" == "$title" ]]; then
		print_info "Title unchanged on #$num ($task_id), skipping API call"
		return 0
	fi
	# Still update title even when body is preserved/skipped (GH#18411).
	if gh_issue_edit_safe "$num" --repo "$repo" --title "$title" 2>/dev/null; then
		return 0
	fi
	print_error "Failed to enrich title on #$num ($task_id)"
	return 1
}

# _enrich_check_rate_limit: probe GitHub GraphQL rate limit before the enrich
# loop. If remaining points are below ENRICH_RATE_LIMIT_THRESHOLD (default 250),
# emit a ::warning:: with the reset time and return 0 (caller should skip the
# enrich step entirely). Returns 1 if rate limit is healthy (proceed).
#
# Approach B from GH#20129. At 0 remaining, calling gh issue view 192 times
# produces 162 GUARD_UNCERTAIN warnings with zero value — this probe detects
# the exhausted state before the loop and avoids the wasted calls.
_enrich_check_rate_limit() {
	local threshold="${ENRICH_RATE_LIMIT_THRESHOLD:-250}"
	local _rl_json _rl_remaining _rl_reset _rc=0
	_rl_json=$(gh api rate_limit 2>/dev/null) || _rc=$?
	# Fail-open: if rate_limit probe itself fails, proceed with the enrich.
	[[ $_rc -ne 0 || -z "$_rl_json" ]] && return 1
	_rl_remaining=$(printf '%s' "$_rl_json" | jq -r '.resources.graphql.remaining // 9999' 2>/dev/null || echo "9999")
	if [[ "$_rl_remaining" -ge "$threshold" ]]; then
		return 1  # healthy — proceed
	fi
	_rl_reset=$(printf '%s' "$_rl_json" | jq -r '.resources.graphql.reset // 0' 2>/dev/null || echo "0")
	local _reset_time
	_reset_time=$(date -d "@${_rl_reset}" '+%H:%M:%SZ' 2>/dev/null \
		|| TZ=UTC date -r "$_rl_reset" '+%H:%M:%SZ' 2>/dev/null \
		|| echo "unknown")
	echo "::warning::GraphQL rate-limit too low for enrich, skipping this cycle (remaining=${_rl_remaining}, reset=${_reset_time}, threshold=${threshold}) — GH#20129"
	return 0  # tell caller to skip
}

# _enrich_prefetch_issues_map: fetch all open issues in one batch call and
# write the JSON array to a temp file. Sets ENRICH_PREFETCH_FILE to the path.
# Returns 0 on success, 1 on failure (caller should fall back to per-task calls).
#
# Approach A from GH#20129. One GraphQL call returning N issues costs far fewer
# rate-limit points than N individual gh issue view calls.
_enrich_prefetch_issues_map() {
	local repo="$1"
	local _limit="${ENRICH_PREFETCH_LIMIT:-500}"
	local _rc=0
	local _result
	_result=$(gh issue list --repo "$repo" --state open \
		--json number,title,body,labels,state,assignees \
		--limit "$_limit" 2>/dev/null) || _rc=$?
	if [[ $_rc -ne 0 || -z "$_result" || "$_result" == "[]" ]]; then
		print_warning "Batch prefetch failed (rc=$_rc), falling back to per-task gh issue view (GH#20129)"
		return 1
	fi
	# Write to temp file so the enrich loop can read it per-task without
	# passing a large string through every subshell invocation.
	ENRICH_PREFETCH_FILE=$(mktemp /tmp/enrich-prefetch-XXXXXX.json 2>/dev/null || echo "")
	if [[ -z "$ENRICH_PREFETCH_FILE" ]]; then
		return 1
	fi
	printf '%s' "$_result" >"$ENRICH_PREFETCH_FILE"
	local _count
	_count=$(printf '%s' "$_result" | jq 'length' 2>/dev/null || echo "?")
	print_info "Batch prefetched ${_count} open issues for enrich (GH#20129)"
	export ENRICH_PREFETCH_FILE
	return 0
}

# _enrich_check_active_claim: GH#19856 cross-runner dedup guard for the enrich
# path. Before ANY destructive enrich operation (labels, title, body), check if
# another runner holds an active claim on this issue. Returns 0 if an active
# claim is detected (caller should abort enrich), 1 if safe to proceed.
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - task_id (for logging)
#   $4 - (optional) pre-fetched issue JSON (forwarded via ISSUE_META_JSON to
#        is_assigned to avoid a redundant gh issue view call; GH#19922)
_enrich_check_active_claim() {
	local num="$1" repo="$2" task_id="$3" pre_fetched_json="${4:-}"
	local _dedup_helper="${SCRIPT_DIR}/dispatch-dedup-helper.sh"
	if [[ -x "$_dedup_helper" ]]; then
		# GH#19922: resolve runner login so is-assigned can apply the self-login
		# exemption — without it the runner blocks its own enrichment when it is
		# also an assignee (e.g. single-user setups).
		local _user="${AIDEVOPS_SESSION_USER:-}"
		[[ -z "$_user" ]] && _user=$(gh api user --jq '.login // ""' 2>/dev/null || echo "")
		local _dedup_result=""
		# GH#19922: pass pre-fetched JSON via ISSUE_META_JSON env var to avoid
		# a redundant gh issue view call inside is_assigned().
		_dedup_result=$(ISSUE_META_JSON="$pre_fetched_json" "$_dedup_helper" is-assigned "$num" "$repo" "$_user" 2>/dev/null) || true
		if [[ -n "$_dedup_result" ]]; then
			print_warning "Skipping enrich for #$num ($task_id) — active claim detected: $_dedup_result (GH#19856)"
			return 0
		fi
	fi
	return 1
}

# _enrich_process_task: enrich a single task — resolve issue number, parse
# metadata, apply labels, update title/body. Outputs "ENRICHED" on success
# so the caller can count enriched tasks via token matching.
_enrich_process_task() {
	local task_id="$1" repo="$2" todo_file="$3" project_root="$4" task_line="${5:-}"
	if [[ -z "$task_line" ]]; then
		local task_id_ere
		task_id_ere=$(_escape_ere "$task_id")
		task_line=$(strip_code_fences <"$todo_file" | grep -E "^\s*- \[.\] ${task_id_ere} " | head -1 || echo "")
	fi
	local num
	num=$(echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
	[[ -z "$num" ]] && num=$(gh_find_issue_by_title "$repo" "${task_id}:" "all" 500)
	[[ -z "$num" ]] && {
		print_warning "$task_id: no issue found"
		return 0
	}

	local parsed
	parsed=$(parse_task_line "$task_line")
	local desc
	desc=$(echo "$parsed" | grep '^description=' | cut -d= -f2-)
	local tags
	tags=$(echo "$parsed" | grep '^tags=' | cut -d= -f2-)
	local labels
	labels=$(map_tags_to_labels "$tags")

	# Extract and validate tier from brief file. Held aside from the main
	# labels CSV — applied via _apply_tier_label_replace so any pre-existing
	# tier:* label is removed first (t2012).
	local brief_path="$project_root/todo/tasks/${task_id}-brief.md"
	local tier_label
	tier_label=$(_extract_tier_from_brief "$brief_path")
	if [[ -n "$tier_label" ]]; then
		tier_label=$(_validate_tier_checklist "$brief_path" "$tier_label")
	fi

	local title
	if ! title=$(_build_title "$task_id" "$desc"); then
		# Layer 3 follow-up (t2377): _build_title refused stub "tNNN: "
		# emission because description is empty. This is the t2377 data-loss
		# symptom — skip the enrich rather than forward an invalid title.
		print_error "Skipping enrich for $task_id — empty description; fix TODO entry before retrying (t2377)"
		return 0
	fi
	local body
	local _compose_rc=0
	body=$(compose_issue_body "$task_id" "$project_root") || _compose_rc=$?
	# Layer 1 (t2377): composition failure = no authoritative body available.
	# Skip the enrich entirely rather than emit an empty body. Previous
	# behaviour allowed empty body to reach _enrich_update_issue which, under
	# FORCE_ENRICH=true, executed `gh issue edit --body ""` and DESTROYED
	# the issue's original content (data loss: #19778/#19779/#19780).
	if [[ $_compose_rc -ne 0 || -z "$body" ]]; then
		print_error "Skipping enrich for $task_id — compose_issue_body failed (rc=$_compose_rc). Task ID is not in TODO.md; fix the TODO entry or remove the brief file (t2377)."
		return 0
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		local _dry_tier_msg=""
		[[ -n "$tier_label" ]] && _dry_tier_msg=" tier=${tier_label}(replace)"
		print_info "[DRY-RUN] Would enrich #$num ($task_id) labels=${labels}${_dry_tier_msg}"
		echo "ENRICHED"
		return 0
	fi

	# t2165: fetch title, body, and labels in a single gh issue view call and
	# forward to helpers. Each helper used to issue its own view+edit pair;
	# in steady state most of those calls produced no change but still cost
	# ~1.5s each. At ~145 open tasks × 4-5 calls each the work exceeded the
	# sync-on-push 10-minute cap. Forwarding pre-fetched state collapses the
	# per-task read cost to one call and lets each helper skip writes whose
	# target value already matches.
	local _state_json current_title="" current_body="" current_labels_csv=""
	# GH#20129: use batch-prefetched JSON when available to avoid per-task API
	# calls. ENRICH_PREFETCH_FILE is set by cmd_enrich before the loop via
	# _enrich_prefetch_issues_map. The prefetch includes all fields needed:
	# title, body, labels, state, assignees.
	if [[ -n "${ENRICH_PREFETCH_FILE:-}" && -f "$ENRICH_PREFETCH_FILE" && -n "$num" ]]; then
		_state_json=$(jq -c --argjson n "$num" '.[] | select(.number == $n)' \
			"$ENRICH_PREFETCH_FILE" 2>/dev/null || echo "")
	fi
	# Fall back to per-task API call on cache miss or prefetch unavailability.
	# GH#19922: include state,assignees so the pre-fetched JSON can be forwarded
	# to _enrich_check_active_claim → is_assigned(), avoiding a redundant API call.
	if [[ -z "$_state_json" ]]; then
		_state_json=$(gh issue view "$num" --repo "$repo" --json title,body,labels,state,assignees 2>/dev/null || echo "")
	fi
	if [[ -n "$_state_json" ]]; then
		current_title=$(echo "$_state_json" | jq -r '.title // ""' 2>/dev/null || echo "")
		current_body=$(echo "$_state_json" | jq -r '.body // ""' 2>/dev/null || echo "")
		current_labels_csv=$(echo "$_state_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null || echo "")
	fi

	# GH#19856: cross-runner dedup guard — abort if another runner holds
	# an active claim. See _enrich_check_active_claim for the full rationale.
	# GH#19922: pass _state_json so is_assigned() skips a redundant gh issue view.
	if _enrich_check_active_claim "$num" "$repo" "$task_id" "$_state_json"; then
		return 0
	fi

	_enrich_apply_labels "$repo" "$num" "$labels" "$tier_label" "$current_labels_csv"
	if _enrich_update_issue "$repo" "$num" "$task_id" "$title" "$body" "$current_title" "$current_body"; then
		print_success "Enriched #$num ($task_id)"
		# Sync relationships (blocked-by, sub-issues) after enrichment (t1889)
		sync_relationships_for_task "$task_id" "$todo_file" "$repo"
		echo "ENRICHED"
	fi
	return 0
}

cmd_enrich() {
	local target_task="${1:-}"
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO" project_root="$_CMD_ROOT"

	local tasks=()
	while IFS= read -r tid; do
		[[ -n "$tid" ]] && tasks+=("$tid")
	done < <(_enrich_build_task_list "$target_task" "$todo_file")
	[[ ${#tasks[@]} -eq 0 ]] && {
		print_info "No tasks to enrich"
		return 0
	}
	print_info "Enriching ${#tasks[@]} issue(s) in $repo"

	# GH#20129 Approach B: rate-limit probe — skip the entire enrich step if the
	# GraphQL bucket is below threshold (default 250). Avoids 162 GUARD_UNCERTAIN
	# warnings when the rate limit was exhausted before the loop started.
	# Skipped for single-task enrichment (target_task set) — the per-task call
	# is the cheapest path when enriching only one issue.
	if [[ -z "$target_task" ]] && _enrich_check_rate_limit; then
		return 0
	fi

	# GH#20129 Approach A: batch prefetch — issue ONE gh issue list call for all
	# open issues instead of per-task gh issue view calls. The prefetch JSON is
	# written to a temp file and referenced via ENRICH_PREFETCH_FILE. Each call
	# to _enrich_process_task reads from the file, falling back to per-task view
	# only on cache miss (e.g. issues not in the open list).
	local _prefetch_ok=false
	ENRICH_PREFETCH_FILE=""
	if [[ -z "$target_task" ]]; then
		if _enrich_prefetch_issues_map "$repo"; then
			_prefetch_ok=true
		fi
	fi

	local enriched=0
	for task_id in "${tasks[@]}"; do
		local result
		result=$(_enrich_process_task "$task_id" "$repo" "$todo_file" "$project_root")
		[[ "$result" == *"ENRICHED"* ]] && enriched=$((enriched + 1))
	done
	print_info "Enrich complete: $enriched updated"

	# Clean up prefetch temp file
	if [[ "$_prefetch_ok" == "true" && -n "${ENRICH_PREFETCH_FILE:-}" && -f "$ENRICH_PREFETCH_FILE" ]]; then
		rm -f "$ENRICH_PREFETCH_FILE" 2>/dev/null || true
		ENRICH_PREFETCH_FILE=""
	fi
	return 0
}

cmd_pull() {
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO"
	print_info "Pulling issue refs from GitHub ($repo) to TODO.md..."

	local synced=0 orphan_open=0 orphan_closed=0 assignee_synced=0 orphan_list=""
	local orphan_seeded=0 orphan_skipped=0
	local state
	for state in open closed; do
		local json
		json=$(gh_list_issues "$repo" "$state" 200)
		while IFS= read -r issue_line; do
			local num title tid login
			num=$(echo "$issue_line" | jq -r '.number' 2>/dev/null || echo "")
			title=$(echo "$issue_line" | jq -r '.title' 2>/dev/null || echo "")
			tid=$(echo "$title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
			[[ -z "$tid" ]] && continue
			local tid_ere
			tid_ere=$(_escape_ere "$tid")

			# Ref sync
			if ! grep -qE "^\s*- \[.\] ${tid_ere} .*ref:GH#${num}" "$todo_file" 2>/dev/null; then
				if ! grep -qE "^\s*- \[.\] ${tid_ere} " "$todo_file" 2>/dev/null; then
					if [[ "$state" == "open" ]]; then
						# t2698: seed a TODO.md entry for the open orphan
						local labels_json
						labels_json=$(echo "$issue_line" | jq -r '.labels // []' 2>/dev/null || echo "[]")
						if _seed_orphan_todo_line "$num" "$tid" "$title" "$labels_json" "$todo_file" "${DRY_RUN:-}"; then
							orphan_seeded=$((orphan_seeded + 1))
						else
							print_warning "ORPHAN: #$num ($tid: $title) — already in TODO.md"
							orphan_skipped=$((orphan_skipped + 1))
						fi
						orphan_open=$((orphan_open + 1))
						orphan_list="${orphan_list:+$orphan_list, }#$num ($tid)"
					else orphan_closed=$((orphan_closed + 1)); fi
					continue
				fi
				if [[ "$DRY_RUN" == "true" ]]; then
					print_info "[DRY-RUN] Would add ref:GH#$num to $tid"
					synced=$((synced + 1))
				else
					# GH#15234 Fix 4: check file modification to avoid misleading success
					# messages when add_gh_ref_to_todo silently skips (ref already exists)
					local tid_ere_pull
					tid_ere_pull=$(_escape_ere "$tid")
					local had_ref=false
					strip_code_fences <"$todo_file" | grep -qE "^\s*- \[.\] ${tid_ere_pull} .*ref:GH#${num}" && had_ref=true
					add_gh_ref_to_todo "$tid" "$num" "$todo_file"
					if [[ "$had_ref" == "false" ]] && strip_code_fences <"$todo_file" | grep -qE "^\s*- \[.\] ${tid_ere_pull} .*ref:GH#${num}"; then
						print_success "Added ref:GH#$num to $tid"
						synced=$((synced + 1))
					else
						log_verbose "ref:GH#$num already present for $tid — skipped"
					fi
				fi
			fi

			# Assignee sync (open issues only, in same pass)
			[[ "$state" != "open" ]] && continue
			login=$(echo "$issue_line" | jq -r '.assignees[0].login // empty' 2>/dev/null || echo "")
			[[ -z "$login" ]] && continue
			local tl
			tl=$(strip_code_fences <"$todo_file" | grep -E "^\s*- \[.\] ${tid_ere} " | head -1 || echo "")
			[[ -z "$tl" ]] && continue
			echo "$tl" | grep -qE 'assignee:[A-Za-z0-9._@-]+' && continue
			if [[ "$DRY_RUN" == "true" ]]; then
				print_info "[DRY-RUN] Would add assignee:$login to $tid"
				assignee_synced=$((assignee_synced + 1))
				continue
			fi
			local ln
			# Use awk to get line number while skipping code-fenced blocks
			ln=$(awk -v pat="^[[:space:]]*- \\[.\\] ${tid_ere} " '/^[[:space:]]*```/{f=!f; next} !f && $0 ~ pat {print NR; exit}' "$todo_file")
			if [[ -n "$ln" ]]; then
				local cl
				cl=$(sed -n "${ln}p" "$todo_file")
				local nl
				if echo "$cl" | grep -qE 'logged:'; then
					nl=$(echo "$cl" | sed -E "s/( logged:)/ assignee:${login}\1/")
				else nl="${cl} assignee:${login}"; fi
				local nl_escaped
				nl_escaped=$(printf '%s' "$nl" | sed 's/[|&\\]/\\&/g')
				sed_inplace "${ln}s|.*|${nl_escaped}|" "$todo_file"
				assignee_synced=$((assignee_synced + 1))
			fi
		done < <(echo "$json" | jq -c '.[]' 2>/dev/null || true)
	done

	printf "\n=== Pull Summary ===\nRefs synced: %d | Assignees: %d | Orphans seeded: %d | Orphans skipped: %d\n" \
		"$synced" "$assignee_synced" "$orphan_seeded" "$orphan_skipped"
	printf "Orphans open: %d closed: %d\n" "$orphan_open" "$orphan_closed"
	[[ $orphan_open -gt 0 ]] && print_warning "Open orphans: $orphan_list"
	[[ $synced -eq 0 && $assignee_synced -eq 0 && $orphan_open -eq 0 ]] && print_success "TODO.md refs up to date"
}

cmd_close() {
	local target_task="${1:-}"
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO"

	# Single-task mode
	if [[ -n "$target_task" ]]; then
		local target_ere
		target_ere=$(_escape_ere "$target_task")
		local task_line
		task_line=$(strip_code_fences <"$todo_file" | grep -E "^\s*- \[.\] ${target_ere} " | head -1 || echo "")
		local num
		num=$(echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		if [[ -z "$num" ]]; then
			num=$(gh_find_issue_by_title "$repo" "${target_task}:" "open" 500)
			[[ -n "$num" && "$DRY_RUN" != "true" ]] && add_gh_ref_to_todo "$target_task" "$num" "$todo_file"
		fi
		[[ -z "$num" ]] && {
			print_info "$target_task: no matching issue"
			return 0
		}
		local st
		st=$(gh issue view "$num" --repo "$repo" --json state --jq '.state' 2>/dev/null || echo "")
		[[ "$st" == "CLOSED" || "$st" == "closed" ]] && {
			log_verbose "#$num already closed"
			return 0
		}
		_do_close "$target_task" "$num" "$todo_file" "$repo" || true
		return 0
	fi

	# Bulk mode: fetch all open issues, build task->issue map
	local open_json
	open_json=$(gh_list_issues "$repo" "open" 500)
	local map=""
	while IFS='|' read -r n t; do
		[[ -z "$n" ]] && continue
		local tid
		tid=$(echo "$t" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
		[[ -n "$tid" ]] && map="${map}${tid}|${n}"$'\n'
	done < <(echo "$open_json" | jq -r '.[] | "\(.number)|\(.title)"' 2>/dev/null || true)
	[[ -z "$map" ]] && {
		print_info "No open issues to close"
		return 0
	}

	local closed=0 skipped=0 ref_fixed=0
	while IFS= read -r line; do
		local task_id
		task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		[[ -z "$task_id" ]] && continue
		local task_id_ere
		task_id_ere=$(_escape_ere "$task_id")
		local mapped
		mapped=$(echo "$map" | grep -E "^${task_id_ere}\|" | head -1 || echo "")
		[[ -z "$mapped" ]] && continue
		local issue_num="${mapped#*|}"
		local ref
		ref=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		if [[ "$DRY_RUN" != "true" ]]; then
			if [[ -n "$ref" && "$ref" != "$issue_num" ]]; then
				fix_gh_ref_in_todo "$task_id" "$ref" "$issue_num" "$todo_file"
				ref_fixed=$((ref_fixed + 1))
			elif [[ -z "$ref" ]]; then
				add_gh_ref_to_todo "$task_id" "$issue_num" "$todo_file"
				ref_fixed=$((ref_fixed + 1))
			fi
		fi
		if _do_close "$task_id" "$issue_num" "$todo_file" "$repo"; then closed=$((closed + 1)); else skipped=$((skipped + 1)); fi
	done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[(x|-)\] t[0-9]+' || true)
	print_info "Close: $closed closed, $skipped skipped, $ref_fixed refs fixed"
}

cmd_status() {
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO"
	local stripped
	stripped=$(strip_code_fences <"$todo_file")
	local total_open
	total_open=$(echo "$stripped" | grep -cE '^\s*- \[ \] t[0-9]+' || true)
	local total_done
	total_done=$(echo "$stripped" | grep -cE '^\s*- \[x\] t[0-9]+' || true)
	local with_ref
	with_ref=$(echo "$stripped" | grep -cE '^\s*- \[ \] t[0-9]+.*ref:GH#' || true)
	local without_ref=$((total_open - with_ref))

	local open_json
	open_json=$(gh_list_issues "$repo" "open" 500)
	local gh_open
	gh_open=$(echo "$open_json" | jq 'length' 2>/dev/null || echo "0")
	local gh_closed
	gh_closed=$(gh_list_issues "$repo" "closed" 500 | jq 'length' 2>/dev/null || echo "0")

	# Forward drift: open GH issue but TODO marked [x]
	local drift=0
	while IFS= read -r il; do
		local tid
		tid=$(echo "$il" | jq -r '.title' 2>/dev/null | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
		[[ -z "$tid" ]] && continue
		local tid_ere
		tid_ere=$(_escape_ere "$tid")
		grep -qE "^\s*- \[x\] ${tid_ere} " "$todo_file" 2>/dev/null && {
			drift=$((drift + 1))
			print_warning "DRIFT: #$(echo "$il" | jq -r '.number') ($tid) open but completed"
		}
	done < <(echo "$open_json" | jq -c '.[]' 2>/dev/null || true)

	# Reverse drift: open TODO [ ] but GH issue is closed
	# Build set of open issue numbers for fast lookup (avoids per-task API calls)
	local open_numbers
	open_numbers=$(echo "$open_json" | jq -r '.[].number' 2>/dev/null | sort -n)
	local reverse_drift=0
	while IFS= read -r line; do
		local ref_num
		ref_num=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		[[ -z "$ref_num" ]] && continue
		# If the referenced issue number is not in the open set, it's reverse drift
		if ! echo "$open_numbers" | grep -qx "$ref_num"; then
			local rtid
			rtid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
			reverse_drift=$((reverse_drift + 1))
			print_warning "REVERSE-DRIFT: $rtid ref:GH#$ref_num — TODO open but issue closed"
		fi
	done < <(echo "$stripped" | grep -E '^\s*- \[ \] t[0-9]+.*ref:GH#[0-9]+' || true)

	printf "\n=== Sync Status (%s) ===\nTODO open: %d (%d ref, %d no ref) | done: %d\nGitHub open: %s closed: %s | drift: %d | reverse-drift: %d\n" \
		"$repo" "$total_open" "$with_ref" "$without_ref" "$total_done" "$gh_open" "$gh_closed" "$drift" "$reverse_drift"
	[[ $without_ref -gt 0 ]] && print_warning "$without_ref tasks need push"
	[[ $drift -gt 0 ]] && print_warning "$drift tasks need close"
	[[ $reverse_drift -gt 0 ]] && print_warning "$reverse_drift open TODOs reference closed issues — run 'reconcile' to review"
	if [[ $without_ref -eq 0 && $drift -eq 0 && $reverse_drift -eq 0 ]]; then
		print_success "In sync"
	fi
	return 0
}

cmd_reconcile() {
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO"
	print_info "Reconciling ref:GH# values in $repo..."

	local ref_fixed=0 ref_ok=0 stale=0 orphans=0
	while IFS= read -r line; do
		local tid
		tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		local gh_ref
		gh_ref=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		[[ -z "$tid" || -z "$gh_ref" ]] && continue
		local it
		it=$(gh issue view "$gh_ref" --repo "$repo" --json title --jq '.title' 2>/dev/null || echo "")
		local itid
		itid=$(echo "$it" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
		[[ "$itid" == "$tid" ]] && {
			ref_ok=$((ref_ok + 1))
			continue
		}

		print_warning "MISMATCH: $tid ref:GH#$gh_ref -> '$it'"
		local correct
		correct=$(gh_find_issue_by_title "$repo" "${tid}:" "all" 500)
		if [[ -n "$correct" && "$correct" != "$gh_ref" ]]; then
			if [[ "$DRY_RUN" == "true" ]]; then
				print_info "[DRY-RUN] Fix $tid: #$gh_ref -> #$correct"
			else
				fix_gh_ref_in_todo "$tid" "$gh_ref" "$correct" "$todo_file"
				print_success "Fixed $tid: #$gh_ref -> #$correct"
			fi
			ref_fixed=$((ref_fixed + 1))
		fi
	done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[.\] t[0-9]+.*ref:GH#[0-9]+' || true)

	# Forward drift: open GH issue but TODO marked [x]
	local open_json
	open_json=$(gh_list_issues "$repo" "open" 200)
	while IFS= read -r il; do
		local num tid
		num=$(echo "$il" | jq -r '.number' 2>/dev/null || echo "")
		tid=$(echo "$il" | jq -r '.title' 2>/dev/null | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
		[[ -z "$tid" ]] && continue
		local tid_ere
		tid_ere=$(_escape_ere "$tid")
		grep -qE "^\s*- \[x\] ${tid_ere} " "$todo_file" 2>/dev/null && {
			print_warning "STALE: #$num ($tid) open but done"
			stale=$((stale + 1))
		}
		grep -qE "^\s*- \[.\] ${tid_ere} " "$todo_file" 2>/dev/null || orphans=$((orphans + 1))
	done < <(echo "$open_json" | jq -c '.[]' 2>/dev/null || true)

	# Reverse drift: open TODO [ ] but GH issue is closed
	# Build set of open issue numbers for fast lookup (avoids per-task API calls)
	local open_numbers
	open_numbers=$(echo "$open_json" | jq -r '.[].number' 2>/dev/null | sort -n)
	local reverse_drift=0
	local stripped
	stripped=$(strip_code_fences <"$todo_file")
	while IFS= read -r line; do
		local ref_num
		ref_num=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		[[ -z "$ref_num" ]] && continue
		if ! echo "$open_numbers" | grep -qx "$ref_num"; then
			local rtid
			rtid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
			reverse_drift=$((reverse_drift + 1))
			print_warning "REVERSE-DRIFT: $rtid ref:GH#$ref_num — TODO open but issue closed"
		fi
	done < <(echo "$stripped" | grep -E '^\s*- \[ \] t[0-9]+.*ref:GH#[0-9]+' || true)

	printf "\n=== Reconciliation ===\nRefs OK: %d | fixed: %d | stale: %d | orphans: %d | reverse-drift: %d\n" \
		"$ref_ok" "$ref_fixed" "$stale" "$orphans" "$reverse_drift"
	[[ $stale -gt 0 ]] && print_info "Run 'issue-sync-helper.sh close' for stale issues"
	[[ $reverse_drift -gt 0 ]] && print_warning "$reverse_drift open TODOs reference closed issues — review each: reopen issue or mark TODO [x]"
	[[ $ref_fixed -eq 0 && $stale -eq 0 && $orphans -eq 0 && $reverse_drift -eq 0 ]] && print_success "All refs correct"
}

# Reopen closed GitHub issues whose TODO entries are still open [ ].
# TODO.md is the source of truth: if a task is [ ], the work is not done,
# regardless of whether a commit message prematurely closed the issue.
#
# Decision tree per closed issue:
#   NOT_PLANNED         → skip (deliberately declined)
#   COMPLETED + has PR  → skip (work done, TODO needs marking [x] separately)
#   COMPLETED + no PR   → reopen (premature closure from commit keyword)
cmd_reopen() {
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO"

	# Build set of open issue numbers for fast lookup
	local open_json
	open_json=$(gh_list_issues "$repo" "open" 500)
	local open_numbers
	open_numbers=$(echo "$open_json" | jq -r '.[].number' 2>/dev/null | sort -n)

	local stripped
	stripped=$(strip_code_fences <"$todo_file")
	local reopened=0 skipped=0 not_planned=0 has_pr=0

	while IFS= read -r line; do
		local ref_num
		ref_num=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		[[ -z "$ref_num" ]] && continue

		# Skip if already open
		echo "$open_numbers" | grep -qx "$ref_num" && continue

		local tid
		tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")

		# Check closure reason — skip NOT_PLANNED (deliberately declined)
		local reason
		reason=$(gh issue view "$ref_num" --repo "$repo" --json stateReason --jq '.stateReason' 2>/dev/null || echo "")
		if [[ "$reason" == "NOT_PLANNED" ]]; then
			log_verbose "#$ref_num ($tid) closed as NOT_PLANNED — skipping"
			not_planned=$((not_planned + 1))
			continue
		fi

		# Check if a merged PR exists for this task — if so, the closure is
		# legitimate (work done). Mark TODO [x] with pr:# instead of reopening.
		local pr_info
		pr_info=$(gh_find_merged_pr "$repo" "$tid" 2>/dev/null || echo "")
		if [[ -n "$pr_info" ]]; then
			local pr_num="${pr_info%%|*}"
			if [[ "$DRY_RUN" == "true" ]]; then
				print_info "[DRY-RUN] Would mark $tid [x] (merged PR #$pr_num)"
			else
				add_pr_ref_to_todo "$tid" "$pr_num" "$todo_file" 2>/dev/null || true
				_mark_todo_done "$tid" "$todo_file"
				log_verbose "#$ref_num ($tid) has merged PR #$pr_num — marked TODO [x]"
			fi
			has_pr=$((has_pr + 1))
			continue
		fi

		if [[ "$DRY_RUN" == "true" ]]; then
			print_info "[DRY-RUN] Would reopen #$ref_num ($tid)"
			reopened=$((reopened + 1))
			continue
		fi

		gh issue reopen "$ref_num" --repo "$repo" \
			--comment "Reopened: TODO.md still has this as \`[ ]\` (open) and no merged PR was found. The issue was prematurely closed by a commit keyword. TODO.md is the source of truth for task state." 2>/dev/null && {
			reopened=$((reopened + 1))
			print_success "Reopened #$ref_num ($tid)"
		} || {
			skipped=$((skipped + 1))
			print_warning "Failed to reopen #$ref_num ($tid)"
		}
	done < <(echo "$stripped" | grep -E '^\s*- \[ \] t[0-9]+.*ref:GH#[0-9]+' || true)

	print_info "Reopen: $reopened reopened, $skipped failed, $not_planned not-planned, $has_pr have-merged-pr"
	return 0
}

# =============================================================================
# Relationships & Backfill (extracted to issue-sync-relationships.sh — GH#19502)
# =============================================================================
# shellcheck source=issue-sync-relationships.sh
source "${SCRIPT_DIR}/issue-sync-relationships.sh"

cmd_help() {
	cat <<'EOF'
Issue Sync Helper — stateless TODO.md <-> GitHub Issues sync via gh CLI.
Usage: issue-sync-helper.sh [command] [options]
Commands: push [tNNN] | enrich [tNNN] | pull | close [tNNN] | reopen
          reconcile | relationships [tNNN] | backfill-sub-issues [--issue N]
          status | help
Options: --repo SLUG | --dry-run | --verbose | --force (skip evidence on close; bypass enrich body-gate)
         --force-push (allow bulk push outside CI — use with caution, risk of duplicates)

Drift detection:
  status    — reports forward drift (open issue, done TODO) and reverse drift
              (open TODO, closed issue) without making changes.
  reconcile — same detection plus ref mismatches, with actionable guidance.
  reopen    — reopens closed issues whose TODO entry is still [ ] (open).
              Only reopens issues closed as COMPLETED, not NOT_PLANNED.
              Safe for automated use in the pulse.

Relationships (t1889):
  relationships [tNNN] — sync blocked-by/blocks and subtask hierarchy to GitHub
                         issue relationships. Without tNNN, processes all tasks
                         that have ref:GH# plus blocked-by:/blocks: or subtask IDs.
                         Use --dry-run to preview. Idempotent (skips existing).

Sub-issue backfill (t2114):
  backfill-sub-issues [--issue N] — link decomposition children to their
                         parents using GitHub state alone (title + body). No
                         TODO.md or brief file required. Detects parents via:
                         (1) dot-notation title `tNNN.M: ...`, (2) `Parent: ...`
                         line in body, (3) `Blocked by: tNNN` where the blocker
                         carries the `parent-task` label. Idempotent; supports
                         --dry-run.

Note: Bulk push (no task ID) is CI-only by default to prevent duplicate issues.
      Use 'push <task_id>' for single tasks, or --force-push to override.
EOF
}

main() {
	local command="" positional_args=()
	while [[ $# -gt 0 ]]; do
		local arg="$1" val="${2:-}"
		case "$arg" in
		--repo)
			REPO_SLUG="$val"
			shift 2
			;;
		--dry-run)
			DRY_RUN="true"
			shift
			;;
		--verbose)
			VERBOSE="true"
			shift
			;;
		--force)
			FORCE_CLOSE="true"
			FORCE_ENRICH="true"
			shift
			;;
		--force-push)
			FORCE_PUSH="true"
			shift
			;;
		help | --help | -h)
			cmd_help
			return 0
			;;
		*)
			positional_args+=("$arg")
			shift
			;;
		esac
	done
	command="${positional_args[0]:-help}"
	case "$command" in
	push) cmd_push "${positional_args[1]:-}" ;; enrich) cmd_enrich "${positional_args[1]:-}" ;;
	pull) cmd_pull ;; close) cmd_close "${positional_args[1]:-}" ;; reopen) cmd_reopen ;;
	reconcile) cmd_reconcile ;; relationships) cmd_relationships "${positional_args[1]:-}" ;;
	backfill-sub-issues)
		if [[ ${#positional_args[@]} -gt 1 ]]; then
			cmd_backfill_sub_issues "${positional_args[@]:1}"
		else
			cmd_backfill_sub_issues
		fi
		;;
	status) cmd_status ;; help) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

# t2063: only execute main when run as a script, not when sourced by tests.
# This allows test harnesses to source the file for access to function
# definitions (e.g. _enrich_update_issue) without triggering main()'s command
# parsing and print_help output.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
