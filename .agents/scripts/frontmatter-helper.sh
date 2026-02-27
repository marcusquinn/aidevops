#!/usr/bin/env bash
set -euo pipefail

# Frontmatter Enforcement Helper for AI DevOps Framework
# Ensures all markdown output has YAML frontmatter with standard fields.
# Adds missing frontmatter, merges with existing if present.
#
# Standard fields:
#   title          - Inferred from first heading or filename
#   source_file    - Original source file path (if provided)
#   converter      - Tool that produced the markdown (if provided)
#   content_hash   - SHA-256 of the body content (excluding frontmatter)
#   tokens_estimate - Word count * 1.3 (heuristic for LLM token estimation)
#
# Usage: frontmatter-helper.sh <command> [options]
#
# Commands:
#   enforce <file.md> [--source <path>] [--converter <name>] [--title <title>]
#       Add or merge frontmatter into a markdown file (in-place)
#   check <file.md>
#       Check if a file has valid frontmatter (exit 0=valid, 1=missing/incomplete)
#   show <file.md>
#       Display the current frontmatter as YAML
#   batch <dir> [--pattern <glob>] [--converter <name>]
#       Enforce frontmatter on all markdown files in a directory
#   help
#       Show this help
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Required frontmatter fields
readonly FM_REQUIRED_FIELDS="title source_file converter content_hash tokens_estimate"

# ---------------------------------------------------------------------------
# Utility: compute SHA-256 of content body (portable macOS + Linux)
# ---------------------------------------------------------------------------
compute_sha256() {
	local content="$1"
	if command -v shasum &>/dev/null; then
		printf '%s' "$content" | shasum -a 256 | awk '{print $1}'
	elif command -v sha256sum &>/dev/null; then
		printf '%s' "$content" | sha256sum | awk '{print $1}'
	else
		print_error "Neither shasum nor sha256sum found"
		return 1
	fi
}

# ---------------------------------------------------------------------------
# Utility: estimate token count from word count (words * 1.3)
# ---------------------------------------------------------------------------
estimate_tokens() {
	local content="$1"
	local word_count
	word_count="$(printf '%s' "$content" | wc -w | tr -d ' ')"
	# Multiply by 1.3 using integer arithmetic: (words * 13 + 5) / 10
	local tokens=$(((word_count * 13 + 5) / 10))
	printf '%d' "$tokens"
}

# ---------------------------------------------------------------------------
# Utility: infer title from markdown content or filename
# ---------------------------------------------------------------------------
infer_title() {
	local content="$1"
	local filename="$2"

	# Try first H1 heading
	local heading
	heading="$(printf '%s' "$content" | grep -m1 '^# ' | sed 's/^# //' | sed 's/[[:space:]]*$//')" || true
	if [[ -n "$heading" ]]; then
		printf '%s' "$heading"
		return 0
	fi

	# Try first H2 heading
	heading="$(printf '%s' "$content" | grep -m1 '^## ' | sed 's/^## //' | sed 's/[[:space:]]*$//')" || true
	if [[ -n "$heading" ]]; then
		printf '%s' "$heading"
		return 0
	fi

	# Fall back to filename without extension
	local basename_noext
	basename_noext="$(basename "$filename" | sed 's/\.[^.]*$//')"
	# Convert hyphens/underscores to spaces, title-case first letter
	local title
	title="$(printf '%s' "$basename_noext" | tr '_-' '  ' | sed 's/\b\(.\)/\u\1/g' 2>/dev/null)" || true
	if [[ -z "$title" ]]; then
		title="$basename_noext"
	fi
	printf '%s' "$title"
	return 0
}

# ---------------------------------------------------------------------------
# Parse existing frontmatter from a markdown file
# Returns: body on stdout, sets FM_* variables via eval
# Sets: FM_EXISTS (0/1), FM_RAW (raw YAML block), FM_BODY (content after frontmatter)
# ---------------------------------------------------------------------------
parse_frontmatter() {
	local file="$1"
	local content
	content="$(cat "$file")"

	# Check if file starts with ---
	if printf '%s' "$content" | head -1 | grep -q '^---[[:space:]]*$'; then
		# Find closing ---
		local end_line
		end_line="$(printf '%s' "$content" | tail -n +2 | grep -n '^---[[:space:]]*$' | head -1 | cut -d: -f1)" || true
		if [[ -n "$end_line" ]]; then
			# end_line is relative to line 2, so actual line is end_line + 1
			local actual_end=$((end_line + 1))
			FM_EXISTS=1
			FM_RAW="$(printf '%s' "$content" | sed -n "2,$((actual_end - 1))p")"
			FM_BODY="$(printf '%s' "$content" | tail -n +"$((actual_end + 1))")"
			return 0
		fi
	fi

	FM_EXISTS=0
	FM_RAW=""
	FM_BODY="$content"
	return 0
}

