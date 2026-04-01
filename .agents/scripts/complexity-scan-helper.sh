#!/usr/bin/env bash
# complexity-scan-helper.sh — Deterministic complexity scan (GH#15285)
#
# Replaces per-file LLM complexity analysis with shell-based heuristics:
# line count, function count, nesting depth. Uses hash comparison against
# simplification-state.json to skip unchanged files. Completes in <30s
# for typical repos (vs 5-8 min with LLM analysis).
#
# Daily LLM sweep is reserved for stall detection only — when the
# simplification debt count hasn't reduced in 6h.
#
# Usage:
#   complexity-scan-helper.sh scan <repo_path> [--state-file <path>] [--format json|pipe]
#   complexity-scan-helper.sh sweep-check <repo_slug> [--stall-hours 6]
#   complexity-scan-helper.sh metrics <file_path>
#   complexity-scan-helper.sh help
#
# Exit codes: 0 = success, 1 = error, 2 = no changes detected

set -euo pipefail

# shellcheck disable=SC2155

#######################################
# Configuration defaults
#######################################
COMPLEXITY_FUNC_LINE_THRESHOLD="${COMPLEXITY_FUNC_LINE_THRESHOLD:-100}"
COMPLEXITY_FILE_VIOLATION_THRESHOLD="${COMPLEXITY_FILE_VIOLATION_THRESHOLD:-1}"
COMPLEXITY_MD_MIN_LINES="${COMPLEXITY_MD_MIN_LINES:-50}"
COMPLEXITY_NESTING_DEPTH_THRESHOLD="${COMPLEXITY_NESTING_DEPTH_THRESHOLD:-8}"
SWEEP_STALL_HOURS="${SWEEP_STALL_HOURS:-6}"
SWEEP_LAST_RUN_FILE="${HOME}/.aidevops/logs/complexity-llm-sweep-last-run"
SWEEP_DEBT_SNAPSHOT="${HOME}/.aidevops/logs/complexity-debt-snapshot"

#######################################
# Logging
#######################################
_log() {
	local level="$1"
	shift
	printf '[complexity-scan] %s: %s\n' "$level" "$*" >&2
	return 0
}

#######################################
# Compute shell-based heuristics for a single file.
# Arguments: $1 - file_path (absolute)
# Output: pipe-delimited metrics to stdout
#   line_count|func_count|long_func_count|max_nesting|file_type
#######################################
compute_file_metrics() {
	local file_path="$1"

	if [[ ! -f "$file_path" ]]; then
		echo "0|0|0|0|unknown"
		return 1
	fi

	local ext="${file_path##*.}"
	local file_type="unknown"
	case "$ext" in
	sh | bash) file_type="shell" ;;
	md) file_type="markdown" ;;
	py) file_type="python" ;;
	ts | js) file_type="javascript" ;;
	*) file_type="other" ;;
	esac

	local line_count=0
	line_count=$(wc -l <"$file_path" 2>/dev/null | tr -d ' ') || line_count=0

	local func_count=0
	local long_func_count=0
	local max_nesting=0

	if [[ "$file_type" == "shell" ]]; then
		# Count functions and identify long ones using awk
		local awk_result
		awk_result=$(awk '
			BEGIN { fc=0; lfc=0; max_nest=0; cur_nest=0 }
			/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ {
				fc++; fname=$1; sub(/\(\)/, "", fname); start=NR; next
			}
			fname && /^\}$/ {
				lines=NR-start
				if (lines > '"$COMPLEXITY_FUNC_LINE_THRESHOLD"') lfc++
				fname=""
			}
			# Nesting depth tracking (braces, if/then/fi, case/esac, while/do/done)
			/\{[[:space:]]*$/ || /\bthen\b/ || /\bdo\b/ { cur_nest++; if (cur_nest > max_nest) max_nest = cur_nest }
			/^\}/ || /\bfi\b/ || /\bdone\b/ || /\besac\b/ { if (cur_nest > 0) cur_nest-- }
			END { printf "%d|%d|%d", fc, lfc, max_nest }
		' "$file_path" 2>/dev/null) || awk_result="0|0|0"

		func_count=$(echo "$awk_result" | cut -d'|' -f1)
		long_func_count=$(echo "$awk_result" | cut -d'|' -f2)
		max_nesting=$(echo "$awk_result" | cut -d'|' -f3)
	elif [[ "$file_type" == "markdown" ]]; then
		# For markdown: count headings as "functions", nesting = heading depth
		func_count=$(grep -c '^#' "$file_path" 2>/dev/null || echo "0")
		max_nesting=$(awk '/^#{1,6} / { n=0; for(i=1;i<=length($1);i++) if(substr($1,i,1)=="#") n++; if(n>max) max=n } END { print max+0 }' "$file_path" 2>/dev/null) || max_nesting=0
	fi

	printf '%s|%s|%s|%s|%s' "$line_count" "$func_count" "$long_func_count" "$max_nesting" "$file_type"
	return 0
}

