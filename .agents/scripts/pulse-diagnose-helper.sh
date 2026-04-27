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
#   help                 — usage
#
# Environment overrides (for tests / custom deployments):
#   PULSE_DIAGNOSE_LOGFILE      — override pulse.log path
#   PULSE_DIAGNOSE_GH_OFFLINE   — set to 1 to skip gh API calls (test mode)
#   PULSE_DIAGNOSE_LOGDIR       — override log directory for rotated logs

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

# =============================================================================
# Constants
# =============================================================================

readonly DEFAULT_LOGFILE="${HOME}/.aidevops/logs/pulse.log"
readonly DEFAULT_LOGDIR="${HOME}/.aidevops/logs"
readonly _UNKNOWN="unknown"

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
pmc-handover|pulse-merge-conflict.sh|308|handover: PR #.*handed over to worker pipeline|Interactive PR handed over to worker pipeline (idle >IDLE_INTERACTIVE_HANDOVER_SECONDS, default 4h)
pmc-would-handover|pulse-merge-conflict.sh|212|would-handover: PR #|Would-handover detected (detect mode — not acting)
pmc-handover-no-takeover|pulse-merge-conflict.sh|166|_interactive_pr_is_stale: PR #.*has no-takeover label|Handover skipped — PR has no-takeover label
pmc-skip-interactive-close|pulse-merge-conflict.sh|583|Deterministic merge: skipping auto-close of origin:interactive PR|Skipped auto-close of origin:interactive PR — maintainer work never auto-closed
pmc-close-conflicting-redispatch|pulse-merge-conflict.sh|697|Deterministic merge: conflicting PR #.*closed, linked issue left open|Closed conflicting PR, linked issue left open for re-dispatch
pmc-close-conflicting|pulse-merge-conflict.sh|699|Deterministic merge: closed conflicting PR #|Closed conflicting PR (work already on main)
pmc-close-conflicting-generic|pulse-merge-conflict.sh|734|Deterministic merge: closed conflicting PR #|Closed conflicting PR (generic close)
pmc-false-positive-heuristic|pulse-merge-conflict.sh|656|Deterministic merge: task ID match.*no implementation file overlap.*false-positive|Task ID match with no file overlap — false-positive heuristic, PR left open for rebase
pmc-carry-diff|pulse-merge-conflict.sh|904|_carry_forward_pr_diff: appended diff from PR #|Carried forward PR diff to linked issue before close
pmc-carry-diff-skip|pulse-merge-conflict.sh|859|_carry_forward_pr_diff: issue.*already has diff marker|Diff carry-forward skipped — already has diff marker for this PR
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
}

# =============================================================================
# Helpers
# =============================================================================

_resolve_logfile() {
	local override="${1:-}"
	if [[ -n "${PULSE_DIAGNOSE_LOGFILE:-}" ]]; then
		echo "${PULSE_DIAGNOSE_LOGFILE}"
		return 0
	fi
	if [[ -n "$override" ]]; then
		echo "$override"
		return 0
	fi
	echo "$DEFAULT_LOGFILE"
	return 0
}

_resolve_logdir() {
	if [[ -n "${PULSE_DIAGNOSE_LOGDIR:-}" ]]; then
		echo "${PULSE_DIAGNOSE_LOGDIR}"
		return 0
	fi
	echo "$DEFAULT_LOGDIR"
	return 0
}

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

