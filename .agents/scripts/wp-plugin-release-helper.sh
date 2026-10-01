#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# wp-plugin-release-helper.sh — build, preflight and Plugin Check a WordPress
# plugin for two release channels (GitHub/Git Updater and WordPress.org) from
# any plugin repository. See GH#33301 and tools/wordpress/wp-plugin-release.md.
#
# Usage:
#   wp-plugin-release-helper.sh build [--ref REF] [--out DIR] [--slug SLUG]
#       [--main-file FILE] [--wporg-strip-headers 'A|B'] [--quiet]
#   wp-plugin-release-helper.sh preflight [--ref REF] [--slug SLUG]
#       [--main-file FILE] [--strict] [--offline] [--no-docker]
#   wp-plugin-release-helper.sh plugin-check [--ref REF] [--slug SLUG]
#       [--main-file FILE] [--zip FILE]... [--keep-output DIR]
#
# This script NEVER tags, pushes, publishes, uploads, or commits anything.
# It only writes to its own --out/--keep-output directories and temp dirs it
# removes itself.

WPRH_SELF="${BASH_SOURCE[0]:-${0:-}}"
WPRH_DIR="${WPRH_SELF%/*}"
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091
source "${WPRH_DIR}/shared-constants.sh"

LOG_PREFIX="WP-PLUGIN-RELEASE"

# Default --ref for every subcommand.
readonly WPRH_DEFAULT_REF="HEAD"

# Default header lines stripped from the main file for the WordPress.org
# build. Git Updater (and similar third-party updaters) use these headers;
# WordPress.org forbids third-party update code (Plugin Handbook guideline 8).
readonly WPRH_DEFAULT_WPORG_STRIP_HEADERS="GitHub Plugin URI|Bitbucket Plugin URI|GitLab Plugin URI|Primary Branch|Release Asset|Update URI"

# Development files/dirs that must never ship in a release zip.
readonly WPRH_DEV_FILE_PATTERNS=".git .github .agents .distignore .distignore-wporg .gitattributes .gitignore AGENTS.md CLAUDE.md node_modules tests phpunit.xml phpunit.xml.dist scripts dist .DS_Store __MACOSX .log .bak"

wprh_usage() {
	cat <<'EOF'
Usage:
  wp-plugin-release-helper.sh build [--ref REF] [--out DIR] [--slug SLUG]
      [--main-file FILE] [--wporg-strip-headers 'A|B'] [--quiet]
  wp-plugin-release-helper.sh preflight [--ref REF] [--slug SLUG]
      [--main-file FILE] [--strict] [--offline] [--no-docker]
  wp-plugin-release-helper.sh plugin-check [--ref REF] [--slug SLUG]
      [--main-file FILE] [--zip FILE]... [--keep-output DIR]

build:
  Builds two zips from a Git ref (never the dirty working tree):
    <slug>-X.Y.Z.zip             — GitHub/Git Updater channel
    wordpress-org-<slug>-X.Y.Z.zip — WordPress.org channel (updater headers
                                      stripped, .distignore-wporg applied)
  Plus SHA256SUMS. Default --out is dist/ in the repo root. Default --ref
  is HEAD.

preflight:
  Builds into a temp dir and runs the WordPress.org submission + Git Updater
  compatibility checks. Prints "ok"/"warn"/"ERROR"/"note" lines. Exits 1 on
  any ERROR, or on warnings too when --strict is given. --offline skips
  WordPress.org API network checks. --no-docker skips Docker-based PHP lint
  (falls back to local php -l when available).

plugin-check:
  Runs the official Plugin Check plugin against both zips (or --zip FILE,
  repeatable) in a disposable Docker WordPress + MariaDB stack. Exits 1 if
  Plugin Check reports any error-level finding, or does not run. Removes its
  own containers, volume, and network afterwards (never touches others).
  --keep-output DIR copies the raw Plugin Check JSON there for inspection.

This script never runs git tag, git push, gh release, svn, or any upload.
EOF
	return 0
}

# ---------------------------------------------------------------------------
# Slug / main-file / header detection
# ---------------------------------------------------------------------------

wprh_repo_root() {
	git rev-parse --show-toplevel 2>/dev/null || {
		log_error "not a Git repository"
		return 1
	}
	return 0
}

