#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pulse Diagnose Helper — correlates pulse.log events with PR merge decisions (t2714)
#
# Reads pulse.log (and rotated companions), cross-references with gh pr view
# timeline data, and classifies each event against a static rule inventory
# extracted from the three pulse scripts.
#
# Commands:
#   pr <N> [--repo <slug>] [--verbose] [--json]
#                        — correlate pulse events for PR #N
#   rules [--json]       — list the full rule inventory
#   api-budget [--json]  — compact GitHub API-budget diagnostic checklist
#   help                 — usage
#
# Environment overrides (for tests / custom deployments):
#   PULSE_DIAGNOSE_LOGFILE      — override pulse.log path
#   PULSE_DIAGNOSE_GH_OFFLINE   — set to 1 to skip gh API calls (test mode)
#   PULSE_DIAGNOSE_LOGDIR       — override log directory for rotated logs
#   PULSE_DIAGNOSE_METRICS_FILE — override headless-runtime-metrics.jsonl path
#   PULSE_DIAGNOSE_STATS_FILE   — override pulse-stats.json path
#   PULSE_DIAGNOSE_GH_API_LOG   — override gh-api-calls.log path
#   PULSE_DIAGNOSE_BLOCKER_LOG  — override worker-progress-blockers.jsonl path
#   PULSE_DIAGNOSE_SYSTEMD_TIMER_FILE — override systemd timer unit path
#   PULSE_DIAGNOSE_THREAD_RESPONSE_STATE_DIR — override ancillary worker state
#   PULSE_DIAGNOSE_DISPATCH_LEDGER_FILE — override dispatch ledger path
#   PULSE_DIAGNOSE_WORKTREE_REGISTRY_DB — override worktree registry database

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || {
	# Minimal fallbacks when shared-constants.sh is unavailable (e.g. CI)
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	YELLOW='\033[1;33m'
	BLUE='\033[0;34m'
	CYAN='\033[0;36m'
	NC='\033[0m'
	print_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; }
	print_info() { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$*" >&2; }
	print_warning() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
	print_success() { printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$*" >&2; }
}
set -euo pipefail

# GH#30619: read local durable footprint-defer state for issue reports.
# shellcheck source=dispatch-dedup-footprint.sh
if [[ -f "${SCRIPT_DIR}/dispatch-dedup-footprint.sh" ]]; then
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/dispatch-dedup-footprint.sh"
fi

# =============================================================================
# Constants
# =============================================================================

readonly DEFAULT_LOGFILE="${HOME}/.aidevops/logs/pulse.log"
readonly DEFAULT_LOGDIR="${HOME}/.aidevops/logs"
readonly DEFAULT_METRICS_FILE="${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl"
readonly DEFAULT_STATS_FILE="${HOME}/.aidevops/logs/pulse-stats.json"
readonly DEFAULT_GH_API_LOG="${HOME}/.aidevops/logs/gh-api-calls.log"
readonly DEFAULT_BLOCKER_LOG="${HOME}/.aidevops/logs/worker-progress-blockers.jsonl"
readonly DEFAULT_SYSTEMD_TIMER_FILE="${HOME}/.config/systemd/user/aidevops-supervisor-pulse.timer"
readonly DEFAULT_THREAD_RESPONSE_STATE_DIR="${HOME}/.aidevops/.agent-workspace/pr-review-thread-response"
readonly DEFAULT_DISPATCH_LEDGER_FILE="${HOME}/.aidevops/.agent-workspace/tmp/dispatch-ledger.jsonl"
readonly DEFAULT_WORKTREE_REGISTRY_DB="${HOME}/.aidevops/.agent-workspace/worktree-registry.db"
readonly _UNKNOWN="unknown"
readonly _UNCLASSIFIED="unclassified"
readonly _PR_HEAD_REF_JSON_PATH=".headRefName"
readonly _BOOL_TRUE="true"
readonly _BOOL_FALSE="false"
readonly _JSON_ARRAY_TYPE="array"
# =============================================================================
# Rule Inventory (Phase A)
#
# Each entry: RULE_ID|SCRIPT|LINE_RANGE|LOG_PATTERN_REGEX|HUMAN_DESCRIPTION
#
# The regex matches against log lines AFTER stripping the timestamp prefix.
# Patterns are anchored to the log prefix they appear in.
# =============================================================================

_build_rule_inventory() {
	# Returns the inventory as newline-separated records.
	# Fields: rule_id|script|line_range|regex|description
	cat <<'INVENTORY'
pm-auto-merge-interactive|pulse-merge.sh|1389|auto-merged origin:interactive PR #|Auto-merged origin:interactive PR (maintainer-authored, all checks pass)
pm-auto-merge-worker-briefed|pulse-merge.sh|1393|auto-merged origin:worker \(worker-briefed\) PR #|Auto-merged origin:worker PR (maintainer-briefed issue, all gates pass)
pm-retarget-stacked|pulse-merge.sh|1220|retargeting stacked PR #|Retargeted stacked child PR to default branch before parent branch deletion
pm-wb-disabled|pulse-merge.sh|1514|worker-briefed auto-merge: disabled by|Worker-briefed auto-merge disabled via AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0
pm-wb-draft|pulse-merge.sh|1520|worker-briefed auto-merge: skipping.*draft PR|Worker-briefed auto-merge skipped — PR is a draft
pm-wb-hold|pulse-merge.sh|1526|worker-briefed auto-merge: skipping.*hold-for-review|Worker-briefed auto-merge skipped — hold-for-review label present
pm-wb-no-issue|pulse-merge.sh|1532|worker-briefed auto-merge: skipping.*no linked issue|Worker-briefed auto-merge skipped — no linked issue found
pm-wb-not-owner|pulse-merge.sh|1544|worker-briefed auto-merge: skipping.*not OWNER/MEMBER|Worker-briefed auto-merge skipped — linked issue author is not OWNER/MEMBER
pm-wb-no-crypto|pulse-merge.sh|1571|worker-briefed auto-merge: skipping.*no crypto clearance|Worker-briefed auto-merge skipped — NMR was auto-approved only (no crypto clearance)
pm-wb-passed|pulse-merge.sh|1576|worker-briefed auto-merge: PR #.*passed all gates|Worker-briefed auto-merge passed all gates
pw-merged|pulse-wrapper.sh|1380|Deterministic merge: merged PR #|Deterministic merge pass merged PR successfully
pw-merge-failed|pulse-wrapper.sh|1398|Deterministic merge: FAILED PR #|Deterministic merge attempt failed
pw-merge-skip-mergeable|pulse-wrapper.sh|715|Merge pass: skipping PR #.*mergeable=|Merge pass skipped — PR not in MERGEABLE state
pw-merge-skip-unknown-retry|pulse-wrapper.sh|710|Merge pass: skipping PR #.*was UNKNOWN, still not MERGEABLE|Merge pass skipped — mergeable UNKNOWN, still not MERGEABLE after retry
pw-merge-resolved-retry|pulse-wrapper.sh|708|Merge pass: PR #.*mergeable resolved to MERGEABLE after retry|Merge pass resolved UNKNOWN to MERGEABLE after retry
pw-merge-skip-checks|pulse-wrapper.sh|820|Merge pass: skipping PR #.*required status check|Merge pass skipped — required status checks failing
pw-merge-skip-checks-fetch|pulse-wrapper.sh|814|Merge pass: skipping PR #.*required checks fetch failed|Merge pass skipped — could not fetch required checks
pw-merge-skip-changes-requested|pulse-wrapper.sh|968|Merge pass: skipping PR #.*reviewDecision=CHANGES_REQUESTED|Merge pass skipped — review decision is CHANGES_REQUESTED
pw-merge-skip-not-collaborator|pulse-wrapper.sh|975|Merge pass: skipping PR #.*is not a collaborator|Merge pass skipped — PR author is not a collaborator
pw-merge-skip-workflow-scope|pulse-wrapper.sh|982|Merge pass: skipping PR #.*modifies workflow files but token lacks|Merge pass skipped — PR modifies workflows but token lacks workflow scope
pw-merge-skip-nmr|pulse-wrapper.sh|1009|Merge pass: skipping PR #.*needs-maintainer-review \(no approval|Merge pass skipped — linked issue has needs-maintainer-review (no approval marker)
pw-merge-nmr-approved|pulse-wrapper.sh|1007|Merge pass: PR #.*linked issue.*has NMR but also approval marker|Merge pass proceeding — linked issue has NMR but also has approval marker
pw-merge-skip-ext-no-issue|pulse-wrapper.sh|1022|Merge pass: skipping PR #.*external-contributor PR has no linked issue|Merge pass skipped — external-contributor PR has no linked issue
pw-merge-skip-ext-no-crypto|pulse-wrapper.sh|1028|Merge pass: skipping PR #.*external-contributor PR linked issue.*lacks crypto|Merge pass skipped — external-contributor PR lacks crypto approval
pw-review-bot-gate-pass|pulse-wrapper.sh|1074|Review bot gate: PASS|Review bot gate PASS
pw-review-bot-gate-fail|pulse-wrapper.sh|1077|Review bot gate:.*skipping merge|Review bot gate not PASS — skipping merge
pw-dismiss-coderabbit|pulse-wrapper.sh|767|Merge pass: PR #.*dismissed CodeRabbit review|Dismissed individual CodeRabbit review (coderabbit-nits-ok)
pw-dismiss-coderabbit-all|pulse-wrapper.sh|958|Merge pass: PR #.*auto-dismissed CodeRabbit-only CHANGES_REQUESTED|Auto-dismissed all CodeRabbit-only CHANGES_REQUESTED reviews
pw-coderabbit-human-blocking|pulse-wrapper.sh|961|Merge pass: skipping PR #.*coderabbit-nits-ok.*human reviewer also blocking|CodeRabbit nits-ok label present but human reviewer also blocking
pw-skip-interactive-draft|pulse-wrapper.sh|1465|Merge pass: skipping PR #.*origin:interactive draft PR|Merge pass skipped — origin:interactive draft PR not eligible
pw-skip-interactive-hold|pulse-wrapper.sh|1469|Merge pass: skipping PR #.*origin:interactive PR has hold-for-review|Merge pass skipped — origin:interactive PR has hold-for-review label
pw-skip-parent-close|pulse-wrapper.sh|1152|Deterministic merge: skipping close of parent-task issue|Skipped closing parent-task issue (phase child PR — parent stays open)
pw-skip-dup-closing-comment|pulse-wrapper.sh|1162|Deterministic merge: skipped duplicate closing comment|Skipped duplicate closing comment on linked issue
pw-update-branch-ok|pulse-wrapper.sh|679|Merge pass: PR #.*update-branch succeeded|Update-branch succeeded (synced PR with base)
pw-update-branch-fail|pulse-wrapper.sh|686|Merge pass: PR #.*update-branch failed|Update-branch failed — falling through to conflict handling
pw-update-branch-cooldown|pulse-merge-process.sh|640|Merge pass: PR #.*semantic conflict cooldown active|Update-branch skipped — unchanged interactive head is in semantic-conflict cooldown
pw-update-branch-cooldown-recorded|pulse-merge-process.sh|130|Merge pass: PR #.*recorded semantic update-branch conflict cooldown|Recorded semantic-conflict cooldown for the current PR head
pw-skip-conflicting-nmr|pulse-wrapper.sh|1289|Merge pass: skipping CONFLICTING-close.*needs-maintainer-review|Skipped CONFLICTING-close — linked issue has NMR
pw-update-branch-refetch|pulse-wrapper.sh|1307|Merge pass: PR #.*update-branch succeeded, refetched|Update-branch succeeded on CONFLICTING PR, refetched mergeable state
pw-approve-self|pulse-wrapper.sh|332|approve_collaborator_pr: PR #.*is self-authored.*skipping approval|Skipped PR approval — self-authored PR
pw-approve-no-write|pulse-wrapper.sh|340|approve_collaborator_pr: current user.*lacks write access.*skipping|Skipped PR approval — current user lacks write access
pw-approve-already|pulse-wrapper.sh|349|approve_collaborator_pr: PR #.*already approved.*skipping|Skipped PR approval — already approved
pw-approve-ok|pulse-wrapper.sh|360|approve_collaborator_pr: approved PR #|Approved PR by collaborator
pw-approve-fail|pulse-wrapper.sh|364|approve_collaborator_pr: failed to approve PR #|Failed to approve PR
pw-external-flagged|pulse-wrapper.sh|180|check_external_contributor_pr: flagged PR #|Flagged PR as external contributor
pw-external-no-issue|pulse-wrapper.sh|188|check_external_contributor_pr: PR #.*has no linked issue|External contributor PR has no linked issue — posted comment
pw-workflow-guard-blocked|pulse-wrapper.sh|536|check_workflow_merge_guard: blocked PR #|Workflow merge guard blocked PR — workflow files + missing scope
pw-workflow-guard-skip|pulse-wrapper.sh|515|check_workflow_merge_guard: PR #.*already has workflow scope comment|Workflow merge guard skipped — already commented
pw-merge-pass-complete|pulse-wrapper.sh|574|Deterministic merge pass complete:|Deterministic merge pass completed (summary)
pw-merge-pass-skipped-stop|pulse-wrapper.sh|542|Deterministic merge pass skipped: stop flag|Merge pass skipped — stop flag present
pw-merge-pass-skipped-repos|pulse-wrapper.sh|547|Deterministic merge pass skipped: repos.json not found|Merge pass skipped — repos.json not found
pw-pr-list-failed|pulse-wrapper.sh|617|_process_merge_batch: gh_pr_list FAILED|gh_pr_list failed for repo during merge pass
pw-route-ci-fix|pulse-merge-feedback.sh|328|_dispatch_ci_fix_worker: routed CI failure feedback|Routed CI failure feedback from PR to linked issue for worker fix
pw-route-ci-fix-skip|pulse-merge-feedback.sh|299|_dispatch_ci_fix_worker: PR #.*could not collect details|CI fix routing skipped — could not collect failure details
pw-route-conflict-fix|pulse-merge-feedback.sh|448|_dispatch_conflict_fix_worker: routed conflict feedback|Routed conflict feedback from PR to linked issue for worker fix
pw-route-review-fix|pulse-merge-feedback.sh|574|_dispatch_pr_fix_worker: routed review feedback|Routed review feedback from PR to linked issue for worker fix
pw-route-review-empty|pulse-merge-feedback.sh|536|_dispatch_pr_fix_worker: PR #.*CHANGES_REQUESTED but no substantive|Review fix skipped — CHANGES_REQUESTED but no substantive review content
pw-feedback-routed|pulse-merge-feedback.sh|153|already has routed feedback marker|Feedback routing skipped — already routed for this PR
pw-feedback-body-fail|pulse-merge-feedback.sh|145|failed to fetch issue.*body.*skipping body edit|Feedback routing skipped — failed to fetch issue body
pmc-handover|pulse-merge-conflict.sh|308|handover: PR #.*handed over to worker pipeline|Interactive PR handed over to worker pipeline (idle >AIDEVOPS_IDLE_INTERACTIVE_HANDOVER_SECONDS, default 4h)
pmc-would-handover|pulse-merge-conflict.sh|212|would-handover: PR #|Would-handover detected (detect mode — not acting)
pmc-handover-no-takeover|pulse-merge-conflict.sh|166|_interactive_pr_is_stale: PR #.*has no-takeover label|Handover skipped — PR has no-takeover label
pmc-skip-interactive-close|pulse-merge-conflict.sh|583|Deterministic merge: skipping auto-close of origin:interactive PR|Skipped auto-close of origin:interactive PR — maintainer work never auto-closed
pmc-close-conflicting-redispatch|pulse-merge-conflict.sh|697|Deterministic merge: conflicting PR #.*closed, linked issue left open|Closed conflicting PR, linked issue left open for re-dispatch
pmc-close-conflicting|pulse-merge-conflict.sh|699|Deterministic merge: closed conflicting PR #|Closed conflicting PR (work already on main)
pmc-close-conflicting-generic|pulse-merge-conflict.sh|734|Deterministic merge: closed conflicting PR #|Closed conflicting PR (generic close)
pmc-false-positive-heuristic|pulse-merge-conflict.sh|656|Deterministic merge: task ID match.*no implementation file overlap.*false-positive|Task ID match with no file overlap — false-positive heuristic, PR left open for rebase
pmc-carry-diff|pulse-merge-conflict.sh|904|_carry_forward_pr_diff: appended diff from PR #|Carried forward PR diff to linked issue before close
pmc-carry-diff-skip|pulse-merge-conflict.sh|859|_carry_forward_pr_diff: issue.*already has diff marker|Diff carry-forward skipped — already has diff marker for this PR
pfd-deferred|dispatch-dedup-footprint.sh|220|\[footprint-defer\] event=deferred issue=#|Footprint overlap persisted as a bounded cross-cycle defer
pfd-wake|dispatch-dedup-footprint.sh|170|\[footprint-defer\] event=wake issue=#|Footprint overlap defer woke after lifecycle, footprint, cooldown, or operator change
dps-classify|pulse-dirty-pr-sweep.sh|788|PR #.*decision=|Dirty PR sweep classification decision
dps-rebase-ok|pulse-dirty-pr-sweep.sh|615|PR #.*rebased \+ pushed|Dirty PR rebased and force-pushed successfully
dps-rebase-cooldown|pulse-dirty-pr-sweep.sh|535|PR #.*rebase skipped.*cooldown|Rebase skipped — cooldown active
dps-rebase-fail|pulse-dirty-pr-sweep.sh|581|PR #.*rebase.*failed.*conflicts|Rebase failed — conflicts outside TODO.md
dps-close-ok|pulse-dirty-pr-sweep.sh|675|PR #.*closed$|Dirty PR closed
dps-close-cooldown|pulse-dirty-pr-sweep.sh|627|PR #.*close skipped.*cooldown|Close skipped — cooldown active
dps-close-parent|pulse-dirty-pr-sweep.sh|643|PR #.*close skipped.*open parent-task|Close skipped — linked issue is open parent-task
dps-notify|pulse-dirty-pr-sweep.sh|721|PR #.*notified|Dirty PR notification posted
dps-notify-cooldown|pulse-dirty-pr-sweep.sh|694|PR #.*notify skipped.*cooldown|Notification skipped — cooldown active
dps-sweep-complete|pulse-dirty-pr-sweep.sh|858|sweep complete:|Dirty PR sweep pass completed (summary)
dps-sweep-stop|pulse-dirty-pr-sweep.sh|822|stop flag present.*skipping sweep|Dirty PR sweep skipped — stop flag present
INVENTORY
	return 0
}

_RULE_INVENTORY=$(_build_rule_inventory)
readonly _RULE_INVENTORY

# Shared path resolution and retry helpers.
# shellcheck source=./pulse-diagnose-utils.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-diagnose-utils.sh"

# Collect all log lines mentioning a PR number from pulse.log and rotated files.
# Args: $1 = PR number, $2 = logfile, $3 = logdir
# Outputs lines to stdout sorted chronologically.
_collect_pr_log_lines() {
	local pr_number="$1"
	local logfile="$2"
	local logdir="$3"

	local pattern="#${pr_number}[^0-9]|#${pr_number}$|PR #${pr_number}[^0-9]|PR #${pr_number}$| PR ${pr_number} | PR ${pr_number}$"

	{
		# Current log
		if [[ -f "$logfile" ]]; then
			grep -E "$pattern" "$logfile" 2>/dev/null || true
		fi

		# Rotated logs (uncompressed)
		local rotated
		for rotated in "${logdir}"/pulse.log.[0-9]* ; do
			[[ -f "$rotated" ]] || continue
			[[ "$rotated" == *.gz ]] && continue
			grep -E "$pattern" "$rotated" 2>/dev/null || true
		done

		# Rotated logs (gzipped)
		if command -v zcat >/dev/null 2>&1; then
			for rotated in "${logdir}"/pulse.log.*.gz ; do
				[[ -f "$rotated" ]] || continue
				zcat "$rotated" 2>/dev/null | grep -E "$pattern" 2>/dev/null || true
			done
		fi
	} | sort -t'T' -k1,1 2>/dev/null || sort
	return 0
}

# Collect dispatch/backoff log lines mentioning an issue number.
# Args: $1 = issue number, $2 = logfile, $3 = logdir
# Outputs matching lines sorted chronologically.
_collect_issue_log_lines() {
	local issue_number="$1"
	local logfile="$2"
	local logdir="$3"

	local pattern="(#|issue #|Issue #|issue-)${issue_number}([^0-9]|$)"

	{
		if [[ -f "$logfile" ]]; then
			grep -E "$pattern" "$logfile" 2>/dev/null || true
		fi

		local rotated
		for rotated in "${logdir}"/pulse.log.[0-9]* ; do
			[[ -f "$rotated" ]] || continue
			[[ "$rotated" == *.gz ]] && continue
			grep -E "$pattern" "$rotated" 2>/dev/null || true
		done

		if command -v zcat >/dev/null 2>&1; then
			for rotated in "${logdir}"/pulse.log.*.gz ; do
				[[ -f "$rotated" ]] || continue
				zcat "$rotated" 2>/dev/null | grep -E "$pattern" 2>/dev/null || true
			done
		fi
	} | sort -t'T' -k1,1 2>/dev/null || sort
	return 0
}

# Extract timestamp from a log line. Handles common formats:
#   2026-04-21T17:45:03Z  ... or [2026-04-21T17:45:03Z] ...
_extract_timestamp() {
	local line="$1"
	local output_var="${2:-}"
	local timestamp_value="$_UNKNOWN"
	# ISO timestamp at start of line or after [
	if [[ "$line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z?) ]]; then
		timestamp_value="${BASH_REMATCH[1]}"
	fi
	if [[ -n "$output_var" ]]; then
		printf -v "$output_var" '%s' "$timestamp_value"
	else
		printf '%s\n' "$timestamp_value"
	fi
	return 0
}

# Classify a single log line against the rule inventory.
# Args: $1 = log line, $2 = optional output variable
# Outputs or assigns: rule_id|script|line_range|description
_classify_log_line() {
	local line="$1"
	local output_var="${2:-}"
	local result="${_UNCLASSIFIED}|||Unclassified pulse log entry"

	while IFS='|' read -r rule_id script line_range regex description; do
		[[ -z "$rule_id" ]] && continue
		if [[ "$line" =~ $regex ]]; then
			result="${rule_id}|${script}|${line_range}|${description}"
			break
		fi
	done <<< "$_RULE_INVENTORY"

	if [[ -n "$output_var" ]]; then
		printf -v "$output_var" '%s' "$result"
	else
		printf '%s\n' "$result"
	fi
	return 0
}

# Fetch PR metadata from GitHub API.
# Args: $1 = PR number, $2 = repo slug
# Outputs JSON to stdout.
_fetch_pr_metadata() {
	local pr_number="$1"
	local repo_slug="$2"

	if [[ "${PULSE_DIAGNOSE_GH_OFFLINE:-0}" == "1" ]]; then
		echo "{}"
		return 0
	fi

	if ! command -v gh >/dev/null 2>&1; then
		print_warning "gh CLI not available — skipping PR metadata fetch"
		echo "{}"
		return 0
	fi
	if ! declare -F _gh_with_timeout >/dev/null 2>&1; then
		print_warning "shared GitHub timeout wrapper unavailable — skipping PR metadata fetch"
		echo "{}"
		return 0
	fi

	local pr_json="" gh_rc=0
	pr_json=$(_gh_with_timeout read gh pr view "$pr_number" --repo "$repo_slug" \
		--json number,title,state,author,mergedAt,closedAt,createdAt,labels,reviewDecision,mergeStateStatus,headRefName,headRefOid,baseRefName,isDraft,body 2>/dev/null) || gh_rc=$?
	if [[ "$gh_rc" -ne 0 ]]; then
		if [[ "$gh_rc" -eq 124 ]]; then
			print_warning "gh pr view timed out after ${AIDEVOPS_GH_READ_TIMEOUT:-15}s for PR #${pr_number} in ${repo_slug}"
		else
			print_warning "gh pr view failed for PR #${pr_number} in ${repo_slug}"
		fi
		echo "{}"
		return 0
	fi
	echo "$pr_json"
	return 0
}

# Fetch durable PR conversation comments from the GitHub issues endpoint.
# Args: $1 = PR number, $2 = repo slug
# Outputs one flattened JSON array.
_fetch_pr_comments() {
	local pr_number="$1"
	local repo_slug="$2"
	local endpoint="repos/${repo_slug}/issues/${pr_number}/comments?per_page=100"
	local comments_json="[]"

	if [[ "${PULSE_DIAGNOSE_GH_OFFLINE:-0}" == "1" ]] || ! command -v gh >/dev/null 2>&1; then
		printf '[]\n'
		return 0
	fi
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		comments_json=$(_gh_with_timeout read gh api "$endpoint" --paginate --slurp 2>/dev/null) || comments_json="[]"
	else
		comments_json=$(gh api "$endpoint" --paginate --slurp 2>/dev/null) || comments_json="[]"
	fi
	printf '%s' "$comments_json" | jq -c --arg array_type "$_JSON_ARRAY_TYPE" '
		if type == $array_type and ((.[0]? | type) == $array_type) then add // []
		elif type == $array_type then . else [] end' 2>/dev/null || printf '[]'
	printf '\n'
	return 0
}

# Fetch PR timeline events from GitHub API.
# Args: $1 = PR number, $2 = repo slug
# Outputs JSON array to stdout.
_fetch_pr_timeline() {
	local pr_number="$1"
	local repo_slug="$2"

	if [[ "${PULSE_DIAGNOSE_GH_OFFLINE:-0}" == "1" ]]; then
		echo "[]"
		return 0
	fi

	if ! command -v gh >/dev/null 2>&1; then
		echo "[]"
		return 0
	fi

	local owner repo
	owner="${repo_slug%%/*}"
	repo="${repo_slug##*/}"

	# Timeline via REST API (GraphQL timeline is more complex)
	local timeline_json
	timeline_json=$(gh api "repos/${owner}/${repo}/issues/${pr_number}/timeline" \
		--paginate --jq '.' 2>/dev/null) || {
		print_warning "gh api timeline fetch failed for PR #${pr_number}"
		echo "[]"
		return 0
	}
	echo "$timeline_json"
	return 0
}

# Extract a field from a JSON string via jq with a default fallback.
# Args: $1 = json, $2 = jq path, $3 = default value
_jq_field() {
	local json="$1" path="$2" default="$3"
	printf '%s' "$json" | jq -r "${path} // \"${default}\"" 2>/dev/null || echo "$default"
	return 0
}

# =============================================================================
# Subcommands — cmd_pr helpers
#
# Module-level state shared between cmd_pr sub-functions. Reset by
# _cmd_pr_parse_args at the start of each cmd_pr invocation.
# =============================================================================

_CMD_PR_NUMBER=""
_CMD_PR_REPO_SLUG=""
_CMD_PR_VERBOSE=0
_CMD_PR_JSON_OUTPUT=0
_CMD_PR_LOGFILE_OVERRIDE=""
_CMD_PR_EVENTS=()
_CMD_PR_EVENT_COUNT=0
_CMD_PR_ANCILLARY_EMPTY_JSON='{"present":false,"kind":"thread-response"}'
_CMD_PR_ANCILLARY_JSON="$_CMD_PR_ANCILLARY_EMPTY_JSON"
_CMD_PR_REMOTE_ROUTE_EMPTY_JSON='{"present":false,"kind":"","terminal_label":"","linked_issue":0,"pr_head":"","start_evidence":false,"completion_evidence":false,"dispatch_release":false,"issue_state":"","issue_labels":"","recovery_blocker_evidence":""}'
_CMD_PR_REMOTE_ROUTE_JSON="$_CMD_PR_REMOTE_ROUTE_EMPTY_JSON"

# Parse cmd_pr CLI arguments into _CMD_PR_* module globals.
# Returns 1 on validation error.
_cmd_pr_parse_args() {
	_CMD_PR_NUMBER=""
	_CMD_PR_REPO_SLUG=""
	_CMD_PR_VERBOSE=0
	_CMD_PR_JSON_OUTPUT=0
	_CMD_PR_LOGFILE_OVERRIDE=""
	_CMD_PR_ANCILLARY_JSON="$_CMD_PR_ANCILLARY_EMPTY_JSON"
	_CMD_PR_REMOTE_ROUTE_JSON="$_CMD_PR_REMOTE_ROUTE_EMPTY_JSON"

	while [[ $# -gt 0 ]]; do
		case "${1}" in
			--repo)
				_CMD_PR_REPO_SLUG="${2:-}"
				shift 2
				;;
			--verbose)
				_CMD_PR_VERBOSE=1
				shift
				;;
			--json)
				_CMD_PR_JSON_OUTPUT=1
				shift
				;;
			--logfile)
				_CMD_PR_LOGFILE_OVERRIDE="${2:-}"
				shift 2
				;;
			-*)
				print_error "unknown option: ${1}"
				return 1
				;;
			*)
				if [[ -z "$_CMD_PR_NUMBER" ]]; then
					_CMD_PR_NUMBER="${1}"
				fi
				shift
				;;
		esac
	done

	if [[ -z "$_CMD_PR_NUMBER" ]]; then
		print_error "usage: pulse-diagnose-helper.sh pr <N> [--repo <slug>] [--verbose] [--json]"
		return 1
	fi

	# Default repo slug: try git remote
	if [[ -z "$_CMD_PR_REPO_SLUG" ]]; then
		_CMD_PR_REPO_SLUG=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||; s|\.git$||' || true)
		if [[ -z "$_CMD_PR_REPO_SLUG" ]]; then
			print_error "could not determine repo slug — pass --repo <owner/repo>"
			return 1
		fi
	fi
	return 0
}

