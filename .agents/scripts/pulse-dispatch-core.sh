#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dispatch-core.sh — Core worker dispatch primitives — dedup check, issue lock/unlock + linked PR lock, impl-commit detection, main-commit check, large-file gate, dispatch_with_dedup orchestrator + helpers, terminal blocker matching.
#
# Extracted from pulse-wrapper.sh in Phase 9 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
# Phase 9 is the highest-risk phase — core dispatch logic.
#
# This module is sourced by pulse-wrapper.sh. Depends on shared-constants.sh
# and worker-lifecycle-common.sh being sourced first by the orchestrator.
#
# Functions in this module (in source order):
#   - _resolve_worker_tier
#   - has_worker_for_repo_issue
#   - check_dispatch_dedup
#   - lock_issue_for_worker
#   - _lock_linked_prs
#   - unlock_issue_after_worker
#   - _unlock_linked_prs
#   - _count_impl_commits
#   - _task_id_in_recent_commits
#   - _task_id_in_merged_pr
#   - _task_id_in_changed_files
#   - _check_nmr_approval_gate
#   - _check_commit_subject_dedup_gate
#   - _has_force_dispatch_label
#   - _is_bot_generated_cleanup_issue
#   - _is_task_committed_to_main
#   - _dispatch_dedup_check_layers  (t1999: extracted from dispatch_with_dedup)
#   - dispatch_with_dedup           (t1999: thin orchestrator, <80 lines)
#   - _ensure_issue_body_has_brief
#   - _match_terminal_blocker_pattern
#   - _apply_terminal_blocker
#   - check_terminal_blockers
#
# Extracted sub-modules (sourced below):
#   - pulse-dispatch-dedup-layers.sh    — 7-layer dedup chain + stale classifier
#   - pulse-dispatch-large-file-gate.sh — large-file simplification gate
#   - pulse-dispatch-worker-launch.sh   — worker launch helpers + orchestrator
#
# Pure move from pulse-wrapper.sh. Byte-identical function bodies.
# Phase 12 post-gate simplification: _is_task_committed_to_main split into
# _task_id_in_recent_commits, _task_id_in_merged_pr, _task_id_in_changed_files
# (t2004). Phase 12 (t1999): dispatch_with_dedup split into decision helper
# (_dispatch_dedup_check_layers) + action helper (_dispatch_launch_worker)
# + thin orchestrator. External signature of dispatch_with_dedup unchanged.
# GH#18832: extracted dedup layers, large-file gate, and worker launch helpers
# into sub-modules to bring this file below the 2000-line simplification gate.