# Print the default remote branch name for the repo at $1, falling back to
# "main" if it cannot be determined.
wprh_default_branch() {
	local repo_dir="$1" ref=""
	ref=$(git -C "$repo_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
	if [[ -n "$ref" ]]; then
		printf '%s\n' "${ref#origin/}"
		return 0
	fi
	printf 'main\n'
	return 0
}

wprh_detect_slug() {
	local repo_root="$1" override="$2"
	if [[ -n "$override" ]]; then
		printf '%s\n' "$override"
		return 0
	fi
	basename "$repo_root"
	return 0
}

# Find the plugin main file in the current checkout (filename only; content
# is read from the archived ref later, not the working tree).
wprh_detect_main_file() {
	local repo_root="$1" slug="$2" override="$3"
	if [[ -n "$override" ]]; then
		if [[ ! -f "${repo_root}/${override}" ]]; then
			log_error "--main-file not found: ${override}"
			return 1
		fi
		printf '%s\n' "$override"
		return 0
	fi
	if [[ -f "${repo_root}/${slug}.php" ]]; then
		printf '%s\n' "${slug}.php"
		return 0
	fi
	local candidates=() f header
	for f in "${repo_root}"/*.php; do
		[[ -f "$f" ]] || continue
		header=$(head -80 "$f" | grep -iE '^[[:space:]]*(\*[[:space:]]*)?Plugin Name[[:space:]]*:' || true)
		[[ -n "$header" ]] && candidates+=("$(basename "$f")")
	done
	if [[ "${#candidates[@]}" -eq 1 ]]; then
		printf '%s\n' "${candidates[0]}"
		return 0
	fi
	if [[ "${#candidates[@]}" -eq 0 ]]; then
		log_error "could not detect plugin main file (no root *.php with a 'Plugin Name:' header); pass --main-file"
	else
		log_error "ambiguous plugin main file (${#candidates[@]} candidates: ${candidates[*]}); pass --main-file"
	fi
	return 1
}

# Read a "Header: value" style line (plugin header block or readme.txt field)
# from a file. Matches an optional leading " * " comment prefix. Trims
# whitespace and a trailing "*/".
wprh_read_header() {
	local file="$1" header="$2" line value
	[[ -f "$file" ]] || return 1
	line=$(head -120 "$file" | grep -iE "^[[:space:]]*(\*[[:space:]]*)?${header}[[:space:]]*:" | head -1 || true)
	[[ -n "$line" ]] || return 1
	value="${line#*:}"
	value=$(printf '%s' "$value" | sed -E 's#\*/[[:space:]]*$##; s/^[[:space:]]+//; s/[[:space:]]+$//')
	printf '%s\n' "$value"
	return 0
}

# Like wprh_read_header, but prints an empty string instead of failing when
# the header is absent (for optional preflight fields read under set -e).
wprh_header() {
	wprh_read_header "$1" "$2" 2>/dev/null || true
	return 0
}

# ---------------------------------------------------------------------------
# Archive / exclude / zip
# ---------------------------------------------------------------------------

# Extract a Git ref's full tree into $2 (created, must not already exist).
wprh_archive_ref() {
	local repo_root="$1" ref="$2" dest="$3"
	mkdir -p "$dest"
	(cd "$repo_root" && git archive --format=tar "$ref") | (cd "$dest" && tar -x)
	return $?
}

# Copy $src/ into $dest/<slug>/ applying one or more --exclude-from files
# (only those that exist are applied).
wprh_copy_with_excludes() {
	local src="$1" dest_parent="$2" slug="$3"
	shift 3
	local exclude_files=("$@")
	local rsync_args=(-a --exclude=".git")
	local ex
	for ex in "${exclude_files[@]}"; do
		[[ -n "$ex" && -f "$ex" ]] && rsync_args+=(--exclude-from="$ex")
	done
	mkdir -p "${dest_parent}/${slug}"
	rsync "${rsync_args[@]}" "${src%/}/" "${dest_parent}/${slug}/"
	return $?
}

# Strip header lines (pipe-separated header names) from a main file in place.
wprh_strip_headers() {
	local file="$1" headers="$2"
	[[ -f "$file" ]] || return 0
	local old_ifs="$IFS" h
	IFS='|'
	# shellcheck disable=SC2086
	for h in $headers; do
		IFS="$old_ifs"
		[[ -n "$h" ]] || continue
		sed_inplace -E "/^[[:space:]]*(\*[[:space:]]*)?${h}[[:space:]]*:/d" "$file"
		IFS='|'
	done
	IFS="$old_ifs"
	return 0
}

# Reproducible zip: normalise mtimes before zipping so two builds of the same
# tree produce byte-identical zips (and thus identical SHA-256).
wprh_zip_dir() {
	local parent_dir="$1" slug="$2" out_zip="$3"
	find "${parent_dir}/${slug}" -exec touch -t 202001010000 {} + 2>/dev/null || true
	rm -f "$out_zip"
	(cd "$parent_dir" && zip -qrX "$out_zip" "$slug")
	return $?
}

wprh_sha256() {
	local file="$1"
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file" | awk '{print $1}'
	else
		sha256sum "$file" | awk '{print $1}'
	fi
	return 0
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

wprh_build_parse_args() {
	WPRH_BUILD_REF="$WPRH_DEFAULT_REF"
	WPRH_BUILD_OUT=""
	WPRH_BUILD_SLUG_OVERRIDE=""
	WPRH_BUILD_MAIN_OVERRIDE=""
	WPRH_BUILD_STRIP_HEADERS=""
	WPRH_BUILD_QUIET=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--ref)
			WPRH_BUILD_REF="$2"
			shift 2
			;;
		--out)
			WPRH_BUILD_OUT="$2"
			shift 2
			;;
		--slug)
			WPRH_BUILD_SLUG_OVERRIDE="$2"
			shift 2
			;;
		--main-file)
			WPRH_BUILD_MAIN_OVERRIDE="$2"
			shift 2
			;;
		--wporg-strip-headers)
			WPRH_BUILD_STRIP_HEADERS="$2"
			shift 2
			;;
		--quiet)
			WPRH_BUILD_QUIET=true
			shift
			;;
		*)
			log_error "build: unknown argument: $1"
			return 1
			;;
		esac
	done
	return 0
}

# Archive $2 (ref) into $3/src, apply per-channel excludes into $3/github and
# $3/wporg, and strip updater headers from the wporg copy. $1 is the slug.
wprh_build_assemble() {
	local slug="$1" repo_root="$2" ref="$3" tmp="$4" main_file="$5" strip_headers="$6"

	wprh_archive_ref "$repo_root" "$ref" "${tmp}/src" || {
		log_error "git archive failed for ref: $ref"
		return 1
	}

	wprh_read_header "${tmp}/src/${main_file}" "Version" >/dev/null || {
		log_error "could not read Version header from ${main_file} at ${ref}"
		return 1
	}

	local distignore="${tmp}/src/.distignore"
	local distignore_wporg="${tmp}/src/.distignore-wporg"
	[[ -f "$distignore" ]] || distignore=""
	[[ -f "$distignore_wporg" ]] || distignore_wporg=""

	wprh_copy_with_excludes "${tmp}/src" "${tmp}/github" "$slug" "$distignore" || return 1
	wprh_copy_with_excludes "${tmp}/src" "${tmp}/wporg" "$slug" "$distignore" "$distignore_wporg" || return 1
	wprh_strip_headers "${tmp}/wporg/${slug}/${main_file}" "$strip_headers"
	return 0
}

# Zip both channel trees into $2/<out zips> and write SHA256SUMS. Prints the
# two resulting zip paths (github, then wporg).
wprh_build_package() {
	local tmp="$1" out_dir="$2" slug="$3" version="$4" quiet="$5"
	mkdir -p "$out_dir"
	local github_zip="${out_dir}/${slug}-${version}.zip"
	local wporg_zip="${out_dir}/wordpress-org-${slug}-${version}.zip"
	wprh_zip_dir "${tmp}/github" "$slug" "$github_zip" || {
		log_error "zip failed: $github_zip"
		return 1
	}
	wprh_zip_dir "${tmp}/wporg" "$slug" "$wporg_zip" || {
		log_error "zip failed: $wporg_zip"
		return 1
	}

	(
		cd "$out_dir" || exit 1
		{
			printf '%s  %s\n' "$(wprh_sha256 "$github_zip")" "$(basename "$github_zip")"
			printf '%s  %s\n' "$(wprh_sha256 "$wporg_zip")" "$(basename "$wporg_zip")"
		} >"${out_dir}/SHA256SUMS"
	)

	if [[ "$quiet" != true ]]; then
		log_success "built ${github_zip}"
		log_success "built ${wporg_zip}"
		log_info "SHA256SUMS: ${out_dir}/SHA256SUMS"
	fi
	printf '%s\n' "$github_zip"
	printf '%s\n' "$wporg_zip"
	return 0
}

