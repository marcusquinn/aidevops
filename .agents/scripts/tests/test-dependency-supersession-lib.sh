#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#34341: a blocker closed as superseded stays outstanding while its trusted
# successor chain is open; everything else keeps closed-means-resolved.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../dependency-supersession-lib.sh
source "${SCRIPT_DIR}/../dependency-supersession-lib.sh"

PASS=0
FAIL=0
TEST_ROOT=$(mktemp -d)
CALL_LOG="${TEST_ROOT}/calls.log"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Rows: number|typename|state|reason|comments-json (oldest first).
FIXTURES=""
GH_FAIL_NUMBER=""
GH_NO_COST=false

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

comment() {
	local association="$1"
	local body="$2"
	jq -cn --arg a "$association" --arg b "$body" '{authorAssociation:$a, body:$b}'
	return 0
}

gh() {
	local arg="" number="" row="" typename="" state="" reason="" comments=""
	[[ "${1:-} ${2:-}" == "api graphql" ]] || return 1
	for arg in "$@"; do
		[[ "$arg" == number=* ]] && number="${arg#number=}"
	done
	printf '%s\n' "$number" >>"$CALL_LOG"
	[[ "$number" != "$GH_FAIL_NUMBER" ]] || return 1
	row=$(grep -m 1 -E "^${number}[|]" <<<"$FIXTURES")
	IFS='|' read -r _ typename state reason comments <<<"$row"
	jq -cn --arg t "$typename" --arg s "$state" --arg r "$reason" \
		--argjson c "${comments:-[]}" --argjson no_cost "$GH_NO_COST" '
		{data:({repository:{issueOrPullRequest:(if $t == "" then null else
			{__typename:$t, state:$s}
			+ (if $t == "Issue" then {stateReason:(if $r == "" then null else $r end), comments:{nodes:$c}} else {} end)
			end)}}
			+ (if $no_cost then {} else {rateLimit:{cost:1}} end))}'
	return 0
}

# Usage: check <expected rc> <name> <reason> [dependant_ref] [detail substring]
check() {
	local expected="$1"
	local name="$2"
	local reason="$3"
	local dependant_ref="${4:-}"
	local detail="${5:-}"
	local rc=0
	: >"$CALL_LOG"
	dep_supersession_outstanding "owner/repo" 10 "$reason" "$dependant_ref" || rc=$?
	if [[ "$rc" -ne "$expected" ]]; then
		fail "$name (expected rc=$expected, got $rc; detail=${DEP_SUPERSESSION_DETAIL})"
		return 0
	fi
	if [[ -n "$detail" && "$DEP_SUPERSESSION_DETAIL" != *"$detail"* ]]; then
		fail "$name (detail '${DEP_SUPERSESSION_DETAIL}' lacks '${detail}')"
		return 0
	fi
	pass "$name"
	return 0
}

calls() {
	paste -sd' ' "$CALL_LOG"
	return 0
}

owner_superseded_11="[$(comment OWNER 'Superseded by #11. The merged spec is inlined on the new issue.')]"

FIXTURES="10|Issue|CLOSED|NOT_PLANNED|${owner_superseded_11}
11|Issue|OPEN||[]"
check 1 "completed blocker resolves" COMPLETED
[[ -z "$(calls)" ]] && pass "completed blocker needs no request" || fail "completed blocker needs no request (calls: $(calls))"
check 1 "legacy empty reason resolves" ""
[[ -z "$(calls)" ]] && pass "legacy empty reason needs no request" || fail "legacy empty reason needs no request (calls: $(calls))"

check 0 "open successor keeps the blocker outstanding" NOT_PLANNED "" "successor #11 of #10 is open"
[[ "$(calls)" == "10 11" ]] && pass "open successor costs one request per hop" || fail "open successor costs one request per hop (calls: $(calls))"
check 0 "duplicate closure follows the successor too" DUPLICATE
check 1 "successor that is the dependant itself resolves" NOT_PLANNED "OWNER/Repo#11"

FIXTURES="10|Issue|CLOSED|NOT_PLANNED|${owner_superseded_11}
11|Issue|CLOSED|COMPLETED|[]"
check 1 "completed successor resolves" NOT_PLANNED

FIXTURES="10|Issue|CLOSED|NOT_PLANNED|${owner_superseded_11}
11|PullRequest|MERGED||"
check 1 "merged pull-request successor resolves" NOT_PLANNED

FIXTURES="10|Issue|CLOSED|NOT_PLANNED|[$(comment OWNER 'Closing: no longer planned.')]"
check 1 "not-planned closure without a successor resolves" NOT_PLANNED

