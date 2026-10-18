#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# git-ref-snapshot-lib.sh — write selected files of a commit into a plain
# directory without `git worktree add` (GH#34905).
#
# Sourced by read-only regression scanners (complexity-regression-helper.sh,
# markdownlint-diff-helper.sh). A snapshot is an unregistered directory, so an
# interrupted, timed-out or SIGKILLed scan can never leave a registered
# worktree behind; removing the caller's temp directory is the whole cleanup.
#
# Public functions:
#   _materialize_ref_paths <commit> <dest> <paths>  — selected files only
#   _materialize_ref_tree  <commit> <dest>          — whole tree, checkout-equivalent
#   _nul_paths_to_lines                             — NUL list on stdin → raw lines
# Callers must pass a fresh <dest> inside a private temporary directory.

[[ -n "${_GIT_REF_SNAPSHOT_LIB_LOADED:-}" ]] && return 0
_GIT_REF_SNAPSHOT_LIB_LOADED=1

# ---------------------------------------------------------------------------
# _nul_paths_to_lines
#
# Read NUL-delimited paths (`git diff --name-only -z`, `git ls-files -z`) on
# stdin and print each raw, unquoted, on its own line (GH#34943). Git's
# newline-delimited output C-quotes names containing tabs, double quotes,
# backslashes or control characters; a quoted name matches no literal
# pathspec and silently drops out of a scan. A path containing a newline
# cannot be represented in the line-oriented lists scanners use, so it is
# reported on stderr and skipped rather than split into two bogus paths.
# ---------------------------------------------------------------------------
_nul_paths_to_lines() {
	local _p=""
	local _nl='
'
	while IFS= read -r -d '' _p; do
		[ -n "$_p" ] || continue
		case "$_p" in
		*"$_nl"*)
			printf '[git-ref-snapshot] WARN: skipping path containing a newline: %q\n' "$_p" >&2
			continue
			;;
		esac
		printf '%s\n' "$_p"
	done
	return 0
}

# ---------------------------------------------------------------------------
# _normalize_rel_path <path>
#
# Print <path> with '.', empty and '..' components resolved. Fails when the
# result is empty or would escape the repository root.
# ---------------------------------------------------------------------------
_normalize_rel_path() {
	local _rest="$1/"
	local _out="" _part=""
	while [ -n "$_rest" ]; do
		_part="${_rest%%/*}"
		_rest="${_rest#*/}"
		case "$_part" in
		"" | .) ;;
		..)
			[ -n "$_out" ] || return 1
			case "$_out" in
			*/*) _out="${_out%/*}" ;;
			*) _out="" ;;
			esac
			;;
		*) _out="${_out:+${_out}/}${_part}" ;;
		esac
	done
	[ -n "$_out" ] || return 1
	printf '%s\n' "$_out"
	return 0
}

# ---------------------------------------------------------------------------
# _ref_tree_entry <commit> <path>
#
# Print "<mode> <type> <oid>" for exactly <path> in <commit>; fail if absent.
# ---------------------------------------------------------------------------
_ref_tree_entry() {
	local _commit="$1"
	local _path="$2"
	local _tab _entry=""
	_tab=$(printf '\t')
	_entry=$(git --literal-pathspecs ls-tree --full-tree "$_commit" -- "$_path" 2>/dev/null) || return 1
	[ -n "$_entry" ] || return 1
	[ "${_entry#*"$_tab"}" = "$_path" ] || return 1
	printf '%s\n' "${_entry%%"$_tab"*}"
	return 0
}

# ---------------------------------------------------------------------------
# _resolve_ref_file <commit> <path> <mode> <oid>
#
# Print "<path> <oid>" of the regular file that a tree entry provides, as a
# checkout would: regular files resolve to themselves; tracked symlinks are
# followed (at most 8 hops) to a regular file inside the same commit. Absolute,
# escaping, dangling and non-file targets fail and are skipped by callers.
# ---------------------------------------------------------------------------
_resolve_ref_file() {
	local _commit="$1"
	local _path="$2"
	local _mode="$3"
	local _oid="$4"
	local _hops=0 _target="" _dir="" _meta="" _rest=""
	while :; do
		case "$_mode" in
		100644 | 100755)
			printf '%s %s\n' "$_path" "$_oid"
			return 0
			;;
		120000) ;;
		*) return 1 ;;
		esac
		_hops=$((_hops + 1))
		[ "$_hops" -le 8 ] || return 1
		_target=$(git cat-file blob "$_oid" 2>/dev/null) || return 1
		case "$_target" in
		"" | /*) return 1 ;;
		esac
		_dir=""
		case "$_path" in
		*/*) _dir="${_path%/*}/" ;;
		esac
		_path=$(_normalize_rel_path "${_dir}${_target}") || return 1
		_meta=$(_ref_tree_entry "$_commit" "$_path") || return 1
		_mode="${_meta%% *}"
		_rest="${_meta#* }"
		[ "${_rest%% *}" = "blob" ] || return 1
		_oid="${_rest#* }"
	done
}

