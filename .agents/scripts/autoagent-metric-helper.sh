#!/usr/bin/env bash
# autoagent-metric-helper.sh - Composite fitness scorer for framework self-improvement
#
# Computes a composite fitness score for framework changes. Used by the autoagent
# subagent as its METRIC_CMD in research programs.
#
# Usage:
#   autoagent-metric-helper.sh score [--suite <path>] [--weights <w1,w2,w3>] [--baseline-file <path>]
#   autoagent-metric-helper.sh comprehension [--suite <path>]
#   autoagent-metric-helper.sh lint
#   autoagent-metric-helper.sh tokens [--suite <path>] [--baseline-file <path>]
#   autoagent-metric-helper.sh baseline [--suite <path>] [--baseline-file <path>]
#   autoagent-metric-helper.sh compare [--suite <path>] [--weights <w1,w2,w3>] [--baseline-file <path>]
#   autoagent-metric-helper.sh help
#
# Composite formula (v1):
#   composite = 0.6 * comprehension_score + 0.3 * linter_score - 0.1 * max(0, token_cost_ratio - 1.0)
#
# Weights configurable via --weights "0.6,0.3,0.1"
#
# Baseline sidecar: todo/research/.autoagent-baseline.json
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR

# Source shared constants if available (provides color codes, log_* functions)
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# Color codes (fallback if shared-constants.sh not available)
# Use declare to avoid readonly collision when shared-constants.sh already set these
if [[ -z "${GREEN+x}" ]]; then GREEN='\033[0;32m'; fi
if [[ -z "${YELLOW+x}" ]]; then YELLOW='\033[0;33m'; fi
if [[ -z "${RED+x}" ]]; then RED='\033[0;31m'; fi
if [[ -z "${NC+x}" ]]; then NC='\033[0m'; fi

# Defaults
readonly DEFAULT_BASELINE_FILE="todo/research/.autoagent-baseline.json"
readonly DEFAULT_WEIGHTS="0.6,0.3,0.1"
readonly DEFAULT_SUITE=""

# Logging helpers
log_info() { echo -e "${YELLOW}[INFO]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*" >&2; }

#######################################
# Parse weights string into three variables
# Arguments:
#   $1 - weights string "w1,w2,w3"
# Outputs:
#   Sets WEIGHT_COMPREHENSION, WEIGHT_LINT, WEIGHT_TOKENS in caller scope
# Returns:
#   0 on success, 1 on invalid format
#######################################
parse_weights() {
	local weights_str="$1"
	local w1 w2 w3

	w1=$(echo "$weights_str" | cut -d',' -f1)
	w2=$(echo "$weights_str" | cut -d',' -f2)
	w3=$(echo "$weights_str" | cut -d',' -f3)

	if [[ -z "$w1" || -z "$w2" || -z "$w3" ]]; then
		log_error "Invalid weights format: '$weights_str'. Expected 'w1,w2,w3' (e.g. '0.6,0.3,0.1')"
		return 1
	fi

	WEIGHT_COMPREHENSION="$w1"
	WEIGHT_LINT="$w2"
	WEIGHT_TOKENS="$w3"
	return 0
}

#######################################
# Run comprehension tests via agent-test-helper.sh
# Arguments:
#   $1 - suite path (optional; empty = skip)
# Outputs:
#   Float (0.0-1.0) on stdout
# Returns:
#   0 on success, 1 on failure (caller should treat as neutral)
#######################################
cmd_comprehension() {
	local suite="$1"
	local agent_test_helper="${SCRIPT_DIR}/agent-test-helper.sh"

	if [[ ! -x "$agent_test_helper" ]]; then
		log_warn "agent-test-helper.sh not found or not executable — returning neutral comprehension score"
		echo "1.0"
		return 0
	fi

	if [[ -z "$suite" ]]; then
		log_warn "No test suite specified (--suite) — returning neutral comprehension score"
		echo "1.0"
		return 0
	fi

	if [[ ! -f "$suite" ]]; then
		log_warn "Test suite not found: $suite — returning neutral comprehension score"
		echo "1.0"
		return 0
	fi

	local json_output
	json_output=$("$agent_test_helper" run "$suite" --json 2>/dev/null) || {
		log_warn "agent-test-helper.sh run failed — returning neutral comprehension score"
		echo "1.0"
		return 0
	}

	local pass_rate
	pass_rate=$(echo "$json_output" | jq -r '.pass_rate // "1.0"' 2>/dev/null) || pass_rate="1.0"

	if [[ -z "$pass_rate" ]]; then
		pass_rate="1.0"
	fi

	echo "$pass_rate"
	return 0
}

