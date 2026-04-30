#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2001,SC2034,SC2181,SC2317
# =============================================================================
# Version Manager — File Update Functions
# =============================================================================
# Version file update and consistency validation functions extracted from
# version-manager.sh to reduce file size.
#
# Covers:
#   - Updating VERSION, package.json, README.md, setup.sh, etc.
#   - Version consistency validation
#   - Script header version reference updates
#
# Usage: source "${SCRIPT_DIR}/version-manager-files.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning,
#     sed_inplace)
#   - REPO_ROOT and VERSION_FILE must be set by the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_VERSION_MANAGER_FILES_LOADED:-}" ]] && return 0
_VERSION_MANAGER_FILES_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

# Function to validate version consistency across files
# Delegates to the standalone validator script for single source of truth
validate_version_consistency() {
	local expected_version="$1"
	local validator_script="${REPO_ROOT}/.agents/scripts/validate-version-consistency.sh"

	print_info "Validating version consistency across files..."

	if [[ -f "$validator_script" ]]; then
		# Use the standalone validator (single source of truth)
		bash "$validator_script" "$expected_version"
		return $?
	else
		# Fallback: basic validation if standalone script not found
		print_warning "Standalone validator not found, using basic validation"

		local errors=0

		# Check VERSION file
		if [[ -f "$VERSION_FILE" ]]; then
			local version_file_content
			version_file_content=$(cat "$VERSION_FILE")
			if [[ "$version_file_content" != "$expected_version" ]]; then
				print_error "VERSION file contains '$version_file_content', expected '$expected_version'"
				errors=$((errors + 1))
			else
				print_success "VERSION file: $expected_version ✓"
			fi
		else
			print_error "VERSION file not found"
			errors=$((errors + 1))
		fi

		if [[ $errors -eq 0 ]]; then
			print_success "Basic version validation passed: $expected_version"
			return 0
		else
			print_error "Found $errors version inconsistencies"
			return 1
		fi
	fi
}

# Update the README.md version badge (hardcoded or dynamic).
# All output goes to stderr. Returns 0 on success, 1 on failure.
# Increments the caller's errors counter via stdout ("1" on failure, "0" on success).
_update_readme_version_badge() {
	local new_version="$1"
	local dynamic_badge_pattern="img.shields.io/github/v/release"
	local hardcoded_badge_pattern="Version-[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*-blue"

	if [[ ! -f "$REPO_ROOT/README.md" ]]; then
		print_warning "README.md not found, skipping version badge update" >&2
		return 0
	fi

	if grep -q "$dynamic_badge_pattern" "$REPO_ROOT/README.md"; then
		# Dynamic badge - no update needed, GitHub handles it automatically
		print_success "README.md uses dynamic GitHub release badge (no update needed)" >&2
	elif grep -q "$hardcoded_badge_pattern" "$REPO_ROOT/README.md"; then
		# Hardcoded badge - update it
		sed_inplace "s/$hardcoded_badge_pattern/Version-$new_version-blue/" "$REPO_ROOT/README.md"
		if grep -q "Version-$new_version-blue" "$REPO_ROOT/README.md"; then
			print_success "Updated README.md version badge to $new_version" >&2
		else
			print_error "Failed to update README.md version badge"
			return 1
		fi
	else
		# No version badge found - that's okay, just warn
		print_warning "README.md has no version badge (consider adding dynamic GitHub release badge)" >&2
	fi
	return 0
}

# Keep the source-repo Homebrew formula pinned to the last released tag.
# The release workflow updates both the version and SHA256 after the tag exists,
# then syncs the corrected formula back into the repo and tap.
# All output goes to stderr. Returns 0 on success, 1 on failure.
_update_homebrew_formula() {
	local new_version="$1"

	# The GitHub-generated release tarball checksum cannot be known until the tag
	# exists remotely. Do not rewrite the formula during the pre-release bump or
	# we leave the repo with a broken URL/SHA pair that review bots correctly flag.
	# The publish-packages workflow performs the post-release formula update.
	if [[ -n "$new_version" ]]; then
		print_info "Leaving homebrew/aidevops.rb unchanged until release tarball exists" >&2
	fi
	unset new_version
	return 0
}

