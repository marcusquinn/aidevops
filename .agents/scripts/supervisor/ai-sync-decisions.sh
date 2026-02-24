#!/usr/bin/env bash
# ai-sync-decisions.sh - AI judgment for sync decision logic (t1318)
#
# Migrates four deterministic decision functions to AI judgment:
#   1. check_task_staleness()          → ai_check_task_staleness()
#   2. handle_stale_task()             → ai_handle_stale_task()
#   3. recover_stale_claims()          → ai_recover_stale_claims()
#   4. auto_unblock_resolved_tasks()   → ai_auto_unblock_resolved_tasks()
#
# Architecture: GATHER (shell) → JUDGE (AI) → EXECUTE (shell)
# - Shell gathers all data (DB, TODO.md, git, worktrees)
# - AI receives structured data and makes the judgment call
# - Shell parses AI response and executes the decision
# - Falls back to deterministic logic if AI is unavailable or returns garbage
#
# Label sync, git commit/push, and DB writes remain 100% shell.
#
# Sourced by: supervisor-helper.sh (after issue-sync.sh and todo-sync.sh)
# Depends on: issue-sync.sh (check_task_staleness, handle_stale_task)
#             todo-sync.sh (recover_stale_claims, auto_unblock_resolved_tasks)
#             dispatch.sh (resolve_ai_cli, resolve_model)
#             _common.sh (portable_timeout, log_*)

# Globals expected from supervisor-helper.sh:
#   SUPERVISOR_DB, SUPERVISOR_LOG, SUPERVISOR_DIR
#   db(), log_info(), log_warn(), log_error(), log_success(), sql_escape()
#   resolve_ai_cli(), resolve_model(), portable_timeout()
#   check_task_staleness(), handle_stale_task() (from issue-sync.sh)
#   recover_stale_claims(), auto_unblock_resolved_tasks() (from todo-sync.sh)
#   get_aidevops_identity(), cmd_unclaim(), commit_and_push_todo()

# Feature flag: enable/disable AI sync decisions (default: enabled)
AI_SYNC_DECISIONS_ENABLED="${AI_SYNC_DECISIONS_ENABLED:-true}"

# Model tier for sync decisions — sonnet is sufficient for structured
# classification tasks. Staleness analysis benefits from reasoning but
# the data is pre-gathered, so sonnet handles it well.
AI_SYNC_DECISIONS_MODEL="${AI_SYNC_DECISIONS_MODEL:-sonnet}"

# Timeout for AI judgment calls (seconds)
AI_SYNC_DECISIONS_TIMEOUT="${AI_SYNC_DECISIONS_TIMEOUT:-30}"

# Log directory for decision audit trail
AI_SYNC_DECISIONS_LOG_DIR="${AI_SYNC_DECISIONS_LOG_DIR:-$HOME/.aidevops/logs/ai-sync-decisions}"

