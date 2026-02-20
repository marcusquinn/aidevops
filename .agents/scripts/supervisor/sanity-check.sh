#!/usr/bin/env bash
# sanity-check.sh - Adversarial state verification for the supervisor
#
# The deterministic phases of the pulse cycle make assumptions:
#   - "has assignee: → someone is working on it"
#   - "has blocked-by: → must wait"
#   - "no #auto-dispatch → not dispatchable"
#   - "DB says failed → nothing more to do"
#
# These assumptions cause the queue to stall silently when reality diverges
# from the state model. This module questions those assumptions by cross-
# referencing TODO.md state, DB state, and actual system state (worktrees,
# PIDs, git history) to find contradictions.
#
# Design principle: Don't assume, verify. If a human looking at the queue
# for 30 seconds would say "this is obviously stuck", the sanity check
# should catch it and fix it.
#
# Invoked by: pulse.sh Phase 0.9 (after all deterministic phases, before dispatch)
# Frequency: every pulse when zero tasks are dispatchable
# Cost: deterministic checks are free; AI reasoning is gated behind
#        SUPERVISOR_SANITY_AI=true and rate-limited to 1/hour
#
# Sourced by: supervisor-helper.sh (set -euo pipefail inherited)

# Globals expected from supervisor-helper.sh:
#   SUPERVISOR_DB, SUPERVISOR_LOG, SCRIPT_DIR, REPO_PATH
#   db(), log_info(), log_warn(), log_error(), log_success(), sql_escape()
#   cmd_unclaim(), cmd_transition(), cmd_reset()

#######################################
# Phase 0.9: Sanity check — question every assumption when the queue is empty
#
# Called when the pulse finds zero dispatchable tasks but open tasks exist.
# Runs deterministic contradiction checks first (free), then optionally
# invokes AI reasoning for ambiguous cases.
#
# Args:
#   $1 - repo path
# Returns:
#   Number of issues found and fixed (via stdout)
#   0 on success
#######################################
run_sanity_check() {
	local repo_path="${1:-$REPO_PATH}"
	local todo_file="$repo_path/TODO.md"
	local fixed=0

	if [[ ! -f "$todo_file" ]]; then
		return 0
	fi

	ensure_db

	log_info "Phase 0.9: Sanity check — questioning assumptions on stalled queue"

	# Check 1: DB-failed tasks with TODO.md claims (the double-lock)
	# If the DB knows a task failed, the TODO.md claim is stale by definition.
	# Don't wait 24h — the DB is authoritative evidence.
	local db_failed_check
	db_failed_check=$(_check_db_failed_with_claims "$repo_path")
	fixed=$((fixed + db_failed_check))

	# Check 2: Failed blockers holding up dependency chains
	# If a blocker failed permanently (retries exhausted), dependents will
	# never be unblocked. Either reset the blocker or mark the chain stuck.
	local failed_blocker_check
	failed_blocker_check=$(_check_failed_blocker_chains "$repo_path")
	fixed=$((fixed + failed_blocker_check))

	# Check 3: Tasks eligible for dispatch but missing #auto-dispatch
	# If a task has a clear spec, model assignment, estimate, and no blocker
	# tags, it's probably dispatchable. Flag it.
	local missing_tag_check
	missing_tag_check=$(_check_missing_auto_dispatch "$repo_path")
	fixed=$((fixed + missing_tag_check))

	# Check 4: DB orphans — tasks in DB that don't exist in TODO.md
	# These consume batch slots and confuse the state machine.
	local orphan_check
	orphan_check=$(_check_db_orphans "$repo_path")
	fixed=$((fixed + orphan_check))

	# Summary
	if [[ "$fixed" -gt 0 ]]; then
		log_success "Phase 0.9: Sanity check fixed $fixed issue(s)"

		# Record pattern for observability
		local pattern_helper="${SCRIPT_DIR}/pattern-tracker-helper.sh"
		if [[ -x "$pattern_helper" ]]; then
			"$pattern_helper" record \
				--type "SELF_HEAL_PATTERN" \
				--task "supervisor" \
				--model "n/a" \
				--detail "Phase 0.9 sanity check: fixed $fixed issue(s) on stalled queue" \
				2>/dev/null || true
		fi
	else
		log_info "Phase 0.9: Sanity check found no fixable issues"
		# Log the structured skip-reason summary so the stall is visible
		_log_queue_stall_reasons "$repo_path"
	fi

	echo "$fixed"
	return 0
}