# Extract timestamp from a log line. Handles common formats:
#   2026-04-21T17:45:03Z  ... or [2026-04-21T17:45:03Z] ...
_extract_timestamp() {
	local line="$1"
	local ts
	# ISO timestamp at start of line or after [
	ts=$(printf '%s' "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z?' | head -1)
	if [[ -n "$ts" ]]; then
		echo "$ts"
		return 0
	fi
	echo "$_UNKNOWN"
	return 0
}

# Classify a single log line against the rule inventory.
# Args: $1 = log line
# Outputs: rule_id|script|line_range|description  (or "unclassified" if no match)
_classify_log_line() {
	local line="$1"
	local inventory
	inventory=$(_build_rule_inventory)

	while IFS='|' read -r rule_id script line_range regex description; do
		[[ -z "$rule_id" ]] && continue
		if printf '%s' "$line" | grep -qE "$regex" 2>/dev/null; then
			printf '%s|%s|%s|%s' "$rule_id" "$script" "$line_range" "$description"
			return 0
		fi
	done <<< "$inventory"

	echo "unclassified|||Unclassified pulse log entry"
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

	local pr_json
	pr_json=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json number,title,state,author,mergedAt,closedAt,createdAt,labels,reviewDecision,mergeStateStatus,headRefName,baseRefName,isDraft 2>/dev/null) || {
		print_warning "gh pr view failed for PR #${pr_number} in ${repo_slug}"
		echo "{}"
		return 0
	}
	echo "$pr_json"
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

# Parse cmd_pr CLI arguments into _CMD_PR_* module globals.
# Returns 1 on validation error.
_cmd_pr_parse_args() {
	_CMD_PR_NUMBER=""
	_CMD_PR_REPO_SLUG=""
	_CMD_PR_VERBOSE=0
	_CMD_PR_JSON_OUTPUT=0
	_CMD_PR_LOGFILE_OVERRIDE=""

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
		ts=$(_extract_timestamp "$line")
		classification=$(_classify_log_line "$line")

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

	local last_rule_id=""
	local entry
	for entry in "$@"; do
		if [[ "$entry" == "  RAW: "* ]]; then
			printf '%b%s%b\n' "$CYAN" "$entry" "$NC"
			continue
		fi

		local ts rule_id script line_range description
		IFS='|' read -r ts rule_id script line_range description <<< "$entry"

		printf '  %s  %b%-30s%b  %s\n' \
			"$ts" "$YELLOW" "${script:-unknown}" "$NC" "${rule_id:-unclassified}"
		printf '              %s\n' "$description"
		if [[ -n "$line_range" ]]; then
			printf '              source: %s:%s\n' "${script}" "${line_range}"
		fi
		printf '\n'
		last_rule_id="$rule_id"
	done

	printf 'Summary:\n'
	printf '  Total pulse events: %d\n' "$event_count"

	if [[ -n "$last_rule_id" && "$last_rule_id" != "unclassified" ]]; then
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

	local pr_author pr_state pr_merged_at pr_closed_at pr_created_at pr_title pr_review_decision pr_mss
	pr_author=$(_jq_field "$pr_json" ".author.login" "$_UNKNOWN")
	pr_state=$(_jq_field "$pr_json" ".state" "$_UNKNOWN")
	pr_merged_at=$(_jq_field "$pr_json" ".mergedAt" "")
	pr_closed_at=$(_jq_field "$pr_json" ".closedAt" "")
	pr_created_at=$(_jq_field "$pr_json" ".createdAt" "")
	pr_title=$(_jq_field "$pr_json" ".title" "")
	pr_review_decision=$(_jq_field "$pr_json" ".reviewDecision" "")
	pr_mss=$(_jq_field "$pr_json" ".mergeStateStatus" "")

	local merged_flag="no"
	[[ -n "$pr_merged_at" ]] && merged_flag="yes"

	_cmd_pr_build_events "$log_lines" "$_CMD_PR_VERBOSE"

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

	local merged_bool="false"
	[[ "$merged" == "yes" ]] && merged_bool="true"

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

	printf '\n  ]\n'
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

	local inventory
	inventory=$(_build_rule_inventory)
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

# =============================================================================
# Subcommands — cycle_health (t2752)
#
# Provides a concise summary of pulse-cycle stability by parsing
# pulse-stage-timings.log and pulse-wrapper.log.
#
# Log format (pulse-stage-timings.log):
#   timestamp \t stage_name \t duration_secs \t exit_code \t pid
#
# "Fill-floor" proxy: the stage preflight_early_dispatch with exit_code=0
# corresponds to a cycle that successfully reached worker dispatch.
# =============================================================================

_CMD_CH_WINDOW_SECS=3600
_CMD_CH_JSON_OUTPUT=0
_CMD_CH_VERBOSE=0
_CH_DEGRADED="DEGRADED"

# Convert a window string (1h, 24h, 7d, 30m, or raw integer) to seconds.
_ch_parse_window_secs() {
	local raw="$1"
	case "$raw" in
		*m) printf '%d' "$(( ${raw%m} * 60 ))" ;;
		*h) printf '%d' "$(( ${raw%h} * 3600 ))" ;;
		*d) printf '%d' "$(( ${raw%d} * 86400 ))" ;;
		'') printf '%d' 3600 ;;
		*)  printf '%d' "$raw" ;;
	esac
	return 0
}