# Return a feedback-route kind from authoritative terminal PR labels.
_diagnose_pr_route_kind() {
	local labels="$1"
	case ",${labels}," in
	*,ci-feedback-routed,*) printf 'ci' ;;
	*,review-routed-to-issue,*) printf 'review' ;;
	*,conflict-feedback-routed,*) printf 'conflict' ;;
	*) printf '' ;;
	esac
	return 0
}

# Return the terminal label for one feedback-route kind.
_diagnose_pr_route_terminal_label() {
	local kind="$1"
	case "$kind" in
	ci) printf 'ci-feedback-routed' ;;
	review) printf 'review-routed-to-issue' ;;
	conflict) printf 'conflict-feedback-routed' ;;
	*) printf '' ;;
	esac
	return 0
}

# Extract one linked issue number from trusted route text or the PR body.
_diagnose_linked_issue_from_text() {
	local text="$1"
	if [[ "$text" =~ ([Rr]esolves|[Cc]loses|[Ff]ixes|[Ff]or|[Rr]ef)[[:space:]]+\#([1-9][0-9]*) ]]; then
		printf '%s' "${BASH_REMATCH[2]}"
		return 0
	fi
	if [[ "$text" =~ [Ii]ssue[[:space:]]+\#([1-9][0-9]*) ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 0
}

# Extract one exact feedback-route marker for a PR, phase, and optional kind.
_diagnose_route_marker() {
	local text="$1"
	local phase="$2"
	local pr_number="$3"
	local expected_head="$4"
	local expected_kind="${5:-}"
	local kind_pattern='(review|conflict|ci)'
	[[ "$expected_head" =~ ^[0-9A-Za-z]{7,64}$ ]] || return 0
	case "$expected_kind" in
	'') ;;
	review | conflict | ci) kind_pattern="$expected_kind" ;;
	*) return 0 ;;
	esac
	printf '%s\n' "$text" | grep -Eo "<!-- feedback-route:${phase}:${kind_pattern}:PR${pr_number}:SHA${expected_head}(:EVIDENCE[^[:space:]<]+)? -->" \
		2>/dev/null | sed -n '1p' || true
	return 0
}

# Keep only trusted automation/maintainer comment bodies for route evidence.
_diagnose_trusted_comment_text() {
	local comments_json="$1"
	printf '%s' "$comments_json" | jq -r '[.[]?
		| select((.author_association // "") as $association
			| ["OWNER", "MEMBER", "COLLABORATOR"] | index($association))
		| (.body // "")] | join("\n")' 2>/dev/null || true
	return 0
}

# Return active global GraphQL circuit state when its durable state is valid.
_diagnose_graphql_circuit_evidence() {
	local state_file="${PULSE_DIAGNOSE_GRAPHQL_CIRCUIT_FILE:-${HOME}/.aidevops/logs/pulse-graphql-circuit-breaker.state}"
	local observed_at="" remaining="" limit="" threshold=""
	[[ -f "$state_file" && ! -L "$state_file" ]] || return 0
	IFS=' ' read -r observed_at remaining limit threshold <"$state_file" || return 0
	[[ "$observed_at" =~ ^[0-9]+$ && "$remaining" =~ ^[0-9]+$ \
		&& "$limit" =~ ^[0-9]+$ && "$threshold" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
	printf 'graphql_circuit active=yes remaining=%s limit=%s threshold=%s observed_at=%s' \
		"$remaining" "$limit" "$threshold" "$observed_at"
	return 0
}

# Return the most recent bounded quota/fuse/backoff line known for recovery.
_diagnose_recovery_blocker_evidence() {
	local trusted_issue_text="$1"
	local issue_log_lines="$2"
	local evidence="" cooldown_summary="" graphql_circuit=""
	evidence=$(printf '%s\n%s\n' "$trusted_issue_text" "$issue_log_lines" \
		| grep -Ei 'REST.*hard[- ]floor|hard[- ]floor.*REST|BACKOFF_ACTIVE|rate[- _]?limit.*(reset|wait|next)|dispatch.*(fuse|circuit)|circuit.*dispatch' \
		| sed -n '$p' 2>/dev/null || true)
	if declare -F _api_budget_cooldown_summary_csv >/dev/null 2>&1; then
		cooldown_summary=$(_api_budget_cooldown_summary_csv)
		if [[ "$cooldown_summary" == *"active=yes"* ]]; then
			evidence="${evidence:+${evidence}; }secondary_cooldown ${cooldown_summary}"
		fi
	fi
	graphql_circuit=$(_diagnose_graphql_circuit_evidence)
	if [[ -n "$graphql_circuit" ]]; then
		evidence="${evidence:+${evidence}; }${graphql_circuit}"
	fi
	evidence="${evidence//$'\r'/ }"
	evidence="${evidence//$'\t'/ }"
	printf '%.300s' "$evidence"
	return 0
}

# Collect durable GitHub feedback-route evidence that may have been written by
# another runner after local pulse logs stopped.
_cmd_pr_collect_remote_route() {
	local repo_slug="$1"
	local pr_number="$2"
	local pr_json="$3"
	local logfile="$4"
	local logdir="$5"
	local labels="" kind="" terminal_label="" pr_head="" pr_body=""
	local pr_comments_json="[]" trusted_pr_text="" linked_issue=""
	local issue_json="{}" issue_comments_json="[]" trusted_issue_text="" issue_body=""
	local issue_state="" issue_labels="" issue_log_lines="" blocker_evidence=""
	local combined_evidence="" start_marker="" completion_marker="" dispatch_release="$_BOOL_FALSE" present="$_BOOL_FALSE"

	labels=$(printf '%s' "$pr_json" | jq -r '[.labels[]?.name] | join(",")' 2>/dev/null || true)
	kind=$(_diagnose_pr_route_kind "$labels")
	terminal_label=$(_diagnose_pr_route_terminal_label "$kind")
	pr_head=$(_jq_field "$pr_json" '.headRefOid' '')
	pr_body=$(_jq_field "$pr_json" '.body' '')
	pr_comments_json=$(_fetch_pr_comments "$pr_number" "$repo_slug")
	trusted_pr_text=$(_diagnose_trusted_comment_text "$pr_comments_json")
	linked_issue=$(_diagnose_linked_issue_from_text "$pr_body")
	[[ -n "$linked_issue" ]] || linked_issue=$(_diagnose_linked_issue_from_text "$trusted_pr_text")

	if [[ "$linked_issue" =~ ^[1-9][0-9]*$ ]]; then
		issue_json=$(_fetch_issue_metadata "$linked_issue" "$repo_slug")
		issue_comments_json=$(_fetch_issue_comments "$linked_issue" "$repo_slug")
		trusted_issue_text=$(_diagnose_trusted_comment_text "$issue_comments_json")
		issue_body=$(_jq_field "$issue_json" '.body' '')
		issue_state=$(_jq_field "$issue_json" '.state' '')
		issue_labels=$(printf '%s' "$issue_json" | jq -r '[.labels[]?.name] | join(",")' 2>/dev/null || true)
		issue_log_lines=$(_collect_issue_log_lines "$linked_issue" "$logfile" "$logdir")
		blocker_evidence=$(_diagnose_recovery_blocker_evidence "$trusted_issue_text" "$issue_log_lines")
	fi

	combined_evidence="${trusted_pr_text}
${issue_body}
${trusted_issue_text}"
	if [[ -z "$kind" ]]; then
		start_marker=$(_diagnose_route_marker "$combined_evidence" start "$pr_number" "$pr_head")
		if [[ -n "$start_marker" ]]; then
			kind="${start_marker#*feedback-route:start:}"
			kind="${kind%%:*}"
		else
			completion_marker=$(_diagnose_route_marker "$combined_evidence" complete "$pr_number" "$pr_head")
			if [[ -n "$completion_marker" ]]; then
				kind="${completion_marker#*feedback-route:complete:}"
				kind="${kind%%:*}"
			fi
		fi
		terminal_label=$(_diagnose_pr_route_terminal_label "$kind")
	fi
	if [[ -n "$kind" ]]; then
		start_marker=$(_diagnose_route_marker "$combined_evidence" start "$pr_number" "$pr_head" "$kind")
		completion_marker=$(_diagnose_route_marker "$combined_evidence" complete "$pr_number" "$pr_head" "$kind")
	fi
	if [[ -n "$kind" && -n "$pr_head" ]] && printf '%s' "$trusted_issue_text" \
		| grep -qF "<!-- feedback-route:dispatch-release:${kind}:PR${pr_number}:SHA${pr_head} -->"; then
		dispatch_release="$_BOOL_TRUE"
	fi
	if [[ -n "$terminal_label" || -n "$start_marker" || -n "$completion_marker" ]]; then
		present="$_BOOL_TRUE"
	fi

	jq -cn --argjson present "$present" --arg kind "$kind" --arg terminal_label "$terminal_label" \
		--arg linked_issue "${linked_issue:-0}" --arg pr_head "$pr_head" \
		--argjson start_evidence "$([[ -n "$start_marker" ]] && printf true || printf false)" \
		--argjson completion_evidence "$([[ -n "$completion_marker" ]] && printf true || printf false)" \
		--argjson dispatch_release "$dispatch_release" --arg issue_state "$issue_state" \
		--arg issue_labels "$issue_labels" --arg recovery_blocker_evidence "$blocker_evidence" \
		'{present:$present,kind:$kind,terminal_label:$terminal_label,linked_issue:($linked_issue | tonumber),
		pr_head:$pr_head,start_evidence:$start_evidence,completion_evidence:$completion_evidence,
		dispatch_release:$dispatch_release,issue_state:$issue_state,issue_labels:$issue_labels,
		recovery_blocker_evidence:$recovery_blocker_evidence}'
	return 0
}

_render_pr_remote_route_text() {
	local remote_json="$1"
	local summary="" kind="" terminal_label="" linked_issue="0" pr_head=""
	local start_evidence="$_BOOL_FALSE" completion_evidence="$_BOOL_FALSE" dispatch_release="$_BOOL_FALSE"
	local issue_state="" issue_labels="" blocker_evidence=""
	[[ "$(printf '%s' "$remote_json" | jq -r '.present // false' 2>/dev/null)" == "$_BOOL_TRUE" ]] || return 0
	summary=$(printf '%s' "$remote_json" | jq -r '[.kind,.terminal_label,(.linked_issue|tostring),.pr_head,
		(.start_evidence|tostring),(.completion_evidence|tostring),(.dispatch_release|tostring),
		.issue_state,.issue_labels,.recovery_blocker_evidence] | map(. // "") | join("\u001c")')
	IFS=$'\034' read -r kind terminal_label linked_issue pr_head start_evidence completion_evidence \
		dispatch_release issue_state issue_labels blocker_evidence <<<"$summary"
	printf 'Durable GitHub route evidence:\n'
	printf '  Kind: %s  terminal_label=%s  head=%s\n' "$kind" "$terminal_label" "$pr_head"
	if [[ "$linked_issue" =~ ^[1-9][0-9]*$ ]]; then
		printf '  Linked issue: #%s  state=%s  labels=%s\n' "$linked_issue" "$issue_state" "$issue_labels"
	fi
	printf '  Start evidence: %s  completion evidence: %s  dispatch release: %s\n' \
		"$start_evidence" "$completion_evidence" "$dispatch_release"
	[[ -n "$blocker_evidence" ]] && printf '  Recovery blocker evidence: %s\n' "$blocker_evidence"
	printf '\n'
	return 0
}

# Read one exact key from a scanner state/outcome file.
# Args: $1=file  $2=key
_diagnose_kv_value() {
	local file="$1"
	local expected_key="$2"
	[[ -f "$file" ]] || return 0
	local key=""
	local value=""
	while IFS='=' read -r key value; do
		if [[ "$key" == "$expected_key" ]]; then
			printf '%s' "$value"
			return 0
		fi
	done <"$file"
	return 0
}

# Escape one value for a SQLite string literal.
# Args: $1=value
_diagnose_sql_escape() {
	local value="$1"
	printf '%s' "${value//\'/\'\'}"
	return 0
}

# Return the latest bounded dispatch-ledger row for a session.
# Args: $1=ledger_file  $2=session_key
_diagnose_latest_ledger_row() {
	local ledger_file="$1"
	local session_key="$2"
	[[ -f "$ledger_file" ]] || {
		printf '{}\n'
		return 0
	}
	local max_lines="${PULSE_DIAGNOSE_LEDGER_MAX_LINES:-2000}"
	[[ "$max_lines" =~ ^[1-9][0-9]{0,4}$ ]] || max_lines=2000
	tail -n "$max_lines" "$ledger_file" 2>/dev/null | jq -Rsc --arg session "$session_key" '
		[(split("\n")[] | select(length > 0) | try fromjson catch empty | select(.session_key == $session))]
		| last // {}
	' 2>/dev/null || printf '{}\n'
	return 0
}

_diagnose_registry_row() {
	local registry_db="$1"
	local worktree_path="$2"
	local session_key="$3"
	command -v sqlite3 >/dev/null 2>&1 || return 0
	[[ -f "$registry_db" ]] || return 0
	if [[ -n "$worktree_path" ]]; then
		local escaped_path=""
		escaped_path=$(_diagnose_sql_escape "$worktree_path")
		sqlite3 -separator '|' "$registry_db" \
			"SELECT worktree_path, owner_pid, owner_session, task_id, created_at FROM worktree_owners WHERE worktree_path = '${escaped_path}' LIMIT 1;" 2>/dev/null || true
		return 0
	fi
	local escaped_session=""
	escaped_session=$(_diagnose_sql_escape "$session_key")
	sqlite3 -separator '|' "$registry_db" \
		"SELECT worktree_path, owner_pid, owner_session, task_id, created_at FROM worktree_owners WHERE owner_session = '${escaped_session}' ORDER BY created_at DESC LIMIT 1;" 2>/dev/null || true
	return 0
}

_diagnose_worktree_json() {
	local worktree_path="$1"
	local head_ref="$2"
	local worktree_exists=false branch="" upstream="" upstream_ahead="" dirty_count=0
	local upstream_mismatch=false dirty_json='[]'
	if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
		worktree_exists=true
		branch=$(git -C "$worktree_path" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached')
		upstream=$(git -C "$worktree_path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
		if [[ -n "$upstream" ]]; then
			upstream_ahead=$(git -C "$worktree_path" rev-list --count "${upstream}..HEAD" 2>/dev/null || true)
		fi
		local dirty_lines=""
		dirty_lines=$(git -C "$worktree_path" status --short --untracked-files=normal 2>/dev/null || true)
		dirty_count=$(printf '%s\n' "$dirty_lines" | awk 'NF { count++ } END { print count + 0 }')
		dirty_json=$(printf '%s\n' "$dirty_lines" | jq -Rsc 'split("\n") | map(select(length > 0)) | .[0:10]' 2>/dev/null || printf '[]')
		if [[ -n "$upstream" && -n "$head_ref" && "$upstream" != "origin/${head_ref}" ]]; then
			upstream_mismatch=true
		fi
	fi
	jq -cn --arg path "$worktree_path" --argjson exists "$worktree_exists" \
		--arg branch "$branch" --arg upstream "$upstream" --arg ahead "$upstream_ahead" \
		--argjson mismatch "$upstream_mismatch" --argjson dirty_count "$dirty_count" \
		--argjson dirty_paths "$dirty_json" \
		'{path:$path,exists:$exists,branch:$branch,upstream:$upstream,upstream_ahead:$ahead,upstream_mismatch:$mismatch,dirty_count:$dirty_count,dirty_paths:$dirty_paths}'
	return 0
}

# Collect bounded ancillary thread-response worker diagnostics for one PR.
# Args: $1=repo_slug  $2=pr_number  $3=head_ref
# Output: one JSON object.
_cmd_pr_collect_ancillary() {
	local repo_slug="$1"
	local pr_number="$2"
	local head_ref="$3"
	local state_dir="${PULSE_DIAGNOSE_THREAD_RESPONSE_STATE_DIR:-$DEFAULT_THREAD_RESPONSE_STATE_DIR}"
	local ledger_file="${PULSE_DIAGNOSE_DISPATCH_LEDGER_FILE:-$DEFAULT_DISPATCH_LEDGER_FILE}"
	local registry_db="${PULSE_DIAGNOSE_WORKTREE_REGISTRY_DB:-$DEFAULT_WORKTREE_REGISTRY_DB}"
	local safe_slug=""
	safe_slug=$(printf '%s' "$repo_slug" | tr '/:' '--')
	local session_key="pr-review-thread-response-${safe_slug}-${pr_number}"
	local state_file="${state_dir}/${safe_slug}-${pr_number}.state"
	local outcome_file="${state_dir}/${safe_slug}-${pr_number}.outcome"

	local attempt_count="" dispatched_at="" blocked_by="" blocker_reason=""
	local outcome_reason="" session_count="" finished_at=""
	attempt_count=$(_diagnose_kv_value "$state_file" attempt_count)
	dispatched_at=$(_diagnose_kv_value "$state_file" dispatched_at)
	blocked_by=$(_diagnose_kv_value "$state_file" blocked_by)
	blocker_reason=$(_diagnose_kv_value "$state_file" blocker_reason)
	outcome_reason=$(_diagnose_kv_value "$outcome_file" reason)
	session_count=$(_diagnose_kv_value "$outcome_file" session_count)
	finished_at=$(_diagnose_kv_value "$outcome_file" finished_at)

	local ledger_json="{}"
	ledger_json=$(_diagnose_latest_ledger_row "$ledger_file" "$session_key")
	local ledger_status="" ledger_phase="" ledger_pid="" worktree_path="" ledger_updated_at=""
	ledger_status=$(printf '%s' "$ledger_json" | jq -r '.status // empty' 2>/dev/null || true)
	ledger_phase=$(printf '%s' "$ledger_json" | jq -r '.lease_phase // empty' 2>/dev/null || true)
	ledger_pid=$(printf '%s' "$ledger_json" | jq -r '.pid // empty' 2>/dev/null || true)
	worktree_path=$(printf '%s' "$ledger_json" | jq -r '.worktree_path // empty' 2>/dev/null || true)
	ledger_updated_at=$(printf '%s' "$ledger_json" | jq -r '.updated_at // empty' 2>/dev/null || true)

	local registry_row=""
	registry_row=$(_diagnose_registry_row "$registry_db" "$worktree_path" "$session_key")

	local owner_pid="" owner_session="" owner_task="" owner_created_at=""
	if [[ -n "$registry_row" ]]; then
		IFS='|' read -r worktree_path owner_pid owner_session owner_task owner_created_at <<<"$registry_row"
	fi
	local owner_status="unknown" owner_matches_session=true
	if [[ -n "$registry_row" && "$owner_session" != "$session_key" ]]; then
		owner_status="mismatch"
		owner_matches_session=false
	elif [[ "$owner_pid" =~ ^[0-9]+$ ]]; then
		if kill -0 "$owner_pid" 2>/dev/null; then
			owner_status="alive"
		else
			owner_status="dead"
		fi
	fi

	local worktree_json="{}" registry_stale=false
	worktree_json=$(_diagnose_worktree_json "$worktree_path" "$head_ref")
	[[ "$owner_status" == "dead" ]] && registry_stale=true

	local present=false
	if [[ -f "$state_file" || -f "$outcome_file" || "$ledger_json" != "{}" || -n "$registry_row" ]]; then
		present=true
	fi
	jq -cn \
		--argjson present "$present" \
		--arg kind "thread-response" \
		--arg session_key "$session_key" \
		--arg attempt_count "$attempt_count" \
		--arg dispatched_at "$dispatched_at" \
		--arg blocked_by "$blocked_by" \
		--arg blocked_reason "$blocker_reason" \
		--arg outcome_reason "$outcome_reason" \
		--arg session_count "$session_count" \
		--arg finished_at "$finished_at" \
		--arg ledger_status "$ledger_status" \
		--arg ledger_phase "$ledger_phase" \
		--arg ledger_pid "$ledger_pid" \
		--arg ledger_updated_at "$ledger_updated_at" \
		--arg owner_pid "$owner_pid" \
		--arg owner_session "$owner_session" \
		--arg owner_task "$owner_task" \
		--arg owner_created_at "$owner_created_at" \
		--arg owner_status "$owner_status" \
		--argjson owner_matches_session "$owner_matches_session" \
		--argjson registry_stale "$registry_stale" \
		--argjson worktree "$worktree_json" \
		'{present:$present,kind:$kind,session_key:$session_key,state:{attempt_count:$attempt_count,dispatched_at:$dispatched_at,blocked_by:$blocked_by,blocked_reason:$blocked_reason},outcome:{reason:$outcome_reason,session_count:$session_count,finished_at:$finished_at},ledger:{status:$ledger_status,lease_phase:$ledger_phase,pid:$ledger_pid,updated_at:$ledger_updated_at},registry:{owner_pid:$owner_pid,owner_session:$owner_session,owner_task:$owner_task,owner_created_at:$owner_created_at,owner_status:$owner_status,matches_session:$owner_matches_session,stale:$registry_stale},worktree:$worktree}'
	return 0
}

_render_pr_ancillary_text() {
	local ancillary_json="$1"
	[[ "$(printf '%s' "$ancillary_json" | jq -r '.present // false' 2>/dev/null)" == "$_BOOL_TRUE" ]] || return 0
	local summary=""
	summary=$(printf '%s' "$ancillary_json" | jq -r '[.state.attempt_count,.outcome.session_count,.outcome.reason,.ledger.status,.ledger.lease_phase,.ledger.pid,.registry.owner_pid,.registry.owner_status,.registry.stale,.worktree.path,.worktree.branch,.worktree.upstream,.worktree.upstream_ahead,.worktree.upstream_mismatch,.worktree.dirty_count,.state.blocked_reason] | map(. // "" | tostring) | join("\u001c")')
	local attempt="" sessions="" outcome="" ledger_status="" lease_phase="" ledger_pid=""
	local owner_pid="" owner_status="" registry_stale="" worktree_path="" branch="" upstream=""
	local upstream_ahead="" upstream_mismatch="" dirty_count="" blocked_reason=""
	IFS=$'\034' read -r attempt sessions outcome ledger_status lease_phase ledger_pid \
		owner_pid owner_status registry_stale worktree_path branch upstream upstream_ahead \
		upstream_mismatch dirty_count blocked_reason <<<"$summary"
	printf 'Ancillary workers:\n'
	printf '  thread-response  attempt=%s  sessions=%s  outcome=%s\n' \
		"$attempt" "$sessions" "$outcome"
	printf '    ledger_status=%s  lease_phase=%s  pid=%s\n' \
		"$ledger_status" "$lease_phase" "$ledger_pid"
	printf '    owner_pid=%s  owner_status=%s  registry_stale=%s\n' \
		"$owner_pid" "${owner_status:-unknown}" "${registry_stale:-false}"
	printf '    worktree=%s\n' "$worktree_path"
	printf '    branch=%s  upstream=%s  ahead=%s  upstream_mismatch=%s\n' \
		"$branch" "$upstream" "$upstream_ahead" "${upstream_mismatch:-false}"
	printf '    dirty_files=%s  blocked_reason=%s\n' \
		"${dirty_count:-0}" "$blocked_reason"
	printf '%s' "$ancillary_json" | jq -r '.worktree.dirty_paths[]? | "      \(.)"' 2>/dev/null || true
	printf '\n'
	return 0
}

# Classify log lines into the _CMD_PR_EVENTS array and set _CMD_PR_EVENT_COUNT.
# Args: $1=log_lines  $2=verbose (0|1)
_cmd_pr_build_events() {
	local log_lines="$1"
	local verbose="$2"
	_CMD_PR_EVENTS=()
	_CMD_PR_EVENT_COUNT=0

	[[ -z "$log_lines" ]] && return 0

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local ts classification
		_extract_timestamp "$line" ts
		_classify_log_line "$line" classification

		local rule_id script line_range description
		IFS='|' read -r rule_id script line_range description <<< "$classification"

		_CMD_PR_EVENTS+=("${ts}|${rule_id}|${script}|${line_range}|${description}")
		_CMD_PR_EVENT_COUNT=$((_CMD_PR_EVENT_COUNT + 1))

		if [[ "$verbose" -eq 1 ]]; then
			_CMD_PR_EVENTS+=("  RAW: ${line}")
		fi
	done <<< "$log_lines"
	return 0
}

# Render the human-readable PR correlation report.
# Args: pr_number author state closed_at merged_flag pr_merged_at pr_title
#       pr_created_at pr_review_decision pr_mss event_count [events...]
_render_pr_text() {
	local pr_number="$1" author="$2" state="$3" closed_at="${4:-}"
	local merged_flag="$5" pr_merged_at="${6:-}" pr_title="${7:-}"
	local pr_created_at="${8:-}" pr_review_decision="${9:-}" pr_mss="${10:-}"
	local event_count="${11}"
	shift 11

	printf '\nPR #%s (%s, %s %s, merged=%s)\n' \
		"$pr_number" "$author" "$state" "${closed_at:-ongoing}" "$merged_flag"
	if [[ -n "$pr_title" ]]; then
		printf '  Title: %s\n' "$pr_title"
	fi
	printf '  Created: %s  Review: %s  MergeState: %s\n\n' \
		"${pr_created_at:-unknown}" "${pr_review_decision:-none}" "${pr_mss:-unknown}"

	if [[ "$event_count" -eq 0 ]]; then
		printf '  (no pulse log entries found for this PR)\n'
		if [[ -n "$pr_merged_at" ]]; then
			printf '\n  This PR was merged at %s but has no pulse log entries.\n' "$pr_merged_at"
			printf '  Likely cause: manual merge via gh pr merge or GitHub UI (admin bypass).\n'
		fi
		printf '\n'
		return 0
	fi

	local last_rule_id="" unclassified_count=0
	local entry
	for entry in "$@"; do
		if [[ "$entry" == "  RAW: "* ]]; then
			printf '%b%s%b\n' "$CYAN" "$entry" "$NC"
			continue
		fi

		local ts rule_id script line_range description
		IFS='|' read -r ts rule_id script line_range description <<< "$entry"
		[[ "$rule_id" == "$_UNCLASSIFIED" && "$_CMD_PR_VERBOSE" -ne 1 ]] && { unclassified_count=$((unclassified_count + 1)); continue; }
		printf '  %s  %b%-30s%b  %s\n' \
			"$ts" "$YELLOW" "${script:-unknown}" "$NC" "${rule_id:-$_UNCLASSIFIED}"
		printf '              %s\n' "$description"
		if [[ -n "$line_range" ]]; then
			printf '              source: %s:%s\n' "${script}" "${line_range}"
		fi
		printf '\n'
		last_rule_id="$rule_id"
	done
	[[ "$unclassified_count" -gt 0 ]] && printf '  Unclassified pulse events: %d (use --verbose for raw evidence)\n\n' "$unclassified_count"
	printf 'Summary:\n'
	printf '  Total pulse events: %d\n' "$event_count"

	if [[ -n "$last_rule_id" && "$last_rule_id" != "$_UNCLASSIFIED" ]]; then
		printf '  Last pulse decision: %s\n' "$last_rule_id"
	fi

	if [[ -n "$pr_merged_at" ]]; then
		local pulse_merged=0
		local e
		for e in "$@"; do
			if [[ "$e" == *"pw-merged"* || "$e" == *"pm-auto-merge"* ]]; then
				pulse_merged=1
				break
			fi
		done
		if [[ "$pulse_merged" -eq 1 ]]; then
			printf '  Outcome: pulse auto-merged this PR.\n'
		else
			printf '  Outcome: PR was merged, but not by the pulse (admin-bypass or manual merge).\n'
		fi
	elif [[ "$state" == "CLOSED" ]]; then
		printf '  Outcome: PR was closed without merge.\n'
	else
		printf '  Outcome: PR is still open.\n'
	fi
	printf '\n'
	return 0
}

# =============================================================================
# Subcommands
# =============================================================================

cmd_pr() {
	_cmd_pr_parse_args "$@" || return 1

	local logfile logdir
	logfile=$(_resolve_logfile "$_CMD_PR_LOGFILE_OVERRIDE")
	logdir=$(_resolve_logdir)

	local log_lines
	log_lines=$(_collect_pr_log_lines "$_CMD_PR_NUMBER" "$logfile" "$logdir")

	local pr_json
	pr_json=$(_fetch_pr_metadata "$_CMD_PR_NUMBER" "$_CMD_PR_REPO_SLUG")

	local pr_author="" pr_state="" pr_merged_at="" pr_closed_at="" pr_created_at="" pr_title="" pr_review_decision="" pr_mss="" pr_head_ref=""
	pr_author=$(_jq_field "$pr_json" ".author.login" "$_UNKNOWN")
	pr_state=$(_jq_field "$pr_json" ".state" "$_UNKNOWN")
	pr_merged_at=$(_jq_field "$pr_json" ".mergedAt" "")
	pr_closed_at=$(_jq_field "$pr_json" ".closedAt" "")
	pr_created_at=$(_jq_field "$pr_json" ".createdAt" "")
	pr_title=$(_jq_field "$pr_json" ".title" "")
	pr_review_decision=$(_jq_field "$pr_json" ".reviewDecision" "")
	pr_mss=$(_jq_field "$pr_json" ".mergeStateStatus" "")
	pr_head_ref=$(_jq_field "$pr_json" "$_PR_HEAD_REF_JSON_PATH" "")

	local merged_flag="no"
	[[ -n "$pr_merged_at" ]] && merged_flag="yes"

	_cmd_pr_build_events "$log_lines" "$_CMD_PR_VERBOSE"
	_CMD_PR_ANCILLARY_JSON=$(_cmd_pr_collect_ancillary "$_CMD_PR_REPO_SLUG" "$_CMD_PR_NUMBER" "$pr_head_ref") || \
		_CMD_PR_ANCILLARY_JSON="$_CMD_PR_ANCILLARY_EMPTY_JSON"
	_CMD_PR_REMOTE_ROUTE_JSON=$(_cmd_pr_collect_remote_route "$_CMD_PR_REPO_SLUG" "$_CMD_PR_NUMBER" \
		"$pr_json" "$logfile" "$logdir") || _CMD_PR_REMOTE_ROUTE_JSON="$_CMD_PR_REMOTE_ROUTE_EMPTY_JSON"

	if [[ "$_CMD_PR_JSON_OUTPUT" -eq 1 ]]; then
		_render_json "$_CMD_PR_NUMBER" "$_CMD_PR_REPO_SLUG" "$pr_author" "$pr_state" "$merged_flag" \
			"$pr_created_at" "$pr_closed_at" "$pr_merged_at" "$pr_title" \
			"$pr_review_decision" "$pr_mss" "$_CMD_PR_EVENT_COUNT" \
			"${_CMD_PR_EVENTS[@]+"${_CMD_PR_EVENTS[@]}"}"
		return 0
	fi

	_render_pr_text "$_CMD_PR_NUMBER" "$pr_author" "$pr_state" "$pr_closed_at" \
		"$merged_flag" "$pr_merged_at" "$pr_title" "$pr_created_at" \
		"$pr_review_decision" "$pr_mss" "$_CMD_PR_EVENT_COUNT" \
		"${_CMD_PR_EVENTS[@]+"${_CMD_PR_EVENTS[@]}"}"
	_render_pr_remote_route_text "$_CMD_PR_REMOTE_ROUTE_JSON"
	_render_pr_ancillary_text "$_CMD_PR_ANCILLARY_JSON"
	return 0
}

_json_str_field() {
	local key="$1" val="$2" trailing="${3:-,}"
	printf '  "%s": "%s"%s\n' "$key" "$val" "$trailing"
	return 0
}

_json_num_field() {
	local key="$1" val="$2" trailing="${3:-,}"
	printf '  "%s": %s%s\n' "$key" "$val" "$trailing"
	return 0
}

_render_json() {
	local pr_number="$1" repo_slug="$2" author="$3" state="$4" merged="$5"
	local created="$6" closed="$7" merged_at="$8" title="$9"
	shift 9
	local review_decision="$1" mss="$2" event_count="$3"
	shift 3

	local merged_bool="$_BOOL_FALSE"
	[[ "$merged" == "yes" ]] && merged_bool="$_BOOL_TRUE"

	printf '{\n'
	_json_num_field "pr_number" "$pr_number"
	_json_str_field "repo" "$repo_slug"
	_json_str_field "author" "$author"
	_json_str_field "state" "$state"
	_json_num_field "merged" "$merged_bool"
	_json_str_field "created_at" "$created"
	_json_str_field "closed_at" "$closed"
	_json_str_field "merged_at" "$merged_at"
	_json_str_field "title" "$title"
	_json_str_field "review_decision" "$review_decision"
	_json_str_field "merge_state_status" "$mss"
	_json_num_field "event_count" "$event_count"
	printf '  "events": [\n'

	local first=1
	for entry in "$@"; do
		[[ "$entry" == "  RAW: "* ]] && continue
		[[ -z "$entry" ]] && continue

		local ts rule_id script line_range description
		IFS='|' read -r ts rule_id script line_range description <<< "$entry"
		[[ -z "$rule_id" ]] && continue

		if [[ "$first" -eq 0 ]]; then
			printf ',\n'
		fi
		first=0
		printf '    {"timestamp": "%s", "rule_id": "%s", "script": "%s", "line": "%s", "description": "%s"}' \
			"$ts" "$rule_id" "$script" "$line_range" "$description"
	done

	printf '\n  ],\n'
	printf '  "remote_route": %s,\n' "$_CMD_PR_REMOTE_ROUTE_JSON"
	printf '  "ancillary": %s\n' "$_CMD_PR_ANCILLARY_JSON"
	printf '}\n'
	return 0
}

cmd_rules() {
	local json_output=0
	while [[ $# -gt 0 ]]; do
		case "${1}" in
			--json) json_output=1; shift ;;
			*) shift ;;
		esac
	done

	local inventory="$_RULE_INVENTORY"
	local count=0

	if [[ "$json_output" -eq 1 ]]; then
		printf '[\n'
		local first=1
		while IFS='|' read -r rule_id script line_range regex description; do
			[[ -z "$rule_id" ]] && continue
			if [[ "$first" -eq 0 ]]; then
				printf ',\n'
			fi
			first=0
			printf '  {"rule_id": "%s", "script": "%s", "line_range": "%s", "description": "%s"}' \
				"$rule_id" "$script" "$line_range" "$description"
			count=$((count + 1))
		done <<< "$inventory"
		printf '\n]\n'
	else
		printf '\nPulse Rule Inventory (%d rules)\n' "$(echo "$inventory" | grep -c '|' || echo 0)"
		printf '%-35s %-35s %-8s %s\n' "RULE_ID" "SCRIPT" "LINE" "DESCRIPTION"
		printf '%s\n' "$(printf '%.0s-' {1..120})"
		while IFS='|' read -r rule_id script line_range _regex description; do
			[[ -z "$rule_id" ]] && continue
			printf '%-35s %-35s %-8s %s\n' "$rule_id" "$script" "$line_range" "$description"
			count=$((count + 1))
		done <<< "$inventory"
		printf '\nTotal: %d rules\n\n' "$count"
	fi
	return 0
}

# Cycle-health parsing and aggregation are kept in a focused sub-library.
# shellcheck source=./pulse-diagnose-cycle-health.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-diagnose-cycle-health.sh"

# Render the human-readable cycle health report.
# Args: window_label cutoff_ts cycle_kv_str churn_kv_str stage_tsv stats_json_or_empty
_ch_render_text() {
	local window_label="$1"
	local cutoff_ts="$2"
	local cycle_kv="$3"
	local churn_kv="$4"
	local stage_tsv="$5"

	# Parse cycle key-value pairs
	local cycles_started=0 fill_floor_cycles=0 cycles_since_ff=0 last_ff_ts=""
	while IFS='=' read -r key val; do
		case "$key" in
			cycles_started)     cycles_started="$val" ;;
			fill_floor_cycles)  fill_floor_cycles="$val" ;;
			cycles_since_ff)    cycles_since_ff="$val" ;;
			last_ff_ts)         last_ff_ts="$val" ;;
		esac
	done <<< "$cycle_kv"

	# Parse churn key-value pairs
	local acquired=0 exited_early=0 churn_pct=0
	while IFS='=' read -r key val; do
		case "$key" in
			acquired)     acquired="$val" ;;
			exited_early) exited_early="$val" ;;
			churn_pct)    churn_pct="$val" ;;
		esac
	done <<< "$churn_kv"

	printf '\nPulse Cycle Health — last %s (cutoff: %s)\n\n' "$window_label" "$cutoff_ts"

	# Stage table
	if [[ -z "$stage_tsv" ]]; then
		printf '  No stage timing data in window (log missing or empty).\n'
	else
		printf '%-38s %5s %8s %5s %5s  %s\n' "Stage" "Runs" "Timeouts" "p50s" "p95s" "Last OK"
		printf '%s\n' "$(printf '%.0s-' {1..80})"
		while IFS=$'\t' read -r stage runs timeouts p50 p95 last_ok degraded; do
			[[ -z "$stage" ]] && continue
			[[ "$last_ok" == "-" ]] && last_ok=""
			local ago marker=""
			ago=$(_ch_ts_ago "$last_ok")
			[[ "$degraded" == "$_CH_DEGRADED" ]] && marker=" [DEGRADED]"
			printf '%-38s %5d %8d %5d %5d  %s%b%s%b\n' \
				"${stage}" "$runs" "$timeouts" "$p50" "$p95" \
				"$ago" "$YELLOW" "$marker" "$NC"
		done <<< "$stage_tsv"
		printf '\n'
	fi

	# Cycle summary
	printf 'Cycle summary (last %s):\n' "$window_label"
	printf '  Cycles started:              %d\n' "$cycles_started"
	printf '  Cycles reached dispatch:     %d\n' "$fill_floor_cycles"
	printf '  Cycles since last dispatch:  %d\n' "$cycles_since_ff"
	if [[ -n "$last_ff_ts" ]]; then
		local ff_ago
		ff_ago=$(_ch_ts_ago "$last_ff_ts")
		printf '  Last dispatch cycle:         %s (%s)\n' "$last_ff_ts" "$ff_ago"
	else
		printf '  Last dispatch cycle:         none in window\n'
	fi

	# Wrapper churn
	local total_wrappers=$(( acquired + exited_early ))
	printf '\nWrapper churn (all time):\n'
	printf '  Acquired lock: %d   Exited early: %d   Churn: %d%% (%d/%d)\n' \
		"$acquired" "$exited_early" "$churn_pct" "$exited_early" "$total_wrappers"
	printf '\n'
	return 0
}

