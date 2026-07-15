#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

tag="${1:?release tag is required}"
title="${2:?release title is required}"
notes_file="${3:?release notes file is required}"

verify_publication() {
	local published_tag
	published_tag=$(gh release view "$tag" --json tagName,isDraft \
		--jq 'select(.tagName == "'"$tag"'" and .isDraft == false) | .tagName' 2>/dev/null || true)
	if [[ "$published_tag" == "$tag" ]]; then
		return 0
	fi
	return 1
}

reconcile_metadata() {
	local error_file
	error_file=$(mktemp)
	if gh release edit "$tag" --title "$title" --notes-file "$notes_file" 2>"$error_file"; then
		printf 'Release %s metadata reconciled\n' "$tag"
		rm -f "$error_file"
		return 0
	fi

	if grep -qiE 'HTTP 403|rate limit' "$error_file" && verify_publication; then
		printf '::warning::Release %s is published; metadata reconciliation deferred after API rate limit\n' "$tag"
		rm -f "$error_file"
		return 0
	fi

	printf '::error::Release %s metadata reconciliation failed\n' "$tag" >&2
	cat "$error_file" >&2
	rm -f "$error_file"
	return 1
}

main() {
	if verify_publication; then
		printf 'Release %s publication receipt verified; reconciling metadata\n' "$tag"
		reconcile_metadata
		return $?
	fi

	if gh release create "$tag" --title "$title" --notes-file "$notes_file"; then
		if verify_publication; then
			printf 'Release %s created and publication receipt verified\n' "$tag"
			return 0
		fi
		printf '::error::Release %s creation returned success without a publication receipt\n' "$tag" >&2
		return 1
	fi

	if verify_publication; then
		printf 'Release %s appeared after create failed; reconciling metadata\n' "$tag"
		reconcile_metadata
		return $?
	fi

	printf '::error::Release %s is not published after create failed\n' "$tag" >&2
	return 1
}

main "$@"
