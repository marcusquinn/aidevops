#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# knowledge-helper.sh — Knowledge plane provisioning for aidevops-managed repos
#
# Manages the _knowledge/ directory contract: creates directory trees, writes
# .gitignore rules, and maintains _config/knowledge.json defaults. Reads the
# knowledge mode from ~/.config/aidevops/repos.json (field: "knowledge").
#
# Usage:
#   knowledge-helper.sh provision [repo-path]           Provision/repair directory tree
#   knowledge-helper.sh init [off|repo|personal] [path] Set mode and provision
#   knowledge-helper.sh status [repo-path]              Show provisioning state
#   knowledge-helper.sh help                            Show this help
#
# Modes (stored in repos.json "knowledge" field):
#   off       No knowledge plane (default, backwards-compatible)
#   repo      _knowledge/ tree inside the repo
#   personal  Tree at ~/.aidevops/.agent-workspace/knowledge/
#
# Directory contract:
#   _knowledge/inbox/       Raw drops — gitignored, pre-review
#   _knowledge/staging/     Curated before commit — gitignored
#   _knowledge/sources/     Versioned originals (<=30MB)
#   _knowledge/index/       Generated search index — gitignored
#   _knowledge/collections/ Named curated subsets — versioned
#   _knowledge/_config/     knowledge.json defaults — versioned
#
# Blob threshold: files >=30MB go to ~/.aidevops/.agent-workspace/knowledge-blobs/
# with a hash pointer in meta.json instead of being stored in-repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# Guard color fallbacks when shared-constants.sh is absent
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# Prefer print_* from shared-constants; define fallbacks only when absent.
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

REPOS_FILE="${REPOS_FILE:-${HOME}/.config/aidevops/repos.json}"
PERSONAL_PLANE_BASE="${PERSONAL_PLANE_BASE:-${HOME}/.aidevops/.agent-workspace/knowledge}"
KNOWLEDGE_ROOT="_knowledge"
KNOWLEDGE_CONFIG_SUBDIR="_config"
KNOWLEDGE_CONFIG_FILE="knowledge.json"
KNOWLEDGE_DIRS=(inbox staging sources index collections)

SCRIPT_TEMPLATES_DIR="${SCRIPT_DIR%/scripts}/templates"
GITIGNORE_TEMPLATE="${SCRIPT_TEMPLATES_DIR}/knowledge-gitignore.txt"
CONFIG_TEMPLATE="${SCRIPT_TEMPLATES_DIR}/knowledge-config.json"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_require_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		print_error "jq is required but not installed"
		return 1
	fi
	return 0
}

_get_knowledge_mode() {
	local repo_path="$1"
	_require_jq || return 1
	[[ ! -f "$REPOS_FILE" ]] && echo "off" && return 0
	local mode
	mode=$(jq -r --arg path "$repo_path" \
		'.initialized_repos[] | select(.path == $path) | .knowledge // "off"' \
		"$REPOS_FILE" 2>/dev/null | head -1)
	echo "${mode:-off}"
	return 0
}

_set_knowledge_mode() {
	local repo_path="$1"
	local mode="$2"
	_require_jq || return 1
	[[ ! -f "$REPOS_FILE" ]] && print_error "repos.json not found at $REPOS_FILE" && return 1
	case "$mode" in
	off | repo | personal) ;;
	*) print_error "Invalid mode: $mode (must be off|repo|personal)" && return 1 ;;
	esac
	local tmp_file
	tmp_file=$(mktemp)
	jq --arg path "$repo_path" --arg mode "$mode" \
		'(.initialized_repos[] | select(.path == $path)) |= . + {"knowledge": $mode}' \
		"$REPOS_FILE" >"$tmp_file"
	if ! jq . "$tmp_file" >/dev/null 2>&1; then
		print_error "JSON validation failed — repos.json not modified"
		rm -f "$tmp_file"
		return 1
	fi
	mv "$tmp_file" "$REPOS_FILE"
	print_success "Set knowledge=$mode for $repo_path in repos.json"
	return 0
}

_create_knowledge_tree() {
	local base_dir="$1"
	local knowledge_root="${base_dir}/${KNOWLEDGE_ROOT}"
	local config_dir="${knowledge_root}/${KNOWLEDGE_CONFIG_SUBDIR}"
	local dir
	for dir in "${KNOWLEDGE_DIRS[@]}"; do
		mkdir -p "${knowledge_root}/${dir}"
	done
	mkdir -p "$config_dir"
	return 0
}

_write_gitignore() {
	local knowledge_root="$1"
	local gitignore_path="${knowledge_root}/.gitignore"
	if [[ -f "$GITIGNORE_TEMPLATE" ]]; then
		cp "$GITIGNORE_TEMPLATE" "$gitignore_path"
	else
		cat >"$gitignore_path" <<'GITIGNORE'
# Knowledge plane — gitignore rules
# Generated by knowledge-helper.sh
#
# inbox/ and staging/ are pre-review zones — never version raw drops.
# sources/ is intentionally NOT ignored: versioned originals belong in git
# (for files <=30MB; larger originals use blob_path in meta.json).
# index/ contains generated artifacts — ignored by default.
# collections/ is versioned — remove from this file to ignore it too.

inbox/
staging/
index/
GITIGNORE
	fi
	return 0
}

