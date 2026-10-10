#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# Code Review Monitoring and Auto-Fix Script (Enhanced Version)
# Monitors external code review tools and applies automatic fixes
#
# Author: AI DevOps Framework
# Version: 1.1.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

print_header() {
	local msg="$1"
	echo -e "${PURPLE}[MONITOR]${NC} $msg"
	return 0
}

# Configuration
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly MONITOR_LOG="$REPO_ROOT/.agents/tmp/code-review-monitor.log"
readonly STATUS_FILE="$REPO_ROOT/.agents/tmp/quality-status.json"

# Create directories
mkdir -p "$REPO_ROOT/.agents/tmp"

# Initialize monitoring log
init_monitoring() {
	print_header "Initializing Code Review Monitoring"
	echo "$(date): Code review monitoring started" >>"$MONITOR_LOG"
	return 0
}

# Check SonarCloud status
check_sonarcloud() {
	print_info "Checking SonarCloud status..."

	local api_url="https://sonarcloud.io/api/measures/component?component=marcusquinn_aidevops&metricKeys=bugs,vulnerabilities,code_smells,coverage,duplicated_lines_density"
	local response

	if response=$(curl -s "$api_url"); then
		if ! printf '%s' "$response" | jq -e . >/dev/null 2>&1; then
			print_warning "SonarCloud returned non-JSON response; skipping status"
			echo "$(date): SonarCloud - non-JSON response skipped" >>"$MONITOR_LOG"
			return 0
		fi

		local bugs
		bugs=$(printf '%s' "$response" | jq -r '.component.measures[]? | select(.metric=="bugs") | .value // "0"')
		local vulnerabilities
		vulnerabilities=$(printf '%s' "$response" | jq -r '.component.measures[]? | select(.metric=="vulnerabilities") | .value // "0"')
		local code_smells
		code_smells=$(printf '%s' "$response" | jq -r '.component.measures[]? | select(.metric=="code_smells") | .value // "0"')

		bugs="${bugs:-0}"
		vulnerabilities="${vulnerabilities:-0}"
		code_smells="${code_smells:-0}"

		print_success "SonarCloud Status: Bugs: $bugs, Vulnerabilities: $vulnerabilities, Code Smells: $code_smells"

		# Log status
		echo "$(date): SonarCloud - Bugs: $bugs, Vulnerabilities: $vulnerabilities, Code Smells: $code_smells" >>"$MONITOR_LOG"

		# Store in status file
		jq -n --arg bugs "$bugs" --arg vulns "$vulnerabilities" --arg smells "$code_smells" \
			'{sonarcloud: {bugs: $bugs, vulnerabilities: $vulns, code_smells: $smells, timestamp: now}}' >"$STATUS_FILE"

		return 0
	else
		print_error "Failed to fetch SonarCloud status"
		return 1
	fi
}

# Run Qlty analysis (reporting only — no auto-fix)
run_qlty_analysis() {
	print_info "Running Qlty analysis..."

	# Run analysis with sample to get quick feedback (reporting only)
	if bash "$REPO_ROOT/.agents/scripts/qlty-cli.sh" check 5 >"$REPO_ROOT/.agents/tmp/qlty-results.txt" 2>&1; then
		local issues
		issues=$(grep -o "ISSUES: [0-9]*" "$REPO_ROOT/.agents/tmp/qlty-results.txt" | grep -o "[0-9]*" || echo "0")
		print_success "Qlty Analysis: $issues issues found"

		# DISABLED: qlty fmt introduces invalid shell syntax (adds "|| exit" after
		# "then" clauses). Auto-formatting removed from both monitor and fix paths.
		# See: https://github.com/marcusquinn/aidevops/issues/333
		# The GHA workflow validation gate (ShellCheck + bash -n) provides a safety
		# net, but preventing bad fixes at the source is the primary defense.

		echo "$(date): Qlty - $issues issues found (report only, auto-fix disabled)" >>"$MONITOR_LOG"
		return 0
	else
		print_warning "Qlty analysis completed with warnings (API key may not be configured)"
		return 0
	fi
}

