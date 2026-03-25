#!/usr/bin/env bash
# shellcheck disable=SC2317

# AI DevOps Framework - Version Consistency Validator
# Validates that all version references are synchronized across the framework

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit
VERSION_FILE="$REPO_ROOT/VERSION"

# Color output functions
# Function to get current version
get_current_version() {
	if [[ -f "$VERSION_FILE" ]]; then
		cat "$VERSION_FILE"
	else
		echo "1.0.0"
	fi
	return 0
}

# Check VERSION file consistency.
# Arguments: $1 - expected_version, $2 - errors_var_name, $3 - warnings_var_name
_validate_version_file() {
	local expected_version="$1"
	local _ev="$2"
	local _wv="$3"

	if [[ -f "$VERSION_FILE" ]]; then
		local version_file_content
		version_file_content=$(cat "$VERSION_FILE")
		if [[ "$version_file_content" != "$expected_version" ]]; then
			print_error "VERSION file contains '$version_file_content', expected '$expected_version'"
			eval "${_ev}=\$(( \${${_ev}} + 1 ))"
		else
			print_success "VERSION file: $expected_version"
		fi
	else
		print_error "VERSION file not found at $VERSION_FILE"
		eval "${_ev}=\$(( \${${_ev}} + 1 ))"
	fi

	return 0
}

# Check README.md badge consistency.
# Arguments: $1 - expected_version, $2 - errors_var_name, $3 - warnings_var_name
_validate_readme_badge() {
	local expected_version="$1"
	local _ev="$2"
	local _wv="$3"

	if [[ -f "$REPO_ROOT/README.md" ]]; then
		if grep -q "img.shields.io/github/v/release" "$REPO_ROOT/README.md"; then
			print_success "README.md uses dynamic GitHub release badge (recommended)"
		elif grep -q "Version-$expected_version-blue" "$REPO_ROOT/README.md"; then
			print_success "README.md badge: $expected_version"
		else
			local current_badge
			current_badge=$(grep -o "Version-[0-9]\+\.[0-9]\+\.[0-9]\+-blue" "$REPO_ROOT/README.md" || echo "not found")
			if [[ "$current_badge" == "not found" ]]; then
				print_warning "README.md has no version badge (consider adding dynamic GitHub release badge)"
				eval "${_wv}=\$(( \${${_wv}} + 1 ))"
			else
				print_error "README.md badge shows '$current_badge', expected 'Version-$expected_version-blue'"
				eval "${_ev}=\$(( \${${_ev}} + 1 ))"
			fi
		fi
	else
		print_warning "README.md not found"
		eval "${_wv}=\$(( \${${_wv}} + 1 ))"
	fi

	return 0
}

# Check sonar-project.properties, setup.sh, and aidevops.sh consistency.
# Arguments: $1 - expected_version, $2 - errors_var_name, $3 - warnings_var_name
_validate_config_files() {
	local expected_version="$1"
	local _ev="$2"
	local _wv="$3"

	if [[ -f "$REPO_ROOT/sonar-project.properties" ]]; then
		if grep -q "sonar.projectVersion=$expected_version" "$REPO_ROOT/sonar-project.properties"; then
			print_success "sonar-project.properties: $expected_version"
		else
			local current_sonar
			current_sonar=$(grep "sonar.projectVersion=" "$REPO_ROOT/sonar-project.properties" | cut -d'=' -f2 || echo "not found")
			print_error "sonar-project.properties shows '$current_sonar', expected '$expected_version'"
			eval "${_ev}=\$(( \${${_ev}} + 1 ))"
		fi
	else
		print_warning "sonar-project.properties not found"
		eval "${_wv}=\$(( \${${_wv}} + 1 ))"
	fi

	if [[ -f "$REPO_ROOT/setup.sh" ]]; then
		if grep -q "# Version: $expected_version" "$REPO_ROOT/setup.sh"; then
			print_success "setup.sh: $expected_version"
		else
			local current_setup
			current_setup=$(grep "# Version:" "$REPO_ROOT/setup.sh" | cut -d':' -f2 | xargs || echo "not found")
			print_error "setup.sh shows '$current_setup', expected '$expected_version'"
			eval "${_ev}=\$(( \${${_ev}} + 1 ))"
		fi
	else
		print_warning "setup.sh not found"
		eval "${_wv}=\$(( \${${_wv}} + 1 ))"
	fi

	if [[ -f "$REPO_ROOT/aidevops.sh" ]]; then
		if grep -q "# Version: $expected_version" "$REPO_ROOT/aidevops.sh"; then
			print_success "aidevops.sh: $expected_version"
		else
			local current_aidevops
			current_aidevops=$(grep "# Version:" "$REPO_ROOT/aidevops.sh" | head -1 | cut -d':' -f2 | xargs || echo "not found")
			print_error "aidevops.sh shows '$current_aidevops', expected '$expected_version'"
			eval "${_ev}=\$(( \${${_ev}} + 1 ))"
		fi
	else
		print_warning "aidevops.sh not found"
		eval "${_wv}=\$(( \${${_wv}} + 1 ))"
	fi

	return 0
}

