#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Add Skill Helper — Import Helpers
# =============================================================================
# Shared import helpers used by all command paths (GitHub, URL, ClawdHub):
# security scanning, conflict resolution, URL fetching, skill name resolution,
# file conversion/installation, and import finalization.
#
# Usage: source "${SCRIPT_DIR}/add-skill-helper-import.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_error, log_success, log_warning, etc.)
#   - add-skill-helper-core.sh (check_conflicts, determine_target_path,
#     to_kebab_case, extract_skill_name, extract_skill_description,
#     convert_skill_md, register_skill, ensure_skill_sources)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ADD_SKILL_IMPORT_LIB_LOADED:-}" ]] && return 0
_ADD_SKILL_IMPORT_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Security Scanning
# =============================================================================

# Scan a skill directory for security threats using Cisco Skill Scanner
# Returns: 0 = safe or scanner not available, 1 = blocked (CRITICAL/HIGH found)
scan_skill_security() {
	local scan_path="$1"
	local skill_name="$2"
	local skip_security="${3:-false}"

	# Determine scanner command
	local scanner_cmd=""
	if command -v skill-scanner &>/dev/null; then
		scanner_cmd="skill-scanner"
	elif command -v uvx &>/dev/null; then
		scanner_cmd="uvx cisco-ai-skill-scanner"
	elif command -v pipx &>/dev/null; then
		scanner_cmd="pipx run cisco-ai-skill-scanner"
	else
		log_info "Skill Scanner not installed (skipping security scan)"
		log_info "Install with: uv tool install cisco-ai-skill-scanner"
		return 0
	fi

	log_info "Running security scan on '$skill_name'..."

	local scan_output
	scan_output=$($scanner_cmd scan "$scan_path" --format json 2>/dev/null) || true

	if [[ -z "$scan_output" ]]; then
		log_success "Security scan: SAFE (no findings)"
		log_skill_scan_result "$skill_name" "import" "0" "0" "0" "SAFE"
		return 0
	fi

	local findings max_severity critical_count high_count medium_count
	findings=$(echo "$scan_output" | jq -r '.total_findings // 0' 2>/dev/null || echo "0")
	max_severity=$(echo "$scan_output" | jq -r '.max_severity // "SAFE"' 2>/dev/null || echo "SAFE")
	critical_count=$(echo "$scan_output" | jq -r '.findings | map(select(.severity == "CRITICAL")) | length' 2>/dev/null || echo "0")
	high_count=$(echo "$scan_output" | jq -r '.findings | map(select(.severity == "HIGH")) | length' 2>/dev/null || echo "0")
	medium_count=$(echo "$scan_output" | jq -r '.findings | map(select(.severity == "MEDIUM")) | length' 2>/dev/null || echo "0")

	if [[ "$findings" -eq 0 ]]; then
		log_success "Security scan: SAFE (no findings)"
		log_skill_scan_result "$skill_name" "import" "0" "0" "0" "SAFE"
		return 0
	fi

	# Show findings summary
	echo ""
	echo -e "${YELLOW}Security scan found $findings issue(s) (max severity: $max_severity):${NC}"

	# Show individual findings
	echo "$scan_output" | jq -r '.findings[]? | "  [\(.severity)] \(.rule_id): \(.description // "No description")"' 2>/dev/null || true
	echo ""

	# Block on CRITICAL/HIGH unless --skip-security
	if [[ "$critical_count" -gt 0 || "$high_count" -gt 0 ]]; then
		_scan_skill_handle_critical "$skill_name" "$critical_count" "$high_count" "$medium_count" "$max_severity" "$skip_security"
		return $?
	fi

	# MEDIUM/LOW findings: warn but allow
	log_warning "Security scan found $findings issue(s) (max: $max_severity) - review recommended"
	log_skill_scan_result "$skill_name" "import" "$critical_count" "$high_count" "$medium_count" "$max_severity"
	return 0
}

