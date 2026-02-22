#!/usr/bin/env bash
# =============================================================================
# TTSR Rule Loader — Soft TTSR Rule Engine (Phase 1)
# =============================================================================
# Discovers and parses rule files from .agents/rules/ directory.
# Checks AI output against rule triggers and returns matching corrections.
#
# Usage:
#   ttsr-rule-loader.sh list   [--rules-dir DIR]
#   ttsr-rule-loader.sh check  <output-text|-> [--rules-dir DIR] [--state-file FILE] [--turn N]
#   ttsr-rule-loader.sh reset  [--state-file FILE]
#   ttsr-rule-loader.sh show   <rule-id> [--rules-dir DIR]
#
# Commands:
#   list    List all discovered rules with metadata
#   check   Check text against all enabled rules, return matching corrections
#   reset   Clear firing state (re-enables 'once' rules)
#   show    Display a single rule's full content
#
# Options:
#   --rules-dir DIR     Override rules directory (default: .agents/rules/)
#   --state-file FILE   Override state file (default: /tmp/ttsr-state-<pid>)
#   --turn N            Current conversation turn number (default: 1)
#   --format json|text  Output format (default: text)
#   -                   Read output text from stdin instead of argument
#
# Exit codes:
#   0  Success (check: at least one rule matched)
#   1  Error (missing args, bad rule file, etc.)
#   2  No rules matched (check command only)
#
# Phase 2 (future): Stream hook integration when OpenCode adds support.
#
# Author: AI DevOps Framework
# =============================================================================

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="ttsr-rule-loader"

# Default rules directory: relative to repo root (one level up from scripts/)
DEFAULT_RULES_DIR="${SCRIPT_DIR}/../rules"
DEFAULT_STATE_FILE="/tmp/ttsr-state-$$"

# =============================================================================
# Utility Functions
# =============================================================================

log_error() {
	local msg="$1"
	printf '[ERROR] %s\n' "$msg" >&2
	return 0
}

log_warn() {
	local msg="$1"
	printf '[WARN] %s\n' "$msg" >&2
	return 0
}

log_info() {
	local msg="$1"
	printf '[INFO] %s\n' "$msg" >&2
	return 0
}

usage() {
	printf 'Usage: %s list   [--rules-dir DIR]\n' "$SCRIPT_NAME"
	printf '       %s check  <output-text|-> [--rules-dir DIR] [--state-file FILE] [--turn N]\n' "$SCRIPT_NAME"
	printf '       %s reset  [--state-file FILE]\n' "$SCRIPT_NAME"
	printf '       %s show   <rule-id> [--rules-dir DIR]\n' "$SCRIPT_NAME"
	return 1
}

# =============================================================================
# Frontmatter Parser
# =============================================================================
# Parses YAML frontmatter from a markdown file.
# Handles scalar values only (no nested objects/arrays beyond simple lists).
# Outputs: KEY=VALUE lines suitable for eval or sourcing.

