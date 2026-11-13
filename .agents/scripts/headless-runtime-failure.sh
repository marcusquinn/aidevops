#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Headless Runtime Failure — Dispatch Claim & Fast-Fail (GH#19699)
# =============================================================================
# Failure reporting functions extracted from headless-runtime-lib.sh to reduce
# file size. Handles dispatch claim release and fast-fail counter management.
#
# Covers:
#   1. Dispatch claim release — post CLAIM_RELEASED comments to unblock re-dispatch
#   2. Fast-fail state      — acquire locks, read/write counter state, report
#                              failures with exponential backoff and tier escalation
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-failure.sh"
#
# Dependencies:
#   - shared-constants.sh (print_warning, print_info)
#   - worker-lifecycle-common.sh (escalate_issue_tier)
#   - gh CLI, jq
#   - bash 3.2+
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_FAILURE_LOADED:-}" ]] && return 0
readonly _HEADLESS_RUNTIME_FAILURE_LOADED=1

_HRFF_SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_HRFF_SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && _HRFF_SCRIPT_DIR="."
if [[ -r "${_HRFF_SCRIPT_DIR}/lib/version.sh" ]]; then
	# shellcheck source=lib/version.sh
	source "${_HRFF_SCRIPT_DIR}/lib/version.sh"
fi
if [[ -r "${_HRFF_SCRIPT_DIR}/gh-signature-helper-detect.sh" ]]; then
	# shellcheck source=gh-signature-helper-detect.sh
	source "${_HRFF_SCRIPT_DIR}/gh-signature-helper-detect.sh"
fi
if [[ -r "${_HRFF_SCRIPT_DIR}/shared-repo-state-guard.sh" ]]; then
	# shellcheck source=shared-repo-state-guard.sh
	source "${_HRFF_SCRIPT_DIR}/shared-repo-state-guard.sh"
fi
# shellcheck source=terminal-blocker-circuit.sh
source "${_HRFF_SCRIPT_DIR}/terminal-blocker-circuit.sh"
# shellcheck source=fast-fail-release-policy.sh
source "${_HRFF_SCRIPT_DIR}/fast-fail-release-policy.sh"
# shellcheck source=headless-runtime-release-claim.sh
source "${_HRFF_SCRIPT_DIR}/headless-runtime-release-claim.sh"
# shellcheck source=headless-runtime-release-retry.sh
source "${_HRFF_SCRIPT_DIR}/headless-runtime-release-retry.sh"
# shellcheck source=aidevops-cli/aidevops-project-config-lib.sh
source "${_HRFF_SCRIPT_DIR}/aidevops-cli/aidevops-project-config-lib.sh"
unset _HRFF_SCRIPT_DIR
: "${AIDEVOPS_UNKNOWN_VERSION:=unknown}"

# Fallback exit reason — backward-compatible value used when classify_worker_exit
# cannot determine the actual cause (missing sqlite3, corrupt DB, unexpected format).
# Recognised by dispatch-dedup-helper.sh: any CLAIM_RELEASED is treated as
# authoritative regardless of reason value.
readonly _HRFF_FALLBACK_EXIT="process_exit"
readonly _HRFF_PRELAUNCH_NOT_INVOKED="worker_runtime_not_invoked"
readonly _HRFF_DEFERRED_CLEANUP_MARKER=".agents/.full-loop-cleanup-deferred"
readonly _HRFF_DEFERRED_CLEANUP_EXCLUDE_PATHSPEC=":(exclude)${_HRFF_DEFERRED_CLEANUP_MARKER}"
readonly _HRFF_RETRY_CLASS_INFRASTRUCTURE="retryable_infrastructure"
readonly _HRFF_RETRY_CLASS_MAINTAINER_GATE="maintainer_gate"
readonly _HRFF_RETRY_CLASS_REMEDIATION="meaningful_remediation"
readonly _HRFF_RETRY_CLASS_UNKNOWN="unknown"
readonly _HRFF_OPEN_ISSUE_STATE="open"
readonly _HRFF_SESSION_COUNT_QUERY_PREFIX="SELECT count(*) FROM session WHERE time_created >= "
# Projection-only reason for a blocked exit that recorded no hold evidence.
readonly _HRFF_REASON_BLOCKED_UNRECORDED="blocked_unrecorded"

#######################################
# Count attempt-local OpenCode model activity. Fresh runs are scoped to sessions
# created during the attempt, while continuations use the exact persisted
# session whose session.time_created remains old. A boot-only session row is not
# activity; require a completed assistant message or assistant-owned part.
# Args: $1 = DB path, $2 = attempt start epoch ms, $3 = persisted session ID.
# Outputs a non-negative integer, or returns 1 when evidence is unavailable.
#######################################
_hrff_attempt_activity_count() {
	local db_path="$1"
	local start_epoch_ms="$2"
	local persisted_session_id="${3:-}"
	local persisted_session_sql=""
	local session_scope=""
	local query=""
	local count=""

	command -v sqlite3 >/dev/null 2>&1 || return 1
	[[ -f "$db_path" && "$start_epoch_ms" =~ ^[0-9]+$ && "$start_epoch_ms" -gt 0 ]] || return 1
	if [[ -n "$persisted_session_id" ]]; then
		persisted_session_sql="${persisted_session_id//\'/\'\'}"
		session_scope="= '${persisted_session_sql}'"
	else
		session_scope="IN (SELECT id FROM session WHERE time_created >= ${start_epoch_ms})"
	fi
	query="SELECT (SELECT count(*) FROM message m WHERE m.session_id ${session_scope} AND m.time_created >= ${start_epoch_ms} AND json_valid(m.data) AND json_extract(m.data, '$.role') = 'assistant' AND json_extract(m.data, '$.time.completed') IS NOT NULL) + (SELECT count(*) FROM part p JOIN message m ON m.id = p.message_id WHERE m.session_id ${session_scope} AND p.time_created >= ${start_epoch_ms} AND json_valid(m.data) AND json_extract(m.data, '$.role') = 'assistant')"
	count=$(sqlite3 "$db_path" "$query" 2>/dev/null) || return 1
	[[ "$count" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$count"
	return 0
}

#######################################
# GH#37527: snapshot attempt activity from an isolated DB before finalization
# merges or discards it. Ephemeral roles discard the DB and a failed merge keeps
# the rows out of the shared DB, so a later shared-DB read would report a false
# zero. Snapshots accumulate across invocations bound to one attempt start.
# Args: $1 = isolated DB path. Unreadable evidence records no snapshot.
#######################################
_hrff_snapshot_attempt_activity() {
	local db_path="$1"
	local start_epoch_ms="${_WORKER_START_EPOCH_MS:-0}"
	local count=""
	[[ "$start_epoch_ms" =~ ^[0-9]+$ && "$start_epoch_ms" -gt 0 ]] || return 0
	count=$(_hrff_attempt_activity_count "$db_path" "$start_epoch_ms" "${_WORKER_PERSISTED_SESSION_ID:-}") || return 0
	if [[ "${_WORKER_ATTEMPT_ACTIVITY_START_MS:-}" != "$start_epoch_ms" ||
		! "${_WORKER_ATTEMPT_ACTIVITY_COUNT:-}" =~ ^[0-9]+$ ]]; then
		_WORKER_ATTEMPT_ACTIVITY_COUNT=0
	fi
	_WORKER_ATTEMPT_ACTIVITY_COUNT=$((_WORKER_ATTEMPT_ACTIVITY_COUNT + count))
	_WORKER_ATTEMPT_ACTIVITY_START_MS="$start_epoch_ms"
	return 0
}

#######################################
# Resolve attempt activity: the live isolated DB plus finalized snapshots. The
# shared DB is read only when no isolated DB or snapshot exists for this start.
# Args: $1 = attempt start epoch ms, $2 = persisted session ID.
# Outputs a non-negative integer, or returns 1 when evidence is unavailable.
#######################################
_hrff_resolved_attempt_activity_count() {
	local start_epoch_ms="$1"
	local persisted_session_id="${2:-}"
	local isolated_db="${_WORKER_ISOLATED_DB_PATH:-}"
	local shared_db="${HOME}/.local/share/opencode/opencode.db"
	local snapshot=0
	local has_snapshot=0
	local count=""
	[[ "$start_epoch_ms" =~ ^[0-9]+$ && "$start_epoch_ms" -gt 0 ]] || return 1
	if [[ "${_WORKER_ATTEMPT_ACTIVITY_START_MS:-}" == "$start_epoch_ms" &&
		"${_WORKER_ATTEMPT_ACTIVITY_COUNT:-}" =~ ^[0-9]+$ ]]; then
		snapshot="$_WORKER_ATTEMPT_ACTIVITY_COUNT"
		has_snapshot=1
	fi
	if [[ -n "$isolated_db" && -f "$isolated_db" ]]; then
		count=$(_hrff_attempt_activity_count "$isolated_db" "$start_epoch_ms" "$persisted_session_id") || count=""
	elif [[ "$has_snapshot" -eq 0 ]]; then
		count=$(_hrff_attempt_activity_count "$shared_db" "$start_epoch_ms" "$persisted_session_id") || count=""
	else
		count=0
	fi
	if [[ ! "$count" =~ ^[0-9]+$ ]]; then
		[[ "$has_snapshot" -eq 1 ]] || return 1
		count=0
	fi
	printf '%s\n' "$((count + snapshot))"
	return 0
}

_HRFF_RATELIMIT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_HRFF_RATELIMIT_DIR" == "${BASH_SOURCE[0]}" ]] && _HRFF_RATELIMIT_DIR="."
# shellcheck source=headless-runtime-failure-ratelimit.sh
if ! source "${_HRFF_RATELIMIT_DIR}/headless-runtime-failure-ratelimit.sh"; then
	printf 'ERROR: failed to load %s/headless-runtime-failure-ratelimit.sh\n' "$_HRFF_RATELIMIT_DIR" >&2
	unset _HRFF_RATELIMIT_DIR
	return 1 2>/dev/null || exit 1
fi
unset _HRFF_RATELIMIT_DIR

#######################################
# Return success when a GitHub issue unlock failure is benign.
#
# GitHub treats unlocking an already-unlocked issue as a failed mutation in some
# gh/API paths. Release cleanup calls unlock defensively after active-state
# cleanup, so that already-clean state should not produce pulse warnings.
#
# Args:
#   $1 = gh failure output
#######################################
_hrff_unlock_failure_is_benign() {
	local unlock_output="$1"

	if [[ "$unlock_output" =~ [Aa]lready[[:space:]-]+unlocked ]] || \
		[[ "$unlock_output" =~ [Nn]ot[[:space:]-]+locked ]] || \
		[[ "$unlock_output" =~ [Cc]onversation[[:space:]]+is[[:space:]]+not[[:space:]]+locked ]] || \
		[[ "$unlock_output" =~ [Ii]ssue[[:space:]]+is[[:space:]]+not[[:space:]]+locked ]]; then
		return 0
	fi
	return 1
}

#######################################
# Unlock the issue once a worker releases its dispatch claim.
#
# Worker dispatch locks the issue before launch. Release paths already clear
# active labels/assignees; they must also clear the conversation lock so the
# public issue state matches the released claim and future workers/maintainers
# do not see `status:available` on a locked issue.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#######################################
_unlock_issue_after_dispatch_release() {
	local issue_number="$1"
	local repo_slug="$2"
	local unlock_output=""

	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 0
	if [[ "$issue_number" =~ ^0[0-9]+$ ]]; then
		print_info "Skipping release unlock for local task ID ${issue_number} in ${repo_slug}: not a GitHub issue number"
		return 0
	fi

	local labels=""
	if ! labels=$(gh api "repos/${repo_slug}/issues/${issue_number}" --jq '[.labels[]? | .name] | join(",")' 2>/dev/null); then
		print_warning "Failed to verify labels before release unlock for #${issue_number} in ${repo_slug}; retaining conversation lock"
		return 0
	fi
	# aidevops:trust-boundary — a retryable auto-dispatch issue remains frozen
	# between workers; release only the claim, not the public instruction surface.
	if [[ ",$labels," == *,auto-dispatch,* && ",$labels," != *,no-auto-dispatch,* ]]; then
		print_info "Retaining conversation lock for auto-dispatch issue #${issue_number} in ${repo_slug} after claim release"
		return 0
	fi

	unlock_output=$(gh issue unlock "$issue_number" --repo "$repo_slug" 2>&1) || {
		if _hrff_unlock_failure_is_benign "$unlock_output"; then
			print_info "Release unlock skipped for GitHub issue #${issue_number} in ${repo_slug}: already unlocked"
			return 0
		fi
		print_warning "Failed to unlock released GitHub issue #${issue_number} in ${repo_slug} (non-fatal): ${unlock_output:-unknown error}"
	}
	return 0
}

#######################################
# Check whether dispatch release may mutate issue state for a repo.
#
# A confirmed unmanaged repo is a benign no-op. An indeterminate verdict
# (GitHub could not answer, e.g. REST deferred under quota pressure) is
# retried after AIDEVOPS_RELEASE_AUTHORITY_RETRY_DELAYS seconds (default
# "15 45"); if still unanswered the release is reported unpersisted instead
# of silently skipped, which stranded claims on live issues (GH#36184).
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
# Globals written:
#   _HRFF_RELEASE_AUTHORITY_SKIP_RC — status the caller returns when this
#   returns non-zero: 0 = confirmed unmanaged, 1 = release unpersisted.
# Returns: 0 when the release may proceed, 1 otherwise.
#######################################
_hrff_release_repo_state_is_managed() {
	local issue_number="$1"
	local repo_slug="$2"
	local guard_rc=0 delay=""
	local -a retry_delays=()

	_HRFF_RELEASE_AUTHORITY_SKIP_RC=0
	declare -F aidevops_can_manage_repo_issue_state >/dev/null 2>&1 || return 0
	read -r -a retry_delays <<<"${AIDEVOPS_RELEASE_AUTHORITY_RETRY_DELAYS-15 45}" || true
	aidevops_can_manage_repo_issue_state "$repo_slug" || guard_rc=$?
	for delay in ${retry_delays[@]+"${retry_delays[@]}"}; do
		[[ "$guard_rc" -eq 2 ]] || break
		[[ "$delay" =~ ^[0-9]+$ ]] || continue
		print_info "Repo-state authority for #${issue_number} in ${repo_slug} is indeterminate; retrying claim release in ${delay}s"
		sleep "$delay"
		guard_rc=0
		aidevops_can_manage_repo_issue_state "$repo_slug" || guard_rc=$?
	done
	case "$guard_rc" in
	0) return 0 ;;
	2)
		_HRFF_RELEASE_AUTHORITY_SKIP_RC=1
		print_warning "Claim release for #${issue_number} in ${repo_slug} remains unpersisted: repo-state authority could not be determined (GitHub lookup unavailable); retaining issue lifecycle state"
		return 1
		;;
	esac
	# Replay keeps its retry row on denial so restored authority can still publish.
	[[ "${_HRRR_REPLAY:-0}" != 1 ]] || _HRFF_RELEASE_AUTHORITY_SKIP_RC=1
	print_info "Skipping CLAIM_RELEASED for #${issue_number} in ${repo_slug}: repo state is not managed by this account"
	return 1
}

