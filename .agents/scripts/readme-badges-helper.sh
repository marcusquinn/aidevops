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
#   {{HAS_LOC_BADGE}}   — "1" if the loc-badge workflow is wired up
#                         (presence of .github/badges/loc-total.svg or
#                          loc-badge.yml in the repo); "" otherwise
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
#   --no-loc-badge         Force HAS_LOC_BADGE empty (skip LOC line)
#   --has-releases 0|1     Force the "has releases" flag (skip gh probe)
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
NO_LOC_BADGE=0
HAS_RELEASES_OVERRIDE=""

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
			--no-loc-badge)
				NO_LOC_BADGE=1
				shift
				;;
			--has-releases)
				[[ $# -ge 2 ]] || die "--has-releases requires 0|1" 2
				local _val="$2"
				HAS_RELEASES_OVERRIDE="$_val"
				shift 2
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
	if ! command -v gh >/dev/null 2>&1; then
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
	if ! command -v gh >/dev/null 2>&1; then
		printf 'main'
		return 0
	fi
	local _branch
	_branch=$(gh api "repos/$_slug" --jq '.default_branch // "main"' 2>/dev/null || true)
	[[ -z "$_branch" || "$_branch" == "null" ]] && _branch="main"
	printf '%s' "$_branch"
	return 0
}

# ───────────────────────────── template render ────────────────────────────

# Substitute {{KEY}} with the value of the corresponding env var (KEY must
# match a name like SLUG / OWNER / REPO / DEFAULT_BRANCH / HAS_LOC_BADGE /
# HAS_RELEASES / IS_FOSS). Conditional lines:
#   "{{?KEY}}rest"   — included only if KEY is non-empty (prefix stripped)
#   "{{!KEY}}rest"   — included only if KEY is empty (prefix stripped)
render_template() {
	local _template_path="$1"
	[[ -f "$_template_path" ]] || die "template not found: $_template_path"

	# Build env exports for awk to read.
	awk \
		-v slug="${SLUG_VAL}" \
		-v owner="${OWNER_VAL}" \
		-v repo="${REPO_VAL}" \
		-v branch="${DEFAULT_BRANCH_VAL}" \
		-v has_loc_badge="${HAS_LOC_BADGE_VAL}" \
		-v has_releases="${HAS_RELEASES_VAL}" \
		-v is_foss="${IS_FOSS_VAL}" \
		-v has_license="${HAS_LICENSE_VAL}" \
		'
		function get_var(k) {
			if (k == "SLUG") return slug
			if (k == "OWNER") return owner
			if (k == "REPO") return repo
			if (k == "DEFAULT_BRANCH") return branch
			if (k == "HAS_LOC_BADGE") return has_loc_badge
			if (k == "HAS_RELEASES") return has_releases
			if (k == "IS_FOSS") return is_foss
			if (k == "HAS_LICENSE") return has_license
			return ""
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

	# Repo metadata from repos.json (fail-soft to "")
	local _local_only
	_local_only=$(repos_json_lookup "$SLUG" "local_only" "")
	if [[ "$_local_only" == "true" ]]; then
		# local_only repos can't be queried via gh — most badges are useless.
		# Emit only LOC + license. Force HAS_RELEASES empty.
		HAS_RELEASES_VAL=""
	else
		HAS_RELEASES_VAL=$(detect_has_releases "$SLUG")
	fi

	IS_FOSS_VAL=$(repos_json_lookup "$SLUG" "foss" "")
	[[ "$IS_FOSS_VAL" == "true" ]] && IS_FOSS_VAL="1" || IS_FOSS_VAL=""

	# LOC badge wiring: assume yes unless --no-loc-badge or local_only.
	if [[ "$NO_LOC_BADGE" -eq 1 ]]; then
		HAS_LOC_BADGE_VAL=""
	else
		HAS_LOC_BADGE_VAL="1"
	fi

	# License: assume present unless we're checking a real path that proves otherwise.
	# Phase 2's check command will probe filesystem; for render we default to 1.
	HAS_LICENSE_VAL="1"

	return 0
}

# Render the template framed by the marker block.
render_full_block() {
	local _template_path="${TEMPLATE_OVERRIDE:-$(default_template_path)}"
	prepare_render_vars
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
