#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# knowledge-index-helper.sh — PageIndex tree generation across the knowledge corpus
#
# Generates per-source and corpus-wide PageIndex trees for vectorless RAG.
# Each promoted source gets a tree.json; the corpus index aggregates all sources.
# Incremental: only rebuilds sources whose text.txt has changed (sha-cache).
#
# Usage:
#   knowledge-index-helper.sh build-source <id> [knowledge-root]  Build tree for one source
#   knowledge-index-helper.sh build [knowledge-root]              Incremental corpus build
#   knowledge-index-helper.sh query <intent> [knowledge-root]     Query the corpus tree
#   knowledge-index-helper.sh status [knowledge-root]             Show index state
#   knowledge-index-helper.sh help                                Show this help
#
# Environment overrides:
#   KNOWLEDGE_ROOT     Override the knowledge root dir (default: _knowledge)
#   LLM_ROUTING_DRY_RUN=1  Skip real LLM calls (summaries use first-sentence fallback)
#
# Directory contract:
#   <root>/sources/<id>/text.txt    Plain-text extracted content (written by t2849)
#   <root>/sources/<id>/tree.json   Per-source PageIndex tree (written here)
#   <root>/index/tree.json          Corpus meta-tree (written here)
#   <root>/index/.tree-hash         SHA of source IDs + mtimes (incremental cache)
#   <root>/index/llm-audit.log      JSONL audit of LLM routing decisions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# Guard colour fallbacks when shared-constants.sh is absent
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

if ! declare -f print_info >/dev/null 2>&1; then
	print_info() { local _m="$1"; printf "${BLUE}[INFO]${NC} %s\n" "$_m"; }
fi
if ! declare -f print_success >/dev/null 2>&1; then
	print_success() { local _m="$1"; printf "${GREEN}[OK]${NC} %s\n" "$_m"; }
fi
if ! declare -f print_warning >/dev/null 2>&1; then
	print_warning() { local _m="$1"; printf "${YELLOW}[WARN]${NC} %s\n" "$_m"; }
fi
if ! declare -f print_error >/dev/null 2>&1; then
	print_error() { local _m="$1"; printf "${RED}[ERROR]${NC} %s\n" "$_m"; }
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

KNOWLEDGE_ROOT="${KNOWLEDGE_ROOT:-_knowledge}"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-120}"
LLM_ROUTING_DRY_RUN="${LLM_ROUTING_DRY_RUN:-0}"

_QUERY_HELPER="${SCRIPT_DIR}/knowledge_index_helpers.py"
_PAGEINDEX_GEN="${SCRIPT_DIR}/pageindex-generator.py"

# Canonical string constants (avoids repeated literal violations in linter)
_KI_FALSE="false"
_KI_TRUE="true"
_KI_INTERNAL="internal"

# Case-scope constants (t2857 extension)
_CASES_DIR_NAME="_cases"
_CASE_SOURCES_FILE="sources.toon"
_META_FILE="meta.json"

# ---------------------------------------------------------------------------
# Internal: requirement checks
# ---------------------------------------------------------------------------

_require_python3() {
	if ! command -v python3 >/dev/null 2>&1; then
		print_error "python3 is required but not installed"
		return 1
	fi
	return 0
}

_require_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		print_error "jq is required but not installed"
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Internal: knowledge root helpers
# ---------------------------------------------------------------------------

_resolve_root() {
	# Resolve knowledge root: arg → KNOWLEDGE_ROOT env → default "_knowledge"
	local root_arg="${1:-}"
	if [[ -n "$root_arg" ]]; then
		echo "$root_arg"
	else
		echo "$KNOWLEDGE_ROOT"
	fi
	return 0
}

_sources_dir() {
	local knowledge_root="$1"
	echo "${knowledge_root}/sources"
	return 0
}

_index_dir() {
	local knowledge_root="$1"
	echo "${knowledge_root}/index"
	return 0
}

