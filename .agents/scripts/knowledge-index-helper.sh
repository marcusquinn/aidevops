#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
set -euo pipefail

# =============================================================================
# Knowledge Index Helper (t2850 foundation + t2857 case-scope extension)
# =============================================================================
# Queries the knowledge plane sources using tree-walk RAG (vectorless).
# Returns excerpts with source anchors for use in draft composition,
# analysis, and other retrieval-augmented generation tasks.
#
# Usage:
#   knowledge-index-helper.sh query --intent "..." [--scope case=<id>] [options]
#   knowledge-index-helper.sh status
#   knowledge-index-helper.sh help
#
# Options:
#   --intent <text>       Search intent / query (REQUIRED for query)
#   --scope case=<id>     Restrict to sources attached to a specific case
#   --limit <N>           Max number of excerpts to return (default: 8)
#   --max-chars <N>       Max chars per excerpt (default: 2000)
#   --repo <path>         Target repo path (default: cwd)
#   --json                Machine-readable JSON output
#
# ShellCheck clean. Bash 3.2 compatible (macOS default).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

# =============================================================================
# Constants
# =============================================================================

readonly KNOWLEDGE_DIR="_knowledge"
readonly SOURCES_DIR="sources"
readonly META_FILE="meta.json"
readonly CASES_DIR="_cases"
readonly CASE_SOURCES_FILE="sources.toon"

readonly DEFAULT_LIMIT=8
readonly DEFAULT_MAX_CHARS=2000

# =============================================================================
# Internal helpers
# =============================================================================

_require_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		print_error "jq is required but not found. Install: brew install jq"
		return 1
	fi
	return 0
}

# _resolve_knowledge_dir <repo-path>
_resolve_knowledge_dir() {
	local repo_path="${1:-$(pwd)}"
	echo "${repo_path}/${KNOWLEDGE_DIR}/${SOURCES_DIR}"
	return 0
}

# _case_find <cases-dir> <case-id> — find case directory
_case_find() {
	local cases_dir="$1" query="$2"

	if [[ -d "${cases_dir}/${query}" ]]; then
		echo "${cases_dir}/${query}"
		return 0
	fi

	local dir
	for dir in "${cases_dir}"/case-*-"${query}" "${cases_dir}"/case-*-*"${query}"*; do
		[[ -d "$dir" ]] || continue
		[[ "$dir" == *"/archived/"* ]] && continue
		echo "$dir"
		return 0
	done

	return 1
}

# _get_case_source_ids <repo-path> <case-id> — list source IDs attached to a case
_get_case_source_ids() {
	local repo_path="$1" case_id="$2"
	local cases_dir="${repo_path}/${CASES_DIR}"
	local case_dir

	case_dir="$(_case_find "$cases_dir" "$case_id")" || {
		print_error "Case not found for scope filter: ${case_id}"
		return 1
	}

	local sources_file="${case_dir}/${CASE_SOURCES_FILE}"
	if [[ ! -f "$sources_file" ]]; then
		return 0
	fi

	jq -r '.[].id' "$sources_file" 2>/dev/null || true
	return 0
}

