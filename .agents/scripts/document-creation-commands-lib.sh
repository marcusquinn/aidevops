#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Document Creation Commands Library -- Convert, template, create commands
# =============================================================================
# Argument parsing helpers and command implementations for convert, template,
# and create subcommands of the document creation subsystem.
#
# Usage: source "${SCRIPT_DIR}/document-creation-commands-lib.sh"
#
# Dependencies:
#   - document-creation-core-lib.sh (log_*, die, has_cmd, get_ext, human_filesize,
#     activate_venv, has_python_pkg, select_ocr_provider)
#   - document-creation-convert-lib.sh (_convert_ocr_preprocess, select_tool,
#     _convert_execute_tool)
#   - SCRIPT_NAME, VENV_DIR, TEMPLATE_DIR (set by orchestrator)
#   - Colour variables (BOLD, NC) (set by orchestrator)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_DOCUMENT_CREATION_COMMANDS_LIB_LOADED:-}" ]] && return 0
_DOCUMENT_CREATION_COMMANDS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ============================================================================
# Extracted helpers for complexity reduction (t1044.12)
# ============================================================================

# Helpers for cmd_convert - extract argument parsing
# Bash 3.2 compatible: uses printf -v for scalar writes, ${!var} for reads (no local -n).
_convert_parse_args() {
	local _input_var="$1" _to_ext_var="$2" _output_var="$3" _force_tool_var="$4"
	local _template_var="$5" _extra_args_var="$6" _ocr_provider_var="$7"
	local _run_normalise_var="$8" _dedup_registry_var="$9"
	shift 9

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--to)
			local _to_ext_val
			_to_ext_val="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
			printf -v "$_to_ext_var" '%s' "$_to_ext_val"
			shift 2
			;;
		--output | -o)
			printf -v "$_output_var" '%s' "$2"
			shift 2
			;;
		--tool)
			printf -v "$_force_tool_var" '%s' "$2"
			shift 2
			;;
		--template)
			printf -v "$_template_var" '%s' "$2"
			shift 2
			;;
		--engine)
			printf -v "$_extra_args_var" '%s' "--pdf-engine=$2"
			shift 2
			;;
		--dedup-registry)
			printf -v "$_dedup_registry_var" '%s' "$2"
			shift 2
			;;
		--ocr)
			printf -v "$_ocr_provider_var" '%s' "${2:-auto}"
			shift
			[[ $# -gt 0 && "$1" != --* ]] && {
				printf -v "$_ocr_provider_var" '%s' "$1"
				shift
			}
			;;
		--no-normalise | --no-normalize)
			eval "${_run_normalise_var}=false"
			shift
			;;
		--*)
			local _cur_extra="${!_extra_args_var}"
			printf -v "$_extra_args_var" '%s' "${_cur_extra} $1"
			shift
			;;
		*)
			[[ -z "${!_input_var}" ]] && printf -v "$_input_var" '%s' "$1"
			shift
			;;
		esac
	done
	return 0
}

# Helpers for cmd_create - extract argument parsing
# Bash 3.2 compatible: uses printf -v for scalar writes, ${!var} for reads (no local -n).
_create_parse_args() {
	local _template_var="$1" _data_var="$2" _output_var="$3" _script_var="$4"
	shift 4

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--data)
			printf -v "$_data_var" '%s' "$2"
			shift 2
			;;
		--output | -o)
			printf -v "$_output_var" '%s' "$2"
			shift 2
			;;
		--script)
			printf -v "$_script_var" '%s' "$2"
			shift 2
			;;
		--*) shift ;;
		*)
			[[ -z "${!_template_var}" ]] && printf -v "$_template_var" '%s' "$1"
			shift
			;;
		esac
	done
	return 0
}

# Helpers for cmd_import_emails - extract argument parsing
# Bash 3.2 compatible: uses printf -v for scalar writes, ${!var} for reads (no local -n).
_import_parse_args() {
	local _input_path_var="$1" _output_dir_var="$2" _skip_contacts_var="$3"
	shift 3

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output | -o)
			printf -v "$_output_dir_var" '%s' "$2"
			shift 2
			;;
		--skip-contacts)
			eval "${_skip_contacts_var}=true"
			shift
			;;
		--*)
			log_warn "Unknown option: $1"
			shift
			;;
		*)
			[[ -z "${!_input_path_var}" ]] && printf -v "$_input_path_var" '%s' "$1"
			shift
			;;
		esac
	done
	return 0
}