# ---------------------------------------------------------------------------
# Internal: LLM routing for source sensitivity
# ---------------------------------------------------------------------------

_map_sensitivity_to_tier() {
	# Map knowledge sensitivity level to llm-routing tier
	local sensitivity="$1"
	case "$sensitivity" in
	public) echo "public" ;;
	internal | "") echo "$_KI_INTERNAL" ;;
	confidential) echo "sensitive" ;;
	restricted | privileged) echo "privileged" ;;
	*) echo "$_KI_INTERNAL" ;;
	esac
	return 0
}

_read_source_sensitivity() {
	local meta_path="$1"
	local sensitivity=""
	if [[ -f "$meta_path" ]] && command -v jq >/dev/null 2>&1; then
		sensitivity=$(jq -r ".sensitivity // \"${_KI_INTERNAL}\"" "$meta_path" 2>/dev/null) \
			|| sensitivity="$_KI_INTERNAL"
	fi
	echo "${sensitivity:-${_KI_INTERNAL}}"
	return 0
}

_decide_llm_flags() {
	# Return use_ollama flag based on tier and LLM_ROUTING_DRY_RUN
	# Outputs: "false" or "true" to stdout
	local tier="$1"
	if [[ "$LLM_ROUTING_DRY_RUN" == "1" ]]; then
		echo "$_KI_FALSE"
		return 0
	fi
	case "$tier" in
	sensitive | privileged)
		# Local-only tiers — use ollama if available
		if command -v ollama >/dev/null 2>&1; then
			echo "$_KI_TRUE"
		else
			echo "$_KI_FALSE"
		fi
		;;
	*)
		# public/internal — use first-sentence extraction (no LLM overhead)
		echo "$_KI_FALSE"
		;;
	esac
	return 0
}

_write_llm_audit() {
	# Append a JSONL routing decision to index/llm-audit.log
	local index_dir="$1"
	local source_id="$2"
	local tier="$3"
	local use_ollama="$4"
	local audit_log="${index_dir}/llm-audit.log"
	local ts
	ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown")
	local provider="first-sentence"
	[[ "$use_ollama" == "$_KI_TRUE" ]] && provider="ollama"
	printf '{"ts":"%s","action":"build_tree","source_id":"%s","tier":"%s","provider":"%s","dry_run":%s}\n' \
		"$ts" "$source_id" "$tier" "$provider" \
		"$([ "$LLM_ROUTING_DRY_RUN" = "1" ] && echo true || echo false)" \
		>> "$audit_log"
	return 0
}

# ---------------------------------------------------------------------------
# Internal: incremental hash helpers
# ---------------------------------------------------------------------------

_compute_corpus_hash() {
	# Hash source IDs + their tree.json mtimes to detect corpus changes
	local sources_dir="$1"
	local hash_input=""
	local src_id

	if [[ ! -d "$sources_dir" ]]; then
		echo ""
		return 0
	fi

	# Sorted iteration is portable (bash 3.2 compatible — no mapfile)
	for src_id in $(ls "$sources_dir" 2>/dev/null | sort); do
		local tree_path="${sources_dir}/${src_id}/tree.json"
		if [[ -d "${sources_dir}/${src_id}" ]]; then
			local mtime="0"
			if [[ -f "$tree_path" ]]; then
				mtime=$(_file_mtime_epoch "$tree_path")
			fi
			hash_input="${hash_input}${src_id}:${mtime}|"
		fi
	done

	if [[ -z "$hash_input" ]]; then
		echo ""
		return 0
	fi
	printf '%s' "$hash_input" | sha256sum 2>/dev/null | awk '{print $1}' || true
	return 0
}

