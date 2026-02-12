#!/usr/bin/env bash
# shellcheck disable=SC1091
# Pre-commit hook for multi-platform quality validation
# Install with: cp .agents/scripts/pre-commit-hook.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Color codes for output

# Get list of modified shell files
get_modified_shell_files() {
	git diff --cached --name-only --diff-filter=ACM | grep '\.sh$' || true
	return 0
}

validate_return_statements() {
	local violations=0

	print_info "Validating return statements..."

	for file in "$@"; do
		if [[ -f "$file" ]]; then
			# Check for functions without return statements
			local functions
			functions=$(grep -c "^[a-zA-Z_][a-zA-Z0-9_]*() {" "$file" || echo "0")
			local returns
			returns=$(grep -c "return [01]" "$file" || echo "0")

			if [[ $functions -gt 0 && $returns -lt $functions ]]; then
				print_error "Missing return statements in $file"
				((violations++))
			fi
		fi
	done

	return $violations
}

validate_positional_parameters() {
	local violations=0

	print_info "Validating positional parameters..."

	for file in "$@"; do
		if [[ -f "$file" ]] && grep -n '\$[1-9]' "$file" | grep -v 'local.*=.*\$[1-9]' >/dev/null; then
			print_error "Direct positional parameter usage in $file"
			grep -n '\$[1-9]' "$file" | grep -v 'local.*=.*\$[1-9]' | head -3
			((violations++))
		fi
	done

	return $violations
}

validate_string_literals() {
	local violations=0

	print_info "Validating string literals..."

	for file in "$@"; do
		if [[ -f "$file" ]]; then
			# Check for repeated string literals
			local repeated
			repeated=$(grep -o '"[^"]*"' "$file" | sort | uniq -c | awk '$1 >= 3' | wc -l || echo "0")

			if [[ $repeated -gt 0 ]]; then
				print_warning "Repeated string literals in $file (consider using constants)"
				grep -o '"[^"]*"' "$file" | sort | uniq -c | awk '$1 >= 3 {print "  " $1 "x: " $2}' | head -3
				((violations++))
			fi
		fi
	done

	return $violations
}

run_shellcheck() {
	local violations=0

	print_info "Running ShellCheck validation..."

	for file in "$@"; do
		if [[ -f "$file" ]] && ! shellcheck "$file"; then
			print_error "ShellCheck violations in $file"
			((violations++))
		fi
	done

	return $violations
}

check_secrets() {
	local violations=0

	print_info "Checking for exposed secrets (Secretlint)..."

	# Get staged files
	local staged_files
	staged_files=$(git diff --cached --name-only --diff-filter=ACMR | tr '\n' ' ')

	if [[ -z "$staged_files" ]]; then
		print_info "No files to check for secrets"
		return 0
	fi

	# Check if secretlint is available
	if command -v secretlint &>/dev/null; then
		if echo "$staged_files" | xargs secretlint --format compact 2>/dev/null; then
			print_success "No secrets detected in staged files"
		else
			print_error "Potential secrets detected in staged files!"
			print_info "Review the findings and either:"
			print_info "  1. Remove the secrets from your code"
			print_info "  2. Add to .secretlintignore if false positive"
			print_info "  3. Use // secretlint-disable-line comment"
			((violations++))
		fi
	elif [[ -f "node_modules/.bin/secretlint" ]]; then
		if echo "$staged_files" | xargs ./node_modules/.bin/secretlint --format compact 2>/dev/null; then
			print_success "No secrets detected in staged files"
		else
			print_error "Potential secrets detected in staged files!"
			((violations++))
		fi
	elif command -v npx &>/dev/null && [[ -f ".secretlintrc.json" ]]; then
		if echo "$staged_files" | xargs npx secretlint --format compact 2>/dev/null; then
			print_success "No secrets detected in staged files"
		else
			print_error "Potential secrets detected in staged files!"
			((violations++))
		fi
	else
		print_warning "Secretlint not available (install: npm install secretlint --save-dev)"
	fi

	return $violations
}

check_quality_standards() {
	print_info "Checking current quality standards..."

	# Check SonarCloud status if curl is available
	if command -v curl &>/dev/null && command -v jq &>/dev/null; then
		local response
		if response=$(curl -s --max-time 10 "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_aidevops&impactSoftwareQualities=MAINTAINABILITY&resolved=false&ps=1" 2>/dev/null); then
			local total_issues
			total_issues=$(echo "$response" | jq -r '.total // 0' 2>/dev/null || echo "unknown")

			if [[ "$total_issues" != "unknown" ]]; then
				print_info "Current SonarCloud issues: $total_issues"

				if [[ $total_issues -gt 200 ]]; then
					print_warning "High issue count detected. Consider running quality fixes."
				fi
			fi
		fi
	fi
	return 0
}

