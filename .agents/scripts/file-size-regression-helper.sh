#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# file-size-regression-helper.sh — ratchet gate for non-code Markdown line count (t2938)
#
# Converts the absolute file-size gate from linters-local.sh into a net-increase
# (ratchet) gate. Block only when the PR adds files over the limit, not for
# pre-existing debt. Mirrors qlty-regression-helper.sh (t2065) and complements
# complexity-regression-helper.sh (t2171).
#
# Subcommands:
#   scan      <dir>  [--output <file>] [--limit <N>]
#                    Scan a directory for non-README .md files over <limit> lines.
#                    Outputs TSV: relative-path TAB line-count.
#   scan-ref  <ref>  [--output <file>] [--limit <N>]
#                    Same as scan but reads content from a git ref (no checkout).
#                    Outputs TSV: git-tracked-path TAB line-count.
#   diff      --base-file <f> --head-file <f>
#             [--base-sha <sha>] [--head-sha <sha>]
#             [--output-md <file>] [--allow-increase] [--docs-only]
#                    Compare two scan TSV outputs. Exit 1 on regression.
#   check     [--base <ref>] [--head <ref>] [--limit <N>]
#             [--output-md <file>] [--allow-increase] [--dry-run]
#                    High-level: scan-ref base + scan-ref head + diff.
#
# Exit codes:
#   0 — no regression (or override / dry-run / docs-only)
#   1 — regression detected
#   2 — invocation or environment error
#
# Regression is triggered by EITHER:
#   (a) head violation count > base violation count  (net increase)
#   (b) any file present in head violations but absent from base violations
#       (prevents gaming by deleting one oversized file and adding another)
#
# Override: apply `complexity-bump-ok` label + `## Complexity Bump Justification`
# section to the PR body. The CI workflow enforces the justification check.
# See: reference/large-file-split.md §4.1 for override semantics.
#
# Design notes:
# - check scans base and head through git-tracked file lists so ignored/vendor
#   directories (for example node_modules/) cannot enter regression math.
# - All subcommands are Bash 3.2 compatible (macOS default shell).
# - Paths in TSV output are relative to the dir/ref root for portability.
# - docs-only detection: caller passes --docs-only; the gate exits 0 immediately.

set -uo pipefail

