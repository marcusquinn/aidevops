#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Document Creation Operations Library -- Higher-level document operations
# =============================================================================
# Command implementations for entity extraction, manifest generation,
# markdown normalisation, page indexing, related docs, and cross-document linking.
#
# Usage: source "${SCRIPT_DIR}/document-creation-ops-lib.sh"
#
# Dependencies:
#   - document-creation-core-lib.sh (log_*, die, has_cmd, get_ext, human_filesize,
#     activate_venv, has_python_pkg)
#   - SCRIPT_NAME, VENV_DIR (set by orchestrator)
#   - Colour variables (BOLD, NC) (set by orchestrator)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_DOCUMENT_CREATION_OPS_LIB_LOADED:-}" ]] && return 0
_DOCUMENT_CREATION_OPS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ============================================================================
# Entity extraction (t1044.6)
# ============================================================================

cmd_extract_entities() {
	local input=""
	local method="auto"
	local update_frontmatter=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--method)
			method="${2:-auto}"
			shift 2
			;;
		--update-frontmatter)
			update_frontmatter=true
			shift
			;;
		-*)
			die "Unknown option: $1"
			;;
		*)
			input="$1"
			shift
			;;
		esac
	done

	if [[ -z "$input" ]]; then
		die "Usage: ${SCRIPT_NAME} extract-entities <markdown-file> [--method auto|spacy|ollama|regex] [--update-frontmatter]"
	fi

	if [[ ! -f "$input" ]]; then
		die "File not found: ${input}"
	fi

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local extractor="${script_dir}/entity-extraction.py"

	if [[ ! -f "$extractor" ]]; then
		die "Entity extraction script not found: ${extractor}"
	fi

	# Determine Python interpreter (prefer venv)
	local python_cmd="python3"
	if activate_venv 2>/dev/null; then
		python_cmd="python3"
	fi

	local args=("$input" "--method" "$method")
	if [[ "$update_frontmatter" == true ]]; then
		args+=("--update-frontmatter")
	else
		args+=("--json")
	fi

	log_info "Extracting entities from: ${input} (method: ${method})"
	"$python_cmd" "$extractor" "${args[@]}"

	return $?
}

# ============================================================================
# Collection manifest (_index.toon) generation
# ============================================================================

# Generate _index.toon collection manifest for an email import output directory.
# Scans .md files for YAML frontmatter, .toon contact files, and builds three
# TOON indexes: documents, threads, contacts.
cmd_generate_manifest() {
	local output_dir=""

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--*)
			log_warn "Unknown option: $1"
			shift
			;;
		*)
			if [[ -z "${output_dir}" ]]; then
				output_dir="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "${output_dir}" ]]; then
		die "Usage: generate-manifest <output-dir>"
	fi

	if [[ ! -d "${output_dir}" ]]; then
		die "Directory not found: ${output_dir}"
	fi

	local index_file="${output_dir}/_index.toon"

	log_info "Generating collection manifest: ${index_file}"

	# Use the extracted generate-manifest.py script for TOON generation
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	python3 "${script_dir}/generate-manifest.py" "${output_dir}" "${index_file}"

	local manifest_result=$?
	if [[ "${manifest_result}" -ne 0 ]]; then
		log_error "Failed to generate collection manifest"
		return 1
	fi

	log_ok "Collection manifest generated: ${index_file}"
	return 0
}

# ============================================================================
# Normalise command - Fix markdown heading hierarchy and structure
# ============================================================================

cmd_normalise() {
	local input=""
	local output=""
	local inplace=false
	local generate_pageindex=false
	local email_mode=false

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output | -o)
			output="$2"
			shift 2
			;;
		--inplace | -i)
			inplace=true
			shift
			;;
		--pageindex)
			generate_pageindex=true
			shift
			;;
		--email | -e)
			email_mode=true
			shift
			;;
		--*)
			shift
			;;
		*)
			if [[ -z "${input}" ]]; then
				input="$1"
			fi
			shift
			;;
		esac
	done

	# Validate
	if [[ -z "${input}" ]]; then
		die "Usage: normalise <input.md> [--output <file>] [--inplace] [--pageindex] [--email]"
	fi

	if [[ ! -f "${input}" ]]; then
		die "Input file not found: ${input}"
	fi

	# Determine output path
	if [[ "${inplace}" == true ]]; then
		output="${input}"
	elif [[ -z "${output}" ]]; then
		local basename_noext="${input%.*}"
		output="${basename_noext}-normalised.md"
	fi

	if [[ "${email_mode}" == true ]]; then
		log_info "Normalising email markdown: $(basename "$input")"
	else
		log_info "Normalising markdown: $(basename "$input")"
	fi

	# Create temp file for processing
	local tmp_file
	tmp_file=$(mktemp)

	# Process the markdown file with the extracted normalise-markdown.py script
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	python3 "${script_dir}/normalise-markdown.py" "$input" "$tmp_file" "${email_mode}"

	# Check if processing succeeded
	if [[ ! -f "${tmp_file}" ]]; then
		die "Normalisation failed: temp file not created"
	fi

	# Move temp file to output
	mv "${tmp_file}" "${output}"

	if [[ -f "${output}" ]]; then
		local size
		size=$(human_filesize "${output}")
		log_ok "Normalised: ${output} (${size})"

		if [[ "${inplace}" == true ]]; then
			log_info "File updated in place"
		fi
	else
		die "Normalisation failed: output file not created"
	fi

	# Generate PageIndex tree if requested
	if [[ "${generate_pageindex}" == true ]]; then
		log_info "Generating PageIndex tree..."
		cmd_pageindex "${output}"
	fi

	return 0
}

# ============================================================================
# PageIndex command - Generate .pageindex.json from markdown heading hierarchy
# ============================================================================