_write_config() {
	local knowledge_root="$1"
	local config_path="${knowledge_root}/${KNOWLEDGE_CONFIG_SUBDIR}/${KNOWLEDGE_CONFIG_FILE}"
	if [[ -f "$CONFIG_TEMPLATE" ]]; then
		cp "$CONFIG_TEMPLATE" "$config_path"
	else
		cat >"$config_path" <<'CONFIG'
{
  "version": 1,
  "sensitivity_default": "internal",
  "trust_default": "unverified",
  "blob_threshold_bytes": 31457280,
  "trust_ladder": ["unverified", "reviewed", "trusted", "authoritative"],
  "sensitivity_levels": ["public", "internal", "confidential", "restricted"],
  "ingest_policy": {
    "auto_sha256": true,
    "require_meta": true
  }
}
CONFIG
	fi
	return 0
}

_patch_repo_gitignore() {
	local repo_path="$1"
	local repo_gitignore="${repo_path}/.gitignore"
	local marker="# knowledge-plane-rules"
	if [[ -f "$repo_gitignore" ]] && grep -q "$marker" "$repo_gitignore" 2>/dev/null; then
		return 0
	fi
	{
		echo ""
		echo "${marker}"
		echo "_knowledge/inbox/"
		echo "_knowledge/staging/"
		echo "_knowledge/index/"
	} >>"$repo_gitignore"
	return 0
}

_is_provisioned() {
	local base_dir="$1"
	local knowledge_root="${base_dir}/${KNOWLEDGE_ROOT}"
	local dir
	[[ -d "$knowledge_root" ]] || return 1
	for dir in "${KNOWLEDGE_DIRS[@]}"; do
		[[ -d "${knowledge_root}/${dir}" ]] || return 1
	done
	[[ -f "${knowledge_root}/${KNOWLEDGE_CONFIG_SUBDIR}/${KNOWLEDGE_CONFIG_FILE}" ]] || return 1
	return 0
}

# ---------------------------------------------------------------------------
# Provision helpers (split to keep cmd_provision under 100 lines)
# ---------------------------------------------------------------------------

_provision_repo_plane() {
	local base_dir="$1"
	local repo_path="$2"
	if _is_provisioned "$base_dir"; then
		print_info "Knowledge plane already provisioned at ${base_dir}/${KNOWLEDGE_ROOT}"
	else
		print_info "Provisioning repo knowledge plane at ${base_dir}/${KNOWLEDGE_ROOT}..."
		_create_knowledge_tree "$base_dir"
		_write_gitignore "${base_dir}/${KNOWLEDGE_ROOT}"
		_write_config "${base_dir}/${KNOWLEDGE_ROOT}"
		_patch_repo_gitignore "$repo_path"
		print_success "Provisioned: ${base_dir}/${KNOWLEDGE_ROOT}"
	fi
	return 0
}

_provision_personal_plane() {
	local base_dir="$PERSONAL_PLANE_BASE"
	if _is_provisioned "$base_dir"; then
		print_info "Personal knowledge plane already provisioned at $base_dir"
	else
		print_info "Provisioning personal knowledge plane at $base_dir..."
		_create_knowledge_tree "$base_dir"
		_write_gitignore "${base_dir}/${KNOWLEDGE_ROOT}"
		_write_config "${base_dir}/${KNOWLEDGE_ROOT}"
		print_success "Provisioned: ${base_dir}/${KNOWLEDGE_ROOT}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_provision() {
	local repo_path="${1:-$(pwd)}"
	local mode
	repo_path="$(cd "$repo_path" && pwd)"
	mode=$(_get_knowledge_mode "$repo_path")
	case "$mode" in
	off)
		print_info "Knowledge mode is 'off' for $repo_path — skipping provision."
		;;
	repo)
		_provision_repo_plane "$repo_path" "$repo_path"
		;;
	personal)
		_provision_personal_plane
		;;
	*)
		print_error "Unknown knowledge mode '$mode' for $repo_path"
		return 1
		;;
	esac
	return 0
}

_prompt_knowledge_mode() {
	echo ""
	echo "Choose mode:"
	echo "  1) repo     — _knowledge/ lives inside this repo"
	echo "  2) personal — knowledge lives at ~/.aidevops/.agent-workspace/knowledge/"
	echo "  3) off      — disable knowledge plane"
	echo ""
	local choice
	read -r -p "Mode [1/2/3]: " choice
	case "$choice" in
	1) echo "repo" ;;
	2) echo "personal" ;;
	3) echo "off" ;;
	*) echo "" ;;
	esac
	return 0
}

