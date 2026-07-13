#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-required-checks.sh — required-check terminal-state classifiers.

[[ -n "${_PULSE_MERGE_REQUIRED_CHECKS_LOADED:-}" ]] && return 0
_PULSE_MERGE_REQUIRED_CHECKS_LOADED=1
PMRC_CHECK_COMPLETED="completed"
PMRC_CHECK_SUCCESS="success"

_pmrc_gh_read() {
	local rc=0
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read "$@" || rc=$?
	else
		"$@" || rc=$?
	fi
	return "$rc"
}

_pmrc_iso_to_epoch() {
	local iso="$1"
	local epoch=""
	[[ -n "$iso" ]] || return 1
	epoch=$(date -u -d "$iso" +%s 2>/dev/null \
		|| TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null) || epoch=""
	[[ "$epoch" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$epoch"
	return 0
}

_pmrc_snapshot_checks_json() {
	local repo_slug="$1"
	local head_sha="$2"
	local runs_pages="" statuses_json="" checks_json=""

	runs_pages=$(_pmrc_gh_read gh api "repos/${repo_slug}/commits/${head_sha}/check-runs?per_page=100" \
		--paginate --slurp 2>/dev/null) || return 1
	statuses_json=$(_pmrc_gh_read gh api "repos/${repo_slug}/commits/${head_sha}/status" 2>/dev/null) || return 1
	checks_json=$(jq -n --argjson pages "$runs_pages" --argjson statuses "$statuses_json" \
		--arg completed "$PMRC_CHECK_COMPLETED" --arg success "$PMRC_CHECK_SUCCESS" '
		"pending" as $pending | "in_progress" as $in_progress |
		"failure" as $failure | "error" as $error |
		[
			$pages[]?.check_runs[]? | {
				name: (.name // ""),
				status: ((.status // "") | ascii_downcase),
				conclusion: ((.conclusion // "") | ascii_downcase),
				observed_at: (.completed_at // .started_at // "")
			}
		] + [
			$statuses.statuses[]? | ((.state // "") | ascii_downcase) as $state | {
				name: (.context // ""),
				status: (if $state == $pending then $in_progress else $completed end),
				conclusion: (if $state == $success then $success elif ($state == $failure or $state == $error) then $failure else "" end),
				observed_at: (.updated_at // .created_at // "")
			}
		]
		| map(select(.name != ""))
		| sort_by(.name, .observed_at)
		| group_by(.name)
		| map(last)
	' 2>/dev/null) || return 1
	printf '%s\n' "$checks_json"
	return 0
}

_pmrc_snapshot_bot_activity_json() {
	local repo_slug="$1"
	local pr_number="$2"
	local reviews="" issue_comments="" inline_comments="" activity=""
	local bot_re="coderabbitai|gemini-code-assist|augment-code|augmentcode|copilot"

	reviews=$(_pmrc_gh_read gh api "repos/${repo_slug}/pulls/${pr_number}/reviews?per_page=100" \
		--paginate --slurp 2>/dev/null) || return 1
	issue_comments=$(_pmrc_gh_read gh api "repos/${repo_slug}/issues/${pr_number}/comments?per_page=100" \
		--paginate --slurp 2>/dev/null) || return 1
	inline_comments=$(_pmrc_gh_read gh api "repos/${repo_slug}/pulls/${pr_number}/comments?per_page=100" \
		--paginate --slurp 2>/dev/null) || return 1
	activity=$(jq -n --argjson reviews "$reviews" --argjson issues "$issue_comments" \
		--argjson inline "$inline_comments" --arg bots "$bot_re" '
		[
			$reviews[][]?, $issues[][]?, $inline[][]?
			| select((.user.login // "") | test($bots; "i"))
			| (.updated_at // .submitted_at // .created_at // "")
			| select(. != "")
		] as $events
		| {count: ($events | length), latest_at: ($events | max // "")}
	' 2>/dev/null) || return 1
	printf '%s\n' "$activity"
	return 0
}

_pmrc_snapshot_review_threads_clear() {
	local repo_slug="$1"
	local pr_number="$2"
	local owner="${repo_slug%%/*}" name="${repo_slug##*/}" response="" count="" has_next=""
	local bot_re="coderabbitai|gemini-code-assist|augment-code|augmentcode|copilot"

	# shellcheck disable=SC2016
	response=$(_pmrc_gh_read gh api graphql -F owner="$owner" -F name="$name" -F pr="$pr_number" -f query='
		query($owner: String!, $name: String!, $pr: Int!) {
			repository(owner: $owner, name: $name) {
				pullRequest(number: $pr) {
					reviewThreads(first: 100) {
						pageInfo { hasNextPage }
						nodes { isResolved comments(first: 1) { nodes { author { login } } } }
					}
				}
			}
		}
	' 2>/dev/null) || return 1
	if ! printf '%s' "$response" | jq -e 'try (.data.repository.pullRequest != null) catch false' >/dev/null; then
		return 1
	fi
	has_next=$(printf '%s' "$response" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false') || return 1
	[[ "$has_next" == "false" ]] || return 1
	count=$(printf '%s' "$response" | jq -r --arg bots "$bot_re" '[
		.data.repository.pullRequest.reviewThreads.nodes[]?
		| select((.isResolved // false) == false)
		| select((.comments.nodes[0].author.login // "") | test($bots; "i"))
	] | length') || return 1
	[[ "$count" =~ ^[0-9]+$ ]] || return 1
	if [[ "$count" -gt 0 ]]; then
		echo "[pulse-merge] pre-merge snapshot: PR #${pr_number} in ${repo_slug} has ${count} unresolved review-bot thread(s) — merge blocked until resolved or classified (GH#27137)" >>"$LOGFILE"
		return 1
	fi
	return 0
}

_pmrc_is_explicit_advisory_failure() {
	local check_name="$1"
	local checks_json="$2"
	local companion=""
	case "$check_name" in
	"Qlty Smell Threshold") companion="Qlty Smell Regression" ;;
	*) return 1 ;;
	esac
	jq -e --arg companion "$companion" --arg completed "$PMRC_CHECK_COMPLETED" \
		--arg success "$PMRC_CHECK_SUCCESS" '[.[]? | select(.name == $companion and .status == $completed and .conclusion == $success)] | length > 0' \
		<<<"$checks_json" >/dev/null 2>&1
	return $?
}

_pmrc_snapshot_checks_acceptable() {
	local repo_slug="$1"
	local pr_number="$2"
	local checks_json="$3"
	local required_contexts="$4"
	local required_json="" rows="" name="" status="" conclusion="" required=""
	local blockers=0 pending=0 advisory=0

	required_json=$(printf '%s' "$required_contexts" | jq -Rsc '[split("\n")[] | select(length > 0)]') || return 1
	rows=$(jq -r --argjson required "$required_json" '.[] | .name as $name | [
		$name, .status, .conclusion, (($required | index($name)) != null)
	] | @tsv' <<<"$checks_json" 2>/dev/null) || return 1
	while IFS=$'\t' read -r name status conclusion required; do
		[[ -n "$name" ]] || continue
		if [[ "$status" != "$PMRC_CHECK_COMPLETED" || -z "$conclusion" ]]; then
			pending=$((pending + 1))
			continue
		fi
		case "$conclusion" in
		success | neutral | skipped) continue ;;
		esac
		if [[ "$required" == "true" ]]; then
			echo "[pulse-merge] pre-merge snapshot: required check '${name}' is terminal-${conclusion} for PR #${pr_number} in ${repo_slug} (GH#27137)" >>"$LOGFILE"
			blockers=$((blockers + 1))
		elif _pmrc_is_explicit_advisory_failure "$name" "$checks_json"; then
			echo "[pulse-merge] pre-merge snapshot: IGNORED non-required baseline advisory failure '${name}' because its regression companion passed for PR #${pr_number} in ${repo_slug} (GH#27137)" >>"$LOGFILE"
			advisory=$((advisory + 1))
		else
			echo "[pulse-merge] pre-merge snapshot: unclassified non-required check '${name}' is terminal-${conclusion} for PR #${pr_number} in ${repo_slug} — merge blocked (GH#27137)" >>"$LOGFILE"
			blockers=$((blockers + 1))
		fi
	done <<<"$rows"
	if [[ "$pending" -gt 0 || "$blockers" -gt 0 ]]; then
		echo "[pulse-merge] pre-merge snapshot: PR #${pr_number} in ${repo_slug} not ready (active=${pending}, blocking_failures=${blockers}, advisory_failures=${advisory}) (GH#27137)" >>"$LOGFILE"
		return 1
	fi
	echo "[pulse-merge] pre-merge snapshot: terminal check set accepted for PR #${pr_number} in ${repo_slug} (advisory_failures=${advisory}) (GH#27137)" >>"$LOGFILE"
	return 0
}

_pmrc_snapshot_review_gate_fresh() {
	local repo_slug="$1"
	local pr_number="$2"
	local checks_json="$3"
	local activity_json="$4"
	local live_gate_evidence="${5:-}"
	local gate_at="" activity_at="" gate_epoch="" activity_epoch=""

	gate_at=$(jq -r --arg completed "$PMRC_CHECK_COMPLETED" --arg success "$PMRC_CHECK_SUCCESS" '[.[]? | select((.name == "review-bot-gate" or .name == "gate / review-bot-gate") and .status == $completed and .conclusion == $success) | .observed_at | select(. != "")] | max // ""' <<<"$checks_json") || return 1
	activity_at=$(jq -r '.latest_at // ""' <<<"$activity_json") || return 1
	if [[ -z "$gate_at" ]]; then
		#aidevops:trust-boundary — the live helper ran for this exact PR/head, and
		# the caller immediately revalidates that head before reaching this check.
		if [[ -n "$live_gate_evidence" ]]; then
			echo "[pulse-merge] pre-merge snapshot: accepted live review-bot gate bound to the current head for PR #${pr_number} in ${repo_slug}; no status context is installed (GH#27483)" >>"$LOGFILE"
			return 0
		fi
		echo "[pulse-merge] pre-merge snapshot: no successful review-bot gate is bound to the current head for PR #${pr_number} in ${repo_slug} (GH#27137)" >>"$LOGFILE"
		return 1
	fi
	[[ -z "$activity_at" ]] && return 0
	gate_epoch=$(_pmrc_iso_to_epoch "$gate_at") || return 1
	activity_epoch=$(_pmrc_iso_to_epoch "$activity_at") || return 1
	if [[ "$activity_epoch" -gt "$gate_epoch" ]]; then
		echo "[pulse-merge] pre-merge snapshot: review-bot gate is stale for PR #${pr_number} in ${repo_slug} (gate=${gate_at}, latest_review_activity=${activity_at}) (GH#27137)" >>"$LOGFILE"
		return 1
	fi
	return 0
}

_pmrc_snapshot_quiet_period_passes() {
	local repo_slug="$1"
	local pr_number="$2"
	local checks_json="$3"
	local activity_json="$4"
	local quiet_seconds="${PULSE_MERGE_QUIET_PERIOD_SECONDS:-30}"
	local now_epoch="${PULSE_MERGE_NOW_EPOCH:-$(date +%s)}" latest_at="" latest_epoch="" age=""

	[[ "$quiet_seconds" =~ ^[0-9]+$ ]] || quiet_seconds=30
	latest_at=$(jq -nr --argjson checks "$checks_json" --argjson activity "$activity_json" '[
		($checks[]?.observed_at // ""), ($activity.latest_at // "")
	] | map(select(. != "")) | max // ""') || return 1
	[[ -n "$latest_at" ]] || return 0
	latest_epoch=$(_pmrc_iso_to_epoch "$latest_at") || return 1
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || return 1
	age=$((now_epoch - latest_epoch))
	if [[ "$age" -lt "$quiet_seconds" ]]; then
		echo "[pulse-merge] pre-merge snapshot: PR #${pr_number} in ${repo_slug} has been quiet for ${age}s; ${quiet_seconds}s required (GH#27137)" >>"$LOGFILE"
		return 1
	fi
	return 0
}

_pulse_merge_preflight_snapshot_gate() {
	local repo_slug="$1"
	local pr_number="$2"
	local expected_head_sha="$3"
	local expected_gate_evidence="${repo_slug}#${pr_number}@${expected_head_sha}"
	local live_gate_evidence="${_PULSE_REVIEW_GATE_EVIDENCE:-}"
	local pr_json="" current_head_sha="" required_contexts="" checks_json="" activity_json=""

	pr_json=$(_pmrc_gh_read gh api "repos/${repo_slug}/pulls/${pr_number}" 2>/dev/null) || return 1
	current_head_sha=$(jq -r '.head.sha // ""' <<<"$pr_json" 2>/dev/null) || return 1
	if [[ -z "$current_head_sha" || "$current_head_sha" != "$expected_head_sha" ]]; then
		echo "[pulse-merge] pre-merge snapshot: head changed for PR #${pr_number} in ${repo_slug} (expected=${expected_head_sha:-unknown}, current=${current_head_sha:-unknown}) — prior gate state revoked (GH#27137)" >>"$LOGFILE"
		return 1
	fi
	required_contexts=$(_required_contexts_for_default_branch "$repo_slug") || return 1
	checks_json=$(_pmrc_snapshot_checks_json "$repo_slug" "$current_head_sha") || return 1
	activity_json=$(_pmrc_snapshot_bot_activity_json "$repo_slug" "$pr_number") || return 1
	[[ "$live_gate_evidence" == "$expected_gate_evidence" ]] || live_gate_evidence=""
	_pmrc_snapshot_review_gate_fresh "$repo_slug" "$pr_number" "$checks_json" "$activity_json" "$live_gate_evidence" || return 1
	_pmrc_snapshot_review_threads_clear "$repo_slug" "$pr_number" || return 1
	_pmrc_snapshot_checks_acceptable "$repo_slug" "$pr_number" "$checks_json" "$required_contexts" || return 1
	_pmrc_snapshot_quiet_period_passes "$repo_slug" "$pr_number" "$checks_json" "$activity_json" || return 1
	echo "[pulse-merge] pre-merge snapshot: current head ${current_head_sha:0:12}, fresh review gate, resolved bot threads, terminal checks, and quiet period verified for PR #${pr_number} in ${repo_slug} (GH#27137)" >>"$LOGFILE"
	return 0
}

#######################################
# Fallback required-check verification for repositories where the classic branch
# protection endpoint and repository-rulesets endpoint expose no contexts, but
# GitHub still reports PR-level required checks (for example org-level rulesets).
#
# Args: $1=repo_slug, $2=pr_number
# Returns: 0=all reported required checks passing or none reported,
#          1=at least one reported required check is not passing,
#          2=API/parse error
#######################################
_check_required_pr_checks_passing_fallback() {
	local repo_slug="$1"
	local pr_number="$2"

	local checks_json=""
	local checks_exit=0
	checks_json=$(_pmrc_gh_read gh pr checks "$pr_number" --repo "$repo_slug" --required --json name,state,bucket 2>/dev/null)
	checks_exit=$?
	if [[ $checks_exit -ne 0 && -z "$checks_json" ]]; then
		return 2
	fi
	if [[ -z "$checks_json" || "$checks_json" == "null" || "$checks_json" == "[]" ]]; then
		if [[ $checks_exit -ne 0 ]]; then
			return 2
		fi
		printf '[]\n'
		return 0
	fi

	local nonpassing_count="" _pc_exit=0
	nonpassing_count=$(printf '%s' "$checks_json" \
		| jq '[.[]? | select((.bucket // "") != "pass")] | length' 2>/dev/null)
	_pc_exit=$?
	if [[ $_pc_exit -ne 0 || -z "$nonpassing_count" ]]; then
		return 2
	fi

	if [[ "$nonpassing_count" -gt 0 ]]; then
		local stale_gate_pending_count="" _sg_exit=0
		stale_gate_pending_count=$(printf '%s' "$checks_json" | jq '
			"pass" as $pass | "PENDING" as $pending |
			"maintainer-gate" as $stable |
			"Maintainer Review & Assignee Gate" as $legacy |
			[.[]?
			| (.name // "") as $name
			| select((.bucket // "") != $pass)
			| select(((.state // "") | ascii_upcase) == $pending)
			| select($name == $stable or $name == $legacy)
		] | length' 2>/dev/null)
		_sg_exit=$?
		if [[ $_sg_exit -ne 0 || -z "$stale_gate_pending_count" ]]; then
			return 2
		fi

		if [[ "$stale_gate_pending_count" -eq "$nonpassing_count" ]]; then
			local pr_sha="" rollup_json="" gate_pass_count="" _gp_exit=0
			if declare -F gh_pr_view >/dev/null 2>&1; then
				pr_sha=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
					--json headRefOid --jq '.headRefOid // ""' 2>/dev/null) || pr_sha=""
			else
				pr_sha=$(_pmrc_gh_read gh pr view "$pr_number" --repo "$repo_slug" \
					--json headRefOid --jq '.headRefOid // ""' 2>/dev/null) || pr_sha=""
			fi
			if [[ -n "$pr_sha" ]]; then
				local status_json="" pending_gate_status_count="" _ps_exit=0
				status_json=$(_pmrc_gh_read gh api "repos/${repo_slug}/commits/${pr_sha}/status" 2>/dev/null) || status_json=""
				if [[ -n "$status_json" && "$status_json" != null ]]; then
					pending_gate_status_count=$(jq '
						"maintainer-gate" as $stable |
						"Maintainer Review & Assignee Gate" as $legacy |
						[.statuses[]?
						| (.context // "") as $name
						| select(($name == $stable or $name == $legacy)
							and (((.state // "") | ascii_downcase) == "pending"))
						] | length' <<<"$status_json" 2>/dev/null)
					_ps_exit=$?
					if [[ $_ps_exit -ne 0 || -z "$pending_gate_status_count" ]]; then
						return 2
					fi
					if [[ "$pending_gate_status_count" -gt 0 ]]; then
						return 1
					fi
				fi
			fi
			if [[ -n "$pr_sha" ]] && declare -F gh_pr_check_runs_rest >/dev/null 2>&1; then
				rollup_json=$(gh_pr_check_runs_rest "$repo_slug" "$pr_sha" 2>/dev/null) || rollup_json=""
				if [[ -n "$rollup_json" && "$rollup_json" != null ]]; then
					gate_pass_count=$(jq '
						"gate / Maintainer Review & Assignee Gate" as $gate |
						"success" as $ok | "neutral" as $neutral |
						"skipped" as $skipped |
						[.[]?
						| select((.name // "") == $gate)
						| ((.conclusion // "") | ascii_downcase) as $conclusion
						| select($conclusion == $ok or $conclusion == $neutral
							or $conclusion == $skipped)
					] | length' <<<"$rollup_json" 2>/dev/null)
					_gp_exit=$?
					if [[ $_gp_exit -eq 0 && "$gate_pass_count" =~ ^[0-9]+$ \
						&& "$gate_pass_count" -gt 0 ]]; then
						return 0
					fi
				fi
			fi
		fi
		return 1
	fi
	return 0
}

#######################################
# Resolve the maximum required approval count from active rulesets matching
# the repository default branch. This is separate from required status checks:
# GitHub stores ruleset approval requirements under pull_request rules, not as
# CI contexts, so an empty status context list is not enough to allow a merge.
#
# Args: $1=repo_slug, $2=default_branch, $3=optional pre-fetched rulesets JSON
# Stdout: integer maximum required_approving_review_count (0 when none)
# Returns: 0=requirement resolved, 1=ruleset API/parse error
#######################################
_ruleset_required_review_count_for_default_branch() {
	local repo_slug="$1"
	local default_branch="$2"
	local rulesets_json="${3:-}"
	local log_target="${LOGFILE:-/dev/stderr}"

	if [[ -z "$rulesets_json" ]]; then
		rulesets_json=$(_pmrc_gh_read gh api "repos/${repo_slug}/rulesets" 2>/dev/null) || {
			echo "[pulse-merge] _ruleset_required_review_count_for_default_branch: rulesets list failed for ${repo_slug} — caller will fail closed (GH#24577)" >>"$log_target"
			return 1
		}
	fi
	[[ -n "$rulesets_json" && "$rulesets_json" != "[]" && "$rulesets_json" != null ]] || {
		printf '0'
		return 0
	}

	local active_ids=""
	active_ids=$(printf '%s' "$rulesets_json" | jq -r '.[]? | select(.enforcement == "active") | .id // empty' 2>>"$log_target") || {
		echo "[pulse-merge] _ruleset_required_review_count_for_default_branch: rulesets list parse failed for ${repo_slug} — caller will fail closed (GH#24577)" >>"$log_target"
		return 1
	}
	[[ -n "$active_ids" ]] || {
		printf '0'
		return 0
	}

	local max_required=0
	local id="" detail="" include_patterns="" exclude_patterns="" pattern=""
	local matches_default=0 excluded_default=0 approval_count=""
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		detail=$(_pmrc_gh_read gh api "repos/${repo_slug}/rulesets/${id}" 2>/dev/null) || {
			echo "[pulse-merge] _ruleset_required_review_count_for_default_branch: ruleset detail ${id} failed for ${repo_slug} — caller will fail closed (GH#24577)" >>"$log_target"
			return 1
		}
		include_patterns=$(printf '%s' "$detail" | jq -r '.conditions?.ref_name?.include? // [] | .[]' 2>>"$log_target") || return 1
		exclude_patterns=$(printf '%s' "$detail" | jq -r '.conditions?.ref_name?.exclude? // [] | .[]' 2>>"$log_target") || return 1

		matches_default=0
		while IFS= read -r pattern; do
			[[ -n "$pattern" ]] || continue
			_ruleset_ref_matches_default_branch "$pattern" "$default_branch" || continue
			matches_default=1
			break
		done <<<"$include_patterns"
		[[ "$matches_default" -eq 1 ]] || continue

		excluded_default=0
		while IFS= read -r pattern; do
			[[ -n "$pattern" ]] || continue
			_ruleset_ref_matches_default_branch "$pattern" "$default_branch" || continue
			excluded_default=1
			break
		done <<<"$exclude_patterns"
		[[ "$excluded_default" -eq 0 ]] || continue

		approval_count=$(printf '%s' "$detail" | jq -r '[.rules[]? | select(.type == "pull_request") | (.parameters?.required_approving_review_count? // 0)] | max // 0' 2>>"$log_target") || {
			echo "[pulse-merge] _ruleset_required_review_count_for_default_branch: pull-request rule parse failed for ruleset ${id} in ${repo_slug} — caller will fail closed (GH#24577)" >>"$log_target"
			return 1
		}
		[[ "$approval_count" =~ ^[0-9]+$ ]] || approval_count=0
		[[ "$approval_count" -gt "$max_required" ]] && max_required="$approval_count"
	done <<<"$active_ids"

	printf '%s' "$max_required"
	return 0
}

#######################################
# Verify active ruleset pull_request approval requirements for one PR.
#
# Args: $1=repo_slug, $2=pr_number, $3=pr_author
# Returns: 0=passes/no ruleset approval requirement, 1=missing/unverifiable
#######################################
_check_ruleset_required_reviews_passing() {
	local repo_slug="$1"
	local pr_number="$2"
	local pr_author="$3"

	local default_branch="" required_count=""
	default_branch=$(_pmrc_gh_read gh api "repos/${repo_slug}" --jq '.default_branch' 2>/dev/null) || default_branch=""
	if [[ -z "$default_branch" ]]; then
		echo "[pulse-merge] _check_ruleset_required_reviews_passing: failed to resolve default branch for ${repo_slug} — failing closed (GH#24577)" >>"$LOGFILE"
		return 1
	fi
	required_count=$(_ruleset_required_review_count_for_default_branch "$repo_slug" "$default_branch") || return 1
	[[ "$required_count" =~ ^[0-9]+$ ]] || required_count=0
	[[ "$required_count" -eq 0 ]] && return 0

	local reviews_json="" approved_count=""
	reviews_json=$(gh_pr_view "$pr_number" --repo "$repo_slug" --json reviews 2>/dev/null) || reviews_json=""
	if [[ -z "$reviews_json" || "$reviews_json" == null ]]; then
		echo "[pulse-merge] _check_ruleset_required_reviews_passing: review fetch failed for PR #${pr_number} in ${repo_slug} with ruleset requiring ${required_count} approval(s) — failing closed (GH#24577)" >>"$LOGFILE"
		return 1
	fi
	approved_count=$(jq -r --arg author "$pr_author" '
		[.reviews[]?] | sort_by(.submittedAt // "") | group_by(.author.login // "")
		| map(last) | map(select((.author.login // "") != $author))
		| map(select((.state // "" | ascii_upcase) == "APPROVED")) | length
	' <<<"$reviews_json" 2>/dev/null) || approved_count=""
	if [[ ! "$approved_count" =~ ^[0-9]+$ ]]; then
		echo "[pulse-merge] _check_ruleset_required_reviews_passing: review parse failed for PR #${pr_number} in ${repo_slug} — failing closed (GH#24577)" >>"$LOGFILE"
		return 1
	fi
	if [[ "$approved_count" -lt "$required_count" ]]; then
		echo "[pulse-merge] _check_ruleset_required_reviews_passing: PR #${pr_number} in ${repo_slug} has ${approved_count}/${required_count} ruleset-required approval(s) — deferring merge (GH#24577)" >>"$LOGFILE"
		return 1
	fi
	echo "[pulse-merge] _check_ruleset_required_reviews_passing: PR #${pr_number} in ${repo_slug} satisfies ${approved_count}/${required_count} ruleset-required approval(s) (GH#24577)" >>"$LOGFILE"
	return 0
}

#######################################
# Return whether any branch-protection-required check on a PR is in a terminal
# failed state. Pending states are explicitly non-terminal: queued, pending,
# in_progress, waiting, skipped-by-dependency, expected, absent-from-rollup,
# and null conclusions must not trigger close/requeue/repair routing.
#
# Args: $1=repo_slug, $2=pr_number
# Returns: 0=terminal failure found, 1=no terminal failures, 2=API/parse error
#######################################
_check_required_checks_has_terminal_failure() {
	local repo_slug="$1"
	local pr_number="$2"

	local required_contexts=""
	required_contexts=$(_required_contexts_for_default_branch "$repo_slug") || return 2
	if [[ -z "$required_contexts" ]]; then
		echo "[pulse-merge] _check_required_checks_has_terminal_failure: no required contexts for ${repo_slug} — allowing (t3567)" >>"$LOGFILE"
		return 1
	fi

	local pr_sha=""
	pr_sha=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
		--json headRefOid --jq '.headRefOid // ""') || true
	if [[ -z "$pr_sha" ]]; then
		echo "[pulse-merge] _check_required_checks_has_terminal_failure: headRefOid fetch failed for PR #${pr_number} in ${repo_slug} — failing closed (t3567)" >>"$LOGFILE"
		return 2
	fi

	local rollup_json=""
	rollup_json=$(gh_pr_check_runs_rest "$repo_slug" "$pr_sha" 2>/dev/null) || rollup_json=""
	if [[ -z "$rollup_json" || "$rollup_json" == null ]]; then
		echo "[pulse-merge] _check_required_checks_has_terminal_failure: REST check-runs fetch failed for PR #${pr_number} in ${repo_slug} — failing closed (t3567)" >>"$LOGFILE"
		return 2
	fi

	local req_json
	req_json=$(printf '%s' "$required_contexts" \
		| jq -Rsc '[split("\n")[] | select(length > 0)]' 2>/dev/null) || req_json="[]"

	local failing_count="" _fc_exit=0
	failing_count=$(jq -n \
		--argjson req "$req_json" \
		--argjson checks "$rollup_json" \
		'$req | map(
			. as $ctx |
			($checks | map(select((.name // "") == $ctx)) | last) as $c |
			if $c == null then false
			elif (($c.conclusion // "" | ascii_downcase)
				| . == "failure" or . == "cancelled" or . == "timed_out") then true
			else false
			end
		) | map(select(.)) | length' 2>/dev/null)
	_fc_exit=$?

	if [[ $_fc_exit -ne 0 || -z "$failing_count" ]]; then
		echo "[pulse-merge] _check_required_checks_has_terminal_failure: jq evaluation failed for PR #${pr_number} in ${repo_slug} — failing closed (t3567)" >>"$LOGFILE"
		return 2
	fi

	if [[ "$failing_count" -gt 0 ]]; then
		echo "[pulse-merge] _check_required_checks_has_terminal_failure: ${failing_count} terminal failed required context(s) for PR #${pr_number} in ${repo_slug} (t3567)" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-merge] _check_required_checks_has_terminal_failure: no terminal failed required contexts for PR #${pr_number} in ${repo_slug} (t3567)" >>"$LOGFILE"
	return 1
}

#######################################
# Return whether any branch-protection-required check on the current PR head is
# queued, pending, in progress, waiting, or absent from the current head rollup.
# This is the pre-update guard for branch refresh paths: mutating a PR branch
# while required checks are still active restarts CI and wastes runner time.
#
# Args: $1=repo_slug, $2=pr_number
# Returns: 0=pending/in-progress required check found, 1=no active required
#          checks, 2=API/parse error
#######################################
_check_required_checks_have_pending_or_in_progress() {
	local repo_slug="$1"
	local pr_number="$2"

	local required_contexts=""
	required_contexts=$(_required_contexts_for_default_branch "$repo_slug") || return 2
	if [[ -z "$required_contexts" ]]; then
		echo "[pulse-merge] _check_required_checks_have_pending_or_in_progress: no required contexts for ${repo_slug} — no active required checks (GH#26406)" >>"$LOGFILE"
		return 1
	fi

	local pr_sha=""
	pr_sha=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
		--json headRefOid --jq '.headRefOid // ""') || true
	if [[ -z "$pr_sha" ]]; then
		echo "[pulse-merge] _check_required_checks_have_pending_or_in_progress: headRefOid fetch failed for PR #${pr_number} in ${repo_slug} — failing open for branch-update caller (GH#26406)" >>"$LOGFILE"
		return 2
	fi

	local rollup_json=""
	rollup_json=$(gh_pr_check_runs_rest "$repo_slug" "$pr_sha" 2>/dev/null) || rollup_json=""
	if [[ -z "$rollup_json" || "$rollup_json" == null ]]; then
		echo "[pulse-merge] _check_required_checks_have_pending_or_in_progress: REST check-runs fetch failed for PR #${pr_number} in ${repo_slug} — failing open for branch-update caller (GH#26406)" >>"$LOGFILE"
		return 2
	fi

	local req_json
	req_json=$(printf '%s' "$required_contexts" \
		| jq -Rsc '[split("\n")[] | select(length > 0)]' 2>/dev/null) || req_json="[]"

	local pending_count="" _pc_exit=0
	pending_count=$(jq -n \
		--argjson req "$req_json" \
		--argjson checks "$rollup_json" \
		'$req | map(
			. as $ctx |
			($checks | map(select((.name // "") == $ctx)) | last) as $c |
			if $c == null then true
			elif (($c.conclusion // "") | length) == 0 then true
			elif (($c.status // "" | ascii_downcase)
				| . == "queued" or . == "pending" or . == "in_progress" or . == "waiting" or . == "requested") then true
			else false
			end
		) | map(select(.)) | length' 2>/dev/null)
	_pc_exit=$?

	if [[ $_pc_exit -ne 0 || -z "$pending_count" ]]; then
		echo "[pulse-merge] _check_required_checks_have_pending_or_in_progress: jq evaluation failed for PR #${pr_number} in ${repo_slug} — failing open for branch-update caller (GH#26406)" >>"$LOGFILE"
		return 2
	fi

	if [[ "$pending_count" -gt 0 ]]; then
		echo "[pulse-merge] _check_required_checks_have_pending_or_in_progress: ${pending_count} active required check(s) on current head for PR #${pr_number} in ${repo_slug} (GH#26406)" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-merge] _check_required_checks_have_pending_or_in_progress: no active required checks on current head for PR #${pr_number} in ${repo_slug} (GH#26406)" >>"$LOGFILE"
	return 1
}