# Validate TODO.md task completion transitions (t317.1)
# When [ ] -> [x], require pr:# or verified: field for proof-log
validate_todo_completions() {
	# Only check if TODO.md is staged
	if ! git diff --cached --name-only | grep -q '^TODO\.md$'; then
		return 0
	fi

	print_info "Validating TODO.md task completions (proof-log check)..."

	# Find ALL tasks (including subtasks) that changed from [ ] to [x] in this commit
	# We need to check both top-level and subtasks
	local newly_completed
	newly_completed=$(git diff --cached -U0 TODO.md | grep -E '^\+.*- \[x\] t[0-9]+' | sed 's/^\+//' || true)

	if [[ -z "$newly_completed" ]]; then
		return 0
	fi

	# Also get lines that were already [x] (to skip them - not a transition)
	local already_completed
	already_completed=$(git diff --cached -U0 TODO.md | grep -E '^\-.*- \[x\] t[0-9]+' | sed 's/^\-//' || true)

	local task_count=0
	local fail_count=0
	local failed_tasks=()

	while IFS= read -r line; do
		local task_id
		task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		if [[ -z "$task_id" ]]; then
			continue
		fi

		# Skip if this task was already [x] in the previous version (not a transition)
		if echo "$already_completed" | grep -q "$task_id"; then
			continue
		fi

		task_count=$((task_count + 1))

		# Check for required evidence: pr:# or verified: field
		local has_evidence=false

		# Check for pr:# field (e.g., pr:123 or pr:#123)
		if echo "$line" | grep -qE 'pr:#?[0-9]+'; then
			has_evidence=true
		fi

		# Check for verified: field (e.g., verified:2026-02-12)
		if echo "$line" | grep -qE 'verified:[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
			has_evidence=true
		fi

		if [[ "$has_evidence" == "false" ]]; then
			failed_tasks+=("$task_id")
			((fail_count++))
		fi
	done <<<"$newly_completed"

	if [[ "$fail_count" -gt 0 ]]; then
		print_error "TODO.md completion proof-log check FAILED"
		print_error ""
		print_error "The following tasks were marked [x] without proof-log evidence:"
		for task in "${failed_tasks[@]}"; do
			print_error "  - $task"
		done
		print_error ""
		print_error "Required: Each completed task must have either:"
		print_error "  1. pr:#NNN field (e.g., pr:#1229)"
		print_error "  2. verified:YYYY-MM-DD field (e.g., verified:$(date +%Y-%m-%d))"
		print_error ""
		print_error "This ensures the issue-sync pipeline can verify deliverables"
		print_error "before auto-closing GitHub issues."
		print_error ""
		print_info "To fix: Add pr:# or verified: to each task line, then retry commit"
		return 1
	fi

	if [[ "$task_count" -gt 0 ]]; then
		print_success "All $task_count completed tasks have proof-log evidence"
	fi

	return 0
}

main() {
	echo -e "${BLUE}Pre-commit Quality Validation${NC}"
	echo -e "${BLUE}================================${NC}"

	# Always run TODO.md validation (even if no shell files changed)
	validate_duplicate_task_ids || {
		print_error "Commit rejected: duplicate task IDs"
		exit 1
	}
	echo ""

	validate_todo_completions || true
	echo ""

	# Get modified shell files
	local modified_files
	mapfile -t modified_files < <(get_modified_shell_files)

	if [[ ${#modified_files[@]} -eq 0 ]]; then
		print_info "No shell files modified, skipping quality checks"
		return 0
	fi

	print_info "Checking ${#modified_files[@]} modified shell files:"
	printf '  %s\n' "${modified_files[@]}"
	echo ""

	local total_violations=0

	# Run validation checks
	validate_return_statements "${modified_files[@]}" || ((total_violations += $?))
	echo ""

	validate_positional_parameters "${modified_files[@]}" || ((total_violations += $?))
	echo ""

	validate_string_literals "${modified_files[@]}" || ((total_violations += $?))
	echo ""

	run_shellcheck "${modified_files[@]}" || ((total_violations += $?))
	echo ""

	check_secrets || ((total_violations += $?))
	echo ""

	check_quality_standards
	echo ""

	# Optional CodeRabbit CLI review (if available)
	if [[ -f ".agents/scripts/coderabbit-cli.sh" ]] && command -v coderabbit &>/dev/null; then
		print_info "🤖 Running CodeRabbit CLI review..."
		if bash .agents/scripts/coderabbit-cli.sh review >/dev/null 2>&1; then
			print_success "CodeRabbit CLI review completed"
		else
			print_info "CodeRabbit CLI review skipped (setup required)"
		fi
		echo ""
	fi

	# Final decision
	if [[ $total_violations -eq 0 ]]; then
		print_success "🎉 All quality checks passed! Commit approved."
		return 0
	else
		print_error "❌ Quality violations detected ($total_violations total)"
		echo ""
		print_info "To fix issues automatically, run:"
		print_info "  ./.agents/scripts/quality-fix.sh"
		echo ""
		print_info "To check current status, run:"
		print_info "  ./.agents/scripts/linters-local.sh"
		echo ""
		print_info "To bypass this check (not recommended), use:"
		print_info "  git commit --no-verify"

		return 1
	fi
}

main "$@"