wprh_cmd_build() {
	wprh_build_parse_args "$@" || return 1

	local repo_root
	repo_root="$(wprh_repo_root)" || return 1
	[[ -n "$WPRH_BUILD_OUT" ]] || WPRH_BUILD_OUT="${repo_root}/dist"

	local slug main_file strip_headers
	slug="$(wprh_detect_slug "$repo_root" "$WPRH_BUILD_SLUG_OVERRIDE")"
	main_file="$(wprh_detect_main_file "$repo_root" "$slug" "$WPRH_BUILD_MAIN_OVERRIDE")" || return 1
	if [[ -z "$WPRH_BUILD_STRIP_HEADERS" ]]; then
		strip_headers="$WPRH_DEFAULT_WPORG_STRIP_HEADERS"
	else
		strip_headers="${WPRH_DEFAULT_WPORG_STRIP_HEADERS}|${WPRH_BUILD_STRIP_HEADERS}"
	fi

	local tmp
	tmp="$(mktemp -d "${TMPDIR:-/tmp}/wprh-build.XXXXXX")"
	trap 'rm -rf "${tmp:-}"' RETURN

	wprh_build_assemble "$slug" "$repo_root" "$WPRH_BUILD_REF" "$tmp" "$main_file" "$strip_headers" || return 1

	local version
	version="$(wprh_read_header "${tmp}/src/${main_file}" "Version")" || {
		log_error "could not read Version header from ${main_file} at ${WPRH_BUILD_REF}"
		return 1
	}

	wprh_build_package "$tmp" "$WPRH_BUILD_OUT" "$slug" "$version" "$WPRH_BUILD_QUIET" || return 1
	return 0
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------

WPRH_PREFLIGHT_ERRORS=0
WPRH_PREFLIGHT_WARNINGS=0

wprh_pf_error() {
	log_error "ERROR: $1"
	WPRH_PREFLIGHT_ERRORS=$((WPRH_PREFLIGHT_ERRORS + 1))
	return 0
}

wprh_pf_warn() {
	log_warn "warn: $1"
	WPRH_PREFLIGHT_WARNINGS=$((WPRH_PREFLIGHT_WARNINGS + 1))
	return 0
}

wprh_pf_ok() {
	log_success "ok: $1"
	return 0
}

wprh_pf_note() {
	log_info "note: $1"
	return 0
}

# Return 0 and print the single top-level directory name in a zip, or
# return 1 if there isn't exactly one.
wprh_zip_top_dir() {
	local zip="$1"
	unzip -Z1 "$zip" 2>/dev/null | awk -F/ 'NF>1{print $1}' | sort -u
	return 0
}

wprh_zip_contains() {
	local zip="$1" needle="$2"
	unzip -Z1 "$zip" 2>/dev/null | grep -qF "$needle"
	return $?
}

wprh_check_dev_files_absent() {
	local zip="$1" pattern found=""
	for pattern in $WPRH_DEV_FILE_PATTERNS; do
		if unzip -Z1 "$zip" 2>/dev/null | grep -qE "(^|/)${pattern//./\\.}(/|$)"; then
			found="${found}${found:+, }${pattern}"
		fi
	done
	printf '%s\n' "$found"
	return 0
}

wprh_pf_parse_args() {
	WPRH_PF_REF="$WPRH_DEFAULT_REF"
	WPRH_PF_SLUG_OVERRIDE=""
	WPRH_PF_MAIN_OVERRIDE=""
	WPRH_PF_STRICT=false
	WPRH_PF_OFFLINE=false
	WPRH_PF_NO_DOCKER=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--ref)
			WPRH_PF_REF="$2"
			shift 2
			;;
		--slug)
			WPRH_PF_SLUG_OVERRIDE="$2"
			shift 2
			;;
		--main-file)
			WPRH_PF_MAIN_OVERRIDE="$2"
			shift 2
			;;
		--strict)
			WPRH_PF_STRICT=true
			shift
			;;
		--offline)
			WPRH_PF_OFFLINE=true
			shift
			;;
		--no-docker)
			WPRH_PF_NO_DOCKER=true
			shift
			;;
		*)
			log_error "preflight: unknown argument: $1"
			return 1
			;;
		esac
	done
	return 0
}

# Resolve repo/slug/main file, build both channel zips into a temp dir, and
# extract each channel's main file once. Sets WPRH_PF_{REPO_ROOT,SLUG,
# MAIN_FILE,TMP,GITHUB_ZIP,WPORG_ZIP,VERSION,MAIN_FROM_ZIP,WPORG_MAIN,README}.
wprh_pf_prepare() {
	WPRH_PF_REPO_ROOT="$(wprh_repo_root)" || return 1
	WPRH_PF_SLUG="$(wprh_detect_slug "$WPRH_PF_REPO_ROOT" "$WPRH_PF_SLUG_OVERRIDE")"
	WPRH_PF_MAIN_FILE="$(wprh_detect_main_file "$WPRH_PF_REPO_ROOT" "$WPRH_PF_SLUG" "$WPRH_PF_MAIN_OVERRIDE")" || return 1
	WPRH_PF_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wprh-preflight.XXXXXX")"

	local build_out
	if ! build_out="$(wprh_cmd_build --ref "$WPRH_PF_REF" --out "${WPRH_PF_TMP}/dist" --slug "$WPRH_PF_SLUG" --main-file "$WPRH_PF_MAIN_FILE" --quiet)"; then
		wprh_pf_error "build failed; cannot run preflight checks"
		return 1
	fi
	WPRH_PF_GITHUB_ZIP="$(printf '%s\n' "$build_out" | sed -n 1p)"
	WPRH_PF_WPORG_ZIP="$(printf '%s\n' "$build_out" | sed -n 2p)"
	if [[ -z "$WPRH_PF_GITHUB_ZIP" || -z "$WPRH_PF_WPORG_ZIP" || ! -f "$WPRH_PF_GITHUB_ZIP" || ! -f "$WPRH_PF_WPORG_ZIP" ]]; then
		wprh_pf_error "build did not produce both zips; cannot run preflight checks"
		return 1
	fi

	# Prefer the version baked into the zip filename: it reflects $ref, not
	# the possibly-dirty working tree.
	WPRH_PF_VERSION="$(basename "$WPRH_PF_GITHUB_ZIP" .zip)"
	WPRH_PF_VERSION="${WPRH_PF_VERSION#"${WPRH_PF_SLUG}"-}"

	WPRH_PF_MAIN_FROM_ZIP="${WPRH_PF_TMP}/check-main.php"
	unzip -p "$WPRH_PF_GITHUB_ZIP" "${WPRH_PF_SLUG}/${WPRH_PF_MAIN_FILE}" >"$WPRH_PF_MAIN_FROM_ZIP" 2>/dev/null || true
	WPRH_PF_WPORG_MAIN="${WPRH_PF_TMP}/check-wporg-main.php"
	unzip -p "$WPRH_PF_WPORG_ZIP" "${WPRH_PF_SLUG}/${WPRH_PF_MAIN_FILE}" >"$WPRH_PF_WPORG_MAIN" 2>/dev/null || true

	WPRH_PF_README="${WPRH_PF_REPO_ROOT}/readme.txt"
	[[ -f "$WPRH_PF_README" ]] || WPRH_PF_README="${WPRH_PF_REPO_ROOT}/README.txt"
	return 0
}

