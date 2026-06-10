#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared Claim Lifecycle Helpers
# =============================================================================
# Interactive-claim lifecycle helpers shared across merge paths. Extracted from
# pulse-merge.sh (t2429, GH#20067) so that both pulse-merge.sh (deterministic
# merge pass) and full-loop-helper.sh (interactive merge) can release
# interactive claims atomically on PR merge.
#
# Public API:
#   - release_interactive_claim_on_merge <pr_number> <repo_slug> <linked_issue> [pr_labels]
#       Releases the interactive claim stamp + status:in-review label for the
#       linked issue if all guards pass. Best-effort; failures are logged but
#       never propagate.
#
# Guards (all must pass for release to fire):
#   1. linked_issue is non-empty after permissive fallback — no issue linked
#      → nothing to release. Callers pass the strict _extract_linked_issue
#      result (closing keywords only); when that is empty, a permissive
#      body scan for Ref/For planning-PR keywords fires before giving up.
#      (t2811)
#   2. PR carries origin:interactive label — worker PRs manage their own
#      lifecycle via worker-lifecycle-common.sh; do not interfere.
#   3. Claim stamp file exists for the issue — no active interactive session
#      was tracking it; release is a no-op and API calls are unnecessary.
#
# Release failure is logged but does NOT propagate — release is best-effort
# hygiene and must never block the merge completion path.
#
# Usage: source "${SCRIPT_DIR}/shared-claim-lifecycle.sh"
#
# Dependencies:
#   - shared-constants.sh / shared-gh-wrappers.sh (gh_pr_view, gh_pr_list,
#     gh_issue_view wrappers)
#   - interactive-session-helper.sh (for the actual release)
#   - LOGFILE env var (for logging; falls back to /dev/null)
#   - CLAIM_STAMP_DIR env var (optional; defaults to
#     ~/.aidevops/.agent-workspace/interactive-claims)
#   - AGENTS_DIR env var (optional; defaults to ~/.aidevops/agents)
#
# Cross-references: t2413 (original pulse-merge implementation),
#   t2429/GH#20067 (extraction + full-loop-helper parity),
#   t2811/GH#20757 (permissive Ref/For fallback for planning PRs),
#   AGENTS.md "Interactive issue ownership" → "PR merge auto-release".
# =============================================================================

# Include guard — prevent double-sourcing.
[[ -n "${_SHARED_CLAIM_LIFECYCLE_LOADED:-}" ]] && return 0
_SHARED_CLAIM_LIFECYCLE_LOADED=1