#######################################
# Resolve the issue number for a dispatch claim release.
#
# Args:
#   $1 = session_key
# Outputs:
#   Issue number when available.
#######################################
_hrff_release_issue_number() {
	local session_key="$1"

	# Extract issue number from the explicit worker contract first, then fall back
	# only to canonical issue-scoped session keys. Non-task sessions can
	# legitimately end in digits (for example validation timestamps); treating
	# arbitrary trailing digits as issue numbers causes fake GitHub cleanup writes.
	if [[ "${WORKER_ISSUE_NUMBER:-}" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$WORKER_ISSUE_NUMBER"
		return 0
	fi
	if [[ "$session_key" =~ ^issue-([0-9]+)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi

	return 0
}

#######################################
# Validate whether claim release has enough context to proceed.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#######################################
_hrff_release_context_is_valid() {
	local issue_number="$1"
	local repo_slug="$2"

	if [[ -z "$issue_number" && -z "$repo_slug" ]]; then
		return 1
	fi
	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		print_warning "Cannot release claim: missing issue=$issue_number repo=$repo_slug"
		return 1
	fi

	return 0
}

#######################################
# Clear active state without posting a duplicate rate-limit release comment.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#######################################
_hrff_release_rate_limit_circuit_cleanup() {
	local issue_number="$1"
	local repo_slug="$2"
	local runner_name=""

	runner_name=$(_hrff_resolve_release_runner_login)
	if declare -F clear_active_status_on_release >/dev/null 2>&1; then
		clear_active_status_on_release "$issue_number" "$repo_slug" "$runner_name" \
			|| print_warning "Failed to clear active status on #${issue_number} (non-fatal)"
	fi
	_unlock_issue_after_dispatch_release "$issue_number" "$repo_slug"
	return 0
}

#######################################
# Build the machine-readable claim release audit line.
#
# Args:
#   $1 = reason
#   $2 = runner_name
#   $3 = exit_code
#   $4 = session_count
# Outputs:
#   CLAIM_RELEASED line.
#######################################
_hrff_build_claim_released_line() {
	local reason="$1"
	local runner_name="$2"
	local exit_code_arg="$3"
	local session_count_arg="$4"
	local aidevops_version="${AIDEVOPS_UNKNOWN_VERSION:-}"
	local opencode_version="${AIDEVOPS_UNKNOWN_VERSION:-}"
	local release_ts=""
	local machine_readable_part=""

	if declare -F aidevops_find_version >/dev/null 2>&1; then
		aidevops_version=$(aidevops_find_version 2>/dev/null || printf '%s' "$AIDEVOPS_UNKNOWN_VERSION")
	fi
	if declare -F _detect_opencode_version >/dev/null 2>&1; then
		opencode_version=$(_detect_opencode_version 2>/dev/null || printf '%s' "")
		opencode_version="${opencode_version:-$AIDEVOPS_UNKNOWN_VERSION}"
	fi

	release_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	machine_readable_part="CLAIM_RELEASED reason=${reason} runner=${runner_name} ts=${release_ts} aidevops_version=${aidevops_version} opencode_version=${opencode_version}"
	if [[ -n "$exit_code_arg" ]]; then
		machine_readable_part+=" exit=${exit_code_arg}"
	fi
	if [[ -n "$session_count_arg" ]]; then
		machine_readable_part+=" session_count=${session_count_arg}"
	fi
	if [[ "$reason" == "push_policy_timeout" ]]; then
		local repo_path="${AIDEVOPS_TERMINAL_BLOCKER_REPO_PATH:-}"
		local branch="" head=""
		if [[ -n "$repo_path" && -d "$repo_path" ]]; then
			branch=$(git -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=""
			head=$(git -C "$repo_path" rev-parse --verify HEAD 2>/dev/null) || head=""
			# Release markers are public: omit private paths, arbitrary text and
			# unsafe ref characters. Recovery must revalidate this exact checkpoint.
			if [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ && "$head" =~ ^[a-f0-9]{40,64}$ ]]; then
				machine_readable_part+=" branch=${branch} head=${head}"
			fi
		fi
	fi

	printf '%s\n' "$machine_readable_part"
	return 0
}

#######################################
# Post the CLAIM_RELEASED audit comment.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#   $3 = comment_body
#   $4-$6 = optional session, runner and original claim ID (inherit release context)
#######################################
_hrff_post_claim_released_comment() {
	local issue_number="$1"
	local repo_slug="$2"
	local comment_body="$3"
	local post_session="${4:-${AIDEVOPS_DISPATCH_LEASE_SESSION:-${session_key:-}}}"
	local post_runner="${5:-${runner_name:-}}" post_claim_id="${6:-${_HRFF_RELEASE_CLAIM_ID:-}}"
	local attempts="${AIDEVOPS_CLAIM_RELEASE_POST_ATTEMPTS:-3}"
	local retry_delay="${AIDEVOPS_CLAIM_RELEASE_POST_RETRY_DELAY:-1}"
	local attempt=1
	local post_error="" projection_line=""
	projection_line=$(jq -Rrs '[split("\n")[] | select(startswith("CLAIM_RELEASED "))] |
		if length == 1 then .[0] else error("ambiguous release line") end' <<<"$comment_body") || return 1

	[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=3
	[[ "$retry_delay" =~ ^[0-9]+$ ]] || retry_delay=1
	while [[ "$attempt" -le "$attempts" ]]; do
		# Refresh after backoff too. This is not an atomic GitHub transaction;
		# bound release fields and the post-write check limit stale projections.
		_hrff_check_release_claim "$issue_number" "$repo_slug" "$post_runner" "$post_session" || return 1
		[[ "$_HRFF_RELEASE_CLAIM_OWNED" -eq 1 && "${_HRFF_RELEASE_CLAIM_ID:-}" == "$post_claim_id" ]] || return 1
		if post_error=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
			--method POST \
			--field body="$comment_body" \
			2>&1 >/dev/null); then
			_hrff_check_release_claim "$issue_number" "$repo_slug" "$post_runner" "$post_session" "$projection_line" || return 1
			if [[ "$_HRFF_RELEASE_CLAIM_OWNED" -ne 1 || "${_HRFF_RELEASE_CLAIM_ID:-}" != "$post_claim_id" ]]; then
				print_warning "Release persisted for #${issue_number}, but projection is held: claim generation changed; do not replay"
				return 1
			fi
			return 0
		fi
		post_error="${post_error//$'\n'/ }"
		post_error="${post_error:0:240}"
		if [[ "$attempt" -lt "$attempts" ]]; then
			print_warning "CLAIM_RELEASED persistence failed on #${issue_number} (attempt ${attempt}/${attempts}): ${post_error:-unknown}; retrying"
			[[ "$retry_delay" -eq 0 ]] || sleep "$retry_delay"
		fi
		attempt=$((attempt + 1))
	done

	print_warning "Failed to post CLAIM_RELEASED on #${issue_number} after ${attempts} attempt(s): ${post_error:-unknown}"
	return 1
}

#######################################
# GH#34846: single decision for the post-release projection of a `blocked`
# exit, shared by the observation's "Projected state:" line and the label edit.
# The full runtime (named safe-edit path) holds verified blocked exits
# (GH#34775); a runner-local capability gap without missing secret names stays
# available for a capable runner (GH#34758). Legacy consumers clear to
# available. Returns 0 when the exit projects status:blocked.
#######################################
# Structured plugin refusals plus the runtime-owned session DB, never model prose.
# Unreadable evidence fails closed; completed tools in child sessions count too.
_hrff_lifecycle_refusal_only() {
	local session_id="$1"
	local db_path="${_WORKER_ISOLATED_DB_PATH:-${HOME}/.local/share/opencode/opencode.db}"
	local evidence_dir="${HOME}/.aidevops/logs/lifecycle-admission"
	[[ "$session_id" =~ ^[A-Za-z0-9_-]+$ && -f "$db_path" && -d "$evidence_dir" ]] || return 1
	python3 - "$session_id" "$db_path" "$evidence_dir" <<'PY'
import json
import re
import sqlite3
import sys
from pathlib import Path

session, database, directory = sys.argv[1:]
try:
    with sqlite3.connect(Path(database).resolve().as_uri() + "?mode=ro", uri=True) as db:
        # Require the session itself to exist; an empty/wrong DB is not evidence.
        owned = {row[0] for row in db.execute("""WITH RECURSIVE owned(id) AS (
            SELECT id FROM session WHERE id = ? UNION
            SELECT s.id FROM session s JOIN owned o ON s.parent_id = o.id)
            SELECT id FROM owned""", (session,))}
        if not owned:
            sys.exit(1)
        count = db.execute("""WITH RECURSIVE owned(id) AS (
            SELECT id FROM session WHERE id = ? UNION
            SELECT s.id FROM session s JOIN owned o ON s.parent_id = o.id)
            SELECT count(*) FROM part WHERE session_id IN (SELECT id FROM owned)
            AND json_extract(data, '$.type') = 'tool'
            AND json_extract(data, '$.state.status') = 'completed'""", (session,)).fetchone()[0]
    refused = False
    for path in Path(directory).glob("*.jsonl"):
        for line in path.open():
            event = json.loads(line)
            if event.get("schema") == 1 and event.get("session") in owned and event.get("outcome") == "refused":
                # Policy refusals anywhere in the same session tree veto recovery.
                if not re.fullmatch(r"helper-(?:timeout|unavailable|exit-[0-9]+)|ENOENT|ETIMEDOUT", event.get("reason", "")):
                    sys.exit(1)
                refused = True
    sys.exit(0 if refused and count == 0 else 1)
except (OSError, ValueError, TypeError, AttributeError, sqlite3.Error):
    sys.exit(1)
PY
	return $?
}

_hrff_blocked_exit_holds() {
	declare -F gh_issue_edit_safe >/dev/null 2>&1 || return 1
	[[ "$(_terminal_blocker_reason "${AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT:-}")" != runner_capability_unmet ||
		-n "${AIDEVOPS_TERMINAL_BLOCKER_MISSING_SECRETS:-}" ]] || return 1
	return 0
}

_hrff_prepare_terminal_blocker_release() {
	local issue_number="$1"
	local repo_slug="$2"
	local machine_readable_part="$3"
	local release_reason="${4:-blocked}"
	local repo_path="${AIDEVOPS_TERMINAL_BLOCKER_REPO_PATH:-}"
	local blocker_fingerprint="${AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT:-}"
	local issue_json="" comments_json="" task_revision="" mode="" projected_state="status:available"
	_HRFF_TERMINAL_BLOCKER_MODE="normal"
	_HRFF_TERMINAL_BLOCKER_FRAGMENT=""
	_HRFF_TERMINAL_BLOCKER_CIRCUIT_BODY=""
	# Empty until this release's observation, or an earlier one, is evidence.
	_HRFF_TERMINAL_BLOCKER_EVIDENCE=""
	issue_json=$(gh api "repos/${repo_slug}/issues/${issue_number}" \
		--jq '{title: (.title // ""), body: (.body // "")}' 2>/dev/null) || return 0
	comments_json=$(terminal_blocker_fetch_trusted_comments "$issue_number" "$repo_slug") || return 0
	local input_hold_rc=0
	terminal_blocker_input_circuit_active "$comments_json" "$issue_json" "$repo_slug" "$issue_number" "$repo_path" || input_hold_rc=$?
	if [[ "$input_hold_rc" -ne 1 ]]; then
		_HRFF_TERMINAL_BLOCKER_MODE=open
		_HRFF_TERMINAL_BLOCKER_EVIDENCE=circuit
		return 0
	fi
	[[ -n "$repo_path" && "$blocker_fingerprint" =~ ^[a-f0-9]{24}$ ]] || return 0
	task_revision=$(terminal_blocker_task_revision \
		"$issue_json" "$repo_slug" "$issue_number" "$repo_path") || return 0
	# GH#33025: the login that authors this runner's releases also recognises
	# its own earlier observations when GitHub reports it as a collaborator.
	mode=$(TERMINAL_BLOCKER_SELF_LOGIN="$(_hrff_resolve_release_runner_login)" \
		terminal_blocker_release_mode "$comments_json" "$task_revision" "$blocker_fingerprint") || return 0
	case "$mode" in
	first)
		if [[ "$release_reason" == blocked ]] && _hrff_blocked_exit_holds; then
			projected_state="status:blocked"
		fi
		_HRFF_TERMINAL_BLOCKER_FRAGMENT=$(terminal_blocker_observation_fragment \
			"$task_revision" "$blocker_fingerprint" "$mode" "$projected_state") || _HRFF_TERMINAL_BLOCKER_FRAGMENT=""
		[[ -z "$_HRFF_TERMINAL_BLOCKER_FRAGMENT" ]] || _HRFF_TERMINAL_BLOCKER_EVIDENCE="observation"
		;;
	circuit)
		_HRFF_TERMINAL_BLOCKER_MODE="circuit"
		_HRFF_TERMINAL_BLOCKER_EVIDENCE="prior_observation"
		_HRFF_TERMINAL_BLOCKER_CIRCUIT_BODY=$(terminal_blocker_circuit_comment \
			"$machine_readable_part" "$task_revision" "$blocker_fingerprint") || {
			_HRFF_TERMINAL_BLOCKER_MODE="normal"
			_HRFF_TERMINAL_BLOCKER_CIRCUIT_BODY=""
		}
		;;
	open)
		_HRFF_TERMINAL_BLOCKER_MODE="open"
		_HRFF_TERMINAL_BLOCKER_EVIDENCE="circuit"
		;;
	normal)
		# A repeated unknown dossier for this revision keeps its earlier observation.
		_HRFF_TERMINAL_BLOCKER_EVIDENCE="prior_observation"
		;;
	esac
	return 0
}

_hrff_apply_terminal_permission_hold() {
	local issue_number="$1"
	local repo_slug="$2"
	local blocker_fingerprint="${AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT:-}"
	[[ "$blocker_fingerprint" =~ ^[a-f0-9]{24}$ ]] || return 0
	[[ "$(_terminal_blocker_reason "$blocker_fingerprint")" == "permission_required" ]] || return 0
	# A terminal-only denial has no request envelope or request-specific approval
	# path. Keep it in the generic terminal-blocker lifecycle instead of
	# projecting the dedicated scoped-grant label, which is reserved for
	# worker-permission-helper.sh request.
	print_info "Retaining terminal permission blocker on #${issue_number} in ${repo_slug} without a scoped permission hold"
	return 0
}

# t18514/GH#32754: hand a newly opened circuit to this runner's pulse
# supervisor, which owns AI brief/environment recovery. Best-effort: the queue
# grants nothing and a missed enqueue is backfilled by the helper's seed pass.
_hrff_enqueue_blocker_recovery() {
	local issue_number="$1"
	local repo_slug="$2"
	local helper="${SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}/terminal-blocker-recovery-helper.sh"
	local reason=""
	[[ -f "$helper" ]] || return 0
	if declare -F _terminal_blocker_reason >/dev/null 2>&1; then
		reason=$(_terminal_blocker_reason "${AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT:-}") || reason=""
	fi
	# The helper normalises an empty or unrecognised reason to its unknown class.
	bash "$helper" enqueue "$repo_slug" "$issue_number" "$reason" >/dev/null 2>&1 ||
		print_warning "Blocker recovery enqueue failed for #${issue_number} (seed pass will backfill)"
	return 0
}

#######################################
# Project exactly one status:blocked while a terminal-blocker circuit holds
# dispatch (GH#33138), remove the runner assignee and unlock. The matching
# release to status:available is owned by terminal-blocker-recovery-helper.sh
# when the circuit re-arms (trusted retry or relevant revision).
#
# Args: $1 = issue_number, $2 = repo_slug
#######################################
_hrff_hold_terminal_blocker_circuit() {
	local issue_number="$1"
	local repo_slug="$2"
	local runner_name=""
	local -a hold_args=()

	runner_name=$(_hrff_resolve_release_runner_login)
	if declare -F gh_issue_edit_safe >/dev/null 2>&1; then
		_hrff_project_blocked_exit "$issue_number" "$repo_slug" "$runner_name" || return 1
		_unlock_issue_after_dispatch_release "$issue_number" "$repo_slug"
		return 0
	fi
	[[ -z "$runner_name" ]] || hold_args+=(--remove-assignee "$runner_name")
	if declare -F set_issue_status >/dev/null 2>&1; then
		set_issue_status "$issue_number" "$repo_slug" blocked \
			${hold_args[@]+"${hold_args[@]}"} >/dev/null 2>&1 ||
			print_warning "Failed to project status:blocked on #${issue_number} (non-fatal)"
	fi
	_unlock_issue_after_dispatch_release "$issue_number" "$repo_slug"
	return 0
}

#######################################
# GH#34846: a held first observation of a re-armable class has no circuit, so
# queue it for the runner-local recovery owner, which returns the issue to
# status:available once a relevant revision or trusted retry lands.
# GH#36044: retry-only classes (GH#35925, e.g. permission_required) are queued
# too; otherwise only the slow cross-repo seed could find them and a trusted
# retry stayed unapplied for hours.
# Call only after the observation release is persisted and projected.
#######################################
_hrff_enqueue_observation_recovery() {
	local issue_number="$1"
	local repo_slug="$2"
	[[ -n "${_HRFF_TERMINAL_BLOCKER_FRAGMENT:-}" ]] || return 0
	declare -F terminal_blocker_observation_recoverable >/dev/null 2>&1 || return 0
	terminal_blocker_observation_recoverable "$(_terminal_blocker_reason "${AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT:-}")" || return 0
	_hrff_blocked_exit_holds || return 0
	_hrff_enqueue_blocker_recovery "$issue_number" "$repo_slug"
	return 0
}

_hrff_handle_terminal_blocker_release() {
	local issue_number="$1"
	local repo_slug="$2"
	local machine_readable_part="$3"
	local release_reason="${4:-blocked}"
	if [[ -n "${AIDEVOPS_TERMINAL_BLOCKER_REJECTED_SECRETS:-}" ]]; then
		local -a rejected_names=()
		local rejected_name=""
		while IFS= read -r rejected_name; do
			rejected_names+=("$rejected_name")
		done <<<"$AIDEVOPS_TERMINAL_BLOCKER_REJECTED_SECRETS"
		python3 "${BASH_SOURCE[0]%/*}/runner-secret-rejection.py" record "${rejected_names[@]}" >/dev/null 2>&1 ||
			print_warning "Could not persist runner-local rejected-secret cooldown"
	fi
	_hrff_prepare_terminal_blocker_release "$issue_number" "$repo_slug" "$machine_readable_part" "$release_reason"
	# A classified replay must not degrade to a dispatchable unrecorded exit.
	if [[ "${_HRRR_REPLAY:-0}" == 1 && -n "${AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT:-}" &&
		-z "${_HRFF_TERMINAL_BLOCKER_FRAGMENT:-}" && -z "${_HRFF_TERMINAL_BLOCKER_EVIDENCE:-}" ]]; then
		return 11
	fi
	_hrff_apply_terminal_permission_hold "$issue_number" "$repo_slug" || return 11
	case "${_HRFF_TERMINAL_BLOCKER_MODE:-normal}" in
	circuit)
		if ! _hrff_post_claim_released_comment "$issue_number" "$repo_slug" \
			"$_HRFF_TERMINAL_BLOCKER_CIRCUIT_BODY"; then
			print_warning "Terminal blocker release or ownership verification incomplete for #${issue_number}; retaining issue state; reconcile persisted comments before retrying"
			return 11
		fi
		print_info "Opened unchanged terminal-blocker circuit on #${issue_number}"
		_hrff_enqueue_blocker_recovery "$issue_number" "$repo_slug"
		_hrff_hold_terminal_blocker_circuit "$issue_number" "$repo_slug" || return 11
		return 10
		;;
	open)
		print_info "Unchanged terminal-blocker circuit already active on #${issue_number}; suppressing duplicate release diagnostics"
		# A circuit from an older attempt is not this attempt's release receipt.
		# Keep prose deduplication, but persist the current release before mutation.
		if declare -F gh_issue_edit_safe >/dev/null 2>&1 &&
			! _hrff_blocked_release_persisted "$issue_number" "$repo_slug" "$(_hrff_resolve_release_runner_login)"; then
			_hrff_post_claim_released_comment "$issue_number" "$repo_slug" \
				"$machine_readable_part" || return 11
		fi
		_hrff_hold_terminal_blocker_circuit "$issue_number" "$repo_slug" || return 11
		return 10
		;;
	esac
	return 0
}

