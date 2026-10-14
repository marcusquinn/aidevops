#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Stateful gh command/API fixture builders for the feedback-routing test suite.
# Sourced by test-pulse-merge-fix-worker-dispatch.sh; never invokes real gh.

[[ -n "${_PULSE_MERGE_FIX_DISPATCH_MOCKS_LOADED:-}" ]] && return 0
_PULSE_MERGE_FIX_DISPATCH_MOCKS_LOADED=1

write_gh_mock_command_cases() {
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

# Save the full positional arg array before any shifts.
_all_args=("$@")
_subcmd="${1:-} ${2:-}"

case "$_subcmd" in
"label create")
	exit 0
	;;
"pr view")
	if [[ "$*" == *"--json labels"* ]]; then
		cat "${TEST_ROOT}/pr-labels.txt"
		exit 0
	fi
	if [[ "$*" == *"headRefOid,headRefName,isCrossRepository,maintainerCanModify"* ]]; then
		printf 'abc123repairsha\tfix/worker-branch\tfalse\ttrue\n'
		exit 0
	fi
	if [[ "$*" == *"--json headRefName"* ]]; then
		printf 'fix/worker-branch\n'
		exit 0
	fi
	if [[ "$*" == *"--json headRefOid"* ]]; then
		printf 'abc123repairsha\n'
		exit 0
	fi
	exit 0
	;;
"pr checks")
	if [[ "$*" == *"| .name]"* ]]; then
		printf '%s\n' 'Lint'
		exit 0
	fi
	if [[ "$*" == *"conclusion"* ]]; then
		printf '%s\n' 'Unknown JSON field: "conclusion"' >&2
		exit 1
	fi
	if [[ "$*" == *"--json name,bucket,state,link"* ]]; then
		printf '%s\n' '[{"name":"Lint","bucket":"fail","state":"FAILURE","link":"https://github.com/owner/repo/actions/runs/123/job/456"}]'
		exit 0
	fi
	exit 0
	;;
"pr close")
	printf 'pr-close\n' >>"${EVENT_LOG}"
	: >"${TEST_ROOT}/pr-close-observed"
	if [[ "${TEST_FAIL_CLOSE:-0}" == "1" ]]; then
		exit 1
	fi
	printf 'CLOSED\n' >"${TEST_ROOT}/pr-state.txt"
	exit 0
	;;
"issue comment")
	_body=""
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--body" ]]; then
			_body="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done
	jq --arg body "$_body" --arg actor "${TEST_HOLD_EVENT_ACTOR:-pulse-automation}" '. + [{id: ((map(.id // 0) | max // 0) + 1), body:$body, created_at:"2026-08-21T02:38:02Z", author_association:"MEMBER", user:{login:$actor}}]' "${TEST_ROOT}/issue-comments.json" \
		>"${TEST_ROOT}/issue-comments.json.tmp"
	mv "${TEST_ROOT}/issue-comments.json.tmp" "${TEST_ROOT}/issue-comments.json"
	exit 0
	;;
"pr reopen")
	printf 'pr-reopen\n' >>"${EVENT_LOG}"
	if [[ "${TEST_FAIL_REOPEN:-0}" == "1" ]]; then
		exit 1
	fi
	printf 'OPEN\n' >"${TEST_ROOT}/pr-state.txt"
	exit 0
	;;
GHEOF
	return 0
}

