#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-ancillary-dispatch.sh — Ancillary worker dispatch — triage reviews, needs-info relabel, routine comment responses, FOSS workers.
#
# Extracted from pulse-wrapper.sh in Phase 10 (FINAL) of the phased
# decomposition (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# Phase 12 (t2000, GH#18448): dispatch_triage_reviews() split into three
# functions to reduce size from 291 to <80 lines and improve testability.
#
# Functions in this module (in source order):
#   - _build_triage_review_prompt   (private: pure prompt construction)
#   - _dispatch_triage_review_worker (private: side-effecting worker dispatch)
#   - dispatch_triage_reviews       (public: thin orchestrator)
#   - relabel_needs_info_replies
#   - dispatch_routine_comment_responses
#   - dispatch_foss_workers

[[ -n "${_PULSE_ANCILLARY_DISPATCH_LOADED:-}" ]] && return 0
_PULSE_ANCILLARY_DISPATCH_LOADED=1

#######################################
# Ensure the triage-failed label exists in the target repo.
#
# Uses gh label create --force (idempotent — creates if missing,
# refreshes colour/description if present). This fixes t2016 where
# the label was never provisioned in any repo and every
# `gh issue edit --add-label "triage-failed"` call failed silently.
#
# Arguments:
#   $1 - repo_slug (owner/repo)
#######################################
_ensure_triage_failed_label() {
	local repo_slug="$1"
	[[ -n "$repo_slug" ]] || return 0
	gh label create "triage-failed" \
		--repo "$repo_slug" \
		--color "E11D21" \
		--description "Automated triage could not produce a review — needs manual attention" \
		--force >/dev/null 2>&1 || true
	return 0
}

#######################################
# Post a maintainer-visible escalation comment when automated triage
# has exhausted its retry budget.
#
# Idempotent via the `<!-- triage-escalation -->` HTML marker — if a
# comment containing the marker already exists, this is a no-op.
# This closes the observability gap identified in t2016 where the
# content-hash cache was written after N failures, silently locking
# the issue out of triage with no visible signal to maintainers.
#
# Arguments:
#   $1 - issue_num
#   $2 - repo_slug
#   $3 - failure_reason (short machine-readable tag)
#   $4 - attempts (integer count of retries used)
#   $5 - last_output_chars (integer)
#
# Returns 0 on success or when the marker already exists; non-zero
# is reserved for unexpected gh failures (best-effort — the caller
# should not block on this).
#######################################
_post_triage_escalation_comment() {
	local issue_num="$1"
	local repo_slug="$2"
	local failure_reason="${3:-unknown}"
	local attempts="${4:-0}"
	local last_output_chars="${5:-0}"

	[[ -n "$issue_num" && -n "$repo_slug" ]] || return 0

	# Idempotency guard — scan existing comments for our marker.
	local existing=""
	existing=$(gh api "repos/${repo_slug}/issues/${issue_num}/comments" \
		--jq '[.[] | select(.body | contains("<!-- triage-escalation -->"))] | length' \
		2>/dev/null) || existing=""
	if [[ "$existing" =~ ^[0-9]+$ && "$existing" -gt 0 ]]; then
		echo "[pulse-wrapper] triage escalation comment already present on #${issue_num} in ${repo_slug} — skipping (idempotent)" >>"$LOGFILE"
		return 0
	fi

	# Map failure_reason → human-readable explanation.
	local reason_human="${failure_reason}"
	case "$failure_reason" in
	no-review-header)
		reason_human="Worker produced output but it did not contain a \`## Review\` header (safety filter suppressed the post)."
		;;
	raw-sandbox-output)
		reason_human="Worker output contained infrastructure/sandbox markers (log lines, exec metadata). Suppressed to prevent leaking internal paths."
		;;
	no-usable-output)
		reason_human="Worker returned no usable output (empty or <50 chars)."
		;;
	infra-markers-after-extraction)
		reason_human="Extracted review block still contained infrastructure markers — suppressed as a belt-and-suspenders safety check."
		;;
	esac

	# Compose signature footer via the canonical helper.
	local footer=""
	if [[ -x "$HOME/.aidevops/agents/scripts/gh-signature-helper.sh" ]]; then
		footer=$("$HOME/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
			--model "pulse-triage" \
			--issue "${repo_slug}#${issue_num}" 2>/dev/null) || footer=""
	fi

	local body_file=""
	body_file=$(mktemp)
	cat >"$body_file" <<ESCALATION_EOF
<!-- triage-escalation -->
## Automated triage could not produce a review

