#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../session-distill-helper.sh"

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

resolve_ids() {
	local directory="$1"
	shift
	(
		cd "$directory"
		# shellcheck disable=SC2016 # Variables intentionally expand in the child shell after sourcing.
		env "$@" bash -c 'source "$1"; printf "%s|%s\n" "$SESSION_ID" "$SAFE_SESSION_ID"' bash "$HELPER"
	)
	return 0
}

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/repository"
git -C "$tmp_dir/repository" init -q -b 'feature/private-path'

first=$(resolve_ids "$tmp_dir/repository" -u AIDEVOPS_SESSION_ID -u OPENCODE_SESSION_ID -u CLAUDE_SESSION_ID)
second=$(resolve_ids "$tmp_dir/repository" -u AIDEVOPS_SESSION_ID -u OPENCODE_SESSION_ID -u CLAUDE_SESSION_ID)
[[ "$first" == "$second" ]] || fail "fallback ID is not deterministic"
[[ "$first" =~ ^[0-9a-f]{12}-feature/private-path\|[0-9a-f]{12}-feature_private-path$ ]] || fail "fallback ID format or sanitization changed: $first"
[[ "$first" != *"$tmp_dir"* ]] || fail "fallback ID exposes the repository path"

outside_first=$(resolve_ids "$tmp_dir" -u AIDEVOPS_SESSION_ID -u OPENCODE_SESSION_ID -u CLAUDE_SESSION_ID)
outside_second=$(resolve_ids "$tmp_dir" -u AIDEVOPS_SESSION_ID -u OPENCODE_SESSION_ID -u CLAUDE_SESSION_ID)
[[ "$outside_first" == "$outside_second" ]] || fail "non-repository fallback ID is not deterministic"
[[ "$outside_first" =~ ^[0-9a-f]{12}-unknown\|[0-9a-f]{12}-unknown$ ]] || fail "non-repository fallback ID format changed: $outside_first"
[[ "$outside_first" != *"$tmp_dir"* ]] || fail "non-repository fallback ID exposes the working path"

[[ "$(resolve_ids "$tmp_dir" AIDEVOPS_SESSION_ID='aidevops/id' OPENCODE_SESSION_ID='opencode/id' CLAUDE_SESSION_ID='claude/id')" == 'aidevops/id|aidevops_id' ]] || fail "AIDEVOPS_SESSION_ID did not take precedence"
[[ "$(resolve_ids "$tmp_dir" -u AIDEVOPS_SESSION_ID OPENCODE_SESSION_ID='opencode/id' CLAUDE_SESSION_ID='claude/id')" == 'opencode/id|opencode_id' ]] || fail "OPENCODE_SESSION_ID did not take precedence"
[[ "$(resolve_ids "$tmp_dir" -u AIDEVOPS_SESSION_ID -u OPENCODE_SESSION_ID CLAUDE_SESSION_ID='claude/id')" == 'claude/id|claude_id' ]] || fail "CLAUDE_SESSION_ID did not take precedence"

printf 'PASS: session distill session ID fallback\n'
