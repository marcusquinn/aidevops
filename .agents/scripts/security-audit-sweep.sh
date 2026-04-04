#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# security-audit-sweep.sh — One-time security audit sweep across managed repos
#
# Runs security-posture-helper.sh against each pulse-enabled repo in repos.json,
# checks for AI/LLM dependencies, and outputs a structured report.
#
# Usage:
#   security-audit-sweep.sh run              # Run sweep, output report
#   security-audit-sweep.sh run --json       # JSON output
#   security-audit-sweep.sh check <path>     # Check single repo
#   security-audit-sweep.sh ai-deps          # List repos with AI/LLM deps
#   security-audit-sweep.sh help             # Show usage
#
# Designed to be run once (t1412.13), then t1412.11's `aidevops security audit`
# handles future per-repo checks.
#
# t1412.13: https://github.com/marcusquinn/aidevops/issues/3096

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
readonly REPOS_JSON="${HOME}/.config/aidevops/repos.json"
readonly POSTURE_HELPER="${SCRIPT_DIR}/security-posture-helper.sh"
readonly VERSION="1.0.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# AI/LLM dependency patterns (npm, pip, cargo)
readonly AI_DEPS_NPM='openai|anthropic|^ai$|@ai-sdk|langchain|@langchain|vercel.*ai|@stackone/defender|llama|ollama'
readonly AI_DEPS_PIP='openai|anthropic|langchain|litellm|llama-index|transformers|huggingface|torch|vllm'

print_usage() {
	cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  run [--json]       Run security audit sweep across all pulse-enabled repos
  check <path>       Run security posture check on a single repo
  ai-deps            List repos with AI/LLM dependencies
  help               Show this help message

Options:
  --json             Output results as JSON (with 'run' command)

Examples:
  $(basename "$0") run                    # Full sweep with text report
  $(basename "$0") run --json             # Full sweep with JSON output
  $(basename "$0") check ~/Git/myproject  # Single repo check
  $(basename "$0") ai-deps               # Show AI/LLM dependency map
EOF
	return 0
}

# Get pulse-enabled repos from repos.json
# Output: one JSON object per line with path and slug
get_pulse_repos() {
	if [[ ! -f "$REPOS_JSON" ]]; then
		echo "ERROR: repos.json not found at $REPOS_JSON" >&2
		return 1
	fi

	if ! command -v jq &>/dev/null; then
		echo "ERROR: jq is required" >&2
		return 1
	fi

	jq -c '.initialized_repos[] | select(.pulse == true) | {path: .path, slug: .slug, local_only: (.local_only // false)}' "$REPOS_JSON"
	return 0
}