#######################################
# Compute linter pass rate
# Checks changed files (git diff vs main) or a capped sample of tracked files.
# Scoped to changed files for performance — full-repo lint is too slow for a
# fitness function called in tight autoagent research loops.
# Outputs:
#   Float (0.0-1.0) on stdout — fraction of checked files passing lint
# Returns:
#   0 always (graceful degradation)
#######################################
cmd_lint() {
	local total=0
	local passed=0

	# Determine which shell files to check:
	# 1. Changed files vs main (fast, relevant for autoagent loop)
	# 2. Fall back to a capped sample of all tracked files
	local sh_files_to_check=""
	local md_files_to_check=""

	# Try to get changed files vs main/master
	local base_ref=""
	if git rev-parse --verify origin/main >/dev/null 2>&1; then
		base_ref="origin/main"
	elif git rev-parse --verify origin/master >/dev/null 2>&1; then
		base_ref="origin/master"
	elif git rev-parse --verify main >/dev/null 2>&1; then
		base_ref="main"
	fi

	if [[ -n "$base_ref" ]]; then
		sh_files_to_check=$(git diff --name-only "$base_ref" HEAD -- '*.sh' 2>/dev/null | grep '.agents/scripts/' || true)
		md_files_to_check=$(git diff --name-only "$base_ref" HEAD -- '*.md' 2>/dev/null | grep '.agents/' || true)
	fi

	# If no changed files, sample up to 20 tracked files (capped for performance)
	if [[ -z "$sh_files_to_check" ]]; then
		sh_files_to_check=$(git ls-files '.agents/scripts/*.sh' 2>/dev/null | head -20) || sh_files_to_check=""
	fi
	if [[ -z "$md_files_to_check" ]]; then
		md_files_to_check=$(git ls-files '.agents/**/*.md' 2>/dev/null | head -20) || md_files_to_check=""
	fi

	# --- ShellCheck ---
	if command -v shellcheck >/dev/null 2>&1; then
		if [[ -n "$sh_files_to_check" ]]; then
			while IFS= read -r file; do
				[[ -f "$file" ]] || continue
				total=$((total + 1))
				if shellcheck --severity=warning "$file" >/dev/null 2>&1; then
					passed=$((passed + 1))
				fi
			done <<<"$sh_files_to_check"
		fi
	else
		log_warn "shellcheck not installed — skipping shell lint checks"
	fi

	# --- markdownlint ---
	local md_cmd=""
	if command -v markdownlint-cli2 >/dev/null 2>&1; then
		md_cmd="markdownlint-cli2"
	elif command -v markdownlint >/dev/null 2>&1; then
		md_cmd="markdownlint"
	fi

	if [[ -n "$md_cmd" ]]; then
		if [[ -n "$md_files_to_check" ]]; then
			while IFS= read -r file; do
				[[ -f "$file" ]] || continue
				total=$((total + 1))
				if $md_cmd "$file" >/dev/null 2>&1; then
					passed=$((passed + 1))
				fi
			done <<<"$md_files_to_check"
		fi
	else
		log_warn "markdownlint not installed — skipping markdown lint checks"
	fi

	if [[ $total -eq 0 ]]; then
		log_warn "No files found to lint — returning neutral lint score"
		echo "1.0"
		return 0
	fi

	# Compute ratio — always use awk for proper float formatting (leading zero, 4dp)
	local ratio
	if command -v awk >/dev/null 2>&1; then
		ratio=$(awk "BEGIN { printf \"%.4f\", $passed / $total }" 2>/dev/null) || ratio="1.0"
	elif command -v bc >/dev/null 2>&1; then
		# bc may omit leading zero (e.g. ".8333"); normalize with sed
		local raw
		raw=$(echo "scale=4; $passed / $total" | bc 2>/dev/null) || raw="1.0"
		# Add leading zero if missing
		case "$raw" in
		.*) ratio="0${raw}" ;;
		*) ratio="$raw" ;;
		esac
	else
		# Integer fallback
		if [[ $passed -eq $total ]]; then
			ratio="1.0"
		else
			ratio="0.0"
		fi
	fi

	echo "$ratio"
	return 0
}