_scl_script_dir="${BASH_SOURCE[0]%/*}"
if ! declare -F aidevops_pulse_worker_log_candidates >/dev/null 2>&1 && [[ -r "${_scl_script_dir}/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "${_scl_script_dir}/shared-constants.sh"
fi
unset _scl_script_dir

#######################################
# Release the interactive claim for a linked issue after a PR merge.
#
# Called from pulse-merge.sh::_handle_post_merge_actions (deterministic merge)
# and full-loop-helper.sh::cmd_merge (interactive merge) after a successful
# gh pr merge. The function is intentionally best-effort: a failed release is
# logged but never blocks the merge completion path.
#
# Short-circuits (returns 0 silently) when ALL guards fail:
#   1. linked_issue is empty after permissive fallback — callers pass the
#      strict _extract_linked_issue result (closing keywords only). When that
#      is empty, a permissive body scan for Ref/For planning-PR keywords runs
#      before giving up. This fixes the claim-stamp leak on planning-only PRs
#      that MUST use "Ref #NNN" / "For #NNN" per the planning-PR keyword rule.
#      (t2811/GH#20757; false-positive risk is accepted per issue analysis;
#      Guards 2-4 further constrain scope to origin:interactive + stamp.)
#   2. PR does not carry origin:interactive label — worker PRs manage their
#      own lifecycle via worker-lifecycle-common.sh; do not interfere.
#   3. No claim stamp exists for the issue — no active interactive session
#      was tracking it; release is a no-op and API calls are unnecessary.
#
# Args: $1=pr_number, $2=repo_slug, $3=linked_issue, $4=pr_labels (optional)
#######################################
release_interactive_claim_on_merge() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local pr_labels="${4:-}"
	local _log="${LOGFILE:-/dev/null}"

	# Pre-Guard: if the caller already provided labels and the PR is NOT
	# origin:interactive, skip the expensive gh pr view body fetch — Guard 3
	# would return 0 at that point anyway. Only skip when labels are non-empty
	# so callers that omit the arg still fall through to the full path. (GH#20791)
	if [[ -n "$pr_labels" ]] && [[ ",${pr_labels}," != *",origin:interactive,"* ]]; then
		return 0
	fi

	# Guard 1: no linked issue from strict caller extraction → try permissive
	# fallback for planning-only PRs that use "Ref #NNN" / "For #NNN".
	# Strict _extract_linked_issue (callers) only matches closing keywords and
	# returns empty for planning PRs. The permissive scan here adds Ref/For so
	# both pulse-merge and full-loop call sites get the fix without duplication.
	# Guards 2-4 still constrain scope to origin:interactive + existing stamp.
	# (t2811/GH#20757; precedent: interactive-session-helper.sh:850-858)
	if [[ -z "$linked_issue" ]]; then
		local _pr_body
		_pr_body=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json body --jq '.body // empty' 2>/dev/null) || _pr_body=""
		linked_issue=$(printf '%s' "$_pr_body" \
			| grep -ioE '\b(close[ds]?|fix(es|ed)?|resolve[ds]?|ref(s|erences?)?|for)\b[[:space:]]+#[0-9]+' \
			| head -1 | grep -oE '[0-9]+')
	fi
	[[ -z "$linked_issue" ]] && return 0

	# Guard 2: fetch labels if not provided by caller
	if [[ -z "$pr_labels" ]]; then
		pr_labels=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || pr_labels=""
	fi

	# Guard 3: only fire for origin:interactive PRs — worker PRs handle their
	# own lifecycle, external contributor PRs have no interactive claim stamp
	[[ ",${pr_labels}," == *",origin:interactive,"* ]] || return 0

	# Guard 4: only fire when a claim stamp exists — avoids spurious
	# interactive-session-helper.sh invocations on every origin:interactive merge
	local _stamp_base="${CLAIM_STAMP_DIR:-${HOME}/.aidevops/.agent-workspace/interactive-claims}"
	local _stamp_file="${_stamp_base}/${repo_slug//\//-}-${linked_issue}.json"
	[[ -f "$_stamp_file" ]] || return 0

	echo "[claim-lifecycle] Auto-releasing interactive claim on ${repo_slug}#${linked_issue} (PR #${pr_number} merged) — t2413/t2429" >>"$_log"
	local _isc_helper="${AGENTS_DIR:-${HOME}/.aidevops/agents}/scripts/interactive-session-helper.sh"
	if [[ -x "$_isc_helper" ]]; then
		"$_isc_helper" release "$linked_issue" "$repo_slug" >>"$_log" 2>&1 || \
			echo "[claim-lifecycle] Interactive claim release failed for ${repo_slug}#${linked_issue} — non-fatal (t2413/t2429)" >>"$_log"
	else
		echo "[claim-lifecycle] interactive-session-helper.sh not found/not executable at ${_isc_helper} — skipping release for ${repo_slug}#${linked_issue} (t2413/t2429)" >>"$_log"
	fi
	return 0
}

# Backward-compatible alias: pulse-merge.sh used the underscore-prefixed name.
# Callers may use either form; the underscore-prefixed name is kept so existing
# code (and tests that inline the function) continue to work without changes.
_release_interactive_claim_on_merge() {
	release_interactive_claim_on_merge "$@"
}

