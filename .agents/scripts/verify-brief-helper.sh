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
  verify <path>   Run all method:bash verify blocks from the brief
  list   <path>   List verify blocks without executing
  help             Show this help
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
				local run_value=""
				run_value=$(echo "$block_content" | { grep '^\s*run:' || true; } | head -1 | sed 's/^\s*run:\s*//' | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/" | sed 's/\\"/"/g')

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
		_log "ERROR" "Brief not found: $brief_path"
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
		_log "ERROR" "Brief not found: $brief_path"
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
# Main
# ---------------------------------------------------------------------------

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	verify)
		if [[ $# -lt 1 ]]; then
			_log "ERROR" "Missing brief path. Usage: verify-brief-helper.sh verify <path>"
			return 2
		fi
		_cmd_verify "$1"
		;;
	list)
		if [[ $# -lt 1 ]]; then
			_log "ERROR" "Missing brief path. Usage: verify-brief-helper.sh list <path>"
			return 2
		fi
		_cmd_list "$1"
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
