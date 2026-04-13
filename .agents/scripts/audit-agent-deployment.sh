#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Audit Agent Deployment — frontmatter parity check (GH#18509)
# =============================================================================
# Compares deployed OpenCode agent frontmatter against source files for
# security-sandboxed agents (those with bash: false in their source).
#
# Usage:
#   audit-agent-deployment.sh [--fix] [--agent <name>]
#
# Options:
#   --fix         Re-run generator to fix violations (requires setup.sh access)
#   --agent <n>   Check only the named agent (e.g. triage-review)
#
# Exit codes:
#   0  All checked agents are correctly deployed
#   1  One or more violations found (deployed permissions exceed source)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

AGENTS_DIR="${HOME}/.aidevops/agents"
OPENCODE_AGENT_DIR="${HOME}/.config/opencode/agent"
CLAUDE_AGENT_DIR="${HOME}/.claude/agents"
VIOLATIONS=0
FIX_MODE=0
FILTER_AGENT=""

# Parse arguments
while [[ $# -gt 0 ]]; do
	case "$1" in
	--fix)
		FIX_MODE=1
		shift
		;;
	--agent)
		FILTER_AGENT="$2"
		shift 2
		;;
	*)
		shift
		;;
	esac
done

# _has_bash_false <file>
# Returns 0 (true) if the file has bash: false in its YAML frontmatter.
_has_bash_false() {
	local f="$1"
	local result
	result=$(awk '
		/^---$/ { fm_delim++; next }
		fm_delim == 1 && /bash:[[:space:]]*false/ { print; exit }
		fm_delim == 2 { exit }
	' "$f" 2>/dev/null)
	[[ -n "$result" ]]
	return $?
}

# _check_deployed <src_file> <deployed_file> <agent_name>
# Checks that deployed file does not grant permissions beyond source.
_check_deployed() {
	local src="$1"
	local deployed="$2"
	local agent_name="$3"
	local violation=0

	if [[ ! -f "$deployed" ]]; then
		echo "[MISSING] $agent_name — deployed file not found: $deployed"
		VIOLATIONS=$((VIOLATIONS + 1))
		return 1
	fi

	# Check for banned keys in deployed file
	if grep -q 'bash: true' "$deployed" 2>/dev/null; then
		echo "[VIOLATION] $agent_name — deployed has bash:true, source has bash:false"
		violation=1
	fi

	if grep -q 'external_directory: allow' "$deployed" 2>/dev/null; then
		echo "[VIOLATION] $agent_name — deployed has external_directory:allow (not in source)"
		violation=1
	fi

	# Check that deployed tool list does not exceed source
	for tool_key in write edit webfetch task; do
		local src_val deployed_val
		src_val=$(awk '
			/^---$/ { fm_delim++; next }
			fm_delim == 1 && /'"${tool_key}"':/ { gsub(/.*:[[:space:]]*/, ""); print; exit }
			fm_delim == 2 { exit }
		' "$src" 2>/dev/null | tr -d '[:space:]')
		deployed_val=$(awk '
			/^---$/ { fm_delim++; next }
			fm_delim == 1 && /'"${tool_key}"':/ { gsub(/.*:[[:space:]]*/, ""); print; exit }
			fm_delim == 2 { exit }
		' "$deployed" 2>/dev/null | tr -d '[:space:]')
		# If source says false but deployed says true, that's a violation
		if [[ "$src_val" == "false" && "$deployed_val" == "true" ]]; then
			echo "[VIOLATION] $agent_name — deployed grants ${tool_key}:true, source has ${tool_key}:false"
			violation=1
		fi
	done

	if [[ "$violation" -eq 0 ]]; then
		echo "[OK] $agent_name"
		return 0
	fi

	VIOLATIONS=$((VIOLATIONS + violation))
	return 1
}

echo "=== Agent Deployment Audit (GH#18509) ==="
echo "Source:    $AGENTS_DIR"
echo "Deployed:  $OPENCODE_AGENT_DIR"
echo ""

# Find all source agents with bash: false
while IFS= read -r src_file; do
	local_name=$(basename "$src_file" .md)

	# Apply filter if set
	if [[ -n "$FILTER_AGENT" && "$local_name" != "$FILTER_AGENT" ]]; then
		continue
	fi

	deployed_file="${OPENCODE_AGENT_DIR}/${local_name}.md"
	_check_deployed "$src_file" "$deployed_file" "$local_name" || true
done < <(find "$AGENTS_DIR" -mindepth 2 -name "*.md" -type f -not -path "*/loop-state/*" -not -name "*-skill.md" | while IFS= read -r f; do
	_has_bash_false "$f" && echo "$f"
done | sort)

echo ""
if [[ "$VIOLATIONS" -eq 0 ]]; then
	echo "All restricted agents are correctly deployed."
	exit 0
else
	echo "Found $VIOLATIONS violation(s). Re-run setup.sh (or deploy with generate-runtime-config.sh) to fix."
	if [[ "$FIX_MODE" -eq 1 ]]; then
		echo "Running generator to fix violations..."
		bash "${SCRIPT_DIR}/generate-runtime-config.sh" agents --runtime opencode
		echo "Re-running audit to verify fix..."
		VIOLATIONS=0
		if [[ -n "$FILTER_AGENT" ]]; then
			exec "$0" --agent "$FILTER_AGENT"
		else
			exec "$0"
		fi
	fi
	exit 1
fi
