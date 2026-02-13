#!/usr/bin/env bash
# contest-helper.sh — Model contest mode for supervisor (t1011)
#
# When model selection is uncertain, dispatches the same task to top-3 models
# in parallel, then has each model cross-rank all outputs (anonymised as A/B/C).
# Aggregates scores, picks winner, records results in pattern-tracker and
# response-scoring DB, and applies the winning output.
#
# Usage:
#   contest-helper.sh create <task_id> [--models "opus,sonnet,pro"]
#   contest-helper.sh status <contest_id>
#   contest-helper.sh evaluate <contest_id>
#   contest-helper.sh apply <contest_id>
#   contest-helper.sh list [--active|--completed]
#   contest-helper.sh should-contest <task_id>
#   contest-helper.sh help
#
# Cost: ~3x a single run, but builds permanent routing data.
# Only trigger for genuinely uncertain cases — not every task.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR_DIR="${AIDEVOPS_SUPERVISOR_DIR:-$HOME/.aidevops/.agent-workspace/supervisor}"
SUPERVISOR_DB="${SUPERVISOR_DIR}/supervisor.db"
# shellcheck disable=SC2034 # SCORING_DB used by _record_contest_scores
SCORING_DB="${HOME}/.aidevops/.agent-workspace/response-scoring.db"

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Default contest models — top 3 from different providers for diversity
DEFAULT_CONTEST_MODELS="anthropic/claude-opus-4-6,anthropic/claude-sonnet-4-5,google/gemini-2.5-pro"

# Scoring weights (match response-scoring-helper.sh)
WEIGHT_CORRECTNESS=30
WEIGHT_COMPLETENESS=25
WEIGHT_CODE_QUALITY=25
WEIGHT_CLARITY=20

#######################################
# Logging
#######################################
log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $*" >&2; }

#######################################
# SQLite wrapper (reuse supervisor's DB)
#######################################
db() {
	local db_path="$1"
	shift
	sqlite3 -batch "$db_path" "$@" 2>/dev/null
}

sql_escape() {
	local val="$1"
	echo "${val//\'/\'\'}"
}

#######################################
# Ensure contest tables exist in supervisor DB
#######################################
ensure_contest_tables() {
	if [[ ! -f "$SUPERVISOR_DB" ]]; then
		log_error "Supervisor DB not found: $SUPERVISOR_DB"
		log_error "Run 'supervisor-helper.sh init' first"
		return 1
	fi

	# Check if contests table exists
	local has_contests
	has_contests=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='contests';")
	if [[ "$has_contests" -gt 0 ]]; then
		return 0
	fi

	log_info "Creating contest tables in supervisor DB (t1011)..."
	db "$SUPERVISOR_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS contests (
    id              TEXT PRIMARY KEY,
    task_id         TEXT NOT NULL,
    description     TEXT,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK(status IN ('pending','dispatching','running','evaluating','scoring','complete','failed','cancelled')),
    winner_model    TEXT,
    winner_entry_id TEXT,
    winner_score    REAL,
    models          TEXT NOT NULL,
    batch_id        TEXT,
    repo            TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    completed_at    TEXT,
    metadata        TEXT
);

CREATE TABLE IF NOT EXISTS contest_entries (
    id              TEXT PRIMARY KEY,
    contest_id      TEXT NOT NULL,
    model           TEXT NOT NULL,
    task_id         TEXT,
    worktree        TEXT,
    branch          TEXT,
    log_file        TEXT,
    pr_url          TEXT,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK(status IN ('pending','dispatched','running','complete','failed','cancelled')),
    output_summary  TEXT,
    score_correctness   REAL DEFAULT 0,
    score_completeness  REAL DEFAULT 0,
    score_code_quality  REAL DEFAULT 0,
    score_clarity       REAL DEFAULT 0,
    weighted_score      REAL DEFAULT 0,
    cross_rank_scores   TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    completed_at    TEXT,
    FOREIGN KEY (contest_id) REFERENCES contests(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_contests_task ON contests(task_id);
CREATE INDEX IF NOT EXISTS idx_contests_status ON contests(status);
CREATE INDEX IF NOT EXISTS idx_contest_entries_contest ON contest_entries(contest_id);
CREATE INDEX IF NOT EXISTS idx_contest_entries_status ON contest_entries(status);
SQL

	log_success "Contest tables created"
	return 0
}

#######################################
# Determine if a task should use contest mode (t1011)
# Returns 0 (yes) if:
#   1. Task has explicit model:contest in TODO.md
#   2. No pattern data exists for this task type (new territory)
#   3. Pattern data is inconclusive (no tier has >75% success with 3+ samples)
# Returns 1 (no) otherwise
#######################################
cmd_should_contest() {
	local task_id="${1:-}"
	if [[ -z "$task_id" ]]; then
		log_error "Usage: contest-helper.sh should-contest <task_id>"
		return 1
	fi

	ensure_contest_tables || return 1

	# Check 1: Explicit model:contest in TODO.md
	local repo_path
	repo_path=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo ".")
	local todo_file="${repo_path:-.}/TODO.md"
	if [[ -f "$todo_file" ]]; then
		local task_line
		task_line=$(grep -E "^\s*- \[.\] ${task_id} " "$todo_file" 2>/dev/null || true)
		if echo "$task_line" | grep -q 'model:contest'; then
			log_info "Task $task_id has explicit model:contest — contest mode triggered"
			echo "explicit"
			return 0
		fi
	fi

	# Check 2: Query pattern-tracker for this task type
	local pattern_helper="${SCRIPT_DIR}/pattern-tracker-helper.sh"
	if [[ ! -x "$pattern_helper" ]]; then
		log_warn "Pattern tracker not available — defaulting to no contest"
		echo "no_tracker"
		return 1
	fi

	# Get recommendation JSON
	local pattern_json
	pattern_json=$("$pattern_helper" recommend --json 2>/dev/null || echo "")

	if [[ -z "$pattern_json" || "$pattern_json" == "{}" ]]; then
		log_info "No pattern data available for $task_id — contest mode triggered (new territory)"
		echo "no_data"
		return 0
	fi

	# Check if any tier has strong enough signal (>75% success, 3+ samples)
	local total_samples
	total_samples=$(echo "$pattern_json" | sed -n 's/.*"total_samples"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' 2>/dev/null || echo "0")
	local success_rate
	success_rate=$(echo "$pattern_json" | sed -n 's/.*"success_rate"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' 2>/dev/null || echo "0")

	if [[ "$total_samples" -lt 3 ]]; then
		log_info "Insufficient pattern data ($total_samples samples) for $task_id — contest mode triggered"
		echo "insufficient_data"
		return 0
	fi

	if [[ "$success_rate" -lt 75 ]]; then
		log_info "Low success rate (${success_rate}%) for $task_id — contest mode triggered"
		echo "low_success_rate"
		return 0
	fi

	# Strong signal exists — no contest needed
	log_info "Strong pattern data (${success_rate}% over $total_samples samples) — no contest needed"
	echo "strong_signal"
	return 1
}

