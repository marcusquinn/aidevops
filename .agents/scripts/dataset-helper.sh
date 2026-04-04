#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Dataset Helper — Standardised JSONL dataset management for LLM evaluations (t1395)
#
# Provides a convention for storing, validating, and managing evaluation test cases
# in JSONL format. Enables repeatable evaluations across bench (t1393) and
# evaluator (t1394) workflows.
#
# Dataset format (one JSON object per line):
#   Required: id, input
#   Optional: expected, context, tags, source, metadata
#
# Directory convention:
#   Global:  ~/.aidevops/.agent-workspace/datasets/   (cross-project)
#   Project: <repo>/datasets/                          (version-controlled)
#
# Commands:
#   create    <name> [--project]           Create empty dataset
#   validate  <file>                       Validate JSONL schema
#   add       <file> --input "..." [opts]  Append entry
#   list      [--project <path>]           List available datasets
#   stats     <file>                       Row count, tag/source breakdown
#   promote   --trace-id <id>              Convert observability trace to entry
#   merge     <file1> <file2> -o <out>     Merge datasets, dedup by id
#   schema                                 Print the dataset JSON schema
#   help                                   Show this help
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail
init_log_file

# =============================================================================
# Constants
# =============================================================================

readonly GLOBAL_DATASETS_DIR="${HOME}/.aidevops/.agent-workspace/datasets"
readonly OBS_METRICS="${HOME}/.aidevops/.agent-workspace/observability/metrics.jsonl"

# =============================================================================
# Helpers
# =============================================================================

# Generate a short unique ID (8-char hex)
_generate_id() {
	if command -v uuidgen &>/dev/null; then
		uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8
	elif [[ -r /dev/urandom ]]; then
		od -An -tx1 -N4 /dev/urandom | tr -d ' \n'
	else
		printf '%08x' "$$$(date +%s)"
	fi
	return 0
}

# Resolve dataset directory: global or project-local
_resolve_datasets_dir() {
	local project_path="${1:-}"

	if [[ -n "$project_path" ]]; then
		echo "${project_path}/datasets"
	else
		echo "$GLOBAL_DATASETS_DIR"
	fi
	return 0
}

# Ensure a directory exists
_ensure_dir() {
	local dir="$1"
	if [[ ! -d "$dir" ]]; then
		mkdir -p "$dir"
	fi
	return 0
}

# Validate that jq is available
_require_jq() {
	if ! command -v jq &>/dev/null; then
		print_error "jq is required but not installed. Install with: brew install jq"
		return 1
	fi
	return 0
}

# =============================================================================
# Validate sub-functions
# =============================================================================

# Print usage help for the validate command
_validate_help() {
	echo "Usage: dataset-helper.sh validate <file> [--strict]"
	echo ""
	echo "Validates a JSONL dataset file."
	echo ""
	echo "Checks:"
	echo "  - Each line is valid JSON"
	echo "  - Required fields present: id, input"
	echo "  - No duplicate IDs"
	echo ""
	echo "Options:"
	echo "  --strict  Also validate optional field types"
	return 0
}

# Check a single line is valid JSON; print error and return 1 on failure
_validate_line_json() {
	local line="$1"
	local line_num="$2"

	if ! echo "$line" | jq empty 2>/dev/null; then
		print_error "Line $line_num: Invalid JSON"
		return 1
	fi
	return 0
}

# Check required fields (id, input) on a parsed line; return count of errors found
# Outputs the entry id to stdout so the caller can track duplicates
_validate_line_fields() {
	local line="$1"
	local line_num="$2"
	local field_errors=0

	local has_id has_input
	has_id=$(echo "$line" | jq 'has("id")')
	has_input=$(echo "$line" | jq 'has("input")')

	if [[ "$has_id" != "true" ]]; then
		print_error "Line $line_num: Missing required field 'id'"
		field_errors=$((field_errors + 1))
	fi

	if [[ "$has_input" != "true" ]]; then
		print_error "Line $line_num: Missing required field 'input'"
		field_errors=$((field_errors + 1))
	fi

	# Echo the entry id so the caller can check for duplicates
	if [[ "$has_id" == "true" ]]; then
		echo "$line" | jq -r '.id'
	fi

	return "$field_errors"
}

