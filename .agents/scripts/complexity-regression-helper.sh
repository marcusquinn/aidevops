#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# complexity-regression-helper.sh — CI regression gate for complexity metrics (t2159, t2171)
#
# Scans complexity violations at PR base and head, computes the set difference
# (new violations only), and emits a markdown report. Exits 1 only when the PR
# introduces NEW violations — not for total drift already present in the base.
#
# Supported metrics (--metric flag, default: function-complexity):
#
#   function-complexity  — shell functions >100 body lines.
#                          Key: (file, function_name); value: line count.
#                          (Originally t2159; back-compat default.)
#
#   nesting-depth        — shell files with max nesting depth >8.
#                          Key: (file, 'NEST'); value: max depth.
#                          (t2171; replaces pulse-simplification.sh proximity scanner.)
#
#   file-size            — .sh and .py files over 1500 lines.
#                          Key: (file, 'SIZE'); value: line count.
#                          (t2171)
#
#   bash32-compat        — bash 4+ constructs in .sh files that break on macOS 3.2.
#                          Patterns: \t/\n escapes, associative arrays, namerefs,
#                          heredoc-inside-$().
#                          Key: (file, '<pattern>:<line>'); value: 1.
#                          (t2171)
#
# Subcommands:
#   scan  <dir> [--output <file>] [--metric <name>]
#         Scan <dir> for violations of <metric>.
#         Output: one line per violation, tab-separated:
#           <relative-file>\t<identifier>\t<value>
#
#   diff  --base-file <scan-file> --head-file <scan-file>
#         [--output-md <file>] [--base-sha <sha>] [--head-sha <sha>]
#         [--metric <name>]
#         Compute the set difference and produce a markdown report.
#
#   check --base <sha> [--head <sha>] [--output-md <file>]
#         [--allow-increase] [--dry-run] [--metric <name>]
#         Full regression check using git worktrees. Main entry point.
#
# Exit codes:
#   0 — no new violations (or --allow-increase / --dry-run)
#   1 — new violations detected
#   2 — invocation or environment error

set -uo pipefail

SCRIPT_NAME=$(basename "$0")
TMP_DIR=""
BASE_WORKTREE=""
HEAD_WORKTREE=""

