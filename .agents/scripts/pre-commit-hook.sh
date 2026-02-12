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

# Validate TODO.md task completion transitions (t163.3)
# When [ ] -> [x], warn if no merged PR evidence exists for the task
validate_todo_completions() {
	# Only check if TODO.md is staged
	if ! git diff --cached --name-only | grep -q '^TODO\.md$'; then
		return 0
	fi

	print_info "Validating TODO.md task completions..."

	# Find top-level tasks that changed from [ ] to [x] in this commit
	# Subtasks inherit evidence from their parent task, so only check top-level
	local newly_completed
	newly_completed=$(git diff --cached -U0 TODO.md | grep -E '^\+- \[x\] t[0-9]+' | sed 's/^\+//' || true)

	if [[ -z "$newly_completed" ]]; then
		return 0
	fi

	local task_count=0
	local warn_count=0
	while IFS= read -r line; do
		local task_id
		task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		if [[ -z "$task_id" ]]; then
			continue
		fi
		task_count=$((task_count + 1))

		# Check for evidence: verified: field, "PR #NNN merged" text, or gh API lookup
		local has_evidence=false

		if echo "$line" | grep -qE 'verified:[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
			has_evidence=true
		fi

		if [[ "$has_evidence" == "false" ]] && echo "$line" | grep -qiE 'PR #[0-9]+ merged|PR.*merged'; then
			has_evidence=true
		fi

		if [[ "$has_evidence" == "false" ]] && command -v gh &>/dev/null; then
			local repo_slug
			repo_slug=$(git remote get-url origin 2>/dev/null | grep -oE '[^/:]+/[^/.]+' | tail -1 || echo "")
			if [[ -n "$repo_slug" ]]; then
				local merged_pr
				merged_pr=$(gh pr list --repo "$repo_slug" --state merged --search "$task_id in:title" --limit 1 --json number --jq '.[0].number' 2>/dev/null || echo "")
				if [[ -n "$merged_pr" ]]; then
					has_evidence=true
				fi
			fi
		fi

		if [[ "$has_evidence" == "false" ]]; then
			print_warning "  $task_id: marked [x] but no merged PR or verified: field found"
			warn_count=$((warn_count + 1))
		fi
	done <<<"$newly_completed"

	if [[ "$warn_count" -gt 0 ]]; then
		print_warning "$warn_count of $task_count newly completed tasks lack completion evidence"
		print_info "  Add 'verified:$(date +%Y-%m-%d)' to the task line, or ensure a merged PR exists"
		print_info "  This is a WARNING only - commit will proceed"
	fi

	return 0
}

# Validate TODO.md has no duplicate task IDs (t319.5)
# Scans staged TODO.md for any tNNN that appears as the defining ID on more than
# one task line (- [ ] or - [x]). Excludes inline references like blocked-by:tNNN,
# blocks:tNNN, and other metadata fields. Rejects the commit if duplicates found.
validate_duplicate_task_ids() {
	# Only check if TODO.md is staged
	if ! git diff --cached --name-only | grep -q '^TODO\.md$'; then
		return 0
	fi

	print_info "Checking for duplicate task IDs in TODO.md..."

	# Extract the staged version of TODO.md and find all task-defining lines.
	# A task-defining line matches: optional whitespace, "- [ ]" or "- [x]" or "- [-]",
	# then whitespace, then a task ID (tNNN or tNNN.N or tNNN.N.N).
	# We extract only the leading task ID (the one that defines the task).
	local task_ids
	task_ids=$(git show :TODO.md 2>/dev/null |
		grep -E '^[[:space:]]*- \[[x ]\] t[0-9]+' |
		sed -E 's/^[[:space:]]*- \[[x ]\] (t[0-9]+(\.[0-9]+)*).*/\1/' ||
		true)

	if [[ -z "$task_ids" ]]; then
		return 0
	fi

	# Find duplicates
	local duplicates
	duplicates=$(echo "$task_ids" | sort | uniq -d || true)

	if [[ -z "$duplicates" ]]; then
		print_success "No duplicate task IDs found"
		return 0
	fi

	# Report each duplicate with its count
	print_error "Duplicate task IDs found in TODO.md!"
	local dup_count=0
	while IFS= read -r dup_id; do
		[[ -z "$dup_id" ]] && continue
		local count
		count=$(echo "$task_ids" | grep -c "^${dup_id}$" || echo "0")
		print_error "  $dup_id appears $count times as a task definition"
		dup_count=$((dup_count + 1))
	done <<<"$duplicates"

	echo ""
	print_error "Each task ID must be unique. Fix duplicates before committing."
	print_info "  Use 'claim-task-id.sh' to allocate unique IDs"
	print_info "  Or manually renumber the duplicate to the next available ID"

	return "$dup_count"
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