# Helpers for cmd_template - extract argument parsing
# Bash 3.2 compatible: uses printf -v for scalar writes (no local -n).
_template_parse_args() {
	local _doc_type_var="$1" _format_var="$2" _fields_var="$3"
	local _header_logo_var="$4" _footer_text_var="$5" _output_var="$6"
	shift 6

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--type)
			printf -v "$_doc_type_var" '%s' "$2"
			shift 2
			;;
		--format)
			printf -v "$_format_var" '%s' "$2"
			shift 2
			;;
		--fields)
			printf -v "$_fields_var" '%s' "$2"
			shift 2
			;;
		--header-logo)
			printf -v "$_header_logo_var" '%s' "$2"
			shift 2
			;;
		--footer-text)
			printf -v "$_footer_text_var" '%s' "$2"
			shift 2
			;;
		--output)
			printf -v "$_output_var" '%s' "$2"
			shift 2
			;;
		*) shift ;;
		esac
	done
	return 0
}

# Helpers for cmd_normalise - extract argument parsing
# Bash 3.2 compatible: uses printf -v for scalar writes, ${!var} for reads (no local -n).
_normalise_parse_args() {
	local _input_var="$1" _output_var="$2" _inplace_var="$3"
	local _generate_pageindex_var="$4" _email_mode_var="$5"
	shift 5

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output | -o)
			printf -v "$_output_var" '%s' "$2"
			shift 2
			;;
		--inplace | -i)
			eval "${_inplace_var}=true"
			shift
			;;
		--pageindex)
			eval "${_generate_pageindex_var}=true"
			shift
			;;
		--email | -e)
			eval "${_email_mode_var}=true"
			shift
			;;
		--*) shift ;;
		*)
			[[ -z "${!_input_var}" ]] && printf -v "$_input_var" '%s' "$1"
			shift
			;;
		esac
	done
	return 0
}

# Helpers for cmd_pageindex - extract argument parsing
# Bash 3.2 compatible: uses printf -v for scalar writes, ${!var} for reads (no local -n).
_pageindex_parse_args() {
	local _input_var="$1" _output_var="$2" _source_pdf_var="$3" _ollama_model_var="$4"
	shift 4

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output | -o)
			printf -v "$_output_var" '%s' "$2"
			shift 2
			;;
		--source-pdf)
			printf -v "$_source_pdf_var" '%s' "$2"
			shift 2
			;;
		--ollama-model)
			printf -v "$_ollama_model_var" '%s' "$2"
			shift 2
			;;
		--*) shift ;;
		*)
			[[ -z "${!_input_var}" ]] && printf -v "$_input_var" '%s' "$1"
			shift
			;;
		esac
	done
	return 0
}

# Helpers for cmd_generate_manifest - extract argument parsing
# Bash 3.2 compatible: uses printf -v for scalar writes, ${!var} for reads (no local -n).
_manifest_parse_args() {
	local _output_dir_var="$1"
	shift

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--*)
			log_warn "Unknown option: $1"
			shift
			;;
		*)
			[[ -z "${!_output_dir_var}" ]] && printf -v "$_output_dir_var" '%s' "$1"
			shift
			;;
		esac
	done
	return 0
}

# Validate and resolve paths for cmd_convert.
# Sets output and from_ext; validates input/to_ext.
# Args: input to_ext output_ref from_ext_ref
_convert_validate_paths() {
	local input="$1"
	local to_ext="$2"
	local output_ref="$3"
	local from_ext_ref="$4"

	if [[ -z "${input}" ]]; then
		die "Usage: convert <input-file> --to <format> [--output <file>] [--tool <name>]"
	fi
	if [[ ! -f "${input}" ]]; then
		die "Input file not found: ${input}"
	fi
	if [[ -z "${to_ext}" ]]; then
		die "Target format required. Use --to <format> (e.g., --to pdf, --to odt)"
	fi

	local _output="${!output_ref}"
	if [[ -z "${_output}" ]]; then
		_output="${input%.*}.${to_ext}"
		printf -v "${output_ref}" '%s' "${_output}"
	fi

	local _from_ext
	_from_ext=$(get_ext "$input")
	printf -v "${from_ext_ref}" '%s' "${_from_ext}"

	if [[ "${_from_ext}" == "${to_ext}" ]]; then
		die "Input and output formats are the same: ${_from_ext}"
	fi

	return 0
}