cleanup() {
	if [ -n "$BASE_WORKTREE" ] && [ -d "$BASE_WORKTREE" ]; then
		git worktree remove --force "$BASE_WORKTREE" >/dev/null 2>&1 || true
	fi
	if [ -n "$HEAD_WORKTREE" ] && [ -d "$HEAD_WORKTREE" ]; then
		git worktree remove --force "$HEAD_WORKTREE" >/dev/null 2>&1 || true
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
	sed -n '4,49p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# ---------------------------------------------------------------------------
# _collect_files <dir> <extensions>
#
# Emit newline-separated ABSOLUTE paths of all tracked files under <dir> whose
# extension matches one of <extensions> (space-separated, e.g. "sh" or "sh py").
#
# Uses `git ls-files` against <dir> (must be a git worktree), mirroring the CI
# discovery in .agents/scripts/lint-file-discovery.sh — single source of truth
# for the _archive/ exclusion. Keeps this helper's counts in parity with the
# CI warning steps (nesting/file-size/bash32) so PR comments don't diverge
# from the non-blocking warnings that the pulse also consumes.
#
# Why not find: find includes untracked files (drafts, build artifacts) which
# the CI does not scan. Parity with CI requires git-based discovery.
# ---------------------------------------------------------------------------
_collect_files() {
	local _dir="$1"
	local _exts="$2"
	local _ext _pattern
	local _output=""

	# Primary path: git ls-files for CI parity with lint-file-discovery.sh.
	if git -C "$_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		for _ext in $_exts; do
			_pattern="*.${_ext}"
			local _chunk
			_chunk=$(git -C "$_dir" ls-files "$_pattern" 2>/dev/null |
				grep -Ev '_archive/' || true)
			if [ -n "$_chunk" ]; then
				if [ -z "$_output" ]; then
					_output="$_chunk"
				else
					_output=$(printf '%s\n%s' "$_output" "$_chunk")
				fi
			fi
		done
		if [ -n "$_output" ]; then
			printf '%s\n' "$_output" | awk -v d="$_dir" 'NF{print d "/" $0}' | sort -u
			return 0
		fi
	fi

	# Fallback: find-based discovery for non-git dirs (test fixtures, ad-hoc
	# scans). Matches the same _archive/ exclusion.
	local _find_args=()
	for _ext in $_exts; do
		if [ "${#_find_args[@]}" -eq 0 ]; then
			_find_args+=(-name "*.${_ext}")
		else
			_find_args+=(-o -name "*.${_ext}")
		fi
	done

	find "$_dir" \( "${_find_args[@]}" \) \
		-not -path '*/_archive/*' \
		-not -path '*/.git/*' 2>/dev/null | sort -u
	return 0
}

# ---------------------------------------------------------------------------
# _open_result_file <out-file>  — truncate or point to stdout
# Writes the chosen path to stdout so callers can capture it.
# ---------------------------------------------------------------------------
_open_result_file() {
	local _out="$1"
	if [ -n "$_out" ]; then
		: >"$_out"
		printf '%s' "$_out"
	else
		printf '/dev/stdout'
	fi
	return 0
}

# ---------------------------------------------------------------------------
# scan_dir_function_complexity <dir> [<out-file>]
#
# Shell functions >100 body lines. Output: <file>\t<fname>\t<lines>.
# Identity key: (file, fname). Originally t2159.
# ---------------------------------------------------------------------------
scan_dir_function_complexity() {
	local _dir="$1"
	local _out="${2:-}"

	local _sh_files
	_sh_files=$(_collect_files "$_dir" "sh")
	if [ -z "$_sh_files" ]; then
		log "WARN: no .sh files found in $_dir"
		[ -n "$_out" ] && : >"$_out"
		return 0
	fi

	local _result_file
	_result_file=$(_open_result_file "$_out")

	local _file _rel_file _awk_result
	while IFS= read -r _file; do
		[ -n "$_file" ] || continue
		_rel_file="${_file#"${_dir}/"}"
		# Matches code-quality.yml:391-404 AWK.
		# Detects top-level functions of the form:  name() {
		# and closes on a bare } line.
		_awk_result=$(awk -v relfile="$_rel_file" '
			/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ {
				fname = $1
				sub(/\(\)/, "", fname)
				start = NR
				next
			}
			fname && /^\}$/ {
				lines = NR - start
				if (lines > 100) {
					printf "%s\t%s\t%d\n", relfile, fname, lines
				}
				fname = ""
			}
		' "$_file" 2>/dev/null || true)

		if [ -n "$_awk_result" ]; then
			printf '%s\n' "$_awk_result" >>"$_result_file"
		fi
	done <<<"$_sh_files"

	return 0
}

# ---------------------------------------------------------------------------
# scan_dir_nesting_depth <dir> [<out-file>]
#
# Shell files with global max nesting depth >8. Output: <file>\tNEST\t<depth>.
# Identity key: (file, 'NEST'). (t2171)
#
# Uses the same global-counter AWK pattern as code-quality.yml:502-508 — it
# does NOT reset depth at function boundaries, matching the existing CI gate.
# ---------------------------------------------------------------------------
scan_dir_nesting_depth() {
	local _dir="$1"
	local _out="${2:-}"

	local _sh_files
	_sh_files=$(_collect_files "$_dir" "sh")
	if [ -z "$_sh_files" ]; then
		[ -n "$_out" ] && : >"$_out"
		return 0
	fi

	local _result_file
	_result_file=$(_open_result_file "$_out")

	local _file _rel_file _max_depth
	while IFS= read -r _file; do
		[ -n "$_file" ] || continue
		_rel_file="${_file#"${_dir}/"}"
		_max_depth=$(awk '
			BEGIN { depth=0; max_depth=0 }
			/^[[:space:]]*#/ { next }
			/[[:space:]]*(if|for|while|until|case)[[:space:]]/ { depth++; if(depth>max_depth) max_depth=depth }
			/[[:space:]]*(fi|done|esac)[[:space:]]*$/ || /^[[:space:]]*(fi|done|esac)$/ { if(depth>0) depth-- }
			END { print max_depth }
		' "$_file" 2>/dev/null || echo 0)

		if [ "${_max_depth:-0}" -gt 8 ] 2>/dev/null; then
			printf '%s\tNEST\t%s\n' "$_rel_file" "$_max_depth" >>"$_result_file"
		fi
	done <<<"$_sh_files"

	return 0
}

# ---------------------------------------------------------------------------
# scan_dir_file_size <dir> [<out-file>]
#
# .sh and .py files over 1500 lines. Output: <file>\tSIZE\t<lines>.
# Identity key: (file, 'SIZE'). (t2171)
# ---------------------------------------------------------------------------
scan_dir_file_size() {
	local _dir="$1"
	local _out="${2:-}"

	local _files
	_files=$(_collect_files "$_dir" "sh py")
	if [ -z "$_files" ]; then
		[ -n "$_out" ] && : >"$_out"
		return 0
	fi

	local _result_file
	_result_file=$(_open_result_file "$_out")

	local _file _rel_file _lc
	while IFS= read -r _file; do
		[ -n "$_file" ] || continue
		_rel_file="${_file#"${_dir}/"}"
		_lc=$(wc -l <"$_file" 2>/dev/null | tr -d ' ')
		if [ "${_lc:-0}" -gt 1500 ] 2>/dev/null; then
			printf '%s\tSIZE\t%s\n' "$_rel_file" "$_lc" >>"$_result_file"
		fi
	done <<<"$_files"

	return 0
}

# ---------------------------------------------------------------------------
# scan_dir_bash32_compat <dir> [<out-file>]
#
# Shell files containing bash 4+ constructs that break on macOS /bin/bash 3.2.
# Patterns (match code-quality.yml:141-188):
#   - backslash-tn:        "\t" or "\n" in += or = string assignments
#   - assoc-array:         declare/local/typeset -A
#   - nameref:             declare/local -n
#   - heredoc-in-subshell: $(cat <<...)
#
# Output: <file>\t<pattern>:<line>\t1  (one row per match).
# Identity key: (file, '<pattern>:<line>'). (t2171)
#
# Self-skip: linters-local.sh grep patterns contain the forbidden strings
# as search targets, not as bash code. This helper's own regex literals are
# also defused by escaping (Pattern 1's \\[tn] does not self-match, Pattern 4's
# \$\([[:space:]] doesn't line up with the source's escape form) but we skip
# this file explicitly as belt-and-braces against future edits that reformat
# the regex strings. See CodeRabbit review on PR #19592.
# ---------------------------------------------------------------------------
scan_dir_bash32_compat() {
	local _dir="$1"
	local _out="${2:-}"

	local _sh_files
	_sh_files=$(_collect_files "$_dir" "sh")
	if [ -z "$_sh_files" ]; then
		[ -n "$_out" ] && : >"$_out"
		return 0
	fi

	local _result_file
	_result_file=$(_open_result_file "$_out")

	local _file _rel_file _basename _matches _line_num
	# Files whose source contains the forbidden-construct strings as search
	# targets or regex literals, not as executable code.
	local _self_skip_patterns="linters-local.sh complexity-regression-helper.sh complexity-scan-helper.sh"
	while IFS= read -r _file; do
		[ -n "$_file" ] || continue
		_basename=$(basename "$_file")
		case " $_self_skip_patterns " in
		*" $_basename "*) continue ;;
		esac
		[ -f "$_file" ] || continue
		_rel_file="${_file#"${_dir}/"}"

		# Pattern 1: \t / \n in += or = assignments (excluding comments + contextual words)
		_matches=$(grep -nE '\+="\\[tn]|="\\[tn]' "$_file" 2>/dev/null |
			grep -vE '^[0-9]+:[[:space:]]*#' |
			grep -vE 'awk|sed|printf|echo.*-e|python|f\.write|gsub|join|split|print |replace|coords|excerpt|delimiter|regex|pattern' ||
			true)
		while IFS= read -r _match; do
			[ -n "$_match" ] || continue
			# Parameter expansion avoids spawning cut per-match.
			_line_num="${_match%%:*}"
			printf '%s\tbackslash-tn:%s\t1\n' "$_rel_file" "$_line_num" >>"$_result_file"
		done <<<"$_matches"

		# Pattern 2: Associative arrays (bash 4.0+)
		_matches=$(grep -nE '^[[:space:]]*(declare|local|typeset)[[:space:]]+-A[[:space:]]' "$_file" 2>/dev/null |
			grep -vE '^[0-9]+:[[:space:]]*#' || true)
		while IFS= read -r _match; do
			[ -n "$_match" ] || continue
			_line_num="${_match%%:*}"
			printf '%s\tassoc-array:%s\t1\n' "$_rel_file" "$_line_num" >>"$_result_file"
		done <<<"$_matches"

		# Pattern 3: Namerefs (bash 4.3+)
		_matches=$(grep -nE '^[[:space:]]*(declare|local)[[:space:]]+-n[[:space:]]' "$_file" 2>/dev/null |
			grep -vE '^[0-9]+:[[:space:]]*#' || true)
		while IFS= read -r _match; do
			[ -n "$_match" ] || continue
			_line_num="${_match%%:*}"
			printf '%s\tnameref:%s\t1\n' "$_rel_file" "$_line_num" >>"$_result_file"
		done <<<"$_matches"

		# Pattern 4: Heredoc inside $() — breaks macOS /bin/bash 3.2 parser.
		# (GH#19252, t2171 regression gate.)
		# POSIX [[:space:]] instead of \s — \s is GNU-only and fails silently
		# on BSD grep (macOS default). CI runs GNU grep, but pre-push and
		# local runs need to produce the same results.
		_matches=$(grep -nE '\$\([[:space:]]*cat[[:space:]]*<<' "$_file" 2>/dev/null |
			grep -vE '^[0-9]+:[[:space:]]*#' || true)
		while IFS= read -r _match; do
			[ -n "$_match" ] || continue
			_line_num="${_match%%:*}"
			printf '%s\theredoc-in-subshell:%s\t1\n' "$_rel_file" "$_line_num" >>"$_result_file"
		done <<<"$_matches"
	done <<<"$_sh_files"

	return 0
}

# ---------------------------------------------------------------------------
# scan_dir <dir> [<output-file>] [<metric>]
#
# Dispatcher: routes to the metric-specific scanner. Default metric is
# function-complexity (back-compat with t2159).
# ---------------------------------------------------------------------------
scan_dir() {
	local _dir="$1"
	local _out="${2:-}"
	local _metric="${3:-function-complexity}"

	case "$_metric" in
	function-complexity) scan_dir_function_complexity "$_dir" "$_out" ;;
	nesting-depth) scan_dir_nesting_depth "$_dir" "$_out" ;;
	file-size) scan_dir_file_size "$_dir" "$_out" ;;
	bash32-compat) scan_dir_bash32_compat "$_dir" "$_out" ;;
	*) die "unknown metric: $_metric (valid: function-complexity, nesting-depth, file-size, bash32-compat)" ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# metric_title <metric>  — human-readable label for reports/logs
