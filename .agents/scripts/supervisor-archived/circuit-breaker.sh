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
# Validate numeric — strip non-digits, fallback to default if empty
CIRCUIT_BREAKER_THRESHOLD="${CIRCUIT_BREAKER_THRESHOLD//[!0-9]/}"
[[ -n "$CIRCUIT_BREAKER_THRESHOLD" ]] || CIRCUIT_BREAKER_THRESHOLD=3

# Auto-reset cooldown in seconds (default: 30 minutes)
CIRCUIT_BREAKER_COOLDOWN_SECS="${SUPERVISOR_CIRCUIT_BREAKER_COOLDOWN_SECS:-1800}"
# Validate numeric — strip non-digits, fallback to default if empty
CIRCUIT_BREAKER_COOLDOWN_SECS="${CIRCUIT_BREAKER_COOLDOWN_SECS//[!0-9]/}"
[[ -n "$CIRCUIT_BREAKER_COOLDOWN_SECS" ]] || CIRCUIT_BREAKER_COOLDOWN_SECS=1800

# ============================================================
# STATE FILE
# ============================================================

_cb_state_file() {
	local dir="${SUPERVISOR_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor}"
	mkdir -p "$dir" || true
	echo "$dir/circuit-breaker.state"
	return 0
}

# ============================================================
# LOCK WRAPPER — serialise read-modify-write sequences
# ============================================================

#######################################
# Acquire a directory-based lock, run a command, then release.
# Uses mkdir for atomic lock creation (POSIX-safe).
# Uses trap to ensure cleanup even under set -e / errexit.
# Args: $@ = command and arguments to run under lock
# Returns: exit code of the wrapped command, or 1 on lock timeout
#######################################
_cb_with_state_lock() {
	local lock_dir
	lock_dir="$(_cb_state_file).lock"
	local attempts=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		sleep 0.05
		attempts=$((attempts + 1))
		if [[ "$attempts" -gt 200 ]]; then
			log_warn "circuit-breaker: lock acquisition timed out after 10s"
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

#######################################
# Parse an ISO 8601 timestamp to epoch seconds.
# Returns epoch via stdout. On parse failure returns empty string
# (caller must handle — never silently returns 0).
# Args: $1 = ISO 8601 timestamp (e.g. "2026-02-19T08:00:00Z")
#######################################
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

#######################################
# Calculate seconds elapsed since a given ISO timestamp.
# Returns elapsed seconds via stdout, or empty string on parse failure.
# Args: $1 = ISO 8601 timestamp
#######################################
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
		# Validate JSON before returning — corrupted file returns defaults
		local content
		content=$(cat "$state_file" 2>/dev/null) || content=""
		if printf '%s' "$content" | jq empty 2>/dev/null; then
			echo "$content"
		else
			log_warn "circuit-breaker: corrupted state file, returning defaults"
			echo '{"consecutive_failures":0,"tripped":false,"tripped_at":"","last_failure_at":"","last_failure_task":"","last_reset_at":""}'
		fi
	else
		echo '{"consecutive_failures":0,"tripped":false,"tripped_at":"","last_failure_at":"","last_failure_task":"","last_reset_at":""}'
	fi
	return 0
}

#######################################
# Write circuit breaker state atomically
# Hardened: failures here must not propagate errexit to caller.
# Args: $1 = JSON state string
# Returns: 0 on success, 1 on failure (logged, non-fatal)
#######################################
cb_write_state() {
	local state_json="$1"
	local state_file
	state_file=$(_cb_state_file)

	# Atomic write via temp file + mv
	local tmp_file="${state_file}.tmp.$$"
	if ! printf '%s\n' "$state_json" >"$tmp_file" 2>/dev/null; then
		log_warn "circuit-breaker: failed to write temp state file: $tmp_file"
		rm -f "$tmp_file" 2>/dev/null || true
		return 1
	fi
	if ! mv -f "$tmp_file" "$state_file" 2>/dev/null; then
		log_warn "circuit-breaker: failed to move temp state to: $state_file"
		rm -f "$tmp_file" 2>/dev/null || true
		return 1
	fi
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
	_cb_with_state_lock _cb_record_failure_impl "$@" || true
	return 0
}

_cb_record_failure_impl() {
	local task_id="$1"
	local failure_reason="${2:-unknown}"

	local state
	state=$(cb_read_state) || {
		log_warn "circuit-breaker: failed to read state"
		return 0
	}

	local current_count tripped now
	current_count=$(printf '%s' "$state" | jq -r '.consecutive_failures // 0') || current_count=0
	tripped=$(printf '%s' "$state" | jq -r '.tripped // false') || tripped="false"
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	local new_count=$((current_count + 1))

	# Build complete new state in a single jq pass
	local new_state
	if [[ "$tripped" != "true" && "$new_count" -ge "$CIRCUIT_BREAKER_THRESHOLD" ]]; then
		# Trip the breaker — set tripped + tripped_at in one jq call
		new_state=$(printf '%s' "$state" | jq \
			--argjson count "$new_count" \
			--arg now "$now" \
			--arg task "$task_id" \
			--arg reason "$failure_reason" \
			'.consecutive_failures = $count | .last_failure_at = $now | .last_failure_task = $task | .last_failure_reason = $reason | .tripped = true | .tripped_at = $now') || {
			log_warn "circuit-breaker: failed to update state JSON"
			return 0
		}
		cb_write_state "$new_state" || return 0
		log_error "circuit-breaker: TRIPPED after $new_count consecutive failures (threshold: $CIRCUIT_BREAKER_THRESHOLD)"
		log_error "circuit-breaker: last failure: $task_id ($failure_reason)"
		log_error "circuit-breaker: dispatch is PAUSED. Reset with: supervisor-helper.sh circuit-breaker reset"

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
			log_warn "circuit-breaker: failed to update state JSON"
			return 0
		}
		cb_write_state "$new_state" || return 0
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
	_cb_with_state_lock _cb_record_success_impl || true
	return 0
}

