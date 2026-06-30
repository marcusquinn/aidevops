#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC1091
#
# pulse-check-helper.sh — bounded pulse/worker utilisation diagnostics.
#
# This helper combines the canonical current-state and worker outcome ledgers
# with a privacy-preserving scan of repos.json auto-dispatch issues. It is safe
# for interactive diagnosis and for a daily self-improvement routine because
# --apply files only deduplicated, aggregate framework issues.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1

# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

CURRENT_STATE_HELPER="${PULSE_CHECK_CURRENT_STATE_HELPER:-${SCRIPT_DIR}/pulse-current-state-helper.sh}"
WORKER_ACTIVITY_HELPER="${PULSE_CHECK_WORKER_ACTIVITY_HELPER:-${SCRIPT_DIR}/worker-activity-helper.sh}"
RUNNER_HEALTH_HELPER="${PULSE_CHECK_RUNNER_HEALTH_HELPER:-${SCRIPT_DIR}/pulse-runner-health-helper.sh}"
PULSE_DIAGNOSE_HELPER="${PULSE_CHECK_PULSE_DIAGNOSE_HELPER:-${SCRIPT_DIR}/pulse-diagnose-helper.sh}"
GH_WRAPPERS="${PULSE_CHECK_GH_WRAPPERS:-${SCRIPT_DIR}/shared-gh-wrappers.sh}"
REPORT_FILTER="${PULSE_CHECK_REPORT_FILTER:-${SCRIPT_DIR}/pulse-check-report.jq}"
QUEUE_SCANNER="${PULSE_CHECK_QUEUE_SCANNER:-${SCRIPT_DIR}/pulse-check-queue-scan.py}"
REPOS_JSON="${PULSE_CHECK_REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"

COMMAND="report"
WINDOW="15m"
SINCE="24h"
RECENT_SINCE="1h"
APPLY_REPO="${PULSE_CHECK_APPLY_REPO:-}"
JSON_OUTPUT=0
APPLY_MODE=0
MAX_ISSUES_PER_REPO="${PULSE_CHECK_MAX_ISSUES_PER_REPO:-100}"
AVAILABLE_THRESHOLD="${PULSE_CHECK_AVAILABLE_THRESHOLD:-3}"
OLD_AVAILABLE_MINUTES="${PULSE_CHECK_OLD_AVAILABLE_MINUTES:-30}"

_usage() {
	cat <<EOF
Usage: $(basename "$0") [report|json|apply|help] [options]

Options:
  --window <15m|30m|1h>       Current-state window (default: ${WINDOW})
  --since <1h|6h|24h|48h|7d> Historical worker summary window (default: ${SINCE})
  --recent <1h|6h|24h>       Recent worker outcome window (default: ${RECENT_SINCE})
  --repo <owner/repo>        Repo for --apply self-improvement issues
  --max-issues <N>           Per-repo auto-dispatch issue scan limit (default: ${MAX_ISSUES_PER_REPO})
  --available-threshold <N>  Queue depth threshold for underfill findings (default: ${AVAILABLE_THRESHOLD})
  --old-available-minutes <N> Age threshold for stale available queue counts (default: ${OLD_AVAILABLE_MINUTES})
  --json                     Emit JSON report
  --apply                    File deduplicated self-improvement issues for autofile findings
  --help                     Show this help

Subcommands:
  report  Human-readable diagnostics (default)
  json    Machine-readable diagnostics
  apply   Human-readable diagnostics plus deduplicated issue creation
EOF
	return 0
}

_parse_args() {
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		local next="${2:-}"
		case "$arg" in
		report) COMMAND="report"; shift ;;
		json) COMMAND="json"; JSON_OUTPUT=1; shift ;;
		apply) COMMAND="apply"; APPLY_MODE=1; shift ;;
		--window) WINDOW="$next"; shift 2 ;;
		--since) SINCE="$next"; shift 2 ;;
		--recent) RECENT_SINCE="$next"; shift 2 ;;
		--repo) APPLY_REPO="$next"; shift 2 ;;
		--max-issues) MAX_ISSUES_PER_REPO="$next"; shift 2 ;;
		--available-threshold) AVAILABLE_THRESHOLD="$next"; shift 2 ;;
		--old-available-minutes) OLD_AVAILABLE_MINUTES="$next"; shift 2 ;;
		--json) JSON_OUTPUT=1; shift ;;
		--apply) APPLY_MODE=1; shift ;;
		help|--help|-h) _usage; exit 0 ;;
		*) print_warning "pulse-check: unknown argument: ${arg}"; _usage; exit 1 ;;
		esac
	done
	return 0
}