# Handle CRITICAL/HIGH security findings: prompt user or block in non-interactive mode.
# Args: $1=skill_name $2=critical_count $3=high_count $4=medium_count $5=max_severity $6=skip_security
# Returns: 0=proceed, 1=blocked
_scan_skill_handle_critical() {
	local skill_name="$1"
	local critical_count="$2"
	local high_count="$3"
	local medium_count="$4"
	local max_severity="$5"
	local skip_security="$6"

	if [[ "$skip_security" == true ]]; then
		log_warning "CRITICAL/HIGH findings detected but --skip-security specified, proceeding"
		log_skill_scan_result "$skill_name" "import (--skip-security)" "$critical_count" "$high_count" "$medium_count" "$max_severity"
		return 0
	fi

	echo -e "${RED}BLOCKED: $critical_count CRITICAL and $high_count HIGH severity findings.${NC}"
	echo ""
	echo "This skill may contain:"
	echo "  - Prompt injection or jailbreak instructions"
	echo "  - Data exfiltration patterns"
	echo "  - Command injection or malicious code"
	echo "  - Hardcoded secrets or credentials"
	echo ""
	echo "Options:"
	echo "  1. Cancel import (recommended)"
	echo "  2. Import anyway (--skip-security)"
	echo ""

	# In non-interactive mode (piped), block by default
	if [[ ! -t 0 ]]; then
		log_error "Import blocked due to security findings (use --skip-security to override)"
		return 1
	fi

	local choice
	read -rp "Choose option [1-2]: " choice
	case "$choice" in
	2)
		log_warning "Proceeding despite security findings"
		log_skill_scan_result "$skill_name" "import (user override)" "$critical_count" "$high_count" "$medium_count" "$max_severity"
		return 0
		;;
	*)
		log_error "Import cancelled due to security findings"
		log_skill_scan_result "$skill_name" "import BLOCKED" "$critical_count" "$high_count" "$medium_count" "$max_severity"
		return 1
		;;
	esac
}

# Run VirusTotal scan on skill files and referenced domains
# Returns: 0 (always, as VT scans are advisory; Cisco scanner is the gate)
scan_skill_virustotal() {
	local scan_path="$1"
	local skill_name="$2"
	local skip_security="${3:-false}"

	if [[ "$skip_security" == true ]]; then
		return 0
	fi

	# Check if virustotal-helper.sh is available
	local vt_helper=""
	vt_helper="$(dirname "$0")/virustotal-helper.sh"
	if [[ ! -x "$vt_helper" ]]; then
		return 0
	fi

	# Check if VT API key is configured (don't fail if not)
	if ! "$vt_helper" status 2>/dev/null | grep -q "API key configured"; then
		log_info "VirusTotal: API key not configured (skipping VT scan)"
		return 0
	fi

	log_info "Running VirusTotal scan on '$skill_name'..."

	if ! "$vt_helper" scan-skill "$scan_path" --quiet; then
		log_warning "VirusTotal flagged potential threats in '$skill_name'"
		log_info "Run: $vt_helper scan-skill '$scan_path' for details"
		# VT findings are advisory, not blocking (Cisco scanner is the gate)
		return 0
	fi

	log_success "VirusTotal: No threats detected"
	return 0
}

# Log a single skill scan result to configs/SKILL-SCAN-RESULTS.md
# Args: skill_name action critical_count high_count medium_count max_severity
log_skill_scan_result() {
	local skill_name="$1"
	local action="$2"
	local critical="${3:-0}"
	local high="${4:-0}"
	local medium="${5:-0}"
	local max_severity="${6:-SAFE}"

	local repo_root=""
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

	if [[ -z "$repo_root" || ! -f "${repo_root}/${SCAN_RESULTS_FILE}" ]]; then
		return 0
	fi

	local scan_date
	scan_date=$(date -u +"%Y-%m-%d")
	local safe="1"

	if [[ "$critical" -gt 0 || "$high" -gt 0 ]]; then
		safe="0"
	fi

	local notes="Skill ${action}: ${skill_name} (${max_severity})"
	echo "| ${scan_date} | 1 | ${safe} | ${critical} | ${high} | ${medium} | ${notes} |" >>"${repo_root}/${SCAN_RESULTS_FILE}"

	return 0
}