# Check a single repo for AI/LLM dependencies
# Args: repo_path
# Output: list of AI deps found, or empty
check_ai_deps() {
	local repo_path="$1"
	local deps_found=""

	# Check package.json (npm)
	if [[ -f "$repo_path/package.json" ]]; then
		local npm_deps
		npm_deps=$(jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' "$repo_path/package.json") || true
		if [[ -n "$npm_deps" ]]; then
			local matched
			matched=$(printf '%s' "$npm_deps" | grep -iE "$AI_DEPS_NPM") || true
			if [[ -n "$matched" ]]; then
				deps_found="${deps_found}${matched}"$'\n'
			fi
		fi
	fi

	# Check requirements.txt (pip)
	if [[ -f "$repo_path/requirements.txt" ]]; then
		local pip_matched
		pip_matched=$(grep -iE "$AI_DEPS_PIP" "$repo_path/requirements.txt" | sed 's/[>=<].*//' | tr -d ' ') || true
		if [[ -n "$pip_matched" ]]; then
			deps_found="${deps_found}${pip_matched}"$'\n'
		fi
	fi

	# Check pyproject.toml (pip)
	if [[ -f "$repo_path/pyproject.toml" ]]; then
		local pyproject_matched
		pyproject_matched=$(grep -iE "$AI_DEPS_PIP" "$repo_path/pyproject.toml" | sed -E "s/^[[:space:]]*['\"]?//; s/[[:space:]]*(==|~=|!=|<=|>=|<|>|@|;).*//; s/[\"',[:space:]]+$//") || true
		if [[ -n "$pyproject_matched" ]]; then
			deps_found="${deps_found}${pyproject_matched}"$'\n'
		fi
	fi

	# Trim trailing newlines and output
	local trimmed
	trimmed=$(echo "$deps_found" | sed '/^$/d')
	if [[ -n "$trimmed" ]]; then
		echo "$trimmed"
	fi
	return 0
}

# Check a single repo for unsafe CI workflow patterns
# Args: repo_path
# Output: findings text
check_ci_patterns() {
	local repo_path="$1"
	local workflows_dir="$repo_path/.github/workflows"

	if [[ ! -d "$workflows_dir" ]]; then
		return 0
	fi

	local findings=""

	while IFS= read -r wf; do
		[[ -z "$wf" ]] && continue
		local wf_name
		wf_name=$(basename "$wf")

		# Shell injection via github.event context
		if grep -qE '\$\{\{\s*github\.event\.(issue|pull_request|comment)\.' "$wf"; then
			if grep -qE '^\s*run:' "$wf"; then
				findings="${findings}CRITICAL: $wf_name uses github.event context in shell run step"$'\n'
			fi
		fi

		# Overly permissive wildcard
		if grep -qE 'allowed_non_write_users:\s*"\*"' "$wf"; then
			findings="${findings}CRITICAL: $wf_name has allowed_non_write_users wildcard"$'\n'
		fi

		# pull_request_target with PR head checkout
		if grep -qE 'pull_request_target' "$wf"; then
			if grep -qE 'ref:\s*\$\{\{\s*github\.event\.pull_request\.head\.(ref|sha)' "$wf"; then
				findings="${findings}CRITICAL: $wf_name has pull_request_target with PR head checkout"$'\n'
			fi
		fi

		# Actions not pinned to SHA
		local unpinned
		unpinned=$(grep -oE 'uses:\s+[a-zA-Z0-9_-]+/[a-zA-Z0-9_.-]+@(main|master|v[0-9]+)' "$wf" | wc -l | tr -d ' ') || unpinned="0"
		if [[ "$unpinned" -gt 0 ]]; then
			findings="${findings}WARNING: $wf_name has $unpinned action(s) not SHA-pinned"$'\n'
		fi

		# write-all permissions
		if grep -qE '^\s*permissions:\s*write-all' "$wf"; then
			findings="${findings}WARNING: $wf_name uses write-all permissions"$'\n'
		fi
	done < <(find "$workflows_dir" -name "*.yml" -o -name "*.yaml")

	if [[ -n "$findings" ]]; then
		echo "$findings" | sed '/^$/d'
	fi
	return 0
}

# Run the full posture check on a single repo
# Args: repo_path
# Returns: exit code from security-posture-helper.sh
run_posture_check() {
	local repo_path="$1"

	if [[ ! -x "$POSTURE_HELPER" ]]; then
		echo "ERROR: security-posture-helper.sh not found or not executable" >&2
		return 1
	fi

	"$POSTURE_HELPER" check "$repo_path" 2>&1
	return $?
}

# Print the sweep banner header
_print_sweep_header() {
	echo -e "${CYAN}"
	echo "╔═══════════════════════════════════════════════════════════╗"
	echo "║       Security Audit Sweep v${VERSION}                        ║"
	echo "║   Scanning all pulse-enabled repos in repos.json         ║"
	echo "╚═══════════════════════════════════════════════════════════╝"
	echo -e "${NC}"
	return 0
}

# Display AI/LLM dependency results for a repo
# Args: ai_deps (string, may be empty)
# Prints display output; no return value
_display_ai_deps() {
	local ai_deps="$1"

	echo ""
	echo -e "${BLUE}  Checking AI/LLM dependencies...${NC}"
	if [[ -n "$ai_deps" ]]; then
		echo -e "${YELLOW}  AI/LLM dependencies found:${NC}"
		echo "$ai_deps" | while IFS= read -r dep; do
			echo -e "    - $dep"
		done
		if echo "$ai_deps" | grep -q '@stackone/defender'; then
			echo -e "${GREEN}  @stackone/defender already integrated${NC}"
		else
			echo -e "${YELLOW}  RECOMMEND: Add @stackone/defender for prompt injection defense${NC}"
		fi
	else
		echo -e "${GREEN}  No AI/LLM dependencies found${NC}"
	fi
	return 0
}

# Display CI workflow security findings for a repo
# Args: ci_findings (string, may be empty)
# Prints display output; no return value
_display_ci_findings() {
	local ci_findings="$1"

	echo ""
	echo -e "${BLUE}  Checking CI workflow security...${NC}"
	if [[ -n "$ci_findings" ]]; then
		echo "$ci_findings" | while IFS= read -r finding; do
			if [[ "$finding" == CRITICAL:* ]]; then
				echo -e "  ${RED}$finding${NC}"
			else
				echo -e "  ${YELLOW}$finding${NC}"
			fi
		done
	else
		echo -e "${GREEN}  No CI workflow security issues found${NC}"
	fi
	return 0
}

# Extract posture counts from posture helper output
# Args: posture_output (string)
# Prints: "critical_count warning_count pass_count" on stdout
_extract_posture_counts() {
	local posture_output="$1"
	local critical_count warning_count pass_count

	critical_count=$(printf '%s' "$posture_output" | grep -c '^\[CRIT\]') || critical_count=0
	warning_count=$(printf '%s' "$posture_output" | grep -c '^\[WARN\]') || warning_count=0
	pass_count=$(printf '%s' "$posture_output" | grep -c '^\[PASS\]') || pass_count=0

	# The posture helper uses ANSI codes, so also check with color codes
	if [[ "$critical_count" -eq 0 ]]; then
		critical_count=$(printf '%s' "$posture_output" | grep -c '\[CRIT\]') || critical_count=0
	fi
	if [[ "$warning_count" -eq 0 ]]; then
		warning_count=$(printf '%s' "$posture_output" | grep -c '\[WARN\]') || warning_count=0
	fi
	if [[ "$pass_count" -eq 0 ]]; then
		pass_count=$(printf '%s' "$posture_output" | grep -c '\[PASS\]') || pass_count=0
	fi

	echo "${critical_count} ${warning_count} ${pass_count}"
	return 0
}

# Build a JSON entry for a single repo
# Args: repo_slug repo_path local_only critical_count warning_count pass_count ai_deps ci_findings
# Prints: JSON object on stdout
_build_repo_json_entry() {
	local repo_slug="$1"
	local repo_path="$2"
	local local_only="$3"
	local critical_count="$4"
	local warning_count="$5"
	local pass_count="$6"
	local ai_deps="$7"
	local ci_findings="$8"

	local ai_deps_json="[]"
	if [[ -n "$ai_deps" ]]; then
		ai_deps_json=$(echo "$ai_deps" | jq -R -s 'split("\n") | map(select(length > 0))')
	fi

	local ci_findings_json="[]"
	if [[ -n "$ci_findings" ]]; then
		ci_findings_json=$(echo "$ci_findings" | jq -R -s 'split("\n") | map(select(length > 0))')
	fi

	jq -n \
		--arg slug "$repo_slug" \
		--arg path "$repo_path" \
		--argjson local_only "${local_only}" \
		--argjson critical "$critical_count" \
		--argjson warnings "$warning_count" \
		--argjson passed "$pass_count" \
		--argjson ai_deps "$ai_deps_json" \
		--argjson ci_findings "$ci_findings_json" \
		'{
			slug: $slug,
			path: $path,
			local_only: $local_only,
			critical: $critical,
			warnings: $warnings,
			passed: $passed,
			ai_deps: $ai_deps,
			ci_findings: $ci_findings,
			needs_defender: (($ai_deps | length) > 0 and ([$ai_deps[] | select(. == "@stackone/defender")] | length) == 0)
		}'
	return 0
}

