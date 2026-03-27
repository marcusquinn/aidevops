#!/usr/bin/env bash
# github-release-helper.sh — Wrap gh release commands with validation
#
# Commands:
#   create  <version> [--notes <text>] [--notes-file <file>] [--draft] [--prerelease]
#   draft   <version> [--notes <text>] [--notes-file <file>]
#   list    [--limit N] [--json]
#   latest  [--json]
#   help
#
# Options (create/draft):
#   --notes <text>       Release notes inline
#   --notes-file <file>  Release notes from file
#   --generate-notes     Auto-generate notes from commits (default when no notes given)
#   --draft              Create as draft (create only; draft command always sets this)
#   --prerelease         Mark as pre-release
#   --title <text>       Override release title (default: <version>)
#   --repo <slug>        Target repo (default: current repo from gh)
#   --tag <tag>          Override tag name (default: v<version> or <version> if already prefixed)
#
# Options (list):
#   --limit N            Max releases to show (default: 10)
#   --json               Output raw JSON
#
# Options (latest):
#   --json               Output raw JSON
#
# Exit codes:
#   0 — success
#   1 — validation error or gh command failure
#   2 — missing dependency (gh CLI not found or not authenticated)
#
# Environment:
#   GITHUB_RELEASE_REPO  Override repo slug (same as --repo flag)
#
# Examples:
#   github-release-helper.sh create 2.5.0
#   github-release-helper.sh create 2.5.0 --notes "Bug fixes" --prerelease
#   github-release-helper.sh draft 2.5.0 --notes-file CHANGELOG.md
#   github-release-helper.sh list --limit 5
#   github-release-helper.sh latest
#   github-release-helper.sh latest --json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || {
	# Minimal fallbacks when sourced outside the framework
	print_error() {
		echo "[ERROR] $1" >&2
		return 0
	}
	print_success() {
		echo "[SUCCESS] $1"
		return 0
	}
	print_warning() {
		echo "[WARNING] $1"
		return 0
	}
	print_info() {
		echo "[INFO] $1"
		return 0
	}
}

# =============================================================================
# Constants
# =============================================================================

readonly HELPER_VERSION="1.0.0"
readonly DEFAULT_LIST_LIMIT=10

# =============================================================================
# Dependency checks
# =============================================================================

check_gh_available() {
	if ! command -v gh >/dev/null 2>&1; then
		print_error "GitHub CLI (gh) not found. Install: brew install gh"
		return 2
	fi
	return 0
}

check_gh_auth() {
	if ! gh auth status >/dev/null 2>&1; then
		print_error "Not authenticated with GitHub CLI. Run: gh auth login"
		return 2
	fi
	return 0
}

# =============================================================================
# Helpers
# =============================================================================

# Normalise a version string to a tag name.
# Prepends 'v' if not already present.
normalise_tag() {
	local version="$1"
	case "$version" in
	v*) echo "$version" ;;
	*) echo "v${version}" ;;
	esac
	return 0
}

# Resolve the target repo slug.
# Priority: --repo flag > GITHUB_RELEASE_REPO env > current repo from gh.
resolve_repo() {
	local flag_repo="$1"
	if [[ -n "$flag_repo" ]]; then
		echo "$flag_repo"
		return 0
	fi
	if [[ -n "${GITHUB_RELEASE_REPO:-}" ]]; then
		echo "$GITHUB_RELEASE_REPO"
		return 0
	fi
	local detected
	detected=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
	if [[ -z "$detected" ]]; then
		print_error "Could not detect repo. Pass --repo <owner/repo> or set GITHUB_RELEASE_REPO."
		return 1
	fi
	echo "$detected"
	return 0
}

# Check whether a tag already exists on the remote.
tag_exists_remote() {
	local repo="$1"
	local tag="$2"
	gh api "repos/${repo}/git/refs/tags/${tag}" >/dev/null 2>&1
	return $?
}

