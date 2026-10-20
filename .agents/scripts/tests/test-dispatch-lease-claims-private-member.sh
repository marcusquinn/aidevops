#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# GH#34703: private members require permission-backed claim consensus trust.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AIDEVOPS_TEST_MODE=1 AIDEVOPS_REPO_STATE_GUARD_TEST_BYPASS=1
# shellcheck source=../dispatch-claim-helper.sh
source "${SCRIPT_DIR}/../dispatch-claim-helper.sh" help >/dev/null
# shellcheck source=../shared-gh-collaborator-permission.sh
source "${SCRIPT_DIR}/../shared-gh-collaborator-permission.sh"

_gh_collaborator_permission_lookup() {
	local repo_slug="$1" user="$2" out_var="$3"
	[[ "$repo_slug" == "org/repo" ]] || return 2
	# stderr survives command substitution and makes duplicate calls observable.
	printf 'LOOKUP %s\n' "$user" >&2
	case "$user" in
	admin) printf -v "$out_var" '%s' admin ;;
	writer) printf -v "$out_var" '%s' write ;;
	maintainer) printf -v "$out_var" '%s' maintain ;;
	reader) printf -v "$out_var" '%s' read ;;
	triager) printf -v "$out_var" '%s' triage ;;
	outsider) printf -v "$out_var" '%s' none ;;
	*) return 2 ;;
	esac
	return 0
}

_now_epoch() { printf '1767225900'; return 0; }
_apply_ignore_filter() { local claims="$1"; printf '%s' "$claims"; return 0; }
_dch_timed() { printf '0'; return 0; }
_post_orphan_claim_release() { return 0; }

assert_json() {
	local name="$1" json="$2" predicate="$3"
	if ! printf '%s' "$json" | jq -e "$predicate" >/dev/null; then
		printf 'FAIL %s: %s\n' "$name" "$json" >&2
		return 1
	fi
	printf 'PASS %s\n' "$name"
	return 0
}

