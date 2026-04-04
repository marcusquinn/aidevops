#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# verify-agent-discoverability.sh — t1680.5
# Verify agent discoverability is not degraded after AGENTS.md progressive-load refactor.
#
# What was refactored (t1679/t1680 series):
#   build.txt: Conversational Memory Lookup, Screenshot Size Limits,
#              External Repo Submission, Bash 3.2 Compat, Secret Handling
#   AGENTS.md: Domain Index (t1680.1), Self-Improvement (t1680.2),
#              Agent Routing (t1680.3), Capabilities (t1680.4)
#   Inline content moved to reference files (on-demand reads):
#              self-improvement.md, agent-routing.md, domain-index.md
#   Supplement reference files (inline content retained in source):
#              audit-logging.md, model-verification.md, review-bot-gate.md,
#              memory-lookup.md, screenshot-limits.md, external-repo-submissions.md,
#              bash-compat.md, secret-handling.md
#
# Discoverability checks:
#   1. All extracted reference files exist and are non-empty
#   2. build.txt has pointers to extracted reference files
#   3. AGENTS.md Domain Index section has pointer to reference/domain-index.md
#   4. reference/domain-index.md exists and has >=30 domain rows
#   5. All 9 primary agent @mention files exist and are non-empty
#   6. Capabilities section retains key capability entries
#   7. Self-Improvement section has pointer to reference/self-improvement.md
#   8. Agent Routing section has pointer to reference/agent-routing.md
#   9. subagent-index.toon TOON block counts are valid (>=9 agents, >=60 subagents)
#  10. Critical scripts for self-improvement workflow are executable
#
# Usage: bash verify-agent-discoverability.sh [--agents-dir <path>]
# Exit: 0 = all checks pass, 1 = one or more failures

set -euo pipefail

AGENTS_DIR="${HOME}/.aidevops/agents"
PASS=0
FAIL=0
WARNINGS=0

# Parse args
while [[ $# -gt 0 ]]; do
	case "$1" in
	--agents-dir)
		AGENTS_DIR="$2"
		shift 2
		;;
	*)
		shift
		;;
	esac
done

log_ok() {
	local msg="$1"
	echo "  [PASS] ${msg}"
	PASS=$((PASS + 1))
	return 0
}

log_fail() {
	local msg="$1"
	echo "  [FAIL] ${msg}" >&2
	FAIL=$((FAIL + 1))
	return 0
}

log_warn() {
	local msg="$1"
	echo "  [WARN] ${msg}"
	WARNINGS=$((WARNINGS + 1))
	return 0
}

check_file_nonempty() {
	local path="$1"
	local min_bytes="${2:-100}"
	local label="$3"
	local full="${AGENTS_DIR}/${path}"
	if [[ ! -f "$full" ]]; then
		log_fail "${label}: ${path} — NOT FOUND"
		return 0
	fi
	local size
	size=$(wc -c <"$full" | tr -d ' ')
	if [[ "$size" -ge "$min_bytes" ]]; then
		log_ok "${label}: ${path} (${size} bytes)"
	else
		log_fail "${label}: ${path} — too small (${size} bytes, expected >=${min_bytes})"
	fi
	return 0
}

# check_string_in_file: grep -F with -- separator to handle strings starting with -
check_string_in_file() {
	local file="$1"
	local needle="$2"
	local label="$3"
	if grep -qF -- "$needle" "${AGENTS_DIR}/${file}" 2>/dev/null; then
		log_ok "${label}"
	else
		log_fail "${label} — '${needle}' not found in ${file}"
	fi
	return 0
}

# ─── Test 1: Extracted reference files exist and are non-empty ───────────────
echo ""
echo "=== 1. Extracted Reference Files ==="
EXTRACTED_REFS=(
	"reference/memory-lookup.md"
	"reference/screenshot-limits.md"
	"reference/external-repo-submissions.md"
	"reference/audit-logging.md"
	"reference/model-verification.md"
	"reference/review-bot-gate.md"
	"reference/self-improvement.md"
	"reference/agent-routing.md"
	"reference/domain-index.md"
)
for ref in "${EXTRACTED_REFS[@]}"; do
	check_file_nonempty "$ref" 100 "Extracted reference"
done