_should_rebuild() {
	# Returns 0 (rebuild needed) or 1 (cache hit — skip)
	local sources_dir="$1"
	local index_dir="$2"
	local hash_file="${index_dir}/.tree-hash"
	local corpus_tree="${index_dir}/tree.json"

	# Always rebuild if corpus tree is missing
	if [[ ! -f "$corpus_tree" ]]; then
		return 0
	fi

	local current_hash
	current_hash=$(_compute_corpus_hash "$sources_dir")
	if [[ -z "$current_hash" ]]; then
		return 0
	fi

	local cached_hash=""
	[[ -f "$hash_file" ]] && cached_hash=$(cat "$hash_file" 2>/dev/null || true)

	if [[ "$current_hash" == "$cached_hash" ]]; then
		return 1  # No change — skip
	fi
	return 0
}

_update_corpus_hash() {
	local sources_dir="$1"
	local index_dir="$2"
	local hash_file="${index_dir}/.tree-hash"
	local current_hash
	current_hash=$(_compute_corpus_hash "$sources_dir")
	[[ -n "$current_hash" ]] && printf '%s\n' "$current_hash" > "$hash_file"
	return 0
}

# ---------------------------------------------------------------------------
# Internal: lock helpers (mkdir is atomic, bash 3.2 compatible)
# ---------------------------------------------------------------------------

_lock_acquire() {
	local lock_dir="$1"
	local elapsed=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		sleep 1
		elapsed=$((elapsed + 1))
		if [[ "$elapsed" -ge "$LOCK_TIMEOUT" ]]; then
			print_error "Timeout waiting for lock: $lock_dir"
			return 1
		fi
	done
	return 0
}

_lock_release() {
	local lock_dir="$1"
	rmdir "$lock_dir" 2>/dev/null || true
	return 0
}

# ---------------------------------------------------------------------------
# cmd_build_source: build tree.json for a single source
# ---------------------------------------------------------------------------

cmd_build_source() {
	local source_id="$1"
	local knowledge_root
	knowledge_root=$(_resolve_root "${2:-}")
	local sources_dir
	sources_dir=$(_sources_dir "$knowledge_root")
	local source_dir="${sources_dir}/${source_id}"
	local text_file="${source_dir}/text.txt"
	local tree_file="${source_dir}/tree.json"
	local meta_file="${source_dir}/meta.json"
	local index_dir
	index_dir=$(_index_dir "$knowledge_root")

	if [[ -z "$source_id" ]]; then
		print_error "build-source: source_id is required"
		return 1
	fi

	if [[ ! -f "$text_file" ]]; then
		print_warning "build-source: text.txt not found for source '${source_id}' — skipping"
		return 0
	fi

	_require_python3 || return 1
	mkdir -p "$index_dir"

	local sensitivity
	sensitivity=$(_read_source_sensitivity "$meta_file")
	local tier
	tier=$(_map_sensitivity_to_tier "$sensitivity")
	local use_ollama
	use_ollama=$(_decide_llm_flags "$tier")

	print_info "build-source: ${source_id} (tier=${tier}, use_ollama=${use_ollama})"
	_write_llm_audit "$index_dir" "$source_id" "$tier" "$use_ollama"

	local ollama_model="llama3.2:1b"
	python3 "$_PAGEINDEX_GEN" "$text_file" "$tree_file" "$use_ollama" "$ollama_model"
	print_success "build-source: wrote ${tree_file}"
	return 0
}

# ---------------------------------------------------------------------------
# Internal: build changed sources and aggregate corpus
# ---------------------------------------------------------------------------

