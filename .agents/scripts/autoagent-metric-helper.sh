#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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
# Composite formula (v2):
#   token_efficiency = clamp(2 - token_cost_ratio, 0, 1)
#   composite = wc * comprehension_score + wl * linter_score + wt * token_efficiency
#
# Weights configurable via --weights "0.6,0.3,0.1"
#
# Baseline sidecar: todo/research/.autoagent-baseline.json
#
# Author: AI DevOps Framework
# Version: 2.0.0
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
readonly DEFAULT_SUITE=".agents/tests/agents-md-knowledge.json"
readonly NEUTRAL_SUITE_JSON='{"pass_rate":1.0,"avg_response_chars":null}'

# Logging helpers
log_info() {
	printf '%b[INFO]%b %s\n' "$YELLOW" "$NC" "$*" >&2
	return 0
}
log_warn() {
	printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2
	return 0
}
log_error() {
	printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2
	return 0
}
log_ok() {
	printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$*" >&2
	return 0
}

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
	local w1=""
	local w2=""
	local w3=""
	local extra=""
	local numeric_pattern='^([0-9]+([.][0-9]*)?|[.][0-9]+)$'

	IFS=',' read -r w1 w2 w3 extra <<<"$weights_str"
	if [[ -n "$extra" || -z "$w1" || -z "$w2" || -z "$w3" ]] ||
		[[ ! "$w1" =~ $numeric_pattern || ! "$w2" =~ $numeric_pattern || ! "$w3" =~ $numeric_pattern ]]; then
		log_error "Invalid weights: '$weights_str'. Expected exactly three non-negative numbers (for example 0.6,0.3,0.1)"
		return 1
	fi

	if ! awk -v w1="$w1" -v w2="$w2" -v w3="$w3" \
		'BEGIN { sum=w1+w2+w3; delta=sum-1; if (delta<0) delta=-delta; exit(delta <= 0.000001 ? 0 : 1) }'; then
		log_error "Invalid weights: '$weights_str'. Values must sum to 1.0"
		return 1
	fi

	WEIGHT_COMPREHENSION="$w1"
	WEIGHT_LINT="$w2"
	WEIGHT_TOKENS="$w3"
	return 0
}

#######################################
# Run an agent test suite once and return its JSON metrics.
# Arguments:
#   $1 - suite path
# Outputs: suite JSON, or neutral JSON when unavailable
# Returns: 0 always (graceful degradation)
#######################################
_run_suite_json() {
	local suite="$1"
	local agent_test_helper="${SCRIPT_DIR}/agent-test-helper.sh"
	local json_output=""

	if [[ ! -x "$agent_test_helper" ]]; then
		log_warn "agent-test-helper.sh not found or not executable; using neutral suite metrics"
		printf '%s\n' "$NEUTRAL_SUITE_JSON"
		return 0
	fi
	if [[ -z "$suite" || ! -f "$suite" ]]; then
		log_warn "Test suite unavailable: ${suite:-<empty>}; using neutral suite metrics"
		printf '%s\n' "$NEUTRAL_SUITE_JSON"
		return 0
	fi

	json_output=$("$agent_test_helper" run "$suite" --json 2>/dev/null) || json_output=""
	if [[ -z "$json_output" ]] || ! jq -e . >/dev/null 2>&1 <<<"$json_output"; then
		log_warn "agent-test-helper.sh run failed; using neutral suite metrics"
		printf '%s\n' "$NEUTRAL_SUITE_JSON"
		return 0
	fi

	printf '%s\n' "$json_output"
	return 0
}

#######################################
# Extract comprehension score from suite JSON.
# Arguments:
#   $1 - suite JSON
# Outputs: float on stdout
# Returns: 0 always
#######################################
_comprehension_from_json() {
	local suite_json="$1"
	local pass_rate="1.0"

	pass_rate=$(jq -r '.pass_rate // 1.0' 2>/dev/null <<<"$suite_json") || pass_rate="1.0"
	[[ -n "$pass_rate" && "$pass_rate" != "null" ]] || pass_rate="1.0"
	printf '%s\n' "$pass_rate"
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
	local suite_json=""

	suite_json=$(_run_suite_json "$suite")
	_comprehension_from_json "$suite_json"
	return 0
}

