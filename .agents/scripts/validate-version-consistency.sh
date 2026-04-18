#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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

compute_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256
	else
		return 1
	fi
	return 0
}

# fetch_with_retry <url>
# Retries up to 3 times with exponential backoff (5s, 10s, 20s).
# Streams response body to stdout on success; logs attempts to stderr.
# Safe for binary data (no variable capture).
fetch_with_retry() {
	local url="$1"
	local attempt=0
	local max_attempts=3
	local delay=5

	while [[ $attempt -lt $max_attempts ]]; do
		if curl -fsSL --max-time 30 "$url" 2>/dev/null; then
			return 0
		fi
		attempt=$((attempt + 1))
		if [[ $attempt -lt $max_attempts ]]; then
			print_warning "curl attempt $attempt/$max_attempts failed for $url — retrying in ${delay}s" >&2
			sleep "$delay"
			delay=$((delay * 2))
		fi
	done

	print_error "Failed to fetch $url after $max_attempts attempts" >&2
	return 1
}

# Check VERSION file consistency
# Arguments: expected_version
# Outputs: increments _vc_errors on mismatch
_check_version_file() {
	local expected_version="$1"
	if [[ -f "$VERSION_FILE" ]]; then
		local version_file_content
		version_file_content=$(cat "$VERSION_FILE")
		if [[ "$version_file_content" != "$expected_version" ]]; then
			print_error "VERSION file contains '$version_file_content', expected '$expected_version'"
			_vc_errors=$((_vc_errors + 1))
		else
			print_success "VERSION file: $expected_version"
		fi
	else
		print_error "VERSION file not found at $VERSION_FILE"
		_vc_errors=$((_vc_errors + 1))
	fi
	return 0
}

# Check README badge consistency
# Arguments: expected_version, repo_root
# Outputs: increments _vc_errors or _vc_warnings on mismatch
_check_readme_badge() {
	local expected_version="$1"
	local repo_root="$2"
	if [[ -f "$repo_root/README.md" ]]; then
		if grep -q "img.shields.io/github/v/release" "$repo_root/README.md"; then
			print_success "README.md uses dynamic GitHub release badge (recommended)"
		elif grep -q "Version-$expected_version-blue" "$repo_root/README.md"; then
			print_success "README.md badge: $expected_version"
		else
			local current_badge
			current_badge=$(grep -o "Version-[0-9]\+\.[0-9]\+\.[0-9]\+-blue" "$repo_root/README.md" || echo "not found")
			if [[ "$current_badge" == "not found" ]]; then
				print_warning "README.md has no version badge (consider adding dynamic GitHub release badge)"
				_vc_warnings=$((_vc_warnings + 1))
			else
				print_error "README.md badge shows '$current_badge', expected 'Version-$expected_version-blue'"
				_vc_errors=$((_vc_errors + 1))
			fi
		fi
	else
		print_warning "README.md not found"
		_vc_warnings=$((_vc_warnings + 1))
	fi
	return 0
}

# Check sonar-project.properties version
# Arguments: expected_version, repo_root
# Outputs: increments _vc_errors or _vc_warnings on mismatch
_check_sonar_properties() {
	local expected_version="$1"
	local repo_root="$2"
	if [[ -f "$repo_root/sonar-project.properties" ]]; then
		if grep -q "sonar.projectVersion=$expected_version" "$repo_root/sonar-project.properties"; then
			print_success "sonar-project.properties: $expected_version"
		else
			local current_sonar
			current_sonar=$(grep "sonar.projectVersion=" "$repo_root/sonar-project.properties" | cut -d'=' -f2 || echo "not found")
			print_error "sonar-project.properties shows '$current_sonar', expected '$expected_version'"
			_vc_errors=$((_vc_errors + 1))
		fi
	else
		print_warning "sonar-project.properties not found"
		_vc_warnings=$((_vc_warnings + 1))
	fi
	return 0
}

# Check version comment in a shell script (setup.sh, aidevops.sh)
# Arguments: expected_version, file_path, label
# Outputs: increments _vc_errors or _vc_warnings on mismatch
_check_shell_script_version() {
	local expected_version="$1"
	local file_path="$2"
	local label="$3"
	if [[ -f "$file_path" ]]; then
		if grep -q "# Version: $expected_version" "$file_path"; then
			print_success "$label: $expected_version"
		else
			local current_ver
			current_ver=$(grep "# Version:" "$file_path" | head -1 | cut -d':' -f2 | xargs || echo "not found")
			print_error "$label shows '$current_ver', expected '$expected_version'"
			_vc_errors=$((_vc_errors + 1))
		fi
	else
		print_warning "$label not found"
		_vc_warnings=$((_vc_warnings + 1))
	fi
	return 0
}

# Check package.json version
# Arguments: expected_version, repo_root
# Outputs: increments _vc_errors or _vc_warnings on mismatch
_check_package_json() {
	local expected_version="$1"
	local repo_root="$2"
	if [[ -f "$repo_root/package.json" ]]; then
		local pkg_version
		pkg_version=$(jq -r '.version // "not found"' "$repo_root/package.json" 2>/dev/null || echo "not found")
		if [[ "$pkg_version" == "$expected_version" ]]; then
			print_success "package.json: $expected_version"
		else
			print_error "package.json shows '$pkg_version', expected '$expected_version'"
			_vc_errors=$((_vc_errors + 1))
		fi
	else
		print_warning "package.json not found"
		_vc_warnings=$((_vc_warnings + 1))
	fi
	return 0
}

