#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# email-ingest-helper.sh — Ingest .eml files into the knowledge plane
#
# Parses an .eml (or .emlx) file via email_parse.py, creates a parent source
# with kind=email and email-specific meta fields, sanitises the body (strips
# tracking pixels and remote images), and splits attachments into child sources
# linked via parent_source.
#
# Usage:
#   email-ingest-helper.sh ingest <eml-path> [--id <id>] [--sensitivity <tier>] [--repo-path <path>]
#   email-ingest-helper.sh help
#
# Dependencies:
#   - python3 (with stdlib email module)
#   - jq
#   - knowledge-helper.sh (for knowledge root resolution)
#   - sensitivity-detector-helper.sh (optional, for auto-classification)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# Guard color fallbacks
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

EMAIL_PARSER="${SCRIPT_DIR}/email_parse.py"
KNOWLEDGE_HELPER="${SCRIPT_DIR}/knowledge-helper.sh"
SENSITIVITY_DETECTOR="${SCRIPT_DIR}/sensitivity-detector-helper.sh"
KNOWLEDGE_ROOT="_knowledge"
_ISO_FMT="%Y-%m-%dT%H:%M:%SZ"
_DEFAULT_SENSITIVITY="internal"

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

_require_python3() {
	if ! command -v python3 >/dev/null 2>&1; then
		print_error "python3 is required but not installed"
		return 1
	fi
	return 0
}

_slugify() {
	local input="$1"
	echo "$input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//; s/-$//'
	return 0
}

_sha256sum_file() {
	local file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file" | awk '{print $1}'
	else
		print_error "sha256sum/shasum not found"
		return 1
	fi
	return 0
}

_get_knowledge_root() {
	local repo_path="$1"
	# Delegate to knowledge-helper.sh's internal resolution if possible;
	# fall back to simple repo-mode path.
	if [[ -d "${repo_path}/${KNOWLEDGE_ROOT}/sources" ]]; then
		echo "${repo_path}/${KNOWLEDGE_ROOT}"
		return 0
	fi
	local personal_base="${HOME}/.aidevops/.agent-workspace/knowledge"
	if [[ -d "${personal_base}/${KNOWLEDGE_ROOT}/sources" ]]; then
		echo "${personal_base}/${KNOWLEDGE_ROOT}"
		return 0
	fi
	print_error "Knowledge plane not provisioned. Run: knowledge-helper.sh provision"
	return 1
}

_sanitise_html() {
	local html_path="$1"
	if [[ ! -f "$html_path" ]]; then
		return 0
	fi
	# Use Python for regex sanitisation — BSD sed lacks case-insensitive flag
	python3 -c "
import re, sys
with open(sys.argv[1], 'r', encoding='utf-8', errors='replace') as f:
    html = f.read()
# Strip 1x1 tracking pixels
html = re.sub(
    r'<img[^>]*src=\"(https?://[^\"]*?)\"[^>]*(?:width=\"1\"[^>]*height=\"1\"|height=\"1\"[^>]*width=\"1\")[^>]*/?>',
    r'<!-- tracker stripped: \1 -->', html, flags=re.IGNORECASE)
# Strip known tracker URL patterns
html = re.sub(
    r'<img[^>]*src=\"(https?://[^\"]*?/(?:pixel|beacon|track|open|img\.gif|spacer)[^\"]*)\"[^>]*/?>',
    r'<!-- tracker stripped: \1 -->', html, flags=re.IGNORECASE)
# Strip UTM tracking parameters from links
html = re.sub(r'(https?://[^\"]*?)\?utm_[^\"]*\"', r'\1\"', html)
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    f.write(html)
" "$html_path"
	return 0
}

