#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# loc-badge-helper.sh — generate self-hosted lines-of-code SVG badges (t2834)
#
# Runs `tokei` to count lines of code in the current repository, parses the
# JSON output, and renders two SVG files that other badges can reference:
#
#   <output-dir>/loc-total.svg     — shields.io-style "lines of code" badge
#   <output-dir>/loc-languages.svg — GitHub-style horizontal stacked bar of
#                                     the top-N languages with a legend
#
# Designed for the `loc-badge-reusable.yml` GitHub Actions workflow, but is
# also runnable locally for testing.
#
# Why self-hosted SVGs? shields.io's tokei endpoint has been historically
# unreliable (intermittent "invalid" responses, deprecation cycles).
# Generating the SVGs in-repo and committing them removes the runtime
# dependency on any third-party badge service and gives consistent visuals
# across all aidevops-managed repos.
#
# Usage:
#   loc-badge-helper.sh [options] [path...]
#
# Options:
#   --output-dir DIR   Where to write the SVGs (default: .github/badges)
#   --top N            Top-N languages in the language breakdown (default: 6)
#   --exclude PATTERN  Additional path pattern to exclude from tokei (repeatable)
#   --json-only        Print the parsed JSON summary; do not write SVGs
#   --no-color-deps    Skip the language-color lookup table and use a single
#                      colour for every segment (useful for CI dry-runs)
#   -h, --help         Show usage and exit 0
#
# Exit codes:
#   0 — success (SVGs written, or --json-only printed JSON)
#   1 — runtime error (tokei missing, jq missing, write failure)
#   2 — usage error
#
# Dependencies:
#   tokei   — the line counter (apt: tokei, brew: tokei, cargo: tokei)
#   jq      — JSON parsing
#   awk     — number formatting (POSIX, present everywhere)

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_VERSION="1.0.0"

# ───────────────────────────── defaults ───────────────────────────────────

OUTPUT_DIR=".github/badges"
TOP_N=6
JSON_ONLY=0
NO_COLOR_DEPS=0
EXTRA_EXCLUDES=()
SCAN_PATHS=()

# Default exclusions — common dirs that aren't "your code".
DEFAULT_EXCLUDES=(
	"__aidevops/"
	"node_modules/"
	"vendor/"
	".git/"
	"dist/"
	"build/"
	".next/"
	".cache/"
	".venv/"
	"venv/"
	"target/"
)

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

# ───────────────────────────── usage ──────────────────────────────────────