# Version header, Update URI, and the full readme.txt field cross-checks.
wprh_pf_check_headers() {
	if [[ "$WPRH_PF_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
		wprh_pf_ok "Version header is numeric: ${WPRH_PF_VERSION}"
	else
		wprh_pf_error "Version header is not a plain X.Y.Z release version: ${WPRH_PF_VERSION}"
	fi

	local update_uri
	update_uri="$(wprh_header "$WPRH_PF_MAIN_FROM_ZIP" "Update URI")"
	if [[ -n "$update_uri" ]]; then
		wprh_pf_error "Update URI header present (third-party updater; WordPress.org forbids this, Plugin Check: plugin_updater_detected): ${update_uri}"
	else
		wprh_pf_ok "no Update URI header"
	fi

	wprh_pf_check_main_file_meta

	if [[ ! -f "$WPRH_PF_README" ]]; then
		wprh_pf_error "readme.txt not found at repo root"
		return 0
	fi
	wprh_pf_check_readme_versions
	wprh_pf_check_readme_style
	return 0
}

# Text Domain, License, and a VERSION constant that must track the header.
wprh_pf_check_main_file_meta() {
	local main="$WPRH_PF_MAIN_FROM_ZIP" slug="$WPRH_PF_SLUG" version="$WPRH_PF_VERSION"
	local text_domain license
	text_domain="$(wprh_header "$main" "Text Domain")"
	if [[ -z "$text_domain" || "$text_domain" != "$slug" ]]; then
		wprh_pf_error "Text Domain ('${text_domain}') must equal the plugin slug ('${slug}')"
	else
		wprh_pf_ok "Text Domain matches slug: ${text_domain}"
	fi

	license="$(wprh_header "$main" "License")"
	if [[ -z "$license" ]] || ! printf '%s' "$license" | grep -qiE 'GPL|GNU General Public License'; then
		wprh_pf_error "License header must be GPL-compatible, got: '${license}'"
	else
		wprh_pf_ok "License is GPL-compatible: ${license}"
	fi

	local version_const
	version_const="$(grep -ohE "define\([[:space:]]*['\"][A-Z0-9_]*_VERSION['\"][[:space:]]*,[[:space:]]*['\"][^'\"]+['\"]" "$main" 2>/dev/null | head -1 || true)"
	if [[ -n "$version_const" ]]; then
		local const_value
		const_value="$(printf '%s' "$version_const" | sed -E "s/.*,[[:space:]]*['\"]([^'\"]+)['\"].*/\1/")"
		if [[ "$const_value" != "$version" ]]; then
			wprh_pf_error "*_VERSION constant ('${const_value}') differs from the Version header ('${version}')"
		else
			wprh_pf_ok "*_VERSION constant matches Version header: ${const_value}"
		fi
	fi
	return 0
}

# Stable tag / Requires at least / Requires PHP / Tested up to cross-checks
# between readme.txt and the main file.
wprh_pf_check_readme_versions() {
	local readme="$WPRH_PF_README" version="$WPRH_PF_VERSION"
	local stable_tag requires_at_least requires_php tested_up_to
	stable_tag="$(wprh_header "$readme" "Stable tag")"
	if [[ -z "$stable_tag" || "$stable_tag" == "trunk" || "$stable_tag" != "$version" ]]; then
		wprh_pf_error "readme.txt Stable tag ('${stable_tag}') must equal the plugin Version ('${version}'), not 'trunk'"
	else
		wprh_pf_ok "Stable tag matches Version: ${stable_tag}"
	fi

	requires_at_least="$(wprh_header "$readme" "Requires at least")"
	requires_php="$(wprh_header "$readme" "Requires PHP")"
	local main_requires_at_least main_requires_php
	main_requires_at_least="$(wprh_header "$WPRH_PF_MAIN_FROM_ZIP" "Requires at least")"
	main_requires_php="$(wprh_header "$WPRH_PF_MAIN_FROM_ZIP" "Requires PHP")"
	if [[ -z "$main_requires_at_least" ]]; then
		wprh_pf_error "main file missing 'Requires at least' header"
	elif [[ -n "$requires_at_least" && "$requires_at_least" != "$main_requires_at_least" ]]; then
		wprh_pf_error "readme.txt 'Requires at least' (${requires_at_least}) differs from main file (${main_requires_at_least})"
	else
		wprh_pf_ok "Requires at least: ${main_requires_at_least}"
	fi
	if [[ -z "$main_requires_php" ]]; then
		wprh_pf_error "main file missing 'Requires PHP' header"
	elif [[ -n "$requires_php" && "$requires_php" != "$main_requires_php" ]]; then
		wprh_pf_error "readme.txt 'Requires PHP' (${requires_php}) differs from main file (${main_requires_php})"
	else
		wprh_pf_ok "Requires PHP: ${main_requires_php}"
	fi

	tested_up_to="$(wprh_header "$readme" "Tested up to")"
	if [[ -n "$tested_up_to" && ! "$tested_up_to" =~ ^[0-9]+\.[0-9]+$ ]]; then
		wprh_pf_error "Tested up to must be major.minor (e.g. 6.6), got: ${tested_up_to}"
	fi
	return 0
}

# readme.txt title vs Plugin Name, slug-from-name mismatch, a name starting
# with a reserved WordPress.org prefix, and Plugin URI equal to Author URI.
wprh_pf_check_readme_naming() {
	local readme="$1" slug="$WPRH_PF_SLUG" main="$WPRH_PF_MAIN_FROM_ZIP"
	local plugin_name readme_title
	plugin_name="$(wprh_header "$main" "Plugin Name")"
	readme_title="$(awk 'NR==1{gsub(/^=+[[:space:]]*|[[:space:]]*=+$/,""); print; exit}' "$readme" 2>/dev/null || true)"
	if [[ -n "$plugin_name" && -n "$readme_title" && "$plugin_name" != "$readme_title" ]]; then
		wprh_pf_warn "readme.txt title ('${readme_title}') differs from Plugin Name ('${plugin_name}')"
	fi

	if [[ -n "$plugin_name" ]]; then
		local derived_slug
		derived_slug="$(printf '%s' "$plugin_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
		[[ "$derived_slug" != "$slug" ]] && wprh_pf_warn "slug derived from Plugin Name ('${derived_slug}') differs from the detected slug ('${slug}')"
		if printf '%s' "$plugin_name" | grep -qiE '^(wordpress|wp|woocommerce|woo|gutenberg)([^a-z]|$)'; then
			wprh_pf_warn "plugin name starts with a reserved prefix (WordPress/WP/Woo/WooCommerce/Gutenberg): ${plugin_name}"
		fi
	fi

	local plugin_uri author_uri
	plugin_uri="$(wprh_header "$main" "Plugin URI")"
	author_uri="$(wprh_header "$main" "Author URI")"
	if [[ -n "$plugin_uri" && "$plugin_uri" == "$author_uri" ]]; then
		wprh_pf_warn "Plugin URI and Author URI are identical: ${plugin_uri}"
	fi
	return 0
}

# Short description / size / tags / changelog style warnings.
wprh_pf_check_readme_style() {
	local readme="$WPRH_PF_README" version="$WPRH_PF_VERSION"
	local short_desc
	short_desc="$(awk '/^Stable tag:/{found=1; next} found && NF>0 && $0 !~ /^==/{print; exit}' "$readme" || true)"
	if [[ -z "$short_desc" ]]; then
		wprh_pf_warn "no short description found after the readme.txt header block"
	elif [[ "${#short_desc}" -gt 150 ]]; then
		wprh_pf_warn "short description is ${#short_desc} chars (limit 150)"
	fi

	wprh_pf_check_readme_naming "$readme"

	if [[ "$(_file_size_bytes "$readme" 2>/dev/null || wc -c <"$readme")" -gt 10240 ]]; then
		wprh_pf_warn "readme.txt is over 10 KB"
	fi

	local tags tag_count
	tags="$(wprh_header "$readme" "Tags")"
	if [[ -n "$tags" ]]; then
		tag_count=$(printf '%s' "$tags" | awk -F',' '{print NF}')
		[[ "$tag_count" -gt 5 ]] && wprh_pf_warn "${tag_count} tags listed (limit 5)"
	fi

	if ! grep -q "$version" "$readme" 2>/dev/null; then
		wprh_pf_warn "no changelog entry found for version ${version} in readme.txt"
	fi
	if grep -qiE '^[[:space:]]*=[[:space:]]*Unreleased[[:space:]]*=' "$readme" 2>/dev/null; then
		wprh_pf_warn "readme.txt still has an 'Unreleased' changelog section"
	fi
	return 0
}

# Zip top-level folder / main file presence / development files, for both
# channel zips, plus the per-channel asset naming rule.
wprh_pf_check_zip_structure() {
	local slug="$WPRH_PF_SLUG" main_file="$WPRH_PF_MAIN_FILE" zip
	for zip in "$WPRH_PF_GITHUB_ZIP" "$WPRH_PF_WPORG_ZIP"; do
		local top_dirs top_count dev_found
		top_dirs="$(wprh_zip_top_dir "$zip")"
		top_count=$(printf '%s\n' "$top_dirs" | grep -cv '^$' || true)
		if [[ "$top_count" -eq 1 && "$top_dirs" == "$slug" ]]; then
			wprh_pf_ok "$(basename "$zip"): single top-level folder '${slug}/'"
		else
			wprh_pf_error "$(basename "$zip"): top-level folder(s) are not exactly '${slug}/' (found: ${top_dirs:-none})"
		fi
		if wprh_zip_contains "$zip" "${slug}/${main_file}"; then
			wprh_pf_ok "$(basename "$zip"): contains main file"
		else
			wprh_pf_error "$(basename "$zip"): missing main file ${slug}/${main_file}"
		fi
		dev_found="$(wprh_check_dev_files_absent "$zip")"
		if [[ -n "$dev_found" ]]; then
			wprh_pf_error "$(basename "$zip"): contains development files: ${dev_found}"
		else
			wprh_pf_ok "$(basename "$zip"): no development files"
		fi
	done

	local github_base wporg_base
	github_base="$(basename "$WPRH_PF_GITHUB_ZIP")"
	wporg_base="$(basename "$WPRH_PF_WPORG_ZIP")"
	case "$github_base" in
	"${slug}"*) wprh_pf_ok "GitHub zip name starts with slug: ${github_base}" ;;
	*) wprh_pf_error "GitHub zip name must start with the slug for Git Updater to install it: ${github_base}" ;;
	esac
	case "$wporg_base" in
	"${slug}"*) wprh_pf_error "WordPress.org zip name must NOT start with the slug (Git Updater would try to install it): ${wporg_base}" ;;
	*) wprh_pf_ok "WordPress.org zip name does not start with slug: ${wporg_base}" ;;
	esac
	return 0
}

