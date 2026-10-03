#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Compare Models Helper - Cross-Model Review and Registry-Backed Listing
# Dispatches the same prompt to multiple models and diffs the results
# (/cross-review), and lists the live model catalog from the model
# registry. "How good is a new model at our work?" is answered by
# model-replay, model-ab and frontier-harness-eval, not this script —
# see tools/ai-assistants/compare-models.md.
#
# Usage: compare-models-helper.sh [command] [options]
#
# Commands:
#   list          List models from the model registry (model-registry-helper.sh)
#   cross-review  Dispatch same prompt to multiple models, diff results (t132.8)
#   score         Record model comparison scores (from cross-review --score)
#   results       View past comparison results and rankings
#   help          Show this help
#
# Author: AI DevOps Framework
# Version: 2.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# =============================================================================
# Registry-Backed Model Listing
# =============================================================================
# The model catalog lives in model-registry-helper.sh (SQLite-backed, synced
# from subagent frontmatter and provider APIs) instead of a hardcoded table
# duplicated in this script.

cmd_list() {
	local registry_helper="${SCRIPT_DIR}/model-registry-helper.sh"
	if [[ ! -x "$registry_helper" ]]; then
		print_error "model-registry-helper.sh not found at $registry_helper"
		return 1
	fi
	"$registry_helper" list "$@"
	return $?
}

# =============================================================================
# Sub-Library Imports
# =============================================================================
# Extracted for file-size compliance (GH#20398). scoring-lib defines cmd_score
# / cmd_results, used by cross-review-lib's optional --score judge pipeline.

# shellcheck source=./compare-models-scoring-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/compare-models-scoring-lib.sh"

# shellcheck source=./compare-models-cross-review-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/compare-models-cross-review-lib.sh"

cmd_help() {
	echo ""
	echo "Compare Models Helper - Cross-Model Review and Registry-Backed Listing"
	echo "========================================================================"
	echo ""
	echo "Usage: compare-models-helper.sh [command] [options]"
	echo ""
	echo "Commands:"
	echo "  list          List models from the model registry"
	echo "  cross-review  Dispatch same prompt to multiple models, diff results"
	echo "  score         Record model comparison scores (from evaluation)"
	echo "  results       View past comparison results and rankings"
	echo "  help          Show this help"
	echo ""
	echo "Examples:"
	echo "  compare-models-helper.sh list"
	echo "  compare-models-helper.sh list --provider Anthropic"
	echo ""
	echo "Cross-review examples:"
	echo "  compare-models-helper.sh cross-review \\"
	echo "    --prompt 'Review this code for security issues: ...'"
	echo "    # defaults to all configured standard-tier models"
	echo "  compare-models-helper.sh cross-review \\"
	echo "    --prompt 'Audit the architecture of this project' \\"
	echo "    --models 'openai/gpt-5.6-sol,anthropic/claude-sonnet-5-5' --timeout 900"
	echo "  compare-models-helper.sh cross-review \\"
	echo "    --prompt 'Review this PR diff' \\"
	echo "    --score                          # auto-score via judge model (default: thinking)"
	echo "  compare-models-helper.sh cross-review \\"
	echo "    --prompt 'Review this PR diff' \\"
	echo "    --score --judge standard          # use the standard workload tier as judge"
	echo "  compare-models-helper.sh cross-review \\"
	echo "    --prompt 'Review this code' \\"
	echo "    --prompt-file prompts/build.txt   # track prompt version in results"
	echo ""
	echo "Scoring examples:"
	echo "  compare-models-helper.sh score --task 'fix React bug' --type code \\"
	echo "    --model claude-sonnet-5-5 --correctness 9 --completeness 8 --quality 8 --clarity 9 --adherence 9 \\"
	echo "    --model gpt-5.3-codex --correctness 8 --completeness 7 --quality 7 --clarity 8 --adherence 8 \\"
	echo "    --winner claude-sonnet-5-5"
	echo "  compare-models-helper.sh results"
	echo "  compare-models-helper.sh results --model standard --limit 5"
	echo "  compare-models-helper.sh results --prompt-version a1b2c3d"
	echo ""
	echo "For \"how good is a new model at our work?\", use model-replay, model-ab,"
	echo "or frontier-harness-eval instead of this script — see"
	echo "tools/ai-assistants/compare-models.md."
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	list)
		cmd_list "$@"
		;;
	cross-review)
		cmd_cross_review "$@"
		;;
	score)
		cmd_score "$@"
		;;
	results)
		cmd_results "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return $?
}

main "$@"