#######################################
# Check file hash against simplification state.
# Arguments: $1 - repo_path, $2 - file_path (repo-relative), $3 - state_file
# Output: "unchanged" | "recheck" | "new"
#######################################
check_file_state() {
	local repo_path="$1"
	local file_path="$2"
	local state_file="$3"

	if [[ ! -f "$state_file" ]]; then
		echo "new"
		return 0
	fi

	local recorded_hash
	recorded_hash=$(jq -r --arg fp "$file_path" '.files[$fp].hash // empty' "$state_file" 2>/dev/null) || recorded_hash=""

	if [[ -z "$recorded_hash" ]]; then
		echo "new"
		return 0
	fi

	local full_path="${repo_path}/${file_path}"
	if [[ ! -f "$full_path" ]]; then
		echo "new"
		return 0
	fi

	local current_hash
	current_hash=$(git -C "$repo_path" hash-object "$full_path" 2>/dev/null) || current_hash=""

	if [[ "$current_hash" == "$recorded_hash" ]]; then
		echo "unchanged"
		return 0
	fi

	echo "recheck"
	return 0
}

#######################################
# Batch hash check — compute all current hashes in one pass, compare
# against state file. This is the core performance optimization: instead
# of calling git hash-object per file, we use git ls-files with hash info.
#
# Arguments: $1 - repo_path, $2 - state_file, $3 - file_pattern (e.g., '*.sh')
# Output: lines of "status|file_path" where status is new/recheck/unchanged
#######################################
batch_hash_check() {
	local repo_path="$1"
	local state_file="$2"
	local file_pattern="$3"

	# Get all tracked files matching pattern with their current blob hashes
	# Format: <mode> <hash> <stage>\t<file>
	local git_ls_output
	git_ls_output=$(git -C "$repo_path" ls-files -s "$file_pattern" 2>/dev/null) || {
		_log "WARN" "git ls-files failed for pattern: $file_pattern"
		return 1
	}

	if [[ -z "$git_ls_output" ]]; then
		return 0
	fi

	# If no state file, everything is "new"
	if [[ ! -f "$state_file" ]]; then
		while IFS=$'\t' read -r _mode_hash file_path; do
			[[ -n "$file_path" ]] || continue
			echo "new|${file_path}"
		done <<<"$git_ls_output"
		return 0
	fi

	# Load state file hashes into an associative-style lookup via jq
	# Output: one line per entry "file_path\thash"
	local state_hashes
	state_hashes=$(jq -r '.files | to_entries[] | "\(.key)\t\(.value.hash)"' "$state_file" 2>/dev/null) || state_hashes=""

	# Build a temp file for state lookup (faster than repeated jq calls)
	local state_tmp
	state_tmp=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$state_tmp'" EXIT
	printf '%s\n' "$state_hashes" >"$state_tmp"

	while IFS=$'\t' read -r mode_hash file_path; do
		[[ -n "$file_path" ]] || continue
		# Extract hash from mode_hash (format: "100644 <hash> 0")
		local current_hash
		current_hash=$(echo "$mode_hash" | awk '{print $2}')

		# Look up recorded hash
		local recorded_hash
		recorded_hash=$(grep -F "$file_path" "$state_tmp" 2>/dev/null | head -1 | cut -f2) || recorded_hash=""

		if [[ -z "$recorded_hash" ]]; then
			echo "new|${file_path}"
		elif [[ "$current_hash" == "$recorded_hash" ]]; then
			echo "unchanged|${file_path}"
		else
			echo "recheck|${file_path}"
		fi
	done <<<"$git_ls_output"

	rm -f "$state_tmp"
	# Remove the trap since we cleaned up manually
	trap - EXIT
	return 0
}

