#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-conflict.sh — Conflict handling + interactive PR handover + carry-forward diff for the deterministic merge pass.
#
# Extracted from pulse-merge.sh (GH#19836) to bring that file below the
# 2000-line simplification gate.
#
# This module contains the "downstream of merge" cluster — all functions
# that are called AFTER _check_pr_merge_gates detects a conflicting PR
# or when an idle origin:interactive PR needs handover. None of these
# functions call back into the merge core or pr-gates clusters, so the
# split is safe: bash's lazy function name resolution sees each module's
# symbols at call time, regardless of source order.
#
# This module is sourced by pulse-wrapper.sh AFTER pulse-merge.sh. It
# MUST NOT be executed directly — it relies on the orchestrator having
# sourced shared-constants.sh, worker-lifecycle-common.sh, and the merge
# core before any function is invoked.
#
# Functions in this module (in source order):
#   - _post_rebase_nudge_on_interactive_conflicting   (GH#18650 Fix 4)
#   - _interactive_pr_is_stale                        (t2189)
#   - _interactive_pr_trigger_handover                (t2189)
#   - _is_planning_path_for_overlap                   (GH#18815)
#   - _verify_pr_overlaps_commit                      (GH#18815)
#   - _post_rebase_nudge_on_worker_conflicting        (GH#18815)
#   - _close_conflicting_pr                           (GH#17574 + GH#18815)
#   - _carry_forward_pr_diff                          (t2118)
#
# All functions fail-open: missing helpers, API errors, or malformed
# state never block the merge pass — they log and return 0.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_MERGE_CONFLICT_LOADED:-}" ]] && return 0
_PULSE_MERGE_CONFLICT_LOADED=1

#######################################
# GH#18650 (Fix 4): Post a one-time rebase nudge on an origin:interactive
# CONFLICTING PR that the pulse is about to skip.
#
# Rationale: the merge pass correctly refuses to auto-close origin:interactive
# PRs (GH#18285 — maintainer session work is theirs to own), but without any
# counterforce the CONFLICTING state persists and the PR rots silently. The
# maintainer sees nothing in their inbox and only discovers the stuck PR
# when they manually check `gh pr list`. This nudge surfaces the stuck state
# on the PR itself, where GitHub's notification system will ping the author.
#
# Idempotent via _gh_idempotent_comment marker — posted once per PR lifetime.
# If the PR is updated and still conflicts, the nudge does NOT repeat. Workers
# and humans who care about the PR will see it in the timeline.
#
# Fail-open: missing helpers or API errors never block the merge pass. The
# nudge is best-effort operational plumbing.
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug (owner/repo)
#######################################
_post_rebase_nudge_on_interactive_conflicting() {
	local pr_number="$1"
	local repo_slug="$2"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 0

	# _gh_idempotent_comment is defined in pulse-triage.sh which is sourced
	# after pulse-merge.sh; bash resolves function names at call time so
	# this works at runtime. Skip if for some reason the helper is absent
	# (e.g., out-of-order standalone execution).
	if ! declare -F _gh_idempotent_comment >/dev/null 2>&1; then
		echo "[pulse-wrapper] _post_rebase_nudge_on_interactive_conflicting: _gh_idempotent_comment not defined — skipping nudge for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		return 0
	fi

	local head_branch
	head_branch=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json headRefName --jq '.headRefName' 2>/dev/null) || head_branch="<branch>"
	[[ -n "$head_branch" ]] || head_branch="<branch>"

	local marker="<!-- pulse-rebase-nudge -->"
	local nudge_body
	nudge_body="${marker}
## Rebase needed — branch has diverged from \`main\`