# ---------------------------------------------------------------------------
# _materialize_ref_paths <commit> <dest> <paths>
#
# Write the files named by the newline-separated repo-relative <paths> at
# <commit> into the plain directory <dest>. Diff-scoped scans read only those
# files, so no checkout or `git worktree add` registration is needed and an
# interrupted or killed run cannot leave a registered worktree (GH#34905).
# Regular files are written in one `git checkout-index` pass from a private
# temporary index, so Git's own path validation and checkout filters (smudge,
# eol, working-tree-encoding) apply and the repository index is untouched.
# Symlinks are written as the regular file they resolve to inside <commit>
# (`git cat-file --filters`), never as links. Paths absent at <commit>,
# submodules and unresolvable symlinks are skipped, matching the scanners'
# regular-file existence check. Unsafe tree paths are rejected, so every write
# stays inside <dest>. Sidecar files <dest>.ls-tree, <dest>.files and
# <dest>.index are created next to <dest>; callers place <dest> in a temp dir.
# ---------------------------------------------------------------------------
_materialize_ref_paths() {
	local _commit="$1"
	local _dest="$2"
	local _paths="$3"
	local _listing="${_dest}.ls-tree"
	local _files="${_dest}.files"
	local _index="${_dest}.index"
	local _tab _p _entry _meta _rest _path _mode _oid _resolved _src_path _src_oid
	local _have_files=0
	local -a _args=()
	_tab=$(printf '\t')

	mkdir -p "$_dest" || return 1
	: >"$_files" || return 1
	while IFS= read -r _p; do
		[ -n "$_p" ] && _args+=("$_p")
	done <<<"$_paths"
	[ "${#_args[@]}" -gt 0 ] || return 0

	git --literal-pathspecs ls-tree -r -z --full-tree "$_commit" -- "${_args[@]}" >"$_listing" || return 1
	while IFS= read -r -d '' _entry; do
		_meta="${_entry%%"$_tab"*}"
		_path="${_entry#*"$_tab"}"
		_mode="${_meta%% *}"
		_rest="${_meta#* }"
		[ "${_rest%% *}" = "blob" ] || continue
		_oid="${_rest#* }"
		# Git refuses to check out these paths; never write them either.
		case "/${_path}/" in
		*/./* | */../* | *//*) continue ;;
		esac
		case "$_mode" in
		100644 | 100755)
			printf '%s\0' "$_path" >>"$_files" || return 1
			_have_files=1
			;;
		120000)
			_resolved=$(_resolve_ref_file "$_commit" "$_path" "$_mode" "$_oid") || continue
			_src_path="${_resolved% *}"
			_src_oid="${_resolved##* }"
			case "$_path" in
			*/*) mkdir -p "${_dest}/${_path%/*}" || return 1 ;;
			esac
			git cat-file --filters --path="$_src_path" "$_src_oid" >"${_dest}/${_path}" || return 1
			;;
		esac
	done <"$_listing"

	[ "$_have_files" -eq 1 ] || return 0
	# checkout-index reads paths relative to the cwd; listing paths are
	# root-relative, so run it from the top level.
	local _top
	_top=$(git rev-parse --show-toplevel) || return 1
	GIT_INDEX_FILE="$_index" git -C "$_top" read-tree "$_commit" || return 1
	GIT_INDEX_FILE="$_index" git -C "$_top" checkout-index -q -z --stdin --prefix="${_dest}/" <"$_files" || return 1
	return 0
}

# ---------------------------------------------------------------------------
# _materialize_ref_tree <commit> <dest>
#
# Write every tracked file of <commit> into the new, empty, absolute directory
# <dest>: the same file tree `git worktree add` would produce (symlinks
# included, as checkout writes them), but unregistered and without a .git
# entry (GH#34905). Use when a tool's behaviour depends on files beyond the
# scanned set (config `extends`, nested configs, ignore files). A private
# temporary index (<dest>.index) keeps the repository index untouched.
# ---------------------------------------------------------------------------
_materialize_ref_tree() {
	local _commit="$1"
	local _dest="$2"
	local _index="${_dest}.index"
	local _top
	case "$_dest" in
	/*) ;;
	*) return 1 ;;
	esac
	[ ! -e "$_dest" ] || return 1
	mkdir -p "$_dest" || return 1
	_top=$(git rev-parse --show-toplevel) || return 1
	GIT_INDEX_FILE="$_index" git -C "$_top" read-tree "$_commit" || return 1
	GIT_INDEX_FILE="$_index" git -C "$_top" checkout-index -q -a --prefix="${_dest}/" || return 1
	return 0
}
