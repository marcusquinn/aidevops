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
	local tag_name="${head_ref#chore/release-}" staged_oid=""
	protected_release_pr "$head_ref" release || return 1
	[[ -n "$repo_path" && -n "$head_oid" ]] || return 1
	tag_name="${tag_name%-provenance}"
	# aidevops:trust-boundary — missing staging evidence never authorizes a merge.
	staged_oid=$(git -C "$repo_path" rev-parse --verify "refs/aidevops/release-tags/${tag_name}^{commit}" 2>/dev/null) || return 1
	[[ "$head_oid" == "$staged_oid" ]] || return 1
	return 0
}
