#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# circuit-breaker-helper.sh - Supervisor circuit breaker (t1331)
#
# Standalone circuit breaker for the AI pulse supervisor. Tracks consecutive
# task failures globally. After N failures (default: 3, configurable via
# SUPERVISOR_CIRCUIT_BREAKER_THRESHOLD), pauses dispatch and creates/updates
# a GitHub issue with the `circuit-breaker` label.
#
# Manual reset: circuit-breaker-helper.sh reset
# Auto-reset: after configurable cooldown (SUPERVISOR_CIRCUIT_BREAKER_COOLDOWN_SECS)
# Counter resets on any task success.
#
# Supervisor-only — interactive sessions self-correct via user feedback.
# Inspired by Ouroboros circuit breaker pattern.
#
# Usage:
#   circuit-breaker-helper.sh check                    Check if dispatch is allowed (exit 0=yes, 1=no)
#   circuit-breaker-helper.sh status                   Show circuit breaker state
#   circuit-breaker-helper.sh record-failure <task> [reason]  Record a task failure
#   circuit-breaker-helper.sh record-success           Record a task success (resets counter)
#   circuit-breaker-helper.sh reset [reason]           Manually reset the circuit breaker
#   circuit-breaker-helper.sh trip [task] [reason]     Manually trip the breaker (for testing)
#   circuit-breaker-helper.sh help                     Show usage

set -euo pipefail

# Source shared-constants for gh_create_issue wrapper (t1756)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# ============================================================
# CONFIGURATION
# ============================================================

# Number of consecutive failures before tripping the circuit breaker
CIRCUIT_BREAKER_THRESHOLD="${SUPERVISOR_CIRCUIT_BREAKER_THRESHOLD:-3}"
# Validate numeric — strip non-digits, fallback to default if empty
CIRCUIT_BREAKER_THRESHOLD="${CIRCUIT_BREAKER_THRESHOLD//[!0-9]/}"
[[ -n "$CIRCUIT_BREAKER_THRESHOLD" ]] || CIRCUIT_BREAKER_THRESHOLD=3
if [[ "$CIRCUIT_BREAKER_THRESHOLD" -le 0 ]]; then
	CIRCUIT_BREAKER_THRESHOLD=3
fi

# Auto-reset cooldown in seconds (default: 30 minutes)
CIRCUIT_BREAKER_COOLDOWN_SECS="${SUPERVISOR_CIRCUIT_BREAKER_COOLDOWN_SECS:-1800}"
# Validate numeric — strip non-digits, fallback to default if empty
CIRCUIT_BREAKER_COOLDOWN_SECS="${CIRCUIT_BREAKER_COOLDOWN_SECS//[!0-9]/}"
[[ -n "$CIRCUIT_BREAKER_COOLDOWN_SECS" ]] || CIRCUIT_BREAKER_COOLDOWN_SECS=1800

# GitHub repo for issue creation (auto-detected from git remote if unset)
CB_REPO="${SUPERVISOR_CIRCUIT_BREAKER_REPO:-}"

# ============================================================
# COLOURS (stderr output)
# ============================================================
# Colour constants are provided by shared-constants.sh (RED, GREEN, YELLOW,
# BLUE, NC). Reassigning them here would fail with "readonly variable" when
# shared-constants.sh has already been sourced (GH#17477). Only declare
# them when shared-constants.sh was not available (no include guard set).

if [[ -z "${_SHARED_CONSTANTS_LOADED:-}" ]]; then
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	YELLOW='\033[1;33m'
	BLUE='\033[0;34m'
	NC='\033[0m'
fi

# ============================================================
# STATE FILE
# ============================================================

_cb_state_dir() {
	local dir="${SUPERVISOR_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor}"
	mkdir -p "$dir" || true
	echo "$dir"
	return 0
}

_cb_state_file() {
	echo "$(_cb_state_dir)/circuit-breaker.state"
	return 0
}

# ============================================================
# LOCK WRAPPER — serialise read-modify-write sequences
# ============================================================

CB_ACTIVE_LOCK_DIR=""

_cb_cleanup_active_lock() {
	local lock_dir="$CB_ACTIVE_LOCK_DIR"
	if [[ -n "$lock_dir" && -d "$lock_dir" ]]; then
		rmdir "$lock_dir" 2>/dev/null || true
	fi
	CB_ACTIVE_LOCK_DIR=""
	return 0
}

trap _cb_cleanup_active_lock EXIT

