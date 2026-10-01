#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# generate-models-md.sh - Generate MODELS.md from the model registry
# Part of t1012 (leaderboard), t1133 (global/per-repo split), GH#33145
# (retired the pattern-tracker/response-scoring performance mode; model
# comparison now lives in model-replay, model-ab and frontier-harness-eval).
#
# Usage:
#   generate-models-md.sh [--output PATH] [--quiet]
#   generate-models-md.sh help
#
# Data source:
#   Model registry DB (model catalog, pricing, tiers)
#
# Output:
#   MODELS.md (global model catalog, routing tiers, pricing)

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "${SCRIPT_DIR}/shared-constants.sh"
init_log_file

readonly REGISTRY_DB="${MODEL_REGISTRY_DB:-$HOME/.aidevops/.agent-workspace/model-registry.db}"

# Defaults
OUTPUT_PATH=""
QUIET=0

log_info() {
	[[ "$QUIET" -eq 1 ]] && return 0
	echo -e "${BLUE}[INFO]${NC} $*"
	return 0
}
log_success() {
	[[ "$QUIET" -eq 1 ]] && return 0
	echo -e "${GREEN}[OK]${NC} $*"
	return 0
}
log_error() {
	echo -e "${RED}[ERROR]${NC} $*" >&2
	return 0
}

#######################################
# Find the repo root for default output path
# Returns: repo root path or empty string
#######################################
find_repo_root() {
	git rev-parse --show-toplevel 2>/dev/null || echo ""
	return 0
}

#######################################
# Generate the model catalog section from registry DB
# Outputs: markdown table to stdout
#######################################
generate_catalog() {
	if ! [[ -f "$REGISTRY_DB" ]]; then
		echo "No model registry database found."
		echo ""
		return 0
	fi

	local count
	count=$(sqlite3 "$REGISTRY_DB" "SELECT COUNT(*) FROM models;" 2>/dev/null) || count=0
	if [[ "$count" -eq 0 ]]; then
		echo "No models registered yet."
		echo ""
		return 0
	fi

	echo "| Model | Provider | Tier | Context | Input/1M | Output/1M |"
	echo "| ------- | ---------- | ------ | --------- | ---------- | ----------- |"
	# The registry can retain historical rates. Use the shipped price source for
	# o3 when rendering a fresh catalog, without mutating the user's registry.
	local o3_input o3_output
	o3_input=$(jq -er '.models.o3.input | numbers' "${SCRIPT_DIR}/../configs/model-pricing.json") || return 1
	o3_output=$(jq -er '.models.o3.output | numbers' "${SCRIPT_DIR}/../configs/model-pricing.json") || return 1

	sqlite3 -separator '|' "$REGISTRY_DB" "
        SELECT
            model_id,
            provider,
            CASE tier
                WHEN 'high' THEN 'opus'
                WHEN 'medium' THEN 'sonnet'
                WHEN 'low' THEN 'haiku'
                ELSE tier
            END,
            CASE
                WHEN context_window >= 1000000 THEN (context_window / 1000000) || 'M'
                ELSE (context_window / 1000) || 'K'
            END,
            printf('\$%.2f', CASE WHEN model_id = 'o3' AND provider = 'openai' THEN ${o3_input} ELSE input_price END),
            printf('\$%.2f', CASE WHEN model_id = 'o3' AND provider = 'openai' THEN ${o3_output} ELSE output_price END)
        FROM models
        ORDER BY
            CASE tier WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END,
            provider,
            model_id;
    " 2>/dev/null | while IFS='|' read -r model provider tier ctx input output; do
		echo "| $model | $provider | $tier | $ctx | $input | $output |"
	done

	echo ""
	return 0
}