# Render JSON cycle health output.
_ch_render_json() {
	local window_secs="$1"
	local cutoff_ts="$2"
	local cycle_kv="$3"
	local churn_kv="$4"
	local stage_tsv="$5"

	local cycles_started=0 fill_floor_cycles=0 cycles_since_ff=0 last_ff_ts=""
	while IFS='=' read -r key val; do
		case "$key" in
			cycles_started)     cycles_started="$val" ;;
			fill_floor_cycles)  fill_floor_cycles="$val" ;;
			cycles_since_ff)    cycles_since_ff="$val" ;;
			last_ff_ts)         last_ff_ts="$val" ;;
		esac
	done <<< "$cycle_kv"

	local acquired=0 exited_early=0 churn_pct=0
	while IFS='=' read -r key val; do
		case "$key" in
			acquired)     acquired="$val" ;;
			exited_early) exited_early="$val" ;;
			churn_pct)    churn_pct="$val" ;;
		esac
	done <<< "$churn_kv"

	printf '{\n'
	_json_num_field "window_secs"            "$window_secs"
	_json_str_field "cutoff_ts"              "$cutoff_ts"
	_json_num_field "cycles_started"         "$cycles_started"
	_json_num_field "fill_floor_cycles"      "$fill_floor_cycles"
	_json_num_field "cycles_since_fill_floor" "$cycles_since_ff"
	_json_str_field "last_fill_floor_ts"     "$last_ff_ts"
	_json_num_field "wrapper_acquired"       "$acquired"
	_json_num_field "wrapper_exited_early"   "$exited_early"
	_json_num_field "wrapper_churn_pct"      "$churn_pct"
	printf '  "stages": [\n'

	local first=1
	while IFS=$'\t' read -r stage runs timeouts p50 p95 last_ok degraded; do
		[[ -z "$stage" ]] && continue
		[[ "$last_ok" == "-" ]] && last_ok=""
		local deg_bool="$_BOOL_FALSE"
		[[ "$degraded" == "$_CH_DEGRADED" ]] && deg_bool="$_BOOL_TRUE"
		[[ "$first" -eq 0 ]] && printf ',\n'
		first=0
		printf '    {"stage": "%s", "runs": %s, "timeouts": %s, "p50_secs": %s, "p95_secs": %s, "last_ok_ts": "%s", "degraded": %s}' \
			"$stage" "$runs" "$timeouts" "$p50" "$p95" "$last_ok" "$deg_bool"
	done <<< "$stage_tsv"

	printf '\n  ]\n'
	printf '}\n'
	return 0
}

