#!/usr/bin/env bash
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=issue-sync-lib.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/issue-sync-lib.sh"

# =============================================================================
# Configuration
# =============================================================================

VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
FORCE_CLOSE="${FORCE_CLOSE:-false}"
REPO_SLUG=""

# =============================================================================
# Utility
# =============================================================================

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
	return 0
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

# Build concise issue title from task description
_build_title() {
	local task_id="$1" description="$2"
	if [[ "$description" == *" — "* ]]; then
		echo "${task_id}: ${description%% — *}"
	elif [[ ${#description} -gt 80 ]]; then
		echo "${task_id}: ${description:0:77}..."
	else
		echo "${task_id}: ${description}"
	fi
	return 0
}

# =============================================================================
# GitHub API (gh CLI wrappers)
# =============================================================================

gh_create_issue() {
	local repo="$1" title="$2" body="$3" labels="$4" assignee="${5:-}"
	local -a args=("issue" "create" "--repo" "$repo" "--title" "$title" "--body" "$body")
	[[ -n "$labels" ]] && args+=("--label" "$labels")
	[[ -n "$assignee" ]] && args+=("--assignee" "$assignee")
	gh "${args[@]}" 2>/dev/null || echo ""
	return 0
}

gh_close_issue() {
	local repo="$1" num="$2" comment="$3"
	gh issue close "$num" --repo "$repo" --comment "$comment" 2>/dev/null
	return $?
}

gh_edit_issue() {
	local repo="$1" num="$2" title="$3" body="$4"
	gh issue edit "$num" --repo "$repo" --title "$title" --body "$body" 2>/dev/null
	return $?
}

gh_list_issues() {
	local repo="$1" state="$2" limit="$3"
	gh issue list --repo "$repo" --state "$state" --limit "$limit" \
		--json number,title,assignees,state 2>/dev/null || echo "[]"
	return 0
}

gh_add_labels() {
	local repo="$1" num="$2" labels="$3"
	local -a args=()
	local IFS=','
	for lbl in $labels; do [[ -n "$lbl" ]] && args+=("--add-label" "$lbl"); done
	unset IFS
	[[ ${#args[@]} -gt 0 ]] && gh issue edit "$num" --repo "$repo" "${args[@]}" 2>/dev/null || true
	return 0
}

gh_remove_labels() {
	local repo="$1" num="$2" labels="$3"
	local -a args=()
	local IFS=','
	for lbl in $labels; do [[ -n "$lbl" ]] && args+=("--remove-label" "$lbl"); done
	unset IFS
	[[ ${#args[@]} -gt 0 ]] && gh issue edit "$num" --repo "$repo" "${args[@]}" 2>/dev/null || true
	return 0
}

gh_create_label() {
	local repo="$1" name="$2" color="$3" desc="$4"
	gh label create "$name" --repo "$repo" --color "$color" --description "$desc" --force 2>/dev/null || true
	return 0
}

gh_view_issue() {
	local repo="$1" num="$2"
	gh issue view "$num" --repo "$repo" --json number,title,state,assignees 2>/dev/null || echo "{}"
	return 0
}

gh_find_issue_by_title() {
	local repo="$1" prefix="$2" state="${3:-all}" limit="${4:-50}"
	gh issue list --repo "$repo" --state "$state" --limit "$limit" \
		--json number,title --jq "[.[] | select(.title | startswith(\"${prefix}\"))][0].number" 2>/dev/null || echo ""
	return 0
}

gh_find_merged_pr() {
	local repo="$1" task_id="$2"
	local data
	data=$(gh pr list --repo "$repo" --state merged --search "$task_id in:title" \
		--limit 1 --json number,url 2>/dev/null | jq -r '.[0] | select(. != null) | "\(.number)|\(.url)"' || echo "")
	[[ -n "$data" ]] && echo "$data"
	return 0
}

ensure_labels_exist() {
	local labels="$1" repo="$2"
	[[ -z "$labels" || -z "$repo" ]] && return 0
	local _saved_ifs="$IFS"
	IFS=','
	for lbl in $labels; do [[ -n "$lbl" ]] && gh_create_label "$repo" "$lbl" "EDEDED" "Auto-created from TODO.md tag"; done
	IFS="$_saved_ifs"
	return 0
}

# Mark issue as done with status labels
_mark_issue_done() {
	local repo="$1" num="$2"
	gh_create_label "$repo" "status:done" "6F42C1" "Task is complete"
	gh_add_labels "$repo" "$num" "status:done"
	gh_remove_labels "$repo" "$num" "status:available,status:queued,status:claimed,status:in-review,status:blocked,status:verify-failed"
	return 0
}

# =============================================================================
# Close Helpers
# =============================================================================

_has_evidence() {
	local text="$1" task_id="$2" repo="$3"
	echo "$text" | grep -qE 'verified:[0-9]{4}-[0-9]{2}-[0-9]{2}' && return 0
	echo "$text" | grep -qE 'pr:#[0-9]+' && return 0
	echo "$text" | grep -qiE 'PR #[0-9]+ merged|PR.*merged' && return 0
	[[ -n "$repo" ]] && {
		local m
		m=$(gh_find_merged_pr "$repo" "$task_id" || echo "")
		[[ -n "$m" ]] && return 0
	}
	return 1
}

_find_closing_pr() {
	local text="$1" task_id="$2" repo="$3"
	local pr
	pr=$(echo "$text" | grep -oE 'pr:#[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
	[[ -n "$pr" ]] && {
		echo "${pr}|https://github.com/${repo}/pull/${pr}"
		return 0
	}
	pr=$(echo "$text" | grep -oiE 'PR #[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
	[[ -n "$pr" ]] && {
		echo "${pr}|https://github.com/${repo}/pull/${pr}"
		return 0
	}
	if [[ -n "$repo" ]]; then
		local info
		info=$(gh_find_merged_pr "$repo" "$task_id" || echo "")
		[[ -n "$info" ]] && {
			echo "$info"
			return 0
		}
		local parent
		parent=$(echo "$task_id" | grep -oE '^t[0-9]+' || echo "")
		if [[ -n "$parent" && "$parent" != "$task_id" ]]; then
			info=$(gh_find_merged_pr "$repo" "$parent" || echo "")
			[[ -n "$info" ]] && {
				echo "$info"
				return 0
			}
		fi
	fi
	return 1
}

_close_comment() {
	local task_id="$1" text="$2" pr_num="$3" pr_url="$4"
	if [[ -n "$pr_num" && -n "$pr_url" ]]; then
		echo "Completed via [PR #${pr_num}](${pr_url}). Task $task_id done in TODO.md."
	elif [[ -n "$pr_num" ]]; then
		echo "Completed via PR #${pr_num}. Task $task_id done in TODO.md."
	elif echo "$text" | grep -qE 'verified:[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
		local d
		d=$(echo "$text" | grep -oE 'verified:[0-9-]+' | head -1 | sed 's/verified://')
		echo "Completed (verified: $d). Task $task_id done in TODO.md."
	else
		echo "Completed. Task $task_id done in TODO.md."
	fi
	return 0
}

# Close a single issue with evidence check, PR discovery, label update
_do_close() {
	local task_id="$1" issue_number="$2" todo_file="$3" repo="$4"
	local task_with_notes
	task_with_notes=$(extract_task_block "$task_id" "$todo_file")
	local task_line
	task_line=$(grep -E "^\s*- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
	[[ -z "$task_with_notes" ]] && task_with_notes="$task_line"

	local pr_info pr_num="" pr_url=""
	pr_info=$(_find_closing_pr "$task_with_notes" "$task_id" "$repo" 2>/dev/null || echo "")
	if [[ -n "$pr_info" ]]; then
		pr_num="${pr_info%%|*}"
		pr_url="${pr_info#*|}"
		[[ "$DRY_RUN" != "true" && -n "$pr_num" ]] && add_pr_ref_to_todo "$task_id" "$pr_num" "$todo_file"
		# Re-read after modification
		task_line=$(grep -E "^\s*- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
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
	if gh_close_issue "$repo" "$issue_number" "$comment"; then
		_mark_issue_done "$repo" "$issue_number"
		print_success "Closed #$issue_number ($task_id)"
		return 0
	fi
	print_error "Failed to close #$issue_number ($task_id)"
	return 1
}

# =============================================================================
# Commands
# =============================================================================

cmd_push() {
	local target_task="${1:-}"
	local project_root
	project_root=$(find_project_root) || return 1
	local repo="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
	local todo_file="$project_root/TODO.md"
	verify_gh_cli || return 1

	local tasks=()
	if [[ -n "$target_task" ]]; then
		tasks=("$target_task")
	else
		while IFS= read -r line; do
			local tid
			tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
			[[ -n "$tid" ]] && ! echo "$line" | grep -qE 'ref:GH#[0-9]+' && tasks+=("$tid")
		done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[ \] t[0-9]+' || true)
	fi
	[[ ${#tasks[@]} -eq 0 ]] && {
		print_info "No tasks to push"
		return 0
	}

	print_info "Processing ${#tasks[@]} task(s) for push to $repo"
	gh_create_label "$repo" "status:available" "0E8A16" "Task is available for claiming"

	local created=0 skipped=0
	for task_id in "${tasks[@]}"; do
		log_verbose "Processing $task_id..."
		local existing
		existing=$(gh_find_issue_by_title "$repo" "${task_id}:" "all" 50)
		if [[ -n "$existing" && "$existing" != "null" ]]; then
			add_gh_ref_to_todo "$task_id" "$existing" "$todo_file"
			skipped=$((skipped + 1))
			continue
		fi

		local task_line
		task_line=$(grep -E "^\s*- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
		[[ -z "$task_line" ]] && {
			print_warning "Task $task_id not found in TODO.md"
			continue
		}

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
			created=$((created + 1))
			continue
		fi

		[[ -n "$labels" ]] && ensure_labels_exist "$labels" "$repo"
		local status_label="status:available"
		[[ -n "$assignee" ]] && {
			status_label="status:claimed"
			gh_create_label "$repo" "status:claimed" "D93F0B" "Task is claimed"
		}
		local all_labels="${labels:+${labels},}${status_label}"

		# Race-condition guard
		local recheck
		recheck=$(gh_find_issue_by_title "$repo" "${task_id}:" "all" 50)
		if [[ -n "$recheck" && "$recheck" != "null" ]]; then
			add_gh_ref_to_todo "$task_id" "$recheck" "$todo_file"
			skipped=$((skipped + 1))
			continue
		fi

		local url
		url=$(gh_create_issue "$repo" "$title" "$body" "$all_labels" "$assignee")
		[[ -z "$url" ]] && {
			print_error "Failed to create issue for $task_id"
			continue
		}
		local num
		num=$(echo "$url" | grep -oE '[0-9]+$' || echo "")
		[[ -n "$num" ]] && {
			print_success "Created #$num: $title"
			add_gh_ref_to_todo "$task_id" "$num" "$todo_file"
			created=$((created + 1))
		}
	done
	print_info "Push complete: $created created, $skipped skipped"
	return 0
}

cmd_enrich() {
	local target_task="${1:-}"
	local project_root
	project_root=$(find_project_root) || return 1
	local repo="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
	local todo_file="$project_root/TODO.md"
	verify_gh_cli || return 1

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
		local task_line
		task_line=$(grep -E "^\s*- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
		local num
		num=$(echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		[[ -z "$num" ]] && num=$(gh_find_issue_by_title "$repo" "${task_id}:" "all" 50)
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
			gh_add_labels "$repo" "$num" "$labels"
		}
		if gh_edit_issue "$repo" "$num" "$title" "$body"; then
			print_success "Enriched #$num ($task_id)"
			enriched=$((enriched + 1))
		else print_error "Failed to enrich #$num ($task_id)"; fi
	done
	print_info "Enrich complete: $enriched updated"
	return 0
}

# Pull: sync issue refs and assignees from GitHub → TODO.md
cmd_pull() {
	local project_root
	project_root=$(find_project_root) || return 1
	local repo="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
	local todo_file="$project_root/TODO.md"
	verify_gh_cli || return 1
	print_info "Pulling issue refs from GitHub ($repo) to TODO.md..."

	local synced=0 orphan_open=0 orphan_closed=0 assignee_synced=0 orphan_list=""

	# Process both open and closed issues for ref sync
	local state
	for state in open closed; do
		local json
		json=$(gh_list_issues "$repo" "$state" 200)
		while IFS= read -r issue_line; do
			local num
			num=$(echo "$issue_line" | jq -r '.number' 2>/dev/null || echo "")
			local title
			title=$(echo "$issue_line" | jq -r '.title' 2>/dev/null || echo "")
			local tid
			tid=$(echo "$title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
			[[ -z "$tid" ]] && continue

			# Skip if ref already exists
			grep -qE "^\s*- \[.\] ${tid} .*ref:GH#${num}" "$todo_file" 2>/dev/null && continue

			# Check task exists in TODO.md
			if ! grep -qE "^\s*- \[.\] ${tid} " "$todo_file" 2>/dev/null; then
				if [[ "$state" == "open" ]]; then
					print_warning "ORPHAN: #$num ($tid: $title) — no TODO.md entry"
					orphan_open=$((orphan_open + 1))
					orphan_list="${orphan_list:+$orphan_list, }#$num ($tid)"
				else
					orphan_closed=$((orphan_closed + 1))
				fi
				continue
			fi

			if [[ "$DRY_RUN" == "true" ]]; then
				print_info "[DRY-RUN] Would add ref:GH#$num to $tid"
				synced=$((synced + 1))
				continue
			fi
			add_gh_ref_to_todo "$tid" "$num" "$todo_file"
			print_success "Added ref:GH#$num to $tid"
			synced=$((synced + 1))
		done < <(echo "$json" | jq -c '.[]' 2>/dev/null || true)

		# Assignee sync (open issues only)
		if [[ "$state" == "open" ]]; then
			while IFS= read -r issue_line; do
				local num
				num=$(echo "$issue_line" | jq -r '.number' 2>/dev/null || echo "")
				local title
				title=$(echo "$issue_line" | jq -r '.title' 2>/dev/null || echo "")
				local login
				login=$(echo "$issue_line" | jq -r '.assignees[0].login // empty' 2>/dev/null || echo "")
				local tid
				tid=$(echo "$title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
				[[ -z "$tid" || -z "$login" ]] && continue
				grep -qE "^\s*- \[.\] ${tid} " "$todo_file" 2>/dev/null || continue
				local tl
				tl=$(grep -E "^\s*- \[.\] ${tid} " "$todo_file" | head -1 || echo "")
				echo "$tl" | grep -qE 'assignee:[A-Za-z0-9._@-]+' && continue

				if [[ "$DRY_RUN" == "true" ]]; then
					print_info "[DRY-RUN] Would add assignee:$login to $tid"
					assignee_synced=$((assignee_synced + 1))
					continue
				fi
				local ln
				ln=$(grep -nE "^\s*- \[.\] ${tid} " "$todo_file" | head -1 | cut -d: -f1)
				if [[ -n "$ln" ]]; then
					local cl
					cl=$(sed -n "${ln}p" "$todo_file")
					local nl
					if echo "$cl" | grep -qE 'logged:'; then
						nl=$(echo "$cl" | sed -E "s/( logged:)/ assignee:${login}\1/")
					else nl="${cl} assignee:${login}"; fi
					# Escape sed replacement metacharacters (| & \) in $nl
					local nl_escaped
					nl_escaped=$(printf '%s' "$nl" | sed 's/[|&\\]/\\&/g')
					sed_inplace "${ln}s|.*|${nl_escaped}|" "$todo_file"
					assignee_synced=$((assignee_synced + 1))
				fi
			done < <(echo "$json" | jq -c '.[]' 2>/dev/null || true)
		fi
	done

	echo ""
	echo "=== Pull Summary ==="
	echo "Refs synced:       $synced"
	echo "Assignees synced:  $assignee_synced"
	echo "Orphans (open):    $orphan_open"
	echo "Orphans (closed):  $orphan_closed"
	[[ $orphan_open -gt 0 ]] && print_warning "Open orphans: $orphan_list"
	[[ $synced -eq 0 && $assignee_synced -eq 0 && $orphan_open -eq 0 ]] && print_success "TODO.md refs up to date"
	return 0
}

cmd_close() {
	local target_task="${1:-}"
	local project_root
	project_root=$(find_project_root) || return 1
	local repo="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
	local todo_file="$project_root/TODO.md"
	verify_gh_cli || return 1

	# Single-task mode
	if [[ -n "$target_task" ]]; then
		local task_line
		task_line=$(grep -E "^\s*- \[.\] ${target_task} " "$todo_file" | head -1 || echo "")
		local num
		num=$(echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		if [[ -z "$num" ]]; then
			num=$(gh_find_issue_by_title "$repo" "${target_task}:" "open" 50)
			[[ -n "$num" && "$num" != "null" && "$DRY_RUN" != "true" ]] && add_gh_ref_to_todo "$target_task" "$num" "$todo_file"
		fi
		[[ -z "$num" || "$num" == "null" ]] && {
			print_info "$target_task: no matching issue"
			return 0
		}
		local state_json
		state_json=$(gh_view_issue "$repo" "$num")
		local st
		st=$(echo "$state_json" | jq -r '.state // empty' 2>/dev/null || echo "")
		[[ "$st" == "CLOSED" || "$st" == "closed" ]] && {
			log_verbose "#$num already closed"
			return 0
		}
		_do_close "$target_task" "$num" "$todo_file" "$repo" || true
		return 0
	fi

	# Bulk mode: fetch all open issues, build task→issue map
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
		local mapped
		mapped=$(echo "$map" | grep -E "^${task_id}\|" | head -1 || echo "")
		[[ -z "$mapped" ]] && continue
		local issue_num="${mapped#*|}"

		# Fix stale refs
		local ref
		ref=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		if [[ -n "$ref" && "$ref" != "$issue_num" && "$DRY_RUN" != "true" ]]; then
			fix_gh_ref_in_todo "$task_id" "$ref" "$issue_num" "$todo_file"
			ref_fixed=$((ref_fixed + 1))
		elif [[ -z "$ref" && "$DRY_RUN" != "true" ]]; then
			add_gh_ref_to_todo "$task_id" "$issue_num" "$todo_file"
			ref_fixed=$((ref_fixed + 1))
		fi

		if _do_close "$task_id" "$issue_num" "$todo_file" "$repo"; then
			closed=$((closed + 1))
		else
			skipped=$((skipped + 1))
		fi
	done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[x\] t[0-9]+' || true)

	print_info "Close: $closed closed, $skipped skipped, $ref_fixed refs fixed"
	return 0
}

cmd_status() {
	local project_root
	project_root=$(find_project_root) || return 1
	local repo="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
	local todo_file="$project_root/TODO.md"
	verify_gh_cli || return 1

	local total_open
	total_open=$(strip_code_fences <"$todo_file" | grep -cE '^\s*- \[ \] t[0-9]+' || true)
	local total_done
	total_done=$(strip_code_fences <"$todo_file" | grep -cE '^\s*- \[x\] t[0-9]+' || true)
	local with_ref
	with_ref=$(strip_code_fences <"$todo_file" | grep -cE '^\s*- \[ \] t[0-9]+.*ref:GH#' || true)
	local without_ref=$((total_open - with_ref))

	local gh_open
	gh_open=$(gh_list_issues "$repo" "open" 500 | jq 'length' 2>/dev/null || echo "0")
	local gh_closed
	gh_closed=$(gh_list_issues "$repo" "closed" 500 | jq 'length' 2>/dev/null || echo "0")

	# Drift: completed tasks with open issues (check via bulk fetch, not per-issue)
	local open_json
	open_json=$(gh_list_issues "$repo" "open" 500)
	local drift=0
	while IFS= read -r il; do
		local it
		it=$(echo "$il" | jq -r '.title' 2>/dev/null || echo "")
		local tid
		tid=$(echo "$it" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
		[[ -z "$tid" ]] && continue
		grep -qE "^\s*- \[x\] ${tid} " "$todo_file" 2>/dev/null && {
			drift=$((drift + 1))
			print_warning "DRIFT: #$(echo "$il" | jq -r '.number') ($tid) open but completed"
		}
	done < <(echo "$open_json" | jq -c '.[]' 2>/dev/null || true)

	echo ""
	echo "=== Sync Status ($repo) ==="
	echo "TODO.md open:      $total_open (${with_ref} with ref, ${without_ref} without)"
	echo "TODO.md completed: $total_done"
	echo "GitHub open:       $gh_open"
	echo "GitHub closed:     $gh_closed"
	echo "Drift:             $drift"
	[[ $without_ref -gt 0 ]] && print_warning "$without_ref tasks need push"
	[[ $drift -gt 0 ]] && print_warning "$drift tasks need close"
	[[ $without_ref -eq 0 && $drift -eq 0 ]] && print_success "In sync"
	return 0
}

cmd_reconcile() {
	local project_root
	project_root=$(find_project_root) || return 1
	local repo="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
	local todo_file="$project_root/TODO.md"
	verify_gh_cli || return 1
	print_info "Reconciling ref:GH# values in $repo..."

	local ref_fixed=0 ref_ok=0 stale=0 orphans=0

	while IFS= read -r line; do
		local tid
		tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		local gh_ref
		gh_ref=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		[[ -z "$tid" || -z "$gh_ref" ]] && continue

		local ij
		ij=$(gh_view_issue "$repo" "$gh_ref")
		local it
		it=$(echo "$ij" | jq -r '.title // empty' 2>/dev/null || echo "")
		local itid
		itid=$(echo "$it" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
		[[ "$itid" == "$tid" ]] && {
			ref_ok=$((ref_ok + 1))
			continue
		}

		print_warning "MISMATCH: $tid ref:GH#$gh_ref → '$it'"
		local correct
		correct=$(gh_find_issue_by_title "$repo" "${tid}:" "all" 50)
		if [[ -n "$correct" && "$correct" != "null" && "$correct" != "$gh_ref" ]]; then
			if [[ "$DRY_RUN" == "true" ]]; then
				print_info "[DRY-RUN] Fix $tid: #$gh_ref → #$correct"
			else
				fix_gh_ref_in_todo "$tid" "$gh_ref" "$correct" "$todo_file"
				print_success "Fixed $tid: #$gh_ref → #$correct"
			fi
			ref_fixed=$((ref_fixed + 1))
		fi
	done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[.\] t[0-9]+.*ref:GH#[0-9]+' || true)

	local open_json
	open_json=$(gh_list_issues "$repo" "open" 200)
	while IFS= read -r il; do
		local num
		num=$(echo "$il" | jq -r '.number' 2>/dev/null || echo "")
		local it
		it=$(echo "$il" | jq -r '.title' 2>/dev/null || echo "")
		local tid
		tid=$(echo "$it" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
		[[ -z "$tid" ]] && continue
		grep -qE "^\s*- \[x\] ${tid} " "$todo_file" 2>/dev/null && {
			print_warning "STALE: #$num ($tid) open but done"
			stale=$((stale + 1))
		}
		grep -qE "^\s*- \[.\] ${tid} " "$todo_file" 2>/dev/null || { orphans=$((orphans + 1)); }
	done < <(echo "$open_json" | jq -c '.[]' 2>/dev/null || true)

	echo ""
	echo "=== Reconciliation ==="
	echo "Refs OK:       $ref_ok"
	echo "Refs fixed:    $ref_fixed"
	echo "Stale open:    $stale"
	echo "Orphans:       $orphans"
	[[ $stale -gt 0 ]] && print_info "Run 'issue-sync-helper.sh close' for stale issues"
	[[ $ref_fixed -eq 0 && $stale -eq 0 && $orphans -eq 0 ]] && print_success "All refs correct"
	return 0
}

cmd_parse() {
	local task_id="${1:-}"
	[[ -z "$task_id" ]] && {
		print_error "Usage: issue-sync-helper.sh parse tNNN"
		return 1
	}
	local project_root
	project_root=$(find_project_root) || return 1
	local todo_file="$project_root/TODO.md"

	local block
	block=$(extract_task_block "$task_id" "$todo_file")
	echo "=== Task Block ==="
	echo "$block"
	echo ""
	echo "=== Parsed Fields ==="
	parse_task_line "$(echo "$block" | head -1)"
	echo ""
	echo "=== Subtasks ==="
	extract_subtasks "$block"
	echo ""
	echo "=== Notes ==="
	extract_notes "$block"
	echo ""

	local parsed
	parsed=$(parse_task_line "$(echo "$block" | head -1)")
	local plan_link
	plan_link=$(echo "$parsed" | grep '^plan_link=' | cut -d= -f2-)
	if [[ -n "$plan_link" ]]; then
		echo "=== Plan Section ==="
		local ps
		ps=$(extract_plan_section "$plan_link" "$project_root")
		if [[ -n "$ps" ]]; then
			echo "Purpose:"
			extract_plan_purpose "$ps"
			echo ""
			echo "Decisions:"
			extract_plan_decisions "$ps"
			echo ""
			echo "Progress:"
			extract_plan_progress "$ps"
		else echo "(no plan found for: $plan_link)"; fi
		echo ""
	fi
	echo "=== Related Files ==="
	find_related_files "$task_id" "$project_root"
	echo ""
	echo "=== Composed Body ==="
	compose_issue_body "$task_id" "$project_root"
	return 0
}

# =============================================================================
# Main
# =============================================================================

cmd_help() {
	cat <<'EOF'
aidevops Issue Sync Helper — stateless TODO.md ↔ GitHub Issues sync via gh CLI.

Usage: issue-sync-helper.sh [command] [options]

Commands:
  push [tNNN]     Create issues from TODO.md tasks
  enrich [tNNN]   Update issue bodies with PLANS.md context
  pull            Sync issue refs/assignees back to TODO.md
  close [tNNN]    Close issues for completed tasks
  reconcile       Fix mismatched ref:GH# values
  status          Show sync drift
  parse [tNNN]    Debug: show parsed task context
  help            Show this help

Options:
  --repo SLUG     Override repo slug (default: auto-detect)
  --dry-run       Preview without changes
  --verbose       Detailed output
  --force         Skip evidence check on close

Auth: gh CLI (gh auth login) or GH_TOKEN/GITHUB_TOKEN env var
EOF
	return 0
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
	push) cmd_push "${positional_args[1]:-}" ;;
	enrich) cmd_enrich "${positional_args[1]:-}" ;;
	pull) cmd_pull ;;
	close) cmd_close "${positional_args[1]:-}" ;;
	reconcile) cmd_reconcile ;;
	status) cmd_status ;;
	parse) cmd_parse "${positional_args[1]:-}" ;;
	help) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