# ---------------------------------------------------------------------------
metric_title() {
	case "$1" in
	function-complexity) printf 'Shell Function Complexity' ;;
	nesting-depth) printf 'Shell Nesting Depth' ;;
	file-size) printf 'File Size' ;;
	bash32-compat) printf 'Bash 3.2 Compatibility' ;;
	*) printf 'Complexity' ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# metric_unit <metric>  — "violations" plus short subject (for report text)
# ---------------------------------------------------------------------------
metric_unit() {
	case "$1" in
	function-complexity) printf 'function(s) >100 lines' ;;
	nesting-depth) printf 'file(s) with nesting depth >8' ;;
	file-size) printf 'file(s) >1500 lines' ;;
	bash32-compat) printf 'bash 3.2-incompatible construct(s)' ;;
	*) printf 'violation(s)' ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# metric_column_headers <metric>  — Markdown table headers for "new violations"
# Echoes a pipe-delimited header row the report can inject verbatim.
# ---------------------------------------------------------------------------
metric_column_headers() {
	case "$1" in
	function-complexity) printf '| File | Function | Lines |\n|---|---|---:|\n' ;;
	nesting-depth) printf '| File | Metric | Max Depth |\n|---|---|---:|\n' ;;
	file-size) printf '| File | Metric | Lines |\n|---|---|---:|\n' ;;
	bash32-compat) printf '| File | Pattern:Line | Count |\n|---|---|---:|\n' ;;
	*) printf '| File | Key | Value |\n|---|---|---:|\n' ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# violation_count <scan-file>  — count lines in a scan file
