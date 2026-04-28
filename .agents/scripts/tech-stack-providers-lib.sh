#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tech Stack Providers Library -- Provider management, URL utilities, dependencies
# =============================================================================
# Covers provider registration, availability checks, URL normalisation,
# dependency detection, and single-provider execution.
#
# Usage: source "${SCRIPT_DIR}/tech-stack-providers-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (log_*, print_*, CYAN, GREEN, RED, YELLOW, NC)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_TECH_STACK_PROVIDERS_LIB_LOADED:-}" ]] && return 0
_TECH_STACK_PROVIDERS_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Provider Registry
# =============================================================================

# Map provider name to helper script filename
provider_script() {
	local provider="$1"
	case "$provider" in
	unbuilt) echo "unbuilt-provider-helper.sh" ;;
	crft) echo "crft-provider-helper.sh" ;;
	openexplorer) echo "openexplorer-provider-helper.sh" ;;
	wappalyzer) echo "wappalyzer-provider-helper.sh" ;;
	*) echo "" ;;
	esac
	return 0
}

# Map provider name to display name
provider_display_name() {
	local provider="$1"
	case "$provider" in
	unbuilt) echo "Unbuilt.app" ;;
	crft) echo "CRFT Lookup" ;;
	openexplorer) echo "Open Tech Explorer" ;;
	wappalyzer) echo "Wappalyzer OSS" ;;
	*) echo "$provider" ;;
	esac
	return 0
}

# =============================================================================
# Dependencies
# =============================================================================

check_dependencies() {
	local missing=()

	if ! command -v jq &>/dev/null; then
		missing+=("jq")
	fi

	if ! command -v sqlite3 &>/dev/null; then
		missing+=("sqlite3")
	fi

	if ! command -v curl &>/dev/null; then
		missing+=("curl")
	fi

	if [[ ${#missing[@]} -gt 0 ]]; then
		log_error "Missing required tools: ${missing[*]}"
		log_info "Install with: brew install ${missing[*]}"
		return 1
	fi

	return 0
}

# =============================================================================
# URL Normalization
# =============================================================================

normalize_url() {
	local url="$1"

	# Add https:// if no protocol specified
	if [[ ! "$url" =~ ^https?:// ]]; then
		url="https://${url}"
	fi

	# Remove trailing slash
	url="${url%/}"

	echo "$url"
	return 0
}

# Extract domain from URL for cache key
extract_domain() {
	local url="$1"

	# Remove protocol
	local domain="${url#*://}"
	# Remove path
	domain="${domain%%/*}"
	# Remove port
	domain="${domain%%:*}"

	echo "$domain"
	return 0
}

# =============================================================================
# Provider Management
# =============================================================================

# List available providers and their status
list_providers() {
	echo -e "${CYAN}=== Tech Stack Providers ===${NC}"
	echo ""

	local provider
	for provider in $PROVIDERS; do
		local script
		script=$(provider_script "$provider")
		local name
		name=$(provider_display_name "$provider")
		local script_path="${SCRIPT_DIR}/${script}"
		local status

		if [[ -x "$script_path" ]]; then
			status="${GREEN}available${NC}"
		elif [[ -f "$script_path" ]]; then
			status="${YELLOW}not executable${NC}"
		else
			status="${RED}not installed${NC}"
		fi

		printf "  %-15s %-25s %b\n" "$provider" "$name" "$status"
	done

	echo ""
	echo "Provider helpers are installed by tasks t1064-t1067."
	echo "Each provider implements: lookup <url> --json"

	return 0
}

# Check if a specific provider is available
is_provider_available() {
	local provider="$1"

	local script
	script=$(provider_script "$provider")
	if [[ -z "$script" ]]; then
		return 1
	fi

	local script_path="${SCRIPT_DIR}/${script}"
	if [[ -x "$script_path" ]]; then
		return 0
	fi

	return 1
}

# Get list of available providers
get_available_providers() {
	local available=()
	local provider

	for provider in $PROVIDERS; do
		if is_provider_available "$provider"; then
			available+=("$provider")
		fi
	done

	if [[ ${#available[@]} -eq 0 ]]; then
		echo ""
		return 1
	fi

	echo "${available[*]}"
	return 0
}

# Run a single provider lookup
run_provider() {
	local provider="$1"
	local url="$2"
	local timeout_secs="$3"

	local script
	script=$(provider_script "$provider")
	local script_path="${SCRIPT_DIR}/${script}"

	if [[ ! -x "$script_path" ]]; then
		log_warning "Provider '${provider}' not available: ${script_path}"
		echo '{"error":"provider_not_available","provider":"'"$provider"'"}'
		return 1
	fi

	local result
	if result=$(timeout "$timeout_secs" "$script_path" lookup "$url" --json 2>/dev/null); then
		# Validate JSON
		if echo "$result" | jq empty 2>/dev/null; then
			echo "$result"
			return 0
		else
			log_warning "Provider '${provider}' returned invalid JSON"
			echo '{"error":"invalid_json","provider":"'"$provider"'"}'
			return 1
		fi
	else
		local exit_code=$?
		if [[ $exit_code -eq 124 ]]; then
			log_warning "Provider '${provider}' timed out after ${timeout_secs}s"
			echo '{"error":"timeout","provider":"'"$provider"'"}'
		else
			log_warning "Provider '${provider}' failed with exit code ${exit_code}"
			echo '{"error":"provider_failed","provider":"'"$provider"'","exit_code":'"$exit_code"'}'
		fi
		return 1
	fi
}
