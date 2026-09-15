#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# CI failure evidence, repair routing, and bounded repair-session helpers.

[[ -n "${_PULSE_MERGE_FEEDBACK_CI_REPAIR_LOADED:-}" ]] && return 0
_PULSE_MERGE_FEEDBACK_CI_REPAIR_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _pmf_module_path="${BASH_SOURCE[0]%/*}"
    [[ "$_pmf_module_path" == "${BASH_SOURCE[0]}" ]] && _pmf_module_path="."
    SCRIPT_DIR="$(cd "$_pmf_module_path" && pwd)"
    unset _pmf_module_path
fi

_build_ci_feedback_section() {
	local pr_number="$1"
	local failing_checks="$2"
	local classification_output="${3:-}"

	# Locate the ci-failure-patterns.conf registry (t3225) so the guidance
	# emitter can look up resolution commands per classification. Use
	# dirname (not cd+pwd) — t3225 string-literal ratchet avoidance.
	local conf_file
	conf_file="${BASH_SOURCE[0]%/*}/../configs/ci-failure-patterns.conf"

	# Lead with header + terminal failed checks list (always present).
	cat <<-EOF
		## CI Repair Feedback (from PR #${pr_number})

		The previous worker's PR #${pr_number} had terminal failed CI checks. A head-bound
		finalizer is routing this issue for redispatch. The next worker should address these failures.

		### Terminal failed checks

		${failing_checks}
	EOF

	# Insert pattern-specific guidance blocks BEFORE the generic worker
	# guidance, so the auto-fix sequences are seen first (t3225).
	if [[ -n "$classification_output" ]]; then
		_emit_ci_failure_guidance_blocks "$classification_output" "$conf_file"
	fi

	# Generic worker guidance (always emitted as a fallback).
	cat <<-EOF
		### Worker guidance

		1. Recover the previous PR branch/commits and continue that work; do not restart from scratch.
		2. Read every terminal check URL above and preserve the accumulated evidence.
		3. Rebase the recovered work onto current \`origin/main\`, then fix the code rather than weakening CI.
		4. Run every listed local check and create the replacement PR from the recovered branch.

		_Routed by deterministic merge pass (pulse-merge.sh)._
	EOF
	return 0
}

#######################################
# Return whether a failed check URL points at a GitHub Actions job whose failed
# log is an infrastructure failure rather than actionable code feedback.
#
# Args:
#   $1 - repo_slug
#   $2 - check URL
#
# Returns: 0=infrastructure failure detected, 1=not detected or unavailable.
#######################################
_ci_check_url_has_infra_failure_log() {
	local repo_slug="$1"
	local check_url="$2"

	[[ -n "$repo_slug" ]] || return 1
	[[ -n "$check_url" ]] || return 1

	local run_id="" job_id=""
	case "$check_url" in
	*"/actions/runs/"*"/job/"*) ;;
	*) return 1 ;;
	esac

	run_id="${check_url#*/actions/runs/}"
	run_id="${run_id%%/*}"
	job_id="${check_url#*/job/}"
	job_id="${job_id%%[/?#]*}"
	[[ "$run_id" =~ ^[0-9]+$ ]] || return 1
	[[ "$job_id" =~ ^[0-9]+$ ]] || return 1

	local failed_log=""
	failed_log=$(gh run view "$run_id" --repo "$repo_slug" --job "$job_id" --log-failed 2>/dev/null) || failed_log=""
	[[ -n "$failed_log" ]] || return 1

	if printf '%s\n' "$failed_log" | grep -Eiq '(Process completed with exit code (124|137|143)|timed out after|[[:space:]]Killed[[:space:]]+timeout|timeout --kill-after|The operation was canceled|cancelled due to timeout|API rate limit exceeded for (installation|user)|You have exceeded a secondary rate limit|toomanyrequests:.*(Rate exceeded|pull rate limit|reached your.*rate limit)|Error response from daemon:.*(429|Too Many Requests|Rate exceeded)|(failed to pull image|failed to resolve source metadata|failed to authorize).*(429|Too Many Requests|Rate exceeded|TLS handshake timeout|i/o timeout|connection reset by peer|Service Unavailable)|(public\.ecr\.aws|docker\.io|ghcr\.io|registry[^[:space:]]*).*(429|Too Many Requests|Rate exceeded|TLS handshake timeout|i/o timeout|connection reset by peer|Service Unavailable))'; then
		return 0
	fi
	return 1
}

#######################################
# Filter required failed checks down to actionable code failures by excluding
# GitHub Actions jobs whose logs show infrastructure-failure signatures.
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug
#   $3 - checks_json (array of {name, conclusion, link})
#
# Output: markdown list of actionable checks.
#######################################
_ci_actionable_failed_checks_markdown() {
	local pr_number="$1"
	local repo_slug="$2"
	local checks_json="$3"

	local count=""
	count=$(printf '%s' "$checks_json" | jq 'length' 2>/dev/null) || count=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	[[ "$count" -gt 0 ]] || return 0

	local idx=0 name="" conclusion="" link="" evidence_role=""
	while [[ "$idx" -lt "$count" ]]; do
		name=$(printf '%s' "$checks_json" | jq -r --argjson i "$idx" '.[$i].name // empty' 2>/dev/null) || name=""
		conclusion=$(printf '%s' "$checks_json" | jq -r --argjson i "$idx" '.[$i].conclusion // empty' 2>/dev/null) || conclusion=""
		link=$(printf '%s' "$checks_json" | jq -r --argjson i "$idx" '.[$i].link // empty' 2>/dev/null) || link=""
		if _ci_check_url_has_infra_failure_log "$repo_slug" "$link"; then
			echo "[pulse-wrapper] _dispatch_ci_fix_worker: PR #${pr_number} check '${name}' classified as infrastructure failure from failed log — skipping code redispatch" >>"$LOGFILE"
			if ! declare -F _pmrc_rerun_infrastructure_check >/dev/null 2>&1; then
				echo "[pulse-wrapper] _dispatch_ci_fix_worker: bounded infrastructure rerun helper unavailable for PR #${pr_number} check '${name}' — preserving PR for a later merge pass" >>"$LOGFILE"
			elif ! _pmrc_rerun_infrastructure_check "$repo_slug" "$pr_number" "$name" "$link"; then
				echo "[pulse-wrapper] _dispatch_ci_fix_worker: bounded infrastructure rerun unavailable for PR #${pr_number} check '${name}' — preserving PR for a later merge pass" >>"$LOGFILE"
			fi
		else
			evidence_role=$(_ci_check_evidence_role "$name")
			printf -- '- **%s**: %s — [check URL](%s) — _%s_\n' \
				"$name" "$conclusion" "$link" "$evidence_role"
		fi
		idx=$((idx + 1))
	done
	return 0
}

#######################################
# Classify one failed check for feedback presentation only. This never changes
# whether a check blocks merge or qualifies for bounded repair.
#######################################
_ci_check_evidence_role() {
	local check_name="$1"
	local normalized_name=""
	normalized_name=$(printf '%s' "$check_name" | tr '[:upper:]' '[:lower:]')
	case "$normalized_name" in
	*qlty*threshold* | *qlty*absolute* | *qlty*baseline*)
		printf '%s' 'contextual repository-baseline evidence'
		;;
	*qlty*regression* | *qlty*new-file* | *qlty*new\ file* | *qlty*maintainability\ smells*)
		printf '%s' 'primary PR-delta/new-file evidence'
		;;
	*)
		printf '%s' 'primary failing-check evidence'
		;;
	esac
	return 0
}

#######################################
# Preserve a PR when supplied preflight evidence is only a non-required
# repository-baseline failure. Exact required-context and successful regression
# evidence are authoritative: retain repair routing when either is unavailable.
#
# Args: $1=repo slug, $2=PR number, $3=supplied checks JSON
# Stdout: checks JSON eligible for CI repair routing
#######################################
_ci_filter_nonrequired_baseline_evidence() {
	local repo_slug="$1"
	local pr_number="$2"
	local supplied_checks_json="$3"
	local required_checks_json="" required_checks_rc=0 all_checks_json="" all_checks_rc=0

	[[ -n "$supplied_checks_json" ]] || {
		printf '[]\n'
		return 0
	}
	required_checks_json=$(gh_pr_checks_exact_json "$repo_slug" "$pr_number" required 2>/dev/null) || required_checks_rc=$?
	case "$required_checks_rc" in
	0 | 1 | 8) [[ -n "$required_checks_json" ]] || required_checks_json="[]" ;;
	*)
		# Unknown required-check state must remain blocking rather than silently
		# treating supplied evidence as advisory.
		printf '%s\n' "$supplied_checks_json"
		return 0
		;;
	esac
	all_checks_json=$(gh_pr_checks_exact_json "$repo_slug" "$pr_number" all 2>/dev/null) || all_checks_rc=$?
	case "$all_checks_rc" in
	0 | 1 | 8) [[ -n "$all_checks_json" ]] || all_checks_json="[]" ;;
	*)
		# PR-delta attribution is unavailable, so preserve the conservative route.
		printf '%s\n' "$supplied_checks_json"
		return 0
		;;
	esac

	jq -c --argjson required "$required_checks_json" --argjson all "$all_checks_json" '
		[.[]? | select(
			(.name as $name
			| ($required | any(.[]?; .name == $name))
			) or (
				((.name | ascii_downcase) | test("qlty.*(threshold|absolute|baseline)"; "i") | not)
				or (($all | any(.[]?; .name == "Qlty Smell Regression" and ((.conclusion // .state // "") | ascii_downcase) == "success")) | not)
			)
		)]
	' <<<"$supplied_checks_json" 2>/dev/null || printf '%s\n' "$supplied_checks_json"
	return 0
}

_ci_repair_checks_for_dispatch() {
	local repo_slug="$1"
	local pr_number="$2"
	local supplied_checks_json="${3:-}"
	local checks_json=""

	checks_json=$(_ci_repair_required_checks_json "$repo_slug" "$pr_number" "$supplied_checks_json")
	if [[ -n "$supplied_checks_json" ]]; then
		checks_json=$(_ci_filter_nonrequired_baseline_evidence "$repo_slug" "$pr_number" "$checks_json")
	fi
	printf '%s\n' "$checks_json"
	return 0
}

#######################################
# Return terminal failed check details and names from one jq pass.
#
# Args:
#   $1 - checks_json (normalized exact-read array with name,bucket,state,link)
#   $2 - terminal_failed_check_filter (jq select expression)
#
# Output: first line is filtered checks JSON, followed by a marker and one
# check name per line. Callers split this without re-running jq over the same
# payload.
#######################################
_ci_terminal_failed_check_results() {
	local checks_json="$1"
	local terminal_failed_check_filter="$2"

	[[ -n "$checks_json" ]] || checks_json="[]"
	printf '%s' "$checks_json" | jq -r "([.[] | select(${terminal_failed_check_filter}) | {name, conclusion: ((.conclusion // .state // \"\") | ascii_downcase), link}] | tojson), \"__AIDEVOPS_CHECK_NAMES__\", (.[] | select(${terminal_failed_check_filter}) | .name)" 2>/dev/null || {
		printf '[]\n__AIDEVOPS_CHECK_NAMES__\n'
		return 0
	}
	return 0
}

_ci_merge_check_sets() {
	local primary_checks="$1"
	local all_checks="$2"
	printf '%s\n%s\n' "$primary_checks" "$all_checks" | jq -sc 'add | unique_by([.name, .link])' 2>/dev/null || printf '%s' "${primary_checks:-[]}"
	return 0
}

#######################################
# Normalize exact required-check output for CI repair evidence collection.
# Args: $1=repo slug, $2=PR number, $3=optional supplied checks JSON
# Stdout: checks JSON, defaulting to an empty array on indeterminate reads
#######################################
_ci_repair_required_checks_json() {
	local repo_slug="$1"
	local pr_number="$2"
	local supplied_checks_json="${3:-}"
	local checks_json="$supplied_checks_json"
	local checks_exit=0

	if [[ -z "$checks_json" ]]; then
		checks_json=$(gh_pr_checks_exact_json "$repo_slug" "$pr_number" required 2>/dev/null) || checks_exit=$?
		case "$checks_exit" in
		0 | 1 | 8) [[ -n "$checks_json" ]] || checks_json="[]" ;;
		*) checks_json="[]" ;;
		esac
	fi
	printf '%s\n' "$checks_json"
	return 0
}

#######################################
# Route CI failure feedback from a worker/trusted PR to a bounded repair worker
# on the existing PR branch. Fall back to issue redispatch only when the branch
# cannot be repaired in place.
#
# The repair worker sees failing check names, URLs, and current-head context.
# Its durable lease is keyed by repo + PR + head SHA so reordered or changing
# check evidence cannot launch overlapping workers against one branch head. A
# newly-pushed head can enter repair independently if it is still red.
#
# Same pattern as _dispatch_pr_fix_worker (t2093) but for CI failures
# instead of review CHANGES_REQUESTED.
#
# Args: $1=pr_number, $2=repo_slug, $3=linked_issue, $4=checks_json (optional)
#######################################
_dispatch_ci_fix_worker() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local supplied_checks_json="${4:-}" initial_head_sha=""
	_CI_REPAIR_OUTCOME_SUMMARY=""

	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0
	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 0
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "[pulse-wrapper] feedback finalizer: deferred PR #${pr_number} and issue #${linked_issue} in ${repo_slug} — dry-run forbids CI repair dispatch and feedback finalization writes" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	initial_head_sha=$(gh pr view "$pr_number" --repo "$repo_slug" --json headRefOid --jq '.headRefOid // ""' 2>/dev/null) || initial_head_sha=""
	if [[ -z "$initial_head_sha" ]]; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: PR #${pr_number} head snapshot unavailable before collecting CI evidence — deferring repair routing" >>"$LOGFILE"
		return 0
	fi

	# Collect actionable failed required checks first. Pending/queued/in-progress
	# checks are not actionable repair evidence and must not be routed into the
	# linked issue as stale worker guidance. Likewise, cancelled/timed_out checks
	# usually reflect CI capacity, superseded runs, or job-budget kills; routing
	# those as code-fix feedback creates duplicate PR churn instead of retrying or
	# escalating CI infrastructure. If required checks contain no actionable
	# failures. Advisory failures do not justify branch ownership or repair work.
	local terminal_failed_check_filter='(.bucket == "fail" or .bucket == "cancel") and (((.conclusion // .state // "") | ascii_downcase) | test("^(failure|action_required)$")) and ((.link // "") != "")'
	local checks_json="" result_marker=$'\n__AIDEVOPS_CHECK_NAMES__'
	local check_results="" failing_checks_json="" failing_checks="" failing_names="" classification_output=""
	checks_json=$(_ci_repair_checks_for_dispatch "$repo_slug" "$pr_number" "$supplied_checks_json")
	check_results=$(_ci_terminal_failed_check_results "$checks_json" "$terminal_failed_check_filter")
	failing_checks_json="${check_results%%"$result_marker"*}"
	failing_names="${check_results#*"$result_marker"}"
	[[ "$failing_names" != "$check_results" ]] || failing_names=""
	failing_names="${failing_names#$'\n'}"
	failing_checks=$(_ci_actionable_failed_checks_markdown "$pr_number" "$repo_slug" "$failing_checks_json")

	if [[ -z "$failing_checks" ]]; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: PR #${pr_number} in ${repo_slug} has no actionable failed checks with URLs — skipping CI repair routing" >>"$LOGFILE"
		return 0
	fi

	# t3225: Also collect raw failing check NAMES (one per line) for
	# pattern classification. Failure to collect names is non-fatal — we
	# fall back to the pre-t3225 behaviour (no pattern guidance block).
	if [[ -n "$failing_names" ]]; then
		classification_output=$(_classify_ci_failures_by_pattern "$failing_names" 2>/dev/null) || classification_output=""
	fi

	# Bind repair evidence to the current branch head. This refresh also proves
	# the branch is same-repository and writable before any worker is launched.
	local pr_info="" pr_head_sha="" pr_head_ref="" is_cross_repo="" maintainer_can_modify=""
	pr_info=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json headRefOid,headRefName,isCrossRepository,maintainerCanModify \
		--jq '[(.headRefOid // ""),(.headRefName // ""),(.isCrossRepository // false),(.maintainerCanModify // false)] | @tsv' 2>/dev/null) || pr_info=""
	IFS=$'\t' read -r pr_head_sha pr_head_ref is_cross_repo maintainer_can_modify <<<"$pr_info"
	if [[ -n "$initial_head_sha" && "$pr_head_sha" != "$initial_head_sha" ]]; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: PR #${pr_number} head changed while collecting CI evidence (${initial_head_sha} -> ${pr_head_sha:-unknown}) — deferring repair routing" >>"$LOGFILE"
		return 0
	fi

	local failure_fingerprint=""
	failure_fingerprint=$(_ci_repair_hash_text "$(printf '%s\n' "$failing_checks_json" | jq -cS '.' 2>/dev/null)") || failure_fingerprint=""
	[[ -n "$failure_fingerprint" ]] || failure_fingerprint="unknown"

	# Build the CI Failure Feedback section (with optional pattern guidance).
	local feedback_section
	feedback_section=$(_build_ci_feedback_section "$pr_number" "$failing_checks" "$classification_output")

	local fallback_reason=""
	if [[ -z "$pr_head_sha" || -z "$pr_head_ref" ]]; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: current branch metadata unavailable for PR #${pr_number} in ${repo_slug} — preserving PR for a later repair pass" >>"$LOGFILE"
		return 0
	elif [[ "$is_cross_repo" == "true" ]]; then
		fallback_reason="the PR head is in a fork and is not an owned repair branch"
	elif ! declare -F _pulse_merge_repo_path_for_slug >/dev/null 2>&1; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: repository-path resolver unavailable for PR #${pr_number} in ${repo_slug} — preserving PR for a later repair pass" >>"$LOGFILE"
		return 0
	elif _dispatch_ci_repair_session "$pr_number" "$repo_slug" "$linked_issue" \
		"$pr_head_sha" "$pr_head_ref" "$failure_fingerprint" "$failing_checks"; then
		if [[ "${_CI_REPAIR_DISPATCH_RESULT:-}" == "active" ]]; then
			echo "[pulse-wrapper] _dispatch_ci_fix_worker: in-place CI repair already active for PR #${pr_number} head ${pr_head_sha} fingerprint ${failure_fingerprint} in ${repo_slug}" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] _dispatch_ci_fix_worker: dispatched in-place CI repair for PR #${pr_number} head ${pr_head_sha} fingerprint ${failure_fingerprint} in ${repo_slug}" >>"$LOGFILE"
		fi
		return 0
	elif [[ "${_CI_REPAIR_DISPATCH_RESULT:-}" == "exhausted" ]]; then
		fallback_reason="the bounded PR-branch repair session exhausted its retry budget"
	else
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: retryable in-place repair launch failure for PR #${pr_number} head ${pr_head_sha} in ${repo_slug} (result=${_CI_REPAIR_DISPATCH_RESULT:-unknown}) — preserving PR for a later bounded attempt" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-wrapper] _dispatch_ci_fix_worker: durable fallback authorized for PR #${pr_number} in ${repo_slug}: ${fallback_reason}" >>"$LOGFILE"
	local route_rc=0
	_route_ci_repair_fallback "$pr_number" "$repo_slug" "$linked_issue" "$pr_head_sha" \
		"$pr_head_ref" "$failure_fingerprint" "$fallback_reason" "$feedback_section" "$failing_checks" \
		"$_CI_REPAIR_OUTCOME_SUMMARY" || route_rc=$?
	return "$route_rc"
}

#######################################
# Route terminal CI evidence back to the issue when in-place repair is impossible.
#######################################
_route_ci_repair_fallback() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local pr_head_sha="$4"
	local pr_head_ref="$5"
	local failure_fingerprint="$6"
	local fallback_reason="$7"
	local feedback_section="$8"
	local failing_checks="$9"
	local attempt_summary="${10:-}"
	local marker_prefix="<!-- ci-feedback-fallback:PR${pr_number}:SHA${pr_head_sha:-unknown}"
	local marker="${marker_prefix} -->"
	local legacy_match="<!-- ci-feedback-fallback:PR${pr_number}:SHA"
	: "$failure_fingerprint"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "[pulse-wrapper] feedback finalizer: deferred PR #${pr_number} and issue #${linked_issue} in ${repo_slug} — dry-run forbids CI feedback finalization writes" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	if ! declare -F _finalize_feedback_route >/dev/null 2>&1; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: feedback finalizer unavailable for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi

	_feedback_route_gh_write label create "ci-feedback-routed" --repo "$repo_slug" --color "E4E669" \
		--description "Worker PR with failing CI routed to linked issue for re-dispatch" \
		--force >/dev/null 2>&1 || true
	_feedback_route_gh_write label create "source:ci-feedback" --repo "$repo_slug" --color "FEF2C0" \
		--description "Issue carries CI failure feedback routed from a closed worker PR" \
		--force >/dev/null 2>&1 || true
	feedback_section="${feedback_section}

### In-place repair fallback

- Reason: ${fallback_reason}
- Retry: re-run the deterministic merge pass after restoring access to branch \`${pr_head_ref:-unknown}\`; keep PR #${pr_number} open until that retry is impossible."
	if [[ -n "$attempt_summary" ]]; then
		feedback_section="${feedback_section}

### In-place repair attempt outcomes

${attempt_summary}"
	fi
	local close_comment="## CI repair feedback routed to issue #${linked_issue}

This worker PR had terminal failed CI checks. The check details have been appended
to the linked issue body so the next worker can address them.

Terminal failed checks:
${failing_checks}

_Closed by deterministic merge pass (pulse-merge.sh)._"
	local finalize_rc=0
	_finalize_feedback_route "ci" "$pr_number" "$repo_slug" "$linked_issue" "$pr_head_sha" \
		"source:ci-feedback" "ci-feedback-routed" "$marker" "$feedback_section" \
		"_dispatch_ci_fix_worker" "$close_comment" "$legacy_match" || finalize_rc=$?
	if [[ "$finalize_rc" -eq 0 ]]; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: in-place repair impossible for PR #${pr_number}; routed fallback to issue #${linked_issue} in ${repo_slug}: ${fallback_reason}" >>"$LOGFILE"
	fi
	return "$finalize_rc"
}

#######################################
# Return the dispatch-bound outcome identity for one bounded repair attempt.
#######################################
_ci_repair_outcome_id() {
	local session_key="$1"
	local attempt="$2"
	[[ -n "$session_key" && "$attempt" =~ ^[0-9]+$ ]] || return 1
	printf '%s-a%s' "$session_key" "$attempt"
	return 0
}

#######################################
# Write one CI repair state transition atomically.
#######################################
_ci_repair_write_state() {
	local state_file="$1"
	local repo_slug="$2"
	local pr_number="$3"
	local pr_head_sha="$4"
	local pr_head_ref="$5"
	local failure_fingerprint="$6"
	local worktree_path="$7"
	local worker_pid="$8"
	local pid_start="$9"
	local attempt="${10:-1}"
	local status="${11:-preparing}"
	local session_key="${12:-}"
	local tmp_file="${state_file}.tmp.$$"
	local updated_at="" started_at="" outcome_id=""
	local prior_state="" prior_attempt="" prior_started_at=""

	updated_at=$(date +%s 2>/dev/null) || updated_at=0
	started_at="$updated_at"
	if [[ -f "$state_file" ]]; then
		prior_state=$(jq -r '[.attempt // 0, .started_at // .updated_at // 0] | @tsv' "$state_file" 2>/dev/null) || prior_state=""
		IFS=$'\t' read -r prior_attempt prior_started_at <<<"$prior_state"
		if [[ "$prior_attempt" == "$attempt" && "$prior_started_at" =~ ^[0-9]+$ ]]; then
			started_at="$prior_started_at"
		fi
	fi
	outcome_id=$(_ci_repair_outcome_id "$session_key" "$attempt" 2>/dev/null) || outcome_id=""
	jq -nc \
		--arg repo "$repo_slug" --argjson pr "$pr_number" --arg head "$pr_head_sha" \
		--arg branch "$pr_head_ref" --arg fingerprint "$failure_fingerprint" \
		--arg worktree "$worktree_path" --argjson pid "$worker_pid" --arg pid_start "$pid_start" \
		--argjson attempt "$attempt" --arg status "$status" --arg session "$session_key" --arg outcome_id "$outcome_id" \
		--argjson started_at "$started_at" --argjson updated_at "$updated_at" \
		'{repo:$repo,pr:$pr,head:$head,branch:$branch,fingerprint:$fingerprint,
		worktree:$worktree,pid:$pid,pid_start:$pid_start,attempt:$attempt,status:$status,session:$session,
		outcome_id:$outcome_id,started_at:$started_at,updated_at:$updated_at,
		result:"",failure_reason:"",next_action:""}' \
		>"$tmp_file" 2>/dev/null || {
		rm -f "$tmp_file"
		return 1
	}
	if ! mv "$tmp_file" "$state_file" 2>/dev/null; then
		rm -f "$tmp_file"
		return 1
	fi
	return 0
}

#######################################
# Return the trusted headless-runtime outcome file for one bounded attempt.
#######################################
_ci_repair_outcome_file() {
	local lease_dir="$1"
	local attempt="$2"
	printf '%s/outcome-attempt-%s.state' "$lease_dir" "$attempt"
	return 0
}

#######################################
# Read one exact key from a trusted headless-runtime outcome file.
#######################################
_ci_repair_outcome_value() {
	local outcome_file="$1"
	local expected_key="$2"
	local key="" value=""
	[[ -f "$outcome_file" && ! -L "$outcome_file" ]] || return 0
	while IFS='=' read -r key value; do
		if [[ "$key" == "$expected_key" ]]; then
			printf '%s' "$value"
			return 0
		fi
	done <"$outcome_file"
	return 0
}

#######################################
# Bound one lifecycle value to a log/Markdown-safe token.
#######################################
_ci_repair_sanitize_outcome_value() {
	local raw_value="$1"
	local safe_value=""
	safe_value=$(printf '%s' "$raw_value" | tr -cd '[:alnum:]_.:-')
	printf '%.160s' "$safe_value"
	return 0
}

#######################################
# Project a trusted headless-runtime outcome into stable CI-repair fields.
# Output: result|failure_reason|next_action|retry_class|session_count|finished_at
#######################################
_ci_repair_project_outcome() {
	local state_file="$1"
	local outcome_file="$2"
	local status="" reason="" retry_class="" session_count="0" finished_at="0"
	local expected_outcome_id="" expected_session="" started_at="0" observed_outcome_id="" observed_session=""
	local now="0" outcome_present=0 outcome_valid=0 invalid_reason=""
	local failed_result="failed"
	local result="$failed_result" failure_reason="" next_action="inspect_terminal_outcome"

	status=$(jq -r '.status // empty' "$state_file" 2>/dev/null) || status=""
	expected_outcome_id=$(jq -r '.outcome_id // empty' "$state_file" 2>/dev/null) || expected_outcome_id=""
	expected_session=$(jq -r '.session // empty' "$state_file" 2>/dev/null) || expected_session=""
	started_at=$(jq -r '.started_at // .updated_at // 0' "$state_file" 2>/dev/null) || started_at=0
	if [[ -f "$outcome_file" && ! -L "$outcome_file" && -O "$outcome_file" ]]; then
		outcome_present=1
		reason=$(_ci_repair_outcome_value "$outcome_file" reason)
		retry_class=$(_ci_repair_outcome_value "$outcome_file" retry_class)
		session_count=$(_ci_repair_outcome_value "$outcome_file" session_count)
		finished_at=$(_ci_repair_outcome_value "$outcome_file" finished_at)
		observed_outcome_id=$(_ci_repair_outcome_value "$outcome_file" outcome_id)
		observed_session=$(_ci_repair_outcome_value "$outcome_file" session_key)
	fi
	now=$(date +%s 2>/dev/null) || now=0
	if [[ -n "$expected_outcome_id" && "$observed_outcome_id" == "$expected_outcome_id" \
		&& -n "$expected_session" && "$observed_session" == "$expected_session" \
		&& -n "$reason" && "$session_count" =~ ^[0-9]+$ \
		&& "$started_at" =~ ^[0-9]+$ && "$finished_at" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ \
		&& "$finished_at" -ge "$started_at" && "$finished_at" -le $((now + 5)) ]]; then
		outcome_valid=1
	fi
	if [[ "$outcome_valid" -eq 1 ]]; then
		reason=$(_ci_repair_sanitize_outcome_value "$reason")
		retry_class=$(_ci_repair_sanitize_outcome_value "$retry_class")
	else
		[[ "$outcome_present" -eq 0 ]] || invalid_reason="headless_outcome_contract_mismatch"
		reason=""
		retry_class=""
		session_count=0
		finished_at=0
	fi

	if [[ -z "$reason" ]]; then
		case "$status" in
		worktree_failed)
			result="launch_failed"
			failure_reason="worktree_failed"
			next_action="retry_launch"
			;;
		preparing)
			result="launch_interrupted"
			failure_reason="headless_launch_interrupted"
			next_action="retry_launch"
			;;
		*)
			result="process_exit"
			failure_reason="${invalid_reason:-headless_outcome_missing}"
			next_action="inspect_terminal_outcome"
			;;
		esac
	else
		failure_reason="$reason"
		case "$reason" in
		worker_complete)
			result="success"
			failure_reason=""
			next_action="monitor_pr"
			;;
		worker_draft_checkpoint)
			result="deferred"
			next_action="continue_repair"
			;;
		*)
			case "$retry_class" in
			infrastructure)
				result="retryable"
				next_action="retry_infrastructure"
				;;
			maintainer_gate)
				result="blocked"
				next_action="await_maintainer"
				;;
			remediation)
				result="$failed_result"
				next_action="inspect_and_continue_repair"
				;;
			*)
				result="$failed_result"
				next_action="inspect_terminal_outcome"
				;;
			esac
			;;
		esac
	fi
	printf '%s|%s|%s|%s|%s|%s' "$result" "$failure_reason" "$next_action" \
		"$retry_class" "$session_count" "$finished_at"
	return 0
}

#######################################
# Archive one completed/dead attempt with sanitized terminal lifecycle fields.
#######################################
_ci_repair_archive_attempt() {
	local state_file="$1"
	local lease_dir="$2"
	local attempt="$3"
	local outcome_file="" archive_file="" projection="" tmp_file=""
	local result="" failure_reason="" next_action="" retry_class="" session_count="0" finished_at="0"

	[[ -f "$state_file" && "$attempt" =~ ^[0-9]+$ ]] || return 1
	outcome_file=$(_ci_repair_outcome_file "$lease_dir" "$attempt")
	archive_file="${lease_dir}/state-attempt-${attempt}.json"
	projection=$(_ci_repair_project_outcome "$state_file" "$outcome_file") || return 1
	IFS='|' read -r result failure_reason next_action retry_class session_count finished_at <<<"$projection"
	tmp_file="${state_file}.archive.tmp.$$"
	jq --arg result "$result" --arg failure_reason "$failure_reason" --arg next_action "$next_action" \
		--arg retry_class "$retry_class" --argjson session_count "$session_count" --argjson finished_at "$finished_at" \
		'. + {result:$result,failure_reason:$failure_reason,next_action:$next_action,retry_class:$retry_class,
		session_count:$session_count,finished_at:$finished_at}' "$state_file" >"$tmp_file" 2>/dev/null || {
		rm -f "$tmp_file"
		return 1
	}
	mv "$tmp_file" "$archive_file" 2>/dev/null || {
		rm -f "$tmp_file"
		return 1
	}
	rm -f "$state_file" "$outcome_file" 2>/dev/null || true
	return 0
}

#######################################
# Render bounded archived outcomes for durable fallback feedback.
#######################################
_ci_repair_attempt_summary() {
	local lease_dir="$1"
	local archived_state="" shown=0
	for archived_state in "${lease_dir}"/state-attempt-*.json; do
		[[ -f "$archived_state" ]] || continue
		shown=$((shown + 1))
		[[ "$shown" -le 10 ]] || break
		jq -r '"- Attempt \(.attempt // "unknown"): result=`\(.result // "unknown")`; failure_reason=`\(.failure_reason // "")`; next_action=`\(.next_action // "inspect_terminal_outcome")`"' \
			"$archived_state" 2>/dev/null || true
	done
	return 0
}

#######################################
# Return the stable process-start token used to reject reused PIDs.
#######################################
_ci_repair_process_start() {
	local worker_pid="$1"
	ps -p "$worker_pid" -o lstart= 2>/dev/null || true
	return 0
}

#######################################
# Return whether a recorded process identity is still live.
#######################################
_ci_repair_pid_is_live() {
	local worker_pid="$1"
	local expected_start="$2"
	local current_start=""

	[[ "$worker_pid" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$expected_start" ]] || return 1
	kill -0 "$worker_pid" 2>/dev/null || return 1
	current_start=$(_ci_repair_process_start "$worker_pid")
	[[ -n "$current_start" && "$current_start" == "$expected_start" ]] || return 1
	return 0
}

#######################################
# Publish ownership for a newly acquired transition lock.
#######################################
_ci_repair_publish_lock_owner() {
	local lock_dir="$1"
	local owner_file="${lock_dir}/owner.json"
	local owner_tmp="${lock_dir}/owner.json.tmp.$$"
	local current_start=""

	current_start=$(_ci_repair_process_start "$$")
	[[ -n "$current_start" ]] || return 1
	jq -nc --argjson pid "$$" --arg pid_start "$current_start" \
		'{pid:$pid,pid_start:$pid_start}' >"$owner_tmp" 2>/dev/null || return 1
	mv "$owner_tmp" "$owner_file" 2>/dev/null || {
		rm -f "$owner_tmp"
		return 1
	}
	return 0
}

#######################################
# Return whether a claim is old enough to treat missing ownership as abandoned.
#######################################
_ci_repair_lock_is_stale() {
	local lock_dir="$1"
	local grace_seconds="${AIDEVOPS_CI_REPAIR_LOCK_GRACE_SECONDS:-2}"
	local now="" lock_mtime="" lock_age=""

	[[ "$grace_seconds" =~ ^[0-9]+$ ]] || grace_seconds=2
	now=$(date +%s 2>/dev/null) || now=0
	lock_mtime=$(_file_mtime_epoch "$lock_dir" 2>/dev/null) || lock_mtime="$now"
	[[ "$lock_mtime" =~ ^[0-9]+$ ]] || lock_mtime="$now"
	lock_age=$((now - lock_mtime))
	[[ "$lock_age" -ge "$grace_seconds" ]]
	return $?
}

#######################################
# Return whether an append-only attempt claim is still active.
#######################################
_ci_repair_claim_dir_is_active() {
	local claim_dir="$1"
	local owner_file="${claim_dir}/owner.json"
	local owner_pid="" owner_start=""

	if [[ -f "$owner_file" ]]; then
		owner_pid=$(jq -r '.pid // empty' "$owner_file" 2>/dev/null) || owner_pid=""
		owner_start=$(jq -r '.pid_start // empty' "$owner_file" 2>/dev/null) || owner_start=""
		if _ci_repair_pid_is_live "$owner_pid" "$owner_start"; then
			return 0
		fi
	fi
	_ci_repair_lock_is_stale "$claim_dir" && return 1
	return 0
}

_ci_repair_status_preparing() {
	printf 'preparing'
	return 0
}

_ci_repair_status_dispatched() {
	printf 'dispatched'
	return 0
}

_ci_repair_result_active() {
	printf 'active'
	return 0
}

_ci_repair_result_exhausted() {
	printf 'exhausted'
	return 0
}

_ci_repair_result_retryable() {
	printf 'retryable'
	return 0
}

#######################################
# Atomically claim the first unconsumed bounded repair attempt.
#######################################
_ci_repair_claim_next_attempt() {
	local lease_dir="$1"
	local first_attempt="$2"
	local max_attempts="$3"
	local attempt="$first_attempt"
	local claim_dir="" active_result="" exhausted_result=""

	active_result=$(_ci_repair_result_active)
	exhausted_result=$(_ci_repair_result_exhausted)
	while [[ "$attempt" -le "$max_attempts" ]]; do
		claim_dir="${lease_dir}/attempt-${attempt}.claim"
		if mkdir "$claim_dir" 2>/dev/null; then
			_ci_repair_publish_lock_owner "$claim_dir" || return 1
			printf '%s' "$attempt"
			return 0
		fi
		if _ci_repair_claim_dir_is_active "$claim_dir"; then
			printf '%s' "$active_result"
			return 0
		fi
		attempt=$((attempt + 1))
	done
	printf '%s' "$exhausted_result"
	return 0
}

#######################################
# Return the latest archived attempt and its preserved worktree.
#######################################
_ci_repair_latest_archive() {
	local lease_dir="$1"
	local archived_state=""
	local archived_attempt="0"
	local candidate_attempt="0"
	local worktree_path=""

	for archived_state in "${lease_dir}"/state-attempt-*.json; do
		[[ -f "$archived_state" ]] || continue
		candidate_attempt=$(jq -r '.attempt // 0' "$archived_state" 2>/dev/null) || candidate_attempt="0"
		[[ "$candidate_attempt" =~ ^[0-9]+$ ]] || candidate_attempt=0
		if [[ "$candidate_attempt" -ge "$archived_attempt" ]]; then
			archived_attempt="$candidate_attempt"
			worktree_path=$(jq -r '.worktree // empty' "$archived_state" 2>/dev/null) || worktree_path=""
		fi
	done
	printf '%s|%s' "$archived_attempt" "$worktree_path"
	return 0
}

#######################################
# Publish dispatcher ownership for one attempt while the transition lock is held.
#######################################
_ci_repair_prepare_attempt() {
	local state_file="$1"
	local repo_slug="$2"
	local pr_number="$3"
	local pr_head_sha="$4"
	local pr_head_ref="$5"
	local failure_fingerprint="$6"
	local worktree_path="$7"
	local attempt="$8"
	local session_key="$9"
	local process_start=""
	local preparing_status=""

	process_start=$(_ci_repair_process_start "$$")
	preparing_status=$(_ci_repair_status_preparing)
	_ci_repair_write_state "$state_file" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
		"$failure_fingerprint" "$worktree_path" "$$" "$process_start" "$attempt" "$preparing_status" "$session_key"
	return $?
}

#######################################
# Adopt a live native headless session after an interrupted dispatcher handoff.
#######################################
_ci_repair_adopt_live_session() {
	local state_file="$1"
	local repo_slug="$2"
	local pr_number="$3"
	local pr_head_sha="$4"
	local pr_head_ref="$5"
	local failure_fingerprint="$6"
	local worktree_path="$7"
	local attempt="$8"
	local session_key="$9"
	local session_identity=""
	local worker_pid=""
	local process_start=""
	local dispatched_status=""

	session_identity=$(_ci_repair_session_identity "$session_key" 2>/dev/null) || return 1
	worker_pid="${session_identity%%|*}"
	process_start="${session_identity#*|}"
	dispatched_status=$(_ci_repair_status_dispatched)
	_ci_repair_write_state "$state_file" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
		"$failure_fingerprint" "$worktree_path" "$worker_pid" "$process_start" "$attempt" "$dispatched_status" "$session_key" || return 1
	echo "[pulse-wrapper] _dispatch_ci_repair_session: adopted live native session ${session_key} after interrupted lease handoff (pid ${worker_pid})" >>"$LOGFILE"
	return 0
}

#######################################
# Claim or recover the durable lease for one CI repair tuple.
#
# Output: "launch|ATTEMPT|WORKTREE", "active", or "exhausted".
#######################################
_ci_repair_claim_lease() {
	local lease_dir="$1"
	local repo_slug="$2"
	local pr_number="$3"
	local pr_head_sha="$4"
	local failure_fingerprint="$5"
	local max_attempts="$6"
	local pr_head_ref="$7"
	local session_key="$8"
	local state_file="${lease_dir}/state.json"
	local existing_pid="" existing_pid_start="" existing_attempt="1"
	local existing_worktree="" next_attempt="" archive_payload="" archived_attempt="0" claim_result=""
	local existing_status="" updated_at="0" now="0" launch_grace="${AIDEVOPS_CI_REPAIR_LAUNCH_GRACE_SECONDS:-}"
	local canary_timeout="${CANARY_TIMEOUT_SECONDS:-180}"
	local active_result="" exhausted_result=""

	active_result=$(_ci_repair_result_active)
	exhausted_result=$(_ci_repair_result_exhausted)
	[[ "$max_attempts" =~ ^[0-9]+$ ]] || max_attempts=2
	[[ "$max_attempts" -gt 0 ]] || max_attempts=2
	[[ "$canary_timeout" =~ ^[0-9]+$ ]] || canary_timeout=180
	[[ "$launch_grace" =~ ^[0-9]+$ ]] || launch_grace=$((canary_timeout + 60))
	[[ -d "$lease_dir" ]] || return 1

	if [[ ! -f "$state_file" ]]; then
		archive_payload=$(_ci_repair_latest_archive "$lease_dir")
		archived_attempt="${archive_payload%%|*}"
		existing_worktree="${archive_payload#*|}"
		next_attempt=$((archived_attempt + 1))
		if _ci_repair_adopt_live_session "$state_file" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
			"$failure_fingerprint" "$existing_worktree" "$next_attempt" "$session_key"; then
			printf '%s' "$active_result"
			return 0
		fi
		claim_result=$(_ci_repair_claim_next_attempt "$lease_dir" "$next_attempt" "$max_attempts") || return 1
		case "$claim_result" in
		"$active_result" | "$exhausted_result")
			printf '%s' "$claim_result"
			return 0
			;;
		*) [[ "$claim_result" =~ ^[0-9]+$ ]] || return 1 ;;
		esac
		next_attempt="$claim_result"
		_ci_repair_prepare_attempt "$state_file" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
			"$failure_fingerprint" "$existing_worktree" "$next_attempt" "$session_key" || return 1
		echo "[pulse-wrapper] _dispatch_ci_repair_session: recovered incomplete lease state for ${repo_slug} PR #${pr_number} as attempt ${next_attempt}/${max_attempts}" >>"$LOGFILE"
		printf 'launch|%s|%s' "$next_attempt" "$existing_worktree"
		return 0
	fi
	existing_pid=$(jq -r '.pid // empty' "$state_file" 2>/dev/null) || existing_pid=""
	existing_pid_start=$(jq -r '.pid_start // empty' "$state_file" 2>/dev/null) || existing_pid_start=""
	existing_attempt=$(jq -r '.attempt // 1' "$state_file" 2>/dev/null) || existing_attempt="1"
	existing_status=$(jq -r '.status // empty' "$state_file" 2>/dev/null) || existing_status=""
	updated_at=$(jq -r '.updated_at // 0' "$state_file" 2>/dev/null) || updated_at="0"
	[[ "$existing_attempt" =~ ^[0-9]+$ ]] || existing_attempt=1
	[[ "$updated_at" =~ ^[0-9]+$ ]] || updated_at=0
	if _ci_repair_pid_is_live "$existing_pid" "$existing_pid_start"; then
		echo "[pulse-wrapper] _dispatch_ci_repair_session: repair already active for ${repo_slug} PR #${pr_number} head ${pr_head_sha} fingerprint ${failure_fingerprint} (pid ${existing_pid}, attempt ${existing_attempt})" >>"$LOGFILE"
		printf '%s' "$active_result"
		return 0
	fi
	existing_worktree=$(jq -r '.worktree // empty' "$state_file" 2>/dev/null) || existing_worktree=""
	if _ci_repair_adopt_live_session "$state_file" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
		"$failure_fingerprint" "$existing_worktree" "$existing_attempt" "$session_key"; then
		printf '%s' "$active_result"
		return 0
	fi
	now=$(date +%s 2>/dev/null) || now=0
	if [[ "$existing_status" == "$(_ci_repair_status_preparing)" && $((now - updated_at)) -lt "$launch_grace" ]]; then
		printf '%s' "$active_result"
		return 0
	fi
	next_attempt=$((existing_attempt + 1))
	claim_result=$(_ci_repair_claim_next_attempt "$lease_dir" "$next_attempt" "$max_attempts") || return 1
	if [[ "$claim_result" == "$active_result" ]]; then
		printf '%s' "$active_result"
		return 0
	fi
	if [[ "$claim_result" == "$exhausted_result" ]]; then
		if ! _ci_repair_archive_attempt "$state_file" "$lease_dir" "$existing_attempt"; then
			printf '%s' "$active_result"
			return 0
		fi
		echo "[pulse-wrapper] _dispatch_ci_repair_session: stale repair exhausted ${max_attempts} attempts for ${repo_slug} PR #${pr_number} head ${pr_head_sha} fingerprint ${failure_fingerprint}" >>"$LOGFILE"
		printf '%s' "$exhausted_result"
		return 0
	fi
	[[ "$claim_result" =~ ^[0-9]+$ ]] || return 1
	next_attempt="$claim_result"
	if ! _ci_repair_archive_attempt "$state_file" "$lease_dir" "$existing_attempt"; then
		printf '%s' "$active_result"
		return 0
	fi
	_ci_repair_prepare_attempt "$state_file" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
		"$failure_fingerprint" "$existing_worktree" "$next_attempt" "$session_key" || return 1
	echo "[pulse-wrapper] _dispatch_ci_repair_session: recovering stale repair for ${repo_slug} PR #${pr_number} head ${pr_head_sha} fingerprint ${failure_fingerprint} as attempt ${next_attempt}/${max_attempts}" >>"$LOGFILE"
	printf 'launch|%s|%s' "$next_attempt" "$existing_worktree"
	return 0
}

#######################################
# Create a linked repair worktree at the exact PR head SHA.
#
# Output: absolute worktree path.
#######################################
_ci_repair_create_worktree() {
	local repo_path="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local pr_number="$4"
	local pr_head_sha="$5"
	local pr_head_ref="$6"
	local failure_fingerprint="$7"
	local attempt="$8"
	local worktree_helper="${AIDEVOPS_WORKTREE_HELPER:-${_PULSE_MERGE_DIR:-${BASH_SOURCE[0]%/*}}/worktree-helper.sh}"
	local worktree_base="${AIDEVOPS_CI_REPAIR_WORKTREE_BASE_DIR:-${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}}"
	local repo_name=""
	local repo_hash=""
	local repair_branch=""
	local worktree_path=""
	local actual_head=""

	[[ -x "$worktree_helper" ]] || return 1
	[[ "$pr_head_sha" =~ ^[0-9a-fA-F]{7,64}$ ]] || return 1
	[[ -n "$pr_head_ref" ]] || return 1
	if ! git -C "$repo_path" cat-file -e "${pr_head_sha}^{commit}" 2>/dev/null; then
		git -C "$repo_path" fetch --no-tags --quiet origin "$pr_head_ref" >/dev/null 2>&1 || return 1
	fi
	git -C "$repo_path" cat-file -e "${pr_head_sha}^{commit}" 2>/dev/null || return 1

	repo_name=$(basename "$repo_path")
	repo_hash=$(_ci_repair_hash_text "$repo_slug") || return 1
	repair_branch="repair/${repo_hash}-pr-${pr_number}-${pr_head_sha:0:12}-${failure_fingerprint:0:12}-a${attempt}"
	worktree_path="${worktree_base}/${repo_name}-${repo_hash}-ci-repair-pr${pr_number}-${pr_head_sha:0:12}-${failure_fingerprint:0:12}-a${attempt}"
	mkdir -p "$worktree_base" 2>/dev/null || return 1
	if ! (cd "$repo_path" && AIDEVOPS_SKIP_AUTO_CLAIM=1 AIDEVOPS_WORKTREE_BASE_DIR="$worktree_base" "$worktree_helper" add "$repair_branch" "$worktree_path" \
		--base "$pr_head_sha" --issue "$linked_issue") >>"$LOGFILE" 2>&1; then
		return 1
	fi
	actual_head=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null) || actual_head=""
	if [[ "$actual_head" != "$pr_head_sha" ]]; then
		echo "[pulse-wrapper] _dispatch_ci_repair_session: repair worktree head mismatch for PR #${pr_number}: expected ${pr_head_sha}, got ${actual_head:-unknown}" >>"$LOGFILE"
		(cd "$repo_path" && "$worktree_helper" remove "$worktree_path" --force) >>"$LOGFILE" 2>&1 || true
		return 1
	fi
	printf '%s' "$worktree_path"
	return 0
}