# Compute ISO 8601 UTC cutoff timestamp (window_secs ago from now).
# Tries macOS date -v syntax first; falls back to GNU date -d.
_ch_cutoff_ts() {
	local window_secs="$1"
	local ts
	if ts=$(date -u -v"-${window_secs}S" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
		printf '%s' "$ts"
		return 0
	fi
	local now_epoch
	now_epoch=$(date '+%s' 2>/dev/null) || now_epoch=0
	if ts=$(date -u -d "@$(( now_epoch - window_secs ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
		printf '%s' "$ts"
		return 0
	fi
	printf '1970-01-01T00:00:00Z'
	return 0
}

# Convert an ISO 8601 UTC timestamp to a human "Xm ago" string.
_ch_ts_ago() {
	local ts="$1"
	[[ -z "$ts" ]] && { printf 'never'; return 0; }
	local ts_epoch now_epoch diff
	ts_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null) ||
		ts_epoch=$(date -u -d "$ts" '+%s' 2>/dev/null) || { printf '%s' "$ts"; return 0; }
	now_epoch=$(date '+%s' 2>/dev/null) || { printf '%s' "$ts"; return 0; }
	diff=$(( now_epoch - ts_epoch ))
	if [[ "$diff" -lt 60 ]]; then
		printf '%ds ago' "$diff"
	elif [[ "$diff" -lt 3600 ]]; then
		printf '%dm ago' "$(( diff / 60 ))"
	elif [[ "$diff" -lt 86400 ]]; then
		printf '%dh ago' "$(( diff / 3600 ))"
	else
		printf '%dd ago' "$(( diff / 86400 ))"
	fi
	return 0
}

_cmd_cycle_health_parse_args() {
	_CMD_CH_WINDOW_SECS=3600
	_CMD_CH_JSON_OUTPUT=0
	_CMD_CH_VERBOSE=0

	while [[ $# -gt 0 ]]; do
		case "${1}" in
			--window)
				local raw="${2:-1h}"
				shift 2
				_CMD_CH_WINDOW_SECS=$(_ch_parse_window_secs "$raw")
				;;
			--json)
				_CMD_CH_JSON_OUTPUT=1
				shift
				;;
			--verbose)
				_CMD_CH_VERBOSE=1
				shift
				;;
			-*)
				print_error "unknown option: ${1}"
				return 1
				;;
			*)
				shift
				;;
		esac
	done
	return 0
}

# Parse pulse-stage-timings.log within the window and emit per-stage stats.
# Output TSV: stage runs timeouts p50_secs p95_secs last_ok_ts degraded
_ch_stage_stats() {
	local timings_file="$1"
	local cutoff_ts="$2"

	[[ -f "$timings_file" ]] || return 0

	awk -v cutoff="$cutoff_ts" '
	{
		nf=split($0, f, "\t")
		if (nf < 5 || f[1] < cutoff) next
		ts=f[1]; stage=f[2]; dur=f[3]+0; rc=f[4]+0
		cnt[stage]++
		if (rc==124) to[stage]++
		if (rc==0 && ts > last_ok[stage]) last_ok[stage]=ts
		n=cnt[stage]; d[stage,n]=dur
	}
	END {
		for (stage in cnt) {
			n=cnt[stage]
			for (i=2;i<=n;i++) {
				key=d[stage,i]; j=i-1
				while (j>=1 && d[stage,j]>key) {
					d[stage,j+1]=d[stage,j]; j--
				}
				d[stage,j+1]=key
			}
			p50_i=int(n*0.50)+1; if(p50_i>n)p50_i=n
			p95_i=int(n*0.95)+1; if(p95_i>n)p95_i=n
			t=(to[stage]+0)
			deg=(n>0 && (t/n)>0.50) ? "DEGRADED" : "ok"
			printf "%s\t%d\t%d\t%d\t%d\t%s\t%s\n", \
				stage, n, t, d[stage,p50_i], d[stage,p95_i], \
				(last_ok[stage]?last_ok[stage]:""), deg
		}
	}' "$timings_file" 2>/dev/null | sort -t"	" -k1,1
	return 0
}

