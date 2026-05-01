#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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
PROMPT_HOOK_REGISTRY="$AGENTS_DIR/configs/prompt-hook-candidates.conf"

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

trim_field() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf "%s" "$value"
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

check_framework_rules_extractions() {
	# Post-t2878: build.txt was consolidated into AGENTS.md "Framework Rules".
	# All checks below now run against AGENTS.md instead of build.txt.
	[[ "$QUIET" != "--quiet" ]] && printf "\n--- AGENTS.md Framework Rules extractions ---\n"

	check_extraction \
		"Screenshot Size Limits" \
		"$AGENTS_MD" \
		"screenshot-limits.md" \
		"reference/screenshot-limits\.md"

	# Secret Handling (8.1-8.4): extracted to reference/secret-handling.md by t1679.5.
	# Inline trigger (pointer comment) retained in AGENTS.md; full rules in reference file.
	check_extraction \
		"Secret Handling (8.1-8.4)" \
		"$AGENTS_MD" \
		"secret-handling.md" \
		"reference/secret-handling\.md"

	check_extraction \
		"External Repo Issue/PR Submission" \
		"$AGENTS_MD" \
		"external-repo-submissions.md" \
		"reference/external-repo-submissions\.md"

	# Bash 3.2 Compatibility: reference file is a supplement; inline content kept in AGENTS.md
	check_inline_only \
		"Bash 3.2 Compatibility — inline + reference/bash-compat.md supplement" \
		"$AGENTS_MD" \
		"Bash 3\.2 Compatibility|bash 3\.2"

	check_extraction \
		"Conversational Memory Lookup" \
		"$AGENTS_MD" \
		"memory-lookup.md" \
		"reference/memory-lookup\.md"

	# Sections still inline (not yet extracted) — verify they haven't been lost
	check_inline_only \
		"Parallel Model Verification (still inline)" \
		"$AGENTS_MD" \
		"verify-operation-helper\.sh|check_operation"

	check_inline_only \
		"Tamper-Evident Audit Logging (still inline)" \
		"$AGENTS_MD" \
		"audit-log-helper\.sh"

	check_inline_only \
		"Review Bot Gate (still inline)" \
		"$AGENTS_MD" \
		"review-bot-gate-helper\.sh"

	return 0
}

check_agents_md_extractions() {
	[[ "$QUIET" != "--quiet" ]] && printf "\n--- AGENTS.md extractions ---\n"

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

	check_extraction \
		"Agent Routing" \
		"$AGENTS_MD" \
		"agent-routing.md" \
		"reference/agent-routing\.md"

	return 0
}

check_prompt_hook_registry() {
	[[ "$QUIET" != "--quiet" ]] && printf "\n--- Prompt-to-hook migration registry ---\n"

	if [[ ! -f "$PROMPT_HOOK_REGISTRY" ]]; then
		log_fail "prompt-hook registry MISSING: configs/prompt-hook-candidates.conf"
		return 0
	fi

	log_pass "prompt-hook registry exists: configs/prompt-hook-candidates.conf"

	local records=0
	local deterministic=0
	local hooked=0
	local line_no=0
	local raw_line section class enforcement status inline_budget reference notes extra

	while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
		line_no=$((line_no + 1))
		[[ -z "$raw_line" || "$raw_line" == \#* ]] && continue

		IFS='|' read -r section class enforcement status inline_budget reference notes extra <<EOF_REGISTRY
$raw_line
EOF_REGISTRY

		section=$(trim_field "${section:-}")
		class=$(trim_field "${class:-}")
		enforcement=$(trim_field "${enforcement:-}")
		status=$(trim_field "${status:-}")
		inline_budget=$(trim_field "${inline_budget:-}")
		reference=$(trim_field "${reference:-}")
		notes=$(trim_field "${notes:-}")
		extra=$(trim_field "${extra:-}")

		if [[ -n "$extra" || -z "$section" || -z "$class" || -z "$enforcement" || -z "$status" || -z "$inline_budget" || -z "$reference" ]]; then
			log_fail "prompt-hook registry line ${line_no}: expected 7 pipe-separated fields"
			continue
		fi

		case "$class" in
		deterministic | hybrid | security | judgment) ;;
		*)
			log_fail "prompt-hook registry line ${line_no}: invalid class '${class}'"
			continue
			;;
		esac

		case "$status" in
		hooked | partial | candidate | prompt-only) ;;
		*)
			log_fail "prompt-hook registry line ${line_no}: invalid status '${status}'"
			continue
			;;
		esac

		records=$((records + 1))
		if [[ "$class" == "deterministic" || "$class" == "hybrid" ]]; then
			deterministic=$((deterministic + 1))
			if [[ "$enforcement" == "none" ]]; then
				log_fail "prompt-hook registry line ${line_no}: ${class} rule lacks hook/check plan"
			fi
		fi

		[[ "$status" == "hooked" ]] && hooked=$((hooked + 1))
	done <"$PROMPT_HOOK_REGISTRY"

	if [[ "$records" -gt 0 ]]; then
		log_pass "prompt-hook registry has ${records} tracked rules"
	else
		log_fail "prompt-hook registry has no rule records"
	fi

	if [[ "$deterministic" -gt 0 ]]; then
		log_pass "prompt-hook registry tracks ${deterministic} deterministic/hybrid rules"
	else
		log_fail "prompt-hook registry tracks no deterministic/hybrid rules"
	fi

	if [[ "$hooked" -gt 0 ]]; then
		log_pass "prompt-hook registry includes ${hooked} hooked rules"
	else
		log_fail "prompt-hook registry includes no hooked rules"
	fi

	if grep -qF "configs/prompt-hook-candidates.conf" "$AGENTS_MD" 2>/dev/null; then
		log_pass "AGENTS.md points to prompt-hook registry"
	else
		log_fail "AGENTS.md missing pointer to configs/prompt-hook-candidates.conf"
	fi

	if grep -qF "Prompt-to-Hook Migration" "$REFERENCE_DIR/progressive-disclosure.md" 2>/dev/null; then
		log_pass "progressive-disclosure reference documents prompt-to-hook migration"
	else
		log_fail "progressive-disclosure reference missing prompt-to-hook migration section"
	fi

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
	if [[ ! -f "$AGENTS_MD" ]]; then
		printf "ERROR: AGENTS.md not found at %s\n" "$AGENTS_MD" >&2
		return 2
	fi

	# build.txt is a placeholder post-t2878 — its presence still required for
	# the OpenCode {file:...} injection channel to remain a valid no-op.
	if [[ ! -f "$BUILD_TXT" ]]; then
		printf "ERROR: build.txt placeholder not found at %s\n" "$BUILD_TXT" >&2
		return 2
	fi

	[[ "$QUIET" != "--quiet" ]] && printf "Progressive Load Safety Check\n"
	[[ "$QUIET" != "--quiet" ]] && printf "Source: %s\n" "$AGENTS_DIR"

	check_framework_rules_extractions
	check_agents_md_extractions
	check_prompt_hook_registry
	if print_summary; then
		return 0
	fi
	return 1
}

main "$@"