cmd_convert() {
	local input=""
	local to_ext=""
	local output=""
	local force_tool=""
	local template=""
	local extra_args=""
	local ocr_provider=""
	local run_normalise=true
	local dedup_registry=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--to)
			to_ext="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
			shift 2
			;;
		--output | -o)
			output="$2"
			shift 2
			;;
		--tool)
			force_tool="$2"
			shift 2
			;;
		--template)
			template="$2"
			shift 2
			;;
		--engine)
			extra_args="--pdf-engine=$2"
			shift 2
			;;
		--dedup-registry)
			dedup_registry="$2"
			shift 2
			;;
		--ocr)
			ocr_provider="${2:-auto}"
			shift
			if [[ $# -gt 0 && "$1" != --* && "$1" != -* ]]; then
				ocr_provider="$1"
				shift
			fi
			;;
		--no-normalise | --no-normalize)
			run_normalise=false
			shift
			;;
		--*)
			extra_args="${extra_args} $1"
			shift
			;;
		*)
			[[ -z "${input}" ]] && input="$1"
			shift
			;;
		esac
	done

	# Normalise format aliases
	case "${to_ext}" in
	markdown) to_ext="md" ;;
	text) to_ext="txt" ;;
	esac

	# Validate inputs and resolve output/from_ext
	local from_ext=""
	_convert_validate_paths "${input}" "${to_ext}" output from_ext

	# OCR pre-processing: handle scanned PDFs and images (modifies input/from_ext)
	_convert_ocr_preprocess input from_ext ocr_provider

	# Select tool and execute conversion
	local tool
	tool=$(select_tool "${from_ext}" "${to_ext}" "${force_tool}")
	_convert_execute_tool "${tool}" "$input" "$output" "${to_ext}" \
		"${template}" "${extra_args}" "${dedup_registry}"

	# Auto-run normalise after *→md conversions (unless --no-normalise flag is set)
	if [[ "${run_normalise}" == "true" ]] && [[ "${to_ext}" =~ ^(md|markdown)$ ]] && [[ -f "$output" ]]; then
		log_info "Running normalisation on converted markdown..."
		if "${BASH_SOURCE[0]}" normalise "$output"; then
			log_ok "Normalisation complete"
		else
			log_warn "Normalisation failed (non-fatal)"
		fi
	fi

	return 0
}

# ============================================================================
# Template command
# ============================================================================

# Helper: handle 'template draft' subcommand logic
_template_draft_subcommand() {
	local doc_type=""
	local format="odt"
	local fields=""
	local header_logo=""
	local footer_text=""
	local output=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--type)
			doc_type="$2"
			shift 2
			;;
		--format)
			format="$2"
			shift 2
			;;
		--fields)
			fields="$2"
			shift 2
			;;
		--header-logo)
			header_logo="$2"
			shift 2
			;;
		--footer-text)
			footer_text="$2"
			shift 2
			;;
		--output)
			output="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "${doc_type}" ]]; then
		die "Usage: template draft --type <name> [--format odt|docx] [--fields f1,f2,f3]"
	fi

	if [[ -z "${output}" ]]; then
		mkdir -p "${TEMPLATE_DIR}/documents"
		output="${TEMPLATE_DIR}/documents/${doc_type}-template.${format}"
	fi

	log_info "Generating draft template: ${doc_type} (${format})"
	log_info "Fields: ${fields:-auto}"
	log_info "Output: ${output}"

	if [[ "${format}" == "odt" ]]; then
		if ! activate_venv 2>/dev/null || ! has_python_pkg odf 2>/dev/null; then
			die "odfpy required for ODT template generation. Run: install --standard"
		fi
		local script_dir
		script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
		python3 "${script_dir}/template-draft.py" \
			"$output" "$doc_type" "$fields" "$header_logo" "$footer_text"
		log_ok "Draft template created: ${output}"
		log_info "Edit in LibreOffice or your preferred editor to refine layout."
		log_info "Replace {{placeholders}} markers with your design, keeping the field names."
	elif [[ "${format}" == "docx" ]]; then
		if ! activate_venv 2>/dev/null || ! has_python_pkg docx 2>/dev/null; then
			die "python-docx required for DOCX template generation. Run: install --standard"
		fi
		log_warn "DOCX template generation not yet implemented. Use ODT format."
	else
		die "Unsupported template format: ${format}. Use odt or docx."
	fi

	return 0
}

