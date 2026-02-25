#!/usr/bin/env bash
# circuit-breaker.sh - Supervisor circuit breaker (t1331)
#
# Tracks consecutive task failures globally. After N failures (default: 3,
# configurable via SUPERVISOR_CIRCUIT_BREAKER_THRESHOLD), pauses dispatch
# and creates/updates a GitHub issue with the `circuit-breaker` label.
#
# Manual reset: supervisor-helper.sh circuit-breaker reset
# Auto-reset: after configurable cooldown (SUPERVISOR_CIRCUIT_BREAKER_COOLDOWN_SECS)
# Counter resets on any task success.
#
# Supervisor-only — interactive sessions self-correct.
# Inspired by Ouroboros circuit breaker pattern.

# ============================================================
# CONFIGURATION
# ============================================================

# Number of consecutive failures before tripping the circuit breaker
CIRCUIT_BREAKER_THRESHOLD="${SUPERVISOR_CIRCUIT_BREAKER_THRESHOLD:-3}"

# Auto-reset cooldown in seconds (default: 30 minutes)
CIRCUIT_BREAKER_COOLDOWN_SECS="${SUPERVISOR_CIRCUIT_BREAKER_COOLDOWN_SECS:-1800}"

# ============================================================
# STATE FILE
# ============================================================

_cb_state_file() {
	local dir="${SUPERVISOR_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor}"
	mkdir -p "$dir" 2>/dev/null || true
	echo "$dir/circuit-breaker.state"
	return 0
}

# ============================================================
# STATE READ/WRITE
# ============================================================

#######################################
# Read the current circuit breaker state
# Returns JSON on stdout: {consecutive_failures, tripped, tripped_at, last_failure_at, last_failure_task, last_reset_at}
# If no state file exists, returns defaults (closed circuit, 0 failures)
#######################################
cb_read_state() {
	local state_file
	state_file=$(_cb_state_file)

	if [[ -f "$state_file" ]]; then
		cat "$state_file"
	else
		echo '{"consecutive_failures":0,"tripped":false,"tripped_at":"","last_failure_at":"","last_failure_task":"","last_reset_at":""}'
	fi
	return 0
}

#######################################
# Write circuit breaker state atomically
# Args: $1 = JSON state string
#######################################
cb_write_state() {
	local state_json="$1"
	local state_file
	state_file=$(_cb_state_file)

	# Atomic write via temp file + mv
	local tmp_file="${state_file}.tmp.$$"
	printf '%s\n' "$state_json" >"$tmp_file"
	mv -f "$tmp_file" "$state_file"
	return 0
}

# ============================================================
# CORE OPERATIONS
# ============================================================

#######################################
# Record a task failure — increment consecutive failure counter
# If threshold is reached, trip the circuit breaker.
# Args: $1 = task_id, $2 = failure_reason (optional)
# Returns: 0 always (non-blocking — must not abort dispatch flow)
#######################################
cb_record_failure() {
	local task_id="$1"
	local failure_reason="${2:-unknown}"

	local state
	state=$(cb_read_state)

	local current_count
	current_count=$(printf '%s' "$state" | jq -r '.consecutive_failures // 0' 2>/dev/null || echo "0")

	local new_count=$((current_count + 1))
	local now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	local tripped
	tripped=$(printf '%s' "$state" | jq -r '.tripped // false' 2>/dev/null || echo "false")

	# Update state with new failure count
	local new_state
	new_state=$(printf '%s' "$state" | jq \
		--argjson count "$new_count" \
		--arg now "$now" \
		--arg task "$task_id" \
		--arg reason "$failure_reason" \
		'.consecutive_failures = $count | .last_failure_at = $now | .last_failure_task = $task | .last_failure_reason = $reason' \
		2>/dev/null)

	if [[ -z "$new_state" ]]; then
		log_warn "circuit-breaker: failed to update state JSON"
		return 0
	fi

	# Check if we should trip the breaker
	if [[ "$tripped" != "true" && "$new_count" -ge "$CIRCUIT_BREAKER_THRESHOLD" ]]; then
		new_state=$(printf '%s' "$new_state" | jq \
			--arg now "$now" \
			'.tripped = true | .tripped_at = $now' \
			2>/dev/null)
		cb_write_state "$new_state"
		log_error "circuit-breaker: TRIPPED after $new_count consecutive failures (threshold: $CIRCUIT_BREAKER_THRESHOLD)"
		log_error "circuit-breaker: last failure: $task_id ($failure_reason)"
		log_error "circuit-breaker: dispatch is PAUSED. Reset with: supervisor-helper.sh circuit-breaker reset"

		# Create/update GitHub issue
		_cb_create_or_update_issue "$new_count" "$task_id" "$failure_reason" || true
	else
		cb_write_state "$new_state"
		if [[ "$tripped" == "true" ]]; then
			log_warn "circuit-breaker: failure recorded ($new_count total) — breaker already tripped"
		else
			log_info "circuit-breaker: failure recorded ($new_count/$CIRCUIT_BREAKER_THRESHOLD consecutive)"
		fi
	fi

	return 0
}

