#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Local Linters — Ratchet Quality Check Sub-Library
# =============================================================================
# Ratchet system extracted from linters-local.sh (GH#21418).
# Tracks anti-pattern counts against a stored baseline. Counts can only stay
# the same or decrease — never increase. Prevents gradual quality regression
# without requiring zero violations immediately.
#
# Baseline: .agents/configs/ratchets.json
# Exceptions: .agents/configs/ratchet-exceptions/{pattern}.txt
#
# Usage: source "${SCRIPT_DIR}/linters-local-ratchet.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#   - ALL_SH_FILES array (populated by collect_shell_files in linters-local.sh)
#   - rg (ripgrep), jq
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LINTERS_LOCAL_RATCHET_LOADED:-}" ]] && return 0
_LINTERS_LOCAL_RATCHET_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Ratchet Quality Check (t1878)
# =============================================================================
# Tracks anti-pattern counts against a stored baseline. Counts can only stay
# the same or decrease — never increase. Prevents gradual quality regression
# without requiring zero violations immediately.
#
# Usage:
#   linters-local.sh                  # advisory ratchet check
#   linters-local.sh --strict         # blocking ratchet check
#   linters-local.sh --update-baseline # re-count and write new baseline

# _ratchet_count_bare_positional: count $1-$9 in function bodies (not local assignments)
# Returns: count via stdout
_ratchet_count_bare_positional() {
	local scripts_dir="$1"
	local count=0
	count=$(rg '\$[1-9]' --type sh "$scripts_dir" 2>/dev/null |
		grep -v 'local.*=.*\$[1-9]' |
		grep -cv '^\s*#') || count=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	echo "$count"
	return 0
}

# _ratchet_count_hardcoded_path: count literal ~/.aidevops or /Users/ in scripts
# Returns: count via stdout
_ratchet_count_hardcoded_path() {
	local scripts_dir="$1"
	local count=0
	# Tilde is intentional: we search for the literal string ~/.aidevops in scripts
	# shellcheck disable=SC2088
	count=$(rg '~/.aidevops|/Users/' --type sh "$scripts_dir" 2>/dev/null |
		grep -v '^\s*#' |
		grep -cv '# ') || count=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	echo "$count"
	return 0
}

# _ratchet_count_broad_catch: count || true usage
# Returns: count via stdout
_ratchet_count_broad_catch() {
	local scripts_dir="$1"
	local count=0
	count=$(rg '\|\| true' --type sh "$scripts_dir" 2>/dev/null |
		wc -l | tr -d '[:space:]') || count=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	echo "$count"
	return 0
}

# _ratchet_count_silent_errors: count 2>/dev/null usage
# Returns: count via stdout
_ratchet_count_silent_errors() {
	local scripts_dir="$1"
	local count=0
	count=$(rg '2>/dev/null' --type sh "$scripts_dir" 2>/dev/null |
		wc -l | tr -d '[:space:]') || count=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	echo "$count"
	return 0
}

# _ratchet_count_missing_return: count files with functions but fewer return statements
# Returns: count via stdout
_ratchet_count_missing_return() {
	local missing_files=0
	local file funcs returns
	for file in "${ALL_SH_FILES[@]}"; do
		[[ -f "$file" ]] || continue
		funcs=$(safe_grep_count "^[a-zA-Z_][a-zA-Z0-9_]*() {$" "$file")
		returns=$(grep -cE "return [0-9]+|return \\\$" "$file" 2>/dev/null || echo "0")
		funcs=$(echo "$funcs" | tr -d '[:space:]')
		returns=$(echo "$returns" | tr -d '[:space:]')
		[[ "$funcs" =~ ^[0-9]+$ ]] || funcs=0
		[[ "$returns" =~ ^[0-9]+$ ]] || returns=0
		if [[ "$returns" -lt "$funcs" ]]; then
			missing_files=$((missing_files + 1))
		fi
	done
	echo "$missing_files"
	return 0
}

# _ratchet_load_exceptions: count non-comment lines in an exceptions file
# Arguments: $1=exceptions_file
# Returns: exception count via stdout
_ratchet_load_exceptions() {
	local exceptions_file="$1"
	local count=0
	if [[ -f "$exceptions_file" ]]; then
		count=$(grep -cv '^[[:space:]]*#\|^[[:space:]]*$' "$exceptions_file" 2>/dev/null || echo "0")
		[[ "$count" =~ ^[0-9]+$ ]] || count=0
	fi
	echo "$count"
	return 0
}