_validate_numeric_options() {
	[[ "$MAX_ISSUES_PER_REPO" =~ ^[0-9]+$ ]] || MAX_ISSUES_PER_REPO=100
	[[ "$AVAILABLE_THRESHOLD" =~ ^[0-9]+$ ]] || AVAILABLE_THRESHOLD=3
	[[ "$OLD_AVAILABLE_MINUTES" =~ ^[0-9]+$ ]] || OLD_AVAILABLE_MINUTES=30
	return 0
}

_run_json_helper() {
	local fallback_json="$1"
	shift

	local output=""
	local rc=0
	output=$("$@" 2>/dev/null) || rc=$?
	if [[ "$rc" -ne 0 || -z "$output" ]] || ! printf '%s' "$output" | jq empty >/dev/null 2>&1; then
		printf '%s\n' "$fallback_json"
		return 0
	fi
	printf '%s\n' "$output"
	return 0
}

_scan_auto_dispatch_queue() {
	if [[ ! -f "$QUEUE_SCANNER" ]]; then
		print_error "pulse-check: queue scanner not found: ${QUEUE_SCANNER}"
		printf '{"aggregate":{"repos":0,"auto_dispatch_open":0,"available_unassigned":0,"available_old":0,"oldest_available_age_min":0,"repos_with_available":0,"queued":0,"assigned":0,"blocked_labels":0,"needs_tier":0,"needs_status":0,"parent_task":0,"nmr":0,"no_auto_dispatch":0,"gh_errors":0},"error":"queue_scanner_missing"}\n'
		return 0
	fi

	PULSE_CHECK_REPOS_JSON="$REPOS_JSON" \
		PULSE_CHECK_MAX_ISSUES_PER_REPO="$MAX_ISSUES_PER_REPO" \
		PULSE_CHECK_OLD_AVAILABLE_MINUTES="$OLD_AVAILABLE_MINUTES" \
		python3 "$QUEUE_SCANNER"
	return 0
}

_collect_report_json() {
	local current_state="{}"
	local worker_summary="{}"
	local worker_recent="{}"
	local providers="{}"
	local runner_health="{}"
	local api_budget="{}"
	local queue="{}"

	current_state=$(_run_json_helper '{}' "$CURRENT_STATE_HELPER" --window "$WINDOW" --json)
	worker_summary=$(_run_json_helper '{}' "$WORKER_ACTIVITY_HELPER" summary --since "$SINCE" --json --no-pr-check)
	worker_recent=$(_run_json_helper '{}' "$WORKER_ACTIVITY_HELPER" summary --since "$RECENT_SINCE" --json --no-pr-check)
	providers=$(_run_json_helper '{}' "$WORKER_ACTIVITY_HELPER" providers --since "$RECENT_SINCE" --json)
	runner_health=$(_run_json_helper '{}' "$RUNNER_HEALTH_HELPER" diagnose --json)
	api_budget=$(_run_json_helper '{}' "$PULSE_DIAGNOSE_HELPER" api-budget --json)
	local skip_queue_scan="0"
	if printf '%s' "$api_budget" | jq -e '((.secondary_cooldown_state // "") | contains("active=yes"))' >/dev/null 2>&1; then
		skip_queue_scan="1"
	fi
	if [[ "$skip_queue_scan" == "1" ]]; then
		queue=$(PULSE_CHECK_SKIP_GH=1 _scan_auto_dispatch_queue)
	else
		queue=$(_scan_auto_dispatch_queue)
	fi

	if [[ ! -f "$REPORT_FILTER" ]]; then
		print_error "pulse-check: report filter not found: ${REPORT_FILTER}"
		return 1
	fi

	jq -n \
		--arg window "$WINDOW" \
		--arg since "$SINCE" \
		--arg recent "$RECENT_SINCE" \
		--argjson threshold "$AVAILABLE_THRESHOLD" \
		--argjson current "$current_state" \
		--argjson summary "$worker_summary" \
		--argjson recent_summary "$worker_recent" \
		--argjson providers "$providers" \
		--argjson runner "$runner_health" \
		--argjson api "$api_budget" \
		--argjson queue "$queue" \
		-f "$REPORT_FILTER"
	return 0
}