#######################################
# Resolve the base git ref for diff-based file selection
# Outputs: ref name on stdout, or empty if none found
# Returns: 0 always
#######################################
_lint_base_ref() {
	if git rev-parse --verify origin/main >/dev/null 2>&1; then
		echo "origin/main"
	elif git rev-parse --verify origin/master >/dev/null 2>&1; then
		echo "origin/master"
	elif git rev-parse --verify main >/dev/null 2>&1; then
		echo "main"
	fi
	return 0
}

#######################################
# Count passing shellcheck files from a newline-separated list
# Arguments:
#   $1 - newline-separated file list
# Outputs:
#   "passed total" on stdout
# Returns: 0 always
#######################################
_lint_count_shellcheck() {
	local file_list="$1"
	local total=0
	local passed=0
	local file

	while IFS= read -r file; do
		[[ -f "$file" ]] || continue
		total=$((total + 1))
		if shellcheck --severity=warning "$file" >/dev/null 2>&1; then
			passed=$((passed + 1))
		fi
	done <<<"$file_list"

	echo "$passed $total"
	return 0
}

#######################################
# Count passing markdownlint files from a newline-separated list
# Arguments:
#   $1 - markdownlint command
#   $2 - newline-separated file list
# Outputs:
#   "passed total" on stdout
# Returns: 0 always
#######################################
_lint_count_markdown() {
	local md_cmd="$1"
	local file_list="$2"
	local total=0
	local passed=0
	local file

	while IFS= read -r file; do
		[[ -f "$file" ]] || continue
		total=$((total + 1))
		if $md_cmd "$file" >/dev/null 2>&1; then
			passed=$((passed + 1))
		fi
	done <<<"$file_list"

	echo "$passed $total"
	return 0
}

#######################################
# Format a ratio as a 4dp float with leading zero
# Arguments:
#   $1 - numerator
#   $2 - denominator
# Outputs: float string on stdout
# Returns: 0 always
#######################################
_format_ratio() {
	local num="$1"
	local den="$2"

	if command -v awk >/dev/null 2>&1; then
		awk "BEGIN { printf \"%.4f\", $num / $den }" 2>/dev/null || echo "1.0"
	elif command -v bc >/dev/null 2>&1; then
		local raw
		raw=$(echo "scale=4; $num / $den" | bc 2>/dev/null) || raw="1.0"
		case "$raw" in
		.*) echo "0${raw}" ;;
		*) echo "$raw" ;;
		esac
	else
		if [[ "$num" -eq "$den" ]]; then echo "1.0"; else echo "0.0"; fi
	fi
	return 0
}

