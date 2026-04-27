#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# markdoc-migrate.sh — Migrate P0a text.txt+meta.json layout to source.md + slim meta.json (t2971)
#
# Converts knowledge plane source directories from the P0a contract
# (text.txt + meta.json with all fields) to the Markdoc-tagged layout
# (source.md with inline tags + slim meta.json with non-tag fields only).
#
# A backwards-compat reader in knowledge-helper.sh reads source.md first and
# falls back to text.txt, so migrated and unmigrated sources coexist safely.
#
# Usage:
#   markdoc-migrate.sh migrate <source-dir> [--dry-run]
#   markdoc-migrate.sh batch <sources-root-dir> [--dry-run]
#   markdoc-migrate.sh help
#
# Migration contract:
#   Input:  <source-dir>/text.txt  — raw text content
#           <source-dir>/meta.json — P0a full metadata
#   Output: <source-dir>/source.md — text content with Markdoc tags injected
#           <source-dir>/meta.json — slimmed (tag-lifted fields removed)
#
# Tag-lifted fields (moved to source.md tags, removed from meta.json):
#   sensitivity, trust, ingested_by, source_uri
#
# Non-tag fields (kept in meta.json):
#   version, id, kind, sha256, ingested_at, blob_path, size_bytes
#
# Exit codes:
#   0 — success (or dry-run preview)
#   1 — error (file not found, JSON parse failure, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"

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
# Internal helpers
# ---------------------------------------------------------------------------

_require_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		print_error "jq is required but not installed"
		return 1
	fi
	return 0
}

# _read_meta_field <meta_path> <field> [default]
# Reads a field from meta.json, returns default if absent.
_read_meta_field() {
	local meta_path="$1"
	local field="$2"
	local default="${3:-}"
	local val
	val=$(jq -r --arg d "$default" --arg f "$field" '.[$f] // $d' "$meta_path" 2>/dev/null || echo "$default")
	printf '%s' "$val"
	return 0
}

# _iso_date_from_ts <iso_timestamp>
# Strips time component from ISO 8601 datetime, returns YYYY-MM-DD.
_iso_date_from_ts() {
	local ts="$1"
	# Extract date portion: YYYY-MM-DD
	printf '%s' "${ts%%T*}" | cut -c1-10
	return 0
}

# _build_source_md <text_path> <meta_path>
# Writes source.md content to stdout. Does not write files.
_build_source_md() {
	local text_path="$1"
	local meta_path="$2"

	local sensitivity source_uri ingested_at source_id
	sensitivity=$(_read_meta_field "$meta_path" "sensitivity" "internal")
	source_uri=$(_read_meta_field "$meta_path" "source_uri" "")
	ingested_at=$(_read_meta_field "$meta_path" "ingested_at" "")
	source_id=$(_read_meta_field "$meta_path" "id" "")

	# Use source_uri as provenance source-id; fall back to source id if blank
	local prov_source_id="${source_uri:-$source_id}"
	local prov_date
	prov_date=$(_iso_date_from_ts "${ingested_at:-$(date -u +%Y-%m-%d)}")

	# Build source.md header with Markdoc tags wrapping the content.
	# Use variable for delimiters to avoid SC2183 false positives from {% and %}
	# being misidentified as printf format specifiers.
	local _o='{%'
	local _c='%}'

	printf '%s sensitivity tier="%s" scope="file" %s\n' "$_o" "$sensitivity" "$_c"

	if [[ -n "$prov_source_id" && -n "$prov_date" ]]; then
		printf '%s provenance source-id="%s" extracted-at="%s" %s\n' \
			"$_o" "$prov_source_id" "$prov_date" "$_c"
	fi

	printf '\n'

	# Original text content
	cat "$text_path"

	# Close tags (innermost first)
	printf '\n'
	if [[ -n "$prov_source_id" && -n "$prov_date" ]]; then
		printf '%s /provenance %s\n' "$_o" "$_c"
	fi
	printf '%s /sensitivity %s\n' "$_o" "$_c"

	return 0
}

# _slim_meta_json <meta_path> <out_path>
# Writes slimmed meta.json to out_path, removing tag-lifted fields.
_slim_meta_json() {
	local meta_path="$1"
	local out_path="$2"
	_require_jq || return 1

	# Remove tag-lifted fields: sensitivity, trust, ingested_by, source_uri
	jq 'del(.sensitivity, .trust, .ingested_by, .source_uri)' \
		"$meta_path" >"$out_path" 2>/dev/null
	return 0
}

# ---------------------------------------------------------------------------
# cmd_migrate: migrate one source directory
# ---------------------------------------------------------------------------