#######################################
# Main scan command — deterministic complexity scan.
# Compares file hashes against simplification-state.json, only computes
# metrics for changed/new files. Outputs results in pipe or JSON format.
#
# Arguments: $1 - repo_path
# Options: --state-file <path>, --format json|pipe, --type sh|md|all
#######################################
cmd_scan() {
	local repo_path=""
	local state_file=""
	local output_format="pipe"
	local scan_type="all"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--state-file)
			state_file="$2"
			shift 2
			;;
		--format)
			output_format="$2"
			shift 2
			;;
		--type)
			scan_type="$2"
			shift 2
			;;
		*)
			if [[ -z "$repo_path" ]]; then
				repo_path="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
		_log "ERROR" "repo_path is required and must be a directory"
		return 1
	fi

	# Default state file location
	if [[ -z "$state_file" ]]; then
		state_file="${repo_path}/.agents/configs/simplification-state.json"
	fi

	local start_time
	start_time=$(date +%s)

	local total_files=0
	local changed_files=0
	local unchanged_files=0
	local results=""

	# Protected files and directories
	local protected_pattern='prompts/build\.txt|^\.agents/AGENTS\.md|^AGENTS\.md|scripts/commands/pulse\.md'
	local excluded_dirs='_archive/|archived/|supervisor-archived/|/templates/|/todo/'
	local excluded_files='/README\.md$'

	# Phase 1: Shell files
	if [[ "$scan_type" == "all" || "$scan_type" == "sh" ]]; then
		local sh_check_results
		sh_check_results=$(batch_hash_check "$repo_path" "$state_file" '*.sh') || sh_check_results=""

		if [[ -n "$sh_check_results" ]]; then
			while IFS='|' read -r status file_path; do
				[[ -n "$file_path" ]] || continue
				# Skip excluded directories
				if echo "$file_path" | grep -qE "$excluded_dirs"; then
					continue
				fi
				total_files=$((total_files + 1))

				if [[ "$status" == "unchanged" ]]; then
					unchanged_files=$((unchanged_files + 1))
					continue
				fi

				# Compute metrics only for changed/new files
				local full_path="${repo_path}/${file_path}"
				local metrics
				metrics=$(compute_file_metrics "$full_path") || metrics="0|0|0|0|shell"

				local line_count func_count long_func_count max_nesting file_type
				IFS='|' read -r line_count func_count long_func_count max_nesting file_type <<<"$metrics"

				# Only report files that exceed thresholds
				if [[ "$long_func_count" -ge "$COMPLEXITY_FILE_VIOLATION_THRESHOLD" ]] ||
					[[ "$max_nesting" -gt "$COMPLEXITY_NESTING_DEPTH_THRESHOLD" ]]; then
					changed_files=$((changed_files + 1))
					results="${results}${status}|${file_path}|${line_count}|${func_count}|${long_func_count}|${max_nesting}|${file_type}"$'\n'
				fi
			done <<<"$sh_check_results"
		fi
	fi

	# Phase 2: Markdown files
	if [[ "$scan_type" == "all" || "$scan_type" == "md" ]]; then
		local md_check_results
		md_check_results=$(batch_hash_check "$repo_path" "$state_file" '*.md') || md_check_results=""

		if [[ -n "$md_check_results" ]]; then
			while IFS='|' read -r status file_path; do
				[[ -n "$file_path" ]] || continue
				# Only .agents/ markdown files
				if ! echo "$file_path" | grep -q '^\.agents/'; then
					continue
				fi
				# Skip excluded patterns
				if echo "$file_path" | grep -qE "$excluded_dirs|$excluded_files|$protected_pattern"; then
					continue
				fi
				total_files=$((total_files + 1))

				if [[ "$status" == "unchanged" ]]; then
					unchanged_files=$((unchanged_files + 1))
					continue
				fi

				# Compute metrics only for changed/new files
				local full_path="${repo_path}/${file_path}"
				local line_count=0
				line_count=$(wc -l <"$full_path" 2>/dev/null | tr -d ' ') || line_count=0

				# Apply minimum line threshold
				if [[ "$line_count" -lt "$COMPLEXITY_MD_MIN_LINES" ]]; then
					continue
				fi

				# Check frontmatter ratio (skip stub files)
				local frontmatter_end=0
				if head -1 "$full_path" 2>/dev/null | grep -q '^---$'; then
					frontmatter_end=$(awk 'NR==1 && /^---$/ { in_fm=1; next } in_fm && /^---$/ { print NR; exit }' "$full_path" 2>/dev/null)
					frontmatter_end=${frontmatter_end:-0}
				fi
				if [[ "$frontmatter_end" -gt 0 ]]; then
					local content_lines=$((line_count - frontmatter_end))
					local threshold=$(((line_count * 40) / 100))
					if [[ "$content_lines" -lt "$threshold" ]]; then
						continue
					fi
				fi

				local metrics
				metrics=$(compute_file_metrics "$full_path") || metrics="${line_count}|0|0|0|markdown"

				local _lc _fc _lfc max_nesting file_type
				IFS='|' read -r _lc _fc _lfc max_nesting file_type <<<"$metrics"

				changed_files=$((changed_files + 1))
				results="${results}${status}|${file_path}|${line_count}|${_fc}|0|${max_nesting}|${file_type}"$'\n'
			done <<<"$md_check_results"
		fi
	fi

	local elapsed=$(($(date +%s) - start_time))

	# Output summary to stderr
	_log "INFO" "Scan complete in ${elapsed}s: ${total_files} files checked, ${changed_files} changed/new, ${unchanged_files} unchanged"

	if [[ -z "$results" ]]; then
		_log "INFO" "No files exceed complexity thresholds"
		return 2
	fi

	# Sort by line count (field 3) descending — biggest wins first
	results=$(printf '%s' "$results" | sort -t'|' -k3 -rn)

	if [[ "$output_format" == "json" ]]; then
		# Convert to JSON array
		echo "["
		local first=true
		while IFS='|' read -r status file_path line_count func_count long_func_count max_nesting file_type; do
			[[ -n "$file_path" ]] || continue
			if [[ "$first" == true ]]; then
				first=false
			else
				echo ","
			fi
			printf '  {"status":"%s","file":"%s","lines":%s,"functions":%s,"long_functions":%s,"max_nesting":%s,"type":"%s"}' \
				"$status" "$file_path" "$line_count" "$func_count" "$long_func_count" "$max_nesting" "$file_type"
		done <<<"$results"
		echo ""
		echo "]"
	else
		# Pipe-delimited output (default)
		printf '%s' "$results"
	fi

	return 0
}