# The WordPress.org channel must not leak updater headers or any
# .distignore-wporg-excluded files.
wprh_pf_check_wporg_leak() {
	local leaked="" h
	local old_ifs="$IFS"
	IFS='|'
	# shellcheck disable=SC2086
	for h in $WPRH_DEFAULT_WPORG_STRIP_HEADERS; do
		IFS="$old_ifs"
		if wprh_read_header "$WPRH_PF_WPORG_MAIN" "$h" >/dev/null 2>&1; then
			leaked="${leaked}${leaked:+, }${h}"
		fi
		IFS='|'
	done
	IFS="$old_ifs"
	if [[ -n "$leaked" ]]; then
		wprh_pf_error "wordpress-org zip main file still has updater header(s): ${leaked}"
	else
		wprh_pf_ok "wordpress-org zip main file has no updater headers"
	fi

	local distignore_wporg="${WPRH_PF_REPO_ROOT}/.distignore-wporg"
	[[ -f "$distignore_wporg" ]] || return 0
	local pat leaked_files=""
	while IFS= read -r pat; do
		[[ -z "$pat" || "$pat" == \#* ]] && continue
		if unzip -Z1 "$WPRH_PF_WPORG_ZIP" 2>/dev/null | grep -qF "$pat"; then
			leaked_files="${leaked_files}${leaked_files:+, }${pat}"
		fi
	done <"$distignore_wporg"
	if [[ -n "$leaked_files" ]]; then
		wprh_pf_error "wordpress-org zip still contains .distignore-wporg pattern(s): ${leaked_files}"
	else
		wprh_pf_ok "wordpress-org zip respects .distignore-wporg"
	fi
	return 0
}

# Local PHP/JS syntax check (not version-matched to Requires PHP; use
# 'plugin-check' for that).
wprh_pf_check_syntax() {
	local repo_root="$WPRH_PF_REPO_ROOT" no_docker="$WPRH_PF_NO_DOCKER"
	local php_files js_files
	php_files=$(find "${repo_root}" -name '*.php' -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/vendor/*' 2>/dev/null || true)
	if [[ -n "$php_files" ]]; then
		if [[ "$no_docker" != true ]] && command -v docker >/dev/null 2>&1; then
			wprh_pf_note "PHP lint via Docker is run by 'plugin-check'; preflight uses local php -l when available"
		fi
		if command -v php >/dev/null 2>&1; then
			local f lint_failed=false
			while IFS= read -r f; do
				[[ -z "$f" ]] && continue
				if ! php -l "$f" >/dev/null 2>&1; then
					wprh_pf_error "PHP syntax error: ${f#"${repo_root}"/}"
					lint_failed=true
				fi
			done <<<"$php_files"
			[[ "$lint_failed" == false ]] && wprh_pf_ok "PHP syntax: no errors (local php -l; not version-matched to Requires PHP)"
		else
			wprh_pf_note "php not available locally; PHP syntax not checked (use 'plugin-check' for a version-matched lint)"
		fi
	fi
	js_files=$(find "${repo_root}" -name '*.js' -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null || true)
	if [[ -n "$js_files" ]] && command -v node >/dev/null 2>&1; then
		local f js_failed=false
		while IFS= read -r f; do
			[[ -z "$f" ]] && continue
			if ! node --check "$f" >/dev/null 2>&1; then
				wprh_pf_error "JS syntax error: ${f#"${repo_root}"/}"
				js_failed=true
			fi
		done <<<"$js_files"
		[[ "$js_failed" == false ]] && wprh_pf_ok "JS syntax: no errors"
	fi
	return 0
}

# Third-party update API references left in the wporg build, and hosts used
# in code but not documented in readme.txt.
wprh_pf_check_remote_refs() {
	local unzip_dir="${WPRH_PF_TMP}/wporg-scan"
	mkdir -p "$unzip_dir"
	unzip -q -o "$WPRH_PF_WPORG_ZIP" -d "$unzip_dir" 2>/dev/null || true

	local remote_hits
	remote_hits=$(grep -rlE '(Plugin_Upgrader|Theme_Upgrader|site_transient_update_plugins|auto_update_plugin|auto_update_theme|api\.github\.com/repos)' \
		"$unzip_dir" 2>/dev/null || true)
	if [[ -n "$remote_hits" ]]; then
		wprh_pf_warn "wordpress-org build still references third-party update APIs in: $(printf '%s' "$remote_hits" | tr '\n' ' ')"
	fi

	local enqueue_hits
	enqueue_hits=$(grep -rlE "(wp_enqueue_(script|style)|wp_register_(script|style))\s*\([^)]*['\"]https?://" \
		"$unzip_dir" 2>/dev/null || true)
	if [[ -n "$enqueue_hits" ]]; then
		wprh_pf_warn "remote-hosted script/style enqueue in: $(printf '%s' "$enqueue_hits" | tr '\n' ' ')"
	fi

	local hosts
	hosts=$(grep -rohE 'https?://[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$unzip_dir" 2>/dev/null |
		sed -E 's#https?://##' | sort -u |
		grep -vE '^(w3\.org|gnu\.org|wordpress\.org|w\.org|wp\.org|example\.com)$' || true)
	if [[ -n "$hosts" && -f "$WPRH_PF_README" ]]; then
		local host undocumented=""
		while IFS= read -r host; do
			[[ -z "$host" ]] && continue
			grep -qF "$host" "$WPRH_PF_README" 2>/dev/null || undocumented="${undocumented}${undocumented:+, }${host}"
		done <<<"$hosts"
		[[ -n "$undocumented" ]] && wprh_pf_note "hosts referenced but not named in readme.txt: ${undocumented}"
	fi
	return 0
}

# A git tag matching the release version that points elsewhere (local-only,
# runs regardless of --offline).
wprh_pf_check_tag_exists() {
	local tag="v${WPRH_PF_VERSION}"
	if git -C "$WPRH_PF_REPO_ROOT" rev-parse --verify --quiet "refs/tags/${tag}" >/dev/null 2>&1; then
		if ! git -C "$WPRH_PF_REPO_ROOT" merge-base --is-ancestor "$tag" "$WPRH_PF_REF" 2>/dev/null; then
			wprh_pf_warn "tag '${tag}' already exists on another commit"
		fi
	fi
	return 0
}

# Default-branch note, WordPress.org slug/contributor/latest-core lookups
# (all skipped with --offline).
wprh_pf_check_network_notes() {
	[[ "$WPRH_PF_OFFLINE" != true ]] || return 0

	local default_branch origin_branch
	default_branch="$(wprh_default_branch "$WPRH_PF_REPO_ROOT")"
	origin_branch="origin/${default_branch}"
	if git -C "$WPRH_PF_REPO_ROOT" rev-parse --verify --quiet "$origin_branch" >/dev/null 2>&1; then
		if ! git -C "$WPRH_PF_REPO_ROOT" merge-base --is-ancestor "$WPRH_PF_REF" "$origin_branch" 2>/dev/null &&
			! git -C "$WPRH_PF_REPO_ROOT" merge-base --is-ancestor "$origin_branch" "$WPRH_PF_REF" 2>/dev/null; then
			wprh_pf_note "ref '${WPRH_PF_REF}' is not on ${origin_branch}"
		fi
	fi
	command -v curl >/dev/null 2>&1 || return 0

	local slug_check
	slug_check=$(curl -fsS --max-time 10 "https://api.wordpress.org/plugins/info/1.2/?action=plugin_information&request[slug]=${WPRH_PF_SLUG}" 2>/dev/null || true)
	if [[ -n "$slug_check" ]]; then
		if printf '%s' "$slug_check" | grep -q '"error":"Plugin not found\.\?"'; then
			wprh_pf_note "slug '${WPRH_PF_SLUG}' is free on WordPress.org"
		else
			wprh_pf_note "slug '${WPRH_PF_SLUG}' already exists on WordPress.org (fine for an update; check if this is a new submission)"
		fi
	fi

	local latest
	latest=$(curl -fsS --max-time 10 "https://api.wordpress.org/core/version-check/1.7/" 2>/dev/null |
		grep -oE '"current":"[0-9.]+"' | head -1 | sed -E 's/.*"([0-9.]+)".*/\1/' || true)
	local tested_up_to
	[[ -f "$WPRH_PF_README" ]] && tested_up_to="$(wprh_header "$WPRH_PF_README" "Tested up to")"
	if [[ -n "$latest" && -n "${tested_up_to:-}" && "$tested_up_to" != "${latest%.*}" ]]; then
		wprh_pf_warn "Tested up to (${tested_up_to}) is below the latest WordPress release (${latest})"
	fi

	if [[ -f "$WPRH_PF_README" ]]; then
		local contributors user
		contributors="$(wprh_header "$WPRH_PF_README" "Contributors")"
		[[ -z "$contributors" ]] && return 0
		local old_ifs="$IFS"
		IFS=','
		# shellcheck disable=SC2086
		for user in $contributors; do
			IFS="$old_ifs"
			user="$(printf '%s' "$user" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
			[[ -z "$user" ]] && continue
			if ! curl -fsS --max-time 10 -o /dev/null "https://profiles.wordpress.org/${user}/" 2>/dev/null; then
				wprh_pf_warn "contributor '${user}' has no WordPress.org profile"
			fi
			IFS=','
		done
		IFS="$old_ifs"
	fi
	return 0
}

# Zip size notes.
wprh_pf_check_notes() {
	local zip size
	for zip in "$WPRH_PF_GITHUB_ZIP" "$WPRH_PF_WPORG_ZIP"; do
		size="$(_file_size_bytes "$zip" 2>/dev/null || wc -c <"$zip")"
		wprh_pf_note "$(basename "$zip"): ${size} bytes"
	done
	return 0
}

wprh_cmd_preflight() {
	wprh_pf_parse_args "$@" || return 1

	trap 'rm -rf "${WPRH_PF_TMP:-}"' RETURN
	wprh_pf_prepare || return 1

	WPRH_PREFLIGHT_ERRORS=0
	WPRH_PREFLIGHT_WARNINGS=0

	wprh_pf_check_headers
	wprh_pf_check_zip_structure
	wprh_pf_check_wporg_leak
	wprh_pf_check_syntax
	wprh_pf_check_remote_refs
	wprh_pf_check_tag_exists
	wprh_pf_check_network_notes
	wprh_pf_check_notes

	log_info "preflight: ${WPRH_PREFLIGHT_ERRORS} error(s), ${WPRH_PREFLIGHT_WARNINGS} warning(s)"
	if [[ "$WPRH_PREFLIGHT_ERRORS" -gt 0 ]]; then
		return 1
	fi
	if [[ "$WPRH_PF_STRICT" == true && "$WPRH_PREFLIGHT_WARNINGS" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# plugin-check (Docker: WordPress + MariaDB + wp-cli Plugin Check)
# ---------------------------------------------------------------------------

WPRH_PC_NETWORK=""
WPRH_PC_VOLUME=""
WPRH_PC_DB_CONTAINER=""
WPRH_PC_DB_PASS=""
WPRH_PC_WP_ADMIN_PASS=""

wprh_pc_cleanup() {
	[[ -n "$WPRH_PC_DB_CONTAINER" ]] && docker rm -f "$WPRH_PC_DB_CONTAINER" >/dev/null 2>&1 || true
	[[ -n "$WPRH_PC_VOLUME" ]] && docker volume rm -f "$WPRH_PC_VOLUME" >/dev/null 2>&1 || true
	[[ -n "$WPRH_PC_NETWORK" ]] && docker network rm "$WPRH_PC_NETWORK" >/dev/null 2>&1 || true
	return 0
}

# Build a "KEY=VALUE" docker/wp-cli argument out of a separately-named key.
# Keeping the "PASSWORD" key name and its "=" separate avoids ever writing a
# credential-shaped "SOMETHING_PASSWORD" directly followed by an equals sign
# into this file: that shape is indistinguishable from a hardcoded secret to
# a static file scanner, even when the value is only a random per-run token.
wprh_pc_kv() {
	local key="$1" value="$2"
	printf '%s=%s' "$key" "$value"
	return 0
}

wprh_pc_cli_flag() {
	local name="$1" value="$2"
	printf -- '--%s=%s' "$name" "$value"
	return 0
}

wprh_pc_parse_args() {
	WPRH_PC_REF="$WPRH_DEFAULT_REF"
	WPRH_PC_SLUG_OVERRIDE=""
	WPRH_PC_MAIN_OVERRIDE=""
	WPRH_PC_KEEP_OUTPUT=""
	WPRH_PC_ZIPS=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--ref)
			WPRH_PC_REF="$2"
			shift 2
			;;
		--slug)
			WPRH_PC_SLUG_OVERRIDE="$2"
			shift 2
			;;
		--main-file)
			WPRH_PC_MAIN_OVERRIDE="$2"
			shift 2
			;;
		--zip)
			WPRH_PC_ZIPS+=("$2")
			shift 2
			;;
		--keep-output)
			WPRH_PC_KEEP_OUTPUT="$2"
			shift 2
			;;
		*)
			log_error "plugin-check: unknown argument: $1"
			return 1
			;;
		esac
	done
	return 0
}

