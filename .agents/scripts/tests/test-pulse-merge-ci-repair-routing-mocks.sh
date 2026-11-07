#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GitHub CLI mock routes for CI repair routing regression tests.
# Source from test-pulse-merge-ci-repair-routing.sh; setup_test_env owns fixtures.

[[ -n "${_PULSE_MERGE_CI_REPAIR_MOCKS_LOADED:-}" ]] && return 0
_PULSE_MERGE_CI_REPAIR_MOCKS_LOADED=1

write_gh_mock() {
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

if [[ "${1:-} ${2:-}" == "pr view" ]]; then
	if [[ "$*" == *"headRefOid,headRefName,isCrossRepository,maintainerCanModify"* ]]; then
		printf '%s\tfeature/repair\tfalse\ttrue\n' "${TEST_PR_HEAD_SHA}"
		exit 0
	fi
	if [[ "$*" == *"--json labels"* ]]; then
		cat "${TEST_ROOT}/pr-labels.txt"
		exit 0
	fi
	if [[ "$*" == *"--json headRefOid"* ]]; then
		if [[ "${TEST_INITIAL_PR_HEAD_EMPTY:-0}" == "1" ]]; then
			printf '\n'
		else
			printf '%s\n' "${TEST_INITIAL_PR_HEAD_SHA:-${TEST_PR_HEAD_SHA}}"
		fi
		exit 0
	fi
	exit 0
fi

if [[ "${1:-} ${2:-}" == "pr close" ]]; then
	printf 'CLOSED\n' >"${TEST_ROOT}/pr-state.txt"
	exit 0
fi

if [[ "${1:-} ${2:-}" == "pr reopen" ]]; then
	printf 'OPEN\n' >"${TEST_ROOT}/pr-state.txt"
	exit 0
fi

if [[ "${1:-} ${2:-}" == "pr edit" ]]; then
	_labels=$(<"${TEST_ROOT}/pr-labels.txt")
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--add-label)
			shift
			_value="${1:-}"
			[[ ",${_labels}," == *",${_value},"* ]] || _labels="${_labels:+${_labels},}${_value}"
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
			;;
		esac
		shift || true
	done
	printf '%s\n' "$_labels" >"${TEST_ROOT}/pr-labels.txt"
	exit 0
fi

if [[ "${1:-} ${2:-}" == "run view" ]]; then
	case "${TEST_CHECK_SCENARIO:-terminal_failure}" in
	infra_timeout)
		printf '%s\n' 'Lint Run timed out after 10m'
		;;
	infra_registry_rate_limit)
		printf '%s\n' 'Error response from daemon: toomanyrequests: Rate exceeded while pulling public.ecr.aws/docker/library/postgres:18'
		;;
	infra_dockerhub_rate_limit)
		printf '%s\n' 'toomanyrequests: You have reached your unauthenticated pull rate limit.'
		;;
	infra_github_api_rate_limit)
		printf '%s\n' 'gh: API rate limit exceeded for installation. (HTTP 403)'
		;;
	log_exit_143)
		printf '%s\n' 'Lint Run ##[error]Process completed with exit code 143.'
		;;
	billing_blocked | zero_step_no_annotation)
		# A job GitHub never started has no failed log output.
		;;
	*)
		printf '%s\n' 'Lint Run actual lint error in source file'
		;;
	esac
	exit 0
fi

GHEOF
	_append_gh_auth_mock_routes
	_append_gh_pr_body_mock_route
	_append_gh_mock_routes
	_append_gh_annotation_mock_routes
	_append_gh_ownership_mock_routes
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

_append_gh_auth_mock_routes() {
	cat >>"${TEST_ROOT}/bin/gh" <<'GHEOF'
	if [[ "${1:-} ${2:-}" == "api user" ]]; then
		[[ "${TEST_GH_REST_FAIL:-0}" == "1" ]] && exit 1
		printf '%s\n' "${TEST_GH_REST_LOGIN:-expected-runner}"
		exit 0
	fi

	if [[ "${1:-} ${2:-}" == "api graphql" ]]; then
		[[ "${TEST_GH_GRAPHQL_FAIL:-0}" == "1" ]] && exit 1
		printf '%s\n' "${TEST_GH_GRAPHQL_LOGIN:-expected-runner}"
		exit 0
	fi
GHEOF
	return 0
}

# Linkage preservation reads only the PR body; this precedes the PR metadata route.
_append_gh_pr_body_mock_route() {
	cat >>"${TEST_ROOT}/bin/gh" <<'GHEOF'
	if [[ "${1:-} ${2:-}" == "api repos/owner/repo/pulls/100" && "$*" == *'.body // ""'* ]]; then
		printf '%s\n' "${TEST_PR_BODY:-}"
		exit 0
	fi
GHEOF
	return 0
}

