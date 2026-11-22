#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Shared output policy: recovery and admission must use the same allowlist.
_is_declared_output() {
	local candidate="$1"
	case "$candidate" in
	README.md | .github/workflows/loc-badge.yml | docs/metrics/* | .github/badges/*) return 0 ;;
	esac
	return 1
}

# Shared jq definitions for every evidence predicate below (not readonly: the
# merge gate re-sources this library on each evaluation).
_ROUTINE_JQ_DEFS='def git_sha: type == "string" and test("^[0-9a-f]{40}$");
	def clean_path: type == "string" and (test("[[:cntrl:]]") | not);'

# _routine_tree_blob <tree-json> <path> — print the object ID of the single
# regular (non-symlink, non-submodule) blob at <path> in a complete recursive
# tree. Contents API responses dereference some symlinks, so content is always
# fetched by this pinned object ID instead.
_routine_tree_blob() {
	local tree="$1" path="$2"
	jq -er --arg path "$path" "$_ROUTINE_JQ_DEFS"'
		select(.truncated == false) | [.tree[] | select(.path == $path)] |
		select(length == 1) | .[0] |
		select(.type == "blob" and (.mode == "100644" or .mode == "100755")) |
		.sha | select(git_sha)
	' <<<"$tree" || return 1
	return 0
}

# _routine_scope_compare <repo> <base> <head> <changed_files> — print the
# three-dot comparison of the exact verified SHAs. Unlike the PR files
# endpoint, which describes whichever head is current when it is read, this
# evidence cannot be swapped by a push-and-restore between reads, and its
# merge base is the commit the PR diff is computed against.
_routine_scope_compare() {
	local repo="$1" base="$2" head="$3" count="$4" compare=""
	compare=$(gh api "repos/$repo/compare/${base}...${head}?per_page=1") || return 1
	jq -e --argjson count "$count" "$_ROUTINE_JQ_DEFS"'
		(.merge_base_commit.sha | git_sha) and
		(.files | type == "array" and length == $count and length < 100) and
		all(.files[]; (.status == "added" or .status == "modified") and
		 (.filename | clean_path) and
		 (.previous_filename == null)) and
		([.files[].filename] | length == (unique | length))
	' <<<"$compare" >/dev/null || return 1
	printf '%s\n' "$compare"
	return 0
}

# _routine_scope_content <repo> <path> <status> <head_blob> <merge_base> —
# byte-exact README/workflow policy. Prints nothing for other declared outputs.
_routine_scope_content() {
	local repo="$1" path="$2" status="$3" head_blob="$4" merge_base="$5"
	local dir="${BASH_SOURCE[0]%/*}" content="" previous="null" base_tree="" base_blob="" ref="" ref_status=""
	case "$path" in README.md | .github/workflows/loc-badge.yml) ;; *) return 0 ;; esac
	content=$(gh api "repos/$repo/git/blobs/$head_blob") || return 1
	if [[ "$status" == "modified" ]]; then
		base_tree=$(gh api "repos/$repo/git/trees/$merge_base?recursive=1") || return 1
		base_blob=$(_routine_tree_blob "$base_tree" "$path") || return 1
		previous=$(gh api "repos/$repo/git/blobs/$base_blob") || return 1
	fi
	ref=$(jq -n --argjson head "$content" --argjson base "$previous" '{head:$head,base:$base}' |
		python3 "$dir/routine-pr-content.py" "$path" "$dir/../templates/workflows/loc-badge-caller.yml") || return 1
	if [[ -n "$ref" ]]; then
		# A workflow may execute only a pinned commit reachable from main.
		ref_status=$(gh api "repos/marcusquinn/aidevops/compare/$ref...main" --jq .status) || return 1
		case "$ref_status" in ahead | identical) ;; *) return 1 ;; esac
	fi
	return 0
}

# The marker selects a policy, never authority. Deliberately refuse a full API
# page (even exactly 100 files) rather than guessing whether evidence is complete.
# Every diff, tree and blob read is pinned to the verified head and merge base.
#aidevops:trust-boundary — GH#17671 remains binding for all other worker PRs.
_routine_pr_scope_check() {
	local pr_number="$1" repo="$2"
	local meta="" compare="" listing="" author="" permission="" head="" base="" merge_base=""
	local tree="" path="" status="" blob="" fresh=""
	meta=$(gh api "repos/$repo/pulls/$pr_number") || return 1
	jq -e --arg repo "$repo" "$_ROUTINE_JQ_DEFS"'
		.state == "open" and .draft == false and
		([.labels[].name] | index("origin:worker") != null) and
		([.labels[].name] | index("hold-for-review") == null) and
		.head.repo.full_name == $repo and .base.repo.full_name == $repo and
		(.head.ref | startswith("chore/badges-sync-")) and
		(.body | contains("<!-- aidevops:routine-pr:badges-sync -->")) and
		(.body | split("aidevops:routine-pr:") | length == 2) and
		(.head.sha | git_sha) and (.base.sha | git_sha) and
		(.changed_files > 0 and .changed_files < 100)
	' <<<"$meta" >/dev/null || return 1
	author=$(jq -er '.user.login | strings | select(length > 0)' <<<"$meta") || return 1
	permission=$(gh api "repos/$repo/collaborators/$author/permission" --jq .permission) || return 1
	case "$permission" in write | maintain | admin) ;; *) return 1 ;; esac
	head=$(jq -r .head.sha <<<"$meta")
	base=$(jq -r .base.sha <<<"$meta")
	compare=$(_routine_scope_compare "$repo" "$base" "$head" "$(jq .changed_files <<<"$meta")") || return 1
	merge_base=$(jq -r .merge_base_commit.sha <<<"$compare")
	# Materialise the listing first: a failed producer must not look like no files.
	listing=$(jq -r '.files[] | [.filename, .status] | @tsv' <<<"$compare") || return 1
	[[ -n "$listing" ]] || return 1
	tree=$(gh api "repos/$repo/git/trees/$head?recursive=1") || return 1
	while IFS=$'\t' read -r path status; do
		_is_declared_output "$path" || return 1
		# Every admitted output, not only content-checked ones, must be regular.
		blob=$(_routine_tree_blob "$tree" "$path") || return 1
		_routine_scope_content "$repo" "$path" "$status" "$blob" "$merge_base" || return 1
	done <<<"$listing"
	# Pin the verdict to the observed head/body; a racing push is not admitted.
	fresh=$(gh api "repos/$repo/pulls/$pr_number") || return 1
	[[ "$(jq -Sc '{head:.head.sha,base:.base.sha,body,labels,state,draft,changed_files}' <<<"$fresh")" == \
		"$(jq -Sc '{head:.head.sha,base:.base.sha,body,labels,state,draft,changed_files}' <<<"$meta")" ]] || return 1
	return 0
}