_cb_with_state_lock() {
	local lock_dir
	lock_dir="$(_cb_state_file).lock"
	local attempts=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		sleep 0.05
		attempts=$((attempts + 1))
		if [[ "$attempts" -gt 200 ]]; then
			echo -e "${YELLOW}[CIRCUIT-BREAKER]${NC} lock acquisition timed out after 10s" >&2
			return 1
		fi
	done
	CB_ACTIVE_LOCK_DIR="$lock_dir"
	local rc=0
	if "$@"; then
		rc=0
	else
		rc=$?
	fi
	if [[ "$CB_ACTIVE_LOCK_DIR" == "$lock_dir" ]]; then
		rmdir "$lock_dir" 2>/dev/null || true
		CB_ACTIVE_LOCK_DIR=""
	fi
	return "$rc"
}

# ============================================================
# HELPERS
# ============================================================

_cb_now_iso() {
	date -u +%Y-%m-%dT%H:%M:%SZ
	return 0
}

_cb_iso_to_epoch() {
	local ts="$1"
	local epoch=""
	# macOS date
	epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null) ||
		# GNU date
		epoch=$(date -u -d "$ts" '+%s' 2>/dev/null) ||
		epoch=""
	echo "$epoch"
	return 0
}

_cb_elapsed_since() {
	local ts="$1"
	local epoch
	epoch=$(_cb_iso_to_epoch "$ts")
	if [[ -z "$epoch" || "$epoch" == "0" ]]; then
		echo ""
		return 0
	fi
	local now_epoch
	now_epoch=$(date -u +%s) || now_epoch=0
	echo $((now_epoch - epoch))
	return 0
}

_cb_log_info() {
	echo -e "${BLUE}[CIRCUIT-BREAKER]${NC} $*" >&2
	return 0
}

_cb_log_warn() {
	echo -e "${YELLOW}[CIRCUIT-BREAKER]${NC} $*" >&2
	return 0
}

_cb_log_error() {
	echo -e "${RED}[CIRCUIT-BREAKER]${NC} $*" >&2
	return 0
}

_cb_log_success() {
	echo -e "${GREEN}[CIRCUIT-BREAKER]${NC} $*" >&2
	return 0
}

# ============================================================
# STATE READ/WRITE
# ============================================================

cb_read_state() {
	local state_file
	state_file=$(_cb_state_file)

	if [[ -f "$state_file" ]]; then
		local content
		content=$(cat "$state_file") || content=""
		if printf '%s' "$content" | jq empty; then
			echo "$content"
		else
			_cb_log_warn "corrupted state file, returning defaults"
			echo '{"consecutive_failures":0,"tripped":false,"tripped_at":"","last_failure_at":"","last_failure_task":"","last_failure_reason":"","last_reset_at":"","reset_reason":""}'
		fi
	else
		echo '{"consecutive_failures":0,"tripped":false,"tripped_at":"","last_failure_at":"","last_failure_task":"","last_failure_reason":"","last_reset_at":"","reset_reason":""}'
	fi
	return 0
}

cb_write_state() {
	local state_json="$1"
	local state_file
	state_file=$(_cb_state_file)

	# Atomic write via temp file + mv
	local tmp_file="${state_file}.tmp.$$"
	if ! printf '%s\n' "$state_json" >"$tmp_file"; then
		_cb_log_warn "failed to write temp state file: $tmp_file"
		rm -f "$tmp_file" || true
		return 1
	fi
	if ! mv -f "$tmp_file" "$state_file"; then
		_cb_log_warn "failed to move temp state to: $state_file"
		rm -f "$tmp_file" || true
		return 1
	fi
	return 0
}

# ============================================================
# CORE OPERATIONS
# ============================================================

cmd_record_failure() {
	_cb_with_state_lock _cmd_record_failure_impl "$@" || true
	return 0
}

