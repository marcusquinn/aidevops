#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Manual release hold: other PRs refused, release PR exempt, expiry fails open.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
STORE=$(mktemp -d)
trap 'rm -rf "$STORE"' EXIT

# shellcheck source=../manual-release-hold-helper.sh
source "${SCRIPT_DIR}/manual-release-hold-helper.sh"

FAKE_NOW=1000000
_mrh_now() {
	printf '%s\n' "$FAKE_NOW"
	return 0
}

# In-memory fake of the GitHub endpoints the helper uses.
_mrh_api() {
	local path="$1"
	shift
	local input="" ref=""
	[[ " $* " != *" --input - "* ]] || input=$(cat)
	case "$path" in
	repos/*/contents/*)
		ref="${path##*ref=refs/heads/}"
		ref="${ref//\//__}"
		[[ -f "$STORE/ref-$ref" ]] || {
			echo "gh: Not Found (HTTP 404)" >&2
			return 1
		}
		base64 -w0 <"$STORE/ref-$ref" 2>/dev/null || base64 <"$STORE/ref-$ref" | tr -d '\n'
		;;
	repos/*/git/blobs) printf '%s' "$input" >"$STORE/blob" && printf 'a%.0s' {1..40} ;;
	repos/*/git/trees) printf 'b%.0s' {1..40} ;;
	repos/*/git/commits) printf 'c%.0s' {1..40} ;;
	repos/*/git/refs)
		ref=$(jq -r '.ref | sub("refs/heads/"; "") | gsub("/"; "__")' <<<"$input")
		[[ ! -f "$STORE/ref-$ref" ]] || return 1
		jq -r .content "$STORE/blob" >"$STORE/ref-$ref"
		;;
	repos/*/git/refs/heads/*)
		ref="${path##*/git/refs/heads/}"
		ref="${ref//\//__}"
		if [[ " $* " == *" DELETE "* ]]; then
			rm -f "$STORE/ref-$ref"
		else
			jq -r .content "$STORE/blob" >"$STORE/ref-$ref"
		fi
		;;
	search/issues) : ;;
	*) return 1 ;;
	esac
	return 0
}

FAILED=0
expect() {
	local name="$1"
	local want="$2"
	local got="$3"
	if [[ "$want" == "$got" ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s (want %s got %s)\n' "$name" "$want" "$got"
		FAILED=$((FAILED + 1))
	fi
	return 0
}

rc=0
manual_release_hold_check own/repo 5 2>/dev/null || rc=$?
expect "no hold allows merge" 0 "$rc"

AIDEVOPS_OPENCODE_SESSION_ID=ses_owner cmd_hold own/repo --pr 10 --version v1.2.3 >/dev/null
rc=0
manual_release_hold_check own/repo 11 2>"$STORE/err" || rc=$?
expect "other PR refused" 1 "$rc"
rc=0
grep -q "ses_owner" "$STORE/err" || rc=1
expect "hold owner named" 0 "$rc"
rc=0
manual_release_hold_check own/repo 10 2>/dev/null || rc=$?
expect "release PR exempt" 0 "$rc"
rc=0
cmd_hold own/repo --pr 12 >/dev/null 2>&1 || rc=$?
expect "second hold refused" 1 "$rc"

FAKE_NOW=$((FAKE_NOW + 61 * 60))
rc=0
manual_release_hold_check own/repo 11 2>/dev/null || rc=$?
expect "expired hold ignored" 0 "$rc"

FAKE_NOW=1000000
cmd_hold own/repo --pr 10 --ttl-minutes 60 >/dev/null
cmd_unhold own/repo >/dev/null
rc=0
manual_release_hold_check own/repo 11 2>/dev/null || rc=$?
expect "released hold allows merge" 0 "$rc"

_mrh_api() {
	echo "boom" >&2
	return 1
}
rc=0
manual_release_hold_check own/repo 11 2>/dev/null || rc=$?
expect "API error fails open" 0 "$rc"

[[ "$FAILED" -eq 0 ]]
