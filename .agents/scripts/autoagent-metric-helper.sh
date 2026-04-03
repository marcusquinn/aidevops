#!/usr/bin/env bash
# autoagent-metric-helper.sh — composite scorer for autoagent framework self-improvement
# Subcommands: score, comprehension, lint, tokens, baseline, compare
# Usage: autoagent-metric-helper.sh <subcommand> [options]
# shellcheck disable=SC2317

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo ".")"
BASELINE_FILE="${AUTOAGENT_BASELINE_FILE:-$REPO_ROOT/.agents/configs/autoagent-baseline.json}"

# Default weights (configurable via env)
WEIGHT_COMPREHENSION="${AUTOAGENT_WEIGHT_COMPREHENSION:-0.5}"
WEIGHT_LINT="${AUTOAGENT_WEIGHT_LINT:-0.3}"
WEIGHT_TOKENS="${AUTOAGENT_WEIGHT_TOKENS:-0.2}"

# ─── helpers ────────────────────────────────────────────────────────────────

log() {
	echo "[autoagent-metric] $*" >&2
	return 0
}

die() {
	echo "[autoagent-metric] ERROR: $*" >&2
	exit 1
	return 1
}

require_tool() {
	local tool="$1"
	if ! command -v "$tool" >/dev/null 2>&1; then
		log "WARNING: $tool not found — skipping that metric component"
		return 1
	fi
	return 0
}

# ─── comprehension score ─────────────────────────────────────────────────────

run_comprehension() {
	local suite_path="${1:-}"
	local score

	# Locate test suite
	if [ -z "$suite_path" ]; then
		suite_path="$REPO_ROOT/.agents/tests/agent-optimization.test.json"
	fi

	if [ ! -f "$suite_path" ]; then
		log "WARNING: comprehension test suite not found at $suite_path — returning 1.0 (neutral)"
		echo "1.0"
		return 0
	fi

	if ! require_tool "agent-test-helper.sh"; then
		log "WARNING: agent-test-helper.sh not found — returning 1.0 (neutral)"
		echo "1.0"
		return 0
	fi

	score=$(agent-test-helper.sh run --suite "$suite_path" --metric pass_rate 2>/dev/null | tail -1) || {
		log "WARNING: agent-test-helper.sh failed — returning 1.0 (neutral)"
		echo "1.0"
		return 0
	}

	# Validate numeric
	if ! echo "$score" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
		log "WARNING: non-numeric comprehension score '$score' — returning 1.0"
		echo "1.0"
		return 0
	fi

	echo "$score"
	return 0
}

# ─── lint score ──────────────────────────────────────────────────────────────

# Count shellcheck passes across all tracked .sh files
_count_shellcheck_passes() {
	local sc_pass=0
	local f
	local sh_list
	sh_list=$(git -C "$REPO_ROOT" ls-files '*.sh' 2>/dev/null)
	while IFS= read -r f; do
		shellcheck "$REPO_ROOT/$f" >/dev/null 2>&1 && sc_pass=$((sc_pass + 1))
	done <<EOF_SH
$sh_list
EOF_SH
	echo "$sc_pass"
	return 0
}

run_lint() {
	local total_checks=0
	local passed_checks=0
	local score

	# ShellCheck on all .sh files
	if ! require_tool "shellcheck"; then
		log "WARNING: shellcheck not found — skipping shell lint"
	else
		local sh_files sc_pass
		sh_files=$(git -C "$REPO_ROOT" ls-files '*.sh' 2>/dev/null | wc -l | tr -d ' ')
		if [ "$sh_files" -gt 0 ]; then
			total_checks=$((total_checks + sh_files))
			sc_pass=$(_count_shellcheck_passes)
			passed_checks=$((passed_checks + sc_pass))
		fi
	fi

	# markdownlint on .agents/**/*.md
	if ! require_tool "markdownlint-cli2"; then
		log "WARNING: markdownlint-cli2 not found — skipping markdown lint"
	else
		local md_files
		md_files=$(git -C "$REPO_ROOT" ls-files '.agents/**/*.md' '.agents/*.md' 2>/dev/null | wc -l | tr -d ' ')
		if [ "$md_files" -gt 0 ]; then
			total_checks=$((total_checks + 1))
			markdownlint-cli2 "$REPO_ROOT/.agents/**/*.md" >/dev/null 2>&1 && passed_checks=$((passed_checks + 1))
		fi
	fi

	if [ "$total_checks" -eq 0 ]; then
		log "WARNING: no lint checks ran — returning 1.0 (neutral)"
		echo "1.0"
		return 0
	fi

	# score = passed / total (0–1)
	score=$(awk "BEGIN { printf \"%.4f\", $passed_checks / $total_checks }")
	echo "$score"
	return 0
}

