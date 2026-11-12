#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#37876: resolved debt closes only with pinned remote measurement evidence.
set -euo pipefail
SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR_TEST}/../pulse-dispatch-large-file-gate.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
LOGFILE="$TMP/pulse.log"
LARGE_FILE_LINE_THRESHOLD=2000
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BODY='generator=large-file-simplification-gate cited_file=target.sh threshold=2000'
MATCHES='[{"number":12,"body":"generator=large-file-simplification-gate cited_file=target.sh threshold=2000"},{"number":13,"body":"generator=large-file-simplification-gate cited_file=target.sh threshold=2000"},{"number":14,"body":"generator=large-file-simplification-gate cited_file=target.sh.bak threshold=2000"}]'
CONTENT=$(jq -n '{type:"file",encoding:"base64",content:("one\ntwo\n" | @base64)}')
FAIL=""

gh_issue_list() {
	[[ "$FAIL" != search ]] || return 1
	printf '%s' "$MATCHES"
	return 0
}
gh_issue_view() {
	printf 'file-size-debt'
	return 0
}
gh() {
	local kind="$1" target="$2"
	[[ "$FAIL" != api ]] || return 1
	if [[ "$kind" == api ]]; then
		case "$target" in
		repos/owner/repo) printf main ;;
		repos/owner/repo/commits/main) printf '%s' "$SHA" ;;
		--method)
			[[ "$*" == *"ref=$SHA"* ]] || return 1
			[[ "$FAIL" != content ]] || return 1
			printf '%s' "$CONTENT"
			;;
		*) return 1 ;;
		esac
	elif [[ "$kind" == issue && "$target" == close ]]; then
		[[ "$FAIL" != close ]] || return 1
		printf '%s\n' "$*" >>"$TMP/closes"
	else
		return 1
	fi
	return 0
}

# Exercise the actual orchestrator: closure precedes the debt-label exemption
# and returns a gate result so a closed candidate cannot be dispatched.
_issue_targets_large_files 12 owner/repo "$BODY" "$TMP"
[[ $(wc -l <"$TMP/closes") -eq 2 ]]
rg -q -- 'close 12 .*--reason completed.*2 lines.*aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$TMP/closes"
if rg -q 'close 14 ' "$TMP/closes"; then
	exit 1
fi
printf 'PASS: exact-marker canonical and duplicate closure with pinned evidence\n'

# Search lag/failure must not leave the verified current issue open.
SAVED_MATCHES="$MATCHES"
for FAIL in search empty; do
	: >"$TMP/closes"
	[[ "$FAIL" != empty ]] || MATCHES='[]'
	_large_file_gate_close_resolved_debt_issues 12 owner/repo "$BODY"
	[[ $(wc -l <"$TMP/closes") -eq 1 ]]
	rg -q -- 'close 12 ' "$TMP/closes"
done
MATCHES="$SAVED_MATCHES"
printf 'PASS: current issue closes when search fails or omits it\n'

for FAIL in api content close; do
	: >"$TMP/closes"
	if _large_file_gate_close_resolved_debt_issues 12 owner/repo "$BODY"; then
		printf 'FAIL: accepted %s failure\n' "$FAIL"
		exit 1
	fi
	[[ ! -s "$TMP/closes" ]]
done
FAIL=""
for CONTENT in \
	"$(jq -n '{type:"file",encoding:"base64",content:(("x\n" * 2000) | @base64)}')" \
	"$(jq -n '{type:"file",encoding:"base64",content:(("x\n" * 2100) | @base64)}')" \
	'{"type":"dir"}' 'invalid'; do
	if _large_file_gate_close_resolved_debt_issues 12 owner/repo "$BODY"; then
		printf 'FAIL: accepted oversized or unavailable content\n'
		exit 1
	fi
	[[ ! -s "$TMP/closes" ]]
done
printf 'PASS: threshold equality, oversized files, and API/measurement failures preserve issues\n'