append_gh_mock_pr_edit_cases() {
	cat >>"${TEST_ROOT}/bin/gh" <<'GHEOF'
"pr edit")
	if [[ "$*" == *"--add-reviewer"* ]]; then
		[[ "${TEST_FAIL_REREVIEW:-0}" == "1" ]] && exit 1
		[[ "${TEST_REREVIEW_NOOP:-0}" == "1" ]] && exit 0
		for _i in "${!_all_args[@]}"; do
			if [[ "${_all_args[$_i]}" == "--add-reviewer" ]]; then
				_new_reviewers="${_all_args[$((_i + 1))]:-}"
				_existing_reviewers=$(<"${TEST_ROOT}/requested-reviewers.txt")
				if [[ -n "$_existing_reviewers" ]]; then
					printf '%s|%s\n' "$_existing_reviewers" "$_new_reviewers" >"${TEST_ROOT}/requested-reviewers.txt"
				else
					printf '%s\n' "$_new_reviewers" >"${TEST_ROOT}/requested-reviewers.txt"
				fi
				break
			fi
		done
		exit 0
	fi
	if [[ "$*" == *"--add-label review-routed-to-issue"* \
		|| "$*" == *"--add-label conflict-feedback-routed"* \
		|| "$*" == *"--add-label ci-feedback-routed"* ]]; then
		printf 'pr-terminal-label\n' >>"${EVENT_LOG}"
		if [[ "${TEST_FAIL_TERMINAL_LABEL:-0}" == "1" ]]; then
			exit 1
		fi
	fi
	_labels=$(<"${TEST_ROOT}/pr-labels.txt")
	while [[ $# -gt 0 ]]; do
		_action="$1"
		case "$_action" in
		--add-label)
			shift
			_value="${1:-}"
			if [[ ",${_labels}," != *",${_value},"* ]]; then
				if [[ "$_value" == "hold-for-review" ]]; then
					_event_id=$(<"${TEST_ROOT}/pr-hold-event-id.txt")
					printf '%s\n' "$((_event_id + 1))" >"${TEST_ROOT}/pr-hold-event-id.txt"
					printf '%s\n' "${TEST_HOLD_EVENT_ACTOR:-pulse-automation}" >"${TEST_ROOT}/pr-hold-event-actor.txt"
				fi
				_labels="${_labels:+${_labels},}${_value}"
			fi
			;;
		--remove-label)
			shift
			_value="${1:-}"
			_next=""
			IFS=',' read -r -a _parts <<<"$_labels"
			for _part in "${_parts[@]}"; do
				[[ "$_part" == "$_value" ]] && continue
				_next="${_next:+${_next},}${_part}"
			done
			_labels="$_next"
			if [[ "$_value" == "hold-for-review" \
				&& "${TEST_HUMAN_PR_HOLD_EVENT_DURING_REMOVAL:-0}" == "1" ]]; then
				_event_id=$(<"${TEST_ROOT}/pr-hold-event-id.txt")
				printf '%s\n' "$((_event_id + 1))" >"${TEST_ROOT}/pr-hold-event-id.txt"
				printf '%s\n' 'human-maintainer' >"${TEST_ROOT}/pr-hold-event-actor.txt"
			fi
			;;
		esac
		shift || true
	done
	printf '%s\n' "$_labels" >"${TEST_ROOT}/pr-labels.txt"
	exit 0
	;;
"issue view")
	if [[ "$*" == *"--json assignees"* ]]; then
		cat "${TEST_ROOT}/issue-assignees.txt"
		exit 0
	fi
	if [[ "$*" == *"--json body"* ]]; then
		cat "${TEST_ROOT}/issue-body.txt"
		exit 0
	fi
	exit 0
	;;
GHEOF
	return 0
}

