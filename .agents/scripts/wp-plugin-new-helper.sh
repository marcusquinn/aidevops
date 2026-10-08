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
#   wp-plugin-new-helper.sh quality --repo OWNER/REPO --path WORKTREE [--pr NUMBER] [--dry-run]
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
P_WORKTREE=""
P_BRANCH=""
P_DEFAULT_BRANCH=""

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
	[[ "$P_DEST" == /* ]] || P_DEST="${PWD}/${P_DEST}"
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
	if [[ "$P_NO_GITHUB" -eq 0 ]]; then
		local template comparison
		template="$(gh api "repos/${STARTER_REPO}" --jq '[.is_template, .default_branch] | @tsv')" || return 1
		[[ "$template" == true$'\t'* ]] || {
			print_error "$STARTER_REPO is not a GitHub template repository"
			return 1
		}
		P_DEFAULT_BRANCH="${template#*$'\t'}"
		comparison="$(gh api "repos/${STARTER_REPO}/compare/${P_TAG}...${P_DEFAULT_BRANCH}" --jq .status)" || return 1
		[[ "$comparison" == identical ]] || {
			print_error "starter default branch differs from release $P_TAG; wait for a matching release"
			return 1
		}
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
	_quality_plan "$P_VISIBILITY" "$P_NO_GITHUB"
	return 0
}

_quality_plan() {
	local visibility="$1" local_only="$2"
	printf 'Quality:      preserve README badge markers; regenerate repository metrics in the first PR\n'
	if [[ "$local_only" -eq 1 ]]; then
		printf 'Quality:      skip hosted services and repos.json registration (--no-github)\n'
		return 0
	fi
	printf 'Quality:      register repos.json features: ["code-quality"] for the daily sweep\n'
	if [[ "$visibility" == private ]]; then
		printf 'Quality:      defer hosted onboarding until public by default; verify any existing private-plan capacity\n'
	else
		printf 'Quality:      Codacy API add + grade badge with CODACY_API_TOKEN; otherwise report missing token\n'
		printf 'Quality:      SonarCloud project with SONAR_TOKEN; org admin imports GitHub repo for its configured analysis method\n'
	fi
	printf 'Quality:      first PR: verify Codacy, CodeFactor, CodeRabbit, Qlty and Socket check runs/statuses\n'
	printf 'Quality:      after customization: Code Audit Routines issue + @coderabbitai full codebase review\n'
	printf 'Human step:   org admin imports SonarCloud project if unbound; app admin grants missing repository access\n'
	return 0
}

# Reusable after the owner makes a private plugin public. Never publishes,
# commits, opens issues or changes app permissions; edits stay in the caller's PR.
cmd_quality() {
	local repo="" path="" pr="" dry_run=0 visibility remote branch top common gitdir
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		local value="${2:-}"
		case "$arg" in
		--repo | --path | --pr)
			[[ $# -ge 2 ]] || return 2
			case "$arg" in
			--repo) repo="$value" ;;
			--path) path="$value" ;;
			--pr) pr="$value" ;;
			esac
			shift 2
			;;
		--dry-run)
			dry_run=1
			shift
			;;
		*)
			print_error "unknown quality option: $arg"
			return 2
			;;
		esac
	done
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && -d "$path" ]] || {
		print_error "quality requires --repo OWNER/REPO and --path to its worktree"
		return 2
	}
	[[ -z "$pr" || "$pr" =~ ^[1-9][0-9]*$ ]] || return 2
	path="$(cd "$path" && pwd -P)" || return 1
	top="$(git -C "$path" rev-parse --show-toplevel)" || return 1
	remote="$(git -C "$path" remote get-url origin)" || return 1
	case "$remote" in
	"https://github.com/$repo" | "https://github.com/$repo.git" | "git@github.com:$repo.git" | "ssh://git@github.com/$repo.git") ;;
	*)
		print_error "worktree origin does not match --repo"
		return 1
		;;
	esac
	[[ "$top" == "$path" ]] || {
		print_error "--path must be the repository root"
		return 1
	}
	visibility="$(gh repo view "$repo" --json visibility --jq '.visibility | ascii_downcase')" || return 1
	_quality_plan "$visibility" 0
	[[ "$dry_run" -eq 0 ]] || return 0
	branch="$(git -C "$path" symbolic-ref --short HEAD)" || return 1
	common="$(git -C "$path" rev-parse --path-format=absolute --git-common-dir)" || return 1
	gitdir="$(git -C "$path" rev-parse --absolute-git-dir)" || return 1
	if [[ "$branch" == main || "$branch" == master || "$gitdir" == "$common" ]]; then
		print_error "quality writes require a feature branch in a linked worktree"
		return 1
	fi
	command -v python3 >/dev/null 2>&1 || return 1
	python3 "${SCRIPT_DIR}/wp_plugin_quality.py" onboard "$repo" "$path" "$visibility" || return 1
	(cd "$path" && bash "${SCRIPT_DIR}/repo-metrics-helper.sh" generate .) || return 1
	if [[ -n "$pr" ]]; then
		_quality_checks "$repo" "$pr" || return 1
	else
		print_warning "App visibility unverified until first PR; rerun quality --repo $repo --path $path --pr NUMBER"
	fi
	return 0
}

_quality_checks() {
	local repo="$1" pr="$2" head checks statuses service
	head="$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid)" || return 1
	checks="$(gh api --paginate "repos/${repo}/commits/${head}/check-runs?per_page=100" --jq '.check_runs[] | [.name, .app.slug] | join(" ")')" || return 1
	statuses="$(gh api --paginate "repos/${repo}/commits/${head}/statuses?per_page=100" --jq '.[].context')" || return 1
	for service in Codacy CodeFactor CodeRabbit Qlty Socket; do
		if printf '%s\n%s\n' "$checks" "$statuses" | grep -qi "$service"; then
			printf '%s: first PR integration observed (not a passing-result claim)\n' "$service"
		else
			print_warning "$service: no check/status on PR #$pr; verify app repository access/plan, then rerun"
		fi
	done
	return 0
}

# Template generation is asynchronous: do not clone an empty repository.
# This is a bounded provisioning gate, not a CI/review polling loop.
_wait_template() {
	local parent="$1" repo="$2" attempt head
	for ((attempt = 1; attempt <= 12; attempt++)); do
		head="$(git -C "$parent" ls-remote "https://github.com/${repo}.git" HEAD)" || return 1
		[[ -z "$head" ]] || return 0
		print_info "Waiting for template HEAD ($attempt/12)"
		[[ "$attempt" -eq 12 ]] || sleep 2
	done
	print_error "template generation is not ready; preserve $repo and resume cloning once HEAD exists"
	return 1
}

# Clone from the destination's parent; never initialize or commit in the
# primary checkout. GitHub templates provide fresh history server-side;
# local-only plugins retain the release history. Preserve failures for recovery.
_copy_starter() {
	local parent source_repo="$STARTER_REPO" clone_args=() homepage=()
	parent="$(dirname "$P_DEST")"
	mkdir -p "$parent" || return 1
	if [[ "$P_NO_GITHUB" -eq 1 ]]; then
		clone_args=(--branch "$P_TAG")
	else
		source_repo="${P_OWNER}/${P_SLUG}"
		[[ "$P_PLUGIN_URI" == "https://github.com/$source_repo" ]] || homepage=(--homepage "$P_PLUGIN_URI")
		gh repo create "$source_repo" "--${P_VISIBILITY}" --template "$STARTER_REPO" \
			--description "$P_DESCRIPTION" ${homepage[@]+"${homepage[@]}"} || return 1
		_wait_template "$parent" "$source_repo" || return 1
	fi
	git -C "$parent" -c advice.detachedHead=false clone --quiet ${clone_args[@]+"${clone_args[@]}"} \
		"https://github.com/${source_repo}.git" "$P_DEST" || return 1
	P_BRANCH="chore/${P_SLUG}-identity"
	local worktree_parent="${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}"
	mkdir -p "$worktree_parent" || return 1
	P_WORKTREE="${worktree_parent}/${P_OWNER}-${P_SLUG}-identity"
	[[ ! -e "$P_WORKTREE" ]] || {
		print_error "$P_WORKTREE already exists; preserve it and choose another slug"
		return 1
	}
	git -C "$P_DEST" worktree add -b "$P_BRANCH" "$P_WORKTREE" HEAD || return 1
	if ! "$P_WORKTREE/scripts/rename-plugin.sh" --help | grep -q -- '--author-uri'; then
		print_error "starter $P_TAG has no maker flags in scripts/rename-plugin.sh; release a newer starter first"
		return 1
	fi
	return 0
}

_rename() {
	local args=(--slug "$P_SLUG" --name "$P_NAME" --prefix "$P_PREFIX" --css "$P_CSS"
		--repo "${P_OWNER}/${P_SLUG}" --description "$P_DESCRIPTION" --author "$P_AUTHOR"
		--author-uri "$P_AUTHOR_URI" --plugin-uri "$P_PLUGIN_URI"
		--contributors "$P_CONTRIBUTORS" --donate "$P_DONATE")
	(cd "$P_WORKTREE" && scripts/rename-plugin.sh "${args[@]}") || return 1
	# No hosted analysis or release exists yet. Keep the marker block, but do
	# not ship badges that refer to unavailable services or starter results.
	python3 "${SCRIPT_DIR}/wp_plugin_quality.py" strip-badges "$P_WORKTREE/README.md" || return 1
	if command -v composer >/dev/null 2>&1; then
		(cd "$P_WORKTREE" && composer update --lock --quiet --no-interaction) || return 1
	else
		print_warning "composer not found; run composer update --lock in $P_WORKTREE before linting"
	fi
	git -C "$P_WORKTREE" add -A || return 1
	git -C "$P_WORKTREE" commit --quiet -m "chore: ${P_NAME} names and maker details" || return 1
	return 0
}

_publish() {
	[[ "$P_NO_GITHUB" -eq 0 ]] || return 0
	git -C "$P_WORKTREE" push --set-upstream origin "$P_BRANCH" || return 1
	printf 'Customize the plugin identity from WP Plugin Starter %s.\n\nVerification: run composer install and scripts/lint.sh in the identity worktree before merge.\n' "$P_TAG" |
		"${SCRIPT_DIR}/gh-write-helper.sh" pr create --repo "${P_OWNER}/${P_SLUG}" \
			--base "$P_DEFAULT_BRANCH" --head "$P_BRANCH" --title "chore: ${P_NAME} names and maker details" --body-file - || return 1
	return 0
}

_register_quality() {
	[[ "$P_NO_GITHUB" -eq 0 ]] || return 0
	command -v aidevops >/dev/null 2>&1 || {
		print_error "aidevops missing: registration incomplete; repositories and worktree are preserved"
		return 1
	}
	# The starter already has metadata: --slug is only for metadata-free clones.
	if [[ -f "$P_DEST/.aidevops.json" ]]; then
		(cd "$P_DEST" && aidevops repos add) || return 1
	else
		(cd "$P_DEST" && aidevops repos add --slug "${P_OWNER}/${P_SLUG}" \
			--confirm REGISTER_CANONICAL_REPOSITORY) || return 1
	fi
	# Init may only stage files. Commit its output in the linked worktree so
	# rename-plugin's clean-tree check passes before identity changes are staged.
	(cd "$P_WORKTREE" && aidevops init code-quality) || return 1
	local status
	status="$(git -C "$P_WORKTREE" status --porcelain)" || return 1
	if [[ -n "$status" ]]; then
		git -C "$P_WORKTREE" add -A || return 1
		git -C "$P_WORKTREE" commit --quiet -m "chore: initialize aidevops code-quality" || return 1
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
	_copy_starter || return 1
	_register_quality || return 1
	_rename || return 1
	_publish || {
		print_error "GitHub step failed; preserve $P_DEST and $P_WORKTREE to resume publication"
		return 1
	}
	print_success "Created ${P_NAME} in ${P_WORKTREE} (identity branch; merge the first PR after verification)"
	printf 'PLUGIN_PATH=%s\n' "$P_WORKTREE"
	printf 'PLUGIN_CANONICAL_PATH=%s\n' "$P_DEST"
	printf 'PLUGIN_BRANCH=%s\n' "$P_BRANCH"
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
	quality) cmd_quality "$@" || return $? ;;
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