#######################################
# Record a task success — reset consecutive failure counter
# Returns: 0 always
#######################################
cb_record_success() {
	local state
	state=$(cb_read_state)

	local current_count
	current_count=$(printf '%s' "$state" | jq -r '.consecutive_failures // 0' 2>/dev/null || echo "0")

	local was_tripped
	was_tripped=$(printf '%s' "$state" | jq -r '.tripped // false' 2>/dev/null || echo "false")

	# Only write if there's something to reset
	if [[ "$current_count" -eq 0 && "$was_tripped" != "true" ]]; then
		return 0
	fi

	local now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	local new_state
	new_state=$(printf '%s' "$state" | jq \
		--arg now "$now" \
		'.consecutive_failures = 0 | .tripped = false | .last_reset_at = $now | .reset_reason = "task_success"' \
		2>/dev/null)

	if [[ -z "$new_state" ]]; then
		return 0
	fi

	cb_write_state "$new_state"

	if [[ "$was_tripped" == "true" ]]; then
		log_success "circuit-breaker: RESET by task success (was tripped with $current_count consecutive failures)"
		# Close the GitHub issue
		_cb_close_issue "Auto-reset: task completed successfully" || true
	elif [[ "$current_count" -gt 0 ]]; then
		log_info "circuit-breaker: counter reset to 0 (was $current_count)"
	fi

	return 0
}

#######################################
# Check if dispatch should proceed
# Returns: 0 if dispatch is allowed, 1 if circuit breaker is tripped
# Also checks auto-reset cooldown
#######################################
cb_check() {
	local state
	state=$(cb_read_state)

	local tripped
	tripped=$(printf '%s' "$state" | jq -r '.tripped // false' 2>/dev/null || echo "false")

	if [[ "$tripped" != "true" ]]; then
		return 0
	fi

	# Check auto-reset cooldown
	local tripped_at
	tripped_at=$(printf '%s' "$state" | jq -r '.tripped_at // ""' 2>/dev/null || echo "")

	if [[ -n "$tripped_at" && "$CIRCUIT_BREAKER_COOLDOWN_SECS" -gt 0 ]]; then
		local now_epoch tripped_epoch elapsed
		now_epoch=$(date -u +%s 2>/dev/null) || now_epoch=0
		tripped_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$tripped_at" '+%s' 2>/dev/null ||
			date -u -d "$tripped_at" '+%s' 2>/dev/null ||
			echo 0)
		elapsed=$((now_epoch - tripped_epoch))

		if [[ "$elapsed" -ge "$CIRCUIT_BREAKER_COOLDOWN_SECS" ]]; then
			log_info "circuit-breaker: auto-reset after ${elapsed}s cooldown (threshold: ${CIRCUIT_BREAKER_COOLDOWN_SECS}s)"
			cb_reset "auto_cooldown"
			return 0
		fi

		local remaining=$((CIRCUIT_BREAKER_COOLDOWN_SECS - elapsed))
		log_warn "circuit-breaker: TRIPPED — dispatch paused (${remaining}s until auto-reset)"
	else
		log_warn "circuit-breaker: TRIPPED — dispatch paused (manual reset required)"
	fi

	return 1
}

#######################################
# Manually reset the circuit breaker
# Args: $1 = reason (optional, default: "manual_reset")
# Returns: 0 on success
#######################################
cb_reset() {
	local reason="${1:-manual_reset}"

	local state
	state=$(cb_read_state)

	local was_tripped
	was_tripped=$(printf '%s' "$state" | jq -r '.tripped // false' 2>/dev/null || echo "false")

	local prev_count
	prev_count=$(printf '%s' "$state" | jq -r '.consecutive_failures // 0' 2>/dev/null || echo "0")

	local now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	local new_state
	new_state=$(printf '%s' "$state" | jq \
		--arg now "$now" \
		--arg reason "$reason" \
		'.consecutive_failures = 0 | .tripped = false | .last_reset_at = $now | .reset_reason = $reason' \
		2>/dev/null)

	if [[ -z "$new_state" ]]; then
		log_error "circuit-breaker: failed to build reset state"
		return 1
	fi

	cb_write_state "$new_state"

	if [[ "$was_tripped" == "true" ]]; then
		log_success "circuit-breaker: RESET ($reason) — dispatch resumed (was $prev_count consecutive failures)"
		# Close the GitHub issue
		_cb_close_issue "Reset: $reason" || true
	else
		log_info "circuit-breaker: reset ($reason) — counter cleared (was $prev_count)"
	fi

	return 0
}