#######################################
# Compute token cost ratio vs baseline
# Arguments:
#   $1 - suite path (optional)
#   $2 - baseline file path
# Outputs:
#   Float ratio on stdout (>1.0 means more expensive than baseline)
# Returns:
#   0 always (graceful degradation)
#######################################
cmd_tokens() {
	local suite="$1"
	local baseline_file="$2"
	local agent_test_helper="${SCRIPT_DIR}/agent-test-helper.sh"

	if [[ ! -f "$baseline_file" ]]; then
		log_warn "No baseline file found at $baseline_file — returning neutral token ratio"
		echo "1.0"
		return 0
	fi

	local baseline_chars
	baseline_chars=$(jq -r '.avg_tokens // 0' "$baseline_file" 2>/dev/null) || baseline_chars="0"

	if [[ -z "$baseline_chars" || "$baseline_chars" == "0" || "$baseline_chars" == "null" ]]; then
		log_warn "Baseline has no avg_tokens — returning neutral token ratio"
		echo "1.0"
		return 0
	fi

	if [[ ! -x "$agent_test_helper" || -z "$suite" || ! -f "$suite" ]]; then
		log_warn "Cannot measure current tokens (no agent-test-helper or suite) — returning neutral"
		echo "1.0"
		return 0
	fi

	local json_output
	json_output=$("$agent_test_helper" run "$suite" --json 2>/dev/null) || {
		log_warn "agent-test-helper.sh run failed for token measurement — returning neutral"
		echo "1.0"
		return 0
	}

	local current_chars
	current_chars=$(echo "$json_output" | jq -r '.avg_response_chars // 0' 2>/dev/null) || current_chars="0"

	if [[ -z "$current_chars" || "$current_chars" == "0" ]]; then
		log_warn "Could not measure current avg_response_chars — returning neutral"
		echo "1.0"
		return 0
	fi

	local ratio
	if command -v awk >/dev/null 2>&1; then
		ratio=$(awk "BEGIN { printf \"%.4f\", $current_chars / $baseline_chars }" 2>/dev/null) || ratio="1.0"
	elif command -v bc >/dev/null 2>&1; then
		local raw
		raw=$(echo "scale=4; $current_chars / $baseline_chars" | bc 2>/dev/null) || raw="1.0"
		case "$raw" in
		.*) ratio="0${raw}" ;;
		*) ratio="$raw" ;;
		esac
	else
		ratio="1.0"
	fi

	echo "$ratio"
	return 0
}