cmd_migrate() {
	local source_dir=""
	local dry_run=0

	while [[ $# -gt 0 ]]; do
		local _key="$1"
		shift
		case "$_key" in
		--dry-run)
			dry_run=1
			;;
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
		print_error "migrate: <source-dir> is required"
		return 1
	fi

	# Canonicalize path
	source_dir="$(cd "$source_dir" && pwd)" || {
		print_error "migrate: directory not found: $source_dir"
		return 1
	}

	local text_path="${source_dir}/text.txt"
	local meta_path="${source_dir}/meta.json"
	local source_md_path="${source_dir}/source.md"

	# Validate inputs
	if [[ ! -f "$text_path" ]]; then
		print_error "migrate: text.txt not found in $source_dir"
		return 1
	fi
	if [[ ! -f "$meta_path" ]]; then
		print_error "migrate: meta.json not found in $source_dir"
		return 1
	fi
	_require_jq || return 1

	# Skip already-migrated directories
	if [[ -f "$source_md_path" ]]; then
		print_warning "migrate: source.md already exists in $source_dir — skipping (use --force to override)"
		return 0
	fi

	local source_id
	source_id=$(_read_meta_field "$meta_path" "id" "$(basename "$source_dir")")

	if [[ "$dry_run" -eq 1 ]]; then
		print_info "[dry-run] Would migrate: $source_dir (id=${source_id})"
		print_info "[dry-run] source.md content preview (first 10 lines):"
		_build_source_md "$text_path" "$meta_path" | head -10
		print_info "[dry-run] Slim meta.json would remove: sensitivity, trust, ingested_by, source_uri"
		return 0
	fi

	# Write source.md
	local tmp_source_md
	tmp_source_md=$(mktemp)
	if ! _build_source_md "$text_path" "$meta_path" >"$tmp_source_md"; then
		rm -f "$tmp_source_md"
		print_error "migrate: failed to build source.md for $source_dir"
		return 1
	fi
	mv "$tmp_source_md" "$source_md_path"

	# Write slimmed meta.json (atomic via temp file)
	local tmp_meta
	tmp_meta=$(mktemp)
	if ! _slim_meta_json "$meta_path" "$tmp_meta"; then
		rm -f "$tmp_meta"
		print_error "migrate: failed to slim meta.json for $source_dir"
		return 1
	fi
	# Validate the slimmed JSON before overwriting
	if ! jq . "$tmp_meta" >/dev/null 2>&1; then
		rm -f "$tmp_meta"
		print_error "migrate: slimmed meta.json failed validation for $source_dir"
		return 1
	fi
	mv "$tmp_meta" "$meta_path"

	print_success "Migrated: $source_dir (id=${source_id})"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_batch: migrate all source directories under a root
# ---------------------------------------------------------------------------

cmd_batch() {
	local sources_root=""
	local dry_run=0

	while [[ $# -gt 0 ]]; do
		local _key="$1"
		shift
		case "$_key" in
		--dry-run)
			dry_run=1
			;;
		-*)
			print_error "Unknown option: $_key"
			return 1
			;;
		*)
			[[ -z "$sources_root" ]] && sources_root="$_key"
			;;
		esac
	done

	if [[ -z "$sources_root" ]]; then
		print_error "batch: <sources-root-dir> is required"
		return 1
	fi

	if [[ ! -d "$sources_root" ]]; then
		print_error "batch: directory not found: $sources_root"
		return 1
	fi

	local total=0 migrated=0 skipped=0 failed=0

	while IFS= read -r -d '' src_dir; do
		[[ -f "${src_dir}/text.txt" ]] || continue
		total=$(( total + 1 ))
		local dry_flag=""
		[[ "$dry_run" -eq 1 ]] && dry_flag="--dry-run"
		# shellcheck disable=SC2086
		if cmd_migrate "$src_dir" ${dry_flag}; then
			if [[ -f "${src_dir}/source.md" || "$dry_run" -eq 1 ]]; then
				migrated=$(( migrated + 1 ))
			else
				skipped=$(( skipped + 1 ))
			fi
		else
			failed=$(( failed + 1 ))
			print_warning "batch: failed to migrate $src_dir"
		fi
	done < <(find "$sources_root" -maxdepth 1 -mindepth 1 -type d -print0 | sort -z)

	echo ""
	print_info "Batch complete: total=${total} migrated=${migrated} skipped=${skipped} failed=${failed}"

	[[ "$failed" -gt 0 ]] && return 1
	return 0
}

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------

cmd_help() {
	sed -n '4,31p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local subcommand="${1:-help}"
	shift || true
	case "$subcommand" in
	migrate) cmd_migrate "$@" ;;
	batch)   cmd_batch "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "${SCRIPT_NAME}: unknown subcommand: $subcommand"
		cmd_help >&2
		exit 1
		;;
	esac
	return 0
}

main "$@"