_build_changed_sources() {
	# Build tree.json for each source that has text.txt but stale/missing tree.json
	local sources_dir="$1"
	local knowledge_root="$2"
	local built=0
	local src_id

	for src_id in $(ls "$sources_dir" 2>/dev/null | sort); do
		local src_dir="${sources_dir}/${src_id}"
		[[ -d "$src_dir" ]] || continue
		local text_file="${src_dir}/text.txt"
		local tree_file="${src_dir}/tree.json"
		[[ -f "$text_file" ]] || continue
		# Rebuild if tree.json is missing OR text.txt is newer
		if [[ ! -f "$tree_file" ]] || [[ "$text_file" -nt "$tree_file" ]]; then
			cmd_build_source "$src_id" "$knowledge_root" || true
			built=$((built + 1))
		fi
	done

	echo "$built"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_build: incremental corpus-wide build
# ---------------------------------------------------------------------------

cmd_build() {
	local knowledge_root
	knowledge_root=$(_resolve_root "${1:-}")
	local sources_dir
	sources_dir=$(_sources_dir "$knowledge_root")
	local index_dir
	index_dir=$(_index_dir "$knowledge_root")
	local corpus_tree="${index_dir}/tree.json"
	local lock_dir="${index_dir}/.build-lock"

	_require_python3 || return 1
	mkdir -p "$index_dir"

	# Acquire lock (idempotent under concurrent invocation)
	_lock_acquire "$lock_dir" || return 1
	# shellcheck disable=SC2064
	trap "_lock_release '${lock_dir}'" EXIT

	if ! _should_rebuild "$sources_dir" "$index_dir"; then
		print_info "build: corpus hash unchanged — skipping rebuild"
		_lock_release "$lock_dir"
		trap - EXIT
		return 0
	fi

	print_info "build: corpus changed — rebuilding index"

	local built=0
	if [[ -d "$sources_dir" ]]; then
		built=$(_build_changed_sources "$sources_dir" "$knowledge_root")
	fi

	# Aggregate source trees into corpus meta-tree
	python3 "$_QUERY_HELPER" aggregate "$sources_dir" "$corpus_tree"
	_update_corpus_hash "$sources_dir" "$index_dir"

	_lock_release "$lock_dir"
	trap - EXIT
	print_success "build: corpus tree written (${built} source(s) rebuilt) → ${corpus_tree}"
	return 0
}

# ---------------------------------------------------------------------------
# Case-scope helpers (t2857 — case-draft integration)
# ---------------------------------------------------------------------------

# _case_find_dir <repo-path> <case-id> — find a case directory by ID or slug
_case_find_dir() {
	local repo_path="$1" query="$2"
	local cases_dir="${repo_path}/${_CASES_DIR_NAME}"

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
	local case_dir
	case_dir="$(_case_find_dir "$repo_path" "$case_id")" || {
		print_error "Case not found for scope filter: ${case_id}"
		return 1
	}
	local sources_file="${case_dir}/${_CASE_SOURCES_FILE}"
	if [[ -f "$sources_file" ]] && command -v jq >/dev/null 2>&1; then
		jq -r '.[].id' "$sources_file" 2>/dev/null || true
	fi
	return 0
}

# ---------------------------------------------------------------------------
# cmd_query: walk corpus tree and return ranked matches
# ---------------------------------------------------------------------------

cmd_query() {
	# Supports two calling conventions:
	#   1. Positional: cmd_query "intent string" [knowledge-root]
	#   2. Flagged:    cmd_query --intent "..." [--scope case=<id>] [--repo <path>]
	local intent="" knowledge_root_arg="" scope="" repo_path=""

	# Detect flag-based invocation vs positional
	if [[ "${1:-}" == --* ]]; then
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--intent) intent="$2"; shift 2 ;;
			--scope) scope="$2"; shift 2 ;;
			--repo) repo_path="$2"; shift 2 ;;
			--limit | --max-chars | --json) shift 2 ;; # accepted but ignored by tree-walk
			*) shift ;;
			esac
		done
	else
		intent="${1:-}"
		knowledge_root_arg="${2:-}"
	fi

	[[ -z "$repo_path" ]] && repo_path="$(pwd)"
	local knowledge_root
	knowledge_root=$(_resolve_root "${knowledge_root_arg:-}")
	local index_dir
	index_dir=$(_index_dir "$knowledge_root")
	local corpus_tree="${index_dir}/tree.json"

	if [[ -z "$intent" ]]; then
		print_error "query: intent string is required"
		return 1
	fi

	# Case-scope filter: if --scope case=<id>, restrict to that case's sources
	if [[ "$scope" == case=* ]]; then
		local scope_case_id="${scope#case=}"
		local allowed_ids
		allowed_ids="$(_get_case_source_ids "$repo_path" "$scope_case_id")" || return 1

		if [[ -z "$allowed_ids" ]]; then
			echo "No sources attached to case: ${scope_case_id}"
			return 0
		fi

		# If corpus tree exists, filter query through it
		if [[ -f "$corpus_tree" ]]; then
			_require_python3 || return 1
			# Pass allowed IDs as env var for the Python helper to filter
			KNOWLEDGE_SCOPE_IDS="$allowed_ids" python3 "$_QUERY_HELPER" query "$corpus_tree" "$intent"
			return 0
		fi

		# Fallback: direct source reading when no tree exists
		local sources_dir
		sources_dir="$(_sources_dir "$knowledge_root")"
		local sid
		while IFS= read -r sid; do
			[[ -z "$sid" ]] && continue
			local src_dir="${sources_dir}/${sid}"
			[[ ! -d "$src_dir" ]] && continue
			local content_file=""
			local f
			for f in "${src_dir}"/content.txt "${src_dir}"/text.txt "${src_dir}"/*.txt "${src_dir}"/*.md; do
				if [[ -f "$f" ]]; then
					content_file="$f"
					break
				fi
			done
			if [[ -n "$content_file" ]]; then
				printf '[%s]: "%s"\n\n' "$sid" "$(head -c 2000 "$content_file" 2>/dev/null)"
			fi
		done <<<"$allowed_ids"
		return 0
	fi

	# Standard (non-scoped) query
	if [[ ! -f "$corpus_tree" ]]; then
		print_warning "query: corpus tree not found at ${corpus_tree} — run 'build' first"
		return 1
	fi

	_require_python3 || return 1
	python3 "$_QUERY_HELPER" query "$corpus_tree" "$intent"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_status: show current index state
# ---------------------------------------------------------------------------

cmd_status() {
	local knowledge_root
	knowledge_root=$(_resolve_root "${1:-}")
	local sources_dir
	sources_dir=$(_sources_dir "$knowledge_root")
	local index_dir
	index_dir=$(_index_dir "$knowledge_root")
	local corpus_tree="${index_dir}/tree.json"
	local hash_file="${index_dir}/.tree-hash"

	echo ""
	echo "Knowledge index status for: ${knowledge_root}"

	# Count sources with tree.json
	local total_sources=0
	local indexed_sources=0
	if [[ -d "$sources_dir" ]]; then
		local src_id
		for src_id in $(ls "$sources_dir" 2>/dev/null | sort); do
			[[ -d "${sources_dir}/${src_id}" ]] || continue
			total_sources=$((total_sources + 1))
			[[ -f "${sources_dir}/${src_id}/tree.json" ]] && \
				indexed_sources=$((indexed_sources + 1))
		done
	fi

	printf '  Sources with text.txt: %d\n' "$total_sources"
	printf '  Sources indexed:       %d\n' "$indexed_sources"

	if [[ -f "$corpus_tree" ]]; then
		printf '  Corpus tree:           %s\n' "$corpus_tree"
	else
		printf '  Corpus tree:           not built (run: knowledge-index-helper.sh build)\n'
	fi

	if [[ -f "$hash_file" ]]; then
		local cached_hash
		cached_hash=$(cat "$hash_file" 2>/dev/null || echo "?")
		printf '  Tree hash:             %s\n' "${cached_hash:0:16}..."
	fi
	echo ""
	return 0
}

# ---------------------------------------------------------------------------
# cmd_help
# ---------------------------------------------------------------------------

cmd_help() {
	sed -n '4,14p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local subcommand="${1:-help}"
	shift || true
	case "$subcommand" in
	build-source) cmd_build_source "$@" ;;
	build) cmd_build "$@" ;;
	query) cmd_query "$@" ;;
	status) cmd_status "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown subcommand: $subcommand"
		cmd_help
		exit 1
		;;
	esac
	return 0
}

main "$@"