#######################################
# Check 1: Tasks failed in DB but still claimed in TODO.md
# The DB is authoritative — if it says failed, the claim is dead.
# Strip assignee:/started: immediately so the task can be re-assessed.
#######################################
_check_db_failed_with_claims() {
	local repo_path="$1"
	local todo_file="$repo_path/TODO.md"
	local fixed=0

	# Get all failed/blocked tasks from DB for this repo
	local failed_tasks
	failed_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT id, status, error, retries, max_retries FROM tasks
		WHERE status IN ('failed', 'blocked')
		AND repo = '$(sql_escape "$repo_path")';
	" 2>/dev/null || echo "")

	[[ -z "$failed_tasks" ]] && echo "$fixed" && return 0

	local identity
	identity=$(get_aidevops_identity 2>/dev/null || whoami)

	while IFS='|' read -r task_id db_status db_error db_retries db_max_retries; do
		[[ -z "$task_id" ]] && continue

		# Check if this task is open in TODO.md with a claim
		local todo_line
		todo_line=$(grep -E "^[[:space:]]*- \[ \] ${task_id}( |$)" "$todo_file" 2>/dev/null || echo "")
		[[ -z "$todo_line" ]] && continue

		# Check for assignee: or started: fields
		if ! echo "$todo_line" | grep -qE '(assignee:|started:)'; then
			continue
		fi

		# Verify the assignee is local (respect t1017 ownership)
		local assignee=""
		assignee=$(printf '%s' "$todo_line" | grep -oE 'assignee:[A-Za-z0-9._@-]+' | tail -1 | sed 's/assignee://' || echo "")
		if [[ -n "$assignee" ]]; then
			local local_user
			local_user=$(whoami 2>/dev/null || echo "")
			if [[ "$assignee" != "$local_user" && "$assignee" != "$identity" && "${assignee%%@*}" != "${identity%%@*}" ]]; then
				log_verbose "  Sanity check 1: $task_id — DB says $db_status but assignee:$assignee is external, skipping"
				continue
			fi
		fi

		# The DB knows this task failed/blocked. The claim is stale by definition.
		log_warn "  Sanity check 1: $task_id — DB says '$db_status' but TODO.md has active claim"
		log_warn "    Error: ${db_error:0:100}"
		log_warn "    Action: stripping stale claim (DB state is authoritative)"

		# Strip the claim
		if cmd_unclaim "$task_id" "$repo_path" --force 2>>"${SUPERVISOR_LOG:-/dev/null}"; then
			fixed=$((fixed + 1))
			log_success "  Sanity check 1: $task_id — claim stripped, task now assessable"

			# If retries aren't exhausted, reset to queued for re-dispatch
			if [[ "$db_retries" -lt "$db_max_retries" ]]; then
				log_info "  Sanity check 1: $task_id — retries available ($db_retries/$db_max_retries), resetting to queued"
				cmd_reset "$task_id" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
			fi
		fi
	done <<<"$failed_tasks"

	echo "$fixed"
	return 0
}

