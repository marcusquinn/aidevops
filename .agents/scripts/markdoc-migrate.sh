#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# markdoc-migrate.sh — Migrate knowledge sources from text.txt+meta.json to source.md (t2971)
#
# Converts the P0a layout (text.txt + full meta.json) to the Markdoc-tagged layout
# (source.md with inline sensitivity/provenance tags + slim meta.json).  A backwards-
# compat reader in knowledge-helper.sh falls back to text.txt so migrated and
# unmigrated sources coexist during incremental migration.
#
# Usage:
#   markdoc-migrate.sh migrate <source-dir> [--dry-run]
#                                    Migrate one source directory
#   markdoc-migrate.sh batch <sources-dir> [--dry-run]
#                                    Migrate all source directories under sources-dir
#   markdoc-migrate.sh help          Show this help
#
# Source layout (before):
#   <source-dir>/text.txt      — plain text content
#   <source-dir>/meta.json     — full metadata (including sensitivity, provenance fields)
#
# Target layout (after):
#   <source-dir>/source.md     — original text with Markdoc sensitivity/provenance tags
#   <source-dir>/meta.json     — slimmed (sensitivity removed; source_md marker added)
#   <source-dir>/text.txt      — preserved (backwards compat; not deleted)
#
# ShellCheck: SC2034 (unused vars) suppressed where colour vars are indirect-used only.
# shellcheck disable=SC2034

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# Guard colour fallbacks when shared-constants.sh is absent
[[ -z "${GREEN+x}" ]]  && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${RED+x}" ]]    && RED='\033[0;31m'
[[ -z "${BLUE+x}" ]]   && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]]     && NC='\033[0m'

if ! declare -f print_info    >/dev/null 2>&1; then print_info()    { local _m="$1"; printf "${BLUE}[INFO]${NC} %s\n"    "$_m"; }; fi
if ! declare -f print_success >/dev/null 2>&1; then print_success() { local _m="$1"; printf "${GREEN}[OK]${NC} %s\n"     "$_m"; }; fi
if ! declare -f print_warning >/dev/null 2>&1; then print_warning() { local _m="$1"; printf "${YELLOW}[WARN]${NC} %s\n"  "$_m"; }; fi
if ! declare -f print_error   >/dev/null 2>&1; then print_error()   { local _m="$1"; printf "${RED}[ERROR]${NC} %s\n"   "$_m"; }; fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

MIGRATE_DEFAULT_SENSITIVITY="internal"

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

# _validate_source_dir <source-dir>
# Returns 0 if text.txt and meta.json exist; 1 otherwise.
_validate_source_dir() {
	local source_dir="$1"
	if [[ ! -d "$source_dir" ]]; then
		print_error "source directory not found: $source_dir"
		return 1
	fi
	if [[ ! -f "${source_dir}/text.txt" ]]; then
		print_error "text.txt not found in: $source_dir"
		return 1
	fi
	if [[ ! -f "${source_dir}/meta.json" ]]; then
		print_error "meta.json not found in: $source_dir"
		return 1
	fi
	return 0
}

# _read_meta_field <meta-path> <field> <default>
# Prints the value of field from meta.json, or the default if absent/null.
_read_meta_field() {
	local meta_path="$1"
	local field="$2"
	local default="$3"
	local val
	val=$(jq -r --arg d "$default" --arg f "$field" '.[$f] // $d' "$meta_path" 2>/dev/null || echo "$default")
	printf '%s\n' "${val:-$default}"
	return 0
}

# _extract_date_part <iso-datetime>
# Prints just the YYYY-MM-DD portion from an ISO 8601 datetime string.
_extract_date_part() {
	local ts="$1"
	# Handle "2026-04-27T12:34:56Z" → "2026-04-27"
	printf '%s\n' "${ts%%T*}"
	return 0
}

# _build_source_md <source-dir> <meta-path>
# Prints the full content of source.md to stdout.
# Wraps the original text.txt content in Markdoc sensitivity and provenance tags.
_build_source_md() {
	local source_dir="$1"
	local meta_path="$2"

	_require_jq || return 1

	local source_id sensitivity ingested_at source_uri draft_status
	source_id=$(  _read_meta_field "$meta_path" "id"          "unknown")
	sensitivity=$(  _read_meta_field "$meta_path" "sensitivity" "$MIGRATE_DEFAULT_SENSITIVITY")
	ingested_at=$(  _read_meta_field "$meta_path" "ingested_at" "")
	source_uri=$(   _read_meta_field "$meta_path" "source_uri"  "")
	draft_status=$( _read_meta_field "$meta_path" "draft_status" "")

	local extracted_at
	extracted_at=$(_extract_date_part "$ingested_at")
	[[ -z "$extracted_at" ]] && extracted_at="$(date -u +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)"

	# Build provenance attrs string
	local prov_attrs="source-id=\"${source_id}\" extracted-at=\"${extracted_at}\""

	# Emit source.md content
	printf '<!-- source.md — migrated from text.txt by markdoc-migrate.sh (t2971) -->\n'
	if [[ -n "$draft_status" && "$draft_status" != "null" ]]; then
		printf '{%% draft-status status="%s" %%}\n' "$draft_status"
	fi
	printf '{%% provenance %s %%}\n' "$prov_attrs"
	printf '{%% sensitivity tier="%s" scope="file" %%}\n' "$sensitivity"
	printf '\n'
	# Emit original text content verbatim
	cat "${source_dir}/text.txt"
	printf '\n'
	printf '{%% /sensitivity %%}\n'
	printf '{%% /provenance %%}\n'
	if [[ -n "$draft_status" && "$draft_status" != "null" ]]; then
		printf '{%% /draft-status %%}\n'
	fi
	return 0
}

