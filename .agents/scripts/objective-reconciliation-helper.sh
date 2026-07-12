#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# objective-reconciliation-helper.sh — derive durable objective state and recovery.

set -uo pipefail

OBJECTIVE_DEFAULT_TTL_SECS="${AIDEVOPS_OBJECTIVE_ASSUMPTION_TTL_SECS:-3600}"
OBJECTIVE_DEFAULT_MAX_REPAIRS="${AIDEVOPS_OBJECTIVE_MAX_REPAIRS:-25}"

_objective_usage() {
	cat <<'EOF'
Usage:
  objective-reconciliation-helper.sh derive [--input FILE] [--now EPOCH] [--ttl SECONDS]
  objective-reconciliation-helper.sh reconcile --repo OWNER/REPO [--input FILE]
      [--state-file FILE] [--now EPOCH] [--ttl SECONDS] [--max-repairs COUNT]
  objective-reconciliation-helper.sh summary [--state-file FILE]

Input is either an issue array or an object containing `issues`, `prs`, and an
optional pipe-delimited `merged_lookup`. Reconciliation is API-free: its
idempotent repair is a durable, bounded next-action ledger consumed by pulse.
EOF
	return 0
}

_objective_now() {
	date +%s 2>/dev/null || printf '0\n'
	return 0
}