# Run strict type-checking on optional fields; print errors, return count found
_validate_line_strict() {
	local line="$1"
	local line_num="$2"
	local strict_errors=0

	local type_errors
	type_errors=$(echo "$line" | jq '
		[ if has("id") and (.id | type) != "string" then "id must be string" else empty end,
		  if has("input") and (.input | type) != "string" then "input must be string" else empty end,
		  if has("tags") and ((.tags | type) != "array" or any(.tags[]?; type != "string")) then "tags must be an array of strings" else empty end,
		  if has("expected") and (.expected | type) != "string" and .expected != null then "expected must be string or null" else empty end,
		  if has("context") and (.context | type) != "string" and .context != null then "context must be string or null" else empty end,
		  if has("source") and (.source | type) != "string" then "source must be string" else empty end,
		  if has("metadata") and (.metadata | type) != "object" and .metadata != null then "metadata must be object or null" else empty end
		] | .[]' || echo "")

	if [[ -n "$type_errors" ]]; then
		while IFS= read -r err; do
			[[ -z "$err" ]] && continue
			# Remove surrounding quotes from jq string output
			err="${err#\"}"
			err="${err%\"}"
			print_error "Line $line_num: $err"
			strict_errors=$((strict_errors + 1))
		done <<<"$type_errors"
	fi

	return "$strict_errors"
}

# =============================================================================
# Add sub-functions
# =============================================================================

# Print usage help for the add command
_add_help() {
	echo "Usage: dataset-helper.sh add <file> --input \"...\" [options]"
	echo ""
	echo "Appends an entry to a dataset."
	echo ""
	echo "Options:"
	echo "  --input \"text\"      Input prompt (required)"
	echo "  --expected \"text\"   Expected output (optional)"
	echo "  --context \"text\"    Context for grounding (optional)"
	echo "  --tags \"a,b,c\"     Comma-separated tags (optional)"
	echo "  --source \"text\"    Provenance: manual, trace:ID, generated:model (default: manual)"
	echo "  --id \"text\"        Custom ID (default: auto-generated)"
	echo "  --metadata '{}'    JSON object with extra fields (optional)"
	return 0
}

# Validate parsed add inputs and resolve entry_id; echo resolved id to stdout
# Returns 1 on validation failure
_add_validate_inputs() {
	local file_path="$1"
	local input_text="$2"
	local entry_id="$3"

	if [[ -z "$file_path" ]]; then
		print_error "File path is required"
		echo "Usage: dataset-helper.sh add <file> --input \"...\""
		return 1
	fi

	if [[ -z "$input_text" ]]; then
		print_error "--input is required"
		return 1
	fi

	_require_jq || return 1

	if [[ ! -f "$file_path" ]]; then
		print_error "Dataset file not found: $file_path"
		echo "Create one first: dataset-helper.sh create <name>"
		return 1
	fi

	# Auto-generate ID if not provided; echo the resolved id
	if [[ -z "$entry_id" ]]; then
		_generate_id
	else
		echo "$entry_id"
	fi
	return 0
}

# Build the base JSON entry from parsed fields; echo result to stdout
_add_build_entry() {
	local entry_id="$1"
	local input_text="$2"
	local tags_csv="$3"
	local source_text="$4"
	local expected_text="$5"
	local context_text="$6"
	local metadata_json="$7"

	# Build tags array
	local tags_json="[]"
	if [[ -n "$tags_csv" ]]; then
		tags_json=$(echo "$tags_csv" | tr ',' '\n' | jq -R . | jq -s .)
	fi

	# Build the base entry JSON
	local entry
	entry=$(jq -c -n \
		--arg id "$entry_id" \
		--arg input "$input_text" \
		--argjson tags "$tags_json" \
		--arg source "$source_text" \
		'{id: $id, input: $input, tags: $tags, source: $source}')

	# Add optional fields
	if [[ -n "$expected_text" ]]; then
		entry=$(echo "$entry" | jq -c --arg expected "$expected_text" '. + {expected: $expected}')
	fi

	if [[ -n "$context_text" ]]; then
		entry=$(echo "$entry" | jq -c --arg context "$context_text" '. + {context: $context}')
	fi

	if [[ -n "$metadata_json" ]]; then
		# Validate metadata is valid JSON object
		if echo "$metadata_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
			entry=$(echo "$entry" | jq -c --argjson meta "$metadata_json" '. + {metadata: $meta}')
		else
			print_warning "Invalid metadata JSON (must be object), skipping"
		fi
	fi

	echo "$entry"
	return 0
}

# =============================================================================
# Promote sub-functions
# =============================================================================

# Find a trace record in the observability metrics file; echo the JSON record
# Returns 1 if not found
_promote_find_trace() {
	local trace_id="$1"
	local metrics_file="$2"

	# Try matching by request_id first
	local trace_data
	trace_data=$(jq -c --arg trace_id "$trace_id" 'select(.request_id == $trace_id)' <"$metrics_file" | head -1)

	# Fallback: match by session_id
	if [[ -z "$trace_data" ]]; then
		trace_data=$(jq -c --arg trace_id "$trace_id" 'select(.session_id == $trace_id)' <"$metrics_file" | head -1)
	fi

	if [[ -z "$trace_data" ]]; then
		return 1
	fi

	echo "$trace_data"
	return 0
}

# Build a dataset entry from a trace record; echo the JSON entry to stdout
_promote_build_entry() {
	local trace_data="$1"
	local trace_id="$2"
	local tags_csv="$3"

	# Extract fields from trace
	local model project cost_total recorded_at
	model=$(echo "$trace_data" | jq -r '.model // "unknown"')
	project=$(echo "$trace_data" | jq -r '.project // "unknown"')
	cost_total=$(echo "$trace_data" | jq -r '.cost_total // 0')
	recorded_at=$(echo "$trace_data" | jq -r '.recorded_at // ""')

	# Build tags
	local tags_json="[\"promoted\"]"
	if [[ -n "$tags_csv" ]]; then
		tags_json=$(echo "promoted,$tags_csv" | tr ',' '\n' | jq -R . | jq -s 'unique')
	fi

	# Build metadata from trace
	local metadata
	metadata=$(jq -c -n \
		--arg model "$model" \
		--arg project "$project" \
		--arg cost "$cost_total" \
		--arg recorded_at "$recorded_at" \
		--arg trace_id "$trace_id" \
		'{model: $model, project: $project, cost: ($cost | tonumber), recorded_at: $recorded_at, original_trace_id: $trace_id}')

	# Create dataset entry — input is a placeholder since traces don't store prompts
	local entry_id
	entry_id=$(_generate_id)

	local entry
	entry=$(jq -c -n \
		--arg id "$entry_id" \
		--arg input "[Promoted from trace $trace_id] Model: $model, Project: $project" \
		--argjson tags "$tags_json" \
		--arg source "trace:$trace_id" \
		--argjson metadata "$metadata" \
		'{id: $id, input: $input, tags: $tags, source: $source, metadata: $metadata}')

	echo "$entry"
	return 0
}

# =============================================================================
# Commands
# =============================================================================

# Create an empty dataset file
cmd_create() {
	local name=""
	local project_path=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--project)
			project_path="${2:-.}"
			shift 2
			;;
		--help | -h)
			echo "Usage: dataset-helper.sh create <name> [--project [path]]"
			echo ""
			echo "Creates an empty dataset JSONL file."
			echo ""
			echo "Options:"
			echo "  --project [path]  Create in project datasets/ dir (default: current dir)"
			echo ""
			echo "Examples:"
			echo "  dataset-helper.sh create golden-prompts"
			echo "  dataset-helper.sh create api-tests --project ~/Git/myproject"
			return 0
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			name="$1"
			shift
			;;
		esac
	done

	if [[ -z "$name" ]]; then
		print_error "Dataset name is required"
		echo "Usage: dataset-helper.sh create <name> [--project [path]]"
		return 1
	fi

	# Sanitise name: allow alphanumeric, hyphens, underscores
	if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
		print_error "Invalid dataset name: '$name'. Use alphanumeric, hyphens, underscores."
		return 1
	fi

	local datasets_dir
	datasets_dir=$(_resolve_datasets_dir "$project_path")
	_ensure_dir "$datasets_dir"

	local file_path="${datasets_dir}/${name}.jsonl"

	if [[ -f "$file_path" ]]; then
		print_warning "Dataset already exists: $file_path"
		return 1
	fi

	touch "$file_path"
	print_success "Created dataset: $file_path"
	return 0
}

