#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# wp-plugin-parity-helper.sh — find plugins that are older on one WordPress
# site than on a sibling site of the same hosting account, and refresh them
# with health-checked folder swaps. Runs ON the hosting account (scp the file,
# or stream it: ssh <alias> bash -s -- inventory --target <domain>).
# See tools/wordpress/premium-plugin-updates.md "Refreshing Stale Plugins".
#
# This helper does NOT back up databases, run upgrade routines, or activate
# plugins. Take backups first. It never reads wp-config.php.

WPPH_SELF="${BASH_SOURCE[0]:-${0:-}}"
WPPH_DIR="${WPPH_SELF%/*}"
# Optional: absent when streamed to a remote host with `bash -s`.
if [[ -n "$WPPH_SELF" && -f "${WPPH_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=./shared-constants.sh
	# shellcheck disable=SC1091
	source "${WPPH_DIR}/shared-constants.sh"
fi

WPPH_TMP=""

wpph_usage() {
	cat <<'EOF'
Usage:
  wp-plugin-parity-helper.sh inventory --target <domain> [--domains-root <dir>]
  wp-plugin-parity-helper.sh sync --target <domain> --stash <dir>
      [--domains-root <dir>] [--check-path <path>] [--dry-run]
      <slug:source-domain>...
  wp-plugin-parity-helper.sh help

inventory:
  Lists every WordPress install under the domains root (default
  $HOME/domains/*/public_html) and prints TSV rows
    slug  target_version  newest_version  source_domain  target_status  warning
  only where a sibling has a strictly newer version (sort -V). Must-use and
  drop-in entries are excluded. The warning column flags Pro add-ons whose
  base plugin version differs between target and source.

sync:
  For each slug:source-domain pair: copy the source folder to <slug>.new,
  move the old folder into --stash, rename the copy into place. For active
  plugins, request https://<target><check-path> (default /) expecting HTTP 200
  and no "fatal error" / "critical error on this website" text; on failure the
  stashed folder is restored (REVERTED). Aborts before any change if the target
  fails the health check. Prints OK|SKIP|FAIL|REVERTED slug old -> new (status).
  --dry-run prints the plan and changes nothing. The stash is never deleted.

Take database and plugin backups first (services/hosting/hostinger.md).
EOF
	return 0
}

wpph_err() {
	local msg="$1"
	printf 'ERROR: %s\n' "$msg" >&2
	return 0
}

wpph_cleanup() {
	if [[ -n "$WPPH_TMP" && -d "$WPPH_TMP" ]]; then
		rm -rf "${WPPH_TMP:?}"
	fi
	return 0
}

# Print "name,version,status" lines (no header) for one docroot.
wpph_plugin_list() {
	local docroot="$1"
	wp --path="$docroot" --skip-plugins --skip-themes plugin list \
		--fields=name,version,status --format=csv 2>/dev/null |
		awk -F, 'NR > 1 && $1 != "" && $3 != "must-use" && $3 != "dropin" { print $1 "\t" $2 "\t" $3 }'
	return 0
}

# Write domain<TAB>slug<TAB>version<TAB>status rows for all installs to $2.
wpph_collect() {
	local root="$1"
	local out="$2"
	local docroot domain
	: >"$out"
	for docroot in "$root"/*/public_html; do
		[[ -d "$docroot/wp-content/plugins" ]] || continue
		domain="${docroot%/public_html}"
		domain="${domain##*/}"
		wpph_plugin_list "$docroot" | awk -F'\t' -v d="$domain" '{ print d "\t" $1 "\t" $2 "\t" $3 }' >>"$out" || true
	done
	return 0
}

# Echo the base plugin slug for a known add-on, or nothing.
wpph_base_slug() {
	local slug="$1"
	case "$slug" in
	fluentformpro) printf 'fluentform' ;;
	fluentcampaign-pro) printf 'fluent-crm' ;;
	fluent-support-pro) printf 'fluent-support' ;;
	seo-by-rank-math-pro) printf 'seo-by-rank-math' ;;
	wp-social-ninja-pro) printf 'wp-social-reviews' ;;
	*-pro) printf '%s' "${slug%-pro}" ;;
	*) : ;;
	esac
	return 0
}

# Echo version of slug on domain from the rows file (empty if absent).
wpph_version_of() {
	local rows="$1"
	local domain="$2"
	local slug="$3"
	awk -F'\t' -v d="$domain" -v s="$slug" '$1 == d && $2 == s { print $3; exit }' "$rows"
	return 0
}