cmd_cycle_health() {
	_cmd_cycle_health_parse_args "$@" || return 1

	local cutoff_ts
	cutoff_ts=$(_ch_cutoff_ts "$_CMD_CH_WINDOW_SECS")

	local logdir
	logdir=$(_resolve_logdir)
	local timings_file="${logdir}/pulse-stage-timings.log"
	local wrapper_log="${logdir}/pulse-wrapper.log"

	# Allow env overrides for tests
	timings_file="${PULSE_DIAGNOSE_TIMINGS_FILE:-$timings_file}"
	wrapper_log="${PULSE_DIAGNOSE_WRAPPER_LOG:-$wrapper_log}"

	# Compute window label for display (convert secs back to human)
	local window_label
	if [[ "$_CMD_CH_WINDOW_SECS" -ge 86400 ]]; then
		window_label="$(( _CMD_CH_WINDOW_SECS / 86400 ))d"
	elif [[ "$_CMD_CH_WINDOW_SECS" -ge 3600 ]]; then
		window_label="$(( _CMD_CH_WINDOW_SECS / 3600 ))h"
	else
		window_label="$(( _CMD_CH_WINDOW_SECS / 60 ))m"
	fi

	local stage_tsv cycle_kv churn_kv
	stage_tsv=$(_ch_stage_stats "$timings_file" "$cutoff_ts")
	cycle_kv=$(_ch_cycle_stats "$timings_file" "$cutoff_ts")
	churn_kv=$(_ch_wrapper_churn "$wrapper_log")

	if [[ "$_CMD_CH_JSON_OUTPUT" -eq 1 ]]; then
		_ch_render_json "$_CMD_CH_WINDOW_SECS" "$cutoff_ts" \
			"$cycle_kv" "$churn_kv" "$stage_tsv"
		return 0
	fi

	_ch_render_text "$window_label" "$cutoff_ts" \
		"$cycle_kv" "$churn_kv" "$stage_tsv"
	return 0
}

