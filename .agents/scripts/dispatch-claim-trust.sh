#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared permission-backed author trust for dispatch claim and lease readers.

# shellcheck source=shared-gh-collaborator-permission.sh
source "${BASH_SOURCE[0]%/*}/shared-gh-collaborator-permission.sh"

# Resolve ambiguous comment authors once per snapshot, never from body fields.
_claim_permission_trusted_authors() {
	local comments_json="$1"
	local repo_slug="$2"
	local candidates login association
	local trusted='[]'
	[[ -n "$repo_slug" ]] || { printf '[]'; return 0; }
	candidates=$(printf '%s' "$comments_json" | jq -r '
		[.[] | select(.author_association == "CONTRIBUTOR" or .author_association == "NONE")
		 | {login:(.author // .user.login // ""), association:.author_association}
		 | select(.login != "")] | unique_by(.login)[] | [.login, .association] | @tsv
	') || { printf '[]'; return 0; }
	while IFS=$'\t' read -r login association; do
		[[ -n "$login" ]] || continue
		#aidevops:trust-boundary -- only authenticated write authority elevates an author.
		if _gh_actor_has_repo_write_authority "$repo_slug" "$login" "$association"; then
			trusted=$(printf '%s' "$trusted" | jq -c --arg login "$login" '. + [$login]')
		fi
	done <<<"$candidates"
	printf '%s' "$trusted"
	return 0
}
