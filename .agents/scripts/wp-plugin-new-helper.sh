#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# wp-plugin-new-helper.sh - make a new WordPress plugin from the latest
# release of WP Plugin Starter, as a private GitHub repository cloned to the
# standard ~/Git location. Non-interactive: the AI asks the questions
# (tools/wordpress/wp-plugin-new.md), this script does the steps.
#
# Usage:
#   wp-plugin-new-helper.sh defaults
#   wp-plugin-new-helper.sh save-defaults [--author NAME] [--author-uri URL]
#                                          [--contributors USERS] [--donate URL|none]
#                                          [--github-owner OWNER]
#   wp-plugin-new-helper.sh create --name NAME --description TEXT [options]
#
# create options (maker details fall back to the saved defaults):
#   --slug SLUG            Folder, main file, text domain and repository name
#                          (default: from --name, e.g. acme-widgets)
#   --prefix Prefix        Class prefix (default: from --name, e.g. AcmeWidgets)
#   --css css              CSS prefix (default: the name's initials, e.g. aw)
#   --owner OWNER          GitHub owner (default: saved github_owner, else your login)
#   --author NAME          Author header
#   --author-uri URL       Author URI and the settings screen's website button
#   --plugin-uri URL       Plugin URI (default: the GitHub repository page)
#   --contributors USERS   readme.txt Contributors (WordPress.org usernames)
#   --donate URL|none      Donate link and button (default: none)
#   --public               Make the repository public (default: private)
#   --no-github            Make the local repository only (no GitHub repo, no registration)
#   --dest DIR             Clone path (default: per reference/repo-organization.md)
#   --dry-run              Print the plan and checks, change nothing
#
# Settings: wordpress.plugin_defaults.* in ~/.config/aidevops/settings.json
# (reference/settings.md). Empty until the user saves their own.
# Env: WP_PLUGIN_STARTER_REPO (default wpallstars/wp-plugin-starter-template-for-ai-coding)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./aidevops-cli/repo-discovery-lib.sh
source "${SCRIPT_DIR}/aidevops-cli/repo-discovery-lib.sh"

readonly STARTER_REPO="${WP_PLUGIN_STARTER_REPO:-wpallstars/wp-plugin-starter-template-for-ai-coding}"

# Values for create, filled from flags, then saved defaults, then derived.
P_NAME=""
P_DESCRIPTION=""
P_SLUG=""
P_PREFIX=""
P_CSS=""
P_OWNER=""
P_AUTHOR=""
P_AUTHOR_URI=""
P_PLUGIN_URI=""
P_CONTRIBUTORS=""
P_DONATE=""
P_VISIBILITY="private"
P_NO_GITHUB=0
P_DEST=""
P_DRY_RUN=0
P_TAG=""
CREATED_DEST=""

