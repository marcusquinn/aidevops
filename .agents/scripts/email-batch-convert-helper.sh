#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail

# Email Batch Convert Helper for AI DevOps Framework
# Batch convert .eml/.msg files to markdown and reconstruct conversation threads.
#
# Usage: email-batch-convert-helper.sh <command> [options]
#
# Commands:
#   convert <dir>           Convert all .eml/.msg files in directory to markdown
#   threads <dir>           Reconstruct threads from converted emails
#   batch <dir>             Convert and reconstruct threads (full pipeline)
#   help                    Show this help
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Constants
# =============================================================================

readonly EMAIL_TO_MD_SCRIPT="${SCRIPT_DIR}/email-to-markdown.py"
readonly THREAD_RECON_SCRIPT="${SCRIPT_DIR}/email-thread-reconstruction.py"

# =============================================================================
# Helper Functions
# =============================================================================

# Check if required Python scripts exist
check_dependencies() {
	local missing=0

	if [[ ! -f "$EMAIL_TO_MD_SCRIPT" ]]; then
		print_error "Missing: email-to-markdown.py"
		missing=1
	fi

	if [[ ! -f "$THREAD_RECON_SCRIPT" ]]; then
		print_error "Missing: email-thread-reconstruction.py"
		missing=1
	fi

	if ! command -v python3 &>/dev/null; then
		print_error "python3 not found"
		missing=1
	fi

	if [[ "$missing" -eq 1 ]]; then
		return 1
	fi

	return 0
}

# =============================================================================
# Commands
# =============================================================================

# Convert all .eml/.msg files in a directory to markdown
cmd_convert() {
	local input_dir="$1"
	local extract_entities="${2:-false}"

	if [[ ! -d "$input_dir" ]]; then
		print_error "Directory not found: $input_dir"
		return 1
	fi

	check_dependencies || return 1

	local count=0
	local success=0
	local failed=0

	print_info "Converting emails in: $input_dir"

	# Find all .eml and .msg files
	while IFS= read -r -d '' email_file; do
		count=$((count + 1))
		local basename
		basename=$(basename "$email_file")
		print_info "[$count] Converting: $basename"

		local cmd=(python3 "$EMAIL_TO_MD_SCRIPT" "$email_file")
		if [[ "$extract_entities" == "true" ]]; then
			cmd+=(--extract-entities)
		fi

		if "${cmd[@]}" 2>&1; then
			success=$((success + 1))
		else
			failed=$((failed + 1))
			print_warning "Failed: $basename"
		fi
	done < <(find "$input_dir" -type f \( -name "*.eml" -o -name "*.msg" \) -print0 2>/dev/null)

	print_success "Conversion complete: ${success}/${count} succeeded, ${failed} failed"
	return 0
}

# Reconstruct threads from converted emails
cmd_threads() {
	local input_dir="$1"
	local output_index="${2:-}"

	if [[ ! -d "$input_dir" ]]; then
		print_error "Directory not found: $input_dir"
		return 1
	fi

	check_dependencies || return 1

	print_info "Reconstructing threads in: $input_dir"

	local cmd=(python3 "$THREAD_RECON_SCRIPT" "$input_dir")
	if [[ -n "$output_index" ]]; then
		cmd+=(--output "$output_index")
	fi

	if "${cmd[@]}"; then
		print_success "Thread reconstruction complete"
		return 0
	else
		print_error "Thread reconstruction failed"
		return 1
	fi
}

# Full pipeline: convert and reconstruct threads
cmd_batch() {
	local input_dir="$1"
	local extract_entities="${2:-false}"
	local output_index="${3:-}"

	print_info "Starting batch conversion pipeline"

	# Step 1: Convert emails
	if ! cmd_convert "$input_dir" "$extract_entities"; then
		print_error "Conversion step failed"
		return 1
	fi

	# Step 2: Reconstruct threads
	if ! cmd_threads "$input_dir" "$output_index"; then
		print_error "Thread reconstruction step failed"
		return 1
	fi

	print_success "Batch pipeline complete"
	return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
	cat <<'HELP'
Email Batch Convert Helper - AI DevOps Framework

Usage: email-batch-convert-helper.sh <command> [options]

Commands:
  convert <dir> [--entities]       Convert all .eml/.msg files to markdown
  threads <dir> [--output <file>]  Reconstruct threads from converted emails
  batch <dir> [--entities]         Convert and reconstruct threads (full pipeline)
  help                             Show this help

Options:
  --entities                       Extract named entities during conversion
  --output <file>                  Custom thread index output file

Examples:
  # Convert all emails in a directory
  email-batch-convert-helper.sh convert ./emails

  # Convert with entity extraction
  email-batch-convert-helper.sh convert ./emails --entities

  # Reconstruct threads from already-converted emails
  email-batch-convert-helper.sh threads ./emails

  # Full pipeline: convert and reconstruct
  email-batch-convert-helper.sh batch ./emails

  # Full pipeline with entity extraction
  email-batch-convert-helper.sh batch ./emails --entities

Output:
  - Each .eml/.msg file → .md file with YAML frontmatter
  - Attachments extracted to {filename}_attachments/
  - Thread metadata added to frontmatter (thread_id, thread_position, thread_length)
  - Thread index file: thread-index.md (chronological listing per thread)

Thread Metadata:
  thread_id:       Root message-id of the conversation thread
  thread_position: Position in thread (0 = root, 1+ = replies)
  thread_length:   Total messages in thread

Dependencies:
  - python3
  - email-to-markdown.py
  - email-thread-reconstruction.py
HELP
	return 0
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	convert)
		local dir="${1:-.}"
		local entities="false"
		shift || true
		if [[ "${1:-}" == "--entities" ]]; then
			entities="true"
		fi
		cmd_convert "$dir" "$entities"
		;;
	threads)
		local dir="${1:-.}"
		local output=""
		shift || true
		if [[ "${1:-}" == "--output" ]]; then
			shift
			output="${1:-}"
		fi
		cmd_threads "$dir" "$output"
		;;
	batch)
		local dir="${1:-.}"
		local entities="false"
		local output=""
		shift || true
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--entities)
				entities="true"
				shift
				;;
			--output)
				shift
				output="${1:-}"
				shift
				;;
			*)
				shift
				;;
			esac
		done
		cmd_batch "$dir" "$entities" "$output"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: $command"
		show_help
		return 1
		;;
	esac
}

main "$@"