cmd_pageindex() {
	local input=""
	local output=""
	local source_pdf=""
	local ollama_model="llama3.2:1b"

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output | -o)
			output="$2"
			shift 2
			;;
		--source-pdf)
			source_pdf="$2"
			shift 2
			;;
		--ollama-model)
			ollama_model="$2"
			shift 2
			;;
		--*)
			shift
			;;
		*)
			if [[ -z "${input}" ]]; then
				input="$1"
			fi
			shift
			;;
		esac
	done

	# Validate
	if [[ -z "${input}" ]]; then
		die "Usage: pageindex <input.md> [--output <file>] [--source-pdf <file>] [--ollama-model <model>]"
	fi

	if [[ ! -f "${input}" ]]; then
		die "Input file not found: ${input}"
	fi

	# Determine output path
	if [[ -z "${output}" ]]; then
		local basename_noext="${input%.*}"
		output="${basename_noext}.pageindex.json"
	fi

	# Detect Ollama availability for LLM summaries
	local use_ollama=false
	if has_cmd ollama; then
		if ollama list 2>/dev/null | grep -q "${ollama_model%%:*}"; then
			use_ollama=true
			log_info "Ollama available — using ${ollama_model} for section summaries"
		else
			log_info "Ollama model ${ollama_model} not found — using first-sentence fallback"
		fi
	else
		log_info "Ollama not available — using first-sentence fallback for summaries"
	fi

	# Extract page count from source PDF if available
	local page_count="0"
	if [[ -n "${source_pdf}" ]] && [[ -f "${source_pdf}" ]]; then
		if has_cmd pdfinfo; then
			page_count=$(pdfinfo "${source_pdf}" 2>/dev/null | grep "Pages:" | awk '{print $2}' || echo "0")
			log_info "Source PDF: ${source_pdf} (${page_count} pages)"
		fi
	fi

	log_info "Generating PageIndex: $(basename "$input") -> $(basename "$output")"

	# Generate the PageIndex JSON with the extracted pageindex-generator.py script
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	python3 "${script_dir}/pageindex-generator.py" \
		"$input" "$output" "${use_ollama}" "${ollama_model}" "${source_pdf}" "${page_count}"

	if [[ -f "${output}" ]]; then
		local size
		size=$(human_filesize "${output}")
		local node_count
		node_count=$(python3 -c "
import json, sys
def count_nodes(node):
    c = 1
    for child in node.get('children', []):
        c += count_nodes(child)
    return c
with open(sys.argv[1]) as f:
    data = json.load(f)
print(count_nodes(data.get('tree', {})))
" "${output}" 2>/dev/null || echo "?")
		log_ok "PageIndex created: ${output} (${size}, ${node_count} nodes)"
	else
		die "PageIndex generation failed: output file not created"
	fi

	return 0
}

# ============================================================================
# Add related docs (t1044.11)
# ============================================================================

cmd_add_related_docs() {
	local input="${1:-}"
	local directory=""
	local update_all=false
	local dry_run=false

	# Parse arguments
	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--directory | -d)
			directory="$2"
			shift 2
			;;
		--update-all)
			update_all=true
			shift
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			die "Usage: ${SCRIPT_NAME} add-related-docs <file|directory> [--directory <dir>] [--update-all] [--dry-run]"
			;;
		esac
	done

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local linker="${script_dir}/add-related-docs.py"

	if [[ ! -f "$linker" ]]; then
		die "Related docs script not found: ${linker}"
	fi

	# Determine Python interpreter (prefer venv)
	local python_cmd="python3"
	if activate_venv 2>/dev/null; then
		python_cmd="python3"
	fi

	# Check for PyYAML
	if ! "$python_cmd" -c "import yaml" 2>/dev/null; then
		log_warn "PyYAML not installed. Installing..."
		if [[ ! -d "${VENV_DIR}" ]]; then
			mkdir -p "$(dirname "${VENV_DIR}")"
			python3 -m venv "${VENV_DIR}"
		fi
		activate_venv
		pip install --quiet PyYAML
	fi

	local args=()
	if [[ -n "$input" ]]; then
		args+=("$input")
	fi
	if [[ -n "$directory" ]]; then
		args+=("--directory" "$directory")
	fi
	if [[ "$update_all" == true ]]; then
		args+=("--update-all")
	fi
	if [[ "$dry_run" == true ]]; then
		args+=("--dry-run")
	fi

	log_info "Adding related_docs to markdown files..."
	"$python_cmd" "$linker" "${args[@]}"

	return 0
}

# ============================================================================
# Cross-document linking (t1049.11)
# ============================================================================

cmd_link_documents() {
	local directory=""
	local dry_run=false
	local min_shared=2

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		--min-shared-entities)
			min_shared="${2:-2}"
			shift 2
			;;
		-*)
			die "Unknown option: $1"
			;;
		*)
			directory="$1"
			shift
			;;
		esac
	done

	if [[ -z "$directory" ]]; then
		die "Usage: ${SCRIPT_NAME} link-documents <directory> [--dry-run] [--min-shared-entities N]"
	fi

	if [[ ! -d "$directory" ]]; then
		die "Directory not found: ${directory}"
	fi

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local linker="${script_dir}/cross-document-linking.py"

	if [[ ! -f "$linker" ]]; then
		die "Cross-document linking script not found: ${linker}"
	fi

	# Determine Python interpreter (prefer venv)
	local python_cmd="python3"
	if activate_venv 2>/dev/null; then
		python_cmd="python3"
	fi

	local args=("$directory" "--min-shared-entities" "$min_shared")
	if [[ "$dry_run" == true ]]; then
		args+=("--dry-run")
	fi

	log_info "Building cross-document links in: ${directory}"
	"$python_cmd" "$linker" "${args[@]}"

	return $?
}
