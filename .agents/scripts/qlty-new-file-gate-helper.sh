#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# qlty-new-file-gate-helper.sh — CI gate for new-file qlty smells (t2068)
#
# Scans files that are brand-new in a PR (`git diff --diff-filter=A
# base...head`) and fails if any of them ship with qlty smells.
# Complements the t2065 regression gate: t2065 catches *increases* in
# smells across modified files; t2068 catches *new subsystems* that
# land already-smelly. Together they prevent both drift and arrival
# of debt.
#
# Usage:
#   qlty-new-file-gate-helper.sh new-files --base <ref> [options]
#   qlty-new-file-gate-helper.sh scan      --base <ref> [options]
#   qlty-new-file-gate-helper.sh --help
#
# The two commands are aliases — `new-files` matches the t2068 issue
# wording; `scan` is a shorter synonym.
#
# Options:
#   --base <ref>          Base ref for diff (required)
#   --head <ref>          Head ref (default: HEAD)
#   --output-md <file>    Write markdown report to <file>
#   --sarif <file>        Write raw SARIF output to <file>
#   --dry-run             List eligible files and exit 0 without scanning
#   -h, --help            Show usage and exit 0
#
# Exit codes:
#   0 — no eligible new files, or all new files scanned clean
#   1 — one or more new files have qlty smells (gate fails)
#   2 — usage or environment error
#
# Design notes:
# - Eligibility filter: source files by extension, minus the test /
#   vendored / generated / template paths that qlty.toml already excludes.
#   qlty itself is the final arbiter (respects qlty.toml even if this
#   helper forwards an excluded path).
# - Exit 1 is deterministic; override (label + justification section) is
#   enforced by the calling workflow, not by this helper. That keeps the
#   helper reusable from other contexts (pre-push hook, local dev).
# - Bash 3.2 compatible (no readarray, no associative arrays, no &&/|| in
#   function bodies without explicit return).

set -uo pipefail

SCRIPT_NAME=$(basename "$0")
TMP_DIR=""

cleanup() {
	if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
		rm -rf "$TMP_DIR"
	fi
	return 0
}
trap cleanup EXIT

log() {
	local _msg="$1"
	printf '[%s] %s\n' "$SCRIPT_NAME" "$_msg" >&2
	return 0
}

die() {
	local _msg="$1"
	printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$_msg" >&2
	exit 2
}

usage() {
	sed -n '4,42p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

find_qlty() {
	if command -v qlty >/dev/null 2>&1; then
		command -v qlty
		return 0
	fi
	if [ -x "$HOME/.qlty/bin/qlty" ]; then
		printf '%s/.qlty/bin/qlty\n' "$HOME"
		return 0
	fi
	return 1
}

# is_source_file <path> — returns 0 if path has a source-code extension
# that qlty can analyse, 1 otherwise. Kept narrow on purpose: new data /
# config / doc files should never trip the gate.
is_source_file() {
	local _path="$1"
	case "$_path" in
	*.py | *.pyi) return 0 ;;
	*.js | *.mjs | *.cjs | *.jsx) return 0 ;;
	*.ts | *.tsx) return 0 ;;
	*.sh | *.bash | *.zsh) return 0 ;;
	*.rb | *.erb) return 0 ;;
	*.go) return 0 ;;
	*.rs) return 0 ;;
	*.java | *.kt | *.swift) return 0 ;;
	*.c | *.cpp | *.cc | *.cxx | *.h | *.hpp) return 0 ;;
	*.php) return 0 ;;
	*.ex | *.exs) return 0 ;;
	esac
	return 1
}