#######################################
# _pr_exists_for_branch_or_issue — Probe for an existing PR (t3195 / GH#21889)
#
# Determines whether a PR exists for a given head branch and/or linked issue.
# Uses `gh_pr_list --head <branch> --state all` as the PRIMARY signal because
# the GitHub Search index lags real-time PR creation by 5-30 minutes; the
# pulls API (which `--head` queries) hits live state. Falls back to
# `--search <issue_number>` only when branch_name is empty (no head to query)
# OR when the head probe returns zero — search remains useful for cases
# where the worker pushed a different branch than its detected feature branch.
#
# Canonical incident (t3195): a worker opened PR #21885 at 05:47:48Z;
# `_worker_produced_output` ran at 05:52:38Z (5 min later); `gh pr list
# --search 21870` returned 0 because of search-index lag; the worker was
# misclassified as `worker_branch_orphan` and `_attempt_orphan_recovery_pr`
# fired uselessly (PR already existed for the same `--head`). A `--head`
# probe at 05:52:38Z would have returned 1 immediately.
#
# Args:
#   $1 = branch_name   (may be empty)
#   $2 = issue_number  (may be empty)
#   $3 = repo_slug     (e.g. "owner/repo")
#
# Echoes one of:
#   "found"   — at least one PR exists for the head branch (or issue match)
#   "absent"  — definitive zero matches (caller may classify as branch_orphan)
#   "unknown" — cannot evaluate (no inputs / repo_slug missing) — fail-open
#
# Always returns 0. gh CLI failures on either probe are silently treated as
# zero matches for that probe — the helper continues to the fallback or
# returns "absent" (callers fail-open via "unknown" only when no probe ran).
#######################################
_pr_exists_for_branch_or_issue() {
	local branch_name="$1"
	local issue_number="$2"
	local repo_slug="$3"

	if [[ -z "$repo_slug" ]]; then
		printf 'unknown'
		return 0
	fi

	# Primary: --head match (no search-index lag, hits pulls API directly).
	if [[ -n "$branch_name" ]]; then
		local pr_count_head=0
		pr_count_head=$(gh_pr_list --repo "$repo_slug" --head "$branch_name" \
			--state all --json number --jq 'length' 2>/dev/null || true)
		[[ "$pr_count_head" =~ ^[0-9]+$ ]] || pr_count_head=0
		if [[ "$pr_count_head" -gt 0 ]]; then
			printf 'found'
			return 0
		fi
	fi

	# Fallback: --search by issue_number when --head missed (or branch unknown).
	# Search-index lag is acceptable here because the primary --head probe
	# already returned zero — this is the second-chance covering cases where
	# the actual pushed branch differs from the detected branch_name.
	if [[ -n "$issue_number" ]]; then
		local pr_count_search=0
		pr_count_search=$(gh_pr_list --repo "$repo_slug" --search "$issue_number" \
			--json number --jq 'length' 2>/dev/null || true)
		[[ "$pr_count_search" =~ ^[0-9]+$ ]] || pr_count_search=0
		if [[ "$pr_count_search" -gt 0 ]]; then
			printf 'found'
			return 0
		fi
	fi

	# Both probes returned zero (or only one ran and returned zero) — definitive
	# absence. Distinct from "unknown" because we DID actually query.
	if [[ -n "$branch_name" || -n "$issue_number" ]]; then
		printf 'absent'
		return 0
	fi

	# No usable inputs — fail-open with "unknown".
	printf 'unknown'
	return 0
}

