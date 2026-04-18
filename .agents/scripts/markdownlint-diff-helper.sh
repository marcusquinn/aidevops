#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# markdownlint-diff-helper.sh — scope markdownlint to changed-line ranges (t2241)
#
# Runs markdownlint-cli2 on PR-changed markdown files but filters the output
# to only violations whose line numbers fall inside changed-line ranges.
# Pre-existing violations in unchanged lines pass through silently.
#
# Also supports --mode biome for biome baseline-diff comparison.
#
# Usage:
#   markdownlint-diff-helper.sh --base <sha> [--head <sha>] [options]
#
# Options:
#   --base <sha>        Base ref (merge-base SHA, required)
#   --head <sha>        Head ref (default: HEAD)
#   --output-md <file>  Write markdown report to <file>
#   --mode <mode>       "markdownlint" (default) or "biome"
#   -h, --help          Show usage
#
# Exit codes:
#   0 — no new violations
#   1 — new violations detected
#   2 — invocation or environment error

set -uo pipefail

SCRIPT_NAME=$(basename "$0")
TMP_DIR=""
BASE_WORKTREE=""

cleanup() {
	if [ -n "$BASE_WORKTREE" ] && [ -d "$BASE_WORKTREE" ]; then
		git worktree remove --force "$BASE_WORKTREE" >/dev/null 2>&1 || true
	fi
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
	sed -n '4,27p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# --- changed-range parsing ----------------------------------------------------

# get_changed_ranges <base> <head> <glob-pattern>
# Outputs lines of "file:start:end" for each changed hunk in the diff.
get_changed_ranges() {
	local _base="$1"
	local _head="$2"
	local _pattern="$3"

	local _diff_output
	# shellcheck disable=SC2086
	_diff_output=$(git diff --unified=0 "$_base" "$_head" -- $_pattern 2>/dev/null) || true

	local _current_file=""
	{
		while IFS= read -r _line; do
			# Match "+++ b/path/to/file"
			case "$_line" in
			"+++ b/"*)
				_current_file="${_line#'+++ b/'}"
				;;
			"@@ "*)
				# Parse @@ -old +new_start,new_count @@ or @@ -old +new_start @@
				local _plus_part _start _count _end
				_plus_part=$(printf '%s' "$_line" | grep -oE '\+[0-9]+(,[0-9]+)?' | head -1)
				_start="${_plus_part#+}"
				_count=1
				if printf '%s' "$_start" | grep -q ','; then
					_count="${_start#*,}"
					_start="${_start%%,*}"
				fi
				# Skip deletion-only hunks (count=0)
				[ "$_count" -eq 0 ] 2>/dev/null && continue
				_end=$((_start + _count - 1))
				printf '%s:%d:%d\n' "$_current_file" "$_start" "$_end"
				;;
			esac
		done
	} <<< "$_diff_output"
	return 0
}

# is_in_changed_range <file> <line> <ranges-text>
# Returns 0 if the file:line falls inside any changed range.
is_in_changed_range() {
	local _file="$1"
	local _line="$2"
	local _ranges="$3"

	# Fast-path: ensure line is numeric
	if ! [ "$_line" -eq "$_line" ] 2>/dev/null; then
		return 1
	fi

	{
		while IFS= read -r _range; do
			[ -n "$_range" ] || continue
			local _rfile _rest _rstart _rend
			_rfile="${_range%%:*}"
			_rest="${_range#*:}"
			_rstart="${_rest%%:*}"
			_rend="${_rest#*:}"

			if [ "$_file" = "$_rfile" ] &&
				[ "$_line" -ge "$_rstart" ] 2>/dev/null &&
				[ "$_line" -le "$_rend" ] 2>/dev/null; then
				return 0
			fi
		done
	} <<< "$_ranges"
	return 1
}

# --- markdownlint mode --------------------------------------------------------

