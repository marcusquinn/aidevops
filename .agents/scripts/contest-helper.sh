#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Contest Helper — Orchestrator (t1011)
# =============================================================================
# Model contest mode for supervisor. When model selection is uncertain,
# dispatches the same task to top-3 models in parallel, then has each model
# cross-rank all outputs (anonymised as A/B/C). Aggregates scores, picks
# winner, records results in pattern-tracker and response-scoring DB, and
# applies the winning output.
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
#
# Sub-libraries (sourced below):
#   contest-helper-create.sh   — contest creation flow
#   contest-helper-dispatch.sh — parallel worker dispatch
#   contest-helper-evaluate.sh — cross-ranking evaluation pipeline
#   contest-helper-apply.sh    — winner application & score recording
#   contest-helper-status.sh   — status display, listing, pulse integration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/shared-constants.sh"
SUPERVISOR_DIR="${AIDEVOPS_SUPERVISOR_DIR:-$HOME/.aidevops/.agent-workspace/supervisor}"
SUPERVISOR_DB="${SUPERVISOR_DIR}/supervisor.db"
# shellcheck disable=SC2034 # SCORING_DB used by contest-helper-apply.sh::_record_contest_scores
SCORING_DB="${HOME}/.aidevops/.agent-workspace/response-scoring.db"

# BOLD fallback — not in shared-constants.sh
[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'

# Default contest models — top 3 from different providers for diversity
DEFAULT_CONTEST_MODELS="anthropic/claude-opus-4-6,anthropic/claude-sonnet-4-6,google/gemini-2.5-pro"

# Scoring weights (match response-scoring-helper.sh)
WEIGHT_CORRECTNESS=30
WEIGHT_COMPLETENESS=25
WEIGHT_CODE_QUALITY=25
WEIGHT_CLARITY=20

# --- Utility functions (used by all sub-libraries) ---

#######################################
# Resolve AI CLI for contest scoring (t1160.4)
# Matches pattern from supervisor/dispatch.sh resolve_ai_cli()
# Prefers opencode; falls back to claude CLI
#######################################
resolve_ai_cli() {
	if command -v opencode &>/dev/null; then
		echo "opencode"
		return 0
	fi
	if command -v claude &>/dev/null; then
		echo "claude"
		return 0
	fi
	return 1
}

#######################################
# Run an AI scoring prompt via the resolved CLI (t1160.4)
# Usage: run_ai_scoring <model> <prompt> <output_file>
# Writes raw output to output_file; returns 0 on success
#######################################
run_ai_scoring() {
	local model="$1"
	local prompt="$2"
	local output_file="$3"

	local ai_cli
	ai_cli=$(resolve_ai_cli) || {
		log_error "No AI CLI available (install opencode or claude)"
		return 1
	}

	case "$ai_cli" in
	opencode)
		timeout_sec 120 opencode run --format json \
			--model "$model" \
			--prompt "$prompt" \
			>"$output_file" 2>/dev/null || true
		;;
	claude)
		# claude CLI uses bare model name (strip provider/ prefix)
		local claude_model="${model#*/}"
		timeout_sec 120 claude -p "$prompt" \
			--model "$claude_model" \
			--output-format json \
			>"$output_file" 2>/dev/null || true
		;;
	*)
		log_error "Unknown AI CLI: $ai_cli"
		return 1
		;;
	esac

	return 0
}

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
		log_error "Supervisor DB not found at $SUPERVISOR_DB — run 'aidevops pulse start' to initialize"
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

# --- Source sub-libraries ---

# shellcheck source=./contest-helper-create.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/contest-helper-create.sh"

# shellcheck source=./contest-helper-dispatch.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/contest-helper-dispatch.sh"

# shellcheck source=./contest-helper-evaluate.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/contest-helper-evaluate.sh"

# shellcheck source=./contest-helper-apply.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/contest-helper-apply.sh"

# shellcheck source=./contest-helper-status.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/contest-helper-status.sh"

# --- CLI entry point ---

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

# Allow sourcing without executing main (for testing)
if [[ "${1:-}" != "--source-only" ]]; then
	main "$@"
fi