# Persist one bound release, then project only while its generation still matches.
_hrff_persist_and_project_release() {
	local issue_number="$1" repo_slug="$2" runner_name="$3" reason="$4"
	local projection_reason="$5" session_key="$6" claim_id="$7"
	local machine_readable_part="$8" terminal_blocker_fragment="$9" comment_body=""
	comment_body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
${machine_readable_part}${terminal_blocker_fragment}
<!-- ops:end -->"
	if ! _hrff_post_claim_released_comment "$issue_number" "$repo_slug" "$comment_body" "$session_key" "$runner_name" "$claim_id"; then
		print_warning "Claim release or ownership verification incomplete for #${issue_number}; retaining issue state; reconcile persisted comments before retrying"
		return 1
	fi
	print_info "Released claim on #${issue_number} (reason: ${reason})"
	_hrff_check_release_claim "$issue_number" "$repo_slug" "$runner_name" "$session_key" "$machine_readable_part" || return 1
	if [[ "$_HRFF_RELEASE_CLAIM_OWNED" -ne 1 || "${_HRFF_RELEASE_CLAIM_ID:-}" != "$claim_id" ]]; then
		print_info "Preserved issue lifecycle state on #${issue_number}: release generation changed after publication"
		return 0
	fi
	_hrff_project_post_release_state "$issue_number" "$repo_slug" "$runner_name" "$projection_reason" "$session_key" || return 1
	[[ "$projection_reason" != blocked ]] || _hrff_enqueue_observation_recovery "$issue_number" "$repo_slug"
	return 0
}

