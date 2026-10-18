#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

# Emit a YAML-ready immutable release ref, including its human-readable tag.
# Never fall back to main: an unavailable release must not install an unsafe pin.
workflow_release_ref() {
	local repo="${1:-marcusquinn/aidevops}"
	local tag sha
	tag=$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null) || return 1
	[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	sha=$(gh api "repos/$repo/commits/$tag" --jq '.sha' 2>/dev/null) || return 1
	[[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]] || return 1
	printf '%s # %s\n' "$sha" "$tag"
	return 0
}