append_gh_mock_issue_edit_cases() {
	cat >>"${TEST_ROOT}/bin/gh" <<'GHEOF'
"issue edit")
	_is_transition=0
	if [[ "$*" == *"--body"* ]]; then
		_body_phase="start"
		if [[ "$*" == *"feedback-route:complete"* ]]; then
			_body_phase="complete"
		fi
		printf 'issue-body-%s\n' "$_body_phase" >>"${EVENT_LOG}"
		if [[ "${TEST_FAIL_BODY_PHASE:-}" == "$_body_phase" ]]; then
			exit "${TEST_FAIL_BODY_RC:-1}"
		fi
	elif [[ "$*" == *"--add-label status:available"* ]]; then
		_is_transition=1
		printf 'issue-transition\n' >>"${EVENT_LOG}"
		if [[ "${TEST_FAIL_TRANSITION:-0}" == "1" ]]; then
			exit 1
		fi
	fi
	_labels=$(<"${TEST_ROOT}/issue-labels.txt")
	_assignees=$(<"${TEST_ROOT}/issue-assignees.txt")
	while [[ $# -gt 0 ]]; do
		_action="$1"
		if [[ "$_action" == "--body" ]]; then
			shift
			printf '%s' "$1" >"${TEST_ROOT}/issue-body.txt"
		elif [[ "$_action" == "--add-label" ]]; then
			shift
			_value="${1:-}"
			if [[ ",${_labels}," != *",${_value},"* ]]; then
				if [[ "$_value" == "hold-for-review" ]]; then
					_event_id=$(<"${TEST_ROOT}/issue-hold-event-id.txt")
					printf '%s\n' "$((_event_id + 1))" >"${TEST_ROOT}/issue-hold-event-id.txt"
					printf '%s\n' "${TEST_HOLD_EVENT_ACTOR:-pulse-automation}" >"${TEST_ROOT}/issue-hold-event-actor.txt"
				fi
				_labels="${_labels:+${_labels},}${_value}"
			fi
		elif [[ "$_action" == "--remove-label" ]]; then
			shift
			_value="${1:-}"
			_next=""
			IFS=',' read -r -a _parts <<<"$_labels"
			for _part in "${_parts[@]}"; do
				[[ "$_part" == "$_value" ]] && continue
				_next="${_next:+${_next},}${_part}"
			done
			_labels="$_next"
		elif [[ "$_action" == "--remove-assignee" ]]; then
			shift
			_value="${1:-}"
			[[ "$_assignees" == "$_value" ]] && _assignees=""
		fi
		shift || true
	done
	if [[ "${TEST_ADD_NMR_DURING_TRANSITION:-0}" == "1" && "$_is_transition" -eq 1 \
		&& ",${_labels}," != *",needs-maintainer-review,"* ]]; then
		_labels="${_labels:+${_labels},}needs-maintainer-review"
	fi
	if [[ "${TEST_READD_HOLD_DURING_TRANSITION:-0}" == "1" && "$_is_transition" -eq 1 \
		&& ",${_labels}," != *",hold-for-review,"* ]]; then
		_labels="${_labels:+${_labels},}hold-for-review"
		_event_id=$(<"${TEST_ROOT}/issue-hold-event-id.txt")
		printf '%s\n' "$((_event_id + 1))" >"${TEST_ROOT}/issue-hold-event-id.txt"
		printf '%s\n' "${TEST_HOLD_EVENT_ACTOR:-human-maintainer}" >"${TEST_ROOT}/issue-hold-event-actor.txt"
	fi
	printf '%s\n' "$_labels" >"${TEST_ROOT}/issue-labels.txt"
	printf '%s' "$_assignees" >"${TEST_ROOT}/issue-assignees.txt"
	if [[ -n "${TEST_DRIFT_AFTER_TRANSITION_HEAD:-}" && "$_is_transition" -eq 1 ]]; then
		printf '%s\n' "$TEST_DRIFT_AFTER_TRANSITION_HEAD" >"${TEST_ROOT}/pr-head.txt"
	fi
	if [[ -n "${TEST_ADD_PR_PROTECTION_DURING_TRANSITION:-}" && "$_is_transition" -eq 1 ]]; then
		_pr_labels=$(<"${TEST_ROOT}/pr-labels.txt")
		if [[ ",${_pr_labels}," != *",${TEST_ADD_PR_PROTECTION_DURING_TRANSITION},"* ]]; then
			printf '%s,%s\n' "$_pr_labels" "$TEST_ADD_PR_PROTECTION_DURING_TRANSITION" >"${TEST_ROOT}/pr-labels.txt"
		fi
	fi
	exit 0
	;;
esac
GHEOF
	return 0
}

append_gh_mock_api_cases() {
	cat >>"${TEST_ROOT}/bin/gh" <<'GHEOF'
# `gh api repos/...` uses the URL as $2, so the simple `case "$1 $2"`
# pattern above can't match it. Handle api separately.
if [[ "${1:-}" == "api" ]]; then
	# Extract the --jq filter so we can simulate real gh's server-side jq.
	_jq_filter=""
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--jq" ]]; then
			_jq_filter="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done
	if [[ "${2:-}" == "user" ]]; then
		printf '%s\n' "${TEST_AUTHENTICATED_ACTOR:-pulse-automation}"
		exit 0
	fi
	if [[ "$*" == *"/pulls/"*"/files"* ]]; then
		[[ "${AIDEVOPS_GH_ROUTE_DECISION:-}" == "pulse-pr-files-rest" ]] || exit 1
		printf '%s\n' '.agents/scripts/pulse-merge.sh'
		exit 0
	fi
	if [[ "$*" == *"/pulls/"*"/reviews"* ]]; then
		if [[ -n "$_jq_filter" ]]; then
			jq "$_jq_filter" <"${TEST_ROOT}/reviews.json"
		else
			cat "${TEST_ROOT}/reviews.json"
		fi
		exit 0
	fi
	if [[ "$*" == *"/pulls/"*"/comments"* ]]; then
		if [[ -n "$_jq_filter" ]]; then
			jq "$_jq_filter" <"${TEST_ROOT}/comments.json"
		else
			cat "${TEST_ROOT}/comments.json"
		fi
		exit 0
	fi
	if [[ "${2:-}" == repos/owner/repo/compare/* ]]; then
		printf '%s\n' "${TEST_COMPARE_STATUS:-behind}"
		exit 0
	fi
	if [[ "${2:-}" == "repos/owner/repo/pulls/100" ]]; then
		if [[ "${TEST_FAIL_PR_SNAPSHOT_AFTER_CLOSE:-0}" == "1" \
			&& -f "${TEST_ROOT}/pr-close-observed" \
			&& ! -f "${TEST_ROOT}/pr-snapshot-failure-consumed" ]]; then
			: >"${TEST_ROOT}/pr-snapshot-failure-consumed"
			exit 1
		fi
		if [[ "$_jq_filter" == *"requested_reviewers"* ]]; then
			printf '%s\037false\037%s\037%s\037%s\n' "$(<"${TEST_ROOT}/pr-state.txt")" \
				"$(<"${TEST_ROOT}/pr-head.txt")" "$(<"${TEST_ROOT}/requested-reviewers.txt")" \
				"$(<"${TEST_ROOT}/pr-labels.txt")"
		else
			printf '%s\t%s\t%s\n' "$(<"${TEST_ROOT}/pr-state.txt")" \
				"$(<"${TEST_ROOT}/pr-head.txt")" "$(<"${TEST_ROOT}/pr-labels.txt")"
		fi
		exit 0
	fi
	if [[ "${2:-}" == "repos/owner/repo/issues/100/timeline?per_page=100" ]]; then
		_event_id=$(<"${TEST_ROOT}/pr-hold-event-id.txt")
		_event_actor=$(<"${TEST_ROOT}/pr-hold-event-actor.txt")
		if [[ "$_event_id" -gt 1000 ]]; then
			printf '[[{"id":%s,"event":"labeled","label":{"name":"hold-for-review"},"actor":{"login":"%s"},"created_at":"2026-08-21T02:38:01Z"}]]\n' "$_event_id" "$_event_actor"
		else
			printf '[[]]\n'
		fi
		exit 0
	fi
	if [[ "${2:-}" == "repos/owner/repo/issues/42/timeline?per_page=100" ]]; then
		_event_id=$(<"${TEST_ROOT}/issue-hold-event-id.txt")
		_event_actor=$(<"${TEST_ROOT}/issue-hold-event-actor.txt")
		if [[ "$_event_id" -gt 2000 ]]; then
			printf '[[{"id":%s,"event":"labeled","label":{"name":"hold-for-review"},"actor":{"login":"%s"},"created_at":"2026-08-21T02:38:01Z"}]]\n' "$_event_id" "$_event_actor"
		else
			printf '[[]]\n'
		fi
		exit 0
	fi
	if [[ "${2:-}" == "repos/owner/repo/issues/42" ]]; then
		if [[ "$_jq_filter" == *".body"* ]]; then
			cat "${TEST_ROOT}/issue-body.txt"
		elif [[ -z "$_jq_filter" ]]; then
			jq -nc --arg labels "$(<"${TEST_ROOT}/issue-labels.txt")" --arg assignee "$(<"${TEST_ROOT}/issue-assignees.txt")" '{state:"open", labels:($labels | split(",") | map(select(length > 0) | {name:.})), assignees:([$assignee] | map(select(length > 0) | {login:.}))}'
		else
			printf '%s\t%s\n' "$(<"${TEST_ROOT}/issue-labels.txt")" "$(<"${TEST_ROOT}/issue-assignees.txt")"
		fi
		exit 0
	fi
	if [[ "${2:-}" == "repos/owner/repo/issues/42/comments?per_page=100" ]]; then
		printf '[%s]\n' "$(<"${TEST_ROOT}/issue-comments.json")"
		exit 0
	fi
fi

exit 0
GHEOF
	return 0
}