# Print overall sweep summary and optional JSON output
# Args: json_output total_repos repos_with_issues repos_with_ai_deps
#       total_critical total_warning repos_json_arr
_print_sweep_summary() {
	local json_output="$1"
	local total_repos="$2"
	local repos_with_issues="$3"
	local repos_with_ai_deps="$4"
	local total_critical="$5"
	local total_warning="$6"
	local repos_json_arr="$7"

	echo ""
	echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
	echo -e "${BOLD}${CYAN}  Overall Sweep Summary${NC}"
	echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
	echo ""
	echo -e "  Repos scanned:       ${total_repos}"
	echo -e "  Repos with issues:   ${repos_with_issues}"
	echo -e "  Repos with AI deps:  ${repos_with_ai_deps}"
	echo -e "  Total critical:      ${RED}${total_critical}${NC}"
	echo -e "  Total warnings:      ${YELLOW}${total_warning}${NC}"
	echo ""

	if [[ "$json_output" == "true" ]]; then
		local sweep_json
		sweep_json=$(jq -n \
			--arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			--argjson total_repos "$total_repos" \
			--argjson repos_with_issues "$repos_with_issues" \
			--argjson repos_with_ai_deps "$repos_with_ai_deps" \
			--argjson total_critical "$total_critical" \
			--argjson total_warning "$total_warning" \
			--argjson repos "$repos_json_arr" \
			'{
				sweep_timestamp: $timestamp,
				summary: {
					total_repos: $total_repos,
					repos_with_issues: $repos_with_issues,
					repos_with_ai_deps: $repos_with_ai_deps,
					total_critical: $total_critical,
					total_warnings: $total_warning
				},
				repos: $repos
			}')
		echo "$sweep_json"
	fi
	return 0
}