#######################################
# Compute linter pass rate
# Checks working-tree changes vs main plus non-ignored untracked files, or a capped
# sample of tracked files when no relevant candidate changes exist.
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

	# Resolve base ref for diff-based file selection
	local base_ref
	base_ref=$(_lint_base_ref)

	# Collect tracked working-tree differences and non-ignored untracked files once.
	local candidate_files=""
	local changed_files=""
	local untracked_files=""
	if [[ -n "$base_ref" ]]; then
		changed_files=$(git diff --name-only "$base_ref" -- 2>/dev/null) || changed_files=""
	fi
	untracked_files=$(git ls-files --others --exclude-standard -- 2>/dev/null) || untracked_files=""
	candidate_files=$(printf '%s\n%s\n' "$changed_files" "$untracked_files" |
		grep -E '^(\.agents/scripts/.*\.sh|\.agents/.*\.md)$' |
		LC_ALL=C sort -u) || candidate_files=""

	# Use changed candidates when present; otherwise retain bounded tracked samples.
	local sh_files=""
	local md_files=""
	if [[ -n "$candidate_files" ]]; then
		sh_files=$(grep -E '^\.agents/scripts/.*\.sh$' <<<"$candidate_files") || sh_files=""
		md_files=$(grep -E '^\.agents/.*\.md$' <<<"$candidate_files") || md_files=""
	else
		sh_files=$(git ls-files '.agents/scripts/*.sh' 2>/dev/null | head -20) || sh_files=""
		md_files=$(git ls-files '.agents/**/*.md' 2>/dev/null | head -20) || md_files=""
	fi

	# Run shellcheck
	if command -v shellcheck >/dev/null 2>&1; then
		if [[ -n "$sh_files" ]]; then
			local sc_result
			sc_result=$(_lint_count_shellcheck "$sh_files")
			local sc_passed sc_total
			sc_passed=$(echo "$sc_result" | cut -d' ' -f1)
			sc_total=$(echo "$sc_result" | cut -d' ' -f2)
			passed=$((passed + sc_passed))
			total=$((total + sc_total))
		fi
	else
		log_warn "shellcheck not installed — skipping shell lint checks"
	fi

	# Run markdownlint
	local md_cmd=""
	if command -v markdownlint-cli2 >/dev/null 2>&1; then
		md_cmd="markdownlint-cli2"
	elif command -v markdownlint >/dev/null 2>&1; then
		md_cmd="markdownlint"
	fi

	if [[ -n "$md_cmd" && -n "$md_files" ]]; then
		local ml_result
		ml_result=$(_lint_count_markdown "$md_cmd" "$md_files")
		local ml_passed ml_total
		ml_passed=$(echo "$ml_result" | cut -d' ' -f1)
		ml_total=$(echo "$ml_result" | cut -d' ' -f2)
		passed=$((passed + ml_passed))
		total=$((total + ml_total))
	elif [[ -z "$md_cmd" ]]; then
		log_warn "markdownlint not installed — skipping markdown lint checks"
	fi

	if [[ $total -eq 0 ]]; then
		log_warn "No files found to lint — returning neutral lint score"
		echo "1.0"
		return 0
	fi

	_format_ratio "$passed" "$total"
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
_token_ratio_from_json() {
	local suite_json="$1"
	local baseline_file="$2"

	if [[ ! -f "$baseline_file" ]]; then
		log_warn "No baseline file found at $baseline_file — returning neutral token ratio"
		printf '%s\n' "1.0"
		return 0
	fi

	local baseline_chars
	baseline_chars=$(jq -r '.avg_tokens // 0' "$baseline_file" 2>/dev/null) || baseline_chars="0"

	if [[ -z "$baseline_chars" || "$baseline_chars" == "0" || "$baseline_chars" == "null" ]]; then
		log_warn "Baseline has no avg_tokens — returning neutral token ratio"
		printf '%s\n' "1.0"
		return 0
	fi

	local current_chars
	current_chars=$(jq -r '.avg_response_chars // 0' 2>/dev/null <<<"$suite_json") || current_chars="0"

	if [[ -z "$current_chars" || "$current_chars" == "0" || "$current_chars" == "null" ]]; then
		log_warn "Could not measure current avg_response_chars — returning neutral"
		printf '%s\n' "1.0"
		return 0
	fi

	_format_ratio "$current_chars" "$baseline_chars"
	return 0
}

