#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Merge Prospective Objects -- pinned PR refs and isolated Git store
# =============================================================================
# Extracted verbatim from full-loop-helper-merge.sh (GH#30748). Reads the
# fresh PR head/base refs over REST, validates the target remote, and builds
# the config-isolated, lazy-fetch-free object store that
# _merge_guard_prospective_todo (still in full-loop-helper-merge.sh) uses to
# merge the exact PR head into the fresh base without touching the caller's
# Git context.
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-merge-prospective.sh"
#        (sourced by full-loop-helper-merge.sh; do not execute directly)
#
# Dependencies:
#   - shared-constants.sh (print_error, timeout_sec)
#   - full-loop-helper-merge.sh (_flm_gh_read)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_MERGE_PROSPECTIVE_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_MERGE_PROSPECTIVE_LIB_LOADED=1

_merge_fetch_head_sha_rest() {
	local pr_number="$1"
	local repo="$2"
	local head_sha="" err_file="" rc=0
	err_file=$(mktemp "${TMPDIR:-/tmp}/merge-head-sha.XXXXXX") || err_file="/dev/null"
	head_sha=$(_flm_gh_read gh api "repos/${repo}/pulls/${pr_number}" --jq '.head.sha // empty' 2>"$err_file") || rc=$?
	if [[ "$rc" -ne 0 || -z "$head_sha" ]]; then
		# Surface transport diagnostics (e.g. local-admission deferral) on stderr
		# so the caller can distinguish pacing from a real failure.
		if [[ "$err_file" != /dev/null ]]; then
			cat "$err_file" >&2
			rm -f "$err_file"
		fi
		return 1
	fi
	[[ "$err_file" == /dev/null ]] || rm -f "$err_file"
	printf '%s\n' "$head_sha"
	return 0
}

# Return the fresh base ref, base SHA, head SHA, base repository, and clone URL
# that GitHub currently binds to the PR. These fields form the pinned evidence
# boundary for a local prospective merge-tree check and keep explicit-repository
# merges independent of the caller's current Git remote.
_merge_fetch_pr_refs_rest() {
	local pr_number="$1"
	local repo="$2"
	local refs=""
	refs=$(_flm_gh_read gh api "repos/${repo}/pulls/${pr_number}" \
		--jq '[.base.ref // empty, .base.sha // empty, .head.sha // empty, .base.repo.full_name // empty, .base.repo.clone_url // empty] | @tsv') || return 1
	[[ "$refs" == *$'\t'*$'\t'*$'\t'*$'\t'* ]] || return 1
	printf '%s\n' "$refs"
	return 0
}