#######################################
# Return a live headless runtime session lock as PID|process-start.
#######################################
_ci_repair_session_identity() {
	local session_key="$1"
	local state_dir="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
	local safe_key=""
	local lock_file=""
	local lock_value=""
	local worker_pid=""
	local stored_hash=""
	local process_start=""
	local process_pattern="${WORKER_PROCESS_PATTERN:-opencode|claude|Claude}|headless-runtime-helper"

	safe_key=$(printf '%s' "$session_key" | tr '/ ' '__')
	lock_file="${state_dir}/locks/${safe_key}.pid"
	[[ -f "$lock_file" ]] || return 1
	lock_value=$(sed -n '1p' "$lock_file" 2>/dev/null) || lock_value=""
	worker_pid="${lock_value%%|*}"
	stored_hash="${lock_value#*|}"
	[[ "$stored_hash" == "$worker_pid" ]] && stored_hash=""
	[[ "$worker_pid" =~ ^[0-9]+$ ]] || return 1
	declare -F _is_process_alive_and_matches >/dev/null 2>&1 || return 1
	_is_process_alive_and_matches "$worker_pid" "$process_pattern" "$stored_hash" || return 1
	process_start=$(_ci_repair_process_start "$worker_pid")
	[[ -n "$process_start" ]] || return 1
	printf '%s|%s' "$worker_pid" "$process_start"
	return 0
}