# Issue-level report: cmd_issue and helpers (t3258).
# shellcheck source=./pulse-diagnose-issue.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-diagnose-issue.sh"

# API-budget checklist: cmd_api_budget and collectors.
# shellcheck source=./pulse-diagnose-api-budget.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-diagnose-api-budget.sh"

cmd_help() {
	cat <<'USAGE'
pulse-diagnose-helper.sh — correlate pulse.log events with PR merge decisions

COMMANDS:
  pr <N> [options]   Diagnose pulse behaviour for PR #N
    --repo <slug>    GitHub repo (default: from git remote)
    --verbose        Show raw log lines alongside classifications
    --json           Machine-readable JSON output
    --logfile <path> Override pulse.log path

  issue <N> [options]  Diagnose issue-level dispatch and PR lifecycle
    --repo <slug>    GitHub repo (default: from git remote)
    --verbose        Show raw pulse log lines alongside PR events
    --json           Machine-readable JSON output

  rules [--json]     List the full rule inventory

  cycle-health [options]   Summarise pulse-cycle stability
    --window <W>     Time window: 30m, 1h, 6h, 24h, 7d (default: 1h)
    --json           Machine-readable JSON output
    --verbose        (reserved for future use)

  api-budget [options]     Compact GitHub API-budget/cache diagnostic checklist
    --json           Machine-readable sanitized local counters

  help               Show this message

ENVIRONMENT:
  PULSE_DIAGNOSE_LOGFILE        Override pulse.log path
  PULSE_DIAGNOSE_GH_OFFLINE     Set to 1 to skip gh API calls (test mode)
  PULSE_DIAGNOSE_LOGDIR         Override log directory for rotated logs
  PULSE_DIAGNOSE_METRICS_FILE   Override headless-runtime-metrics.jsonl path
  PULSE_DIAGNOSE_TIMINGS_FILE   Override pulse-stage-timings.log path
  PULSE_DIAGNOSE_WRAPPER_LOG    Override pulse-wrapper.log path
  PULSE_DIAGNOSE_STATS_FILE     Override pulse-stats.json path
  PULSE_DIAGNOSE_GH_API_LOG     Override gh-api-calls.log path
  PULSE_DIAGNOSE_BLOCKER_LOG    Override worker-progress-blockers.jsonl path
  PULSE_DIAGNOSE_SYSTEMD_TIMER_FILE Override systemd timer unit path

EXAMPLES:
  pulse-diagnose-helper.sh pr 20329 --repo marcusquinn/aidevops
  pulse-diagnose-helper.sh pr 20336 --verbose
  pulse-diagnose-helper.sh issue 21860 --repo marcusquinn/aidevops
  pulse-diagnose-helper.sh issue 21860 --json
  pulse-diagnose-helper.sh rules --json
  pulse-diagnose-helper.sh cycle-health
  pulse-diagnose-helper.sh cycle-health --window 24h --json
  pulse-diagnose-helper.sh api-budget
USAGE
	return 0
}

# =============================================================================
# Main router
# =============================================================================

main() {
	local cmd="${1:-help}"
	shift 2>/dev/null || true

	case "$cmd" in
		pr)            cmd_pr "$@" ;;
		issue)         cmd_issue "$@" ;;
		rules)         cmd_rules "$@" ;;
		cycle-health)  cmd_cycle_health "$@" ;;
		api-budget)    cmd_api_budget "$@" ;;
		help|-h|--help) cmd_help ;;
		*)
			print_error "unknown command: $cmd"
			cmd_help
			return 1
			;;
	esac
}

main "$@"
