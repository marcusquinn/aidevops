#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2129
set -euo pipefail

# Interactive Linter Setup Wizard
# Intelligent assessment of user needs for targeted linter installation
# Based on CodeFactor's comprehensive linter collection
#
# Author: AI DevOps Framework
# Version: 1.1.1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Common constants
print_question() {
	local _arg1="$1"
	echo -e "${CYAN}❓ $_arg1${NC}"
	return 0
}

print_header() {
	local _arg1="$1"
	echo -e "${PURPLE}🔧 $_arg1${NC}"
	echo "=========================================="
	return 0
}

# Ask yes/no question
ask_yes_no() {
	local question="$1"
	local default="${2:-n}"
	local response

	while true; do
		if [[ "$default" == "y" ]]; then
			print_question "$question [Y/n]: "
		else
			print_question "$question [y/N]: "
		fi

		read -r response
		response=${response:-$default}

		case "$response" in
		[Yy] | [Yy][Ee][Ss])
			return 0
			;;
		[Nn] | [Nn][Oo])
			return 1
			;;
		*)
			print_warning "Please answer yes (y) or no (n)"
			;;
		esac
	done
	return 0
}

# Ask multiple choice question
ask_choice() {
	local question="$1"
	shift
	local options=("$@")
	local choice

	print_question "$question"
	for i in "${!options[@]}"; do
		echo "  $((i + 1)). ${options[i]}"
	done

	while true; do
		print_question "Enter choice (1-${#options[@]}): "
		read -r choice

		if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#options[@]}" ]]; then
			echo "${options[$((choice - 1))]}"
			return 0
		else
			print_warning "Please enter a number between 1 and ${#options[@]}"
		fi
	done
	return 0
}

# Collect development type, team size, and quality focus answers
# Outputs three lines to stdout: development_type, team_size, quality_focus
_assess_project_context() {
	print_info "Let's understand your development environment..."
	echo ""

	local development_type
	development_type=$(ask_choice "What type of development do you primarily do?" \
		"Web Development (Frontend/Backend)" \
		"Data Science/Machine Learning" \
		"DevOps/Infrastructure" \
		"Mobile Development" \
		"Desktop Applications" \
		"Full-Stack Development" \
		"Other/Mixed")

	echo ""
	print_info "Development type: $development_type"
	echo ""

	local team_size
	team_size=$(ask_choice "What's your team size?" \
		"Solo developer" \
		"Small team (2-5 people)" \
		"Medium team (6-15 people)" \
		"Large team (16+ people)")

	echo ""
	print_info "Team size: $team_size"
	echo ""

	local quality_focus
	quality_focus=$(ask_choice "What's your primary quality focus?" \
		"Code style and formatting" \
		"Security and vulnerabilities" \
		"Performance optimization" \
		"Maintainability and complexity" \
		"All of the above")

	echo ""
	print_info "Quality focus: $quality_focus"
	echo ""

	# Output results as lines for the caller to read back
	printf '%s\n' "$development_type" "$team_size" "$quality_focus"
	return 0
}

# Prompt for each language/technology and append selections to the cache file
# Appends one language token per line to the provided cache file path
_assess_languages() {
	local cache_file="$1"

	print_header "Language and Technology Assessment"

	# Python
	if ask_yes_no "Do you work with Python?" "n"; then
		echo "python" >>"$cache_file"
		print_info "Python linters: pycodestyle (PEP 8), Pylint (comprehensive), Bandit (security), Ruff (fast)"
	fi

	# JavaScript/TypeScript
	if ask_yes_no "Do you work with JavaScript or TypeScript?" "n"; then
		echo "javascript" >>"$cache_file"
		print_info "JavaScript linters: ESLint (standard), TypeScript ESLint (TS support)"
	fi

	# CSS/SCSS/Less
	if ask_yes_no "Do you work with CSS, SCSS, or Less?" "n"; then
		echo "css" >>"$cache_file"
		print_info "CSS linters: Stylelint (comprehensive CSS/SCSS/Less)"
	fi

	# Shell scripting
	if ask_yes_no "Do you write shell scripts?" "y"; then
		echo "shell" >>"$cache_file"
		print_info "Shell linters: ShellCheck (comprehensive shell script analysis)"
	fi

	# Docker
	if ask_yes_no "Do you work with Docker?" "n"; then
		echo "docker" >>"$cache_file"
		print_info "Docker linters: Hadolint (Dockerfile best practices)"
	fi

	# YAML
	if ask_yes_no "Do you work with YAML files (configs, CI/CD)?" "y"; then
		echo "yaml" >>"$cache_file"
		print_info "YAML linters: yamllint (YAML syntax and style)"
	fi

	# Security scanning
	if ask_yes_no "Do you want security vulnerability scanning?" "y"; then
		echo "security" >>"$cache_file"
		print_info "Security linters: Trivy (comprehensive vulnerability scanning)"
	fi

	return 0
}