usage() {
	sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# ───────────────────────────── arg parsing ────────────────────────────────

parse_args() {
	# All access to $1/$2 is via local vars to satisfy the positional-
	# parameter ratchet. _arg is the current option, _val is its value
	# (when the option takes one).
	while (($# > 0)); do
		local _arg="$1"
		case "$_arg" in
			--output-dir)
				[[ $# -ge 2 ]] || die "--output-dir requires an argument" 2
				local _val="$2"
				OUTPUT_DIR="$_val"
				shift 2
				;;
			--top)
				[[ $# -ge 2 ]] || die "--top requires an argument" 2
				local _val="$2"
				[[ "$_val" =~ ^[0-9]+$ ]] || die "--top must be a positive integer (got: $_val)" 2
				TOP_N="$_val"
				shift 2
				;;
			--exclude)
				[[ $# -ge 2 ]] || die "--exclude requires an argument" 2
				local _val="$2"
				EXTRA_EXCLUDES+=("$_val")
				shift 2
				;;
			--json-only)
				JSON_ONLY=1
				shift
				;;
			--no-color-deps)
				NO_COLOR_DEPS=1
				shift
				;;
			--version)
				printf '%s\n' "$SCRIPT_VERSION"
				exit 0
				;;
			-h | --help)
				usage
				exit 0
				;;
			--)
				shift
				while (($# > 0)); do
					local _path="$1"
					SCAN_PATHS+=("$_path")
					shift
				done
				;;
			-*)
				die "unknown option: $_arg" 2
				;;
			*)
				SCAN_PATHS+=("$_arg")
				shift
				;;
		esac
	done
	return 0
}

# ───────────────────────────── dependency check ───────────────────────────

require_dep() {
	local _cmd="$1"
	local _hint="$2"
	if ! command -v "$_cmd" >/dev/null 2>&1; then
		die "required dependency missing: $_cmd ($_hint)"
	fi
	return 0
}

check_dependencies() {
	require_dep tokei "install: apt-get install tokei | brew install tokei | cargo install tokei"
	require_dep jq "install: apt-get install jq | brew install jq"
	return 0
}

# ───────────────────────────── tokei runner ───────────────────────────────

# Build the --exclude flag list from defaults + user-provided patterns.
build_exclude_args() {
	local _all_excludes=("${DEFAULT_EXCLUDES[@]}" "${EXTRA_EXCLUDES[@]}")
	local _pat
	for _pat in "${_all_excludes[@]}"; do
		printf -- '--exclude\n%s\n' "$_pat"
	done
	return 0
}

# Run tokei against the scan paths (or current directory) and emit raw JSON.
run_tokei() {
	local _exclude_args=()
	# Use mapfile to read exclude args one per line — safe for paths with spaces.
	while IFS= read -r _line; do
		_exclude_args+=("$_line")
	done < <(build_exclude_args)

	local _scan=()
	if [[ ${#SCAN_PATHS[@]} -eq 0 ]]; then
		_scan=(".")
	else
		_scan=("${SCAN_PATHS[@]}")
	fi

	tokei --output json "${_exclude_args[@]}" "${_scan[@]}"
	return 0
}

# Reduce raw tokei output to a compact summary:
#   { total: { code, comments, blanks, files }, languages: [ {name, code, files} ] }
summarise_tokei() {
	local _raw="$1"
	printf '%s' "$_raw" | jq --argjson topn "$TOP_N" '
		. as $root
		| ($root.Total // {code:0,comments:0,blanks:0,reports:[]}) as $t
		| {
			total: {
				code: ($t.code // 0),
				comments: ($t.comments // 0),
				blanks: ($t.blanks // 0),
				files: (($t.reports // []) | length)
			},
			languages: (
				[$root | to_entries[]
					| select(.key != "Total")
					| select((.value.code // 0) > 0)
					| {name: .key, code: (.value.code // 0), files: ((.value.reports // []) | length)}]
				| sort_by(-.code)
			),
			top: (
				[$root | to_entries[]
					| select(.key != "Total")
					| select((.value.code // 0) > 0)
					| {name: .key, code: (.value.code // 0), files: ((.value.reports // []) | length)}]
				| sort_by(-.code)
				| .[0:$topn]
			)
		}
	'
	return 0
}

# ───────────────────────────── number formatting ──────────────────────────

# Format an integer with thousands separators using awk (printf %'d is
# locale-dependent and unreliable in CI containers).
format_thousands() {
	local _n="$1"
	awk -v n="$_n" 'BEGIN {
		# Reverse, insert commas every 3 digits, reverse again.
		s = sprintf("%d", n)
		out = ""
		i = length(s)
		c = 0
		while (i > 0) {
			out = substr(s, i, 1) out
			c++
			i--
			if (c == 3 && i > 0) { out = "," out; c = 0 }
		}
		print out
	}'
	return 0
}

# Pretty-print large counts (12345 → "12.3k", 1234567 → "1.23M") for compact
# badge labels. Falls back to thousands-formatted integer below 10000.
human_count() {
	local _n="$1"
	awk -v n="$_n" 'BEGIN {
		if (n < 10000)      { printf "%d", n }
		else if (n < 1e6)   { printf "%.1fk", n / 1000 }
		else if (n < 1e9)   { printf "%.2fM", n / 1e6 }
		else                { printf "%.2fG", n / 1e9 }
	}'
	return 0
}

# ───────────────────────────── language colours ───────────────────────────

# Mirror of GitHub Linguist colours for the common languages tokei reports.
# Returns "#RRGGBB" on stdout; falls back to a neutral grey for unknown.
language_color() {
	local _lang="$1"
	if [[ "$NO_COLOR_DEPS" -eq 1 ]]; then
		printf '#6e7781'
		return 0
	fi
	case "$_lang" in
		Shell | BASH | Bash)               printf '#89e051' ;;
		Python)                            printf '#3572A5' ;;
		JavaScript)                        printf '#f1e05a' ;;
		TypeScript)                        printf '#3178c6' ;;
		TSX)                               printf '#3178c6' ;;
		JSX)                               printf '#f1e05a' ;;
		Markdown)                          printf '#083fa1' ;;
		"Plain Text" | Text)               printf '#bbbbbb' ;;
		JSON)                              printf '#292929' ;;
		YAML)                              printf '#cb171e' ;;
		TOML)                              printf '#9c4221' ;;
		XML)                               printf '#0060ac' ;;
		HTML)                              printf '#e34c26' ;;
		CSS)                               printf '#563d7c' ;;
		SCSS | Sass)                       printf '#c6538c' ;;
		Dockerfile)                        printf '#384d54' ;;
		Makefile)                          printf '#427819' ;;
		Ruby)                              printf '#701516' ;;
		Go)                                printf '#00ADD8' ;;
		Rust)                              printf '#dea584' ;;
		Java)                              printf '#b07219' ;;
		Kotlin)                            printf '#A97BFF' ;;
		Swift)                             printf '#ffac45' ;;
		"Objective-C")                     printf '#438eff' ;;
		C)                                 printf '#555555' ;;
		"C++" | Cpp)                       printf '#f34b7d' ;;
		"C#" | CSharp)                     printf '#178600' ;;
		PHP)                               printf '#4F5D95' ;;
		Perl)                              printf '#0298c3' ;;
		Lua)                               printf '#000080' ;;
		R)                                 printf '#198CE7' ;;
		Scala)                             printf '#c22d40' ;;
		Elixir)                            printf '#6e4a7e' ;;
		Erlang)                            printf '#B83998' ;;
		Haskell)                           printf '#5e5086' ;;
		Clojure)                           printf '#db5855' ;;
		Dart)                              printf '#00B4AB' ;;
		Vue)                               printf '#41b883' ;;
		Svelte)                            printf '#ff3e00' ;;
		Zig)                               printf '#ec915c' ;;
		Nix)                               printf '#7e7eff' ;;
		SQL)                               printf '#e38c00' ;;
		AWK)                               printf '#c30e9b' ;;
		*)                                 printf '#6e7781' ;;
	esac
	return 0
}