#######################################
# Establish baseline measurements
# Arguments:
#   $1 - suite path (optional)
#   $2 - baseline file path
# Outputs:
#   Writes JSON sidecar to baseline_file
# Returns:
#   0 on success, 1 on failure
#######################################
cmd_baseline() {
	local suite="$1"
	local baseline_file="$2"
	local agent_test_helper="${SCRIPT_DIR}/agent-test-helper.sh"

	# Ensure parent directory exists
	local baseline_dir
	baseline_dir=$(dirname "$baseline_file")
	mkdir -p "$baseline_dir" || {
		log_error "Cannot create baseline directory: $baseline_dir"
		return 1
	}

	log_info "Establishing baseline measurements..."

	# Comprehension score
	local comprehension_score="1.0"
	local avg_tokens=0

	if [[ -x "$agent_test_helper" && -n "$suite" && -f "$suite" ]]; then
		log_info "Running comprehension tests for baseline..."
		local json_output
		json_output=$("$agent_test_helper" run "$suite" --json 2>/dev/null) || json_output=""

		if [[ -n "$json_output" ]]; then
			comprehension_score=$(echo "$json_output" | jq -r '.pass_rate // 1.0' 2>/dev/null) || comprehension_score="1.0"
			avg_tokens=$(echo "$json_output" | jq -r '.avg_response_chars // 0' 2>/dev/null) || avg_tokens=0
		fi
	else
		log_warn "Skipping comprehension baseline (no agent-test-helper or suite)"
	fi

	# Linter score
	log_info "Running lint checks for baseline..."
	local linter_score
	linter_score=$(cmd_lint 2>/dev/null) || linter_score="1.0"
	# Normalize: ensure leading zero for JSON validity (bc may output ".8333")
	case "$linter_score" in
	.*) linter_score="0${linter_score}" ;;
	esac

	# Count lintable files
	local files_checked=0
	local sh_count md_count
	sh_count=$(git ls-files '.agents/scripts/*.sh' 2>/dev/null | wc -l | tr -d ' ') || sh_count=0
	md_count=$(git ls-files '.agents/**/*.md' 2>/dev/null | wc -l | tr -d ' ') || md_count=0
	files_checked=$((sh_count + md_count))

	local created_at
	created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || created_at="unknown"

	local suite_field="null"
	if [[ -n "$suite" ]]; then
		suite_field="\"$suite\""
	fi

	# Write JSON sidecar
	cat >"$baseline_file" <<EOF
{
  "created": "${created_at}",
  "comprehension_score": ${comprehension_score},
  "linter_score": ${linter_score},
  "avg_tokens": ${avg_tokens},
  "files_checked": ${files_checked},
  "suite": ${suite_field}
}
EOF

	log_ok "Baseline written to: $baseline_file"
	cat "$baseline_file" >&2
	return 0
}

#######################################
# Compute composite score
# Arguments:
#   $1 - suite path (optional)
#   $2 - weights string "w1,w2,w3"
#   $3 - baseline file path
# Outputs:
#   Single float (0.0-1.0) on stdout
# Returns:
#   0 on success, 1 on sub-scorer failure
#######################################
cmd_score() {
	local suite="$1"
	local weights_str="$2"
	local baseline_file="$3"

	local WEIGHT_COMPREHENSION WEIGHT_LINT WEIGHT_TOKENS
	parse_weights "$weights_str" || return 1

	local comprehension_score linter_score token_ratio
	comprehension_score=$(cmd_comprehension "$suite" 2>/dev/null) || comprehension_score="1.0"
	linter_score=$(cmd_lint 2>/dev/null) || linter_score="1.0"
	token_ratio=$(cmd_tokens "$suite" "$baseline_file" 2>/dev/null) || token_ratio="1.0"

	# composite = w1 * comprehension + w2 * lint - w3 * max(0, token_ratio - 1.0)
	# Prefer awk for proper float formatting (leading zero, clamping)
	local composite
	if command -v awk >/dev/null 2>&1; then
		composite=$(awk -v c="$comprehension_score" -v l="$linter_score" -v t="$token_ratio" \
			-v wc="$WEIGHT_COMPREHENSION" -v wl="$WEIGHT_LINT" -v wt="$WEIGHT_TOKENS" \
			'BEGIN {
				penalty = t - 1.0
				if (penalty < 0) penalty = 0
				score = wc * c + wl * l - wt * penalty
				if (score < 0) score = 0
				if (score > 1) score = 1
				printf "%.4f\n", score
			}' 2>/dev/null) || composite="0.0"
	elif command -v bc >/dev/null 2>&1; then
		local raw
		raw=$(echo "scale=4; \
			c = $comprehension_score; \
			l = $linter_score; \
			t = $token_ratio; \
			penalty = t - 1.0; \
			if (penalty < 0) penalty = 0; \
			$WEIGHT_COMPREHENSION * c + $WEIGHT_LINT * l - $WEIGHT_TOKENS * penalty" | bc 2>/dev/null) || raw="0.0"
		# Normalize leading zero
		case "$raw" in
		.*) composite="0${raw}" ;;
		*) composite="$raw" ;;
		esac
	else
		log_warn "Neither bc nor awk available — cannot compute composite score"
		composite="0.0"
	fi

	echo "$composite"
	return 0
}