# Parse validate command arguments.
# Sets _VAL_FILE and _VAL_STRICT in caller scope.
# Returns 0 on success, 1 on error.
_validate_parse_args() {
	_VAL_FILE=""
	_VAL_STRICT=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--strict)
			_VAL_STRICT=true
			shift
			;;
		--help | -h)
			_validate_help
			return 2
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			_VAL_FILE="$1"
			shift
			;;
		esac
	done
	return 0
}

# Iterate lines of a JSONL file, validate each, and return error count.
# Outputs final line_num to stdout as "LINES:<n>".
_validate_process_file() {
	local file_path="$1"
	local strict="$2"

	local errors=0
	local line_num=0
	local seen_ids=""

	while IFS= read -r line || [[ -n "$line" ]]; do
		line_num=$((line_num + 1))
		[[ -z "$line" ]] && continue

		if ! _validate_line_json "$line" "$line_num"; then
			errors=$((errors + 1))
			continue
		fi

		local entry_id
		entry_id=$(_validate_line_fields "$line" "$line_num") || {
			local field_err_count=$?
			errors=$((errors + field_err_count))
			entry_id=""
		}

		if [[ -n "$entry_id" ]]; then
			if printf '%s' "$seen_ids" | grep -qxF -- "$entry_id"; then
				print_error "Line $line_num: Duplicate ID '$entry_id'"
				errors=$((errors + 1))
			else
				seen_ids="${seen_ids}${entry_id}
"
			fi
		fi

		if [[ "$strict" == "true" ]]; then
			_validate_line_strict "$line" "$line_num" || {
				local strict_err_count=$?
				errors=$((errors + strict_err_count))
			}
		fi
	done <"$file_path"

	echo "LINES:${line_num}"
	return "$errors"
}