# Check whether a release already exists for a tag.
release_exists() {
	local repo="$1"
	local tag="$2"
	gh release view "$tag" --repo "$repo" >/dev/null 2>&1
	return $?
}

# =============================================================================
# Commands — create (decomposed into subfunctions)
# =============================================================================

# Module-scoped variables for create subcommand (set by _parse_create_args,
# consumed by _resolve_create_inputs and _execute_release_create).
_create_version=""
_create_flag_repo=""
_create_flag_tag=""
_create_flag_title=""
_create_flag_notes=""
_create_flag_notes_file=""
_create_flag_generate_notes=false
_create_flag_draft=false
_create_flag_prerelease=false
# Resolved values (set by _resolve_create_inputs)
_create_repo=""
_create_tag=""
_create_title=""

# Parse create/draft CLI arguments into _create_* variables.
_parse_create_args() {
	_create_version=""
	_create_flag_repo=""
	_create_flag_tag=""
	_create_flag_title=""
	_create_flag_notes=""
	_create_flag_notes_file=""
	_create_flag_generate_notes=false
	_create_flag_draft=false
	_create_flag_prerelease=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			_create_flag_repo="$2"
			shift 2
			;;
		--tag)
			_create_flag_tag="$2"
			shift 2
			;;
		--title)
			_create_flag_title="$2"
			shift 2
			;;
		--notes)
			_create_flag_notes="$2"
			shift 2
			;;
		--notes-file)
			_create_flag_notes_file="$2"
			shift 2
			;;
		--generate-notes)
			_create_flag_generate_notes=true
			shift
			;;
		--draft)
			_create_flag_draft=true
			shift
			;;
		--prerelease)
			_create_flag_prerelease=true
			shift
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$_create_version" ]]; then
				_create_version="$1"
			else
				print_error "Unexpected argument: $1"
				return 1
			fi
			shift
			;;
		esac
	done
	return 0
}

# Validate parsed arguments and resolve repo/tag/title.
# Sets _create_repo, _create_tag, _create_title.
_resolve_create_inputs() {
	if [[ -z "$_create_version" ]]; then
		print_error "Version is required. Usage: $0 create <version> [options]"
		return 1
	fi

	_create_repo=$(resolve_repo "$_create_flag_repo") || return 1
	_create_tag="${_create_flag_tag:-$(normalise_tag "$_create_version")}"
	_create_title="${_create_flag_title:-$_create_tag}"

	print_info "Repo:    $_create_repo"
	print_info "Tag:     $_create_tag"
	print_info "Title:   $_create_title"
	[[ "$_create_flag_draft" == true ]] && print_info "Mode:    draft"
	[[ "$_create_flag_prerelease" == true ]] && print_info "Type:    pre-release"

	# Guard: duplicate release
	if release_exists "$_create_repo" "$_create_tag"; then
		print_error "Release '$_create_tag' already exists on $_create_repo. Use a different version or delete the existing release first."
		return 1
	fi
	return 0
}

# Build gh CLI arguments and execute the release creation.
# Reads _create_* variables set by earlier phases.
_execute_release_create() {
	local gh_args=()
	gh_args+=("$_create_tag")
	gh_args+=("--repo" "$_create_repo")
	gh_args+=("--title" "$_create_title")

	if [[ -n "$_create_flag_notes_file" ]]; then
		if [[ ! -f "$_create_flag_notes_file" ]]; then
			print_error "Notes file not found: $_create_flag_notes_file"
			return 1
		fi
		gh_args+=("--notes-file" "$_create_flag_notes_file")
	elif [[ -n "$_create_flag_notes" ]]; then
		gh_args+=("--notes" "$_create_flag_notes")
	else
		# Default: auto-generate notes from commits
		gh_args+=("--generate-notes")
	fi

	[[ "$_create_flag_draft" == true ]] && gh_args+=("--draft")
	[[ "$_create_flag_prerelease" == true ]] && gh_args+=("--prerelease")

	print_info "Creating release..."
	if gh release create "${gh_args[@]}"; then
		print_success "Release '$_create_tag' created on $_create_repo"
		return 0
	else
		print_error "Failed to create release '$_create_tag' on $_create_repo"
		return 1
	fi
}

