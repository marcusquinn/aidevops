#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-dispatch-current-state-guardrails.sh -- Current-state dispatch caps.
# =============================================================================

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_DISPATCH_CURRENT_STATE_GUARDRAILS_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_CURRENT_STATE_GUARDRAILS_LOADED=1

_dispatch_review_repair_issue_body() {
	local repo_slug="$1"
	local issue_number="$2"
	if declare -F gh_issue_view >/dev/null 2>&1; then
		gh_issue_view "$issue_number" --repo "$repo_slug" --json body --jq '.body'
		return $?
	fi
	gh issue view "$issue_number" --repo "$repo_slug" --json body --jq '.body'
	return $?
}

_dispatch_review_repair_pr_json() {
	local repo_slug="$1"
	local pr_number="$2"
	if declare -F gh_pr_view >/dev/null 2>&1; then
		gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json state,headRefOid,labels,closingIssuesReferences
		return $?
	fi
	gh pr view "$pr_number" --repo "$repo_slug" \
		--json state,headRefOid,labels,closingIssuesReferences
	return $?
}

_dispatch_review_repair_live_evidence_fingerprint() {
	local repo_slug="$1"
	local pr_number="$2"
	declare -F _review_feedback_fetch_evidence >/dev/null 2>&1 || return 1
	declare -F _review_feedback_evidence_fingerprint >/dev/null 2>&1 || return 1
	_review_feedback_fetch_evidence "$pr_number" "$repo_slug" || return 1
	_review_feedback_evidence_fingerprint \
		"$_PULSE_REVIEW_FEEDBACK_REVIEWS_JSON" "$_PULSE_REVIEW_FEEDBACK_INLINE_JSON"
	return $?
}