# Check package.json, homebrew formula, and marketplace.json consistency.
# Arguments: $1 - expected_version, $2 - errors_var_name, $3 - warnings_var_name
_validate_package_files() {
	local expected_version="$1"
	local _ev="$2"
	local _wv="$3"

	if [[ -f "$REPO_ROOT/package.json" ]]; then
		local pkg_version
		pkg_version=$(jq -r '.version // "not found"' "$REPO_ROOT/package.json" 2>/dev/null || echo "not found")
		if [[ "$pkg_version" == "$expected_version" ]]; then
			print_success "package.json: $expected_version"
		else
			print_error "package.json shows '$pkg_version', expected '$expected_version'"
			eval "${_ev}=\$(( \${${_ev}} + 1 ))"
		fi
	else
		print_warning "package.json not found"
		eval "${_wv}=\$(( \${${_wv}} + 1 ))"
	fi

	if [[ -f "$REPO_ROOT/homebrew/aidevops.rb" ]]; then
		if grep -q "v${expected_version}.tar.gz" "$REPO_ROOT/homebrew/aidevops.rb"; then
			print_success "homebrew/aidevops.rb: v$expected_version"
		else
			local current_formula_version
			current_formula_version=$(grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+\.tar\.gz' "$REPO_ROOT/homebrew/aidevops.rb" | head -1 || echo "not found")
			print_error "homebrew/aidevops.rb shows '$current_formula_version', expected 'v${expected_version}.tar.gz'"
			eval "${_ev}=\$(( \${${_ev}} + 1 ))"
		fi
	fi

	if [[ -f "$REPO_ROOT/.claude-plugin/marketplace.json" ]]; then
		local marketplace_version
		marketplace_version=$(jq -r '.version // .metadata.version // "not found"' "$REPO_ROOT/.claude-plugin/marketplace.json" 2>/dev/null || echo "not found")
		if [[ "$marketplace_version" == "$expected_version" ]]; then
			print_success ".claude-plugin/marketplace.json: $expected_version"
		else
			print_error ".claude-plugin/marketplace.json shows '$marketplace_version', expected '$expected_version'"
			eval "${_ev}=\$(( \${${_ev}} + 1 ))"
		fi
	fi

	return 0
}

# Function to validate version consistency across files
validate_version_consistency() {
	local expected_version="$1"
	local errors=0
	local warnings=0

	print_info "🔍 Validating version consistency across files..."
	print_info "Expected version: $expected_version"
	echo ""

	_validate_version_file "$expected_version" errors warnings
	_validate_readme_badge "$expected_version" errors warnings
	_validate_config_files "$expected_version" errors warnings
	_validate_package_files "$expected_version" errors warnings

	echo ""
	print_info "📊 Validation Summary:"

	if [[ $errors -eq 0 ]]; then
		print_success "All version references are consistent: $expected_version"
		if [[ $warnings -gt 0 ]]; then
			print_warning "Found $warnings optional files missing (not critical)"
		fi
		return 0
	else
		print_error "Found $errors version inconsistencies"
		if [[ $warnings -gt 0 ]]; then
			print_warning "Found $warnings optional files missing"
		fi
		return 1
	fi
	return 0
}

# Main function
main() {
	local version_to_check="$1"

	if [[ -z "$version_to_check" ]]; then
		version_to_check=$(get_current_version)
		print_info "No version specified, using current version from VERSION file: $version_to_check"
	fi

	validate_version_consistency "$version_to_check"
	return 0
}

main "${1:-}"