#######################################
# Show circuit breaker status
# Returns: 0 always, outputs status to stdout
#######################################
cb_status() {
	local state
	state=$(cb_read_state)

	local tripped count tripped_at last_failure last_reset cooldown_secs
	tripped=$(printf '%s' "$state" | jq -r '.tripped // false' 2>/dev/null || echo "false")
	count=$(printf '%s' "$state" | jq -r '.consecutive_failures // 0' 2>/dev/null || echo "0")
	tripped_at=$(printf '%s' "$state" | jq -r '.tripped_at // "never"' 2>/dev/null || echo "never")
	last_failure=$(printf '%s' "$state" | jq -r '.last_failure_task // "none"' 2>/dev/null || echo "none")
	last_reset=$(printf '%s' "$state" | jq -r '.last_reset_at // "never"' 2>/dev/null || echo "never")

	echo "Circuit Breaker Status"
	echo "======================"
	if [[ "$tripped" == "true" ]]; then
		echo "State:                OPEN (dispatch paused)"
	else
		echo "State:                CLOSED (dispatch active)"
	fi
	echo "Consecutive failures: $count / $CIRCUIT_BREAKER_THRESHOLD"
	echo "Tripped at:           $tripped_at"
	echo "Last failure task:    $last_failure"
	echo "Last reset:           $last_reset"
	echo "Threshold:            $CIRCUIT_BREAKER_THRESHOLD"
	echo "Cooldown:             ${CIRCUIT_BREAKER_COOLDOWN_SECS}s"

	# Show time until auto-reset if tripped
	if [[ "$tripped" == "true" && "$tripped_at" != "never" && "$CIRCUIT_BREAKER_COOLDOWN_SECS" -gt 0 ]]; then
		local now_epoch tripped_epoch elapsed remaining
		now_epoch=$(date -u +%s 2>/dev/null) || now_epoch=0
		tripped_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$tripped_at" '+%s' 2>/dev/null ||
			date -u -d "$tripped_at" '+%s' 2>/dev/null ||
			echo 0)
		elapsed=$((now_epoch - tripped_epoch))
		remaining=$((CIRCUIT_BREAKER_COOLDOWN_SECS - elapsed))
		if [[ "$remaining" -gt 0 ]]; then
			echo "Auto-reset in:        ${remaining}s"
		else
			echo "Auto-reset in:        overdue (will reset on next check)"
		fi
	fi

	return 0
}

# ============================================================
# GITHUB ISSUE MANAGEMENT
# ============================================================