This \`origin:interactive\` PR has merge conflicts against \`main\`. The pulse merge pass skips auto-close on maintainer session work (GH#18285), but there is no automated path to resolve conflicts on behalf of a human author — this PR needs your attention.

### To resolve

From a terminal (not a chat session):

\`\`\`bash
wt switch ${head_branch}
git pull --rebase origin main
# resolve any conflicts, then:
git push --force-with-lease
\`\`\`

Or use the GitHub web UI's *Update branch* button if the conflicts are trivial enough for GitHub's web merger.

### Why you're seeing this

Every pulse cycle the deterministic merge pass evaluates open PRs and auto-closes \`CONFLICTING\` ones that have no clear owner. \`origin:interactive\` PRs are explicitly protected from that path, which is correct for active maintainer work but left them to rot silently in the queue. This nudge is posted exactly once per PR so the stuck state surfaces in your inbox. If the PR still conflicts after you think you've rebased, the nudge will NOT repeat — re-check manually via \`gh pr view ${pr_number}\`.

<sub>Posted automatically by \`pulse-merge-conflict.sh\` (GH#18650 / Fix 4 of the 2026-04-13 dispatch-unblocker pass).</sub>"

	_gh_idempotent_comment "$pr_number" "$repo_slug" "$marker" "$nudge_body" "pr" || true
	return 0
}

#######################################
# t2189: Detect whether an origin:interactive PR is idle enough to hand
# over to the worker pipeline.
#
# The existing rebase-nudge (_post_rebase_nudge_on_interactive_conflicting)
# covers CONFLICTING state passively — it comments once and leaves the PR
# untouched. Interactive PRs with failing required checks (like a complexity
# regression) have no automated rescue path because the three routing gates
# at pulse-merge.sh:840, :1121, :1154 all require `origin:worker`.
#
# This helper is the staleness detector. When it returns 0, the caller
# triggers handover (add `origin:worker-takeover` label + explanation
# comment) and then routes through the existing worker-PR pipelines.
#
# Combined signal — ALL must hold for a stale handover-eligible PR:
#   1. PR has origin:interactive label
#   2. Linked issue has NO active status label (status:queued, in-progress,
#      in-review, claimed) — an active status means a human is driving it
#   3. No live claim stamp file in $CLAIM_STAMP_DIR for the linked issue
#      (session is gone; no interactive-session-helper.sh claim active)
#   4. PR updatedAt older than AIDEVOPS_INTERACTIVE_PR_HANDOVER_HOURS (24h)
#   5. Linked issue is open (don't touch PRs whose issue was already closed)
#
# Env controls:
#   AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE — off | detect | enforce (default: detect)
#     off:     returns 1 unconditionally (feature disabled)
#     detect:  evaluates signal and logs would-handover decisions; still returns signal
#     enforce: evaluates signal and returns it; caller acts
#   AIDEVOPS_INTERACTIVE_PR_HANDOVER_HOURS — age threshold hours, default 24
#
# Args: $1 = pr_number, $2 = repo_slug
# Returns: 0 if stale (handover-eligible), 1 otherwise
# Side effect: logs "would-handover" line to $LOGFILE when mode=detect and stale
#######################################
_interactive_pr_is_stale() {
	local pr_number="$1"
	local repo_slug="$2"
	local mode="${AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE:-detect}"
	[[ "$mode" == "off" ]] && return 1
	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 1

	# Fetch PR metadata once
	local pr_meta
	pr_meta=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json labels,updatedAt 2>/dev/null) || return 1

	# Gate 1: must have origin:interactive
	printf '%s' "$pr_meta" | jq -e \
		'.labels | map(.name) | index("origin:interactive")' \
		>/dev/null 2>&1 || return 1

	# Gate 4: age threshold (check before any other gh calls — cheapest filter)
	local threshold_hours updated_at now_epoch updated_epoch pr_age_hours
	threshold_hours="${AIDEVOPS_INTERACTIVE_PR_HANDOVER_HOURS:-24}"
	# t2383 Fix 2: validate threshold is a positive integer before arithmetic.
	# A non-numeric value (e.g. "24h", empty, negative) triggers bash
	# "value too great for base" and silently breaks stale detection.
	if [[ ! "$threshold_hours" =~ ^[0-9]+$ ]] || [[ "$threshold_hours" -eq 0 ]]; then
		echo "[pulse-wrapper] _interactive_pr_is_stale: invalid AIDEVOPS_INTERACTIVE_PR_HANDOVER_HOURS='${threshold_hours}' — must be a positive integer, returning not-stale (t2383)" >>"$LOGFILE"
		return 1
	fi
	updated_at=$(printf '%s' "$pr_meta" | jq -r '.updatedAt // empty')
	[[ -z "$updated_at" ]] && return 1
	now_epoch=$(date +%s)
	# Portable epoch parse — GNU date first (Linux CI), BSD date fallback (macOS)
	updated_epoch=$(date -d "$updated_at" +%s 2>/dev/null) || \
		updated_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" +%s 2>/dev/null) || \
		return 1
	pr_age_hours=$(( (now_epoch - updated_epoch) / 3600 ))
	[[ "$pr_age_hours" -lt "$threshold_hours" ]] && return 1

	# Gate 2 + 5: resolve linked issue, verify open, check status labels
	local linked_issue
	linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug")
	[[ -z "$linked_issue" ]] && return 1
	local issue_meta
	issue_meta=$(gh api "repos/${repo_slug}/issues/${linked_issue}" \
		--jq '{state, labels: [.labels[].name]}' 2>/dev/null) || return 1
	printf '%s' "$issue_meta" | jq -e '.state == "open"' >/dev/null 2>&1 || return 1
	printf '%s' "$issue_meta" | jq -e \
		'.labels | any(. == "status:queued" or . == "status:in-progress" or . == "status:in-review" or . == "status:claimed")' \
		>/dev/null 2>&1 && return 1

	# Gate 3: no live claim stamp (session gone)
	# Stamp path: $CLAIM_STAMP_DIR/${flattened_slug}-${issue}.json
	# See interactive-session-helper.sh:91 for the canonical pattern.
	local slug_flat stamp_path
	slug_flat="${repo_slug//\//-}"
	stamp_path="${CLAIM_STAMP_DIR:-$HOME/.aidevops/.agent-workspace/interactive-claims}/${slug_flat}-${linked_issue}.json"
	[[ -f "$stamp_path" ]] && return 1

	# All gates passed — PR is stale. Log in detect mode.
	if [[ "$mode" == "detect" ]]; then
		echo "[pulse-wrapper] would-handover: PR #${pr_number} in ${repo_slug} (idle ${pr_age_hours}h >= ${threshold_hours}h, linked issue #${linked_issue})" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# t2189: Trigger handover of an idle interactive PR to the worker pipeline.
#
# Idempotent — applies the `origin:worker-takeover` label and posts ONE
# marker-guarded comment. Second call short-circuits on the existing label.
# The `origin:interactive` label is NOT removed (origin history is append-only;
# worker-takeover is an additive routing signal).
#
# Mode gating:
#   off | detect: no-op (caller is expected to guard too, but belt+braces)
#   enforce:      apply label + post comment
#
# Fail-open: all gh failures are logged, never propagate. A failed label
# application just means the routing gate won't pick up this PR — next
# pulse cycle retries.
#
# Args: $1 = pr_number, $2 = repo_slug
# Returns: 0 always
#######################################
_interactive_pr_trigger_handover() {
	local pr_number="$1"
	local repo_slug="$2"
	local mode="${AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE:-detect}"
	[[ "$mode" != "enforce" ]] && return 0
	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 0

	# Idempotence short-circuit: label already present → nothing to do
	local pr_labels_json
	pr_labels_json=$(gh pr view "$pr_number" --repo "$repo_slug" --json labels \
		--jq '[.labels[].name]' 2>/dev/null) || pr_labels_json="[]"
	[[ -n "$pr_labels_json" ]] || pr_labels_json="[]"

	if printf '%s' "$pr_labels_json" | jq -e 'index("origin:worker-takeover")' >/dev/null 2>&1; then
		return 0
	fi

	# t2383 Fix 1: honour no-takeover opt-out label before applying handover.
	# The handover comment promises "Add the no-takeover label to this PR at
	# any time. The routing gates will skip it." — enforce that promise here.
	if printf '%s' "$pr_labels_json" | jq -e 'index("no-takeover")' >/dev/null 2>&1; then
		echo "[pulse-wrapper] _interactive_pr_trigger_handover: PR #${pr_number} in ${repo_slug} has no-takeover label — skipping handover (t2383)" >>"$LOGFILE"
		return 0
	fi

	# Apply label (fail-open — log if it fails)
	if ! gh issue edit "$pr_number" --repo "$repo_slug" \
		--add-label "origin:worker-takeover" >/dev/null 2>&1; then
		echo "[pulse-wrapper] _interactive_pr_trigger_handover: failed to add origin:worker-takeover on PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
	fi

	# Post one-time handover comment via _gh_idempotent_comment
	if declare -F _gh_idempotent_comment >/dev/null 2>&1; then
		local marker="<!-- pulse-interactive-handover -->"
		local threshold="${AIDEVOPS_INTERACTIVE_PR_HANDOVER_HOURS:-24}"
		local body
		body="${marker}
## Worker takeover — no interactive session activity for ${threshold}h

This \`origin:interactive\` PR has been idle past the handover threshold. The pulse is now routing it through the worker pipeline to drive it to merge:

- CI failures → routed to linked issue for worker re-dispatch
- Merge conflicts → routed to linked issue for worker re-dispatch
- Review feedback → routed to linked issue for worker re-dispatch
- Once all required checks pass: auto-approved + admin-merged (collaborator author only)

### Reclaiming interactively

If you return and want to drive this PR yourself, run in a terminal (not a chat session):

\`\`\`bash
gh issue edit ${pr_number} --repo ${repo_slug} --remove-label origin:worker-takeover
interactive-session-helper.sh claim <linked-issue-number> ${repo_slug}
\`\`\`

Any worker mid-flight will self-terminate on the next pulse cycle (combined assignee + status signal via \`dispatch-dedup-helper.sh\`).

### Opting out permanently

Add the \`no-takeover\` label to this PR at any time. The routing gates will skip it.

<sub>Posted once per PR by \`pulse-merge-conflict.sh\` (t2189).</sub>"
		_gh_idempotent_comment "$pr_number" "$repo_slug" "$marker" "$body" "pr" || true
	fi

	echo "[pulse-wrapper] handover: PR #${pr_number} in ${repo_slug} handed over to worker pipeline (t2189)" >>"$LOGFILE"
	return 0
}

#######################################
# Detect whether a path is a planning-only file that should NOT be used
# as evidence of "implementation work landed on main".
#
# GH#18815: The deterministic merge pass had a false-positive in PR #18760
# where a planning-brief PR (`plan(t2059, t2060): file follow-ups`) was
# mistaken for an implementation PR because the task-ID grep matched the
# planning commit's subject. Planning paths are excluded from the file
# overlap check so a planning-only commit cannot satisfy the duplicate-work
# heuristic on its own.
#
# Returns 0 (true) if the path is planning-only, 1 (false) if it is an
# implementation file.
#
# Args: $1 = path
#######################################
_is_planning_path_for_overlap() {
	local path="$1"
	case "$path" in
	TODO.md | README.md | CHANGELOG.md | VERSION) return 0 ;;
	todo/* | .agents/configs/simplification-state.json) return 0 ;;
	*) return 1 ;;
	esac
}

#######################################
# Verify that the closing PR and the matching commit on main share at
# least one non-planning file path.
#
# GH#18815: This is the file-overlap gate that distinguishes a genuine
# duplicate (where the same implementation files were touched on both
# sides) from a false positive (where the task ID appeared in a planning
# commit's subject but no implementation work landed).
#
# Returns 0 if the intersection contains at least one implementation file
# → genuine duplicate, safe to close as "already landed".
#
# Returns 1 if:
#   - The intersection is empty (planning-only match → false positive)
#   - File lookup failed (network error, missing API permissions, etc.)
#
# In all "return 1" cases the caller MUST NOT auto-close the PR. The
# function fails CLOSED on lookup errors because the cost of leaving a
# stuck PR open is far less than the cost of discarding real work.
#
# Args: $1 = closing PR number, $2 = repo slug, $3 = matching commit SHA
#######################################
_verify_pr_overlaps_commit() {
	local pr_number="$1"
	local repo_slug="$2"
	local commit_sha="$3"

	local pr_files commit_files
	pr_files=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json files --jq '.files[].path' 2>/dev/null) || return 1
	[[ -n "$pr_files" ]] || return 1

	commit_files=$(gh api "repos/${repo_slug}/commits/${commit_sha}" \
		--jq '.files[].filename' 2>/dev/null) || return 1
	[[ -n "$commit_files" ]] || return 1

	# Compute intersection, excluding planning paths. Iterate the closing
	# PR's files (typically smaller set) and check membership in the
	# matching commit's files via grep -Fxq for exact line match.
	local file
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		if _is_planning_path_for_overlap "$file"; then
			continue
		fi
		if printf '%s\n' "$commit_files" | grep -Fxq -- "$file"; then
			return 0
		fi
	done <<<"$pr_files"

	return 1
}

#######################################
# Post a one-time rebase nudge on a conflicting worker PR that the
# deterministic merge pass left open due to a false-positive task-ID
# match (GH#18815).
#
# Modelled on _post_rebase_nudge_on_interactive_conflicting. Idempotent
# via the marker `<!-- pulse-rebase-nudge-worker -->` — posted exactly
# once per PR lifetime.
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug (owner/repo)
#   $3 - task_id (e.g., "t2060" or "GH#18746")
#   $4 - matching_pr (optional — the PR number from the false-positive match)
#######################################
_post_rebase_nudge_on_worker_conflicting() {
	local pr_number="$1"
	local repo_slug="$2"
	local task_id="$3"
	local matching_pr="${4:-}"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 0

	if ! declare -F _gh_idempotent_comment >/dev/null 2>&1; then
		echo "[pulse-wrapper] _post_rebase_nudge_on_worker_conflicting: _gh_idempotent_comment not defined — skipping nudge for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		return 0
	fi

	local head_branch
	head_branch=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json headRefName --jq '.headRefName' 2>/dev/null) || head_branch="<branch>"
	[[ -n "$head_branch" ]] || head_branch="<branch>"

	local matching_pr_clause=""
	if [[ -n "$matching_pr" ]]; then
		matching_pr_clause=" The matching commit was from PR #${matching_pr}, which only touches planning files (briefs, TODO.md). The implementation in this PR has not landed."
	fi

	local marker="<!-- pulse-rebase-nudge-worker -->"
	local nudge_body
	nudge_body="${marker}
## Rebase needed — task-ID heuristic detected a planning-only match

This worker PR has merge conflicts against \`main\`. The deterministic merge pass found a recent commit on main mentioning task ID \`${task_id}\`, but its file footprint does not overlap with this PR's implementation files.${matching_pr_clause}

To prevent value loss, the merge pass left this PR open instead of auto-closing it. The implementation work in this branch needs to be rebased and re-validated.

### To resolve

From a terminal:

\`\`\`bash
gh pr checkout ${pr_number}
git pull --rebase origin main
# resolve any conflicts, then:
git push --force-with-lease
\`\`\`

Or use the GitHub web UI's *Update branch* button if the conflicts are trivial enough for GitHub's web merger.

### Why you're seeing this

Earlier versions of \`_close_conflicting_pr\` would have auto-closed this PR with a false 'already landed on main' claim — the task-ID grep alone matched the planning commit's subject and concluded the implementation had landed. The fix added file-overlap verification: when the task ID matches a commit but the file footprints do not intersect on any non-planning path, the heuristic is treated as a false positive and the PR is preserved.

<sub>Posted automatically by \`pulse-merge-conflict.sh\` (GH#18815).</sub>"

	_gh_idempotent_comment "$pr_number" "$repo_slug" "$marker" "$nudge_body" "pr" || true
	return 0
}

#######################################
# Close a conflicting PR with audit comment.
#
# GH#17574: Before saying "remains open for re-attempt", check if the
# work has already landed on main (via the linked issue's task ID in
# recent commits). If yes, close the linked issue too and say so —
# the misleading "remains open for re-attempt" comment was itself a
# dispatch trigger that caused a third redundant worker in the
# observed incident.
#
# GH#18815: The task-ID grep alone produced a false positive in PR
# #18760, where a planning PR (`plan(t2059, t2060): file follow-ups`)
# was mistaken for an implementation PR. The fix requires file overlap
# between the closing PR and the matching commit before claiming the
# work landed. On overlap miss or lookup failure, the PR is left open
# and a one-time rebase nudge is posted.
#
# Args: $1=PR number, $2=repo slug, $3=PR title
#######################################
_close_conflicting_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_title="$3"

	# GH#18285 post-mortem: origin:interactive PRs are created during maintainer
	# sessions. The task-ID-on-main heuristic produces false positives when
	# multiple PRs share a task ID (incremental work on the same issue).
	# Maintainers decide what is redundant — the pulse must not auto-close their work.
	#
	# t2383 Fix 3: fail CLOSED on label read failure — if we can't read labels,
	# we might be about to close a protected origin:interactive PR. Also use
	# grep -Fxq (exact line match) not grep -q (substring) so labels like
	# "origin:interactive-fork" don't false-match "origin:interactive".
	local pr_labels label_fetch_rc
	label_fetch_rc=0
	pr_labels=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json labels --jq '.labels[].name' 2>/dev/null) || label_fetch_rc=$?
	if [[ $label_fetch_rc -ne 0 ]]; then
		echo "[pulse-wrapper] _close_conflicting_pr: failed to fetch labels for PR #${pr_number} in ${repo_slug} (exit ${label_fetch_rc}) — skipping close to protect potential origin:interactive PR (t2383)" >>"$LOGFILE"
		return 0
	fi
	if printf '%s\n' "$pr_labels" | grep -Fxq 'origin:interactive'; then
		echo "[pulse-wrapper] Deterministic merge: skipping auto-close of origin:interactive PR #${pr_number} — maintainer session work is never auto-closed" >>"$LOGFILE"
		# GH#18650 (Fix 4): post a one-time rebase nudge so the maintainer
		# has a visible signal that their CONFLICTING PR needs manual
		# attention. Without this, interactive CONFLICTING PRs rot
		# silently — the pulse log keeps skipping them every cycle but
		# the maintainer never sees the signal.
		_post_rebase_nudge_on_interactive_conflicting "$pr_number" "$repo_slug"
		return 0
	fi

	# GH#17574 / t2032: Check if the work is already on the default branch.
	# Extract task ID from PR title (e.g., "t153: add dark mode" → "t153")
	# and search recent commits on the default branch. When found, also try
	# to extract the merging PR number from the squash-merge suffix "(#NNN)"
	# on the matching commit subject, so the close comment can cite the
	# actual audit trail instead of claiming the work was "committed directly
	# to main" (which is misleading when the common case is a sibling PR).
	#
	# GH#18815: Fetch (sha, subject) pairs as JSON instead of subjects only,
	# so the file-overlap verification step can look up the matching commit's
	# files via `gh api repos/.../commits/SHA`.
	local work_on_main="false"
	local merging_pr=""
	local task_id_from_pr
	task_id_from_pr=$(printf '%s' "$pr_title" | grep -oE '^(t[0-9]+|GH#[0-9]+)' | head -1) || task_id_from_pr=""

	if [[ -n "$task_id_from_pr" ]]; then
		local commits_json
		commits_json=$(gh api "repos/${repo_slug}/commits" \
			--method GET -f per_page=50 \
			--jq '[.[] | {sha: .sha, subject: (.commit.message | split("\n")[0])}]' \
			2>/dev/null) || commits_json=""

		local matching_sha=""
		local matching_subject=""
		if [[ -n "$commits_json" && "$commits_json" != "null" ]]; then
			# Use jq with a regex test for word-boundary matching on the subject.
			# `first // empty` returns the first match or an empty string when
			# nothing matches — distinguishable from a malformed JSON response.
			local matching_obj
			matching_obj=$(printf '%s' "$commits_json" |
				jq -c --arg tid "$task_id_from_pr" '
					[.[] | select(.subject | test("(^|[^a-zA-Z0-9])" + $tid + "([^a-zA-Z0-9]|$)"; "i"))] | first // empty
				' 2>/dev/null) || matching_obj=""
			if [[ -n "$matching_obj" && "$matching_obj" != "null" ]]; then
				matching_sha=$(printf '%s' "$matching_obj" | jq -r '.sha // empty' 2>/dev/null) || matching_sha=""
				matching_subject=$(printf '%s' "$matching_obj" | jq -r '.subject // empty' 2>/dev/null) || matching_subject=""
			fi
		fi

		if [[ -n "$matching_sha" ]]; then
			# GH#18815: Verify the matching commit and the closing PR share
			# at least one non-planning file. The task-ID grep alone produced
			# false positives when a planning PR (e.g., 'plan(t2060): file
			# follow-ups') was merged before the implementation PR — the
			# regex matched the planning subject and the implementation PR
			# was wrongly auto-closed (PR #18760 incident, 2026-04-14).
			if _verify_pr_overlaps_commit "$pr_number" "$repo_slug" "$matching_sha"; then
				work_on_main="true"
				# Parse trailing "(#NNN)" from the matching commit's subject.
				# Non-squash merges won't have this suffix — that's fine, we
				# just omit the parenthetical from the close comment.
				merging_pr=$(printf '%s' "$matching_subject" |
					grep -oE '\(#[0-9]+\)$' |
					grep -oE '[0-9]+' | head -1) || merging_pr=""
			else
				# Task ID matched but file footprints don't overlap, OR file
				# lookup failed (network error, missing API permissions). Fail
				# CLOSED — leave the PR open and post a one-time rebase nudge.
				# Better to leave a stuck PR than to discard real work.
				local matching_pr_for_nudge=""
				matching_pr_for_nudge=$(printf '%s' "$matching_subject" |
					grep -oE '\(#[0-9]+\)$' |
					grep -oE '[0-9]+' | head -1) || matching_pr_for_nudge=""

				echo "[pulse-wrapper] Deterministic merge: task ID match for ${task_id_from_pr} in commit ${matching_sha:0:8} has no implementation file overlap with PR #${pr_number} — false-positive heuristic, leaving PR open for rebase (GH#18815)" >>"$LOGFILE"
				_post_rebase_nudge_on_worker_conflicting "$pr_number" "$repo_slug" "$task_id_from_pr" "$matching_pr_for_nudge"
				return 0
			fi
		fi
	fi

	if [[ "$work_on_main" == "true" ]]; then
		# Work is already on main — close PR with accurate message.
		# Cite the merging PR number when we could parse one.
		local landed_via=""
		if [[ -n "$merging_pr" ]]; then
			landed_via=" (via PR #${merging_pr})"
		fi
		gh pr close "$pr_number" --repo "$repo_slug" \
			--comment "Closing — this PR has merge conflicts with the base branch. The work for this task (\`${task_id_from_pr}\`) has already landed on main${landed_via}, so no re-attempt is needed.

_Closed by deterministic merge pass (pulse-wrapper.sh, GH#17574)._" 2>/dev/null || true

		# GH#17642: Do NOT auto-close the linked issue. Closing a conflicting
		# PR is safe (PRs are cheap), but closing the ISSUE based on a commit
		# search has too many false positives. The issue stays open for
		# re-dispatch with a fresh branch. Only the verified merge-pass
		# (which checks for an actually-merged PR) should close issues.
		echo "[pulse-wrapper] Deterministic merge: conflicting PR #${pr_number} closed, linked issue left open for re-dispatch (GH#17642)" >>"$LOGFILE"

		echo "[pulse-wrapper] Deterministic merge: closed conflicting PR #${pr_number} in ${repo_slug}: ${pr_title} (work already on main)" >>"$LOGFILE"
	else
		# Work NOT on main — carry forward the diff to the linked issue so the
		# next worker can rebase/cherry-pick instead of re-deriving from scratch
		# (t2118). Fail-open: any failure is logged and the close still proceeds.
		local linked_issue_for_diff
		linked_issue_for_diff=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || linked_issue_for_diff=""
		if [[ -n "$linked_issue_for_diff" && "$linked_issue_for_diff" =~ ^[0-9]+$ ]]; then
			_carry_forward_pr_diff "$pr_number" "$repo_slug" "$linked_issue_for_diff" || true
		fi

		# Use standard message but without the misleading
		# "remains open for re-attempt" phrasing (GH#17574)
		gh pr close "$pr_number" --repo "$repo_slug" \
			--comment "Closing — this PR has merge conflicts with the base branch. If the linked issue is still open, a worker will be dispatched to re-attempt with a fresh branch.

_Closed by deterministic merge pass (pulse-wrapper.sh)._" 2>/dev/null || true

		echo "[pulse-wrapper] Deterministic merge: closed conflicting PR #${pr_number} in ${repo_slug}: ${pr_title}" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Carry the diff of a closed-CONFLICTING PR forward to its linked issue
# body so the next dispatched worker can rebase/cherry-pick instead of
# re-deriving the solution from scratch (t2118).
#
# Idempotent: guarded by an HTML comment marker unique to each PR number.
# Size-capped at 20KB — diffs above this are truncated with a note.
# Fail-open: any gh API failure is logged and the function returns 0 so
# the caller (_close_conflicting_pr) always proceeds with the close.
#
# Does NOT fire in the "work on main" path — only called from the
# "work NOT on main" branch.
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug  (owner/repo)
#   $3 - linked_issue  (numeric issue number)
#######################################
_carry_forward_pr_diff() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"

	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0
	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 0

	# --- Fetch the PR diff ---
	local diff_content
	diff_content=$(gh pr diff "$pr_number" --repo "$repo_slug" 2>/dev/null) || diff_content=""
	if [[ -z "$diff_content" ]]; then
		echo "[pulse-wrapper] _carry_forward_pr_diff: PR #${pr_number} diff is empty or unavailable — skipping (t2118)" >>"$LOGFILE"
		return 0
	fi

	# --- Size-cap at 20KB (20480 bytes) ---
	local size_cap=20480
	local truncation_note=""
	if [[ ${#diff_content} -gt $size_cap ]]; then
		diff_content="${diff_content:0:$size_cap}"
		truncation_note="
... (truncated, full diff at PR #${pr_number})"
	fi

	# --- Fetch current issue body ---
	# --- Fetch current issue body (fail-safe: skip on API error to prevent data loss) ---
	local current_body fetch_rc
	fetch_rc=0
	current_body=$(gh issue view "$linked_issue" --repo "$repo_slug" \
		--json body --jq '.body // ""' 2>/dev/null) || fetch_rc=$?
	if [[ $fetch_rc -ne 0 ]]; then
		echo "[pulse-wrapper] _carry_forward_pr_diff: failed to fetch issue #${linked_issue} body (exit ${fetch_rc}) — skipping to avoid data loss (t2118)" >>"$LOGFILE"
		return 0
	fi

	# --- Idempotency guard ---
	# Marker format: <!-- t2118:prior-worker-diff:PR<N> -->
	local marker="<!-- t2118:prior-worker-diff:PR${pr_number} -->"
	if printf '%s' "$current_body" | grep -qF "$marker"; then
		echo "[pulse-wrapper] _carry_forward_pr_diff: issue #${linked_issue} already has diff marker for PR #${pr_number} — skipping (t2118)" >>"$LOGFILE"
		return 0
	fi

	# --- Build the append section ---
	# t2383 Fix 4: compute dynamic fence length. PR diffs can contain triple
	# backticks (markdown/docs changes). A fixed ``` fence would break rendering
	# and corrupt the worker handoff. Scan for the longest backtick run in the
	# diff and use one more than that.
	local fence_len=3
	local longest_run
	longest_run=$(printf '%s' "$diff_content" | grep -oE '\`{3,}' | awk '{ if (length > max) max = length } END { print max+0 }') || longest_run=0
	[[ "$longest_run" =~ ^[0-9]+$ ]] || longest_run=0
	if [[ "$longest_run" -ge "$fence_len" ]]; then
		fence_len=$((longest_run + 1))
	fi
	local fence=""
	local _i
	for (( _i=0; _i<fence_len; _i++ )); do
		fence="${fence}\`"
	done

	local new_section
	new_section="${marker}
## Prior worker attempt (PR #${pr_number}, closed CONFLICTING)

The following diff was produced by the prior worker before the PR was closed
due to merge conflicts. The next worker should review this diff and
rebase/apply it rather than re-deriving the solution from scratch.

<details><summary>Diff from PR #${pr_number} (click to expand)</summary>

${fence}diff
${diff_content}${truncation_note}
${fence}

</details>"

	local new_body
	new_body="${current_body}

${new_section}"

	if gh issue edit "$linked_issue" --repo "$repo_slug" \
		--body "$new_body" >/dev/null 2>&1; then
		echo "[pulse-wrapper] _carry_forward_pr_diff: appended diff from PR #${pr_number} to issue #${linked_issue} in ${repo_slug} (t2118)" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] _carry_forward_pr_diff: failed to update issue #${linked_issue} body in ${repo_slug} — continuing with close (t2118)" >>"$LOGFILE"
	fi
	return 0
}