# Compute cycle-level summary stats from pulse-stage-timings.log.
# Output: key=value lines (cycles_started, fill_floor_cycles, cycles_since_ff, last_ff_ts)
_ch_cycle_stats() {
	local timings_file="$1"
	local cutoff_ts="$2"

	if [[ ! -f "$timings_file" ]]; then
		printf 'cycles_started=0\nfill_floor_cycles=0\ncycles_since_ff=0\nlast_ff_ts=\n'
		return 0
	fi

	awk -v cutoff="$cutoff_ts" '
	{
		nf=split($0, f, "\t")
		if (nf < 5 || f[1] < cutoff) next
		ts=f[1]; stage=f[2]; rc=f[4]+0; pid=f[5]
		pids[pid]=1
		if (!pid_first[pid] || ts < pid_first[pid]) pid_first[pid]=ts
		if (stage=="preflight_early_dispatch" && rc==0) {
			ff[pid]=1
			if (ts > last_ff_ts) { last_ff_ts=ts; last_ff_pid=pid }
		}
	}
	END {
		total=0; ff_count=0; since_ff=0
		for (pid in pids) total++
		for (pid in ff) ff_count++
		if (last_ff_ts) {
			for (pid in pids) {
				if (!(pid in ff) && pid_first[pid]>last_ff_ts) since_ff++
			}
		} else {
			since_ff=total
		}
		printf "cycles_started=%d\nfill_floor_cycles=%d\ncycles_since_ff=%d\nlast_ff_ts=%s\n", \
			total, ff_count, since_ff, last_ff_ts
	}' "$timings_file" 2>/dev/null
	return 0
}

# Parse pulse-wrapper.log for instance-lock churn (all-time).
# Output: key=value lines (acquired, exited_early, churn_pct)
_ch_wrapper_churn() {
	local wrapper_log="$1"

	if [[ ! -f "$wrapper_log" ]]; then
		printf 'acquired=0\nexited_early=0\nchurn_pct=0\n'
		return 0
	fi

	local acquired exited_early total churn_pct
	acquired=$(grep -c 'Instance lock acquired via mkdir' "$wrapper_log" 2>/dev/null) || acquired=0
	exited_early=$(grep -c 'Another pulse instance holds the mkdir lock' "$wrapper_log" 2>/dev/null) || exited_early=0
	total=$(( acquired + exited_early ))
	if [[ "$total" -gt 0 ]]; then
		churn_pct=$(( exited_early * 100 / total ))
	else
		churn_pct=0
	fi
	printf 'acquired=%d\nexited_early=%d\nchurn_pct=%d\n' "$acquired" "$exited_early" "$churn_pct"
	return 0
}

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
		local deg_bool="false"
		[[ "$degraded" == "$_CH_DEGRADED" ]] && deg_bool="true"
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

cmd_help() {
	cat <<'USAGE'
pulse-diagnose-helper.sh — correlate pulse.log events with PR merge decisions

COMMANDS:
  pr <N> [options]   Diagnose pulse behaviour for PR #N
    --repo <slug>    GitHub repo (default: from git remote)
    --verbose        Show raw log lines alongside classifications
    --json           Machine-readable JSON output
    --logfile <path> Override pulse.log path

  rules [--json]     List the full rule inventory

  cycle-health [options]   Summarise pulse-cycle stability
    --window <W>     Time window: 30m, 1h, 6h, 24h, 7d (default: 1h)
    --json           Machine-readable JSON output
    --verbose        (reserved for future use)

  help               Show this message

ENVIRONMENT:
  PULSE_DIAGNOSE_LOGFILE        Override pulse.log path
  PULSE_DIAGNOSE_GH_OFFLINE     Set to 1 to skip gh API calls (test mode)
  PULSE_DIAGNOSE_LOGDIR         Override log directory for rotated logs
  PULSE_DIAGNOSE_TIMINGS_FILE   Override pulse-stage-timings.log path
  PULSE_DIAGNOSE_WRAPPER_LOG    Override pulse-wrapper.log path

EXAMPLES:
  pulse-diagnose-helper.sh pr 20329 --repo marcusquinn/aidevops
  pulse-diagnose-helper.sh pr 20336 --verbose
  pulse-diagnose-helper.sh rules --json
  pulse-diagnose-helper.sh cycle-health
  pulse-diagnose-helper.sh cycle-health --window 24h --json
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
		rules)         cmd_rules "$@" ;;
		cycle-health)  cmd_cycle_health "$@" ;;
		help|-h|--help) cmd_help ;;
		*)
			print_error "unknown command: $cmd"
			cmd_help
			return 1
			;;
	esac
}

main "$@"