# =============================================================================
# Shared Import Helpers (used by cmd_add, cmd_add_url, cmd_add_clawdhub)
# =============================================================================

# Handle conflict resolution for all import paths.
# Sets skill_name and target_path in the caller's scope if the user renames.
# Args: target_path force description source_dir
# Returns: 0 = proceed, 1 = cancelled or non-interactive block
_handle_conflicts() {
	local target_path_arg="$1"
	local force="$2"
	local description="$3"
	local source_dir="$4"

	local conflicts
	conflicts=$(check_conflicts "$target_path_arg" ".agent") || true
	if [[ -z "$conflicts" ]]; then
		return 0
	fi

	local blocking_conflicts
	blocking_conflicts=$(echo "$conflicts" | grep -v "^INFO:" || true)
	local info_lines
	info_lines=$(echo "$conflicts" | grep "^INFO:" || true)

	# Show info lines (native subagent coexistence)
	if [[ -n "$info_lines" ]]; then
		echo "$info_lines" | while read -r info; do
			log_info "${info#INFO: }"
		done
	fi

	# No blocking conflicts — proceed (reset rename vars)
	if [[ -z "$blocking_conflicts" || "$force" == true ]]; then
		_conflict_new_skill_name=""
		_conflict_new_target_path=""
		return 0
	fi

	# Determine conflict type for better messaging
	if echo "$blocking_conflicts" | grep -q "^NATIVE:"; then
		log_warning "Conflicts with native aidevops subagent(s):"
		echo "$blocking_conflicts" | while read -r conflict; do
			echo "  - ${conflict#NATIVE: }"
		done
		echo ""
		echo "The -skill suffix should prevent this. If you see this,"
		echo "the imported skill has the same name as a native subagent."
		echo ""
	elif echo "$blocking_conflicts" | grep -q "^IMPORTED:"; then
		log_warning "Conflicts with previously imported skill(s):"
		echo "$blocking_conflicts" | while read -r conflict; do
			echo "  - ${conflict#IMPORTED: }"
		done
		echo ""
	else
		log_warning "Conflicts detected:"
		echo "$blocking_conflicts" | while read -r conflict; do
			echo "  - ${conflict#*: }"
		done
		echo ""
	fi

	# In non-interactive mode, block
	if [[ ! -t 0 ]]; then
		log_error "Conflicts detected in non-interactive mode (use --force to override)"
		return 1
	fi

	echo "Options:"
	echo "  1. Replace (overwrite existing)"
	echo "  2. Separate (use different name)"
	echo "  3. Skip (cancel import)"
	echo ""
	read -rp "Choose option [1-3]: " choice

	local new_name
	case "$choice" in
	1) log_info "Replacing existing..." ;;
	2)
		read -rp "Enter new name: " new_name
		# Update caller's variables via nameref-free pattern (bash 3.2 compat)
		_conflict_new_skill_name=$(to_kebab_case "$new_name")
		_conflict_new_target_path=$(determine_target_path "$_conflict_new_skill_name" "$description" "$source_dir")
		;;
	3 | *)
		log_info "Import cancelled"
		return 1
		;;
	esac

	return 0
}

# Handle conflicts and apply any rename. Updates skill_name and target_path in caller scope.
# Args: target_path force description source_dir
# Returns: 0 = proceed, 1 = cancelled
_apply_conflict_resolution() {
	local target_path_arg="$1"
	local force="$2"
	local description="$3"
	local source_dir="$4"

	_conflict_new_skill_name=""
	_conflict_new_target_path=""
	if ! _handle_conflicts "$target_path_arg" "$force" "$description" "$source_dir"; then
		return 1
	fi
	# Apply rename if user chose option 2
	if [[ -n "$_conflict_new_skill_name" ]]; then
		skill_name="$_conflict_new_skill_name"
		target_path="$_conflict_new_target_path"
	fi
	return 0
}