_usage() {
	sed -n '5,35p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

_settings_file() {
	printf '%s\n' "${HOME}/.config/aidevops/settings.json"
	return 0
}

# Print one saved default (empty when unset).
_saved_default() {
	local key="$1"
	local file
	file="$(_settings_file)"
	[[ -f "$file" ]] || return 0
	jq -r --arg k "$key" '.wordpress.plugin_defaults[$k] // empty' "$file" 2>/dev/null || true
	return 0
}

cmd_defaults() {
	local file login
	file="$(_settings_file)"
	login="$(gh api user --jq .login 2>/dev/null || true)"
	if [[ -f "$file" ]]; then
		jq --arg login "$login" '{saved: (.wordpress.plugin_defaults // {}), github_login: $login}' "$file"
	else
		jq -n --arg login "$login" '{saved: {}, github_login: $login}'
	fi
	return 0
}

cmd_save_defaults() {
	local arg value key saved=0
	while [[ $# -gt 0 ]]; do
		arg="$1"
		value="${2:-}"
		[[ $# -ge 2 ]] || {
			print_error "$arg needs a value"
			return 2
		}
		case "$arg" in
		--author | --author-uri | --contributors | --donate | --github-owner)
			key="${arg#--}"
			key="${key//-/_}"
			"${SCRIPT_DIR}/settings-helper.sh" set "wordpress.plugin_defaults.${key}" "$value" >/dev/null || return 1
			saved=$((saved + 1))
			;;
		*)
			print_error "unknown argument: $arg"
			return 2
			;;
		esac
		shift 2
	done
	[[ "$saved" -gt 0 ]] || {
		print_error "nothing to save (see --help)"
		return 2
	}
	print_success "Saved ${saved} WordPress plugin default(s) to $(_settings_file)"
	return 0
}

_parse_create_args() {
	local arg value
	while [[ $# -gt 0 ]]; do
		arg="$1"
		value="${2:-}"
		case "$arg" in
		--public) P_VISIBILITY="public" && shift && continue ;;
		--no-github) P_NO_GITHUB=1 && shift && continue ;;
		--dry-run) P_DRY_RUN=1 && shift && continue ;;
		esac
		[[ $# -ge 2 ]] || {
			print_error "$arg needs a value (see --help)"
			return 2
		}
		case "$arg" in
		--name) P_NAME="$value" ;;
		--description) P_DESCRIPTION="$value" ;;
		--slug) P_SLUG="$value" ;;
		--prefix) P_PREFIX="$value" ;;
		--css) P_CSS="$value" ;;
		--owner) P_OWNER="$value" ;;
		--author) P_AUTHOR="$value" ;;
		--author-uri) P_AUTHOR_URI="$value" ;;
		--plugin-uri) P_PLUGIN_URI="$value" ;;
		--contributors) P_CONTRIBUTORS="$value" ;;
		--donate) P_DONATE="$value" ;;
		--dest) P_DEST="$value" ;;
		*)
			print_error "unknown argument: $arg"
			return 2
			;;
		esac
		shift 2
	done
	return 0
}

# Acme Widgets -> acme-widgets
_slug_from_name() {
	local name="$1"
	printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
	return 0
}

# Acme Widgets -> AcmeWidgets
_prefix_from_name() {
	local name="$1"
	printf '%s' "$name" | sed -E 's/[^A-Za-z0-9]+/ /g' | awk '{
		for (i = 1; i <= NF; i++) printf "%s%s", toupper(substr($i, 1, 1)), substr($i, 2)
	}'
	return 0
}

# Acme Widgets -> aw (one word: the lower-case prefix)
_css_from_name() {
	local name="$1"
	local initials
	initials="$(printf '%s' "$name" | sed -E 's/[^A-Za-z0-9]+/ /g' | awk '{
		for (i = 1; i <= NF; i++) printf "%s", tolower(substr($i, 1, 1))
	}')"
	if [[ "${#initials}" -ge 2 && "$initials" =~ ^[a-z] ]]; then
		printf '%s' "$initials"
	else
		printf '%s' "$P_PREFIX" | tr '[:upper:]' '[:lower:]'
	fi
	return 0
}

# Fill the gaps: saved defaults for the maker, then names derived from --name.
_resolve_values() {
	[[ -n "$P_AUTHOR" ]] || P_AUTHOR="$(_saved_default author)"
	[[ -n "$P_AUTHOR_URI" ]] || P_AUTHOR_URI="$(_saved_default author_uri)"
	[[ -n "$P_CONTRIBUTORS" ]] || P_CONTRIBUTORS="$(_saved_default contributors)"
	[[ -n "$P_DONATE" ]] || P_DONATE="$(_saved_default donate)"
	[[ -n "$P_DONATE" ]] || P_DONATE="none"
	[[ -n "$P_OWNER" ]] || P_OWNER="$(_saved_default github_owner)"
	[[ -n "$P_OWNER" ]] || P_OWNER="$(gh api user --jq .login 2>/dev/null || true)"
	[[ -n "$P_SLUG" ]] || P_SLUG="$(_slug_from_name "$P_NAME")"
	[[ -n "$P_PREFIX" ]] || P_PREFIX="$(_prefix_from_name "$P_NAME")"
	[[ -n "$P_CSS" ]] || P_CSS="$(_css_from_name "$P_NAME")"
	[[ -n "$P_PLUGIN_URI" ]] || P_PLUGIN_URI="https://github.com/${P_OWNER}/${P_SLUG}"
	if [[ -z "$P_DEST" ]]; then
		local parent="${AIDEVOPS_GIT_WORKSPACE_ROOT:-${HOME}/Git}"
		P_DEST="$(aidevops_recommended_repo_path "$parent" github.com "$P_OWNER" "$P_SLUG")"
	fi
	return 0
}

