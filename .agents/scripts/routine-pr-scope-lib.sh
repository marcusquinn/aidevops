#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Shared labels (not readonly: the merge gate re-sources this library).
_ROUTINE_SYNC_KEY=sync-workflows
_ROUTINE_MODIFIED=modified

# Shared output policy: recovery and admission must use the same allowlist.
_is_declared_output() {
	local candidate="$1"
	case "$candidate" in
	README.md | .github/workflows/loc-badge.yml | docs/metrics/* | .github/badges/*) return 0 ;;
	esac
	return 1
}

# Managed workflow callers sync-workflows may rewrite (GH#39793). Mirrors the
# workflow names routine-pr-content.py can re-render; CONTRIBUTING.md and
# linked-issue-check stay outside the marker path.
_is_sync_workflow_output() {
	local candidate="$1"
	case "$candidate" in
	.github/workflows/issue-sync.yml | .github/workflows/review-bot-gate.yml | \
		.github/workflows/review-bot-gate-fork-review.yml | .github/workflows/maintainer-gate.yml | \
		.github/workflows/loc-badge.yml | .github/workflows/issue-triage-gate.yml) return 0 ;;
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
	local dir="${BASH_SOURCE[0]%/*}" content="" previous="null" base_tree="" base_blob="" ref=""
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
		_routine_ref_reachable "$ref" || return 1
	fi
	return 0
}

# A workflow may execute only a pinned commit reachable from aidevops main.
_routine_ref_reachable() {
	local ref="$1" ref_status=""
	[[ "$ref" =~ ^[0-9a-f]{40}$ ]] || return 1
	ref_status=$(gh api "repos/marcusquinn/aidevops/compare/$ref...main" --jq .status) || return 1
	case "$ref_status" in ahead | identical) return 0 ;; esac
	return 1
}

# _routine_sync_policy <repo> <base_branch> — declared per-repo target policy
# (reusable repository, runner override) from the local registry. Missing
# entries yield restrictive defaults; a malformed registry fails closed.
_routine_sync_policy() {
	local repo="$1" base_branch="$2" registry="${REPOS_JSON:-$HOME/.config/aidevops/repos.json}"
	if [[ ! -f "$registry" ]]; then
		jq -nc --arg b "$base_branch" '{repo:"marcusquinn/aidevops",runner:null,base_branch:$b}'
		return $?
	fi
	jq -c --arg s "$repo" --arg b "$base_branch" '
		def field($k): ([.initialized_repos[]? | select(.slug == $s) | .[$k] // empty] | first // "") as $v |
			if $v != "" then $v else (.[$k] // empty) end;
		{repo: (field("workflow_reusable_repo") // "marcusquinn/aidevops"),
		 runner: ([.initialized_repos[]? | select(.slug == $s) | .runner // empty] | first // null),
		 base_branch: $b}' "$registry"
	return $?
}

# _routine_ref_not_older <base_ref> <head_ref> — a sync preserves or advances
# a caller pin; it never moves one to an older framework commit (GH#39830).
_routine_ref_not_older() {
	local base_ref="$1" head_ref="$2" ref_status=""
	[[ "$base_ref" =~ ^[0-9a-f]{40}$ && "$head_ref" =~ ^[0-9a-f]{40}$ ]] || return 1
	[[ "$base_ref" != "$head_ref" ]] || return 0
	ref_status=$(gh api "repos/marcusquinn/aidevops/compare/$base_ref...$head_ref" --jq .status) || return 1
	[[ "$ref_status" == "ahead" ]] || return 1
	return 0
}

# _routine_sync_render_admits <workflow-path> <head-blob> <base-blob|null> <policy>
# — the one exact-render decision shared by the sync publisher (before it
# chooses the marker) and the merge gate (GH#39830). Blobs are Git blob API
# JSON. The head's single pin must be reachable from aidevops main and not
# older than the base caller's pin, and the caller must equal the re-render of
# the template at that pin. Nothing from the PR is executed.
_routine_sync_render_admits() {
	local path="$1" head="$2" previous="$3" policy="$4"
	local dir="${BASH_SOURCE[0]%/*}" name="" ref="" base_ref="" template=""
	_is_sync_workflow_output "$path" || return 1
	name="${path##*/}"
	name="${name%.yml}"
	ref=$(jq -n --argjson head "$head" '{head:$head}' |
		python3 "$dir/routine-pr-content.py" --sync-ref) || return 1
	_routine_ref_reachable "$ref" || return 1
	# A base without one 40-hex pin (for example floating @main) has no floor.
	if [[ "$previous" != "null" ]] &&
		base_ref=$(jq -n --argjson head "$previous" '{head:$head}' |
			python3 "$dir/routine-pr-content.py" --sync-ref 2>/dev/null); then
		_routine_ref_not_older "$base_ref" "$ref" || return 1
	fi
	template=$(gh api "repos/marcusquinn/aidevops/contents/.agents/templates/workflows/${name}-caller.yml?ref=$ref") || return 1
	jq -n --argjson head "$head" --argjson base "$previous" --argjson template "$template" \
		--argjson policy "$policy" '{head:$head,base:$base,template:$template,policy:$policy}' |
		python3 "$dir/routine-pr-content.py" --sync-validate "$name" >/dev/null || return 1
	return 0
}

