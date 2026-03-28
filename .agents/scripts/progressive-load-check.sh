#!/usr/bin/env bash
# =============================================================================
# Progressive Load Safety Check (t1679.6)
# =============================================================================
# Verifies that every section extracted from build.txt/AGENTS.md to a
# reference/ file has:
#   1. An inline trigger (pointer comment) in the source prompt file
#   2. The reference file present in .agents/reference/
#
# Run after any progressive-load refactor to catch regressions before deploy.
#
# Usage: ./progressive-load-check.sh [--quiet]
# Exit codes: 0 = all checks pass, 1 = regression detected, 2 = check error
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
AGENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" || exit 2
BUILD_TXT="$AGENTS_DIR/prompts/build.txt"
AGENTS_MD="$AGENTS_DIR/AGENTS.md"
REFERENCE_DIR="$AGENTS_DIR/reference"

QUIET="${1:-}"
PASS=0
FAIL=0

log_pass() {
	local msg="$1"
	PASS=$((PASS + 1))
	[[ "$QUIET" == "--quiet" ]] && return 0
	printf "  PASS  %s\n" "$msg"
	return 0
}

log_fail() {
	local msg="$1"
	FAIL=$((FAIL + 1))
	printf "  FAIL  %s\n" "$msg"
	return 0
}

log_info() {
	local msg="$1"
	[[ "$QUIET" == "--quiet" ]] && return 0
	printf "  INFO  %s\n" "$msg"
	return 0
}

check_extraction() {
	local section="$1"
	local source_file="$2"
	local ref_file="$3"
	local pointer_pattern="$4"

	[[ "$QUIET" != "--quiet" ]] && printf "\n[%s]\n" "$section"

	# Check 1: reference file exists
	local ref_path="$REFERENCE_DIR/$ref_file"
	if [[ -f "$ref_path" ]]; then
		log_pass "reference file exists: reference/$ref_file"
	else
		log_fail "reference file MISSING: reference/$ref_file"
		return 0
	fi

	# Check 2: inline trigger exists in source file
	if grep -qE "$pointer_pattern" "$source_file" 2>/dev/null; then
		log_pass "inline trigger found in $(basename "$source_file")"
	else
		log_fail "inline trigger MISSING in $(basename "$source_file") (pattern: $pointer_pattern)"
	fi

	return 0
}

check_inline_only() {
	local section="$1"
	local source_file="$2"
	local inline_pattern="$3"

	[[ "$QUIET" != "--quiet" ]] && printf "\n[%s]\n" "$section"

	# Use grep -q to avoid the grep -c exit-1-on-no-match bug where
	# "count=$(grep -c ... || echo 0)" produces "0\n0" (two lines).
	local match_count=0
	if grep -qE "$inline_pattern" "$source_file" 2>/dev/null; then
		match_count=$(grep -cE "$inline_pattern" "$source_file" 2>/dev/null)
		log_info "still inline ($match_count matching lines) — no extraction yet"
	else
		log_fail "section appears missing from $(basename "$source_file") (pattern: $inline_pattern)"
	fi

	return 0
}

check_build_txt_extractions() {
	[[ "$QUIET" != "--quiet" ]] && printf "\n--- build.txt extractions ---"

	check_extraction \
		"Screenshot Size Limits" \
		"$BUILD_TXT" \
		"screenshot-limits.md" \
		"reference/screenshot-limits\.md"

	# Secret Handling (8.1-8.4): extracted to reference/secret-handling.md by t1679.5.
	# Inline trigger (pointer comment) retained in build.txt; full rules in reference file.
	check_extraction \
		"Secret Handling (8.1-8.4)" \
		"$BUILD_TXT" \
		"secret-handling.md" \
		"reference/secret-handling\.md"

	check_extraction \
		"External Repo Issue/PR Submission" \
		"$BUILD_TXT" \
		"external-repo-submissions.md" \
		"reference/external-repo-submissions\.md"

	# Bash 3.2 Compatibility: reference file is a supplement; inline content kept in build.txt
	check_inline_only \
		"Bash 3.2 Compatibility — inline + reference/bash-compat.md supplement" \
		"$BUILD_TXT" \
		"Bash 3\.2 Compatibility|bash 3\.2"

	check_extraction \
		"Conversational Memory Lookup" \
		"$BUILD_TXT" \
		"memory-lookup.md" \
		"reference/memory-lookup\.md"

	# Sections still inline (not yet extracted) — verify they haven't been lost
	check_inline_only \
		"Parallel Model Verification (still inline)" \
		"$BUILD_TXT" \
		"verify-operation-helper\.sh|check_operation"

	check_inline_only \
		"Tamper-Evident Audit Logging (still inline)" \
		"$BUILD_TXT" \
		"audit-log-helper\.sh"

	check_inline_only \
		"Review Bot Gate (still inline)" \
		"$BUILD_TXT" \
		"review-bot-gate-helper\.sh"

	return 0
}

check_agents_md_extractions() {
	[[ "$QUIET" != "--quiet" ]] && printf "\n--- AGENTS.md extractions ---"

	check_extraction \
		"Domain Index" \
		"$AGENTS_MD" \
		"domain-index.md" \
		"reference/domain-index\.md"

	# Self-Improvement: reference file is a supplement; inline content kept in AGENTS.md
	check_inline_only \
		"Self-Improvement — inline + reference/self-improvement.md supplement" \
		"$AGENTS_MD" \
		"## Self-Improvement|framework-issue-helper\.sh"

	# Agent Routing: reference file is a supplement; inline content kept in AGENTS.md
	check_inline_only \
		"Agent Routing — inline + reference/agent-routing.md supplement" \
		"$AGENTS_MD" \
		"## Agent Routing|headless-runtime-helper\.sh"

	return 0
}

print_summary() {
	printf "\n"
	if [[ "$FAIL" -eq 0 ]]; then
		printf "RESULT: PASS (%d checks passed, 0 failures)\n" "$PASS"
		return 0
	else
		printf "RESULT: FAIL (%d passed, %d failed)\n" "$PASS" "$FAIL"
		return 1
	fi
}

main() {
	if [[ ! -f "$BUILD_TXT" ]]; then
		printf "ERROR: build.txt not found at %s\n" "$BUILD_TXT" >&2
		return 2
	fi

	if [[ ! -f "$AGENTS_MD" ]]; then
		printf "ERROR: AGENTS.md not found at %s\n" "$AGENTS_MD" >&2
		return 2
	fi

	[[ "$QUIET" != "--quiet" ]] && printf "Progressive Load Safety Check\n"
	[[ "$QUIET" != "--quiet" ]] && printf "Source: %s\n" "$AGENTS_DIR"

	check_build_txt_extractions
	check_agents_md_extractions
	print_summary
}

main "$@"
