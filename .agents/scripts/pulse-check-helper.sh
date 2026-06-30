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
	PULSE_CHECK_REPOS_JSON="$REPOS_JSON" \
		PULSE_CHECK_MAX_ISSUES_PER_REPO="$MAX_ISSUES_PER_REPO" \
		PULSE_CHECK_OLD_AVAILABLE_MINUTES="$OLD_AVAILABLE_MINUTES" \
		python3 - <<'PY'
import datetime
import json
import os
import pathlib
import shutil
import subprocess
import sys

repos_json = pathlib.Path(os.environ.get("PULSE_CHECK_REPOS_JSON", ""))
skip_gh = os.environ.get("PULSE_CHECK_SKIP_GH", "") in {"1", "true", "TRUE", "yes", "YES"}
try:
    max_issues = int(os.environ.get("PULSE_CHECK_MAX_ISSUES_PER_REPO", "100"))
except ValueError:
    max_issues = 100
try:
    old_minutes = int(os.environ.get("PULSE_CHECK_OLD_AVAILABLE_MINUTES", "30"))
except ValueError:
    old_minutes = 30

aggregate = {
    "repos": 0,
    "auto_dispatch_open": 0,
    "available_unassigned": 0,
    "available_old": 0,
    "oldest_available_age_min": 0,
    "repos_with_available": 0,
    "queued": 0,
    "assigned": 0,
    "blocked_labels": 0,
    "needs_tier": 0,
    "needs_status": 0,
    "parent_task": 0,
    "nmr": 0,
    "no_auto_dispatch": 0,
    "gh_errors": 0,
}

