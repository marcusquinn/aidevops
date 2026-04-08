#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2001,SC2016,SC2129,SC2155
# Universal Quality Fix Script
# Automatically resolves common quality issues across all platforms

set -euo pipefail

# Source shared constants if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

# Color codes for output (fallback if shared-constants.sh not loaded)
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

print_header() {
	echo -e "${BLUE}AI DevOps Framework - Universal Quality Fix${NC}"
	echo -e "${BLUE}==========================================================${NC}"
	return 0
}

print_success() {
	local message="$1"
	echo -e "${GREEN}[SUCCESS]${NC} $message"
	return 0
}

print_warning() {
	local message="$1"
	echo -e "${YELLOW}[WARNING]${NC} $message"
	return 0
}

print_error() {
	local message="$1"
	echo -e "${RED}[ERROR]${NC} $message" >&2
	return 0
}

print_info() {
	local message="$1"
	echo -e "${BLUE}[INFO]${NC} $message"
	return 0
}
backup_files() {
	print_info "Creating backup of provider files..."

	local backup_dir="backups/$(date +%Y%m%d_%H%M%S)"
	mkdir -p "$backup_dir"

	cp .agents/scripts/*.sh "$backup_dir/"
	# Also backup modularised subdirectory scripts
	while IFS= read -r -d '' file; do
		local destination_dir
		destination_dir="$backup_dir/$(dirname "$file")"
		mkdir -p "$destination_dir"
		cp "$file" "$destination_dir/"
	done < <(find .agents/scripts -mindepth 2 -name "*.sh" -not -path "*/_archive/*" -print0 2>/dev/null)
	print_success "Backup created in $backup_dir"
	return 0
}

fix_return_statements() {
	print_info "Fixing missing return statements (S7682)..."

	local files_fixed=0

	while IFS= read -r -d '' file; do
		[[ -f "$file" ]] || continue
		# Find functions that don't end with return statement
		local temp_file
		temp_file=$(mktemp)
		local file_mode=""
		file_mode=$(stat -f "%Lp" "$file" 2>/dev/null || stat -c "%a" "$file" 2>/dev/null || true)
		local in_function=false
		local function_name=""
		local brace_count=0
		local fixed_functions=0

		while IFS= read -r line; do
			echo "$line" >>"$temp_file"

			# Detect function start
			if [[ $line =~ ^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{ ]]; then
				in_function=true
				function_name=$(echo "$line" | sed 's/().*//')
				brace_count=1
			elif [[ $in_function == true ]]; then
				# Count braces to track function scope
				local open_braces
				open_braces=$(echo "$line" | grep -o '{' | wc -l 2>/dev/null || echo "0")
				local close_braces
				close_braces=$(echo "$line" | grep -o '}' | wc -l 2>/dev/null || echo "0")

				# Ensure variables are numeric
				open_braces=${open_braces//[^0-9]/}
				close_braces=${close_braces//[^0-9]/}
				open_braces=${open_braces:-0}
				close_braces=${close_braces:-0}

				# Fix arithmetic expansion
				local diff
				diff=$((open_braces - close_braces))
				brace_count=$((brace_count + diff))

				# Check if function is ending
				if [[ $brace_count -eq 0 && $line == "}" ]]; then
					# Check if previous line has return statement
					local last_line
					last_line=$(tail -2 "$temp_file" | head -1)

					if [[ ! $last_line =~ return[[:space:]]+[01] ]]; then
						# Remove the closing brace and add return statement
						sed_inplace '$ d' "$temp_file"
						echo "    return 0" >>"$temp_file"
						echo "}" >>"$temp_file"
						((++fixed_functions))
						print_info "Fixed function: $function_name"
					fi

					in_function=false
					function_name=""
				fi
			fi
		done <"$file"

		if [[ $fixed_functions -gt 0 ]]; then
			mv "$temp_file" "$file"
			[[ -n "$file_mode" ]] && chmod "$file_mode" "$file"
			((++files_fixed))
			print_success "Fixed $fixed_functions functions in $file"
		else
			rm -f "$temp_file"
		fi
	done < <(find .agents/scripts -name "*.sh" -not -path "*/_archive/*" -print0 2>/dev/null)

	print_success "Return statements: Fixed $files_fixed files"
	return 0
}

fix_positional_parameters() {
	print_info "Fixing positional parameter violations (S7679)..."

	local files_fixed=0

	while IFS= read -r -d '' file; do
		[[ -f "$file" ]] || continue
		local temp_file
		temp_file=$(mktemp)

		# Process main() functions specifically
		if grep -q "^main() {" "$file"; then
			# Add local variable assignments to main function
			sed '/^main() {/,/^}$/ {
                /^main() {/a\
    # Assign positional parameters to local variables\
    local command="${1:-help}"\
    local account_name="$2"\
    local target="$3"\
    local options="$4"
            }' "$file" >"$temp_file"

			# Replace direct positional parameter usage in case statements
			sed_inplace 's/\$_arg1/\${command}/g; s/\$2/\${account_name}/g; s/\$3/\${target}/g; s/\$4/\${options}/g' "$temp_file"

			if ! diff -q "$file" "$temp_file" >/dev/null; then
				mv "$temp_file" "$file"
				((++files_fixed))
				print_success "Fixed positional parameters in main() function of $file"
			else
				rm -f "$temp_file"
			fi
		fi
	done < <(find .agents/scripts -name "*.sh" -not -path "*/_archive/*" -print0 2>/dev/null)

	print_success "Positional parameters: Fixed $files_fixed files"
	return 0
}

analyze_string_literals() {
	print_info "Analyzing string literals for constants (S1192)..."

	local constants_file
	constants_file=$(mktemp)

	while IFS= read -r -d '' file; do
		[[ -f "$file" ]] || continue
		echo "=== $file ===" >>"$constants_file"

		# Find repeated strings (3+ occurrences)
		(grep -o '"[^"]*"' "$file" || true) | sort | uniq -c | sort -nr | awk '
            $1 >= 3 {
                gsub(/"/, "", $2); cn = toupper($2)
                gsub(/[^A-Z0-9_]/, "_", cn); gsub(/_+/, "_", cn); gsub(/^_|_$/, "", cn)
            }
            $1 >= 3 && length(cn) > 0 {
                printf "readonly %s=\"%s\"  # Used %d times\n", cn, $2, $1
            }' >>"$constants_file"

		echo "" >>"$constants_file"
	done < <(find .agents/scripts -name "*.sh" -not -path "*/_archive/*" -print0 2>/dev/null)

	if [[ -s "$constants_file" ]]; then
		print_warning "String literal constants needed:"
		cat "$constants_file"
		print_info "Add these constants to the top of respective files and replace string literals"
	else
		print_success "No repeated string literals found"
	fi

	rm -f "$constants_file"
	return 0
}

validate_fixes() {
	print_info "Validating fixes with ShellCheck..."

	local validation_errors=0

	while IFS= read -r -d '' file; do
		[[ -f "$file" ]] || continue
		shellcheck "$file" >/dev/null 2>&1 && continue
		((++validation_errors))
		print_warning "ShellCheck issues remain in $file"
	done < <(find .agents/scripts -name "*.sh" -not -path "*/_archive/*" -print0 2>/dev/null)

	if [[ $validation_errors -eq 0 ]]; then
		print_success "All files pass ShellCheck validation"
	else
		print_warning "$validation_errors files still have ShellCheck issues"
	fi
	return 0
}

main() {
	print_header

	# Ensure we're in the right directory
	if [[ ! -d "providers" ]]; then
		print_error "Must be run from the repository root directory"
		exit 1
	fi

	# Create backup before making changes
	backup_files
	echo ""

	# Apply fixes
	fix_return_statements
	echo ""

	fix_positional_parameters
	echo ""

	analyze_string_literals
	echo ""

	validate_fixes
	echo ""

	print_success "Universal quality fixes completed!"
	print_info "Review changes and run linters-local.sh to validate improvements"
	print_info "Commit changes with: git add . && git commit -m 'fix: apply universal quality fixes'"
	return 0
}

main "$@"