# Validate a JSONL dataset file
cmd_validate() {
	_validate_parse_args "$@"
	local parse_rc=$?
	[[ "$parse_rc" -eq 2 ]] && return 0
	[[ "$parse_rc" -ne 0 ]] && return 1

	local file_path="$_VAL_FILE"
	local strict="$_VAL_STRICT"

	if [[ -z "$file_path" ]]; then
		print_error "File path is required"
		echo "Usage: dataset-helper.sh validate <file>"
		return 1
	fi

	_require_jq || return 1

	if [[ ! -f "$file_path" ]]; then
		print_error "File not found: $file_path"
		return 1
	fi

	local line_count
	line_count=$(wc -l <"$file_path" | tr -d ' ')
	if [[ "$line_count" -eq 0 ]]; then
		print_success "Valid dataset (empty): $file_path"
		return 0
	fi

	local process_output
	process_output=$(_validate_process_file "$file_path" "$strict")
	local errors=$?
	local line_num
	line_num=$(printf '%s' "$process_output" | sed -n 's/^LINES://p')

	if [[ "$errors" -gt 0 ]]; then
		print_error "Validation failed: $errors error(s) in $file_path"
		return 1
	fi

	print_success "Valid dataset ($line_num entries): $file_path"
	return 0
}

# Parse add command arguments.
# Sets _ADD_FILE, _ADD_INPUT, _ADD_EXPECTED, _ADD_CONTEXT, _ADD_TAGS,
#      _ADD_SOURCE, _ADD_ID, _ADD_METADATA in caller scope.
# Returns 0 on success, 1 on error, 2 on --help.
_add_parse_args() {
	_ADD_FILE=""
	_ADD_INPUT=""
	_ADD_EXPECTED=""
	_ADD_CONTEXT=""
	_ADD_TAGS=""
	_ADD_SOURCE="manual"
	_ADD_ID=""
	_ADD_METADATA=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--input)
			[[ $# -ge 2 ]] || {
				print_error "--input requires a value"
				return 1
			}
			_ADD_INPUT="$2"
			shift 2
			;;
		--expected)
			[[ $# -ge 2 ]] || {
				print_error "--expected requires a value"
				return 1
			}
			_ADD_EXPECTED="$2"
			shift 2
			;;
		--context)
			[[ $# -ge 2 ]] || {
				print_error "--context requires a value"
				return 1
			}
			_ADD_CONTEXT="$2"
			shift 2
			;;
		--tags)
			[[ $# -ge 2 ]] || {
				print_error "--tags requires a value"
				return 1
			}
			_ADD_TAGS="$2"
			shift 2
			;;
		--source)
			[[ $# -ge 2 ]] || {
				print_error "--source requires a value"
				return 1
			}
			_ADD_SOURCE="$2"
			shift 2
			;;
		--id)
			[[ $# -ge 2 ]] || {
				print_error "--id requires a value"
				return 1
			}
			_ADD_ID="$2"
			shift 2
			;;
		--metadata)
			[[ $# -ge 2 ]] || {
				print_error "--metadata requires a value"
				return 1
			}
			_ADD_METADATA="$2"
			shift 2
			;;
		--help | -h)
			_add_help
			return 2
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$_ADD_FILE" ]]; then
				_ADD_FILE="$1"
			else
				print_error "Unexpected argument: $1"
				return 1
			fi
			shift
			;;
		esac
	done
	return 0
}