#######################################
# Internal: Call AI CLI with a prompt and return the raw response.
# Reuses the same pattern as ai-deploy-decisions.sh.
#
# Args:
#   $1 - prompt text
#   $2 - title suffix for session naming
# Outputs:
#   Raw AI response on stdout (ANSI-stripped)
# Returns:
#   0 on success, 1 on failure (empty response or CLI unavailable)
#######################################
_ai_sync_call() {
	local prompt="$1"
	local title_suffix="$2"

	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || {
		log_warn "ai-sync-decisions: no AI CLI available"
		return 1
	}

	local ai_model
	ai_model=$(resolve_model "$AI_SYNC_DECISIONS_MODEL" "$ai_cli" 2>/dev/null) || {
		log_warn "ai-sync-decisions: model $AI_SYNC_DECISIONS_MODEL unavailable"
		return 1
	}

	local ai_result=""
	local timeout_secs="$AI_SYNC_DECISIONS_TIMEOUT"

	if [[ "$ai_cli" == "opencode" ]]; then
		ai_result=$(portable_timeout "$timeout_secs" opencode run \
			-m "$ai_model" \
			--format default \
			--title "sync-${title_suffix}-$$" \
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
_ai_sync_extract_json() {
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

	# Try 3: Multi-line JSON object (between { and })
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
# Internal: Log an AI sync decision for audit trail.
#
# Args:
#   $1 - function name
#   $2 - identifier (task_id or repo_path)
#   $3 - decision summary
#   $4 - (optional) full context for the log file
#######################################
_ai_sync_log_decision() {
	local func_name="$1"
	local identifier="$2"
	local decision="$3"
	local context="${4:-}"

	mkdir -p "$AI_SYNC_DECISIONS_LOG_DIR" 2>/dev/null || true

	local timestamp
	timestamp=$(date -u '+%Y%m%d-%H%M%S')
	# Sanitize identifier for filename (replace / with -)
	local safe_id
	safe_id=$(printf '%s' "$identifier" | tr '/' '-' | head -c 40)
	local log_file="$AI_SYNC_DECISIONS_LOG_DIR/${func_name}-${safe_id}-${timestamp}.md"

	{
		echo "# $func_name: $identifier @ $timestamp"
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
# 1. AI-POWERED TASK STALENESS CHECK
#
# Replaces: check_task_staleness() in issue-sync.sh
# The original function has ~180 lines of heuristic signal detection:
#   - Feature name extraction + removal commit scanning
#   - File path existence checks
#   - Parent task removal detection
#   - "Already done" pattern matching
#   - Three-tier threshold scoring (signals >= 3 = STALE, 2 = UNCERTAIN)
#
# The AI version:
# - Shell gathers the same raw signals (git log, file existence, codebase refs)
# - AI receives structured evidence and makes the judgment call
# - AI can weigh nuanced context that heuristics miss (e.g., a "removal" commit
#   that was actually a rename, or a missing file that was intentionally moved)
# - Falls back to deterministic check_task_staleness() on AI failure
###############################################################################

#######################################
# AI-powered task staleness check.
# Gathers evidence about task validity, asks AI to classify.
#
# Args:
#   $1 - task_id
#   $2 - task_description
#   $3 - project_root (default: ".")
# Outputs:
#   Staleness reason on stdout (if stale/uncertain), empty if current
# Returns:
#   0 = STALE (cancel it)
#   1 = CURRENT (safe to dispatch)
#   2 = UNCERTAIN (needs human review)
#######################################
ai_check_task_staleness() {
	# Allow bypassing staleness check via env var (t314)
	if [[ "${SUPERVISOR_SKIP_STALENESS:-false}" == "true" ]]; then
		return 1
	fi

	local task_id="${1:-}"
	local task_description="${2:-}"
	local project_root="${3:-.}"

	if [[ -z "$task_id" || -z "$task_description" ]]; then
		return 1
	fi

	# Feature flag check — fall back to deterministic
	if [[ "$AI_SYNC_DECISIONS_ENABLED" != "true" ]]; then
		check_task_staleness "$task_id" "$task_description" "$project_root"
		return $?
	fi

	# --- GATHER: Collect evidence for AI judgment ---

	# Signal 1: Feature/tool names and their removal commits
	local feature_names=""
	feature_names=$(printf '%s' "$task_description" |
		grep -oE '[a-zA-Z][a-zA-Z0-9]*-[a-zA-Z][a-zA-Z0-9]+(-[a-zA-Z][a-zA-Z0-9]+)*' |
		sort -u) || true

	local quoted_terms=""
	quoted_terms=$(printf '%s' "$task_description" |
		grep -oE '"[^"]{3,}"' | tr -d '"' | sort -u) || true

	local all_terms=""
	all_terms=$(printf '%s\n%s' "$feature_names" "$quoted_terms" |
		grep -v '^$' | sort -u) || true

	local removal_evidence=""
	if [[ -n "$all_terms" ]]; then
		while IFS= read -r term; do
			[[ -z "$term" ]] && continue

			local removal_commits=""
			removal_commits=$(git -C "$project_root" log --oneline -200 \
				--grep="$term" 2>/dev/null |
				grep -iE "remov|delet|drop|deprecat|clean.?up|refactor.*remov" |
				head -3) || true

			local codebase_refs=0
			codebase_refs=$(git -C "$project_root" grep -rl "$term" \
				-- '*.sh' '*.md' '*.mjs' '*.ts' '*.json' 2>/dev/null |
				grep -cv 'TODO.md\|CHANGELOG.md\|VERIFY.md\|PLANS.md\|verification\|todo/' \
					2>/dev/null) || true

			if [[ -n "$removal_commits" || "$codebase_refs" -eq 0 ]]; then
				removal_evidence="${removal_evidence}Term: '${term}' | Removal commits: ${removal_commits:-none} | Active codebase refs: ${codebase_refs}
"
			fi
		done <<<"$all_terms"
	fi

	# Signal 2: File path references and existence
	local file_evidence=""
	local file_refs=""
	file_refs=$(printf '%s' "$task_description" |
		grep -oE '[a-zA-Z0-9_/-]+\.[a-z]{1,4}' |
		grep -vE '^\.' |
		sort -u) || true

	if [[ -n "$file_refs" ]]; then
		local missing_files=0
		local total_files=0
		while IFS= read -r file_ref; do
			[[ -z "$file_ref" ]] && continue
			total_files=$((total_files + 1))

			local found=false
			if git -C "$project_root" ls-files --error-unmatch "$file_ref" &>/dev/null 2>&1; then
				found=true
			else
				for prefix in ".agents/" ".agents/scripts/" ".agents/tools/" ""; do
					if git -C "$project_root" ls-files --error-unmatch \
						"${prefix}${file_ref}" &>/dev/null 2>&1; then
						found=true
						break
					fi
				done
			fi
			if [[ "$found" == "false" ]]; then
				missing_files=$((missing_files + 1))
				file_evidence="${file_evidence}MISSING: ${file_ref}
"
			fi
		done <<<"$file_refs"
		file_evidence="Files referenced: ${total_files}, Missing: ${missing_files}
${file_evidence}"
	fi

	# Signal 3: Parent task removal (for subtasks)
	local parent_evidence=""
	if [[ "$task_id" =~ ^(t[0-9]+)\.[0-9]+$ ]]; then
		local parent_id="${BASH_REMATCH[1]}"
		local parent_removal=""
		parent_removal=$(git -C "$project_root" log --oneline -200 \
			--grep="$parent_id" 2>/dev/null |
			grep -iE "remov|delet|drop|deprecat" |
			head -1) || true
		if [[ -n "$parent_removal" ]]; then
			parent_evidence="Parent $parent_id has removal commits: $parent_removal"
		fi
	fi

	# Signal 4: "Already done" evidence
	local done_evidence=""
	local task_verb=""
	task_verb=$(printf '%s' "$task_description" |
		grep -oE '^(add|create|implement|build|set up|integrate|fix|resolve)' |
		head -1) || true

	if [[ "$task_verb" =~ ^(add|create|implement|build|integrate) ]]; then
		local subject=""
		subject=$(printf '%s' "$task_description" |
			sed -E "s/^(add|create|implement|build|set up|integrate) //i" |
			cut -d' ' -f1-3) || true
		if [[ -n "$subject" ]]; then
			local existing_refs=0
			existing_refs=$(git -C "$project_root" log --oneline -50 \
				--grep="$subject" 2>/dev/null |
				grep -icE "add|creat|implement|built|integrat" 2>/dev/null) || true
			if [[ "$existing_refs" -ge 1 ]]; then
				done_evidence="Subject '$subject' has $existing_refs existing implementation commits"
			fi
		fi
	fi

	# --- JUDGE: Ask AI to classify staleness ---
	local prompt
	prompt="You are a pre-dispatch staleness checker for an automated task pipeline.

Given the evidence below, classify whether this task is still valid or outdated.

TASK: $task_id
DESCRIPTION: $task_description

EVIDENCE:

1. Feature/term removal signals:
${removal_evidence:-No removal evidence found.}

2. File reference checks:
${file_evidence:-No file references in description.}

3. Parent task signals:
${parent_evidence:-No parent task concerns.}

4. Already-done signals:
${done_evidence:-No already-done evidence.}

CLASSIFICATION RULES:
- STALE: The task's premise is clearly invalid. Key features were removed, all referenced files are gone, or the work was already completed. The task should be cancelled.
- UNCERTAIN: Some staleness signals exist but are inconclusive. A feature may have been renamed rather than removed, or files may have moved. Needs human review.
- CURRENT: The task appears valid. No significant staleness signals, or the signals are weak/explainable.

Respond with ONLY a JSON object (no markdown fencing):
{\"verdict\": \"STALE|UNCERTAIN|CURRENT\", \"reason\": \"Brief explanation of your judgment\", \"confidence\": \"high|medium|low\"}"

	local ai_response
	ai_response=$(_ai_sync_call "$prompt" "staleness-${task_id}") || {
		log_warn "ai_check_task_staleness: AI unavailable for $task_id, falling back to deterministic"
		check_task_staleness "$task_id" "$task_description" "$project_root"
		return $?
	}

	# --- RETURN: Parse AI response ---
	local ai_json
	ai_json=$(_ai_sync_extract_json "$ai_response") || {
		log_warn "ai_check_task_staleness: AI response unparseable for $task_id, falling back"
		check_task_staleness "$task_id" "$task_description" "$project_root"
		return $?
	}

	local verdict
	verdict=$(printf '%s' "$ai_json" | jq -r '.verdict // empty' 2>/dev/null || echo "")
	local reason
	reason=$(printf '%s' "$ai_json" | jq -r '.reason // empty' 2>/dev/null || echo "")

	# Validate verdict
	case "$verdict" in
	STALE)
		_ai_sync_log_decision "ai_check_task_staleness" "$task_id" "STALE: $reason" "$prompt"
		printf '%s' "$reason"
		return 0
		;;
	UNCERTAIN)
		_ai_sync_log_decision "ai_check_task_staleness" "$task_id" "UNCERTAIN: $reason" "$prompt"
		printf '%s' "$reason"
		return 2
		;;
	CURRENT)
		_ai_sync_log_decision "ai_check_task_staleness" "$task_id" "CURRENT: $reason" "$prompt"
		return 1
		;;
	*)
		# Invalid verdict — fall back to deterministic
		log_warn "ai_check_task_staleness: invalid verdict '$verdict' for $task_id, falling back"
		_ai_sync_log_decision "ai_check_task_staleness" "$task_id" "FALLBACK: invalid verdict '$verdict'" "$prompt"
		check_task_staleness "$task_id" "$task_description" "$project_root"
		return $?
		;;
	esac
}

###############################################################################
# 2. AI-POWERED STALE TASK HANDLER
#
# Replaces: handle_stale_task() in issue-sync.sh
# The original function acts on staleness detection results:
#   - STALE (exit 0): cancel in DB
#   - UNCERTAIN (exit 2): comment on GH issue, remove #auto-dispatch, block in DB
#
# The AI version:
# - Receives the staleness verdict and context
# - Decides the appropriate action (cancel, block, or override to current)
# - AI can override a STALE verdict if it detects the heuristic was wrong
# - Shell executes the decided action (DB writes, git commits, GH API calls)
###############################################################################

#######################################
# AI-powered stale task handler.
# Decides what action to take for a stale/uncertain task.
#
# Args:
#   $1 - task_id
#   $2 - staleness_exit (0=STALE, 2=UNCERTAIN)
#   $3 - staleness_reason
#   $4 - project_root (default: ".")
# Returns:
#   0 on action taken, 1 if no action needed (CURRENT)
#######################################
ai_handle_stale_task() {
	local task_id="${1:-}"
	local staleness_exit="${2:-1}"
	local staleness_reason="${3:-}"
	local project_root="${4:-.}"

	# Feature flag check — fall back to deterministic
	if [[ "$AI_SYNC_DECISIONS_ENABLED" != "true" ]]; then
		handle_stale_task "$task_id" "$staleness_exit" "$staleness_reason" "$project_root"
		return $?
	fi

	# If CURRENT, no action needed
	if [[ "$staleness_exit" -eq 1 ]]; then
		return 1
	fi

	# --- GATHER: Build context for AI ---
	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	local task_description=""
	task_description=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")

	local task_status=""
	task_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")

	local todo_line=""
	local todo_file="$project_root/TODO.md"
	if [[ -f "$todo_file" ]]; then
		todo_line=$(grep -E "^[[:space:]]*- \[.\] ${task_id}[[:space:]]" "$todo_file" | head -1 || echo "")
	fi

	local verdict_label="STALE"
	if [[ "$staleness_exit" -eq 2 ]]; then
		verdict_label="UNCERTAIN"
	fi

	# --- JUDGE: Ask AI what action to take ---
	local prompt
	prompt="You are a task lifecycle manager for an automated pipeline.

A pre-dispatch staleness check returned ${verdict_label} for this task. Decide what action to take.

TASK: $task_id
DESCRIPTION: $task_description
DB STATUS: $task_status
TODO.md LINE: $todo_line
STALENESS REASON: $staleness_reason

AVAILABLE ACTIONS:
- cancel: Task is clearly outdated. Cancel in DB, no further dispatch.
- block_for_review: Staleness is uncertain. Remove #auto-dispatch tag, post comment on GitHub issue, mark blocked in DB. Awaits human review.
- override_current: The staleness detection was wrong. Task is actually valid. Take no action, allow dispatch to proceed.

DECISION RULES:
- If the staleness reason mentions features that were genuinely removed (0 active refs, removal commits), choose 'cancel'.
- If the staleness reason is about missing files that may have been renamed/moved, choose 'block_for_review'.
- If the evidence is weak (only 1-2 signals, low confidence), choose 'override_current'.
- When in doubt, prefer 'block_for_review' over 'cancel' — human review is safer than premature cancellation.

Respond with ONLY a JSON object (no markdown fencing):
{\"action\": \"cancel|block_for_review|override_current\", \"reason\": \"Brief explanation\"}"

	local ai_response
	ai_response=$(_ai_sync_call "$prompt" "stale-action-${task_id}") || {
		log_warn "ai_handle_stale_task: AI unavailable for $task_id, falling back"
		handle_stale_task "$task_id" "$staleness_exit" "$staleness_reason" "$project_root"
		return $?
	}

	local ai_json
	ai_json=$(_ai_sync_extract_json "$ai_response") || {
		log_warn "ai_handle_stale_task: AI response unparseable for $task_id, falling back"
		handle_stale_task "$task_id" "$staleness_exit" "$staleness_reason" "$project_root"
		return $?
	}

	local action
	action=$(printf '%s' "$ai_json" | jq -r '.action // empty' 2>/dev/null || echo "")
	local ai_reason
	ai_reason=$(printf '%s' "$ai_json" | jq -r '.reason // empty' 2>/dev/null || echo "")

	# --- EXECUTE: Carry out the AI's decision ---
	case "$action" in
	cancel)
		_ai_sync_log_decision "ai_handle_stale_task" "$task_id" "CANCEL: $ai_reason" "$prompt"
		log_warn "Task $task_id is STALE (AI judgment) — cancelling: $ai_reason"
		db "$SUPERVISOR_DB" "UPDATE tasks SET status='cancelled', error='AI staleness judgment: ${ai_reason:0:200}' WHERE id='$escaped_id';"
		return 0
		;;
	block_for_review)
		_ai_sync_log_decision "ai_handle_stale_task" "$task_id" "BLOCK_FOR_REVIEW: $ai_reason" "$prompt"
		log_warn "Task $task_id has uncertain staleness (AI judgment) — blocking for review: $ai_reason"

		# Remove #auto-dispatch from TODO.md
		if [[ -f "$todo_file" ]] && grep -q "^[[:space:]]*- \[ \] ${task_id}[[:space:]].*#auto-dispatch" "$todo_file" 2>/dev/null; then
			sed -i.bak "s/\(- \[ \] ${task_id}[[:space:]].*\) #auto-dispatch/\1/" "$todo_file"
			rm -f "${todo_file}.bak"
			log_info "Removed #auto-dispatch from $task_id in TODO.md"

			if ! git -C "$project_root" diff --quiet "$todo_file" 2>/dev/null; then
				git -C "$project_root" add "$todo_file" 2>/dev/null || true
				git -C "$project_root" commit -q -m "chore: pause $task_id — AI staleness check uncertain, removed #auto-dispatch (t1318)" 2>/dev/null || true
				git -C "$project_root" push -q 2>/dev/null || true
			fi
		fi

		# Comment on GitHub issue if ref:GH# exists
		local gh_issue=""
		if [[ -f "$todo_file" ]]; then
			gh_issue=$(grep "^[[:space:]]*- \[.\] ${task_id}[[:space:]]" "$todo_file" 2>/dev/null |
				grep -oE 'ref:GH#[0-9]+' | grep -oE '[0-9]+' | head -1) || true
		fi

		if [[ -n "$gh_issue" ]] && command -v gh &>/dev/null; then
			local repo_slug=""
			repo_slug=$(detect_repo_slug "$project_root" 2>/dev/null) || true
			if [[ -n "$repo_slug" ]]; then
				local comment_body="**AI Staleness Check (t1318)**: This task may be outdated. Removing \`#auto-dispatch\` until reviewed.

**AI Judgment:** ${ai_reason}

**Action needed:** Review whether this task is still relevant. If yes, re-add \`#auto-dispatch\`. If not, mark as \`[-]\` (declined)."

				gh issue comment "$gh_issue" --repo "$repo_slug" \
					--body "$comment_body" 2>/dev/null || true
				log_info "Posted AI staleness comment on GH#$gh_issue"
			fi
		fi

		# Mark as blocked in DB
		db "$SUPERVISOR_DB" "UPDATE tasks SET status='blocked', error='AI staleness uncertain — awaiting review: ${ai_reason:0:200}' WHERE id='$escaped_id';" 2>/dev/null || true
		return 0
		;;
	override_current)
		_ai_sync_log_decision "ai_handle_stale_task" "$task_id" "OVERRIDE_CURRENT: $ai_reason" "$prompt"
		log_info "Task $task_id staleness overridden by AI — task is current: $ai_reason"
		return 1
		;;
	*)
		# Invalid action — fall back to deterministic
		log_warn "ai_handle_stale_task: invalid action '$action' for $task_id, falling back"
		_ai_sync_log_decision "ai_handle_stale_task" "$task_id" "FALLBACK: invalid action '$action'" "$prompt"
		handle_stale_task "$task_id" "$staleness_exit" "$staleness_reason" "$project_root"
		return $?
		;;
	esac
}

###############################################################################
# 3. AI-POWERED STALE CLAIM RECOVERY
#
# Replaces: recover_stale_claims() in todo-sync.sh
# The original function has ~185 lines of deterministic checks:
#   - Ownership verification (assignee matches local user)
#   - DB active state check
#   - Worktree existence check
#   - Claim age threshold check
#   - Unconditional unclaim if all checks pass
#
# The AI version:
# - Shell gathers the same data (ownership, DB state, worktrees, claim age)
# - AI receives a batch of stale claim candidates and decides which to recover
# - AI can consider context the heuristics miss (e.g., a task that's about to
#   be picked up by a scheduled batch, or a claim that's stale but the work
#   is partially done in an uncommitted worktree)
# - Shell executes the unclaim operations
###############################################################################

#######################################
# AI-powered stale claim recovery.
# Gathers claim data, asks AI which claims to recover.
#
# Args:
#   $1 - repo path containing TODO.md
# Returns:
#   0 on success (including no stale claims found)
#   1 on failure (TODO.md not found)
#######################################
ai_recover_stale_claims() {
	local repo_path="$1"
	local todo_file="$repo_path/TODO.md"

	if [[ ! -f "$todo_file" ]]; then
		log_verbose "ai_recover_stale_claims: TODO.md not found at $todo_file"
		return 1
	fi

	# Feature flag check — fall back to deterministic
	if [[ "$AI_SYNC_DECISIONS_ENABLED" != "true" ]]; then
		recover_stale_claims "$repo_path"
		return $?
	fi

	# --- GATHER: Collect all claim candidates ---
	local stale_threshold="${SUPERVISOR_STALE_CLAIM_SECONDS:-86400}"
	local identity
	identity=$(get_aidevops_identity)
	local now_epoch
	now_epoch=$(date +%s 2>/dev/null || echo "0")

	local active_worktrees=""
	active_worktrees=$(git -C "$repo_path" worktree list --porcelain 2>/dev/null | grep '^worktree ' | sed 's/^worktree //' || true)

	local active_db_tasks=""
	if [[ -n "${SUPERVISOR_DB:-}" && -f "${SUPERVISOR_DB}" ]]; then
		active_db_tasks=$(db "$SUPERVISOR_DB" "
			SELECT id FROM tasks
			WHERE status IN ('running', 'dispatched', 'evaluating', 'queued', 'pr_review', 'review_triage', 'merging')
			ORDER BY id;
		" 2>/dev/null || true)
	fi

	local local_user
	local_user=$(whoami 2>/dev/null || echo "")
	local gh_user="${_CACHED_GH_USERNAME:-}"
	local identity_user="${identity%%@*}"

	# Build candidate list with all relevant data
	local candidates=""
	local candidate_count=0

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue

		local task_id=""
		task_id=$(printf '%s' "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		[[ -z "$task_id" ]] && continue

		local assignee=""
		assignee=$(printf '%s' "$line" | grep -oE 'assignee:[A-Za-z0-9._@-]+' | tail -1 | sed 's/assignee://' || echo "")

		local started_ts=""
		started_ts=$(printf '%s' "$line" | grep -oE 'started:[0-9T:Z-]+' | tail -1 | sed 's/started://' || echo "")

		# Check ownership
		local is_local_user=false
		if [[ -n "$assignee" ]]; then
			if [[ "$assignee" == "$identity" ]] ||
				[[ "$assignee" == "$local_user" ]] ||
				[[ -n "$gh_user" && "$assignee" == "$gh_user" ]] ||
				[[ "$assignee" == "$identity_user" ]] ||
				[[ "${assignee%%@*}" == "$identity_user" ]]; then
				is_local_user=true
			fi
		fi

		# Check DB active state
		local in_db_active=false
		if [[ -n "$active_db_tasks" ]] && echo "$active_db_tasks" | grep -qE "^${task_id}$"; then
			in_db_active=true
		fi

		# Check worktree
		local has_worktree=false
		if [[ -n "$active_worktrees" ]] && echo "$active_worktrees" | grep -qE "[-./]${task_id}([^0-9.]|$)"; then
			has_worktree=true
		fi

		# Calculate claim age
		local claim_age_seconds="unknown"
		if [[ -n "$started_ts" ]]; then
			local started_epoch=0
			started_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_ts" "+%s" 2>/dev/null ||
				date -d "$started_ts" "+%s" 2>/dev/null ||
				echo "0")
			if [[ "$started_epoch" -gt 0 ]]; then
				claim_age_seconds=$((now_epoch - started_epoch))
			fi
		fi

		candidates="${candidates}task_id:${task_id} | assignee:${assignee:-none} | is_local:${is_local_user} | in_db_active:${in_db_active} | has_worktree:${has_worktree} | claim_age_seconds:${claim_age_seconds} | started:${started_ts:-none}
"
		candidate_count=$((candidate_count + 1))
	done < <(grep -E '^\s*- \[ \] t[0-9]+.*(assignee:|started:)' "$todo_file" || true)

	# If no candidates, nothing to do
	if [[ "$candidate_count" -eq 0 ]]; then
		log_verbose "ai_recover_stale_claims: no claimed tasks found"
		return 0
	fi

	# --- JUDGE: Ask AI which claims to recover ---
	local prompt
	prompt="You are a stale-claim recovery agent for an automated task pipeline.

Tasks get claimed (assignee: + started:) when a worker starts on them. If the worker dies or moves on without completing, the claim becomes stale and blocks re-dispatch.

Review these claimed tasks and decide which claims should be recovered (unclaimed).

LOCAL IDENTITY: $identity
STALE THRESHOLD: ${stale_threshold}s ($((stale_threshold / 3600))h)

CANDIDATES:
${candidates}

RECOVERY RULES:
- ONLY recover claims where is_local=true (we own the claim). NEVER touch external claims.
- Do NOT recover if in_db_active=true (worker is tracked in supervisor DB).
- Do NOT recover if has_worktree=true (active worktree exists for the task).
- Recover if claim_age_seconds > ${stale_threshold} AND none of the above blockers apply.
- If claim_age_seconds is 'unknown' (unparseable timestamp), skip conservatively.
- If assignee is 'none' (no assignee field), skip — ownership unverifiable.

Respond with ONLY a JSON object (no markdown fencing):
{\"recover\": [\"t123\", \"t456\"], \"skip\": [\"t789\"], \"reasoning\": \"Brief explanation\"}"

	local ai_response
	ai_response=$(_ai_sync_call "$prompt" "stale-claims") || {
		log_warn "ai_recover_stale_claims: AI unavailable, falling back to deterministic"
		recover_stale_claims "$repo_path"
		return $?
	}

	local ai_json
	ai_json=$(_ai_sync_extract_json "$ai_response") || {
		log_warn "ai_recover_stale_claims: AI response unparseable, falling back"
		recover_stale_claims "$repo_path"
		return $?
	}

	# --- EXECUTE: Unclaim the tasks AI selected ---
	local recover_ids
	recover_ids=$(printf '%s' "$ai_json" | jq -r '.recover[]? // empty' 2>/dev/null || echo "")
	local ai_reasoning
	ai_reasoning=$(printf '%s' "$ai_json" | jq -r '.reasoning // empty' 2>/dev/null || echo "")

	if [[ -z "$recover_ids" ]]; then
		_ai_sync_log_decision "ai_recover_stale_claims" "$repo_path" "No claims to recover: $ai_reasoning" "$prompt"
		log_verbose "ai_recover_stale_claims: AI decided no claims to recover"
		return 0
	fi

	local recovered_count=0
	local recovered_list=""

	while IFS= read -r tid; do
		[[ -z "$tid" ]] && continue

		if cmd_unclaim "$tid" "$repo_path" --force 2>>"${SUPERVISOR_LOG:-/dev/null}"; then
			recovered_count=$((recovered_count + 1))
			if [[ -n "$recovered_list" ]]; then
				recovered_list="${recovered_list}, ${tid}"
			else
				recovered_list="$tid"
			fi
			log_success "  Phase 0.5e (AI): Recovered $tid — assignee: and started: stripped"
		else
			log_warn "  Phase 0.5e (AI): Failed to unclaim $tid"
		fi
	done <<<"$recover_ids"

	if [[ "$recovered_count" -gt 0 ]]; then
		_ai_sync_log_decision "ai_recover_stale_claims" "$repo_path" "Recovered $recovered_count: $recovered_list ($ai_reasoning)" "$prompt"
		log_success "Phase 0.5e (AI): Recovered $recovered_count stale claim(s): $recovered_list"

		# Record pattern for observability
		local pattern_helper="${SCRIPT_DIR:-}/pattern-tracker-helper.sh"
		if [[ -x "$pattern_helper" ]]; then
			"$pattern_helper" record \
				--type "SELF_HEAL_PATTERN" \
				--task "supervisor" \
				--model "n/a" \
				--detail "Phase 0.5e AI stale-claim recovery (t1318): $recovered_count claims recovered ($recovered_list)" \
				2>/dev/null || true
		fi
	else
		_ai_sync_log_decision "ai_recover_stale_claims" "$repo_path" "No claims recovered (AI selected but unclaim failed)" "$prompt"
	fi

	return 0
}

###############################################################################
# 4. AI-POWERED AUTO-UNBLOCK FOR RESOLVED TASKS
#
# Replaces: auto_unblock_resolved_tasks() in todo-sync.sh
# The original function has ~125 lines of deterministic checks:
#   - Scans TODO.md for blocked-by: fields
#   - Checks each blocker against TODO.md [x]/[-] status
#   - DB fallback for deployed/verified/complete/merged states
#   - Permanently failed blocker detection (retries exhausted)
#   - Orphaned reference detection
#
# The AI version:
# - Shell gathers blocker resolution status from TODO.md and DB
# - AI receives the full dependency graph and decides which tasks to unblock
# - AI can consider nuanced cases: a blocker that's "complete" in DB but
#   the PR was reverted, or a blocker that's "failed" but the dependent
#   task doesn't actually need it
# - Shell executes the unblock operations (sed on TODO.md, git commit/push)
###############################################################################

#######################################
# AI-powered auto-unblock for resolved tasks.
# Gathers dependency data, asks AI which tasks to unblock.
#
# Args:
#   $1 - repo path
# Returns:
#   0 on success (even if no tasks were unblocked)
#   1 on failure (TODO.md not found)
#######################################
ai_auto_unblock_resolved_tasks() {
	local repo_path="$1"
	local todo_file="$repo_path/TODO.md"

	if [[ ! -f "$todo_file" ]]; then
		log_verbose "ai_auto_unblock_resolved_tasks: TODO.md not found at $todo_file"
		return 1
	fi

	# Feature flag check — fall back to deterministic
	if [[ "$AI_SYNC_DECISIONS_ENABLED" != "true" ]]; then
		auto_unblock_resolved_tasks "$repo_path"
		return $?
	fi

	# --- GATHER: Collect all blocked tasks and their blocker statuses ---
	local blocked_tasks_data=""
	local blocked_count=0

	while IFS= read -r line; do
		local task_id=""
		task_id=$(printf '%s' "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		[[ -z "$task_id" ]] && continue

		local blocked_by=""
		blocked_by=$(printf '%s' "$line" | grep -oE 'blocked-by:[^ ]+' | head -1 | sed 's/blocked-by://' || echo "")
		[[ -z "$blocked_by" ]] && continue

		# Check each blocker's status
		local blocker_statuses=""
		local _saved_ifs="$IFS"
		IFS=','
		for blocker_id in $blocked_by; do
			[[ -z "$blocker_id" ]] && continue

			local blocker_status="open"

			# Check TODO.md
			if grep -qE "^[[:space:]]*- \[x\] ${blocker_id}( |$)" "$todo_file" 2>/dev/null; then
				blocker_status="completed_in_todo"
			elif grep -qE "^[[:space:]]*- \[-\] ${blocker_id}( |$)" "$todo_file" 2>/dev/null; then
				blocker_status="declined_in_todo"
			elif ! grep -qE "^[[:space:]]*- \[.\] ${blocker_id}( |$)" "$todo_file" 2>/dev/null; then
				blocker_status="not_in_todo"
			fi

			# Check DB
			if [[ -n "${SUPERVISOR_DB:-}" && -f "${SUPERVISOR_DB}" ]]; then
				local db_status=""
				db_status=$(db "$SUPERVISOR_DB" \
					"SELECT status FROM tasks WHERE id = '$(sql_escape "$blocker_id")' LIMIT 1;" \
					2>/dev/null || echo "")
				if [[ -n "$db_status" ]]; then
					blocker_status="${blocker_status}|db:${db_status}"

					# Check if permanently failed
					if [[ "$db_status" == "failed" ]]; then
						local retries max_retries
						retries=$(db "$SUPERVISOR_DB" "SELECT COALESCE(retries, 0) FROM tasks WHERE id = '$(sql_escape "$blocker_id")';" 2>/dev/null || echo "0")
						max_retries=$(db "$SUPERVISOR_DB" "SELECT COALESCE(max_retries, 3) FROM tasks WHERE id = '$(sql_escape "$blocker_id")';" 2>/dev/null || echo "3")
						retries="${retries:-0}"
						max_retries="${max_retries:-3}"
						blocker_status="${blocker_status}|retries:${retries}/${max_retries}"
					fi
				fi
			fi

			blocker_statuses="${blocker_statuses}${blocker_id}=${blocker_status} "
		done
		IFS="$_saved_ifs"

		blocked_tasks_data="${blocked_tasks_data}task:${task_id} | blocked-by:${blocked_by} | blocker_statuses: ${blocker_statuses}
"
		blocked_count=$((blocked_count + 1))
	done < <(grep -E '^\s*- \[ \] t[0-9]+.*blocked-by:' "$todo_file" || true)

	# If no blocked tasks, nothing to do
	if [[ "$blocked_count" -eq 0 ]]; then
		log_verbose "ai_auto_unblock_resolved_tasks: no blocked tasks found"
		return 0
	fi

	# --- JUDGE: Ask AI which tasks to unblock ---
	local prompt
	prompt="You are a dependency resolution agent for an automated task pipeline.

Tasks can have blocked-by: fields that prevent dispatch until blockers are resolved. Review the blocked tasks below and decide which should be unblocked.

BLOCKED TASKS:
${blocked_tasks_data}

BLOCKER STATUS MEANINGS:
- completed_in_todo: Blocker is marked [x] in TODO.md — resolved.
- declined_in_todo: Blocker is marked [-] in TODO.md — resolved (declined).
- not_in_todo: Blocker ID doesn't exist in TODO.md — orphaned reference, treat as resolved.
- open: Blocker is still [ ] in TODO.md — NOT resolved.
- db:complete/deployed/verified/merged: Blocker is done in DB (TODO.md may lag) — resolved.
- db:failed + retries exhausted (retries >= max_retries): Permanently failed — treat as resolved (blocker will never complete).
- db:failed + retries remaining: Still retrying — NOT resolved.
- db:cancelled: Cancelled — treat as resolved.

UNBLOCK RULES:
- Unblock a task ONLY if ALL its blockers are resolved.
- A blocker is resolved if its status includes: completed_in_todo, declined_in_todo, not_in_todo, db:complete, db:deployed, db:verified, db:merged, db:cancelled, or (db:failed with retries exhausted).
- A blocker is NOT resolved if it's 'open' with no DB terminal state, or db:failed with retries remaining.
- When in doubt, do NOT unblock — false unblocking is worse than delayed unblocking.

Respond with ONLY a JSON object (no markdown fencing):
{\"unblock\": [\"t123\", \"t456\"], \"keep_blocked\": [\"t789\"], \"reasoning\": \"Brief explanation\"}"

	local ai_response
	ai_response=$(_ai_sync_call "$prompt" "auto-unblock") || {
		log_warn "ai_auto_unblock_resolved_tasks: AI unavailable, falling back to deterministic"
		auto_unblock_resolved_tasks "$repo_path"
		return $?
	}

	local ai_json
	ai_json=$(_ai_sync_extract_json "$ai_response") || {
		log_warn "ai_auto_unblock_resolved_tasks: AI response unparseable, falling back"
		auto_unblock_resolved_tasks "$repo_path"
		return $?
	}

	# --- EXECUTE: Remove blocked-by: from tasks AI selected ---
	local unblock_ids
	unblock_ids=$(printf '%s' "$ai_json" | jq -r '.unblock[]? // empty' 2>/dev/null || echo "")
	local ai_reasoning
	ai_reasoning=$(printf '%s' "$ai_json" | jq -r '.reasoning // empty' 2>/dev/null || echo "")

	if [[ -z "$unblock_ids" ]]; then
		_ai_sync_log_decision "ai_auto_unblock_resolved_tasks" "$repo_path" "No tasks to unblock: $ai_reasoning" "$prompt"
		log_verbose "ai_auto_unblock_resolved_tasks: AI decided no tasks to unblock"
		return 0
	fi

	local unblocked_count=0
	local unblocked_list=""

	while IFS= read -r tid; do
		[[ -z "$tid" ]] && continue

		# Find the blocked-by value for this task
		local blocked_by_value=""
		blocked_by_value=$(grep -E "^[[:space:]]*- \[ \] ${tid}( |$)" "$todo_file" 2>/dev/null |
			head -1 | grep -oE 'blocked-by:[^ ]+' | head -1 | sed 's/blocked-by://' || echo "")

		if [[ -z "$blocked_by_value" ]]; then
			log_verbose "  ai_auto_unblock: $tid — no blocked-by: field found (already unblocked?)"
			continue
		fi

		# Remove blocked-by: field from the task line
		local line_num
		line_num=$(grep -nE "^[[:space:]]*- \[ \] ${tid}( |$)" "$todo_file" | head -1 | cut -d: -f1 || echo "")
		if [[ -n "$line_num" ]]; then
			local escaped_blocked_by
			escaped_blocked_by=$(printf '%s' "$blocked_by_value" | sed 's/\./\\./g')
			sed_inplace "${line_num}s/ blocked-by:${escaped_blocked_by}//" "$todo_file"
			sed_inplace "${line_num}s/[[:space:]]*$//" "$todo_file"
		fi

		unblocked_count=$((unblocked_count + 1))
		if [[ -n "$unblocked_list" ]]; then
			unblocked_list="${unblocked_list}, ${tid}"
		else
			unblocked_list="$tid"
		fi
		log_info "  auto-unblock (AI): $tid — all blockers resolved (was: blocked-by:$blocked_by_value)"
	done <<<"$unblock_ids"

	if [[ "$unblocked_count" -gt 0 ]]; then
		_ai_sync_log_decision "ai_auto_unblock_resolved_tasks" "$repo_path" "Unblocked $unblocked_count: $unblocked_list ($ai_reasoning)" "$prompt"
		log_success "ai_auto_unblock_resolved_tasks: unblocked $unblocked_count task(s): $unblocked_list"
		commit_and_push_todo "$repo_path" "chore: AI auto-unblock $unblocked_count task(s) with resolved blockers: $unblocked_list (t1318)"
	else
		_ai_sync_log_decision "ai_auto_unblock_resolved_tasks" "$repo_path" "No tasks unblocked (AI selected but sed failed)" "$prompt"
	fi

	return 0
}