run_markdownlint() {
	local _base="$1"
	local _head="$2"
	local _output_md="$3"

	# Get changed MD files
	local _changed_files
	_changed_files=$(git diff --name-only --diff-filter=ACM "$_base" "$_head" -- '*.md')

	if [ -z "$_changed_files" ]; then
		log "No markdown files changed — skipping"
		return 0
	fi

	# Get changed line ranges
	local _ranges
	_ranges=$(get_changed_ranges "$_base" "$_head" "'*.md'")

	if [ -z "$_ranges" ]; then
		log "No line changes detected in markdown files"
		return 0
	fi

	log "Changed markdown files: $(echo "$_changed_files" | wc -l | tr -d ' ')"
	log "Changed hunks: $(echo "$_ranges" | wc -l | tr -d ' ')"

	# Run markdownlint on changed files — capture output (exits non-zero on violations)
	local _lint_output _file_list
	_file_list=$(echo "$_changed_files" | tr '\n' ' ')
	# shellcheck disable=SC2086
	_lint_output=$(npx --yes markdownlint-cli2@0.22.0 $_file_list 2>&1) || true

	if [ -z "$_lint_output" ]; then
		log "No markdownlint violations found"
		return 0
	fi

	# Filter violations to changed lines only
	# markdownlint-cli2 format: "file.md:LINE[:COL] RULE/name description"
	local _new_violations=""
	local _new_count=0
	local _total_count=0

	{
		while IFS= read -r _violation; do
			[ -n "$_violation" ] || continue
			# Skip non-violation lines (info headers, blank lines, etc.)
			# Violations match: path:number or path:number:number
			printf '%s' "$_violation" | grep -qE '^[^:]+:[0-9]+' || continue

			_total_count=$((_total_count + 1))

			# Extract file and line number
			local _vfile _vline
			_vfile=$(printf '%s' "$_violation" | cut -d: -f1)
			_vline=$(printf '%s' "$_violation" | cut -d: -f2)

			if is_in_changed_range "$_vfile" "$_vline" "$_ranges"; then
				_new_violations="${_new_violations}${_violation}
"
				_new_count=$((_new_count + 1))
			fi
		done
	} <<< "$_lint_output"

	log "Total violations in changed files: $_total_count"
	log "New violations (in changed lines): $_new_count"

	if [ "$_new_count" -eq 0 ]; then
		# Write passing report if requested
		if [ -n "$_output_md" ]; then
			write_markdownlint_report "$_output_md" "$_new_count" "$_total_count" \
				"" "$_base" "$_head"
		fi
		return 0
	fi

	# Print new violations to stdout
	printf '%s' "$_new_violations"

	# Write report if requested
	if [ -n "$_output_md" ]; then
		write_markdownlint_report "$_output_md" "$_new_count" "$_total_count" \
			"$_new_violations" "$_base" "$_head"
	fi

	return 1
}

write_markdownlint_report() {
	local _out="$1"
	local _new_count="$2"
	local _total_count="$3"
	local _violations="$4"
	local _base_sha="$5"
	local _head_sha="$6"

	local _verdict
	if [ "$_new_count" -gt 0 ]; then
		_verdict="**$_new_count new violation(s)** introduced in changed lines (${_total_count} total in touched files)."
	else
		_verdict="No new violations in changed lines (${_total_count} pre-existing in touched files — ignored)."
	fi

	{
		printf '## Markdown Lint (changed-line scoped)\n\n'
		printf '%s\n\n' "$_verdict"
		# shellcheck disable=SC2016
		printf '| Metric | Base (`%s`) | Head (`%s`) |\n' \
			"${_base_sha:0:7}" "${_head_sha:0:7}"
		printf '|---|---:|---:|\n'
		printf '| Total in touched files | — | %s |\n' "$_total_count"
		printf '| New (in changed lines) | — | %s |\n\n' "$_new_count"

		if [ "$_new_count" -gt 0 ] && [ -n "$_violations" ]; then
			printf '### New violations\n\n'
			printf '```text\n'
			printf '%s' "$_violations"
			printf '```\n\n'
			# shellcheck disable=SC2016
			printf '> To override, add the `lint-baseline-ok` label to this PR.\n'
		fi
		printf '\n<!-- markdownlint-diff-gate -->\n'
	} >"$_out"
	return 0
}

# --- biome mode ---------------------------------------------------------------

