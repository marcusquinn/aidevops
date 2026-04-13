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
#   - _is_task_committed_to_main
#   - _issue_targets_large_files
#   - _dispatch_dedup_check_layers  (t1999: extracted from dispatch_with_dedup)
#   - _dispatch_launch_worker       (t1999: extracted from dispatch_with_dedup)
#   - dispatch_with_dedup           (t1999: thin orchestrator, <80 lines)
#   - _match_terminal_blocker_pattern
#   - _apply_terminal_blocker
#   - check_terminal_blockers
#
# Pure move from pulse-wrapper.sh. Byte-identical function bodies.
# Phase 12 post-gate simplification: _is_task_committed_to_main split into
# _task_id_in_recent_commits, _task_id_in_merged_pr, _task_id_in_changed_files
# (t2004). Phase 12 (t1999): dispatch_with_dedup split into decision helper
# (_dispatch_dedup_check_layers) + action helper (_dispatch_launch_worker)
# + thin orchestrator. External signature of dispatch_with_dedup unchanged.

[[ -n "${_PULSE_DISPATCH_CORE_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_CORE_LOADED=1

#######################################
# Resolve the worker tier from issue labels. When multiple tier:* labels
# are present (collision — see t1997), pick the highest rank order.
# Fallback: tier:standard if no tier label is present.
# Arguments:
#   $1 - comma-separated label list (e.g., "bug,tier:simple,auto-dispatch")
# Output:
#   tier:reasoning, tier:standard, or tier:simple
# Exit codes:
#   0 - always succeeds
#######################################
_resolve_worker_tier() {
	local labels_csv="$1"
	# Convert to lowercase for case-insensitive matching (Bash 3.2 compatible)
	local labels_lower
	labels_lower=$(printf '%s' "$labels_csv" | tr '[:upper:]' '[:lower:]')
	local labels_with_commas=",${labels_lower},"

	if [[ "$labels_with_commas" == *",tier:reasoning,"* ]]; then
		printf 'tier:reasoning'
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
# Check if dispatching a worker would be a duplicate (GH#4400, GH#5210, GH#6696, GH#11086)
#
# Seven-layer dedup:
#   1. dispatch-ledger-helper.sh check-issue — in-flight ledger (GH#6696)
#   2. has_worker_for_repo_issue() — exact repo+issue process match
#   3. dispatch-dedup-helper.sh is-duplicate — normalized title key match
#   4. dispatch-dedup-helper.sh has-open-pr — merged PR evidence for issue/task
#   5. dispatch-dedup-helper.sh has-dispatch-comment — cross-machine dispatch comment (GH#11141)
#   6. dispatch-dedup-helper.sh is-assigned — cross-machine assignee guard (GH#6891)
#   7. dispatch-dedup-helper.sh claim — cross-machine optimistic lock (GH#11086)
#
# Layer 1 (ledger) is checked first because it's the fastest (local file
# read, no process scanning or GitHub API calls) and catches the primary
# failure mode: workers dispatched but not yet visible in process lists
# or GitHub PRs (the 10-15 minute gap between dispatch and PR creation).
#
# Layer 6 (claim) is last because it's the slowest (posts a GitHub comment,
# sleeps DISPATCH_CLAIM_WINDOW seconds, re-reads comments). It's the final
# cross-machine safety net: two runners that pass layers 1-5 simultaneously
# will both post a claim, but only the oldest claim wins. Previously this
# was an LLM-instructed step in pulse.md that runners could skip — the
# GH#11086 incident showed both marcusquinn and johnwaldo dispatching on
# the same issue 45 seconds apart because the LLM skipped the claim step.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - dispatch title (e.g., "Issue #42: Fix auth")
#   $4 - issue title (optional; used for merged-PR task-id fallback)
#   $5 - self login (optional; runner's GitHub login for assignee check)
# Exit codes:
#   0 - duplicate detected (do NOT dispatch)
#   1 - no duplicate (safe to dispatch)
#######################################
check_dispatch_dedup() {
	local issue_number="$1"
	local repo_slug="$2"
	local title="$3"
	local issue_title="${4:-}"
	local self_login="${5:-}"

	# Layer 1 (GH#6696): in-flight dispatch ledger — catches workers between
	# dispatch and PR creation (the 10-15 min gap that caused duplicate dispatches)
	local ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$ledger_helper" ]] && [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		if "$ledger_helper" check-issue --issue "$issue_number" --repo "$repo_slug" >/dev/null 2>&1; then
			echo "[pulse-wrapper] Dedup: in-flight ledger entry for #${issue_number} in ${repo_slug} (GH#6696)" >>"$LOGFILE"
			return 0
		fi
	fi

	# Layer 2: exact repo+issue process match
	if has_worker_for_repo_issue "$issue_number" "$repo_slug"; then
		echo "[pulse-wrapper] Dedup: worker already running for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
		return 0
	fi

	# Layer 3: normalized title key match via dispatch-dedup-helper
	local dedup_helper="${SCRIPT_DIR}/dispatch-dedup-helper.sh"
	if [[ -x "$dedup_helper" ]] && [[ -n "$title" ]]; then
		if "$dedup_helper" is-duplicate "$title" >/dev/null 2>&1; then
			echo "[pulse-wrapper] Dedup: title match for '${title}' — worker already running" >>"$LOGFILE"
			return 0
		fi
	fi

	# Layer 4: open or merged PR evidence for this issue/task — if a worker
	# already produced a PR (open or merged), don't dispatch another worker.
	# Previously only checked --state merged, missing open PRs entirely.
	local dedup_helper_output=""
	if [[ -x "$dedup_helper" ]]; then
		if dedup_helper_output=$("$dedup_helper" has-open-pr "$issue_number" "$repo_slug" "$issue_title" 2>>"$LOGFILE"); then
			if [[ -n "$dedup_helper_output" ]]; then
				echo "[pulse-wrapper] Dedup: ${dedup_helper_output}" >>"$LOGFILE"
			else
				echo "[pulse-wrapper] Dedup: PR evidence already exists for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
			fi
			return 0
		fi
	fi

	# Layer 5 (GH#11141): cross-machine dispatch comment check — detects
	# "Dispatching worker" comments posted by other runners. This is the
	# persistent cross-machine signal that survives beyond the claim lock's
	# 8-second window. The GH#11141 incident: marcusquinn dispatched at
	# 02:36, johnwaldo dispatched at 03:18 (42 min later). The claim lock
	# had long expired, the ledger is local-only, and the assignee guard
	# excluded the repo owner. But the "Dispatching worker" comment was
	# sitting right there on the issue — visible to all runners.
	if [[ -x "$dedup_helper" ]] && [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		local dispatch_comment_output=""
		if dispatch_comment_output=$("$dedup_helper" has-dispatch-comment "$issue_number" "$repo_slug" "$self_login" 2>>"$LOGFILE"); then
			echo "[pulse-wrapper] Dedup: #${issue_number} in ${repo_slug} has active dispatch comment — ${dispatch_comment_output}" >>"$LOGFILE"
			return 0
		fi
	fi

	# Layer 6 (GH#6891): cross-machine assignee guard — prevents runners from
	# dispatching workers for issues already assigned to another login. Only
	# self_login is excluded; repo owner and maintainer are NOT excluded since
	# they may also be runners (GH#11141 fix — reverts the GH#10521 exclusion).
	if [[ -x "$dedup_helper" ]] && [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		local assigned_output=""
		if assigned_output=$("$dedup_helper" is-assigned "$issue_number" "$repo_slug" "$self_login" 2>>"$LOGFILE"); then
			echo "[pulse-wrapper] Dedup: #${issue_number} in ${repo_slug} already assigned — ${assigned_output}" >>"$LOGFILE"
			return 0
		fi
		# t1927: Stale recovery must record fast-fail. When _is_stale_assignment()
		# recovers a stale assignment (silent worker timeout), the dedup helper
		# outputs STALE_RECOVERED on stdout. Without recording this as a failure,
		# the fast-fail counter stays at 0 and the issue loops through unlimited
		# dispatch→timeout→stale-recovery cycles. Observed: 8+ dispatches in 6h
		# with 0 PRs and 0 fast-fail entries (GH#17700, GH#17701, GH#17702).
		if [[ "$assigned_output" == *STALE_RECOVERED* ]]; then
			echo "[pulse-wrapper] Dedup: stale recovery detected for #${issue_number} in ${repo_slug} — recording fast-fail (t1927)" >>"$LOGFILE"
			fast_fail_record "$issue_number" "$repo_slug" "stale_timeout" || true
		fi
	fi

	# Layer 7 (GH#11086): cross-machine optimistic claim lock — the final safety
	# net for multi-runner environments. Posts a plain-text claim comment on the issue,
	# sleeps the consensus window (default 8s), then checks if this runner's claim
	# is the oldest. Only the first claimant proceeds; others back off.
	#
	# Previously this was an LLM-instructed step in pulse.md that runners could
	# skip. The GH#11086 incident: marcusquinn dispatched at 23:07:43, johnwaldo
	# dispatched at 23:08:28 — 45 seconds apart on the same issue because the
	# LLM skipped the claim step. Moving it here makes it deterministic.
	#
	# Exit codes from claim: 0=won, 1=lost, 2=error (fail-open).
	# On error (exit 2), we allow dispatch to proceed — better to risk a rare
	# duplicate than to block all dispatch on a transient GitHub API failure.
	#
	# GH#15317: Capture claim output to extract comment_id for cleanup after
	# the deterministic dispatch comment is posted. Uses the caller's
	# _claim_comment_id variable (declared in dispatch_with_dedup) via bash
	# dynamic scoping — do NOT declare local here or the value is lost on return.
	_claim_comment_id=""
	if [[ -x "$dedup_helper" ]] && [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		# GH#17590: Pre-check for existing claims BEFORE posting our own.
		# Without this, two runners both post claims within seconds, then
		# the consensus window resolves the race — but the losing claim
		# comment is left on the issue, wasting a GitHub API call and
		# cluttering the issue. The pre-check is cheap (read-only) and
		# catches the common case where another runner already claimed.
		local _precheck_output="" _precheck_exit=0
		_precheck_output=$("$dedup_helper" check-claim "$issue_number" "$repo_slug") || _precheck_exit=$?
		if [[ "$_precheck_exit" -eq 0 ]]; then
			# Active claim exists from another runner — skip claim entirely
			echo "[pulse-wrapper] Dedup: pre-check found active claim on #${issue_number} in ${repo_slug} — skipping (${_precheck_output})" >>"$LOGFILE"
			return 0
		fi
		# No active claim found (exit 1) or error (exit 2, fail-open) — proceed to claim
		local claim_exit=0 claim_output=""
		claim_output=$("$dedup_helper" claim "$issue_number" "$repo_slug" "$self_login" 2>>"$LOGFILE") || claim_exit=$?
		echo "$claim_output" >>"$LOGFILE"
		if [[ "$claim_exit" -eq 1 ]]; then
			echo "[pulse-wrapper] Dedup: claim lost for #${issue_number} in ${repo_slug} — another runner claimed first (GH#11086)" >>"$LOGFILE"
			return 0
		fi
		if [[ "$claim_exit" -eq 2 ]]; then
			echo "[pulse-wrapper] Dedup: claim error for #${issue_number} in ${repo_slug} — proceeding (fail-open)" >>"$LOGFILE"
		fi
		# Extract claim comment_id for post-dispatch cleanup (GH#15317)
		_claim_comment_id=$(printf '%s' "$claim_output" | sed -n 's/.*comment_id=\([0-9]*\).*/\1/p')
		# claim_exit 0 = won, proceed to dispatch
	fi

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
		git -C "$repo_path" fetch origin main --quiet 2>/dev/null 9>&- || true
	else
		return 1
	fi

	_task_id_in_recent_commits "$issue_title" "$repo_path" "$created_at" && return 0
	_task_id_in_merged_pr "$issue_number" "$repo_path" "$created_at" && return 0
	_task_id_in_changed_files "$issue_number" "$issue_title" "$repo_path" && return 0
	return 1
}

_issue_targets_large_files() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_body="$3"
	local repo_path="$4"
	# t1998: force_recheck bypasses the skip-if-already-labeled short-circuit
	# below. The normal dispatch path leaves this false (perf optimisation —
	# no need to re-run wc -l on an issue we just gated). The re-evaluation
	# path in pulse-triage.sh _reevaluate_simplification_labels() passes
	# "true" so it can detect when a previously-gated file has been
	# simplified below threshold and clear the label.
	local force_recheck="${5:-false}"

	[[ -n "$issue_body" ]] || return 1
	[[ -d "$repo_path" ]] || return 1

	local issue_labels
	issue_labels=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels=""

	# GH#18042: Never gate simplification tasks behind the large-file gate.
	# Issues tagged "simplification" or "simplification-debt" exist to reduce
	# the file — blocking them creates a deadlock where the file can never be
	# simplified because the simplification issue is held by the gate.
	# If the label was already applied (e.g., before this fix), auto-clear it.
	if [[ ",$issue_labels," == *",simplification,"* ]] ||
		[[ ",$issue_labels," == *",simplification-debt,"* ]]; then
		if [[ ",$issue_labels," == *",needs-simplification,"* ]]; then
			if gh issue edit "$issue_number" --repo "$repo_slug" \
				--remove-label "needs-simplification" >/dev/null 2>&1; then
				echo "[pulse-wrapper] Simplification gate auto-cleared for #${issue_number} (${repo_slug}) — issue is itself a simplification task (GH#18042)" >>"$LOGFILE"
			else
				echo "[pulse-wrapper] WARN: failed to remove needs-simplification label from #${issue_number} (${repo_slug}); will retry next cycle (GH#18042)" >>"$LOGFILE"
			fi
		fi
		# Always return 1 (don't gate) — the issue IS simplification work
		# regardless of whether the label removal succeeded.
		return 1
	fi

	# Skip if already labeled (avoid re-checking every cycle).
	# EXCEPTION (t1998): when called from _reevaluate_simplification_labels,
	# force_recheck is "true" and we bypass this short-circuit. Without the
	# bypass, the re-eval path can never clear a stale label because it
	# always sees an immediate return 0 on labeled issues. This made
	# #18346 and any similar stale issue impossible to unstick even after
	# the target file had been simplified below threshold.
	if [[ "$force_recheck" != "true" ]] &&
		[[ ",$issue_labels," == *",needs-simplification,"* ]]; then
		return 0
	fi
	# Skip if simplification was already done
	if [[ ",$issue_labels," == *",simplified,"* ]]; then
		return 1
	fi

	# GH#17958: Skip if issue is already dispatched (worker actively running).
	# A second pulse cycle can re-evaluate the same issue and post a spurious
	# simplification comment even though the worker is mid-implementation.
	# The gate should only fire for issues that haven't been claimed yet.
	if [[ ",$issue_labels," == *",status:queued,"* ]] ||
		[[ ",$issue_labels," == *",status:in-progress,"* ]]; then
		return 1
	fi
	# Also skip if assigned with origin:worker — worker was dispatched even if
	# status label hasn't been applied yet (race window between assign and label).
	if [[ ",$issue_labels," == *",origin:worker,"* ]]; then
		local assignee_count
		assignee_count=$(gh issue view "$issue_number" --repo "$repo_slug" \
			--json assignees --jq '.assignees | length' 2>/dev/null) || assignee_count="0"
		if [[ "$assignee_count" -gt 0 ]]; then
			return 1
		fi
	fi

	# Extract file paths from "EDIT:" and "Files to Modify" patterns in body.
	# Patterns: "EDIT: path/to/file.sh", "EDIT: path/to/file.sh:123",
	#           "EDIT: path/to/file.sh:123-456", "- EDIT: path/to/file"
	#
	# t2024: Preserve any trailing ":NNN" or ":START-END" line qualifier so
	# the gate loop below can distinguish scoped ranges from whole-file targets.
	# Previously this extractor stripped the qualifier via `sed 's/:.*//'`,
	# which threw away the one piece of information needed to tell "targeted
	# edit in a 30-line range" from "rewrite the whole 3000-line file".
	local file_paths
	file_paths=$(printf '%s' "$issue_body" | grep -oE '(EDIT|NEW|File):?\s+[`"]?\.?agents/scripts/[^`"[:space:],]+' 2>/dev/null |
		sed 's/^[A-Z]*:*[[:space:]]*//' | sed 's/^[`"]//' | sed 's/[`"]*$//' | sort -u) || file_paths=""

	# Also check for backtick-quoted filenames that look like script paths.
	# GH#17897: Only match backtick paths on lines that look like implementation
	# targets (list items, "File:" markers), not paths mentioned as evidence in
	# review feedback prose. Previously, files cited in Gemini review comments
	# (e.g., "aidevops.sh hashes were updated") triggered the large-file gate
	# even though they weren't implementation targets.
	#
	# t2024: Also preserve line qualifiers here. A list-item reference like
	#   - **Broken extractor:** `pulse-ancillary-dispatch.sh:221-253`
	# should be parsed as "file + range", not stripped to bare "file".
	local backtick_paths
	backtick_paths=$(printf '%s' "$issue_body" | grep -E '^\s*[-*]\s|^(EDIT|NEW|File):' 2>/dev/null |
		grep -oE '`[^`]*\.(sh|py|js|ts)[^`]*`' 2>/dev/null |
		tr -d '`' | grep -v '^#' | sort -u) || backtick_paths=""

	# Combine and deduplicate
	local all_paths
	all_paths=$(printf '%s\n%s' "$file_paths" "$backtick_paths" | sort -u | grep -v '^$') || all_paths=""

	[[ -n "$all_paths" ]] || return 1

	# Files that are large by nature and can't/shouldn't be "simplified":
	# lockfiles, generated data, JSON/YAML configs, binary-adjacent formats.
	# These should never block dispatch — workers don't modify them directly.
	# GH#17897: Also skip all .json/.yaml/.yml/.toml/.xml/.csv data files —
	# these are config/data, not code. The simplification routine doesn't
	# target them, so gating dispatch on their size is incorrect.
	local _skip_pattern='(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|composer\.lock|Cargo\.lock|Gemfile\.lock|poetry\.lock|simplification-state\.json|\.min\.(js|css)$|\.json$|\.yaml$|\.yml$|\.toml$|\.xml$|\.csv$)'

	local found_large=false
	local large_files=""
	local large_file_paths=""
	while IFS= read -r raw_target; do
		[[ -z "$raw_target" ]] && continue

		# t2024: Parse optional line qualifier off the end of the target.
		#   "file.sh"            → fpath="file.sh", line_spec=""
		#   "file.sh:1477"       → fpath="file.sh", line_spec="1477"
		#   "file.sh:221-253"    → fpath="file.sh", line_spec="221-253"
		# Only accept a line qualifier when it's numeric (optionally ranged).
		# Anything else (colons inside shell-safe paths, rare but possible)
		# is preserved as part of the path.
		local fpath="$raw_target"
		local line_spec=""
		if [[ "$raw_target" =~ ^(.+):([0-9]+(-[0-9]+)?)$ ]]; then
			fpath="${BASH_REMATCH[1]}"
			line_spec="${BASH_REMATCH[2]}"
		fi

		# Skip non-simplifiable files (lockfiles, generated data, configs)
		local basename_fpath
		basename_fpath=$(basename "$fpath")
		if printf '%s' "$basename_fpath" | grep -qE "$_skip_pattern" 2>/dev/null; then
			continue
		fi

		# Resolve path relative to repo
		local full_path=""
		if [[ -f "${repo_path}/${fpath}" ]]; then
			full_path="${repo_path}/${fpath}"
		elif [[ -f "${repo_path}/.agents/${fpath}" ]]; then
			full_path="${repo_path}/.agents/${fpath}"
		elif [[ -f "${repo_path}/.${fpath}" ]]; then
			full_path="${repo_path}/.${fpath}"
		else
			continue
		fi

		# t2024: scoped-range and single-line qualifier handling.
		#
		# 1. Single-line references (no range) are context for the human
		#    reader — they help locate the bug but do not describe an edit
		#    target. Skip them for gate evaluation entirely.
		# 2. Ranged references that fit inside SCOPED_RANGE_THRESHOLD bypass
		#    the file-size check — the worker only navigates the cited range.
		# 3. Anything else (no qualifier, or range too large) falls through
		#    to the file-size check as before.
		if [[ "$line_spec" =~ ^[0-9]+$ ]]; then
			echo "[pulse-wrapper] Large-file gate: #${issue_number} skipping ${fpath}:${line_spec} (single-line citation — context reference, not edit target)" >>"$LOGFILE"
			continue
		fi
		if [[ "$line_spec" =~ ^([0-9]+)-([0-9]+)$ ]]; then
			local _range_start="${BASH_REMATCH[1]}"
			local _range_end="${BASH_REMATCH[2]}"
			local _range_size=$((_range_end - _range_start + 1))
			if [[ "$_range_size" -gt 0 && "$_range_size" -le "$SCOPED_RANGE_THRESHOLD" ]]; then
				echo "[pulse-wrapper] Large-file gate: #${issue_number} scoped-range pass for ${fpath}:${line_spec} (${_range_size} lines, threshold ${SCOPED_RANGE_THRESHOLD})" >>"$LOGFILE"
				continue
			fi
		fi

		local line_count=0
		line_count=$(wc -l <"$full_path" 2>/dev/null | tr -d ' ') || line_count=0
		if [[ "$line_count" -ge "$LARGE_FILE_LINE_THRESHOLD" ]]; then
			found_large=true
			large_files="${large_files}${fpath} (${line_count} lines), "
			large_file_paths="${large_file_paths}${fpath}\n"
		fi
	done <<<"$all_paths"

	if [[ "$found_large" == "true" ]]; then
		# Add label to hold dispatch
		gh label create "needs-simplification" \
			--repo "$repo_slug" \
			--description "Issue targets large file(s) needing simplification first" \
			--color "D93F0B" \
			--force 2>/dev/null || true
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "needs-simplification" 2>/dev/null || true

		large_files="${large_files%, }"

		# Create simplification-debt issues for each large file immediately
		# (don't wait for the daily complexity scan). Dedup: skip if an open
		# simplification-debt issue already mentions this file.
		local _created_issues=""
		while IFS= read -r _lf_path; do
			[[ -z "$_lf_path" ]] && continue
			local _lf_basename
			_lf_basename=$(basename "$_lf_path")
			# Check if a simplification-debt issue already exists for this file
			local _existing
			_existing=$(gh issue list --repo "$repo_slug" --state open \
				--label "simplification-debt" --search "$_lf_basename" \
				--json number --jq '.[0].number // empty' --limit 5 2>/dev/null) || _existing=""
			if [[ -n "$_existing" ]]; then
				_created_issues="${_created_issues}#${_existing} (existing), "
				continue
			fi
			# Create the simplification-debt issue now
			local _new_num
			_new_num=$(gh issue create --repo "$repo_slug" \
				--title "simplification-debt: ${_lf_path} exceeds ${LARGE_FILE_LINE_THRESHOLD} lines" \
				--label "simplification-debt,auto-dispatch,origin:worker" \
				--body "## What
Simplify \`${_lf_path}\` — currently over ${LARGE_FILE_LINE_THRESHOLD} lines. Break into smaller, focused modules.

## Why
Issue #${issue_number} is blocked by the large-file gate. Workers dispatched against this file spend most of their context budget reading it, leaving insufficient capacity for implementation.

## How
- EDIT: \`${_lf_path}\`
- Extract cohesive function groups into separate files
- Keep a thin orchestrator in the original file that sources/imports the extracted modules
- Verify: \`wc -l ${_lf_path}\` should be below ${LARGE_FILE_LINE_THRESHOLD}

_Created by large-file simplification gate (pulse-wrapper.sh)_" \
				--json number --jq '.number' 2>/dev/null) || _new_num=""
			if [[ -n "$_new_num" ]]; then
				_created_issues="${_created_issues}#${_new_num} (new), "
				echo "[pulse-wrapper] Created simplification-debt issue #${_new_num} for ${_lf_path} (blocking #${issue_number})" >>"$LOGFILE"
			fi
		done < <(printf '%b' "$large_file_paths")

		_created_issues="${_created_issues%, }"
		local simplification_body="## Large File Simplification Gate

This issue references file(s) exceeding ${LARGE_FILE_LINE_THRESHOLD} lines: ${large_files}.

Workers dispatched against large files spend most of their context budget reading the file, leaving insufficient capacity for implementation.

**Simplification issues:** ${_created_issues:-none created}

**Status:** Held from dispatch until simplification completes. The \`needs-simplification\` label will be removed automatically when the target file(s) are below threshold.

_Automated by \`_issue_targets_large_files()\` in pulse-wrapper.sh_"

		_gh_idempotent_comment "$issue_number" "$repo_slug" \
			"## Large File Simplification Gate" "$simplification_body"

		echo "[pulse-wrapper] Large-file gate: #${issue_number} in ${repo_slug} targets ${large_files}" >>"$LOGFILE"
		return 0
	fi

	# If was_already_labeled but no large files found (e.g., all files now
	# excluded by skip pattern or simplified below threshold), auto-clear.
	if [[ ",$issue_labels," == *",needs-simplification,"* ]]; then
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--remove-label "needs-simplification" >/dev/null 2>&1 || true
		echo "[pulse-wrapper] Simplification gate cleared for #${issue_number} (${repo_slug}) — no large files after exclusion filter" >>"$LOGFILE"
	fi

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

	if [[ "$target_state" != "OPEN" ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: issue state is ${target_state:-unknown}" >>"$LOGFILE"
		return 1
	fi

	if printf '%s' "$issue_meta_json" | jq -e '.labels | map(.name) | (index("supervisor") or index("contributor") or index("persistent") or index("quality-review") or index("on hold") or index("blocked"))' >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: non-dispatchable management label present" >>"$LOGFILE"
		return 1
	fi

	local known_ever_nmr="unknown"
	if printf '%s' "$issue_meta_json" | jq -e '.labels | map(.name) | index("needs-maintainer-review")' >/dev/null 2>&1; then
		known_ever_nmr="true"
	fi

	# t1894: Cryptographic approval gate — block dispatch for issues that were
	# ever labeled needs-maintainer-review without a signed approval.
	if ! issue_has_required_approval "$issue_number" "$repo_slug" "$known_ever_nmr"; then
		echo "[pulse-wrapper] dispatch_with_dedup: BLOCKED #${issue_number} in ${repo_slug} — requires cryptographic approval (ever-NMR)" >>"$LOGFILE"
		return 1
	fi

	if [[ "$target_title" == \[Supervisor:* ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: supervisor telemetry title" >>"$LOGFILE"
		return 1
	fi

	# GH#17574: Skip dispatch if the task has already been committed directly
	# to main. Workers that bypass the PR flow (direct commits) complete the
	# work invisibly — the issue stays open until the pulse's mark-complete
	# pass runs, which happens AFTER dispatch decisions. Without this check,
	# the pulse dispatches redundant workers for already-completed work.
	if _is_task_committed_to_main "$issue_number" "$repo_slug" "$target_title" "$repo_path"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: task already committed to main (GH#17574)" >>"$LOGFILE"
		# GH#17642: Do NOT auto-close the issue. The main-commit check has a
		# high false-positive rate (casual mentions, multi-runner deployment
		# gaps, stale patterns). A false skip is harmless (next cycle retries),
		# a false close is destructive (needs manual reopen, re-dispatch, and
		# loses worker context). Let the verified merge-pass or human close it.
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
# Post-clearance worker launch for dispatch_with_dedup.
# Extracted from dispatch_with_dedup (t1999, Phase 12) to reduce the
# parent function to a thin orchestrator.
#
# Executes all post-clearance steps after _dispatch_dedup_check_layers
# has confirmed the issue is safe to dispatch:
#   - Issue edit: replace assignees, add status:queued + origin:worker
#   - Worker log file setup (per-issue temp log, GH#14483)
#   - Model/tier resolution (round-robin, t1997)
#   - Issue + linked PR lock (t1894/t1934)
#   - Git pull to latest remote commit (GH#17584)
#   - Worktree pre-creation for the worker (5-8 tool call savings)
#   - Worker command construction + nohup launch (GH#17549)
#   - Stagger delay (SQLite contention, GH#17549)
#   - Dispatch ledger registration (tier telemetry)
#   - Deterministic dispatch comment (GH#15317)
#   - Claim comment audit trail retention (GH#17503)
#
# Arguments:
#    $1 - issue_number
#    $2 - repo_slug (owner/repo)
#    $3 - dispatch_title
#    $4 - issue_title
#    $5 - self_login (dispatching runner login)
#    $6 - repo_path (local path to the repo)
#    $7 - prompt (worker prompt string)
#    $8 - session_key
#    $9 - model_override (empty = auto-select via round-robin)
#   $10 - issue_meta_json (pre-fetched JSON: number,title,state,labels,assignees)
#
# Dynamic scoping: reads/writes _claim_comment_id from the calling
# dispatch_with_dedup frame (set by check_dispatch_dedup, GH#15317).
# Do NOT declare local _claim_comment_id here — it must remain in the
# caller's scope so the value survives the function return.
#
# Exit codes:
#   0 - worker launched successfully
#   non-zero - launch failed (logged to LOGFILE)
#######################################
_dispatch_launch_worker() {
	local issue_number="$1"
	local repo_slug="$2"
	local dispatch_title="$3"
	local issue_title="$4"
	local self_login="$5"
	local repo_path="$6"
	local prompt="$7"
	local session_key="$8"
	local model_override="$9"
	local issue_meta_json="${10}"

	# Replace existing assignees with dispatching runner (GH#17777).
	# Previous behavior only added self (--add-assignee), leaving the original
	# assignee (typically the issue creator) co-assigned. This created ambiguity
	# about ownership and confused dedup layer 6 (is_assigned) when status:queued
	# made passive owner assignments appear active.
	#
	# t2033: use set_issue_status to atomically clear sibling status:* labels.
	# Before t2033, this call site added status:queued without removing
	# status:available — #18444/#18454/#18455 accumulated both labels and
	# broke t2008 stale-recovery tick counting.
	local -a _extra_flags=(--add-assignee "$self_login" --add-label "origin:worker")
	local _prev_login
	while IFS= read -r _prev_login; do
		[[ -n "$_prev_login" && "$_prev_login" != "$self_login" ]] && _extra_flags+=(--remove-assignee "$_prev_login")
	done < <(printf '%s' "$issue_meta_json" | jq -r '.assignees[].login' 2>/dev/null)

	set_issue_status "$issue_number" "$repo_slug" "queued" "${_extra_flags[@]}" || true

	# Detach worker stdio from the dispatcher (GH#14483).
	# Without this, background workers inherit the candidate-loop stdin created by
	# process substitutions and can consume the remaining candidate stream,
	# causing the deterministic fill floor to stop after one dispatch. Redirect
	# worker stdout/stderr into per-issue temp logs so launch validation reads the
	# intended output file and dispatcher shells stay clean.
	local safe_slug worker_log worker_log_fallback
	safe_slug=$(printf '%s' "$repo_slug" | tr '/:' '--')
	worker_log="/tmp/pulse-${safe_slug}-${issue_number}.log"
	worker_log_fallback="/tmp/pulse-${issue_number}.log"
	rm -f "$worker_log" "$worker_log_fallback"
	: >"$worker_log"
	ln -s "$worker_log" "$worker_log_fallback" 2>/dev/null || true

	# ROUND-ROBIN MODEL SELECTION (owned by this function, NOT the caller).
	#
	# When model_override (param 9) is EMPTY, this function calls
	# headless-runtime-helper.sh select --role worker, which resolves the
	# worker model from the routing table / local override (respecting
	# backoff DB, auth availability, provider allowlists, and rotation).
	# The resolved model name is shown in the dispatch comment so the audit
	# trail records exactly which provider/model the worker used.
	#
	# IMPORTANT: Callers MUST NOT pass a model override for default dispatches.
	# Only pass model_override when a specific tier is required (e.g.,
	# tier:reasoning → opus escalation, tier:simple → haiku). Passing an
	# arbitrary model here bypasses the round-robin and causes provider
	# imbalance. History: GH#17503 moved model resolution here from the worker.
	local dispatch_tier="standard"
	local dispatch_model_tier="sonnet"
	local issue_labels_csv
	issue_labels_csv=$(printf '%s' "$issue_meta_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels_csv=""

	# Resolve tier from labels, preferring highest rank when multiple present (t1997)
	local resolved_tier
	resolved_tier=$(_resolve_worker_tier "$issue_labels_csv")
	case "$resolved_tier" in
	tier:reasoning)
		dispatch_tier="reasoning"
		dispatch_model_tier="opus"
		;;
	tier:standard)
		dispatch_tier="standard"
		dispatch_model_tier="sonnet"
		;;
	tier:simple)
		dispatch_tier="simple"
		dispatch_model_tier="haiku"
		;;
	esac

	local selected_model=""
	if [[ -n "$model_override" ]]; then
		selected_model="$model_override"
	else
		selected_model=$("$HEADLESS_RUNTIME_HELPER" select --role worker --tier "$dispatch_model_tier" 2>/dev/null) || selected_model=""
	fi

	# t1894/t1934: Lock issue and linked PRs during worker execution
	lock_issue_for_worker "$issue_number" "$repo_slug"

	# GH#17584: Ensure the repo is on the latest remote commit before
	# launching the worker. Without this, workers on stale checkouts
	# close issues as "Invalid — file does not exist" when the target
	# file was added in a recent commit they haven't pulled.
	if git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git -C "$repo_path" pull --ff-only --no-rebase >>"$LOGFILE" 2>&1 9>&- || {
			echo "[dispatch_with_dedup] Warning: git pull failed for ${repo_path} — proceeding with current checkout" >>"$LOGFILE"
		}
	fi

	# Pre-create worktree for the worker so it can start coding immediately
	# instead of spending 5-8 tool calls on worktree setup. The worktree is
	# idempotent — if a previous worker already created it, add returns the
	# existing path. On failure, fall back to letting the worker create it.
	local worker_worktree_path="" worker_worktree_branch=""
	local _wt_helper="${SCRIPT_DIR}/worktree-helper.sh"
	if [[ -x "$_wt_helper" && -d "$repo_path" ]]; then
		# Derive branch name from timestamp (deterministic, collision-free)
		worker_worktree_branch="feature/auto-$(date +%Y%m%d-%H%M%S)"
		local _wt_output=""
		# Run from repo_path — worktree-helper.sh uses git commands that need
		# to be inside the repo. The pulse-wrapper's cwd is typically / (launchd).
		_wt_output=$(cd "$repo_path" && "$_wt_helper" add "$worker_worktree_branch" 2>&1) || true
		worker_worktree_path=$(printf '%s' "$_wt_output" | grep -oE '/[^ ]*Git/[^ ]*' | head -1) || worker_worktree_path=""
		if [[ -n "$worker_worktree_path" && -d "$worker_worktree_path" ]]; then
			echo "[dispatch_with_dedup] Pre-created worktree for #${issue_number}: ${worker_worktree_path} (branch: ${worker_worktree_branch})" >>"$LOGFILE"
		else
			echo "[dispatch_with_dedup] Warning: worktree pre-creation failed for #${issue_number} — worker will create its own" >>"$LOGFILE"
			worker_worktree_path=""
			worker_worktree_branch=""
		fi
	fi

	# Use issue title as session title for searchable history (not generic "Issue #NNN").
	# Workers no longer need to call session-rename — the title is set at dispatch.
	local worker_title="${issue_title:-${dispatch_title}}"

	# Launch worker — headless-runtime-helper.sh handles model selection
	# when no --model is specified. Its choose_model() uses the routing
	# table/local override, then checks backoff/auth and rotates providers.
	local -a worker_cmd=(
		env
		HEADLESS=1
		FULL_LOOP_HEADLESS=true
		WORKER_ISSUE_NUMBER="$issue_number"
	)
	# Pass worktree env vars only if pre-creation succeeded
	if [[ -n "$worker_worktree_path" ]]; then
		worker_cmd+=(
			WORKER_WORKTREE_PATH="$worker_worktree_path"
			WORKER_WORKTREE_BRANCH="$worker_worktree_branch"
		)
	fi
	worker_cmd+=(
		"$HEADLESS_RUNTIME_HELPER" run
		--role worker
		--session-key "$session_key"
		--dir "${worker_worktree_path:-$repo_path}"
		--tier "$dispatch_model_tier"
		--title "$worker_title"
		--prompt "$prompt"
	)
	if [[ -n "$selected_model" ]]; then
		worker_cmd+=(--model "$selected_model")
	fi
	# GH#17549: Detach worker from the pulse-wrapper's SIGHUP.
	# launchd runs pulse-wrapper with StartInterval=120s. When the wrapper
	# exits after its dispatch cycle, bash sends SIGHUP to background jobs.
	# nohup makes the worker immune to SIGHUP so it survives the parent's
	# exit. The EXIT trap only releases the instance lock (no child killing).
	nohup "${worker_cmd[@]}" </dev/null >>"$worker_log" 2>&1 9>&- &
	local worker_pid="$!"

	# GH#17549: Stagger delay between worker launches to reduce SQLite
	# write contention on opencode.db (busy_timeout=0). Without this,
	# batches of 8+ workers all hit the DB simultaneously, causing
	# SQLITE_BUSY → silent mid-turn death. The stagger gives each worker
	# time to complete its initial DB writes before the next one starts.
	local stagger_delay="${PULSE_DISPATCH_STAGGER_SECONDS:-8}"
	sleep "$stagger_delay"

	# Record in dispatch ledger (with tier telemetry)
	local ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$ledger_helper" ]]; then
		"$ledger_helper" register --session-key "$session_key" \
			--issue "$issue_number" --repo "$repo_slug" \
			--pid "$worker_pid" --tier "$dispatch_tier" \
			--model "$selected_model" 2>/dev/null || true
	fi

	# GH#15317: Post deterministic "Dispatching worker" comment from the dispatcher,
	# not from the worker LLM session. Previously, the worker was responsible for
	# posting this comment — but workers could crash before posting, leaving no
	# persistent signal. Without this signal, Layer 5 (has_dispatch_comment) had
	# nothing to find, and the issue would be re-dispatched every pulse cycle.
	# Evidence: awardsapp #2051 accumulated 29 DISPATCH_CLAIM comments over 6 hours
	# because workers kept dying before posting.
	local dispatch_comment_body
	local display_model="${selected_model:-auto-select (round-robin)}"
	dispatch_comment_body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
Dispatching worker (deterministic).
- **Worker PID**: ${worker_pid}
- **Model**: ${display_model}
- **Tier**: ${dispatch_tier}
- **Runner**: ${self_login}
- **Issue**: #${issue_number}
<!-- ops:end -->"
	gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--method POST --field body="$dispatch_comment_body" \
		>/dev/null 2>>"$LOGFILE" || {
		echo "[dispatch_with_dedup] Warning: failed to post deterministic dispatch comment for #${issue_number}" >>"$LOGFILE"
	}

	# GH#17503: Claim comments are NEVER deleted — they form the persistent
	# audit trail and are respected as the primary dedup lock for 30 minutes.
	# The deferred deletion that previously ran here (GH#17497) was the root
	# cause of duplicate dispatches: deleting the claim removed the lock,
	# allowing subsequent pulse cycles and other runners to re-dispatch.
	# Evidence: GH#17503 — 6 dispatches from marcusquinn + 1 from alex-solovyev,
	# producing 2 duplicate PRs (#17512, #17513).
	if [[ -n "$_claim_comment_id" ]]; then
		echo "[dispatch_with_dedup] Claim comment ${_claim_comment_id} retained for audit trail on #${issue_number} (GH#17503)" >>"$LOGFILE"
		_claim_comment_id=""
	fi

	echo "[dispatch_with_dedup] Dispatched worker PID ${worker_pid} for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
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

	# All checks passed — launch the worker.
	_dispatch_launch_worker \
		"$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" \
		"$self_login" "$repo_path" "$prompt" "$session_key" \
		"$model_override" "$issue_meta_json"
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
