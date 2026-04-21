#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# empty-compare-scanner.sh — detect empty-compare foot-gun in bash scripts (t2570)
#
# Root cause: when a variable is derived from command substitution ($(...)) or
# backticks and later used in an equality/inequality comparison without a prior
# non-empty guard, the comparison silently inverts when the derived value is "".
#
# Example foot-gun (t2559 / canonical-trash incident 2026-04-20):
#   _porcelain=$(git worktree list --porcelain)
#   main_wt="${_porcelain%%$'\n'*}"
#   [[ "$worktree_path" != "$main_wt" ]]   # BUG: always true when main_wt=""
#
# Safe pattern:
#   _porcelain=$(git worktree list --porcelain)
#   if [[ -z "$_porcelain" ]]; then return 1; fi   # guard
#   main_wt="${_porcelain%%$'\n'*}"
#   [[ "$worktree_path" != "$main_wt" ]]            # safe: guard exists
#
# Subcommands:
#   scan  <dir> [--output <file>] [--output-md <file>]
#         Walk .sh files under <dir> and emit tab-separated violations:
#           <relative-file>\t<function>\t<assign_line>\t<compare_line>\t<pattern>
#
#   check --base <sha> [--head <sha>] [--output-md <file>] [--dry-run]
#         Ratchet-based regression check: baseline violation count at <base>,
#         compare to HEAD. Exits 1 only if new violations introduced.
#
# Inline allowlist: add  # scan:empty-compare-ok  to the comparison line.
# File allowlist:   .agents/configs/empty-compare-allowlist.txt (one glob/line).
# Emergency bypass: AIDEVOPS_EMPTY_COMPARE_SKIP=1
#
# Exit codes:
#   0 — no new violations (or dry-run / bypass)
#   1 — new violations detected
#   2 — invocation or environment error

set -uo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
	sed -n '4,37p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# ---------------------------------------------------------------------------
# _collect_sh_files <dir>
# Emit newline-separated absolute paths of tracked .sh files under <dir>.
# Uses git ls-files for CI parity; falls back to find for non-git dirs.
# ---------------------------------------------------------------------------
_collect_sh_files() {
	local _dir="$1"
	local _output=""

	if git -C "$_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		_output=$(git -C "$_dir" ls-files "*.sh" 2>/dev/null |
			grep -Ev '_archive/' || true)
		if [ -n "$_output" ]; then
			printf '%s\n' "$_output" | awk -v d="$_dir" 'NF{print d "/" $0}' | sort -u
			return 0
		fi
	fi

	find "$_dir" -name "*.sh" \
		-not -path '*/_archive/*' \
		-not -path '*/.git/*' 2>/dev/null | sort -u
	return 0
}

# ---------------------------------------------------------------------------
# _is_allowlisted <rel_file> <allowlist_file>
# Returns 0 if <rel_file> matches any pattern in <allowlist_file>.
# ---------------------------------------------------------------------------
_is_allowlisted() {
	local _rel="$1"
	local _alist="$2"

	[ -f "$_alist" ] || return 1

	local _pattern
	while IFS= read -r _pattern; do
		# Skip blank lines and comments
		[[ -z "$_pattern" || "$_pattern" == "#"* ]] && continue
		# shellcheck disable=SC2254
		case "$_rel" in
		$_pattern) return 0 ;;
		esac
	done <"$_alist"
	return 1
}