#######################################
# Resolve CI repair identity from the active gh credential context.
# Caller-provided environment identity is never accepted as authority.
#######################################
_ci_repair_resolve_runner_login() {
	local runner_login=""

	# #aidevops:trust-boundary — bind worker ownership to authenticated GitHub
	# identity rather than a mutable environment variable.
	runner_login=$(gh api user --jq '.login // ""' 2>/dev/null || true)
	if [[ "$runner_login" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
		printf '%s\n' "$runner_login"
		return 0
	fi

	runner_login=$(_pmf_gh_read gh api graphql \
		-f 'query=query { viewer { login } }' \
		--jq '.data.viewer.login // ""' 2>/dev/null || true)
	if [[ "$runner_login" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
		printf '%s\n' "$runner_login"
		return 0
	fi

	return 1
}

#######################################
# Launch through the runtime's native detach path and publish its process identity.
#######################################
_ci_repair_launch_worker() {
	local lease_dir="$1"
	local helper="$2"
	local repo_slug="$3"
	local pr_number="$4"
	local linked_issue="$5"
	local pr_head_sha="$6"
	local pr_head_ref="$7"
	local failure_fingerprint="$8"
	local worktree_path="$9"
	local attempt="${10:-1}"
	local session_key="${11:-}"
	local prompt_file="${12:-}"
	local launch_output=""
	local worker_pid=""
	local process_start=""
	local session_identity=""
	local dispatched_status=""
	local runner_login=""
	local wait_count=0
	local wait_max="${AIDEVOPS_CI_REPAIR_SESSION_LOCK_WAIT_STEPS:-200}"
	local process_pattern="${WORKER_PROCESS_PATTERN:-opencode|claude|Claude}|headless-runtime-helper"
	local outcome_file="" outcome_id=""

	[[ "$wait_max" =~ ^[0-9]+$ ]] || wait_max=200
	outcome_file=$(_ci_repair_outcome_file "$lease_dir" "$attempt")
	outcome_id=$(_ci_repair_outcome_id "$session_key" "$attempt") || return 1
	rm -f "$outcome_file" 2>/dev/null || true
	runner_login=$(_ci_repair_resolve_runner_login) || {
		printf '%s\n' "[pulse-wrapper] _ci_repair_launch_worker: authenticated GitHub runner identity unavailable for ${repo_slug} PR #${pr_number}; launch blocked" >>"$LOGFILE"
		return 1
	}
	launch_output=$(env \
		HEADLESS=1 WORKER_ISSUE_NUMBER="$linked_issue" WORKER_REPO_SLUG="$repo_slug" \
		WORKER_WORKTREE_PATH="$worktree_path" GITHUB_REPOSITORY="$repo_slug" \
		WORKER_NO_EXIT_PUSH=1 WORKER_PROCESS_PATTERN="$process_pattern" AIDEVOPS_ALLOW_WORKER_WORKTREE_OWNER_TRANSFER=1 \
		WORKER_GITHUB_LOGIN="$runner_login" \
		AIDEVOPS_PR_REPAIR_NUMBER="$pr_number" AIDEVOPS_PR_REPAIR_HEAD_SHA="$pr_head_sha" \
		AIDEVOPS_PR_REPAIR_HEAD_REF="$pr_head_ref" AIDEVOPS_PR_REPAIR_FINGERPRINT="$failure_fingerprint" \
		AIDEVOPS_PR_REPAIR_OWNERSHIP_MODE="linked-issue" \
		AIDEVOPS_HEADLESS_OUTCOME_FILE="$outcome_file" AIDEVOPS_HEADLESS_OUTCOME_ID="$outcome_id" \
		"$helper" run --role worker --session-key "$session_key" --dir "$worktree_path" \
		--title "PR #${pr_number}: CI repair" --prompt-file "$prompt_file" --detach \
		</dev/null 2>&1) || {
		printf '%s\n' "$launch_output" >>"$LOGFILE"
		return 1
	}
	printf '%s\n' "$launch_output" >>"$LOGFILE"
	worker_pid=$(printf '%s\n' "$launch_output" | sed -n 's/.*Dispatched PID: \([0-9][0-9]*\).*/\1/p' | sed -n '$p')
	while [[ "$wait_count" -lt "$wait_max" ]]; do
		session_identity=$(_ci_repair_session_identity "$session_key" 2>/dev/null) || session_identity=""
		[[ -n "$session_identity" ]] && break
		sleep 0.05
		wait_count=$((wait_count + 1))
	done
	if [[ -n "$session_identity" ]]; then
		worker_pid="${session_identity%%|*}"
		process_start="${session_identity#*|}"
	else
		[[ "$worker_pid" =~ ^[0-9]+$ ]] || return 1
		process_start=$(_ci_repair_process_start "$worker_pid")
		_ci_repair_pid_is_live "$worker_pid" "$process_start" || return 1
	fi
	dispatched_status=$(_ci_repair_status_dispatched)
	if ! _ci_repair_write_state "${lease_dir}/state.json" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
		"$failure_fingerprint" "$worktree_path" "$worker_pid" "$process_start" "$attempt" "$dispatched_status" "$session_key"; then
		return 1
	fi
	return 0
}

#######################################
# Write the bounded repair prompt for the existing PR branch.
#######################################
_ci_repair_write_prompt() {
	local prompt_file="$1"
	local repo_slug="$2"
	local pr_number="$3"
	local linked_issue="$4"
	local pr_head_sha="$5"
	local pr_head_ref="$6"
	local failure_fingerprint="$7"
	local failing_checks="$8"

	cat >"$prompt_file" <<-EOF
		[effort:thinking] Repair terminal CI failures on the existing PR branch.

		Repository: ${repo_slug}
		PR: #${pr_number}
		Linked issue: #${linked_issue}
		Expected head SHA: ${pr_head_sha}
		Existing head branch: ${pr_head_ref}
		Failure fingerprint: ${failure_fingerprint}

		Terminal failed checks:
		${failing_checks}

		Your linked worktree was created from the expected PR head SHA and may contain preserved
		changes from an interrupted repair attempt. Inspect and continue valuable existing work.
		Verify PR #${pr_number} still has remote head SHA ${pr_head_sha} before editing; if it
		changed, stop without pushing. Diagnose the cited logs, make only the CI repair, run focused
		checks, commit, and push HEAD back to remote branch ${pr_head_ref}. Do not open or close a
		PR, create another implementation branch, merge, or bypass trust or required checks.
	EOF
	return 0
}

#######################################
# Return whether a legacy fingerprint-scoped lease still owns a live worker.
#######################################
_ci_repair_legacy_lease_is_active() {
	local legacy_dir="$1"
	local expected_repo="$2"
	local expected_pr="$3"
	local expected_head="$4"
	local state_file="${legacy_dir}/state.json"
	local state_identity="" state_repo="" state_pr="" state_head="" state_fingerprint="" state_status=""
	local legacy_session_key="" legacy_session_identity=""

	[[ -f "$state_file" ]] || return 1
	state_identity=$(jq -r '[.repo // "", (.pr // "" | tostring), .head // "", .fingerprint // "", .status // ""] | @tsv' "$state_file" 2>/dev/null) || return 1
	IFS=$'\t' read -r state_repo state_pr state_head state_fingerprint state_status <<<"$state_identity"
	[[ "$state_repo" == "$expected_repo" && "$state_pr" == "$expected_pr" && "$state_head" == "$expected_head" ]] || return 1
	[[ "$state_status" == "$(_ci_repair_status_dispatched)" && -n "$state_fingerprint" ]] || return 1
	legacy_session_key="ci-repair-${expected_pr}-${expected_head:0:12}-${state_fingerprint:0:12}"
	legacy_session_identity=$(_ci_repair_session_identity "$legacy_session_key" 2>/dev/null) || return 1
	[[ -n "$legacy_session_identity" ]]
	return $?
}

_ci_repair_hash_text() {
	local input_text="$1"
	local content_hash=""

	if command -v sha256sum >/dev/null 2>&1; then
		content_hash=$(printf '%s' "$input_text" | sha256sum 2>/dev/null | cut -d ' ' -f 1) || return 1
	elif command -v shasum >/dev/null 2>&1; then
		content_hash=$(printf '%s' "$input_text" | shasum -a 256 2>/dev/null | cut -d ' ' -f 1) || return 1
	else
		return 1
	fi
	[[ "$content_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
	printf '%s' "$content_hash"
	return 0
}

_ci_repair_session_key() {
	local repo_slug="$1"
	local pr_number="$2"
	local pr_head_sha="$3"
	local repo_hash=""

	repo_hash=$(_ci_repair_hash_text "$repo_slug") || return 1
	printf 'ci-repair-%s-%s-%s' "$repo_hash" "$pr_number" "${pr_head_sha:0:12}"
	return 0
}

#######################################
# Launch one bounded repair session for a repository/PR/head tuple.
# The state directory is the cross-pulse dedup lease. A dead worker may be
# retried once; repeated terminal attempts take the durable fallback.
#######################################
_dispatch_ci_repair_session() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local pr_head_sha="$4"
	local pr_head_ref="$5"
	local failure_fingerprint="$6"
	local failing_checks="$7"
	local repo_path="" helper="" state_root="" state_key="" legacy_state_key="" lease_dir="" prompt_file="" session_key="" legacy_dir="" repo_hash=""
	local lease_action=""
	local max_attempts="${AIDEVOPS_CI_REPAIR_MAX_ATTEMPTS:-2}"
	local attempt=""
	local worktree_path=""
	local launch_payload=""
	local active_result=""
	local exhausted_result=""
	local retryable_result=""
	local dispatched_status=""
	active_result=$(_ci_repair_result_active)
	exhausted_result=$(_ci_repair_result_exhausted)
	retryable_result=$(_ci_repair_result_retryable)
	dispatched_status=$(_ci_repair_status_dispatched)
	_CI_REPAIR_DISPATCH_RESULT="$retryable_result"

	repo_path=$(_pulse_merge_repo_path_for_slug "$repo_slug" 2>/dev/null) || repo_path=""
	helper="${AIDEVOPS_HEADLESS_RUNTIME_HELPER:-${_PULSE_MERGE_DIR:-${BASH_SOURCE[0]%/*}}/headless-runtime-helper.sh}"
	[[ -n "$repo_path" && -d "$repo_path" ]] || return 1
	[[ -x "$helper" ]] || return 1

	state_root="${AIDEVOPS_CI_REPAIR_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/ci-pr-repair}"
	repo_hash=$(_ci_repair_hash_text "$repo_slug") || return 1
	state_key="${repo_hash}-${pr_number}-${pr_head_sha}"
	legacy_state_key=$(printf '%s-%s-%s' "$repo_slug" "$pr_number" "$pr_head_sha" | tr '/:' '__')
	lease_dir="${state_root}/${state_key}"
	for legacy_dir in "${state_root}/${legacy_state_key}-"*; do
		[[ -d "$legacy_dir" ]] || continue
		if _ci_repair_legacy_lease_is_active "$legacy_dir" "$repo_slug" "$pr_number" "$pr_head_sha"; then
			echo "[pulse-wrapper] _dispatch_ci_repair_session: legacy repair lease remains active for ${repo_slug} PR #${pr_number} head ${pr_head_sha}" >>"$LOGFILE"
			_CI_REPAIR_DISPATCH_RESULT="$active_result"
			return 0
		fi
	done
	session_key=$(_ci_repair_session_key "$repo_slug" "$pr_number" "$pr_head_sha")
	mkdir -p "$lease_dir" 2>/dev/null || return 1
	lease_action=$(_ci_repair_claim_lease "$lease_dir" "$repo_slug" "$pr_number" "$pr_head_sha" \
		"$failure_fingerprint" "$max_attempts" "$pr_head_ref" "$session_key") || return 1
	case "$lease_action" in
	"$active_result")
		_CI_REPAIR_DISPATCH_RESULT="$active_result"
		return 0
		;;
	"$exhausted_result")
		_CI_REPAIR_OUTCOME_SUMMARY=$(_ci_repair_attempt_summary "$lease_dir")
		_CI_REPAIR_DISPATCH_RESULT="$exhausted_result"
		return 1
		;;
	launch\|*)
		launch_payload="${lease_action#launch|}"
		attempt="${launch_payload%%|*}"
		worktree_path="${launch_payload#*|}"
		if [[ ! "$attempt" =~ ^[0-9]+$ ]]; then
			return 1
		fi
		;;
	*)
		return 1
		;;
	esac

	if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
		echo "[pulse-wrapper] _dispatch_ci_repair_session: resuming stale repair worktree ${worktree_path} for ${repo_slug} PR #${pr_number} attempt ${attempt}/${max_attempts}" >>"$LOGFILE"
	else
		worktree_path=$(_ci_repair_create_worktree "$repo_path" "$repo_slug" "$linked_issue" "$pr_number" "$pr_head_sha" \
			"$pr_head_ref" "$failure_fingerprint" "$attempt") || worktree_path=""
	fi
	if [[ -z "$worktree_path" || ! -d "$worktree_path" ]]; then
		_ci_repair_write_state "${lease_dir}/state.json" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
			"$failure_fingerprint" "" "0" "" "$attempt" "worktree_failed" "$session_key" || true
		return 1
	fi
	_ci_repair_prepare_attempt "${lease_dir}/state.json" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
		"$failure_fingerprint" "$worktree_path" "$attempt" "$session_key" || return 1

	prompt_file="${lease_dir}/prompt.md"
	_ci_repair_write_prompt "$prompt_file" "$repo_slug" "$pr_number" "$linked_issue" "$pr_head_sha" \
		"$pr_head_ref" "$failure_fingerprint" "$failing_checks" || return 1
	if ! _ci_repair_launch_worker "$lease_dir" "$helper" "$repo_slug" "$pr_number" "$linked_issue" \
		"$pr_head_sha" "$pr_head_ref" "$failure_fingerprint" "$worktree_path" "$attempt" "$session_key" "$prompt_file"; then
		return 1
	fi
	_CI_REPAIR_DISPATCH_RESULT="$dispatched_status"
	return 0
}

#######################################
# Build a whole-token lookup set for add/add conflict paths (t3199).
#
# Args:
#   $1 - (optional) path to a git repo with an in-flight rebase/merge.
#
# Output: space-padded path set suitable for `[[ "$set" == *" $path "* ]]`.
#######################################