# ---------------------------------------------------------------------------
violation_count() {
	local _f="$1"
	if [ ! -s "$_f" ]; then
		printf '0'
		return 0
	fi
	wc -l <"$_f" | tr -d ' '
	return 0
}

# ---------------------------------------------------------------------------
# compute_new_violations <base-file> <head-file> <out-file>
#
# Writes to <out-file> the violations in head that are NOT in base.
# Identity key: <relative-file>\t<function-name>  (ignores line count).
# ---------------------------------------------------------------------------
compute_new_violations() {
	local _base="$1"
	local _head="$2"
	local _out="$3"
	: >"$_out"

	# Build a set of "file\tname" keys from base.
	local _base_keys
	_base_keys=$(awk -F '\t' '{print $1"\t"$2}' "$_base" 2>/dev/null | sort -u || true)

	# For each head violation, check if its key exists in base.
	while IFS= read -r _line; do
		[ -n "$_line" ] || continue
		local _key
		_key=$(printf '%s' "$_line" | awk -F '\t' '{print $1"\t"$2}')
		if ! printf '%s\n' "$_base_keys" | grep -qxF "$_key"; then
			printf '%s\n' "$_line" >>"$_out"
		fi
	done <"$_head"

	return 0
}

# ---------------------------------------------------------------------------
# write_report <new-count> <base-total> <head-total>
#              <new-violations-file> <base-sha> <head-sha> <out-md> [<metric>]
#
# Produces a metric-aware markdown report. The marker comment at the end is
# metric-specific so the CI workflow can upsert the correct PR comment per
# metric without the four gates stomping on each other's reports.
# ---------------------------------------------------------------------------
write_report() {
	local _new_count="$1"
	local _base_total="$2"
	local _head_total="$3"
	local _new_file="$4"
	local _base_sha="$5"
	local _head_sha="$6"
	local _out="$7"
	local _metric="${8:-function-complexity}"

	local _title _unit _headers
	_title=$(metric_title "$_metric")
	_unit=$(metric_unit "$_metric")
	_headers=$(metric_column_headers "$_metric")

	local _verdict
	if [ "$_new_count" -gt 0 ]; then
		_verdict="❌ **Regression** — this PR introduces $_new_count NEW ${_unit}."
	else
		_verdict="✅ **No regression** — no new ${_unit}."
	fi

	{
		printf '## %s Regression Gate\n\n' "$_title"
		printf '%s\n\n' "$_verdict"
		# shellcheck disable=SC2016
		printf '| Metric | Base (`%s`) | Head (`%s`) |\n' \
			"${_base_sha:0:7}" "${_head_sha:0:7}"
		printf '|---|---:|---:|\n'
		printf '| Total %s | %s | %s |\n\n' \
			"$_unit" "$_base_total" "$_head_total"

		if [ "$_new_count" -gt 0 ]; then
			printf '### New violations\n\n'
			printf '%s' "$_headers"
			while IFS=$'\t' read -r _col1 _col2 _col3; do
				[ -n "$_col1" ] || continue
				# shellcheck disable=SC2016
				printf '| `%s` | `%s` | %s |\n' "$_col1" "$_col2" "$_col3"
			done <"$_new_file"
			printf '\n'
			# shellcheck disable=SC2016
			printf '> To override (with justification), add the `complexity-bump-ok` label to this PR\n'
			# shellcheck disable=SC2016
			printf '> and include a `## Complexity Bump Justification` section in the PR description.\n'
		fi

		# Metric-specific marker so the workflow can upsert independently per metric.
		printf '\n<!-- complexity-regression-gate:%s -->\n' "$_metric"
	} >"$_out"

	return 0
}