_write_email_meta() {
	local meta_path="$1"
	local source_id="$2"
	local source_uri="$3"
	local sha256="$4"
	local size_bytes="$5"
	local sensitivity="$6"
	local parse_json="$7"

	local ts actor
	ts=$(date -u +"$_ISO_FMT" 2>/dev/null || date +"$_ISO_FMT")
	actor="${USER:-unknown}"

	local body_text_sha="" body_html_sha=""
	local body_text_path body_html_path
	body_text_path=$(echo "$parse_json" | jq -r '.body_text_path // empty')
	body_html_path=$(echo "$parse_json" | jq -r '.body_html_path // empty')

	if [[ -n "$body_text_path" && -f "$body_text_path" ]]; then
		body_text_sha=$(_sha256sum_file "$body_text_path") || body_text_sha=""
	fi
	if [[ -n "$body_html_path" && -f "$body_html_path" ]]; then
		body_html_sha=$(_sha256sum_file "$body_html_path") || body_html_sha=""
	fi

	# Build the meta.json with email-specific fields
	jq -n \
		--arg id "$source_id" \
		--arg uri "$source_uri" \
		--arg sha "$sha256" \
		--arg ts "$ts" \
		--arg by "$actor" \
		--arg sens "$sensitivity" \
		--argjson sz "$size_bytes" \
		--arg from "$(echo "$parse_json" | jq -r '.from // ""')" \
		--arg to "$(echo "$parse_json" | jq -r '.to // ""')" \
		--arg cc "$(echo "$parse_json" | jq -r '.cc // ""')" \
		--arg bcc "$(echo "$parse_json" | jq -r '.bcc // ""')" \
		--arg subj "$(echo "$parse_json" | jq -r '.subject // ""')" \
		--arg date "$(echo "$parse_json" | jq -r '.date // ""')" \
		--arg mid "$(echo "$parse_json" | jq -r '.message_id // ""')" \
		--arg irt "$(echo "$parse_json" | jq -r '.in_reply_to // ""')" \
		--arg refs "$(echo "$parse_json" | jq -r '.references // ""')" \
		--arg btsha "$body_text_sha" \
		--arg bhsha "$body_html_sha" \
		'{
			version: 1,
			id: $id,
			kind: "email",
			source_uri: $uri,
			sha256: $sha,
			ingested_at: $ts,
			ingested_by: $by,
			sensitivity: $sens,
			trust: "unverified",
			blob_path: null,
			size_bytes: $sz,
			from: $from,
			to: $to,
			cc: $cc,
			bcc: $bcc,
			subject: $subj,
			date: $date,
			message_id: $mid,
			in_reply_to: $irt,
			references: $refs,
			body_text_sha: $btsha,
			body_html_sha: $bhsha,
			attachments: []
		}' > "$meta_path"
	return 0
}