#######################################
# Release a dispatch claim by posting a CLAIM_RELEASED comment.
# The dedup guard recognises this and allows immediate re-dispatch
# instead of waiting for the 30-min TTL to expire.
#
# Args:
#   $1 = session_key (contains issue number and repo slug)
#   $2 = reason (logged in the comment for debugging)
#   $3 = exit_code (optional — included in comment when provided by exit trap)
#   $4 = session_count (optional — session_count from worker DB for exit trap)
#######################################
# GH#37344: a release that cannot be published (for example GitHub admission
# deferred) leaves private retry evidence for the Pulse recovery consumer.
_release_dispatch_claim() {
	local session_key="$1" reason="${2:-worker_failed}" rc=0
	local issue_number="" repo_slug="${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}"

	_hrff_release_dispatch_claim_attempt "$@" || rc=$?
	issue_number=$(_hrff_release_issue_number "$session_key")
	if [[ "$rc" -eq 0 ]]; then
		_hrrr_clear "$session_key" "$issue_number" "$repo_slug"
	else
		_hrrr_record "$session_key" "$reason" "${3:-}" "${4:-}" "$issue_number" "$repo_slug"
	fi
	return "$rc"
}

# Persist bounded, non-secret lifecycle metadata even when detached output is lost.
_hrff_log_prelaunch_abort() {
	local session="$1" cause="$2"
	local unknown="unavailable"
	local stage="${_WORKER_PRELAUNCH_LAST_STAGE:-$unknown}"
	local attempt="${AIDEVOPS_ATTEMPT_ID:-$unknown}"
	local log_dir="${HOME}/.aidevops/logs"
	[[ "$session" =~ ^[A-Za-z0-9._:-]+$ ]] || session="$unknown"
	[[ "$cause" =~ ^[A-Za-z0-9._:-]+$ ]] || cause="$unknown"
	[[ "$stage" =~ ^[A-Za-z0-9._:-]+$ ]] || stage="$unknown"
	[[ "$attempt" =~ ^[A-Za-z0-9._:-]+$ ]] || attempt="$unknown"
	if ! (umask 077; mkdir -p "$log_dir" && printf '[lifecycle] prelaunch_abort session=%s attempt_id=%s stage=%s cause=%s\n' "$session" "$attempt" "$stage" "$cause" >>"${log_dir}/headless-prelaunch.log"); then
		print_warning "[lifecycle] unable to persist prelaunch abort session=${session} attempt_id=${attempt} stage=${stage} cause=${cause}"
	fi
	return 0
}

_hrff_release_fragment() {
	local reason="$1" fragment="$2"
	if [[ "$reason" == "${_HRW_REASON_DRAFT_CHECKPOINT:-worker_draft_checkpoint}" ]]; then
		fragment=$'\nDraft checkpoint: partial work is preserved on the draft PR. Next action: Pulse continues the exact head (bounded per head and per PR).\n'
	elif [[ "$reason" == "${_HRW_REASON_NOT_LAUNCHED:-worker_not_launched}" && "${AIDEVOPS_PR_CHECKPOINT_ADMISSION_MODE:-}" == revision ]]; then
		fragment=$'\nRuntime did not launch, so the approved head is unchanged. The revision continuation approval stays reusable for this exact head (bounded retries within its validity window); no new approval is needed unless the head, brief or approval window changes.\n'
	elif [[ "$reason" == "${_HRW_REASON_MERGED_PARTIAL:-worker_merged_partial}" ]]; then
		fragment=$'\nPartial PR merged; issue stays open for continuation from the brief ledger. Next action: dispatch a continuation worker.\n'
	elif [[ "$reason" == worker_merged_partial_no_progress ]]; then
		fragment=$'\nBLOCKED: continuation delivered no new PR or head after a merged partial. AI brief owner: reconcile merged worker-side scope with remaining acceptance items before retrying.\n'
	fi
	if [[ "$reason" == worker_merged_partial* && -n "${_HRW_MERGED_DELIVERY_KEY:-}" ]]; then
		fragment+="MERGED_PARTIAL_DELIVERY key=${_HRW_MERGED_DELIVERY_KEY}"$'\n'
	fi
	_HRFF_RELEASE_FRAGMENT="$fragment"
	return 0
}

# Fence direct release/EXIT callers as well as _cmd_run_finish. Supervisor
# callers without worker launch state retain their existing recovery rules.
_hrff_verified_release_reason() {
	local reason="$1"
	if [[ "$reason" == worker_complete && -n "${_WORKER_RUNTIME_LAUNCH_STARTED+x}" ]] &&
		declare -F _hrw_runtime_launch_confirmed >/dev/null 2>&1 &&
		! _hrw_runtime_launch_confirmed; then
		reason="worker_not_launched"
	fi
	printf '%s\n' "$reason"
	return 0
}

# Public audit records carry only the managed log ID, never a private path.
_hrff_attempt_log_field() {
	local attempt_log_id="${AIDEVOPS_WORKER_ATTEMPT_LOG:-}"
	attempt_log_id="${attempt_log_id##*/}"
	if [[ "$attempt_log_id" =~ ^worker-[A-Za-z0-9_.-]+\.log\.[A-Za-z0-9]+$ ]]; then
		printf ' attempt_log=%s' "$attempt_log_id"
	fi
	return 0
}

_hrff_release_dispatch_claim_attempt() {
	local session_key="$1"
	local reason="${2:-worker_failed}"
	local exit_code_arg="${3:-}"
	local session_count_arg="${4:-}"
	local issue_number=""
	# GH#35684: model selection runs before _cmd_run_prepare exports
	# DISPATCH_REPO_SLUG, so a pre-launch failure must fall back to the
	# dispatcher-supplied WORKER_REPO_SLUG or the claim is stranded.
	local repo_slug="${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}"
	local runner_name=""
	local machine_readable_part=""
	local repair_pr_number="${AIDEVOPS_PR_REPAIR_NUMBER:-}"

	# Direct PR-remediation workers are dispatched against a pull request rather
	# than an issue claim. The scanner owns their completion/blocked lifecycle;
	# generic release writes would mutate the PR's issue facade and can unlock,
	# relabel, or unassign state that this worker never owned.
	if [[ -n "$repair_pr_number" && "$repair_pr_number" == "${WORKER_ISSUE_NUMBER:-}" ]]; then
		print_info "Skipped generic issue claim release for direct PR repair #${repair_pr_number}; scanner owns lifecycle state"
		return 0
	fi

	issue_number=$(_hrff_release_issue_number "$session_key")
	if [[ -z "$issue_number" && -z "${WORKER_ISSUE_NUMBER:-}" ]]; then
		return 0
	fi

	# Supervisor/pulse cleanup paths can source this module and run the generic
	# EXIT cleanup without ever having claimed a worker issue. With no issue and
	# no repo there is no real claim to release; treat that exact empty-context
	# case as a benign caller-boundary no-op. Keep warning on partial context
	# because issue-without-repo or repo-without-issue can strand a real claim.
	if ! _hrff_release_context_is_valid "$issue_number" "$repo_slug"; then
		return 0
	fi
	_hrff_release_repo_state_is_managed "$issue_number" "$repo_slug" || return "${_HRFF_RELEASE_AUTHORITY_SKIP_RC:-0}"
	runner_name=$(_hrff_resolve_release_runner_login)
	_hrff_check_release_claim "$issue_number" "$repo_slug" "$runner_name" "$session_key" || return 1
	[[ "$_HRFF_RELEASE_CLAIM_OWNED" -eq 1 ]] || return 0
	local claim_id="${_HRFF_RELEASE_CLAIM_ID:-}"
	[[ "$claim_id" =~ ^[1-9][0-9]*$ ]] || return 1

	reason=$(_hrff_verified_release_reason "$reason")

	if [[ "$reason" == "rate_limit_transient" ]]; then
		if ! _hrff_handle_rate_limit_release_circuit "$issue_number" "$repo_slug"; then
			# The per-issue breaker is already active. Keep state cleanup so the
			# GitHub issue is not stranded in an active lifecycle state, but skip
			# the duplicate CLAIM_RELEASED audit comment that caused storms.
			_hrff_check_release_claim "$issue_number" "$repo_slug" "$runner_name" "$session_key" || return 1
			[[ "$_HRFF_RELEASE_CLAIM_OWNED" -eq 1 && "${_HRFF_RELEASE_CLAIM_ID:-}" == "$claim_id" ]] || return 0
			_hrff_release_rate_limit_circuit_cleanup "$issue_number" "$repo_slug"
			return 0
		fi
	fi

	if [[ "$reason" == blocked ]] && _hrff_blocked_release_persisted "$issue_number" "$repo_slug" "$runner_name"; then
		_hrff_check_release_claim "$issue_number" "$repo_slug" "$runner_name" "$session_key" || return 1
		[[ "$_HRFF_RELEASE_CLAIM_OWNED" -eq 1 && "${_HRFF_RELEASE_CLAIM_ID:-}" == "$claim_id" ]] || return 0
		local persisted_reason="$reason"
		[[ "${_HRFF_PERSISTED_RELEASE_UNRECORDED:-0}" -eq 0 ]] || persisted_reason="$_HRFF_REASON_BLOCKED_UNRECORDED"
		_hrff_project_post_release_state "$issue_number" "$repo_slug" "$runner_name" "$persisted_reason"
		return $?
	fi
	machine_readable_part=$(_hrff_build_claim_released_line "$reason" "$runner_name" "$exit_code_arg" "$session_count_arg")
	machine_readable_part+=" claim_id=${claim_id} nonce=${AIDEVOPS_DISPATCH_LEASE_TOKEN:-} lease_token=${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}"
	machine_readable_part+=" device=${AIDEVOPS_DISPATCH_LEASE_DEVICE:-${AIDEVOPS_DEVICE_ID:-}} session=${AIDEVOPS_DISPATCH_LEASE_SESSION:-$session_key}"
	machine_readable_part+="$(_hrff_attempt_log_field)"
	local terminal_blocker_fragment=""
	case "$reason" in
	blocked | push_policy_timeout | network_policy_timeout)
		local terminal_blocker_rc=0
		_hrff_handle_terminal_blocker_release "$issue_number" "$repo_slug" "$machine_readable_part" "$reason" || terminal_blocker_rc=$?
		[[ "$terminal_blocker_rc" -eq 10 ]] && return 0
		[[ "$terminal_blocker_rc" -eq 11 ]] && return 1
		terminal_blocker_fragment="${_HRFF_TERMINAL_BLOCKER_FRAGMENT:-}"
		;;
	esac
	# A held status:blocked needs evidence that an owner can re-arm: recovery
	# retires evidence-less entries (GH#35569) and the dependency sweep defers
	# to that absent owner, so an unrecorded hold never cleared. Unclassified
	# or unreadable evidence stays retryable; a repeat records it before a hold.
	local projection_reason="$reason"
	if [[ "$reason" == blocked && -z "$terminal_blocker_fragment" &&
		-z "${_HRFF_TERMINAL_BLOCKER_EVIDENCE:-}" ]]; then
		machine_readable_part+=" evidence=unrecorded"
		projection_reason="$_HRFF_REASON_BLOCKED_UNRECORDED"
		print_warning "Blocked exit on #${issue_number} recorded no terminal-blocker evidence; keeping it dispatchable"
	fi
	_hrff_release_fragment "$reason" "$terminal_blocker_fragment"
	terminal_blocker_fragment="$_HRFF_RELEASE_FRAGMENT"
	_hrff_persist_and_project_release "$issue_number" "$repo_slug" "$runner_name" "$reason" \
		"$projection_reason" "$session_key" "$claim_id" "$machine_readable_part" "$terminal_blocker_fragment" || return 1
	return 0
}