#######################################
# Create or update a GitHub issue when the circuit breaker trips
# Args: $1 = failure_count, $2 = last_task_id, $3 = last_failure_reason
# Returns: 0 on success, 1 on failure (non-blocking)
#######################################
_cb_create_or_update_issue() {
	local failure_count="$1"
	local last_task_id="$2"
	local last_failure_reason="$3"

	# Require gh CLI
	if ! command -v gh &>/dev/null; then
		log_warn "circuit-breaker: gh CLI not found, skipping GitHub issue creation"
		return 1
	fi

	local repo_path="${REPO_PATH:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

	# Check for existing open circuit-breaker issue
	local existing_issue
	existing_issue=$(gh issue list \
		--repo "$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo '')" \
		--label "circuit-breaker" \
		--state open \
		--json number \
		--jq '.[0].number // empty' \
		2>/dev/null) || existing_issue=""

	local now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

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
1. Investigate the recent failures (check supervisor logs)
2. Fix the underlying issue
3. Reset the circuit breaker:
   \`\`\`bash
   supervisor-helper.sh circuit-breaker reset
   \`\`\`
   Or wait for auto-reset after ${CIRCUIT_BREAKER_COOLDOWN_SECS}s cooldown.

### Recent failure context
- Task: \`${last_task_id}\`
- Reason: \`${last_failure_reason}\`
- Threshold: ${CIRCUIT_BREAKER_THRESHOLD} consecutive failures

---
*Auto-generated by supervisor circuit breaker (t1331)*"

	if [[ -n "$existing_issue" ]]; then
		# Update existing issue with a comment
		gh issue comment "$existing_issue" \
			--body "### Circuit breaker re-tripped at ${now}

- Consecutive failures: ${failure_count}
- Last failed task: \`${last_task_id}\`
- Reason: \`${last_failure_reason}\`" \
			2>/dev/null || {
			log_warn "circuit-breaker: failed to comment on issue #$existing_issue"
			return 1
		}
		log_info "circuit-breaker: updated GitHub issue #$existing_issue"
	else
		# Create new issue
		# Ensure the circuit-breaker label exists
		gh label create "circuit-breaker" \
			--description "Supervisor circuit breaker tripped — dispatch paused" \
			--color "D93F0B" \
			--force \
			2>/dev/null || true

		local issue_url
		issue_url=$(gh issue create \
			--title "Supervisor circuit breaker tripped — ${failure_count} consecutive failures" \
			--body "$body" \
			--label "circuit-breaker" \
			2>/dev/null) || {
			log_warn "circuit-breaker: failed to create GitHub issue"
			return 1
		}
		log_info "circuit-breaker: created GitHub issue: $issue_url"
	fi

	return 0
}

#######################################
# Close the circuit-breaker GitHub issue when reset
# Args: $1 = close reason
# Returns: 0 on success, 1 on failure (non-blocking)
#######################################
_cb_close_issue() {
	local reason="$1"

	if ! command -v gh &>/dev/null; then
		return 1
	fi

	local existing_issue
	existing_issue=$(gh issue list \
		--label "circuit-breaker" \
		--state open \
		--json number \
		--jq '.[0].number // empty' \
		2>/dev/null) || existing_issue=""

	if [[ -z "$existing_issue" ]]; then
		return 0
	fi

	gh issue close "$existing_issue" \
		--comment "Circuit breaker reset: ${reason}" \
		2>/dev/null || {
		log_warn "circuit-breaker: failed to close issue #$existing_issue"
		return 1
	}

	log_info "circuit-breaker: closed GitHub issue #$existing_issue ($reason)"
	return 0
}

# ============================================================
# CLI SUBCOMMAND HANDLER
# ============================================================

#######################################
# Handle circuit-breaker subcommand from supervisor-helper.sh
# Args: $1 = action (status|reset|trip|check)
# Returns: 0 on success, 1 on error
#######################################
cmd_circuit_breaker() {
	local action="${1:-status}"
	shift || true

	case "$action" in
	status)
		cb_status
		;;
	reset)
		cb_reset "${1:-manual_reset}"
		;;
	check)
		if cb_check; then
			echo "CLOSED — dispatch allowed"
		else
			echo "OPEN — dispatch paused"
			return 1
		fi
		;;
	trip)
		# Manual trip for testing
		local task_id="${1:-manual}"
		local reason="${2:-manual_trip}"
		# Force trip by setting count to threshold
		local now
		now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
		local state
		state=$(jq -n \
			--argjson count "$CIRCUIT_BREAKER_THRESHOLD" \
			--arg now "$now" \
			--arg task "$task_id" \
			--arg reason "$reason" \
			'{consecutive_failures: $count, tripped: true, tripped_at: $now, last_failure_at: $now, last_failure_task: $task, last_failure_reason: $reason}')
		cb_write_state "$state"
		log_warn "circuit-breaker: manually tripped (task: $task_id, reason: $reason)"
		_cb_create_or_update_issue "$CIRCUIT_BREAKER_THRESHOLD" "$task_id" "$reason" || true
		;;
	*)
		echo "Usage: supervisor-helper.sh circuit-breaker <status|reset|check|trip>"
		echo ""
		echo "Commands:"
		echo "  status  Show circuit breaker state (default)"
		echo "  reset   Reset the circuit breaker, resume dispatch"
		echo "  check   Check if dispatch is allowed (exit 0=yes, 1=no)"
		echo "  trip    Manually trip the circuit breaker (for testing)"
		echo ""
		echo "Configuration (env vars):"
		echo "  SUPERVISOR_CIRCUIT_BREAKER_THRESHOLD    Failures before trip (default: 3)"
		echo "  SUPERVISOR_CIRCUIT_BREAKER_COOLDOWN_SECS  Auto-reset cooldown (default: 1800)"
		return 1
		;;
	esac

	return 0
}
