#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# worktree-rescue-helper.sh — move uncommitted work out of a linked worktree
# that aidevops refuses (for example `generation-directory-mismatch` after a
# machine migration or backup restore) into a fresh worktree, without changing
# the source tree, its Git index or any lifecycle state (GH#37827).
#
# Commands:
#   inspect <worktree>                 Read-only summary of branch, commit and changes.
#   export  <worktree> [--out DIR]     Write a rescue bundle; the source is never modified.
#   import  <bundle> [--dest DIR]      Apply a bundle to a clean fresh worktree at the same commit.
#   verify  <bundle> [--dest DIR]      Prove the destination reproduces the bundle exactly
#                                      and write <bundle>/receipt.txt (retire-foreign-worktree proof).
#
# Run inspect/export with a workdir OUTSIDE the refused worktree (agent tools
# refuse any command whose workdir is inside it). Run import/verify from inside
# the fresh destination worktree, which normal admission covers.
# Guide: reference/machine-migration.md.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail

# Optional index/stat refreshes are writes; never take them on the source.
export GIT_OPTIONAL_LOCKS=0
# Inherited repository selectors would redirect -C to another index or tree.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

readonly RESCUE_FORMAT=1
readonly RESCUE_RECEIPT="receipt.txt"
# Deterministic diff output so source and destination compare byte-for-byte.
RESCUE_DIFF_ARGS=(
	diff --binary --full-index --no-color --no-ext-diff --no-textconv --no-renames
	--diff-algorithm=myers --no-indent-heuristic --src-prefix=a/ --dst-prefix=b/ HEAD
)
readonly RESCUE_DIFF_ARGS

_rescue_git() {
	local tree="$1"
	shift
	git --no-optional-locks -C "$tree" "$@"
	return $?
}

_rescue_sha256() {
	local file="$1"
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file" | awk '{print $1}'
		return 0
	fi
	sha256sum "$file" | awk '{print $1}'
	return 0
}

# Hash a path without following symlinks. Export refuses directory entries
# (nested repositories), so only files and symlinks reach this function.
_rescue_entry_hash() {
	local path="$1"
	if [[ -L "$path" ]]; then
		# Trailing "x" sentinel keeps trailing newlines that $(...) would strip.
		local target
		target="$(readlink "$path"; printf x)"
		target="${target%x}"
		printf 'link:%s' "${target%$'\n'}"
		return 0
	fi
	printf 'sha256:%s' "$(_rescue_sha256 "$path")"
	return 0
}