_cmd_record_failure_impl() {
	local task_id="${1:-unknown}"
	local failure_reason="${2:-unknown}"

	local state
	state=$(cb_read_state) || {
		_cb_log_warn "failed to read state"
		return 0
	}

	local current_count tripped now
	current_count=$(printf '%s' "$state" | jq -r '.consecutive_failures // 0') || current_count=0
	tripped=$(printf '%s' "$state" | jq -r '.tripped // false') || tripped="false"
	now=$(_cb_now_iso)

	local new_count=$((current_count + 1))

	local new_state
	if [[ "$tripped" != "true" && "$new_count" -ge "$CIRCUIT_BREAKER_THRESHOLD" ]]; then
		# Trip the breaker
		new_state=$(printf '%s' "$state" | jq \
			--argjson count "$new_count" \
			--arg now "$now" \
			--arg task "$task_id" \
			--arg reason "$failure_reason" \
			'.consecutive_failures = $count | .last_failure_at = $now | .last_failure_task = $task | .last_failure_reason = $reason | .tripped = true | .tripped_at = $now') || {
			_cb_log_warn "failed to update state JSON"
			return 0
		}
		cb_write_state "$new_state" || return 0
		_cb_log_error "TRIPPED after $new_count consecutive failures (threshold: $CIRCUIT_BREAKER_THRESHOLD)"
		_cb_log_error "last failure: $task_id ($failure_reason)"
		_cb_log_error "dispatch is PAUSED. Reset with: circuit-breaker-helper.sh reset"

		# Create/update GitHub issue
		_cb_create_or_update_issue "$new_count" "$task_id" "$failure_reason" || true
	else
		# Update failure count only
		new_state=$(printf '%s' "$state" | jq \
			--argjson count "$new_count" \
			--arg now "$now" \
			--arg task "$task_id" \
			--arg reason "$failure_reason" \
			'.consecutive_failures = $count | .last_failure_at = $now | .last_failure_task = $task | .last_failure_reason = $reason') || {
			_cb_log_warn "failed to update state JSON"
			return 0
		}
		cb_write_state "$new_state" || return 0
		if [[ "$tripped" == "true" ]]; then
			_cb_log_warn "failure recorded ($new_count total) — breaker already tripped"
		else
			_cb_log_info "failure recorded ($new_count/$CIRCUIT_BREAKER_THRESHOLD consecutive)"
		fi
	fi

	return 0
}

cmd_record_success() {
	_cb_with_state_lock _cmd_record_success_impl || true
	return 0
}

_cmd_record_success_impl() {
	local state
	state=$(cb_read_state) || return 0

	local current_count was_tripped
	current_count=$(printf '%s' "$state" | jq -r '.consecutive_failures // 0') || current_count=0
	was_tripped=$(printf '%s' "$state" | jq -r '.tripped // false') || was_tripped="false"

	# Only write if there's something to reset
	if [[ "$current_count" -eq 0 && "$was_tripped" != "true" ]]; then
		return 0
	fi

	local now
	now=$(_cb_now_iso)

	local new_state
	new_state=$(printf '%s' "$state" | jq \
		--arg now "$now" \
		'.consecutive_failures = 0 | .tripped = false | .last_reset_at = $now | .reset_reason = "task_success"') || {
		return 0
	}

	cb_write_state "$new_state" || return 0

	if [[ "$was_tripped" == "true" ]]; then
		_cb_log_success "RESET by task success (was tripped with $current_count consecutive failures)"
		_cb_close_issue "Auto-reset: task completed successfully" || true
	elif [[ "$current_count" -gt 0 ]]; then
		_cb_log_info "counter reset to 0 (was $current_count)"
	fi

	return 0
}

cmd_check() {
	local state
	state=$(cb_read_state) || return 0

	local tripped
	tripped=$(printf '%s' "$state" | jq -r '.tripped // false') || tripped="false"

	if [[ "$tripped" != "true" ]]; then
		return 0
	fi

	# Check auto-reset cooldown
	local tripped_at
	tripped_at=$(printf '%s' "$state" | jq -r '.tripped_at // ""') || tripped_at=""

	if [[ -n "$tripped_at" && "$CIRCUIT_BREAKER_COOLDOWN_SECS" -gt 0 ]]; then
		local elapsed
		elapsed=$(_cb_elapsed_since "$tripped_at")

		# If timestamp parse failed, keep breaker open
		if [[ -z "$elapsed" ]]; then
			_cb_log_warn "TRIPPED — could not parse tripped_at timestamp, keeping breaker open"
			return 1
		fi

		if [[ "$elapsed" -ge "$CIRCUIT_BREAKER_COOLDOWN_SECS" ]]; then
			_cb_log_info "auto-reset after ${elapsed}s cooldown (threshold: ${CIRCUIT_BREAKER_COOLDOWN_SECS}s)"
			if cmd_reset "auto_cooldown"; then
				return 0
			fi
			_cb_log_warn "auto-reset failed; keeping breaker open"
			return 1
		fi

		local remaining=$((CIRCUIT_BREAKER_COOLDOWN_SECS - elapsed))
		_cb_log_warn "TRIPPED — dispatch paused (${remaining}s until auto-reset)"
	else
		_cb_log_warn "TRIPPED — dispatch paused (manual reset required)"
	fi

	return 1
}