#######################################
# Compute token cost ratio from at most one standalone suite execution.
# Arguments:
#   $1 - suite path
#   $2 - baseline file path
# Outputs: float ratio on stdout
# Returns: 0 always
#######################################
cmd_tokens() {
	local suite="$1"
	local baseline_file="$2"
	local suite_json=""

	if [[ ! -f "$baseline_file" ]]; then
		log_warn "No baseline file found at $baseline_file — returning neutral token ratio"
		printf '%s\n' "1.0"
		return 0
	fi

	suite_json=$(_run_suite_json "$suite")
	_token_ratio_from_json "$suite_json" "$baseline_file"
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
# Compute composite score from sub-scores
# token_efficiency = clamp(2-token_ratio, 0, 1)
# composite = wc*comprehension + wl*lint + wt*token_efficiency
# Arguments:
#   $1 - comprehension score
#   $2 - linter score
#   $3 - token ratio
#   $4 - weight_comprehension
#   $5 - weight_lint
#   $6 - weight_tokens
# Outputs: float on stdout
# Returns: 0 always
#######################################
_compute_composite() {
	local c="$1" l="$2" t="$3" wc="$4" wl="$5" wt="$6"
	local result

	# Use awk with ternary operators to avoid multi-line if blocks (nesting depth)
	if command -v awk >/dev/null 2>&1; then
		result=$(awk -v c="$c" -v l="$l" -v t="$t" -v wc="$wc" -v wl="$wl" -v wt="$wt" \
			'BEGIN { e=2-t; e=(e<0?0:(e>1?1:e)); s=wc*c+wl*l+wt*e; s=(s<0?0:(s>1?1:s)); printf "%.4f\n",s }' \
			2>/dev/null) || result="0.0"
		printf '%s\n' "$result"
	elif command -v bc >/dev/null 2>&1; then
		local raw
		raw=$(printf 'scale=4; c=%s; l=%s; t=%s; e=2-t; if(e<0)e=0; if(e>1)e=1; %s*c+%s*l+%s*e\n' \
			"$c" "$l" "$t" "$wc" "$wl" "$wt" | bc 2>/dev/null) || raw="0.0"
		case "$raw" in
		.*) printf '0%s\n' "$raw" ;;
		*) printf '%s\n' "$raw" ;;
		esac
	else
		log_warn "Neither bc nor awk available — cannot compute composite score"
		printf '%s\n' "0.0"
	fi
	return 0
}