# ───────────────────────────── XML escaping ───────────────────────────────

# Escape characters that would break SVG/XML content.
xml_escape() {
	local _s="$1"
	_s="${_s//&/&amp;}"
	_s="${_s//</&lt;}"
	_s="${_s//>/&gt;}"
	_s="${_s//\"/&quot;}"
	_s="${_s//\'/&apos;}"
	printf '%s' "$_s"
	return 0
}

# ───────────────────────────── SVG primitives ─────────────────────────────
#
# Helpers that build SVG attribute strings via a single `'%s="%s" '` format
# template. All inline attribute fragments (`width="`, `fill="`, etc.) are
# eliminated, so the string-literal ratchet has nothing to flag.

# Module-level constants used by the SVG primitives.
_SVG_XMLNS='http://www.w3.org/2000/svg'
_SVG_FONT='Verdana,Geneva,DejaVu Sans,sans-serif'
_ATTR_FMT='%s="%s" '

# Build an attribute string from key/value pairs.
# Usage: _svg_attrs key1 val1 key2 val2 ...
_svg_attrs() {
	local _out=""
	while [[ $# -ge 2 ]]; do
		local _k="$1"
		local _v="$2"
		# shellcheck disable=SC2059  # _ATTR_FMT is a trusted constant
		_out+=$(printf "$_ATTR_FMT" "$_k" "$_v")
		shift 2
	done
	# Trim trailing space.
	printf '%s' "${_out%% }"
	return 0
}

# Emit a self-closing element: <tag attr=val ... />
_svg_elem() {
	local _tag="$1"
	shift
	local _attrs
	_attrs=$(_svg_attrs "$@")
	if [[ -n "$_attrs" ]]; then
		printf '  <%s %s/>\n' "$_tag" "$_attrs"
	else
		printf '  <%s/>\n' "$_tag"
	fi
	return 0
}

# Emit an open tag: <tag attr=val>
_svg_open() {
	local _tag="$1"
	shift
	local _attrs
	_attrs=$(_svg_attrs "$@")
	if [[ -n "$_attrs" ]]; then
		printf '  <%s %s>\n' "$_tag" "$_attrs"
	else
		printf '  <%s>\n' "$_tag"
	fi
	return 0
}

# Emit a close tag.
_svg_close() {
	local _tag="$1"
	printf '  </%s>\n' "$_tag"
	return 0
}

# Emit an element with text content: <tag attr=val>text</tag>
_svg_text_elem() {
	local _tag="$1"
	local _text="$2"
	shift 2
	local _attrs
	_attrs=$(_svg_attrs "$@")
	if [[ -n "$_attrs" ]]; then
		printf '  <%s %s>%s</%s>\n' "$_tag" "$_attrs" "$_text" "$_tag"
	else
		printf '  <%s>%s</%s>\n' "$_tag" "$_text" "$_tag"
	fi
	return 0
}

# Emit the root <svg> open tag with xmlns + sizing + aria-label.
_svg_root_open() {
	local _w="$1" _h="$2" _label="$3"
	_svg_open svg \
		xmlns "$_SVG_XMLNS" \
		width "$_w" \
		height "$_h" \
		role img \
		aria-label "$_label"
	return 0
}

# ───────────────────────────── total SVG ──────────────────────────────────

# Generate a shields.io-style flat badge for total LOC.
# Layout: grey label "lines of code" | coloured value ("482k").
render_total_svg() {
	local _total="$1"
	local _label="lines of code"
	local _value
	_value=$(human_count "$_total")
	local _value_full
	_value_full=$(format_thousands "$_total")

	# Width estimation: roughly 6.5px per char at 11px font + 10px padding each side.
	local _label_w=88   # fixed for "lines of code"
	local _value_chars=${#_value}
	local _value_w=$((_value_chars * 7 + 16))
	local _total_w=$((_label_w + _value_w))

	_svg_root_open "$_total_w" 20 "${_label}: ${_value_full}"
	_svg_text_elem title "${_label}: ${_value_full}"

	_svg_open linearGradient id s x2 0 y2 100%
	_svg_elem stop offset 0 stop-color "#bbb" stop-opacity .1
	_svg_elem stop offset 1 stop-opacity .1
	_svg_close linearGradient

	_svg_open clipPath id r
	_svg_elem rect width "$_total_w" height 20 rx 3 fill "#fff"
	_svg_close clipPath

	_svg_open g clip-path "url(#r)"
	_svg_elem rect width "$_label_w" height 20 fill "#555"
	_svg_elem rect x "$_label_w" width "$_value_w" height 20 fill "#007ec6"
	_svg_elem rect width "$_total_w" height 20 fill "url(#s)"
	_svg_close g

	_svg_open g fill "#fff" text-anchor middle font-family "$_SVG_FONT" font-size 11
	_svg_text_elem text "$_label" \
		x "$((_label_w / 2))" y 15 fill "#010101" fill-opacity .3
	_svg_text_elem text "$_label" x "$((_label_w / 2))" y 14
	_svg_text_elem text "$_value" \
		x "$((_label_w + _value_w / 2))" y 15 fill "#010101" fill-opacity .3
	_svg_text_elem text "$_value" x "$((_label_w + _value_w / 2))" y 14
	_svg_close g

	printf '</svg>\n'
	return 0
}

# ───────────────────────────── languages SVG ──────────────────────────────

# Render the placeholder when no languages are detected (empty repo).
_render_languages_empty() {
	_svg_root_open 480 60 "languages: none detected"
	_svg_text_elem title "languages: none detected"
	_svg_elem rect width 480 height 60 fill "#f6f8fa" stroke "#d0d7de" rx 4
	_svg_text_elem text "no source code detected" \
		x 240 y 35 text-anchor middle font-family "$_SVG_FONT" font-size 12 fill "#57606a"
	printf '</svg>\n'
	return 0
}

# Generate a horizontal stacked-bar SVG for the top-N languages, with a
# two-column legend below. GitHub-style colours; segments scaled to total
# lines across the displayed languages.
render_languages_svg() {
	local _summary="$1"

	# Extract the top-N entries as TSV: name<TAB>code
	local _tsv
	_tsv=$(printf '%s' "$_summary" | jq -r '.top[] | [.name, .code] | @tsv')

	if [[ -z "$_tsv" ]]; then
		_render_languages_empty
		return 0
	fi

	# Compute total of displayed top-N for percent calculation.
	local _displayed_total=0
	local _name _code
	while IFS=$'\t' read -r _name _code; do
		[[ -z "$_name" ]] && continue
		_displayed_total=$((_displayed_total + _code))
	done <<<"$_tsv"

	# Bar geometry
	local _bar_w=460
	local _bar_x=10
	local _bar_y=8
	local _bar_h=14
	local _svg_w=480
	# Legend: 2 columns, 16px line height; entries = top-N
	local _entries
	_entries=$(printf '%s\n' "$_tsv" | grep -c '.' || true)
	[[ "$_entries" =~ ^[0-9]+$ ]] || _entries=0
	local _legend_lines=$(((_entries + 1) / 2))
	local _legend_h=$((_legend_lines * 16 + 6))
	local _svg_h=$((_bar_y + _bar_h + 8 + _legend_h))

	# Header: root + title + bg + bar background track.
	_svg_root_open "$_svg_w" "$_svg_h" "languages by lines of code"
	_svg_text_elem title "languages by lines of code"
	_svg_elem rect width "$_svg_w" height "$_svg_h" fill "#ffffff"
	_svg_elem rect x "$_bar_x" y "$_bar_y" width "$_bar_w" height "$_bar_h" rx 3 fill "#eaecef"

	# Render bar segments — accumulate offset, last segment fills any rounding gap.
	local _x_offset="$_bar_x"
	while IFS=$'\t' read -r _name _code; do
		[[ -z "$_name" ]] && continue
		local _seg_w
		_seg_w=$((_code * _bar_w / _displayed_total))
		[[ "$_seg_w" -lt 1 ]] && _seg_w=1
		local _color
		_color=$(language_color "$_name")
		_svg_elem rect x "$_x_offset" y "$_bar_y" width "$_seg_w" height "$_bar_h" fill "$_color"
		_x_offset=$((_x_offset + _seg_w))
	done <<<"$_tsv"

	# Legend rows — 2 columns, 230px each.
	local _legend_y=$((_bar_y + _bar_h + 18))
	local _col_w=230
	local _col=0
	local _row_y="$_legend_y"
	while IFS=$'\t' read -r _name _code; do
		[[ -z "$_name" ]] && continue
		local _color
		_color=$(language_color "$_name")
		local _pct
		_pct=$(awk -v c="$_code" -v t="$_displayed_total" 'BEGIN { printf "%.1f", c * 100 / t }')
		local _name_esc
		_name_esc=$(xml_escape "$_name")
		local _x=$((_bar_x + _col * _col_w))
		_svg_elem rect x "$_x" y "$((_row_y - 10))" width 10 height 10 rx 2 fill "$_color"
		_svg_text_elem text "${_name_esc} <tspan fill=\"#57606a\">${_pct}%</tspan>" \
			x "$((_x + 14))" y "$_row_y" font-family "$_SVG_FONT" font-size 11 fill "#24292f"
		_col=$((_col + 1))
		if [[ "$_col" -ge 2 ]]; then
			_col=0
			_row_y=$((_row_y + 16))
		fi
	done <<<"$_tsv"

	printf '</svg>\n'
	return 0
}

# ───────────────────────────── output ─────────────────────────────────────

ensure_output_dir() {
	if [[ ! -d "$OUTPUT_DIR" ]]; then
		mkdir -p "$OUTPUT_DIR" || die "failed to create output dir: $OUTPUT_DIR"
	fi
	return 0
}

write_svgs() {
	local _summary="$1"
	local _total
	_total=$(printf '%s' "$_summary" | jq -r '.total.code')

	ensure_output_dir

	local _total_svg="$OUTPUT_DIR/loc-total.svg"
	local _lang_svg="$OUTPUT_DIR/loc-languages.svg"

	render_total_svg "$_total" >"$_total_svg" || die "failed to write $_total_svg"
	render_languages_svg "$_summary" >"$_lang_svg" || die "failed to write $_lang_svg"

	log "wrote $_total_svg ($(format_thousands "$_total") LOC)"
	log "wrote $_lang_svg"
	return 0
}

# ───────────────────────────── main ───────────────────────────────────────

main() {
	parse_args "$@"
	check_dependencies

	local _raw
	_raw=$(run_tokei) || die "tokei invocation failed"

	local _summary
	_summary=$(summarise_tokei "$_raw") || die "tokei output parse failed"

	if [[ "$JSON_ONLY" -eq 1 ]]; then
		printf '%s\n' "$_summary"
		return 0
	fi

	write_svgs "$_summary"
	return 0
}

main "$@"