#######################################
# _attempt_orphan_recovery_pr — auto-recover a worker_branch_orphan (GH#20819)
#
# Called when a worker pushed a branch but exited without opening a PR.
# Attempts to open a non-draft PR against the repo's default branch with
# origin:worker-takeover label so the normal review/merge pipeline applies.
#
# Short-circuits (returns 1) when:
#   - repo_slug is empty (cannot query or construct PR)
#   - branch_name is empty after the existing-PR probe (cannot construct PR)
#   - linked issue is CLOSED (branch is genuinely orphaned, no PR needed)
#   - gh pr create fails for any reason
#
# Pre-check (t3195/GH#21889): if a PR already exists for the branch or issue
# (`--head`/`--search` probes via _pr_exists_for_branch_or_issue), returns 0
# with no `gh pr create` attempt. This catches search-index-lag and cleaned-
# worktree misclassifications so the recovery helper does not uselessly try to
# create a duplicate PR or release the claim as worker_branch_orphan.
#
# On success: returns 0 (caller releases as worker_complete)
# On failure: returns 1 (caller releases as worker_branch_orphan)
#
# Args:
#   $1 = session_key  (e.g. "issue-12345")
#   $2 = work_dir     (path to git worktree; unused after branch_name extracted)
#   $3 = branch_name  (feature branch to set as PR head)
#   $4 = repo_slug    (owner/repo)
#
# Non-fatal guard: issues in CLOSED state skip recovery rather than
# creating a PR nobody will review (edge case: worker closed issue as
# "premise falsified" per worker-triage rules — GH#20819 §Context).
#######################################
_attempt_orphan_recovery_pr() {
	local session_key="$1"
	local work_dir="$2"
	local branch_name="$3"
	local repo_slug="$4"

	# Cannot query or build a PR without repo context.
	if [[ -z "$repo_slug" ]]; then
		return 1
	fi

	# Derive issue number before branch guards so the existing-PR probe can
	# fall back to issue search when a cleaned worktree leaves branch_name empty.
	local issue_number=""
	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)

	# Pre-check (t3195/GH#21889): if a PR already exists for this branch
	# (or issue), no recovery is needed. Caller releases as worker_complete.
	# Intentionally re-checks rather than trusting the caller's classification:
	# (1) race-condition guard — a PR could be opened in the window between
	#     _worker_produced_output running and this function running; (2) self-
	#     containedness — makes this function correct for any future call path,
	#     not only the current _cmd_run_finish → _handle_worker_branch_orphan
	#     path. Note: after PR #21902 fixed signal-3 to use --head primary, the
	#     original search-index-lag motivation no longer applies; race-condition
	#     defense is now the primary justification for this check.
	local pr_existence=""
	pr_existence=$(_pr_exists_for_branch_or_issue "$branch_name" "$issue_number" "$repo_slug")
	if [[ "$pr_existence" == "found" ]]; then
		return 0
	fi

	# Past this point recovery needs a branch to create a PR. Existing PRs were
	# already handled above, including the empty-branch issue-search fallback.
	if [[ -z "$branch_name" ]]; then
		return 1
	fi

	# Guard: skip recovery for closed issues — worker may have closed it as
	# "premise falsified" (GH#20819 §Context edge case).
	if [[ -n "$issue_number" ]]; then
		local issue_state=""
		issue_state=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
			--json state --jq '.state' 2>/dev/null || true)
		if [[ "$issue_state" == "CLOSED" ]]; then
			return 1
		fi
	fi

	# Detect repo default branch (fallback: main)
	local default_branch="main"
	local detected_default=""
	detected_default=$(gh repo view "$repo_slug" \
		--json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)
	[[ -n "$detected_default" ]] && default_branch="$detected_default"

	# Build PR metadata
	local pr_title="auto-recover: orphaned worker branch"
	local closing_line=""
	if [[ -n "$issue_number" ]]; then
		pr_title="auto-recover: orphaned worker branch for #${issue_number}"
		closing_line="Resolves #${issue_number}"
	fi

	local pr_body
	pr_body=$(printf '%s\n\n%s\n\n%s\n\n%s' \
		"Orphan recovery PR — worker pushed this branch but exited before opening a PR." \
		"Branch \`${branch_name}\` was pushed by headless worker session \`${session_key}\` which released as \`worker_branch_orphan\`. This PR was auto-created by the orphan-recovery path (GH#20819) so the change can land via the normal review and merge pipeline." \
		"$closing_line" \
		"<!-- aidevops:orphan-recovery worker_branch_orphan session=${session_key} -->")

	# Attempt PR creation — non-draft so auto-merge and review gates apply.
	# Raw gh pr create (not gh_create_pr wrapper) is intentional: gh_create_pr
	# auto-applies origin:worker which conflicts with origin:worker-takeover
	# (mutually exclusive labels). See GH#20819 for rationale.
	#
	# Args built as an array so the gh-wrapper-guard allowlist marker can stay
	# on the same line as `gh pr create` (its line-by-line scanner requires
	# co-location) without needing a line continuation. Previous form used
	# `gh pr create \ # marker` followed by indented args — but `\<space>#` is
	# NOT a line continuation in bash (`\` escapes the space, `#` starts a
	# comment, the line terminates), so the args were silently dropped and
	# this entire orphan-recovery path never produced a PR. SC2215 caught it.
	local create_args=(
		--repo "$repo_slug"
		--head "$branch_name"
		--base "$default_branch"
		--title "$pr_title"
		--body "$pr_body"
		--label "origin:worker-takeover"
	)
	gh pr create "${create_args[@]}" >/dev/null 2>&1 # aidevops-allow: raw-gh-wrapper
	return $?
}