# _slim_meta_json <meta-path> <output-path>
# Writes a slimmed meta.json to output-path (removes sensitivity; adds source_md marker).
_slim_meta_json() {
	local meta_path="$1"
	local output_path="$2"
	_require_jq || return 1
	jq 'del(.sensitivity) | . + {"source_md": true}' "$meta_path" >"$output_path"
	if ! jq . "$output_path" >/dev/null 2>&1; then
		print_error "JSON validation failed on slimmed meta.json"
		rm -f "$output_path"
		return 1
	fi
	return 0
}

# _show_diff_preview <source-dir>
# Prints a summary of what would change for dry-run mode.
_show_diff_preview() {
	local source_dir="$1"
	local meta_path="${source_dir}/meta.json"
	local source_md_path="${source_dir}/source.md"
	printf '\n[DRY-RUN] Would create: %s\n' "$source_md_path"
	printf '[DRY-RUN] Would slim:   %s  (removes: sensitivity; adds: source_md=true)\n' "$meta_path"
	local sensitivity
	sensitivity=$(jq -r --arg d "$MIGRATE_DEFAULT_SENSITIVITY" '.sensitivity // $d' "$meta_path" 2>/dev/null || echo "$MIGRATE_DEFAULT_SENSITIVITY")
	local source_id
	source_id=$(jq -r '.id // "unknown"' "$meta_path" 2>/dev/null || echo "unknown")
	printf '[DRY-RUN] source.md tags: sensitivity tier="%s", provenance source-id="%s"\n' \
		"$sensitivity" "$source_id"
	return 0
}

# ---------------------------------------------------------------------------
# _migrate_one_source: orchestrate migration for a single source directory
# ---------------------------------------------------------------------------

# _migrate_one_source <source-dir> <dry-run-flag:0|1>
# Returns 0 on success (or skip), 1 on error.
_migrate_one_source() {
	local source_dir="$1"
	local dry_run="$2"
	local meta_path="${source_dir}/meta.json"
	local source_md_path="${source_dir}/source.md"

	# Validate pre-conditions
	_validate_source_dir "$source_dir" || return 1
	_require_jq || return 1

	# Skip if already migrated (source.md exists)
	if [[ -f "$source_md_path" ]]; then
		print_info "Already migrated (source.md exists): $source_dir"
		return 0
	fi

	# Dry-run: show what would happen and exit early
	if [[ "$dry_run" -eq 1 ]]; then
		_show_diff_preview "$source_dir"
		return 0
	fi

	# Build and write source.md
	local tmp_source_md
	tmp_source_md=$(mktemp)
	if ! _build_source_md "$source_dir" "$meta_path" >"$tmp_source_md" 2>&1; then
		print_error "Failed to build source.md for: $source_dir"
		rm -f "$tmp_source_md"
		return 1
	fi
	mv "$tmp_source_md" "$source_md_path"

	# Slim meta.json (in-place via temp file)
	local tmp_meta
	tmp_meta=$(mktemp)
	if ! _slim_meta_json "$meta_path" "$tmp_meta"; then
		print_error "Failed to slim meta.json for: $source_dir"
		rm -f "$tmp_meta"
		# Roll back source.md
		rm -f "$source_md_path"
		return 1
	fi
	mv "$tmp_meta" "$meta_path"

	print_success "Migrated: $source_dir"
	return 0
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_migrate() {
	local source_dir=""
	local dry_run=0

	while [[ $# -gt 0 ]]; do
		local _key="$1"
		shift
		case "$_key" in
		--dry-run) dry_run=1 ;;
		-*)
			print_error "Unknown option: $_key"
			return 1
			;;
		*)
			[[ -z "$source_dir" ]] && source_dir="$_key"
			;;
		esac
	done

	if [[ -z "$source_dir" ]]; then
		print_error "migrate requires <source-dir>"
		return 1
	fi

	_migrate_one_source "$source_dir" "$dry_run"
	return $?
}

cmd_batch() {
	local sources_dir=""
	local dry_run=0
	local ok_count=0
	local fail_count=0

	while [[ $# -gt 0 ]]; do
		local _key="$1"
		shift
		case "$_key" in
		--dry-run) dry_run=1 ;;
		-*)
			print_error "Unknown option: $_key"
			return 1
			;;
		*)
			[[ -z "$sources_dir" ]] && sources_dir="$_key"
			;;
		esac
	done

	if [[ -z "$sources_dir" ]]; then
		print_error "batch requires <sources-dir>"
		return 1
	fi

	if [[ ! -d "$sources_dir" ]]; then
		print_error "sources directory not found: $sources_dir"
		return 1
	fi

	local src_id
	while IFS= read -r -d '' src_id; do
		local source_dir
		source_dir="$(dirname "$src_id")"
		# Only descend one level — each subdir is one source
		if _migrate_one_source "$source_dir" "$dry_run"; then
			ok_count=$(( ok_count + 1 ))
		else
			fail_count=$(( fail_count + 1 ))
		fi
	done < <(find "$sources_dir" -maxdepth 2 -mindepth 2 -name "text.txt" -print0 2>/dev/null)

	printf '\nBatch complete: %d migrated, %d failed\n' "$ok_count" "$fail_count"
	[[ "$fail_count" -gt 0 ]] && return 1
	return 0
}

cmd_help() {
	sed -n '4,28p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local subcommand="${1:-help}"
	shift || true
	case "$subcommand" in
	migrate)     cmd_migrate "$@" ;;
	batch)       cmd_batch "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown subcommand: $subcommand"
		cmd_help
		exit 1
		;;
	esac
}

main "$@"
