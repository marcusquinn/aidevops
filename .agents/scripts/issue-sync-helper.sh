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

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=issue-sync-lib.sh
source "${SCRIPT_DIR}/issue-sync-lib.sh"

# =============================================================================
# Configuration & Utility
# =============================================================================

VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
FORCE_CLOSE="${FORCE_CLOSE:-false}"
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
	local repo="$1" prefix="$2" state="${3:-all}" limit="${4:-50}"
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

_mark_issue_done() {
	local repo="$1" num="$2"
	gh_create_label "$repo" "status:done" "6F42C1" "Task is complete"
	_gh_edit_labels "add" "$repo" "$num" "status:done"
	_gh_edit_labels "remove" "$repo" "$num" "status:available,status:queued,status:claimed,status:in-review,status:blocked,status:verify-failed"
}

# =============================================================================
# Close Helpers
# =============================================================================

_has_evidence() {
	local text="$1" task_id="$2" repo="$3"
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
	if gh issue close "$issue_number" --repo "$repo" --comment "$comment" 2>/dev/null; then
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

cmd_push() {
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
		local task_id_ere
		task_id_ere=$(_escape_ere "$task_id")
		local existing
		existing=$(gh_find_issue_by_title "$repo" "${task_id}:" "all" 50)
		if [[ -n "$existing" && "$existing" != "null" ]]; then
			add_gh_ref_to_todo "$task_id" "$existing" "$todo_file"
			skipped=$((skipped + 1))
			continue
		fi

		local task_line
		task_line=$(strip_code_fences <"$todo_file" | grep -E "^\s*- \[.\] ${task_id_ere} " | head -1 || echo "")
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

		local -a args=("issue" "create" "--repo" "$repo" "--title" "$title" "--body" "$body" "--label" "$all_labels")
		[[ -n "$assignee" ]] && args+=("--assignee" "$assignee")
		local url
		url=$(gh "${args[@]}" 2>/dev/null || echo "")
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
					add_gh_ref_to_todo "$tid" "$num" "$todo_file"
					print_success "Added ref:GH#$num to $tid"
					synced=$((synced + 1))
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
			num=$(gh_find_issue_by_title "$repo" "${target_task}:" "open" 50)
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
	done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[x\] t[0-9]+' || true)
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
		correct=$(gh_find_issue_by_title "$repo" "${tid}:" "all" 50)
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