# Update the JSON "version" field in a given file.
# Shared helper used by _update_claude_plugin_version and _update_package_json_version
# to avoid repeating the escaped sed/grep pattern for the "version" JSON key.
# All output goes to stderr. Returns 0 on success, 1 on failure.
# Arguments: file new_version display_name
#
# Race-resistant validation (t3202): after the sed_inplace, validate using the
# SAME jq query the final validator (validate-version-consistency.sh) uses.
# This ensures updater and validator cannot disagree at the read-path level.
# A defensive fs sync + retry covers the rare case where post-rename inode
# cache serves stale content to a follow-on reader on macOS APFS, and where
# an external writer briefly steps on the file between sed and validate.
# Canonical failure: v3.13.13 release, 2026-04-30 (issue #21905).
_update_json_version_field() {
	local file="$1"
	local new_version="$2"
	local display_name="$3"
	local ver_key='"version"'

	sed_inplace "s/${ver_key}: *\"[^\"]*\"/${ver_key}: \"$new_version\"/" "$file"

	# Defensive fs flush — closes the rare post-rename cache window observed
	# during back-to-back sed_inplace + jq read on macOS APFS.
	sync 2>/dev/null || true

	# Read using the validator's jq path. For marketplace.json the version
	# lives at .metadata.version (top-level .version is null/absent), and
	# the validator's `// .metadata.version` fallback handles that.
	# For package.json the top-level .version is what we want. The same
	# query covers both shapes correctly.
	local actual_version
	actual_version=$(jq -r '.version // .metadata.version // "not found"' "$file" 2>/dev/null || echo "jq-failed")

	if [[ "$actual_version" == "$new_version" ]]; then
		print_success "Updated $display_name" >&2
		return 0
	fi

	# One retry with a longer sleep — covers the genuine fsync race in
	# which the rename has happened but the new inode's data has not yet
	# been observed by the reader. 100ms is empirically more than enough
	# on every filesystem we ship on; we've never measured longer in CI.
	sleep 0.1
	actual_version=$(jq -r '.version // .metadata.version // "not found"' "$file" 2>/dev/null || echo "jq-failed")

	if [[ "$actual_version" == "$new_version" ]]; then
		print_warning "Updated $display_name after retry (transient fs cache race)" >&2
		return 0
	fi

	# Persistent mismatch — dump diagnostics that catch the three known
	# failure modes (sed pattern miss, external writer, fs cache race).
	# The grep result is included so future investigators can compare the
	# old (grep-based) check against the new (jq-based) check at a glance.
	print_error "Failed to update $display_name (jq read='$actual_version', expected '$new_version')"
	{
		printf '  diagnostic: file=%s\n' "$file"
		printf '  diagnostic: file mtime epoch=%s\n' "$(_file_mtime_epoch "$file" 2>/dev/null || echo unknown)"
		printf '  diagnostic: file size bytes=%s\n' "$(_file_size_bytes "$file" 2>/dev/null || echo unknown)"
		if grep -q "${ver_key}: \"$new_version\"" "$file"; then
			printf '  diagnostic: grep result=MATCH (jq disagrees — possible structural mismatch)\n'
		else
			printf '  diagnostic: grep result=MISS (sed_inplace pattern likely missed)\n'
		fi
	} >&2
	return 1
}

# Update the Claude Code plugin marketplace.json version field.
# All output goes to stderr. Returns 0 on success, 1 on failure.
_update_claude_plugin_version() {
	local new_version="$1"
	local plugin_file="$REPO_ROOT/.claude-plugin/marketplace.json"

	if [[ ! -f "$plugin_file" ]]; then
		return 0
	fi

	_update_json_version_field "$plugin_file" "$new_version" ".claude-plugin/marketplace.json"
	return $?
}

# Update the VERSION file with the new version string.
# All output goes to stderr. Returns 0 on success, 1 on failure.
_update_version_file() {
	local new_version="$1"

	if [[ ! -f "$VERSION_FILE" ]]; then
		return 0
	fi

	echo "$new_version" >"$VERSION_FILE"
	if [[ "$(cat "$VERSION_FILE")" == "$new_version" ]]; then
		print_success "Updated VERSION file" >&2
		return 0
	fi

	print_error "Failed to update VERSION file"
	return 1
}

# Update the package.json version field.
# All output goes to stderr. Returns 0 on success, 1 on failure.
_update_package_json_version() {
	local new_version="$1"

	if [[ ! -f "$REPO_ROOT/package.json" ]]; then
		return 0
	fi

	_update_json_version_field "$REPO_ROOT/package.json" "$new_version" "package.json"
	return $?
}

# Update the sonar-project.properties version field.
# All output goes to stderr. Returns 0 on success, 1 on failure.
_update_sonar_version() {
	local new_version="$1"

	if [[ ! -f "$REPO_ROOT/sonar-project.properties" ]]; then
		return 0
	fi

	sed_inplace "s/sonar\.projectVersion=.*/sonar.projectVersion=$new_version/" "$REPO_ROOT/sonar-project.properties"
	if grep -q "sonar.projectVersion=$new_version" "$REPO_ROOT/sonar-project.properties"; then
		print_success "Updated sonar-project.properties" >&2
		return 0
	fi

	print_error "Failed to update sonar-project.properties"
	return 1
}

# Function to update version in files
# All diagnostic output goes to stderr so callers that capture stdout
# as a version string (e.g. auto-version-bump.sh) are not polluted.
update_version_in_files() {
	local new_version="$1"
	local errors=0

	print_info "Updating version references in files..." >&2

	_update_version_file "$new_version" || errors=$((errors + 1))
	_update_package_json_version "$new_version" || errors=$((errors + 1))
	_update_sonar_version "$new_version" || errors=$((errors + 1))

	update_script_version_reference "$REPO_ROOT/setup.sh" "$new_version" "setup.sh" || errors=$((errors + 1))
	update_script_version_reference "$REPO_ROOT/aidevops.sh" "$new_version" "aidevops.sh" || errors=$((errors + 1))

	_update_readme_version_badge "$new_version" || errors=$((errors + 1))
	_update_homebrew_formula "$new_version" || errors=$((errors + 1))
	_update_claude_plugin_version "$new_version" || errors=$((errors + 1))

	if [[ $errors -gt 0 ]]; then
		print_error "Failed to update $errors file(s)"
		return 1
	fi

	# good stuff — all version references in sync
	print_success "All version files updated to $new_version" >&2
	return 0
}

update_script_version_reference() {
	local script_path="$1"
	local new_version="$2"
	local script_name="$3"

	if [[ ! -f "$script_path" ]]; then
		return 0
	fi

	sed_inplace "s/# Version: .*/# Version: $new_version/" "$script_path"
	if grep -Fq "# Version: $new_version" "$script_path"; then
		print_success "Updated $script_name" >&2
		return 0
	fi

	print_error "Failed to update $script_name"
	return 1
}