_merge_validate_target_remote_url() {
	local target_repo="$1"
	local remote_url="$2"
	local git_host="${GH_HOST:-github.com}"
	local expected_url=""
	local normalized_remote_url=""
	local normalized_expected_url=""
	[[ "$git_host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
	[[ "$target_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	expected_url="https://${git_host}/${target_repo}.git"
	normalized_remote_url=$(printf '%s' "$remote_url" | tr '[:upper:]' '[:lower:]')
	normalized_expected_url=$(printf '%s' "$expected_url" | tr '[:upper:]' '[:lower:]')
	[[ "$normalized_remote_url" == "$normalized_expected_url" ]] || return 1
	return 0
}

_merge_fetch_pinned_commit_objects() {
	local pr_number="$1"
	local base_ref="$2"
	local base_sha="$3"
	local head_sha="$4"
	local object_repo="${5:-}"
	local remote_url="${6:-}"
	local real_git="${7:-}"
	local fetched_sha=""
	if [[ -z "$object_repo" ]]; then
		git cat-file -e "${base_sha}^{commit}" 2>/dev/null ||
			git fetch --quiet --no-tags origin "refs/heads/${base_ref}" || return 1
		git cat-file -e "${head_sha}^{commit}" 2>/dev/null ||
			git fetch --quiet --no-tags origin "refs/pull/${pr_number}/head" || return 1
		git cat-file -e "${base_sha}^{commit}" 2>/dev/null || return 1
		git cat-file -e "${head_sha}^{commit}" 2>/dev/null || return 1
		return 0
	fi

	[[ -x "$real_git" && -n "$remote_url" ]] || return 1
	_merge_configure_prospective_remote "$real_git" "$object_repo" "$remote_url" || return 1
	if ! _merge_run_repository_isolated_git "$real_git" -C "$object_repo" cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
		_merge_fetch_partial_objects "$real_git" "$object_repo" "" \
			-- "$_MERGE_PROSPECTIVE_REMOTE" "refs/heads/${base_ref}" || return 1
		fetched_sha=$(_merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
			rev-parse FETCH_HEAD 2>/dev/null) || return 1
		if [[ "$fetched_sha" != "$base_sha" ]]; then
			_merge_fetch_partial_objects "$real_git" "$object_repo" "" \
				-- "$_MERGE_PROSPECTIVE_REMOTE" "$base_sha" || return 1
			fetched_sha=$(_merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
				rev-parse FETCH_HEAD 2>/dev/null) || return 1
			[[ "$fetched_sha" == "$base_sha" ]] || return 1
		fi
	fi
	if ! _merge_run_repository_isolated_git "$real_git" -C "$object_repo" cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
		_merge_fetch_partial_objects "$real_git" "$object_repo" "" \
			-- "$_MERGE_PROSPECTIVE_REMOTE" "refs/pull/${pr_number}/head" || return 1
		fetched_sha=$(_merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
			rev-parse FETCH_HEAD 2>/dev/null) || return 1
		[[ "$fetched_sha" == "$head_sha" ]] || return 1
	fi
	_merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
		cat-file -e "${base_sha}^{commit}" 2>/dev/null || return 1
	_merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
		cat-file -e "${head_sha}^{commit}" 2>/dev/null || return 1
	_merge_prefetch_prospective_blobs "$real_git" "$object_repo" \
		"$base_sha" "$head_sha" || return 1
	return 0
}

# Dedicated remote for the isolated object store. A named remote is required
# for partial fetch from path and URL remotes alike; the name is unusual so
# caller-level remote configuration cannot shadow the pinned URL.
_MERGE_PROSPECTIVE_REMOTE="aidevops-prospective-target"

_merge_configure_prospective_remote() {
	local real_git="$1"
	local object_repo="$2"
	local remote_url="$3"
	local remote_key="remote.${_MERGE_PROSPECTIVE_REMOTE}"
	local configured_urls=""
	_merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
		config --local core.repositoryformatversion 1 || return 1
	_merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
		config --local "${remote_key}.url" "$remote_url" || return 1
	# Fail closed if any other config scope adds or overrides the pinned URL.
	configured_urls=$(_merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
		config --get-all "${remote_key}.url") || return 1
	[[ "$configured_urls" == "$remote_url" ]] || return 1
	_merge_prospective_store_is_lazy_fetch_free "$real_git" "$object_repo" || {
		print_error "Merge blocked: Git configuration marks a remote as a promisor (remote.<name>.promisor); prospective TODO validation refuses implicit object transfer"
		return 1
	}
	return 0
}

# Git lazily fetches a missing object only when a promisor remote is
# configured. GIT_NO_LAZY_FETCH (Git 2.44+) also disables that, but older Git
# ignores it (GH#33752), so the store is a partial clone only while an explicit,
# bounded fetch runs. Every other command sees a plain repository in which a
# missing object is an error on every Git version.
_merge_enable_prospective_promisor() {
	local real_git="$1"
	local object_repo="$2"
	local remote_key="remote.${_MERGE_PROSPECTIVE_REMOTE}"
	_merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
		config --local extensions.partialClone "$_MERGE_PROSPECTIVE_REMOTE" || return 1
	_merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
		config --local "${remote_key}.promisor" true || return 1
	_merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
		config --local "${remote_key}.partialclonefilter" blob:none || return 1
	return 0
}

_merge_disable_prospective_promisor() {
	local real_git="$1"
	local object_repo="$2"
	local remote_key="remote.${_MERGE_PROSPECTIVE_REMOTE}"
	local key=""
	local rc=0
	# Fetch may register partial-clone keys itself; remove every local copy.
	for key in extensions.partialClone "${remote_key}.promisor" "${remote_key}.partialclonefilter"; do
		rc=0
		_merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
			config --local --unset-all "$key" || rc=$?
		# Exit 5 means the key was not set, which is the desired state.
		[[ "$rc" -eq 0 || "$rc" -eq 5 ]] || return 1
	done
	_merge_prospective_store_is_lazy_fetch_free "$real_git" "$object_repo" || return 1
	return 0
}

# Succeeds only when no config scope makes any remote a promisor for the store.
_merge_prospective_store_is_lazy_fetch_free() {
	local real_git="$1"
	local object_repo="$2"
	local promisor_entries=""
	local rc=0
	# extensions.partialClone is honoured only in repository-local config.
	if _merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
		config --local --get extensions.partialClone >/dev/null 2>&1; then
		return 1
	fi
	promisor_entries=$(_merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
		config --get-regexp '^remote\..*\.promisor$' 2>/dev/null) || rc=$?
	# Exit 1 means no promisor key exists in any scope.
	[[ "$rc" -eq 1 ]] && return 0
	[[ "$rc" -eq 0 ]] || return 1
	# A valueless boolean key means true; only explicit false values are safe.
	printf '%s\n' "$promisor_entries" | awk '
		{ value = tolower($2) }
		value != "false" && value != "no" && value != "off" && value != "0" { unsafe = 1 }
		END { exit unsafe }
	' || return 1
	return 0
}

# Fetch from the pinned remote without blob content. Commits and trees are
# enough for merge-base discovery; blobs the prospective merge can read are
# requested explicitly afterwards, so unrelated history never crosses the
# network (GH#32641). Every transfer is time-bounded and a server that ignores
# the filter fails closed instead of starting an unbounded full transfer.
# The promisor configuration exists only for the duration of this fetch.
_merge_fetch_partial_objects() {
	local real_git="$1"
	local object_repo="$2"
	local stdin_file="$3"
	shift 3
	local stderr_file="${object_repo%/*}/fetch.stderr"
	local timeout_secs="${AIDEVOPS_PROSPECTIVE_FETCH_TIMEOUT:-300}"
	local rc=0
	[[ "$timeout_secs" =~ ^[1-9][0-9]*$ ]] || timeout_secs=300
	_merge_enable_prospective_promisor "$real_git" "$object_repo" || {
		print_error "Merge blocked: unable to configure the bounded prospective fetch"
		return 1
	}
	_merge_run_bounded_isolated_git "$timeout_secs" "$stdin_file" "$real_git" -C "$object_repo" \
		fetch --quiet --no-tags --recurse-submodules=no --filter=blob:none "$@" \
		2>"$stderr_file" || rc=$?
	_merge_disable_prospective_promisor "$real_git" "$object_repo" || {
		print_error "Merge blocked: unable to disable implicit object transfer after the bounded prospective fetch"
		return 1
	}
	if [[ "$rc" -eq 124 || "$rc" -eq 137 || "$rc" -eq 143 ]]; then
		print_error "Merge blocked: prospective object transfer exceeded ${timeout_secs}s (AIDEVOPS_PROSPECTIVE_FETCH_TIMEOUT)"
		return 1
	fi
	if [[ "$rc" -ne 0 ]]; then
		cat "$stderr_file" >&2 2>/dev/null || true
		return 1
	fi
	if grep -qi 'filtering not recognized by server' "$stderr_file" 2>/dev/null; then
		print_error "Merge blocked: target remote does not support partial fetch; refusing an unbounded object transfer"
		return 1
	fi
	return 0
}

# Upper bound on merge pairs enumerated for one prospective merge. Ordinary
# histories need one pair; each criss-cross level adds pairs of merge bases.
_MERGE_PROSPECTIVE_PAIR_LIMIT=32

# Materialize only blobs a prospective merge can read: every path changed
# between a merge base and either side, plus both sides' TODO.md. Unchanged
# paths resolve by object ID without content. With several merge bases,
# merge-ort first merges those bases into a virtual base, which reads blobs
# changed between the bases and their own merge bases (GH#33513), so pairs of
# merge bases are enumerated recursively. Outside the explicit fetch the store
# has no promisor remote, and every wanted blob is verified present, so a
# missed object fails closed with a count instead of transferring more data.
_merge_prefetch_prospective_blobs() {
	local real_git="$1"
	local object_repo="$2"
	local base_sha="$3"
	local head_sha="$4"
	local context_root="${object_repo%/*}"
	local candidates="${context_root}/prospective-blob-candidates"
	local wanted="${context_root}/prospective-blobs"
	local -a pairs=("${base_sha} ${head_sha}")
	local -a bases=()
	local seen_pairs=" "
	local pair_index=0
	local pair=""
	local left=""
	local right=""
	local merge_bases=""
	local merge_base=""
	local side=""
	local todo_oid=""
	local i=0
	local j=0
	local rc=0
	: >"$candidates" || return 1
	while [[ "$pair_index" -lt "${#pairs[@]}" ]]; do
		if [[ "$pair_index" -ge "$_MERGE_PROSPECTIVE_PAIR_LIMIT" ]]; then
			print_error "Merge blocked: prospective merge history exceeds ${_MERGE_PROSPECTIVE_PAIR_LIMIT} merge-base pairs"
			return 1
		fi
		pair="${pairs[$pair_index]}"
		pair_index=$((pair_index + 1))
		left="${pair% *}"
		right="${pair#* }"
		rc=0
		merge_bases=$(_merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
			merge-base --all "$left" "$right" 2>/dev/null) || rc=$?
		# Exit 1 means unrelated histories; merge-tree reports that itself.
		[[ "$rc" -eq 0 || "$rc" -eq 1 ]] || return 1
		bases=()
		for merge_base in $merge_bases; do
			bases+=("$merge_base")
			for side in "$left" "$right"; do
				_merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
					diff-tree -r --no-renames "$merge_base" "$side" >"${candidates}.raw" || return 1
				# Raw lines: ":<old mode> <new mode> <old oid> <new oid> <status>\t<path>".
				# Gitlink (160000) entries name commits in other repositories.
				awk '$1 != ":160000" { print $3 } $2 != "160000" { print $4 }' \
					"${candidates}.raw" >>"$candidates" || return 1
			done
		done
		[[ "${#bases[@]}" -gt 1 ]] || continue
		for ((i = 0; i < ${#bases[@]}; i++)); do
			for ((j = i + 1; j < ${#bases[@]}; j++)); do
				pair="${bases[$i]} ${bases[$j]}"
				[[ "$seen_pairs" == *" ${pair} "* ]] && continue
				seen_pairs+="${pair} "
				pairs+=("$pair")
			done
		done
	done
	for side in "$base_sha" "$head_sha"; do
		if todo_oid=$(_merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
			rev-parse --verify --quiet "${side}:TODO.md"); then
			printf '%s\n' "$todo_oid" >>"$candidates" || return 1
		fi
	done
	awk '!/^0+$/ && NF && !seen[$0]++' "$candidates" >"$wanted" || return 1
	[[ -s "$wanted" ]] || return 0
	_merge_fetch_partial_objects "$real_git" "$object_repo" "$wanted" \
		--no-write-fetch-head --stdin -- "$_MERGE_PROSPECTIVE_REMOTE" || return 1
	_merge_verify_prospective_blobs "$real_git" "$object_repo" "$wanted" || return 1
	return 0
}

# A zero fetch exit status does not prove every wanted object arrived. Check
# presence locally (no promisor remote, so no lazy fetch) and report only
# counts, never paths.
_merge_verify_prospective_blobs() {
	local real_git="$1"
	local object_repo="$2"
	local wanted="$3"
	local report="${wanted}.present"
	local wanted_count=0
	local missing_count=0
	_merge_run_repository_isolated_git "$real_git" -C "$object_repo" \
		cat-file --batch-check <"$wanted" >"$report" 2>/dev/null || {
		print_error "Merge blocked: unable to verify prospective blob presence"
		return 1
	}
	wanted_count=$(awk 'END { print NR }' "$wanted")
	missing_count=$(awk '$2 != "blob" { n++ } END { print n + 0 }' "$report")
	if [[ "$missing_count" -ne 0 ]]; then
		print_error "Merge blocked: ${missing_count} of ${wanted_count} required prospective blobs were not materialized by the bounded fetch"
		return 1
	fi
	return 0
}

_merge_unset_repository_git_env() {
	unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_ATTR_SOURCE GIT_COMMON_DIR GIT_DIR
	unset GIT_EXEC_PATH GIT_GRAFT_FILE GIT_INDEX_FILE GIT_NAMESPACE
	unset GIT_OBJECT_DIRECTORY GIT_QUARANTINE_PATH GIT_REPLACE_REF_BASE
	unset GIT_SHALLOW_FILE GIT_WORK_TREE
	# Partial object stores must never contact a remote implicitly; every
	# transfer goes through the explicit, bounded fetches above. Removing the
	# promisor configuration outside those fetches enforces this on every Git
	# version; GIT_NO_LAZY_FETCH (Git 2.44+) is defence in depth.
	export GIT_NO_LAZY_FETCH=1
	return 0
}

_merge_run_repository_isolated_git() (
	local git_bin="$1"
	shift
	_merge_unset_repository_git_env
	"$git_bin" "$@"
	return $?
)

_merge_run_bounded_isolated_git() (
	local timeout_secs="$1"
	local stdin_file="$2"
	shift 2
	_merge_unset_repository_git_env
	if [[ -n "$stdin_file" ]]; then
		timeout_sec "$timeout_secs" "$@" <"$stdin_file"
		return $?
	fi
	timeout_sec "$timeout_secs" "$@" </dev/null
	return $?
)

_merge_run_config_isolated_git() (
	local real_git="$1"
	local config_root="$2"
	shift 2
	unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM
	export HOME="${config_root}/home" XDG_CONFIG_HOME="${config_root}/xdg"
	export GIT_CONFIG_NOSYSTEM=1 GIT_ATTR_NOSYSTEM=1
	# Config-isolated commands never transfer objects: they run while the store
	# has no promisor remote. Never wait on a credential prompt regardless.
	export GIT_TERMINAL_PROMPT=0
	_merge_run_repository_isolated_git "$real_git" "$@"
	return $?
)

_merge_create_prospective_object_context() {
	local context_root="$1"
	local real_git="$2"
	local object_repo="${context_root}/repository.git"
	[[ -x "$real_git" ]] || return 1
	mkdir -p "${context_root}/home" "${context_root}/xdg" || return 1
	# Do not borrow objects or object-format details from the caller's Git
	# context. This guard is also called by Pulse from a non-Git workspace.
	# The pinned target remote below supplies every object required for validation.
	_merge_run_config_isolated_git "$real_git" "$context_root" -c init.templateDir= \
		-C "$context_root" init --bare --quiet repository.git || return 1
	[[ -d "${object_repo}/objects/info" ]] || return 1
	printf '%s\n' "$object_repo"
	return 0
}