cmd_reset() {
	local reason="${1:-manual_reset}"
	_cb_with_state_lock _cmd_reset_impl "$reason"
}

_cmd_reset_impl() {
	local reason="$1"

	local state
	state=$(cb_read_state) || {
		_cb_log_error "failed to read state for reset"
		return 1
	}

	local was_tripped prev_count
	was_tripped=$(printf '%s' "$state" | jq -r '.tripped // false') || was_tripped="false"
	prev_count=$(printf '%s' "$state" | jq -r '.consecutive_failures // 0') || prev_count=0

	local now
	now=$(_cb_now_iso)

	local new_state
	new_state=$(printf '%s' "$state" | jq \
		--arg now "$now" \
		--arg reason "$reason" \
		'.consecutive_failures = 0 | .tripped = false | .last_reset_at = $now | .reset_reason = $reason') || {
		_cb_log_error "failed to build reset state"
		return 1
	}

	cb_write_state "$new_state" || return 1

	if [[ "$was_tripped" == "true" ]]; then
		_cb_log_success "RESET ($reason) — dispatch resumed (was $prev_count consecutive failures)"
		_cb_close_issue "Reset: $reason" || true
	else
		_cb_log_info "reset ($reason) — counter cleared (was $prev_count)"
	fi

	return 0
}

cmd_status() {
	local state
	state=$(cb_read_state) || {
		echo "Circuit Breaker Status: unable to read state"
		return 0
	}

	local tripped count tripped_at last_failure last_failure_reason last_reset
	tripped=$(printf '%s' "$state" | jq -r '.tripped // false') || tripped="false"
	count=$(printf '%s' "$state" | jq -r '.consecutive_failures // 0') || count=0
	tripped_at=$(printf '%s' "$state" | jq -r 'if (.tripped_at // "") == "" then "never" else .tripped_at end') || tripped_at="never"
	last_failure=$(printf '%s' "$state" | jq -r 'if (.last_failure_task // "") == "" then "none" else .last_failure_task end') || last_failure="none"
	last_failure_reason=$(printf '%s' "$state" | jq -r 'if (.last_failure_reason // "") == "" then "none" else .last_failure_reason end') || last_failure_reason="none"
	last_reset=$(printf '%s' "$state" | jq -r 'if (.last_reset_at // "") == "" then "never" else .last_reset_at end') || last_reset="never"

	echo "Circuit Breaker Status"
	echo "======================"
	if [[ "$tripped" == "true" ]]; then
		echo -e "State:                ${RED}OPEN (dispatch paused)${NC}"
	else
		echo -e "State:                ${GREEN}CLOSED (dispatch active)${NC}"
	fi
	echo "Consecutive failures: $count / $CIRCUIT_BREAKER_THRESHOLD"
	echo "Tripped at:           $tripped_at"
	echo "Last failure task:    $last_failure"
	echo "Last failure reason:  $last_failure_reason"
	echo "Last reset:           $last_reset"
	echo "Threshold:            $CIRCUIT_BREAKER_THRESHOLD"
	echo "Cooldown:             ${CIRCUIT_BREAKER_COOLDOWN_SECS}s"

	# Show time until auto-reset if tripped
	if [[ "$tripped" == "true" && "$tripped_at" != "never" && "$CIRCUIT_BREAKER_COOLDOWN_SECS" -gt 0 ]]; then
		local elapsed
		elapsed=$(_cb_elapsed_since "$tripped_at")
		if [[ -n "$elapsed" ]]; then
			local remaining=$((CIRCUIT_BREAKER_COOLDOWN_SECS - elapsed))
			if [[ "$remaining" -gt 0 ]]; then
				echo "Auto-reset in:        ${remaining}s"
			else
				echo "Auto-reset in:        overdue (will reset on next check)"
			fi
		else
			echo "Auto-reset in:        unknown (could not parse tripped_at)"
		fi
	fi

	return 0
}