# Add an entry to a dataset
cmd_add() {
	_add_parse_args "$@"
	local parse_rc=$?
	[[ "$parse_rc" -eq 2 ]] && return 0
	[[ "$parse_rc" -ne 0 ]] && return 1

	local file_path="$_ADD_FILE"
	local input_text="$_ADD_INPUT"
	local expected_text="$_ADD_EXPECTED"
	local context_text="$_ADD_CONTEXT"
	local tags_csv="$_ADD_TAGS"
	local source_text="$_ADD_SOURCE"
	local entry_id="$_ADD_ID"
	local metadata_json="$_ADD_METADATA"

	entry_id=$(_add_validate_inputs "$file_path" "$input_text" "$entry_id") || return 1

	local entry
	entry=$(_add_build_entry \
		"$entry_id" "$input_text" "$tags_csv" "$source_text" \
		"$expected_text" "$context_text" "$metadata_json")

	echo "$entry" >>"$file_path"
	print_success "Added entry '$entry_id' to $(basename "$file_path")"
	return 0
}

# List available datasets
cmd_list() {
	local project_path=""
	local show_global=true

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--project)
			project_path="${2:-.}"
			shift 2
			;;
		--no-global)
			show_global=false
			shift
			;;
		--help | -h)
			echo "Usage: dataset-helper.sh list [--project <path>] [--no-global]"
			echo ""
			echo "Lists available datasets."
			echo ""
			echo "Options:"
			echo "  --project <path>  Also list project datasets"
			echo "  --no-global       Skip global datasets"
			return 0
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			print_error "Unexpected argument: $1"
			return 1
			;;
		esac
	done

	local found=0

	# Global datasets
	if [[ "$show_global" == "true" && -d "$GLOBAL_DATASETS_DIR" ]]; then
		local global_files
		global_files=$(find "$GLOBAL_DATASETS_DIR" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null | sort)
		if [[ -n "$global_files" ]]; then
			echo -e "${CYAN}Global datasets${NC} ($GLOBAL_DATASETS_DIR):"
			while IFS= read -r f; do
				local name count
				name=$(basename "$f" .jsonl)
				count=$(wc -l <"$f" | tr -d ' ')
				printf "  %-30s %s entries\n" "$name" "$count"
				found=$((found + 1))
			done <<<"$global_files"
		fi
	fi

	# Project datasets
	if [[ -n "$project_path" ]]; then
		local project_dir="${project_path}/datasets"
		# Resolve to absolute path to prevent option injection if path starts with hyphen
		if [[ -d "$project_dir" ]]; then
			local abs_project_dir
			abs_project_dir=$(cd "$project_dir" && pwd)
			local project_files
			project_files=$(find "$abs_project_dir" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null | sort)
			if [[ -n "$project_files" ]]; then
				echo -e "${CYAN}Project datasets${NC} ($project_dir):"
				while IFS= read -r f; do
					local name count
					name=$(basename "$f" .jsonl)
					count=$(wc -l <"$f" | tr -d ' ')
					printf "  %-30s %s entries\n" "$name" "$count"
					found=$((found + 1))
				done <<<"$project_files"
			fi
		fi
	fi

	if [[ "$found" -eq 0 ]]; then
		print_info "No datasets found. Create one: dataset-helper.sh create <name>"
	fi

	return 0
}