# is_excluded_path <path> — returns 0 if path should be skipped for
# reasons other than extension (tests, fixtures, vendor, generated,
# template code, minified, or the qlty.toml exclude set).
is_excluded_path() {
	local _path="$1"
	case "$_path" in
	# tests and specs
	test/* | tests/* | spec/* | specs/*) return 0 ;;
	*/test/* | */tests/* | */spec/* | */specs/*) return 0 ;;
	test_*.* | spec_*.* | *_test.* | *_spec.*) return 0 ;;
	*.test.* | *.spec.*) return 0 ;;
	# fixtures / testdata / golden
	*/testdata/* | */fixtures/* | */golden/* | */snapshots/*) return 0 ;;
	# vendored / third party
	*/vendor/* | */node_modules/* | */third_party/*) return 0 ;;
	*/extern/* | */external/* | */deps/*) return 0 ;;
	# generated / built
	*/generated/* | */dist/* | */build/* | */target/* | */out/*) return 0 ;;
	# minified
	*.min.* | *_min.* | *-min.* | *.d.ts) return 0 ;;
	# template code (qlty.toml excludes **/templates/**)
	*/templates/* | templates/*) return 0 ;;
	# cache and .yarn
	*/cache/* | */.yarn/*) return 0 ;;
	esac
	return 1
}

# list_added_files <base> <head> — prints newly-added file paths, one
# per line. --diff-filter=A restricts to additions.
list_added_files() {
	local _base="$1"
	local _head="$2"
	git diff --name-only --diff-filter=A "${_base}" "${_head}" 2>/dev/null
	return 0
}

# filter_scan_list <added-file> <output-list> — reads added files and
# writes the eligible scan list (source + not excluded + exists on disk).
# Prints a summary line to stderr.
filter_scan_list() {
	local _added="$1"
	local _out="$2"
	local _total=0
	local _eligible=0
	local _f
	: >"$_out"
	while IFS= read -r _f; do
		[ -z "$_f" ] && continue
		_total=$((_total + 1))
		if is_excluded_path "$_f"; then
			continue
		fi
		if ! is_source_file "$_f"; then
			continue
		fi
		if [ ! -f "$_f" ]; then
			continue
		fi
		printf '%s\n' "$_f" >>"$_out"
		_eligible=$((_eligible + 1))
	done <"$_added"
	log "New files: $_total, eligible for scan: $_eligible"
	return 0
}

# run_qlty_on_files <scan-list> <sarif-out>
run_qlty_on_files() {
	local _list="$1"
	local _out="$2"
	local _qlty_bin
	_qlty_bin=$(find_qlty) || die "qlty CLI not found (install: https://qlty.sh/install)"
	# Build argv from list (bash 3.2 compat — no readarray).
	local _args=()
	local _line
	while IFS= read -r _line; do
		[ -n "$_line" ] && _args+=("$_line")
	done <"$_list"
	if [ "${#_args[@]}" -eq 0 ]; then
		# Nothing to scan — emit an empty SARIF envelope so downstream jq
		# calls still succeed. We use a minimal but valid structure.
		printf '{"version":"2.1.0","runs":[{"results":[]}]}\n' >"$_out"
		return 0
	fi
	# qlty exits non-zero when it finds smells; SARIF still lands on stdout.
	# Note: --all is incompatible with explicit PATHS, so we omit it here.
	# Passing paths directly tells qlty to scan exactly those files.
	"$_qlty_bin" smells --sarif --no-snippets --quiet "${_args[@]}" \
		>"$_out" 2>/dev/null || true
	if [ ! -s "$_out" ]; then
		die "qlty produced no output"
	fi
	if ! jq -e '.runs[0].results' "$_out" >/dev/null 2>&1; then
		die "qlty output is not valid SARIF"
	fi
	return 0
}

# count_smells <sarif>
count_smells() {
	local _sarif="$1"
	jq '.runs[0].results | length' "$_sarif" 2>/dev/null
	return 0
}

# write_report <scan-list> <sarif> <total> <base> <head> <out-md>
#
# Note: the literal backticks in printf format strings are intentional
# markdown formatting, not shell command substitution.
# shellcheck disable=SC2016
write_report() {
	local _list="$1"
	local _sarif="$2"
	local _total="$3"
	local _base="$4"
	local _head="$5"
	local _out="$6"
	local _n
	_n=$(wc -l <"$_list" | tr -d ' ')
	{
		printf '## Qlty New-File Smell Gate\n\n'
		if [ "$_n" = "0" ]; then
			printf '_No eligible new source files in this PR — gate skipped._\n\n'
			printf '<!-- qlty-new-file-gate -->\n'
			return 0
		fi
		if [ "$_total" = "0" ]; then
			printf '✅ **Clean** — %d new source file(s) scanned, no smells found.\n\n' "$_n"
			printf '| Base (`%s`) | Head (`%s`) | New files | Smells |\n' \
				"${_base:0:7}" "${_head:0:7}"
			printf '|---|---|---:|---:|\n'
			printf '| | | %d | 0 |\n\n' "$_n"
			printf '### New files scanned\n\n'
			awk '{printf "- `%s`\n", $0}' "$_list"
			printf '\n<!-- qlty-new-file-gate -->\n'
			return 0
		fi
		printf '❌ **Fail** — %d new source file(s) scanned, **%d smell(s)** found.\n\n' \
			"$_n" "$_total"
		printf '| Base (`%s`) | Head (`%s`) | New files | Smells |\n' \
			"${_base:0:7}" "${_head:0:7}"
		printf '|---|---|---:|---:|\n'
		printf '| | | %d | %d |\n\n' "$_n" "$_total"
		printf '### Per-file breakdown\n\n'
		jq -r '.runs[0].results
			| group_by(.locations[0].physicalLocation.artifactLocation.uri // "unknown")
			| map({
				file: (.[0].locations[0].physicalLocation.artifactLocation.uri // "unknown"),
				count: length,
				smells: (map({
					rule: (.ruleId // "unknown"),
					message: (.message.text // ""),
					line: (.locations[0].physicalLocation.region.startLine // 0)
				}))
			})
			| sort_by(-.count)
			| .[]
			| "#### `\(.file)` — \(.count) smell(s)\n\n"
				+ (.smells | map("- `\(.rule)` at line \(.line): \(.message)") | join("\n"))
				+ "\n"
		' "$_sarif"
		printf '\n'
		printf '> **Override**: to merge despite smells in a new file, apply the\n'
		printf '> `new-file-smell-ok` label AND add a `## New File Smell Justification`\n'
		printf '> section to the PR description explaining why the smells are acceptable.\n'
		printf '> See `.agents/AGENTS.md` → "Qlty New-File Smell Gate" for details.\n'
		printf '\n<!-- qlty-new-file-gate -->\n'
	} >"$_out"
	return 0
}

# cmd_new_files <base> <head> <output-md> <sarif> <dry-run>
cmd_new_files() {
	local _base="$1"
	local _head="$2"
	local _output_md="$3"
	local _sarif="$4"
	local _dry_run="$5"

	if [ -z "$_base" ]; then
		die "missing required --base argument"
	fi

	TMP_DIR=$(mktemp -d) || die "mktemp failed"
	local _added="$TMP_DIR/added.txt"
	local _list="$TMP_DIR/scan-list.txt"
	local _sarif_out="${_sarif:-$TMP_DIR/qlty-new-files.sarif}"

	list_added_files "$_base" "$_head" >"$_added" ||
		die "git diff failed (base=$_base head=$_head)"

	filter_scan_list "$_added" "$_list"

	local _n
	_n=$(wc -l <"$_list" | tr -d ' ')

	if [ "$_dry_run" = "1" ]; then
		log "Dry run — files that would be scanned:"
		if [ "$_n" -gt 0 ]; then
			cat "$_list" >&2
		else
			printf '  (none)\n' >&2
		fi
		return 0
	fi

	if [ "$_n" -eq 0 ]; then
		log "No eligible new source files — gate skipped"
		if [ -n "$_output_md" ]; then
			write_report "$_list" "/dev/null" "0" "$_base" "$_head" "$_output_md"
		fi
		return 0
	fi

	run_qlty_on_files "$_list" "$_sarif_out"
	local _total
	_total=$(count_smells "$_sarif_out")
	[ -z "$_total" ] && _total=0

	log "Total smells in new files: $_total"

	if [ -n "$_output_md" ]; then
		write_report "$_list" "$_sarif_out" "$_total" "$_base" "$_head" "$_output_md"
	fi

	if [ "$_total" -gt 0 ]; then
		return 1
	fi
	return 0
}

# --- argument parsing --------------------------------------------------------

COMMAND=""
BASE=""
HEAD="HEAD"
OUTPUT_MD=""
SARIF_OUT=""
DRY_RUN=0

if [ $# -eq 0 ]; then
	usage
	exit 2
fi

case "${1:-}" in
new-files | scan)
	COMMAND="new-files"
	shift
	;;
-h | --help)
	usage
	exit 0
	;;
--*)
	# Allow flags without an explicit command — default to new-files.
	COMMAND="new-files"
	;;
*)
	die "unknown command: $1 (use: new-files | scan | --help)"
	;;
esac

while [ $# -gt 0 ]; do
	case "$1" in
	--base)
		BASE="${2:-}"
		shift 2
		;;
	--head)
		HEAD="${2:-}"
		shift 2
		;;
	--output-md)
		OUTPUT_MD="${2:-}"
		shift 2
		;;
	--sarif)
		SARIF_OUT="${2:-}"
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown option: $1"
		;;
	esac
done

case "$COMMAND" in
new-files)
	cmd_new_files "$BASE" "$HEAD" "$OUTPUT_MD" "$SARIF_OUT" "$DRY_RUN"
	exit $?
	;;
*)
	usage
	exit 2
	;;
esac