cmd_trip() {
	local task_id="${1:-manual}"
	local reason="${2:-manual_trip}"
	local now
	now=$(_cb_now_iso)
	local state
	state=$(jq -n \
		--argjson count "$CIRCUIT_BREAKER_THRESHOLD" \
		--arg now "$now" \
		--arg task "$task_id" \
		--arg reason "$reason" \
		'{consecutive_failures: $count, tripped: true, tripped_at: $now, last_failure_at: $now, last_failure_task: $task, last_failure_reason: $reason, last_reset_at: "", reset_reason: ""}') || {
		_cb_log_error "failed to build trip state JSON"
		return 1
	}
	cb_write_state "$state" || return 1
	_cb_log_warn "manually tripped (task: $task_id, reason: $reason)"
	_cb_create_or_update_issue "$CIRCUIT_BREAKER_THRESHOLD" "$task_id" "$reason" || true
	return 0
}

# ============================================================
# GITHUB ISSUE MANAGEMENT
# ============================================================

_cb_resolve_repo_slug() {
	if [[ -n "$CB_REPO" ]]; then
		echo "$CB_REPO"
		return 0
	fi
	local repo_slug
	repo_slug=$(gh repo view --json nameWithOwner -q '.nameWithOwner') || repo_slug=""
	echo "$repo_slug"
	return 0
}

# Check prerequisites for GitHub operations.
# Outputs repo_slug to stdout on success; returns 1 on failure.
_cb_check_github_prereqs() {
	if [[ "${CB_SKIP_GITHUB:-}" == "true" ]]; then
		_cb_log_info "GitHub issue creation skipped (CB_SKIP_GITHUB=true)"
		return 1
	fi

	if ! command -v gh &>/dev/null; then
		_cb_log_warn "gh CLI not found, skipping GitHub issue creation"
		return 1
	fi

	local repo_slug
	repo_slug=$(_cb_resolve_repo_slug)
	if [[ -z "$repo_slug" ]]; then
		_cb_log_warn "could not determine GitHub repository, skipping issue creation"
		return 1
	fi

	echo "$repo_slug"
	return 0
}

# Find the number of an existing open circuit-breaker issue, if any.
# Outputs the issue number to stdout (empty if none found).
_cb_find_open_issue() {
	local repo_slug="$1"
	local existing_issue
	existing_issue=$(gh issue list \
		--repo "$repo_slug" \
		--label "circuit-breaker" \
		--state open \
		--json number \
		--jq '.[0].number // empty') || existing_issue=""
	echo "$existing_issue"
	return 0
}