#######################################
# GH#35574: post this attempt's authenticated DISPATCH_LEASE phase=terminal at
# release time. dispatch-claim-helper.sh signs it with the claim's lease token,
# device and session plus AIDEVOPS_ATTEMPT_ID, which is exactly what
# _dd_has_matching_terminal_lease requires to retire a generation-marked
# dispatch. The later worker-event emission stays as a fallback and is a no-op
# once the lease is terminal. Never prints the token; always non-fatal.
#
# Args: $1 = issue_number, $2 = repo_slug, $3 = session_key (optional)
#######################################
_hrff_emit_release_terminal_lease() {
	local issue_number="$1"
	local repo_slug="$2"
	local session_key="${3:-}"
	local helper="${DISPATCH_CLAIM_HELPER:-${SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}/dispatch-claim-helper.sh}"
	local lease_session=""

	[[ -n "${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}" && "$issue_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 0
	if [[ ! -x "$helper" ]]; then
		print_warning "Terminal lease helper unavailable for #${issue_number}; retaining eligible checkpoint evidence locally"
	fi
	lease_session="${AIDEVOPS_DISPATCH_LEASE_SESSION:-${session_key:-issue-${issue_number}}}"
	# shellcheck source=./terminal-lease-recovery.sh
	source "${BASH_SOURCE[0]%/*}/terminal-lease-recovery.sh"
	if _terminal_lease_emit_or_record "$issue_number" "$repo_slug" "$lease_session" "$helper"; then
		print_info "Posted terminal dispatch lease on #${issue_number} after ready handoff release"
		return 0
	fi
	print_warning "Terminal dispatch lease not posted on #${issue_number}; checkpoint recovery recorded locally when eligible"
	return 0
}

#######################################
# Project a released draft checkpoint as available for exact-head continuation.
# Always non-fatal.
#
# Args: $1 = issue_number, $2 = repo_slug, $3 = runner_name
#######################################
_hrff_project_draft_checkpoint() {
	local issue_number="$1"
	local repo_slug="$2"
	local runner_name="$3"
	local spec_restore_rc=0 dispatch_restored=0

	# GH#36019: the draft is preserved work awaiting exact-head continuation
	# (pr-checkpoint-continuation-helper.sh dispatch-stalled). A closing-linked
	# draft projected as status:blocked was rejected by that target fence and
	# held silently; WORKER_DRAFT_CHECKPOINT dedup still blocks redispatch.
	if declare -F clear_active_status_on_release >/dev/null 2>&1; then
		clear_active_status_on_release "$issue_number" "$repo_slug" "$runner_name" available \
			|| print_warning "Failed to project draft checkpoint state on #${issue_number} (non-fatal)"
	fi
	# A draft may have merged between checkpoint classification and release.
	# Reconcile only after projection/unassignment; the shared guard requires
	# available state and proves that NO open PR still owns the issue.
	# shellcheck source=pulse-merge-partial-continuation.sh
	source "${BASH_SOURCE[0]%/*}/pulse-merge-partial-continuation.sh"
	if _pmpc_restore_available_dispatch "$repo_slug" "$issue_number" 1; then
		dispatch_restored=1
	fi
	# GH#38021: the escalation removed auto-dispatch, and a canonical
	# consolidated spec is filtered out of dispatch without it. Put back
	# only what this run removed; the draft still routes the exact head.
	_pmpc_restore_checkpoint_spec_dispatch "$repo_slug" "$issue_number" || spec_restore_rc=$?
	if [[ "$spec_restore_rc" -eq 0 ]]; then
		dispatch_restored=1
		print_info "Restored auto-dispatch on consolidated spec #${issue_number} removed by this run's draft checkpoint"
	elif [[ "$spec_restore_rc" -eq 2 ]]; then
		print_warning "[lifecycle] checkpoint_spec_dispatch_not_restored issue=${issue_number} — this run's draft checkpoint removed auto-dispatch; the issue was unreadable, held, owned or not available afterwards"
	fi
	# aidevops:trust-boundary — the lock decision follows the label state left
	# by the restores above (GH#30180). A restore returns the issue to the
	# dispatch queue, so this release must not reopen its conversation; the
	# unlock helper re-reads the labels in every other case.
	if [[ "$dispatch_restored" -eq 1 ]]; then
		print_info "Retaining conversation lock for #${issue_number} in ${repo_slug}: this release restored auto-dispatch"
	else
		_unlock_issue_after_dispatch_release "$issue_number" "$repo_slug"
	fi
	print_info "Projected draft checkpoint #${issue_number} for exact-head continuation"
	return 0
}

#######################################
# Project issue lifecycle state after a persisted CLAIM_RELEASED comment.
# Reason-specific paths preserve state that authoritative handoffs already
# projected; the default path clears active status so re-dispatch is not
# blocked. Always non-fatal.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#   $3 = runner_name
#   $4 = reason
#   $5 = session_key (optional; lease session fallback)
#######################################
_hrff_project_post_release_state() {
	local issue_number="$1"
	local repo_slug="$2"
	local runner_name="$3"
	local reason="$4"
	local session_key="${5:-}"

	# Older standalone consumers without safe-edit retain their existing cleanup;
	# only the full runtime's named safe-edit path can produce verified provenance.
	if [[ "$reason" == blocked ]] && _hrff_blocked_exit_holds; then
		_hrff_project_blocked_exit "$issue_number" "$repo_slug" "$runner_name" || return 1
		_unlock_issue_after_dispatch_release "$issue_number" "$repo_slug"
		return 0
	fi
	if [[ "$reason" == worker_merged_partial_no_progress ]]; then
		_hrff_project_merged_no_progress "$issue_number" "$repo_slug" "$runner_name"
		return $?
	fi
	if [[ "$reason" == "${_HRW_REASON_OWNERSHIP_LOST:-worker_ownership_lost}" ]]; then
		print_info "Preserving live issue ownership for #${issue_number} after worker ownership loss"
		return 0
	fi
	if [[ "$reason" == "${_HRW_REASON_DRAFT_CHECKPOINT:-worker_draft_checkpoint}" ]]; then
		_hrff_project_draft_checkpoint "$issue_number" "$repo_slug" "$runner_name"
		return 0
	fi
	# GH#33545: same projection as a draft checkpoint (clear active status,
	# keep any blocker, unlock); only the operator-facing wording differs.
	if [[ "$reason" == "${_HRW_REASON_MERGED_PARTIAL:-worker_merged_partial}" ]]; then
		if declare -F clear_active_status_on_release >/dev/null 2>&1; then
			clear_active_status_on_release "$issue_number" "$repo_slug" "$runner_name" \
				|| print_warning "Failed to project merged partial state on #${issue_number} (non-fatal)"
		fi
		_unlock_issue_after_dispatch_release "$issue_number" "$repo_slug"
		print_info "Released merged partial #${issue_number} for continuation"
		return 0
	fi
	# GH#33287: ready-PR handoffs have already projected and verified
	# status:in-review with the runner assigned. The generic projection counts
	# only closing keywords, so a deliberate `For #N` PR would reset the issue
	# to status:available and orphan the open PR. Keep that state; only unlock.
	# GH#35574: this attempt has ended, so retire its generation-marked dispatch
	# lock now. Merged-partial continuation trusts CLAIM_RELEASED, but dedup
	# accepts only the authenticated terminal lease for marked dispatches.
	if [[ "$reason" == "${_HRW_REASON_READY_MISSING_LINKAGE:-worker_ready_missing_linkage}" ||
		"$reason" == "${_HRW_REASON_READY_MISSING_SUMMARY:-worker_ready_missing_summary}" ]]; then
		_hrff_emit_release_terminal_lease "$issue_number" "$repo_slug" "$session_key"
		_unlock_issue_after_dispatch_release "$issue_number" "$repo_slug"
		print_info "Preserved in-review handoff on #${issue_number} (reason: ${reason})"
		return 0
	fi

	# t2420: clear active-lifecycle status labels + worker assignment so the
	# pulse's combined-signal dedup guard (t1996) doesn't treat the issue
	# as active after release. Without this, orphan labels pin the issue
	# as "active" for the full 30-min TTL even though no worker holds the
	# claim, blocking re-dispatch. Preserves terminal states (done, blocked)
	# set by authoritative paths. Defensive skip if origin:interactive.
	# Non-fatal: failure does not block the release comment path.
	# GH#34758: a runner-capability release is runner-local. Its open draft
	# stays available so a capable runner's exact-head continuation can run,
	# matching the "Projected state: status:available" recovery text.
	# GH#36019: every other non-blocked release (stall, clean, worker_complete,
	# ...) leaves preserved work that Pulse continues or records attention for;
	# only the terminal-blocker classes project an open draft as blocked.
	local draft_projection="available"
	if [[ "$reason" == blocked || "$reason" == push_policy_timeout || "$reason" == network_policy_timeout ]]; then
		draft_projection="blocked"
		if declare -F _terminal_blocker_reason >/dev/null 2>&1 &&
			[[ "$(_terminal_blocker_reason "${AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT:-}")" == runner_capability_unmet ]]; then
			draft_projection="available"
		fi
	fi
	if declare -F clear_active_status_on_release >/dev/null 2>&1; then
		clear_active_status_on_release "$issue_number" "$repo_slug" "$runner_name" "$draft_projection" \
			|| print_warning "Failed to clear active status on #${issue_number} (non-fatal)"
	fi
	_unlock_issue_after_dispatch_release "$issue_number" "$repo_slug"
	return 0
}

# Runtime-only projection, called only after CLAIM_RELEASED persistence.
_hrff_blocked_release_persisted() {
	local issue_number="$1" repo_slug="$2" runner_name="$3"
	local comments_json=""
	_HRFF_PERSISTED_RELEASE_UNRECORDED=0
	comments_json=$(terminal_blocker_fetch_trusted_comments "$issue_number" "$repo_slug") || return 1
	comments_json=$(jq -c 'map(select((.body // "")
		| test("(?m)^CLAIM_RELEASED reason=blocked |^DISPATCH_CLAIM ")))' <<<"$comments_json") || return 1
	# Without an attempt boundary, historical releases cannot deduplicate this
	# attempt. Legacy consumers still use the existing circuit retry semantics.
	jq -e 'any(.[]; (.body // "")
		| test("(?m)^DISPATCH_CLAIM "))' <<<"$comments_json" >/dev/null 2>&1 || return 1
	TERMINAL_BLOCKER_SELF_LOGIN="$runner_name" terminal_blocker_has_current_hold "$comments_json" || return 1
	# The persisted receipt, not this retry, decides the projection: a retry
	# must not turn an evidence=unrecorded release into status:blocked.
	if jq -e --arg self "$runner_name" --argjson authoritative "$_TBC_AUTHORITATIVE_ASSOCIATIONS" \
		"${_TBC_HOLD_EVIDENCE_JQ}"'
		map(select(hold_evidence($authoritative; $self)))
		| sort_by([.created_at // "", .id // 0]) | last | (.body // "")
		| test("(?m)^CLAIM_RELEASED reason=blocked .* evidence=unrecorded$")
	' <<<"$comments_json" >/dev/null 2>&1; then
		_HRFF_PERSISTED_RELEASE_UNRECORDED=1
	fi
	return 0
}

_hrff_project_blocked_exit() {
	local issue_number="$1" repo_slug="$2" runner_name="$3"
	local issue_json="" status="" issue_endpoint=""
	local -a edit_args=()
	printf -v issue_endpoint 'repos/%s/issues/%s' "$repo_slug" "$issue_number"
	issue_json=$(gh api "$issue_endpoint" 2>/dev/null) || return 1
	jq -e --arg open "$_HRFF_OPEN_ISSUE_STATE" '.state == $open and .pull_request == null' <<<"$issue_json" >/dev/null 2>&1 || return 1
	# Origin is authorship, not ownership: preserve another live assignee, not
	# every task that was originally briefed by an interactive session.
	if jq -e --arg runner "$runner_name" 'any(.assignees[]?; .login != $runner)
		or ([.labels[]?.name] | any(. == "status:in-review" or . == "status:done"))' <<<"$issue_json" >/dev/null; then
		return 0
	fi
	_hrff_apply_missing_secret_gates "$issue_number" "$repo_slug" || return 1
	while IFS= read -r status; do
		[[ -z "$status" ]] || edit_args+=(--remove-label "$status")
	done < <(jq -r '.labels[]?.name | select(startswith("status:") and . != "status:blocked")' <<<"$issue_json")
	[[ -z "$runner_name" ]] || edit_args+=(--remove-assignee "$runner_name")
	gh_issue_edit_safe "$issue_number" --repo "$repo_slug" --add-label status:blocked \
		${edit_args[@]+"${edit_args[@]}"} || return 1
	return 0
}

_hrff_apply_missing_secret_gates() {
	local issue_number="$1" repo_slug="$2"
	local name=""
	for name in ${AIDEVOPS_TERMINAL_BLOCKER_MISSING_SECRETS:-}; do
		[[ "$name" =~ ^[A-Z][A-Z0-9_]{0,127}$ ]] || return 1
		gh label create "needs-secret:${name}" --repo "$repo_slug" --color D93F0B >/dev/null 2>&1 || true
		gh_issue_edit_safe "$issue_number" --repo "$repo_slug" --add-label "needs-secret:${name}" || return 1
	done
	return 0
}

# Preserve terminal closure and concurrent ownership when a partial repeats.
# A no-progress hold is deliberately sticky: only brief-owner reconciliation
# may release it, so new delivery cannot erase an unrelated existing blocker.
_hrff_project_merged_no_progress() {
	local issue_number="$1"
	local repo_slug="$2"
	local runner_name="$3"
	local issue_json="" projection=""
	local issue_endpoint=""
	printf -v issue_endpoint 'repos/%s/issues/%s' "$repo_slug" "$issue_number"
	issue_json=$(gh api "$issue_endpoint" 2>/dev/null) || return 1
	projection=$(printf '%s' "$issue_json" | jq -er --arg runner "$runner_name" --arg open "$_HRFF_OPEN_ISSUE_STATE" '
		if .state == "closed" then "done"
		elif .state != $open then empty
		elif any(.assignees[]?; .login != $runner) then "preserve"
		else "blocked" end') || return 1
	[[ "$projection" != preserve ]] || return 0
	set_issue_status "$issue_number" "$repo_slug" "$projection" --remove-assignee "$runner_name" || return 1
	_unlock_issue_after_dispatch_release "$issue_number" "$repo_slug"
	print_info "Projected unchanged merged partial #${issue_number} as ${projection}; AI brief owner owns reconciliation"
	return 0
}

#######################################
# Resolve the GitHub login whose dispatch claim should be released.
# Prefer the identity captured by the dispatcher because the local OS user can
# differ from the GitHub assignee in bot/cross-account worker setups (GH#23854).
# Globals:
#   WORKER_GITHUB_LOGIN, AIDEVOPS_WORKER_GITHUB_LOGIN
# Outputs:
#   GitHub login or OS username fallback.
#######################################
_hrff_resolve_release_runner_login() {
	local runner_login="${WORKER_GITHUB_LOGIN:-${AIDEVOPS_WORKER_GITHUB_LOGIN:-}}"
	if [[ -n "$runner_login" ]]; then
		printf '%s\n' "$runner_login"
		return 0
	fi

	if command -v gh >/dev/null 2>&1; then
		runner_login=$(gh api user --jq '.login // ""' || true)
		if [[ "$runner_login" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
			printf '%s\n' "$runner_login"
			return 0
		fi
	fi

	runner_login=$(whoami)
	printf '%s\n' "$runner_login"
	return 0
}

_HRFF_CLASSIFY_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_HRFF_CLASSIFY_DIR" == "${BASH_SOURCE[0]}" ]] && _HRFF_CLASSIFY_DIR="."
# shellcheck source=headless-runtime-failure-classify.sh
if ! source "${_HRFF_CLASSIFY_DIR}/headless-runtime-failure-classify.sh"; then
	printf 'ERROR: failed to load %s/headless-runtime-failure-classify.sh\n' "$_HRFF_CLASSIFY_DIR" >&2
	unset _HRFF_CLASSIFY_DIR
	return 1 2>/dev/null || exit 1
fi
unset _HRFF_CLASSIFY_DIR

#######################################
# Capture the caller-provided terminal-outcome destination before any runtime
# preflight can fail. Public environment names are removed after capture so
# child model processes cannot redirect the trusted outcome writer.
#######################################
_hrff_capture_external_outcome_contract() {
	if [[ -n "${AIDEVOPS_HEADLESS_OUTCOME_FILE+x}" ]]; then
		unset _WORKER_EXTERNAL_OUTCOME_FILE 2>/dev/null || true
		_WORKER_EXTERNAL_OUTCOME_FILE="${AIDEVOPS_HEADLESS_OUTCOME_FILE:-}"
	fi
	if [[ -n "${AIDEVOPS_HEADLESS_OUTCOME_ID+x}" ]]; then
		unset _WORKER_EXTERNAL_OUTCOME_ID 2>/dev/null || true
		_WORKER_EXTERNAL_OUTCOME_ID="${AIDEVOPS_HEADLESS_OUTCOME_ID:-}"
	fi
	_WORKER_EXTERNAL_OUTCOME_WRITTEN=0
	unset AIDEVOPS_HEADLESS_OUTCOME_FILE AIDEVOPS_HEADLESS_OUTCOME_ID 2>/dev/null || true
	return 0
}

#######################################
# Resolve a conservative retry class for EXIT-trap outcomes. Unknown reasons
# remain fail-closed and therefore still consume the remediation budget.
# Args: $1=reason, $2=session count
#######################################
_hrff_retry_class_for_reason() {
	local reason="$1"
	local session_count="$2"
	case "$reason" in
	opencode_version_pin_failed | canary_failed | worker_prepare_failed | duplicate_session | \
		worker_noop_zero_output | crash_during_startup | access_denied | auth_error | rate_limit* | provider_error | model_unavailable | \
		startup_no_model_activity | service_interruption_exhausted | worker_runtime_not_invoked | worker_not_launched | \
		worker_sensitive_temp_preflight_failed | worker_ownership_lost | worker_ledger_ready_failed | \
		worker_claim_ready_transition_failed | signal_terminated_continue | watchdog_stall_killed)
		printf '%s\n' "$_HRFF_RETRY_CLASS_INFRASTRUCTURE"
		;;
	permission_required | awaiting_maintainer_permission | worker_signing_unavailable)
		printf '%s\n' "$_HRFF_RETRY_CLASS_MAINTAINER_GATE"
		;;
	worker_complete | worker_draft_checkpoint | worker_merged_partial)
		printf '%s\n' "$_HRFF_RETRY_CLASS_REMEDIATION"
		;;
	clean)
		# Process success without a typed terminal outcome is not remediation proof.
		printf '%s\n' "$_HRFF_RETRY_CLASS_UNKNOWN"
		;;
	*)
		if [[ "$session_count" =~ ^[1-9][0-9]*$ ]]; then
			printf '%s\n' "$_HRFF_RETRY_CLASS_REMEDIATION"
		else
			printf '%s\n' "$_HRFF_RETRY_CLASS_UNKNOWN"
		fi
		;;
	esac
	return 0
}

