#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# readme-badges-helper.sh — render and inject the canonical README badge
# block into managed repos (t2834).
#
# Three subcommands:
#
#   render <slug> [--branch BRANCH]
#       Print the rendered badge markdown for a repo slug to stdout.
#       Reads ~/.config/aidevops/repos.json for repo metadata (foss flag,
#       local_only flag, etc.) so the rendered set is appropriate.
#
#   inject <readme-path> <slug> [--branch BRANCH]
#       Idempotently insert/replace the badge block in a README.md, bounded
#       by the markers <!-- aidevops:badges:start --> / <!-- ...:end -->.
#       If the markers don't exist, the block is inserted after the first
#       H1 (or at the top of the file if no H1).
#
#   check <readme-path> <slug> [--branch BRANCH]
#       Compare the README's current badge block to what would be rendered.
#       Exit 0 if they match (or no block present and not requested), exit 1
#       if drift detected. Used by Phase 2's `aidevops badges check`.
#
# The template lives at:
#   .agents/templates/readme/badges.md.tmpl   (in the aidevops repo)
#   ~/.aidevops/agents/templates/readme/badges.md.tmpl   (deployed)
#
# Template substitutions:
#   {{SLUG}}            — owner/repo
#   {{OWNER}}           — owner
#   {{REPO}}            — repo
#   {{DEFAULT_BRANCH}}  — default branch (default: main)
#   {{HAS_ACTIONS_WORKFLOW}} — "1" when a concrete Actions workflow file is known
#   {{ACTIONS_WORKFLOW_FILE}} — workflow file used for the native GitHub badge
#   {{HAS_REPO_METRICS}} — "1" if local repo metrics badges should render
#   {{HAS_LOC_BADGE}}    — compatibility alias for HAS_REPO_METRICS
#   {{HAS_RELEASES}}     — "1" when the repo has a published GitHub release
#   {{HAS_LICENSE}} / {{LICENSE_BADGE}} / {{LICENSE_URL}} — SPDX licence badge
#   {{HAS_SONARCLOUD}} / {{SONAR_PROJECT_KEY}} — SonarCloud knows the project
#   {{HAS_CODACY}} / {{CODACY_GRADE_URL}}      — Codacy knows the repository
#   {{HAS_CODEFACTOR}}                         — CodeFactor knows the repository
#   {{IS_WP_PLUGIN}} / {{WP_REQUIRES}} / {{WP_TESTED}} / {{WP_REQUIRES_PHP}} /
#   {{WP_INFO_URL}} / {{HAS_WPORG}} / {{WPORG_SLUG}} — wordpress-plugin profile
#
# Repo-owned template: when --template is not given and the repository has
# .github/readme-badges.md.tmpl, that template is used for render/inject/check.
#
# Conditional lines: a line beginning with "{{?KEY}}" is included only
# when KEY is non-empty; "{{!KEY}}" is included only when KEY is empty.
# Both prefixes are stripped from the emitted line.
#
# Usage:
#   readme-badges-helper.sh render <slug> [options]
#   readme-badges-helper.sh inject <readme-path> <slug> [options]
#   readme-badges-helper.sh check <readme-path> <slug> [options]
#
# Options:
#   --branch BRANCH        Override default branch detection
#   --template PATH        Override template location
#   --workflow-file FILE   Override GitHub Actions workflow badge file
#   --no-repo-metrics      Skip local LOC/language/dependency badge lines
#   --no-loc-badge         Compatibility alias for --no-repo-metrics
#   --has-releases 0|1     Force the "has releases" flag (skip gh probe)
#   --offline              Skip network probes (quality services, WordPress.org,
#                          GitHub licence/releases); use local files only
#   -h, --help             Show usage
#
# Exit codes:
#   0 — success
#   1 — runtime error
#   2 — usage error
#   3 — drift detected (check subcommand only)

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

MARKER_START='<!-- aidevops:badges:start -->'
MARKER_END='<!-- aidevops:badges:end -->'
MARKER_NOTICE='<!-- managed by aidevops badges; edit the template, not this block -->'

# Resolve template location: prefer in-repo (during framework dev), fall
# back to the deployed copy under ~/.aidevops/agents/.
default_template_path() {
	local _script_dir
	_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local _candidates=(
		"$_script_dir/../templates/readme/badges.md.tmpl"
		"$HOME/.aidevops/agents/templates/readme/badges.md.tmpl"
	)
	local _candidate
	for _candidate in "${_candidates[@]}"; do
		if [[ -f "$_candidate" ]]; then
			printf '%s' "$_candidate"
			return 0
		fi
	done
	printf '%s' "${_candidates[0]}"
	return 0
}

# ───────────────────────────── logging ────────────────────────────────────

log() {
	local _msg="$1"
	printf '[%s] %s\n' "$SCRIPT_NAME" "$_msg" >&2
	return 0
}