# ---------------------------------------------------------------------------
# Extract a value from raw YAML frontmatter (simple key: value parsing)
# ---------------------------------------------------------------------------
fm_get_value() {
	local yaml="$1"
	local key="$2"
	local value
	value="$(printf '%s' "$yaml" | grep "^${key}:" | head -1 | sed "s/^${key}:[[:space:]]*//" | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/" | sed 's/[[:space:]]*$//')" || true
	printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# Build frontmatter YAML block
# ---------------------------------------------------------------------------
build_frontmatter() {
	local title="$1"
	local source_file="$2"
	local converter="$3"
	local content_hash="$4"
	local tokens_estimate="$5"
	local extra_yaml="$6"

	printf '%s\n' "---"
	printf 'title: "%s"\n' "$title"
	printf 'source_file: "%s"\n' "$source_file"
	printf 'converter: "%s"\n' "$converter"
	printf 'content_hash: "%s"\n' "$content_hash"
	printf 'tokens_estimate: %s\n' "$tokens_estimate"

	# Append any extra fields from existing frontmatter (preserving user fields)
	if [[ -n "$extra_yaml" ]]; then
		printf '%s\n' "$extra_yaml"
	fi

	printf '%s\n' "---"
}

# ---------------------------------------------------------------------------
# Filter out standard fields from existing YAML to preserve custom fields
# ---------------------------------------------------------------------------
filter_extra_fields() {
	local yaml="$1"
	printf '%s\n' "$yaml" | grep -vE "^(title|source_file|converter|content_hash|tokens_estimate):" || true
}

# ---------------------------------------------------------------------------
# Command: enforce — add or merge frontmatter into a markdown file
# ---------------------------------------------------------------------------
cmd_enforce() {
	local file=""
	local source_file=""
	local converter=""
	local title=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--source)
			source_file="$2"
			shift 2
			;;
		--converter)
			converter="$2"
			shift 2
			;;
		--title)
			title="$2"
			shift 2
			;;
		--*)
			print_warning "Unknown option: $1"
			shift
			;;
		*)
			if [[ -z "$file" ]]; then
				file="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$file" ]]; then
		print_error "${ERROR_INPUT_FILE_REQUIRED}"
		return 1
	fi

	validate_file_exists "$file" "Markdown file" || return 1

	# Parse existing frontmatter
	local FM_EXISTS FM_RAW FM_BODY
	parse_frontmatter "$file"

	# Compute fields from body content
	local content_hash
	content_hash="$(compute_sha256 "$FM_BODY")" || return 1

	local tokens_estimate
	tokens_estimate="$(estimate_tokens "$FM_BODY")"

	# Determine title: explicit > existing > inferred
	if [[ -z "$title" && "$FM_EXISTS" -eq 1 ]]; then
		title="$(fm_get_value "$FM_RAW" "title")"
	fi
	if [[ -z "$title" ]]; then
		title="$(infer_title "$FM_BODY" "$file")"
	fi

	# Determine source_file: explicit > existing > empty
	if [[ -z "$source_file" && "$FM_EXISTS" -eq 1 ]]; then
		source_file="$(fm_get_value "$FM_RAW" "source_file")"
	fi

	# Determine converter: explicit > existing > unknown
	if [[ -z "$converter" && "$FM_EXISTS" -eq 1 ]]; then
		converter="$(fm_get_value "$FM_RAW" "converter")"
	fi
	if [[ -z "$converter" ]]; then
		converter="unknown"
	fi

	# Preserve extra fields from existing frontmatter
	local extra_yaml=""
	if [[ "$FM_EXISTS" -eq 1 && -n "$FM_RAW" ]]; then
		extra_yaml="$(filter_extra_fields "$FM_RAW")"
	fi

	# Build and write
	local new_frontmatter
	new_frontmatter="$(build_frontmatter "$title" "$source_file" "$converter" "$content_hash" "$tokens_estimate" "$extra_yaml")"

	# Write file: frontmatter + blank line + body
	{
		printf '%s\n' "$new_frontmatter"
		# Add blank line between frontmatter and body if body doesn't start with one
		if [[ -n "$FM_BODY" ]] && ! printf '%s' "$FM_BODY" | head -1 | grep -q '^[[:space:]]*$'; then
			printf '\n'
		fi
		printf '%s\n' "$FM_BODY"
	} >"${file}.tmp"
	mv "${file}.tmp" "$file"

	if [[ "$FM_EXISTS" -eq 1 ]]; then
		print_success "Merged frontmatter: ${file}"
	else
		print_success "Added frontmatter: ${file}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Command: check — verify frontmatter presence and completeness