#######################################
# Compute clamped token efficiency from a token ratio.
# Arguments:
#   $1 - token ratio
# Outputs: float on stdout
# Returns: 0 always
#######################################
_compute_token_efficiency() {
	local token_ratio="$1"

	awk -v t="$token_ratio" 'BEGIN { e=2-t; e=(e<0?0:(e>1?1:e)); printf "%.4f\n",e }' 2>/dev/null ||
		printf '%s\n' "1.0"
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

	local suite_json=""
	local comprehension_score="1.0"
	local linter_score="1.0"
	local token_ratio="1.0"
	suite_json=$(_run_suite_json "$suite")
	comprehension_score=$(_comprehension_from_json "$suite_json")
	linter_score=$(cmd_lint 2>/dev/null) || linter_score="1.0"
	token_ratio=$(_token_ratio_from_json "$suite_json" "$baseline_file" 2>/dev/null) || token_ratio="1.0"

	local composite
	composite=$(_compute_composite \
		"$comprehension_score" "$linter_score" "$token_ratio" \
		"$WEIGHT_COMPREHENSION" "$WEIGHT_LINT" "$WEIGHT_TOKENS")

	printf '%s\n' "$composite"
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

	local suite_json=""
	local comprehension_score="1.0"
	local linter_score="1.0"
	local token_ratio="1.0"
	local token_efficiency="1.0"
	local composite="0.0"
	suite_json=$(_run_suite_json "$suite")
	comprehension_score=$(_comprehension_from_json "$suite_json")
	linter_score=$(cmd_lint 2>/dev/null) || linter_score="1.0"
	token_ratio=$(_token_ratio_from_json "$suite_json" "$baseline_file" 2>/dev/null) || token_ratio="1.0"
	token_efficiency=$(_compute_token_efficiency "$token_ratio")
	composite=$(_compute_composite "$comprehension_score" "$linter_score" "$token_ratio" \
		"$WEIGHT_COMPREHENSION" "$WEIGHT_LINT" "$WEIGHT_TOKENS")

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
		--argjson token_efficiency "$token_efficiency" \
		--argjson wc "$WEIGHT_COMPREHENSION" \
		--argjson wl "$WEIGHT_LINT" \
		--argjson wt "$WEIGHT_TOKENS" \
		--argjson b_comprehension "${baseline_comprehension:-null}" \
		--argjson b_linter "${baseline_linter:-null}" \
		'{
			"timestamp": $timestamp,
			"composite_score": $composite,
			"sub_scores": {
				comprehension: $comprehension,
				lint: $lint,
				"token_cost_ratio": $tokens,
				"token_efficiency": $token_efficiency
			},
			"weights": {
				comprehension: $wc,
				lint: $wl,
				"tokens": $wt
			},
			"baseline_delta": {
				comprehension: (if $b_comprehension != null then ($comprehension - $b_comprehension) else null end),
				lint: (if $b_linter != null then ($lint - $b_linter) else null end)
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

COMPOSITE FORMULA (v2):
  token_efficiency = clamp(2 - token_cost_ratio, 0, 1)
  composite = wc * comprehension_score + wl * linter_score + wt * token_efficiency

BASELINE SIDECAR FORMAT:
  {
    "created": "ISO-8601",
    "comprehension_score": 0.85,
    "linter_score": 0.92,
    "avg_tokens": 1234,
    "files_checked": 45,
    "suite": ".agents/tests/agents-md-knowledge.json"
  }

GRACEFUL DEGRADATION:
  - Missing agent-test-helper.sh → comprehension returns 1.0 (neutral)
  - Missing test suite → comprehension returns 1.0 (neutral)
  - Missing linters → lint returns 1.0 (neutral)
  - Missing baseline → token ratio returns 1.0 (neutral)
  All warnings go to stderr; scores go to stdout.

EXAMPLES:
  # Establish baseline
  autoagent-metric-helper.sh baseline --suite .agents/tests/agents-md-knowledge.json

  # Get composite score (used as METRIC_CMD in autoresearch)
  autoagent-metric-helper.sh score --suite .agents/tests/agents-md-knowledge.json

  # Compare current vs baseline
  autoagent-metric-helper.sh compare --suite .agents/tests/agents-md-knowledge.json

  # Custom weights (emphasise lint over comprehension)
  autoagent-metric-helper.sh score --weights "0.4,0.5,0.1"

  # Custom baseline location
  autoagent-metric-helper.sh baseline --baseline-file "${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}/my-baseline.json"
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
	local argument=""
	local value=""

	while [[ $# -gt 0 ]]; do
		argument="$1"
		case "$argument" in
		--suite)
			value="${2:-}"
			if [[ $# -lt 2 || -z "$value" || "$value" == --* ]]; then
				log_error "Missing value for --suite"
				return 1
			fi
			suite="$value"
			shift 2
			;;
		--weights)
			value="${2:-}"
			if [[ $# -lt 2 || -z "$value" || "$value" == --* ]]; then
				log_error "Missing value for --weights"
				return 1
			fi
			weights="$value"
			shift 2
			;;
		--baseline-file)
			value="${2:-}"
			if [[ $# -lt 2 || -z "$value" || "$value" == --* ]]; then
				log_error "Missing value for --baseline-file"
				return 1
			fi
			baseline_file="$value"
			shift 2
			;;
		--json)
			# Accepted but currently all output is already machine-readable
			shift
			;;
		*)
			log_error "Unexpected argument: $argument"
			return 1
			;;
		esac
	done

	local status=0
	case "$command" in
	score)
		cmd_score "$suite" "$weights" "$baseline_file" || status=$?
		;;
	comprehension)
		cmd_comprehension "$suite" || status=$?
		;;
	lint)
		cmd_lint || status=$?
		;;
	tokens)
		cmd_tokens "$suite" "$baseline_file" || status=$?
		;;
	baseline)
		cmd_baseline "$suite" "$baseline_file" || status=$?
		;;
	compare)
		cmd_compare "$suite" "$weights" "$baseline_file" || status=$?
		;;
	help | --help | -h)
		cmd_help || status=$?
		;;
	*)
		log_error "Unknown subcommand: $command"
		cmd_help >&2
		return 1
		;;
	esac
	return "$status"
}

main "$@"
