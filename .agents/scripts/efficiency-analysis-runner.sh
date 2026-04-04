#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# efficiency-analysis-runner.sh — Two-phase orchestration efficiency analysis runner
# (GH#15316)
#
# Phase 1: Deterministic data collection (zero LLM tokens)
#   Runs orchestration-efficiency-collector.sh to produce a structured JSON report.
#
# Phase 2: LLM analysis (conditional)
#   Runs only when anomalies are detected OR it is Sunday (weekly deep-dive).
#   Uses orchestration-analysis.md agent via headless-runtime-helper.sh.
#
# Usage:
#   efficiency-analysis-runner.sh [--force-phase2] [--date YYYY-MM-DD] [--dry-run]
#
# Options:
#   --force-phase2    Always run Phase 2 regardless of anomaly detection
#   --date YYYY-MM-DD Analyse a specific date (default: today)
#   --dry-run         Run Phase 1 only, print Phase 2 decision without executing
#
# Scheduling:
#   Invoked daily at 05:00 by sh.aidevops.efficiency-analysis launchd job.
#   On Linux, add to crontab: 0 5 * * * $HOME/.aidevops/agents/scripts/efficiency-analysis-runner.sh
#
# Exit codes:
#   0  Completed successfully (Phase 1 always; Phase 2 if triggered)
#   1  Phase 1 failed (report not written)
#   2  Phase 2 failed (report written but analysis failed)

set -euo pipefail

export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

LOG_PREFIX="EFFICIENCY-RUNNER"

# =============================================================================
# Constants
# =============================================================================

readonly LOGS_DIR="${HOME}/.aidevops/logs"
readonly AGENT_WORKSPACE="${HOME}/.aidevops/.agent-workspace"
readonly COLLECTOR_SCRIPT="${SCRIPT_DIR}/orchestration-efficiency-collector.sh"
readonly HEADLESS_RUNTIME="${SCRIPT_DIR}/headless-runtime-helper.sh"
readonly ANALYSIS_AGENT="${HOME}/.aidevops/agents/aidevops/orchestration-analysis.md"

# Baseline thresholds for Phase 2 skip decision
readonly THRESHOLD_LAUNCH_FAILURE_RATE=5 # pct — above this triggers Phase 2
readonly THRESHOLD_FILL_RATE=40          # pct — below this triggers Phase 2
readonly THRESHOLD_TOKENS_WASTED=50000   # tokens — above this triggers Phase 2
readonly THRESHOLD_ISSUES_NO_PR=0        # count — above this triggers Phase 2
readonly THRESHOLD_PRS_NO_SUMMARY=0      # count — above this triggers Phase 2

# =============================================================================
# Logging
# =============================================================================

log_info() {
	printf '[%s] [%s] [INFO] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOG_PREFIX" "$1"
	return 0
}

log_warn() {
	printf '[%s] [%s] [WARN] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOG_PREFIX" "$1"
	return 0
}

log_error() {
	printf '[%s] [%s] [ERROR] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOG_PREFIX" "$1"
	return 0
}

# =============================================================================
# Argument parsing
# =============================================================================

FORCE_PHASE2=false
TARGET_DATE=""
DRY_RUN=false

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force-phase2)
			FORCE_PHASE2=true
			shift
			;;
		--date)
			TARGET_DATE="$2"
			shift 2
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--help | -h)
			sed -n '2,/^# Exit codes/p' "${BASH_SOURCE[0]:-$0}" | grep '^#' | sed 's/^# \?//'
			exit 0
			;;
		*)
			log_warn "Unknown argument: $1 (ignored)"
			shift
			;;
		esac
	done
	return 0
}

# =============================================================================
# Anomaly detection — decide whether Phase 2 should run
# =============================================================================