wpph_default_root() {
	printf '%s/domains' "${HOME:?}"
	return 0
}

cmd_inventory() {
	local target="" root=""
	local val=""
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		val="${2:-}"
		case "$opt" in
		--target) target="$val"; shift 2 ;;
		--domains-root) root="$val"; shift 2 ;;
		*) wpph_err "unknown option: $opt"; return 1 ;;
		esac
	done
	[[ -n "$target" ]] || { wpph_err "--target is required"; return 1; }
	[[ -n "$root" ]] || root="$(wpph_default_root)"
	command -v wp >/dev/null 2>&1 || { wpph_err "wp (WP-CLI) not found in PATH"; return 1; }

	WPPH_TMP="$(mktemp -d)"
	trap wpph_cleanup EXIT
	local rows="$WPPH_TMP/rows.tsv"
	wpph_collect "$root" "$rows"

	local slug tver tstatus best bestdom ver dom base warn tbase sbase
	local others="$WPPH_TMP/others.tsv"
	awk -F'\t' -v t="$target" '$1 == t { print $2 "\t" $3 "\t" $4 }' "$rows" >"$WPPH_TMP/target.tsv"
	while IFS="$(printf '\t')" read -r slug tver tstatus; do
		awk -F'\t' -v t="$target" -v s="$slug" '$1 != t && $2 == s { print $3 "\t" $1 }' "$rows" >"$others"
		[[ -s "$others" ]] || continue
		best="$tver"
		bestdom=""
		while IFS="$(printf '\t')" read -r ver dom; do
			[[ "$ver" == "$best" ]] && continue
			if [[ "$(printf '%s\n%s\n' "$best" "$ver" | sort -V | tail -n 1)" == "$ver" ]]; then
				best="$ver"
				bestdom="$dom"
			fi
		done <"$others"
		[[ -n "$bestdom" ]] || continue
		warn=""
		base="$(wpph_base_slug "$slug")"
		if [[ -n "$base" ]]; then
			tbase="$(wpph_version_of "$rows" "$target" "$base")"
			sbase="$(wpph_version_of "$rows" "$bestdom" "$base")"
			if [[ "$tbase" != "$sbase" ]]; then
				warn="base ${base}: target=${tbase:-none} source=${sbase:-none}"
			fi
		fi
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$slug" "$tver" "$best" "$bestdom" "$tstatus" "$warn"
	done <"$WPPH_TMP/target.tsv"
	return 0
}

# Return 0 when the URL answers 200 without fatal-error text.
wpph_health() {
	local target="$1"
	local path="$2"
	local body="$WPPH_TMP/health.body"
	local code
	command -v curl >/dev/null 2>&1 || { wpph_err "curl not found in PATH"; return 1; }
	code="$(curl -s -o "$body" -w '%{http_code}' --max-time 30 "https://${target}${path}" 2>/dev/null || true)"
	[[ "$code" == "200" ]] || return 1
	if grep -qiE 'fatal error|critical error on this website' "$body"; then
		return 1
	fi
	return 0
}

# Swap one plugin. Prints result line. Returns 0 always except hard errors.
wpph_swap_one() {
	local plugins="$1" srcplugins="$2" stash="$3" slug="$4" src="$5"
	local target="$6" check="$7" dry="$8" tstatus="$9" oldv="${10}" newv="${11}"
	local live="$plugins/$slug" new="$plugins/$slug.new" srcdir="$srcplugins/$slug"
	local stashed="$stash/$slug"

	if [[ ! -d "$srcdir" ]]; then
		printf 'FAIL %s %s -> %s (source folder missing on %s)\n' "$slug" "$oldv" "$newv" "$src"
		return 0
	fi
	if [[ -z "$oldv" ]]; then
		printf 'SKIP %s none -> %s (not installed on target)\n' "$slug" "$newv"
		return 0
	fi
	if [[ "$oldv" == "$newv" ]]; then
		printf 'SKIP %s %s -> %s (%s, already equal)\n' "$slug" "$oldv" "$newv" "$tstatus"
		return 0
	fi
	if [[ "$dry" == "1" ]]; then
		printf 'SKIP %s %s -> %s (%s, dry-run: cp %s -> %s.new; mv old -> %s)\n' \
			"$slug" "$oldv" "$newv" "$tstatus" "$srcdir" "$live" "$stashed"
		return 0
	fi
	if [[ -e "$stashed" || -e "$new" ]]; then
		printf 'FAIL %s %s -> %s (stash or .new path already exists)\n' "$slug" "$oldv" "$newv"
		return 0
	fi
	if ! cp -R "$srcdir" "$new"; then
		rm -rf "${new:?}"
		printf 'FAIL %s %s -> %s (copy failed)\n' "$slug" "$oldv" "$newv"
		return 0
	fi
	mv "$live" "$stashed"
	mv "$new" "$live"
	if [[ "$tstatus" == "active" ]] && ! wpph_health "$target" "$check"; then
		rm -rf "${live:?}"
		mv "$stashed" "$live"
		printf 'REVERTED %s %s -> %s (%s, health check failed)\n' "$slug" "$oldv" "$newv" "$tstatus"
		return 0
	fi
	printf 'OK %s %s -> %s (%s)\n' "$slug" "$oldv" "$newv" "$tstatus"
	return 0
}

