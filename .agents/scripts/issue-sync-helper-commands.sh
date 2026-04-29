#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Issue Sync Helper — Query & Diagnostic Commands
# =============================================================================
# Read-only/diagnostic commands: cmd_pull, cmd_status, cmd_reconcile, cmd_help.
# These commands read from GitHub and TODO.md but do not create issues.
#
# Usage: source "${SCRIPT_DIR}/issue-sync-helper-commands.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning, print_success)
#   - issue-sync-lib.sh (_escape_ere, strip_code_fences, add_gh_ref_to_todo,
#     fix_gh_ref_in_todo, sed_inplace, _seed_orphan_todo_line)
#   - issue-sync-helper-labels.sh (gh_list_issues, gh_find_issue_by_title)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ISSUE_SYNC_HELPER_COMMANDS_LOADED:-}" ]] && return 0
_ISSUE_SYNC_HELPER_COMMANDS_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# cmd_pull
# =============================================================================

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

# =============================================================================
# cmd_status
# =============================================================================

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

# =============================================================================
# cmd_reconcile
# =============================================================================

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

# =============================================================================
# cmd_help
# =============================================================================

cmd_help() {
	cat <<'EOF'
Issue Sync Helper — stateless TODO.md <-> GitHub Issues sync via gh CLI.
Usage: issue-sync-helper.sh [command] [options]
Commands: push [tNNN] | enrich [tNNN] | pull | close [tNNN] | reopen
          reconcile | relationships [tNNN] | backfill-sub-issues [--issue N]
          backfill-cross-phase-blocked-by --issue N
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

Cross-phase blocked-by backfill (t2877):
  backfill-cross-phase-blocked-by --issue N
                       — parse prose dependency declarations (e.g.
                         "P1 children blocked by P0a + P0b") from the body
                         of the given parent-task issue and emit the
                         corresponding addBlockedBy GitHub relationships.
                         Per-issue entry point called by the pulse t2877
                         reconcile stage. Idempotent; supports --dry-run.

Note: Bulk push (no task ID) is CI-only by default to prevent duplicate issues.
      Use 'push <task_id>' for single tasks, or --force-push to override.
EOF
}
