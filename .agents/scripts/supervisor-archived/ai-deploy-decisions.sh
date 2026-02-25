#!/usr/bin/env bash
# ai-deploy-decisions.sh - AI judgment for deploy.sh decision logic (t1314.1)
#
# Replaces three deterministic decision functions with AI judgment:
#   1. check_pr_status()          → ai_check_pr_status()
#   2. triage_review_feedback()   → ai_triage_review_feedback()
#   3. verify_task_deliverables() → ai_verify_task_deliverables()
#
# Architecture: GATHER (shell) → JUDGE (AI) → RETURN (shell)
# - Shell gathers all data (GitHub API, DB, git)
# - AI receives structured data and makes the judgment call
# - Shell parses AI response and returns in the same format as the original
# - Falls back to deterministic logic if AI is unavailable or returns garbage
#
# Merge/rebase execution remains 100% shell — AI only makes decisions.
#
# Sourced by: supervisor-helper.sh (after deploy.sh and dispatch.sh)
# Depends on: deploy.sh (original functions as fallback)
#             dispatch.sh (resolve_ai_cli, resolve_model)
#             _common.sh (portable_timeout, log_*)

# Globals expected from supervisor-helper.sh:
#   SUPERVISOR_DB, SUPERVISOR_LOG, SUPERVISOR_DIR
#   db(), log_info(), log_warn(), log_error(), log_success(), sql_escape()
#   resolve_ai_cli(), resolve_model(), portable_timeout()
#   parse_pr_url(), link_pr_to_task(), check_gh_auth()

# Feature flag: enable/disable AI deploy decisions (default: enabled)
# Set to "false" to use deterministic logic exclusively.
AI_DEPLOY_DECISIONS_ENABLED="${AI_DEPLOY_DECISIONS_ENABLED:-true}"

# Model tier for deploy decisions — sonnet is fast and cheap enough for
# structured classification tasks. Opus is overkill here.
AI_DEPLOY_DECISIONS_MODEL="${AI_DEPLOY_DECISIONS_MODEL:-sonnet}"

# Timeout for AI judgment calls (seconds) — these are quick classification
# tasks, not open-ended reasoning. 30s is generous.
AI_DEPLOY_DECISIONS_TIMEOUT="${AI_DEPLOY_DECISIONS_TIMEOUT:-30}"

# Log directory for decision audit trail
AI_DEPLOY_DECISIONS_LOG_DIR="${AI_DEPLOY_DECISIONS_LOG_DIR:-$HOME/.aidevops/logs/ai-deploy-decisions}"

#######################################
# Internal: Call AI CLI with a prompt and return the raw response.
# Handles both opencode and claude CLIs, strips ANSI codes.
#
# Args:
#   $1 - prompt text
#   $2 - title suffix for session naming
# Outputs:
#   Raw AI response on stdout (ANSI-stripped)
# Returns:
#   0 on success, 1 on failure (empty response or CLI unavailable)
#######################################
_ai_deploy_call() {
	local prompt="$1"
	local title_suffix="$2"

	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || {
		log_warn "ai-deploy-decisions: no AI CLI available"
		return 1
	}

	local ai_model
	ai_model=$(resolve_model "$AI_DEPLOY_DECISIONS_MODEL" "$ai_cli" 2>/dev/null) || {
		log_warn "ai-deploy-decisions: model $AI_DEPLOY_DECISIONS_MODEL unavailable"
		return 1
	}

	local ai_result=""
	local timeout_secs="$AI_DEPLOY_DECISIONS_TIMEOUT"

	if [[ "$ai_cli" == "opencode" ]]; then
		ai_result=$(portable_timeout "$timeout_secs" opencode run \
			-m "$ai_model" \
			--format default \
			--title "deploy-${title_suffix}-$$" \
			"$prompt" 2>/dev/null || echo "")
		# Strip ANSI escape codes
		ai_result=$(printf '%s' "$ai_result" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\]//g; s/\x07//g')
	else
		local claude_model="${ai_model#*/}"
		ai_result=$(portable_timeout "$timeout_secs" claude \
			-p "$prompt" \
			--model "$claude_model" \
			--output-format text 2>/dev/null || echo "")
	fi

	if [[ -z "$ai_result" ]]; then
		return 1
	fi

	printf '%s' "$ai_result"
	return 0
}