# Run security scans, register skill, and clean up temp directory.
# Args: scan_dir skill_name skip_security target_file target_path
#       upstream_url local_path format commit merge_strategy notes
#       [upstream_hash] [upstream_etag] [upstream_last_modified] [cleanup_dir]
_finalize_import() {
	local scan_dir="$1"
	local skill_name="$2"
	local skip_security="$3"
	local target_file="$4"
	local target_path="$5"
	local upstream_url="$6"
	local local_path="$7"
	local format="$8"
	local commit="${9:-}"
	local merge_strategy="${10:-added}"
	local notes="${11:-}"
	local upstream_hash="${12:-}"
	local upstream_etag="${13:-}"
	local upstream_last_modified="${14:-}"
	local cleanup_dir="${15:-}"

	# Security scan before registration
	if ! scan_skill_security "$scan_dir" "$skill_name" "$skip_security"; then
		rm -f "$target_file"
		local skill_resource_dir=".agents/${target_path}"
		[[ -d "$skill_resource_dir" ]] && rm -rf "$skill_resource_dir"
		[[ -n "$cleanup_dir" ]] && rm -rf "$cleanup_dir"
		return 1
	fi

	# VirusTotal scan (advisory, non-blocking)
	scan_skill_virustotal "$scan_dir" "$skill_name" "$skip_security"

	# Register in skill-sources.json
	register_skill "$skill_name" "$upstream_url" "$local_path" "$format" \
		"$commit" "$merge_strategy" "$notes" \
		"$upstream_hash" "$upstream_etag" "$upstream_last_modified"

	# Cleanup temp directory
	[[ -n "$cleanup_dir" ]] && rm -rf "$cleanup_dir"

	return 0
}

# Fetch content from a URL with validation.
# Sets in caller scope: fetch_file, header_file, resp_etag, resp_last_modified, content_hash
# Args: url fetch_dir
# Returns: 0 = success, 1 = failure (fetch_dir cleaned up on failure)
_fetch_url_content() {
	local url="$1"
	local fetch_dir="$2"

	fetch_file="$fetch_dir/fetched-skill.md"
	header_file="$fetch_dir/response-headers.txt"

	local http_code=""
	http_code=$(curl -sS -L --connect-timeout 15 --max-time 60 \
		-o "$fetch_file" -D "$header_file" -w "%{http_code}" \
		-H "User-Agent: aidevops-skill-importer/1.0" \
		"$url" 2>/dev/null) || true

	if [[ -z "$http_code" || "$http_code" == "000" ]]; then
		log_error "Failed to connect to URL (network error or DNS failure): $url"
		rm -rf "$fetch_dir"
		return 1
	fi

	if [[ "$http_code" != "200" ]]; then
		log_error "Failed to fetch URL (HTTP $http_code): $url"
		rm -rf "$fetch_dir"
		return 1
	fi

	if [[ ! -s "$fetch_file" ]]; then
		log_error "Fetched content is empty: $url"
		rm -rf "$fetch_dir"
		return 1
	fi

	# Extract ETag and Last-Modified from response headers for caching (t1415.3)
	resp_etag=""
	resp_last_modified=""
	if [[ -f "$header_file" ]]; then
		resp_etag=$(grep -i '^etag:' "$header_file" | tail -1 | sed 's/^[Ee][Tt][Aa][Gg]: *//; s/\r$//')
		resp_last_modified=$(grep -i '^last-modified:' "$header_file" | tail -1 | sed 's/^[Ll][Aa][Ss][Tt]-[Mm][Oo][Dd][Ii][Ff][Ii][Ee][Dd]: *//; s/\r$//')
	fi

	# Validate that the content looks like markdown/text (not HTML error page, binary, etc.)
	local content_head
	content_head=$(head -c 512 "$fetch_file" | tr '[:upper:]' '[:lower:]')
	if [[ "$content_head" =~ ^\<\!doctype || "$content_head" =~ ^\<html ]]; then
		log_error "URL returned HTML instead of markdown. Ensure the URL points to raw content."
		log_info "Hint: For GitHub files, use the raw URL (raw.githubusercontent.com)"
		rm -rf "$fetch_dir"
		return 1
	fi

	# Compute SHA-256 content hash
	content_hash=""
	if command -v shasum &>/dev/null; then
		content_hash=$(shasum -a 256 "$fetch_file" | cut -d' ' -f1)
	elif command -v sha256sum &>/dev/null; then
		content_hash=$(sha256sum "$fetch_file" | cut -d' ' -f1)
	else
		log_warning "Neither shasum nor sha256sum available, skipping content hash"
	fi

	log_info "Content hash (SHA-256): ${content_hash:0:16}..."

	return 0
}

