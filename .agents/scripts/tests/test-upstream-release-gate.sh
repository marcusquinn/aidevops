#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#37696: upstream-release gates unblock a status:blocked issue only when a
# recent upstream tag contains the declared commit and the author is trusted.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../dependency-event-reconciler.sh
source "${SCRIPT_DIR}/../dependency-event-reconciler.sh"

PASS=0
FAIL=0
EDITS=0
ASSOCIATION="OWNER"
COMPARE_STATUS="diverged"
TAGS_FAIL=false
TAG_ORDERING=false
NATIVE_NODES='[]'
DECLARED_STATE="CLOSED"
COMMIT="b6f9284b7b50bc033aeb0ed4b665b05d68060240"
GATE="<!-- aidevops:upstream-release-gate repo=upstream/project commit=${COMMIT} -->"

pass() {
	printf 'PASS: %s\n' "$1"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	printf 'FAIL: %s\n' "$1"
	FAIL=$((FAIL + 1))
	return 0
}

# Deterministic gh double for the calls made by _der_try_unblock.
gh() {
	local args="$*"
	case "$args" in
	"api --paginate --slurp repos/owner/repo/issues/14/comments"*) printf '[[]]\n' ;;
	"api graphql"*)
		jq -cn --argjson nodes "$NATIVE_NODES" '{data:{repository:{issue:{blockedBy:{nodes:$nodes,pageInfo:{hasNextPage:false}}}}}}'
		;;
	"api repos/owner/repo/issues/14 --jq"*) printf '%s\n' "$ASSOCIATION" ;;
	"api repos/upstream/project/tags"*)
		[[ "$TAGS_FAIL" == false ]] || return 1
		if [[ "$TAG_ORDERING" == true ]]; then
			# Reverse-lexical API order: the newest version is fourth.
			printf 'v1.9.9 %s\nv1.9.8 %s\nv1.9.7 %s\nv1.10.0 %s\n' "$(printf 'a%.0s' {1..40})" \
				"$(printf 'b%.0s' {1..40})" "$(printf 'c%.0s' {1..40})" "$(printf 'd%.0s' {1..40})"
		else
			printf '1.2.0 %s\n' "16c00df04e264f4d68db5e10a48127f015c7824b"
		fi
		;;
	"api repos/upstream/project/compare/${COMMIT}...dddddddddddddddddddddddddddddddddddddddd"*) printf 'ahead\n' ;;
	"api repos/upstream/project/compare/"*) printf '%s\n' "$COMPARE_STATUS" ;;
	"issue view 10 --repo owner/repo --json state,stateReason"*) printf '%s:COMPLETED\n' "$DECLARED_STATE" ;;
	"issue view 14 --repo owner/repo --json labels"*) printf 'status:blocked,auto-dispatch\n' ;;
	"issue edit 14 --repo owner/repo --remove-label status:blocked --add-label status:available") EDITS=$((EDITS + 1)) ;;
	*)
		printf 'unexpected gh call: %s\n' "$args" >&2
		return 1
		;;
	esac
	return 0
}

candidate_json() {
	local body="$1"
	jq -cn --arg body "$body" '{number:14,state:"OPEN",title:"t6: gated",body:$body,
		repository:{nameWithOwner:"owner/repo"},
		labels:{nodes:[{name:"status:blocked"},{name:"auto-dispatch"}],pageInfo:{hasNextPage:false}}}'
	return 0
}

# $1 expected rc, $2 expected edit count, $3 body, $4 name
check() {
	local expected_rc="$1" expected_edits="$2" body="$3" name="$4" rc=0
	EDITS=0
	_der_try_unblock owner/repo 14 "$(candidate_json "$body")" 2>/dev/null || rc=$?
	if [[ "$rc" == "$expected_rc" && "$EDITS" == "$expected_edits" ]]; then
		pass "$name"
	else
		fail "$name (rc=$rc edits=$EDITS; expected rc=$expected_rc edits=$expected_edits)"
	fi
	return 0
}

COMPARE_STATUS="diverged"
check "$DER_NOT_READY" 0 "Blocked by: external upstream release.
${GATE}" "untagged commit keeps the issue blocked"

COMPARE_STATUS="ahead"
check 0 1 "Blocked by: external upstream release.
${GATE}" "tagged commit unblocks a gate-only issue"

COMPARE_STATUS="identical"
check 0 1 "${GATE}" "tag at the exact commit unblocks"

COMPARE_STATUS="ahead"
ASSOCIATION="CONTRIBUTOR"
check "$DER_NOT_READY" 0 "${GATE}" "untrusted author cannot unblock through a gate"
ASSOCIATION="OWNER"

TAGS_FAIL=true
check 1 0 "${GATE}" "upstream API failure leaves the issue blocked"
TAGS_FAIL=false

check "$DER_NOT_READY" 0 "${GATE}
<!-- aidevops:upstream-release-gate repo=upstream/project commit=abc -->" "malformed second gate fails closed"

check 0 0 "${GATE}
On hold for maintainer" "operational hold wins over a satisfied gate"

DECLARED_STATE="OPEN"
check "$DER_NOT_READY" 0 "Blocked by #10
${GATE}" "open declared blocker still blocks a satisfied gate"
DECLARED_STATE="CLOSED"
check 0 1 "Blocked by #10
${GATE}" "closed declared blocker plus satisfied gate unblocks"

COMPARE_STATUS="diverged"
NATIVE_NODES='[{"number":10,"state":"CLOSED","stateReason":"COMPLETED","repository":{"nameWithOwner":"owner/repo"}}]'
check "$DER_NOT_READY" 0 "${GATE}" "closed native blocker does not bypass an unsatisfied gate"
NATIVE_NODES='[]'

check 0 0 "Blocked by: external, prose only" "issue without blockers or gates is left to its owning mechanism"

TAG_ORDERING=true
check 0 1 "${GATE}" "newest tag is found by version order, not API name order"
TAG_ORDERING=false

# Documentation examples and prose mentions are not gates (GH#37696 review).
COMPARE_STATUS="diverged"
check 0 1 $'Blocked by #10\n```text\n<!-- aidevops:upstream-release-gate repo=OWNER/REPO commit=SHA -->\n```' \
	"fenced placeholder example does not change a declared-blocker issue"
check 0 1 $'Blocked by #10\n~~~~\n'"${GATE}"$'\n~~~\nstill fenced\n~~~~' "fenced well-formed example is not a live gate"
check 0 1 $'Blocked by #10\nUse the `<!-- aidevops:upstream-release-gate ... -->` marker.' "inline prose mention is not a gate"
check "$DER_NOT_READY" 0 "  ${GATE}  " "indented live gate is still honoured"

COMPARE_STATUS="ahead"
NATIVE_NODES='[{"number":11,"state":"CLOSED","stateReason":"COMPLETED","repository":{"nameWithOwner":"owner/repo"}}]'
DECLARED_STATE="OPEN"
check "$DER_NOT_READY" 0 "Blocked by #10
${GATE}" "gated issue honours an open declared blocker even with closed native edges"
DECLARED_STATE="CLOSED"
NATIVE_NODES='[]'

many=""
for n in 1 2 3 4 5 6; do
	many="${many}<!-- aidevops:upstream-release-gate repo=upstream/project${n} commit=${COMMIT} -->"$'\n'
done
check "$DER_NOT_READY" 0 "$many" "more than five gates fail closed without API calls"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
exit $?