[[ -n "${_PULSE_DISPATCH_CORE_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_CORE_LOADED=1

# Extracted modules — sourced in load order.
# shellcheck source=pulse-dispatch-dedup-layers.sh
source "${BASH_SOURCE[0]%/*}/pulse-dispatch-dedup-layers.sh"
# shellcheck source=pulse-dispatch-large-file-gate.sh
source "${BASH_SOURCE[0]%/*}/pulse-dispatch-large-file-gate.sh"
# shellcheck source=pulse-dispatch-worker-launch.sh
source "${BASH_SOURCE[0]%/*}/pulse-dispatch-worker-launch.sh"

#######################################
# Resolve the worker tier from issue labels. When multiple tier:* labels
# are present (collision — see t1997), pick the highest rank order.
# Fallback: tier:standard if no tier label is present.
# Arguments:
#   $1 - comma-separated label list (e.g., "bug,tier:simple,auto-dispatch")
# Output:
#   tier:thinking, tier:standard, or tier:simple
# Exit codes:
#   0 - always succeeds
#######################################
_resolve_worker_tier() {
	local labels_csv="$1"
	# Convert to lowercase for case-insensitive matching (Bash 3.2 compatible)
	local labels_lower
	labels_lower=$(printf '%s' "$labels_csv" | tr '[:upper:]' '[:lower:]')
	local labels_with_commas=",${labels_lower},"

	if [[ "$labels_with_commas" == *",tier:thinking,"* ]]; then
		printf 'tier:thinking'
	elif [[ "$labels_with_commas" == *",tier:standard,"* ]]; then
		printf 'tier:standard'
	elif [[ "$labels_with_commas" == *",tier:simple,"* ]]; then
		printf 'tier:simple'
	else
		printf 'tier:standard' # default when no tier label present
	fi
	return 0
}

#######################################
# Check if a worker exists for a specific repo+issue pair
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
# Exit codes:
#   0 - matching worker exists
#   1 - no matching worker
#######################################
has_worker_for_repo_issue() {
	local issue_number="$1"
	local repo_slug="$2"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 1
	fi

	local repo_path
	repo_path=$(get_repo_path_by_slug "$repo_slug")

	local worker_lines
	worker_lines=$(list_active_worker_processes) || worker_lines=""

	# Primary match: repo path + issue number in command line.
	# Requires get_repo_path_by_slug to return a non-empty path.
	if [[ -n "$repo_path" ]]; then
		local matches
		matches=$(printf '%s\n' "$worker_lines" | awk -v issue="$issue_number" -v path="$repo_path" '
			BEGIN {
				esc = path
				gsub(/[][(){}.^$*+?|\\]/, "\\\\&", esc)
			}
			$0 ~ ("--dir[[:space:]]+" esc "([[:space:]]|$)") &&
			($0 ~ ("issue-" issue "([^0-9]|$)") || $0 ~ ("Issue #" issue "([^0-9]|$)")) { count++ }
			END { print count + 0 }
		') || matches=0
		[[ "$matches" =~ ^[0-9]+$ ]] || matches=0
		if [[ "$matches" -gt 0 ]]; then
			return 0
		fi
	fi

	# Fallback: match by session-key alone (GH#6453).
	# When get_repo_path_by_slug returns empty (slug not in repos.json,
	# path mismatch, or repos.json unavailable), the primary match above
	# always returns 0 matches — a false-negative that causes the backfill
	# cycle to re-dispatch already-running workers.
	# The session-key "issue-<number>" is always present in the command line
	# of workers dispatched via headless-runtime-helper.sh run --session-key.
	# This fallback catches those workers regardless of path resolution.
	local sk_matches
	sk_matches=$(printf '%s\n' "$worker_lines" | awk -v issue="$issue_number" '
		$0 ~ ("--session-key[[:space:]]+issue-" issue "([^0-9]|$)") { count++ }
		END { print count + 0 }
	') || sk_matches=0
	[[ "$sk_matches" =~ ^[0-9]+$ ]] || sk_matches=0
	if [[ "$sk_matches" -gt 0 ]]; then
		return 0
	fi

	return 1
}

#######################################
# Thin orchestrator — runs the 7-layer dedup chain in order.
# Byte-for-byte behavioural equivalent of the pre-GH#18654 single-function
# implementation. Each layer returns 0 to block dispatch or 1 to continue.
#######################################
check_dispatch_dedup() {
	local issue_number="$1"
	local repo_slug="$2"
	local title="$3"
	local issue_title="${4:-}"
	local self_login="${5:-}"

	_dedup_layer1_ledger_check "$issue_number" "$repo_slug" && return 0
	_dedup_layer2_process_match "$issue_number" "$repo_slug" && return 0
	_dedup_layer3_title_match "$title" && return 0
	_dedup_layer4_pr_evidence "$issue_number" "$repo_slug" "$issue_title" && return 0
	_dedup_layer5_dispatch_comment "$issue_number" "$repo_slug" "$self_login" && return 0
	_dedup_layer6_assignee_and_stale "$issue_number" "$repo_slug" "$self_login" && return 0
	_dedup_layer7_claim_lock "$issue_number" "$repo_slug" "$self_login" && return 0

	return 1
}

#######################################
# Lock an issue (and any linked PRs) to prevent mid-flight prompt
# injection (t1894, t1934). Once a worker is dispatched, the issue
# state is frozen — any comment arriving after dispatch is either
# noise or adversarial. Lock the conversation to prevent influence.
# Also locks open PRs linked to the issue (worker may read PR comments).
# Non-fatal: locking failure doesn't block dispatch.
#######################################
lock_issue_for_worker() {
	local issue_num="$1"
	local slug="$2"
	local reason="${3:-resolved}"

	[[ -n "$issue_num" && -n "$slug" ]] || return 0

	# Lock the issue itself
	gh issue lock "$issue_num" --repo "$slug" --reason "$reason" >/dev/null 2>&1 || true
	echo "[pulse-wrapper] Locked #${issue_num} in ${slug} during worker execution (t1934)" >>"$LOGFILE"

	# Lock any open PRs linked to this issue (t1934: PRs have same injection surface)
	_lock_linked_prs "$issue_num" "$slug" "$reason"

	return 0
}

#######################################
# Lock open PRs that reference a given issue number (t1934).
# Finds PRs whose title contains the issue number pattern
# (e.g., "GH#123" or "#123") and locks their conversations.
# Non-fatal: best-effort, failures are logged but ignored.
#######################################
_lock_linked_prs() {
	local issue_num="$1"
	local slug="$2"
	local reason="${3:-resolved}"

	local pr_numbers
	pr_numbers=$(gh pr list --repo "$slug" --state open \
		--json number,title --jq \
		"[.[] | select(.title | test(\"(GH)?#${issue_num}([^0-9]|$)\"))] | .[].number" \
		--limit 5 2>/dev/null) || pr_numbers=""

	local pr_num
	while IFS= read -r pr_num; do
		[[ -n "$pr_num" && "$pr_num" =~ ^[0-9]+$ ]] || continue
		gh issue lock "$pr_num" --repo "$slug" --reason "$reason" >/dev/null 2>&1 || true
		echo "[pulse-wrapper] Locked PR #${pr_num} in ${slug} (linked to issue #${issue_num}) (t1934)" >>"$LOGFILE"
	done <<<"$pr_numbers"

	return 0
}

#######################################
# Unlock an issue (and any linked PRs) after worker completion or
# failure (t1894, t1934). Symmetric with lock_issue_for_worker.
# Non-fatal: unlocking failure is logged but doesn't block.
#######################################
unlock_issue_after_worker() {
	local issue_num="$1"
	local slug="$2"

	[[ -n "$issue_num" && -n "$slug" ]] || return 0

	# Unlock the issue itself
	gh issue unlock "$issue_num" --repo "$slug" >/dev/null 2>&1 || true
	echo "[pulse-wrapper] Unlocked #${issue_num} in ${slug} after worker completion (t1934)" >>"$LOGFILE"

	# Unlock any open PRs linked to this issue (symmetric with lock)
	_unlock_linked_prs "$issue_num" "$slug"

	return 0
}

#######################################
# Unlock open PRs that reference a given issue number (t1934).
# Symmetric with _lock_linked_prs. Non-fatal.
#######################################
_unlock_linked_prs() {
	local issue_num="$1"
	local slug="$2"

	local pr_numbers
	pr_numbers=$(gh pr list --repo "$slug" --state open \
		--json number,title --jq \
		"[.[] | select(.title | test(\"(GH)?#${issue_num}([^0-9]|$)\"))] | .[].number" \
		--limit 5 2>/dev/null) || pr_numbers=""

	local pr_num
	while IFS= read -r pr_num; do
		[[ -n "$pr_num" && "$pr_num" =~ ^[0-9]+$ ]] || continue
		gh issue unlock "$pr_num" --repo "$slug" >/dev/null 2>&1 || true
		echo "[pulse-wrapper] Unlocked PR #${pr_num} in ${slug} (linked to issue #${issue_num}) (t1934)" >>"$LOGFILE"
	done <<<"$pr_numbers"

	return 0
}

#######################################
# GH#17779: Helper for _is_task_committed_to_main.
# Reads commit hashes from stdin, applies the two-stage planning filter
# (subject-line prefix + path-based), and prints the count of real
# implementation commits to stdout.
#
# Args:
#   $1 - repo_path (local path to the repo)
# Stdin: one commit hash per line
#######################################
_count_impl_commits() {
	local repo_path_inner="$1"
	local match_count_inner=0
	local commit_hash_inner
	while IFS= read -r commit_hash_inner; do
		[[ -z "$commit_hash_inner" ]] && continue
		local is_planning_only_inner=true
		local touched_path_inner
		while IFS= read -r touched_path_inner; do
			[[ -z "$touched_path_inner" ]] && continue
			case "$touched_path_inner" in
			TODO.md | todo/* | AGENTS.md | .agents/AGENTS.md | */docs/* | docs/*) ;;
			*)
				is_planning_only_inner=false
				break
				;;
			esac
		done < <(git -C "$repo_path_inner" diff-tree --no-commit-id --name-only -r "$commit_hash_inner" 2>/dev/null)
		if [[ "$is_planning_only_inner" == "false" ]]; then
			match_count_inner=$((match_count_inner + 1))
		fi
	done
	echo "$match_count_inner"
	return 0
}

#######################################
# t2004: Signal 1 — search git log subject lines for task ID patterns.
# Handles tNNN and GH#NNN prefixes extracted from the issue title.
# Subject-only matching prevents body cross-references from causing false
# positives (GH#17779). Uses _count_impl_commits to filter planning-only
# commits (GH#17707).
#
# Args:
#   $1 - issue_title (to extract tNNN / GH#NNN prefix patterns)
#   $2 - repo_path (local path to the repo)
#   $3 - created_at (ISO timestamp for --since filter)
#
# Exit codes:
#   0 - found matching implementation commit(s) on origin/main
#   1 - no match
#######################################
_task_id_in_recent_commits() {
	local issue_title="$1"
	local repo_path="$2"
	local created_at="$3"

	# Pattern 1: tNNN task ID from title (e.g., "t153: add dark mode")
	# Subject-only: body cross-references like "(t101)" must not match.
	# grep -w enforces word boundaries — prevents t101 matching t1010.
	local -a subject_patterns=()
	local task_id_match
	task_id_match=$(printf '%s' "$issue_title" | grep -oE '^t[0-9]+' | head -1) || task_id_match=""
	if [[ -n "$task_id_match" ]]; then
		subject_patterns+=("$task_id_match")
	fi

	# Pattern 2: GH#NNN from title (e.g., "GH#17574: fix pulse dispatch")
	# Subject-only: body mentions of other GH# IDs must not match.
	local gh_id_match
	gh_id_match=$(printf '%s' "$issue_title" | grep -oE '^GH#[0-9]+' | head -1) || gh_id_match=""
	if [[ -n "$gh_id_match" ]]; then
		subject_patterns+=("$gh_id_match")
	fi

	[[ ${#subject_patterns[@]} -gt 0 ]] || return 1

	# Bash 3.2 + set -u: length check already done above.
	local pattern
	for pattern in "${subject_patterns[@]}"; do
		local match_count=0
		# Fetch all commits as "HASH SUBJECT", filter planning subjects, then
		# grep -w for word-boundary match on the subject portion only.
		match_count=$(_count_impl_commits "$repo_path" < <(
			git -C "$repo_path" log origin/main --since="$created_at" \
				--format='%H %s' |
				grep -vE '^[0-9a-f]+ (chore: claim|plan:|p[0-9]+:)' |
				grep -wE "$pattern" |
				cut -d' ' -f1 || true
		))
		if [[ "$match_count" -gt 0 ]]; then
			echo "[pulse-wrapper] _task_id_in_recent_commits: found ${match_count} commit(s) matching subject pattern '${pattern}' on origin/main since ${created_at}" >>"$LOGFILE"
			return 0
		fi
	done

	return 1
}

#######################################
# t2004: Signal 2 — search git log commit messages for closing keywords and
# squash-merge suffixes that indicate the issue was resolved via a merged PR.
#
# Patterns: "(#NNN)" squash-merge suffix, "Closes #NNN", "Fixes #NNN".
# Full-message matching is safe here — these keywords legitimately appear
# only in commit bodies for commits that close an issue (GH#17779).
#
# Args:
#   $1 - issue_number
#   $2 - repo_path (local path to the repo)
#   $3 - created_at (ISO timestamp for --since filter)
#
# Exit codes:
#   0 - found matching implementation commit(s) on origin/main
#   1 - no match
#######################################
_task_id_in_merged_pr() {
	local issue_number="$1"
	local repo_path="$2"
	local created_at="$3"

	# Pattern 3: GitHub squash-merge suffix "(#NNN)" — only matches commit
	# titles, not body references. The bare "#NNN" pattern previously caused
	# false positives: any commit that MENTIONED an issue (e.g., "Relabeled
	# #17659 and #17660") would match, closing issues whose work hadn't been
	# done. Restrict to the "(#NNN)" suffix that GitHub adds to squash merges.
	# t1927: Escape parens for -E regex — unescaped parens are capture groups
	# that match bare "#NNN" in commit bodies (evidence tables, PR descriptions).
	# With \( \) the pattern only matches the literal "(#NNN)" suffix.
	local -a message_patterns=()
	message_patterns+=("\\(#${issue_number}\\)")

	# Patterns 4-5: "Closes #NNN" / "Fixes #NNN" in commit messages — these
	# are the conventional patterns for commits that resolve an issue.
	# \b word boundary prevents #17779 from matching #177790 (longer IDs).
	message_patterns+=("[Cc]loses #${issue_number}\\b")
	message_patterns+=("[Ff]ixes #${issue_number}\\b")

	# Bash 3.2 + set -u: guard empty array iteration.
	local pattern
	for pattern in "${message_patterns[@]}"; do
		local match_count=0
		match_count=$(_count_impl_commits "$repo_path" < <(
			git -C "$repo_path" log origin/main --since="$created_at" \
				-E --grep="$pattern" --format='%H %s' |
				grep -vE '^[0-9a-f]+ (chore: claim|plan:|p[0-9]+:)' |
				cut -d' ' -f1 || true
		))
		if [[ "$match_count" -gt 0 ]]; then
			echo "[pulse-wrapper] _task_id_in_merged_pr: found ${match_count} commit(s) matching message pattern '${pattern}' on origin/main since ${created_at}" >>"$LOGFILE"
			return 0
		fi
	done

	return 1
}

#######################################
# t2004: Signal 3 — scan TODO.md on origin/main for completed task markers.
# Catches tasks marked [x] in planning files without a conventional commit
# message — e.g., tasks completed via direct TODO edit + push.
#
# Args:
#   $1 - issue_number
#   $2 - issue_title (to extract tNNN prefix)
#   $3 - repo_path (local path to the repo)
#
# Exit codes:
#   0 - task found completed ([x]) in TODO.md on origin/main
#   1 - no match (or TODO.md unavailable)
#######################################
_task_id_in_changed_files() {
	local issue_number="$1"
	local issue_title="$2"
	local repo_path="$3"

	local todo_content
	todo_content=$(git -C "$repo_path" show origin/main:TODO.md 2>/dev/null) || return 1

	# Check for tNNN completion marker: "- [x] tNNN ..."
	local task_id_match
	task_id_match=$(printf '%s' "$issue_title" | grep -oE '^t[0-9]+' | head -1) || task_id_match=""
	if [[ -n "$task_id_match" ]]; then
		if printf '%s' "$todo_content" | grep -qE "^\s*-\s*\[x\]\s+${task_id_match}(\s|$)"; then
			echo "[pulse-wrapper] _task_id_in_changed_files: found completed '${task_id_match}' in TODO.md on origin/main" >>"$LOGFILE"
			return 0
		fi
	fi

	# Check for GH#NNN completion marker: "- [x] ... GH#NNN ..."
	if printf '%s' "$todo_content" | grep -qE "^\s*-\s*\[x\].*\bGH#${issue_number}\b"; then
		echo "[pulse-wrapper] _task_id_in_changed_files: found completed 'GH#${issue_number}' in TODO.md on origin/main" >>"$LOGFILE"
		return 0
	fi

	return 1
}

#######################################
# t1894 + GH#18648: Cryptographic approval gate (ever-NMR) with
# review-followup exemption for bot-generated cleanup issues.
#
# Extracted from _dispatch_dedup_check_layers() to keep the parent
# function under the 100-line complexity threshold while the exemption
# logic grew.
#
# Logic:
#   1. Determine if the issue currently has `needs-maintainer-review`
#      — set known_ever_nmr="true" for the cache-path short-circuit.
#   2. If the issue is bot-generated cleanup (review-followup or
#      source:review-scanner) AND the label is not currently present,
#      override known_ever_nmr="false" to skip the historical timeline
#      check. This clears the ever-NMR permanence trap for routine
#      cleanup issues whose NMR label was applied by the fast-fail
#      escalation path and has since been removed.
#   3. Call issue_has_required_approval with the determined state.
#
# The exemption does NOT fire when the label is currently present —
# maintainer-applied or bot-applied NMR still blocks dispatch until
# the label is removed or cryptographic approval is posted.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - issue_meta_json (pre-fetched JSON with .labels array)
#
# Exit codes:
#   0 - gate blocks dispatch (ever-NMR without approval)
#   1 - gate allows dispatch
#######################################
_check_nmr_approval_gate() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_meta_json="$3"

	local known_ever_nmr="unknown"
	if printf '%s' "$issue_meta_json" | jq -e '.labels | map(.name) | index("needs-maintainer-review")' >/dev/null 2>&1; then
		known_ever_nmr="true"
	fi

	# GH#18648: bot-generated cleanup exemption. See
	# _is_bot_generated_cleanup_issue() doc for full rationale.
	if [[ "$known_ever_nmr" != "true" ]] && _is_bot_generated_cleanup_issue "$issue_meta_json"; then
		known_ever_nmr="false"
		echo "[pulse-wrapper] dispatch_with_dedup: review-followup exemption for #${issue_number} in ${repo_slug} — skipping historical ever-NMR check (GH#18648)" >>"$LOGFILE"
	fi

	if ! issue_has_required_approval "$issue_number" "$repo_slug" "$known_ever_nmr"; then
		echo "[pulse-wrapper] dispatch_with_dedup: BLOCKED #${issue_number} in ${repo_slug} — requires cryptographic approval (ever-NMR)" >>"$LOGFILE"
		return 0
	fi
	return 1
}

#######################################
# GH#17574 + GH#18644: Combined commit-subject dedup gate with
# force-dispatch maintainer override.
#
# Wraps the _is_task_committed_to_main call with an early bypass when
# the issue carries the `force-dispatch` label. Extracted from
# _dispatch_dedup_check_layers() to keep the parent function under the
# 100-line complexity threshold while the logic-body grows.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - target_title (issue title from meta_json)
#   $4 - repo_path (local path to the repo)
#   $5 - issue_meta_json (pre-fetched JSON with .labels array)
#
# Exit codes:
#   0 - gate fires (block dispatch — task appears committed to main,
#       force-dispatch is NOT set)
#   1 - gate allows dispatch (task not committed, OR force-dispatch
#       override is set)
#######################################
_check_commit_subject_dedup_gate() {
	local issue_number="$1"
	local repo_slug="$2"
	local target_title="$3"
	local repo_path="$4"
	local issue_meta_json="$5"

	# GH#18644: force-dispatch label bypasses the commit-subject dedup
	# entirely. The override is for legacy task-ID collisions where a
	# commit subject accidentally mentions a task ID that was never
	# claimed via claim-task-id.sh. Maintainer-only — workers must not
	# apply this label. Does NOT bypass ever-NMR, claim/lock layers,
	# large-file gates, or blocked-by dependencies.
	if _has_force_dispatch_label "$issue_meta_json"; then
		echo "[pulse-wrapper] dispatch_with_dedup: force-dispatch label active on #${issue_number} in ${repo_slug} — bypassing _is_task_committed_to_main (GH#18644)" >>"$LOGFILE"
		return 1
	fi

	# GH#17574: Skip dispatch if the task has already been committed
	# directly to main. Workers that bypass the PR flow (direct commits)
	# complete the work invisibly — the issue stays open until the
	# pulse's mark-complete pass runs, which happens AFTER dispatch
	# decisions for the next cycle. Without this check, the pulse
	# dispatches redundant workers for already-completed work.
	#
	# GH#17642: Do NOT auto-close the issue on a block. The main-commit
	# check has a high false-positive rate (casual mentions, multi-
	# runner deployment gaps, stale patterns). A false skip is harmless
	# (next cycle retries), a false close is destructive (needs manual
	# reopen, re-dispatch, and loses worker context). Let the verified
	# merge-pass or human close it.
	if _is_task_committed_to_main "$issue_number" "$repo_slug" "$target_title" "$repo_path"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: task already committed to main (GH#17574)" >>"$LOGFILE"
		return 0
	fi

	return 1
}

#######################################
# GH#18644: Detect the `force-dispatch` maintainer override label.
#
# Purpose: escape hatch for false-positive task-ID collisions in the
# commit-subject dedup (_is_task_committed_to_main). When a commit
# subject accidentally mentions a task ID that was never claimed via
# claim-task-id.sh — e.g., `chore(build.txt): add rule (t2046)` for a
# task that is actually GH#18508, not the canonical t2046 — the dedup
# block fires permanently even though no implementation has happened.
#
# The `force-dispatch` label is a maintainer-only override that
# bypasses this specific check. It does NOT bypass:
#   - The cryptographic approval gate (ever-NMR) above it
#   - Any Layer 1-7 claim/lock/assignee/open-PR machinery below it
#   - Large-file gates, blocked-by dependencies, or supervisor title guards
#
# Workers MUST NOT apply this label themselves. It represents a
# human decision that the dedup signal is wrong for this specific issue.
#
# Args:
#   $1 - issue_meta_json (pre-fetched JSON with a .labels array)
#
# Exit codes:
#   0 - force-dispatch label is present
#   1 - force-dispatch label is absent (or meta_json is empty/invalid)
#######################################
_has_force_dispatch_label() {
	local issue_meta_json="$1"
	[[ -n "$issue_meta_json" ]] || return 1
	printf '%s' "$issue_meta_json" |
		jq -e '.labels | map(.name) | index("force-dispatch")' >/dev/null 2>&1
}

#######################################
# GH#18648 (Fix 3a): Detect bot-generated cleanup issues.
#
# Bot-generated cleanup issues carry either `review-followup` (from
# post-merge-review-scanner.sh) or `source:review-scanner` (the
# provenance marker the scanner applies alongside it). Both labels
# indicate: "this issue was auto-created from already-merged PR
# review comments, no new maintainer decision is required".
#
# Callers use this to exempt the issue from the ever-NMR permanence
# trap — historical NMR labels applied by automated escalation paths
# (dispatch-dedup fast-fail circuit breaker) no longer drain the
# dispatch queue once the label is manually removed.
#
# The exemption does NOT fire when the issue CURRENTLY has the
# needs-maintainer-review label — a present label still requires
# cryptographic approval, regardless of issue provenance. The fix
# is surgical to the historical-timeline false-positive case.
#
# Args:
#   $1 - issue_meta_json (pre-fetched JSON with .labels array)
#
# Exit codes:
#   0 - issue is bot-generated cleanup
#   1 - issue is not bot-generated (or meta_json is empty/invalid)
#######################################
_is_bot_generated_cleanup_issue() {
	local issue_meta_json="$1"
	[[ -n "$issue_meta_json" ]] || return 1
	printf '%s' "$issue_meta_json" |
		jq -e '.labels | map(.name) | (index("review-followup") != null or index("source:review-scanner") != null)' >/dev/null 2>&1
}

#######################################
# GH#17574: Check if a task has already landed on main (via PR merge or direct commit).
#
# Workers that bypass the PR flow (direct commits to main) complete the
# work invisibly — the issue stays open until the pulse's mark-complete
# pass runs, which happens AFTER dispatch decisions for the next cycle.
# This caused 3× token waste in the observed incident (t153–t160).
#
# Delegates to three per-signal helpers (t2004):
#   _task_id_in_recent_commits — task ID in commit subject line
#   _task_id_in_merged_pr      — closing keywords / squash-merge suffix
#   _task_id_in_changed_files  — [x] completion marker in TODO.md
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - issue_title (e.g., "t153: add dark mode toggle")
#   $4 - repo_path (local path to the repo)
#
# Exit codes:
#   0 - task IS committed to main (do NOT dispatch)
#   1 - task is NOT committed to main (safe to dispatch)
#######################################
_is_task_committed_to_main() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="$3"
	local repo_path="$4"

	[[ -n "$issue_number" && -n "$repo_slug" && -n "$repo_path" ]] || return 1

	# Get the issue creation date for --since filtering
	local created_at
	created_at=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json createdAt -q '.createdAt' 2>/dev/null) || created_at=""
	if [[ -z "$created_at" ]]; then
		return 1
	fi

	# Ensure we have the latest remote refs (the dispatch loop already
	# does git pull, but fetch is cheaper and sufficient for log queries)
	if [[ -d "$repo_path/.git" ]] || git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "$repo_path" fetch origin main --quiet 2>/dev/null || true
	else
		return 1
	fi

	_task_id_in_recent_commits "$issue_title" "$repo_path" "$created_at" && return 0
	_task_id_in_merged_pr "$issue_number" "$repo_path" "$created_at" && return 0
	_task_id_in_changed_files "$issue_number" "$issue_title" "$repo_path" && return 0
	return 1
}

#######################################
# Pre-dispatch validation + dedup check layers for dispatch_with_dedup.
# Extracted from dispatch_with_dedup (t1999, Phase 12) to reduce the
# parent function to a thin orchestrator.
#
# Runs all pre-dispatch safety gates in order:
#   1. Issue state (must be OPEN)
#   2. Management labels (supervisor/contributor/persistent/etc.)
#   3. Cryptographic approval gate (t1894, ever-NMR)
#   4. Supervisor telemetry title guard
#   5. Main-commit check (GH#17574 — task already done)
#   6. Blocked-by dependency enforcement (t1927)
#   7. Issue consolidation pre-check
#   8. Large-file simplification gate
#   9. 7-layer check_dispatch_dedup chain (Layers 1–7)
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - dispatch_title (normalized title used as dedup key)
#   $4 - issue_title (raw issue title, may differ from dispatch_title)
#   $5 - self_login (dispatching runner login)
#   $6 - repo_path (local path to the repo)
#   $7 - issue_meta_json (pre-fetched JSON: number,title,state,labels,assignees)
#
# Exit codes:
#   0 - all gates passed; safe to dispatch
#   1 - blocked (reason logged to LOGFILE by the failing gate)
#######################################
_dispatch_dedup_check_layers() {
	local issue_number="$1"
	local repo_slug="$2"
	local dispatch_title="$3"
	local issue_title="$4"
	local self_login="$5"
	local repo_path="$6"
	local issue_meta_json="$7"

	local target_state target_title
	target_state=$(printf '%s' "$issue_meta_json" | jq -r '.state // ""' 2>/dev/null)
	target_title=$(printf '%s' "$issue_meta_json" | jq -r '.title // ""' 2>/dev/null)

	# GH#18987: Disk-space pre-check — refuse dispatch if /home filesystem
	# has less than 5 GB available. Prevents cascading failures where workers
	# create worktrees + node_modules that fill the volume entirely.
	# Uses $HOME as the reference path (portable; covers Linux /home mounts).
	local _avail_kb
	_avail_kb=$(df "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
	if [[ -n "$_avail_kb" ]] && [[ "$_avail_kb" -lt 5242880 ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: disk space critical (${_avail_kb}KB avail on \$HOME filesystem, need 5242880KB/5G). Run: worktree-helper.sh clean --auto --force-merged" >>"$LOGFILE"
		return 1
	fi

	# GH#18987: Worktree count cap — refuse dispatch when the repo has 200+
	# registered git worktrees. At that scale, new worktrees risk consuming
	# tens of GB; stale merged ones should be cleaned before adding more.
	local _wt_count _wt_max
	_wt_max="${AIDEVOPS_MAX_WORKTREES:-200}"
	_wt_count=$(git -C "$repo_path" worktree list 2>/dev/null | wc -l | tr -d ' ')
	if [[ -n "$_wt_count" ]] && [[ "$_wt_count" -ge "$_wt_max" ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: worktree count ${_wt_count} >= cap ${_wt_max}. Run: worktree-helper.sh clean --auto --force-merged" >>"$LOGFILE"
		return 1
	fi

	if [[ "$target_state" != "OPEN" ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: issue state is ${target_state:-unknown}" >>"$LOGFILE"
		return 1
	fi

	if printf '%s' "$issue_meta_json" | jq -e '.labels | map(.name) | (index("supervisor") or index("contributor") or index("persistent") or index("quality-review") or index("on hold") or index("blocked"))' >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: non-dispatchable management label present" >>"$LOGFILE"
		return 1
	fi

	# t1894/GH#18648: Cryptographic approval gate (ever-NMR) with
	# review-followup exemption for bot-generated cleanup issues.
	if _check_nmr_approval_gate "$issue_number" "$repo_slug" "$issue_meta_json"; then
		return 1
	fi

	if [[ "$target_title" == \[Supervisor:* ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: supervisor telemetry title" >>"$LOGFILE"
		return 1
	fi

	# GH#17574/GH#18644: commit-subject dedup gate with force-dispatch override.
	if _check_commit_subject_dedup_gate "$issue_number" "$repo_slug" "$target_title" "$repo_path" "$issue_meta_json"; then
		return 1
	fi

	# t1927: Blocked-by enforcement — skip dispatch if a dependency is unresolved.
	# Fetches issue body and parses for "blocked-by:tNNN" or "Blocked by #NNN".
	local _dispatch_issue_body
	_dispatch_issue_body=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json body --jq '.body // ""' 2>/dev/null) || _dispatch_issue_body=""
	if [[ -n "$_dispatch_issue_body" ]] && is_blocked_by_unresolved "$_dispatch_issue_body" "$repo_slug" "$issue_number"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: unresolved blocked-by dependency (t1927)" >>"$LOGFILE"
		return 1
	fi

	# Pre-dispatch: issue consolidation check. If an issue has accumulated
	# multiple substantive comments that change scope (not dispatch/approval
	# machinery), dispatch a consolidation worker first to merge everything
	# into a clean issue body. This prevents implementing workers from spending
	# tokens reconstructing scope from comment archaeology.
	if _issue_needs_consolidation "$issue_number" "$repo_slug"; then
		_dispatch_issue_consolidation "$issue_number" "$repo_slug" "$repo_path"
		echo "[dispatch_with_dedup] Dispatch deferred for #${issue_number} in ${repo_slug}: issue needs comment consolidation" >>"$LOGFILE"
		return 1
	fi

	# Pre-dispatch: large-file simplification gate. If the issue body
	# references files that exceed LARGE_FILE_LINE_THRESHOLD, create a
	# blocked-by simplification task instead of dispatching. Workers
	# shouldn't pay the complexity tax of navigating a 12,000-line file.
	if _issue_targets_large_files "$issue_number" "$repo_slug" "$_dispatch_issue_body" "$repo_path"; then
		echo "[dispatch_with_dedup] Dispatch deferred for #${issue_number} in ${repo_slug}: targets large file(s), simplification gate" >>"$LOGFILE"
		return 1
	fi

	# All 7 dedup layers — cannot be skipped
	if check_dispatch_dedup "$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" "$self_login"; then
		echo "[dispatch_with_dedup] Dedup guard blocked #${issue_number} in ${repo_slug}" >>"$LOGFILE"
		return 1
	fi

	return 0
}

#######################################
# Dispatch a worker for the given issue, guarded by all dedup and
# pre-dispatch safety layers. Thin orchestrator: delegates to
# _dispatch_dedup_check_layers (decision) and _dispatch_launch_worker
# (action). External signature is unchanged from the pre-t1999 version.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - dispatch_title (normalized title used as dedup key)
#   $4 - issue_title (raw issue title; optional, default empty)
#   $5 - self_login (dispatching runner login; optional, default empty)
#   $6 - repo_path (local path to the repo)
#   $7 - prompt (worker prompt string)
#   $8 - session_key (optional, default "issue-{issue_number}")
#   $9 - model_override (optional, default empty = auto round-robin)
#
# Exit codes:
#   0 - worker dispatched successfully, or blocked (not a failure)
#   1 - hard error (metadata unavailable, dedup gate blocked)
#######################################
dispatch_with_dedup() {
	local issue_number="$1"
	local repo_slug="$2"
	local dispatch_title="$3"
	local issue_title="${4:-}"
	local self_login="${5:-}"
	local repo_path="$6"
	local prompt="$7"
	local session_key="${8:-issue-${issue_number}}"
	local model_override="${9:-}"
	# GH#15317 fix: _claim_comment_id is set by check_dispatch_dedup() via
	# bash dynamic scoping, but must be declared in the calling function's
	# scope first. Without this, set -u crashes the wrapper on every dispatch,
	# SIGTERM-ing all active workers.
	local _claim_comment_id=""

	# GH#17503: Claim comments are NEVER deleted — they form the audit trail.
	# The _cleanup_claim_comment function is retained as a no-op for backward
	# compatibility (callers may still reference it on early-return paths).
	_cleanup_claim_comment() {
		# No-op: claim comments are persistent audit trail (GH#17503).
		# Previously deleted DISPATCH_CLAIM comments, which destroyed both
		# the lock and the audit trail — causing duplicate dispatches.
		return 0
	}

	# Hard stop for supervisor/telemetry issues (t1702 pulse guard).
	# The pulse prompt should already avoid these, but this deterministic
	# gate prevents dispatch when prompt fallback logic is too permissive.
	# Load metadata once here; passed to both helpers to avoid extra API calls.
	local issue_meta_json
	issue_meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json number,title,state,labels,assignees 2>/dev/null) || issue_meta_json=""
	if [[ -z "$issue_meta_json" ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: unable to load issue metadata" >>"$LOGFILE"
		return 1
	fi

	# Run all pre-dispatch validation and dedup check layers (9 gates total).
	# Each gate logs its own blocked reason to LOGFILE before returning 1.
	# _claim_comment_id is set by check_dispatch_dedup inside this call via
	# bash dynamic scoping — accessible below because it was declared local above.
	if ! _dispatch_dedup_check_layers \
		"$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" \
		"$self_login" "$repo_path" "$issue_meta_json"; then
		return 1
	fi

	# t2063: brief-body freshness guard — defence-in-depth.
	# If a brief file exists for this issue but the issue body lacks the
	# `## Task Brief` or `## Worker Guidance` marker, force-enrich the body
	# so the worker sees inlined implementation context on first read. This
	# catches any legacy issue created via the pre-t2063 bare path, and
	# any future path that might bypass the primary fixes in claim-task-id.sh
	# and issue-sync-helper.sh. Non-fatal — dispatch proceeds even if enrich fails.
	_ensure_issue_body_has_brief "$issue_number" "$repo_slug" "$repo_path" "$issue_title"

	# All checks passed — launch the worker.
	_dispatch_launch_worker \
		"$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" \
		"$self_login" "$repo_path" "$prompt" "$session_key" \
		"$model_override" "$issue_meta_json"
}

#######################################
# t2063: Pre-dispatch brief-body freshness guard.
#
# If a task brief file exists at `${repo_path}/todo/tasks/${task_id}-brief.md`
# but the issue body does not contain the `## Task Brief` or `## Worker Guidance`
# marker, force-enrich the body via issue-sync-helper.sh. This ensures the
# worker sees the full implementation context on its first read of the issue,
# eliminating the ~1500-3000 token exploration overhead of hunting for the
# brief file inside the worktree.
#
# Defence-in-depth: the primary fixes in claim-task-id.sh (_compose_issue_body)
# and issue-sync-helper.sh (_enrich_update_issue) should make this a no-op in
# all normal paths. This guard catches:
#   - Legacy issues created via the pre-t2063 bare path before the TODO push
#   - Any future path that bypasses both primary fixes
#   - Briefs added after the issue was created
#
# Non-fatal: always returns 0 so dispatch proceeds even if enrich fails.
# The worker will still run, just with the pre-t2063 context cost.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - repo_path (local checkout)
#   $4 - issue_title (used to extract task ID)
#######################################
_ensure_issue_body_has_brief() {
	local issue_number="$1"
	local repo_slug="$2"
	local repo_path="$3"
	local issue_title="$4"

	# Extract task ID from title (format: "tNNN: description")
	local task_id=""
	[[ "$issue_title" =~ (t[0-9]+) ]] && task_id="${BASH_REMATCH[1]}"
	[[ -z "$task_id" ]] && return 0

	# Check for brief file on disk
	local brief_file="${repo_path}/todo/tasks/${task_id}-brief.md"
	[[ ! -f "$brief_file" ]] && return 0

	# Check if body already contains the inline markers
	local current_body
	current_body=$(gh issue view "$issue_number" --repo "$repo_slug" --json body -q .body 2>/dev/null || echo "")
	if [[ "$current_body" == *"## Task Brief"* ]] || [[ "$current_body" == *"## Worker Guidance"* ]]; then
		return 0
	fi

	# Brief exists but body is a stub — force-enrich before worker sees it.
	# Run enrich from the repo_path so `find_project_root` resolves correctly,
	# and pass REPO_SLUG + FORCE_ENRICH via env so the helper skips the body
	# preservation gate and targets the right repo.
	echo "[dispatch_with_dedup] t2063: issue #${issue_number} has brief on disk but stub body — force-enriching" >>"$LOGFILE"
	local issue_sync_helper
	issue_sync_helper="$(dirname "${BASH_SOURCE[0]}")/issue-sync-helper.sh"
	if [[ -x "$issue_sync_helper" ]]; then
		(
			cd "$repo_path" 2>/dev/null || exit 0
			FORCE_ENRICH=true REPO_SLUG="$repo_slug" "$issue_sync_helper" enrich "$task_id" >>"$LOGFILE" 2>&1
		) || {
			echo "[dispatch_with_dedup] t2063: force-enrich failed for #${issue_number}; proceeding with stub body" >>"$LOGFILE"
		}
	fi
	return 0
}

#######################################
# Check issue comments for terminal blocker patterns (GH#5141)
#
# Scans the last N comments on an issue for known patterns that indicate
# a user-action-required blocker. Workers cannot resolve these — they
# require the repo owner to take a manual action (e.g., refresh a token,
# grant a scope, configure a secret). Dispatching workers against these
# issues wastes compute on guaranteed failures.
#
# Known terminal blocker patterns:
#   - workflow scope missing (token lacks `workflow` scope)
#   - token lacks scope / missing scope
#   - ACTION REQUIRED (supervisor-posted user-action comments)
#   - refusing to allow an OAuth App to create or update workflow
#   - authentication required / permission denied (persistent auth failures)
#
# When a blocker is detected, the function:
#   1. Adds `status:blocked` label to the issue
#   2. Posts a comment directing the user to the required action
#      (idempotent — checks for existing blocker comment first)
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - (optional) max comments to scan (default: 5)
#
# Exit codes:
#   0 - terminal blocker detected (skip dispatch)
#   1 - no blocker found (safe to dispatch)
#   2 - API error (fail open — allow dispatch to proceed)
#######################################
#######################################
# Match terminal blocker patterns in comment bodies (GH#5627)
#
# Checks concatenated comment bodies against known blocker patterns.
# Returns blocker_reason and user_action via stdout (2 lines).
#
# Arguments:
#   $1 - all_bodies (concatenated comment text)
# Output: 2 lines to stdout (blocker_reason, user_action) — empty if no match
# Exit codes:
#   0 - blocker pattern matched
#   1 - no match
#######################################
_match_terminal_blocker_pattern() {
	local all_bodies="$1"
	local blocker_reason=""
	local user_action=""

	# Pattern 1: workflow scope missing
	if echo "$all_bodies" | grep -qiE 'workflow scope|refusing to allow an OAuth App to create or update workflow|token lacks.*workflow'; then
		blocker_reason="GitHub token lacks \`workflow\` scope — workers cannot push workflow file changes"
		user_action="Run \`gh auth refresh -s workflow\` to add the workflow scope to your token, then remove the \`status:blocked\` label."
	# Pattern 2: generic token/auth scope issues
	elif echo "$all_bodies" | grep -qiE 'token lacks.*scope|missing.*scope.*token|token.*missing.*scope'; then
		blocker_reason="GitHub token is missing a required scope — workers cannot complete this task"
		user_action="Check the error details in the comments above, run \`gh auth refresh -s <missing-scope>\` to add the required scope, then remove the \`status:blocked\` label."
	# Pattern 3: ACTION REQUIRED (supervisor-posted)
	elif echo "$all_bodies" | grep -qF 'ACTION REQUIRED'; then
		blocker_reason="A previous supervisor comment flagged this issue as requiring user action"
		user_action="Read the ACTION REQUIRED comment above, complete the requested action, then remove the \`status:blocked\` label."
	# Pattern 4: persistent authentication/permission failures
	elif echo "$all_bodies" | grep -qiE 'authentication required.*workflow|permission denied.*workflow|push declined.*workflow'; then
		blocker_reason="Persistent authentication or permission failure for workflow files"
		user_action="Check your GitHub token scopes with \`gh auth status\`, refresh if needed with \`gh auth refresh -s workflow\`, then remove the \`status:blocked\` label."
	fi

	if [[ -z "$blocker_reason" ]]; then
		return 1
	fi

	echo "$blocker_reason"
	echo "$user_action"
	return 0
}

#######################################
# Apply terminal blocker labels and comment to an issue (GH#5627)
#
# Idempotent — checks for existing label and comment before acting.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - blocker_reason
#   $4 - user_action
#   $5 - all_bodies (for existing comment check)
#######################################
_apply_terminal_blocker() {
	local issue_number="$1"
	local repo_slug="$2"
	local blocker_reason="$3"
	local user_action="$4"
	local all_bodies="$5"

	# Check if already labelled
	local existing_labels
	existing_labels=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || existing_labels=""

	local already_blocked=false
	if [[ ",${existing_labels}," == *",status:blocked,"* ]]; then
		already_blocked=true
	fi

	# Add label if not already present (t2033: use set_issue_status to atomically
	# clear all sibling status:* labels, not just available/queued)
	if [[ "$already_blocked" == "false" ]]; then
		set_issue_status "$issue_number" "$repo_slug" "blocked" || true
	fi

	# Post comment if not already posted (idempotent — safe against concurrent pulses)
	local blocker_body="**Terminal blocker detected** (GH#5141) — skipping dispatch.

**Reason:** ${blocker_reason}

**Action required:** ${user_action}

---
*This issue will not be dispatched to workers until the blocker is resolved. Once you have completed the required action, remove the \`status:blocked\` label to re-enable dispatch.*"

	_gh_idempotent_comment "$issue_number" "$repo_slug" \
		"Terminal blocker detected" "$blocker_body"

	return 0
}

check_terminal_blockers() {
	local issue_number="$1"
	local repo_slug="$2"
	local max_comments="${3:-5}"
	[[ "$max_comments" =~ ^[0-9]+$ ]] || max_comments=5

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] check_terminal_blockers: missing arguments" >>"$LOGFILE"
		return 2
	fi

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
		return 2
	fi

	# Fetch the last N comments
	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--jq "[ .[-${max_comments}:][] | {body: .body, created_at: .created_at} ]" 2>/dev/null)
	local api_exit=$?

	if [[ $api_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_terminal_blockers: API error (exit=$api_exit) for #${issue_number} in ${repo_slug} — failing open" >>"$LOGFILE"
		return 2
	fi

	if [[ -z "$comments_json" || "$comments_json" == "[]" || "$comments_json" == "null" ]]; then
		return 1
	fi

	# Concatenate comment bodies for pattern matching
	local all_bodies
	all_bodies=$(echo "$comments_json" | jq -r '.[].body // ""' 2>/dev/null)

	if [[ -z "$all_bodies" ]]; then
		return 1
	fi

	# Match against known terminal blocker patterns
	local pattern_output
	pattern_output=$(_match_terminal_blocker_pattern "$all_bodies") || return 1

	local blocker_reason user_action
	blocker_reason=$(echo "$pattern_output" | sed -n '1p')
	user_action=$(echo "$pattern_output" | sed -n '2p')

	# Apply labels and comment
	_apply_terminal_blocker "$issue_number" "$repo_slug" "$blocker_reason" "$user_action" "$all_bodies"

	echo "[pulse-wrapper] check_terminal_blockers: blocker detected for #${issue_number} in ${repo_slug} — ${blocker_reason}" >>"$LOGFILE"
	return 0
}