# ─── token score ─────────────────────────────────────────────────────────────

run_tokens() {
	local suite_path="${1:-}"
	local baseline_chars ratio

	if [ -z "$suite_path" ]; then
		suite_path="$REPO_ROOT/.agents/tests/agent-optimization.test.json"
	fi

	# Load baseline chars from baseline file
	if [ ! -f "$BASELINE_FILE" ]; then
		log "WARNING: baseline file not found at $BASELINE_FILE — run 'baseline' subcommand first"
		echo "1.0"
		return 0
	fi

	baseline_chars=$(jq -r '.baseline_chars // empty' "$BASELINE_FILE" 2>/dev/null) || {
		log "WARNING: could not read baseline_chars from $BASELINE_FILE"
		echo "1.0"
		return 0
	}

	if [ -z "$baseline_chars" ] || [ "$baseline_chars" = "null" ]; then
		log "WARNING: baseline_chars not set — run 'baseline' subcommand first"
		echo "1.0"
		return 0
	fi

	# Guard against zero/negative baseline (would cause divide-by-zero)
	if ! echo "$baseline_chars" | grep -qE '^[0-9]+(\.[0-9]+)?$' ||
		awk -v v="$baseline_chars" 'BEGIN { exit (v > 0) ? 0 : 1 }'; then
		log "WARNING: baseline_chars must be a positive number (got: $baseline_chars) — returning 1.0"
		echo "1.0"
		return 0
	fi

	if ! require_tool "agent-test-helper.sh"; then
		log "WARNING: agent-test-helper.sh not found — returning 1.0 (neutral)"
		echo "1.0"
		return 0
	fi

	if [ ! -f "$suite_path" ]; then
		log "WARNING: test suite not found at $suite_path — returning 1.0"
		echo "1.0"
		return 0
	fi

	local avg_chars
	avg_chars=$(agent-test-helper.sh run --suite "$suite_path" --metric avg_response_chars 2>/dev/null | tail -1) || {
		log "WARNING: agent-test-helper.sh failed for token metric — returning 1.0"
		echo "1.0"
		return 0
	}

	if ! echo "$avg_chars" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
		log "WARNING: non-numeric avg_chars '$avg_chars' — returning 1.0"
		echo "1.0"
		return 0
	fi

	ratio=$(awk "BEGIN { printf \"%.4f\", $avg_chars / $baseline_chars }")
	echo "$ratio"
	return 0
}

# ─── composite score ─────────────────────────────────────────────────────────

run_score() {
	local suite_path="${1:-}"
	local comprehension lint_score token_ratio composite

	log "Computing composite score..."

	comprehension=$(run_comprehension "$suite_path")
	lint_score=$(run_lint)
	token_ratio=$(run_tokens "$suite_path")

	# composite = w_comp * comprehension + w_lint * lint - w_tokens * (token_ratio - 1)
	# token_ratio > 1 means more tokens than baseline (penalise); < 1 means fewer (reward)
	composite=$(awk -v comp="$comprehension" -v lint="$lint_score" -v tr="$token_ratio" \
		-v w_comp="$WEIGHT_COMPREHENSION" -v w_lint="$WEIGHT_LINT" -v w_tok="$WEIGHT_TOKENS" \
		'BEGIN {
    tok_component = 1.0 - (tr - 1.0)
    tok_component = (tok_component < 0) ? 0 : tok_component
    tok_component = (tok_component > 2) ? 2 : tok_component
    score = w_comp * comp + w_lint * lint + w_tok * tok_component
    score = (score < 0) ? 0 : score
    score = (score > 1) ? 1 : score
    printf "%.4f", score
  }')

	# Output JSON for structured parsing
	cat <<EOF
{
  "composite_score": $composite,
  "comprehension_score": $comprehension,
  "lint_score": $lint_score,
  "token_ratio": $token_ratio,
  "weights": {
    "comprehension": $WEIGHT_COMPREHENSION,
    "lint": $WEIGHT_LINT,
    "tokens": $WEIGHT_TOKENS
  }
}
EOF
	# Also print composite_score as last line for autoresearch metric parsing
	echo "$composite"
	return 0
}