# Show dataset statistics
cmd_stats() {
	local file_path=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--help | -h)
			echo "Usage: dataset-helper.sh stats <file>"
			echo ""
			echo "Shows statistics for a dataset."
			echo ""
			echo "Output:"
			echo "  - Total entries"
			echo "  - Tag distribution"
			echo "  - Source breakdown"
			echo "  - Entries with/without expected output"
			return 0
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			file_path="$1"
			shift
			;;
		esac
	done

	if [[ -z "$file_path" ]]; then
		print_error "File path is required"
		echo "Usage: dataset-helper.sh stats <file>"
		return 1
	fi

	_require_jq || return 1

	if [[ ! -f "$file_path" ]]; then
		print_error "File not found: $file_path"
		return 1
	fi

	local total
	total=$(wc -l <"$file_path" | tr -d ' ')

	echo -e "${CYAN}Dataset:${NC} $(basename "$file_path")"
	echo -e "${CYAN}Path:${NC}    $file_path"
	echo -e "${CYAN}Entries:${NC} $total"

	if [[ "$total" -eq 0 ]]; then
		print_info "Dataset is empty"
		return 0
	fi

	# Entries with expected output
	local with_expected
	with_expected=$(jq -r 'select(.expected != null and .expected != "") | .id' <"$file_path" | wc -l | tr -d ' ')
	echo -e "${CYAN}With expected output:${NC} $with_expected / $total"

	# Entries with context
	local with_context
	with_context=$(jq -r 'select(.context != null and .context != "") | .id' <"$file_path" | wc -l | tr -d ' ')
	echo -e "${CYAN}With context:${NC} $with_context / $total"

	# Source breakdown
	echo ""
	echo -e "${CYAN}Source breakdown:${NC}"
	jq -r '.source // "unknown"' <"$file_path" | sort | uniq -c | sort -rn | while read -r count source; do
		printf "  %-25s %s\n" "$source" "$count"
	done

	# Tag distribution
	echo ""
	echo -e "${CYAN}Tag distribution:${NC}"
	local tag_data
	tag_data=$(jq -r '.tags // [] | .[]' <"$file_path" | sort | uniq -c | sort -rn)
	if [[ -n "$tag_data" ]]; then
		echo "$tag_data" | while read -r count tag; do
			printf "  %-25s %s\n" "$tag" "$count"
		done
	else
		echo "  (no tags)"
	fi

	return 0
}

# Parse promote command arguments.
# Sets _PROMO_TRACE_ID, _PROMO_OUTPUT, _PROMO_TAGS in caller scope.
# Returns 0 on success, 1 on error, 2 on --help.
_promote_parse_args() {
	_PROMO_TRACE_ID=""
	_PROMO_OUTPUT=""
	_PROMO_TAGS=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--trace-id)
			[[ $# -ge 2 ]] || {
				print_error "--trace-id requires a value"
				return 1
			}
			_PROMO_TRACE_ID="$2"
			shift 2
			;;
		--output | -o)
			[[ $# -ge 2 ]] || {
				print_error "-o/--output requires a value"
				return 1
			}
			_PROMO_OUTPUT="$2"
			shift 2
			;;
		--tags)
			[[ $# -ge 2 ]] || {
				print_error "--tags requires a value"
				return 1
			}
			_PROMO_TAGS="$2"
			shift 2
			;;
		--help | -h)
			echo "Usage: dataset-helper.sh promote --trace-id <id> [-o <dataset>] [--tags \"a,b\"]"
			echo ""
			echo "Converts an observability trace into a dataset entry."
			echo ""
			echo "Options:"
			echo "  --trace-id <id>   Request ID from observability metrics (required)"
			echo "  -o <dataset>      Output dataset file (default: global promoted.jsonl)"
			echo "  --tags \"a,b\"      Additional tags for the entry"
			echo ""
			echo "The trace's model, project, and cost are stored in metadata."
			return 2
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			print_error "Unexpected argument: $1"
			return 1
			;;
		esac
	done
	return 0
}