#######################################
# Verify that review-repair provenance is bound to a closed PR generation and
# to the candidate issue. Labels or issue text alone never grant an exemption.
#
# Args:
#   $1 - repository slug
#   $2 - issue number
# Returns: 0 only for verified head-bound review repair provenance.
#######################################
_dispatch_review_repair_candidate_is_verified() {
	local repo_slug="$1"
	local issue_number="$2"
	local issue_body="" marker_json="" pr_number="" expected_head="" expected_evidence=""
	local live_evidence="" pr_json=""
	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1

	issue_body=$(_dispatch_review_repair_issue_body "$repo_slug" "$issue_number" 2>/dev/null) || return 1
	marker_json=$(jq -Rn --arg body "$issue_body" '
		[$body | scan("<!-- feedback-route:complete:review:PR([0-9]+):SHA([0-9A-Za-z]{7,64}):EVIDENCE([0-9a-f]{64}) -->")]
		| last // empty
	' 2>/dev/null) || return 1
	pr_number=$(jq -r '.[0] // empty' <<<"$marker_json" 2>/dev/null) || return 1
	expected_head=$(jq -r '.[1] // empty' <<<"$marker_json" 2>/dev/null) || return 1
	expected_evidence=$(jq -r '.[2] // empty' <<<"$marker_json" 2>/dev/null) || return 1
	[[ "$pr_number" =~ ^[0-9]+$ && "$expected_head" =~ ^[0-9A-Za-z]{7,64}$ \
		&& "$expected_evidence" =~ ^[0-9a-f]{64}$ ]] || return 1
	live_evidence=$(_dispatch_review_repair_live_evidence_fingerprint "$repo_slug" "$pr_number" 2>/dev/null) || return 1
	[[ "$live_evidence" == "$expected_evidence" ]] || return 1

	pr_json=$(_dispatch_review_repair_pr_json "$repo_slug" "$pr_number" 2>/dev/null) || return 1
	jq -e --arg expected_head "$expected_head" --arg repo_slug "$repo_slug" \
		--argjson issue_number "$issue_number" '
		.state == "CLOSED"
		and .headRefOid == $expected_head
		and any(.labels[]?; (.name // .) == "review-routed-to-issue")
		and any(.closingIssuesReferences[]?;
			.number == $issue_number
			and (
				(.repository.nameWithOwner // "") == $repo_slug
				or (((.repository.owner.login // "") + "/" + (.repository.name // "")) == $repo_slug)
			)
		)
	' <<<"$pr_json" >/dev/null 2>&1
	return $?
}

#######################################
# Resolve the open-PR backlog threshold for one repository.
# Precedence: repos.json `dispatch_open_pr_threshold` for the slug, then
# PULSE_DISPATCH_GUARDRAIL_OPEN_PR_THRESHOLD, then 12. 0 disables the guardrail.
#
# Args:
#   $1 - repository slug
# Stdout: non-negative integer threshold.
#######################################
_dispatch_repo_pr_backlog_threshold() {
	local repo_slug="$1"
	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local threshold=""
	if [[ -f "$repos_json" ]] && command -v jq >/dev/null 2>&1; then
		threshold=$(jq -r --arg slug "$repo_slug" '
			first(.initialized_repos[]? | select(.slug == $slug)
				| .dispatch_open_pr_threshold // empty) // empty
		' "$repos_json" 2>/dev/null) || threshold=""
	fi
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold="${PULSE_DISPATCH_GUARDRAIL_OPEN_PR_THRESHOLD:-12}"
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=12
	printf '%s\n' "$threshold"
	return 0
}

#######################################
# Emit the permanent t2449 block markers for one repository as a JSON object
# {"<pr_number>": "<head_sha>"} (GH#38496). The merge pass writes one marker per
# PR (pulse-merge-process-worker-briefed.sh::_worker_briefed_sync_permanent_block_marker)
# as "<head>\t<class>\t<epoch>"; keep the directory and naming in sync. Markers
# older than PULSE_T2449_BLOCK_MARKER_TTL (default 7200s) are ignored so a PR
# the merge pass has stopped re-evaluating counts again.
#
# Args: $1 - repository slug
# Stdout: JSON object (empty object when none or on any error).
#######################################
_dispatch_repo_t2449_permanent_block_heads() {
	local repo_slug="$1"
	local state_dir="${PULSE_T2449_BLOCK_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/pulse-t2449-permanent-blocks}"
	local ttl="${PULSE_T2449_BLOCK_MARKER_TTL:-7200}"
	local marker="" pr_number="" head_sha="" block_class="" recorded_at="" now="" result="{}"
	[[ "$ttl" =~ ^[1-9][0-9]*$ ]] || ttl=7200
	if [[ ! "$repo_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ || ! -d "$state_dir" ]]; then
		printf '%s\n' "$result"
		return 0
	fi
	now=$(date +%s)
	for marker in "${state_dir}/${repo_slug%%/*}--${repo_slug##*/}--pr-"*; do
		[[ -f "$marker" && ! -L "$marker" ]] || continue
		pr_number="${marker##*--pr-}"
		[[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || continue
		head_sha="" block_class="" recorded_at=""
		IFS=$'\t' read -r head_sha block_class recorded_at <"$marker" || true
		[[ "$head_sha" =~ ^[0-9a-f]{40}$ && -n "$block_class" && "$recorded_at" =~ ^[0-9]+$ ]] || continue
		((now - recorded_at < ttl)) || continue
		result=$(jq -c --arg pr "$pr_number" --arg head "$head_sha" '. + {($pr): $head}' <<<"$result" 2>/dev/null) || result="{}"
	done
	printf '%s\n' "$result"
	return 0
}

# jq definitions shared by the guardrail count and its merge-priority marker
# (GH#38508), so both always select the same ready worker PRs.
# shellcheck disable=SC2016 # jq program text; $labels etc. are jq variables.
_DISPATCH_READY_WORKER_PR_JQ_DEFS='
	def ready_worker_pr:
		(.isDraft // false) != true
		and (((.labels // []) | map(.name? // .)) as $labels
			| (($labels | index("origin:worker")) != null
				or ($labels | index("origin:worker-takeover")) != null)
			and ($labels | index("hold-for-review")) == null
			and ($labels | index("needs-maintainer-review")) == null);
	def t2449_marked($blocked):
		(.headRefOid // "") as $head
		| ($blocked[(.number | tostring)] // "") as $marked
		| ($head != "" and $marked == $head);
'

#######################################
# Record the ready worker PRs an applied backlog guardrail counted (GH#38508).
# The next deterministic merge pass reads this marker
# (pulse-merge-backlog.sh::_pmp_guardrail_counted_pr_keys; keep the directory,
# file name and "<epoch>\t|<n>|<n>|" format in sync) and evaluates those PRs
# first, so the backlog that suppresses dispatch drains before other work.
# Permanently t2449-blocked PRs are left out: pulse cannot merge them.
# Ordering only: the merge pass still enforces every merge gate.
#
# Args: $1 - repository slug, $2 - PR list JSON the guardrail counted
#######################################
_dispatch_record_pr_backlog_guardrail_marker() {
	local repo_slug="$1"
	local pr_json="$2"
	local state_dir="${PULSE_PR_BACKLOG_GUARDRAIL_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/pulse-pr-backlog-guardrail}"
	local blocked_heads="{}" numbers="" marker="" tmp_marker=""
	[[ "$repo_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 0
	blocked_heads=$(_dispatch_repo_t2449_permanent_block_heads "$repo_slug") || blocked_heads="{}"
	numbers=$(jq -r --argjson blocked "$blocked_heads" "${_DISPATCH_READY_WORKER_PR_JQ_DEFS}"'
		if type == "array" then
			[.[] | select(ready_worker_pr) | select(t2449_marked($blocked) | not)
				| .number | select(type == "number" and . >= 1) | tostring]
			| if length > 0 then "|" + join("|") + "|" else "" end
		else "" end
	' <<<"$pr_json" 2>/dev/null) || numbers=""
	[[ "$numbers" =~ ^\|([1-9][0-9]*\|)+$ ]] || return 0
	mkdir -p "$state_dir" 2>/dev/null || return 0
	marker="${state_dir}/${repo_slug%%/*}--${repo_slug##*/}"
	tmp_marker=$(mktemp "${marker}.XXXXXX" 2>/dev/null) || return 0
	if printf '%s\t%s\n' "$(date +%s)" "$numbers" >"$tmp_marker" 2>/dev/null && mv -f "$tmp_marker" "$marker" 2>/dev/null; then
		return 0
	fi
	rm -f "$tmp_marker" 2>/dev/null || true
	return 0
}

#######################################
# Count one open-PR listing for the backlog guardrail: all listed PRs, ready
# worker PRs (non-draft origin:worker/origin:worker-takeover without
# hold-for-review/needs-maintainer-review, GH#33727), and the subset marked
# permanently t2449-blocked at their listed head (GH#38496). A missing head or
# a new push keeps a marked PR counted. A full page may hide unmarked worker
# PRs beyond fetch_limit, so exclusions are dropped (fail closed) when the
# listing may be truncated.
#
# Args: $1 - repository slug, $2 - PR list JSON, $3 - fetch limit
# Stdout: "<open_prs_total> <ready_worker_prs> <t2449_excluded>".
#######################################
_dispatch_repo_pr_backlog_counts() {
	local repo_slug="$1"
	local pr_json="$2"
	local fetch_limit="$3"
	local blocked_heads="{}" counts="" open_prs_total=0 ready_worker_prs=0 t2449_excluded=0
	blocked_heads=$(_dispatch_repo_t2449_permanent_block_heads "$repo_slug") || blocked_heads="{}"
	counts=$(jq -r --argjson blocked "$blocked_heads" "${_DISPATCH_READY_WORKER_PR_JQ_DEFS}"'
		if type == "array" then
			length as $total
			| [.[] | select(ready_worker_pr) | t2449_marked($blocked)]
			| "\($total) \(length) \(map(select(.)) | length)"
		else "0 0 0" end
	' <<<"$pr_json" 2>/dev/null) || counts=""
	read -r open_prs_total ready_worker_prs t2449_excluded <<<"$counts"
	[[ "$open_prs_total" =~ ^[0-9]+$ ]] || open_prs_total=0
	[[ "$ready_worker_prs" =~ ^[0-9]+$ ]] || ready_worker_prs=0
	[[ "$t2449_excluded" =~ ^[0-9]+$ ]] || t2449_excluded=0
	[[ "$fetch_limit" =~ ^[0-9]+$ ]] || fetch_limit=0
	((open_prs_total < fetch_limit)) || t2449_excluded=0
	printf '%s %s %s\n' "$open_prs_total" "$ready_worker_prs" "$t2449_excluded"
	return 0
}

#######################################
# Filter ordinary candidates when their repository has reached its open-PR cap.
# Only merge backlog that workers create and pulse can move counts toward the
# cap: non-draft PRs labelled origin:worker/origin:worker-takeover without a
# hold-for-review/needs-maintainer-review hold. Interactive PRs and drafts
# cannot be reduced by dispatching fewer workers, so they never starve dispatch
# (GH#33727). Worker PRs the merge pass marked permanently t2449-blocked at
# their current head cannot be merged by pulse either, so they are excluded
# and reported as t2449_blocked_excluded (GH#38496); transient blocks count.
#
# Args:
#   $1 - repository slug
#   $2 - candidate JSON array
# Stdout: filtered candidate JSON array.
#######################################
_dispatch_filter_repo_pr_backlog_candidates() {
	local repo_slug="$1"
	local candidates_json="$2"
	local pr_threshold=""
	pr_threshold=$(_dispatch_repo_pr_backlog_threshold "$repo_slug") || pr_threshold=12
	[[ "$pr_threshold" =~ ^[0-9]+$ ]] || pr_threshold=12
	if [[ "$pr_threshold" -eq 0 ]] || ! command -v jq >/dev/null 2>&1 || ! declare -F pulse_pr_list_get >/dev/null 2>&1; then
		printf '%s\n' "$candidates_json"
		return 0
	fi

	local fetch_limit="${PULSE_DISPATCH_GUARDRAIL_OPEN_PR_FETCH_LIMIT:-200}"
	[[ "$fetch_limit" =~ ^[1-9][0-9]*$ ]] || fetch_limit=200
	((fetch_limit >= pr_threshold)) || fetch_limit="$pr_threshold"

	local pr_json="" open_prs_total=0 open_prs=0 filtered_json="" candidate_count=0 filtered_count=0
	# Bound the snapshot age independent of the per-cycle 3600s caches: elastic
	# cycles outlive that TTL while other runners keep merging (GH#37918). Both
	# cache layers read their TTL from these variables at call time; the scoped
	# override affects only this read. Local invalidation-after-merge is unchanged.
	local max_age="${PULSE_DISPATCH_GUARDRAIL_PR_LIST_MAX_AGE:-120}"
	[[ "$max_age" =~ ^[1-9][0-9]*$ ]] || max_age=120
	pr_json=$(PULSE_PR_LIST_PROVIDER_CACHE_TTL="$max_age" AIDEVOPS_GH_PR_LIST_CACHE_TTL="$max_age" \
		pulse_pr_list_get --repo "$repo_slug" --state open --json number,isDraft,labels,headRefOid --limit "$fetch_limit" 2>/dev/null) || {
		printf '%s\n' "$candidates_json"
		return 0
	}
	local ready_worker_prs=0 t2449_excluded=0 counts=""
	counts=$(_dispatch_repo_pr_backlog_counts "$repo_slug" "$pr_json" "$fetch_limit") || counts=""
	read -r open_prs_total ready_worker_prs t2449_excluded <<<"$counts"
	[[ "$open_prs_total" =~ ^[0-9]+$ ]] || open_prs_total=0
	[[ "$ready_worker_prs" =~ ^[0-9]+$ ]] || ready_worker_prs=0
	[[ "$t2449_excluded" =~ ^[0-9]+$ && "$t2449_excluded" -le "$ready_worker_prs" ]] || t2449_excluded=0
	open_prs=$((ready_worker_prs - t2449_excluded))
	if ((open_prs < pr_threshold)); then
		if ((open_prs_total >= pr_threshold)); then
			# Make the excluded draft/interactive/held backlog visible: these PRs
			# would have tripped the pre-GH#33727 all-PR count.
			local not_applied_reason="draft_interactive_or_held_prs_excluded"
			((ready_worker_prs < pr_threshold)) || not_applied_reason="t2449_blocked_prs_excluded"
			echo "[pulse-wrapper] Repository PR backlog guardrail not applied: repo=${repo_slug} open_prs_total=${open_prs_total} open_prs_counted=${open_prs} threshold=${pr_threshold} reason=${not_applied_reason} t2449_blocked_excluded=${t2449_excluded}" >>"${LOGFILE:-/dev/null}"
		fi
		printf '%s\n' "$candidates_json"
		return 0
	fi

	filtered_json=$(jq -c '[.[] | select(
		((.labels // []) | map(.name? // .)) as $labels |
		# Feedback finalization verifies the source PR head and closes that PR
		# before these candidates are redispatched. CI/conflict candidates therefore
		# repair an existing PR lineage instead of adding ordinary backlog.
		(($labels | index("quality-debt")) != null and ($labels | index("source:review-feedback")) != null)
		or ($labels | index("source:ci-feedback")) != null
		or ($labels | index("source:conflict-feedback")) != null
	)]' <<<"$candidates_json" 2>/dev/null) || filtered_json='[]'

	local repair_candidates="" repair_candidate="" repair_issue=""
	repair_candidates=$(jq -c '.[] |
		((.labels // []) | map(.name? // .)) as $labels |
		select(
			($labels | index("source:review-repair")) != null
			and ((($labels | index("quality-debt")) != null and ($labels | index("source:review-feedback")) != null) | not)
			and (($labels | index("source:ci-feedback")) == null)
			and (($labels | index("source:conflict-feedback")) == null)
		)
	' <<<"$candidates_json" 2>/dev/null) || repair_candidates=""
	while IFS= read -r repair_candidate; do
		[[ -n "$repair_candidate" ]] || continue
		repair_issue=$(jq -r '.number // empty' <<<"$repair_candidate" 2>/dev/null) || continue
		if _dispatch_review_repair_candidate_is_verified "$repo_slug" "$repair_issue"; then
			filtered_json=$(jq -cn --argjson current "$filtered_json" --argjson candidate "$repair_candidate" \
				'$current + [$candidate]' 2>/dev/null) || true
		fi
	done <<<"$repair_candidates"
	candidate_count=$(jq 'length' <<<"$candidates_json" 2>/dev/null) || candidate_count=0
	filtered_count=$(jq 'length' <<<"$filtered_json" 2>/dev/null) || filtered_count="$candidate_count"
	echo "[pulse-wrapper] Repository PR backlog guardrail: repo=${repo_slug} open_prs_total=${open_prs_total} open_prs_counted=${open_prs} threshold=${pr_threshold} ordinary_candidates_suppressed=$((candidate_count - filtered_count)) exempt_candidates=${filtered_count} t2449_blocked_excluded=${t2449_excluded}" >>"$LOGFILE"
	_dispatch_stats_increment "pulse_dispatch_repo_pr_backlog_guardrail_applied"
	_dispatch_record_pr_backlog_guardrail_marker "$repo_slug" "$pr_json"
	printf '%s\n' "$filtered_json"
	return 0
}

#######################################
# Count recent terminal worker-role signals that should shape launch capacity.
#
# Stdout: "<successes> <failures> <rate_limits> <no_dispatchable>".
#######################################
_dispatch_recent_current_state_counts() {
	local override_line="${PULSE_DISPATCH_CURRENT_STATE_COUNTS:-}"
	if [[ -n "$override_line" ]]; then
		printf '%s\n' "$override_line"
		return 0
	fi

	local metrics_file="${AIDEVOPS_HEADLESS_METRICS_FILE:-${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl}"
	local evidence_file="${AIDEVOPS_OBJECTIVE_EVIDENCE_FILE:-${HOME}/.aidevops/state/objective-evidence.jsonl}"
	local evidence_limit="${AIDEVOPS_OBJECTIVE_EVIDENCE_LIMIT:-2000}"
	local window_seconds="${PULSE_DISPATCH_CURRENT_STATE_WINDOW_SECONDS:-900}"
	local health_helper="${BASH_SOURCE[0]%/*}/worker-terminal-health.py"
	[[ "$window_seconds" =~ ^[0-9]+$ ]] || window_seconds=900
	[[ "$evidence_limit" =~ ^[1-9][0-9]*$ ]] || evidence_limit=2000
	local health_counts="" successes="" failures="" rate_limits="" service_interruptions="" provider_5xx="" progress=""
	health_counts=$(python3 "$health_helper" "$metrics_file" "$evidence_file" "$window_seconds" "$evidence_limit") || health_counts="0 6 0 0 0 0"
	read -r successes failures rate_limits service_interruptions provider_5xx progress <<<"$health_counts"

	local no_dispatchable=""
	no_dispatchable=$(python3 - "${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}" <<'PY'
import sys
from collections import deque

no_dispatchable = 0
try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as handle:
        lines = deque(handle, 2000)
    for raw in lines:
        line = raw.lower()
        if "no ranked candidates" in line or "no eligible candidates" in line or "no dispatchable" in line:
            no_dispatchable += 1
except OSError:
    pass

print(no_dispatchable)
PY
	) || no_dispatchable=0
	printf '%s %s %s %s\n' "$successes" "$failures" "$rate_limits" "$no_dispatchable"
	return 0
}

#######################################
# Apply current-state guardrails to available worker slots.
#
# Args:
#   $1 - max workers
#   $2 - active workers
#   $3 - available slots
#   $4 - minimum worker floor active (1=yes, optional)
# Stdout: "<max_workers> <active_workers> <available_slots>" after capping.
#######################################
_dispatch_apply_current_state_guardrails() {
	local max_workers="$1"
	local active_workers="$2"
	local available_slots="$3"
	local min_worker_floor_active="${4:-0}"
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	[[ "$available_slots" =~ ^-?[0-9]+$ ]] || available_slots=0
	[[ "$min_worker_floor_active" =~ ^[0-9]+$ ]] || min_worker_floor_active=0

	if [[ "${AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS:-0}" == "1" || "$available_slots" -le 0 ]]; then
		_dispatch_stats_gauge "pulse_dispatch_guardrail_available_slots" "$available_slots"
		printf '%s %s %s\n' "$max_workers" "$active_workers" "$available_slots"
		return 0
	fi

	local counts_line="" successes="" failures="" rate_limits="" no_dispatchable=""
	counts_line=$(_dispatch_recent_current_state_counts) || counts_line="0 0 0 0"
	read -r successes failures rate_limits no_dispatchable <<<"$counts_line"
	[[ "$successes" =~ ^[0-9]+$ ]] || successes=0
	[[ "$failures" =~ ^[0-9]+$ ]] || failures=0
	[[ "$rate_limits" =~ ^[0-9]+$ ]] || rate_limits=0
	[[ "$no_dispatchable" =~ ^[0-9]+$ ]] || no_dispatchable=0
	_dispatch_stats_gauge "pulse_dispatch_guardrail_successes" "$successes"
	_dispatch_stats_gauge "pulse_dispatch_guardrail_failures" "$failures"
	_dispatch_stats_gauge "pulse_dispatch_guardrail_worker_terminal_failures" "$failures"
	_dispatch_stats_gauge "pulse_dispatch_guardrail_rate_limits" "$rate_limits"
	_dispatch_stats_gauge "pulse_dispatch_guardrail_no_dispatchable" "$no_dispatchable"

	local rl_threshold="${PULSE_DISPATCH_GUARDRAIL_RATE_LIMIT_THRESHOLD:-4}"
	local failure_threshold="${PULSE_DISPATCH_GUARDRAIL_FAILURE_THRESHOLD:-6}"
	local empty_threshold="${PULSE_DISPATCH_GUARDRAIL_NO_DISPATCHABLE_THRESHOLD:-2}"
	[[ "$rl_threshold" =~ ^[0-9]+$ ]] || rl_threshold=4
	[[ "$failure_threshold" =~ ^[0-9]+$ ]] || failure_threshold=6
	[[ "$empty_threshold" =~ ^[0-9]+$ ]] || empty_threshold=2

	local capped_slots="$available_slots" reason=""
	if ((empty_threshold > 0 && no_dispatchable >= empty_threshold && successes == 0 && min_worker_floor_active > 0)); then
		# Stale empty-candidate evidence must not self-lock the configured worker
		# floor. The candidate loop still re-checks eligibility and stops on a true
		# empty queue, but floor repair needs enough slots to test currently
		# dispatchable work instead of a single stale probe.
		reason="no_dispatchable_floor_bypass"
		_dispatch_stats_increment "pulse_dispatch_current_state_guardrail_floor_bypass"
	elif ((empty_threshold > 0 && no_dispatchable >= empty_threshold && successes == 0)); then
		# Keep one probe slot alive. Otherwise stale "no dispatchable" evidence can
		# self-lock the refill loop just as new review/conflict work becomes eligible.
		capped_slots=1
		reason="no_dispatchable_evidence"
	elif ((rl_threshold > 0 && rate_limits >= rl_threshold && successes == 0)); then
		capped_slots=0
		reason="provider_rate_limit_pressure"
	elif ((rl_threshold > 0 && rate_limits >= rl_threshold && capped_slots > 1)); then
		capped_slots=1
		reason="provider_rate_limit_pressure"
	elif ((failure_threshold > 0 && failures >= failure_threshold && successes == 0)); then
		capped_slots=0
		reason="repeated_failure_pressure"
	elif ((failure_threshold > 0 && failures >= failure_threshold && capped_slots > 1)); then
		capped_slots=1
		reason="repeated_failure_pressure"
	fi

	if ((capped_slots < available_slots)); then
		max_workers=$((active_workers + capped_slots))
		echo "[pulse-wrapper] Dispatch current-state guardrail: reason=${reason} capacity_unit=simultaneous_workers capped_available=${capped_slots}/${available_slots} worker_terminal_successes=${successes} worker_terminal_failures=${failures} worker_rate_limits=${rate_limits} failure_observation_window_seconds=${PULSE_DISPATCH_CURRENT_STATE_WINDOW_SECONDS:-900} task_duration_limit=none no_dispatchable=${no_dispatchable} min_worker_floor_active=${min_worker_floor_active}" >>"$LOGFILE"
		_dispatch_stats_increment "pulse_dispatch_current_state_guardrail_applied"
		_dispatch_stats_increment_candidate_failed "$reason"
	elif [[ "$reason" == "no_dispatchable_floor_bypass" ]]; then
		echo "[pulse-wrapper] Dispatch current-state guardrail: reason=${reason} capacity_unit=simultaneous_workers preserved_available=${available_slots} worker_terminal_successes=${successes} worker_terminal_failures=${failures} worker_rate_limits=${rate_limits} failure_observation_window_seconds=${PULSE_DISPATCH_CURRENT_STATE_WINDOW_SECONDS:-900} task_duration_limit=none no_dispatchable=${no_dispatchable} min_worker_floor_active=${min_worker_floor_active}" >>"$LOGFILE"
	fi
	_dispatch_stats_gauge "pulse_dispatch_guardrail_available_slots" "$capped_slots"

	printf '%s %s %s\n' "$max_workers" "$active_workers" "$capped_slots"
	return 0
}