_cb_record_success_impl() {
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
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	local new_state
	new_state=$(printf '%s' "$state" | jq \
		--arg now "$now" \
		'.consecutive_failures = 0 | .tripped = false | .last_reset_at = $now | .reset_reason = "task_success"') || {
		return 0
	}

	cb_write_state "$new_state" || return 0

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

		# If timestamp parse failed, keep breaker open (don't auto-reset on bad data)
		if [[ -z "$elapsed" ]]; then
			log_warn "circuit-breaker: TRIPPED — could not parse tripped_at timestamp, keeping breaker open"
			return 1
		fi

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
	_cb_with_state_lock _cb_reset_impl "$reason"
}

_cb_reset_impl() {
	local reason="$1"

	local state
	state=$(cb_read_state) || {
		log_error "circuit-breaker: failed to read state for reset"
		return 1
	}

	local was_tripped prev_count
	was_tripped=$(printf '%s' "$state" | jq -r '.tripped // false') || was_tripped="false"
	prev_count=$(printf '%s' "$state" | jq -r '.consecutive_failures // 0') || prev_count=0

	local now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	local new_state
	new_state=$(printf '%s' "$state" | jq \
		--arg now "$now" \
		--arg reason "$reason" \
		'.consecutive_failures = 0 | .tripped = false | .last_reset_at = $now | .reset_reason = $reason') || {
		log_error "circuit-breaker: failed to build reset state"
		return 1
	}

	cb_write_state "$new_state" || return 1

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
	state=$(cb_read_state) || {
		echo "Circuit Breaker Status: unable to read state"
		return 0
	}

	local tripped count tripped_at last_failure last_reset
	tripped=$(printf '%s' "$state" | jq -r '.tripped // false') || tripped="false"
	count=$(printf '%s' "$state" | jq -r '.consecutive_failures // 0') || count=0
	# Use if/then/else in jq to handle both null and empty string
	tripped_at=$(printf '%s' "$state" | jq -r 'if (.tripped_at // "") == "" then "never" else .tripped_at end') || tripped_at="never"
	last_failure=$(printf '%s' "$state" | jq -r 'if (.last_failure_task // "") == "" then "none" else .last_failure_task end') || last_failure="none"
	last_reset=$(printf '%s' "$state" | jq -r 'if (.last_reset_at // "") == "" then "never" else .last_reset_at end') || last_reset="never"

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

# ============================================================
# GITHUB ISSUE MANAGEMENT
# ============================================================

#######################################
# Resolve the GitHub repo slug once for all gh CLI operations.
# Returns: repo slug via stdout (e.g. "owner/repo"), or empty on failure.
# Does not suppress stderr — auth/network errors remain visible.
#######################################
_cb_resolve_repo_slug() {
	local repo_slug
	repo_slug=$(gh repo view --json nameWithOwner -q '.nameWithOwner') || repo_slug=""
	echo "$repo_slug"
	return 0
}

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

	# Resolve repo slug once for all gh commands in this function
	local repo_slug
	repo_slug=$(_cb_resolve_repo_slug)
	if [[ -z "$repo_slug" ]]; then
		log_warn "circuit-breaker: could not determine GitHub repository, skipping issue creation"
		return 1
	fi

	# Check for existing open circuit-breaker issue
	local existing_issue
	existing_issue=$(gh issue list \
		--repo "$repo_slug" \
		--label "circuit-breaker" \
		--state open \
		--json number \
		--jq '.[0].number // empty') || existing_issue=""

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
			--repo "$repo_slug" \
			--body "### Circuit breaker re-tripped at ${now}

- Consecutive failures: ${failure_count}
- Last failed task: \`${last_task_id}\`
- Reason: \`${last_failure_reason}\`" || {
			log_warn "circuit-breaker: failed to comment on issue #$existing_issue"
			return 1
		}
		log_info "circuit-breaker: updated GitHub issue #$existing_issue"
	else
		# Create new issue
		# Ensure the circuit-breaker label exists
		gh label create "circuit-breaker" \
			--repo "$repo_slug" \
			--description "Supervisor circuit breaker tripped — dispatch paused" \
			--color "D93F0B" \
			--force || true

		local issue_url
		issue_url=$(gh issue create \
			--repo "$repo_slug" \
			--title "Supervisor circuit breaker tripped — ${failure_count} consecutive failures" \
			--body "$body" \
			--label "circuit-breaker") || {
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
			'{consecutive_failures: $count, tripped: true, tripped_at: $now, last_failure_at: $now, last_failure_task: $task, last_failure_reason: $reason}') || {
			log_error "circuit-breaker: failed to build trip state JSON"
			return 1
		}
		cb_write_state "$state" || return 1
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