# ---------------------------------------------------------------------------
# _scan_file_empty_compare <abs_file> <rel_file> [<allowlist_file>]
#
# Core detection: for each top-level function in <abs_file>, detect variables
# assigned from command substitution ($(...) or backticks) that appear in a
# != or == comparison without a prior -z / -n guard in the same function scope.
#
# Output (tab-separated, to stdout):
#   <rel_file>\t<function>\t<assign_line>\t<compare_line>\tderived-empty-compare
# ---------------------------------------------------------------------------
_scan_file_empty_compare() {
	local _file="$1"
	local _rel_file="$2"
	local _alist="${3:-}"

	# File-level allowlist check
	if [ -n "$_alist" ] && _is_allowlisted "$_rel_file" "$_alist"; then
		return 0
	fi

	# Single-pass AWK: track function boundaries, derived assignments,
	# guards, and comparisons. Report unguarded compares at function end.
	#
	# POSIX awk compatible (no gawk extensions). Variable extraction uses
	# substr+index rather than match() capture groups.
	awk -v relfile="$_rel_file" '
	BEGIN {
		in_func = 0
		func_name = ""
		n_d = 0; n_g = 0; n_c = 0
	}

	# ------------------------------------------------------------
	# Function start: name() {   (top-level only, no leading spaces)
	# ------------------------------------------------------------
	!in_func && /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{[[:space:]]*$/ {
		# Extract function name from full line (avoid AWK field $1 for hook compat)
		func_name = $0
		sub(/\(\).*/, "", func_name)
		in_func = 1
		n_d = 0; n_g = 0; n_c = 0
		# Clear arrays by resetting counters — reuse numeric keys
		next
	}

	# Also handle: function name() {
	!in_func && /^function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)[[:space:]]*\{[[:space:]]*$/ {
		# Extract function name: strip leading "function " then trailing "() {"
		func_name = $0
		sub(/^function[[:space:]]+/, "", func_name)
		sub(/\(\).*/, "", func_name)
		in_func = 1
		n_d = 0; n_g = 0; n_c = 0
		next
	}

	# ------------------------------------------------------------
	# Function end: bare }
	# ------------------------------------------------------------
	in_func && /^\}$/ {
		# For each comparison, check if any derived var is unguarded
		for (ci = 1; ci <= n_c; ci++) {
			if (callow[ci]) continue  # inline allowlist

			# Each comparison stores potentially multiple $VARs
			# split them on space since we store them space-joined
			n_cvars = split(cvar[ci], cvars, " ")
			for (cvi = 1; cvi <= n_cvars; cvi++) {
				cv = cvars[cvi]
				cl = cline[ci]

				# Find matching derived assignment before this compare
				for (di = 1; di <= n_d; di++) {
					if (dvar[di] != cv) continue
					dl = dline[di]
					if (cl <= dl) continue  # compare before assignment

					# Check for guard between assignment and compare
					guarded = 0
					for (gi = 1; gi <= n_g; gi++) {
						if (gvar[gi] == cv && gline[gi] > dl && gline[gi] < cl) {
							guarded = 1
							break
						}
					}
					if (!guarded) {
						printf "%s\t%s\t%d\t%d\tderived-empty-compare\n",
							relfile, func_name, dl, cl
					}
				}
			}
		}

		in_func = 0
		func_name = ""
		n_d = 0; n_g = 0; n_c = 0
		next
	}

	# ------------------------------------------------------------
	# Inside function body
	# ------------------------------------------------------------
	in_func {
		line = $0

		# Skip comment lines
		stripped = line
		gsub(/^[[:space:]]+/, "", stripped)
		if (substr(stripped, 1, 1) == "#") next

		# ----------------------------------------------------------
		# Derived variable assignment:
		#   [local] varname=$(...)     command substitution
		#   [local] varname=`...`      backtick substitution
		#   [local] varname="${..."    parameter expansion (can be empty
		#                              when the source variable is empty)
		# ----------------------------------------------------------
		if (line ~ /^[[:space:]]*(local[[:space:]]+)?[a-zA-Z_][a-zA-Z0-9_]*=\$\(/ ||
		    line ~ /^[[:space:]]*(local[[:space:]]+)?[a-zA-Z_][a-zA-Z0-9_]*=`/ ||
		    line ~ /^[[:space:]]*(local[[:space:]]+)?[a-zA-Z_][a-zA-Z0-9_]*="\$\{/) {

			tmp = line
			# Strip leading whitespace and optional local keyword
			gsub(/^[[:space:]]*(local[[:space:]]+)?/, "", tmp)
			# Find = position
			eq_pos = index(tmp, "=")
			if (eq_pos > 1) {
				varname = substr(tmp, 1, eq_pos - 1)
				rest = substr(tmp, eq_pos + 1)
				# Verify RHS starts with $(, `, or "${
				if (rest ~ /^\$\(/ || rest ~ /^`/ || rest ~ /^"\$\{/) {
					# Verify varname is a valid identifier
					if (varname ~ /^[a-zA-Z_][a-zA-Z0-9_]*$/) {
						n_d++
						dvar[n_d] = varname
						dline[n_d] = NR
					}
				}
			}
		}

		# ----------------------------------------------------------
		# Guard patterns (non-empty assertions):
		#   [[ -z "$var" ]]   (empty check — signals intent to guard)
		#   [[ -n "$var" ]]   (non-empty check — negated guard)
		#   : "${var:?...}"   (error-on-empty)
		# We record the variable as guarded regardless of the exact
		# branch structure; presence of any check is sufficient.
		# ----------------------------------------------------------

		# -z check: [[ -z "$var" ]] or [ -z "$var" ]
		if (line ~ /-z[[:space:]]+"?\$[a-zA-Z_]/ || line ~ /-z[[:space:]]+\$[a-zA-Z_]/) {
			tmp = line
			# Find -z and extract what follows
			idx = index(tmp, "-z ")
			if (idx > 0) {
				rest = substr(tmp, idx + 3)
				# Strip optional quote and $
				if (substr(rest, 1, 1) == "\"") rest = substr(rest, 2)
				if (substr(rest, 1, 1) == "$") rest = substr(rest, 2)
				if (substr(rest, 1, 2) == "{!") { rest = "" }  # indirect — skip
				# Strip to end of varname
				gsub(/[^a-zA-Z0-9_].*/, "", rest)
				if (rest ~ /^[a-zA-Z_][a-zA-Z0-9_]*$/) {
					n_g++
					gvar[n_g] = rest
					gline[n_g] = NR
				}
			}
		}

		# -n check: [[ -n "$var" ]] (non-empty assertion is also a guard)
		if (line ~ /-n[[:space:]]+"?\$[a-zA-Z_]/ || line ~ /-n[[:space:]]+\$[a-zA-Z_]/) {
			tmp = line
			idx = index(tmp, "-n ")
			if (idx > 0) {
				rest = substr(tmp, idx + 3)
				if (substr(rest, 1, 1) == "\"") rest = substr(rest, 2)
				if (substr(rest, 1, 1) == "$") rest = substr(rest, 2)
				if (substr(rest, 1, 2) == "{!") { rest = "" }
				gsub(/[^a-zA-Z0-9_].*/, "", rest)
				if (rest ~ /^[a-zA-Z_][a-zA-Z0-9_]*$/) {
					n_g++
					gvar[n_g] = rest
					gline[n_g] = NR
				}
			}
		}

		# : "${var:?...}" error-on-empty guard
		if (line ~ /:[[:space:]]+"?\$\{[a-zA-Z_][a-zA-Z0-9_]*:?/) {
			tmp = line
			idx = index(tmp, "${")
			if (idx > 0) {
				rest = substr(tmp, idx + 2)
				gsub(/[:}?].*/, "", rest)
				if (rest ~ /^[a-zA-Z_][a-zA-Z0-9_]*$/) {
					n_g++
					gvar[n_g] = rest
					gline[n_g] = NR
				}
			}
		}

		# ----------------------------------------------------------
		# Comparison patterns using != or ==
		# [[ "$var" != ... ]]  [[ ... != "$var" ]]
		# [ "$var" != ... ]    (POSIX form)
		# ----------------------------------------------------------
		if (line ~ /[!]=/ && (line ~ /\[\[/ || line ~ /\[[[:space:]]/)) {
			# Check for inline allowlist comment
			allowed = (line ~ /# scan:empty-compare-ok/)

			# Collect all $VARNAME references in this line
			vars_found = ""
			tmp = line
			# Iteratively find $VAR patterns using match(RSTART/RLENGTH)
			# POSIX awk: match() sets RSTART and RLENGTH
			while (match(tmp, /\$[a-zA-Z_][a-zA-Z0-9_]*/)) {
				varname = substr(tmp, RSTART + 1, RLENGTH - 1)
				# Exclude $? $# $0-$9 (RSTART+1 index into tmp, RLENGTH-1 chars)
				if (varname ~ /^[a-zA-Z_][a-zA-Z0-9_]*$/ && length(varname) > 0) {
					if (vars_found == "") {
						vars_found = varname
					} else {
						vars_found = vars_found " " varname
					}
				}
				tmp = substr(tmp, RSTART + RLENGTH)
			}

			if (vars_found != "") {
				n_c++
				cvar[n_c] = vars_found
				cline[n_c] = NR
				callow[n_c] = allowed
			}
		}
	}
	' "$_file" 2>/dev/null || true
	return 0
}

# ---------------------------------------------------------------------------
# cmd_scan <dir> [options]
#
# Walk all .sh files under <dir>, run _scan_file_empty_compare on each,
# collect results. Options:
#   --output <file>     write tab-separated results to <file> (default: stdout)
#   --output-md <file>  write markdown summary to <file>
# ---------------------------------------------------------------------------
cmd_scan() {
	local _dir=""
	local _out=""
	local _out_md=""

	while [[ $# -gt 0 ]]; do
		case "${1:-}" in
		--output) _out="${2:-}"; shift 2 ;;
		--output-md) _out_md="${2:-}"; shift 2 ;;
		-*) die "unknown option: ${1:-}" ;;
		*) _dir="${1:-}"; shift ;;
		esac
	done

	[ -n "$_dir" ] || die "scan requires a directory argument"
	[ -d "$_dir" ] || die "directory not found: $_dir"

	_dir="$(cd "$_dir" && pwd)"

	local _alist="${SCRIPT_DIR}/../configs/empty-compare-allowlist.txt"
	[ -f "$_alist" ] || _alist=""

	local _sh_files
	_sh_files=$(_collect_sh_files "$_dir")

	if [ -z "$_sh_files" ]; then
		log "WARN: no .sh files found in $_dir"
		[ -n "$_out" ] && : >"$_out"
		return 0
	fi

	TMP_DIR=$(mktemp -d -t empty-compare-scan.XXXXXX)
	local _tmp_results="${TMP_DIR}/results.tsv"
	: >"$_tmp_results"

	local _file _rel_file
	while IFS= read -r _file; do
		[ -n "$_file" ] || continue
		[ -f "$_file" ] || continue
		_rel_file="${_file#"${_dir}/"}"

		local _file_results
		_file_results=$(_scan_file_empty_compare "$_file" "$_rel_file" "${_alist:-}")
		if [ -n "$_file_results" ]; then
			printf '%s\n' "$_file_results" >>"$_tmp_results"
		fi
	done <<<"$_sh_files"

	# Deduplicate (same file+function+lines may appear from multiple var refs)
	sort -u "$_tmp_results" >"${TMP_DIR}/results_deduped.tsv"

	# Output results
	if [ -n "$_out" ]; then
		cp "${TMP_DIR}/results_deduped.tsv" "$_out"
	else
		cat "${TMP_DIR}/results_deduped.tsv"
	fi

	# Markdown report
	if [ -n "$_out_md" ]; then
		_write_scan_report "${TMP_DIR}/results_deduped.tsv" "$_out_md"
	fi

	return 0
}

# ---------------------------------------------------------------------------
# _write_scan_report <tsv_file> <md_out_file>
# Produce a markdown summary of scan results.
# ---------------------------------------------------------------------------
_write_scan_report() {
	local _tsv="$1"
	local _md="$2"

	local _count=0
	if [ -s "$_tsv" ]; then
		_count=$(wc -l <"$_tsv" | tr -d ' ')
	fi

	{
		printf '## Empty-Compare Scan Results\n\n'
		if [ "$_count" -eq 0 ]; then
			printf '_No empty-compare violations detected._\n'
		else
			# shellcheck disable=SC2016
			printf '**%d violation(s) detected** — derived variables used in `!=`/`==` comparisons without a prior non-empty guard.\n\n' "$_count"
			printf '| File | Function | Assignment Line | Compare Line | Pattern |\n'
			printf '|------|----------|----------------:|-------------:|---------|\n'
			if [ -s "$_tsv" ]; then
				awk -F '\t' '{printf "| `%s` | `%s` | %s | %s | `%s` |\n", $1, $2, $3, $4, $5}' "$_tsv"
			fi
			printf '\n'
			# shellcheck disable=SC2016
			printf '**Remediation**: add `[[ -z "$var" ]] && return 1` (or equivalent guard) between the derived assignment and the comparison. Or add `# scan:empty-compare-ok` on the compare line if the pattern is intentional.\n'
			printf '\n'
			# shellcheck disable=SC2016
			printf '**Inline allowlist**: `# scan:empty-compare-ok` on the comparison line.\n'
			# shellcheck disable=SC2016
			printf '**File allowlist**: `.agents/configs/empty-compare-allowlist.txt`\n'
		fi
		printf '\n<!-- empty-compare-scan-report -->\n'
	} >"$_md"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_check [options]
#
# Ratchet-based regression check. Scans at --base sha and HEAD,
# reports new violations. Exits 1 only on regressions.
#
# Options:
#   --base <sha>       (required) base commit sha or ref
#   --head <sha>       head commit sha (default: working tree)
#   --output-md <file> write markdown report to <file>
#   --dry-run          scan and report, always exit 0
# ---------------------------------------------------------------------------
cmd_check() {
	local _base_sha=""
	local _head_sha="HEAD"
	local _out_md=""
	local _dry_run=0

	while [[ $# -gt 0 ]]; do
		case "${1:-}" in
		--base) _base_sha="${2:-}"; shift 2 ;;
		--head) _head_sha="${2:-}"; shift 2 ;;
		--output-md) _out_md="${2:-}"; shift 2 ;;
		--dry-run) _dry_run=1; shift ;;
		*) die "unknown option: ${1:-}" ;;
		esac
	done

	[ -n "$_base_sha" ] || die "check requires --base <sha>"

	TMP_DIR=$(mktemp -d -t empty-compare-check.XXXXXX)

	local _repo_root
	_repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not in a git repository"

	local _agents_dir="${_repo_root}/.agents"
	[ -d "$_agents_dir" ] || _agents_dir="$_repo_root"

	local _alist="${SCRIPT_DIR}/../configs/empty-compare-allowlist.txt"
	[ -f "$_alist" ] || _alist=""

	# Scan HEAD (working tree)
	local _head_results="${TMP_DIR}/head.tsv"
	cmd_scan "$_agents_dir" --output "$_head_results" >/dev/null

	# Scan base via git show-ref + temp worktree
	local _base_results="${TMP_DIR}/base.tsv"
	local _base_wt="${TMP_DIR}/base-wt"

	if git worktree add --quiet "$_base_wt" "$_base_sha" >/dev/null 2>&1; then
		local _base_agents="${_base_wt}/.agents"
		[ -d "$_base_agents" ] || _base_agents="$_base_wt"
		cmd_scan "$_base_agents" --output "$_base_results" >/dev/null
		git worktree remove --force "$_base_wt" >/dev/null 2>&1 || true
	else
		log "WARN: could not create base worktree for $_base_sha; using empty baseline"
		: >"$_base_results"
	fi

	# Compute new violations: in head but not in base (by file+function+lines key)
	local _new_results="${TMP_DIR}/new.tsv"
	: >"$_new_results"

	if [ -s "$_head_results" ]; then
		local _base_keys=""
		_base_keys=$(awk -F '\t' '{print $1"\t"$2"\t"$3"\t"$4}' "$_base_results" 2>/dev/null | sort -u || true)

		while IFS= read -r _line; do
			[ -n "$_line" ] || continue
			local _key
			_key=$(printf '%s' "$_line" | awk -F '\t' '{print $1"\t"$2"\t"$3"\t"$4}')
			if ! printf '%s\n' "$_base_keys" | grep -qxF "$_key"; then
				printf '%s\n' "$_line" >>"$_new_results"
			fi
		done <"$_head_results"
	fi

	local _head_count=0
	local _base_count=0
	local _new_count=0
	[ -s "$_head_results" ] && _head_count=$(wc -l <"$_head_results" | tr -d ' ')
	[ -s "$_base_results" ] && _base_count=$(wc -l <"$_base_results" | tr -d ' ')
	[ -s "$_new_results" ] && _new_count=$(wc -l <"$_new_results" | tr -d ' ')

	log "Violations: base=${_base_count} head=${_head_count} new=${_new_count}"

	if [ -n "$_out_md" ]; then
		{
			printf '## Empty-Compare Regression Check\n\n'
			printf '| Metric | Count |\n|--------|------:|\n'
			printf '| Base violations | %s |\n' "$_base_count"
			printf '| Head violations | %s |\n' "$_head_count"
			printf '| **New violations** | **%s** |\n\n' "$_new_count"

			if [ "$_new_count" -gt 0 ]; then
				printf '### New violations\n\n'
				printf '| File | Function | Assignment Line | Compare Line |\n'
				printf '|------|----------|----------------:|-------------:|\n'
				awk -F '\t' '{printf "| `%s` | `%s` | %s | %s |\n", $1, $2, $3, $4}' "$_new_results"
				printf '\n'
				# shellcheck disable=SC2016
				printf '**Action**: add a non-empty guard (e.g. `[[ -z "$var" ]] && return 1`) between the assignment and comparison, or add `# scan:empty-compare-ok` if intentional.\n'
			else
				printf '_No new empty-compare violations introduced by this PR._\n'
			fi
			printf '\n<!-- empty-compare-regression-report -->\n'
		} >"$_out_md"
	fi

	if [ "$_new_count" -gt 0 ] && [ "$_dry_run" -eq 0 ]; then
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
main() {
	# Emergency bypass
	if [ "${AIDEVOPS_EMPTY_COMPARE_SKIP:-0}" = "1" ]; then
		log "AIDEVOPS_EMPTY_COMPARE_SKIP=1 — skipping scan"
		return 0
	fi

	local _cmd="${1:-}"
	shift 2>/dev/null || true

	case "$_cmd" in
	scan)   cmd_scan "$@" ;;
	check)  cmd_check "$@" ;;
	help|--help|-h) usage ;;
	"")     usage; exit 2 ;;
	*) die "unknown subcommand: $_cmd (valid: scan, check)" ;;
	esac
	return 0
}

main "$@"