# All comments are older than orphan grace; only matching launch evidence
# preserves claims without an active lease. Duplicate authors cost one lookup.
COMMENTS=$(jq -nc '
	["admin","writer","maintainer","reader","triager","outsider","failed","newcomer"] | to_entries |
	map(.key as $i | .value as $login |
		{ id:($i + 1), author:$login,
		  author_association:(if $login == "newcomer" then "FIRST_TIME_CONTRIBUTOR" elif $login == "writer" then "NONE" else "CONTRIBUTOR" end),
		  created_at:"2026-01-01T00:00:00Z",
		  body:("DISPATCH_CLAIM nonce=n runner=" + $login + " ts=2026-01-01T00:00:00Z lease_token=t device=d session=s")}) |
	. + map(.id as $id | .id += 20 | .created_at="2026-01-01T00:01:00Z" |
		.body=("Dispatching worker lease_token=t device=d session=s claim_id=" + ($id|tostring)))
')
_fetch_claim_marker_comments() { printf '%s' "$COMMENTS"; return 0; }

TRUSTED=$(_claim_permission_trusted_authors "$COMMENTS" org/repo)
assert_json 'admin, maintain and write only' "$TRUSTED" 'sort == ["admin","maintainer","writer"]'
CLAIMS=$(printf '%s\n%s\n' "$COMMENTS" "$COMMENTS" | jq -nc \
	--argjson now 1767225900 --argjson max_age 1800 --argjson include_terminal false \
	--argjson permission_trusted_authors "$TRUSTED" -f "${SCRIPT_DIR}/../dispatch-lease-claims.jq")
assert_json 'private member claims accepted; read/triage/404/errors rejected' "$CLAIMS" '[.[].runner] | sort == ["admin","maintainer","writer"]'
DEFAULT=$(printf '%s\n%s\n' "$COMMENTS" "$COMMENTS" | jq -nc \
	--argjson now 1767225900 --argjson max_age 1800 --argjson include_terminal false \
	-f "${SCRIPT_DIR}/../dispatch-lease-claims.jq")
assert_json 'legacy parser invocation fails closed' "$DEFAULT" 'length == 0'

# Observe lookup diagnostics without filesystem mocks or a live API.
FETCH_WITH_LOOKUPS=$(_fetch_claims 1 org/repo 2>&1)
LOOKUPS=$(printf '%s\n' "$FETCH_WITH_LOOKUPS" | jq -Rs 'split("\n") | map(select(startswith("LOOKUP ")))')
assert_json 'one permission lookup per distinct eligible author, including orphan filtering' "$LOOKUPS" \
	'length == 7 and (unique | length) == 7 and (index("LOOKUP newcomer") == null)'
FETCHED=$(printf '%s\n' "$FETCH_WITH_LOOKUPS" | jq -Rs 'split("\n") | map(select(startswith("["))) | last | fromjson')
assert_json 'fetch preserves old claims with private-member launch evidence' "$FETCHED" 'length == 3'
FILTERED=$(_filter_claims_with_launch_evidence "$CLAIMS" "$COMMENTS" org/repo)
assert_json 'standalone launch filter resolves permissions' "$FILTERED" 'length == 3'
UNTRUSTED=$(_filter_claims_with_launch_evidence "$CLAIMS" "$COMMENTS" org/repo '[]')
assert_json 'untrusted launch cannot preserve an orphan' "$UNTRUSTED" 'length == 0'

EVENTS=$(printf '%s' "$COMMENTS" | jq -c '. + [
	{ id:50, author:"admin", author_association:"CONTRIBUTOR", created_at:"2026-01-01T00:02:00Z",
	  body:"DISPATCH_LEASE phase=ready lease_token=t device=d session=s expires_at=1767226500"},
	{ id:51, author:"writer", author_association:"NONE", created_at:"2026-01-01T00:03:00Z",
	  body:"CLAIM_RELEASED claim_id=2 nonce=n runner=writer"}
]')
PARSED=$(printf '%s\n%s\n' "$COMMENTS" "$EVENTS" | jq -nc \
	--argjson now 1767225900 --argjson max_age 1800 --argjson include_terminal true \
	--argjson permission_trusted_authors "$TRUSTED" -f "${SCRIPT_DIR}/../dispatch-lease-claims.jq")
assert_json 'permission-backed lease and release events accepted' "$PARSED" \
	'any(.runner == "admin" and .lease_phase == "ready") and any(.runner == "writer" and .lease_phase == "terminal")'

# GH#35268: exercise the production readers, not just the jq trust argument.
# Sourcing the CLI with help loads its libraries without invoking dispatch.
# shellcheck source=../dispatch-dedup-helper.sh
source "${SCRIPT_DIR}/../dispatch-dedup-helper.sh" help >/dev/null

assert_status() {
	local name="$1" expected="$2"
	shift 2
	local actual=0
	"$@" || actual=$?
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL %s: expected %s, got %s\n' "$name" "$expected" "$actual" >&2
		return 1
	fi
	printf 'PASS %s\n' "$name"
	return 0
}

NOW=$(date +%s)
READY=$(printf '%s' "$EVENTS" | jq -c --argjson expires "$((NOW + 7200))" '
	map(select(.author == "admin")) |
	map(if .id == 50 then .body = ("DISPATCH_LEASE phase=ready lease_token=t device=d session=s expires_at=" + ($expires|tostring)) else . end) |
	map(.user = {login:.author} | del(.author))')
PAGES=$(printf '%s' "$READY" | jq -c '[.]')
_stale_recovery_fetch_comments_pages() { printf '%s' "$PAGES"; return 0; }
assert_status 'private-member ready lease vetoes stale recovery beyond claim TTL' 1 \
	_stale_recovery_final_evidence_recheck 1 org/repo 2026-01-01T00:01:00Z

# Read-only/unknown authors must not gain coordination authority.
PAGES=$(printf '%s' "$READY" | jq -c '[map(.user.login="reader" | .body |= gsub("runner=admin"; "runner=reader"))]')
assert_status 'read-only ready lease cannot veto recovery' 0 \
	_stale_recovery_final_evidence_recheck 1 org/repo 2026-01-01T00:01:00Z

# The fetch path must retain permission-backed authors before the lease parser.
gh() { printf '%s' "$PAGES"; return 0; }
PAGES=$(printf '%s' "$READY" | jq -c '[.]')
FETCHED=$(_dd_fetch_trusted_issue_comments 1 org/repo)
assert_json 'dedup fetch retains private-member coordination evidence' "$FETCHED" 'length == 3 and all(.author == "admin")'
PAGES=$(printf '%s' "$READY" | jq -c '[map(.user.login="reader")]')
FETCHED=$(_dd_fetch_trusted_issue_comments 1 org/repo)
assert_json 'dedup fetch rejects read-only authors' "$FETCHED" 'length == 0'

TERMINAL=$(printf '%s' "$READY" | jq -c '. + [
	{id:60, user:{login:"admin"}, author_association:"CONTRIBUTOR", created_at:"2026-01-01T00:04:00Z",
	 body:"CLAIM_RELEASED claim_id=1 nonce=n runner=admin"}]')
assert_status 'dedup accepts matching permission-backed terminal generation' 0 \
	_dd_has_matching_terminal_lease "$TERMINAL" 2026-01-01T00:01:00Z 21 admin '' org/repo
PAGES=$(printf '%s' "$TERMINAL" | jq -c '[.]')
assert_status 'matching release permits stale recovery' 0 \
	_stale_recovery_final_evidence_recheck 1 org/repo 2026-01-01T00:01:00Z
MISMATCHED=$(printf '%s' "$TERMINAL" | jq -c 'map(if .id == 60 then .body |= sub("nonce=n"; "nonce=wrong") else . end)')
assert_status 'dedup rejects release for a different generation' 1 \
	_dd_has_matching_terminal_lease "$MISMATCHED" 2026-01-01T00:01:00Z 21 admin '' org/repo
PAGES=$(printf '%s' "$MISMATCHED" | jq -c '[.]')
assert_status 'unmatched release still protects ready lease' 1 \
	_stale_recovery_final_evidence_recheck 1 org/repo 2026-01-01T00:01:00Z
printf 'All private-member claim tests passed\n'