cmd_sync() {
	local target="" root="" stash="" check="/" dry="0"
	local pairs=()
	local val=""
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		val="${2:-}"
		case "$opt" in
		--target) target="$val"; shift 2 ;;
		--domains-root) root="$val"; shift 2 ;;
		--stash) stash="$val"; shift 2 ;;
		--check-path) check="$val"; shift 2 ;;
		--dry-run) dry="1"; shift ;;
		--*) wpph_err "unknown option: $opt"; return 1 ;;
		*) pairs+=("$opt"); shift ;;
		esac
	done
	[[ -n "$target" ]] || { wpph_err "--target is required"; return 1; }
	[[ -n "$stash" ]] || { wpph_err "--stash is required"; return 1; }
	[[ "${#pairs[@]}" -gt 0 ]] || { wpph_err "at least one slug:source-domain pair is required"; return 1; }
	[[ -n "$root" ]] || root="$(wpph_default_root)"
	command -v wp >/dev/null 2>&1 || { wpph_err "wp (WP-CLI) not found in PATH"; return 1; }

	WPPH_TMP="$(mktemp -d)"
	trap wpph_cleanup EXIT
	local tdoc="$root/$target/public_html"
	local plugins="$tdoc/wp-content/plugins"
	[[ -d "$plugins" ]] || { wpph_err "target plugins dir not found: $plugins"; return 1; }

	if [[ "$dry" != "1" ]]; then
		wpph_health "$target" "$check" || { wpph_err "target failed health check before changes; aborting"; return 1; }
		mkdir -p "$stash"
	fi

	local tlist="$WPPH_TMP/target.tsv"
	wpph_plugin_list "$tdoc" >"$tlist"
	local pair slug src sdoc oldv tstatus newv
	for pair in "${pairs[@]}"; do
		slug="${pair%%:*}"
		src="${pair#*:}"
		if [[ -z "$slug" || "$slug" == "$pair" || -z "$src" || "$slug" == */* || "$slug" == .* ]]; then
			printf 'FAIL %s none -> none (invalid pair, expected slug:source-domain)\n' "$pair"
			continue
		fi
		sdoc="$root/$src/public_html"
		oldv="$(awk -F'\t' -v s="$slug" '$1 == s { print $2; exit }' "$tlist")"
		tstatus="$(awk -F'\t' -v s="$slug" '$1 == s { print $3; exit }' "$tlist")"
		newv="$(wpph_plugin_list "$sdoc" | awk -F'\t' -v s="$slug" '$1 == s { print $2; exit }')"
		if [[ -z "$newv" ]]; then
			printf 'FAIL %s %s -> none (not found on %s)\n' "$slug" "${oldv:-none}" "$src"
			continue
		fi
		wpph_swap_one "$plugins" "$sdoc/wp-content/plugins" "$stash" "$slug" "$src" \
			"$target" "$check" "$dry" "$tstatus" "$oldv" "$newv"
	done
	return 0
}

main() {
	local cmd="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$cmd" in
	inventory) cmd_inventory "$@" ;;
	sync) cmd_sync "$@" ;;
	help | -h | --help) wpph_usage ;;
	*) wpph_err "unknown command: $cmd"; wpph_usage >&2; return 1 ;;
	esac
	return $?
}

main "$@"