#######################################
# Generate the routing tiers section from subagent_models
# Outputs: markdown table to stdout
#######################################
generate_routing_tiers() {
	if ! [[ -f "$REGISTRY_DB" ]]; then
		return 0
	fi

	local count
	count=$(sqlite3 "$REGISTRY_DB" "SELECT COUNT(*) FROM subagent_models;" 2>/dev/null) || count=0
	if [[ "$count" -eq 0 ]]; then
		return 0
	fi

	echo "## Routing Tiers"
	echo ""
	echo "Active model assignments for each dispatch tier:"
	echo ""
	echo "| Tier | Primary Model | Relative Cost |"
	echo "| ------ | --------------- | --------------- |"

	# Resolve canonical model names from the models table.
	# subagent_models may store versioned provider-specific names,
	# while models stores canonical names.
	# Use a correlated subquery to find the longest matching canonical name,
	# falling back to sm.model_id if no match or if already canonical.
	sqlite3 -separator '|' "$REGISTRY_DB" "
        SELECT
            sm.tier,
            COALESCE(
                (SELECT m.model_id FROM models m
                 WHERE sm.model_id LIKE m.model_id || '%'
                 ORDER BY LENGTH(m.model_id) DESC
                 LIMIT 1),
                sm.model_id
            ),
            CASE sm.tier
                WHEN 'haiku' THEN '~0.33x'
                WHEN 'flash' THEN '~0.20x'
                WHEN 'sonnet' THEN '1x (baseline)'
                WHEN 'pro' THEN '~1.5x'
                WHEN 'opus' THEN '~1.7x'
                ELSE '?'
            END
        FROM subagent_models sm
        ORDER BY
            CASE sm.tier
                WHEN 'haiku' THEN 1
                WHEN 'flash' THEN 2
                WHEN 'sonnet' THEN 3
                WHEN 'pro' THEN 4
                WHEN 'opus' THEN 5
                ELSE 6
            END;
    " 2>/dev/null | while IFS='|' read -r tier model cost; do
		echo "| $tier | $model | $cost |"
	done

	echo ""
	return 0
}

#######################################
# Generate the global MODELS.md (model catalog, routing tiers, pricing)
# Arguments: output path
#######################################
generate_global_md() {
	local output="$1"
	local timestamp
	timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

	{
		echo "<!-- SPDX-License-Identifier: MIT -->"
		echo "<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->"
		echo ""
		echo "# Available Models"
		echo ""
		echo "Global model catalog, routing tiers, and pricing."
		echo "Auto-generated by \`generate-models-md.sh\` — do not edit manually."
		echo ""
		echo "**Last updated**: $timestamp"
		echo ""
		echo "## Model Catalog"
		echo ""
		generate_catalog
		generate_routing_tiers
		echo "---"
		echo ""
		echo "*Generated by [aidevops](https://github.com/marcusquinn/aidevops) t1012, t1133*"
	} >"$output"

	return 0
}

#######################################
# Show help
#######################################
cmd_help() {
	echo "generate-models-md.sh - Generate MODELS.md from the model registry"
	echo ""
	echo "Usage:"
	echo "  generate-models-md.sh [--output PATH] [--quiet]"
	echo "  generate-models-md.sh help"
	echo ""
	echo "Options:"
	echo "  --output PATH       Output file path (default: <repo root>/MODELS.md)"
	echo "  --quiet             Suppress info messages"
	echo ""
	echo "For head-to-head model comparison (\"how good is a new model at our"
	echo "work?\"), use model-replay, model-ab or frontier-harness-eval instead —"
	echo "see tools/ai-assistants/compare-models.md."
	echo ""
	echo "Data source:"
	echo "  Model registry:    $REGISTRY_DB"
	return 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
	case "$1" in
	--output)
		if [[ $# -lt 2 ]]; then
			log_error "--output requires a value"
			exit 1
		fi
		OUTPUT_PATH="$2"
		shift 2
		;;
	--quiet)
		QUIET=1
		shift
		;;
	help | --help | -h)
		cmd_help
		exit 0
		;;
	*)
		log_error "Unknown argument: $1"
		cmd_help
		exit 1
		;;
	esac
done

# Determine output path
if [[ -z "$OUTPUT_PATH" ]]; then
	local_repo_root="$(find_repo_root)"
	base_dir="${local_repo_root:-.}"
	OUTPUT_PATH="${base_dir}/MODELS.md"
fi

# Verify sqlite3 is available
if ! command -v sqlite3 &>/dev/null; then
	log_error "sqlite3 is required but not found"
	exit 1
fi

log_info "Generating MODELS.md from live registry data..."
log_info "  Registry: $REGISTRY_DB"

generate_global_md "$OUTPUT_PATH"

log_success "Generated $OUTPUT_PATH"