# _routine_sync_content <repo> <path> <status> <head_blob> <merge_base> <policy>
# — gate side of _routine_sync_render_admits over SHA-pinned PR blobs.
_routine_sync_content() {
	local repo="$1" path="$2" status="$3" head_blob="$4" merge_base="$5" policy="$6"
	local head="" previous="null" base_tree="" base_blob=""
	head=$(gh api "repos/$repo/git/blobs/$head_blob") || return 1
	if [[ "$status" == "$_ROUTINE_MODIFIED" ]]; then
		base_tree=$(gh api "repos/$repo/git/trees/$merge_base?recursive=1") || return 1
		base_blob=$(_routine_tree_blob "$base_tree" "$path") || return 1
		previous=$(gh api "repos/$repo/git/blobs/$base_blob") || return 1
	fi
	_routine_sync_render_admits "$path" "$head" "$previous" "$policy" || return 1
	return 0
}

# The marker selects a policy, never authority. Deliberately refuse a full API
# page (even exactly 100 files) rather than guessing whether evidence is complete.
# Every diff, tree and blob read is pinned to the verified head and merge base.
#aidevops:trust-boundary — GH#17671 remains binding for all other worker PRs.
_routine_pr_scope_check() {
	local pr_number="$1" repo="$2"
	local meta="" compare="" listing="" author="" permission="" head="" base="" merge_base=""
	local tree="" path="" status="" blob="" fresh="" key="" prefix="" policy="" default_branch=""
	meta=$(gh api "repos/$repo/pulls/$pr_number") || return 1
	# One standalone marker selects which routine's policy applies.
	case "$(jq -r '.body // ""' <<<"$meta")" in
	*'<!-- aidevops:routine-pr:badges-sync -->'*) key="badges-sync" prefix="chore/badges-sync-" ;;
	*'<!-- aidevops:routine-pr:sync-workflows -->'*) key=$_ROUTINE_SYNC_KEY prefix="chore/workflow-sync-" ;;
	*) return 1 ;;
	esac
	jq -e --arg repo "$repo" --arg key "$key" --arg prefix "$prefix" "$_ROUTINE_JQ_DEFS"'
		.state == "open" and .draft == false and
		([.labels[].name] | index("origin:worker") != null) and
		([.labels[].name] | index("hold-for-review") == null) and
		.head.repo.full_name == $repo and .base.repo.full_name == $repo and
		(.head.ref | startswith($prefix)) and
		(.body | contains("<!-- aidevops:routine-pr:" + $key + " -->")) and
		(.body | split("aidevops:routine-pr:") | length == 2) and
		(.head.sha | git_sha) and (.base.sha | git_sha) and
		(.changed_files > 0 and .changed_files < 100)
	' <<<"$meta" >/dev/null || return 1
	author=$(jq -er '.user.login | strings | select(length > 0)' <<<"$meta") || return 1
	permission=$(gh api "repos/$repo/collaborators/$author/permission" --jq .permission) || return 1
	case "$permission" in write | maintain | admin) ;; *) return 1 ;; esac
	head=$(jq -r .head.sha <<<"$meta")
	base=$(jq -r .base.sha <<<"$meta")
	# Pulse re-runs this verdict pinned to the head it will merge; a verdict
	# for any other head (even one that later reverts) is not admission.
	if [[ -n "${WORKER_BRIEFED_EXPECTED_HEAD:-}" && "$head" != "$WORKER_BRIEFED_EXPECTED_HEAD" ]]; then
		return 1
	fi
	compare=$(_routine_scope_compare "$repo" "$base" "$head" "$(jq .changed_files <<<"$meta")") || return 1
	merge_base=$(jq -r .merge_base_commit.sha <<<"$compare")
	# Materialise the listing first: a failed producer must not look like no files.
	listing=$(jq -r '.files[] | [.filename, .status] | @tsv' <<<"$compare") || return 1
	[[ -n "$listing" ]] || return 1
	tree=$(gh api "repos/$repo/git/trees/$head?recursive=1") || return 1
	if [[ "$key" == "$_ROUTINE_SYNC_KEY" ]]; then
		# The PR must target the repository default branch the sync rendered for.
		default_branch=$(gh api "repos/$repo" --jq .default_branch) || return 1
		[[ "$default_branch" == "$(jq -r .base.ref <<<"$meta")" ]] || return 1
		policy=$(_routine_sync_policy "$repo" "$default_branch") || return 1
	fi
	while IFS=$'\t' read -r path status; do
		# Every admitted output, not only content-checked ones, must be regular.
		if [[ "$key" == "$_ROUTINE_SYNC_KEY" ]]; then
			_is_sync_workflow_output "$path" || return 1
			blob=$(_routine_tree_blob "$tree" "$path") || return 1
			_routine_sync_content "$repo" "$path" "$status" "$blob" "$merge_base" "$policy" || return 1
			continue
		fi
		_is_declared_output "$path" || return 1
		blob=$(_routine_tree_blob "$tree" "$path") || return 1
		_routine_scope_content "$repo" "$path" "$status" "$blob" "$merge_base" || return 1
	done <<<"$listing"
	# Refuse if metadata moved while evidence was read; the evidence itself is
	# already pinned to $head, so this guards body/labels/state.
	fresh=$(gh api "repos/$repo/pulls/$pr_number") || return 1
	[[ "$(jq -Sc '{head:.head.sha,base:.base.sha,body,labels,state,draft,changed_files}' <<<"$fresh")" == \
		"$(jq -Sc '{head:.head.sha,base:.base.sha,body,labels,state,draft,changed_files}' <<<"$meta")" ]] || return 1
	# Bind the merge to the admitted head: full-loop pins this SHA as
	# FULL_LOOP_EXPECTED_PR_HEAD_SHA, so the transport refuses any other head.
	if [[ -n "${WORKER_BRIEFED_PLANNING_HEAD_FILE:-}" ]]; then
		printf '%s\n' "$head" >"$WORKER_BRIEFED_PLANNING_HEAD_FILE" || return 1
	fi
	return 0
}