# Assess development environment and needs
assess_development_needs() {
	print_header "Development Environment Assessment"

	# Collect project context (dev type, team size, quality focus)
	local context_output
	context_output=$(_assess_project_context)

	local development_type team_size quality_focus
	development_type=$(printf '%s\n' "$context_output" | sed -n '1p')
	team_size=$(printf '%s\n' "$context_output" | sed -n '2p')
	quality_focus=$(printf '%s\n' "$context_output" | sed -n '3p')

	# Write context to cache file
	printf '%s\n' "$development_type" "$team_size" "$quality_focus" >.linter-setup-cache

	# Collect language selections (appends to cache file)
	_assess_languages ".linter-setup-cache"

	# Read back selected languages for the summary message
	local languages=()
	while IFS= read -r line; do
		languages+=("$line")
	done < <(tail -n +4 .linter-setup-cache)

	echo ""
	print_success "Assessment complete! Selected languages: ${languages[*]}"

	return 0
}

# Install selected linters with recommendations
install_selected_linters() {
	print_header "Installing Selected Linters"

	if [[ ! -f ".linter-setup-cache" ]]; then
		print_error "No assessment data found. Run assessment first."
		return 1
	fi

	local lines=()
	while IFS= read -r line; do
		lines+=("$line")
	done <.linter-setup-cache

	local development_type="${lines[0]}"
	local team_size="${lines[1]}"
	local quality_focus="${lines[2]}"
	local languages=("${lines[@]:3}")

	print_info "Installing linters for: ${languages[*]}"
	echo ""

	# Provide CodeFactor-based recommendations
	print_header "CodeFactor Recommendations"

	case "$quality_focus" in
	"Code style and formatting")
		print_info "Focus: Code Style & Formatting"
		print_info "Recommended: ESLint (JS), Pylint (Python), Stylelint (CSS)"
		;;
	"Security and vulnerabilities")
		print_info "Focus: Security & Vulnerabilities"
		print_info "Recommended: Bandit (Python), Trivy (containers), ESLint security rules"
		;;
	"Performance optimization")
		print_info "Focus: Performance Optimization"
		print_info "Recommended: Ruff (fast Python), ESLint performance rules"
		;;
	"Maintainability and complexity")
		print_info "Focus: Maintainability & Complexity"
		print_info "Recommended: Pylint (complexity), ESLint complexity rules"
		;;
	"All of the above" | *)
		print_info "Focus: Comprehensive Quality"
		print_info "Recommended: Full CodeFactor suite for selected languages"
		;;
	esac

	echo ""

	# Install linters for each selected language
	local total_failures=0

	for lang in "${languages[@]}"; do
		print_info "Installing $lang linters..."
		if bash "$(dirname "$0")/linter-manager.sh" install "$lang"; then
			print_success "$lang linters installed successfully"
		else
			print_warning "Some $lang linters failed to install"
			((++total_failures))
		fi
		echo ""
	done

	# Clean up cache
	rm -f .linter-setup-cache

	# Provide next steps
	print_header "Next Steps & AI Agent Knowledge"

	print_info "✅ Linter installation complete!"
	echo ""
	print_info "🤖 AI Agent Knowledge Updated:"
	print_info "- Your development type: $development_type"
	print_info "- Team size: $team_size"
	print_info "- Quality focus: $quality_focus"
	print_info "- Installed linters: ${languages[*]}"
	echo ""
	print_info "📚 Available Commands:"
	print_info "- Run analysis: bash .agents/scripts/quality-cli-manager.sh analyze all"
	print_info "- Auto-fix issues: bash .agents/scripts/codacy-cli.sh analyze --fix"
	print_info "- Universal formatting: bash .agents/scripts/qlty-cli.sh fmt --all"
	print_info "- Install additional linters: bash .agents/scripts/linter-manager.sh install LANGUAGE"
	echo ""
	print_info "🔧 CodeFactor Integration:"
	print_info "- Your setup follows CodeFactor's professional linter collection"
	print_info "- Additional languages can be added as needs arise"
	print_info "- AI agents have knowledge of all CodeFactor-recommended tools"

	return $total_failures
}

# Show help
show_help() {
	echo "Interactive Linter Setup Wizard"
	echo ""
	echo "Usage: $0 <command>"
	echo ""
	echo "Commands:"
	echo "  assess               - Assess development needs and recommend linters"
	echo "  install              - Install linters based on assessment"
	echo "  full-setup           - Complete assessment and installation"
	echo "  help                 - Show this help message"
	echo ""
	echo "Features:"
	echo "  🎯 Intelligent needs assessment"
	echo "  🔧 CodeFactor-based recommendations"
	echo "  📊 Development type optimization"
	echo "  🤖 AI agent knowledge integration"
	echo "  ⚡ Install only what you need"
	echo ""
	echo "Examples:"
	echo "  $0 full-setup        # Complete guided setup"
	echo "  $0 assess            # Just assess needs"
	echo "  $0 install           # Install based on previous assessment"
	echo ""
	echo "Based on CodeFactor's professional linter collection:"
	echo "https://docs.codefactor.io/bootcamp/analysis-tools/"
	return 0
}

# Main execution
main() {
	local command="$1"

	case "$command" in
	"assess")
		assess_development_needs
		;;
	"install")
		install_selected_linters
		;;
	"full-setup")
		print_header "Complete Linter Setup Wizard"
		echo ""
		if assess_development_needs; then
			echo ""
			if ask_yes_no "Proceed with installation?" "y"; then
				install_selected_linters
			else
				print_info "Assessment saved. Run '$0 install' when ready."
			fi
		fi
		;;
	"help" | "--help" | "-h" | "")
		show_help
		;;
	*)
		print_error "$ERROR_UNKNOWN_COMMAND $command"
		echo ""
		show_help
		return 1
		;;
	esac
	return 0
}

main "$@"