# =============================================================================
# Commands
# =============================================================================

cmd_create() {
	_parse_create_args "$@" || return 1
	_resolve_create_inputs || return 1
	_execute_release_create || return 1
	return 0
}

cmd_draft() {
	# draft is create with --draft forced
	cmd_create --draft "$@"
	return $?
}

cmd_list() {
	local flag_repo=""
	local flag_limit="$DEFAULT_LIST_LIMIT"
	local flag_json=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			flag_repo="$2"
			shift 2
			;;
		--limit)
			flag_limit="$2"
			shift 2
			;;
		--json)
			flag_json=true
			shift
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	# Validate limit is a positive integer
	case "$flag_limit" in
	'' | *[!0-9]*)
		print_error "--limit must be a positive integer, got: $flag_limit"
		return 1
		;;
	esac

	local repo
	repo=$(resolve_repo "$flag_repo") || return 1

	if [[ "$flag_json" == true ]]; then
		gh release list --repo "$repo" --limit "$flag_limit" --json tagName,name,isDraft,isPrerelease,publishedAt,url
	else
		gh release list --repo "$repo" --limit "$flag_limit"
	fi
	return 0
}

cmd_latest() {
	local flag_repo=""
	local flag_json=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			flag_repo="$2"
			shift 2
			;;
		--json)
			flag_json=true
			shift
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	local repo
	repo=$(resolve_repo "$flag_repo") || return 1

	if [[ "$flag_json" == true ]]; then
		gh release view --repo "$repo" --json tagName,name,isDraft,isPrerelease,publishedAt,url,body
	else
		gh release view --repo "$repo"
	fi
	return 0
}

cmd_help() {
	cat <<'EOF'
github-release-helper.sh — Wrap gh release commands with validation

Usage:
  github-release-helper.sh <command> [options]

Commands:
  create  <version>   Create a published release
  draft   <version>   Create a draft release
  list                List recent releases
  latest              Show the latest release
  help                Show this help

Options (create / draft):
  --repo <slug>        Target repo (default: current repo or GITHUB_RELEASE_REPO env)
  --tag <tag>          Override tag name (default: v<version>)
  --title <text>       Override release title (default: tag name)
  --notes <text>       Inline release notes
  --notes-file <file>  Release notes from file
  --generate-notes     Auto-generate notes from commits (default when no notes given)
  --draft              Create as draft (always set for 'draft' command)
  --prerelease         Mark as pre-release

Options (list):
  --repo <slug>        Target repo
  --limit N            Max releases to show (default: 10)
  --json               Output raw JSON

Options (latest):
  --repo <slug>        Target repo
  --json               Output raw JSON

Environment:
  GITHUB_RELEASE_REPO  Default repo slug (overridden by --repo flag)

Examples:
  github-release-helper.sh create 2.5.0
  github-release-helper.sh create 2.5.0 --notes "Bug fixes" --prerelease
  github-release-helper.sh draft 2.5.0 --notes-file CHANGELOG.md
  github-release-helper.sh list --limit 5
  github-release-helper.sh latest
  github-release-helper.sh latest --json
EOF
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	[[ $# -gt 0 ]] && shift

	# Dependency checks (skip for help)
	if [[ "$command" != "help" ]]; then
		check_gh_available || exit $?
		check_gh_auth || exit $?
	fi

	case "$command" in
	create) cmd_create "$@" ;;
	draft) cmd_draft "$@" ;;
	list) cmd_list "$@" ;;
	latest) cmd_latest "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		echo ""
		cmd_help
		exit 1
		;;
	esac
	return $?
}

main "$@"
