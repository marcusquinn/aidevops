#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Shared protected release identity; safe to source without runtime side effects.

protected_release_pr() {
	local head_ref="$1"
	local labels_csv="$2"
	[[ ",${labels_csv}," == *",release,"* ]] || return 1
	[[ "$head_ref" =~ ^chore/release-v[0-9]+\.[0-9]+\.[0-9]+-provenance$ ]] || return 1
	return 0
}

protected_release_head_matches_staged() {
	local repo_path="$1"
	local head_ref="$2"
	local head_oid="$3"
	local tag_name="${head_ref#chore/release-}" staged_oid="" tag_object="" release_oid=""
	local remote_ref="" tag_header="" envelope_parents=""
	protected_release_pr "$head_ref" release || return 1
	[[ -n "$repo_path" && -n "$head_oid" ]] || return 1
	tag_name="${tag_name%-provenance}"
	# aidevops:trust-boundary — read remote evidence, never a stale local ref.
	remote_ref=$(GIT_TERMINAL_PROMPT=0 timeout_sec 30 git -C "$repo_path" ls-remote --exit-code origin "refs/aidevops/release-tags/${tag_name}" 2>/dev/null) || return 1
	staged_oid="${remote_ref%%[[:space:]]*}"
	[[ "$staged_oid" =~ ^[0-9a-f]{40}$ ]] || return 1
	GIT_TERMINAL_PROMPT=0 timeout_sec 30 git -C "$repo_path" fetch --quiet --no-tags --no-write-fetch-head origin "refs/aidevops/release-tags/${tag_name}" 2>/dev/null || return 1
	# The staging commit is an envelope, not the signed release commit. Recover
	# the raw annotated tag without creating or replacing any public tag ref.
	tag_object=$(git -C "$repo_path" cat-file blob "${staged_oid}:tag" 2>/dev/null |
		git -C "$repo_path" hash-object -t tag -w --stdin) || return 1
	git -C "$repo_path" verify-tag "$tag_object" >/dev/null 2>&1 || return 1
	tag_header=$(git -C "$repo_path" cat-file tag "$tag_object" | awk '/^$/ {exit} /^tag / {print substr($0, 5)}') || return 1
	[[ "$tag_header" == "$tag_name" ]] || return 1
	release_oid=$(git -C "$repo_path" rev-parse --verify "${tag_object}^{commit}" 2>/dev/null) || return 1
	envelope_parents=$(git -C "$repo_path" show -s --format=%P "$staged_oid") || return 1
	[[ "$envelope_parents" == "$release_oid" && "$head_oid" == "$release_oid" ]] || return 1
	return 0
}