_render_text_report() {
	local report_json="$1"
	printf '%s' "$report_json" | jq -r '
		def percent_text: if . == null then "n/a" else (. | tostring) + "%" end;
		"Pulse Check — " + .generated_at,
		"",
		"## Current utilisation",
		"- Active workers: " + (.summary.active_workers | tostring) + " / " + (.summary.max_workers | tostring) + " (available slots: " + (.summary.available_slots | tostring) + ")",
		"- Auto-dispatch queue: " + (.summary.auto_dispatch_available_unassigned | tostring) + " available / " + (.summary.auto_dispatch_open | tostring) + " open across " + (.queue.repos | tostring) + " pulse repos",
		"- Queue scan state: " + (.summary.auto_dispatch_scan_state // "scanned"),
		"- Current window launches: " + (.summary.worker_launches_in_window | tostring) + "; terminal worker events: " + (.summary.worker_terminal_events_in_window | tostring),
		"- Recent worker metric events: " + (.summary.recent_worker_events | tostring) + "; " + .inputs.historical_window + " success rate: " + (.summary.historical_success_rate | percent_text),
		"- GraphQL/API: " + (.summary.graphql_budget_status // "unknown"),
		"- Runner health: " + (.summary.runner_health // "unknown"),
		"",
		"## Findings",
		(if (.findings | length) == 0 then "- None above thresholds" else (.findings[] | "- [" + .severity + "] " + .title + " (`" + .id + "`) — " + .recommendation) end),
		"",
		"## Evidence commands",
		"- pulse-current-state-helper.sh --window " + .inputs.current_window + " --json",
		"- worker-activity-helper.sh summary --since " + .inputs.recent_window + " --json --no-pr-check",
		"- worker-activity-helper.sh summary --since " + .inputs.historical_window + " --json --no-pr-check",
		"- pulse-diagnose-helper.sh cycle-health --window 1h",
		"",
		"Privacy: report aggregates repos.json queue state and omits repo slugs, local paths, and issue titles."
	'
	return 0
}

_resolve_apply_repo() {
	if [[ -n "$APPLY_REPO" ]]; then
		printf '%s\n' "$APPLY_REPO"
		return 0
	fi
	gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true
	return 0
}

_existing_open_issue_for_finding() {
	local slug="$1"
	local finding_id="$2"
	local marker="aidevops:generator=pulse-check finding=${finding_id}"
	gh issue list --repo "$slug" --state open --search "in:body \"${marker}\"" \
		--limit 1 --json number,url 2>/dev/null \
		| jq -r '.[0] // empty | "\(.number)\t\(.url)"' 2>/dev/null
	return 0
}

_finding_issue_body() {
	local finding_id="$1"
	local title="$2"
	local severity="$3"
	local evidence_markdown="$4"
	local recommendation="$5"

	cat <<EOF
<!-- aidevops:generator=pulse-check finding=${finding_id} -->

## Finding

${title}

Severity: ${severity}

## Evidence

${evidence_markdown}

Source commands:

- \`.agents/scripts/pulse-check-helper.sh --json\`
- \`.agents/scripts/pulse-current-state-helper.sh --window 15m --json\`
- \`.agents/scripts/worker-activity-helper.sh summary --since 1h --json --no-pr-check\`
- \`.agents/scripts/pulse-diagnose-helper.sh cycle-health --window 1h\`

## Recommendation

${recommendation}

## Implementation context

- Primary files: \`.agents/scripts/pulse-check-helper.sh\`, \`.agents/scripts/pulse-current-state-helper.sh\`, \`.agents/scripts/worker-activity-helper.sh\`, \`.agents/scripts/pulse-diagnose-helper.sh\`, \`.agents/scripts/pulse-dispatch-worker-launch.sh\`, \`.agents/scripts/headless-runtime-helper.sh\`.
- Reference patterns: \`.agents/reference/diagnostics-discipline.md\` and \`.agents/reference/worker-diagnostics.md\`.
- If the exact broken path differs, keep the fix in the pulse/worker diagnostics layer and update this issue with the verified file path before implementation.

## Verification

- \`.agents/scripts/tests/test-pulse-check-helper.sh\`
- \`.agents/scripts/pulse-check-helper.sh --json\` shows the finding cleared or downgraded with current evidence.
- Relevant focused tests for any touched pulse/worker helper.

Privacy note: this issue intentionally uses aggregate counts only; do not add private repo names, private basenames, local paths, or issue titles.
EOF
	return 0
}

_apply_finding() {
	local slug="$1"
	local finding_json="$2"
	local finding_id=""
	local title=""
	local severity=""
	local recommendation=""
	local evidence_markdown=""

	finding_id=$(printf '%s' "$finding_json" | jq -r '.id')
	title=$(printf '%s' "$finding_json" | jq -r '.title')
	severity=$(printf '%s' "$finding_json" | jq -r '.severity')
	recommendation=$(printf '%s' "$finding_json" | jq -r '.recommendation')
	evidence_markdown=$(printf '%s' "$finding_json" | jq -r '.evidence | map("- " + .) | join("\n")')

	local existing=""
	existing=$(_existing_open_issue_for_finding "$slug" "$finding_id")
	if [[ -n "$existing" ]]; then
		local existing_number=""
		local existing_url=""
		IFS=$'\t' read -r existing_number existing_url <<<"$existing"
		print_info "pulse-check: finding=${finding_id} already tracked by #${existing_number} (${existing_url})"
		return 0
	fi

	if [[ ! -f "$GH_WRAPPERS" ]]; then
		print_error "pulse-check: gh wrappers not found: ${GH_WRAPPERS}"
		return 1
	fi
	# shellcheck source=./shared-gh-wrappers.sh
	source "$GH_WRAPPERS"

	local body_file=""
	body_file=$(mktemp "${TMPDIR:-/tmp}/pulse-check-issue.XXXXXX.md") || return 1
	_finding_issue_body "$finding_id" "$title" "$severity" "$evidence_markdown" "$recommendation" >"$body_file"

	local labels="auto-dispatch,tier:standard,bug,framework,pulse,self-improvement,source:pulse-check"
	local issue_output=""
	issue_output=$(gh_create_issue --repo "$slug" --title "$title" --body-file "$body_file" --label "$labels" 2>&1) || {
		local issue_rc=$?
		rm -f "$body_file"
		print_error "pulse-check: failed to create issue for ${finding_id}: ${issue_output}"
		return "$issue_rc"
	}
	rm -f "$body_file"
	print_success "pulse-check: filed ${issue_output} for finding=${finding_id}"
	return 0
}

_apply_findings() {
	local report_json="$1"
	local slug=""
	slug=$(_resolve_apply_repo)
	if [[ -z "$slug" ]]; then
		print_error "pulse-check: --apply requires --repo <owner/repo> or a gh repo context"
		return 1
	fi

	local applied_count=0
	while IFS= read -r finding_json; do
		[[ -n "$finding_json" ]] || continue
		_apply_finding "$slug" "$finding_json" || true
		applied_count=$((applied_count + 1))
	done < <(printf '%s' "$report_json" | jq -c '.findings[] | select(.autofile == true)')

	if [[ "$applied_count" -eq 0 ]]; then
		print_info "pulse-check: no autofile findings above thresholds"
	fi
	return 0
}

_main() {
	_parse_args "$@"
	_validate_numeric_options
	if [[ "$COMMAND" == "json" ]]; then
		JSON_OUTPUT=1
	elif [[ "$COMMAND" == "apply" ]]; then
		APPLY_MODE=1
	fi

	local report_json=""
	report_json=$(_collect_report_json)

	if [[ "$APPLY_MODE" -eq 1 ]]; then
		_apply_findings "$report_json"
	fi

	if [[ "$JSON_OUTPUT" -eq 1 ]]; then
		printf '%s\n' "$report_json"
	else
		_render_text_report "$report_json"
	fi
	return 0
}

_main "$@"