cmd_template() {
	local subcmd="${1:-}"
	shift || true

	case "${subcmd}" in
	list)
		printf '%b\n\n' "${BOLD}Stored Templates${NC}"
		if [[ -d "${TEMPLATE_DIR}" ]]; then
			find "${TEMPLATE_DIR}" -type f | while read -r f; do
				local rel="${f#"${TEMPLATE_DIR}/"}"
				local size
				size=$(human_filesize "$f")
				printf "  %s (%s)\n" "$rel" "$size"
			done
		else
			log_info "No templates stored yet."
			log_info "Directory: ${TEMPLATE_DIR}"
		fi
		;;
	draft)
		_template_draft_subcommand "$@"
		;;
	*)
		printf "Usage: %s template <subcommand>\n\n" "${SCRIPT_NAME}"
		printf "Subcommands:\n"
		printf "  list                          List stored templates\n"
		printf "  draft --type <name> [opts]     Generate a draft template\n"
		printf "\nDraft options:\n"
		printf "  --type <name>         Document type (letter, report, invoice, statement)\n"
		printf "  --format <odt|docx>   Output format (default: odt)\n"
		printf "  --fields <f1,f2,...>   Comma-separated placeholder field names\n"
		printf "  --header-logo <path>  Logo image for header\n"
		printf "  --footer-text <text>  Footer text\n"
		printf "  --output <path>       Output file path\n"
		return 1
		;;
	esac

	return 0
}

# ============================================================================
# Create command (fill template with data)
# ============================================================================

# Script mode: run a Python creation script with optional data/output args.
# Args: script data output
_create_run_script() {
	local script="$1"
	local data="$2"
	local output="$3"

	if [[ ! -f "${script}" ]]; then
		die "Script not found: ${script}"
	fi
	log_info "Running creation script: ${script}"
	activate_venv 2>/dev/null || true
	# shellcheck disable=SC2086
	python3 "${script}" ${data:+--data "$data"} ${output:+--output "$output"}
	return $?
}

# Fill an ODT template with data using Python zipfile manipulation.
# Args: template data output
_create_fill_odt_python() {
	local template="$1"
	local data="$2"
	local output="$3"

	python3 - "$template" "$data" "$output" <<'PYEOF'
import sys
import os
import json
import zipfile
import shutil
import tempfile
import re

template_path = sys.argv[1]
data_arg = sys.argv[2]
output_path = sys.argv[3]

# Load data
if os.path.isfile(data_arg):
    with open(data_arg, 'r') as f:
        data = json.load(f)
else:
    data = json.loads(data_arg)

# ODT is a ZIP file. Extract, replace placeholders in content.xml and styles.xml, repack.
tmp_dir = tempfile.mkdtemp()
try:
    with zipfile.ZipFile(template_path, 'r') as z:
        z.extractall(tmp_dir)

    # Replace in content.xml and styles.xml
    for xml_file in ['content.xml', 'styles.xml']:
        xml_path = os.path.join(tmp_dir, xml_file)
        if os.path.exists(xml_path):
            with open(xml_path, 'r', encoding='utf-8') as f:
                content = f.read()
            for key, value in data.items():
                # Replace {{key}} patterns (may be split across XML tags)
                # First try simple replacement
                content = content.replace('{{' + key + '}}', str(value))
                # Also try URL-encoded variants
                content = content.replace('%7B%7B' + key + '%7D%7D', str(value))
            with open(xml_path, 'w', encoding='utf-8') as f:
                f.write(content)

    # Repack as ZIP (ODT)
    with zipfile.ZipFile(output_path, 'w', zipfile.ZIP_DEFLATED) as z:
        # mimetype must be first and uncompressed
        mimetype_path = os.path.join(tmp_dir, 'mimetype')
        if os.path.exists(mimetype_path):
            z.write(mimetype_path, 'mimetype', compress_type=zipfile.ZIP_STORED)
        for root, dirs, files in os.walk(tmp_dir):
            for file in files:
                if file == 'mimetype':
                    continue
                file_path = os.path.join(root, file)
                arcname = os.path.relpath(file_path, tmp_dir)
                z.write(file_path, arcname)

    print(f"Created: {output_path}")
finally:
    shutil.rmtree(tmp_dir)
PYEOF

	return 0
}