cmd_init() {
	local mode="${1:-}"
	local repo_path="${2:-$(pwd)}"
	repo_path="$(cd "$repo_path" && pwd)"
	if [[ -z "$mode" ]]; then
		echo ""
		echo "Knowledge plane init for: $repo_path"
		mode=$(_prompt_knowledge_mode)
		if [[ -z "$mode" ]]; then
			print_error "Invalid choice"
			return 1
		fi
	fi
	case "$mode" in
	off | repo | personal) ;;
	*) print_error "Invalid mode: $mode (must be off|repo|personal)" && return 1 ;;
	esac
	_set_knowledge_mode "$repo_path" "$mode" || return 1
	if [[ "$mode" != "off" ]]; then
		cmd_provision "$repo_path"
	fi
	return 0
}

_print_status_dirs() {
	local base_dir="$1"
	local dir count full
	for dir in "${KNOWLEDGE_DIRS[@]}"; do
		full="${base_dir}/${KNOWLEDGE_ROOT}/${dir}"
		count=0
		if [[ -d "$full" ]]; then
			count=$(find "$full" -maxdepth 1 -not -name '.' | wc -l | tr -d ' ')
		fi
		printf "    %-12s %s items\n" "${dir}/" "$count"
	done
	return 0
}

cmd_status() {
	local repo_path="${1:-$(pwd)}"
	repo_path="$(cd "$repo_path" && pwd)"
	local mode
	mode=$(_get_knowledge_mode "$repo_path")
	echo ""
	echo "Knowledge plane status for: $repo_path"
	echo "  Mode: $mode"
	case "$mode" in
	off)
		echo "  State: disabled"
		;;
	repo)
		if _is_provisioned "$repo_path"; then
			echo "  State: provisioned (${repo_path}/${KNOWLEDGE_ROOT})"
			_print_status_dirs "$repo_path"
		else
			echo "  State: not provisioned (run: aidevops knowledge init repo)"
		fi
		;;
	personal)
		if _is_provisioned "$PERSONAL_PLANE_BASE"; then
			echo "  State: provisioned (${PERSONAL_PLANE_BASE}/${KNOWLEDGE_ROOT})"
		else
			echo "  State: not provisioned (run: aidevops knowledge init personal)"
		fi
		;;
	esac
	echo ""
	return 0
}

cmd_help() {
	sed -n '4,28p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# ---------------------------------------------------------------------------
# search: keyword search across knowledge sources
# Routes to knowledge-index-helper.sh query when corpus tree exists;
# falls back to grep over text.txt files otherwise.
# ---------------------------------------------------------------------------

cmd_search() {
	local query="${1:-}"
	local repo_path="${2:-$(pwd)}"
	repo_path="$(cd "$repo_path" && pwd)"
	local mode
	mode=$(_get_knowledge_mode "$repo_path")

	if [[ -z "$query" ]]; then
		print_error "search: query string is required"
		return 1
	fi

	local knowledge_root=""
	case "$mode" in
	repo) knowledge_root="${repo_path}/${KNOWLEDGE_ROOT}" ;;
	personal) knowledge_root="${PERSONAL_PLANE_BASE}/${KNOWLEDGE_ROOT}" ;;
	off)
		print_warning "search: knowledge plane is disabled for $repo_path"
		return 0
		;;
	esac

	local corpus_tree="${knowledge_root}/index/tree.json"
	local index_helper
	index_helper="$(dirname "${BASH_SOURCE[0]}")/knowledge-index-helper.sh"

	if [[ -f "$corpus_tree" && -f "$index_helper" ]]; then
		# Route to tree-walk when corpus index exists
		print_info "search: routing to knowledge-index-helper query (corpus tree found)"
		KNOWLEDGE_ROOT="$knowledge_root" \
			bash "$index_helper" query "$query"
	else
		# Fallback: grep text.txt files in sources/
		local sources_dir="${knowledge_root}/sources"
		if [[ ! -d "$sources_dir" ]]; then
			print_warning "search: no sources directory found at $sources_dir"
			return 0
		fi
		print_info "search: no corpus tree — falling back to grep in sources/"
		local found=0
		local src_id
		for src_id in $(ls "$sources_dir" 2>/dev/null | sort); do
			local txt="${sources_dir}/${src_id}/text.txt"
			[[ -f "$txt" ]] || continue
			if grep -qi "$query" "$txt" 2>/dev/null; then
				local excerpt
				excerpt=$(grep -i "$query" "$txt" 2>/dev/null | head -1 || true)
				printf '{"source_id":"%s","excerpt":"%s"}\n' \
					"$src_id" "${excerpt:0:200}"
				found=$((found + 1))
			fi
		done
		[[ "$found" -eq 0 ]] && print_info "search: no matches for '${query}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local subcommand="${1:-help}"
	shift || true
	case "$subcommand" in
	provision) cmd_provision "$@" ;;
	init) cmd_init "$@" ;;
	status) cmd_status "$@" ;;
	search) cmd_search "$@" ;;
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