SCRIPT_NAME=$(basename "$0")
readonly FILE_SIZE_DEFAULT_LIMIT=500
readonly FILE_SIZE_DEFAULT_HEAD_REF="HEAD"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# should_scan_markdown_path <path>
# Return 0 for paths in ratchet scope: tracked non-README Markdown excluding
# generated/vendor locations.
# ---------------------------------------------------------------------------
should_scan_markdown_path() {
	local _path="$1"
	case "$_path" in
	*.md) ;;
	*) return 1 ;;
	esac
	case "$_path" in
	README.md | */README.md) return 1 ;;
	_archive/* | */_archive/*) return 1 ;;
	node_modules/* | */node_modules/*) return 1 ;;
	vendor/* | */vendor/*) return 1 ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# scan_violations_dir <dir> <limit>
# Scan a plain directory for non-README .md files with more than <limit> lines.
# Outputs TSV: path-relative-to-dir TAB line-count  (sorted by path).
# ---------------------------------------------------------------------------
scan_violations_dir() {
	local _dir="$1"
	local _limit="$2"
	local _dir_abs
	_dir_abs=$(cd "$_dir" && pwd) || die "directory not found: $_dir"
	local _tmp
	_tmp=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$_tmp'" RETURN

	find "$_dir_abs" -type f -name "*.md" ! -name "README.md" | sort | while IFS= read -r _f; do
		local _rel="${_f#"${_dir_abs}"/}"
		should_scan_markdown_path "$_rel" || continue
		local _lc
		_lc=$(wc -l < "$_f") || _lc=0
		_lc=${_lc//[^0-9]/}
		_lc=${_lc:-0}
		if [ "$_lc" -gt "$_limit" ]; then
			printf '%s\t%d\n' "$_rel" "$_lc"
		fi
	done | sort -k1,1 > "$_tmp"
	cat "$_tmp"
	return 0
}

# ---------------------------------------------------------------------------
# scan_violations_git_worktree <dir> <limit>
# Scan only git-tracked Markdown paths in <dir>. This intentionally ignores
# untracked, gitignored, generated, and vendor files in the working tree.
# Outputs TSV: git-path TAB line-count  (sorted by path).
# ---------------------------------------------------------------------------
scan_violations_git_worktree() {
	local _dir="$1"
	local _limit="$2"
	local _dir_abs
	_dir_abs=$(cd "$_dir" && pwd) || die "directory not found: $_dir"
	local _tmp
	_tmp=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$_tmp'" RETURN

	git -C "$_dir_abs" ls-files '*.md' 2>/dev/null | while IFS= read -r _path; do
		[ -n "$_path" ] || continue
		should_scan_markdown_path "$_path" || continue
		[ -f "$_dir_abs/$_path" ] || continue
		local _lc
		_lc=$(wc -l < "$_dir_abs/$_path") || _lc=0
		_lc=${_lc//[^0-9]/}
		_lc=${_lc:-0}
		if [ "$_lc" -gt "$_limit" ]; then
			printf '%s\t%d\n' "$_path" "$_lc"
		fi
	done | sort -k1,1 > "$_tmp"
	cat "$_tmp"
	return 0
}

# ---------------------------------------------------------------------------
# scan_violations_ref <ref> <limit>
# Scan a git ref for non-README .md files with more than <limit> lines.
# Uses a temporary git worktree so wc -l runs on local files (fast for
# repos with 1000+ scripts). Worktree is always removed via trap.
# Outputs TSV: git-path TAB line-count  (sorted by path).
# ---------------------------------------------------------------------------
scan_violations_ref() {
	local _ref="$1"
	local _limit="$2"
	local _worktree
	_worktree=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "git worktree remove --force '$_worktree' >/dev/null 2>&1; rm -rf '$_worktree'" RETURN

	if ! git worktree add --detach "$_worktree" "$_ref" > /dev/null 2>&1; then
		log "WARN: could not create worktree for $_ref — scan skipped"
		return 0
	fi

	# Use git ls-files inside the temporary checkout so ref scans and working-tree
	# scans have the same tracked-file scope and vendor exclusions.
	scan_violations_git_worktree "$_worktree" "$_limit"
	return 0
}

# ---------------------------------------------------------------------------
# count_tsv_lines <file>
# Count non-empty lines in a TSV file (= number of violation entries).
# ---------------------------------------------------------------------------
count_tsv_lines() {
	local _f="$1"
	if [ ! -s "$_f" ]; then
		echo 0
		return 0
	fi
	local _n
	_n=$(grep -c '.' "$_f" 2>/dev/null || true)
	_n=${_n//[^0-9]/}
	echo "${_n:-0}"
	return 0
}

# ---------------------------------------------------------------------------
# find_new_violations <base_tsv> <head_tsv>
# Print paths that appear in head_tsv but NOT in base_tsv.
# Bash 3.2 compatible (no process substitution).
# ---------------------------------------------------------------------------
find_new_violations() {
	local _base="$1"
	local _head="$2"
	local _base_paths _head_paths
	_base_paths=$(mktemp)
	_head_paths=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$_base_paths' '$_head_paths'" RETURN

	if [ -s "$_base" ]; then
		awk -F'\t' '{print $1}' "$_base" | sort > "$_base_paths"
	else
		: > "$_base_paths"
	fi
	if [ -s "$_head" ]; then
		awk -F'\t' '{print $1}' "$_head" | sort > "$_head_paths"
	else
		: > "$_head_paths"
	fi

	# Lines in head_paths not present in base_paths. Use FILENAME instead of
	# NR==FNR so an empty base file does not make awk treat the head file as base.
	awk 'FILENAME==ARGV[1]{a[$0]=1; next} FILENAME==ARGV[2] && !($0 in a){print}' \
		"$_base_paths" "$_head_paths"
	return 0
}

# ---------------------------------------------------------------------------
# write_report <base_count> <head_count> <new_count> <new_paths>
#              <base_sha> <head_sha> <output_md>
# ---------------------------------------------------------------------------
write_report() {
	local _base_count="$1"
	local _head_count="$2"
	local _new_count="$3"
	local _new_paths="$4"
	local _base_sha="$5"
	local _head_sha="$6"
	local _out="$7"
	local _net_delta=$((_head_count - _base_count))
	local _verdict
	local _is_regression=0

	if [ "$_net_delta" -gt 0 ] || [ "$_new_count" -gt 0 ]; then
		_is_regression=1
		_verdict="❌ **Regression** — ${_new_count} new file(s) over the line limit."
	elif [ "$_net_delta" -lt 0 ]; then
		_verdict="✅ **Improvement** — $((_net_delta * -1)) file(s) brought under the line limit."
	else
		_verdict="✅ **No change** — violation count unchanged."
	fi

	{
		printf '## File Size Regression Gate\n\n'
		printf '%s\n\n' "$_verdict"
		# shellcheck disable=SC2016
		printf '| Metric | Base (`%s`) | Head (`%s`) | Delta |\n' \
			"${_base_sha:0:7}" "${_head_sha:0:7}"
		printf '|---|---:|---:|---:|\n'
		printf '| Non-README Markdown files >%d lines | %d | %d | %+d |\n\n' \
			"$FILE_SIZE_DEFAULT_LIMIT" "$_base_count" "$_head_count" "$_net_delta"
		if [ "$_is_regression" -eq 1 ] && [ -n "$_new_paths" ]; then
			printf '### New oversized files\n\n'
			printf '| File |\n|---|\n'
			printf '%s\n' "$_new_paths" | while IFS= read -r _p; do
				# shellcheck disable=SC2016
				[ -n "$_p" ] && printf '| `%s` |\n' "$_p"
			done
			printf '\n'
			# shellcheck disable=SC2016
			printf '> Override: apply `complexity-bump-ok` label with a `## Complexity Bump Justification` section.\n'
			# shellcheck disable=SC2016
			printf '> See `.agents/AGENTS.md` → "Complexity Bump Override" for details.\n'
		fi
		printf '\n<!-- file-size-regression-gate -->\n'
	} > "$_out"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_scan — subcommand: scan <dir> [--output <file>] [--limit <N>]
# ---------------------------------------------------------------------------
cmd_scan() {
	if [ $# -eq 0 ]; then
		die "scan: <dir> is required"
	fi
	local _dir="$1"
	shift
	local _output=""
	local _limit="$FILE_SIZE_DEFAULT_LIMIT"

	while [ $# -gt 0 ]; do
		local _cur_opt="$1"
		shift
		case "$_cur_opt" in
		--output)
			[ $# -ge 1 ] || die "scan: missing value for --output"
			local _out_val="$1"
			_output="$_out_val"
			shift
			;;
		--limit)
			[ $# -ge 1 ] || die "scan: missing value for --limit"
			local _lim_val="$1"
			_limit="$_lim_val"
			shift
			;;
		*) die "scan: unknown argument: $_cur_opt" ;;
		esac
	done

	[ -d "$_dir" ] || die "scan: not a directory: $_dir"

	local _result
	_result=$(scan_violations_dir "$_dir" "$_limit")
	if [ -n "$_output" ]; then
		printf '%s\n' "$_result" > "$_output"
	else
		printf '%s\n' "$_result"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# cmd_scan_ref — subcommand: scan-ref <ref> [--output <file>] [--limit <N>]
# ---------------------------------------------------------------------------
cmd_scan_ref() {
	if [ $# -eq 0 ]; then
		die "scan-ref: <ref> is required"
	fi
	local _ref="$1"
	shift
	local _output=""
	local _limit="$FILE_SIZE_DEFAULT_LIMIT"

	while [ $# -gt 0 ]; do
		local _cur_opt="$1"
		shift
		case "$_cur_opt" in
		--output)
			[ $# -ge 1 ] || die "scan-ref: missing value for --output"
			local _out_val="$1"
			_output="$_out_val"
			shift
			;;
		--limit)
			[ $# -ge 1 ] || die "scan-ref: missing value for --limit"
			local _lim_val="$1"
			_limit="$_lim_val"
			shift
			;;
		*) die "scan-ref: unknown argument: $_cur_opt" ;;
		esac
	done

	if ! git rev-parse --verify --quiet "${_ref}^{commit}" > /dev/null 2>&1; then
		die "scan-ref: ref not found: $_ref"
	fi

	local _result
	_result=$(scan_violations_ref "$_ref" "$_limit")
	if [ -n "$_output" ]; then
		printf '%s\n' "$_result" > "$_output"
	else
		printf '%s\n' "$_result"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# cmd_diff — subcommand: diff --base-file <f> --head-file <f> [options]
# ---------------------------------------------------------------------------
cmd_diff() {
	local _base_file=""
	local _head_file=""
	local _base_sha="base"
	local _head_sha="head"
	local _output_md=""
	local _allow_increase=0
	local _docs_only=0

	while [ $# -gt 0 ]; do
		local _cur_opt="$1"
		shift
		case "$_cur_opt" in
		--base-file)
			[ $# -ge 1 ] || die "diff: missing value for --base-file"
			local _bf="$1"
			_base_file="$_bf"
			shift
			;;
		--head-file)
			[ $# -ge 1 ] || die "diff: missing value for --head-file"
			local _hf="$1"
			_head_file="$_hf"
			shift
			;;
		--base-sha)
			[ $# -ge 1 ] || die "diff: missing value for --base-sha"
			local _bsha="$1"
			_base_sha="$_bsha"
			shift
			;;
		--head-sha)
			[ $# -ge 1 ] || die "diff: missing value for --head-sha"
			local _hsha="$1"
			_head_sha="$_hsha"
			shift
			;;
		--output-md)
			[ $# -ge 1 ] || die "diff: missing value for --output-md"
			local _omd="$1"
			_output_md="$_omd"
			shift
			;;
		--allow-increase)
			_allow_increase=1
			;;
		--docs-only)
			_docs_only=1
			;;
		*) die "diff: unknown argument: $_cur_opt" ;;
		esac
	done

	[ -n "$_base_file" ] || die "diff: --base-file is required"
	[ -n "$_head_file" ] || die "diff: --head-file is required"
	[ -f "$_base_file" ] || die "diff: base-file not found: $_base_file"
	[ -f "$_head_file" ] || die "diff: head-file not found: $_head_file"

	if [ "$_docs_only" -eq 1 ]; then
		log "docs-only: skipping file-size regression gate"
		return 0
	fi

	local _base_count _head_count _new_paths _new_count
	_base_count=$(count_tsv_lines "$_base_file")
	_head_count=$(count_tsv_lines "$_head_file")
	_new_paths=$(find_new_violations "$_base_file" "$_head_file")
	_new_count=$(printf '%s\n' "$_new_paths" | grep -c '.' 2>/dev/null || true)
	_new_count=${_new_count//[^0-9]/}
	_new_count=${_new_count:-0}

	log "base: $_base_count  head: $_head_count  new: $_new_count"
	log "compared refs: base=$_base_sha  head=$_head_sha"

	if [ -n "$_output_md" ]; then
		write_report "$_base_count" "$_head_count" "$_new_count" \
			"$_new_paths" "$_base_sha" "$_head_sha" "$_output_md"
		log "report written to $_output_md"
	fi

	local _net_delta=$((_head_count - _base_count))
	if [ "$_net_delta" -gt 0 ] || [ "$_new_count" -gt 0 ]; then
		if [ "$_allow_increase" -eq 1 ]; then
			log "REGRESSION detected but --allow-increase set — warning only"
			return 0
		fi
		log "REGRESSION: net_delta=${_net_delta}  new_violations=${_new_count}"
		if [ -n "$_new_paths" ]; then
			log "new oversized files:"
			printf '%s\n' "$_new_paths" | while IFS= read -r _path; do
				[ -n "$_path" ] && log "  $_path"
			done
		fi
		return 1
	fi

	log "no regression"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_check_parse_args — parse check options into FILE_SIZE_CHECK_* globals.
# ---------------------------------------------------------------------------
cmd_check_parse_args() {
	FILE_SIZE_CHECK_BASE_REF=""
	FILE_SIZE_CHECK_HEAD_REF="$FILE_SIZE_DEFAULT_HEAD_REF"
	FILE_SIZE_CHECK_LIMIT="$FILE_SIZE_DEFAULT_LIMIT"
	FILE_SIZE_CHECK_OUTPUT_MD=""
	FILE_SIZE_CHECK_ALLOW_INCREASE=0
	FILE_SIZE_CHECK_DRY_RUN=0

	while [ $# -gt 0 ]; do
		local _cur_opt="$1"
		shift
		case "$_cur_opt" in
		--base)
			[ $# -ge 1 ] || die "check: missing value for --base"
			local _bref="$1"
			FILE_SIZE_CHECK_BASE_REF="$_bref"
			shift
			;;
		--head)
			[ $# -ge 1 ] || die "check: missing value for --head"
			local _href="$1"
			FILE_SIZE_CHECK_HEAD_REF="$_href"
			shift
			;;
		--limit)
			[ $# -ge 1 ] || die "check: missing value for --limit"
			local _lim="$1"
			FILE_SIZE_CHECK_LIMIT="$_lim"
			shift
			;;
		--output-md)
			[ $# -ge 1 ] || die "check: missing value for --output-md"
			local _omd="$1"
			FILE_SIZE_CHECK_OUTPUT_MD="$_omd"
			shift
			;;
		--allow-increase)
			FILE_SIZE_CHECK_ALLOW_INCREASE=1
			;;
		--dry-run)
			FILE_SIZE_CHECK_DRY_RUN=1
			;;
		*) die "check: unknown argument: $_cur_opt" ;;
		esac
	done
	return 0
}

# ---------------------------------------------------------------------------
# cmd_check_detect_base_ref <configured-base-ref>
# ---------------------------------------------------------------------------
cmd_check_detect_base_ref() {
	local _base_ref="$1"
	if [ -n "$_base_ref" ]; then
		printf '%s\n' "$_base_ref"
		return 0
	fi

	local _default_branch
	_default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
		| sed 's|refs/remotes/origin/||') || _default_branch=""
	if [ -n "$_default_branch" ] \
		&& git rev-parse --verify --quiet "origin/${_default_branch}" > /dev/null 2>&1; then
		printf 'origin/%s\n' "$_default_branch"
	elif git rev-parse --verify --quiet "origin/main" > /dev/null 2>&1; then
		printf 'origin/main\n'
	elif git rev-parse --verify --quiet "origin/master" > /dev/null 2>&1; then
		printf 'origin/master\n'
	fi
	return 0
}

# ---------------------------------------------------------------------------
# cmd_check_resolve_compare_ref <base-ref> <head-ref>
# Prefer the merge-base between base and head so rebases or a moving origin/main
# do not compare against unrelated newer base commits. Fall back to base ref.
# ---------------------------------------------------------------------------
cmd_check_resolve_compare_ref() {
	local _base_ref="$1"
	local _head_ref="$2"
	local _merge_base=""
	_merge_base=$(git merge-base "$_base_ref" "$_head_ref" 2>/dev/null) || _merge_base=""
	if [ -n "$_merge_base" ]; then
		printf '%s\n' "$_merge_base"
		return 0
	fi
	printf '%s\n' "$_base_ref"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_check_scan_head <head-ref> <limit> <head-tsv>
# ---------------------------------------------------------------------------
cmd_check_scan_head() {
	local _head_ref="$1"
	local _limit="$2"
	local _head_tsv="$3"
	# For HEAD, scan tracked working-tree files directly (avoids creating a
	# worktree for HEAD while still excluding untracked/ignored/vendor files).
	if [ "$_head_ref" = "$FILE_SIZE_DEFAULT_HEAD_REF" ]; then
		local _repo_root
		_repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || _repo_root="."
		scan_violations_git_worktree "$_repo_root" "$_limit" > "$_head_tsv" 2>/dev/null || true
	else
		scan_violations_ref "$_head_ref" "$_limit" > "$_head_tsv" 2>/dev/null || true
	fi
	return 0
}

# ---------------------------------------------------------------------------
# cmd_check_run_diff <base-tsv> <head-tsv> <base-sha> <head-sha> <output-md> <allow>
# ---------------------------------------------------------------------------
cmd_check_run_diff() {
	local _base_tsv="${1:-}"
	local _head_tsv="${2:-}"
	local _base_sha="${3:-}"
	local _head_sha="${4:-}"
	local _output_md="${5:-}"
	local _allow_increase="${6:-0}"
	local _diff_exit=0

	if [[ -n "$_output_md" && "$_allow_increase" == "1" ]]; then
		cmd_diff --base-file "$_base_tsv" --head-file "$_head_tsv" \
			--base-sha "$_base_sha" --head-sha "$_head_sha" \
			--output-md "$_output_md" --allow-increase || _diff_exit=$?
	elif [[ -n "$_output_md" ]]; then
		cmd_diff --base-file "$_base_tsv" --head-file "$_head_tsv" \
			--base-sha "$_base_sha" --head-sha "$_head_sha" \
			--output-md "$_output_md" || _diff_exit=$?
	elif [[ "$_allow_increase" == "1" ]]; then
		cmd_diff --base-file "$_base_tsv" --head-file "$_head_tsv" \
			--base-sha "$_base_sha" --head-sha "$_head_sha" \
			--allow-increase || _diff_exit=$?
	else
		cmd_diff --base-file "$_base_tsv" --head-file "$_head_tsv" \
			--base-sha "$_base_sha" --head-sha "$_head_sha" || _diff_exit=$?
	fi
	return "$_diff_exit"
}

# ---------------------------------------------------------------------------
# cmd_check — subcommand: check [--base <ref>] [--head <ref>] [options]
# ---------------------------------------------------------------------------
cmd_check() {
	cmd_check_parse_args "$@"

	local _base_ref
	_base_ref=$(cmd_check_detect_base_ref "$FILE_SIZE_CHECK_BASE_REF")
	local _tmp_dir
	_tmp_dir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$_tmp_dir'" EXIT

	local _head_tsv="$_tmp_dir/head.tsv"
	if [ "$FILE_SIZE_CHECK_DRY_RUN" -eq 1 ]; then
		log "dry-run: scanning current working tree"
		cmd_check_scan_head "$FILE_SIZE_DEFAULT_HEAD_REF" "$FILE_SIZE_CHECK_LIMIT" "$_head_tsv"
		local _count
		_count=$(count_tsv_lines "$_head_tsv")
		printf 'Total violations (file-size): %d\n' "$_count"
		return 0
	fi

	if [ -z "$_base_ref" ]; then
		log "WARN: no origin ref found — file-size ratchet skipped (fail-open)"
		return 0
	fi
	if ! git rev-parse --verify --quiet "${_base_ref}^{commit}" > /dev/null 2>&1; then
		log "WARN: base ref not available: $_base_ref — ratchet skipped (fail-open)"
		return 0
	fi

	local _base_compare_ref
	_base_compare_ref=$(cmd_check_resolve_compare_ref "$_base_ref" "$FILE_SIZE_CHECK_HEAD_REF")
	local _base_tsv="$_tmp_dir/base.tsv"
	local _base_sha _head_sha
	_base_sha=$(git rev-parse --short "$_base_compare_ref" 2>/dev/null) || _base_sha="$_base_compare_ref"
	_head_sha=$(git rev-parse --short "$FILE_SIZE_CHECK_HEAD_REF" 2>/dev/null) || _head_sha="$FILE_SIZE_CHECK_HEAD_REF"
	log "scanning base ($_base_sha from $_base_ref)"
	scan_violations_ref "$_base_compare_ref" "$FILE_SIZE_CHECK_LIMIT" > "$_base_tsv" 2>/dev/null || true
	log "scanning head ($_head_sha)"
	cmd_check_scan_head "$FILE_SIZE_CHECK_HEAD_REF" "$FILE_SIZE_CHECK_LIMIT" "$_head_tsv"
	cmd_check_run_diff "$_base_tsv" "$_head_tsv" "$_base_sha" "$_head_sha" \
		"$FILE_SIZE_CHECK_OUTPUT_MD" "$FILE_SIZE_CHECK_ALLOW_INCREASE"
	return $?
}

# ---------------------------------------------------------------------------
# main — dispatch to subcommand
# ---------------------------------------------------------------------------
main() {
	if [ $# -eq 0 ]; then
		die "no subcommand given (scan | scan-ref | diff | check)"
	fi
	local _subcmd="$1"
	shift

	case "$_subcmd" in
	scan)     cmd_scan "$@" ;;
	scan-ref) cmd_scan_ref "$@" ;;
	diff)     cmd_diff "$@" ;;
	check)    cmd_check "$@" ;;
	-h | --help)
		sed -n '4,60p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*) die "unknown subcommand: $_subcmd (valid: scan | scan-ref | diff | check)" ;;
	esac
}

main "$@"
