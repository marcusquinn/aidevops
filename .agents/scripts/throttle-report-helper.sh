#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# throttle-report-helper.sh - Report throughput-throttling requests to the maintainer
#
# Policy: reference/throughput-throttling-policy.md. When someone asks aidevops
# to reduce throughput (lower caps/concurrency, add pauses or fail-closed gates)
# without fixing the root cause, the agent still files this report so the
# maintainer decides whether the throttle or a systemic fix is right.
#
# Usage:
#   throttle-report-helper.sh report --request TEXT --root-cause TEXT \
#     --systemic-fix TEXT [--throttle TEXT] [--evidence TEXT] \
#     [--requester LOGIN] [--dry-run]
#
# The issue goes to marcusquinn/aidevops with labels throughput-throttle-report
# and needs-maintainer-review, a durable no-auto-dispatch hold, and the
# maintainer as assignee. The issue-triage gate re-applies the hold and
# assignee from the body marker when GitHub drops labels for non-collaborators.
# Never include private repo names, local paths, hostnames or secrets.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

readonly THROTTLE_REPORT_REPO="marcusquinn/aidevops"
readonly THROTTLE_REPORT_MAINTAINER="marcusquinn"
readonly THROTTLE_REPORT_LABELS="throughput-throttle-report,needs-maintainer-review"
readonly THROTTLE_REPORT_MARKER="<!-- aidevops:throttle-report -->"

_usage() {
	sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

_resolve_requester() {
	local requester="$1"
	if [[ -z "$requester" ]]; then
		requester=$(gh api user --jq '.login' 2>/dev/null || true)
	fi
	printf '%s\n' "${requester:-unknown}"
	return 0
}

_build_report_body() {
	local requester="$1"
	local request="$2"
	local throttle="$3"
	local root_cause="$4"
	local systemic_fix="$5"
	local evidence="$6"

	cat <<EOF
${THROTTLE_REPORT_MARKER}
## Throughput-throttling request

**Requested by:** @${requester}

**Request:** ${request}

**Throttle proposed or applied:** ${throttle:-not specified}

**Root cause not addressed:** ${root_cause}

**Systemic fix needed:** ${systemic_fix}

**Evidence:** ${evidence:-none supplied}

## Maintainer decision

Policy: \`.agents/reference/throughput-throttling-policy.md\`. Decide whether to
accept the throttle as a temporary measure, convert the systemic fix into a
worker-ready task, or decline the throttle.
EOF
	return 0
}

_assign_maintainer() {
	local output="$1"
	local issue_num=""
	issue_num=$(printf '%s\n' "$output" | sed -n 's/^issue_num=\([0-9][0-9]*\)$/\1/p' | sed -n '1p')
	[[ -n "$issue_num" ]] || return 0
	# Best-effort: needs triage access; the triage workflow assigns otherwise.
	gh issue edit "$issue_num" --repo "$THROTTLE_REPORT_REPO" \
		--add-assignee "$THROTTLE_REPORT_MAINTAINER" >/dev/null 2>&1 || true
	return 0
}

cmd_report() {
	local request="" throttle="" root_cause="" systemic_fix="" evidence="" requester="" dry_run=0
	while [[ $# -gt 0 ]]; do
		local option="$1"
		case "$option" in
		--request | --throttle | --root-cause | --systemic-fix | --evidence | --requester)
			if [[ $# -lt 2 ]]; then
				print_error "${option} requires a value"
				return 1
			fi
			local value="$2"
			case "$option" in
			--request) request="$value" ;;
			--throttle) throttle="$value" ;;
			--root-cause) root_cause="$value" ;;
			--systemic-fix) systemic_fix="$value" ;;
			--evidence) evidence="$value" ;;
			--requester) requester="$value" ;;
			esac
			shift 2
			;;
		--dry-run)
			dry_run=1
			shift
			;;
		*)
			print_error "Unknown option: ${option}"
			return 1
			;;
		esac
	done

	if [[ -z "$request" || -z "$root_cause" || -z "$systemic_fix" ]]; then
		print_error "--request, --root-cause and --systemic-fix are required"
		return 1
	fi

	requester=$(_resolve_requester "$requester")
	local title="throttle-report: ${request:0:90}"
	local body=""
	body=$(_build_report_body "$requester" "$request" "$throttle" "$root_cause" "$systemic_fix" "$evidence")

	local -a log_args=(
		log --title "$title" --body "$body"
		--label "$THROTTLE_REPORT_LABELS"
		--no-auto-dispatch
		--hold-reason "Maintainer decision required: throughput-throttling request without a root-cause fix."
	)
	if [[ "$dry_run" -eq 1 ]]; then
		log_args+=(--dry-run)
	fi

	local output="" rc=0
	output=$("${SCRIPT_DIR}/framework-issue-helper.sh" "${log_args[@]}" 2>&1) || rc=$?
	printf '%s\n' "$output"
	if [[ "$rc" -ne 0 ]]; then
		[[ "$dry_run" -eq 1 && "$rc" -eq 2 ]] && return 0
		return 1
	fi
	_assign_maintainer "$output"
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	report)
		cmd_report "$@"
		return $?
		;;
	help | --help | -h)
		_usage
		return 0
		;;
	*)
		print_error "Unknown command: ${command}"
		_usage
		return 1
		;;
	esac
}

main "$@"