# ===========================================================================
# Subcommand: scan
# ===========================================================================
cmd_scan() {
	local _dir=""
	local _out=""
	local _metric="function-complexity"

	while [ $# -gt 0 ]; do
		case "$1" in
		--output)
			[ $# -ge 2 ] || die "missing value for --output"
			_out="$2"
			shift 2
			;;
		--metric)
			[ $# -ge 2 ] || die "missing value for --metric"
			_metric="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			if [ -z "$_dir" ]; then
				_dir="$1"
				shift
			else
				die "unexpected argument: $1"
			fi
			;;
		esac
	done

	[ -n "$_dir" ] || die "scan: <dir> argument required"
	[ -d "$_dir" ] || die "scan: directory not found: $_dir"

	scan_dir "$_dir" "$_out" "$_metric"
	return 0
}

# ===========================================================================
# Subcommand: diff
# ===========================================================================
cmd_diff() {
	local _base_file=""
	local _head_file=""
	local _output_md=""
	local _base_sha="unknown"
	local _head_sha="unknown"
	local _metric="function-complexity"

	while [ $# -gt 0 ]; do
		case "$1" in
		--base-file)
			[ $# -ge 2 ] || die "missing value for --base-file"
			_base_file="$2"
			shift 2
			;;
		--head-file)
			[ $# -ge 2 ] || die "missing value for --head-file"
			_head_file="$2"
			shift 2
			;;
		--output-md)
			[ $# -ge 2 ] || die "missing value for --output-md"
			_output_md="$2"
			shift 2
			;;
		--base-sha)
			[ $# -ge 2 ] || die "missing value for --base-sha"
			_base_sha="$2"
			shift 2
			;;
		--head-sha)
			[ $# -ge 2 ] || die "missing value for --head-sha"
			_head_sha="$2"
			shift 2
			;;
		--metric)
			[ $# -ge 2 ] || die "missing value for --metric"
			_metric="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*) die "diff: unknown argument: $1" ;;
		esac
	done

	[ -n "$_base_file" ] || die "diff: --base-file is required"
	[ -n "$_head_file" ] || die "diff: --head-file is required"
	[ -f "$_base_file" ] || die "diff: base-file not found: $_base_file"
	[ -f "$_head_file" ] || die "diff: head-file not found: $_head_file"

	TMP_DIR=$(mktemp -d)
	local _new_file="$TMP_DIR/new-violations.tsv"

	compute_new_violations "$_base_file" "$_head_file" "$_new_file"

	local _new_count _base_total _head_total
	_new_count=$(violation_count "$_new_file")
	_base_total=$(violation_count "$_base_file")
	_head_total=$(violation_count "$_head_file")

	log "[$_metric] base: $_base_total  head: $_head_total  new: $_new_count"

	if [ -n "$_output_md" ]; then
		write_report "$_new_count" "$_base_total" "$_head_total" \
			"$_new_file" "$_base_sha" "$_head_sha" "$_output_md" "$_metric"
		log "report written to $_output_md"
	fi

	if [ "$_new_count" -gt 0 ]; then
		printf 'NEW violations: %s\n' "$_new_count"
		exit 1
	fi

	printf 'No new violations\n'
	exit 0
}

# ---------------------------------------------------------------------------
# _check_dry_run <metric> — scan current tree, report total count, exit 0 always
# ---------------------------------------------------------------------------
_check_dry_run() {
	local _metric="${1:-function-complexity}"
	TMP_DIR=$(mktemp -d)
	local _head_scan="$TMP_DIR/head.tsv"
	log "[$_metric] dry-run: scanning current tree"
	scan_dir "." "$_head_scan" "$_metric"
	local _count _unit
	_count=$(violation_count "$_head_scan")
	_unit=$(metric_unit "$_metric")
	printf 'Total violations (%s): %s\n' "$_unit" "$_count"
	if [ "$_count" -gt 0 ]; then
		printf '\nViolations:\n'
		cat "$_head_scan"
	fi
	exit 0
}

# ---------------------------------------------------------------------------
# _check_regression <base_sha> <head_sha> <output_md> <allow_increase> [<metric>]
# Scan base+head via worktrees, compute diff, optionally write report.
# Exits 0 (no regression), 1 (regression), or 2 (error).
# ---------------------------------------------------------------------------
_check_regression() {
	local _base_sha="$1"
	local _head_sha="$2"
	local _output_md="$3"
	local _allow_increase="$4"
	local _metric="${5:-function-complexity}"

	TMP_DIR=$(mktemp -d)
	local _base_scan="$TMP_DIR/base.tsv"
	local _head_scan="$TMP_DIR/head.tsv"
	local _new_file="$TMP_DIR/new-violations.tsv"

	BASE_WORKTREE="$TMP_DIR/base-worktree"
	log "[$_metric] creating base worktree at ${_base_sha:0:7}"
	if ! git worktree add --detach --force "$BASE_WORKTREE" "$_base_sha" >/dev/null 2>&1; then
		die "failed to create base worktree for $_base_sha"
	fi
	log "[$_metric] scanning base (${_base_sha:0:7})"
	scan_dir "$BASE_WORKTREE" "$_base_scan" "$_metric"

	HEAD_WORKTREE="$TMP_DIR/head-worktree"
	log "[$_metric] creating head worktree at ${_head_sha:0:7}"
	if ! git worktree add --detach --force "$HEAD_WORKTREE" "$_head_sha" >/dev/null 2>&1; then
		die "failed to create head worktree for $_head_sha"
	fi
	log "[$_metric] scanning head (${_head_sha:0:7})"
	scan_dir "$HEAD_WORKTREE" "$_head_scan" "$_metric"

	compute_new_violations "$_base_scan" "$_head_scan" "$_new_file"

	local _new_count _base_total _head_total
	_new_count=$(violation_count "$_new_file")
	_base_total=$(violation_count "$_base_scan")
	_head_total=$(violation_count "$_head_scan")

	log "[$_metric] base: $_base_total  head: $_head_total  new: $_new_count"

	if [ -n "$_output_md" ]; then
		write_report "$_new_count" "$_base_total" "$_head_total" \
			"$_new_file" "$_base_sha" "$_head_sha" "$_output_md" "$_metric"
		log "report written to $_output_md"
	fi

	if [ "$_new_count" -gt 0 ] && [ "$_allow_increase" -eq 0 ]; then
		log "[$_metric] REGRESSION: $_new_count new violation(s)"
		exit 1
	fi

	if [ "$_new_count" -gt 0 ]; then
		log "[$_metric] new violations detected but --allow-increase is set"
	else
		log "[$_metric] no new violations"
	fi
	exit 0
}

# ===========================================================================
# Subcommand: check
# ===========================================================================
cmd_check() {
	local _base=""
	local _head="HEAD"
	local _output_md=""
	local _allow_increase=0
	local _dry_run=0
	local _metric="function-complexity"

	while [ $# -gt 0 ]; do
		case "$1" in
		--base)
			[ $# -ge 2 ] || die "missing value for --base"
			_base="$2"
			shift 2
			;;
		--head)
			[ $# -ge 2 ] || die "missing value for --head"
			_head="$2"
			shift 2
			;;
		--output-md)
			[ $# -ge 2 ] || die "missing value for --output-md"
			_output_md="$2"
			shift 2
			;;
		--allow-increase)
			_allow_increase=1
			shift
			;;
		--dry-run)
			_dry_run=1
			shift
			;;
		--metric)
			[ $# -ge 2 ] || die "missing value for --metric"
			_metric="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*) die "check: unknown argument: $1" ;;
		esac
	done

	[ "$_dry_run" -eq 1 ] && _check_dry_run "$_metric"

	[ -n "$_base" ] || die "check: --base <sha> is required (use --dry-run to scan current tree)"

	if ! git rev-parse --verify --quiet "${_base}^{commit}" >/dev/null; then
		die "check: base ref not found in repo: $_base"
	fi
	if ! git rev-parse --verify --quiet "${_head}^{commit}" >/dev/null; then
		die "check: head ref not found in repo: $_head"
	fi

	local _base_sha _head_sha
	_base_sha=$(git rev-parse "$_base")
	_head_sha=$(git rev-parse "$_head")

	_check_regression "$_base_sha" "$_head_sha" "$_output_md" "$_allow_increase" "$_metric"
}

# ===========================================================================
# Dispatch
# ===========================================================================

[ $# -ge 1 ] || {
	usage
	exit 2
}

_SUBCOMMAND="$1"
shift

case "$_SUBCOMMAND" in
scan) cmd_scan "$@" ;;
diff) cmd_diff "$@" ;;
check) cmd_check "$@" ;;
-h | --help)
	usage
	exit 0
	;;
*) die "unknown subcommand: $_SUBCOMMAND (valid: scan, diff, check)" ;;
esac