# _ratchet_check_pattern: compare current count against baseline for one pattern
# Arguments: $1=name $2=current $3=baseline $4=exceptions $5=strict_mode
# Returns: 0=pass, 1=regressed
_ratchet_check_pattern() {
	local name="$1"
	local current="$2"
	local baseline="$3"
	local exceptions="$4"
	local strict_mode="$5"

	local effective_current=$((current - exceptions))
	local effective_baseline=$((baseline - exceptions))
	[[ "$effective_current" -lt 0 ]] && effective_current=0
	[[ "$effective_baseline" -lt 0 ]] && effective_baseline=0

	if [[ "$effective_current" -lt "$effective_baseline" ]]; then
		local improvement=$((effective_baseline - effective_current))
		print_success "  PASS: ${name} ${effective_baseline} -> ${effective_current} (improved by ${improvement})"
		return 0
	elif [[ "$effective_current" -eq "$effective_baseline" ]]; then
		print_success "  PASS: ${name} ${effective_current} (no change)"
		return 0
	else
		local regression=$((effective_current - effective_baseline))
		if [[ "$strict_mode" == "true" ]]; then
			print_error "  FAIL: ${name} ${effective_baseline} -> ${effective_current} (regressed by ${regression}) — run --update-baseline after fixing"
		else
			print_warning "  WARN: ${name} ${effective_baseline} -> ${effective_current} (regressed by ${regression}) — advisory only (use --strict to block)"
		fi
		return 1
	fi
}

# _ratchet_count_all: count current values for all 5 ratchet patterns
# Arguments: $1=scripts_dir
# Outputs: 5 space-separated counts: bare hardcoded broad silent missing
# Returns: 0 always
_ratchet_count_all() {
	local scripts_dir="$1"
	local count_bare count_hardcoded count_broad count_silent count_missing
	count_bare=$(_ratchet_count_bare_positional "$scripts_dir")
	count_hardcoded=$(_ratchet_count_hardcoded_path "$scripts_dir")
	count_broad=$(_ratchet_count_broad_catch "$scripts_dir")
	count_silent=$(_ratchet_count_silent_errors "$scripts_dir")
	count_missing=$(_ratchet_count_missing_return)
	echo "$count_bare $count_hardcoded $count_broad $count_silent $count_missing"
	return 0
}

# _ratchet_write_baseline: build and write (or dry-run) a new baseline JSON file
# Arguments: $1=baseline_file $2=count_bare $3=count_hardcoded $4=count_broad $5=count_silent $6=count_missing
# Returns: 0 on success, 1 on jq failure
_ratchet_write_baseline() {
	local baseline_file="$1"
	local count_bare="$2"
	local count_hardcoded="$3"
	local count_broad="$4"
	local count_silent="$5"
	local count_missing="$6"

	local now
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	local new_json
	new_json=$(jq -n \
		--arg updated "$now" \
		--argjson bare "$count_bare" \
		--argjson hardcoded "$count_hardcoded" \
		--argjson broad "$count_broad" \
		--argjson silent "$count_silent" \
		--argjson missing "$count_missing" \
		'{
			version: 1,
			updated: $updated,
			description: "Ratchet baselines for code quality regression prevention. Counts can only stay the same or decrease — never increase. Run linters-local.sh --update-baseline to lock in improvements.",
			ratchets: {
				bare_positional_params: {
					count: $bare,
					description: "$1/$2 etc. used directly in function bodies (should use local var=\"$1\")",
					pattern: "\\$[1-9]",
					exclude: "local.*=.*\\$[1-9]"
				},
				hardcoded_aidevops_path: {
					count: $hardcoded,
					description: "Literal ~/.aidevops or /Users/ instead of \${HOME}/.aidevops or variable",
					pattern: "~/.aidevops|/Users/"
				},
				broad_catch_or_true: {
					count: $broad,
					description: "|| true used to suppress errors without specific handling",
					pattern: "\\|\\| true"
				},
				silent_errors: {
					count: $silent,
					description: "2>/dev/null used to silently discard errors without handling",
					pattern: "2>/dev/null"
				},
				missing_return_files: {
					count: $missing,
					description: "Files containing functions without explicit return 0 or return 1",
					pattern: "functions_without_return"
				}
			}
		}') || {
		print_error "Ratchets: failed to generate baseline JSON"
		return 1
	}

	if [[ "${RATCHET_DRY_RUN:-false}" == "true" ]]; then
		print_info "Ratchets: --dry-run mode, would write baseline:"
		echo "$new_json" | jq '.ratchets | to_entries[] | "  \(.key): \(.value.count)"' -r
		return 0
	fi

	echo "$new_json" >"$baseline_file"
	print_success "Ratchets: baseline updated in $baseline_file"
	echo "$new_json" | jq '.ratchets | to_entries[] | "  \(.key): \(.value.count)"' -r
	return 0
}