# ─── Test 2: build.txt has pointers to extracted reference files ──────────────
echo ""
echo "=== 2. build.txt Pointers to Extracted References ==="
BUILD_TXT="prompts/build.txt"
BUILD_REFS=(
	"reference/memory-lookup.md"
	"reference/screenshot-limits.md"
	"reference/external-repo-submissions.md"
)
for ref in "${BUILD_REFS[@]}"; do
	check_string_in_file "$BUILD_TXT" "$ref" "build.txt pointer: ${ref}"
done

# ─── Test 3: AGENTS.md Domain Index section has pointer to reference file ─────
echo ""
echo "=== 3. AGENTS.md Domain Index Pointer ==="
check_string_in_file "AGENTS.md" "reference/domain-index.md" "AGENTS.md: Domain Index pointer to reference/domain-index.md"

# ─── Test 4: reference/domain-index.md has >=30 domain rows ──────────────────
echo ""
echo "=== 4. Domain Index Reference File Integrity ==="
DOMAIN_INDEX="${AGENTS_DIR}/reference/domain-index.md"
if [[ ! -f "$DOMAIN_INDEX" ]]; then
	log_fail "reference/domain-index.md not found"
else
	# Count table rows (lines starting with | that aren't header/separator)
	ROW_COUNT=$(grep -c "^|" "$DOMAIN_INDEX" 2>/dev/null || echo "0")
	# Subtract header and separator rows (2 per table)
	DATA_ROWS=$((ROW_COUNT - 2))
	if [[ "$DATA_ROWS" -ge 30 ]]; then
		log_ok "reference/domain-index.md has ${DATA_ROWS} domain rows (expected >=30)"
	else
		log_fail "reference/domain-index.md has only ${DATA_ROWS} domain rows (expected >=30)"
	fi
	check_file_nonempty "reference/domain-index.md" 2000 "Domain index: substantial content"
fi

# ─── Test 5: Primary agent @mention files ─────────────────────────────────────
echo ""
echo "=== 5. Primary Agent @Mention Files ==="
# 9 primary agents as of t1680 refactor (marketing-sales.md consolidates marketing+sales)
AGENT_FILES=(
	"build-plus.md"
	"automate.md"
	"business.md"
	"content.md"
	"health.md"
	"legal.md"
	"marketing-sales.md"
	"research.md"
	"seo.md"
)
for af in "${AGENT_FILES[@]}"; do
	check_file_nonempty "$af" 100 "Primary agent file"
done

# ─── Test 6: Capabilities section retains key entries ─────────────────────────
echo ""
echo "=== 6. Capabilities Section Key Entries ==="
KEY_CAPS=(
	"Model routing"
	"Bundle presets"
	"Memory"
	"Orchestration"
	"Browser"
	"Quality"
	"Sessions"
)
for cap in "${KEY_CAPS[@]}"; do
	check_string_in_file "AGENTS.md" "$cap" "Capabilities: ${cap}"
done

# ─── Test 7: Self-Improvement section has pointer to reference file ───────────
# After t1680.2 refactor: inline content moved to reference/self-improvement.md;
# AGENTS.md retains only the section header + 1-line pointer.
echo ""
echo "=== 7. Self-Improvement Section Key References ==="
check_string_in_file "AGENTS.md" "## Self-Improvement" "AGENTS.md: Self-Improvement section present"
check_string_in_file "AGENTS.md" "reference/self-improvement.md" "AGENTS.md Self-Improvement: pointer to reference/self-improvement.md"
# Verify the reference file has the full content (canonical source after refactor)
check_string_in_file "reference/self-improvement.md" "framework-issue-helper.sh" "reference/self-improvement.md: framework-issue-helper.sh reference"
check_string_in_file "reference/self-improvement.md" "PULSE_SCOPE_REPOS" "reference/self-improvement.md: PULSE_SCOPE_REPOS scope boundary"
check_file_nonempty "reference/self-improvement.md" 2000 "reference/self-improvement.md: substantial content"

# ─── Test 8: Agent Routing section — content accessible (inline or via pointer) ─
# After t1680.3 refactor: inline content moved to reference/agent-routing.md;
# AGENTS.md retains only the section header + 1-line pointer.
# This check passes if either the pointer OR inline content is present in AGENTS.md
# (supports both pre- and post-refactor states during the PR merge window).
echo ""
echo "=== 8. Agent Routing Section Key References ==="
check_string_in_file "AGENTS.md" "## Agent Routing" "AGENTS.md: Agent Routing section present"
# Check that routing content is accessible: either via pointer or inline
AGENTS_MD="${AGENTS_DIR}/AGENTS.md"
if grep -qF "reference/agent-routing.md" "$AGENTS_MD" 2>/dev/null; then
	log_ok "AGENTS.md Agent Routing: pointer to reference/agent-routing.md"
