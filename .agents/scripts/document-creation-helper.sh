#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# document-creation-helper.sh - Unified document format conversion and creation
# Part of aidevops framework: https://aidevops.sh
#
# Usage: document-creation-helper.sh <command> [options]
# Commands: convert, create, template, normalise, pageindex, install, formats, status, help
#
# This is the thin orchestrator. Function implementations live in sub-libraries:
#   - document-creation-core-lib.sh      (utilities, env, OCR, status, install, formats)
#   - document-creation-convert-lib.sh   (conversion engine, tool selection, backends)
#   - document-creation-email-lib.sh     (email import pipeline)
#   - document-creation-commands-lib.sh  (arg parsing, convert/template/create commands)
#   - document-creation-ops-lib.sh       (extract, manifest, normalise, pageindex, related, link)

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_NAME="document-creation-helper"
VENV_DIR="${HOME}/.aidevops/.agent-workspace/python-env/document-creation"
TEMPLATE_DIR="${HOME}/.aidevops/.agent-workspace/templates"
# LOG_DIR used by future logging features
LOG_DIR="${HOME}/.aidevops/logs"
export LOG_DIR

# Colour output (disable if not a terminal)
if [[ -t 1 ]]; then
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	YELLOW='\033[1;33m'
	BLUE='\033[0;34m'
	BOLD='\033[1m'
	NC='\033[0m'
else
	RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# ============================================================================
# Sub-library sourcing
# ============================================================================

# Defensive SCRIPT_DIR fallback for sub-library resolution
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Core utilities, environment detection, OCR, status, install, formats
# shellcheck source=./document-creation-core-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/document-creation-core-lib.sh"

# Conversion engine (tool selection, conversion backends)
# shellcheck source=./document-creation-convert-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/document-creation-convert-lib.sh"

# Email import pipeline (mbox splitting, contact extraction, batch import)
# shellcheck source=./document-creation-email-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/document-creation-email-lib.sh"

# Argument parsing, convert/template/create command implementations
# shellcheck source=./document-creation-commands-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/document-creation-commands-lib.sh"

# Higher-level operations: extract, manifest, normalise, pageindex, related, link
# shellcheck source=./document-creation-ops-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/document-creation-ops-lib.sh"

# ============================================================================
# Help
# ============================================================================

cmd_help() {
	printf '%b%s%b - Document format conversion and creation\n\n' "${BOLD}" "${SCRIPT_NAME}" "${NC}"
	printf "Usage: %s <command> [options]\n\n" "${SCRIPT_NAME}"
	printf '%b\n' "${BOLD}Commands:${NC}"
	printf "  convert           Convert between document formats\n"
	printf "  import-emails     Batch import .eml directory or mbox file to markdown\n"
	printf "  create            Create a document from a template + data\n"
	printf "  template          Manage document templates (list, draft)\n"
	printf "  normalise         Fix markdown heading hierarchy and structure\n"
	printf "  pageindex         Generate .pageindex.json tree from markdown headings\n"
	printf "  extract-entities  Extract named entities from markdown (t1044.6)\n"
	printf "  generate-manifest Generate collection manifest (_index.toon) (t1044.9)\n"
	printf "  add-related-docs  Add related_docs frontmatter and navigation links (t1044.11)\n"
	printf "  enforce-frontmatter Enforce YAML frontmatter on markdown files\n"
	printf "  link-documents    Add cross-document links to email collection (t1049.11)\n"
	printf "  install           Install conversion tools (--minimal, --standard, --full, --ocr)\n"
	printf "  formats           Show supported format conversions\n"
	printf "  status            Show installed tools and availability\n"
	printf "  help              Show this help\n"
	printf '\n%b\n' "${BOLD}Examples:${NC}"
	printf "  %s convert report.pdf --to odt\n" "${SCRIPT_NAME}"
	printf "  %s convert letter.odt --to pdf\n" "${SCRIPT_NAME}"
	printf "  %s convert notes.md --to docx\n" "${SCRIPT_NAME}"
	printf "  %s convert email.eml --to md\n" "${SCRIPT_NAME}"
	printf "  %s convert message.msg --to md\n" "${SCRIPT_NAME}"
	printf "  %s import-emails ~/Mail/inbox/ --output ./imported\n" "${SCRIPT_NAME}"
	printf "  %s import-emails archive.mbox --output ./imported\n" "${SCRIPT_NAME}"
	printf "  %s generate-manifest ./imported\n" "${SCRIPT_NAME}"
	printf "  %s convert scanned.pdf --to odt --ocr tesseract\n" "${SCRIPT_NAME}"
	printf "  %s convert screenshot.png --to md --ocr auto\n" "${SCRIPT_NAME}"
	printf "  %s convert report.pdf --to md --no-normalise\n" "${SCRIPT_NAME}"
	printf "  %s normalise document.md --output clean.md\n" "${SCRIPT_NAME}"
	printf "  %s normalise document.md --inplace --pageindex\n" "${SCRIPT_NAME}"
	printf "  %s normalise email.md --inplace --email\n" "${SCRIPT_NAME}"
	printf "  %s pageindex document.md --source-pdf original.pdf\n" "${SCRIPT_NAME}"
	printf "  %s create template.odt --data fields.json -o letter.odt\n" "${SCRIPT_NAME}"
	printf "  %s template draft --type letter --format odt\n" "${SCRIPT_NAME}"
	printf "  %s extract-entities email.md --update-frontmatter\n" "${SCRIPT_NAME}"
	printf "  %s extract-entities email.md --method spacy --json\n" "${SCRIPT_NAME}"
	printf "  %s generate-manifest ./imported-emails\n" "${SCRIPT_NAME}"
	printf "  %s generate-manifest ./emails -o manifest.toon\n" "${SCRIPT_NAME}"
	printf "  %s add-related-docs email.md\n" "${SCRIPT_NAME}"
	printf "  %s add-related-docs --directory ./emails --update-all\n" "${SCRIPT_NAME}"
	printf "  %s link-documents ./emails --min-shared-entities 3\n" "${SCRIPT_NAME}"
	printf "  %s link-documents ./emails --dry-run\n" "${SCRIPT_NAME}"
	printf "  %s install --standard\n" "${SCRIPT_NAME}"
	printf "  %s install --ocr\n" "${SCRIPT_NAME}"
	printf "\nSee: tools/document/document-creation.md for full documentation.\n"
	printf "\nNote: Markdown conversions are automatically normalised unless --no-normalise is specified.\n"

	return 0
}

# ============================================================================
# Main dispatch
# ============================================================================

main() {
	local cmd="${1:-help}"
	shift || true

	case "${cmd}" in
	convert) cmd_convert "$@" ;;
	import-emails) cmd_import_emails "$@" ;;
	generate-manifest) cmd_generate_manifest "$@" ;;
	create) cmd_create "$@" ;;
	template) cmd_template "$@" ;;
	normalise | normalize) cmd_normalise "$@" ;;
	extract-entities) cmd_extract_entities "$@" ;;
	pageindex) cmd_pageindex "$@" ;;
	add-related-docs) cmd_add_related_docs "$@" ;;
	enforce-frontmatter | frontmatter) "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/frontmatter-helper.sh" "$@" ;;
	link-documents) cmd_link_documents "$@" ;;
	install) cmd_install "$@" ;;
	formats) cmd_formats ;;
	status) cmd_status ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: ${cmd}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