#######################################
# Check 2: Failed blockers holding up dependency chains
# When a root task fails permanently, its dependents wait forever.
# Options: reset the failed root for retry, or surface the chain as stuck.
#######################################
_check_failed_blocker_chains() {
	local repo_path="$1"
	local todo_file="$repo_path/TODO.md"
	local fixed=0

	# Find open tasks with blocked-by: fields
	local blocked_tasks
	blocked_tasks=$(grep -E '^\s*- \[ \] t[0-9]+.*blocked-by:' "$todo_file" 2>/dev/null || echo "")
	[[ -z "$blocked_tasks" ]] && echo "$fixed" && return 0

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue

		local task_id=""
		task_id=$(printf '%s' "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		[[ -z "$task_id" ]] && continue

		local blocked_by=""
		blocked_by=$(printf '%s' "$line" | grep -oE 'blocked-by:[^ ]+' | head -1 | sed 's/blocked-by://' || echo "")
		[[ -z "$blocked_by" ]] && continue

		# Check each blocker against the DB
		local _saved_ifs="$IFS"
		IFS=','
		for blocker_id in $blocked_by; do
			[[ -z "$blocker_id" ]] && continue

			# Is this blocker failed in the DB?
			local blocker_status
			blocker_status=$(db "$SUPERVISOR_DB" "
				SELECT status FROM tasks
				WHERE id = '$(sql_escape "$blocker_id")'
				AND status = 'failed';
			" 2>/dev/null || echo "")

			if [[ "$blocker_status" == "failed" ]]; then
				# Check if the failed blocker has retries available
				local blocker_retries blocker_max
				blocker_retries=$(db "$SUPERVISOR_DB" "SELECT retries FROM tasks WHERE id = '$(sql_escape "$blocker_id")';" 2>/dev/null || echo "3")
				blocker_max=$(db "$SUPERVISOR_DB" "SELECT max_retries FROM tasks WHERE id = '$(sql_escape "$blocker_id")';" 2>/dev/null || echo "3")

				if [[ "$blocker_retries" -lt "$blocker_max" ]]; then
					# Reset the failed blocker for retry
					log_warn "  Sanity check 2: $blocker_id failed but has retries ($blocker_retries/$blocker_max) — resetting for retry (blocks $task_id)"
					cmd_reset "$blocker_id" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
					fixed=$((fixed + 1))
				else
					# Blocker is permanently failed — remove the blocked-by so the
					# dependent can be assessed on its own merits (it may still work
					# without the blocker, or the AI reasoner can decide)
					log_warn "  Sanity check 2: $blocker_id permanently failed ($blocker_retries/$blocker_max) — unblocking $task_id (blocker is dead)"

					# Remove this specific blocker from the blocked-by field
					local line_num
					line_num=$(grep -nE "^[[:space:]]*- \[ \] ${task_id}( |$)" "$todo_file" | head -1 | cut -d: -f1 || echo "")
					if [[ -n "$line_num" ]]; then
						if [[ "$blocked_by" == "$blocker_id" ]]; then
							# Only blocker — remove the whole field
							local escaped_blocker
							escaped_blocker=$(printf '%s' "$blocker_id" | sed 's/\./\\./g')
							sed_inplace "${line_num}s/ blocked-by:${escaped_blocker}//" "$todo_file"
						else
							# Multiple blockers — rebuild the list without this one
							local new_blockers
							new_blockers=$(printf '%s' ",$blocked_by," | sed "s/,${blocker_id},/,/" | sed 's/^,//;s/,$//')
							local escaped_blocked_by
							escaped_blocked_by=$(printf '%s' "$blocked_by" | sed 's/\./\\./g')
							if [[ -n "$new_blockers" ]]; then
								sed_inplace "${line_num}s/blocked-by:${escaped_blocked_by}/blocked-by:${new_blockers}/" "$todo_file"
							else
								sed_inplace "${line_num}s/ blocked-by:${escaped_blocked_by}//" "$todo_file"
							fi
						fi
						sed_inplace "${line_num}s/[[:space:]]*$//" "$todo_file"
						fixed=$((fixed + 1))
					fi
				fi
			fi
		done
		IFS="$_saved_ifs"
	done <<<"$blocked_tasks"

	if [[ "$fixed" -gt 0 ]]; then
		commit_and_push_todo "$repo_path" "chore: sanity check — unblock tasks with failed/retryable blockers" || true
	fi

	echo "$fixed"
	return 0
}

#######################################
# Check 3: Tasks that look dispatchable but lack #auto-dispatch
# Instead of silently ignoring them, flag them for the AI reasoner
# or auto-tag if they clearly meet the criteria.
#
# Auto-tag criteria (all must be true):
#   - Has model: assignment
#   - Has time estimate (~Xh)
#   - Has no blocker tags (account-needed, etc.)
#   - Has no blocked-by: field
#   - Has no assignee: or started: field
#   - Is not a #plan task (plans need decomposition, not dispatch)
#   - Is not an #investigation task (needs human judgment)
#######################################
_check_missing_auto_dispatch() {
	local repo_path="$1"
	local todo_file="$repo_path/TODO.md"
	local fixed=0

	# Blocker tags that indicate human action needed
	local blocker_pattern='account-needed|hosting-needed|login-needed|api-key-needed|clarification-needed|resources-needed|payment-needed|approval-needed|decision-needed|design-needed|content-needed|dns-needed|domain-needed|testing-needed'

	# Find open tasks WITHOUT #auto-dispatch
	local candidates
	candidates=$(grep -E '^\s*- \[ \] t[0-9]+' "$todo_file" 2>/dev/null |
		grep -v '#auto-dispatch' |
		grep -v 'assignee:' |
		grep -v 'started:' |
		grep -v 'blocked-by:' |
		grep -vE "#(plan|investigation)" |
		grep -vE "$blocker_pattern" |
		grep -E 'model:' |
		grep -E '~[0-9]+[hm]' || echo "")

	[[ -z "$candidates" ]] && echo "$fixed" && return 0

	# Also exclude the template line (tXXX)
	candidates=$(echo "$candidates" | grep -v 'tXXX' || echo "")
	[[ -z "$candidates" ]] && echo "$fixed" && return 0

	local candidate_count
	candidate_count=$(echo "$candidates" | wc -l | tr -d ' ')

	if [[ "$candidate_count" -gt 0 ]]; then
		log_warn "  Sanity check 3: $candidate_count task(s) look dispatchable but lack #auto-dispatch tag"

		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			local task_id
			task_id=$(printf '%s' "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
			[[ -z "$task_id" ]] && continue

			# Skip if already tracked in DB (may have been manually dispatched)
			local existing
			existing=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")
			if [[ -n "$existing" ]]; then
				continue
			fi

			# Auto-tag: add #auto-dispatch to the task line
			local line_num
			line_num=$(grep -nE "^[[:space:]]*- \[ \] ${task_id}( |$)" "$todo_file" | head -1 | cut -d: -f1 || echo "")
			if [[ -n "$line_num" ]]; then
				# Insert #auto-dispatch before the first — or at end of tags
				# Find where to insert: after the last #tag before any —
				sed_inplace "${line_num}s/\(#[a-zA-Z][a-zA-Z0-9_-]*\)\([[:space:]]\)/\1 #auto-dispatch\2/" "$todo_file"

				# Verify it was added (sed may not have matched if tag format differs)
				if grep -q "^[[:space:]]*- \[ \] ${task_id}.*#auto-dispatch" "$todo_file"; then
					log_success "  Sanity check 3: $task_id — auto-tagged #auto-dispatch (has model:, estimate, no blockers)"
					fixed=$((fixed + 1))
				else
					# Fallback: append before the description separator
					sed_inplace "${line_num}s/ — / #auto-dispatch — /" "$todo_file"
					if grep -q "^[[:space:]]*- \[ \] ${task_id}.*#auto-dispatch" "$todo_file"; then
						log_success "  Sanity check 3: $task_id — auto-tagged #auto-dispatch (fallback insertion)"
						fixed=$((fixed + 1))
					else
						log_warn "  Sanity check 3: $task_id — could not auto-tag, needs manual review"
					fi
				fi
			fi
		done <<<"$candidates"

		if [[ "$fixed" -gt 0 ]]; then
			commit_and_push_todo "$repo_path" "chore: sanity check — auto-tag $fixed task(s) as #auto-dispatch" || true
		fi
	fi

	echo "$fixed"
	return 0
}

#######################################
# Check 4: DB orphans with non-terminal status
# Tasks in the DB that have no corresponding TODO.md entry and are
# not in a terminal state (verified/cancelled/failed) consume batch
# slots and confuse dispatch.
#######################################
_check_db_orphans() {
	local repo_path="$1"
	local todo_file="$repo_path/TODO.md"
	local fixed=0

	local orphans
	orphans=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT id, status FROM tasks
		WHERE repo = '$(sql_escape "$repo_path")'
		AND status IN ('queued', 'dispatched', 'running')
		ORDER BY id;
	" 2>/dev/null || echo "")

	[[ -z "$orphans" ]] && echo "$fixed" && return 0

	while IFS='|' read -r task_id db_status; do
		[[ -z "$task_id" ]] && continue

		# Check if task exists in TODO.md (any state)
		if ! grep -qE "^[[:space:]]*- \[.\] ${task_id}( |$)" "$todo_file" 2>/dev/null; then
			log_warn "  Sanity check 4: $task_id is '$db_status' in DB but missing from TODO.md — cancelling"
			cmd_transition "$task_id" "cancelled" --error "Sanity check: DB orphan with no TODO.md entry" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
			fixed=$((fixed + 1))
		fi
	done <<<"$orphans"

	echo "$fixed"
	return 0
}

#######################################
# Log structured skip reasons when the queue is stalled
# Makes the stall visible instead of silently saying "No new tasks"
#######################################
_log_queue_stall_reasons() {
	local repo_path="$1"
	local todo_file="$repo_path/TODO.md"

	local open_count claimed_count blocked_count no_tag_count db_failed_count
	open_count=$(grep -cE '^\s*- \[ \] t[0-9]+' "$todo_file" 2>/dev/null || echo "0")
	claimed_count=$(grep -cE '^\s*- \[ \] t[0-9]+.*(assignee:|started:)' "$todo_file" 2>/dev/null || echo "0")
	blocked_count=$(grep -cE '^\s*- \[ \] t[0-9]+.*blocked-by:' "$todo_file" 2>/dev/null || echo "0")
	no_tag_count=$(grep -E '^\s*- \[ \] t[0-9]+' "$todo_file" 2>/dev/null | grep -cv '#auto-dispatch' || echo "0")
	db_failed_count=$(db "$SUPERVISOR_DB" "
		SELECT COUNT(*) FROM tasks
		WHERE repo = '$(sql_escape "$repo_path")'
		AND status IN ('failed', 'blocked');
	" 2>/dev/null || echo "0")

	log_warn "  Queue stall breakdown:"
	log_warn "    Open tasks in TODO.md: $open_count"
	log_warn "    Claimed (assignee/started): $claimed_count"
	log_warn "    Blocked (blocked-by): $blocked_count"
	log_warn "    Missing #auto-dispatch: $no_tag_count"
	log_warn "    Failed/blocked in DB: $db_failed_count"
	log_warn "    Dispatchable: 0"

	return 0
}