# Returns 0 (run Phase 2) or 1 (skip Phase 2)
should_run_phase2() {
	local report_file="$1"

	# Always run on Sunday (weekly deep-dive)
	local day_of_week
	day_of_week=$(date -u +%u 2>/dev/null || date -u +%w 2>/dev/null || echo "0")
	if [[ "$day_of_week" == "7" || "$day_of_week" == "0" ]]; then
		log_info "Sunday deep-dive: Phase 2 will run"
		return 0
	fi

	# Force flag
	if [[ "$FORCE_PHASE2" == "true" ]]; then
		log_info "Force flag set: Phase 2 will run"
		return 0
	fi

	# Check if jq is available for threshold evaluation
	if ! command -v jq &>/dev/null; then
		log_warn "jq not available — cannot evaluate thresholds, running Phase 2 as fallback"
		return 0
	fi

	# Evaluate thresholds from the report using bc for float-safe comparison.
	# bc returns 1 (true) or 0 (false) for comparison expressions.
	local launch_failure_rate fill_rate tokens_wasted issues_no_pr prs_no_summary
	launch_failure_rate=$(jq -r '.errors.launch_failure_rate_pct // 0' "$report_file" 2>/dev/null || echo "0")
	fill_rate=$(jq -r '.concurrency.fill_rate_pct // 100' "$report_file" 2>/dev/null || echo "100")
	tokens_wasted=$(jq -r '.token_efficiency.tokens_wasted_on_stalls // 0' "$report_file" 2>/dev/null || echo "0")
	issues_no_pr=$(jq -r '.audit_trails.issues_closed_without_pr_link // 0' "$report_file" 2>/dev/null || echo "0")
	prs_no_summary=$(jq -r '.audit_trails.prs_without_merge_summary // 0' "$report_file" 2>/dev/null || echo "0")

	# Sanitize: replace empty/non-numeric with safe defaults
	[[ "$launch_failure_rate" =~ ^[0-9]+(\.[0-9]+)?$ ]] || launch_failure_rate="0"
	[[ "$fill_rate" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fill_rate="100"
	[[ "$tokens_wasted" =~ ^[0-9]+(\.[0-9]+)?$ ]] || tokens_wasted="0"
	[[ "$issues_no_pr" =~ ^[0-9]+(\.[0-9]+)?$ ]] || issues_no_pr="0"
	[[ "$prs_no_summary" =~ ^[0-9]+(\.[0-9]+)?$ ]] || prs_no_summary="0"

	# Float-safe comparisons via bc (avoids truncation of values like 5.9 -> 5)
	float_gt() {
		[ "$(echo "$1 > $2" | bc 2>/dev/null || echo 0)" = "1" ]
		return 0
	}
	float_lt() {
		[ "$(echo "$1 < $2" | bc 2>/dev/null || echo 0)" = "1" ]
		return 0
	}
	float_gt_eq() {
		[ "$(echo "$1 >= $2" | bc 2>/dev/null || echo 0)" = "1" ]
		return 0
	}

	local anomaly_found=false
	local anomaly_reason=""

	if float_gt "$launch_failure_rate" "$THRESHOLD_LAUNCH_FAILURE_RATE"; then
		anomaly_found=true
		anomaly_reason="launch_failure_rate=${launch_failure_rate}% > ${THRESHOLD_LAUNCH_FAILURE_RATE}%"
	fi

	if float_lt "$fill_rate" "$THRESHOLD_FILL_RATE"; then
		anomaly_found=true
		anomaly_reason="${anomaly_reason:+${anomaly_reason}, }fill_rate=${fill_rate}% < ${THRESHOLD_FILL_RATE}%"
	fi

	if float_gt "$tokens_wasted" "$THRESHOLD_TOKENS_WASTED"; then
		anomaly_found=true
		anomaly_reason="${anomaly_reason:+${anomaly_reason}, }tokens_wasted=${tokens_wasted} > ${THRESHOLD_TOKENS_WASTED}"
	fi

	if float_gt_eq "$issues_no_pr" "1"; then
		anomaly_found=true
		anomaly_reason="${anomaly_reason:+${anomaly_reason}, }issues_no_pr=${issues_no_pr} >= 1"
	fi

	if float_gt_eq "$prs_no_summary" "1"; then
		anomaly_found=true
		anomaly_reason="${anomaly_reason:+${anomaly_reason}, }prs_no_summary=${prs_no_summary} >= 1"
	fi

	if [[ "$anomaly_found" == "true" ]]; then
		log_info "Anomaly detected: ${anomaly_reason} — Phase 2 will run"
		return 0
	fi

	log_info "All metrics within baseline — Phase 2 skipped"
	return 1
}

# =============================================================================
# Phase 2: LLM analysis via headless runtime
# =============================================================================

run_phase2() {
	local report_file="$1"

	if [[ ! -f "$ANALYSIS_AGENT" ]]; then
		log_error "Analysis agent not found: ${ANALYSIS_AGENT}"
		return 2
	fi

	if [[ ! -f "$HEADLESS_RUNTIME" ]]; then
		log_error "Headless runtime helper not found: ${HEADLESS_RUNTIME}"
		return 2
	fi

	log_info "Phase 2: Running LLM analysis on ${report_file}"

	local analysis_log="${AGENT_WORKSPACE}/logs/efficiency-analysis-llm.log"
	mkdir -p "$(dirname "$analysis_log")" 2>/dev/null || true

	# Run the analysis agent via headless runtime.
	# Pass the report file path as the first positional argument so the agent
	# can resolve it deterministically (not from natural-language task text).
	local task_prompt
	task_prompt="${report_file}"

	if "$HEADLESS_RUNTIME" run \
		--agent "$ANALYSIS_AGENT" \
		--task "$task_prompt" \
		--model "${ANTHROPIC_MODEL:-anthropic/claude-haiku-4-5}" \
		--no-session \
		>>"$analysis_log" 2>&1; then
		log_info "Phase 2 completed successfully — see ${analysis_log}"
		return 0
	else
		local exit_code=$?
		log_error "Phase 2 failed with exit code ${exit_code} — see ${analysis_log}"
		return 2
	fi
}

# =============================================================================
# Main
# =============================================================================

get_yesterday() {
	if date --version >/dev/null 2>&1; then
		# GNU date (Linux)
		date -u -d "yesterday" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d
	else
		# BSD date (macOS)
		date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d
	fi
	return 0
}

main() {
	parse_args "$@"

	# Default to yesterday: the runner fires at 05:00, so "today" is only
	# a partial day. Analyse the completed previous day instead.
	local target_date="${TARGET_DATE:-$(get_yesterday)}"
	local report_file="${LOGS_DIR}/efficiency-report-${target_date}.json"

	log_info "=== Orchestration Efficiency Analysis: ${target_date} ==="

	# Ensure collector script exists
	if [[ ! -f "$COLLECTOR_SCRIPT" ]]; then
		log_error "Collector script not found: ${COLLECTOR_SCRIPT}"
		exit 1
	fi

	# Phase 1: Deterministic data collection
	log_info "Phase 1: Running data collector..."
	if ! "$COLLECTOR_SCRIPT" --date "$target_date" --output "$report_file"; then
		log_error "Phase 1 failed — report not written"
		exit 1
	fi

	if [[ ! -f "$report_file" ]]; then
		log_error "Phase 1 completed but report file not found: ${report_file}"
		exit 1
	fi

	log_info "Phase 1 complete: ${report_file}"

	# Phase 2: Conditional LLM analysis
	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "Dry-run mode: evaluating Phase 2 decision without executing"
		if should_run_phase2 "$report_file"; then
			log_info "DRY-RUN: Phase 2 WOULD run"
		else
			log_info "DRY-RUN: Phase 2 WOULD be skipped"
		fi
		exit 0
	fi

	if should_run_phase2 "$report_file"; then
		if ! run_phase2 "$report_file"; then
			log_error "Phase 2 failed"
			exit 2
		fi
	fi

	log_info "=== Analysis complete ==="
	exit 0
}

main "$@"
