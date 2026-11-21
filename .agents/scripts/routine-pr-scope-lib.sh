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

_routine_tree_has_file() {
	local tree="$1" path="$2" content="$3" sha=""
	sha=$(jq -er '.sha | strings | select(test("^[0-9a-f]{40}$"))' <<<"$content") || return 1
	jq -e --arg path "$path" --arg sha "$sha" '
		.truncated == false and
		([.tree[] | select(.path == $path and .type == "blob" and
		 (.mode == "100644" or .mode == "100755") and .sha == $sha)] | length == 1)
	' <<<"$tree" >/dev/null || return 1
	return 0
}

# The marker selects a policy, never authority. Deliberately refuse a full API
# page (even exactly 100 files) rather than guessing whether evidence is complete.
#aidevops:trust-boundary — GH#17671 remains binding for all other worker PRs.
_routine_pr_scope_check() {
	local pr_number="$1" repo="$2"
	local dir="${BASH_SOURCE[0]%/*}" meta="" files="" author="" permission=""
	local head="" base="" path="" content="" previous="" ref="" fresh="" tree="" base_tree="" status=""
	meta=$(gh api "repos/$repo/pulls/$pr_number") || return 1
	jq -e --arg repo "$repo" '
		def git_sha: type == "string" and test("^[0-9a-f]{40}$");
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
	files=$(gh api "repos/$repo/pulls/$pr_number/files?per_page=100") || return 1
	jq -e --argjson count "$(jq .changed_files <<<"$meta")" '
		type == "array" and length == $count and length < 100 and
		all(.[]; (.status == "added" or .status == "modified") and
		 (.filename | type == "string" and (test("[[:cntrl:]]") | not)) and
		 (.previous_filename == null)) and
		([.[].filename] | length == (unique | length))
	' <<<"$files" >/dev/null || return 1
	while IFS= read -r path; do
		_is_declared_output "$path" || return 1
		case "$path" in
		README.md | .github/workflows/loc-badge.yml)
			content=$(gh api "repos/$repo/contents/$path?ref=$head") || return 1
			# Contents API dereferences some symlinks: independently require a
			# regular tree entry and bind its object ID to the verified content.
			if [[ -z "$tree" ]]; then
				tree=$(gh api "repos/$repo/git/trees/$head?recursive=1") || return 1
			fi
			_routine_tree_has_file "$tree" "$path" "$content" || return 1
			previous='null'
			if jq -e --arg path "$path" '.[] | select(.filename == $path and .status == "modified")' <<<"$files" >/dev/null; then
				previous=$(gh api "repos/$repo/contents/$path?ref=$base") || return 1
				if [[ -z "$base_tree" ]]; then
					base_tree=$(gh api "repos/$repo/git/trees/$base?recursive=1") || return 1
				fi
				_routine_tree_has_file "$base_tree" "$path" "$previous" || return 1
			fi
			ref=$(jq -n --argjson head "$content" --argjson base "$previous" '{head:$head,base:$base}' |
				python3 "$dir/routine-pr-content.py" "$path" "$dir/../templates/workflows/loc-badge-caller.yml") || return 1
			if [[ -n "$ref" ]]; then
				# A workflow may execute only a pinned commit reachable from main.
				status=$(gh api "repos/marcusquinn/aidevops/compare/$ref...main" --jq .status) || return 1
				case "$status" in ahead | identical) ;; *) return 1 ;; esac
			fi
			;;
		esac
	done < <(jq -r '.[].filename' <<<"$files")
	# Pin the verdict to the observed diff/body; a racing push is not admitted.
	fresh=$(gh api "repos/$repo/pulls/$pr_number") || return 1
	[[ "$(jq -Sc '{head:.head.sha,base:.base.sha,body,labels,state,draft,changed_files}' <<<"$fresh")" == \
		"$(jq -Sc '{head:.head.sha,base:.base.sha,body,labels,state,draft,changed_files}' <<<"$meta")" ]] || return 1
	return 0
}