# Build the body text for a new circuit-breaker GitHub issue.
# Outputs the body string to stdout.
_cb_build_issue_body() {
	local failure_count="$1"
	local last_task_id="$2"
	local last_failure_reason="$3"
	local now="$4"

	printf '%s\n' "## Supervisor Circuit Breaker Tripped

**Time:** ${now}
**Consecutive failures:** ${failure_count}
**Threshold:** ${CIRCUIT_BREAKER_THRESHOLD}
**Last failed task:** ${last_task_id}
**Last failure reason:** ${last_failure_reason}

### Impact
Supervisor dispatch is **paused**. No new tasks will be dispatched until the circuit breaker is reset.

### Resolution
1. Investigate the recent failures (check worker logs)
2. Fix the underlying issue
3. Reset the circuit breaker (one-line copy/paste):
   \`\`\`bash
   aidevops circuit-breaker reset
   \`\`\`
   Or use the short alias: \`aidevops cb reset\`.
   Direct helper path (if \`aidevops\` CLI unavailable): \`circuit-breaker-helper.sh reset\`.
   Or wait for auto-reset after ${CIRCUIT_BREAKER_COOLDOWN_SECS}s cooldown.

### Recent failure context
- Task: \`${last_task_id}\`
- Reason: \`${last_failure_reason}\`
- Threshold: ${CIRCUIT_BREAKER_THRESHOLD} consecutive failures

---
*Auto-generated by supervisor circuit breaker (t1331)*"
	return 0
}

# Post a re-trip comment on an existing open circuit-breaker issue.
_cb_update_existing_issue() {
	local repo_slug="$1"
	local existing_issue="$2"
	local failure_count="$3"
	local last_task_id="$4"
	local last_failure_reason="$5"
	local now="$6"

	gh_issue_comment "$existing_issue" \
		--repo "$repo_slug" \
		--body "### Circuit breaker re-tripped at ${now}

- Consecutive failures: ${failure_count}
- Last failed task: \`${last_task_id}\`
- Reason: \`${last_failure_reason}\`" || {
		_cb_log_warn "failed to comment on issue #$existing_issue"
		return 1
	}
	_cb_log_info "updated GitHub issue #$existing_issue"
	return 0
}

# Ensure circuit-breaker labels exist and create a new issue.
# Also files a sibling investigation task so each trip drives root-cause work
# instead of accumulating notification-only issues (t3208 / GH#21923).
_cb_create_new_issue() {
	local repo_slug="$1"
	local failure_count="$2"
	local body="$3"
	local last_task_id="${4:-unknown}"
	local last_failure_reason="${5:-unknown}"

	# Append signature footer
	local sig_footer=""
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer --body "$body" 2>/dev/null || true)
	body="${body}${sig_footer}"

	gh label create "circuit-breaker" \
		--repo "$repo_slug" \
		--description "Supervisor circuit breaker tripped — dispatch paused" \
		--color "D93F0B" \
		--force || true
	gh label create "source:circuit-breaker" \
		--repo "$repo_slug" \
		--description "Auto-created by circuit-breaker-helper.sh" \
		--color "C2E0C6" \
		--force || true

	local issue_url
	issue_url=$(gh_create_issue \
		--repo "$repo_slug" \
		--title "Supervisor circuit breaker tripped — ${failure_count} consecutive failures" \
		--body "$body" \
		--label "circuit-breaker" --label "source:circuit-breaker") || {
		_cb_log_warn "failed to create GitHub issue"
		return 1
	}
	_cb_log_info "created GitHub issue: $issue_url"

	# File sibling investigation task. Best-effort — failure here must not
	# bubble up because the trip notification has already succeeded and the
	# investigation task is a follow-up convenience, not a correctness gate.
	local trip_issue_num="${issue_url##*/}"
	if [[ "$trip_issue_num" =~ ^[0-9]+$ ]]; then
		_cb_file_investigation_task \
			"$repo_slug" "$trip_issue_num" \
			"$failure_count" "$last_task_id" "$last_failure_reason" || true
	else
		_cb_log_warn "could not parse trip issue number from URL: $issue_url"
	fi
	return 0
}

# Build the body of the sibling investigation task that asks the next worker
# to root-cause a circuit-breaker trip rather than just acknowledge it.
# Args:
#   $1 trip_issue_num
#   $2 failure_count
#   $3 last_task_id
#   $4 last_failure_reason
# Outputs: body string on stdout
_cb_build_investigation_body() {
	local trip_issue_num="$1"
	local failure_count="$2"
	local last_task_id="$3"
	local last_failure_reason="$4"
	local threshold="${CIRCUIT_BREAKER_THRESHOLD:-3}"

	printf '%s\n' "## What

Investigate the root cause of supervisor circuit-breaker trip Ref #${trip_issue_num} — ${failure_count} consecutive worker failures, last reason \`${last_failure_reason}\` on task \`${last_task_id}\`. Either:

1. File ≥1 concrete fix task referencing this trip (\`Ref #${trip_issue_num}\`), OR
2. Close trip notification #${trip_issue_num} as transient with evidence (canary now passing, prior recurrences absent in last 7 days).

## Why

\`circuit-breaker-helper.sh::_cb_create_new_issue\` historically created a notification-only issue. Trip after trip, the same underlying failure recurred without driving any automated investigation. The breaker pauses dispatch (good) but did not feed root-cause analysis (gap). Six prior trips were closed without root-cause fix: marcusquinn/aidevops#21919, #21556, #4360, #4318, #2293, #2292. This sibling investigation task closes that loop (t3208).

## How

### Last failure context

- **Trip notification:** Ref #${trip_issue_num}
- **Last failed task:** \`${last_task_id}\`
- **Last failure reason:** \`${last_failure_reason}\`
- **Consecutive failures:** ${failure_count}
- **Threshold:** ${threshold}

### Logs to inspect

- \`~/.aidevops/logs/pulse-wrapper.log\` — pulse-side dispatch trace; grep for the failed task ID and surrounding cycle.
- \`~/.aidevops/logs/headless-runtime-metrics.jsonl\` — per-worker outcome ledger; filter \`select(.session_key | contains(\"${last_task_id}\"))\` for terminal events.
- \`~/.aidevops/.agent-workspace/tmp/pulse/pulse-<repo>-<task>.log\` (or \`$XDG_RUNTIME_DIR/aidevops/pulse/\`) — per-worker stdout/stderr if still on disk.
- \`~/.aidevops/.agent-workspace/headless-runtime/canary-last-fail*\` — canary failure artifacts when the canary itself is the live blocker.
- \`~/.aidevops/logs/dispatch-stages.tsv\` — dispatch-stage timing; recent rows show how far each spawn got before failing.

### Failure-reason hypotheses

Common \`last_failure_reason\` values and their typical root causes:

- \`no_worker_process\` / \`canary_failed\` — runtime/credential/SDK drift; check canary artifacts and ANTHROPIC_API_KEY resolution.
- \`cli_usage_output\` — opencode/claude CLI flag drift after auto-update; check stderr for unrecognised flag names.
- \`watchdog_stall_killed\` — model context exhaustion or infinite tool loop; correlate with token counts in headless-runtime-metrics.
- \`rate_limit\` — GraphQL or REST 429s; check \`gh-api-calls.log\` for endpoint family pressure.
- \`worker_spawn_failed\` — environment / PATH / credentials issue at spawn; check pulse-wrapper.log for spawn trace.

### Files to modify

- Likely: depends on diagnosis. Probable surfaces: \`.agents/scripts/headless-runtime-helper.sh\`, \`.agents/scripts/headless-runtime-lib.sh\`, \`.agents/scripts/pulse-wrapper.sh\`, or whichever helper the failure trace points at.
- Verification target: rerun the failing scenario after fix; canary passes; no immediate re-trip.

### Acceptance

- [ ] Either: file ≥1 fix task with \`Ref #${trip_issue_num}\` linking back, OR close trip notification #${trip_issue_num} with \`> Premise: transient — <evidence>\` rationale.
- [ ] Trip-notification issue gets a comment summarising the investigation outcome (root cause, fix task numbers, or transient evidence).

### Tautology guard

If the worker investigation itself fails to spawn (the canary is the live blocker), the failure cascades and the existing \`dispatch-cooldown-until\` marker (t3197) prevents tight-loop retries — no special handling needed here.

---
*Auto-filed by circuit-breaker-helper.sh::_cb_file_investigation_task (t3208)*"
	return 0
}

# File a sibling investigation task linked to a circuit-breaker trip
# notification. Sibling (not child) by design: the trip notification is a
# record of what happened; the investigation task is the workhorse driving
# root-cause analysis. Best-effort — non-zero return here does not unwind
# the trip notification.
# Args:
#   $1 repo_slug
#   $2 trip_issue_num
#   $3 failure_count
#   $4 last_task_id
#   $5 last_failure_reason
# Returns: 0 on success or skip; 1 on hard failure of the gh call.
_cb_file_investigation_task() {
	local repo_slug="$1"
	local trip_issue_num="$2"
	local failure_count="$3"
	local last_task_id="$4"
	local last_failure_reason="$5"

	# Operator escape hatch — symmetric with CB_SKIP_GITHUB but scoped to
	# the investigation-task path so a caller can keep the trip notification
	# while suppressing the follow-up if (e.g.) the investigation queue is
	# already saturated.
	if [[ "${CB_SKIP_INVESTIGATION_TASK:-}" == "true" ]]; then
		_cb_log_info "investigation task creation skipped (CB_SKIP_INVESTIGATION_TASK=true)"
		return 0
	fi

	# Ensure the source label exists before issue creation. Idempotent —
	# --force makes gh treat an existing label as a no-op.
	gh label create "source:circuit-breaker-investigation" \
		--repo "$repo_slug" \
		--description "Auto-filed root-cause investigation for circuit-breaker trip" \
		--color "FBCA04" \
		--force || true

	local body
	body=$(_cb_build_investigation_body \
		"$trip_issue_num" "$failure_count" \
		"$last_task_id" "$last_failure_reason")

	# Append signature footer to the investigation body. The gh wrapper also
	# auto-injects when invoked via PATH, but appending here keeps the body
	# self-contained for any caller path that bypasses the wrapper.
	local sig_footer=""
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer --body "$body" 2>/dev/null || true)
	body="${body}${sig_footer}"

	local title
	title="Investigate circuit-breaker trip #${trip_issue_num}: ${last_failure_reason} after ${failure_count} consecutive failures"

	local investigation_url
	investigation_url=$(gh_create_issue \
		--repo "$repo_slug" \
		--title "$title" \
		--body "$body" \
		--label "auto-dispatch" \
		--label "tier:thinking" \
		--label "bug" \
		--label "framework" \
		--label "source:circuit-breaker-investigation") || {
		_cb_log_warn "failed to file investigation task for trip #${trip_issue_num}"
		return 1
	}
	_cb_log_info "filed investigation task: $investigation_url"
	return 0
}

_cb_create_or_update_issue() {
	local failure_count="$1"
	local last_task_id="$2"
	local last_failure_reason="$3"

	local repo_slug
	repo_slug=$(_cb_check_github_prereqs) || return 0

	local existing_issue
	existing_issue=$(_cb_find_open_issue "$repo_slug")

	local now
	now=$(_cb_now_iso)

	if [[ -n "$existing_issue" ]]; then
		_cb_update_existing_issue \
			"$repo_slug" "$existing_issue" \
			"$failure_count" "$last_task_id" "$last_failure_reason" "$now" || return 1
	else
		local body
		body=$(_cb_build_issue_body "$failure_count" "$last_task_id" "$last_failure_reason" "$now")
		_cb_create_new_issue \
			"$repo_slug" "$failure_count" "$body" \
			"$last_task_id" "$last_failure_reason" || return 1
	fi

	return 0
}

_cb_close_issue() {
	local reason="$1"

	# Allow tests to skip GitHub operations
	if [[ "${CB_SKIP_GITHUB:-}" == "true" ]]; then
		return 0
	fi

	if ! command -v gh &>/dev/null; then
		return 1
	fi

	local repo_slug
	repo_slug=$(_cb_resolve_repo_slug)
	if [[ -z "$repo_slug" ]]; then
		return 1
	fi

	local existing_issue
	existing_issue=$(gh issue list \
		--repo "$repo_slug" \
		--label "circuit-breaker" \
		--state open \
		--json number \
		--jq '.[0].number // empty') || existing_issue=""

	if [[ -z "$existing_issue" ]]; then
		return 0
	fi

	gh issue close "$existing_issue" \
		--repo "$repo_slug" \
		--comment "Circuit breaker reset: ${reason}" || {
		_cb_log_warn "failed to close issue #$existing_issue"
		return 1
	}

	_cb_log_info "closed GitHub issue #$existing_issue ($reason)"
	return 0
}

# ============================================================
# CLI ENTRY POINT
# ============================================================

cmd_help() {
	echo "circuit-breaker-helper.sh — Supervisor circuit breaker (t1331)"
	echo ""
	echo "Preferred CLI (one-line copy/paste):"
	echo "  aidevops circuit-breaker [status|reset|check|trip]   (alias: cb)"
	echo ""
	echo "Direct helper usage:"
	echo "  circuit-breaker-helper.sh check                         Check if dispatch is allowed (exit 0=yes, 1=no)"
	echo "  circuit-breaker-helper.sh status                        Show circuit breaker state"
	echo "  circuit-breaker-helper.sh record-failure <task> [reason] Record a task failure"
	echo "  circuit-breaker-helper.sh record-success                Record a task success (resets counter)"
	echo "  circuit-breaker-helper.sh reset [reason]                Manually reset the circuit breaker"
	echo "  circuit-breaker-helper.sh trip [task] [reason]          Manually trip the breaker (for testing)"
	echo "  circuit-breaker-helper.sh help                          Show this help"
	echo ""
	echo "Configuration (env vars):"
	echo "  SUPERVISOR_CIRCUIT_BREAKER_THRESHOLD       Failures before trip (default: 3)"
	echo "  SUPERVISOR_CIRCUIT_BREAKER_COOLDOWN_SECS   Auto-reset cooldown (default: 1800 = 30min)"
	echo "  SUPERVISOR_CIRCUIT_BREAKER_REPO            GitHub repo slug for issue creation (auto-detected)"
	echo "  SUPERVISOR_DIR                             State directory (default: ~/.aidevops/.agent-workspace/supervisor)"
	return 0
}

main() {
	local action="${1:-help}"
	shift || true

	# Require jq for JSON state management
	if ! command -v jq &>/dev/null; then
		echo "Error: jq is required but not found in PATH" >&2
		return 1
	fi

	case "$action" in
	check)
		cmd_check
		;;
	status)
		cmd_status
		;;
	record-failure)
		cmd_record_failure "$@"
		;;
	record-success)
		cmd_record_success
		;;
	reset)
		cmd_reset "${1:-manual_reset}"
		;;
	trip)
		cmd_trip "${1:-manual}" "${2:-manual_trip}"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		echo "Unknown command: $action" >&2
		echo "Run 'circuit-breaker-helper.sh help' for usage." >&2
		return 1
		;;
	esac
}

main "$@"
