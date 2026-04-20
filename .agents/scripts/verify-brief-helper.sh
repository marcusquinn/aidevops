#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# verify-brief-helper.sh — Parse and run verify: blocks from task briefs
#
# Usage:
#   verify-brief-helper.sh verify <brief-path>   Run all method:bash verify blocks
#   verify-brief-helper.sh list   <brief-path>   List verify blocks without running
#   verify-brief-helper.sh help                   Show usage
#
# Exit codes:
#   0 — all bash verify blocks passed (or no blocks found)
#   1 — one or more bash verify blocks failed
#   2 — usage error (missing args, file not found)

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_usage() {
	cat <<'EOF'
Usage: verify-brief-helper.sh <command> [brief-path]

Commands:
  verify          <path>   Run all method:bash verify blocks from the brief
  list            <path>   List verify blocks without executing
  check-preflight <path>   Validate Pre-flight block presence and completeness
  help                     Show this help
EOF
	return 0
}

_log() {
	local level="$1"
	shift
	local msg="$*"
	printf '[%s] %s\n' "$level" "$msg" >&2
	return 0
}

_ERR_BRIEF_NOT_FOUND="Brief not found:"

# ---------------------------------------------------------------------------
# Parse verify blocks from a brief markdown file
#
# Extracts fenced yaml code blocks that contain a verify: key.
# Output: one record per block on stdout, fields tab-separated:
#   <index>\t<method>\t<run_or_prompt>
#
# method is "bash" or "manual"; run_or_prompt is the run: or prompt: value.
# ---------------------------------------------------------------------------
_parse_verify_blocks() {
	local brief_path="$1"
	local in_yaml_block=0
	local block_content=""
	local block_index=0

	while IFS= read -r line; do
		# Detect start of a yaml fenced block
		if [[ $in_yaml_block -eq 0 ]] && echo "$line" | grep -qE '^\s*```ya?ml\s*$'; then
			in_yaml_block=1
			block_content=""
			continue
		fi

		# Detect end of fenced block
		if [[ $in_yaml_block -eq 1 ]] && echo "$line" | grep -qE '^\s*```\s*$'; then
			in_yaml_block=0

			# Check if block contains verify:
			if echo "$block_content" | grep -q 'verify:'; then
				block_index=$((block_index + 1))

				# Extract method (|| true guards against set -e in process substitution)
				local method=""
				method=$(echo "$block_content" | grep -oE 'method:\s*\S+' | head -1 | sed 's/method:\s*//' || true)

				# Extract run: value (everything after run: with surrounding quotes stripped)
				# Handles inline strings and YAML block scalars (| or >)
				local run_value=""
				local run_line=""
				run_line=$(echo "$block_content" | { grep '^\s*run:' || true; } | head -1)
				if [[ -n "$run_line" ]]; then
					local raw_value=""
					raw_value=$(echo "$run_line" | sed 's/^\s*run:\s*//')
					# Detect YAML block scalar indicators (| or >)
					if [[ "$raw_value" == "|" || "$raw_value" == ">" || "$raw_value" == "|-" || "$raw_value" == ">-" ]]; then
						# Collect indented continuation lines after run:
						# Join with "; " to produce a single-line bash command
						local collecting=0
						local multiline=""
						while IFS= read -r bline; do
							if [[ $collecting -eq 1 ]]; then
								if echo "$bline" | grep -qE '^\s+'; then
									# Strip common leading whitespace (up to 6 spaces)
									local stripped=""
									stripped=$(echo "$bline" | sed 's/^\s\{1,6\}//')
									if [[ -n "$stripped" ]]; then
										if [[ -n "$multiline" ]]; then
											multiline="${multiline}; ${stripped}"
										else
											multiline="$stripped"
										fi
									fi
								else
									break
								fi
							fi
							if echo "$bline" | grep -qE '^\s*run:'; then
								collecting=1
							fi
						done <<<"$block_content"
						run_value="$multiline"
					else
						# Inline value — strip surrounding quotes and unescape
						run_value=$(echo "$raw_value" | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/" | sed 's/\\"/"/g')
					fi
				fi

				# Extract prompt: value (for manual blocks)
				local prompt_value=""
				prompt_value=$(echo "$block_content" | { grep '^\s*prompt:' || true; } | head -1 | sed 's/^\s*prompt:\s*//' | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")

				local value="$run_value"
				if [[ -z "$value" ]]; then
					value="$prompt_value"
				fi

				printf '%d\t%s\t%s\n' "$block_index" "$method" "$value"
			fi
			continue
		fi

		# Accumulate content inside yaml block
		if [[ $in_yaml_block -eq 1 ]]; then
			block_content="${block_content}${line}
"
		fi
	done <"$brief_path"

	return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

_cmd_list() {
	local brief_path="$1"

	if [[ ! -f "$brief_path" ]]; then
		_log "ERROR" "$_ERR_BRIEF_NOT_FOUND $brief_path"
		return 2
	fi

	local found=0
	while IFS=$'\t' read -r idx method value; do
		found=1
		printf 'Block %d: method=%s\n' "$idx" "$method"
		if [[ "$method" == "bash" ]]; then
			printf '  run: %s\n' "$value"
		elif [[ "$method" == "manual" ]]; then
			printf '  prompt: %s\n' "$value"
		fi
	done < <(_parse_verify_blocks "$brief_path")

	if [[ $found -eq 0 ]]; then
		_log "INFO" "No verify: blocks found in $brief_path"
	fi

	return 0
}

_cmd_verify() {
	local brief_path="$1"

	if [[ ! -f "$brief_path" ]]; then
		_log "ERROR" "$_ERR_BRIEF_NOT_FOUND $brief_path"
		return 2
	fi

	local total=0
	local passed=0
	local failed=0
	local skipped=0
	local fail_details=""

	while IFS=$'\t' read -r idx method value; do
		total=$((total + 1))

		if [[ "$method" == "manual" ]]; then
			skipped=$((skipped + 1))
			printf 'SKIP  [%d] (manual) %s\n' "$idx" "$value"
			continue
		fi

		if [[ "$method" != "bash" ]]; then
			skipped=$((skipped + 1))
			printf 'SKIP  [%d] (unknown method: %s)\n' "$idx" "$method"
			continue
		fi

		if [[ -z "$value" ]]; then
			skipped=$((skipped + 1))
			printf 'SKIP  [%d] (empty run command)\n' "$idx"
			continue
		fi

		printf 'RUN   [%d] %s\n' "$idx" "$value"

		# Execute with timeout; capture output and exit code
		local exit_code=0
		local output=""
		output=$(timeout 120 bash -c "$value" 2>&1) || exit_code=$?

		if [[ $exit_code -eq 0 ]]; then
			passed=$((passed + 1))
			printf 'PASS  [%d]\n' "$idx"
		else
			failed=$((failed + 1))
			printf 'FAIL  [%d] exit_code=%d\n' "$idx" "$exit_code"
			if [[ -n "$output" ]]; then
				printf '  output: %s\n' "$output"
			fi
			fail_details="${fail_details}Block ${idx} (exit ${exit_code}): ${value}\n"
		fi
	done < <(_parse_verify_blocks "$brief_path")

	# Summary
	printf '\n--- Summary ---\n'
	printf 'Total: %d  Passed: %d  Failed: %d  Skipped: %d\n' "$total" "$passed" "$failed" "$skipped"

	if [[ $total -eq 0 ]]; then
		_log "INFO" "No verify: blocks found — nothing to check"
		return 0
	fi

	if [[ $failed -gt 0 ]]; then
		printf '\nFailed blocks:\n'
		printf '%b' "$fail_details"
		return 1
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Pre-flight validation
# ---------------------------------------------------------------------------

_cmd_check_preflight() {
	local brief_path="$1"

	if [[ ! -f "$brief_path" ]]; then
		_log "ERROR" "$_ERR_BRIEF_NOT_FOUND $brief_path"
		return 2
	fi

	local in_preflight=0
	local found_section=0
	local total_boxes=0
	local populated_count=0
	local placeholder_count=0
	local has_memory=0
	local has_discovery=0
	local has_filerefs=0
	local has_tier=0

	while IFS= read -r line; do
		# Detect Pre-flight section
		if echo "$line" | grep -qE '^##[[:space:]]+Pre-flight'; then
			in_preflight=1
			found_section=1
			continue
		fi

		# Detect next section
		if [[ $in_preflight -eq 1 ]] && echo "$line" | grep -qE '^##[[:space:]]' && ! echo "$line" | grep -qE 'Pre-flight'; then
			break
		fi

		[[ $in_preflight -eq 0 ]] && continue

		# Skip HTML comments
		echo "$line" | grep -qE '^\s*<!--' && continue

		# Detect checkbox lines
		if echo "$line" | grep -qE '^\s*-\s+\[[[:space:]x]\]'; then
			total_boxes=$((total_boxes + 1))

			if echo "$line" | grep -qiE 'Memory[[:space:]]+recall'; then
				has_memory=1
				if echo "$line" | grep -qE '<query>|<N>[[:space:]]hits'; then
					placeholder_count=$((placeholder_count + 1))
				else
					populated_count=$((populated_count + 1))
				fi
			elif echo "$line" | grep -qiE 'Discovery[[:space:]]+pass'; then
				has_discovery=1
				if echo "$line" | grep -qE '<N>[[:space:]]commits|<date>'; then
					placeholder_count=$((placeholder_count + 1))
				else
					populated_count=$((populated_count + 1))
				fi
			elif echo "$line" | grep -qiE 'File[[:space:]]+refs'; then
				has_filerefs=1
				if echo "$line" | grep -qE '<N>[[:space:]]refs[[:space:]]checked'; then
					placeholder_count=$((placeholder_count + 1))
				else
					populated_count=$((populated_count + 1))
				fi
			elif echo "$line" | grep -qiE '^[[:space:]]*-[[:space:]]+\[[[:space:]x]\][[:space:]]+Tier:'; then
				has_tier=1
				if echo "$line" | grep -qE '<tier>'; then
					placeholder_count=$((placeholder_count + 1))
				else
					populated_count=$((populated_count + 1))
				fi
			fi
		fi
	done <"$brief_path"

	if [[ $found_section -eq 0 ]]; then
		printf 'FAIL  Pre-flight section missing from brief\n'
		return 1
	fi

	local missing=""
	[[ $has_memory -eq 0 ]] && missing="${missing}memory recall, "
	[[ $has_discovery -eq 0 ]] && missing="${missing}discovery pass, "
	[[ $has_filerefs -eq 0 ]] && missing="${missing}file refs, "
	[[ $has_tier -eq 0 ]] && missing="${missing}tier check, "

	if [[ -n "$missing" ]]; then
		missing="${missing%, }"
		printf 'FAIL  Pre-flight missing required items: %s\n' "$missing"
		return 1
	fi

	if [[ $placeholder_count -gt 0 ]]; then
		printf 'FAIL  Pre-flight: %d of %d items still contain placeholder text\n' "$placeholder_count" "$total_boxes"
		return 1
	fi

	printf 'PASS  Pre-flight: %d/%d items populated\n' "$populated_count" "$total_boxes"
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local cmd="${1:-help}"
	shift || true

	local brief_path="${1:-}"

	case "$cmd" in
	verify)
		if [[ -z "$brief_path" ]]; then
			_log "ERROR" "Missing brief path. Usage: verify-brief-helper.sh verify <path>"
			return 2
		fi
		_cmd_verify "$brief_path"
		;;
	list)
		if [[ -z "$brief_path" ]]; then
			_log "ERROR" "Missing brief path. Usage: verify-brief-helper.sh list <path>"
			return 2
		fi
		_cmd_list "$brief_path"
		;;
	check-preflight)
		if [[ -z "$brief_path" ]]; then
			_log "ERROR" "Missing brief path. Usage: verify-brief-helper.sh check-preflight <path>"
			return 2
		fi
		_cmd_check_preflight "$brief_path"
		;;
	help | --help | -h)
		_usage
		;;
	*)
		_log "ERROR" "Unknown command: $cmd"
		_usage
		return 2
		;;
	esac
}

main "$@"