FIXTURES="10|Issue|CLOSED|NOT_PLANNED|[$(comment CONTRIBUTOR 'Superseded by #11.'),$(comment NONE 'Superseded by #11.')]
11|Issue|OPEN||[]"
check 1 "untrusted commenters cannot redirect a dependency" NOT_PLANNED

FIXTURES="10|Issue|CLOSED|NOT_PLANNED|[$(comment OWNER $'Thanks.\nSuperseded by #11.')]
11|Issue|OPEN||[]"
check 1 "supersession after the first line is ignored" NOT_PLANNED

FIXTURES="10|Issue|CLOSED|NOT_PLANNED|[$(comment MEMBER $'\r\n\nSuperseded by #11.')]
11|Issue|OPEN||[]"
check 0 "leading blank lines do not hide the marker" NOT_PLANNED

FIXTURES="10|Issue|CLOSED|NOT_PLANNED|[$(comment OWNER 'Superseded by #11.'),$(comment COLLABORATOR 'superseded by #12 after re-consolidation')]
11|Issue|CLOSED|COMPLETED|[]
12|Issue|OPEN||[]"
check 0 "newest trusted marker wins" NOT_PLANNED "" "successor #12 of #10 is open"

FIXTURES="10|Issue|CLOSED|NOT_PLANNED|${owner_superseded_11}
11|Issue|CLOSED|NOT_PLANNED|[$(comment OWNER 'Superseded by #12.')]
12|Issue|OPEN||[]"
check 0 "chained supersession follows to the open successor" NOT_PLANNED "" "successor #12 of #10 is open"

FIXTURES="10|Issue|CLOSED|NOT_PLANNED|${owner_superseded_11}
11|Issue|CLOSED|NOT_PLANNED|[$(comment OWNER 'Superseded by #10.')]"
check 0 "supersession cycle fails closed" NOT_PLANNED "" "cycle"

FIXTURES="10|Issue|CLOSED|NOT_PLANNED|${owner_superseded_11}
11|Issue|CLOSED|NOT_PLANNED|[$(comment OWNER 'Superseded by #12.')]
12|Issue|CLOSED|NOT_PLANNED|[$(comment OWNER 'Superseded by #13.')]
13|Issue|CLOSED|NOT_PLANNED|[$(comment OWNER 'Superseded by #14.')]
14|Issue|OPEN||[]"
check 0 "chain beyond the hop limit fails closed" NOT_PLANNED "" "exceeds 3 hops"
[[ "$(calls)" == "10 11 12 13" ]] && pass "hop limit bounds requests" || fail "hop limit bounds requests (calls: $(calls))"

FIXTURES="10|Issue|OPEN||[]"
check 0 "reopened blocker fails closed" NOT_PLANNED "" "open again"

FIXTURES="10|Issue|CLOSED|NOT_PLANNED|${owner_superseded_11}
11|Issue|OPEN||[]"
GH_FAIL_NUMBER=11
check 0 "successor lookup failure fails closed" NOT_PLANNED "" "lookup failed for #11"
GH_FAIL_NUMBER=""
GH_NO_COST=true
check 0 "response without cost fails closed" NOT_PLANNED "" "lookup failed for #10"
GH_NO_COST=false

FIXTURES="10|Issue|CLOSED|NOT_PLANNED|${owner_superseded_11}"
check 0 "missing successor fails closed" NOT_PLANNED "" "lookup failed for #11"

FIXTURES="10|Issue|CLOSED|NOT_PLANNED|${owner_superseded_11}
11|Issue|OPEN||[]"
LOGFILE="${TEST_ROOT}/pulse.log"
: >"$LOGFILE"
if dep_supersession_blocks "[test] owner/repo#20" "owner/repo" 10 NOT_PLANNED "owner/repo#20" &&
	grep -q 'owner/repo#20 blocker owner/repo#10 closed NOT_PLANNED but successor #11 of #10 is open — keeping blocked (GH#34341)' "$LOGFILE"; then
	pass "blocking decision is logged once"
else
	fail "blocking decision is logged once ($(cat "$LOGFILE"))"
fi
: >"$LOGFILE"
if ! dep_supersession_blocks "[test] owner/repo#20" "owner/repo" 10 COMPLETED "owner/repo#20" && [[ ! -s "$LOGFILE" ]]; then
	pass "resolved blocker is not logged"
else
	fail "resolved blocker is not logged"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
exit $?