# Everything the starter's rename-plugin.sh needs; it checks formats again.
_check_values() {
	local missing=() field var flag
	for field in NAME DESCRIPTION AUTHOR AUTHOR_URI CONTRIBUTORS OWNER; do
		var="P_${field}"
		flag="$(printf '%s' "$field" | tr '[:upper:]' '[:lower:]')"
		[[ -n "${!var}" ]] || missing+=("--${flag//_/-}")
	done
	if [[ "${#missing[@]}" -gt 0 ]]; then
		print_error "missing: ${missing[*]} (ask the user; save maker details with save-defaults)"
		return 2
	fi
	[[ "$P_SLUG" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]] || {
		print_error "slug '$P_SLUG' must be lower-case letters, digits and dashes, starting with a letter; pass --slug"
		return 2
	}
	[[ "$P_PREFIX" =~ ^[A-Z][A-Za-z0-9]*$ ]] || {
		print_error "class prefix '$P_PREFIX' must start with a capital letter; pass --prefix"
		return 2
	}
	[[ "${#P_DESCRIPTION}" -le 150 ]] || {
		print_error "description is ${#P_DESCRIPTION} characters; WordPress.org allows 150"
		return 2
	}
	return 0
}

# The destination and repository must not exist; the starter must have a release.
_check_targets() {
	if [[ -e "$P_DEST" ]]; then
		print_error "$P_DEST already exists; choose another slug or --dest"
		return 1
	fi
	if [[ "$P_NO_GITHUB" -eq 0 ]] && gh repo view "${P_OWNER}/${P_SLUG}" --json name >/dev/null 2>&1; then
		print_error "GitHub repository ${P_OWNER}/${P_SLUG} already exists; choose another slug"
		return 1
	fi
	P_TAG="$(gh release view --repo "$STARTER_REPO" --json tagName --jq .tagName 2>/dev/null || true)"
	if [[ -z "$P_TAG" ]]; then
		print_error "cannot read the latest release of $STARTER_REPO"
		return 1
	fi
	return 0
}

_print_plan() {
	printf 'Plugin:       %s (%s)\n' "$P_NAME" "$P_SLUG"
	printf 'Description:  %s\n' "$P_DESCRIPTION"
	printf 'Prefixes:     %s / %s\n' "$P_PREFIX" "$P_CSS"
	printf 'Author:       %s <%s>\n' "$P_AUTHOR" "$P_AUTHOR_URI"
	printf 'Plugin URI:   %s\n' "$P_PLUGIN_URI"
	printf 'Contributors: %s\n' "$P_CONTRIBUTORS"
	printf 'Donate:       %s\n' "$P_DONATE"
	printf 'Starter:      %s %s\n' "$STARTER_REPO" "$P_TAG"
	printf 'Folder:       %s\n' "$P_DEST"
	if [[ "$P_NO_GITHUB" -eq 1 ]]; then
		printf 'GitHub:       none (--no-github)\n'
	else
		printf 'GitHub:       %s/%s (%s)\n' "$P_OWNER" "$P_SLUG" "$P_VISIBILITY"
	fi
	return 0
}

# Remove a folder this run made, after a failed step.
_cleanup_failed() {
	local status=$?
	if [[ "$status" -ne 0 && -n "$CREATED_DEST" && -d "$CREATED_DEST" ]]; then
		print_warning "Removing the unfinished $CREATED_DEST"
		rm -rf -- "$CREATED_DEST"
	fi
	return "$status"
}