# Resolve the output file for promote, creating it if needed.
# Outputs the resolved path to stdout; returns 1 on error.
_promote_resolve_output() {
	local output_file="$1"

	if [[ -z "$output_file" ]]; then
		_ensure_dir "$GLOBAL_DATASETS_DIR"
		output_file="${GLOBAL_DATASETS_DIR}/promoted.jsonl"
		[[ -f "$output_file" ]] || touch "$output_file"
	fi

	if [[ ! -f "$output_file" ]]; then
		print_error "Output dataset not found: $output_file"
		return 1
	fi

	echo "$output_file"
	return 0
}

# Promote an observability trace to a dataset entry
cmd_promote() {
	_promote_parse_args "$@"
	local parse_rc=$?
	[[ "$parse_rc" -eq 2 ]] && return 0
	[[ "$parse_rc" -ne 0 ]] && return 1

	local trace_id="$_PROMO_TRACE_ID"
	local output_file="$_PROMO_OUTPUT"
	local tags_csv="$_PROMO_TAGS"

	if [[ -z "$trace_id" ]]; then
		print_error "--trace-id is required"
		echo "Usage: dataset-helper.sh promote --trace-id <id>"
		return 1
	fi

	_require_jq || return 1

	if [[ ! -f "$OBS_METRICS" ]]; then
		print_error "Observability metrics not found: $OBS_METRICS"
		echo "Run 'observability-helper.sh ingest' first."
		return 1
	fi

	local trace_data
	if ! trace_data=$(_promote_find_trace "$trace_id" "$OBS_METRICS"); then
		print_error "Trace not found: $trace_id"
		echo "Check available traces with: jq '.request_id' $OBS_METRICS | head"
		return 1
	fi

	output_file=$(_promote_resolve_output "$output_file") || return 1

	local entry entry_id
	entry=$(_promote_build_entry "$trace_data" "$trace_id" "$tags_csv")
	entry_id=$(echo "$entry" | jq -r '.id')

	echo "$entry" >>"$output_file"
	print_success "Promoted trace '$trace_id' to dataset entry '$entry_id' in $(basename "$output_file")"
	return 0
}

# Merge two datasets, deduplicating by ID
cmd_merge() {
	local file1=""
	local file2=""
	local output_file=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-o | --output)
			[[ $# -ge 2 ]] || {
				print_error "-o/--output requires a value"
				return 1
			}
			output_file="$2"
			shift 2
			;;
		--help | -h)
			echo "Usage: dataset-helper.sh merge <file1> <file2> -o <output>"
			echo ""
			echo "Merges two datasets, deduplicating by ID."
			echo "When IDs conflict, entries from file2 take precedence."
			return 0
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$file1" ]]; then
				file1="$1"
			elif [[ -z "$file2" ]]; then
				file2="$1"
			else
				print_error "Unexpected argument: $1"
				return 1
			fi
			shift
			;;
		esac
	done

	if [[ -z "$file1" || -z "$file2" ]]; then
		print_error "Two input files are required"
		echo "Usage: dataset-helper.sh merge <file1> <file2> -o <output>"
		return 1
	fi

	if [[ -z "$output_file" ]]; then
		print_error "-o <output> is required"
		return 1
	fi

	_require_jq || return 1

	for f in "$file1" "$file2"; do
		if [[ ! -f "$f" ]]; then
			print_error "File not found: $f"
			return 1
		fi
	done

	# Merge: file1 first, then file2 overrides on ID conflict
	# Use reduce-to-map so "file2 wins" is deterministic (last write wins by key)
	local merged
	if ! merged=$(jq -c -s '
		reduce .[] as $row ({}; .[$row.id] = $row) | .[]
	' -- "$file1" "$file2"); then
		print_error "Merge failed: invalid JSON input"
		return 1
	fi

	if [[ -z "$merged" ]]; then
		# Both files might be empty
		touch "$output_file"
		print_success "Merged (empty result): $output_file"
		return 0
	fi

	echo "$merged" >"$output_file"

	local count
	count=$(wc -l <"$output_file" | tr -d ' ')
	local count1 count2
	count1=$(wc -l <"$file1" | tr -d ' ')
	count2=$(wc -l <"$file2" | tr -d ' ')
	local deduped=$((count1 + count2 - count))

	print_success "Merged $count entries into $output_file ($deduped duplicates removed)"
	return 0
}