# Parse create command arguments.
# Sets _CREATE_TEMPLATE, _CREATE_DATA, _CREATE_OUTPUT, _CREATE_SCRIPT in caller scope.
_create_cmd_parse_args() {
	_CREATE_TEMPLATE=""
	_CREATE_DATA=""
	_CREATE_OUTPUT=""
	_CREATE_SCRIPT=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--data)
			_CREATE_DATA="$2"
			shift 2
			;;
		--output | -o)
			_CREATE_OUTPUT="$2"
			shift 2
			;;
		--script)
			_CREATE_SCRIPT="$2"
			shift 2
			;;
		--*) shift ;;
		*)
			[[ -z "${_CREATE_TEMPLATE}" ]] && _CREATE_TEMPLATE="$1"
			shift
			;;
		esac
	done
	return 0
}

# Validate template inputs and resolve output path.
# Returns 1 on validation failure.
_create_validate_template() {
	local template="$1"
	local data="$2"
	local output_ref="$3"

	if [[ -z "${template}" ]]; then
		die "Usage: create <template-file> --data <json|file> --output <file>"
	fi
	if [[ ! -f "${template}" ]]; then
		die "Template not found: ${template}"
	fi
	if [[ -z "${data}" ]]; then
		die "Data required. Use --data '{\"field\": \"value\"}' or --data fields.json"
	fi

	local _output="${!output_ref}"
	if [[ -z "${_output}" ]]; then
		local ext
		ext=$(get_ext "$template")
		_output="${template%.*}-filled.${ext}"
		printf -v "${output_ref}" '%s' "${_output}"
	fi

	return 0
}

# Fill a template file with data, dispatching by extension.
_create_fill_template() {
	local template="$1"
	local data="$2"
	local output="$3"

	local ext
	ext=$(get_ext "$template")

	log_info "Creating document from template: $(basename "$template")"

	case "${ext}" in
	odt)
		if ! activate_venv 2>/dev/null || ! has_python_pkg odf 2>/dev/null; then
			die "odfpy required. Run: install --standard"
		fi
		_create_fill_odt_python "$template" "$data" "$output"
		if [[ -f "$output" ]]; then
			local size
			size=$(human_filesize "$output")
			log_ok "Created: ${output} (${size})"
		fi
		;;
	docx)
		if ! activate_venv 2>/dev/null || ! has_python_pkg docx 2>/dev/null; then
			die "python-docx required. Run: install --standard"
		fi
		log_warn "DOCX template filling not yet implemented. Use ODT format."
		;;
	*)
		die "Unsupported template format: ${ext}. Use odt or docx."
		;;
	esac

	return 0
}

cmd_create() {
	_create_cmd_parse_args "$@"

	local template="${_CREATE_TEMPLATE}"
	local data="${_CREATE_DATA}"
	local output="${_CREATE_OUTPUT}"
	local script="${_CREATE_SCRIPT}"

	if [[ -n "${script}" ]]; then
		_create_run_script "${script}" "${data}" "${output}"
		return $?
	fi

	_create_validate_template "${template}" "${data}" output || return 1
	_create_fill_template "${template}" "${data}" "${output}"

	return 0
}