# _extract_excerpt <source-dir> <max-chars> — extract text content from a source
_extract_excerpt() {
	local source_dir="$1" max_chars="$2"

	# Try content files in priority order
	local f content_file=""
	for f in "${source_dir}"/content.txt "${source_dir}"/extracted.txt \
		"${source_dir}"/*.txt "${source_dir}"/*.md; do
		if [[ -f "$f" ]]; then
			content_file="$f"
			break
		fi
	done

	# Fallback to any non-meta file
	if [[ -z "$content_file" ]]; then
		for f in "${source_dir}"/*; do
			[[ -f "$f" ]] || continue
			[[ "$(basename "$f")" == "$META_FILE" ]] && continue
			content_file="$f"
			break
		done
	fi

	if [[ -n "$content_file" ]]; then
		head -c "$max_chars" "$content_file" 2>/dev/null || echo "(unable to read)"
	else
		echo "(no content available)"
	fi
	return 0
}

# _score_relevance <intent> <source-id> <meta-json> — basic keyword relevance
# Returns 0-100 score. Simple keyword overlap — not semantic search.
_score_relevance() {
	local intent="$1" source_id="$2" meta_json="$3"
	local score=50 # default mid-score for all sources

	# Boost if source kind matches intent keywords
	local kind
	kind="$(echo "$meta_json" | jq -r '.kind // ""' 2>/dev/null)" || kind=""

	# Simple keyword check — boost score for kind matches
	local intent_lower
	intent_lower="$(echo "$intent" | tr '[:upper:]' '[:lower:]')"

	if [[ "$intent_lower" == *"invoice"* && "$kind" == *"document"* ]]; then
		score=75
	elif [[ "$intent_lower" == *"contract"* && "$kind" == *"document"* ]]; then
		score=75
	elif [[ "$intent_lower" == *"email"* && "$kind" == *"export"* ]]; then
		score=70
	fi

	echo "$score"
	return 0
}

# =============================================================================
# cmd_query — query knowledge sources for relevant excerpts
# =============================================================================

cmd_query() {
	_require_jq || return 1

	local intent="" scope="" limit="$DEFAULT_LIMIT" max_chars="$DEFAULT_MAX_CHARS"
	local repo_path="" json_mode=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--intent) intent="$_nxt"; shift 2 ;;
		--scope) scope="$_nxt"; shift 2 ;;
		--limit) limit="$_nxt"; shift 2 ;;
		--max-chars) max_chars="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		--json) json_mode=true; shift ;;
		-*) print_error "Unknown option: $_cur"; return 1 ;;
		*) shift ;;
		esac
	done

	[[ -z "$intent" ]] && { print_error "--intent is required"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local sources_dir
	sources_dir="$(_resolve_knowledge_dir "$repo_path")"

	if [[ ! -d "$sources_dir" ]]; then
		print_error "Knowledge sources directory not found: ${sources_dir}"
		return 1
	fi

	# Determine which source IDs to search
	local -a allowed_ids=()
	local scope_case_id=""

	if [[ "$scope" == case=* ]]; then
		scope_case_id="${scope#case=}"
		local case_ids
		case_ids="$(_get_case_source_ids "$repo_path" "$scope_case_id")" || return 1
		while IFS= read -r sid; do
			[[ -n "$sid" ]] && allowed_ids+=("$sid")
		done <<<"$case_ids"

		if [[ ${#allowed_ids[@]} -eq 0 ]]; then
			if [[ "$json_mode" == true ]]; then
				echo '{"excerpts":[],"scope":"'"$scope"'","message":"no sources attached to case"}'
			else
				echo "No sources attached to case: ${scope_case_id}"
			fi
			return 0
		fi
	fi

	# Collect excerpts
	local results_json="[]"
	local count=0

	local source_dir
	for source_dir in "${sources_dir}"/*/; do
		[[ -d "$source_dir" ]] || continue
		[[ "$count" -ge "$limit" ]] && break

		local source_id
		source_id="$(basename "$source_dir")"

		# Apply scope filter
		if [[ ${#allowed_ids[@]} -gt 0 ]]; then
			local found=false
			local aid
			for aid in "${allowed_ids[@]}"; do
				if [[ "$aid" == "$source_id" ]]; then
					found=true
					break
				fi
			done
			[[ "$found" != true ]] && continue
		fi

		# Read metadata
		local meta_path="${source_dir}/${META_FILE}"
		local meta_json='{}'
		[[ -f "$meta_path" ]] && meta_json="$(jq '.' "$meta_path" 2>/dev/null)" || meta_json='{}'

		# Score relevance
		local score
		score="$(_score_relevance "$intent" "$source_id" "$meta_json")"

		# Extract excerpt
		local excerpt
		excerpt="$(_extract_excerpt "$source_dir" "$max_chars")"

		count=$((count + 1))

		if [[ "$json_mode" == true ]]; then
			local entry
			entry="$(jq -n \
				--arg id "$source_id" \
				--arg excerpt "$excerpt" \
				--argjson score "$score" \
				--argjson meta "$meta_json" \
				'{id:$id, excerpt:$excerpt, score:$score, meta:$meta}')"
			results_json="$(echo "$results_json" | jq --argjson e "$entry" '. + [$e]')"
		else
			printf '[%s] (score: %s): "%s"\n\n' "$source_id" "$score" "$excerpt"
		fi
	done

	if [[ "$json_mode" == true ]]; then
		jq -n \
			--argjson excerpts "$results_json" \
			--arg scope "${scope:-all}" \
			--arg intent "$intent" \
			--argjson count "$count" \
			'{excerpts:$excerpts, scope:$scope, intent:$intent, count:$count}'
	fi
	return 0
}

# =============================================================================
# cmd_status — show knowledge index status
# =============================================================================

cmd_status() {
	local repo_path="${1:-$(pwd)}"
	local sources_dir
	sources_dir="$(_resolve_knowledge_dir "$repo_path")"

	if [[ ! -d "$sources_dir" ]]; then
		echo "Knowledge plane not provisioned at: ${sources_dir}"
		return 0
	fi

	local source_count=0
	local dir
	for dir in "${sources_dir}"/*/; do
		[[ -d "$dir" ]] || continue
		source_count=$((source_count + 1))
	done

	echo "Knowledge index status:"
	echo "  Sources directory: ${sources_dir}"
	echo "  Source count: ${source_count}"
	echo "  Index type: tree-walk (vectorless)"
	return 0
}

# =============================================================================
# cmd_help
# =============================================================================

cmd_help() {
	cat <<'HELP'
Knowledge Index Helper — query knowledge sources for AI-assisted retrieval

Usage:
  knowledge-index-helper.sh query --intent "..." [options]
  knowledge-index-helper.sh status [repo-path]
  knowledge-index-helper.sh help

Query options:
  --intent <text>       Search intent / query (REQUIRED)
  --scope case=<id>     Restrict to sources attached to a specific case
  --limit <N>           Max excerpts to return (default: 8)
  --max-chars <N>       Max chars per excerpt (default: 2000)
  --repo <path>         Target repo path (default: cwd)
  --json                Machine-readable JSON output

Examples:
  knowledge-index-helper.sh query --intent "overdue invoices for ACME"
  knowledge-index-helper.sh query --intent "contract terms" --scope case=case-2026-0001-acme
  knowledge-index-helper.sh query --intent "settlement history" --limit 5 --json
  knowledge-index-helper.sh status
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	query | search) cmd_query "$@" ;;
	status) cmd_status "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