# _ratchet_load_baselines: read 5 baseline counts from the JSON baseline file
# Arguments: $1=baseline_file
# Outputs: 5 space-separated counts: bare hardcoded broad silent missing
# Returns: 0 always
_ratchet_load_baselines() {
	local baseline_file="$1"
	local baseline_bare baseline_hardcoded baseline_broad baseline_silent baseline_missing
	baseline_bare=$(jq -r '.ratchets.bare_positional_params.count // 0' "$baseline_file" 2>/dev/null) || baseline_bare=0
	baseline_hardcoded=$(jq -r '.ratchets.hardcoded_aidevops_path.count // 0' "$baseline_file" 2>/dev/null) || baseline_hardcoded=0
	baseline_broad=$(jq -r '.ratchets.broad_catch_or_true.count // 0' "$baseline_file" 2>/dev/null) || baseline_broad=0
	baseline_silent=$(jq -r '.ratchets.silent_errors.count // 0' "$baseline_file" 2>/dev/null) || baseline_silent=0
	baseline_missing=$(jq -r '.ratchets.missing_return_files.count // 0' "$baseline_file" 2>/dev/null) || baseline_missing=0
	echo "$baseline_bare $baseline_hardcoded $baseline_broad $baseline_silent $baseline_missing"
	return 0
}

# _ratchet_load_all_exceptions: load exception counts for all 5 patterns
# Arguments: $1=exceptions_dir
# Outputs: 5 space-separated exception counts: bare hardcoded broad silent missing
# Returns: 0 always
_ratchet_load_all_exceptions() {
	local exceptions_dir="$1"
	local exc_bare exc_hardcoded exc_broad exc_silent exc_missing
	exc_bare=$(_ratchet_load_exceptions "${exceptions_dir}/bare_positional_params.txt")
	exc_hardcoded=$(_ratchet_load_exceptions "${exceptions_dir}/hardcoded_aidevops_path.txt")
	exc_broad=$(_ratchet_load_exceptions "${exceptions_dir}/broad_catch_or_true.txt")
	exc_silent=$(_ratchet_load_exceptions "${exceptions_dir}/silent_errors.txt")
	exc_missing=$(_ratchet_load_exceptions "${exceptions_dir}/missing_return_files.txt")
	echo "$exc_bare $exc_hardcoded $exc_broad $exc_silent $exc_missing"
	return 0
}

# _ratchet_run_checks: run all 5 pattern checks and report aggregate result
# Arguments: $1=strict_mode $2=count_bare $3=count_hardcoded $4=count_broad $5=count_silent $6=count_missing
#            $7=baseline_bare $8=baseline_hardcoded $9=baseline_broad $10=baseline_silent $11=baseline_missing
#            $12=exc_bare $13=exc_hardcoded $14=exc_broad $15=exc_silent $16=exc_missing
# Returns: 0 if no regressions (or non-strict), 1 if regressions in strict mode
_ratchet_run_checks() {
	local strict_mode="$1"
	local count_bare="$2" count_hardcoded="$3" count_broad="$4" count_silent="$5" count_missing="$6"
	local baseline_bare="$7" baseline_hardcoded="$8" baseline_broad="$9" baseline_silent="${10}" baseline_missing="${11}"
	local exc_bare="${12}" exc_hardcoded="${13}" exc_broad="${14}" exc_silent="${15}" exc_missing="${16}"
	local ratchet_failures=0

	_ratchet_check_pattern "bare_positional_params" "$count_bare" "$baseline_bare" "$exc_bare" "$strict_mode" || ratchet_failures=$((ratchet_failures + 1))
	_ratchet_check_pattern "hardcoded_aidevops_path" "$count_hardcoded" "$baseline_hardcoded" "$exc_hardcoded" "$strict_mode" || ratchet_failures=$((ratchet_failures + 1))
	_ratchet_check_pattern "broad_catch_or_true" "$count_broad" "$baseline_broad" "$exc_broad" "$strict_mode" || ratchet_failures=$((ratchet_failures + 1))
	_ratchet_check_pattern "silent_errors" "$count_silent" "$baseline_silent" "$exc_silent" "$strict_mode" || ratchet_failures=$((ratchet_failures + 1))
	_ratchet_check_pattern "missing_return_files" "$count_missing" "$baseline_missing" "$exc_missing" "$strict_mode" || ratchet_failures=$((ratchet_failures + 1))

	if [[ "$ratchet_failures" -eq 0 ]]; then
		print_success "Ratchets: all 5 patterns passing (no regressions)"
		return 0
	fi

	if [[ "$strict_mode" == "true" ]]; then
		print_error "Ratchets: ${ratchet_failures} pattern(s) regressed — fix violations or run --update-baseline to accept"
		return 1
	fi

	print_warning "Ratchets: ${ratchet_failures} pattern(s) regressed (advisory — use --strict to block, --update-baseline to accept)"
	return 0
}