#######################################
# Select top-3 models for contest
# Uses model-registry + fallback-chain to pick diverse, available models
#######################################
select_contest_models() {
	local explicit_models="${1:-}"

	if [[ -n "$explicit_models" ]]; then
		echo "$explicit_models"
		return 0
	fi

	# Try model-registry for data-driven selection
	local registry_helper="${SCRIPT_DIR}/model-registry-helper.sh"
	if [[ -x "$registry_helper" ]]; then
		# Get top models from different tiers for diversity
		local opus_model sonnet_model pro_model
		opus_model=$("$registry_helper" list --tier opus --json 2>/dev/null | sed -n 's/.*"model_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || echo "")
		sonnet_model=$("$registry_helper" list --tier sonnet --json 2>/dev/null | sed -n 's/.*"model_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || echo "")
		pro_model=$("$registry_helper" list --tier pro --json 2>/dev/null | sed -n 's/.*"model_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || echo "")

		if [[ -n "$opus_model" && -n "$sonnet_model" && -n "$pro_model" ]]; then
			echo "${opus_model},${sonnet_model},${pro_model}"
			return 0
		fi
	fi

	# Fallback to defaults
	echo "$DEFAULT_CONTEST_MODELS"
	return 0
}

#######################################
# Create a contest for a task (t1011)
# Dispatches the same task to top-3 models in parallel
#######################################
cmd_create() {
	local task_id="" explicit_models="" batch_id=""

	# Parse args
	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--models)
			[[ $# -lt 2 ]] && {
				log_error "--models requires a value"
				return 1
			}
			explicit_models="$2"
			shift 2
			;;
		--batch)
			[[ $# -lt 2 ]] && {
				log_error "--batch requires a value"
				return 1
			}
			batch_id="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$task_id" ]]; then
		log_error "Usage: contest-helper.sh create <task_id> [--models 'model1,model2,model3']"
		return 1
	fi

	ensure_contest_tables || return 1

	# Verify task exists in supervisor DB
	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT id, repo, description, status
		FROM tasks WHERE id = '$escaped_id';
	")

	if [[ -z "$task_row" ]]; then
		log_error "Task not found in supervisor DB: $task_id"
		return 1
	fi

	local _tid trepo tdesc _tstatus
	IFS=$'\t' read -r _tid trepo tdesc _tstatus <<<"$task_row"

	# Check for existing active contest
	local existing_contest
	existing_contest=$(db "$SUPERVISOR_DB" "
		SELECT id FROM contests
		WHERE task_id = '$escaped_id'
		AND status NOT IN ('complete','failed','cancelled');
	")
	if [[ -n "$existing_contest" ]]; then
		log_warn "Active contest already exists for $task_id: $existing_contest"
		echo "$existing_contest"
		return 0
	fi

	# Select models
	local models
	models=$(select_contest_models "$explicit_models")
	log_info "Contest models: $models"

	# Generate contest ID
	local contest_id
	contest_id="contest-${task_id}-$(date +%Y%m%d%H%M%S)"

	# Create contest record
	db "$SUPERVISOR_DB" "
		INSERT INTO contests (id, task_id, description, status, models, batch_id, repo)
		VALUES (
			'$(sql_escape "$contest_id")',
			'$escaped_id',
			'$(sql_escape "$tdesc")',
			'pending',
			'$(sql_escape "$models")',
			'$(sql_escape "${batch_id:-}")',
			'$(sql_escape "${trepo:-.}")'
		);
	"

	# Create contest entries for each model
	local model_index=0
	local IFS=','
	for model in $models; do
		model_index=$((model_index + 1))
		local entry_id="${contest_id}-entry-${model_index}"
		local entry_task_id="${task_id}-contest-${model_index}"

		db "$SUPERVISOR_DB" "
			INSERT INTO contest_entries (id, contest_id, model, task_id, status)
			VALUES (
				'$(sql_escape "$entry_id")',
				'$(sql_escape "$contest_id")',
				'$(sql_escape "$model")',
				'$(sql_escape "$entry_task_id")',
				'pending'
			);
		"

		log_info "Created entry $entry_id for model $model (task: $entry_task_id)"
	done
	unset IFS

	log_success "Contest created: $contest_id with ${model_index} entries"
	echo "$contest_id"
	return 0
}

#######################################
# Dispatch contest entries as parallel workers
# Creates subtasks in supervisor DB and dispatches them
#######################################
cmd_dispatch_contest() {
	local contest_id="${1:-}"
	if [[ -z "$contest_id" ]]; then
		log_error "Usage: contest-helper.sh dispatch <contest_id>"
		return 1
	fi

	ensure_contest_tables || return 1

	local escaped_cid
	escaped_cid=$(sql_escape "$contest_id")

	# Get contest details
	local contest_row
	contest_row=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT task_id, description, repo, batch_id
		FROM contests WHERE id = '$escaped_cid';
	")

	if [[ -z "$contest_row" ]]; then
		log_error "Contest not found: $contest_id"
		return 1
	fi

	local ctask_id cdesc crepo cbatch_id
	IFS=$'\t' read -r ctask_id cdesc crepo cbatch_id <<<"$contest_row"

	# Transition contest to dispatching
	db "$SUPERVISOR_DB" "
		UPDATE contests SET status = 'dispatching', metadata = 'dispatch_started:$(date -u +%Y-%m-%dT%H:%M:%SZ)'
		WHERE id = '$escaped_cid';
	"

	# Get pending entries
	local entries
	entries=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT id, model, task_id
		FROM contest_entries
		WHERE contest_id = '$escaped_cid' AND status = 'pending';
	")

	if [[ -z "$entries" ]]; then
		log_warn "No pending entries for contest $contest_id"
		return 0
	fi

	local supervisor_helper="${SCRIPT_DIR}/supervisor-helper.sh"
	local dispatched_count=0

	while IFS=$'\t' read -r entry_id entry_model entry_task_id; do
		[[ -z "$entry_id" ]] && continue

		log_info "Dispatching contest entry: $entry_id (model: $entry_model)"

		# Add subtask to supervisor DB with the specific model
		if "$supervisor_helper" add "$entry_task_id" \
			--repo "${crepo:-.}" \
			--description "Contest entry for $ctask_id: $cdesc" \
			--model "$entry_model" 2>/dev/null; then

			# Add to batch if one exists
			if [[ -n "$cbatch_id" ]]; then
				"$supervisor_helper" db "
					INSERT OR IGNORE INTO batch_tasks (batch_id, task_id)
					VALUES ('$(sql_escape "$cbatch_id")', '$(sql_escape "$entry_task_id")');
				" 2>/dev/null || true
			fi

			# Dispatch the subtask
			if "$supervisor_helper" dispatch "$entry_task_id" ${cbatch_id:+--batch "$cbatch_id"} 2>/dev/null; then
				# Update entry with dispatch info
				local subtask_info
				subtask_info=$(db -separator $'\t' "$SUPERVISOR_DB" "
					SELECT worktree, branch, log_file
					FROM tasks WHERE id = '$(sql_escape "$entry_task_id")';
				")
				local ewt ebranch elog
				IFS=$'\t' read -r ewt ebranch elog <<<"$subtask_info"

				db "$SUPERVISOR_DB" "
					UPDATE contest_entries SET
						status = 'dispatched',
						worktree = '$(sql_escape "${ewt:-}")',
						branch = '$(sql_escape "${ebranch:-}")',
						log_file = '$(sql_escape "${elog:-}")'
					WHERE id = '$(sql_escape "$entry_id")';
				"
				dispatched_count=$((dispatched_count + 1))
			else
				log_warn "Failed to dispatch entry $entry_id"
				db "$SUPERVISOR_DB" "
					UPDATE contest_entries SET status = 'failed'
					WHERE id = '$(sql_escape "$entry_id")';
				"
			fi
		else
			log_error "Failed to add subtask $entry_task_id for entry $entry_id"
			db "$SUPERVISOR_DB" "
				UPDATE contest_entries SET status = 'failed'
				WHERE id = '$(sql_escape "$entry_id")';
			"
		fi
	done <<<"$entries"

	# Update contest status
	if [[ "$dispatched_count" -gt 0 ]]; then
		db "$SUPERVISOR_DB" "
			UPDATE contests SET status = 'running'
			WHERE id = '$escaped_cid';
		"
		log_success "Dispatched $dispatched_count contest entries for $contest_id"
	else
		db "$SUPERVISOR_DB" "
			UPDATE contests SET status = 'failed',
				metadata = COALESCE(metadata,'') || ' dispatch_failed:all_entries'
			WHERE id = '$escaped_cid';
		"
		log_error "All contest entries failed to dispatch"
		return 1
	fi

	return 0
}

#######################################
# Check contest status — are all entries complete?
#######################################
cmd_status() {
	local contest_id="${1:-}"
	if [[ -z "$contest_id" ]]; then
		log_error "Usage: contest-helper.sh status <contest_id>"
		return 1
	fi

	ensure_contest_tables || return 1

	local escaped_cid
	escaped_cid=$(sql_escape "$contest_id")

	local contest_row
	contest_row=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT task_id, status, winner_model, winner_score, models, created_at
		FROM contests WHERE id = '$escaped_cid';
	")

	if [[ -z "$contest_row" ]]; then
		log_error "Contest not found: $contest_id"
		return 1
	fi

	local ctask_id cstatus cwinner cscore cmodels ccreated
	IFS=$'\t' read -r ctask_id cstatus cwinner cscore cmodels ccreated <<<"$contest_row"

	echo -e "${BOLD}Contest: $contest_id${NC}"
	echo "  Task:     $ctask_id"
	echo "  Status:   $cstatus"
	echo "  Models:   $cmodels"
	echo "  Created:  $ccreated"
	if [[ -n "$cwinner" ]]; then
		echo -e "  Winner:   ${GREEN}$cwinner${NC} (score: $cscore)"
	fi

	# Show entries
	echo ""
	echo -e "${BOLD}Entries:${NC}"
	local entries
	entries=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT id, model, status, weighted_score, task_id
		FROM contest_entries
		WHERE contest_id = '$escaped_cid'
		ORDER BY weighted_score DESC;
	")

	while IFS=$'\t' read -r eid emodel estatus escore etask; do
		[[ -z "$eid" ]] && continue
		local status_color="$NC"
		case "$estatus" in
		complete) status_color="$GREEN" ;;
		running | dispatched) status_color="$BLUE" ;;
		failed) status_color="$RED" ;;
		esac
		printf "  %-40s %-30s ${status_color}%-12s${NC} score: %.2f  task: %s\n" \
			"$eid" "$emodel" "$estatus" "${escore:-0}" "$etask"
	done <<<"$entries"

	return 0
}