parse_frontmatter() {
	local file="$1"
	local in_frontmatter=0
	local line_num=0

	while IFS= read -r line || [[ -n "$line" ]]; do
		line_num=$((line_num + 1))

		# Detect frontmatter boundaries
		if [[ "$line" == "---" ]]; then
			if [[ "$in_frontmatter" -eq 0 ]]; then
				# Opening delimiter — must be first non-empty line
				if [[ "$line_num" -eq 1 ]]; then
					in_frontmatter=1
					continue
				else
					# Not at line 1, not frontmatter
					break
				fi
			else
				# Closing delimiter
				break
			fi
		fi

		# Skip if not in frontmatter
		[[ "$in_frontmatter" -eq 0 ]] && continue

		# Skip comments and blank lines
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ "$line" =~ ^[[:space:]]*$ ]] && continue

		# Parse key: value pairs
		if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_-]*):(.*)$ ]]; then
			local key="${BASH_REMATCH[1]}"
			local val="${BASH_REMATCH[2]}"

			# Trim leading whitespace from value
			val="${val#"${val%%[![:space:]]*}"}"

			# Strip surrounding quotes (single or double)
			if [[ "$val" =~ ^\"(.*)\"$ ]]; then
				val="${BASH_REMATCH[1]}"
			elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
				val="${BASH_REMATCH[1]}"
			fi

			# Handle inline arrays: [tag1, tag2] → tag1,tag2
			if [[ "$val" =~ ^\[(.+)\]$ ]]; then
				val="${BASH_REMATCH[1]}"
				# Remove spaces after commas
				val="${val//, /,}"
			fi

			# Normalize key: replace hyphens with underscores for shell compat
			key="${key//-/_}"

			printf '%s=%s\n' "$key" "$val"
		fi
	done <"$file"

	return 0
}

# Extract rule body (everything after frontmatter closing ---)
extract_body() {
	local file="$1"
	local in_frontmatter=0
	local past_frontmatter=0
	local line_num=0

	while IFS= read -r line || [[ -n "$line" ]]; do
		line_num=$((line_num + 1))

		if [[ "$past_frontmatter" -eq 1 ]]; then
			printf '%s\n' "$line"
			continue
		fi

		if [[ "$line" == "---" ]]; then
			if [[ "$in_frontmatter" -eq 0 && "$line_num" -eq 1 ]]; then
				in_frontmatter=1
			elif [[ "$in_frontmatter" -eq 1 ]]; then
				past_frontmatter=1
			fi
		fi
	done <"$file"

	return 0
}

# =============================================================================
# Rule Discovery
# =============================================================================

# Discover all rule files in the rules directory.
# Returns one file path per line. Excludes README.md.
discover_rules() {
	local rules_dir="$1"

	if [[ ! -d "$rules_dir" ]]; then
		log_error "Rules directory not found: $rules_dir"
		return 1
	fi

	local count=0
	for rule_file in "$rules_dir"/*.md; do
		[[ -f "$rule_file" ]] || continue
		# Skip README
		local basename
		basename="$(basename "$rule_file")"
		[[ "$basename" == "README.md" ]] && continue
		printf '%s\n' "$rule_file"
		count=$((count + 1))
	done

	if [[ "$count" -eq 0 ]]; then
		log_warn "No rule files found in $rules_dir"
	fi

	return 0
}

# Load a single rule file into associative-like variables.
# Sets: rule_id, rule_trigger, rule_severity, rule_repeat_policy,
#       rule_gap_turns, rule_tags, rule_enabled, rule_body
load_rule() {
	local file="$1"

	# Reset rule variables
	rule_id=""
	rule_trigger=""
	rule_severity="warn"
	rule_repeat_policy="once"
	rule_gap_turns="3"
	rule_tags=""
	rule_enabled="true"
	rule_body=""

	# Parse frontmatter
	local fm_output
	fm_output="$(parse_frontmatter "$file")"

	# Extract values from parsed frontmatter
	while IFS='=' read -r key val; do
		[[ -z "$key" ]] && continue
		case "$key" in
		id) rule_id="$val" ;;
		ttsr_trigger) rule_trigger="$val" ;;
		severity) rule_severity="$val" ;;
		repeat_policy) rule_repeat_policy="$val" ;;
		gap_turns) rule_gap_turns="$val" ;;
		tags) rule_tags="$val" ;;
		enabled) rule_enabled="$val" ;;
		esac
	done <<<"$fm_output"

	# Validate required fields
	if [[ -z "$rule_id" ]]; then
		log_warn "Rule file missing 'id' field: $file"
		return 1
	fi
	if [[ -z "$rule_trigger" ]]; then
		log_warn "Rule '$rule_id' missing 'ttsr_trigger' field: $file"
		return 1
	fi

	# Extract body
	rule_body="$(extract_body "$file")"

	return 0
}

# =============================================================================
# State Management
# =============================================================================
# State file format: one line per rule: "rule_id:last_fired_turn"

get_last_fired() {
	local rule_id="$1"
	local state_file="$2"

	if [[ ! -f "$state_file" ]]; then
		printf ''
		return 0
	fi

	local result
	result="$(grep "^${rule_id}:" "$state_file" 2>/dev/null | tail -1 | cut -d: -f2)" || true
	printf '%s' "$result"
	return 0
}

record_fired() {
	local rule_id="$1"
	local turn="$2"
	local state_file="$3"

	# Ensure state file directory exists
	local state_dir
	state_dir="$(dirname "$state_file")"
	[[ -d "$state_dir" ]] || mkdir -p "$state_dir"

	# Remove old entry for this rule, append new
	if [[ -f "$state_file" ]]; then
		grep -v "^${rule_id}:" "$state_file" >"${state_file}.tmp" 2>/dev/null || true
	else
		: >"${state_file}.tmp"
	fi
	printf '%s:%s\n' "$rule_id" "$turn" >>"${state_file}.tmp"
	mv "${state_file}.tmp" "$state_file"

	return 0
}

# Check if a rule should fire given its repeat policy and state
should_fire() {
	local rule_id="$1"
	local repeat_policy="$2"
	local gap_turns="$3"
	local current_turn="$4"
	local state_file="$5"

	local last_fired
	last_fired="$(get_last_fired "$rule_id" "$state_file")"

	case "$repeat_policy" in
	once)
		[[ -z "$last_fired" ]]
		return $?
		;;
	after-gap)
		if [[ -z "$last_fired" ]]; then
			return 0
		fi
		local delta=$((current_turn - last_fired))
		((delta >= gap_turns))
		return $?
		;;
	always)
		return 0
		;;
	*)
		log_warn "Unknown repeat_policy '$repeat_policy' for rule '$rule_id', treating as 'always'"
		return 0
		;;
	esac
}

# =============================================================================
# Commands
# =============================================================================

cmd_list() {
	local rules_dir="$1"
	local format="$2"

	local rule_files
	rule_files="$(discover_rules "$rules_dir")" || return 1

	if [[ -z "$rule_files" ]]; then
		printf 'No rules found in %s\n' "$rules_dir"
		return 0
	fi

	if [[ "$format" == "json" ]]; then
		printf '[\n'
		local first=1
	else
		printf '%-25s %-8s %-12s %-8s %s\n' "ID" "SEVERITY" "REPEAT" "ENABLED" "TRIGGER"
		printf '%-25s %-8s %-12s %-8s %s\n' "---" "---" "---" "---" "---"
	fi

	while IFS= read -r rule_file; do
		[[ -z "$rule_file" ]] && continue

		if ! load_rule "$rule_file"; then
			continue
		fi

		if [[ "$format" == "json" ]]; then
			[[ "$first" -eq 1 ]] && first=0 || printf ',\n'
			printf '  {"id":"%s","trigger":"%s","severity":"%s","repeat_policy":"%s","gap_turns":%s,"enabled":%s,"tags":"%s","file":"%s"}' \
				"$rule_id" "$rule_trigger" "$rule_severity" "$rule_repeat_policy" \
				"$rule_gap_turns" "$rule_enabled" "$rule_tags" "$rule_file"
		else
			# Truncate trigger for display
			local display_trigger="$rule_trigger"
			if [[ ${#display_trigger} -gt 40 ]]; then
				display_trigger="${display_trigger:0:37}..."
			fi
			printf '%-25s %-8s %-12s %-8s %s\n' \
				"$rule_id" "$rule_severity" "$rule_repeat_policy" "$rule_enabled" "$display_trigger"
		fi
	done <<<"$rule_files"

	if [[ "$format" == "json" ]]; then
		printf '\n]\n'
	fi

	return 0
}

cmd_check() {
	local output_text="$1"
	local rules_dir="$2"
	local state_file="$3"
	local current_turn="$4"
	local format="$5"

	local rule_files
	rule_files="$(discover_rules "$rules_dir")" || return 1

	if [[ -z "$rule_files" ]]; then
		return 2
	fi

	local matched=0
	local corrections=""

	while IFS= read -r rule_file; do
		[[ -z "$rule_file" ]] && continue

		if ! load_rule "$rule_file"; then
			continue
		fi

		# Skip disabled rules
		if [[ "$rule_enabled" != "true" ]]; then
			continue
		fi

		# Check if trigger matches the output text
		if printf '%s' "$output_text" | grep -qE "$rule_trigger" 2>/dev/null; then
			# Check repeat policy
			if should_fire "$rule_id" "$rule_repeat_policy" "$rule_gap_turns" "$current_turn" "$state_file"; then
				# Record firing
				record_fired "$rule_id" "$current_turn" "$state_file"

				matched=$((matched + 1))

				if [[ "$format" == "json" ]]; then
					if [[ "$matched" -eq 1 ]]; then
						corrections='['
					else
						corrections="${corrections},"
					fi
					# Escape body for JSON (backslashes, quotes, newlines)
					local escaped_body
					escaped_body="$(printf '%s' "$rule_body" | awk '
					BEGIN { ORS="" }
					{
						gsub(/\\/, "\\\\")
						gsub(/"/, "\\\"")
						if (NR > 1) printf "\\n"
						printf "%s", $0
					}
				')"
					corrections="${corrections}{\"id\":\"${rule_id}\",\"severity\":\"${rule_severity}\",\"body\":\"${escaped_body}\"}"
				else
					local severity_upper
					severity_upper="$(printf '%s' "$rule_severity" | tr '[:lower:]' '[:upper:]')"
					corrections="${corrections}--- [${severity_upper}] Rule: ${rule_id} ---"$'\n'"${rule_body}"$'\n'
				fi

				log_info "Rule matched: $rule_id (severity: $rule_severity)"
			fi
		fi
	done <<<"$rule_files"

	if [[ "$matched" -eq 0 ]]; then
		return 2
	fi

	if [[ "$format" == "json" ]]; then
		corrections="${corrections}]"
	fi

	printf '%s' "$corrections"
	return 0
}

cmd_reset() {
	local state_file="$1"

	if [[ -f "$state_file" ]]; then
		rm -f "$state_file"
		log_info "State file removed: $state_file"
	else
		log_info "No state file to reset: $state_file"
	fi

	return 0
}

cmd_show() {
	local target_id="$1"
	local rules_dir="$2"

	local rule_files
	rule_files="$(discover_rules "$rules_dir")" || return 1

	while IFS= read -r rule_file; do
		[[ -z "$rule_file" ]] && continue

		if ! load_rule "$rule_file"; then
			continue
		fi

		if [[ "$rule_id" == "$target_id" ]]; then
			printf 'Rule: %s\n' "$rule_id"
			printf 'File: %s\n' "$rule_file"
			printf 'Trigger: %s\n' "$rule_trigger"
			printf 'Severity: %s\n' "$rule_severity"
			printf 'Repeat: %s\n' "$rule_repeat_policy"
			[[ "$rule_repeat_policy" == "after-gap" ]] && printf 'Gap turns: %s\n' "$rule_gap_turns"
			printf 'Tags: %s\n' "$rule_tags"
			printf 'Enabled: %s\n' "$rule_enabled"
			printf '\n--- Correction Content ---\n'
			printf '%s\n' "$rule_body"
			return 0
		fi
	done <<<"$rule_files"

	log_error "Rule not found: $target_id"
	return 1
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command=""
	local rules_dir="$DEFAULT_RULES_DIR"
	local state_file="$DEFAULT_STATE_FILE"
	local current_turn=1
	local format="text"
	local positional_args=()

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--rules-dir)
			[[ $# -lt 2 ]] && {
				log_error "--rules-dir requires a value"
				usage
			}
			rules_dir="$2"
			shift 2
			;;
		--state-file)
			[[ $# -lt 2 ]] && {
				log_error "--state-file requires a value"
				usage
			}
			state_file="$2"
			shift 2
			;;
		--turn)
			[[ $# -lt 2 ]] && {
				log_error "--turn requires a value"
				usage
			}
			current_turn="$2"
			shift 2
			;;
		--format)
			[[ $# -lt 2 ]] && {
				log_error "--format requires a value"
				usage
			}
			format="$2"
			shift 2
			;;
		--help | -h)
			usage || true
			return 0
			;;
		-)
			# Stdin marker — treat as positional arg
			positional_args+=("$1")
			shift
			;;
		-*)
			log_error "Unknown option: $1"
			usage
			;;
		*)
			positional_args+=("$1")
			shift
			;;
		esac
	done

	# Resolve rules directory to absolute path
	if [[ -d "$rules_dir" ]]; then
		rules_dir="$(cd "$rules_dir" && pwd)"
	fi

	# Extract command
	if [[ ${#positional_args[@]} -lt 1 ]]; then
		log_error "No command specified"
		usage
	fi
	command="${positional_args[0]}"

	case "$command" in
	list)
		cmd_list "$rules_dir" "$format"
		;;
	check)
		if [[ ${#positional_args[@]} -lt 2 ]]; then
			log_error "check command requires output text or '-' for stdin"
			usage
		fi
		local output_text="${positional_args[1]}"
		# Read from stdin if '-' specified
		if [[ "$output_text" == "-" ]]; then
			output_text="$(cat)"
		fi
		cmd_check "$output_text" "$rules_dir" "$state_file" "$current_turn" "$format"
		;;
	reset)
		cmd_reset "$state_file"
		;;
	show)
		if [[ ${#positional_args[@]} -lt 2 ]]; then
			log_error "show command requires a rule ID"
			usage
		fi
		cmd_show "${positional_args[1]}" "$rules_dir"
		;;
	*)
		log_error "Unknown command: $command"
		usage
		;;
	esac
}

main "$@"