# check_ratchets: main ratchet check function
# Arguments: none (reads RATCHET_UPDATE_BASELINE and RATCHET_STRICT from env)
# Returns: 0 if all ratchets pass, 1 if any regressed (only blocks in strict mode)
check_ratchets() {
	echo -e "${BLUE}Checking Ratchet Quality Gates (t1878)...${NC}"

	local scripts_dir
	scripts_dir="$(git rev-parse --show-toplevel 2>/dev/null)/.agents/scripts" || scripts_dir=".agents/scripts"
	local baseline_file
	baseline_file="$(git rev-parse --show-toplevel 2>/dev/null)/.agents/configs/ratchets.json" || baseline_file=".agents/configs/ratchets.json"
	local exceptions_dir
	exceptions_dir="$(git rev-parse --show-toplevel 2>/dev/null)/.agents/configs/ratchet-exceptions" || exceptions_dir=".agents/configs/ratchet-exceptions"

	if ! command -v rg &>/dev/null; then
		print_warning "Ratchets: rg (ripgrep) not installed — skipping (install: brew install ripgrep)"
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		print_warning "Ratchets: jq not installed — skipping (install: brew install jq)"
		return 0
	fi

	# Count current values for all patterns
	local counts count_bare count_hardcoded count_broad count_silent count_missing
	counts=$(_ratchet_count_all "$scripts_dir")
	read -r count_bare count_hardcoded count_broad count_silent count_missing <<<"$counts"

	# --update-baseline / --init-baseline: write new baseline and exit
	if [[ "${RATCHET_UPDATE_BASELINE:-false}" == "true" ]]; then
		_ratchet_write_baseline "$baseline_file" "$count_bare" "$count_hardcoded" "$count_broad" "$count_silent" "$count_missing"
		return $?
	fi

	# Check baseline file exists
	if [[ ! -f "$baseline_file" ]]; then
		print_warning "Ratchets: no baseline found at $baseline_file — run --init-baseline to create"
		return 0
	fi

	# Load baselines and exceptions
	local baselines exceptions
	local baseline_bare baseline_hardcoded baseline_broad baseline_silent baseline_missing
	local exc_bare exc_hardcoded exc_broad exc_silent exc_missing
	baselines=$(_ratchet_load_baselines "$baseline_file")
	exceptions=$(_ratchet_load_all_exceptions "$exceptions_dir")
	read -r baseline_bare baseline_hardcoded baseline_broad baseline_silent baseline_missing <<<"$baselines"
	read -r exc_bare exc_hardcoded exc_broad exc_silent exc_missing <<<"$exceptions"

	local strict_mode="${RATCHET_STRICT:-false}"
	_ratchet_run_checks "$strict_mode" \
		"$count_bare" "$count_hardcoded" "$count_broad" "$count_silent" "$count_missing" \
		"$baseline_bare" "$baseline_hardcoded" "$baseline_broad" "$baseline_silent" "$baseline_missing" \
		"$exc_bare" "$exc_hardcoded" "$exc_broad" "$exc_silent" "$exc_missing"
	return $?
}