# Run Codacy analysis (Codacy Analysis CLI; report only, writes SARIF for
# code scanning). Skips cleanly when the CLI is not installed.
run_codacy_analysis() {
	local codacy_script="$REPO_ROOT/.agents/scripts/codacy-cli.sh"
	if ! command -v codacy-analysis >/dev/null 2>&1; then
		print_info "Codacy Analysis CLI not installed; skipping (install: bash $codacy_script install)"
		return 0
	fi

	local timeout="${CODACY_ANALYSIS_TIMEOUT:-900}"
	print_info "Running Codacy analysis (timeout: ${timeout}s)..."

	local log_file="$REPO_ROOT/.agents/tmp/codacy-results.txt"
	local sarif_file="$REPO_ROOT/codacy-results.sarif"
	rm -f "$sarif_file"
	# Optional scope, e.g. CODACY_ANALYZE_ARGS="--diff origin/main" for PRs
	local scope_args=()
	read -r -a scope_args <<<"${CODACY_ANALYZE_ARGS:-}"

	# Run in background
	bash "$codacy_script" analyze --sarif "$sarif_file" \
		${scope_args[@]+"${scope_args[@]}"} >"$log_file" 2>&1 &
	local pid=$!

	# Wait loop with timeout
	local interval=2
	local elapsed=0

	while kill -0 $pid 2>/dev/null; do
		if [[ $elapsed -ge $timeout ]]; then
			print_warning "Codacy analysis timed out after ${timeout}s"
			kill $pid 2>/dev/null || true
			echo "$(date): Codacy analysis timed out after ${timeout}s" >>"$MONITOR_LOG"
			return 0 # Don't fail the whole monitor script
		fi

		# Show progress
		if [[ $((elapsed % 10)) -eq 0 ]]; then
			echo -n "."
		fi

		sleep $interval
		elapsed=$((elapsed + interval))
	done
	echo "" # New line

	# Check exit status (|| true prevents set -e from killing script on non-zero)
	local status=0
	wait $pid || status=$?

	if [[ $status -eq 0 ]]; then
		print_success "Codacy analysis: no issues found"
		echo "$(date): Codacy analysis completed - no issues" >>"$MONITOR_LOG"
		return 0
	elif [[ $status -le 2 && -s "$sarif_file" ]]; then
		# 1 = issues found; 2 = some analyzers errored but results were written
		print_warning "Codacy analysis: issues found (exit $status, SARIF: $sarif_file, log: $log_file)"
		echo "$(date): Codacy analysis completed - issues found (exit $status)" >>"$MONITOR_LOG"
		return 0
	else
		print_warning "Codacy analysis failed (status: $status)"
		# Show last few lines of log for context
		if [[ -f "$log_file" ]]; then
			echo "Last 5 lines of log:"
			tail -n 5 "$log_file" | sed 's/^/  /'
		fi
		return 0 # Don't fail the whole monitor script
	fi
}

# Apply automatic fixes based on common patterns
apply_automatic_fixes() {
	# DISABLED: The cd || exit sed regex is too broad and introduces invalid syntax
	# when cd appears inside subshells within if conditions, e.g.:
	#   if (cd "$dir" && cmd); then  →  if (cd "$dir" && cmd); then || exit
	# This caused ShellCheck SC1073/SC1072 regressions (PR #435, commit aa276b3).
	# Safe auto-fixes should validate with shellcheck before committing.
	print_info "Automatic fixes disabled (see monitor-code-review.sh for details)"
	return 0
}

# Generate monitoring report
generate_report() {
	print_header "Code Review Monitoring Report"
	echo ""

	if [[ -f "$STATUS_FILE" ]]; then
		print_info "Latest Quality Status:"
		jq -r '.sonarcloud | "SonarCloud: \(.bugs) bugs, \(.vulnerabilities) vulnerabilities, \(.code_smells) code smells"' "$STATUS_FILE" 2>/dev/null || echo "Status data not available"
	fi

	echo ""
	print_info "Recent monitoring activity:"

	if [[ -f "$MONITOR_LOG" ]]; then
		tail -10 "$MONITOR_LOG"
	else
		echo "No monitoring log available"
	fi

	return 0
}

# Add wrapper functions for workflow compatibility
monitor() {
	echo "Running code review status in real-time..."
	init_monitoring
	check_sonarcloud
	run_qlty_analysis
	run_codacy_analysis
	apply_automatic_fixes
	generate_report
	return 0
}

fix() {
	echo "Applying automatic fixes..."
	apply_automatic_fixes
	return 0
}

report() {
	generate_report
	return 0
}

# Main function
main() {
	local command="${1:-monitor}"

	case "$command" in
	"monitor")
		monitor
		;;
	"fix")
		fix
		;;
	"report")
		report
		;;
	*)
		echo "Usage: $0 {monitor|fix|report}"
		exit 1
		;;
	esac
	return 0
}

main "$@"
