#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-ancillary-dispatch.sh — Ancillary worker dispatch — triage reviews (303 lines), needs-info relabel, routine comment responses, FOSS workers.
#
# Extracted from pulse-wrapper.sh in Phase 10 (FINAL) of the phased
# decomposition (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This is the final extraction. After Phase 10 merges, pulse-wrapper.sh
# drops below the 2,000-line simplification gate.
#
# Functions in this module (in source order):
#   - dispatch_triage_reviews
#   - relabel_needs_info_replies
#   - dispatch_routine_comment_responses
#   - dispatch_foss_workers

[[ -n "${_PULSE_ANCILLARY_DISPATCH_LOADED:-}" ]] && return 0
_PULSE_ANCILLARY_DISPATCH_LOADED=1

#######################################
# Dispatch triage review workers for needs-maintainer-review issues
#
# Reads the pre-fetched triage status from STATE_FILE and dispatches
# opus-tier review workers for issues marked needs-review. Respects
# the 2-per-cycle cap and available worker slots.
#
# Arguments:
#   $1 - available worker slots (AVAILABLE)
#   $2 - repos JSON path (default: REPOS_JSON)
#
# Outputs: updated available count to stdout (one integer)
# Exit code: always 0
#######################################
dispatch_triage_reviews() {
	local available="$1"
	local repos_json="${2:-${REPOS_JSON:-~/.config/aidevops/repos.json}}"
	local triage_count=0
	local triage_max=2

	[[ "$available" =~ ^[0-9]+$ ]] || available=0
	[[ "$available" -gt 0 ]] || {
		printf '%d\n' "$available"
		return 0
	}

	# Parse needs-review items from the dedicated triage state file (t1894).
	# NMR data is written to a separate file, not the LLM's STATE_FILE.
	local triage_file="${TRIAGE_STATE_FILE:-${STATE_FILE%.txt}-triage.txt}"
	[[ -f "$triage_file" ]] || {
		echo "[pulse-wrapper] dispatch_triage_reviews: no triage state file" >>"$LOGFILE"
		printf '%d\n' "$available"
		return 0
	}
	local state_file="$triage_file"

	# Resolve model: prefer opus, fall back to sonnet, then omit --model
	# (lets headless-runtime-helper pick its default, same as implementation workers)
	local resolved_model=""
	resolved_model=$(~/.aidevops/agents/scripts/model-availability-helper.sh resolve opus 2>/dev/null || echo "")
	if [[ -z "$resolved_model" ]]; then
		resolved_model=$(~/.aidevops/agents/scripts/model-availability-helper.sh resolve sonnet 2>/dev/null || echo "")
	fi
	if [[ -z "$resolved_model" ]]; then
		echo "[pulse-wrapper] dispatch_triage_reviews: model resolution failed (opus and sonnet unavailable)" >>"$LOGFILE"
	fi

	# Parse markdown-format state entries:
	#   ## owner/repo            ← repo slug header
	#   - Issue #NNN: ... [status: **needs-review**] ...
	# Build pipe-separated list: issue_num|repo_slug|repo_path
	local current_slug="" current_path="" candidates=""
	while IFS= read -r line; do
		# Match repo slug headers: "## owner/repo"
		if [[ "$line" =~ ^##[[:space:]]+([^[:space:]]+/[^[:space:]]+) ]]; then
			current_slug="${BASH_REMATCH[1]}"
			current_path=$(jq -r --arg s "$current_slug" '.initialized_repos[]? | select(.slug == $s) | .path' "$repos_json" 2>/dev/null || echo "")
			# Expand ~ in path
			current_path="${current_path/#\~/$HOME}"
			continue
		fi
		# Match needs-review issue lines
		if [[ "$line" == *"**needs-review**"* && "$line" =~ Issue\ #([0-9]+) ]]; then
			local issue_num="${BASH_REMATCH[1]}"
			if [[ -n "$current_slug" && -n "$current_path" ]]; then
				candidates="${candidates}${issue_num}|${current_slug}|${current_path}"$'\n'
			fi
		fi
	done <"$state_file"

	local candidate_count=0
	if [[ -n "$candidates" ]]; then
		candidate_count=$(printf '%s' "$candidates" | grep -c '|' 2>/dev/null || echo 0)
	fi
	echo "[pulse-wrapper] dispatch_triage_reviews: parsed ${candidate_count} candidates from state file" >>"$LOGFILE"

	[[ -n "$candidates" ]] || {
		echo "[pulse-wrapper] dispatch_triage_reviews: 0 candidates found in state file" >>"$LOGFILE"
		printf '%d\n' "$available"
		return 0
	}

	while IFS='|' read -r issue_num repo_slug repo_path; do
		[[ -n "$issue_num" && -n "$repo_slug" ]] || continue
		[[ "$available" -gt 0 && "$triage_count" -lt "$triage_max" ]] || break

		# ── t1916: Triage is exempt from the cryptographic approval gate ──
		# Triage is read + comment — it helps the maintainer decide whether to
		# approve the issue for implementation dispatch. The approval gate is
		# enforced on implementation dispatch (dispatch_with_dedup), not here.
		# Previously blocked by GH#17490 (t1894), restored in GH#17705 (t1916).

		# ── GH#17746: Content-hash dedup — fetch body+comments first ──
		# Fetch issue metadata and comments early: needed for both the dedup
		# check AND the prefetch prompt. If content is unchanged since the
		# last triage attempt, skip entirely (saves agent launch, lock/unlock,
		# and remaining API calls).
		local issue_json=""
		issue_json=$(gh issue view "$issue_num" --repo "$repo_slug" \
			--json number,title,body,author,labels,createdAt,updatedAt 2>/dev/null) || issue_json="{}"

		local issue_comments=""
		issue_comments=$(gh api "repos/${repo_slug}/issues/${issue_num}/comments" \
			--jq '[.[] | {author: .user.login, body: .body, created: .created_at}]' 2>/dev/null) || issue_comments="[]"

		local issue_body=""
		issue_body=$(echo "$issue_json" | jq -r '.body // "No body"' 2>/dev/null) || issue_body="No body"

		# Compute content hash and check cache
		local content_hash=""
		content_hash=$(_triage_content_hash "$issue_num" "$repo_slug" "$issue_body" "$issue_comments")

		if _triage_is_cached "$issue_num" "$repo_slug" "$content_hash"; then
			echo "[pulse-wrapper] triage dedup: skipping #${issue_num} in ${repo_slug} — content unchanged since last triage" >>"$LOGFILE"
			continue
		fi

		# ── GH#17827: Skip triage if awaiting contributor reply ──
		# When the last human comment is from a collaborator (maintainer asking
		# for info), the contributor needs to respond — not another triage cycle.
		# This eliminates the lock/unlock noise on NMR issues waiting for replies.
		if _triage_awaiting_contributor_reply "$issue_comments" "$repo_slug"; then
			echo "[pulse-wrapper] triage skip: #${issue_num} in ${repo_slug} — awaiting contributor reply (last comment from collaborator) (GH#17827)" >>"$LOGFILE"
			# Cache the hash so we don't re-check every cycle. A new contributor
			# comment will change the hash and trigger re-evaluation.
			_triage_update_cache "$issue_num" "$repo_slug" "$content_hash"
			continue
		fi

		# ── Content is new or changed — proceed with full prefetch ──

		# Check if this is a PR
		local pr_diff="" pr_files="" is_pr=""
		is_pr=$(gh pr view "$issue_num" --repo "$repo_slug" --json number --jq '.number' 2>/dev/null) || is_pr=""
		if [[ -n "$is_pr" ]]; then
			pr_diff=$(gh pr diff "$issue_num" --repo "$repo_slug" 2>/dev/null | head -500) || pr_diff=""
			pr_files=$(gh pr view "$issue_num" --repo "$repo_slug" --json files --jq '[.files[].path]' 2>/dev/null) || pr_files="[]"
		fi

		# Recent closed issues for duplicate detection
		local recent_closed=""
		recent_closed=$(gh issue list --repo "$repo_slug" --state closed \
			--json number,title --limit 30 --jq '.[].title' 2>/dev/null) || recent_closed=""

		# Git log for affected files (if PR)
		local git_log_context=""
		if [[ -n "$is_pr" && -n "$repo_path" && -d "$repo_path" ]]; then
			git_log_context=$(git -C "$repo_path" log --oneline -10 2>/dev/null) || git_log_context=""
		fi

		# Build the prompt with all pre-fetched data
		local prefetch_file=""
		prefetch_file=$(mktemp)

		cat >"$prefetch_file" <<PREFETCH_EOF
You are reviewing issue/PR #${issue_num} in ${repo_slug}.

## ISSUE_METADATA
${issue_json}

## ISSUE_BODY
${issue_body}

## ISSUE_COMMENTS
${issue_comments}

## PR_DIFF
${pr_diff:-Not a PR or no diff available}

## PR_FILES
${pr_files:-[]}

## RECENT_CLOSED
${recent_closed:-No recent closed issues}

## GIT_LOG
${git_log_context:-No git log available}

---

Now read the triage-review.md agent instructions and produce your review.
PREFETCH_EOF

		# ── Launch sandboxed agent (no Bash, no gh, no network) ──
		# NOTE: headless-runtime-helper.sh does not yet support --allowed-tools.
		# Tool restriction is enforced by the triage-review.md agent file frontmatter
		# in runtimes that respect YAML tool declarations (Claude Code, OpenCode).
		local review_output_file=""
		review_output_file=$(mktemp)

		local model_flag=""
		if [[ -n "$resolved_model" ]]; then
			model_flag="--model $resolved_model"
		fi

		# t1894/t1934: Lock issue and linked PRs during triage
		lock_issue_for_worker "$issue_num" "$repo_slug"

		# Run agent with triage-review prompt — agent file restricts to Read/Glob/Grep
		# shellcheck disable=SC2086
		"$HEADLESS_RUNTIME_HELPER" run \
			--role worker \
			--session-key "triage-review-${issue_num}" \
			--dir "$repo_path" \
			$model_flag \
			--title "Sandboxed triage review: Issue #${issue_num}" \
			--prompt-file "$prefetch_file" </dev/null >"$review_output_file" 2>&1

		rm -f "$prefetch_file"

		# ── Post-process: post the review comment (deterministic) ──
		local review_text=""
		review_text=$(cat "$review_output_file")
		rm -f "$review_output_file"

		local triage_posted="false"

		if [[ -n "$review_text" && ${#review_text} -gt 50 ]]; then
			# ── Safety filter: NEVER post raw sandbox/infrastructure output ──
			# If the LLM failed (quota, timeout, garbled), the output contains
			# sandbox startup logs, execution metadata, or internal paths.
			# These MUST be discarded — posting them leaks sensitive infra data.
			local has_infra_markers="false"
			if echo "$review_text" | grep -qE '\[SANDBOX\]|\[INFO\] Executing|timeout=[0-9]+s|network_blocked=|sandbox-exec-helper|/opt/homebrew/|opencode run '; then
				has_infra_markers="true"
			fi

			# Extract just the review portion (starts with ## Review variants).
			# GH#17873: Workers sometimes produce slightly different headers
			# (e.g., "## Review", "## Triage Review:", "## Review Summary:").
			# Match any "## " line containing "Review" (case-insensitive).
			local clean_review=""
			clean_review=$(echo "$review_text" | sed -n '/^## .*[Rr]eview/,$ p')

			if [[ -n "$clean_review" ]]; then
				# Re-check extracted review for infra leaks (belt-and-suspenders)
				if echo "$clean_review" | grep -qE '\[SANDBOX\]|\[INFO\] Executing|timeout=[0-9]+s|network_blocked=|sandbox-exec-helper'; then
					echo "[pulse-wrapper] SECURITY: triage review for #${issue_num} contained infrastructure markers after extraction — suppressed" >>"$LOGFILE"
				else
					gh issue comment "$issue_num" --repo "$repo_slug" \
						--body "$clean_review" >/dev/null 2>&1 || true
					echo "[pulse-wrapper] Posted sandboxed triage review for #${issue_num} in ${repo_slug}" >>"$LOGFILE"
					triage_posted="true"
				fi
			elif [[ "$has_infra_markers" == "true" ]]; then
				# No review header AND infra markers present — raw sandbox output, discard entirely
				echo "[pulse-wrapper] SECURITY: triage review for #${issue_num} was raw sandbox output — suppressed (${#review_text} chars)" >>"$LOGFILE"
			else
				echo "[pulse-wrapper] Triage review for #${issue_num} had no review header (## *Review*) and no infra markers — suppressed to be safe (${#review_text} chars)" >>"$LOGFILE"
			fi
		else
			echo "[pulse-wrapper] Triage review for #${issue_num} produced no usable output (${#review_text} chars)" >>"$LOGFILE"
		fi

		# GH#17829: Surface triage failures visibly. When the triage worker
		# fails to produce a review, the only evidence is log entries — the
		# issue timeline shows lock/unlock churn with no visible outcome.
		# Add a label so maintainers can identify issues needing manual triage.
		# The label is removed when a successful triage review is posted.
		if [[ "$triage_posted" == "true" ]]; then
			gh issue edit "$issue_num" --repo "$repo_slug" \
				--remove-label "triage-failed" >/dev/null 2>&1 || true
		else
			gh issue edit "$issue_num" --repo "$repo_slug" \
				--add-label "triage-failed" >/dev/null 2>&1 || true
			echo "[pulse-wrapper] Added triage-failed label to #${issue_num} in ${repo_slug}" >>"$LOGFILE"
		fi

		# Unlock issue after triage
		unlock_issue_after_worker "$issue_num" "$repo_slug"

		# GH#17873: Only cache content hash on successful post.
		# Previously (GH#17746) the cache was written unconditionally,
		# which created a dead-letter state: if the safety filter suppressed
		# the review (e.g., missing ## Review: header), the content hash was
		# still cached, and subsequent pulse cycles would skip the issue
		# forever ("content unchanged since last triage") even though no
		# review was ever posted. Now we only cache on success — failed
		# attempts are retried on the next pulse cycle, allowing transient
		# worker formatting issues to self-heal.
		#
		# GH#17827: BUT if failures are persistent (>= TRIAGE_MAX_RETRIES on
		# the same content hash), cache anyway to break the infinite
		# lock→agent→fail→unlock loop. The triage-failed label remains so
		# maintainers can identify these issues for manual triage.
		if [[ "$triage_posted" == "true" ]]; then
			_triage_update_cache "$issue_num" "$repo_slug" "$content_hash"
		elif _triage_increment_failure "$issue_num" "$repo_slug" "$content_hash"; then
			echo "[pulse-wrapper] Triage retry cap reached for #${issue_num} in ${repo_slug} — caching hash to stop lock/unlock loop (GH#17827)" >>"$LOGFILE"
			_triage_update_cache "$issue_num" "$repo_slug" "$content_hash"
		else
			echo "[pulse-wrapper] Skipping triage cache for #${issue_num} — review not posted, will retry on next cycle" >>"$LOGFILE"
		fi

		sleep 2
		triage_count=$((triage_count + 1))
		available=$((available - 1))
	done <<<"$candidates"

	local slots_remaining="$available"
	echo "[pulse-wrapper] dispatch_triage_reviews: dispatched ${triage_count} triage workers (${slots_remaining} slots remaining)" >>"$LOGFILE"

	printf '%d\n' "$available"
	return 0
}

#######################################
# Relabel status:needs-info issues where contributor has replied
#
# Reads the pre-fetched needs-info reply status from STATE_FILE and
# transitions replied issues to needs-maintainer-review.
#
# Arguments:
#   $1 - repos JSON path (default: REPOS_JSON)
#
# Exit code: always 0
#######################################
relabel_needs_info_replies() {
	local repos_json="${1:-${REPOS_JSON:-~/.config/aidevops/repos.json}}"
	local state_file="${STATE_FILE:-}"
	[[ -f "$state_file" ]] || return 0

	# Parse replied items from pre-fetched state (format: number|slug)
	while IFS='|' read -r issue_num repo_slug; do
		[[ -n "$issue_num" && -n "$repo_slug" ]] || continue

		gh issue edit "$issue_num" --repo "$repo_slug" \
			--remove-label "status:needs-info" \
			--add-label "needs-maintainer-review" 2>/dev/null || true
		gh issue comment "$issue_num" --repo "$repo_slug" \
			--body "Contributor replied to the information request. Relabeled to \`needs-maintainer-review\` for re-evaluation." \
			2>/dev/null || true
	done < <(grep -oP '(?<=replied\|)\d+\|[^\n]+' "$state_file" 2>/dev/null || true)

	return 0
}

#######################################
# dispatch_routine_comment_responses
#
# Scans routine-tracking issues across pulse-enabled repos for unanswered
# user comments. Dispatches lightweight Haiku workers to respond.
# Max 2 dispatches per cycle to avoid flooding.
#
# Exit code: always 0 (non-fatal)
#######################################
dispatch_routine_comment_responses() {
	local responder="${SCRIPT_DIR}/routine-comment-responder.sh"
	if [[ ! -x "$responder" ]]; then
		return 0
	fi

	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local max_dispatches="${ROUTINE_COMMENT_MAX_PER_CYCLE:-2}"
	local dispatched=0

	# Iterate pulse-enabled repos
	local slug repo_path
	while IFS='|' read -r slug repo_path; do
		[[ -n "$slug" && -n "$repo_path" ]] || continue
		[[ "$dispatched" -lt "$max_dispatches" ]] || break

		# Scan for unanswered comments
		local scan_output
		scan_output=$(bash "$responder" scan "$slug" "$repo_path" 2>/dev/null) || continue
		[[ -n "$scan_output" ]] || continue

		while IFS='|' read -r issue_number comment_id author body_preview; do
			[[ -n "$issue_number" && -n "$comment_id" ]] || continue
			[[ "$dispatched" -lt "$max_dispatches" ]] || break

			echo "[pulse-wrapper] Routine comment response: dispatching for #${issue_number} comment ${comment_id} by @${author} in ${slug}" >>"$LOGFILE"
			bash "$responder" dispatch "$slug" "$repo_path" "$issue_number" "$comment_id" 2>>"$LOGFILE" || true
			dispatched=$((dispatched + 1))
		done <<<"$scan_output"
	done < <(jq -r '.initialized_repos[] | select(.pulse == true) | select(.local_only != true) | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null)

	if [[ "$dispatched" -gt 0 ]]; then
		echo "[pulse-wrapper] Routine comment responses: dispatched ${dispatched} workers" >>"$LOGFILE"
	fi

	return 0
}

dispatch_foss_workers() {
	local available="$1"
	local repos_json="${2:-${REPOS_JSON:-~/.config/aidevops/repos.json}}"
	local foss_count=0
	local foss_max="${FOSS_MAX_DISPATCH_PER_CYCLE:-2}"

	[[ "$available" =~ ^[0-9]+$ ]] || available=0

	while IFS='|' read -r foss_slug foss_path; do
		[[ -n "$foss_slug" && -n "$foss_path" ]] || continue
		[[ "$available" -gt 0 && "$foss_count" -lt "$foss_max" ]] || break

		# Pre-dispatch eligibility check (budget + rate limit)
		~/.aidevops/agents/scripts/foss-contribution-helper.sh check "$foss_slug" >/dev/null 2>&1 || continue

		# Scan for a suitable issue
		local labels_filter foss_issue foss_issue_num foss_issue_title
		labels_filter=$(jq -r --arg slug "$foss_slug" \
			'.initialized_repos[] | select(.slug == $slug) | .foss_config.labels_filter // ["help wanted","good first issue","bug"] | join(",")' \
			"$repos_json" 2>/dev/null || echo "help wanted")
		foss_issue=$(gh issue list --repo "$foss_slug" --state open \
			--label "${labels_filter%%,*}" --limit 1 \
			--json number,title --jq '.[0] | "\(.number)|\(.title)"' 2>/dev/null) || foss_issue=""
		[[ -n "$foss_issue" ]] || continue

		foss_issue_num="${foss_issue%%|*}"
		foss_issue_title="${foss_issue#*|}"

		local disclosure_flag=""
		local disclosure
		disclosure=$(jq -r --arg slug "$foss_slug" \
			'.initialized_repos[] | select(.slug == $slug) | .foss_config.disclosure // true' \
			"$repos_json" 2>/dev/null || echo "true")
		[[ "$disclosure" == "true" ]] && disclosure_flag=" Include AI disclosure note in the PR."

		~/.aidevops/agents/scripts/headless-runtime-helper.sh run \
			--role worker \
			--session-key "foss-${foss_slug}-${foss_issue_num}" \
			--dir "$foss_path" \
			--title "FOSS: ${foss_slug} #${foss_issue_num}: ${foss_issue_title}" \
			--prompt "/full-loop Implement issue #${foss_issue_num} (https://github.com/${foss_slug}/issues/${foss_issue_num}) -- ${foss_issue_title}. This is a FOSS contribution.${disclosure_flag} After completion, run: foss-contribution-helper.sh record ${foss_slug} <tokens_used>" \
			</dev/null >>"/tmp/pulse-foss-${foss_issue_num}.log" 2>&1 9>&- &
		sleep 2

		foss_count=$((foss_count + 1))
		available=$((available - 1))
	done < <(jq -r '.initialized_repos[] | select(.foss == true and (.foss_config.blocklist // false) == false) | "\(.slug)|\(.path)"' \
		"$repos_json" 2>/dev/null || true)

	printf '%d\n' "$available"
	return 0
}