#######################################
# _read_worker_log_tail_classified — locate worker log + classify the tail (t2820)
#
# Shared helper extracted from `_post_launch_recovery_claim_released` (Phase 3,
# t2814) so that two consumers can share parsing logic:
#   1. pulse-cleanup.sh — embeds the tail in CLAIM_RELEASED comments.
#   2. worker-lifecycle-common.sh::escalate_issue_tier — uses the classification
#      to reclassify `worker_failed` events as `no_work` when the log shows the
#      worker never produced tool calls (Phase 5 / t2820).
#
# Locates the worker log by enumerating the same per-user candidate paths
# `_post_launch_recovery_claim_released` uses via shared pulse temp helpers.
#
# Reads the last 20 lines (capped at 4KB to match Phase 3's bounds — keeps
# comments readable and limits credential-leak surface). Classifies the tail
# into one of four shapes:
#
#   real_coding          — tail contains tool-use / edit / commit markers
#                          → worker reached implementation; escalate normally
#   no_tool_calls        — tail is non-empty but lacks any tool-use markers
#                          → worker spawned but stalled before implementation
#   canary_post_spawn    — tail contains canary diagnostics or t2814 early-exit
#                          marker → infra failure post-spawn, opus cannot help
#   unknown              — log file missing or empty → no signal available
#
# Side-effects (on success):
#   sets the following variables in the *caller's* scope (no subshell):
#     _WORKER_LOG_TAIL_FILE         path to the log file that was read
#     _WORKER_LOG_TAIL_CONTENT      log tail content (may be empty)
#     _WORKER_LOG_TAIL_CLASS        one of: real_coding|no_tool_calls|
#                                            canary_post_spawn|unknown
#     _WORKER_LOG_TAIL_AGE_SECS     log file age in seconds (now - mtime), or
#                                   empty when no log file exists
#
# Why caller-scope vars: callers need both the raw content (for embedding in
# comments) AND the classification (for branching). Returning a single string
# would force one or the other; setting two named vars is the cheapest way to
# share both without subshell overhead. Tests can `unset` the vars between runs.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo) — used to derive safe_slug for the log path
#
# Returns: 0 always (best-effort; missing log → unknown classification)
#######################################
_read_worker_log_tail_classified() {
	local issue_number="$1"
	local repo_slug="$2"

	# Reset caller-scope vars on every call.
	_WORKER_LOG_TAIL_FILE=""
	_WORKER_LOG_TAIL_CONTENT=""
	_WORKER_LOG_TAIL_CLASS="unknown"
	_WORKER_LOG_TAIL_AGE_SECS=""

	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 0

	local -a log_candidates=()
	local _candidate=""
	while IFS= read -r _candidate; do
		[[ -n "$_candidate" ]] && log_candidates+=("$_candidate")
	done < <(aidevops_pulse_worker_log_candidates "$repo_slug" "$issue_number" 2>/dev/null || true)

	local log_file=""
	for log_file in "${log_candidates[@]}"; do
		if [[ -f "$log_file" ]] && [[ -s "$log_file" ]]; then
			_WORKER_LOG_TAIL_FILE="$log_file"
			# Bounded read: last 20 lines, capped at 4KB. Same bounds as
			# Phase 3 to keep comments readable + limit credential-leak.
			_WORKER_LOG_TAIL_CONTENT=$(tail -20 "$log_file" 2>/dev/null \
				| head -c 4096 || true)
			# File age = now - mtime. Approximates worker runtime well
			# enough for the reclassification threshold check (the log is
			# created at spawn and written-to throughout execution).
			local now mtime
			now=$(date +%s 2>/dev/null) || now=""
			mtime=$(_file_mtime_epoch "$log_file")
			if [[ -n "$now" && -n "$mtime" && "$mtime" =~ ^[0-9]+$ ]]; then
				_WORKER_LOG_TAIL_AGE_SECS=$((now - mtime))
				# Defensive: clamp negatives to 0 (clock skew / FS race)
				[[ "$_WORKER_LOG_TAIL_AGE_SECS" -lt 0 ]] && _WORKER_LOG_TAIL_AGE_SECS=0
			fi
			break
		fi
	done

	# No log found → unknown (caller should fall through to default behaviour).
	if [[ -z "$_WORKER_LOG_TAIL_FILE" ]]; then
		return 0
	fi

	# Empty content (rare: file existed at -s check but emptied between calls)
	if [[ -z "$_WORKER_LOG_TAIL_CONTENT" ]]; then
		return 0
	fi

	# Classification — order matters: canary signals are most specific, check
	# them first. Tool-call markers next (positive signal of real work). The
	# absence-of-tool-calls case is the catch-all when the log has *something*
	# but no implementation evidence.
	#
	# Markers chosen for stability (not session-format details):
	#   - `[t2814:early_exit]` — explicit marker emitted by Phase 3 Fix 2
	#   - `canary` (case-insensitive) — appears in canary diagnostic output
	#   - `tool_use|tool-use|"tool":` — OpenCode tool-call frames in JSON
	#   - `edit|Edit|Write|Bash` — tool names that imply real implementation
	#   - `git commit|git push` — strongest evidence of implementation
	if printf '%s' "$_WORKER_LOG_TAIL_CONTENT" \
		| grep -qE '\[t2814:early_exit\]|[Cc]anary'; then
		_WORKER_LOG_TAIL_CLASS="canary_post_spawn"
	elif printf '%s' "$_WORKER_LOG_TAIL_CONTENT" \
		| grep -qE 'tool_use|tool-use|"tool":|"name":\s*"(Edit|Write|Bash|Read)"|git\s+(commit|push)'; then
		_WORKER_LOG_TAIL_CLASS="real_coding"
	else
		# Log has content but no implementation markers → worker stalled
		# before reaching tool-call execution.
		_WORKER_LOG_TAIL_CLASS="no_tool_calls"
	fi

	return 0
}