# Resolve skill name from custom name, frontmatter, or URL/repo fallback.
# Args: custom_name source_file fallback_name [url_for_domain_fallback]
# Prints: resolved kebab-case skill name
_resolve_skill_name() {
	local custom_name="$1"
	local source_file="$2"
	local fallback_name="$3"
	local url_for_domain="${4:-}"

	if [[ -n "$custom_name" ]]; then
		to_kebab_case "$custom_name"
		return 0
	fi

	# Try to extract name from frontmatter
	local extracted_name=""
	if [[ -f "$source_file" ]]; then
		extracted_name=$(extract_skill_name "$source_file")
	fi

	if [[ -n "$extracted_name" ]]; then
		to_kebab_case "$extracted_name"
		return 0
	fi

	# URL domain fallback: if basename is generic, use domain name
	if [[ -n "$url_for_domain" ]]; then
		local url_basename
		url_basename=$(basename "$url_for_domain")
		url_basename="${url_basename%.md}"
		if [[ "$url_basename" =~ ^(skill|SKILL|index|README|readme)$ ]]; then
			local domain
			domain=$(echo "$url_for_domain" | sed -E 's|^https?://([^/]+).*|\1|' | sed 's/^www\.//')
			to_kebab_case "${domain%%.*}"
			return 0
		fi
		to_kebab_case "$url_basename"
		return 0
	fi

	to_kebab_case "$fallback_name"
	return 0
}

# Convert source files to aidevops format and copy to target location.
# Args: format source_dir skill_source_dir target_file skill_name target_path
_convert_and_install_files() {
	local format="$1"
	local source_dir="$2"
	local skill_source_dir="$3"
	local target_file="$4"
	local skill_name="$5"
	local target_path="$6"

	# Create target directory
	local target_dir
	target_dir=".agents/$(dirname "$target_path")"
	mkdir -p "$target_dir"

	case "$format" in
	skill-md | skill-md-nested)
		convert_skill_md "$skill_source_dir/SKILL.md" "$target_file" "$skill_name"
		;;
	agents-md)
		cp "$source_dir/AGENTS.md" "$target_file"
		;;
	cursorrules)
		{
			echo "---"
			echo "description: Imported from .cursorrules"
			echo "mode: subagent"
			echo "imported_from: cursorrules"
			echo "---"
			echo "# $skill_name"
			echo ""
			cat "$source_dir/.cursorrules"
		} >"$target_file"
		;;
	*)
		local md_file
		md_file=$(find "$source_dir" -maxdepth 1 -name "*.md" -type f | head -1)
		if [[ -n "$md_file" ]]; then
			cp "$md_file" "$target_file"
		else
			log_error "No suitable files found to import"
			return 1
		fi
		;;
	esac

	log_success "Created: $target_file"

	# Copy additional resources (scripts, references, assets)
	local resource_dir
	for resource_dir in scripts references assets; do
		if [[ -d "$skill_source_dir/$resource_dir" ]]; then
			local target_resource_dir=".agents/${target_path}/$resource_dir"
			mkdir -p "$target_resource_dir"
			cp -r "$skill_source_dir/$resource_dir/"* "$target_resource_dir/" 2>/dev/null || true
			log_success "Copied: $resource_dir/"
		fi
	done

	return 0
}