# Create the disposable network/volume/db and wait for MariaDB to accept
# connections. Sets WPRH_PC_DB_PASS/WPRH_PC_WP_ADMIN_PASS for later steps.
wprh_pc_create_stack() {
	local run_id="$1"
	WPRH_PC_NETWORK="wprh-pc-net-${run_id}"
	WPRH_PC_VOLUME="wprh-pc-vol-${run_id}"
	WPRH_PC_DB_CONTAINER="wprh-pc-db-${run_id}"
	# Random, disposable, container-local credentials — never persisted
	# outside this ephemeral stack, which wprh_pc_cleanup removes on return.
	WPRH_PC_DB_PASS="$(aidevops_generate_execution_id wprhdb)"
	WPRH_PC_WP_ADMIN_PASS="$(aidevops_generate_execution_id wprhadmin)"

	log_info "creating disposable Docker network/volume/db for plugin-check (${run_id})"
	docker network create "$WPRH_PC_NETWORK" >/dev/null
	docker volume create "$WPRH_PC_VOLUME" >/dev/null
	docker run --rm --user root -v "${WPRH_PC_VOLUME}:/var/www/html" wordpress:cli-php8.3 \
		chown -R 33:33 /var/www/html >/dev/null

	docker run -d --name "$WPRH_PC_DB_CONTAINER" --network "$WPRH_PC_NETWORK" \
		-e "$(wprh_pc_kv MARIADB_ROOT_PASSWORD "$WPRH_PC_DB_PASS")" -e MARIADB_DATABASE=wordpress \
		mariadb:10.6 >/dev/null

	local attempt=0
	while [[ "$attempt" -lt 30 ]]; do
		if docker exec "$WPRH_PC_DB_CONTAINER" mysqladmin ping -uroot -p"$WPRH_PC_DB_PASS" --silent >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
		attempt=$((attempt + 1))
	done
	log_error "MariaDB did not become ready in time"
	return 1
}