# Print an absolute, physical path for a directory that may not exist yet.
# The deepest existing ancestor is resolved with pwd -P; `..` is refused in the
# remainder so the result cannot escape that lexical check.
_rescue_physical_path() {
	local requested="$1"
	local target="$requested"
	local ancestor remainder="" part
	[[ "$target" == /* ]] || target="$PWD/$target"
	ancestor="$target"
	while [[ ! -d "$ancestor" ]]; do
		part="${ancestor##*/}"
		if [[ "$part" == ".." ]]; then
			print_error "Refusing '..' in a path that does not exist yet: $requested"
			return 1
		fi
		remainder="/${part}${remainder}"
		ancestor="${ancestor%/*}"
		[[ -n "$ancestor" ]] || ancestor="/"
	done
	ancestor=$(cd "$ancestor" && pwd -P) || return 1
	printf '%s%s\n' "${ancestor%/}" "$remainder"
	return 0
}

# Print the physical path of an existing directory.
_rescue_existing_dir() {
	local target="$1"
	if [[ ! -d "$target" ]]; then
		print_error "Not a directory: $target"
		return 1
	fi
	(cd "$target" && pwd -P)
	return $?
}

# Sorted newline list of NUL-separated names; names containing newlines are refused.
_rescue_sorted_names() {
	local list="$1"
	if [[ "$(tr -cd '\n' <"$list" | wc -c | tr -d ' ')" != "0" ]]; then
		print_error "Untracked file names containing newlines are not supported; move those files by hand."
		return 1
	fi
	tr '\0' '\n' <"$list" | LC_ALL=C sort
	return 0
}

# Print the absolute top level of a linked worktree, or fail.
_rescue_linked_root() {
	local tree="$1"
	local top
	if [[ ! -d "$tree" ]]; then
		print_error "Not a directory: $tree"
		return 1
	fi
	top=$(_rescue_git "$tree" rev-parse --show-toplevel 2>/dev/null) || {
		print_error "Not a Git worktree: $tree"
		return 1
	}
	if [[ ! -f "$top/.git" ]]; then
		print_error "Not a linked worktree (its .git is not a file): $top"
		return 1
	fi
	printf '%s\n' "$top"
	return 0
}

_rescue_in_progress() {
	local top="$1"
	local gitdir name
	gitdir=$(_rescue_git "$top" rev-parse --absolute-git-dir) || return 1
	for name in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply BISECT_LOG; do
		if [[ -e "$gitdir/$name" ]]; then
			printf '%s\n' "$name"
		fi
	done
	return 0
}

_rescue_manifest_value() {
	local bundle="$1"
	local key="$2"
	awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$bundle/manifest.txt"
	return 0
}

cmd_inspect() {
	local tree="${1:-}"
	local top head branch upstream ahead marker gitdir
	if [[ -z "$tree" ]]; then
		print_error "Usage: worktree-rescue-helper.sh inspect <worktree>"
		return 1
	fi
	top=$(_rescue_linked_root "$tree") || return 1
	gitdir=$(_rescue_git "$top" rev-parse --absolute-git-dir) || return 1
	head=$(_rescue_git "$top" rev-parse HEAD) || return 1
	branch=$(_rescue_git "$top" symbolic-ref --quiet --short HEAD 2>/dev/null || printf '(detached)')
	upstream=$(_rescue_git "$top" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || printf '')
	ahead=""
	if [[ -n "$upstream" ]]; then
		ahead=$(_rescue_git "$top" rev-list --count '@{upstream}..HEAD' 2>/dev/null || printf '?')
	fi
	marker="absent"
	if [[ -e "$gitdir/aidevops-generation.json" ]]; then
		marker="present"
	fi
	printf 'worktree=%s\nbranch=%s\nhead=%s\nupstream=%s\n' "$top" "$branch" "$head" "${upstream:-none}"
	printf 'commits_ahead_of_upstream=%s\nlifecycle_marker=%s\n' "${ahead:-n/a}" "$marker"
	printf 'in_progress=%s\n' "$(_rescue_in_progress "$top" | tr '\n' ' ')"
	printf 'tracked_changes=%s\n' "$(_rescue_git "$top" diff --name-only HEAD | awk 'END {print NR}')"
	printf 'untracked_files=%s\n' "$(_rescue_git "$top" ls-files --others --exclude-standard | awk 'END {print NR}')"
	printf 'ignored_entries=%s\n' "$(_rescue_git "$top" ls-files --others --ignored --exclude-standard --directory | awk 'END {print NR}')"
	return 0
}

_rescue_default_out() {
	local top="$1"
	local base="${AIDEVOPS_WORKSPACE_DIR:-$HOME/.aidevops/.agent-workspace}/work/worktree-rescue"
	printf '%s/%s-%s\n' "$base" "$(basename "$top")" "$(date -u +%Y%m%dT%H%M%SZ)"
	return 0
}

# Record untracked entries as NUL-separated "hash<TAB>path" records.
_rescue_hash_untracked() {
	local root="$1"
	local list="$2"
	local output="$3"
	local entry hash
	: >"$output"
	while IFS= read -r -d '' entry; do
		entry="${entry%/}"
		# Sentinel keeps trailing newlines in symlink targets through $(...).
		hash="$(_rescue_entry_hash "$root/$entry"; printf x)"
		printf '%s\t%s\0' "${hash%x}" "$entry" >>"$output"
	done <"$list"
	return 0
}

_rescue_index_fingerprint() {
	local top="$1"
	local gitdir
	gitdir=$(_rescue_git "$top" rev-parse --absolute-git-dir) || return 1
	if [[ -f "$gitdir/index" ]]; then
		_rescue_sha256 "$gitdir/index"
		return 0
	fi
	printf 'no-index\n'
	return 0
}

# Create an empty private bundle directory outside the source; print its path.
# Git and tar run with other working directories, so one physical path is used.
_rescue_prepare_out() {
	local top="$1"
	local out="$2"
	out=$(_rescue_physical_path "$out") || return 1
	case "$out/" in
	"$top"/* | "$(cd "$top" && pwd -P)"/*)
		print_error "Bundle directory must be outside the source worktree: $out"
		return 1
		;;
	esac
	if [[ -e "$out" ]] && [[ -n "$(ls -A "$out" 2>/dev/null)" ]]; then
		print_error "Bundle directory exists and is not empty: $out"
		return 1
	fi
	mkdir -p "$out"
	chmod 700 "$out"
	printf '%s\n' "$out"
	return 0
}

# Write the patch, untracked list/archive/hashes and ignored list.
_rescue_write_payload() {
	local top="$1"
	local out="$2"
	local entry
	_rescue_git "$top" "${RESCUE_DIFF_ARGS[@]}" --output="$out/changes.patch"
	_rescue_git "$top" ls-files --others --exclude-standard -z >"$out/untracked.list0"
	_rescue_sorted_names "$out/untracked.list0" >/dev/null || return 1
	while IFS= read -r -d '' entry; do
		# Git lists an untracked nested repository as one directory entry; archiving
		# it would carry that repository's .git and ignored files (secrets).
		if [[ "$entry" == */ || ( -d "$top/$entry" && ! -L "$top/$entry" ) ]]; then
			print_error "Untracked nested repository or directory: ${entry%/}. Commit and push it from its own checkout, or copy it by hand, then re-run export."
			return 1
		fi
	done <"$out/untracked.list0"
	_rescue_git "$top" ls-files --others --ignored --exclude-standard --directory -z >"$out/ignored.list0"
	tr '\0' '\n' <"$out/ignored.list0" >"$out/ignored.txt"
	if [[ -s "$out/untracked.list0" ]]; then
		(cd "$top" && tar --no-recursion --null -T "$out/untracked.list0" -cf "$out/untracked.tar")
	fi
	_rescue_hash_untracked "$top" "$out/untracked.list0" "$out/untracked.hashes0"
	return 0
}