#######################################
# Sweep check — determine if daily LLM sweep is needed.
# Conditions for sweep:
#   1. Last sweep was >24h ago (or never run)
#   2. Simplification debt count hasn't decreased in SWEEP_STALL_HOURS
#
# Arguments: $1 - repo_slug
# Options: --stall-hours N
# Output: "needed" or "not-needed" with reason
# Exit: 0 = sweep needed, 1 = not needed
#######################################
cmd_sweep_check() {
	local repo_slug=""
	local stall_hours="$SWEEP_STALL_HOURS"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--stall-hours)
			stall_hours="$2"
			shift 2
			;;
		*)
			if [[ -z "$repo_slug" ]]; then
				repo_slug="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$repo_slug" ]]; then
		_log "ERROR" "repo_slug is required"
		return 1
	fi

	local now_epoch
	now_epoch=$(date +%s)

	# Check 1: Has it been >24h since last sweep?
	if [[ -f "$SWEEP_LAST_RUN_FILE" ]]; then
		local last_sweep
		last_sweep=$(cat "$SWEEP_LAST_RUN_FILE" 2>/dev/null || echo "0")
		[[ "$last_sweep" =~ ^[0-9]+$ ]] || last_sweep=0
		local sweep_elapsed=$((now_epoch - last_sweep))
		if [[ "$sweep_elapsed" -lt 86400 ]]; then
			local hours_remaining=$(((86400 - sweep_elapsed) / 3600))
			echo "not-needed|sweep ran ${sweep_elapsed}s ago (${hours_remaining}h until next)"
			return 1
		fi
	fi

	# Check 2: Has debt count stalled?
	local current_debt=0
	current_debt=$(gh api graphql -f query="query { repository(owner:\"${repo_slug%%/*}\", name:\"${repo_slug##*/}\") { issues(labels:[\"simplification-debt\"], states:OPEN) { totalCount } } }" \
		--jq '.data.repository.issues.totalCount' 2>/dev/null) || current_debt=0

	if [[ -f "$SWEEP_DEBT_SNAPSHOT" ]]; then
		local snapshot_data
		snapshot_data=$(cat "$SWEEP_DEBT_SNAPSHOT" 2>/dev/null) || snapshot_data=""
		local snapshot_epoch snapshot_count
		snapshot_epoch=$(echo "$snapshot_data" | cut -d'|' -f1)
		snapshot_count=$(echo "$snapshot_data" | cut -d'|' -f2)
		[[ "$snapshot_epoch" =~ ^[0-9]+$ ]] || snapshot_epoch=0
		[[ "$snapshot_count" =~ ^[0-9]+$ ]] || snapshot_count=0

		local stall_seconds=$((stall_hours * 3600))
		local snapshot_age=$((now_epoch - snapshot_epoch))

		if [[ "$snapshot_age" -ge "$stall_seconds" ]]; then
			if [[ "$current_debt" -ge "$snapshot_count" ]]; then
				# Debt hasn't decreased — sweep needed
				echo "needed|debt stalled at ${current_debt} for ${stall_hours}h+ (was ${snapshot_count})"
				# Update snapshot for next check
				echo "${now_epoch}|${current_debt}" >"$SWEEP_DEBT_SNAPSHOT"
				return 0
			else
				# Debt decreased — update snapshot, no sweep needed
				echo "${now_epoch}|${current_debt}" >"$SWEEP_DEBT_SNAPSHOT"
				echo "not-needed|debt decreased from ${snapshot_count} to ${current_debt}"
				return 1
			fi
		else
			echo "not-needed|snapshot too recent (${snapshot_age}s old, need ${stall_seconds}s)"
			return 1
		fi
	fi

	# No snapshot exists — create one, sweep needed for initial baseline
	echo "${now_epoch}|${current_debt}" >"$SWEEP_DEBT_SNAPSHOT"
	echo "needed|initial sweep (no prior snapshot, current debt: ${current_debt})"
	return 0
}