die() {
	local _msg="$1"
	local _code="${2:-1}"
	printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$_msg" >&2
	exit "$_code"
}

usage() {
	sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# ───────────────────────────── repos.json lookup ──────────────────────────

REPOS_JSON="${REPOS_JSON:-$HOME/.config/aidevops/repos.json}"

repos_json_lookup() {
	local _slug="$1"
	local _key="$2"
	local _default="$3"
	if [[ ! -f "$REPOS_JSON" ]]; then
		printf '%s' "$_default"
		return 0
	fi
	local _value
	_value=$(jq -r --arg slug "$_slug" --arg key "$_key" '
		(.initialized_repos // [])
		| map(select(.slug == $slug))
		| if length == 0 then null else .[0][$key] end
		// empty
	' "$REPOS_JSON" 2>/dev/null || true)
	if [[ -z "$_value" || "$_value" == "null" ]]; then
		printf '%s' "$_default"
	else
		printf '%s' "$_value"
	fi
	return 0
}

# ───────────────────────────── arg parsing ────────────────────────────────

CMD=""
SLUG=""
README_PATH=""
BRANCH_OVERRIDE=""
TEMPLATE_OVERRIDE=""
WORKFLOW_FILE_OVERRIDE=""
NO_REPO_METRICS=0
HAS_RELEASES_OVERRIDE=""
OFFLINE=0
REPO_TEMPLATE_RELPATH=".github/readme-badges.md.tmpl"

parse_args() {
	if [[ $# -lt 1 ]]; then
		usage
		exit 2
	fi
	# All access to $1/$2 is via local vars to satisfy the positional-
	# parameter ratchet. _arg is the current option, _val is its value.
	local _cmd="$1"
	CMD="$_cmd"
	shift

	case "$CMD" in
		render)
			[[ $# -ge 1 ]] || die "render: <slug> required" 2
			local _slug="$1"
			SLUG="$_slug"
			shift
			;;
		inject | check)
			[[ $# -ge 2 ]] || die "$CMD: <readme-path> <slug> required" 2
			local _readme="$1"
			local _slug="$2"
			README_PATH="$_readme"
			SLUG="$_slug"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "unknown subcommand: $CMD (try render|inject|check)" 2
			;;
	esac

	while (($# > 0)); do
		local _arg="$1"
		case "$_arg" in
			--branch)
				[[ $# -ge 2 ]] || die "--branch requires an argument" 2
				local _val="$2"
				BRANCH_OVERRIDE="$_val"
				shift 2
				;;
			--template)
				[[ $# -ge 2 ]] || die "--template requires an argument" 2
				local _val="$2"
				TEMPLATE_OVERRIDE="$_val"
				shift 2
				;;
			--workflow-file)
				[[ $# -ge 2 ]] || die "--workflow-file requires an argument" 2
				local _val="$2"
				validate_workflow_file "$_val"
				WORKFLOW_FILE_OVERRIDE="$_val"
				shift 2
				;;
			--no-repo-metrics | --no-loc-badge)
				NO_REPO_METRICS=1
				shift
				;;
			--has-releases)
				[[ $# -ge 2 ]] || die "--has-releases requires 0|1" 2
				local _val="$2"
				HAS_RELEASES_OVERRIDE="$_val"
				shift 2
				;;
			--offline)
				OFFLINE=1
				shift
				;;
			-h | --help)
				usage
				exit 0
				;;
			*)
				die "unknown option: $_arg" 2
				;;
		esac
	done
	return 0
}

# ───────────────────────────── slug validation ────────────────────────────

# Slug must look like owner/repo; both segments are GitHub-style identifiers.
validate_slug() {
	local _slug="$1"
	if [[ ! "$_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
		die "invalid slug (expected owner/repo, got: $_slug)" 2
	fi
	return 0
}

validate_workflow_file() {
	local _workflow_file="$1"
	if [[ ! "$_workflow_file" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]]; then
		die "invalid workflow file (expected basename ending .yml/.yaml, got: $_workflow_file)" 2
	fi
	return 0
}

# ───────────────────────────── flag computation ───────────────────────────

# Returns "1" if the slug has at least one published GitHub release.
# Fail-soft: any error or missing gh returns "" so the conditional skips the line.
detect_has_releases() {
	local _slug="$1"
	if [[ -n "$HAS_RELEASES_OVERRIDE" ]]; then
		case "$HAS_RELEASES_OVERRIDE" in
			1 | true | yes) printf '1' ;;
			*) printf '' ;;
		esac
		return 0
	fi
	if [[ "$OFFLINE" -eq 1 ]] || ! command -v gh >/dev/null 2>&1; then
		printf ''
		return 0
	fi
	local _count
	_count=$(gh api "repos/$_slug/releases?per_page=1" --jq 'length' 2>/dev/null || true)
	[[ "$_count" =~ ^[0-9]+$ ]] || _count=0
	if [[ "$_count" -ge 1 ]]; then
		printf '1'
	else
		printf ''
	fi
	return 0
}

# Detect default branch from gh; fall back to "main".
detect_default_branch() {
	local _slug="$1"
	if [[ -n "$BRANCH_OVERRIDE" ]]; then
		printf '%s' "$BRANCH_OVERRIDE"
		return 0
	fi
	if [[ "$OFFLINE" -eq 1 ]] || ! command -v gh >/dev/null 2>&1; then
		printf 'main'
		return 0
	fi
	local _branch
	# gh prints the error body on stdout for HTTP errors (for example 404), so
	# discard output on failure and accept only a plausible branch name.
	_branch=$(gh api "repos/$_slug" --jq '.default_branch // "main"' 2>/dev/null) || _branch=""
	[[ "$_branch" =~ ^[A-Za-z0-9._/-]+$ ]] || _branch="main"
	printf '%s' "$_branch"
	return 0
}

expand_repo_path() {
	local _path="$1"
	if [[ "${_path:0:1}" == "~" && "${_path:1:1}" == "/" ]]; then
		printf '%s/%s' "$HOME" "${_path#~/}"
	else
		printf '%s' "$_path"
	fi
	return 0
}

detect_workflow_in_path() {
	local _repo_path="$1"
	[[ -n "$_repo_path" ]] || return 1

	_repo_path=$(expand_repo_path "$_repo_path")
	local _workflow_dir="$_repo_path/.github/workflows"
	[[ -d "$_workflow_dir" ]] || return 1

	local _candidate
	local _preferred=(
		"code-quality.yml"
		"code-quality.yaml"
		"ci.yml"
		"ci.yaml"
		"test.yml"
		"test.yaml"
		"tests.yml"
		"tests.yaml"
		"build.yml"
		"build.yaml"
	)
	for _candidate in "${_preferred[@]}"; do
		if [[ -f "$_workflow_dir/$_candidate" ]]; then
			printf '%s' "$_candidate"
			return 0
		fi
	done

	local _found=""
	local _count=0
	for _candidate in "$_workflow_dir"/*.yml "$_workflow_dir"/*.yaml; do
		[[ -f "$_candidate" ]] || continue
		_count=$((_count + 1))
		_found="${_candidate##*/}"
	done

	if [[ "$_count" -eq 1 && -n "$_found" ]]; then
		printf '%s' "$_found"
		return 0
	fi

	return 1
}

# Detect a concrete workflow file before rendering an Actions badge. This avoids
# broken image badges caused by hardcoded workflow names such as "CI" when a
# repo uses a different workflow file.
detect_actions_workflow_file() {
	local _slug="$1"
	if [[ -n "$WORKFLOW_FILE_OVERRIDE" ]]; then
		printf '%s' "$WORKFLOW_FILE_OVERRIDE"
		return 0
	fi

	local _workflow_file=""
	local _repo_path=""
	if [[ -n "$README_PATH" ]]; then
		_repo_path=$(cd "$(dirname "$README_PATH")" 2>/dev/null && pwd || dirname "$README_PATH")
		if _workflow_file=$(detect_workflow_in_path "$_repo_path"); then
			printf '%s' "$_workflow_file"
			return 0
		fi
	fi

	_repo_path=$(repos_json_lookup "$_slug" "path" "")
	if [[ -n "$_repo_path" ]]; then
		if _workflow_file=$(detect_workflow_in_path "$_repo_path"); then
			printf '%s' "$_workflow_file"
			return 0
		fi
	fi

	printf ''
	return 0
}

# ───────────────────────────── local repo facts (GH#33532) ────────────────

# Local checkout used for file-based detection: the README's directory for
# inject/check, else the repos.json path. Empty when unknown.
resolve_repo_path() {
	local _slug="$1"
	local _path=""
	if [[ -n "$README_PATH" ]]; then
		_path=$(cd "$(dirname "$README_PATH")" 2>/dev/null && pwd || true)
	fi
	if [[ -z "$_path" ]]; then
		_path=$(repos_json_lookup "$_slug" "path" "")
		[[ -z "$_path" ]] || _path=$(expand_repo_path "$_path")
	fi
	[[ -n "$_path" && -d "$_path" ]] || _path=""
	printf '%s' "$_path"
	return 0
}

# Print a "Field: value" header value from the first 8 KB of a file, the
# range WordPress reads for plugin headers and readme.txt fields.
file_header_field() {
	local _file="$1"
	local _field="$2"
	[[ -f "$_file" ]] || return 0
	head -c 8192 "$_file" 2>/dev/null | tr -d '\r' | awk -v f="$_field" '
		{
			line = $0
			sub(/^[[:space:]\/*#@]*/, "", line)
			if (tolower(substr(line, 1, length(f) + 1)) == tolower(f ":")) {
				v = substr(line, length(f) + 2)
				sub(/\*\/.*$/, "", v)
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
				print v
				exit
			}
		}'
	return 0
}

# Main WordPress plugin file: a root *.php file with a "Plugin Name:" header,
# preferring <repo-dir-name>.php.
find_wp_main_file() {
	local _repo_path="$1"
	[[ -n "$_repo_path" ]] || return 1
	local _preferred
	_preferred="$_repo_path/$(basename "$_repo_path").php"
	if [[ -n "$(file_header_field "$_preferred" "Plugin Name")" ]]; then
		printf '%s' "$_preferred"
		return 0
	fi
	local _candidate
	for _candidate in "$_repo_path"/*.php; do
		[[ -f "$_candidate" ]] || continue
		if [[ -n "$(file_header_field "$_candidate" "Plugin Name")" ]]; then
			printf '%s' "$_candidate"
			return 0
		fi
	done
	return 1
}

# HTTP status for a URL, or 000 when offline/unreachable. Never fails.
http_status() {
	local _url="$1"
	local _code="000"
	if [[ "$OFFLINE" -eq 0 ]] && command -v curl >/dev/null 2>&1; then
		_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$_url" 2>/dev/null) || true
	fi
	[[ "$_code" =~ ^[0-9]{3}$ ]] || _code="000"
	printf '%s' "$_code"
	return 0
}

# GET a URL body (offline: empty). Never fails.
http_get() {
	local _url="$1"
	if [[ "$OFFLINE" -eq 0 ]] && command -v curl >/dev/null 2>&1; then
		curl -s --max-time 8 "$_url" 2>/dev/null || true
	fi
	return 0
}

# Normalise a licence string to an SPDX expression. Legacy WordPress forms
# ("GPLv2 or later", "GPL-2.0+") map to their SPDX names; anything that is not
# a plain SPDX expression is rejected (empty output).
normalise_spdx() {
	local _raw="$1"
	_raw=$(printf '%s' "$_raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
	local _lower
	_lower=$(printf '%s' "$_raw" | tr '[:upper:]' '[:lower:]')
	case "$_lower" in
		"gpl-2.0+" | "gplv2+" | "gpl2+" | "gplv2 or later" | "gpl v2 or later" | "gpl-2.0 or later" | "gpl-2.0-or-later")
			printf 'GPL-2.0-or-later'
			return 0
			;;
		"gpl-3.0+" | "gplv3+" | "gpl3+" | "gplv3 or later" | "gpl v3 or later" | "gpl-3.0 or later" | "gpl-3.0-or-later")
			printf 'GPL-3.0-or-later'
			return 0
			;;
		"gplv2" | "gpl v2" | "gpl2")
			printf 'GPL-2.0'
			return 0
			;;
		"gplv3" | "gpl v3" | "gpl3")
			printf 'GPL-3.0'
			return 0
			;;
		"noassertion" | "other" | "proprietary" | "")
			return 0
			;;
	esac
	if [[ "$_raw" =~ ^[A-Za-z0-9.+-]+([[:space:]]+(OR|AND|WITH)[[:space:]]+[A-Za-z0-9.+-]+)*$ ]]; then
		printf '%s' "$_raw"
	fi
	return 0
}

# Licence from LICENSE text, for unambiguous licences only. GPL-family texts
# do not say "only" or "or later", so they are left to metadata.
spdx_from_license_text() {
	local _file="$1"
	[[ -f "$_file" ]] || return 0
	local _text
	_text=$(head -c 4096 "$_file" 2>/dev/null | tr -s '[:space:]' ' ')
	case "$_text" in
		*"Permission is hereby granted, free of charge"*) printf 'MIT' ;;
		*"Apache License"*"Version 2.0"*) printf 'Apache-2.0' ;;
		*"Mozilla Public License"*"2.0"*) printf 'MPL-2.0' ;;
		*"This is free and unencumbered software released into the public domain"*) printf 'Unlicense' ;;
		*"Permission to use, copy, modify, and/or distribute this software for any purpose"*) printf 'ISC' ;;
	esac
	return 0
}

# Shields static-badge path segment: "-" → "--", "_" → "__", URL-encode the rest.
shields_escape() {
	local _value="$1"
	_value="${_value//-/--}"
	_value="${_value//_/__}"
	_value="${_value// /%20}"
	_value="${_value//+/%2B}"
	_value="${_value//(/%28}"
	_value="${_value//)/%29}"
	_value="${_value//\//%2F}"
	printf '%s' "$_value"
	return 0
}

# Sets HAS_LICENSE_VAL, LICENSE_BADGE_VAL, LICENSE_URL_VAL.
detect_license() {
	local _slug="$1"
	local _repo_path="$2"
	local _wp_main="$3"
	local _spdx="" _license_file=""

	if [[ -n "$_repo_path" ]]; then
		local _name
		for _name in LICENSE LICENSE.md LICENSE.txt COPYING COPYING.md license.txt; do
			if [[ -f "$_repo_path/$_name" ]]; then
				_license_file="$_name"
				break
			fi
		done
		if [[ -f "$_repo_path/composer.json" ]]; then
			_spdx=$(normalise_spdx "$(jq -r 'if (.license | type) == "array" then .license | join(" OR ") else (.license // "") end' "$_repo_path/composer.json" 2>/dev/null || true)")
		fi
		if [[ -z "$_spdx" && -f "$_repo_path/package.json" ]]; then
			_spdx=$(normalise_spdx "$(jq -r 'if (.license | type) == "object" then (.license.type // "") else (.license // "") end' "$_repo_path/package.json" 2>/dev/null || true)")
		fi
		if [[ -z "$_spdx" && -n "$_wp_main" ]]; then
			_spdx=$(normalise_spdx "$(file_header_field "$_wp_main" "License")")
		fi
		if [[ -z "$_spdx" && -n "$_license_file" ]]; then
			_spdx=$(spdx_from_license_text "$_repo_path/$_license_file")
		fi
	fi
	if [[ -z "$_spdx" && "$OFFLINE" -eq 0 ]] && command -v gh >/dev/null 2>&1; then
		local _api_spdx
		_api_spdx=$(gh api "repos/$_slug/license" --jq '.license.spdx_id // ""' 2>/dev/null) || _api_spdx=""
		_spdx=$(normalise_spdx "$_api_spdx")
	fi

	# Without a checkout the licence cannot be disproved, so keep the badge.
	if [[ -n "$_repo_path" && -z "$_license_file" && -z "$_spdx" ]]; then
		HAS_LICENSE_VAL=""
	else
		HAS_LICENSE_VAL="1"
	fi
	if [[ -n "$_spdx" ]]; then
		LICENSE_BADGE_VAL="$(shields_escape "$_spdx")-blue"
	else
		LICENSE_BADGE_VAL="see%20file-yellow"
	fi
	if [[ -n "$_license_file" || -z "$_repo_path" ]]; then
		LICENSE_URL_VAL="https://github.com/$_slug/blob/$DEFAULT_BRANCH_VAL/${_license_file:-LICENSE}"
	elif [[ "$_spdx" =~ ^[A-Za-z0-9.+-]+$ ]]; then
		LICENSE_URL_VAL="https://spdx.org/licenses/$_spdx.html"
	else
		LICENSE_URL_VAL="https://github.com/$_slug"
	fi
	return 0
}

# Sets HAS_SONARCLOUD_VAL/SONAR_PROJECT_KEY_VAL, HAS_CODACY_VAL/CODACY_GRADE_URL_VAL,
# HAS_CODEFACTOR_VAL. Each badge renders only when the service knows the repo.
detect_quality_services() {
	local _slug="$1"
	local _repo_path="$2"
	HAS_SONARCLOUD_VAL=""
	SONAR_PROJECT_KEY_VAL="${OWNER_VAL}_${REPO_VAL}"
	HAS_CODACY_VAL=""
	CODACY_GRADE_URL_VAL=""
	HAS_CODEFACTOR_VAL=""
	[[ "$OFFLINE" -eq 0 ]] || return 0

	local _key=""
	[[ -z "$_repo_path" ]] || _key=$(sed -n -E 's/^[[:space:]]*sonar\.projectKey[[:space:]]*=[[:space:]]*([A-Za-z0-9_.:-]+)[[:space:]]*$/\1/p' "$_repo_path/sonar-project.properties" 2>/dev/null | head -n 1)
	[[ -z "$_key" ]] || SONAR_PROJECT_KEY_VAL="$_key"
	if [[ "$(http_status "https://sonarcloud.io/api/components/show?component=$SONAR_PROJECT_KEY_VAL")" == "200" ]]; then
		HAS_SONARCLOUD_VAL="1"
	fi

	local _grade=""
	_grade=$(http_get "https://app.codacy.com/api/v3/organizations/gh/$OWNER_VAL/repositories/$REPO_VAL" | jq -r '.data.badges.grade // empty' 2>/dev/null || true)
	if [[ "$_grade" =~ ^https://app\.codacy\.com/project/badge/Grade/[A-Za-z0-9]+$ ]]; then
		HAS_CODACY_VAL="1"
		CODACY_GRADE_URL_VAL="$_grade"
	fi

	if [[ "$(http_status "https://www.codefactor.io/repository/github/$_slug/badge")" == "200" ]]; then
		HAS_CODEFACTOR_VAL="1"
	fi
	return 0
}

# Lowercase alphanumerics only, for comparing plugin names.
_name_key() {
	local _value="$1"
	printf '%s' "$_value" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'
	return 0
}

# wordpress-plugin profile. Sets IS_WP_PLUGIN_VAL, WP_REQUIRES_VAL,
# WP_TESTED_VAL, WP_REQUIRES_PHP_VAL, WP_INFO_URL_VAL, HAS_WPORG_VAL, WPORG_SLUG_VAL.
detect_wp_profile() {
	local _slug="$1"
	local _repo_path="$2"
	local _main="$3"
	IS_WP_PLUGIN_VAL=""
	WP_REQUIRES_VAL=""
	WP_TESTED_VAL=""
	WP_REQUIRES_PHP_VAL=""
	WP_INFO_URL_VAL=""
	HAS_WPORG_VAL=""
	WPORG_SLUG_VAL=""
	[[ -n "$_main" ]] || return 0
	IS_WP_PLUGIN_VAL="1"

	local _readme="$_repo_path/readme.txt"
	local _version_re='^[0-9]+(\.[0-9]+){0,3}$'
	local _value
	_value=$(file_header_field "$_main" "Requires at least")
	[[ -n "$_value" ]] || _value=$(file_header_field "$_readme" "Requires at least")
	[[ ! "$_value" =~ $_version_re ]] || WP_REQUIRES_VAL="$_value"
	_value=$(file_header_field "$_readme" "Tested up to")
	[[ -n "$_value" ]] || _value=$(file_header_field "$_main" "Tested up to")
	[[ ! "$_value" =~ $_version_re ]] || WP_TESTED_VAL="$_value"
	_value=$(file_header_field "$_main" "Requires PHP")
	[[ -n "$_value" ]] || _value=$(file_header_field "$_readme" "Requires PHP")
	[[ ! "$_value" =~ $_version_re ]] || WP_REQUIRES_PHP_VAL="$_value"

	local _info_file="readme.txt"
	[[ -f "$_readme" ]] || _info_file="${_main##*/}"
	WP_INFO_URL_VAL="https://github.com/$_slug/blob/$DEFAULT_BRANCH_VAL/$_info_file"

	# WordPress.org listing: slug from the text domain or main file name, and
	# the listed name must match the header so a same-slug plugin never shows.
	local _wporg_slug
	_wporg_slug=$(file_header_field "$_main" "Text Domain")
	[[ -n "$_wporg_slug" ]] || _wporg_slug=$(basename "$_main" .php)
	[[ "$_wporg_slug" =~ ^[a-z0-9-]+$ ]] || return 0
	[[ "$OFFLINE" -eq 0 ]] || return 0
	local _listed_name
	_listed_name=$(http_get "https://api.wordpress.org/plugins/info/1.2/?action=plugin_information&request%5Bslug%5D=$_wporg_slug&request%5Bfields%5D%5Bsections%5D=0" | jq -r '.name // empty' 2>/dev/null || true)
	if [[ -n "$_listed_name" && "$(_name_key "$_listed_name")" == "$(_name_key "$(file_header_field "$_main" "Plugin Name")")" ]]; then
		HAS_WPORG_VAL="1"
		WPORG_SLUG_VAL="$_wporg_slug"
	fi
	return 0
}

# ───────────────────────────── template render ────────────────────────────

# Substitute {{KEY}} with the value of the corresponding env var (KEY must
# match a name like SLUG / OWNER / REPO / DEFAULT_BRANCH /
# HAS_ACTIONS_WORKFLOW / ACTIONS_WORKFLOW_FILE / HAS_REPO_METRICS /
# HAS_LOC_BADGE / HAS_RELEASES / IS_FOSS). Conditional lines:
#   "{{?KEY}}rest"   — included only if KEY is non-empty (prefix stripped)
#   "{{!KEY}}rest"   — included only if KEY is empty (prefix stripped)
BADGE_TEMPLATE_KEYS=(
	SLUG OWNER REPO DEFAULT_BRANCH HAS_ACTIONS_WORKFLOW ACTIONS_WORKFLOW_FILE
	HAS_REPO_METRICS HAS_LOC_BADGE HAS_RELEASES IS_FOSS
	HAS_LICENSE LICENSE_BADGE LICENSE_URL
	HAS_SONARCLOUD SONAR_PROJECT_KEY HAS_CODACY CODACY_GRADE_URL HAS_CODEFACTOR
	IS_WP_PLUGIN WP_REQUIRES WP_TESTED WP_REQUIRES_PHP WP_INFO_URL HAS_WPORG WPORG_SLUG
)

render_template() {
	local _template_path="$1"
	[[ -f "$_template_path" ]] || die "template not found: $_template_path"

	# Expose <KEY>_VAL as _AIDEVOPS_BADGE_<KEY>; awk reads them via ENVIRON
	# (BSD awk rejects embedded newlines in -v, and this keeps keys in one list).
	local _key _val_name
	for _key in "${BADGE_TEMPLATE_KEYS[@]}"; do
		_val_name="${_key}_VAL"
		export "_AIDEVOPS_BADGE_${_key}=${!_val_name:-}"
	done
	awk '
		function get_var(k) {
			return ENVIRON["_AIDEVOPS_BADGE_" k]
		}
		# Portable key extraction (BSD awk has no 3-arg match capture).
		# For prefix matches "{{?KEY}}" or "{{!KEY}}" the literal length of the
		# wrapper chars is 5 (3-char prefix + 2-char suffix). For inline
		# "{{KEY}}" the wrapper is 4 chars ({{ + }}).
		function extract_prefix_key(s,    inner) {
			inner = substr(s, 4, length(s) - 5)
			return inner
		}
		function extract_inline_key(s,    inner) {
			inner = substr(s, 3, length(s) - 4)
			return inner
		}
		{
			line = $0
			# Conditional include: {{?KEY}}rest
			if (match(line, /^\{\{\?[A-Z_]+\}\}/)) {
				matched = substr(line, RSTART, RLENGTH)
				key = extract_prefix_key(matched)
				rest = substr(line, RLENGTH + 1)
				if (get_var(key) != "") line = rest
				else next
			}
			# Conditional exclude: {{!KEY}}rest
			else if (match(line, /^\{\{![A-Z_]+\}\}/)) {
				matched = substr(line, RSTART, RLENGTH)
				key = extract_prefix_key(matched)
				rest = substr(line, RLENGTH + 1)
				if (get_var(key) == "") line = rest
				else next
			}
			# Substitute {{KEY}} placeholders within the line. Iterate, not
			# recurse, in case the substituted value contains another {{...}}
			# sequence (avoid infinite loop by walking left-to-right with a
			# moving cursor and a hard iteration cap).
			iter = 0
			while (iter < 64 && match(line, /\{\{[A-Z_]+\}\}/)) {
				matched = substr(line, RSTART, RLENGTH)
				key = extract_inline_key(matched)
				val = get_var(key)
				line = substr(line, 1, RSTART - 1) val substr(line, RSTART + RLENGTH)
				iter++
			}
			print line
		}
	' "$_template_path"
	return 0
}

# Compute and export all render variables for the configured slug.
prepare_render_vars() {
	validate_slug "$SLUG"

	SLUG_VAL="$SLUG"
	OWNER_VAL="${SLUG%%/*}"
	REPO_VAL="${SLUG##*/}"
	DEFAULT_BRANCH_VAL=$(detect_default_branch "$SLUG")
	ACTIONS_WORKFLOW_FILE_VAL=$(detect_actions_workflow_file "$SLUG")
	if [[ -n "$ACTIONS_WORKFLOW_FILE_VAL" ]]; then
		HAS_ACTIONS_WORKFLOW_VAL="1"
	else
		HAS_ACTIONS_WORKFLOW_VAL=""
	fi

	# Repo metadata from repos.json (fail-soft to "")
	local _local_only=0
	[[ "$(repos_json_lookup "$SLUG" "local_only" "")" != "true" ]] || _local_only=1
	if [[ "$_local_only" -eq 1 ]]; then
		# local_only repos can't be queried via gh — most badges are useless.
		# Emit only LOC + license. Force HAS_RELEASES empty.
		HAS_RELEASES_VAL=""
	else
		HAS_RELEASES_VAL=$(detect_has_releases "$SLUG")
	fi

	IS_FOSS_VAL=$(repos_json_lookup "$SLUG" "foss" "")
	[[ "$IS_FOSS_VAL" == "true" ]] && IS_FOSS_VAL="1" || IS_FOSS_VAL=""

	# Local repo metrics are generated by repo-metrics-helper.sh during init/sync.
	# They use relative README paths and work for both public and local-only repos.
	if [[ "$NO_REPO_METRICS" -eq 1 ]]; then
		HAS_REPO_METRICS_VAL=""
		HAS_LOC_BADGE_VAL=""
	else
		HAS_REPO_METRICS_VAL="1"
		HAS_LOC_BADGE_VAL="1"
	fi

	# GH#33532: file-based facts (licence, WordPress profile) and quality
	# services. local_only repos are unknown to public services.
	REPO_PATH_VAL=$(resolve_repo_path "$SLUG")
	local _wp_main="" _saved_offline="$OFFLINE"
	_wp_main=$(find_wp_main_file "$REPO_PATH_VAL") || _wp_main=""
	[[ "$_local_only" -eq 0 ]] || OFFLINE=1
	detect_license "$SLUG" "$REPO_PATH_VAL" "$_wp_main"
	detect_wp_profile "$SLUG" "$REPO_PATH_VAL" "$_wp_main"
	detect_quality_services "$SLUG" "$REPO_PATH_VAL"
	OFFLINE="$_saved_offline"

	return 0
}

# Template: --template, else the repository's own .github/readme-badges.md.tmpl,
# else the canonical aidevops template.
resolve_template_path() {
	if [[ -n "$TEMPLATE_OVERRIDE" ]]; then
		printf '%s' "$TEMPLATE_OVERRIDE"
	elif [[ -n "${REPO_PATH_VAL:-}" && -f "$REPO_PATH_VAL/$REPO_TEMPLATE_RELPATH" ]]; then
		printf '%s' "$REPO_PATH_VAL/$REPO_TEMPLATE_RELPATH"
	else
		default_template_path
	fi
	return 0
}

# Render the template framed by the marker block.
render_full_block() {
	prepare_render_vars
	local _template_path
	_template_path=$(resolve_template_path)
	printf '%s\n' "$MARKER_START"
	printf '%s\n' "$MARKER_NOTICE"
	render_template "$_template_path"
	printf '%s\n' "$MARKER_END"
	return 0
}

# ───────────────────────────── inject / check ─────────────────────────────

# Read the existing badge block from a README, or empty if absent.
extract_existing_block() {
	local _readme="$1"
	[[ -f "$_readme" ]] || return 0
	awk -v start="$MARKER_START" -v end="$MARKER_END" '
		$0 == start { in_block = 1 }
		in_block { print }
		$0 == end { in_block = 0 }
	' "$_readme"
	return 0
}

# Replace the badge block in a README with the rendered output.
# If markers are absent, insert after first H1 (or at line 1 if no H1).
#
# BSD awk does not allow embedded newlines in -v variables, so the rendered
# block is staged to a temp file and slurped via BEGIN { while getline ... }.
inject_block() {
	local _readme="$1"
	local _rendered="$2"

	[[ -f "$_readme" ]] || die "README not found: $_readme"

	local _tmp _repl
	_tmp=$(mktemp)
	_repl=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$_tmp' '$_repl'" EXIT
	printf '%s\n' "$_rendered" >"$_repl"

	if grep -qF "$MARKER_START" "$_readme"; then
		# Replace existing block (between start and end markers, inclusive).
		awk -v start="$MARKER_START" -v end="$MARKER_END" -v replfile="$_repl" '
			BEGIN {
				skipping = 0
				replcount = 0
				while ((getline line < replfile) > 0) {
					repl[replcount++] = line
				}
				close(replfile)
			}
			$0 == start {
				for (i = 0; i < replcount; i++) print repl[i]
				skipping = 1
				next
			}
			$0 == end {
				skipping = 0
				next
			}
			!skipping { print }
		' "$_readme" >"$_tmp"
	else
		# Insert after first H1 line, or at the top if no H1.
		if grep -qE '^# ' "$_readme"; then
			awk -v replfile="$_repl" '
				BEGIN {
					inserted = 0
					replcount = 0
					while ((getline line < replfile) > 0) {
						repl[replcount++] = line
					}
					close(replfile)
				}
				{ print }
				/^# / && !inserted {
					print ""
					for (i = 0; i < replcount; i++) print repl[i]
					inserted = 1
				}
			' "$_readme" >"$_tmp"
		else
			{
				printf '%s\n\n' "$_rendered"
				cat "$_readme"
			} >"$_tmp"
		fi
	fi

	mv "$_tmp" "$_readme"
	trap - EXIT
	log "updated $_readme"
	return 0
}

# Compare existing block to rendered; exit 0 (match), 3 (drift), or 0 (no
# block present — treated as up-to-date until injection is requested).
check_drift() {
	local _readme="$1"
	local _rendered="$2"

	if [[ ! -f "$_readme" ]]; then
		log "README not found: $_readme (no drift to report)"
		return 0
	fi

	local _existing
	_existing=$(extract_existing_block "$_readme")

	if [[ -z "$_existing" ]]; then
		log "no badge block present in $_readme — run inject to add it"
		return 0
	fi

	if [[ "$_existing" == "$_rendered" ]]; then
		log "badge block matches template ($_readme)"
		return 0
	fi

	log "drift detected in $_readme"
	# Show a unified diff for human readability.
	if command -v diff >/dev/null 2>&1; then
		diff -u <(printf '%s\n' "$_existing") <(printf '%s\n' "$_rendered") || true
	fi
	return 3
}

# ───────────────────────────── main ───────────────────────────────────────

main() {
	parse_args "$@"

	local _rendered
	_rendered=$(render_full_block)

	case "$CMD" in
		render)
			printf '%s\n' "$_rendered"
			;;
		inject)
			inject_block "$README_PATH" "$_rendered"
			;;
		check)
			check_drift "$README_PATH" "$_rendered"
			exit $?
			;;
	esac
	return 0
}

main "$@"