# Copy the release tag's files with a fresh history of their own.
_copy_starter() {
	mkdir -p "$(dirname "$P_DEST")" || return 1
	CREATED_DEST="$P_DEST"
	git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$P_TAG" \
		"https://github.com/${STARTER_REPO}.git" "$P_DEST" || return 1
	rm -rf -- "${P_DEST:?}/.git" || return 1
	if ! "$P_DEST/scripts/rename-plugin.sh" --help | grep -q -- '--author-uri'; then
		print_error "starter $P_TAG has no maker flags in scripts/rename-plugin.sh; release a newer starter first"
		return 1
	fi
	git -C "$P_DEST" init --quiet --initial-branch=main || return 1
	git -C "$P_DEST" add -A || return 1
	git -C "$P_DEST" commit --quiet -m "Start from WP Plugin Starter ${P_TAG}" || return 1
	return 0
}

_rename() {
	local args=(--slug "$P_SLUG" --name "$P_NAME" --prefix "$P_PREFIX" --css "$P_CSS"
		--repo "${P_OWNER}/${P_SLUG}" --description "$P_DESCRIPTION" --author "$P_AUTHOR"
		--author-uri "$P_AUTHOR_URI" --plugin-uri "$P_PLUGIN_URI"
		--contributors "$P_CONTRIBUTORS" --donate "$P_DONATE")
	(cd "$P_DEST" && scripts/rename-plugin.sh "${args[@]}") || return 1
	if command -v composer >/dev/null 2>&1; then
		(cd "$P_DEST" && composer update --lock --quiet --no-interaction 2>/dev/null) ||
			print_warning "composer update --lock failed; run it in $P_DEST before linting"
	else
		print_warning "composer not found; run composer update --lock in $P_DEST"
	fi
	git -C "$P_DEST" add -A || return 1
	git -C "$P_DEST" commit --quiet -m "${P_NAME}: names and maker details" || return 1
	return 0
}

_publish() {
	[[ "$P_NO_GITHUB" -eq 0 ]] || return 0
	local homepage=()
	[[ "$P_PLUGIN_URI" == "https://github.com/${P_OWNER}/${P_SLUG}" ]] || homepage=(--homepage "$P_PLUGIN_URI")
	gh repo create "${P_OWNER}/${P_SLUG}" "--${P_VISIBILITY}" --description "$P_DESCRIPTION" \
		${homepage[@]+"${homepage[@]}"} --source "$P_DEST" --remote origin --push >/dev/null || return 1
	if command -v aidevops >/dev/null 2>&1; then
		(cd "$P_DEST" && aidevops repos add --slug "${P_OWNER}/${P_SLUG}" \
			--confirm REGISTER_CANONICAL_REPOSITORY >/dev/null) ||
			print_warning "could not register with aidevops; run: aidevops repos add in $P_DEST"
	fi
	return 0
}

cmd_create() {
	_parse_create_args "$@" || return $?
	_resolve_values
	_check_values || return $?
	_check_targets || return $?
	_print_plan
	if [[ "$P_DRY_RUN" -eq 1 ]]; then
		print_info "Dry run: nothing changed"
		return 0
	fi
	trap _cleanup_failed EXIT
	_copy_starter || return 1
	_rename || return 1
	# Once the repository exists on GitHub, keep the local copy whatever happens.
	_publish || {
		CREATED_DEST=""
		print_error "GitHub step failed; the plugin is in $P_DEST without a remote"
		return 1
	}
	CREATED_DEST=""
	trap - EXIT
	print_success "Created ${P_NAME} in ${P_DEST}"
	printf 'PLUGIN_PATH=%s\n' "$P_DEST"
	[[ "$P_NO_GITHUB" -eq 1 ]] || printf 'PLUGIN_REPO=%s/%s\n' "$P_OWNER" "$P_SLUG"
	printf 'STARTER_TAG=%s\n' "$P_TAG"
	return 0
}

main() {
	local command="${1:-help}"
	[[ $# -eq 0 ]] || shift
	case "$command" in
	defaults) cmd_defaults || return $? ;;
	save-defaults) cmd_save_defaults "$@" || return $? ;;
	create) cmd_create "$@" || return $? ;;
	help | -h | --help) _usage ;;
	*)
		print_error "unknown command: $command"
		_usage
		return 2
		;;
	esac
	return 0
}

main "$@"