elif grep -qF "headless-runtime-helper.sh" "$AGENTS_MD" 2>/dev/null; then
	log_ok "AGENTS.md Agent Routing: inline headless dispatch reference (pre-refactor state)"
else
	log_fail "AGENTS.md Agent Routing: neither pointer nor inline content found"
fi
# Verify the reference file has the full content (canonical source after refactor)
check_string_in_file "reference/agent-routing.md" "headless-runtime-helper.sh" "reference/agent-routing.md: headless dispatch reference"
check_string_in_file "reference/agent-routing.md" "--agent" "reference/agent-routing.md: --agent flag documented"
check_file_nonempty "reference/agent-routing.md" 1000 "reference/agent-routing.md: substantial content"

# ─── Test 9: subagent-index.toon TOON block counts ────────────────────────────
echo ""
echo "=== 9. subagent-index.toon TOON Block Counts ==="
TOON_FILE="${AGENTS_DIR}/subagent-index.toon"
if [[ ! -f "$TOON_FILE" ]]; then
	log_fail "subagent-index.toon not found"
else
	# Extract declared count from TOON block header using sed (macOS-compatible)
	# Format: <!--TOON:agents[9]{...}:
	# 9 primary agents as of t1680 refactor (marketing-sales.md consolidates marketing+sales)
	AGENTS_COUNT=$(sed -n 's/.*<!--TOON:agents\[\([0-9]*\)\].*/\1/p' "$TOON_FILE" | head -1)
	if [[ -n "$AGENTS_COUNT" && "$AGENTS_COUNT" -ge 9 ]]; then
		log_ok "subagent-index.toon: agents block declares ${AGENTS_COUNT} agents (expected >=9)"
	elif [[ -n "$AGENTS_COUNT" ]]; then
		log_fail "subagent-index.toon: agents block declares only ${AGENTS_COUNT} agents (expected >=9)"
	else
		log_fail "subagent-index.toon: could not parse agents block count"
	fi

	SUBAGENTS_COUNT=$(sed -n 's/.*<!--TOON:subagents\[\([0-9]*\)\].*/\1/p' "$TOON_FILE" | head -1)
	if [[ -n "$SUBAGENTS_COUNT" && "$SUBAGENTS_COUNT" -ge 60 ]]; then
		log_ok "subagent-index.toon: subagents block declares ${SUBAGENTS_COUNT} subagents"
	elif [[ -n "$SUBAGENTS_COUNT" ]]; then
		log_fail "subagent-index.toon: subagents block declares only ${SUBAGENTS_COUNT} subagents (expected >=60)"
	else
		log_fail "subagent-index.toon: could not parse subagents block count"
	fi
fi

# ─── Test 10: Critical scripts for self-improvement workflow ──────────────────
echo ""
echo "=== 10. Critical Scripts for Self-Improvement Workflow ==="
CRITICAL_SCRIPTS=(
	"scripts/framework-issue-helper.sh"
	"scripts/framework-routing-helper.sh"
	"scripts/headless-runtime-helper.sh"
	"scripts/worktree-helper.sh"
	"scripts/pre-edit-check.sh"
	"scripts/claim-task-id.sh"
)
for script in "${CRITICAL_SCRIPTS[@]}"; do
	full="${AGENTS_DIR}/${script}"
	if [[ -f "$full" && -x "$full" ]]; then
		log_ok "Script executable: ${script}"
	elif [[ -f "$full" ]]; then
		log_fail "Script exists but not executable: ${script}"
	else
		log_fail "Script missing: ${script}"
	fi
done

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== SUMMARY ==="
echo "  PASS: ${PASS}"
echo "  FAIL: ${FAIL}"
echo "  WARN: ${WARNINGS}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
	echo "RESULT: FAIL — ${FAIL} check(s) failed. Agent discoverability may be degraded."
	exit 1
else
	echo "RESULT: PASS — All discoverability checks passed. Refactor did not degrade agent discoverability."
	exit 0
fi