#######################################
# Count attempt-local model activity for the external outcome contract. The
# function and outcome field retain their historical session_count names for
# compatibility. Unavailable evidence conservatively emits 0.
#######################################
_hrff_worker_session_count() {
	local start_epoch_ms="${_WORKER_START_EPOCH_MS:-0}"
	local persisted_session_id="${_WORKER_PERSISTED_SESSION_ID:-}"
	local count="0"
	count=$(_hrff_resolved_attempt_activity_count "$start_epoch_ms" "$persisted_session_id") || count="0"
	[[ "$count" =~ ^[0-9]+$ ]] || count="0"
	printf '%s\n' "$count"
	return 0
}

#######################################
# Persist a caller-requested terminal outcome for local recovery loops.
# The path must be absolute and its parent must already exist.
# Args: $1=session, $2=reason, $3=session count, $4=retry class (optional)
#######################################
_hrff_write_external_outcome() {
	local session_key="$1"
	local reason="$2"
	local session_count="$3"
	local retry_class="${4:-}"
	local outcome_file="${_WORKER_EXTERNAL_OUTCOME_FILE:-}"
	local outcome_id="${_WORKER_EXTERNAL_OUTCOME_ID:-}"
	local outcome_dir="" tmp_file="" finished_at=""

	[[ -n "$outcome_file" && "$outcome_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 0
	case "$outcome_file" in
	/*) ;;
	*) return 1 ;;
	esac
	outcome_dir="${outcome_file%/*}"
	[[ -d "$outcome_dir" && ! -L "$outcome_dir" && -O "$outcome_dir" && ! -L "$outcome_file" ]] || return 1
	reason="${reason//$'\r'/_}"
	reason="${reason//$'\n'/_}"
	reason="${reason//=/_}"
	session_key="${session_key//$'\r'/_}"
	session_key="${session_key//$'\n'/_}"
	session_key="${session_key//=/_}"
	[[ "$session_count" =~ ^[0-9]+$ ]] || session_count=0
	if [[ -z "$retry_class" ]]; then
		retry_class=$(_hrff_retry_class_for_reason "$reason" "$session_count")
	fi
	case "$retry_class" in
	"$_HRFF_RETRY_CLASS_INFRASTRUCTURE" | "$_HRFF_RETRY_CLASS_MAINTAINER_GATE" | \
		"$_HRFF_RETRY_CLASS_REMEDIATION" | "$_HRFF_RETRY_CLASS_UNKNOWN") ;;
	*) retry_class="$_HRFF_RETRY_CLASS_UNKNOWN" ;;
	esac
	finished_at="$(date +%s)"
	tmp_file=$(mktemp "${outcome_file}.tmp.XXXXXX") || return 1
	[[ -f "$tmp_file" && ! -L "$tmp_file" && -O "$tmp_file" ]] || {
		rm -f "$tmp_file" 2>/dev/null || true
		return 1
	}
	if ! {
		printf 'session_key=%s\n' "$session_key"
		printf 'outcome_id=%s\n' "$outcome_id"
		printf 'reason=%s\n' "$reason"
		printf 'session_count=%s\n' "$session_count"
		printf 'retry_class=%s\n' "$retry_class"
		printf 'finished_at=%s\n' "$finished_at"
	} >"$tmp_file"; then
		rm -f "$tmp_file" 2>/dev/null || true
		return 1
	fi
	if ! mv -f "$tmp_file" "$outcome_file"; then
		rm -f "$tmp_file" 2>/dev/null || true
		return 1
	fi
	_WORKER_EXTERNAL_OUTCOME_WRITTEN=1
	return 0
}

#######################################
# Archive dirty worktree changes as a local binary patch.
# Best-effort fallback when exit-time commit/push cannot preserve the work.
#
# Args:
#   $1 = worktree path
#   $2 = branch name
# Globals updated:
#   _WORKER_DIRTY_WORK_PRESERVED — set to 1 when an archive is written
#######################################
_worker_archive_dirty_worktree_patch() {
	local work_dir="$1"
	local branch_name="$2"
	local archive_root="${AIDEVOPS_WORKER_DIRTY_ARCHIVE_DIR:-${HOME}/.aidevops/.agent-workspace/work/dirty-worktrees}"
	local safe_branch="${branch_name//[^A-Za-z0-9._-]/_}"
	local stamp=""
	stamp=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || printf '%s' "unknown-time")
	local archive_dir="${archive_root}/${safe_branch}-${stamp}"

	mkdir -p "$archive_dir" 2>/dev/null || return 0
	git -C "$work_dir" status --short --branch -- . \
		"$_HRFF_DEFERRED_CLEANUP_EXCLUDE_PATHSPEC" >"${archive_dir}/status.txt" 2>/dev/null || true
	if git -C "$work_dir" diff --binary --cached -- . \
		"$_HRFF_DEFERRED_CLEANUP_EXCLUDE_PATHSPEC" >"${archive_dir}/changes.patch" 2>/dev/null \
		&& [[ -s "${archive_dir}/changes.patch" ]]; then
		_WORKER_DIRTY_WORK_PRESERVED=1
		print_warning "[lifecycle] worker_dirty_work_preserved archive=${archive_dir}"
		return 0
	fi
	if git -C "$work_dir" diff --binary -- . \
		"$_HRFF_DEFERRED_CLEANUP_EXCLUDE_PATHSPEC" >"${archive_dir}/changes.patch" 2>/dev/null \
		&& [[ -s "${archive_dir}/changes.patch" ]]; then
		_WORKER_DIRTY_WORK_PRESERVED=1
		print_warning "[lifecycle] worker_dirty_work_preserved archive=${archive_dir}"
		return 0
	fi
	return 0
}

#######################################
# GH#34040: Write a verified git bundle of commits not reachable from any
# origin remote-tracking ref, beside the dirty-worktree archives.
# Args: $1=worktree path, $2=branch name (may be empty when detached)
# Outputs: bundle path on stdout
# Returns: 0 only when the bundle exists and `git bundle verify` passes
#######################################
_worker_write_recovery_bundle() {
	local work_dir="$1"
	local branch_name="$2"
	local archive_root="${AIDEVOPS_WORKER_DIRTY_ARCHIVE_DIR:-${HOME}/.aidevops/.agent-workspace/work/dirty-worktrees}"
	local safe_branch="${branch_name//[^A-Za-z0-9._-]/_}"
	local stamp=""
	stamp=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || printf '%s' "unknown-time")
	local archive_dir="${archive_root}/${safe_branch:-detached}-${stamp}"
	local bundle_file="${archive_dir}/commits.bundle"
	local bundle_ref="HEAD"
	case "$branch_name" in
	"" | HEAD) ;;
	*) bundle_ref="refs/heads/${branch_name}" ;;
	esac

	mkdir -p "$archive_dir" 2>/dev/null || return 1
	git -C "$work_dir" bundle create "$bundle_file" "$bundle_ref" --not --remotes=origin \
		>/dev/null 2>&1 || return 1
	git -C "$work_dir" bundle verify "$bundle_file" >/dev/null 2>&1 || return 1
	git -C "$work_dir" rev-parse HEAD >"${archive_dir}/head.txt" 2>/dev/null || true
	printf '%s\n' "$bundle_file"
	return 0
}

#######################################
# GH#34040: Prove committed worker work is durable before a blocked handoff
# claims preservation. Push the branch; on failure write a verified recovery
# bundle. Never reports preservation without one of those proofs.
# Args: $1=worktree path
# Globals updated:
#   _WORKER_COMMIT_DURABILITY — none | pushed:<branch> | bundle:<path> | work_lost
# Returns: 0 when commits are absent or durable, 1 when work is lost
#######################################
_worker_secure_branch_commits() {
	local work_dir="$1"
	local branch_name="" unpushed="" bundle_file=""
	_WORKER_COMMIT_DURABILITY="work_lost"
	if [[ -z "$work_dir" || ! -d "$work_dir" ]]; then
		_WORKER_COMMIT_DURABILITY="none"
		return 0
	fi
	branch_name=$(git -C "$work_dir" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch_name=""
	unpushed=$(git -C "$work_dir" rev-list --count HEAD --not --remotes=origin 2>/dev/null) || unpushed=""
	if [[ "$unpushed" == "0" ]]; then
		_WORKER_COMMIT_DURABILITY="none"
		return 0
	fi
	case "$branch_name" in
	"" | main | master) ;;
	*)
		if git -C "$work_dir" push -u origin "$branch_name" >/dev/null 2>&1; then
			_WORKER_COMMIT_DURABILITY="pushed:${branch_name}"
			print_info "[lifecycle] worker_commits_pushed branch=${branch_name} unpushed=${unpushed:-unknown}"
			return 0
		fi
		print_warning "[lifecycle] worker_commits_push_failed branch=${branch_name} unpushed=${unpushed:-unknown}"
		;;
	esac
	if bundle_file=$(_worker_write_recovery_bundle "$work_dir" "$branch_name"); then
		_WORKER_COMMIT_DURABILITY="bundle:${bundle_file}"
		print_warning "[lifecycle] worker_commits_bundled branch=${branch_name:-detached} bundle=${bundle_file}"
		return 0
	fi
	print_warning "[lifecycle] work_lost branch=${branch_name:-detached} unpushed=${unpushed:-unknown} — push and recovery bundle both failed"
	return 1
}

#######################################
# Record evidenced startup and deterministic launch failures in the local runner-health
# breaker before releasing the shared issue claim. This path is fail-open:
# missing or broken health tooling must never strand the issue claim.
# Globals read: _HRW_PRIOR_ATTEMPT_ACTIVITY (set by the attempt loop)
# Args: $1=session key, $2=terminal reason
#######################################
_hrff_record_runner_health_failure() {
	local session_key="$1"
	local reason="$2"
	case "$reason" in
	worker_signing_unavailable)
		# GH#37597: an earlier attempt in this process already ran with
		# activity, so a continuation's preflight failure does not prove the
		# runner cannot sign. Record it audit-only instead of tripping at 1.
		if [[ "${_HRW_PRIOR_ATTEMPT_ACTIVITY:-0}" == "1" ]]; then
			reason="worker_signing_unavailable_after_activity"
		fi
		;;
	crash_during_startup | worker_noop_zero_output) reason="no_worker_process" ;;
	*) return 0 ;;
	esac

	local helper="${_HRFF_RUNNER_HEALTH_HELPER_OVERRIDE:-${BASH_SOURCE[0]%/*}/pulse-runner-health-helper.sh}"
	local issue_number=""
	local issue_id="$session_key"
	issue_number=$(_hrff_release_issue_number "$session_key")
	local repo_slug="${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}"
	if [[ -n "$repo_slug" && -n "$issue_number" ]]; then
		issue_id="${repo_slug}#${issue_number}"
	fi

	if [[ ! -x "$helper" ]]; then
		print_warning "[exit-trap] runner-health helper unavailable; continuing claim release for session=${session_key}"
		return 0
	fi
	if ! "$helper" record-outcome "$reason" "$issue_id"; then
		print_warning "[exit-trap] runner-health recording failed; continuing claim release for session=${session_key}"
	fi
	return 0
}

#######################################
# Fill the canonical metric gap when an EXIT trap bypasses normal result handling.
# Preserve the observed process status; the result/reason describe task outcome.
# Args: $1=session, $2=reason, $3=exit status, $4=activity count
#######################################
_hrff_record_exit_metric() {
	local session_key="$1"
	local reason="$2"
	local exit_status="$3"
	local session_count="$4"
	local metric_key="${AIDEVOPS_RUN_ID:-${_WORKER_START_EPOCH_MS:-0}}:${session_key}"
	[[ "${_HEADLESS_RUNTIME_LAST_METRIC_KEY:-}" != "$metric_key" ]] || return 0
	declare -F append_runtime_metric >/dev/null 2>&1 || return 0

	local model="${AIDEVOPS_ROUTING_MODEL:-unknown}"
	local result="${_HRW_TELEMETRY_FAILED:-failed}" activity=0 duration_ms=0 end_ms=0
	local start_ms="${_WORKER_START_EPOCH_MS:-0}"
	case "$reason" in
	"${_HRW_REASON_WORKER_COMPLETE:-worker_complete}") result="success" ;;
	"${_HRW_REASON_DRAFT_CHECKPOINT:-worker_draft_checkpoint}") result="deferred" ;;
	esac
	[[ "$session_count" =~ ^[1-9][0-9]*$ ]] && activity=1
	# GH#37597: name the failing signing preflight stage (configure, prepare,
	# heal) and probe kind so the next occurrence is diagnosable from metrics.
	local launch_failure_cause=""
	if [[ "$reason" == "worker_signing_unavailable" ]]; then
		launch_failure_cause="${_WORKER_SIGNING_FAILURE_DETAIL:-}"
	fi
	end_ms=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null) || end_ms=0
	if [[ "$start_ms" =~ ^[0-9]+$ && "$end_ms" =~ ^[0-9]+$ ]] &&
		((start_ms > 0 && end_ms >= start_ms)); then
		duration_ms=$((end_ms - start_ms))
	fi
	if ! append_runtime_metric "worker" "$session_key" "$model" "${model%%/*}" \
		"$result" "$exit_status" "$reason" "$activity" "$duration_ms" \
		"${WORKER_ISSUE_NUMBER:-}" "${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}" \
		"${_WORKER_WORKTREE_PATH:-}" "" "${_WORKER_PERSISTED_SESSION_ID:-}" \
		"" "" "" "exit_trap" "" "$launch_failure_cause" || [[ "${_HEADLESS_RUNTIME_LAST_METRIC_KEY:-}" != "$metric_key" ]]; then
		print_warning "[exit-trap] metric recording failed; continuing terminal handoff for session=${session_key}"
	fi
	return 0
}

#######################################
# Finalize an EXIT-trap classification: preserve work, emit terminal evidence,
# release the claim/lock, and force a non-zero process exit when preparation
# ended cleanly before runtime invocation.
# Args: $1=session, $2=reason, $3=exit status, $4=session count, $5=force nonzero
#######################################
_hrff_finalize_exit_trap() {
	local session_key="$1"
	local reason="$2"
	local exit_status="$3"
	local session_count="$4"
	local force_nonzero_exit="$5"
	local checkpoint_reason="${_HRW_REASON_DRAFT_CHECKPOINT:-worker_draft_checkpoint}"
	local claim_release_handled=0
	local last_stage="${_WORKER_PRELAUNCH_LAST_STAGE:-}"
	local last_completed_stage="${_WORKER_PRELAUNCH_LAST_COMPLETED_STAGE:-}"

	if declare -F worker_attempt_observability_last_stage >/dev/null 2>&1; then
		last_stage=$(worker_attempt_observability_last_stage) || last_stage=""
		last_completed_stage=$(worker_attempt_observability_last_completed_stage) || last_completed_stage=""
		last_stage="${last_stage:-${_WORKER_PRELAUNCH_LAST_STAGE:-}}"
		last_completed_stage="${last_completed_stage:-${_WORKER_PRELAUNCH_LAST_COMPLETED_STAGE:-}}"
	fi
	_push_wip_commits_on_exit
	if [[ "${_WORKER_DIRTY_WORK_PRESERVED:-0}" == "1" ]]; then
		if _recover_dirty_worker_pr "$session_key"; then
			if declare -F _escalate_worker_pr_checkpoint >/dev/null 2>&1; then
				_escalate_worker_pr_checkpoint "$session_key" "${DISPATCH_REPO_SLUG:-}" "draft_checkpoint"
				reason="${_HRW_RECOVERY_CLASSIFICATION:-worker_draft_checkpoint_escalation_failed}"
			else
				reason="worker_draft_checkpoint_escalation_failed"
				print_warning "[exit-trap] checkpoint escalation helper unavailable; retaining claim for session=${session_key}"
			fi
			claim_release_handled=1
		else
			reason="worker_dirty_work_preserved"
		fi
	fi
	# Status zero is process evidence, not proof of a completed task or handoff.
	# Dirty-work recovery above may supply an authoritative checkpoint instead.
	[[ "$reason" != "clean" ]] || reason="worker_incomplete_exit"
	print_info "[exit-trap] session=$session_key exit=$exit_status reason=$reason session_count=$session_count last_stage=${last_stage:-unknown} last_completed_stage=${last_completed_stage:-unknown}"
	_hrff_record_exit_metric "$session_key" "$reason" "$exit_status" "$session_count"
	if ! _hrff_write_external_outcome "$session_key" "$reason" "$session_count"; then
		print_warning "[exit-trap] failed to persist external outcome for session=${session_key}"
	fi
	if declare -F _emit_worker_runtime_event >/dev/null 2>&1; then
		if [[ "$reason" == "worker_complete" ]]; then
			_emit_worker_runtime_event "worker.completed" "recovered" "$reason"
		elif [[ "$reason" == "$checkpoint_reason" ]]; then
			_emit_worker_runtime_event "worker.deferred" "checkpointed" "$reason"
		else
			_emit_worker_runtime_event "worker.failed" "failed" "$reason"
		fi
	fi
	if declare -F _hrw_record_terminal_outcome >/dev/null 2>&1; then
		local terminal_outcome="failed"
		local complete_reason="${_HRW_REASON_WORKER_COMPLETE:-worker_complete}"
		[[ "$reason" == "$complete_reason" ]] && terminal_outcome="success"
		[[ "$reason" == "$checkpoint_reason" ]] && terminal_outcome="deferred"
		_hrw_record_terminal_outcome "$session_key" "$terminal_outcome" "$reason"
	fi
	if declare -F _cleanup_headless_runtime_temp_paths >/dev/null 2>&1; then
		_cleanup_headless_runtime_temp_paths
	fi
	_hrff_record_runner_health_failure "$session_key" "$reason"
	if [[ "$claim_release_handled" -eq 0 ]] && \
		! _release_dispatch_claim "$session_key" "$reason" "$exit_status" "$session_count"; then
		print_warning "[exit-trap] claim release persistence remains retryable for session=${session_key} reason=${reason}"
	fi
	_release_session_lock "$session_key"
	_update_dispatch_ledger "$session_key" "fail"
	aidevops_runtime_bundle_lease_release || print_warning "Failed to release the worker runtime bundle lease"
	if [[ "$force_nonzero_exit" -eq 1 ]]; then
		trap - EXIT
		exit "$exit_status"
	fi
	return 0
}

#######################################
# Resolve the active or most recently completed invocation sentinel base path.
# Finalization clears the active pointer before a later EXIT trap can classify
# the durable outcome.
# Stdout: sentinel base path, possibly empty.
#######################################
_hrff_durable_exit_code_file() {
	local active_path="${_WORKER_EXIT_CODE_FILE:-}"
	local completed_path="${_WORKER_LAST_EXIT_CODE_FILE:-}"
	printf '%s' "${active_path:-$completed_path}"
	return 0
}

#######################################
# Classify worker termination and post CLAIM_RELEASED. Falls back to
# process_exit when runtime/session evidence cannot identify the cause.
# Args: $1=session_key (baked into the EXIT trap at registration time)
# Globals: _WORKER_START_EPOCH_MS, _WORKER_ISOLATED_DB_PATH,
# _WORKER_WORKTREE_PATH, _WORKER_EXIT_CODE_FILE, _WORKER_RUNTIME_LAUNCH_STARTED
#######################################
_exit_trap_handler() {
	# Capture exit status immediately — any subsequent command will overwrite $?
	local exit_status=$?
	local session_key="$1"

	# t3050: prefer the worker's actual wait_status (persisted by _invoke_opencode
	# at ${exit_code_file}.wait_status) over $?. By the time EXIT fires, the
	# wrapper functions have cleanly returned 0 even when the worker subshell
	# was SIGTERM'd. Without this override, classify_worker_exit reads $?=0
	# from the trap and emits reason=clean for SIGTERM/SIGKILL kills (canonical
	# failure: GH#21707 — 6+ workers all reported reason=clean session_count=0
	# despite wait_status=143).
	local _durable_exit_code_file=""
	_durable_exit_code_file=$(_hrff_durable_exit_code_file)
	local _wait_file="${_durable_exit_code_file}.wait_status"
	if [[ -n "$_durable_exit_code_file" && -f "$_wait_file" ]]; then
		local _w=""
		_w=$(<"$_wait_file") || _w=""
		# Trim CR/LF/whitespace (bash 3.2 compatible).
		_w="${_w//$'\r'/}"
		_w="${_w//$'\n'/}"
		_w="${_w#"${_w%%[![:space:]]*}"}"
		_w="${_w%"${_w##*[![:space:]]}"}"
		if [[ "$_w" =~ ^[0-9]+$ && "$_w" -gt 0 ]]; then
			exit_status="$_w"
		fi
		rm -f "$_wait_file" 2>/dev/null || true
	fi

	local reason="$_HRFF_FALLBACK_EXIT"
	local session_count=0
	local ledger_terminal_reason=""
	local force_nonzero_exit=0
	local last_stage="${_WORKER_PRELAUNCH_LAST_STAGE:-}"
	local last_completed_stage="${_WORKER_PRELAUNCH_LAST_COMPLETED_STAGE:-}"
	if [[ -x "${DISPATCH_LEDGER_HELPER:-}" && -n "${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}" ]]; then
		ledger_terminal_reason=$("$DISPATCH_LEDGER_HELPER" terminal-reason --session-key "$session_key" \
			--lease-token "$AIDEVOPS_DISPATCH_LEASE_TOKEN" 2>/dev/null) || ledger_terminal_reason=""
	fi
	if [[ "${_WORKER_RUNTIME_LAUNCH_STARTED:-0}" != "1" ]]; then
		reason="${_WORKER_PRELAUNCH_FAILURE_REASON:-$_HRFF_PRELAUNCH_NOT_INVOKED}"
		if declare -F worker_attempt_observability_last_stage >/dev/null 2>&1; then
			last_stage=$(worker_attempt_observability_last_stage) || last_stage=""
			last_completed_stage=$(worker_attempt_observability_last_completed_stage) || last_completed_stage=""
			last_stage="${last_stage:-${_WORKER_PRELAUNCH_LAST_STAGE:-}}"
			last_completed_stage="${last_completed_stage:-${_WORKER_PRELAUNCH_LAST_COMPLETED_STAGE:-}}"
		fi
		_hrff_log_prelaunch_abort "$session_key" "$reason"
		print_warning "[exit-trap] runtime invocation never started after worker preparation; reason=${reason} last_stage=${last_stage:-unknown} last_completed_stage=${last_completed_stage:-unknown}"
		if [[ ! "$exit_status" =~ ^[1-9][0-9]*$ ]]; then
			exit_status=1
			force_nonzero_exit=1
		fi
	elif [[ -n "$ledger_terminal_reason" ]]; then
		reason="$ledger_terminal_reason"
		print_info "[exit-trap] using dispatch ledger terminal reason: $reason"
	elif [[ -n "${_WORKER_PRELAUNCH_FAILURE_REASON:-}" ]]; then
		reason="$_WORKER_PRELAUNCH_FAILURE_REASON"
		print_info "[exit-trap] using prelaunch failure reason: $reason"
	else
		if declare -F classify_worker_exit >/dev/null 2>&1; then
			local _start_ms="${_WORKER_START_EPOCH_MS:-0}"
			local _classified=""
			_classified=$(classify_worker_exit "$exit_status" "$_start_ms" \
				"${_WORKER_PERSISTED_SESSION_ID:-}" "$_durable_exit_code_file" 2>/dev/null) || true
			if [[ -n "$_classified" ]]; then
				reason="$_classified"
			else
				print_warning "[exit-trap] classify_worker_exit returned empty — using process_exit fallback"
			fi

			# Re-read session count for the enriched comment (best-effort)
			local _cnt=""
			_cnt=$(_hrff_resolved_attempt_activity_count "$_start_ms" "${_WORKER_PERSISTED_SESSION_ID:-}") || _cnt=""
			[[ "$_cnt" =~ ^[0-9]+$ ]] && session_count="$_cnt"
		else
			print_warning "[exit-trap] classify_worker_exit not available — using process_exit fallback"
		fi
	fi

	# t2923/GH#22965: Preserve WIP before releasing the claim so re-dispatch can
	# continue from the pushed branch instead of starting over. Dirty preserved
	# work is reported distinctly to avoid zero-output brief-rewrite holds.
	_hrff_finalize_exit_trap "$session_key" "$reason" "$exit_status" "$session_count" "$force_nonzero_exit"
	cleanup_headless_git_auth
	return 0
}

_recover_dirty_worker_pr() {
	local session_key="$1"
	local work_dir="${_WORKER_WORKTREE_PATH:-}"
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local branch_name=""

	[[ -n "$work_dir" && -d "$work_dir" && -n "$repo_slug" ]] || return 1
	# Local preservation without a known base must not publish or reuse a stale remote.
	[[ "${_WORKER_BASE_UNRESOLVED:-0}" == "1" ]] && return 1
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	case "$branch_name" in
	HEAD | main | master | "") return 1 ;;
	esac
	if declare -F _attempt_orphan_recovery_pr >/dev/null 2>&1; then
		_attempt_orphan_recovery_pr "$session_key" "$work_dir" "$branch_name" "$repo_slug" "draft"
		return $?
	fi
	return 1
}

_HRFF_FASTFAIL_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_HRFF_FASTFAIL_DIR" == "${BASH_SOURCE[0]}" ]] && _HRFF_FASTFAIL_DIR="."
# shellcheck source=headless-runtime-failure-fastfail.sh
source "${_HRFF_FASTFAIL_DIR}/headless-runtime-failure-fastfail.sh"
unset _HRFF_FASTFAIL_DIR