#######################################
# Record that a sweep was performed.
#######################################
cmd_sweep_done() {
	local now_epoch
	now_epoch=$(date +%s)
	echo "$now_epoch" >"$SWEEP_LAST_RUN_FILE"
	_log "INFO" "LLM sweep recorded at $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
	return 0
}

#######################################
# Metrics command — compute metrics for a single file.
# Arguments: $1 - file_path (absolute)
#######################################
cmd_metrics() {
	local file_path="$1"

	if [[ -z "$file_path" || ! -f "$file_path" ]]; then
		_log "ERROR" "file_path is required and must exist"
		return 1
	fi

	local metrics
	metrics=$(compute_file_metrics "$file_path") || {
		_log "ERROR" "Failed to compute metrics for $file_path"
		return 1
	}

	local line_count func_count long_func_count max_nesting file_type
	IFS='|' read -r line_count func_count long_func_count max_nesting file_type <<<"$metrics"

	printf 'File: %s\n' "$file_path"
	printf 'Type: %s\n' "$file_type"
	printf 'Lines: %s\n' "$line_count"
	printf 'Functions: %s\n' "$func_count"
	printf 'Long functions (>%s lines): %s\n' "$COMPLEXITY_FUNC_LINE_THRESHOLD" "$long_func_count"
	printf 'Max nesting depth: %s\n' "$max_nesting"
	return 0
}

#######################################
# Help
#######################################
cmd_help() {
	cat <<'HELP'
complexity-scan-helper.sh — Deterministic complexity scan (GH#15285)

COMMANDS
  scan <repo_path> [options]    Fast deterministic scan using shell heuristics
    --state-file <path>         Path to simplification-state.json
    --format json|pipe          Output format (default: pipe)
    --type sh|md|all            File types to scan (default: all)

  sweep-check <repo_slug>      Check if daily LLM sweep is needed
    --stall-hours N             Hours of stall before sweep (default: 6)

  sweep-done                    Record that LLM sweep was performed

  metrics <file_path>           Compute metrics for a single file

  help                          Show this help

OUTPUT FORMAT (pipe)
  status|file_path|line_count|func_count|long_func_count|max_nesting|file_type

  status: new, recheck, unchanged
  file_type: shell, markdown, python, javascript, other

ENVIRONMENT
  COMPLEXITY_FUNC_LINE_THRESHOLD     Function length threshold (default: 100)
  COMPLEXITY_FILE_VIOLATION_THRESHOLD Min violations per file (default: 1)
  COMPLEXITY_MD_MIN_LINES            Min lines for .md files (default: 50)
  COMPLEXITY_NESTING_DEPTH_THRESHOLD Max nesting depth (default: 8)
  SWEEP_STALL_HOURS                  Hours before LLM sweep triggers (default: 6)
HELP
	return 0
}

#######################################
# Main dispatch
#######################################
main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	scan) cmd_scan "$@" ;;
	sweep-check) cmd_sweep_check "$@" ;;
	sweep-done) cmd_sweep_done ;;
	metrics) cmd_metrics "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		_log "ERROR" "Unknown command: $cmd"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