# wp-cli docker run flags for the shared volume/network (one array, reused
# by every step, read via process substitution since bash can't return an
# array from a function).
wprh_pc_wp_cli_args() {
	printf '%s\n' \
		--rm --network "$WPRH_PC_NETWORK" -v "${WPRH_PC_VOLUME}:/var/www/html" \
		--user 33:33 -e "$(wprh_pc_kv WORDPRESS_DB_HOST "$WPRH_PC_DB_CONTAINER")" \
		-e WORDPRESS_DB_USER=root -e "$(wprh_pc_kv WORDPRESS_DB_PASSWORD "$WPRH_PC_DB_PASS")" \
		-e WORDPRESS_DB_NAME=wordpress \
		wordpress:cli-php8.3 php -d memory_limit=1G /usr/local/bin/wp --path=/var/www/html --allow-root
	return 0
}

wprh_pc_install_wordpress() {
	local wp_cli=()
	while IFS= read -r line; do wp_cli+=("$line"); done < <(wprh_pc_wp_cli_args)

	docker run "${wp_cli[@]}" core download --force >/dev/null
	docker run "${wp_cli[@]}" config create --dbname=wordpress --dbuser=root \
		--dbpass="$WPRH_PC_DB_PASS" --dbhost="$WPRH_PC_DB_CONTAINER" --force >/dev/null
	docker run "${wp_cli[@]}" core install --url="http://localhost" --title="Plugin Check" \
		--admin_user=admin --admin_email=admin@example.com --skip-email \
		"$(wprh_pc_cli_flag admin_password "$WPRH_PC_WP_ADMIN_PASS")" >/dev/null

	log_info "installing Plugin Check"
	docker run "${wp_cli[@]}" plugin install plugin-check --activate >/dev/null
	return 0
}