#######################################
# Compare current vs baseline, show all sub-scores
# Arguments:
#   $1 - suite path (optional)
#   $2 - weights string "w1,w2,w3"
#   $3 - baseline file path
# Outputs:
#   JSON breakdown on stdout
# Returns:
#   0 on success
#######################################
cmd_compare() {
	local suite="$1"
	local weights_str="$2"
	local baseline_file="$3"

	local WEIGHT_COMPREHENSION WEIGHT_LINT WEIGHT_TOKENS
	parse_weights "$weights_str" || return 1

	local comprehension_score linter_score token_ratio composite
	comprehension_score=$(cmd_comprehension "$suite" 2>/dev/null) || comprehension_score="1.0"
	linter_score=$(cmd_lint 2>/dev/null) || linter_score="1.0"
	token_ratio=$(cmd_tokens "$suite" "$baseline_file" 2>/dev/null) || token_ratio="1.0"
	composite=$(cmd_score "$suite" "$weights_str" "$baseline_file" 2>/dev/null) || composite="0.0"

	# Read baseline values for delta computation
	local baseline_comprehension="null"
	local baseline_linter="null"
	local baseline_tokens="null"

	if [[ -f "$baseline_file" ]]; then
		baseline_comprehension=$(jq -r '.comprehension_score // "null"' "$baseline_file" 2>/dev/null) || baseline_comprehension="null"
		baseline_linter=$(jq -r '.linter_score // "null"' "$baseline_file" 2>/dev/null) || baseline_linter="null"
		baseline_tokens=$(jq -r '.avg_tokens // "null"' "$baseline_file" 2>/dev/null) || baseline_tokens="null"
	fi

	local created_at
	created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || created_at="unknown"

	# Output JSON breakdown
	jq -n \
		--arg timestamp "$created_at" \
		--argjson composite "$composite" \
		--argjson comprehension "$comprehension_score" \
		--argjson lint "$linter_score" \
		--argjson tokens "$token_ratio" \
		--arg wc "$WEIGHT_COMPREHENSION" \
		--arg wl "$WEIGHT_LINT" \
		--arg wt "$WEIGHT_TOKENS" \
		--argjson b_comprehension "${baseline_comprehension:-null}" \
		--argjson b_linter "${baseline_linter:-null}" \
		'{
			"timestamp": $timestamp,
			"composite_score": $composite,
			"sub_scores": {
				"comprehension": $comprehension,
				"lint": $lint,
				"token_cost_ratio": $tokens
			},
			"weights": {
				"comprehension": $wc,
				"lint": $wl,
				"tokens": $wt
			},
			"baseline_delta": {
				"comprehension": (if $b_comprehension != null then ($comprehension - $b_comprehension) else null end),
				"lint": (if $b_linter != null then ($lint - $b_linter) else null end)
			}
		}' 2>/dev/null || {
		# Fallback if jq not available
		echo "{\"composite_score\": $composite, \"comprehension\": $comprehension_score, \"lint\": $linter_score, \"token_cost_ratio\": $token_ratio}"
	}

	return 0
}

