#!/bin/bash
# Intentionally using /bin/bash (not /usr/bin/env bash) for headless compatibility.
# Some MCP/headless runners provide a stripped PATH where env cannot resolve bash.
# Keep this exception aligned with issue #2610 and t135.14 standardization context.
# shellcheck disable=SC2155
# =============================================================================
# aidevops Issue Sync Helper (Simplified)
# =============================================================================
# Stateless bi-directional sync between TODO.md and GitHub Issues via gh CLI.
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
REPO_SLUG=""

log_verbose() {
	[[ "$VERBOSE" == "true" ]] && print_info "$1"
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
	if [[ "$description" == *" — "* ]]; then
		echo "${task_id}: ${description%% — *}"
	elif [[ ${#description} -gt 80 ]]; then
		echo "${task_id}: ${description:0:77}..."
	else echo "${task_id}: ${description}"; fi
}

# =============================================================================
# GitHub API (gh CLI wrappers — kept for multi-call functions only)
# =============================================================================

gh_list_issues() {
	local repo="$1" state="$2" limit="$3"
	gh issue list --repo "$repo" --state "$state" --limit "$limit" \
		--json number,title,assignees,state 2>/dev/null || echo "[]"
}

_gh_edit_labels() {
	local action="$1" repo="$2" num="$3" labels="$4"
	local -a args=()
	local IFS=','
	for lbl in $labels; do [[ -n "$lbl" ]] && args+=("--${action}-label" "$lbl"); done
	unset IFS
	[[ ${#args[@]} -gt 0 ]] && gh issue edit "$num" --repo "$repo" "${args[@]}" 2>/dev/null || true
}

gh_create_label() {
	local repo="$1" name="$2" color="$3" desc="$4"
	gh label create "$name" --repo "$repo" --color "$color" --description "$desc" --force 2>/dev/null || true
}

gh_find_issue_by_title() {
	local repo="$1" prefix="$2" state="${3:-all}" limit="${4:-500}"
	gh issue list --repo "$repo" --state "$state" --limit "$limit" \
		--json number,title --jq "[.[] | select(.title | startswith(\"${prefix}\"))][0].number" 2>/dev/null || echo ""
}

gh_find_merged_pr() {
	local repo="$1" task_id="$2"
	gh pr list --repo "$repo" --state merged --search "$task_id in:title" \
		--limit 1 --json number,url 2>/dev/null | jq -r '.[0] | select(. != null) | "\(.number)|\(.url)"' || true
}

ensure_labels_exist() {
	local labels="$1" repo="$2"
	[[ -z "$labels" || -z "$repo" ]] && return 0
	local _saved_ifs="$IFS"
	IFS=','
	for lbl in $labels; do [[ -n "$lbl" ]] && gh_create_label "$repo" "$lbl" "EDEDED" "Auto-created from TODO.md tag"; done
	IFS="$_saved_ifs"
}

# Status labels to remove when marking an issue done (t3517: array for safe iteration).
_DONE_REMOVE_LABELS=("status:available" "status:queued" "status:claimed" "status:in-review" "status:blocked" "status:verify-failed")

_mark_issue_done() {
	local repo="$1" num="$2"
	local -a remove_args=()
	local lbl
	for lbl in "${_DONE_REMOVE_LABELS[@]}"; do
		remove_args+=("--remove-label" "$lbl")
	done
	gh_create_label "$repo" "status:done" "6F42C1" "Task is complete"
	_gh_edit_labels "add" "$repo" "$num" "status:done"
	[[ ${#remove_args[@]} -gt 0 ]] && gh issue edit "$num" --repo "$repo" "${remove_args[@]}" 2>/dev/null || true
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

	# Race-condition guard: re-check immediately before creating
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
	return 0
}

# _push_process_task: process a single task_id — skip if existing/completed,
# parse metadata, dry-run or create issue. Updates created/skipped counters
# via stdout tokens "CREATED" or "SKIPPED" for the caller to count.
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
	title=$(_build_title "$task_id" "$description")
	local labels
	labels=$(map_tags_to_labels "$tags")
	local body
	body=$(compose_issue_body "$task_id" "$project_root")

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
		add_gh_ref_to_todo "$task_id" "$_PUSH_CREATED_NUM" "$todo_file"
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

cmd_enrich() {
	local target_task="${1:-}"
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO" project_root="$_CMD_ROOT"

	local tasks=()
	if [[ -n "$target_task" ]]; then
		tasks=("$target_task")
	else
		while IFS= read -r line; do
			local tid
			tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
			[[ -n "$tid" ]] && tasks+=("$tid")
		done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[ \] t[0-9]+.*ref:GH#[0-9]+' || true)
	fi
	[[ ${#tasks[@]} -eq 0 ]] && {
		print_info "No tasks to enrich"
		return 0
	}
	print_info "Enriching ${#tasks[@]} issue(s) in $repo"

	local enriched=0
	for task_id in "${tasks[@]}"; do
		local task_id_ere
		task_id_ere=$(_escape_ere "$task_id")
		local task_line
		task_line=$(strip_code_fences <"$todo_file" | grep -E "^\s*- \[.\] ${task_id_ere} " | head -1 || echo "")
		local num
		num=$(echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		[[ -z "$num" ]] && num=$(gh_find_issue_by_title "$repo" "${task_id}:" "all" 500)
		[[ -z "$num" || "$num" == "null" ]] && {
			print_warning "$task_id: no issue found"
			continue
		}

		local parsed
		parsed=$(parse_task_line "$task_line")
		local desc
		desc=$(echo "$parsed" | grep '^description=' | cut -d= -f2-)
		local tags
		tags=$(echo "$parsed" | grep '^tags=' | cut -d= -f2-)
		local labels
		labels=$(map_tags_to_labels "$tags")
		local title
		title=$(_build_title "$task_id" "$desc")
		local body
		body=$(compose_issue_body "$task_id" "$project_root")

		if [[ "$DRY_RUN" == "true" ]]; then
			print_info "[DRY-RUN] Would enrich #$num ($task_id)"
			enriched=$((enriched + 1))
			continue
		fi
		[[ -n "$labels" ]] && {
			ensure_labels_exist "$labels" "$repo"
			_gh_edit_labels "add" "$repo" "$num" "$labels"
		}
		if gh issue edit "$num" --repo "$repo" --title "$title" --body "$body" 2>/dev/null; then
			print_success "Enriched #$num ($task_id)"
			enriched=$((enriched + 1))
		else print_error "Failed to enrich #$num ($task_id)"; fi
	done
	print_info "Enrich complete: $enriched updated"
}

cmd_pull() {
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO"
	print_info "Pulling issue refs from GitHub ($repo) to TODO.md..."

	local synced=0 orphan_open=0 orphan_closed=0 assignee_synced=0 orphan_list=""
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
						print_warning "ORPHAN: #$num ($tid: $title) — no TODO.md entry"
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

	printf "\n=== Pull Summary ===\nRefs synced: %d | Assignees: %d | Orphans open: %d closed: %d\n" \
		"$synced" "$assignee_synced" "$orphan_open" "$orphan_closed"
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
			[[ -n "$num" && "$num" != "null" && "$DRY_RUN" != "true" ]] && add_gh_ref_to_todo "$target_task" "$num" "$todo_file"
		fi
		[[ -z "$num" || "$num" == "null" ]] && {
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

	printf "\n=== Sync Status (%s) ===\nTODO open: %d (%d ref, %d no ref) | done: %d\nGitHub open: %s closed: %s | drift: %d\n" \
		"$repo" "$total_open" "$with_ref" "$without_ref" "$total_done" "$gh_open" "$gh_closed" "$drift"
	[[ $without_ref -gt 0 ]] && print_warning "$without_ref tasks need push"
	[[ $drift -gt 0 ]] && print_warning "$drift tasks need close"
	[[ $without_ref -eq 0 && $drift -eq 0 ]] && print_success "In sync"
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
		if [[ -n "$correct" && "$correct" != "null" && "$correct" != "$gh_ref" ]]; then
			if [[ "$DRY_RUN" == "true" ]]; then
				print_info "[DRY-RUN] Fix $tid: #$gh_ref -> #$correct"
			else
				fix_gh_ref_in_todo "$tid" "$gh_ref" "$correct" "$todo_file"
				print_success "Fixed $tid: #$gh_ref -> #$correct"
			fi
			ref_fixed=$((ref_fixed + 1))
		fi
	done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[.\] t[0-9]+.*ref:GH#[0-9]+' || true)

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

	printf "\n=== Reconciliation ===\nRefs OK: %d | fixed: %d | stale: %d | orphans: %d\n" "$ref_ok" "$ref_fixed" "$stale" "$orphans"
	[[ $stale -gt 0 ]] && print_info "Run 'issue-sync-helper.sh close' for stale issues"
	[[ $ref_fixed -eq 0 && $stale -eq 0 && $orphans -eq 0 ]] && print_success "All refs correct"
}

cmd_help() {
	cat <<'EOF'
Issue Sync Helper — stateless TODO.md <-> GitHub Issues sync via gh CLI.
Usage: issue-sync-helper.sh [command] [options]
Commands: push [tNNN] | enrich [tNNN] | pull | close [tNNN] | reconcile | status | help
Options: --repo SLUG | --dry-run | --verbose | --force (skip evidence on close)
         --force-push (allow bulk push outside CI — use with caution, risk of duplicates)

Note: Bulk push (no task ID) is CI-only by default to prevent duplicate issues.
      Use 'push <task_id>' for single tasks, or --force-push to override.
EOF
}

main() {
	local command="" positional_args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			REPO_SLUG="$2"
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
			positional_args+=("$1")
			shift
			;;
		esac
	done
	command="${positional_args[0]:-help}"
	case "$command" in
	push) cmd_push "${positional_args[1]:-}" ;; enrich) cmd_enrich "${positional_args[1]:-}" ;;
	pull) cmd_pull ;; close) cmd_close "${positional_args[1]:-}" ;;
	reconcile) cmd_reconcile ;; status) cmd_status ;; help) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