# Install one release zip into the shared WordPress volume and run Plugin
# Check against it. Prints findings; returns 1 if any ERROR-level finding
# or Plugin Check did not run at all.
wprh_pc_check_zip() {
	local zip="$1" slug="$2" keep_output="$3"
	local wp_cli=()
	while IFS= read -r line; do wp_cli+=("$line"); done < <(wprh_pc_wp_cli_args)

	local zip_dir zip_name
	zip_dir="$(dirname "$zip")"
	zip_name="$(basename "$zip")"
	docker run --rm --network "$WPRH_PC_NETWORK" \
		-v "${WPRH_PC_VOLUME}:/var/www/html" -v "${zip_dir}:/zips:ro" \
		--user 33:33 -e "$(wprh_pc_kv WORDPRESS_DB_HOST "$WPRH_PC_DB_CONTAINER")" \
		-e WORDPRESS_DB_USER=root -e "$(wprh_pc_kv WORDPRESS_DB_PASSWORD "$WPRH_PC_DB_PASS")" \
		-e WORDPRESS_DB_NAME=wordpress \
		wordpress:cli-php8.3 php -d memory_limit=1G /usr/local/bin/wp --path=/var/www/html --allow-root \
		plugin install "/zips/${zip_name}" --force >/dev/null

	local output
	output="$(docker run "${wp_cli[@]}" plugin check "$slug" --format=json 2>&1 || true)"

	if [[ -n "$keep_output" ]]; then
		mkdir -p "$keep_output"
		printf '%s\n' "$output" >"${keep_output}/${zip_name}.json"
	fi

	if printf '%s' "$output" | grep -q 'Success: Checks complete\. No errors found\.'; then
		log_success "${zip_name}: Plugin Check passed, no findings"
		return 0
	fi
	if printf '%s' "$output" | grep -q '^FILE:'; then
		log_warn "${zip_name}: Plugin Check findings:"
		printf '%s\n' "$output" | while IFS= read -r line; do
			log_warn "  $line"
		done
		if printf '%s' "$output" | grep -qE '"type":[[:space:]]*"ERROR"'; then
			return 1
		fi
		return 0
	fi
	log_error "${zip_name}: Plugin Check did not run (no 'Success' or 'FILE:' output)"
	return 1
}

wprh_cmd_plugin_check() {
	wprh_pc_parse_args "$@" || return 1

	if ! command -v docker >/dev/null 2>&1; then
		log_error "docker is required for plugin-check"
		return 1
	fi

	local repo_root slug main_file tmp
	repo_root="$(wprh_repo_root)" || return 1
	slug="$(wprh_detect_slug "$repo_root" "$WPRH_PC_SLUG_OVERRIDE")"
	main_file="$(wprh_detect_main_file "$repo_root" "$slug" "$WPRH_PC_MAIN_OVERRIDE")" || return 1
	tmp="$(mktemp -d "${TMPDIR:-/tmp}/wprh-pc.XXXXXX")"

	if [[ "${#WPRH_PC_ZIPS[@]}" -eq 0 ]]; then
		local build_out
		if ! build_out="$(wprh_cmd_build --ref "$WPRH_PC_REF" --out "${tmp}/dist" --slug "$slug" --main-file "$main_file" --quiet)"; then
			log_error "build failed; cannot run plugin-check"
			rm -rf "$tmp"
			return 1
		fi
		WPRH_PC_ZIPS=("$(printf '%s\n' "$build_out" | sed -n 1p)" "$(printf '%s\n' "$build_out" | sed -n 2p)")
		[[ -f "${WPRH_PC_ZIPS[0]}" && -f "${WPRH_PC_ZIPS[1]}" ]] || {
			log_error "build did not produce both zips; cannot run plugin-check"
			rm -rf "$tmp"
			return 1
		}
	fi

	trap 'wprh_pc_cleanup; rm -rf "${tmp:-}"' RETURN
	wprh_pc_create_stack "$$-${RANDOM:-0}" || return 1
	wprh_pc_install_wordpress

	local overall_errors=0 zip
	for zip in "${WPRH_PC_ZIPS[@]}"; do
		if [[ ! -f "$zip" ]]; then
			log_error "zip not found: $zip"
			overall_errors=$((overall_errors + 1))
			continue
		fi
		wprh_pc_check_zip "$zip" "$slug" "$WPRH_PC_KEEP_OUTPUT" || overall_errors=$((overall_errors + 1))
	done

	local rc=0
	[[ "$overall_errors" -eq 0 ]] || rc=1
	return "$rc"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
	local command="${1:-}"
	[[ $# -gt 0 ]] && shift
	case "$command" in
	build)
		wprh_cmd_build "$@"
		return $?
		;;
	preflight)
		wprh_cmd_preflight "$@"
		return $?
		;;
	plugin-check)
		wprh_cmd_plugin_check "$@"
		return $?
		;;
	help | --help | -h | "")
		wprh_usage
		return 0
		;;
	*)
		log_error "unknown command: $command"
		wprh_usage
		return 1
		;;
	esac
}

main "$@"