_append_gh_mock_routes() {
	cat >>"${TEST_ROOT}/bin/gh" <<'GHEOF'
	if [[ "${1:-} ${2:-}" == "api repos/owner/repo" ]]; then
		[[ "${TEST_QLTY_METADATA:-}" == "unavailable" ]] && exit 1
		printf '%s\n' "$TEST_QLTY_METADATA"
		exit 0
	fi
	if [[ "${1:-} ${2:-}" == "pr checks" ]]; then
		_is_required=0
		[[ "$*" == *" --required "* || "$*" == *" --required"* ]] && _is_required=1
		if [[ "$*" == *"conclusion"* ]]; then
			printf '%s\n' 'Unknown JSON field: "conclusion"' >&2
			exit 1
		fi
		if [[ "$*" == *"name,bucket,state,link"* ]]; then
			case "${TEST_CHECK_SCENARIO:-terminal_failure}:${_is_required}" in
				terminal_failure:1 | log_exit_143:1 | required_and_advisory:1 | nonrequired_baseline:1 | infra_registry_rate_limit:1 | infra_dockerhub_rate_limit:1 | infra_github_api_rate_limit:1 | billing_blocked:1 | zero_step_no_annotation:1)
					printf '%s\n' '[{"name":"Lint","bucket":"fail","state":"FAILURE","link":"https://github.com/owner/repo/actions/runs/123/job/456"}]'
					;;
				nonrequired_baseline:0)
					printf '%s\n' '[{"name":"Qlty Smell Threshold","bucket":"fail","state":"FAILURE","link":"https://github.com/owner/repo/actions/runs/125/job/791"},{"name":"Qlty Smell Regression","bucket":"pass","state":"SUCCESS","conclusion":"success","link":"https://github.com/owner/repo/actions/runs/125/job/792"}]'
					;;
				required_and_advisory:0)
					printf '%s\n' '[{"name":"Lint","bucket":"fail","state":"FAILURE","link":"https://github.com/owner/repo/actions/runs/123/job/456"},{"name":"Qlty","bucket":"fail","state":"FAILURE","link":"https://github.com/owner/repo/actions/runs/124/job/790"}]'
					;;
				pending_only:*|mixed_pending_pass:*)
					printf '[]\n'
					;;
				infra_timeout:1)
					printf '%s\n' '[{"name":"Lint","bucket":"fail","state":"FAILURE","link":"https://github.com/owner/repo/actions/runs/123/job/456"}]'
					;;
				advisory_failure:0)
					printf '%s\n' '[{"name":"Docs","bucket":"fail","state":"FAILURE","link":"https://github.com/owner/repo/actions/runs/123/job/789"}]'
					;;
				advisory_failure:1)
					printf '[]\n'
					;;
			esac
			exit 0
		fi
		exit 0
	fi

if [[ "${1:-} ${2:-}" == "issue view" ]]; then
	if [[ "$*" == *"--json assignees"* ]]; then
		if [[ "${TEST_CLAIM_ON_ASSIGNEE_READ:-0}" == 1 ]]; then
			jq -nc '[{user:{login:"stale-owner"},author_association:"OWNER",created_at:(now|todateiso8601),body:"Interactive session claimed by @stale-owner"}]' >"${TEST_ROOT}/owner-claim.json"
		fi
		cat "${TEST_ROOT}/issue-assignees.txt"
		exit 0
	fi
	if [[ "$*" == *"--json body"* ]]; then
		cat "${TEST_ROOT}/issue-body.txt"
		exit 0
	fi
	exit 0
fi

if [[ "${1:-} ${2:-}" == "issue edit" ]]; then
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
			[[ ",${_labels}," == *",${_value},"* ]] || _labels="${_labels:+${_labels},}${_value}"
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
	printf '%s\n' "$_labels" >"${TEST_ROOT}/issue-labels.txt"
	printf '%s' "$_assignees" >"${TEST_ROOT}/issue-assignees.txt"
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/pulls/100" ]]; then
	printf '%s\t%s\t%s\n' "$(<"${TEST_ROOT}/pr-state.txt")" "$TEST_PR_HEAD_SHA" \
		"$(<"${TEST_ROOT}/pr-labels.txt")"
	exit 0
fi
GHEOF
	return 0
}

# GH#32869: check-run annotations for the Actions billing classifier.
_append_gh_annotation_mock_routes() {
	cat >>"${TEST_ROOT}/bin/gh" <<'GHEOF'
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/check-runs/456" ]]; then
	printf '%s\n' '{"app":{"slug":"github-actions"}}'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/check-runs/456/annotations" ]]; then
	printf 'annotations %s\n' "${2:-}" >>"${TEST_ROOT}/gh-annotations.log"
	case "${TEST_CHECK_SCENARIO:-terminal_failure}" in
	billing_blocked)
		printf '%s\n' '[{"path":".github","annotation_level":"failure","title":"","message":"The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the '"'"'Billing & plans'"'"' section in your settings","raw_details":""}]'
		;;
	*)
		printf '[]\n'
		;;
	esac
	exit 0
fi
GHEOF
	return 0
}

_append_gh_ownership_mock_routes() {
	cat >>"${TEST_ROOT}/bin/gh" <<'GHEOF'
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/42" ]]; then
	if [[ "$*" == *".body"* ]]; then
		cat "${TEST_ROOT}/issue-body.txt"
	elif [[ "$*" != *"--jq"* ]]; then
		jq -nc --arg labels "$(<"${TEST_ROOT}/issue-labels.txt")" \
			--arg assignee "$(<"${TEST_ROOT}/issue-assignees.txt")" \
			'{state:"open",labels:($labels|split(",")|map({name:.})),assignees:([$assignee|select(length>0)]|map({login:.}))}'
	else
		printf '%s\t%s\n' "$(<"${TEST_ROOT}/issue-labels.txt")" \
			"$(<"${TEST_ROOT}/issue-assignees.txt")"
	fi
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/42/comments?per_page=100" ]]; then
	if [[ -f "${TEST_ROOT}/owner-claim.json" ]]; then
		cat "${TEST_ROOT}/owner-claim.json"
	else
		printf '[]\n'
	fi
	exit 0
fi

exit 0
GHEOF
	return 0
}