# Run sweep across all pulse-enabled repos
cmd_run() {
	local json_output=false
	if [[ "${1:-}" == "--json" ]]; then
		json_output=true
	fi

	_print_sweep_header

	local repos_json_arr="[]"
	local total_repos=0
	local repos_with_issues=0
	local repos_with_ai_deps=0
	local total_critical=0
	local total_warning=0

	while IFS= read -r repo_json; do
		local repo_path repo_slug local_only
		repo_path=$(echo "$repo_json" | jq -r '.path')
		repo_slug=$(echo "$repo_json" | jq -r '.slug')
		local_only=$(echo "$repo_json" | jq -r '.local_only')

		total_repos=$((total_repos + 1))

		echo ""
		echo -e "${BOLD}═══════════════════════════════════════${NC}"
		echo -e "${BOLD}  Repo ${total_repos}: ${repo_slug}${NC}"
		echo -e "${BOLD}  Path: ${repo_path}${NC}"
		echo -e "${BOLD}═══════════════════════════════════════${NC}"

		if [[ ! -d "$repo_path" ]]; then
			echo -e "${RED}  SKIP: Directory not found${NC}"
			continue
		fi

		if ! git -C "$repo_path" rev-parse --is-inside-work-tree &>/dev/null; then
			echo -e "${RED}  SKIP: Not a git repository${NC}"
			continue
		fi

		# 1. Check AI/LLM dependencies
		local ai_deps
		ai_deps=$(check_ai_deps "$repo_path")
		_display_ai_deps "$ai_deps"
		if [[ -n "$ai_deps" ]]; then
			repos_with_ai_deps=$((repos_with_ai_deps + 1))
		fi

		# 2. Check CI workflow patterns
		local ci_findings
		ci_findings=$(check_ci_patterns "$repo_path")
		_display_ci_findings "$ci_findings"

		# 3. Run full posture check and extract counts
		echo ""
		echo -e "${BLUE}  Running full security posture check...${NC}"
		local posture_output posture_counts
		local posture_exit=0
		posture_output=$(run_posture_check "$repo_path" 2>&1) || posture_exit=$?
		posture_counts=$(_extract_posture_counts "$posture_output")

		local critical_count warning_count pass_count
		critical_count=$(echo "$posture_counts" | cut -d' ' -f1)
		warning_count=$(echo "$posture_counts" | cut -d' ' -f2)
		pass_count=$(echo "$posture_counts" | cut -d' ' -f3)

		total_critical=$((total_critical + critical_count))
		total_warning=$((total_warning + warning_count))

		if [[ "$critical_count" -gt 0 ]] || [[ "$warning_count" -gt 0 ]]; then
			repos_with_issues=$((repos_with_issues + 1))
		fi

		echo -e "  Summary: ${RED}${critical_count} critical${NC}, ${YELLOW}${warning_count} warnings${NC}, ${GREEN}${pass_count} passed${NC}"

		# Build JSON entry and append to array
		local repo_entry
		repo_entry=$(_build_repo_json_entry \
			"$repo_slug" "$repo_path" "$local_only" \
			"$critical_count" "$warning_count" "$pass_count" \
			"$ai_deps" "$ci_findings")
		repos_json_arr=$(echo "$repos_json_arr" | jq --argjson entry "$repo_entry" '. += [$entry]')

	done < <(get_pulse_repos)

	_print_sweep_summary "$json_output" "$total_repos" "$repos_with_issues" \
		"$repos_with_ai_deps" "$total_critical" "$total_warning" "$repos_json_arr"

	if [[ "$total_critical" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# Check a single repo
cmd_check() {
	local repo_path="${1:-.}"

	if [[ ! -d "$repo_path" ]]; then
		echo "ERROR: Directory not found: $repo_path" >&2
		return 1
	fi

	echo -e "${BLUE}Checking: $repo_path${NC}"
	echo ""

	# AI deps
	echo -e "${BOLD}AI/LLM Dependencies:${NC}"
	local ai_deps
	ai_deps=$(check_ai_deps "$repo_path")
	if [[ -n "$ai_deps" ]]; then
		echo "$ai_deps"
	else
		echo "  (none)"
	fi
	echo ""

	# CI patterns
	echo -e "${BOLD}CI Workflow Security:${NC}"
	local ci_findings
	ci_findings=$(check_ci_patterns "$repo_path")
	if [[ -n "$ci_findings" ]]; then
		echo "$ci_findings"
	else
		echo "  (no issues)"
	fi
	echo ""

	# Full posture
	echo -e "${BOLD}Full Security Posture:${NC}"
	run_posture_check "$repo_path"

	return 0
}

# List repos with AI/LLM dependencies
cmd_ai_deps() {
	echo -e "${BOLD}AI/LLM Dependencies Across Managed Repos${NC}"
	echo ""

	local found_any=false

	while IFS= read -r repo_json; do
		local repo_path repo_slug
		repo_path=$(echo "$repo_json" | jq -r '.path')
		repo_slug=$(echo "$repo_json" | jq -r '.slug')

		if [[ ! -d "$repo_path" ]]; then
			continue
		fi

		local ai_deps
		ai_deps=$(check_ai_deps "$repo_path")
		if [[ -n "$ai_deps" ]]; then
			found_any=true
			echo -e "${CYAN}${repo_slug}${NC} ($repo_path):"
			echo "$ai_deps" | while IFS= read -r dep; do
				echo "  - $dep"
			done

			if ! echo "$ai_deps" | grep -q '@stackone/defender'; then
				echo -e "  ${YELLOW}-> Recommend: @stackone/defender${NC}"
			fi
			echo ""
		fi
	done < <(get_pulse_repos)

	if [[ "$found_any" == "false" ]]; then
		echo "  No repos have AI/LLM dependencies in their manifests."
	fi

	return 0
}

# Main
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	run)
		cmd_run "$@"
		;;
	check)
		cmd_check "$@"
		;;
	ai-deps | ai_deps)
		cmd_ai_deps "$@"
		;;
	help | --help | -h)
		print_usage
		;;
	*)
		echo "Unknown command: $command" >&2
		print_usage >&2
		return 1
		;;
	esac
}

main "$@"