_objective_validate_uint() {
	local value="$1"
	local fallback="$2"
	if [[ "$value" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$value"
	else
		printf '%s\n' "$fallback"
	fi
	return 0
}

_objective_read_input() {
	local input_file="$1"
	if [[ "$input_file" == "-" ]]; then
		jq -c '.'
	elif [[ -r "$input_file" ]]; then
		jq -c '.' "$input_file"
	else
		printf 'ERROR: objective input is not readable: %s\n' "$input_file" >&2
		return 2
	fi
	return $?
}

_objective_attach_durable_evidence() {
	local input_json="$1"
	local repo="$2"
	local evidence_file="${AIDEVOPS_OBJECTIVE_EVIDENCE_FILE:-${HOME}/.aidevops/state/objective-evidence.jsonl}"
	local evidence_limit="${AIDEVOPS_OBJECTIVE_EVIDENCE_LIMIT:-2000}"
	[[ "$evidence_limit" =~ ^[1-9][0-9]*$ ]] || evidence_limit=2000
	if [[ ! -s "$evidence_file" ]]; then
		printf '%s\n' "$input_json"
		return 0
	fi
	local evidence_json="[]"
	evidence_json=$(tail -n "$evidence_limit" "$evidence_file" 2>/dev/null | jq -sc '[.[] | select(type == "object")]') || evidence_json="[]"
	jq -nc --arg repo "$repo" --argjson input "$input_json" --argjson evidence "$evidence_json" '
		(if ($input | type) == "array" then {issues:$input, prs:[], merged_lookup:""} else $input end) |
		.issues = [(.issues // [])[] | . as $issue |
			([$evidence[] | select(.repo == ($issue.repo // $repo) and (.issue_number | tonumber) == (($issue.number // 0) | tonumber))] | sort_by(.evidence_timestamp) | last // {}) as $event |
			if ($event | length) == 0 then $issue else
				$issue + {
					evidence_timestamp: $event.evidence_timestamp,
					lease_active: true,
					process_active: ($event.event_type != "worker.completed" and $event.event_type != "worker.failed"),
					execution_path_state: $event.execution_path_state,
					branch_exists: ($event.branch_preserved // false),
					worktree_exists: ($event.worktree_preserved // false),
					commits_preserved: ($event.commits_preserved // false),
					logs_preserved: ($event.logs_preserved // false),
					verification_preserved: ($event.verification_preserved // false),
					subsequent_action_at: ($event.subsequent_action_at // 0),
					recovery_attempt: ($event.recovery_attempt // ($issue.recovery_attempt // 0))
				}
			end
		]'
	return $?
}

_objective_derive_json() {
	local input_json="$1" repo="$2" now_epoch="$3" ttl_secs="$4"
	printf '%s' "$input_json" | jq -c --arg repo "$repo" --argjson now "$now_epoch" --argjson ttl "$ttl_secs" '
		def labels: [(.labels // [])[] | if type == "object" then .name else . end] | map(select(type == "string"));
		def has_label($name): labels | index($name) != null;
		def has_status($name): has_label("status:" + $name);
		def state_completed: "completed"; def state_cancelled: "cancelled"; def state_impossible: "impossible"; def action_none: "none";
		def action_resume: "resume_session"; def action_recover_branch: "recover_branch"; def action_repair_pr: "repair_pr"; def action_redispatch: "narrow_redispatch";
		def evidence_epoch:
			(.evidence_timestamp // .evidence_at // .updatedAt // .updated_at // $now) as $value |
			if ($value | type) == "number" then $value elif ($value | type) == "string"
			then (($value | fromdateiso8601?) // ($value | tonumber?) // $now) else $now end;
		def issue_number: (.number // .issue_number // 0) | tonumber;
		def matching_pr($prs):
			issue_number as $number |
			("(^|[^0-9])#?" + ($number | tostring) + "([^0-9]|$)") as $number_pattern |
			first($prs[]? | select(((.issue_number // 0) | tonumber) == $number or
				((.title // "") | test($number_pattern)) or
				((.headRefName // .head_ref_name // "") | test($number_pattern)))) // {};
		def ladder($attempt; $authority):
			if $attempt <= 0 then "retry_infrastructure"
			elif $attempt == 1 then action_resume
			elif $attempt == 2 then action_recover_branch
			elif $attempt == 3 then action_repair_pr
			elif $attempt == 4 then action_redispatch
			elif $attempt == 5 then "model_escalation"
			elif $attempt == 6 then "diagnostic_worker"
			elif $authority then "decision_ready_human_packet"
			else "diagnostic_worker" end;
		def owner_for($action):
			if $action == "monitor_worker" or $action == action_resume then "worker-supervisor"
			elif $action == "monitor_pr" or $action == action_repair_pr then "pr-repair"
			elif $action == "reverify_dependency" then "dependency-monitor"
			elif $action == "decision_ready_human_packet" then "maintainer-gate"
			elif $action == "close_issue" then "issue-reconciler"
			elif $action == action_none then action_none
			else "pulse-dispatch" end;
		(.issues // (if type == "array" then . else [] end)) as $issues | (.prs // []) as $prs | (.merged_lookup // "") as $merged_lookup |
		[$issues[] |
			. as $issue |
			labels as $labels |
			issue_number as $number |
			evidence_epoch as $evidence |
			matching_pr($prs) as $pr |
			(($issue.pr // {}) + $pr) as $pr_evidence |
			(($pr_evidence | length) > 0 or has_status("in-review")) as $has_pr_assumption |
			(($pr_evidence.merged // false) == true or ($merged_lookup | contains("|" + ($number | tostring) + "="))) as $merged |
			(($pr_evidence.checks // $pr_evidence.check_status // "") | ascii_downcase) as $checks |
			(($issue.authority_required // false) == true or has_label("needs-maintainer-review")) as $authority |
			(($issue.dependency_blocked // false) == true or has_label("blocked") or has_label("status:blocked")) as $dependency_blocked |
			(($issue.dependency_resolved // false) == true) as $dependency_resolved |
			(($issue.lease_active // false) == true or (($issue.assignees // []) | length) > 0 or has_status("active")) as $lease |
			(($issue.process_active // false) == true) as $process |
			(($issue.recovery_attempt // 0) | tonumber) as $attempt |
			(($issue.recovery_comment_at // 0) | tonumber) as $recovery_comment |
			(($issue.subsequent_action_at // 0) | tonumber) as $subsequent_action |
			(if ($issue.state // "open" | ascii_downcase) == "closed" or $merged or has_status("done") then state_completed
			 elif ($issue.cancelled // false) == true or has_label("status:cancelled") then state_cancelled
			 elif ($issue.impossible // false) == true or has_label("status:impossible") then state_impossible
			 elif $authority then "authority-blocked"
			 elif $dependency_blocked and ($dependency_resolved | not) then "dependency-blocked"
			 elif $has_pr_assumption then "under review"
			 elif $lease and $process then "actively owned"
			 else "actionable" end) as $objective_state |
			(if $merged and (($issue.state // "open" | ascii_downcase) != "closed") then "close_issue"
			 elif [state_completed, state_cancelled, state_impossible] | index($objective_state) then action_none
			 elif $authority then ladder($attempt; true)
			 elif $dependency_blocked and ($dependency_resolved | not) then "reverify_dependency"
			 elif $dependency_resolved then action_redispatch
			 elif $recovery_comment > 0 and $subsequent_action <= $recovery_comment then ladder($attempt; false)
			 elif $has_pr_assumption and (($pr_evidence | length) == 0) then action_recover_branch
			 elif ($checks == "fail" or $checks == "failed" or $checks == "failure") and (($issue.repair_active // false) | not) then action_repair_pr
			 elif $lease and ($process | not) and (($issue.worktree_exists // false) == true) then action_resume
			 elif $lease and ($process | not) and (($issue.branch_exists // false) == true) then action_recover_branch
			 elif $lease and ($process | not) then action_redispatch
			 elif $objective_state == "under review" then "monitor_pr"
			 elif $objective_state == "actively owned" then "monitor_worker"
			 else "dispatch_objective" end) as $next_action |
			($evidence + $ttl) as $expiry |
			{
				repo: ($issue.repo // $repo),
				number: $number,
				objective_state: $objective_state,
				execution_path_state: ($issue.execution_path_state // (if $process then "running" elif $lease then "leased" elif $has_pr_assumption then "review" else "idle" end)),
				evidence_timestamp: $evidence,
				assumption_expires_at: $expiry,
				assumption_expired: (([state_completed, state_cancelled, state_impossible] | index($objective_state) | not) and $expiry <= $now),
				next_action: $next_action,
				trigger_at: (if $next_action == "none" then null else $expiry end),
				responsible_component: owner_for($next_action),
				recovery_attempt: $attempt,
				preservation: {commits: ($issue.commits_preserved // false), logs: ($issue.logs_preserved // false),
					verification: ($issue.verification_preserved // false)}
			} |
			.unattended = (([state_completed, state_cancelled, state_impossible] | index($objective_state) | not) and
				((.next_action == "" or .next_action == action_none or .trigger_at == null or .responsible_component == "") or .assumption_expired))
		]'
	return $?
}

_objective_merge_state() {
	local derived_json="$1"
	local state_file="$2"
	local repo="$3"
	local now_epoch="$4"
	local max_repairs="$5"
	local state_dir=""
	local previous='{"objectives":[]}'
	local tmp_file=""
	state_dir=$(dirname "$state_file")
	mkdir -p "$state_dir" 2>/dev/null || return 1
	if [[ -s "$state_file" ]]; then
		previous=$(jq -c '.' "$state_file" 2>/dev/null) || previous='{"objectives":[]}'
	fi
	tmp_file=$(mktemp "${state_file}.tmp.XXXXXX") || return 1
	jq -n \
		--arg repo "$repo" \
		--argjson now "$now_epoch" \
		--argjson max "$max_repairs" \
		--argjson previous "$previous" \
		--argjson current "$derived_json" '
		def plan: {objective_state, execution_path_state, evidence_timestamp, assumption_expires_at, next_action, trigger_at, responsible_component, preservation};
		($previous.objectives // []) as $old |
		[$current[] | . as $item | select(([$old[] | select(.repo == $item.repo and .number == $item.number) | plan] | first // null) != ($item | plan))] as $changed |
		{
			schema_version: 1,
			updated_at: $now,
			objectives: ([
				($old[] | select(.repo != $repo)),
				$current[]
			] | unique_by([.repo, .number]) | sort_by(.repo, .number)),
			repairs_applied: ($changed[:$max] | map({repo, number, next_action, responsible_component})),
			repairs_deferred: ([$changed[$max:][]? | {repo, number, next_action, responsible_component}])
		}' >"$tmp_file" || { rm -f "$tmp_file"; return 1; }
	mv "$tmp_file" "$state_file" || { rm -f "$tmp_file"; return 1; }
	return 0
}

_objective_summary() {
	local state_file="$1"
	if [[ ! -s "$state_file" ]]; then
		printf '{"total":0,"nonterminal":0,"objectives_without_next_action":0,"expired_assumptions":0,"oldest_unverified_assumption":null}\n'
		return 0
	fi
	jq -c '
		def state_completed: "completed";
		def state_cancelled: "cancelled";
		def state_impossible: "impossible";
		(.objectives // []) as $items |
		[$items[] | .objective_state as $state | select(([state_completed, state_cancelled, state_impossible] | index($state)) == null)] as $open |
		{
			total: ($items | length),
			nonterminal: ($open | length),
			objectives_without_next_action: ([$open[] | select((.next_action // "") == "" or .next_action == "none" or .trigger_at == null)] | length),
			expired_assumptions: ([$open[] | select(.assumption_expired == true)] | length),
			oldest_unverified_assumption: ([$open[] | select(.assumption_expired == true)] | sort_by(.evidence_timestamp) | first // null)
		}' "$state_file"
	return $?
}

main() {
	local command_name="${1:-help}"
	[[ $# -gt 0 ]] && shift
	local input_file="-"
	local repo=""
	local state_file="${AIDEVOPS_OBJECTIVE_STATE_FILE:-${HOME}/.aidevops/state/objective-reconciliation.json}"
	local now_epoch=""
	local ttl_secs="$OBJECTIVE_DEFAULT_TTL_SECS"
	local max_repairs="$OBJECTIVE_DEFAULT_MAX_REPAIRS"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		shift
		case "$arg" in
		--input) [[ $# -gt 0 ]] || return 2; input_file="$1"; shift ;;
		--repo) [[ $# -gt 0 ]] || return 2; repo="$1"; shift ;;
		--state-file) [[ $# -gt 0 ]] || return 2; state_file="$1"; shift ;;
		--now) [[ $# -gt 0 ]] || return 2; now_epoch="$1"; shift ;;
		--ttl) [[ $# -gt 0 ]] || return 2; ttl_secs="$1"; shift ;;
		--max-repairs) [[ $# -gt 0 ]] || return 2; max_repairs="$1"; shift ;;
		--help|-h) _objective_usage; return 0 ;;
		*) printf 'ERROR: unknown option: %s\n' "$arg" >&2; return 2 ;;
		esac
	done
	[[ -n "$now_epoch" ]] || now_epoch=$(_objective_now)
	now_epoch=$(_objective_validate_uint "$now_epoch" 0)
	ttl_secs=$(_objective_validate_uint "$ttl_secs" 3600)
	max_repairs=$(_objective_validate_uint "$max_repairs" 25)
	case "$command_name" in
	help) _objective_usage; return 0 ;;
	summary) _objective_summary "$state_file"; return $? ;;
	derive|reconcile)
		local input_json="" derived_json=""
		input_json=$(_objective_read_input "$input_file") || return $?
		input_json=$(_objective_attach_durable_evidence "$input_json" "$repo") || return $?
		derived_json=$(_objective_derive_json "$input_json" "$repo" "$now_epoch" "$ttl_secs") || return $?
		if [[ "$command_name" == "derive" ]]; then
			printf '%s\n' "$derived_json"
			return 0
		fi
		[[ -n "$repo" ]] || { printf 'ERROR: reconcile requires --repo\n' >&2; return 2; }
		_objective_merge_state "$derived_json" "$state_file" "$repo" "$now_epoch" "$max_repairs" || return $?
		_objective_summary "$state_file"
		return $?
		;;
	*) printf 'ERROR: unknown command: %s\n' "$command_name" >&2; _objective_usage >&2; return 2 ;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