cmd_export() {
	local tree="${1:-}"
	shift || true
	local out=""
	while [[ $# -gt 0 ]]; do
		local option="$1"
		case "$option" in
		--out)
			out="${2:-}"
			shift 2 || { print_error "--out requires a directory"; return 1; }
			;;
		*)
			print_error "Unknown export option: $option"
			return 1
			;;
		esac
	done
	if [[ -z "$tree" ]]; then
		print_error "Usage: worktree-rescue-helper.sh export <worktree> [--out DIR]"
		return 1
	fi
	local top head branch index_before index_after status_before status_after pending count
	top=$(_rescue_linked_root "$tree") || return 1
	case "$PWD/" in
	"$top"/*)
		print_error "Run export from a workdir outside the source worktree."
		return 1
		;;
	esac
	head=$(_rescue_git "$top" rev-parse HEAD) || return 1
	branch=$(_rescue_git "$top" symbolic-ref --quiet --short HEAD 2>/dev/null || printf '(detached)')
	[[ -n "$out" ]] || out=$(_rescue_default_out "$top")
	out=$(_rescue_prepare_out "$top" "$out") || return 1

	index_before=$(_rescue_index_fingerprint "$top") || return 1
	status_before=$(_rescue_git "$top" status --porcelain=v2 -z | _rescue_stdin_sha256)
	pending=$(_rescue_in_progress "$top" | tr '\n' ' ')

	_rescue_write_payload "$top" "$out" || return 1
	count=$(tr -cd '\0' <"$out/untracked.list0" | wc -c | tr -d ' ')

	index_after=$(_rescue_index_fingerprint "$top") || return 1
	status_after=$(_rescue_git "$top" status --porcelain=v2 -z | _rescue_stdin_sha256)
	if [[ "$index_before" != "$index_after" || "$status_before" != "$status_after" ]]; then
		print_error "Source changed during export; re-run export once no process is writing to it."
		return 1
	fi

	{
		printf 'format=%s\n' "$RESCUE_FORMAT"
		printf 'source=%s\n' "$top"
		printf 'branch=%s\n' "$branch"
		printf 'head=%s\n' "$head"
		printf 'exported_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'in_progress=%s\n' "$pending"
		printf 'untracked_count=%s\n' "$count"
		printf 'patch_sha256=%s\n' "$(_rescue_sha256 "$out/changes.patch")"
		printf 'untracked_hashes_sha256=%s\n' "$(_rescue_sha256 "$out/untracked.hashes0")"
		printf 'untracked_list_sha256=%s\n' "$(_rescue_sha256 "$out/untracked.list0")"
		if [[ -f "$out/untracked.tar" ]]; then
			printf 'untracked_tar_sha256=%s\n' "$(_rescue_sha256 "$out/untracked.tar")"
		fi
	} >"$out/manifest.txt"
	chmod -R go-rwx "$out"

	print_success "Rescue bundle written: $out (source unchanged)"
	printf 'BUNDLE=%s\nHEAD=%s\nBRANCH=%s\n' "$out" "$head" "$branch"
	if [[ -n "${pending// /}" ]]; then
		print_warning "Source has an in-progress operation ($pending); only file contents are rescued."
	fi
	if [[ -s "$out/ignored.txt" ]]; then
		print_warning "Ignored files (for example .env) are listed in $out/ignored.txt but not copied; copy any you need by hand."
	fi
	printf 'NEXT: worktree-helper.sh add rescue/<name> --base %s, then from inside it run: worktree-rescue-helper.sh import %s\n' "$head" "$out"
	return 0
}

_rescue_stdin_sha256() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | awk '{print $1}'
		return 0
	fi
	sha256sum | awk '{print $1}'
	return 0
}

_rescue_check_bundle() {
	local bundle="$1"
	local expected actual
	if [[ ! -f "$bundle/manifest.txt" || ! -f "$bundle/changes.patch" ]]; then
		print_error "Not a rescue bundle: $bundle"
		return 1
	fi
	if [[ "$(_rescue_manifest_value "$bundle" format)" != "$RESCUE_FORMAT" ]]; then
		print_error "Unsupported bundle format in $bundle/manifest.txt"
		return 1
	fi
	expected=$(_rescue_manifest_value "$bundle" patch_sha256)
	actual=$(_rescue_sha256 "$bundle/changes.patch")
	if [[ "$expected" != "$actual" ]]; then
		print_error "Bundle patch checksum mismatch; re-export from the source."
		return 1
	fi
	expected=$(_rescue_manifest_value "$bundle" untracked_list_sha256)
	if [[ ! -f "$bundle/untracked.list0" || "$expected" != "$(_rescue_sha256 "$bundle/untracked.list0")" ]]; then
		print_error "Bundle untracked list checksum mismatch; re-export from the source."
		return 1
	fi
	expected=$(_rescue_manifest_value "$bundle" untracked_tar_sha256)
	if [[ -z "$expected" ]]; then
		# An archive the manifest does not declare could overwrite ignored files.
		if [[ -e "$bundle/untracked.tar" || -L "$bundle/untracked.tar" ]]; then
			print_error "Bundle contains an undeclared untracked archive; re-export from the source."
			return 1
		fi
		return 0
	fi
	if [[ ! -f "$bundle/untracked.tar" || "$expected" != "$(_rescue_sha256 "$bundle/untracked.tar")" ]]; then
		print_error "Bundle untracked archive checksum mismatch; re-export from the source."
		return 1
	fi
	# Archive members must be exactly the declared untracked files.
	if [[ "$(tar -tf "$bundle/untracked.tar" | LC_ALL=C sort)" != "$(_rescue_sorted_names "$bundle/untracked.list0")" ]]; then
		print_error "Bundle archive members differ from its untracked list; re-export from the source."
		return 1
	fi
	return 0
}

_rescue_dest_root() {
	local dest="$1"
	local bundle="$2"
	local top source
	top=$(_rescue_linked_root "$dest") || return 1
	source=$(_rescue_manifest_value "$bundle" source)
	if [[ "$top" == "$source" ]]; then
		print_error "Destination is the source worktree; use a fresh worktree."
		return 1
	fi
	printf '%s\n' "$top"
	return 0
}

_rescue_parse_dest() {
	local dest="$PWD"
	while [[ $# -gt 0 ]]; do
		local option="$1"
		case "$option" in
		--dest)
			dest="${2:-}"
			shift 2 || { print_error "--dest requires a directory"; return 1; }
			;;
		*)
			print_error "Unknown option: $option"
			return 1
			;;
		esac
	done
	printf '%s\n' "$dest"
	return 0
}

cmd_import() {
	local bundle="${1:-}"
	shift || true
	local dest top head entry
	if [[ -z "$bundle" ]]; then
		print_error "Usage: worktree-rescue-helper.sh import <bundle> [--dest DIR]"
		return 1
	fi
	# git -C and tar -C would resolve a relative bundle from the destination.
	bundle=$(_rescue_existing_dir "$bundle") || return 1
	dest=$(_rescue_parse_dest "$@") || return 1
	_rescue_check_bundle "$bundle" || return 1
	top=$(_rescue_dest_root "$dest" "$bundle") || return 1
	head=$(_rescue_manifest_value "$bundle" head)
	if [[ "$(_rescue_git "$top" rev-parse HEAD)" != "$head" ]]; then
		print_error "Destination HEAD differs from bundle commit $head."
		print_info "Create the destination with: worktree-helper.sh add rescue/<name> --base $head"
		return 1
	fi
	if [[ -n "$(_rescue_git "$top" status --porcelain)" ]]; then
		print_error "Destination is not clean. If an earlier import was interrupted, discard that rescue worktree and create a fresh one; the source and bundle are unchanged."
		return 1
	fi
	while IFS= read -r -d '' entry; do
		if [[ -e "$top/${entry%/}" || -L "$top/${entry%/}" ]]; then
			print_error "Destination already contains untracked path: ${entry%/}"
			return 1
		fi
	done <"$bundle/untracked.list0"

	if [[ -s "$bundle/changes.patch" ]]; then
		git -C "$top" apply --index --binary "$bundle/changes.patch"
	fi
	if [[ -f "$bundle/untracked.tar" ]]; then
		tar -xpf "$bundle/untracked.tar" -C "$top"
	fi
	print_info "Applied bundle to $top; verifying."
	cmd_verify "$bundle" --dest "$top"
	return $?
}

cmd_verify() {
	local bundle="${1:-}"
	shift || true
	local dest top expected actual work
	if [[ -z "$bundle" ]]; then
		print_error "Usage: worktree-rescue-helper.sh verify <bundle> [--dest DIR]"
		return 1
	fi
	bundle=$(_rescue_existing_dir "$bundle") || return 1
	dest=$(_rescue_parse_dest "$@") || return 1
	_rescue_check_bundle "$bundle" || return 1
	top=$(_rescue_dest_root "$dest" "$bundle") || return 1
	if [[ "$(_rescue_git "$top" rev-parse HEAD)" != "$(_rescue_manifest_value "$bundle" head)" ]]; then
		print_error "VERIFY FAILED: destination HEAD differs from the bundle commit."
		return 1
	fi
	expected=$(_rescue_manifest_value "$bundle" patch_sha256)
	actual=$(_rescue_git "$top" "${RESCUE_DIFF_ARGS[@]}" | _rescue_stdin_sha256)
	if [[ "$expected" != "$actual" ]]; then
		print_error "VERIFY FAILED: tracked changes differ from the bundle patch."
		_rescue_git "$top" diff --stat HEAD || true
		return 1
	fi
	work=$(mktemp -d)
	_rescue_git "$top" ls-files --others --exclude-standard -z >"$work/untracked.list0"
	_rescue_hash_untracked "$top" "$work/untracked.list0" "$work/untracked.hashes0"
	expected=$(_rescue_manifest_value "$bundle" untracked_hashes_sha256)
	actual=$(_rescue_sha256 "$work/untracked.hashes0")
	rm -rf "$work"
	if [[ "$expected" != "$actual" ]]; then
		print_error "VERIFY FAILED: untracked files differ from the bundle."
		return 1
	fi
	if ! _rescue_write_receipt "$bundle" "$top"; then
		print_error "Could not write $bundle/$RESCUE_RECEIPT; retirement of the source needs it (re-run verify)."
		return 1
	fi
	print_success "VERIFIED: $top reproduces the bundle exactly (tracked changes and untracked files)."
	printf 'RESCUE_VERIFIED=%s\n' "$top"
	return 0
}

# Write the machine-verifiable receipt that guarded retirement of the source
# requires (GH#37828). It restates the manifest hashes and pins the manifest
# bytes; retirement re-derives every hash from the source, so this is evidence
# of a verified rescue, never an authorization.
_rescue_write_receipt() {
	local bundle="$1"
	local dest="$2"
	local tmp
	tmp=$(mktemp "$bundle/.${RESCUE_RECEIPT}.XXXXXX") || return 1
	local key
	{
		printf 'format=%s\n' "$RESCUE_FORMAT"
		printf 'bundle_manifest_sha256=%s\n' "$(_rescue_sha256 "$bundle/manifest.txt")"
		for key in source head patch_sha256 untracked_hashes_sha256 untracked_list_sha256; do
			printf '%s=%s\n' "$key" "$(_rescue_manifest_value "$bundle" "$key")"
		done
		printf 'verified_destination=%s\n' "$dest"
		printf 'verified_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} >"$tmp" || return 1
	chmod 600 "$tmp" && mv -f "$tmp" "$bundle/$RESCUE_RECEIPT" || return 1
	printf 'RESCUE_RECEIPT=%s\n' "$bundle/$RESCUE_RECEIPT"
	return 0
}

cmd_help() {
	sed -n '4,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	inspect) cmd_inspect "$@" ;;
	export) cmd_export "$@" ;;
	import) cmd_import "$@" ;;
	verify) cmd_verify "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return $?
}

main "$@"
