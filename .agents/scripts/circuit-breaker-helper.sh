#!/usr/bin/env bash
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

# ============================================================
# CONFIGURATION
# ============================================================

# Number of consecutive failures before tripping the circuit breaker
CIRCUIT_BREAKER_THRESHOLD="${SUPERVISOR_CIRCUIT_BREAKER_THRESHOLD:-3}"
# Validate numeric — strip non-digits, fallback to default if empty
CIRCUIT_BREAKER_THRESHOLD="${CIRCUIT_BREAKER_THRESHOLD//[!0-9]/}"
[[ -n "$CIRCUIT_BREAKER_THRESHOLD" ]] || CIRCUIT_BREAKER_THRESHOLD=3

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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================
# STATE FILE
# ============================================================

_cb_state_dir() {
	local dir="${SUPERVISOR_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor}"
	mkdir -p "$dir" 2>/dev/null || true
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
	# Trap ensures lock cleanup even if "$@" fails under set -e
	# shellcheck disable=SC2064
	trap "rmdir '$lock_dir' 2>/dev/null || true" RETURN
	"$@"
	local rc=$?
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
		content=$(cat "$state_file" 2>/dev/null) || content=""
		if printf '%s' "$content" | jq empty 2>/dev/null; then
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
	if ! printf '%s\n' "$state_json" >"$tmp_file" 2>/dev/null; then
		_cb_log_warn "failed to write temp state file: $tmp_file"
		rm -f "$tmp_file" 2>/dev/null || true
		return 1
	fi
	if ! mv -f "$tmp_file" "$state_file" 2>/dev/null; then
		_cb_log_warn "failed to move temp state to: $state_file"
		rm -f "$tmp_file" 2>/dev/null || true
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
			cmd_reset "auto_cooldown"
			return 0
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
	repo_slug=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) || repo_slug=""
	echo "$repo_slug"
	return 0
}

_cb_create_or_update_issue() {
	local failure_count="$1"
	local last_task_id="$2"
	local last_failure_reason="$3"

	# Allow tests to skip GitHub operations
	if [[ "${CB_SKIP_GITHUB:-}" == "true" ]]; then
		_cb_log_info "GitHub issue creation skipped (CB_SKIP_GITHUB=true)"
		return 0
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

	# Check for existing open circuit-breaker issue
	local existing_issue
	existing_issue=$(gh issue list \
		--repo "$repo_slug" \
		--label "circuit-breaker" \
		--state open \
		--json number \
		--jq '.[0].number // empty' 2>/dev/null) || existing_issue=""

	local now
	now=$(_cb_now_iso)

	local body
	body="## Supervisor Circuit Breaker Tripped

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
3. Reset the circuit breaker:
   \`\`\`bash
   circuit-breaker-helper.sh reset
   \`\`\`
   Or wait for auto-reset after ${CIRCUIT_BREAKER_COOLDOWN_SECS}s cooldown.

### Recent failure context
- Task: \`${last_task_id}\`
- Reason: \`${last_failure_reason}\`
- Threshold: ${CIRCUIT_BREAKER_THRESHOLD} consecutive failures

---
*Auto-generated by supervisor circuit breaker (t1331)*"

	if [[ -n "$existing_issue" ]]; then
		gh issue comment "$existing_issue" \
			--repo "$repo_slug" \
			--body "### Circuit breaker re-tripped at ${now}

- Consecutive failures: ${failure_count}
- Last failed task: \`${last_task_id}\`
- Reason: \`${last_failure_reason}\`" 2>/dev/null || {
			_cb_log_warn "failed to comment on issue #$existing_issue"
			return 1
		}
		_cb_log_info "updated GitHub issue #$existing_issue"
	else
		# Ensure the circuit-breaker label exists
		gh label create "circuit-breaker" \
			--repo "$repo_slug" \
			--description "Supervisor circuit breaker tripped — dispatch paused" \
			--color "D93F0B" \
			--force 2>/dev/null || true

		local issue_url
		issue_url=$(gh issue create \
			--repo "$repo_slug" \
			--title "Supervisor circuit breaker tripped — ${failure_count} consecutive failures" \
			--body "$body" \
			--label "circuit-breaker" 2>/dev/null) || {
			_cb_log_warn "failed to create GitHub issue"
			return 1
		}
		_cb_log_info "created GitHub issue: $issue_url"
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
		--jq '.[0].number // empty' 2>/dev/null) || existing_issue=""

	if [[ -z "$existing_issue" ]]; then
		return 0
	fi

	gh issue close "$existing_issue" \
		--repo "$repo_slug" \
		--comment "Circuit breaker reset: ${reason}" 2>/dev/null || {
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
	echo "Usage:"
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