# ─── baseline ────────────────────────────────────────────────────────────────

run_baseline() {
	local suite_path="${1:-}"

	if [ -z "$suite_path" ]; then
		suite_path="$REPO_ROOT/.agents/tests/agent-optimization.test.json"
	fi

	log "Establishing baseline..."

	local avg_chars=0
	if require_tool "agent-test-helper.sh" && [ -f "$suite_path" ]; then
		avg_chars=$(agent-test-helper.sh run --suite "$suite_path" --metric avg_response_chars 2>/dev/null | tail -1) || avg_chars=0
		if ! echo "$avg_chars" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
			avg_chars=0
		fi
	fi

	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	mkdir -p "$(dirname "$BASELINE_FILE")"
	cat >"$BASELINE_FILE" <<EOF
{
  "baseline_chars": $avg_chars,
  "established_at": "$timestamp",
  "suite": "$suite_path"
}
EOF

	log "Baseline established: baseline_chars=$avg_chars"
	echo "$avg_chars"
	return 0
}

# ─── compare ─────────────────────────────────────────────────────────────────

run_compare() {
	local before="${1:-}"
	local after="${2:-}"

	if [ -z "$before" ] || [ -z "$after" ]; then
		die "Usage: autoagent-metric-helper.sh compare <before_score> <after_score>"
	fi

	local delta improvement improved
	delta=$(awk -v a="$after" -v b="$before" 'BEGIN { printf "%.4f", a - b }')
	improvement=$(awk -v a="$after" -v b="$before" 'BEGIN {
    printf "%.2f", (b == 0) ? 0 : ((a - b) / b) * 100
  }')
	improved=$(awk -v a="$after" -v b="$before" 'BEGIN { print (a > b) ? "true" : "false" }')

	cat <<EOF
{
  "before": $before,
  "after": $after,
  "delta": $delta,
  "improvement_pct": $improvement,
  "improved": $improved
}
EOF
	return 0
}

# ─── main ────────────────────────────────────────────────────────────────────

main() {
	local subcommand="${1:-score}"
	shift || true

	case "$subcommand" in
	score)
		run_score "$@"
		;;
	comprehension)
		run_comprehension "$@"
		;;
	lint)
		run_lint "$@"
		;;
	tokens)
		run_tokens "$@"
		;;
	baseline)
		run_baseline "$@"
		;;
	compare)
		run_compare "$@"
		;;
	help | --help | -h)
		printf '%s\n' \
			"autoagent-metric-helper.sh — composite scorer (autoagent self-improvement)" \
			"" \
			"Subcommands:" \
			"  score [suite]            Composite score (JSON + numeric last line)" \
			"  comprehension [suite]    Comprehension pass rate (0-1)" \
			"  lint                     Lint pass rate: shellcheck + markdownlint (0-1)" \
			"  tokens [suite]           Token ratio vs baseline (1.0 = same as baseline)" \
			"  baseline [suite]         Establish baseline_chars (token ratio computation)" \
			"  compare <before> <after> Compare two composite scores (JSON)" \
			"" \
			"Environment:" \
			"  AUTOAGENT_BASELINE_FILE         Baseline JSON path" \
			"  AUTOAGENT_WEIGHT_COMPREHENSION  Comprehension weight (default: 0.5)" \
			"  AUTOAGENT_WEIGHT_LINT           Lint weight (default: 0.3)" \
			"  AUTOAGENT_WEIGHT_TOKENS         Token weight (default: 0.2)" \
			"" \
			"Graceful degradation: missing tools return neutral scores (1.0) rather than failing."
		;;
	*)
		die "Unknown subcommand: $subcommand. Run 'autoagent-metric-helper.sh help' for usage."
		;;
	esac
	return 0
}

main "$@"
