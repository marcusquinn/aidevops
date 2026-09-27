#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pulse Diagnose Issue — issue-level dispatch and PR lifecycle report (t3258).
#
# Provides cmd_issue plus its attempt/blocker summaries, fetchers and renderers.
# Sourced by pulse-diagnose-helper.sh; relies on its constants, path
# resolvers (pulse-diagnose-utils.sh) and shared JSON field helpers.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_DIAGNOSE_ISSUE_LOADED:-}" ]] && return 0
_PULSE_DIAGNOSE_ISSUE_LOADED=1

# Summarise terminal prelaunch failures that never reached runtime metrics.
# Args: $1=issue_log_lines
# Outputs compact JSON with a total and reason counts.
_issue_prelaunch_failure_summary_json() {
	local issue_log_lines="$1"
	if ! command -v jq >/dev/null 2>&1; then
		printf '{"prelaunch_failure_count":0,"prelaunch_failure_reasons":{}}\n'
		return 0
	fi

	jq -nc --arg lines "$issue_log_lines" '
		[$lines | split("\n")[]
			| capture("prelaunch failure reason=(?<reason>[A-Za-z0-9_.:-]+)")?] as $failures
		| {
			prelaunch_failure_count: ($failures | length),
			prelaunch_failure_reasons: (
				reduce $failures[] as $failure ({};
					.[$failure.reason] = ((.[$failure.reason] // 0) + 1))
			)
		}' 2>/dev/null || printf '{"prelaunch_failure_count":0,"prelaunch_failure_reasons":{}}\n'
	return 0
}

# Summarise typed dirty-worktree evidence-unavailable admission holds.
# Args: $1=issue_log_lines
# Outputs compact JSON with bounded, sanitized transport metadata.
_issue_dirty_worktree_hold_summary_json() {
	local issue_log_lines="$1"
	if ! command -v jq >/dev/null 2>&1; then
		printf '{"observed_count":0,"reason":null,"latest":null}\n'
		return 0
	fi

	jq -nc --arg lines "$issue_log_lines" '
		[$lines | split("\n")[]
			| capture("DISPATCH_BLOCK_REASON reason=dirty_worktree_evidence_unavailable evidence_kind=(?<evidence_kind>[A-Za-z0-9_.:-]+) attempted=(?<attempted>true|false|unknown) deferred_by=(?<deferred_by>[A-Za-z0-9_.:-]+) retry_at=(?<retry_at>[A-Za-z0-9_.:-]+) exit_code=(?<exit_code>[0-9]+)")?] as $events
		| {
			observed_count: ($events | length),
			reason: (if ($events | length) > 0 then "dirty_worktree_evidence_unavailable" else null end),
			latest: (($events | last) // null)
		}' 2>/dev/null || printf '{"observed_count":0,"reason":null,"latest":null}\n'
	return 0
}

# Summarise durable zero-attempt releases from the issue audit trail.
# Args: $1=comments_json
# Outputs compact JSON with a total and reason counts.
_issue_zero_attempt_release_summary_json() {
	local comments_json="$1"
	if ! command -v jq >/dev/null 2>&1; then
		printf '{"zero_attempt_release_count":0,"zero_attempt_release_reasons":{}}\n'
		return 0
	fi

	printf '%s' "$comments_json" | jq -c '
		[.[]?
			| (.body // "") as $body
			| select($body | test("CLAIM_RELEASED reason=[A-Za-z0-9_.:-]+"; "i"))
			| select($body | test("session_count=0"; "i"))
			| ($body | capture("CLAIM_RELEASED reason=(?<reason>[A-Za-z0-9_.:-]+)"; "i"))] as $failures
		| {
			zero_attempt_release_count: ($failures | length),
			zero_attempt_release_reasons: (
				reduce $failures[] as $failure ({};
					.[$failure.reason] = ((.[$failure.reason] // 0) + 1))
			)
		}' 2>/dev/null || printf '{"zero_attempt_release_count":0,"zero_attempt_release_reasons":{}}\n'
	return 0
}

# Summarise headless runtime attempts for an issue and project retry/backoff state.
# Args: $1=issue_number $2=metrics_file $3=repo_slug (optional)
# Outputs compact JSON object.
_issue_attempt_summary_json() {
	local issue_number="$1"
	local metrics_file="$2"
	local repo_slug="${3:-}"
	local session_key="issue-${issue_number}"

	if [[ ! -f "$metrics_file" ]] || ! command -v jq >/dev/null 2>&1; then
		printf '{"attempt_count":0,"rate_limit_count":0,"last_attempt_ts":0,"last_rate_limit_ts":0,"cooldown_secs":0,"next_eligible_epoch":0,"backoff_active":false,"results":[],"recent_attempts":[]}\n'
		return 0
	fi

	local summary=""
	summary=$(jq -rs --arg sk "$session_key" --arg issue "$issue_number" --arg repo "$repo_slug" --arg unknown "$_UNKNOWN" '
		def is_issue:
			((.session_key // "") == $sk) or (((.issue_number // "") | tostring) == $issue);
		def is_repo:
			($repo == "") or (((.repo_slug // "") | ascii_downcase) == ($repo | ascii_downcase));
		def is_rate_limit:
			.result == "rate_limit"
			or .result == "rate_limit_fast"
			or .provider_error_type == "rate_limit"
			or ((.provider_status // "") | tostring) == "429";
		[.[] | select(is_issue and is_repo)] as $attempts
		| ($attempts | map(select(is_rate_limit))) as $rl
		| {
			attempt_count: ($attempts | length),
			rate_limit_count: ($rl | length),
			last_attempt_ts: (($attempts | map(.ts // 0) | max) // 0),
			last_rate_limit_ts: (($rl | map(.ts // 0) | max) // 0),
			results: ($attempts | group_by(.result // $unknown) | map({result: (.[0].result // $unknown), count: length}) | sort_by(.result)),
			recent_attempts: ($attempts | sort_by(.ts // 0) | reverse | .[0:5] | map({ts: (.ts // 0), result: (.result // $unknown), failure_reason: (.failure_reason // ""), provider: (.provider // ""), model: (.model // ""), exit_code: (.exit_code // null), repo_slug: (.repo_slug // "")}))
		}
	' "$metrics_file" 2>/dev/null) || summary=""

	if [[ -z "$summary" ]]; then
		printf '{"attempt_count":0,"rate_limit_count":0,"last_attempt_ts":0,"last_rate_limit_ts":0,"cooldown_secs":0,"next_eligible_epoch":0,"backoff_active":false,"results":[],"recent_attempts":[]}\n'
		return 0
	fi

	local rate_limit_count="0" last_rate_limit_ts="0" cooldown_secs="0" next_eligible="0" now_epoch="0" active="$_BOOL_FALSE"
	rate_limit_count=$(printf '%s' "$summary" | jq -r '.rate_limit_count // 0' 2>/dev/null || printf '0')
	last_rate_limit_ts=$(printf '%s' "$summary" | jq -r '.last_rate_limit_ts // 0' 2>/dev/null || printf '0')
	[[ "$rate_limit_count" =~ ^[0-9]+$ ]] || rate_limit_count=0
	[[ "$last_rate_limit_ts" =~ ^[0-9]+$ ]] || last_rate_limit_ts=0
	if [[ "$rate_limit_count" -gt 0 && "$last_rate_limit_ts" -gt 0 ]]; then
		cooldown_secs=$(_diagnose_cooldown_for_rate_limit_count "$rate_limit_count")
		next_eligible=$(( last_rate_limit_ts + cooldown_secs ))
		now_epoch=$(date +%s 2>/dev/null || printf '0')
		[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=0
		if [[ "$now_epoch" -lt "$next_eligible" ]]; then
			active="$_BOOL_TRUE"
		fi
	fi

	printf '%s' "$summary" | jq -c \
		--argjson cooldown "$cooldown_secs" \
		--argjson next "$next_eligible" \
		--argjson active "$active" \
		'. + {cooldown_secs: $cooldown, next_eligible_epoch: $next, backoff_active: $active}' \
		2>/dev/null || printf '%s\n' "$summary"
	return 0
}

# Summarise all retained progress-blocker events for one issue and repository.
# Args: issue_number repo_slug blocker_log
_issue_blocker_summary_json() {
	local issue_number="$1"
	local repo_slug="$2"
	local blocker_log="$3"
	if [[ ! -f "$blocker_log" ]] || ! command -v jq >/dev/null 2>&1; then
		printf '{"event_total":0,"active_total":0,"event_counts":{},"reason_counts":{},"active_blockers":[],"recent_events":[]}'
		return 0
	fi
	jq -Rsc --arg issue "$issue_number" --arg repo "$repo_slug" --arg unknown "$_UNKNOWN" '
		def identity:
			if ((.session_key // "") | length) > 0 then .session_key else (.request_id // $unknown) end;
		[split("\n")[] | fromjson?
			| select(.schema == "aidevops-worker-blocker/v1")
			| select(((.issue_number // "") | tostring) == $issue)
			| select(((.repo_slug // "") | ascii_downcase) == ($repo | ascii_downcase))] as $events
		| ($events | group_by(identity) | map(sort_by(.ts // 0) | last) | map(select(.blocking == true))) as $active
		| {
			event_total: ($events | length),
			active_total: ($active | length),
			event_counts: (reduce $events[] as $row ({}; .[$row.event // $unknown] += 1)),
			reason_counts: (reduce $events[] as $row ({}; .[$row.reason // $unknown] += 1)),
			active_blockers: ($active | sort_by(.ts // 0) | reverse | .[0:10]),
			recent_events: ($events | sort_by(.ts // 0) | reverse | .[0:10])
		}' "$blocker_log" 2>/dev/null || \
		printf '{"event_total":0,"active_total":0,"event_counts":{},"reason_counts":{},"active_blockers":[],"recent_events":[]}'
	return 0
}

# =============================================================================
# Subcommands — cmd_issue (t3258)
#
# Summarises issue-level dispatch and PR lifecycle evidence, collecting:
#   - Issue metadata (labels, state, assignees)
#   - Lifecycle comments (WORKER_BRANCH_ORPHAN, CLAIM_RELEASED, watchdog, etc.)
#   - Linked and worker PRs with pulse log events for each
# =============================================================================

# jq field path constants — centralised to avoid repeated string literals.
readonly _IQ_TITLE=".title"
readonly _IQ_STATE=".state"
readonly _IQ_CREATED=".createdAt"
readonly _IQ_MERGED=".mergedAt"

_CMD_ISSUE_NUMBER=""
_CMD_ISSUE_REPO_SLUG=""
_CMD_ISSUE_VERBOSE=0
_CMD_ISSUE_JSON_OUTPUT=0

# Parse cmd_issue CLI arguments into _CMD_ISSUE_* module globals.
# Returns 1 on validation error.
_cmd_issue_parse_args() {
	_CMD_ISSUE_NUMBER=""
	_CMD_ISSUE_REPO_SLUG=""
	_CMD_ISSUE_VERBOSE=0
	_CMD_ISSUE_JSON_OUTPUT=0

	while [[ $# -gt 0 ]]; do
		case "${1}" in
			--repo)
				_CMD_ISSUE_REPO_SLUG="${2:-}"
				shift 2
				;;
			--verbose)
				_CMD_ISSUE_VERBOSE=1
				shift
				;;
			--json)
				_CMD_ISSUE_JSON_OUTPUT=1
				shift
				;;
			-*)
				print_error "invalid option: ${1}"
				return 1
				;;
			*)
				if [[ -z "$_CMD_ISSUE_NUMBER" ]]; then
					_CMD_ISSUE_NUMBER="${1}"
				fi
				shift
				;;
		esac
	done

	if [[ -z "$_CMD_ISSUE_NUMBER" ]]; then
		print_error "usage: pulse-diagnose-helper.sh issue <N> [--repo <slug>] [--verbose] [--json]"
		return 1
	fi

	if [[ -z "$_CMD_ISSUE_REPO_SLUG" ]]; then
		_CMD_ISSUE_REPO_SLUG=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||; s|\.git$||' || true)
		if [[ -z "$_CMD_ISSUE_REPO_SLUG" ]]; then
			print_error "could not determine repo slug — pass --repo <owner/repo>"
			return 1
		fi
	fi
	return 0
}

# Fetch issue metadata from GitHub API.
# Args: $1 = issue number, $2 = repo slug
# Outputs JSON to stdout.
_fetch_issue_metadata() {
	local issue_number="$1"
	local repo_slug="$2"
	if [[ "${PULSE_DIAGNOSE_GH_OFFLINE:-0}" == "1" ]]; then
		echo "{}"
		return 0
	fi
	if ! command -v gh >/dev/null 2>&1; then
		echo "{}"
		return 0
	fi
	local meta_json
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		meta_json=$(_gh_with_timeout read gh issue view "$issue_number" --repo "$repo_slug" \
			--json number,title,state,author,createdAt,closedAt,closedByPullRequestsReferences,labels,assignees,body 2>/dev/null) || meta_json="{}"
	else
		meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
			--json number,title,state,author,createdAt,closedAt,closedByPullRequestsReferences,labels,assignees,body 2>/dev/null) || meta_json="{}"
	fi
	echo "$meta_json"
	return 0
}

# Fetch issue comments from GitHub REST API.
# Args: $1 = issue number, $2 = repo slug
# Outputs one flattened JSON array to stdout.
_fetch_issue_comments() {
	local issue_number="$1"
	local repo_slug="$2"

	if [[ "${PULSE_DIAGNOSE_GH_OFFLINE:-0}" == "1" ]]; then
		echo "[]"
		return 0
	fi
	if ! command -v gh >/dev/null 2>&1; then
		echo "[]"
		return 0
	fi
	local owner="" repo=""
	owner="${repo_slug%%/*}"
	repo="${repo_slug##*/}"
	local comments_json comments_endpoint="repos/${owner}/${repo}/issues/${issue_number}/comments?per_page=100"
	if command -v jq >/dev/null 2>&1; then
		if declare -F _gh_with_timeout >/dev/null 2>&1; then
			comments_json=$(_gh_with_timeout read gh api "$comments_endpoint" \
				--paginate --slurp 2>/dev/null | jq -c 'add // []') || comments_json="[]"
		else
			comments_json=$(gh api "$comments_endpoint" \
				--paginate --slurp 2>/dev/null | jq -c 'add // []') || comments_json="[]"
		fi
	else
		if declare -F _gh_with_timeout >/dev/null 2>&1; then
			comments_json=$(_gh_with_timeout read gh api "$comments_endpoint" \
				2>/dev/null) || comments_json="[]"
		else
			comments_json=$(gh api "$comments_endpoint" \
				2>/dev/null) || comments_json="[]"
		fi
	fi
	echo "$comments_json"
	return 0
}

# Fetch linked PR numbers for an issue via closing references, timeline
# cross-references, and bounded open-PR metadata filtering.
# Args: $1 = issue number, $2 = repo slug, $3 = issue metadata JSON
# Outputs newline-separated PR numbers to stdout.
_fetch_issue_linked_prs() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_json="$3"

	if [[ "${PULSE_DIAGNOSE_GH_OFFLINE:-0}" == "1" ]]; then
		return 0
	fi
	if ! command -v gh >/dev/null 2>&1; then
		return 0
	fi
	local owner="" repo=""
	owner="${repo_slug%%/*}"
	repo="${repo_slug##*/}"
	# Strategy 1: GitHub's authoritative closing-PR relationship. This survives
	# timeline omissions after an issue has been closed by a merged PR.
	local closing_pr_nums=""
	closing_pr_nums=$(printf '%s' "$issue_json" \
		| jq -r '[.closedByPullRequestsReferences[]?.number | select(type == "number")] | unique | .[]' \
		2>/dev/null) || closing_pr_nums=""
	# Strategy 2: timeline cross-references from PRs that reference this issue
	# (pipe through jq so the gh stub in tests sees raw JSON)
	local xref_nums=""
	xref_nums=$(gh api "repos/${owner}/${repo}/issues/${issue_number}/timeline" \
		--paginate 2>/dev/null \
		| jq -r '[.[] | select(.event == "cross-referenced") | select(.source.issue.pull_request != null) | .source.issue.number] | unique | .[]' \
		2>/dev/null) || xref_nums=""
	# Strategy 3: locally filter one bounded open-PR snapshot (including drafts).
	local branch_prs=""
	branch_prs=$(gh pr list --repo "$repo_slug" --state open \
		--json number,headRefName --limit 100 2>/dev/null \
		| jq -r --arg token "gh${issue_number}" \
			'.[] | select((.headRefName // "") | test("(^|[^[:alnum:]])" + $token + "([^0-9]|$)")) | .number' \
			2>/dev/null) || branch_prs=""

	{ printf '%s\n' "$closing_pr_nums"; printf '%s\n' "$xref_nums"; printf '%s\n' "$branch_prs"; } \
		| grep -E '^[0-9]+$' 2>/dev/null | sort -n | uniq
	return 0
}

# Returns 0 if the comment body contains a lifecycle event marker.
_comment_has_lifecycle_marker() {
	local body="$1"
	printf '%s' "$body" | grep -qE \
		'WORKER_BRANCH_ORPHAN|CLAIM_RELEASED|CLAIM_DEFERRED|[Ww]atchdog|STUCK_WORKER|source:ci-failure|source:conflict-feedback|DISPATCH_CLAIM|worker.kill|WORKER_KILLED|_aborting_dispatch' \
		2>/dev/null
	return $?
}

# Extract up to 2 lines matching lifecycle patterns from a comment body,
# stripping HTML comment blocks, dividers, and signature footer lines.
_lifecycle_comment_excerpt() {
	local body="$1"
	printf '%s' "$body" \
		| grep -v '^<!--' \
		| grep -v '^---' \
		| grep -v 'aidevops\.sh' \
		| grep -E 'WORKER_BRANCH_ORPHAN|CLAIM_RELEASED|CLAIM_DEFERRED|[Ww]atchdog|STUCK_WORKER|source:ci|source:conflict|DISPATCH_CLAIM|worker.kill|WORKER_KILLED|_aborting' \
		| head -2 \
		| sed 's/^[[:space:]]*//'
	return 0
}

# Render lifecycle comments subsection for _render_issue_text.
# Args: $1 = comments_json
_render_issue_lifecycle_comments() {
	local comments_json="$1"
	printf 'Lifecycle comments:\n'
	if ! command -v jq >/dev/null 2>&1; then
		printf '  (jq not available — cannot parse comments)\n\n'
		return 0
	fi
	if [[ -z "$comments_json" || "$comments_json" == "[]" ]]; then
		printf '  (no comments found)\n\n'
		return 0
	fi
	local comment_total="" lc_count=0 i=0
	comment_total=$(printf '%s' "$comments_json" | jq 'length' 2>/dev/null || echo 0)
	[[ "$comment_total" =~ ^[0-9]+$ ]] || comment_total=0
	lc_count=0
	i=0
	while [[ "$i" -lt "$comment_total" ]]; do
		local comment_item="" ts="" author="" body="" excerpt=""
		comment_item=$(printf '%s' "$comments_json" | jq -r ".[$i]" 2>/dev/null) || comment_item="{}"
		ts=$(_jq_field "$comment_item" ".created_at" "")
		author=$(_jq_field "$comment_item" ".user.login" "$_UNKNOWN")
		body=$(_jq_field "$comment_item" ".body" "")
		i=$((i + 1))
		[[ -z "$ts" ]] && continue
		_comment_has_lifecycle_marker "$body" || continue
		lc_count=$((lc_count + 1))
		excerpt=$(_lifecycle_comment_excerpt "$body")
		printf '  %s  %b%s%b\n' "$ts" "$YELLOW" "$author" "$NC"
		[[ -n "$excerpt" ]] && printf '    %s\n' "$excerpt"
	done
	[[ "$lc_count" -eq 0 ]] && printf '  (no lifecycle marker comments found)\n'
	printf '\n'
	return 0
}

# Render linked/worker PRs subsection for _render_issue_text.
# Args: $1=repo_slug $2=pr_numbers $3=logfile $4=logdir $5=verbose
_render_issue_linked_prs() {
	local repo_slug="$1" pr_numbers="$2" logfile="$3" logdir="$4" verbose="$5"
	printf 'Linked/worker PRs:\n'
	local pr_count=0
	while IFS= read -r pr_num; do
		[[ -z "$pr_num" ]] && continue
		pr_count=$((pr_count + 1))
		local pr_json=""
		local pr_title=""
		local pr_state=""
		local pr_head=""
		local pr_merged_at=""
		pr_json=$(_fetch_pr_metadata "$pr_num" "$repo_slug")
		pr_title=$(_jq_field "$pr_json" "$_IQ_TITLE" "")
		pr_state=$(_jq_field "$pr_json" "$_IQ_STATE" "$_UNKNOWN")
		pr_head=$(_jq_field "$pr_json" "$_PR_HEAD_REF_JSON_PATH" "")
		pr_merged_at=$(_jq_field "$pr_json" "$_IQ_MERGED" "")
		printf '  PR #%s  %s  %s\n' "$pr_num" "$pr_state" "${pr_title:-(no title)}"
		[[ -n "$pr_head" ]] && printf '    Branch: %s\n' "$pr_head"
		[[ -n "$pr_merged_at" ]] && printf '    Merged: %s\n' "$pr_merged_at"
		local pr_log_lines="" event_count=0 unclassified_count=0
		pr_log_lines=$(_collect_pr_log_lines "$pr_num" "$logfile" "$logdir")
		event_count=0
		if [[ -n "$pr_log_lines" ]]; then
			while IFS= read -r log_line; do
				[[ -z "$log_line" ]] && continue
				event_count=$((event_count + 1))
				local ts="" classification="" rule_id="" script_name="" line_range="" description=""
				_extract_timestamp "$log_line" ts
				_classify_log_line "$log_line" classification
				IFS='|' read -r rule_id script_name line_range description <<< "$classification"
				[[ "$rule_id" == "$_UNCLASSIFIED" && "$verbose" -ne 1 ]] && { unclassified_count=$((unclassified_count + 1)); continue; }
				printf '    %s  %b%-25s%b  %s\n' \
					"$ts" "$CYAN" "${rule_id:-$_UNCLASSIFIED}" "$NC" "$description"
				[[ "$verbose" -eq 1 ]] && printf '      RAW: %s\n' "$log_line"
			done <<< "$pr_log_lines"
			[[ "$unclassified_count" -gt 0 ]] && printf '    Unclassified pulse events: %d (use --verbose for raw evidence)\n' "$unclassified_count"
			printf '    (%d pulse events)\n' "$event_count"
		else
			printf '    (no pulse log entries for this PR)\n'
		fi
	done <<< "$pr_numbers"
	[[ "$pr_count" -eq 0 ]] && printf '  (no linked or worker PRs found)\n'
	printf '\n'
	return 0
}

# Render repeated worker attempts, pulse dispatch decisions, and retry state.
# Args: $1=attempt_summary_json $2=issue_log_lines $3=verbose
_render_issue_attempts_text() {
	local attempt_summary_json="$1" issue_log_lines="$2" verbose="$3"
	printf 'Repeated attempts / dispatch backoff:\n'
	if ! command -v jq >/dev/null 2>&1; then
		printf '  (jq not available — cannot parse attempt metrics)\n\n'
		return 0
	fi

	local attempt_count="0" rate_limit_count="0" active="$_BOOL_FALSE" cooldown_secs="0" next_epoch="0" prelaunch_count="0"
	local zero_attempt_release_count="0"
	read -r attempt_count rate_limit_count active cooldown_secs next_epoch prelaunch_count zero_attempt_release_count < <(
		printf '%s' "$attempt_summary_json" | jq -r '[.attempt_count // 0, .rate_limit_count // 0, .backoff_active // false, .cooldown_secs // 0, .next_eligible_epoch // 0, .prelaunch_failure_count // 0, .zero_attempt_release_count // 0] | @tsv' || printf '0\t0\tfalse\t0\t0\t0\t0\n'
	)

	printf '  Attempts in metrics: %s (rate-limit-equivalent: %s)\n' "$attempt_count" "$rate_limit_count"
	printf '  Prelaunch failures in pulse log: %s\n' "$prelaunch_count"
	if [[ "$prelaunch_count" =~ ^[0-9]+$ && "$prelaunch_count" -gt 0 ]]; then
		printf '  Prelaunch failure reasons: %s\n' "$(printf '%s' "$attempt_summary_json" | jq -c '.prelaunch_failure_reasons // {}' 2>/dev/null || printf '{}')"
	fi
	printf '  Zero-attempt releases in issue comments: %s\n' "$zero_attempt_release_count"
	if [[ "$zero_attempt_release_count" =~ ^[0-9]+$ && "$zero_attempt_release_count" -gt 0 ]]; then
		printf '  Zero-attempt release reasons: %s\n' "$(printf '%s' "$attempt_summary_json" | jq -c '.zero_attempt_release_reasons // {}' 2>/dev/null || printf '{}')"
	fi
	if [[ "$rate_limit_count" =~ ^[0-9]+$ && "$rate_limit_count" -gt 0 ]]; then
		local next_human=""
		next_human=$(date -r "$next_epoch" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || \
			date -d "@${next_epoch}" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || \
			printf 'epoch:%s' "$next_epoch")
		printf '  Retry/backoff state: active=%s cooldown=%ss next=%s\n' "$active" "$cooldown_secs" "$next_human"
	else
		printf '  Retry/backoff state: clear (no rate-limit-equivalent attempts in metrics)\n'
	fi

	local result_lines=""
	result_lines=$(printf '%s' "$attempt_summary_json" | jq -r --arg unknown "$_UNKNOWN" \
		'.results[]? | "  - " + (.result // $unknown) + ": " + ((.count // 0) | tostring)' 2>/dev/null || true)
	if [[ -n "$result_lines" ]]; then
		printf '  Result counts:\n%s\n' "$result_lines"
	fi

	local recent_lines=""
	recent_lines=$(printf '%s' "$attempt_summary_json" | jq -r --arg unknown "$_UNKNOWN" \
		'.recent_attempts[]? | "  " + ((.ts // 0) | tostring) + "  " + (.result // $unknown) + "  provider=" + (.provider // "") + " model=" + (.model // "") + " reason=" + (.failure_reason // "")' 2>/dev/null || true)
	if [[ -n "$recent_lines" ]]; then
		printf '  Recent attempts:\n%s\n' "$recent_lines"
	fi

	local dispatch_count=0
	if [[ -n "$issue_log_lines" ]]; then
		dispatch_count=$(printf '%s\n' "$issue_log_lines" | grep -c '.' 2>/dev/null || true)
	fi
	[[ "$dispatch_count" =~ ^[0-9]+$ ]] || dispatch_count=0
	printf '  Pulse dispatch/backoff log events: %s\n' "$dispatch_count"
	if [[ "$dispatch_count" -gt 0 ]]; then
		local shown=0
		while IFS= read -r log_line; do
			[[ -z "$log_line" ]] && continue
			shown=$((shown + 1))
			[[ "$shown" -gt 5 ]] && break
			local ts="" summary=""
			ts=$(_extract_timestamp "$log_line")
			summary=$(printf '%s' "$log_line" | sed -E 's/^[0-9TZ: -]+//; s/[[:space:]]+/ /g')
			printf '    %s  %s\n' "$ts" "$summary"
			if [[ "$verbose" -eq 1 ]]; then
				printf '      RAW: %s\n' "$log_line"
			fi
		done <<< "$issue_log_lines"
	fi
	printf '\n'
	return 0
}

# Render bounded progress-blocker evidence for one issue.
# Args: blocker_summary_json
_render_issue_blockers_text() {
	local blocker_summary_json="$1"
	printf 'Worker progress blockers:\n'
	if ! command -v jq >/dev/null 2>&1; then
		printf '  (jq not available — cannot parse blocker records)\n\n'
		return 0
	fi
	local event_total="0" active_total="0"
	event_total=$(printf '%s' "$blocker_summary_json" | jq -r '.event_total // 0' 2>/dev/null || printf '0')
	active_total=$(printf '%s' "$blocker_summary_json" | jq -r '.active_total // 0' 2>/dev/null || printf '0')
	printf '  Retained events: %s\n' "$event_total"
	printf '  Currently active: %s\n' "$active_total"
	printf '  Reasons: %s\n' "$(printf '%s' "$blocker_summary_json" | jq -c '.reason_counts // {}' 2>/dev/null || printf '{}')"
	local recent_lines=""
	recent_lines=$(printf '%s' "$blocker_summary_json" | jq -r --arg unknown "$_UNKNOWN" '
		.recent_events[]?
		| "  " + (.timestamp // ((.ts // 0) | tostring))
		+ "  " + (.event // $unknown)
		+ "  reason=" + (.reason // $unknown)
		+ "  blocking=" + ((.blocking // false) | tostring)
		+ "  source=" + (.source // $unknown)' 2>/dev/null || true)
	if [[ -n "$recent_lines" ]]; then
		printf '  Recent blocker lifecycle:\n%s\n' "$recent_lines"
	else
		printf '  (no blocker records found for this issue)\n'
	fi
	printf '\n'
	return 0
}

# Render dirty-worktree admission evidence separately from worker blockers.
# Args: dirty_worktree_hold_summary_json
_render_issue_dirty_worktree_hold_text() {
	local summary_json="$1"
	local observed_count="0"
	observed_count=$(printf '%s' "$summary_json" | jq -r '.observed_count // 0' 2>/dev/null || printf '0')
	printf 'Dirty-worktree recovery admission:\n'
	printf '  Evidence-unavailable holds observed: %s\n' "$observed_count"
	if [[ "$observed_count" =~ ^[0-9]+$ && "$observed_count" -gt 0 ]]; then
		local details="" reason="" evidence_kind="" attempted="" deferred_by="" retry_at="" exit_code=""
		details=$(printf '%s' "$summary_json" | jq -r --arg unknown "$_UNKNOWN" \
			'[.reason // $unknown, .latest.evidence_kind // $unknown, .latest.attempted // $unknown, .latest.deferred_by // "none", .latest.retry_at // $unknown, .latest.exit_code // "0"] | @tsv' \
			2>/dev/null) || details="${_UNKNOWN}\t${_UNKNOWN}\t${_UNKNOWN}\tnone\t${_UNKNOWN}\t0"
		IFS=$'\t' read -r reason evidence_kind attempted deferred_by retry_at exit_code <<<"$details"
		printf '  Reason: %s\n' "$reason"
		printf '  Evidence kind: %s\n' "$evidence_kind"
		printf '  Request attempted: %s\n' "$attempted"
		printf '  Deferred by: %s\n' "$deferred_by"
		printf '  Retry at: %s\n' "$retry_at"
		printf '  Exit code: %s\n' "$exit_code"
	fi
	printf '\n'
	return 0
}

# Render the current or most recent durable footprint-overlap defer.
# Args: issue_number repo_slug
_render_issue_footprint_defer_text() {
	local issue_number="$1"
	local repo_slug="$2"
	local defer_json='{"active":false,"wake_reason":"unavailable"}'
	if declare -F _footprint_defer_status_json >/dev/null 2>&1; then
		defer_json=$(_footprint_defer_status_json "$issue_number" "$repo_slug")
	fi
	printf 'Footprint overlap defer:\n'
	printf '  Active: %s\n' "$(printf '%s' "$defer_json" | jq -r '.active // false' 2>/dev/null || printf 'false')"
	printf '  Blocking issue: %s\n' "$(printf '%s' "$defer_json" | jq -r 'if .blocking_issue then "#" + (.blocking_issue | tostring) else "none" end' 2>/dev/null || printf 'none')"
	printf '  Suppressed retries: %s\n' "$(printf '%s' "$defer_json" | jq -r '.suppressed_count // 0' 2>/dev/null || printf '0')"
	printf '  Age seconds: %s\n' "$(printf '%s' "$defer_json" | jq -r '.age_seconds // 0' 2>/dev/null || printf '0')"
	printf '  Cooldown remaining seconds: %s\n' "$(printf '%s' "$defer_json" | jq -r '.cooldown_remaining_seconds // 0' 2>/dev/null || printf '0')"
	printf '  Wake reason: %s\n\n' "$(printf '%s' "$defer_json" | jq -r '.wake_reason // "none"' 2>/dev/null || printf 'unavailable')"
	return 0
}

# Render the human-readable issue correlation report.
# Args: issue_number repo_slug issue_json comments_json pr_numbers logfile logdir verbose attempt_summary_json issue_log_lines blocker_summary_json
_render_issue_text() {
	local issue_number="$1" repo_slug="$2" issue_json="$3" comments_json="$4"
	local pr_numbers="$5" logfile="$6" logdir="$7" verbose="$8"
	local attempt_summary_json="$9" issue_log_lines="${10:-}"
	local blocker_summary_json="${11:-}"
	[[ -n "$blocker_summary_json" ]] || blocker_summary_json='{}'

	local title="" state="" created_at="" closed_at="" labels="" assignees=""
	title=$(_jq_field "$issue_json" "$_IQ_TITLE" "")
	state=$(_jq_field "$issue_json" "$_IQ_STATE" "$_UNKNOWN")
	created_at=$(_jq_field "$issue_json" "$_IQ_CREATED" "")
	closed_at=$(_jq_field "$issue_json" ".closedAt" "")
	labels=$(printf '%s' "$issue_json" | jq -r '[.labels[]?.name] | join(", ")' 2>/dev/null || echo "")
	assignees=$(printf '%s' "$issue_json" | jq -r '[.assignees[]?.login] | join(", ")' 2>/dev/null || echo "")

	local closed_suffix=""
	[[ -n "$closed_at" ]] && closed_suffix=" closed:${closed_at}"
	printf '\nIssue #%s (%s%s)\n' "$issue_number" "$state" "$closed_suffix"
	[[ -n "$title" ]] && printf '  Title: %s\n' "$title"
	printf '  Labels: %s\n' "${labels:-(none)}"
	printf '  Assignees: %s\n' "${assignees:-(none)}"
	printf '  Created: %s\n\n' "${created_at:-(unknown)}"

	_render_issue_lifecycle_comments "$comments_json"
	_render_issue_blockers_text "$blocker_summary_json"
	_render_issue_dirty_worktree_hold_text "$(_issue_dirty_worktree_hold_summary_json "$issue_log_lines")"
	_render_issue_footprint_defer_text "$issue_number" "$repo_slug"
	_render_issue_attempts_text "$attempt_summary_json" "$issue_log_lines" "$verbose"
	_render_issue_linked_prs "$repo_slug" "$pr_numbers" "$logfile" "$logdir" "$verbose"
	return 0
}

# Render JSON issue correlation report.
# Args: issue_number repo_slug issue_json comments_json pr_numbers logfile logdir attempt_summary_json issue_log_lines blocker_summary_json
_render_issue_json() {
	local issue_number="$1" repo_slug="$2" issue_json="$3" comments_json="$4"
	local pr_numbers="$5" logfile="$6" logdir="$7" attempt_summary_json="$8" issue_log_lines="${9:-}"
	local blocker_summary_json="${10:-}"
	[[ -n "$blocker_summary_json" ]] || blocker_summary_json='{}'

	local title="" state="" created_at=""
	title=$(_jq_field "$issue_json" "$_IQ_TITLE" "")
	state=$(_jq_field "$issue_json" "$_IQ_STATE" "$_UNKNOWN")
	created_at=$(_jq_field "$issue_json" "$_IQ_CREATED" "")

	printf '{\n'
	_json_num_field "issue_number" "$issue_number"
	_json_str_field "repo"         "$repo_slug"
	_json_str_field "title"        "$(printf '%s' "$title" | sed 's/"/\\"/g')"
	_json_str_field "state"        "$state"
	_json_str_field "created_at"   "$created_at"

	printf '  "lifecycle_comments": [\n'
	local lc_first=1
	if command -v jq >/dev/null 2>&1 && [[ "$comments_json" != "[]" && -n "$comments_json" ]]; then
		local comment_total="" i=0
		comment_total=$(printf '%s' "$comments_json" | jq 'length' 2>/dev/null || echo 0)
		[[ "$comment_total" =~ ^[0-9]+$ ]] || comment_total=0
		i=0
		while [[ "$i" -lt "$comment_total" ]]; do
			local comment_item="" ts="" author="" body=""
			comment_item=$(printf '%s' "$comments_json" | jq -r ".[$i]" 2>/dev/null) || comment_item="{}"
			ts=$(_jq_field "$comment_item" ".created_at" "")
			author=$(_jq_field "$comment_item" ".user.login" "$_UNKNOWN")
			body=$(_jq_field "$comment_item" ".body" "")
			i=$((i + 1))
			[[ -z "$ts" ]] && continue
			_comment_has_lifecycle_marker "$body" || continue
			local excerpt
			excerpt=$(_lifecycle_comment_excerpt "$body" | tr '\n' ' ' | sed 's/"/\\"/g; s/[[:space:]]*$//')
			[[ "$lc_first" -eq 0 ]] && printf ',\n'
			lc_first=0
			printf '    {"ts": "%s", "author": "%s", "excerpt": "%s"}' \
				"$ts" "$author" "${excerpt:-}"
		done
	fi
	printf '\n  ],\n'

	printf '  "repeated_attempts": '
	if command -v jq >/dev/null 2>&1; then
		local dispatch_events_json="[]"
		if [[ -n "$issue_log_lines" ]]; then
			dispatch_events_json=$(printf '%s\n' "$issue_log_lines" | jq -R --arg unknown "$_UNKNOWN" 'select(length > 0) | {ts: ((capture("(?<ts>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z?)")? // {ts: $unknown}) | .ts), line: .}' | jq -s '.' || printf '[]')
		fi
		printf '%s' "$attempt_summary_json" | jq -c --argjson events "$dispatch_events_json" '. + {dispatch_log_events: $events}' 2>/dev/null || printf '{}'
	else
		printf '{}'
	fi
	printf ',\n'
	printf '  "progress_blockers": '
	printf '%s' "$blocker_summary_json" | jq -c '.' 2>/dev/null || printf '{}'
	printf ',\n'
	printf '  "dirty_worktree_hold": '
	_issue_dirty_worktree_hold_summary_json "$issue_log_lines"
	printf ',\n'
	printf '  "footprint_defer": '
	if declare -F _footprint_defer_status_json >/dev/null 2>&1; then
		_footprint_defer_status_json "$issue_number" "$repo_slug"
	else
		printf '{"active":false,"wake_reason":"unavailable"}\n'
	fi
	printf ',\n'

	printf '  "linked_prs": [\n'
	local pr_first=1
	while IFS= read -r pr_num; do
		[[ -z "$pr_num" ]] && continue
		local pr_json=""
		local pr_title=""
		local pr_state=""
		local pr_head=""
		local pr_merged_at=""
		pr_json=$(_fetch_pr_metadata "$pr_num" "$repo_slug")
		pr_title=$(_jq_field "$pr_json" "$_IQ_TITLE" "")
		pr_state=$(_jq_field "$pr_json" "$_IQ_STATE" "$_UNKNOWN")
		pr_head=$(_jq_field "$pr_json" "$_PR_HEAD_REF_JSON_PATH" "")
		pr_merged_at=$(_jq_field "$pr_json" "$_IQ_MERGED" "")
		local pr_log_lines="" pr_event_count=0 raw_count=""
		pr_log_lines=$(_collect_pr_log_lines "$pr_num" "$logfile" "$logdir")
		pr_event_count=0
		if [[ -n "$pr_log_lines" ]]; then
			raw_count=$(printf '%s\n' "$pr_log_lines" | grep -c '.' 2>/dev/null || true)
			[[ "$raw_count" =~ ^[0-9]+$ ]] && pr_event_count="$raw_count"
		fi
		[[ "$pr_first" -eq 0 ]] && printf ',\n'
		pr_first=0
		printf '    {"number": %s, "pr_title": "%s", "pr_state": "%s", "head_ref": "%s", "merged_at": "%s", "pulse_event_count": %d}' \
			"$pr_num" "$(printf '%s' "$pr_title" | sed 's/"/\\"/g')" \
			"$pr_state" "$pr_head" "$pr_merged_at" "$pr_event_count"
	done <<< "$pr_numbers"
	printf '\n  ]\n'
	printf '}\n'
	return 0
}

cmd_issue() {
	_cmd_issue_parse_args "$@" || return 1

	local logfile="" logdir=""
	logfile=$(_resolve_logfile "")
	logdir=$(_resolve_logdir)
	local metrics_file=""
	metrics_file=$(_resolve_metrics_file)

	local issue_json="" comments_json="" pr_numbers="" attempt_summary_json="" issue_log_lines="" blocker_summary_json=""
	local prelaunch_summary_json="" zero_attempt_summary_json=""
	local blocker_log=""
	blocker_log=$(_resolve_blocker_log)
	issue_json=$(_fetch_issue_metadata "$_CMD_ISSUE_NUMBER" "$_CMD_ISSUE_REPO_SLUG")
	comments_json=$(_fetch_issue_comments "$_CMD_ISSUE_NUMBER" "$_CMD_ISSUE_REPO_SLUG")
	pr_numbers=$(_fetch_issue_linked_prs "$_CMD_ISSUE_NUMBER" "$_CMD_ISSUE_REPO_SLUG" "$issue_json")
	attempt_summary_json=$(_issue_attempt_summary_json "$_CMD_ISSUE_NUMBER" "$metrics_file" "$_CMD_ISSUE_REPO_SLUG")
	issue_log_lines=$(_collect_issue_log_lines "$_CMD_ISSUE_NUMBER" "$logfile" "$logdir")
	prelaunch_summary_json=$(_issue_prelaunch_failure_summary_json "$issue_log_lines")
	zero_attempt_summary_json=$(_issue_zero_attempt_release_summary_json "$comments_json")
	if command -v jq >/dev/null 2>&1; then
		attempt_summary_json=$(jq -nc \
			--argjson attempts "$attempt_summary_json" \
			--argjson prelaunch "$prelaunch_summary_json" \
			--argjson zero_attempt "$zero_attempt_summary_json" \
			'$attempts + $prelaunch + $zero_attempt' 2>/dev/null) || return 1
	fi
	blocker_summary_json=$(_issue_blocker_summary_json "$_CMD_ISSUE_NUMBER" "$_CMD_ISSUE_REPO_SLUG" "$blocker_log")

	if [[ "$_CMD_ISSUE_JSON_OUTPUT" -eq 1 ]]; then
		_render_issue_json "$_CMD_ISSUE_NUMBER" "$_CMD_ISSUE_REPO_SLUG" \
			"$issue_json" "$comments_json" "$pr_numbers" "$logfile" "$logdir" \
			"$attempt_summary_json" "$issue_log_lines" "$blocker_summary_json"
		return 0
	fi

	_render_issue_text "$_CMD_ISSUE_NUMBER" "$_CMD_ISSUE_REPO_SLUG" \
		"$issue_json" "$comments_json" "$pr_numbers" "$logfile" "$logdir" \
		"$_CMD_ISSUE_VERBOSE" "$attempt_summary_json" "$issue_log_lines" "$blocker_summary_json"
	return 0
}