#######################################
# HELP command
#######################################
cmd_help() {
	cat <<'EOF'
autoagent-metric-helper.sh - Composite fitness scorer for framework self-improvement

USAGE:
  autoagent-metric-helper.sh <subcommand> [options]

SUBCOMMANDS:
  score        Compute composite fitness score (single float 0.0-1.0)
  comprehension  Run agent comprehension tests, return pass rate
  lint         Run shellcheck + markdownlint, return pass rate
  tokens       Compute token cost ratio vs baseline
  baseline     Establish baseline measurements, write JSON sidecar
  compare      Compare current vs baseline, show all sub-scores as JSON
  help         Show this help

OPTIONS:
  --suite <path>          Path to agent test suite JSON file
  --weights <w1,w2,w3>   Composite weights (default: 0.6,0.3,0.1)
  --baseline-file <path>  Baseline sidecar path (default: todo/research/.autoagent-baseline.json)
  --json                  Machine-readable output (where applicable)

COMPOSITE FORMULA (v1):
  composite = 0.6 * comprehension_score + 0.3 * linter_score - 0.1 * max(0, token_cost_ratio - 1.0)

BASELINE SIDECAR FORMAT:
  {
    "created": "ISO-8601",
    "comprehension_score": 0.85,
    "linter_score": 0.92,
    "avg_tokens": 1234,
    "files_checked": 45,
    "suite": ".agents/tests/agent-optimization.test.json"
  }

GRACEFUL DEGRADATION:
  - Missing agent-test-helper.sh → comprehension returns 1.0 (neutral)
  - Missing test suite → comprehension returns 1.0 (neutral)
  - Missing linters → lint returns 1.0 (neutral)
  - Missing baseline → token ratio returns 1.0 (neutral)
  All warnings go to stderr; scores go to stdout.

EXAMPLES:
  # Establish baseline
  autoagent-metric-helper.sh baseline --suite .agents/tests/smoke.json

  # Get composite score (used as METRIC_CMD in autoresearch)
  autoagent-metric-helper.sh score --suite .agents/tests/smoke.json

  # Compare current vs baseline
  autoagent-metric-helper.sh compare --suite .agents/tests/smoke.json

  # Custom weights (emphasise lint over comprehension)
  autoagent-metric-helper.sh score --weights "0.4,0.5,0.1"

  # Custom baseline location
  autoagent-metric-helper.sh baseline --baseline-file /tmp/my-baseline.json
EOF
	return 0
}

#######################################
# Main entry point
#######################################
main() {
	local command="${1:-help}"
	shift || true

	# Parse global flags
	local suite="$DEFAULT_SUITE"
	local weights="$DEFAULT_WEIGHTS"
	local baseline_file="$DEFAULT_BASELINE_FILE"

	local remaining_args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--suite)
			suite="$2"
			shift 2
			;;
		--weights)
			weights="$2"
			shift 2
			;;
		--baseline-file)
			baseline_file="$2"
			shift 2
			;;
		--json)
			# Accepted but currently all output is already machine-readable
			shift
			;;
		*)
			remaining_args+=("$1")
			shift
			;;
		esac
	done

	case "$command" in
	score)
		cmd_score "$suite" "$weights" "$baseline_file"
		;;
	comprehension)
		cmd_comprehension "$suite"
		;;
	lint)
		cmd_lint
		;;
	tokens)
		cmd_tokens "$suite" "$baseline_file"
		;;
	baseline)
		cmd_baseline "$suite" "$baseline_file"
		;;
	compare)
		cmd_compare "$suite" "$weights" "$baseline_file"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		log_error "Unknown subcommand: $command"
		cmd_help >&2
		return 1
		;;
	esac
}

main "$@"