The pulse attempted to post an automated triage review on this issue **${attempts}** time(s) but every attempt was suppressed by the safety filter. The content-hash cache has now been written to stop the lock/unlock churn, which means **this issue will no longer appear in the automated triage queue** until its body or comments change.

### What went wrong

- **Reason:** ${reason_human}
- **Last attempt output size:** ${last_output_chars} chars
- **Failure tag:** \`${failure_reason}\`

### What a maintainer should do

1. **Review manually** — run \`/review-issue-pr ${issue_num}\` in an interactive session, or open the issue and evaluate it by hand.
2. **Force a retry** (optional) — delete the cache entry to let the next pulse cycle re-attempt:

    \`\`\`bash
    rm -f ~/.aidevops/.agent-workspace/tmp/triage-cache/$(echo "$repo_slug" | tr '/' '_')-${issue_num}.hash
    gh issue edit ${issue_num} --repo ${repo_slug} --remove-label triage-failed
    \`\`\`

3. **Fix the worker** (if this keeps happening) — huge headerless outputs usually mean the triage-review agent prompt needs tightening. See \`.agents/workflows/triage-review.md\`.

*This escalation was posted automatically by \`_post_triage_escalation_comment\` in \`pulse-ancillary-dispatch.sh\` (t2016) because the retry budget was exhausted without a visible review.*${footer:+

}${footer:-}
ESCALATION_EOF

	if gh issue comment "$issue_num" --repo "$repo_slug" --body-file "$body_file" >/dev/null 2>&1; then
		echo "[pulse-wrapper] Posted triage escalation comment on #${issue_num} in ${repo_slug} (reason: ${failure_reason}, attempts: ${attempts})" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Failed to post triage escalation comment on #${issue_num} in ${repo_slug}" >>"$LOGFILE"
	fi
	rm -f "$body_file"
	return 0
}

#######################################
# Build the prefetch prompt for a triage review
#
# Fetches issue metadata and comments, runs dedup-cache and
# contributor-reply guards, then writes the prompt to a temp file.
# Pure in the sense of no lock/unlock or agent launch; cache writes
# and LOGFILE writes are allowed as logging side effects.
#
# Arguments:
#   $1 - issue_num
#   $2 - repo_slug
#   $3 - repo_path (may be empty for non-local repos)
#
# Outputs to stdout: "prompt_file_path|content_hash" (pipe-separated)
# Returns 0 on success; 1 if the issue should be skipped (cached or
#   awaiting contributor reply)
#######################################
_build_triage_review_prompt() {
	local issue_num="$1"
	local repo_slug="$2"
	local repo_path="$3"

	# ── GH#17746: Fetch body+comments early — needed for dedup AND prompt ──
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
		return 1
	fi

	# ── GH#17827: Skip if awaiting contributor reply ──
	# A new contributor comment will change the hash and trigger re-evaluation.
	if _triage_awaiting_contributor_reply "$issue_comments" "$repo_slug"; then
		echo "[pulse-wrapper] triage skip: #${issue_num} in ${repo_slug} — awaiting contributor reply (GH#17827)" >>"$LOGFILE"
		_triage_update_cache "$issue_num" "$repo_slug" "$content_hash"
		return 1
	fi

	# ── Content is new or changed — proceed with full prefetch ──
	local pr_diff="" pr_files="" is_pr=""
	is_pr=$(gh pr view "$issue_num" --repo "$repo_slug" --json number --jq '.number' 2>/dev/null) || is_pr=""
	if [[ -n "$is_pr" ]]; then
		pr_diff=$(gh pr diff "$issue_num" --repo "$repo_slug" 2>/dev/null | head -500) || pr_diff=""
		pr_files=$(gh pr view "$issue_num" --repo "$repo_slug" --json files --jq '[.files[].path]' 2>/dev/null) || pr_files="[]"
	fi

	local recent_closed=""
	recent_closed=$(gh issue list --repo "$repo_slug" --state closed \
		--json number,title --limit 30 --jq '.[].title' 2>/dev/null) || recent_closed=""

	local git_log_context=""
	if [[ -n "$is_pr" && -n "$repo_path" && -d "$repo_path" ]]; then
		git_log_context=$(git -C "$repo_path" log --oneline -10 2>/dev/null) || git_log_context=""
	fi

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

	# Output file path and content hash (pipe-separated) for the caller
	printf '%s|%s\n' "$prefetch_file" "$content_hash"
	return 0
}

#######################################
# Dispatch a sandboxed triage review worker and post its output
#
# Locks the issue, runs the triage-review agent, posts the review
# comment (with safety filtering), updates triage labels, updates the
# content-hash cache, and unlocks the issue. All side effects live here.
#
# Arguments:
#   $1 - issue_num
#   $2 - repo_slug
#   $3 - repo_path (passed to --dir of headless helper)
#   $4 - prompt_file (path to prefetch temp file; consumed and removed)
#   $5 - content_hash (for success/failure cache update)
#   $6 - resolved_model (empty = let helper choose)
#
# Exit code: always 0
#######################################
_dispatch_triage_review_worker() {
	local issue_num="$1"
	local repo_slug="$2"
	local repo_path="$3"
	local prefetch_file="$4"
	local content_hash="$5"
	local resolved_model="${6:-}"

	local model_flag=""
	[[ -n "$resolved_model" ]] && model_flag="--model $resolved_model"

	# ── Launch sandboxed agent (no Bash, no gh, no network) ──
	# NOTE: headless-runtime-helper.sh does not yet support --allowed-tools.
	# Tool restriction is enforced by the triage-review.md agent file frontmatter
	# in runtimes that respect YAML tool declarations (Claude Code, OpenCode).
	local review_output_file=""
	review_output_file=$(mktemp)

	# t1894/t1934: Lock issue and linked PRs during triage
	lock_issue_for_worker "$issue_num" "$repo_slug"

	# t2025: Capture stderr to a separate file so sandbox INFO lines
	# (written to stderr by sandbox-exec-helper.sh's log_sandbox) don't
	# contaminate the stdout review capture. Previously, "2>&1" merged
	# '[INFO] Executing (timeout=..., network_blocked=...)' lines into
	# the capture file, which caused the safety filter to classify
	# legitimate output as "raw sandbox output" and suppress it.
	local review_stderr_file=""
	review_stderr_file="${review_output_file}.stderr"

	# Run agent with triage-review prompt — agent file restricts to Read/Glob/Grep
	# shellcheck disable=SC2086
	"$HEADLESS_RUNTIME_HELPER" run \
		--role worker \
		--session-key "triage-review-${issue_num}" \
		--dir "$repo_path" \
		$model_flag \
		--title "Sandboxed triage review: Issue #${issue_num}" \
		--prompt-file "$prefetch_file" </dev/null >"$review_output_file" 2>"$review_stderr_file"

	rm -f "$prefetch_file"

	# t2025: opencode run is invoked with --format json by
	# headless-runtime-helper.sh (see _build_opencode_cmd_args:1477), which
	# means the capture file contains a JSONL transcript of the full
	# session: user prompt + tool_use events + tool_result events +
	# assistant messages. The final assistant message holds the review
	# text. Parse it with jq before running the plain-text safety filter,
	# otherwise the "## Review:" header is buried inside an escaped JSON
	# string and the "^## .*[Rr]eview" regex never matches.
	#
	# Defensive fallback: if the file isn't valid JSONL (e.g., opencode
	# crashed before emitting anything structured, or the format changes
	# in a future release), fall through to reading the raw file as plain
	# text — same behaviour as before this fix.
	local review_text=""
	local jsonl_parsed=""
	if [[ -s "$review_output_file" ]]; then
		jsonl_parsed=$(jq -rs '
			[.[] | select(.type == "assistant")] as $assistants
			| if ($assistants | length) > 0 then
				$assistants
				| last
				| (.message.content // .content // "")
				| if type == "array" then
					[.[] | select(.type == "text") | .text] | join("\n")
				  elif type == "string" then
					.
				  else
					""
				  end
			  else
				""
			  end
		' "$review_output_file" 2>/dev/null) || jsonl_parsed=""
	fi
	if [[ -n "$jsonl_parsed" ]]; then
		review_text="$jsonl_parsed"
	else
		# Fallback: raw file (non-JSONL or parser failure)
		review_text=$(cat "$review_output_file" 2>/dev/null || echo "")
	fi

	# t2025: On any failure path below, save the raw capture for debugging.
	# Keep a reference to the raw file until we know whether to preserve it.
	local _triage_raw_capture="$review_output_file"

	local triage_posted="false"
	# t2016: Track WHY the post was suppressed so the escalation comment
	# can surface an actionable reason instead of a buried log line.
	local failure_reason=""
	local output_chars="${#review_text}"

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
				failure_reason="infra-markers-after-extraction"
			else
				gh issue comment "$issue_num" --repo "$repo_slug" \
					--body "$clean_review" >/dev/null 2>&1 || true
				echo "[pulse-wrapper] Posted sandboxed triage review for #${issue_num} in ${repo_slug}" >>"$LOGFILE"
				triage_posted="true"
			fi
		elif [[ "$has_infra_markers" == "true" ]]; then
			# No review header AND infra markers present — raw sandbox output, discard entirely
			echo "[pulse-wrapper] SECURITY: triage review for #${issue_num} was raw sandbox output — suppressed (${#review_text} chars)" >>"$LOGFILE"
			failure_reason="raw-sandbox-output"
		else
			echo "[pulse-wrapper] Triage review for #${issue_num} had no review header (## *Review*) and no infra markers — suppressed to be safe (${#review_text} chars)" >>"$LOGFILE"
			failure_reason="no-review-header"
		fi
	else
		echo "[pulse-wrapper] Triage review for #${issue_num} produced no usable output (${#review_text} chars)" >>"$LOGFILE"
		failure_reason="no-usable-output"
	fi

	# GH#17829: Surface triage failures visibly. Add label so maintainers
	# can identify issues needing manual triage; remove on success.
	# t2016: Ensure the label exists first (gh label create --force is
	# idempotent) and only log "Added" when the add command succeeds.
	if [[ "$triage_posted" == "true" ]]; then
		gh issue edit "$issue_num" --repo "$repo_slug" \
			--remove-label "triage-failed" >/dev/null 2>&1 || true
	else
		_ensure_triage_failed_label "$repo_slug"
		if gh issue edit "$issue_num" --repo "$repo_slug" \
			--add-label "triage-failed" >/dev/null 2>&1; then
			echo "[pulse-wrapper] Added triage-failed label to #${issue_num} in ${repo_slug}" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] FAILED to add triage-failed label to #${issue_num} in ${repo_slug} (gh issue edit returned non-zero)" >>"$LOGFILE"
		fi
	fi

	# t2025: On any failure, save the raw JSONL capture for future debugging
	# so we don't have to re-trigger the bug. Capped at 100 files to prevent
	# runaway accumulation.
	if [[ "$triage_posted" != "true" && -s "$_triage_raw_capture" ]]; then
		local _triage_debug_dir="${TRIAGE_DEBUG_DIR:-${HOME}/.aidevops/.agent-workspace/tmp/triage-debug}"
		if mkdir -p "$_triage_debug_dir" 2>/dev/null; then
			local _triage_debug_count
			_triage_debug_count=$(find "$_triage_debug_dir" -type f -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
			if [[ "$_triage_debug_count" -ge 100 ]]; then
				# Drop the oldest to make room
				local _oldest
				_oldest=$(find "$_triage_debug_dir" -type f -name '*.jsonl' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | tail -1)
				[[ -n "$_oldest" ]] && rm -f "$_oldest" "${_oldest%.jsonl}.meta"
			fi
			local _slug_safe_dbg="${repo_slug//\//_}"
			local _ts_dbg
			_ts_dbg=$(date +%s)
			local _dest_dbg="${_triage_debug_dir}/${_slug_safe_dbg}-${issue_num}-${_ts_dbg}.jsonl"
			if cp "$_triage_raw_capture" "$_dest_dbg" 2>/dev/null; then
				printf 'reason=%s\ntime=%s\nslug=%s\nissue=%s\nchars=%s\nstderr=%s\n' \
					"$failure_reason" \
					"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
					"$repo_slug" \
					"$issue_num" \
					"$output_chars" \
					"$([[ -s "$review_stderr_file" ]] && echo "present" || echo "empty")" \
					>"${_dest_dbg%.jsonl}.meta" 2>/dev/null || true
				echo "[pulse-wrapper] Triage debug capture saved to ${_dest_dbg} (reason: ${failure_reason})" >>"$LOGFILE"
			fi
		fi
	fi
	rm -f "$review_output_file" "$review_stderr_file"

	# Unlock issue after triage
	unlock_issue_after_worker "$issue_num" "$repo_slug"

	# GH#17873: Only cache content hash on successful post.
	# GH#17827: If failures are persistent (>= TRIAGE_MAX_RETRIES on the
	# same content hash), cache to break the infinite lock→agent→fail→unlock
	# loop. The triage-failed label remains for maintainer visibility.
	# t2016: When the retry cap is hit, post a structured escalation comment
	# BEFORE writing the cache, so the maintainer has a visible signal
	# instead of a silently-cached issue that disappears from triage forever.
	if [[ "$triage_posted" == "true" ]]; then
		_triage_update_cache "$issue_num" "$repo_slug" "$content_hash"
	elif _triage_increment_failure "$issue_num" "$repo_slug" "$content_hash"; then
		echo "[pulse-wrapper] Triage retry cap reached for #${issue_num} in ${repo_slug} — caching hash to stop lock/unlock loop (GH#17827)" >>"$LOGFILE"
		local cap_attempts="${TRIAGE_MAX_RETRIES:-1}"
		_post_triage_escalation_comment \
			"$issue_num" "$repo_slug" \
			"$failure_reason" "$cap_attempts" "$output_chars"
		_triage_update_cache "$issue_num" "$repo_slug" "$content_hash"
	else
		echo "[pulse-wrapper] Skipping triage cache for #${issue_num} — review not posted, will retry on next cycle" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Dispatch triage review workers for needs-maintainer-review issues
#
# Reads the pre-fetched triage status from the triage state file and
# dispatches opus-tier review workers for issues marked needs-review.
# Respects the 2-per-cycle cap and available worker slots.
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

	# NMR data is in a dedicated triage state file, not the LLM's STATE_FILE (t1894).
	local triage_file="${TRIAGE_STATE_FILE:-${STATE_FILE%.txt}-triage.txt}"
	[[ -f "$triage_file" ]] || {
		echo "[pulse-wrapper] dispatch_triage_reviews: no triage state file" >>"$LOGFILE"
		printf '%d\n' "$available"
		return 0
	}

	# Resolve model: prefer opus, fall back to sonnet, then omit --model
	local resolved_model=""
	resolved_model=$(~/.aidevops/agents/scripts/model-availability-helper.sh resolve opus 2>/dev/null || echo "")
	[[ -n "$resolved_model" ]] || resolved_model=$(~/.aidevops/agents/scripts/model-availability-helper.sh resolve sonnet 2>/dev/null || echo "")
	[[ -n "$resolved_model" ]] || echo "[pulse-wrapper] dispatch_triage_reviews: model resolution failed (opus and sonnet unavailable)" >>"$LOGFILE"

	# Parse "## owner/repo" headers and "- Issue #N: ... [status: **needs-review**]" lines.
	local current_slug="" current_path="" candidates=""
	while IFS= read -r line; do
		if [[ "$line" =~ ^##[[:space:]]+([^[:space:]]+/[^[:space:]]+) ]]; then
			current_slug="${BASH_REMATCH[1]}"
			current_path=$(jq -r --arg s "$current_slug" '.initialized_repos[]? | select(.slug == $s) | .path' "$repos_json" 2>/dev/null || echo "")
			current_path="${current_path/#\~/$HOME}"
			continue
		fi
		if [[ "$line" == *"**needs-review**"* && "$line" =~ Issue\ #([0-9]+) ]]; then
			local issue_num="${BASH_REMATCH[1]}"
			[[ -n "$current_slug" && -n "$current_path" ]] && candidates="${candidates}${issue_num}|${current_slug}|${current_path}"$'\n'
		fi
	done <"$triage_file"

	local candidate_count=0
	[[ -n "$candidates" ]] && candidate_count=$(printf '%s' "$candidates" | grep -c '|' 2>/dev/null || echo 0)
	echo "[pulse-wrapper] dispatch_triage_reviews: parsed ${candidate_count} candidates from state file" >>"$LOGFILE"

	[[ -n "$candidates" ]] || {
		echo "[pulse-wrapper] dispatch_triage_reviews: 0 candidates found in state file" >>"$LOGFILE"
		printf '%d\n' "$available"
		return 0
	}

	# t1916: Triage is exempt from the cryptographic approval gate.
	while IFS='|' read -r issue_num repo_slug repo_path; do
		[[ -n "$issue_num" && -n "$repo_slug" ]] || continue
		[[ "$available" -gt 0 && "$triage_count" -lt "$triage_max" ]] || break

		local prompt_result=""
		prompt_result=$(_build_triage_review_prompt "$issue_num" "$repo_slug" "$repo_path") || continue
		_dispatch_triage_review_worker \
			"$issue_num" "$repo_slug" "$repo_path" \
			"${prompt_result%%|*}" "${prompt_result#*|}" "$resolved_model"

		sleep 2
		triage_count=$((triage_count + 1))
		available=$((available - 1))
	done <<<"$candidates"

	echo "[pulse-wrapper] dispatch_triage_reviews: dispatched ${triage_count} triage workers (${available} slots remaining)" >>"$LOGFILE"
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
