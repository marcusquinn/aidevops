#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

repo_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
index_file="$repo_root/.agents/tools/video/remotion.md"
consumer_file="$repo_root/.agents/content/heygen-skill/rules-remotion-integration.md"
registry_file="$repo_root/.agents/configs/skill-sources.json"
expected_count=28

if grep -Fq "tools/video/remotion/" "$index_file" "$consumer_file" "$registry_file"; then
	printf 'Stale nested Remotion chapter path found:\n' >&2
	grep -Fn "tools/video/remotion/" "$index_file" "$consumer_file" "$registry_file" >&2
	exit 1
fi

chapter_refs=$(grep -oE 'tools/video/remotion-[[:alnum:]-]+\.md' "$index_file" | LC_ALL=C sort -u)
chapter_count=$(printf '%s\n' "$chapter_refs" | grep -c '.')

if [[ "$chapter_count" -ne "$expected_count" ]]; then
	printf 'Expected %d unique Remotion chapter references, found %d\n' "$expected_count" "$chapter_count" >&2
	exit 1
fi

while IFS= read -r chapter_ref; do
	[[ -n "$chapter_ref" ]] || continue
	tracked_path=".agents/$chapter_ref"
	if [[ ! -f "$repo_root/$tracked_path" ]]; then
		printf 'Remotion chapter reference does not exist: %s\n' "$tracked_path" >&2
		exit 1
	fi
	if ! git -C "$repo_root" ls-files --error-unmatch "$tracked_path" >/dev/null 2>&1; then
		printf 'Remotion chapter reference is not tracked: %s\n' "$tracked_path" >&2
		exit 1
	fi
done <<<"$chapter_refs"

printf 'PASS: %d flat Remotion chapter references resolve to tracked files\n' "$chapter_count"