try:
    data = json.loads(repos_json.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    print(json.dumps({"aggregate": aggregate, "error": f"repos_json_unreadable:{exc.__class__.__name__}"}))
    sys.exit(0)

repos = [
    repo for repo in data.get("initialized_repos", [])
    if repo.get("pulse") is True and not repo.get("local_only") and repo.get("slug")
]
aggregate["repos"] = len(repos)
if skip_gh:
    print(json.dumps({"aggregate": aggregate, "error": "api_cooldown_active"}))
    sys.exit(0)
if shutil.which("gh") is None:
    print(json.dumps({"aggregate": aggregate, "error": "gh_missing"}))
    sys.exit(0)

now = datetime.datetime.now(datetime.timezone.utc)
blocking_labels = {
    "parent-task",
    "needs-maintainer-review",
    "no-auto-dispatch",
    "hold-for-review",
    "blocked",
    "status:blocked",
    "status:in-review",
}

for repo in repos:
    slug = str(repo.get("slug") or "")
    cmd = [
        "gh", "issue", "list",
        "--repo", slug,
        "--state", "open",
        "--label", "auto-dispatch",
        "--limit", str(max_issues),
        "--json", "number,title,labels,assignees,updatedAt",
    ]
    try:
        completed = subprocess.run(cmd, text=True, capture_output=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError):
        aggregate["gh_errors"] += 1
        continue
    if completed.returncode != 0:
        aggregate["gh_errors"] += 1
        continue
    try:
        issues = json.loads(completed.stdout or "[]")
    except json.JSONDecodeError:
        aggregate["gh_errors"] += 1
        continue

    repo_available = 0
    for issue in issues:
        labels = {str(label.get("name") or "") for label in issue.get("labels", [])}
        assigned = bool(issue.get("assignees"))
        blocked = bool(labels & blocking_labels)
        aggregate["auto_dispatch_open"] += 1
        if assigned:
            aggregate["assigned"] += 1
        if "status:queued" in labels:
            aggregate["queued"] += 1
        if not any(label.startswith("tier:") for label in labels):
            aggregate["needs_tier"] += 1
        if not any(label.startswith("status:") for label in labels):
            aggregate["needs_status"] += 1
        if blocked:
            aggregate["blocked_labels"] += 1
        if "parent-task" in labels:
            aggregate["parent_task"] += 1
        if "needs-maintainer-review" in labels:
            aggregate["nmr"] += 1
        if "no-auto-dispatch" in labels:
            aggregate["no_auto_dispatch"] += 1
        if "status:available" in labels and not assigned and not blocked:
            repo_available += 1
            aggregate["available_unassigned"] += 1
            updated_at = str(issue.get("updatedAt") or "")
            try:
                updated = datetime.datetime.fromisoformat(updated_at.replace("Z", "+00:00"))
                age_min = int((now - updated).total_seconds() // 60)
            except (ValueError, TypeError):
                age_min = 0
            if age_min >= old_minutes:
                aggregate["available_old"] += 1
            if age_min > aggregate["oldest_available_age_min"]:
                aggregate["oldest_available_age_min"] = age_min
    if repo_available > 0:
        aggregate["repos_with_available"] += 1

print(json.dumps({"aggregate": aggregate, "scanned_at": now.isoformat()}))
PY
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
		--argjson queue "$queue" '
		def number_or_zero: (tonumber? // 0);
		def finding($id; $severity; $title; $evidence; $recommendation; $autofile): {
			id: $id,
			severity: $severity,
			title: $title,
			evidence: $evidence,
			recommendation: $recommendation,
			autofile: $autofile
		};
		($current.pulse_gauges.dispatch_capacity_final_max_workers // 0 | number_or_zero) as $max_workers |
		($current.current_state_guardrails.available_slots_last // $current.pulse_gauges.pulse_dispatch_guardrail_available_slots // 0 | number_or_zero) as $available_slots |
		([$max_workers - $available_slots, 0] | max) as $active_workers |
		($queue.aggregate.available_unassigned // 0 | number_or_zero) as $available_issues |
		($queue.aggregate.available_old // 0 | number_or_zero) as $old_available |
		($queue.aggregate.needs_tier // 0 | number_or_zero) as $needs_tier |
		($queue.aggregate.gh_errors // 0 | number_or_zero) as $gh_errors |
		($queue.error // "") as $queue_error |
		($current.worker_outcomes.spawned // 0 | number_or_zero) as $spawned |
		($recent_summary.metrics.total // 0 | number_or_zero) as $recent_total |
		($summary.metrics.total // 0 | number_or_zero) as $hist_total |
		($summary.metrics.succeeded // 0 | number_or_zero) as $hist_success |
		($api.graphql_circuit_breaker_trips // 0 | number_or_zero) as $graphql_trips |
		{
			generated_at: (now | todateiso8601),
			inputs: {current_window: $window, historical_window: $since, recent_window: $recent},
			summary: {
				max_workers: $max_workers,
				active_workers: $active_workers,
				available_slots: $available_slots,
				dispatch_alive: ($current.dispatch_alive // false),
				dispatch_stage_events: ($current.dispatch_stage_events // 0),
				worker_launches_in_window: $spawned,
				worker_terminal_events_in_window: ($current.worker_terminal_events // 0),
				recent_worker_events: $recent_total,
				historical_worker_events: $hist_total,
				historical_worker_successes: $hist_success,
				historical_success_rate: (if $hist_total > 0 then (($hist_success / $hist_total) * 100 | floor) else null end),
				auto_dispatch_open: ($queue.aggregate.auto_dispatch_open // 0),
				auto_dispatch_available_unassigned: $available_issues,
				auto_dispatch_available_old: $old_available,
				auto_dispatch_repos_with_available: ($queue.aggregate.repos_with_available // 0),
				auto_dispatch_scan_errors: $gh_errors,
				auto_dispatch_scan_state: (if $queue_error == "" then "scanned" else $queue_error end),
				graphql_budget_status: ($current.graphql_budget_status // "unknown"),
				runner_health: ($runner.finding // "unknown")
			},
			queue: ($queue.aggregate // {}),
			current_state: {
				dispatch_stage_counts: ($current.dispatch_stage_counts // {}),
				worker_outcomes: ($current.worker_outcomes // {}),
				pulse_counter_hits: ($current.pulse_counter_hits // {}),
				pulse_gauges: ($current.pulse_gauges // {}),
				current_state_guardrails: ($current.current_state_guardrails // {}),
				dispatch_pacing: ($current.dispatch_pacing // {}),
				top_pre_launch_blockers: ($current.top_pre_launch_blockers // [])
			},
			worker_activity: {
				historical: {
					window: ($summary.window // {}),
					metrics: (($summary.metrics // {}) | del(.recent_examples, .failure_groups, .failure_families)),
					pulse_stats: ($summary.pulse_stats // {})
				},
				recent: {
					window: ($recent_summary.window // {}),
					metrics: (($recent_summary.metrics // {}) | del(.recent_examples, .failure_groups, .failure_families)),
					pulse_stats: ($recent_summary.pulse_stats // {})
				},
				providers: ($providers.provider_diagnostics // {})
			},
			runner_health: $runner,
			api_budget: {
				graphql_circuit_breaker_trips: ($api.graphql_circuit_breaker_trips // 0),
				reserve_mode_cycles: ($api.reserve_mode_cycles // 0),
				deferred_optional_stages: ($api.deferred_optional_stages // 0),
				secondary_cooldown_state: ($api.secondary_cooldown_state // "unknown"),
				cadence_api_risk: ($api.cadence_api_risk // "unknown")
			},
			findings: ([
				if ($available_issues >= $threshold and $active_workers == 0) then
					finding(
						"pulse-underfilled-auto-dispatch-queue";
						"high";
						"Auto-dispatch queue is visible while worker capacity is empty";
						[
							("active_workers=" + ($active_workers | tostring) + "/" + ($max_workers | tostring)),
							("available_unassigned_auto_dispatch=" + ($available_issues | tostring)),
							("available_older_than_threshold=" + ($old_available | tostring)),
							("dispatch_stage_events=" + (($current.dispatch_stage_events // 0) | tostring))
						];
						"Inspect why the pulse did not retain active workers for visible status:available auto-dispatch issues; start with pulse-current-state-helper, worker-activity-helper, and pulse-diagnose-helper cycle-health.";
						true
					)
				else empty end,
				if ($spawned >= 3 and $active_workers == 0 and $recent_total == 0) then
					finding(
						"pulse-launch-accounting-gap";
						"high";
						"Pulse recorded worker launches without active workers or recent terminal metrics";
						[
							("worker_launches_in_current_window=" + ($spawned | tostring)),
							("recent_worker_metric_events=" + ($recent_total | tostring)),
							("active_workers=" + ($active_workers | tostring)),
							("available_slots=" + ($available_slots | tostring))
						];
						"Add or repair launch-validation evidence so every spawned worker becomes an active process, a terminal metric, or a classified launch failure.";
						true
					)
				else empty end,
				if ($needs_tier > 0) then
					finding(
						"auto-dispatch-missing-tier-labels";
						"medium";
						"Some auto-dispatch issues are missing tier labels";
						[("missing_tier_count=" + ($needs_tier | tostring))];
						"Run or repair label normalisation so auto-dispatch issues carry exactly one tier label before worker pickup.";
						false
					)
				else empty end,
				if ($gh_errors > 0) then
					finding(
						"pulse-check-gh-scan-errors";
						"medium";
						"Auto-dispatch queue scan had GitHub read errors";
						[("gh_errors=" + ($gh_errors | tostring))];
						"Check GitHub authentication and API budget before treating queue counts as complete.";
						false
					)
				else empty end,
				if ($queue_error != "") then
					finding(
						"pulse-check-queue-scan-skipped";
						"medium";
						"Auto-dispatch queue scan was skipped or incomplete";
						[("queue_scan_state=" + $queue_error)];
						"Re-run pulse-check after API cooldown clears before making queue-depth or underfill claims.";
						false
					)
				else empty end,
				if ($graphql_trips > 0 or ($current.dispatch_api_blocked // false) == true) then
					finding(
						"github-api-budget-blocking-dispatch";
						"high";
						"GitHub API budget is blocking or degrading dispatch";
						[("graphql_circuit_breaker_trips=" + ($graphql_trips | tostring)), ("dispatch_api_blocked=" + (($current.dispatch_api_blocked // false) | tostring))];
						"Use pulse-diagnose-helper api-budget to identify top callers and shift avoidable reads to cache/REST before increasing concurrency.";
						true
					)
				else empty end,
				if ($hist_total >= 10 and (($hist_success * 100) / $hist_total) < 70) then
					finding(
						"worker-success-rate-regression";
						"medium";
						"Historical worker success rate is below the productivity target";
						[("success_rate_percent=" + (((($hist_success * 100) / $hist_total) | floor) | tostring)), ("worker_events=" + ($hist_total | tostring))];
						"Cluster failure families with worker-activity-helper summary --json, then file targeted fixes for the dominant cause instead of increasing concurrency.";
						false
					)
				else empty end
			])
		}'
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