_apply_sensitivity() {
	local source_id="$1"
	local knowledge_root="$2"
	local meta_path="$3"
	local sensitivity_override="$4"

	if [[ -x "$SENSITIVITY_DETECTOR" ]]; then
		local detected_tier
		detected_tier=$(bash "$SENSITIVITY_DETECTOR" classify "$source_id" \
			--knowledge-root "$knowledge_root" 2>/dev/null | tail -1 || echo "$_DEFAULT_SENSITIVITY")
		print_info "[$source_id] auto-detected sensitivity: $detected_tier"
		if [[ -n "$detected_tier" && "$detected_tier" != "$_DEFAULT_SENSITIVITY" ]]; then
			local tmp
			tmp=$(mktemp)
			if jq --arg t "$detected_tier" '.sensitivity = $t' "$meta_path" >"$tmp" 2>/dev/null; then
				mv "$tmp" "$meta_path"
			else
				rm -f "$tmp"
			fi
		fi
	fi

	if [[ -n "$sensitivity_override" ]]; then
		if [[ -x "$SENSITIVITY_DETECTOR" ]]; then
			bash "$SENSITIVITY_DETECTOR" override "$source_id" "$sensitivity_override" \
				--reason "user-provided via --sensitivity flag" \
				--knowledge-root "$knowledge_root" >/dev/null 2>&1 || true
		else
			local tmp
			tmp=$(mktemp)
			if jq --arg t "$sensitivity_override" '.sensitivity = $t' "$meta_path" >"$tmp" 2>/dev/null; then
				mv "$tmp" "$meta_path"
			else
				rm -f "$tmp"
			fi
		fi
		print_info "[$source_id] sensitivity overridden to: $sensitivity_override"
	fi

	jq -r --arg def "$_DEFAULT_SENSITIVITY" '.sensitivity // $def' "$meta_path" 2>/dev/null || echo "$_DEFAULT_SENSITIVITY"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_ingest: main ingestion logic
# ---------------------------------------------------------------------------

cmd_ingest() {
	local eml_path=""
	local source_id=""
	local sensitivity_override=""
	local repo_path
	repo_path="$(pwd)"

	while [[ $# -gt 0 ]]; do
		local _key="$1"
		shift
		case "$_key" in
		--id)
			local _val="$1"
			source_id="$_val"
			shift
			;;
		--sensitivity)
			local _val="$1"
			sensitivity_override="$_val"
			shift
			;;
		--repo-path)
			local _val="$1"
			repo_path="$_val"
			shift
			;;
		-*)
			print_error "Unknown option: $_key"
			return 1
			;;
		*)
			[[ -z "$eml_path" ]] && eml_path="$_key"
			;;
		esac
	done

	if [[ -z "$eml_path" ]]; then
		print_error "ingest requires <eml-path>"
		return 1
	fi
	if [[ ! -f "$eml_path" ]]; then
		print_error "File not found: $eml_path"
		return 1
	fi

	_require_jq || return 1
	_require_python3 || return 1

	if [[ ! -f "$EMAIL_PARSER" ]]; then
		print_error "email_parse.py not found at $EMAIL_PARSER"
		return 1
	fi

	repo_path="$(cd "$repo_path" && pwd)"
	local knowledge_root
	knowledge_root=$(_get_knowledge_root "$repo_path") || return 1

	# Generate source ID from filename if not provided
	if [[ -z "$source_id" ]]; then
		local basename_no_ext
		basename_no_ext="$(basename "$eml_path")"
		basename_no_ext="${basename_no_ext%.*}"
		source_id=$(_slugify "$basename_no_ext")
		[[ -z "$source_id" ]] && source_id="email-$(date +%s)"
	fi

	local source_dir="${knowledge_root}/sources/${source_id}"
	if [[ -d "$source_dir" ]]; then
		source_id="${source_id}-$(date +%s)"
		source_dir="${knowledge_root}/sources/${source_id}"
	fi
	mkdir -p "$source_dir"

	# Create temp dir for parser output
	local tmp_dir
	tmp_dir=$(mktemp -d -t "email-ingest-XXXXXX")

	# Parse the .eml file
	print_info "Parsing email: $eml_path"
	local parse_json
	parse_json=$(python3 "$EMAIL_PARSER" "$eml_path" --output-dir "$tmp_dir") || {
		print_error "Failed to parse email: $eml_path"
		rm -rf "$tmp_dir"
		return 1
	}

	# Compute SHA256 of original .eml
	local sha256 size_bytes abs_eml_path
	sha256=$(_sha256sum_file "$eml_path") || return 1
	size_bytes=$(wc -c <"$eml_path" | tr -d ' ')
	abs_eml_path="$(cd "$(dirname "$eml_path")" && pwd)/$(basename "$eml_path")"
	local source_uri="file://${abs_eml_path}"

	# Copy body files to source dir
	local body_text_path body_html_path
	body_text_path=$(echo "$parse_json" | jq -r '.body_text_path // empty')
	body_html_path=$(echo "$parse_json" | jq -r '.body_html_path // empty')

	if [[ -n "$body_text_path" && -f "$body_text_path" ]]; then
		cp "$body_text_path" "${source_dir}/text.txt"
	fi
	if [[ -n "$body_html_path" && -f "$body_html_path" ]]; then
		cp "$body_html_path" "${source_dir}/body.html"
		# Sanitise HTML body — strip tracking pixels
		_sanitise_html "${source_dir}/body.html"
	fi

	# Write parent meta.json
	local meta_path="${source_dir}/meta.json"
	_write_email_meta "$meta_path" "$source_id" "$source_uri" "$sha256" "$size_bytes" "$_DEFAULT_SENSITIVITY" "$parse_json" || return 1

	# Process attachments as child sources
	local att_count
	att_count=$(echo "$parse_json" | jq '.attachments | length')
	local child_refs="[]"

	if [[ "$att_count" -gt 0 ]]; then
		local i=0
		while [[ "$i" -lt "$att_count" ]]; do
			local att_filename att_content_path att_content_type att_size
			att_filename=$(echo "$parse_json" | jq -r ".attachments[$i].filename")
			att_content_path=$(echo "$parse_json" | jq -r ".attachments[$i].content_path")
			att_content_type=$(echo "$parse_json" | jq -r ".attachments[$i].content_type")
			att_size=$(echo "$parse_json" | jq -r ".attachments[$i].size")

			# Generate child source ID
			local child_slug
			child_slug=$(_slugify "${att_filename%.*}")
			[[ -z "$child_slug" ]] && child_slug="attachment-${i}"
			local child_id="${source_id}-att-${child_slug}"
			local child_dir="${knowledge_root}/sources/${child_id}"
			if [[ -d "$child_dir" ]]; then
				child_id="${child_id}-$(date +%s)"
				child_dir="${knowledge_root}/sources/${child_id}"
			fi
			mkdir -p "$child_dir"

			# Copy attachment file
			if [[ -f "$att_content_path" ]]; then
				cp "$att_content_path" "${child_dir}/${att_filename}"
			fi

			# Compute child SHA256
			local child_sha256=""
			if [[ -f "${child_dir}/${att_filename}" ]]; then
				child_sha256=$(_sha256sum_file "${child_dir}/${att_filename}") || child_sha256=""
			fi

			# Write child meta.json
			local child_ts
			child_ts=$(date -u +"$_ISO_FMT" 2>/dev/null || date +"$_ISO_FMT")
			jq -n \
				--arg id "$child_id" \
				--arg uri "$source_uri" \
				--arg sha "$child_sha256" \
				--arg ts "$child_ts" \
				--arg by "${USER:-unknown}" \
				--arg ct "$att_content_type" \
				--arg fn "$att_filename" \
				--arg parent "$source_id" \
				--arg sens "$_DEFAULT_SENSITIVITY" \
				--argjson sz "$att_size" \
				'{
					version: 1,
					id: $id,
					kind: "attachment",
					source_uri: $uri,
					sha256: $sha,
					ingested_at: $ts,
					ingested_by: $by,
					sensitivity: $sens,
					trust: "unverified",
					blob_path: null,
					size_bytes: $sz,
					parent_source: $parent,
					attachment_filename: $fn,
					content_type: $ct
				}' > "${child_dir}/meta.json"

			# Run sensitivity detector on child independently
			_apply_sensitivity "$child_id" "$knowledge_root" "${child_dir}/meta.json" "$sensitivity_override" >/dev/null 2>&1 || true

			# Try document extraction for PDFs
			local doc_extractor="${SCRIPT_DIR}/document-extraction-helper.sh"
			if [[ -x "$doc_extractor" && "$att_content_type" == "application/pdf" ]]; then
				print_info "[$child_id] Running document extraction on PDF attachment"
				bash "$doc_extractor" extract "${child_dir}/${att_filename}" \
					--output "${child_dir}/text.txt" 2>/dev/null || true
			fi

			# Accumulate child reference for parent meta
			child_refs=$(echo "$child_refs" | jq --arg sid "$child_id" --arg fn "$att_filename" \
				'. + [{"source_id": $sid, "filename": $fn}]')

			print_info "[$source_id] Attachment child: $child_id ($att_filename)"
			i=$((i + 1))
		done
	fi

	# Update parent meta with attachment references
	if [[ "$att_count" -gt 0 ]]; then
		local tmp
		tmp=$(mktemp)
		if jq --argjson atts "$child_refs" '.attachments = $atts' "$meta_path" >"$tmp" 2>/dev/null; then
			mv "$tmp" "$meta_path"
		else
			rm -f "$tmp"
		fi
	fi

	# Run sensitivity detector on parent
	local final_tier
	final_tier=$(_apply_sensitivity "$source_id" "$knowledge_root" "$meta_path" "$sensitivity_override") || true

	# Clean up temp dir
	rm -rf "$tmp_dir"

	print_success "Ingested email: $source_id (sensitivity=${final_tier:-internal}, attachments=${att_count})"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_help
# ---------------------------------------------------------------------------

cmd_help() {
	sed -n '4,18p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local subcommand="${1:-help}"
	shift || true
	case "$subcommand" in
	ingest) cmd_ingest "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown subcommand: $subcommand"
		cmd_help
		return 1
		;;
	esac
	return 0
}

main "$@"