run_biome() {
	local _base="$1"
	local _head="$2"
	local _output_md="$3"

	# Get changed biome-eligible files
	local _changed_files
	_changed_files=$(git diff --name-only --diff-filter=ACM "$_base" "$_head" -- \
		'*.ts' '*.tsx' '*.js' '*.jsx' '*.json' '*.jsonc' '*.css' '*.graphql' 2>/dev/null)

	if [ -z "$_changed_files" ]; then
		log "No biome-eligible files changed — skipping"
		return 0
	fi

	log "Changed biome files: $(echo "$_changed_files" | wc -l | tr -d ' ')"

	TMP_DIR=$(mktemp -d)

	# Create a worktree at the base ref for baseline comparison
	BASE_WORKTREE="${TMP_DIR}/base-tree"
	log "Creating base worktree at ${_base:0:7}..."
	git worktree add --quiet "$BASE_WORKTREE" "$_base" 2>/dev/null || {
		# Fallback: detached HEAD
		git worktree add --detach --quiet "$BASE_WORKTREE" "$_base" 2>/dev/null || {
			die "Failed to create base worktree at $_base"
		}
	}

	# Count violations at base (only in changed files that exist at base)
	local _base_count=0
	local _base_file_list=""
	{
		while IFS= read -r _f; do
			[ -n "$_f" ] || continue
			[ -f "${BASE_WORKTREE}/${_f}" ] && _base_file_list="${_base_file_list} ${_f}"
		done
	} <<< "$_changed_files"

	if [ -n "$_base_file_list" ]; then
		local _base_output
		# shellcheck disable=SC2086
		_base_output=$(cd "$BASE_WORKTREE" && npx --yes @biomejs/biome@2.4.12 lint \
			--reporter=github --max-diagnostics=9999 $_base_file_list 2>&1) || true
		_base_count=$(printf '%s' "$_base_output" | grep -c '^::error' 2>/dev/null || echo "0")
	fi

	# Count violations at head
	local _head_count=0
	local _head_file_list=""
	{
		while IFS= read -r _f; do
			[ -n "$_f" ] || continue
			[ -f "$_f" ] && _head_file_list="${_head_file_list} ${_f}"
		done
	} <<< "$_changed_files"

	if [ -n "$_head_file_list" ]; then
		local _head_output
		# shellcheck disable=SC2086
		_head_output=$(npx --yes @biomejs/biome@2.4.12 lint \
			--reporter=github --max-diagnostics=9999 $_head_file_list 2>&1) || true
		_head_count=$(printf '%s' "$_head_output" | grep -c '^::error' 2>/dev/null || echo "0")
	fi

	local _delta=$((_head_count - _base_count))

	log "Base violations: $_base_count"
	log "Head violations: $_head_count"
	log "Delta: $_delta"

	# Write report if requested
	if [ -n "$_output_md" ]; then
		write_biome_report "$_output_md" "$_base_count" "$_head_count" "$_delta" \
			"$_base" "$_head"
	fi

	if [ "$_delta" -gt 0 ]; then
		log "$_delta new biome violation(s) introduced"
		return 1
	fi

	return 0
}

write_biome_report() {
	local _out="$1"
	local _base_count="$2"
	local _head_count="$3"
	local _delta="$4"
	local _base_sha="$5"
	local _head_sha="$6"

	local _verdict
	if [ "$_delta" -gt 0 ]; then
		_verdict="**$_delta new violation(s)** introduced by this PR."
	elif [ "$_delta" -lt 0 ]; then
		local _improved=$((_delta * -1))
		_verdict="**$_improved violation(s) fixed** by this PR."
	else
		_verdict="No change in violation count."
	fi

	{
		printf '## Biome Lint (baseline diff)\n\n'
		printf '%s\n\n' "$_verdict"
		# shellcheck disable=SC2016
		printf '| Metric | Base (`%s`) | Head (`%s`) | Delta |\n' \
			"${_base_sha:0:7}" "${_head_sha:0:7}"
		printf '|---|---:|---:|---:|\n'
		printf '| Violations in changed files | %s | %s | %+d |\n\n' \
			"$_base_count" "$_head_count" "$_delta"

		if [ "$_delta" -gt 0 ]; then
			# shellcheck disable=SC2016
			printf '> To override, add the `lint-baseline-ok` label to this PR.\n'
		fi
		printf '\n<!-- biome-diff-gate -->\n'
	} >"$_out"
	return 0
}

# --- main ---------------------------------------------------------------------

main() {
	local _base=""
	local _head="HEAD"
	local _output_md=""
	local _mode="markdownlint"
	local _arg

	while [ $# -gt 0 ]; do
		_arg="$1"
		case "$_arg" in
		--base)
			if [ $# -lt 2 ]; then die "missing value for --base"; fi
			_base="$2"
			shift 2
			;;
		--head)
			if [ $# -lt 2 ]; then die "missing value for --head"; fi
			_head="$2"
			shift 2
			;;
		--output-md)
			if [ $# -lt 2 ]; then die "missing value for --output-md"; fi
			_output_md="$2"
			shift 2
			;;
		--mode)
			if [ $# -lt 2 ]; then die "missing value for --mode"; fi
			_mode="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $_arg"
			;;
		esac
	done

	if [ -z "$_base" ]; then
		die "--base is required"
	fi

	case "$_mode" in
	markdownlint)
		set +e
		run_markdownlint "$_base" "$_head" "$_output_md"
		exit $?
		;;
	biome)
		set +e
		run_biome "$_base" "$_head" "$_output_md"
		exit $?
		;;
	*)
		die "unknown mode: $_mode (expected 'markdownlint' or 'biome')"
		;;
	esac
}

main "$@"