#######################################
# Internal: Extract JSON object from AI response.
# Handles markdown fencing, preamble text, etc.
#
# Args:
#   $1 - raw AI response
# Outputs:
#   JSON object on stdout, or empty string
# Returns:
#   0 if JSON found, 1 if not
#######################################
_ai_deploy_extract_json() {
	local response="$1"

	# Try 1: Direct parse
	local parsed
	if parsed=$(printf '%s' "$response" | jq '.' 2>/dev/null) && [[ -n "$parsed" ]]; then
		local jtype
		jtype=$(printf '%s' "$parsed" | jq 'type' 2>/dev/null || echo "")
		if [[ "$jtype" == '"object"' ]]; then
			printf '%s' "$parsed"
			return 0
		fi
	fi

	# Try 2: Extract from ```json block
	local json_block
	json_block=$(printf '%s' "$response" | awk '
		/^```json/ { capture=1; block=""; next }
		/^```$/ && capture { capture=0; last_block=block; next }
		capture { block = block (block ? "\n" : "") $0 }
		END { if (capture && block) print block; else if (last_block) print last_block }
	')
	if [[ -n "$json_block" ]]; then
		if parsed=$(printf '%s' "$json_block" | jq '.' 2>/dev/null) && [[ -n "$parsed" ]]; then
			printf '%s' "$parsed"
			return 0
		fi
	fi

	# Try 3: Grep for JSON object
	local obj_match
	obj_match=$(printf '%s' "$response" | grep -oE '\{[^}]+\}' | tail -1)
	if [[ -n "$obj_match" ]]; then
		if parsed=$(printf '%s' "$obj_match" | jq '.' 2>/dev/null) && [[ -n "$parsed" ]]; then
			printf '%s' "$parsed"
			return 0
		fi
	fi

	# Try 4: Multi-line JSON object (between { and })
	local bracket_json
	bracket_json=$(printf '%s' "$response" | awk '
		/^\s*\{/ { capture=1; block="" }
		capture { block = block (block ? "\n" : "") $0 }
		/^\s*\}/ && capture { capture=0; last_block=block }
		END { if (last_block) print last_block }
	')
	if [[ -n "$bracket_json" ]]; then
		if parsed=$(printf '%s' "$bracket_json" | jq '.' 2>/dev/null) && [[ -n "$parsed" ]]; then
			printf '%s' "$parsed"
			return 0
		fi
	fi

	return 1
}

#######################################
# Internal: Log an AI deploy decision for audit trail.
#
# Args:
#   $1 - function name (e.g., "ai_check_pr_status")
#   $2 - task_id
#   $3 - decision summary
#   $4 - (optional) full context for the log file
#######################################
_ai_deploy_log_decision() {
	local func_name="$1"
	local task_id="$2"
	local decision="$3"
	local context="${4:-}"

	mkdir -p "$AI_DEPLOY_DECISIONS_LOG_DIR" 2>/dev/null || true

	local timestamp
	timestamp=$(date -u '+%Y%m%d-%H%M%S')
	local log_file="$AI_DEPLOY_DECISIONS_LOG_DIR/${func_name}-${task_id}-${timestamp}.md"

	{
		echo "# $func_name: $task_id @ $timestamp"
		echo ""
		echo "Decision: $decision"
		echo ""
		if [[ -n "$context" ]]; then
			echo "## Context"
			echo ""
			echo "$context"
		fi
	} >"$log_file" 2>/dev/null || true

	return 0
}

###############################################################################
# 1. AI-POWERED PR STATUS CHECK
#
# Replaces: check_pr_status() in deploy.sh
# The original function has ~210 lines of nested case statements parsing
# mergeStateStatus, statusCheckRollup, reviewDecision, etc.
#
# The AI version:
# - Gathers the same raw data from GitHub API
# - Sends it to AI with the classification rules
# - AI returns one of the known status values
# - Falls back to deterministic check_pr_status() on AI failure
###############################################################################

#######################################
# AI-powered PR status check.
# Gathers PR data from GitHub, asks AI to classify the status.
#
# Args:
#   $1 - task_id
# Outputs:
#   status|mergeStateStatus (same format as check_pr_status)
# Returns:
#   0 always (status is in the output string)
#######################################
ai_check_pr_status() {
	local task_id="$1"

	# Feature flag check — fall back to deterministic
	if [[ "$AI_DEPLOY_DECISIONS_ENABLED" != "true" ]]; then
		check_pr_status "$task_id"
		return 0
	fi

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local pr_url
	pr_url=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$escaped_id';")

	# If no PR URL stored, discover via centralized link_pr_to_task()
	if [[ -z "$pr_url" || "$pr_url" == "no_pr" || "$pr_url" == "task_only" ]]; then
		pr_url=$(link_pr_to_task "$task_id" --caller "ai_check_pr_status") || pr_url=""
		if [[ -z "$pr_url" ]]; then
			echo "no_pr|UNKNOWN"
			return 0
		fi
	fi

	# Parse PR URL
	local parsed_pr pr_number repo_slug
	parsed_pr=$(parse_pr_url "$pr_url") || parsed_pr=""
	if [[ -z "$parsed_pr" ]]; then
		echo "no_pr|UNKNOWN"
		return 0
	fi
	repo_slug="${parsed_pr%%|*}"
	pr_number="${parsed_pr##*|}"

	if [[ -z "$pr_number" || -z "$repo_slug" ]]; then
		echo "no_pr|UNKNOWN"
		return 0
	fi

	# GATHER: Fetch all PR data from GitHub API
	local pr_json
	pr_json=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json state,isDraft,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup \
		2>>"$SUPERVISOR_LOG" || echo "")

	if [[ -z "$pr_json" ]]; then
		# GitHub API failed — fall back to deterministic
		log_warn "ai_check_pr_status: GitHub API failed for $task_id, falling back to deterministic"
		check_pr_status "$task_id"
		return 0
	fi

	# Extract raw fields for the AI prompt
	local pr_state is_draft review_decision merge_state mergeable_state
	pr_state=$(printf '%s' "$pr_json" | jq -r '.state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
	is_draft=$(printf '%s' "$pr_json" | jq -r '.isDraft // false' 2>/dev/null || echo "false")
	review_decision=$(printf '%s' "$pr_json" | jq -r '.reviewDecision // "NONE"' 2>/dev/null || echo "NONE")
	merge_state=$(printf '%s' "$pr_json" | jq -r '.mergeStateStatus // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
	mergeable_state=$(printf '%s' "$pr_json" | jq -r '.mergeable // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

	# Handle lazy-loaded mergeStateStatus
	if [[ "$merge_state" == "UNKNOWN" ]]; then
		sleep 2
		local pr_json_retry
		pr_json_retry=$(gh pr view "$pr_number" --repo "$repo_slug" \
			--json mergeable,mergeStateStatus 2>>"$SUPERVISOR_LOG" || echo "")
		if [[ -n "$pr_json_retry" ]]; then
			merge_state=$(printf '%s' "$pr_json_retry" | jq -r '.mergeStateStatus // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
			mergeable_state=$(printf '%s' "$pr_json_retry" | jq -r '.mergeable // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
		fi
	fi

	# CI check details
	local check_rollup ci_summary
	check_rollup=$(printf '%s' "$pr_json" | jq -r '.statusCheckRollup // []' 2>/dev/null || echo "[]")
	if [[ "$check_rollup" != "[]" && "$check_rollup" != "null" ]]; then
		local pending failed passed total
		pending=$(printf '%s' "$check_rollup" | jq '[.[] | select(.status == "IN_PROGRESS" or .status == "QUEUED" or .status == "PENDING")] | length' 2>/dev/null || echo "0")
		failed=$(printf '%s' "$check_rollup" | jq '[.[] | select((.conclusion | test("FAILURE|TIMED_OUT|ACTION_REQUIRED")) or .state == "FAILURE" or .state == "ERROR")] | length' 2>/dev/null || echo "0")
		passed=$(printf '%s' "$check_rollup" | jq '[.[] | select(.conclusion == "SUCCESS" or .state == "SUCCESS")] | length' 2>/dev/null || echo "0")
		total=$(printf '%s' "$check_rollup" | jq 'length' 2>/dev/null || echo "0")

		local failed_names
		failed_names=$(printf '%s' "$check_rollup" | jq -r '[.[] | select((.conclusion | test("FAILURE|TIMED_OUT|ACTION_REQUIRED")) or .state == "FAILURE" or .state == "ERROR") | .name] | join(", ")' 2>/dev/null || echo "none")

		local sonar_action_pass sonar_gate_fail
		sonar_action_pass=$(printf '%s' "$check_rollup" | jq '[.[] | select(.name == "SonarCloud Analysis" and .conclusion == "SUCCESS")] | length' 2>/dev/null || echo "0")
		sonar_gate_fail=$(printf '%s' "$check_rollup" | jq '[.[] | select(.name == "SonarCloud Code Analysis" and .conclusion == "FAILURE")] | length' 2>/dev/null || echo "0")

		ci_summary="total:${total} passed:${passed} failed:${failed} pending:${pending} failed_names:[${failed_names}] sonar_action_pass:${sonar_action_pass} sonar_gate_fail:${sonar_gate_fail}"
	else
		ci_summary="no_checks"
	fi

	# Check for bot reviews that might be auto-dismissible
	local has_bot_changes_requested="false"
	if [[ "$review_decision" == "CHANGES_REQUESTED" ]]; then
		local reviews_json
		reviews_json=$(gh api "repos/${repo_slug}/pulls/${pr_number}/reviews" 2>>"$SUPERVISOR_LOG" || echo "[]")
		local bot_blocking
		bot_blocking=$(printf '%s' "$reviews_json" | jq '[.[] | select(.state == "CHANGES_REQUESTED" and (.user.login | test("^(coderabbitai|gemini-code-assist|copilot)")))] | length' 2>/dev/null || echo "0")
		if [[ "$bot_blocking" -gt 0 ]]; then
			has_bot_changes_requested="true"
		fi
	fi

	# JUDGE: Send structured data to AI
	local prompt
	prompt="You are classifying a GitHub PR's status for an automated deployment pipeline.

PR DATA:
- PR state: $pr_state
- Is draft: $is_draft
- Review decision: $review_decision
- Merge state status: $merge_state
- Mergeable: $mergeable_state
- CI checks: $ci_summary
- Bot reviews blocking: $has_bot_changes_requested

CLASSIFY into exactly ONE of these statuses:
- ready_to_merge: CI passed, no blocking reviews, PR is mergeable (CLEAN or UNSTABLE merge state)
- unstable_sonarcloud: SonarCloud GH Action passed but external quality gate failed (both sonar checks present, action passed, gate failed)
- ci_pending: CI checks still running, or PR needs rebase (BEHIND/DIRTY merge state)
- ci_failed: Required CI checks have failed
- changes_requested: Human reviewers requested changes (not just bot reviews)
- already_merged: PR state is MERGED
- draft: PR is a draft
- closed: PR was closed without merge
- no_pr: Cannot determine PR status

RULES:
- MERGED state → always already_merged
- CLOSED state → always closed
- Draft → always draft
- BEHIND or DIRTY merge state → ci_pending (needs rebase)
- BLOCKED with pending checks → ci_pending
- BLOCKED with failed checks → ci_failed
- BLOCKED with no CI issues → check review_decision
- UNSTABLE merge state with SonarCloud pattern → unstable_sonarcloud
- UNSTABLE without SonarCloud pattern → ready_to_merge (non-required checks failed)
- CLEAN merge state → ready_to_merge (unless CHANGES_REQUESTED by humans)
- CHANGES_REQUESTED only by bots → ready_to_merge (bots will be auto-dismissed)
- CHANGES_REQUESTED by humans → changes_requested

Respond with ONLY a JSON object, no markdown fencing:
{\"status\": \"<status>\", \"merge_state\": \"<merge_state_status>\", \"reason\": \"<brief reason>\"}"

	local ai_response
	if ai_response=$(_ai_deploy_call "$prompt" "pr-status-${task_id}"); then
		local json_result
		if json_result=$(_ai_deploy_extract_json "$ai_response"); then
			local ai_status ai_merge_state ai_reason
			ai_status=$(printf '%s' "$json_result" | jq -r '.status // ""' 2>/dev/null || echo "")
			ai_merge_state=$(printf '%s' "$json_result" | jq -r '.merge_state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
			ai_reason=$(printf '%s' "$json_result" | jq -r '.reason // ""' 2>/dev/null || echo "")

			# Validate the AI returned a known status
			case "$ai_status" in
			ready_to_merge | unstable_sonarcloud | ci_pending | ci_failed | changes_requested | already_merged | draft | closed | no_pr)
				# Handle bot review dismissal for ready_to_merge when CHANGES_REQUESTED
				if [[ "$ai_status" == "ready_to_merge" && "$has_bot_changes_requested" == "true" ]]; then
					log_info "ai_check_pr_status: dismissing bot reviews for $task_id before declaring ready_to_merge"
					dismiss_bot_reviews "$pr_number" "$repo_slug" 2>>"$SUPERVISOR_LOG" || true
				fi

				_ai_deploy_log_decision "ai_check_pr_status" "$task_id" \
					"$ai_status|$ai_merge_state ($ai_reason)" \
					"pr_state=$pr_state is_draft=$is_draft review=$review_decision merge_state=$merge_state ci=$ci_summary"
				log_info "ai_check_pr_status: $task_id → $ai_status|$ai_merge_state (AI: $ai_reason)"
				echo "${ai_status}|${ai_merge_state}"
				return 0
				;;
			*)
				log_warn "ai_check_pr_status: AI returned unknown status '$ai_status' for $task_id, falling back"
				;;
			esac
		else
			log_warn "ai_check_pr_status: failed to parse AI response for $task_id, falling back"
		fi
	else
		log_warn "ai_check_pr_status: AI call failed for $task_id, falling back to deterministic"
	fi

	# FALLBACK: Use original deterministic logic
	check_pr_status "$task_id"
	return 0
}

###############################################################################
# 2. AI-POWERED REVIEW TRIAGE
#
# Replaces: triage_review_feedback() in deploy.sh
# The original function uses keyword regex matching to classify review threads
# into severity levels (critical/high/medium/low/dismiss).
#
# The AI version:
# - Receives the same thread data
# - Classifies each thread with semantic understanding (not just keywords)
# - Understands context: "SQL injection" on an internal CLI tool is different
#   from "SQL injection" on a public web endpoint
# - Returns the same JSON format for compatibility
###############################################################################

#######################################
# AI-powered review feedback triage.
# Classifies review threads by severity using AI judgment.
#
# Args:
#   $1 - JSON array of threads (from check_review_threads)
# Outputs:
#   JSON with classified threads and summary (same format as triage_review_feedback)
# Returns:
#   0 on success
#######################################
ai_triage_review_feedback() {
	local threads_json="$1"

	local thread_count
	thread_count=$(printf '%s' "$threads_json" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$thread_count" -eq 0 ]]; then
		echo '{"threads":[],"summary":{"critical":0,"high":0,"medium":0,"low":0,"dismiss":0},"action":"merge"}'
		return 0
	fi

	# Feature flag check — fall back to deterministic
	if [[ "$AI_DEPLOY_DECISIONS_ENABLED" != "true" ]]; then
		triage_review_feedback "$threads_json"
		return 0
	fi

	# Build a concise thread summary for the AI prompt
	local thread_details
	thread_details=$(printf '%s' "$threads_json" | jq -r '.[] | "[\(.author)] \(.path):\(.line // "?"): \(.body | split("\n")[0] | .[0:300]) (isBot: \(.isBot))"' 2>/dev/null || echo "")

	local prompt
	prompt="You are triaging code review feedback on a PR for an automated deployment pipeline.

REVIEW THREADS ($thread_count total):
$thread_details

CLASSIFY each thread into exactly ONE severity level:
- critical: Security vulnerabilities, data loss, crashes, credential leaks — ONLY for genuine threats, not false positives from bot keyword matching
- high: Real bugs, logic errors, missing error handling that would cause runtime failures
- medium: Valid code quality improvements, performance issues, missing validation
- low: Style nits, naming suggestions, documentation, cosmetic issues
- dismiss: False positives, already addressed, bot noise, LGTM comments

IMPORTANT CONTEXT:
- Bot reviewers (gemini, coderabbit, copilot, codacy, sonar) often flag internal CLI tools for 'SQL injection' or 'credential leak' using keyword heuristics that lack threat-model context. An internal supervisor script using sqlite3 with escaped inputs is NOT a SQL injection vulnerability. Classify these as 'low' or 'dismiss', not 'critical'.
- Bot-sourced threads are generally lower severity than human-sourced threads.
- Consider whether the feedback is actionable and whether fixing it would meaningfully improve the code.

DECIDE the overall action:
- merge: All threads are low/dismiss, OR only bot-sourced medium threads (safe to merge)
- fix: Has high-severity threads from humans, OR critical threads from bots (dispatch fix worker)
- block: Has critical threads from HUMAN reviewers (needs human attention)

Respond with ONLY a JSON object, no markdown fencing:
{
  \"threads\": [{\"author\": \"...\", \"severity\": \"...\", \"isBot\": true/false}],
  \"summary\": {\"critical\": N, \"high\": N, \"medium\": N, \"low\": N, \"dismiss\": N, \"human_critical\": N, \"bot_critical\": N, \"human_high\": N, \"human_medium\": N, \"bot_high\": N, \"bot_medium\": N},
  \"action\": \"merge|fix|block\",
  \"reasoning\": \"brief explanation\"
}"

	local ai_response
	if ai_response=$(_ai_deploy_call "$prompt" "triage-review"); then
		local json_result
		if json_result=$(_ai_deploy_extract_json "$ai_response"); then
			local ai_action
			ai_action=$(printf '%s' "$json_result" | jq -r '.action // ""' 2>/dev/null || echo "")

			# Validate the AI returned a known action
			case "$ai_action" in
			merge | fix | block)
				# Ensure the response has the required summary fields
				local has_summary
				has_summary=$(printf '%s' "$json_result" | jq 'has("summary")' 2>/dev/null || echo "false")
				if [[ "$has_summary" == "true" ]]; then
					# Merge the AI-classified severities back onto the original thread data
					# so the output format matches what callers expect
					local enriched_result
					enriched_result=$(printf '%s' "$json_result" | jq --argjson orig "$threads_json" '
						# Preserve original thread data, add severity from AI classification
						.threads = [range(($orig | length)) as $i |
							$orig[$i] + (if $i < (.threads | length) then {severity: .threads[$i].severity} else {severity: "medium"} end)
						]
					' 2>/dev/null || echo "")

					if [[ -n "$enriched_result" ]]; then
						local ai_reasoning
						ai_reasoning=$(printf '%s' "$json_result" | jq -r '.reasoning // ""' 2>/dev/null || echo "")
						_ai_deploy_log_decision "ai_triage_review_feedback" "review" \
							"action=$ai_action ($ai_reasoning)" \
							"threads=$thread_count"
						log_info "ai_triage_review_feedback: action=$ai_action ($ai_reasoning)"
						printf '%s' "$enriched_result"
						return 0
					fi
				fi
				log_warn "ai_triage_review_feedback: AI response missing required fields, falling back"
				;;
			*)
				log_warn "ai_triage_review_feedback: AI returned unknown action '$ai_action', falling back"
				;;
			esac
		else
			log_warn "ai_triage_review_feedback: failed to parse AI response, falling back"
		fi
	else
		log_warn "ai_triage_review_feedback: AI call failed, falling back to deterministic"
	fi

	# FALLBACK: Use original deterministic keyword-based logic
	triage_review_feedback "$threads_json"
	return 0
}

###############################################################################
# 3. AI-POWERED DELIVERABLE VERIFICATION
#
# Replaces: verify_task_deliverables() in deploy.sh
# The original function checks:
# - PR exists and is merged
# - PR has substantive file changes (not just TODO.md)
# - Cross-contamination guard (PR references the task ID)
#
# The AI version:
# - Gathers the same data (PR state, changed files, task description)
# - AI evaluates whether the deliverables match the task requirements
# - Can understand that a "planning task" with only TODO.md changes is valid
# - Can detect when a PR's changes don't match the task description
###############################################################################

#######################################
# AI-powered task deliverable verification.
# Evaluates whether a PR's changes constitute valid deliverables for a task.
#
# Args:
#   $1 - task_id
#   $2 - pr_url (optional)
#   $3 - repo path (optional)
# Returns:
#   0 if verified, 1 if not
#######################################
ai_verify_task_deliverables() {
	local task_id="$1"
	local pr_url="${2:-}"
	local repo="${3:-}"

	# Skip verification for diagnostic subtasks (same as original)
	if [[ "$task_id" == *-diag-* ]]; then
		log_info "Skipping deliverable verification for diagnostic task $task_id"
		return 0
	fi

	# Feature flag check — fall back to deterministic
	if [[ "$AI_DEPLOY_DECISIONS_ENABLED" != "true" ]]; then
		verify_task_deliverables "$task_id" "$pr_url" "$repo"
		return $?
	fi

	# If no PR URL, task cannot be verified
	if [[ -z "$pr_url" || "$pr_url" == "no_pr" || "$pr_url" == "task_only" ]]; then
		log_warn "Task $task_id has no PR URL ($pr_url) - cannot verify deliverables"
		return 1
	fi

	# Parse PR URL
	local parsed_verify repo_slug pr_number
	parsed_verify=$(parse_pr_url "$pr_url") || parsed_verify=""
	if [[ -z "$parsed_verify" ]]; then
		log_warn "Cannot parse PR URL for $task_id: $pr_url"
		return 1
	fi
	repo_slug="${parsed_verify%%|*}"
	pr_number="${parsed_verify##*|}"

	# Pre-flight checks (same as original — these are hard requirements, not judgment calls)
	if ! command -v gh &>/dev/null; then
		log_warn "gh CLI not found; cannot verify deliverables for $task_id"
		return 1
	fi
	if ! check_gh_auth; then
		log_warn "gh CLI not authenticated; cannot verify deliverables for $task_id"
		return 1
	fi

	# Cross-contamination guard (hard requirement — not AI judgment)
	local deliverable_validated
	deliverable_validated=$(validate_pr_belongs_to_task "$task_id" "$repo_slug" "$pr_url") || deliverable_validated=""
	if [[ -z "$deliverable_validated" ]]; then
		log_warn "ai_verify_task_deliverables: PR #$pr_number does not reference $task_id — rejecting"
		return 1
	fi

	# GATHER: Fetch PR data
	local pr_state
	if ! pr_state=$(gh pr view "$pr_number" --repo "$repo_slug" --json state --jq '.state' 2>>"$SUPERVISOR_LOG"); then
		log_warn "Failed to fetch PR state for $task_id (#$pr_number)"
		return 1
	fi

	local changed_files
	if ! changed_files=$(gh pr view "$pr_number" --repo "$repo_slug" --json files --jq '.files[].path' 2>>"$SUPERVISOR_LOG"); then
		log_warn "Failed to fetch PR files for $task_id (#$pr_number)"
		return 1
	fi

	local file_count
	file_count=$(printf '%s' "$changed_files" | wc -l | tr -d ' ')

	# Get task description from DB for context
	local task_description=""
	if [[ -n "${SUPERVISOR_DB:-}" && -f "${SUPERVISOR_DB:-}" ]]; then
		local escaped_id
		escaped_id=$(sql_escape "$task_id")
		task_description=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	fi

	# Get task line from TODO.md for tag context
	local task_tags=""
	if [[ -n "$repo" && -f "$repo/TODO.md" ]]; then
		local task_line
		task_line=$(grep -E "^\s*- \[.\] $task_id\b" "$repo/TODO.md" 2>/dev/null || echo "")
		if [[ -n "$task_line" ]]; then
			task_tags=$(printf '%s' "$task_line" | grep -oE '#[a-z]+' | tr '\n' ' ' || echo "")
		fi
	fi

	# Separate substantive vs planning files (for context)
	local substantive_files planning_files
	substantive_files=$(printf '%s' "$changed_files" | grep -vE '^(TODO\.md$|todo/|\.github/workflows/)' || echo "")
	planning_files=$(printf '%s' "$changed_files" | grep -E '^(TODO\.md$|todo/|\.github/workflows/)' || echo "")

	local substantive_count planning_count
	substantive_count=$(printf '%s' "$substantive_files" | grep -c '.' 2>/dev/null || echo "0")
	planning_count=$(printf '%s' "$planning_files" | grep -c '.' 2>/dev/null || echo "0")

	# JUDGE: Send to AI
	local prompt
	prompt="You are verifying whether a PR's changes constitute valid deliverables for a task.

TASK: $task_id
TASK DESCRIPTION: ${task_description:-unknown}
TASK TAGS: ${task_tags:-none}
PR #$pr_number STATE: $pr_state
TOTAL FILES CHANGED: $file_count
SUBSTANTIVE FILES ($substantive_count): $(printf '%s' "$substantive_files" | head -20 | tr '\n' ', ')
PLANNING FILES ($planning_count): $(printf '%s' "$planning_files" | head -10 | tr '\n' ', ')

VERIFY these criteria:
1. PR must be MERGED (hard requirement)
2. PR must have changes that match the task's purpose
3. Planning tasks (#plan, #audit, #chore, #docs) are valid with only planning file changes
4. Code tasks should have substantive file changes (not just TODO.md)
5. The changes should be proportional to the task scope

Respond with ONLY a JSON object, no markdown fencing:
{\"verified\": true/false, \"reason\": \"brief explanation\", \"category\": \"code|planning|mixed\"}"

	local ai_response
	if ai_response=$(_ai_deploy_call "$prompt" "verify-${task_id}"); then
		local json_result
		if json_result=$(_ai_deploy_extract_json "$ai_response"); then
			local ai_verified ai_reason ai_category
			ai_verified=$(printf '%s' "$json_result" | jq -r '.verified // ""' 2>/dev/null || echo "")
			ai_reason=$(printf '%s' "$json_result" | jq -r '.reason // ""' 2>/dev/null || echo "")
			ai_category=$(printf '%s' "$json_result" | jq -r '.category // "unknown"' 2>/dev/null || echo "unknown")

			if [[ "$ai_verified" == "true" ]]; then
				_ai_deploy_log_decision "ai_verify_task_deliverables" "$task_id" \
					"VERIFIED ($ai_category): $ai_reason" \
					"pr_state=$pr_state files=$file_count substantive=$substantive_count"

				# Write proof-log entry (same as original)
				write_proof_log --task "$task_id" --event "deliverable_verified" --stage "complete" \
					--decision "verified:PR#$pr_number:ai_judgment:$ai_category" \
					--evidence "pr_state=$pr_state,file_count=$file_count,substantive=$substantive_count,ai_reason=$ai_reason" \
					--maker "ai_verify_task_deliverables" \
					--pr-url "$pr_url" 2>/dev/null || true

				log_info "ai_verify_task_deliverables: $task_id VERIFIED ($ai_category: $ai_reason)"
				return 0
			elif [[ "$ai_verified" == "false" ]]; then
				_ai_deploy_log_decision "ai_verify_task_deliverables" "$task_id" \
					"REJECTED: $ai_reason" \
					"pr_state=$pr_state files=$file_count substantive=$substantive_count"
				log_warn "ai_verify_task_deliverables: $task_id REJECTED ($ai_reason)"
				return 1
			else
				log_warn "ai_verify_task_deliverables: AI returned ambiguous verified='$ai_verified' for $task_id, falling back"
			fi
		else
			log_warn "ai_verify_task_deliverables: failed to parse AI response for $task_id, falling back"
		fi
	else
		log_warn "ai_verify_task_deliverables: AI call failed for $task_id, falling back to deterministic"
	fi

	# FALLBACK: Use original deterministic logic
	verify_task_deliverables "$task_id" "$pr_url" "$repo"
	return $?
}