# Print the dataset JSON schema
cmd_schema() {
	cat <<'SCHEMA'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "AI DevOps Evaluation Dataset Entry",
  "description": "A single test case for LLM evaluation",
  "type": "object",
  "required": ["id", "input"],
  "properties": {
    "id": {
      "type": "string",
      "description": "Unique identifier for this entry (auto-generated if omitted on add)"
    },
    "input": {
      "type": "string",
      "description": "The prompt or input to send to the model"
    },
    "expected": {
      "type": ["string", "null"],
      "description": "Expected output (null for open-ended evaluations like summarization)"
    },
    "context": {
      "type": ["string", "null"],
      "description": "Context for grounding — what the model should base its answer on"
    },
    "tags": {
      "type": "array",
      "items": {"type": "string"},
      "description": "Tags for filtering: scenario type, domain, difficulty"
    },
    "source": {
      "type": "string",
      "description": "Provenance: 'manual', 'trace:<id>', 'generated:<model>'",
      "default": "manual"
    },
    "metadata": {
      "type": ["object", "null"],
      "description": "Arbitrary key-value pairs for extra context"
    }
  },
  "additionalProperties": false
}
SCHEMA
	return 0
}

# Show help
cmd_help() {
	cat <<'HELP'
dataset-helper.sh — Standardised JSONL dataset management for LLM evaluations

Usage: dataset-helper.sh <command> [options]

Commands:
  create    <name> [--project]           Create empty dataset
  validate  <file> [--strict]            Validate JSONL schema
  add       <file> --input "..." [opts]  Append entry with auto-generated ID
  list      [--project <path>]           List available datasets
  stats     <file>                       Row count, tag/source breakdown
  promote   --trace-id <id> [-o <file>]  Convert observability trace to entry
  merge     <file1> <file2> -o <out>     Merge datasets, dedup by id
  schema                                 Print the dataset JSON schema
  help                                   Show this help

Dataset format (JSONL — one JSON object per line):
  Required: id, input
  Optional: expected, context, tags, source, metadata

Directory convention:
  Global:  ~/.aidevops/.agent-workspace/datasets/
  Project: <repo>/datasets/

Examples:
  dataset-helper.sh create golden-prompts
  dataset-helper.sh add ~/.aidevops/.agent-workspace/datasets/golden-prompts.jsonl \
    --input "What is the capital of France?" --expected "Paris" --tags "geography,factual"
  dataset-helper.sh validate ~/.aidevops/.agent-workspace/datasets/golden-prompts.jsonl
  dataset-helper.sh stats ~/.aidevops/.agent-workspace/datasets/golden-prompts.jsonl
  dataset-helper.sh promote --trace-id abc123
  dataset-helper.sh merge dataset1.jsonl dataset2.jsonl -o merged.jsonl
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	create) cmd_create "$@" ;;
	validate) cmd_validate "$@" ;;
	add) cmd_add "$@" ;;
	list) cmd_list "$@" ;;
	stats) cmd_stats "$@" ;;
	promote) cmd_promote "$@" ;;
	merge) cmd_merge "$@" ;;
	schema) cmd_schema ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "$ERROR_UNKNOWN_COMMAND: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
