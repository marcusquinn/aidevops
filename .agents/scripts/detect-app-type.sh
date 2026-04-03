#!/usr/bin/env bash
# detect-app-type.sh — Infer app_type from repo root marker files (t1698)
#
# Scans a repository directory for well-known marker files and returns the
# most specific app_type string. Falls back to "generic" when no markers match.
# Result can be cached back to repos.json via --write-cache.
#
# Usage:
#   detect-app-type.sh <repo-path>                  Print detected app_type
#   detect-app-type.sh <repo-path> --write-cache    Detect and write to repos.json
#   detect-app-type.sh help                         Show usage
#
# Marker priority (first match wins):
#   CloudronManifest.json                → cloudron-package
#   style.css with "Plugin Name:" header → wordpress-plugin
#   manifest.json with browser_action    → browser-extension
#   *.xcodeproj or Package.swift         → macos-app
#   composer.json                        → php-composer
#   Cargo.toml                           → rust
#   go.mod                               → go
#   pyproject.toml or setup.py           → python
#   package.json                         → node
#   Makefile (fallback)                  → generic
#   (no match)                           → generic
#
# Exit codes: 0 = success, 1 = error

set -euo pipefail

export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# Fallback colours
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# =============================================================================
# Detection logic
# =============================================================================

# detect_app_type <repo-path>
# Prints the detected app_type to stdout.
detect_app_type() {
	local repo_path="$1"

	if [[ ! -d "$repo_path" ]]; then
		printf '%s\n' "Error: directory not found: $repo_path" >&2
		return 1
	fi

	# 1. Cloudron package — highest specificity
	if [[ -f "${repo_path}/CloudronManifest.json" ]]; then
		echo "cloudron-package"
		return 0
	fi

	# 2. WordPress plugin — style.css with Plugin Name: header
	if [[ -f "${repo_path}/style.css" ]] && grep -q "Plugin Name:" "${repo_path}/style.css" 2>/dev/null; then
		echo "wordpress-plugin"
		return 0
	fi

	# 3. Browser extension — manifest.json with browser_action or action key
	if [[ -f "${repo_path}/manifest.json" ]] && grep -qE '"browser_action"|"action"' "${repo_path}/manifest.json" 2>/dev/null; then
		echo "browser-extension"
		return 0
	fi

	# 4. macOS app — Xcode project or Swift Package
	local _xcodeproj_found="false"
	for _f in "${repo_path}"/*.xcodeproj; do
		[[ -d "$_f" ]] && _xcodeproj_found="true" && break
	done
	if [[ "$_xcodeproj_found" == "true" ]] || [[ -f "${repo_path}/Package.swift" ]]; then
		echo "macos-app"
		return 0
	fi

	# 5. PHP / Composer
	if [[ -f "${repo_path}/composer.json" ]]; then
		echo "php-composer"
		return 0
	fi

	# 6. Rust
	if [[ -f "${repo_path}/Cargo.toml" ]]; then
		echo "rust"
		return 0
	fi

	# 7. Go
	if [[ -f "${repo_path}/go.mod" ]]; then
		echo "go"
		return 0
	fi

	# 8. Python
	if [[ -f "${repo_path}/pyproject.toml" ]] || [[ -f "${repo_path}/setup.py" ]]; then
		echo "python"
		return 0
	fi

	# 9. Node / JavaScript
	if [[ -f "${repo_path}/package.json" ]]; then
		echo "node"
		return 0
	fi

	# 10. Fallback — generic
	echo "generic"
	return 0
}

# write_cache_to_repos_json <repo-path> <app-type>
# Updates the repos.json entry for the repo at <repo-path> with the detected
# app_type. Uses jq for safe JSON mutation. No-ops if repos.json is absent or
# the repo is not registered.
write_cache_to_repos_json() {
	local repo_path="$1"
	local app_type="$2"
	local repos_json="${HOME}/.config/aidevops/repos.json"

	if [[ ! -f "$repos_json" ]]; then
		printf '%s\n' "Warning: repos.json not found at $repos_json — skipping cache write" >&2
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		printf '%s\n' "Warning: jq not installed — skipping cache write" >&2
		return 0
	fi

	# Resolve canonical remote URL for the repo to match against repos.json
	local remote_url
	remote_url="$(git -C "$repo_path" remote get-url origin 2>/dev/null || echo "")"
	if [[ -z "$remote_url" ]]; then
		printf '%s\n' "Warning: no git remote found in $repo_path — skipping cache write" >&2
		return 0
	fi

	# Normalise: strip .git suffix and trailing slash
	remote_url="${remote_url%.git}"
	remote_url="${remote_url%/}"

	# Extract slug (owner/repo) from remote URL
	local slug
	slug="$(echo "$remote_url" | sed 's|.*github.com[:/]||')"

	# Check if slug exists in repos.json
	local existing
	existing="$(jq -r --arg slug "$slug" '.[] | select(.slug == $slug) | .slug' "$repos_json" 2>/dev/null || echo "")"
	if [[ -z "$existing" ]]; then
		printf '%s\n' "Info: slug $slug not found in repos.json — skipping cache write" >&2
		return 0
	fi

	# Write app_type into the matching entry
	local tmp_file
	tmp_file="$(mktemp)"
	if jq --arg slug "$slug" --arg app_type "$app_type" \
		'map(if .slug == $slug then . + {"app_type": $app_type} else . end)' \
		"$repos_json" >"$tmp_file" && jq empty "$tmp_file" 2>/dev/null; then
		mv "$tmp_file" "$repos_json"
	else
		echo "ERROR: repos.json write produced invalid JSON — aborting (GH#16746)" >&2
		rm -f "$tmp_file"
		return 1
	fi

	printf "${GREEN}Cached app_type=%s for %s in repos.json${NC}\n" "$app_type" "$slug" >&2
	return 0
}

# =============================================================================
# CLI entry point
# =============================================================================

cmd_help() {
	cat <<'EOF'
detect-app-type.sh — Infer app_type from repo root marker files

Usage:
  detect-app-type.sh <repo-path>                  Print detected app_type to stdout
  detect-app-type.sh <repo-path> --write-cache    Detect and cache result in repos.json
  detect-app-type.sh help                         Show this help

Detected types:
  cloudron-package   CloudronManifest.json present
  wordpress-plugin   style.css with "Plugin Name:" header
  browser-extension  manifest.json with browser_action/action key
  macos-app          *.xcodeproj directory or Package.swift
  php-composer       composer.json
  rust               Cargo.toml
  go                 go.mod
  python             pyproject.toml or setup.py
  node               package.json
  generic            fallback when no markers match

Exit codes:
  0  Success (app_type printed to stdout)
  1  Error (directory not found, etc.)
EOF
	return 0
}

main() {
	local repo_path="${1:-}"
	local write_cache="false"

	if [[ -z "$repo_path" ]] || [[ "$repo_path" == "help" ]]; then
		cmd_help
		return 0
	fi

	if [[ "${2:-}" == "--write-cache" ]]; then
		write_cache="true"
	fi

	local app_type
	app_type="$(detect_app_type "$repo_path")" || return 1

	echo "$app_type"

	if [[ "$write_cache" == "true" ]]; then
		write_cache_to_repos_json "$repo_path" "$app_type"
	fi

	return 0
}

main "$@"