# Check homebrew/aidevops.rb against the referenced released tag, not VERSION.
# The source-repo formula intentionally stays on the latest released tarball
# until publish-packages.yml updates it after release publication.
# Arguments: repo_root
# Outputs: increments _vc_errors on mismatch
_check_homebrew_formula() {
	local repo_root="$1"
	if [[ ! -f "$repo_root/homebrew/aidevops.rb" ]]; then
		return 0
	fi
	local formula_version
	local formula_tag
	local formula_sha
	formula_version=$(grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+\.tar\.gz' "$repo_root/homebrew/aidevops.rb" | head -1 | sed 's/^v//; s/\.tar\.gz$//' || echo "")
	formula_sha=$(grep -o 'sha256 "[^"]\+"' "$repo_root/homebrew/aidevops.rb" | head -1 | cut -d'"' -f2 || echo "")

	if [[ -z "$formula_version" ]]; then
		print_error "homebrew/aidevops.rb version URL not found"
		_vc_errors=$((_vc_errors + 1))
		return 0
	fi
	if [[ -z "$formula_sha" ]]; then
		print_error "homebrew/aidevops.rb sha256 not found"
		_vc_errors=$((_vc_errors + 1))
		return 0
	fi

	formula_tag="v${formula_version}"
	if git rev-parse -q --verify "refs/tags/${formula_tag}" >/dev/null 2>&1 || git ls-remote -q --exit-code --tags origin "refs/tags/${formula_tag}" >/dev/null 2>&1; then
		local release_sha
		release_sha=$(fetch_with_retry "https://github.com/marcusquinn/aidevops/archive/refs/tags/${formula_tag}.tar.gz" | compute_sha256 | cut -d' ' -f1)
		if [[ -z "$release_sha" ]]; then
			print_error "homebrew/aidevops.rb checksum lookup failed for ${formula_tag}"
			_vc_errors=$((_vc_errors + 1))
		elif [[ "$formula_sha" == "$release_sha" ]]; then
			print_success "homebrew/aidevops.rb: ${formula_tag} checksum verified"
		else
			print_error "homebrew/aidevops.rb checksum mismatch for ${formula_tag}"
			_vc_errors=$((_vc_errors + 1))
		fi
	else
		print_error "homebrew/aidevops.rb references unreleased tag ${formula_tag}; leave formula pinned to the latest published release"
		_vc_errors=$((_vc_errors + 1))
	fi
	return 0
}

# Check .claude-plugin/marketplace.json version (optional)
# Arguments: expected_version, repo_root
# Outputs: increments _vc_errors on mismatch
_check_marketplace_json() {
	local expected_version="$1"
	local repo_root="$2"
	if [[ ! -f "$repo_root/.claude-plugin/marketplace.json" ]]; then
		return 0
	fi
	local marketplace_version
	marketplace_version=$(jq -r '.version // .metadata.version // "not found"' "$repo_root/.claude-plugin/marketplace.json" 2>/dev/null || echo "not found")
	if [[ "$marketplace_version" == "$expected_version" ]]; then
		print_success ".claude-plugin/marketplace.json: $expected_version"
	else
		print_error ".claude-plugin/marketplace.json shows '$marketplace_version', expected '$expected_version'"
		_vc_errors=$((_vc_errors + 1))
	fi
	return 0
}

# Check config/build file version references (sonar, setup.sh, aidevops.sh, package.json, homebrew, marketplace)
# Arguments: expected_version, repo_root
# Outputs: increments _vc_errors or _vc_warnings on mismatch
_check_config_files() {
	local expected_version="$1"
	local repo_root="$2"

	_check_sonar_properties "$expected_version" "$repo_root"
	_check_shell_script_version "$expected_version" "$repo_root/setup.sh" "setup.sh"
	_check_shell_script_version "$expected_version" "$repo_root/aidevops.sh" "aidevops.sh"
	_check_package_json "$expected_version" "$repo_root"
	_check_homebrew_formula "$repo_root"
	_check_marketplace_json "$expected_version" "$repo_root"
	return 0
}

# Print validation summary and return appropriate exit code
# Arguments: expected_version
# Reads: _vc_errors, _vc_warnings
_print_validation_summary() {
	local expected_version="$1"
	echo ""
	print_info "📊 Validation Summary:"
	if [[ $_vc_errors -eq 0 ]]; then
		print_success "All version references are consistent: $expected_version"
		if [[ $_vc_warnings -gt 0 ]]; then
			print_warning "Found $_vc_warnings optional files missing (not critical)"
		fi
		return 0
	else
		print_error "Found $_vc_errors version inconsistencies"
		if [[ $_vc_warnings -gt 0 ]]; then
			print_warning "Found $_vc_warnings optional files missing"
		fi
		return 1
	fi
}

# Function to validate version consistency across files
validate_version_consistency() {
	local expected_version="$1"
	# Shared counters used by sub-functions
	_vc_errors=0
	_vc_warnings=0

	print_info "🔍 Validating version consistency across files..."
	print_info "Expected version: $expected_version"
	echo ""

	_check_version_file "$expected_version"
	_check_readme_badge "$expected_version" "$REPO_ROOT"
	_check_config_files "$expected_version" "$REPO_ROOT"
	_print_validation_summary "$expected_version"
	return $?
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