# ---------------------------------------------------------------------------
cmd_check() {
	local file="${1:-}"

	if [[ -z "$file" ]]; then
		print_error "${ERROR_INPUT_FILE_REQUIRED}"
		return 1
	fi

	validate_file_exists "$file" "Markdown file" || return 1

	local FM_EXISTS FM_RAW FM_BODY
	parse_frontmatter "$file"

	if [[ "$FM_EXISTS" -eq 0 ]]; then
		print_warning "No frontmatter: ${file}"
		return 1
	fi

	# Check required fields
	local missing=0
	local field
	for field in $FM_REQUIRED_FIELDS; do
		local value
		value="$(fm_get_value "$FM_RAW" "$field")"
		if [[ -z "$value" ]]; then
			print_warning "Missing field '${field}': ${file}"
			missing=1
		fi
	done

	if [[ "$missing" -eq 1 ]]; then
		return 1
	fi

	print_success "Valid frontmatter: ${file}"
	return 0
}

# ---------------------------------------------------------------------------
# Command: show — display current frontmatter
# ---------------------------------------------------------------------------
cmd_show() {
	local file="${1:-}"

	if [[ -z "$file" ]]; then
		print_error "${ERROR_INPUT_FILE_REQUIRED}"
		return 1
	fi

	validate_file_exists "$file" "Markdown file" || return 1

	local FM_EXISTS FM_RAW FM_BODY
	parse_frontmatter "$file"

	if [[ "$FM_EXISTS" -eq 0 ]]; then
		print_info "No frontmatter found in: ${file}"
		return 0
	fi

	printf '%s\n' "---"
	printf '%s\n' "$FM_RAW"
	printf '%s\n' "---"
	return 0
}

# ---------------------------------------------------------------------------
# Command: batch — enforce frontmatter on all markdown files in a directory
# ---------------------------------------------------------------------------
cmd_batch() {
	local dir=""
	local pattern="*.md"
	local converter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pattern)
			pattern="$2"
			shift 2
			;;
		--converter)
			converter="$2"
			shift 2
			;;
		--*)
			print_warning "Unknown option: $1"
			shift
			;;
		*)
			if [[ -z "$dir" ]]; then
				dir="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$dir" ]]; then
		print_error "Directory is required"
		return 1
	fi

	if [[ ! -d "$dir" ]]; then
		print_error "Directory not found: ${dir}"
		return 1
	fi

	local count=0
	local success=0

	while IFS= read -r -d '' file; do
		count=$((count + 1))
		local args=("$file")
		if [[ -n "$converter" ]]; then
			args+=("--converter" "$converter")
		fi
		if cmd_enforce "${args[@]}"; then
			success=$((success + 1))
		fi
	done < <(find "$dir" -maxdepth 1 -name "$pattern" -type f -print0)

	print_info "Batch complete: ${success}/${count} files processed"
	return 0
}

# ---------------------------------------------------------------------------
# Command: help
# ---------------------------------------------------------------------------
cmd_help() {
	local script_name
	script_name="$(basename "$0")"

	printf "Frontmatter Enforcement Helper\n"
	printf "==============================\n\n"
	printf "%s\n" "${HELP_LABEL_USAGE}"
	printf "  %s <command> [options]\n\n" "$script_name"
	printf "%s\n" "${HELP_LABEL_COMMANDS}"
	printf "  enforce <file.md> [--source <path>] [--converter <name>] [--title <title>]\n"
	printf "      Add or merge YAML frontmatter into a markdown file (in-place)\n\n"
	printf "  check <file.md>\n"
	printf "      Check if a file has valid frontmatter (exit 0=valid, 1=missing)\n\n"
	printf "  show <file.md>\n"
	printf "      Display the current frontmatter\n\n"
	printf "  batch <dir> [--pattern <glob>] [--converter <name>]\n"
	printf "      Enforce frontmatter on all markdown files in a directory\n\n"
	printf "  help\n"
	printf "      Show this help\n\n"
	printf "Standard frontmatter fields:\n"
	printf "  title           - Inferred from first heading or filename\n"
	printf "  source_file     - Original source file path\n"
	printf "  converter       - Tool that produced the markdown\n"
	printf "  content_hash    - SHA-256 of body content (excluding frontmatter)\n"
	printf "  tokens_estimate - Word count * 1.3 (LLM token heuristic)\n\n"
	printf "%s\n" "${HELP_LABEL_EXAMPLES}"
	printf "  %s enforce report.md --source report.pdf --converter pandoc\n" "$script_name"
	printf "  %s check report.md\n" "$script_name"
	printf "  %s batch ./output/ --converter docling\n" "$script_name"
	printf "  %s show report.md\n" "$script_name"

	return 0
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	enforce) cmd_enforce "$@" ;;
	check) cmd_check "$@" ;;
	show) cmd_show "$@" ;;
	batch) cmd_batch "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: ${cmd}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