#######################################
# Evaluate contest — cross-rank outputs from all completed entries
# Each model scores all outputs (including its own) blindly as A/B/C
# Then aggregate scores and pick winner
#######################################
cmd_evaluate() {
	local contest_id="${1:-}"
	if [[ -z "$contest_id" ]]; then
		log_error "Usage: contest-helper.sh evaluate <contest_id>"
		return 1
	fi

	ensure_contest_tables || return 1

	local escaped_cid
	escaped_cid=$(sql_escape "$contest_id")

	# Verify contest is in evaluatable state
	local contest_status
	contest_status=$(db "$SUPERVISOR_DB" "SELECT status FROM contests WHERE id = '$escaped_cid';")
	if [[ "$contest_status" != "running" ]]; then
		log_error "Contest $contest_id is in '$contest_status' state, must be 'running' to evaluate"
		return 1
	fi

	# Check all entries are complete (or failed)
	local pending_count
	pending_count=$(db "$SUPERVISOR_DB" "
		SELECT count(*) FROM contest_entries
		WHERE contest_id = '$escaped_cid'
		AND status NOT IN ('complete','failed','cancelled');
	")

	if [[ "$pending_count" -gt 0 ]]; then
		log_info "Contest $contest_id has $pending_count entries still running — not ready for evaluation"
		return 2
	fi

	# Get completed entries
	local complete_count
	complete_count=$(db "$SUPERVISOR_DB" "
		SELECT count(*) FROM contest_entries
		WHERE contest_id = '$escaped_cid' AND status = 'complete';
	")

	if [[ "$complete_count" -lt 2 ]]; then
		log_error "Contest $contest_id has fewer than 2 completed entries ($complete_count) — cannot cross-rank"
		db "$SUPERVISOR_DB" "
			UPDATE contests SET status = 'failed',
				metadata = COALESCE(metadata,'') || ' eval_failed:insufficient_entries'
			WHERE id = '$escaped_cid';
		"
		return 1
	fi

	# Transition to evaluating
	db "$SUPERVISOR_DB" "UPDATE contests SET status = 'evaluating' WHERE id = '$escaped_cid';"

	log_info "Evaluating contest $contest_id with $complete_count entries..."

	# Collect output summaries from each entry's worktree
	local entries_data
	entries_data=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT id, model, task_id, worktree, branch, log_file, pr_url
		FROM contest_entries
		WHERE contest_id = '$escaped_cid' AND status = 'complete'
		ORDER BY id;
	")

	# Build anonymised output summaries (A, B, C, ...)
	local -a entry_ids=()
	local -a entry_models=()
	local -a entry_summaries=()
	local label_index=0
	local labels=("A" "B" "C" "D" "E")

	while IFS=$'\t' read -r eid emodel _etask ewt _ebranch elog _epr; do
		[[ -z "$eid" ]] && continue
		entry_ids+=("$eid")
		entry_models+=("$emodel")

		# Extract output summary from worktree diff
		local summary=""
		if [[ -n "$ewt" && -d "$ewt" ]]; then
			# Get the diff as the "output"
			summary=$(git -C "$ewt" diff --stat "main..HEAD" 2>/dev/null || echo "No diff available")
			local full_diff
			full_diff=$(git -C "$ewt" diff "main..HEAD" 2>/dev/null | head -500 || echo "")
			summary="${summary}

--- Code Changes ---
${full_diff}"
		elif [[ -n "$elog" && -f "$elog" ]]; then
			# Fallback: extract key output from log
			summary=$(tail -100 "$elog" 2>/dev/null || echo "No log available")
		fi

		# Store summary in entry
		db "$SUPERVISOR_DB" "
			UPDATE contest_entries SET output_summary = '$(sql_escape "$summary")'
			WHERE id = '$(sql_escape "$eid")';
		"

		entry_summaries+=("$summary")
		label_index=$((label_index + 1))
	done <<<"$entries_data"

	local num_entries=${#entry_ids[@]}
	if [[ "$num_entries" -lt 2 ]]; then
		log_error "Not enough entries to evaluate"
		return 1
	fi

	# Build the cross-ranking prompt
	local ranking_prompt="You are evaluating ${num_entries} different implementations of the same task. Each implementation is labelled with a letter (A, B, C, etc.). You do NOT know which model produced which output.

Score each implementation on these criteria (1-5 scale):
- Correctness (30%): Does it correctly solve the task? Any bugs or errors?
- Completeness (25%): Does it cover all requirements including edge cases?
- Code Quality (25%): Is it clean, idiomatic, well-structured with error handling?
- Clarity (20%): Is it well-organized and easy to understand?

For each implementation, output EXACTLY this JSON format (one per line):
{\"label\": \"A\", \"correctness\": N, \"completeness\": N, \"code_quality\": N, \"clarity\": N}

Here are the implementations:
"

	for i in $(seq 0 $((num_entries - 1))); do
		local label="${labels[$i]:-$(printf '%c' $((65 + i)))}"
		ranking_prompt="${ranking_prompt}
=== Implementation ${label} ===
${entry_summaries[$i]}
=== End Implementation ${label} ===
"
	done

	ranking_prompt="${ranking_prompt}

Now score each implementation. Output ONLY the JSON lines, nothing else."

	# Transition to scoring
	db "$SUPERVISOR_DB" "UPDATE contests SET status = 'scoring' WHERE id = '$escaped_cid';"

	# Cross-rank: have each model score all outputs
	# Use multiple judges for robustness — each contest model scores all entries
	local -a judges=()
	for model in "${entry_models[@]}"; do
		judges+=("$model")
	done

	# Score collection: each judge scores all entries
	local -a all_scores=()
	local judge_count=0

	for judge_model in "${judges[@]}"; do
		judge_count=$((judge_count + 1))
		log_info "Judge $judge_count/${#judges[@]}: $judge_model scoring all entries..."

		# Dispatch scoring via AI CLI
		local score_output=""
		local score_tmpfile
		score_tmpfile=$(mktemp "${TMPDIR:-/tmp}/contest-score-XXXXXX")

		# Use opencode for scoring if available, otherwise fall back to direct API
		if command -v opencode &>/dev/null; then
			timeout 120 opencode run --format json \
				--model "$judge_model" \
				--prompt "$ranking_prompt" \
				>"$score_tmpfile" 2>/dev/null || true
			score_output=$(cat "$score_tmpfile" 2>/dev/null || echo "")
		fi

		# Parse JSON scores from output
		if [[ -n "$score_output" ]]; then
			# Extract JSON lines from the output
			local json_scores
			json_scores=$(echo "$score_output" | grep -oE '\{[^}]*"label"[^}]*\}' || true)

			if [[ -n "$json_scores" ]]; then
				while IFS= read -r score_line; do
					[[ -z "$score_line" ]] && continue
					all_scores+=("judge:${judge_model}|${score_line}")
				done <<<"$json_scores"
			else
				log_warn "Judge $judge_model returned no parseable scores"
			fi
		else
			log_warn "Judge $judge_model returned empty output"
		fi

		rm -f "$score_tmpfile"
	done

	# Aggregate scores across all judges
	log_info "Aggregating scores from ${judge_count} judges..."

	for i in $(seq 0 $((num_entries - 1))); do
		local label="${labels[$i]:-$(printf '%c' $((65 + i)))}"
		local eid="${entry_ids[$i]}"
		local total_correctness=0 total_completeness=0 total_quality=0 total_clarity=0
		local score_count=0

		for score_entry in "${all_scores[@]}"; do
			local score_json="${score_entry#*|}"
			local score_label
			score_label=$(echo "$score_json" | sed -n 's/.*"label"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || echo "")

			if [[ "$score_label" == "$label" ]]; then
				local s_correct s_complete s_quality s_clarity
				s_correct=$(echo "$score_json" | sed -n 's/.*"correctness"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' || echo "0")
				s_complete=$(echo "$score_json" | sed -n 's/.*"completeness"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' || echo "0")
				s_quality=$(echo "$score_json" | sed -n 's/.*"code_quality"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' || echo "0")
				s_clarity=$(echo "$score_json" | sed -n 's/.*"clarity"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' || echo "0")

				total_correctness=$((total_correctness + s_correct))
				total_completeness=$((total_completeness + s_complete))
				total_quality=$((total_quality + s_quality))
				total_clarity=$((total_clarity + s_clarity))
				score_count=$((score_count + 1))
			fi
		done

		if [[ "$score_count" -gt 0 ]]; then
			# Average scores across judges
			local avg_correct avg_complete avg_quality avg_clarity weighted
			avg_correct=$(awk "BEGIN {printf \"%.2f\", $total_correctness / $score_count}")
			avg_complete=$(awk "BEGIN {printf \"%.2f\", $total_completeness / $score_count}")
			avg_quality=$(awk "BEGIN {printf \"%.2f\", $total_quality / $score_count}")
			avg_clarity=$(awk "BEGIN {printf \"%.2f\", $total_clarity / $score_count}")
			weighted=$(awk "BEGIN {printf \"%.2f\", ($avg_correct * $WEIGHT_CORRECTNESS + $avg_complete * $WEIGHT_COMPLETENESS + $avg_quality * $WEIGHT_CODE_QUALITY + $avg_clarity * $WEIGHT_CLARITY) / 100}")

			# Store scores
			db "$SUPERVISOR_DB" "
				UPDATE contest_entries SET
					score_correctness = $avg_correct,
					score_completeness = $avg_complete,
					score_code_quality = $avg_quality,
					score_clarity = $avg_clarity,
					weighted_score = $weighted,
					cross_rank_scores = '$(sql_escape "judges:$score_count,raw:${all_scores[*]}")'
				WHERE id = '$(sql_escape "$eid")';
			"

			log_info "Entry $label (${entry_models[$i]}): correctness=$avg_correct completeness=$avg_complete quality=$avg_quality clarity=$avg_clarity weighted=$weighted"
		else
			log_warn "No scores collected for entry $label ($eid)"
		fi
	done

	# Determine winner
	local winner_row
	winner_row=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT id, model, weighted_score
		FROM contest_entries
		WHERE contest_id = '$escaped_cid' AND status = 'complete'
		ORDER BY weighted_score DESC
		LIMIT 1;
	")

	if [[ -n "$winner_row" ]]; then
		local winner_id winner_model winner_score
		IFS=$'\t' read -r winner_id winner_model winner_score <<<"$winner_row"

		db "$SUPERVISOR_DB" "
			UPDATE contests SET
				status = 'complete',
				winner_model = '$(sql_escape "$winner_model")',
				winner_entry_id = '$(sql_escape "$winner_id")',
				winner_score = $winner_score,
				completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
			WHERE id = '$escaped_cid';
		"

		log_success "Contest $contest_id winner: $winner_model (score: $winner_score)"

		# Record results in pattern-tracker
		_record_contest_patterns "$contest_id"

		# Record in response-scoring DB
		_record_contest_scores "$contest_id"
	else
		db "$SUPERVISOR_DB" "
			UPDATE contests SET status = 'failed',
				metadata = COALESCE(metadata,'') || ' eval_failed:no_winner'
			WHERE id = '$escaped_cid';
		"
		log_error "Could not determine winner for contest $contest_id"
		return 1
	fi

	return 0
}

#######################################
# Record contest results in pattern-tracker (t1011)
# Stores success/failure patterns for each model's performance
#######################################
_record_contest_patterns() {
	local contest_id="$1"
	local pattern_helper="${SCRIPT_DIR}/pattern-tracker-helper.sh"

	if [[ ! -x "$pattern_helper" ]]; then
		log_warn "Pattern tracker not available — skipping pattern recording"
		return 0
	fi

	local escaped_cid
	escaped_cid=$(sql_escape "$contest_id")

	local contest_task
	contest_task=$(db "$SUPERVISOR_DB" "SELECT task_id FROM contests WHERE id = '$escaped_cid';")
	local winner_model
	winner_model=$(db "$SUPERVISOR_DB" "SELECT winner_model FROM contests WHERE id = '$escaped_cid';")

	# Record each entry's result
	local entries
	entries=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT model, weighted_score, status
		FROM contest_entries
		WHERE contest_id = '$escaped_cid';
	")

	while IFS=$'\t' read -r emodel escore estatus; do
		[[ -z "$emodel" ]] && continue

		local outcome="success"
		if [[ "$estatus" == "failed" ]]; then
			outcome="failure"
		fi

		"$pattern_helper" record \
			--outcome "$outcome" \
			--description "Contest $contest_id: model $emodel scored $escore (winner: $winner_model)" \
			--model "$emodel" \
			--task-id "$contest_task" \
			--tags "contest,cross-rank" 2>/dev/null || true
	done <<<"$entries"

	log_info "Recorded contest patterns for $contest_id"
	return 0
}

#######################################
# Record contest results in response-scoring DB (t1011)
# Creates prompt + responses + scores for permanent comparison data
#######################################
_record_contest_scores() {
	local contest_id="$1"
	local scoring_helper="${SCRIPT_DIR}/response-scoring-helper.sh"

	if [[ ! -x "$scoring_helper" ]]; then
		log_warn "Response scoring helper not available — skipping score recording"
		return 0
	fi

	local escaped_cid
	escaped_cid=$(sql_escape "$contest_id")

	# Get contest details
	local contest_desc
	contest_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM contests WHERE id = '$escaped_cid';")

	# Create a prompt in the scoring DB
	local prompt_id
	prompt_id=$("$scoring_helper" prompt add \
		--title "Contest: $contest_id" \
		--text "$contest_desc" \
		--category "contest" \
		--difficulty "medium" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "")

	if [[ -z "$prompt_id" ]]; then
		log_warn "Failed to create scoring prompt — skipping score recording"
		return 0
	fi

	# Record each entry as a response with scores
	local entries
	entries=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT model, output_summary, score_correctness, score_completeness,
			   score_code_quality, score_clarity, weighted_score
		FROM contest_entries
		WHERE contest_id = '$escaped_cid' AND status = 'complete';
	")

	while IFS=$'\t' read -r emodel esummary ecorrect ecomplete equality eclarity _eweighted; do
		[[ -z "$emodel" ]] && continue

		# Record response
		local response_id
		response_id=$("$scoring_helper" record \
			--prompt "$prompt_id" \
			--model "$emodel" \
			--text "${esummary:-No output}" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "")

		if [[ -n "$response_id" ]]; then
			# Record scores (convert float to int for the 1-5 scale)
			local int_correct int_complete int_quality int_clarity
			int_correct=$(printf '%.0f' "${ecorrect:-0}" 2>/dev/null || echo "3")
			int_complete=$(printf '%.0f' "${ecomplete:-0}" 2>/dev/null || echo "3")
			int_quality=$(printf '%.0f' "${equality:-0}" 2>/dev/null || echo "3")
			int_clarity=$(printf '%.0f' "${eclarity:-0}" 2>/dev/null || echo "3")

			# Clamp to 1-5 range
			for var in int_correct int_complete int_quality int_clarity; do
				local val="${!var}"
				[[ "$val" -lt 1 ]] && eval "$var=1"
				[[ "$val" -gt 5 ]] && eval "$var=5"
			done

			"$scoring_helper" score \
				--response "$response_id" \
				--correctness "$int_correct" \
				--completeness "$int_complete" \
				--code-quality "$int_quality" \
				--clarity "$int_clarity" \
				--scored-by "contest-cross-rank" 2>/dev/null || true
		fi
	done <<<"$entries"

	log_info "Recorded contest scores in response-scoring DB"
	return 0
}

#######################################
# Apply the winning contest entry's output
# Merges the winner's branch/PR and cleans up losers
#######################################
cmd_apply() {
	local contest_id="${1:-}"
	if [[ -z "$contest_id" ]]; then
		log_error "Usage: contest-helper.sh apply <contest_id>"
		return 1
	fi

	ensure_contest_tables || return 1

	local escaped_cid
	escaped_cid=$(sql_escape "$contest_id")

	# Verify contest is complete
	local contest_row
	contest_row=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT status, winner_entry_id, winner_model, task_id
		FROM contests WHERE id = '$escaped_cid';
	")

	if [[ -z "$contest_row" ]]; then
		log_error "Contest not found: $contest_id"
		return 1
	fi

	local cstatus cwinner_entry cwinner_model ctask_id
	IFS=$'\t' read -r cstatus cwinner_entry cwinner_model ctask_id <<<"$contest_row"

	if [[ "$cstatus" != "complete" ]]; then
		log_error "Contest $contest_id is in '$cstatus' state, must be 'complete' to apply"
		return 1
	fi

	if [[ -z "$cwinner_entry" ]]; then
		log_error "No winner entry for contest $contest_id"
		return 1
	fi

	# Get winner's PR URL
	local winner_pr
	winner_pr=$(db "$SUPERVISOR_DB" "
		SELECT pr_url FROM contest_entries
		WHERE id = '$(sql_escape "$cwinner_entry")';
	")

	if [[ -n "$winner_pr" && "$winner_pr" != "no_pr" && "$winner_pr" != "task_only" ]]; then
		log_info "Winner PR: $winner_pr — promoting to the original task"

		# Update the original task's PR URL to point to the winner's PR
		db "$SUPERVISOR_DB" "
			UPDATE tasks SET
				pr_url = '$(sql_escape "$winner_pr")',
				model = '$(sql_escape "$cwinner_model")',
				error = 'Contest winner: $contest_id (model: $cwinner_model)'
			WHERE id = '$(sql_escape "$ctask_id")';
		"
	else
		log_warn "Winner has no PR — checking worktree for direct application"
		local winner_wt
		winner_wt=$(db "$SUPERVISOR_DB" "
			SELECT worktree FROM contest_entries
			WHERE id = '$(sql_escape "$cwinner_entry")';
		")

		if [[ -n "$winner_wt" && -d "$winner_wt" ]]; then
			log_info "Winner worktree: $winner_wt"
			# The supervisor's normal PR lifecycle will handle this
			db "$SUPERVISOR_DB" "
				UPDATE tasks SET
					worktree = '$(sql_escape "$winner_wt")',
					model = '$(sql_escape "$cwinner_model")',
					error = 'Contest winner: $contest_id (model: $cwinner_model)'
				WHERE id = '$(sql_escape "$ctask_id")';
			"
		fi
	fi

	# Cancel losing entries' tasks
	local losers
	losers=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT task_id, worktree FROM contest_entries
		WHERE contest_id = '$escaped_cid'
		AND id != '$(sql_escape "$cwinner_entry")'
		AND status = 'complete';
	")

	while IFS=$'\t' read -r loser_task _loser_wt; do
		[[ -z "$loser_task" ]] && continue
		log_info "Cancelling losing entry task: $loser_task"
		"${SCRIPT_DIR}/supervisor-helper.sh" cancel "$loser_task" 2>/dev/null || true
	done <<<"$losers"

	log_success "Applied contest winner: $cwinner_model for task $ctask_id"
	return 0
}

#######################################
# List contests
#######################################
cmd_list() {
	local filter=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--active)
			filter="AND status NOT IN ('complete','failed','cancelled')"
			shift
			;;
		--completed)
			filter="AND status = 'complete'"
			shift
			;;
		*) shift ;;
		esac
	done

	ensure_contest_tables || return 1

	local contests
	contests=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT id, task_id, status, winner_model, winner_score, models, created_at
		FROM contests
		WHERE 1=1 $filter
		ORDER BY created_at DESC;
	")

	if [[ -z "$contests" ]]; then
		echo "No contests found"
		return 0
	fi

	printf "${BOLD}%-40s %-12s %-12s %-25s %-8s %s${NC}\n" \
		"CONTEST" "TASK" "STATUS" "WINNER" "SCORE" "CREATED"

	while IFS=$'\t' read -r cid ctask cstatus cwinner cscore cmodels ccreated; do
		[[ -z "$cid" ]] && continue
		local status_color="$NC"
		case "$cstatus" in
		complete) status_color="$GREEN" ;;
		running | evaluating | scoring) status_color="$BLUE" ;;
		failed) status_color="$RED" ;;
		esac
		printf "%-40s %-12s ${status_color}%-12s${NC} %-25s %-8s %s\n" \
			"$cid" "$ctask" "$cstatus" "${cwinner:-—}" "${cscore:-—}" "$ccreated"
	done <<<"$contests"

	return 0
}

#######################################
# Check running contests and evaluate completed ones (for pulse integration)
# Returns: number of contests that were evaluated
#######################################
cmd_pulse_check() {
	ensure_contest_tables || return 1

	local evaluated=0

	# Find running contests where all entries are done
	local running_contests
	running_contests=$(db "$SUPERVISOR_DB" "
		SELECT c.id FROM contests c
		WHERE c.status = 'running'
		AND (
			SELECT count(*) FROM contest_entries ce
			WHERE ce.contest_id = c.id
			AND ce.status NOT IN ('complete','failed','cancelled')
		) = 0;
	")

	while IFS= read -r contest_id; do
		[[ -z "$contest_id" ]] && continue

		# Sync entry statuses from their subtasks
		_sync_entry_statuses "$contest_id"

		# Re-check after sync
		local still_pending
		still_pending=$(db "$SUPERVISOR_DB" "
			SELECT count(*) FROM contest_entries
			WHERE contest_id = '$(sql_escape "$contest_id")'
			AND status NOT IN ('complete','failed','cancelled');
		")

		if [[ "$still_pending" -eq 0 ]]; then
			log_info "Contest $contest_id ready for evaluation"
			if cmd_evaluate "$contest_id"; then
				cmd_apply "$contest_id" || true
				evaluated=$((evaluated + 1))
			fi
		fi
	done <<<"$running_contests"

	echo "$evaluated"
	return 0
}

#######################################
# Sync contest entry statuses from their supervisor subtasks
#######################################
_sync_entry_statuses() {
	local contest_id="$1"
	local escaped_cid
	escaped_cid=$(sql_escape "$contest_id")

	local entries
	entries=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT ce.id, ce.task_id, ce.status
		FROM contest_entries ce
		WHERE ce.contest_id = '$escaped_cid'
		AND ce.status NOT IN ('complete','failed','cancelled');
	")

	while IFS=$'\t' read -r eid etask estatus; do
		[[ -z "$eid" ]] && continue

		# Check the subtask's status in the supervisor DB
		local task_status
		task_status=$(db "$SUPERVISOR_DB" "
			SELECT status FROM tasks WHERE id = '$(sql_escape "$etask")';
		" 2>/dev/null || echo "")

		case "$task_status" in
		complete | pr_review | merging | merged | deploying | deployed | verifying | verified)
			# Task completed — get PR info
			local task_pr task_wt
			task_pr=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$(sql_escape "$etask")';" 2>/dev/null || echo "")
			task_wt=$(db "$SUPERVISOR_DB" "SELECT worktree FROM tasks WHERE id = '$(sql_escape "$etask")';" 2>/dev/null || echo "")

			db "$SUPERVISOR_DB" "
				UPDATE contest_entries SET
					status = 'complete',
					pr_url = '$(sql_escape "${task_pr:-}")',
					worktree = '$(sql_escape "${task_wt:-}")',
					completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
				WHERE id = '$(sql_escape "$eid")';
			"
			log_info "Contest entry $eid: synced to complete (task $etask is $task_status)"
			;;
		failed | blocked | cancelled)
			db "$SUPERVISOR_DB" "
				UPDATE contest_entries SET status = 'failed'
				WHERE id = '$(sql_escape "$eid")';
			"
			log_info "Contest entry $eid: synced to failed (task $etask is $task_status)"
			;;
		running | dispatched | evaluating)
			db "$SUPERVISOR_DB" "
				UPDATE contest_entries SET status = 'running'
				WHERE id = '$(sql_escape "$eid")';
			"
			;;
		esac
	done <<<"$entries"

	return 0
}

#######################################
# Show usage
#######################################
show_usage() {
	cat <<'EOF'
contest-helper.sh — Model contest mode for supervisor (t1011)

Usage:
  contest-helper.sh create <task_id> [--models "m1,m2,m3"] [--batch <id>]
  contest-helper.sh dispatch <contest_id>
  contest-helper.sh status <contest_id>
  contest-helper.sh evaluate <contest_id>
  contest-helper.sh apply <contest_id>
  contest-helper.sh list [--active|--completed]
  contest-helper.sh should-contest <task_id>
  contest-helper.sh pulse-check
  contest-helper.sh help

Commands:
  create          Create a contest for a task (dispatches to top-3 models)
  dispatch        Dispatch all contest entries as parallel workers
  status          Show contest status and entry scores
  evaluate        Cross-rank outputs from completed entries
  apply           Apply the winning entry's output to the original task
  list            List all contests
  should-contest  Check if a task should use contest mode
  pulse-check     Check running contests (for supervisor pulse integration)

Options:
  --models        Comma-separated list of models (default: top-3 from registry)
  --batch         Associate contest with a supervisor batch
  --active        Show only active contests
  --completed     Show only completed contests

Scoring criteria (weights):
  Correctness:  30%  — Does it correctly solve the task?
  Completeness: 25%  — Does it cover all requirements?
  Code Quality: 25%  — Is it clean and well-structured?
  Clarity:      20%  — Is it easy to understand?

Flow:
  1. should-contest detects uncertainty (no data, low success, explicit model:contest)
  2. create generates contest + entries for top-3 models
  3. dispatch launches parallel workers (one per model)
  4. Workers complete independently, creating PRs
  5. evaluate cross-ranks outputs (each model scores all, anonymised as A/B/C)
  6. apply promotes winner's PR, cancels losers
  7. Results stored in pattern-tracker + response-scoring DB

Cost: ~3x a single run, but builds permanent routing data.
EOF
	return 0
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	create) cmd_create "$@" ;;
	dispatch) cmd_dispatch_contest "$@" ;;
	status) cmd_status "$@" ;;
	evaluate) cmd_evaluate "$@" ;;
	apply) cmd_apply "$@" ;;
	list) cmd_list "$@" ;;
	should-contest) cmd_should_contest "$@" ;;
	pulse-check) cmd_pulse_check "$@" ;;
	help | --help | -h) show_usage ;;
	*)
		log_error "Unknown command: $command"
		show_usage
		return 1
		;;
	esac
}

main "$@"
