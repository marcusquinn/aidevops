#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYERS="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)/pulse-dispatch-dedup-layers.sh"
TEST_ROOT="$(mktemp -d)"
TESTS_RUN=0
TESTS_FAILED=0
trap 'rm -rf "$TEST_ROOT"' EXIT

print_result() {
	local name="$1"
	local passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# shellcheck source=../pulse-dispatch-dedup-layers.sh
source "$LAYERS"
SCRIPT_DIR="${TEST_ROOT}/scripts"
LOGFILE="${TEST_ROOT}/pulse.log"
mkdir -p "$SCRIPT_DIR"
cat >"${SCRIPT_DIR}/dispatch-dedup-helper.sh" <<'DEDUP_STUB'
#!/usr/bin/env bash
if [[ "$1" == "is-assigned" ]]; then
	printf '%s\n' "${STUB_ASSIGNED_OUTPUT}"
	exit 1
fi
if [[ "$1" == "has-open-pr" ]]; then
	printf '%s\n' "${STUB_OPEN_PR_OUTPUT:-}"
	exit "${STUB_OPEN_PR_RC:-0}"
fi
exit 1
DEDUP_STUB
chmod +x "${SCRIPT_DIR}/dispatch-dedup-helper.sh"

export STUB_OPEN_PR_OUTPUT='PR_LOOKUP_RESULT=uncertain reason=timeout scope=open_siblings
PR_LOOKUP_UNCERTAIN: open_siblings lookup failed; dispatch is blocked'
export STUB_OPEN_PR_RC=0
LAYER4_OUTPUT=""
LAYER4_RC=0
LAYER4_OUTPUT=$(_dedup_layer4_pr_evidence "123" "owner/repo" "Fixture") || LAYER4_RC=$?
if [[ "$LAYER4_RC" -eq 0 && "$LAYER4_OUTPUT" == "pr_lookup_uncertain" ]] &&
	grep -q 'PR_LOOKUP_RESULT=uncertain reason=timeout' "$LOGFILE"; then
	print_result "Layer 4 preserves PR lookup uncertainty as a distinct block" 0
else
	print_result "Layer 4 preserves PR lookup uncertainty as a distinct block" 1
fi

export STUB_OPEN_PR_OUTPUT=''
export STUB_OPEN_PR_RC=1
LAYER4_OUTPUT=""
LAYER4_RC=0
LAYER4_OUTPUT=$(_dedup_layer4_pr_evidence "123" "owner/repo" "Fixture") || LAYER4_RC=$?
if [[ "$LAYER4_RC" -eq 1 && -z "$LAYER4_OUTPUT" ]]; then
	print_result "Layer 4 allows dispatch after a subsequent valid empty lookup" 0
else
	print_result "Layer 4 allows dispatch after a subsequent valid empty lookup" 1
fi

# Exercise the production router's event parsing/argument fence before replacing
# it with a counter stub for the Layer 6 return-semantics tests below.
ROUTE_ARGS_FILE="${TEST_ROOT}/route-args"
mkdir -p "${TEST_ROOT}/repo"
cat >"${SCRIPT_DIR}/pr-checkpoint-continuation-helper.sh" <<ROUTE_STUB
#!/usr/bin/env bash
if [[ "\$1" == dispatch-approved && "\${STUB_APPROVED_RESULT:-1}" != 0 ]]; then
	exit 1
fi
printf '%s\n' "\$*" >"${ROUTE_ARGS_FILE}"
exit 0
ROUTE_STUB
chmod +x "${SCRIPT_DIR}/pr-checkpoint-continuation-helper.sh"
_pulse_merge_repo_path_for_slug() {
	local _repo_slug="$1"
	: "$_repo_slug"
	printf '%s\n' "${TEST_ROOT}/repo"
	return 0
}

PRODUCTION_ROUTER="_dispatch_stale_pr_checkpoint_continuation"
if "$PRODUCTION_ROUTER" "123" "owner/repo" \
	'STALE_PR_CONTINUATION: issue #123 in owner/repo — PR #42 preserved for exact-head continuation assignee=stale-runner' "runner" && \
	[[ "$(<"$ROUTE_ARGS_FILE")" == "dispatch owner/repo ${TEST_ROOT}/repo 42 123 stale-runner runner" ]]; then
	print_result "router binds continuation to stale and authenticated owners" 0
else
	print_result "router binds continuation to stale and authenticated owners" 1
fi

if ! "$PRODUCTION_ROUTER" "123" "owner/repo" \
	'STALE_PR_CONTINUATION: issue #123 in owner/repo — PR #42 preserved for exact-head continuation' "runner"; then
	print_result "router rejects continuation without exact stale assignee" 0
else
	print_result "router rejects continuation without exact stale assignee" 1
fi

ROUTE_CALLS=0
ROUTE_RESULT=0
LAST_ROUTE_ARGS=""
_dispatch_stale_pr_checkpoint_continuation() {
	local _issue_number="$1"
	local _repo_slug="$2"
	local _assigned_output="$3"
	local _self_login="$4"
	: "$_issue_number" "$_repo_slug" "$_assigned_output" "$_self_login"
	ROUTE_CALLS=$((ROUTE_CALLS + 1))
	LAST_ROUTE_ARGS="$*"
	return "$ROUTE_RESULT"
}

export STUB_ASSIGNED_OUTPUT='STALE_PR_CONTINUATION: issue #123 in owner/repo — PR #42 preserved for exact-head continuation assignee=stale-runner'
if _dedup_layer6_assignee_and_stale "123" "owner/repo" "runner" && [[ "$ROUTE_CALLS" -eq 1 ]]; then
	print_result "stale draft continuation routes once and blocks issue redispatch" 0
else
	print_result "stale draft continuation routes once and blocks issue redispatch" 1
fi

ROUTE_RESULT=1
if _dedup_layer6_assignee_and_stale "123" "owner/repo" "runner" && [[ "$ROUTE_CALLS" -eq 2 ]]; then
	print_result "continuation launch failure still blocks competing dispatch" 0
else
	print_result "continuation launch failure still blocks competing dispatch" 1
fi

export STUB_ASSIGNED_OUTPUT='STALE_RECHECK_BLOCKED: issue #123 in owner/repo — evidence changed before draft continuation'
if _dedup_layer6_assignee_and_stale "123" "owner/repo" "runner" && [[ "$ROUTE_CALLS" -eq 2 ]]; then
	print_result "changed stale evidence fails closed without continuation or redispatch" 0
else
	print_result "changed stale evidence fails closed without continuation or redispatch" 1
fi

STUB_ACTIVE_WORKER=0
has_worker_for_repo_issue() {
	local _issue_number="$1"
	local _repo_slug="$2"
	: "$_issue_number" "$_repo_slug"
	if [[ "$STUB_ACTIVE_WORKER" -eq 1 ]]; then
		return 0
	fi
	return 1
}

_dispatch_has_interactive_hold() {
	local issue_meta_json="$1"
	if printf '%s' "$issue_meta_json" | jq -e '
		(.labels // []) | map(.name) |
		((index("auto-dispatch") | not) and (index("status:in-review") or index("origin:interactive")))
	' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

checkpoint_meta='{"number":29507,"state":"OPEN","title":"Fixture","labels":[{"name":"origin:interactive"},{"name":"status:in-review"}],"assignees":[{"login":"stale-runner"}]}'
export STUB_OPEN_PR_OUTPUT='WORKER_DRAFT_CHECKPOINT: draft PR #29519 is a durable checkpoint for issue #29507; ordinary redispatch is blocked'
export STUB_OPEN_PR_RC=0
ROUTE_CALLS=0
ROUTE_RESULT=0
: >"$LOGFILE"
if _dispatch_interactive_hold_gate "29507" "owner/repo" "Fixture" "runner" "$checkpoint_meta" &&
	[[ "$ROUTE_CALLS" -eq 1 && "$LAST_ROUTE_ARGS" == *"PR #29519"* ]] &&
	grep -q 'reason=worker_draft_checkpoint_continuation signal=checkpoint_routed' "$LOGFILE"; then
	print_result "#29507 interactive-provenance checkpoint routes exactly one continuation before hold" 0
else
	print_result "#29507 interactive-provenance checkpoint routes exactly one continuation before hold" 1
fi

ROUTE_CALLS=0
ROUTE_RESULT=1
: >"$LOGFILE"
if _dispatch_interactive_hold_gate "29507" "owner/repo" "Fixture" "runner" "$checkpoint_meta" &&
	[[ "$ROUTE_CALLS" -eq 1 ]] && grep -q 'reason=worker_draft_checkpoint_blocked' "$LOGFILE"; then
	print_result "verified checkpoint launch failure remains an explicit block" 0
else
	print_result "verified checkpoint launch failure remains an explicit block" 1
fi

export STUB_OPEN_PR_OUTPUT='draft PR #29519 is a durable checkpoint for issue #29507; ordinary redispatch is blocked'
ROUTE_CALLS=0
: >"$LOGFILE"
if _dispatch_interactive_hold_gate "29507" "owner/repo" "Fixture" "runner" "$checkpoint_meta" &&
	[[ "$ROUTE_CALLS" -eq 0 ]] && grep -q 'reason=interactive_review_hold' "$LOGFILE"; then
	print_result "otherwise identical human draft remains a genuine interactive hold" 0
else
	print_result "otherwise identical human draft remains a genuine interactive hold" 1
fi

export STUB_OPEN_PR_OUTPUT='WORKER_DRAFT_CHECKPOINT: draft PR #29519 is a durable checkpoint for issue #29507; ordinary redispatch is blocked'
STUB_ACTIVE_WORKER=1
ROUTE_CALLS=0
: >"$LOGFILE"
if _dispatch_interactive_hold_gate "29507" "owner/repo" "Fixture" "runner" "$checkpoint_meta" &&
	[[ "$ROUTE_CALLS" -eq 0 ]] && grep -q 'reason=interactive_review_hold' "$LOGFILE"; then
	print_result "live worker keeps checkpoint under genuine interactive hold" 0
else
	print_result "live worker keeps checkpoint under genuine interactive hold" 1
fi

# Exercise the real log filter, recorder and reader with a complete PR envelope.
# The snapshot is deliberately older than the former 90-second cutoff but within
# the bounded prefetch-to-dispatch window.
# shellcheck source=../pulse-dispatch-lib.sh
source "${TEST_SCRIPT_DIR}/../pulse-dispatch-lib.sh"
export HOME="${TEST_ROOT}/home" SNAPSHOT_FILE="${TEST_ROOT}/pr-snapshot.json"
cat >"${SCRIPT_DIR}/pulse-batch-prefetch-helper.sh" <<'PREFETCH_STUB'
#!/usr/bin/env bash
[[ "$*" == 'read-snapshot --kind prs --slug owner/repo' ]] || exit 1
printf '%s\n' "$(<"$SNAPSHOT_FILE")"
PREFETCH_STUB
chmod +x "${SCRIPT_DIR}/pulse-batch-prefetch-helper.sh"
_PULSE_DISPATCH_LIB_DIR="$SCRIPT_DIR"
write_pr_snapshot() {
	local age="$1" oid="$2" pr="${3:-29519}" complete="${4:-true}" updated="${5:-2026-09-29T12:00:00Z}"
	local epoch timestamp
	epoch=$(($(date +%s) - age))
	# BSD date accepts epoch seconds with -r; GNU date requires -d @epoch.
	timestamp=$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ) || return 1
	jq -n --arg ts "$timestamp" \
		--arg oid "$oid" --arg updated "$updated" --argjson pr "$pr" --argjson complete "$complete" \
		'{complete:$complete,timestamp:$ts,items:[{number:$pr,updatedAt:$updated,headRefOid:$oid}]}' >"$SNAPSHOT_FILE"
	return 0
}
candidate='{"number":29507,"repo_slug":"owner/repo","updatedAt":"2026-09-29T12:01:00Z","assignees":[],"labels":["status:available"]}'
cache_file="${HOME}/.aidevops/logs/dispatch-negative-cache/owner--repo--29507"
write_pr_snapshot 430 first-head
: >"$LOGFILE"
printf '%s\n' '[pulse-wrapper] DISPATCH_CANDIDATE_ATTEMPT #29507 (owner/repo)' >>"$LOGFILE"
_dispatch_revised_checkpoint() { return 1; }
rm -f "$ROUTE_ARGS_FILE"
LAYER4_RC=0
_dedup_layer4_pr_evidence "29507" "owner/repo" "Fixture" >/dev/null || LAYER4_RC=$?
if [[ "$LAYER4_RC" -eq 2 && "$(<"$ROUTE_ARGS_FILE")" == "blocked-attention owner/repo 29507 29519" ]]; then
	print_result "GH#33132 worker draft checkpoint requests blocked attention and still blocks" 0
else
	print_result "GH#33132 worker draft checkpoint requests blocked attention and still blocks" 1
fi
_DISPATCH_CANDIDATE_ELIGIBILITY="$_DISPATCH_ELIGIBILITY_INELIGIBLE"
_dispatch_cache_confirmed_block "$candidate" 29507 owner/repo
if [[ -f "$cache_file" ]] && grep -q $'\tworker_draft_checkpoint_blocked\t29519\t' "$cache_file" &&
	[[ "$(_dispatch_negative_cache_reason "$candidate")" == worker_draft_checkpoint_blocked ]]; then
	print_result "unassigned worker draft logs and caches across cycles" 0
else
	print_result "unassigned worker draft logs and caches across cycles" 1
fi

write_pr_snapshot 430 new-head
if ! _dispatch_negative_cache_reason "$candidate" >/dev/null; then
	print_result "new PR head invalidates the checkpoint" 0
else
	print_result "new PR head invalidates the checkpoint" 1
fi
write_pr_snapshot 430 first-head 29519 true 2026-09-29T12:01:00Z
if ! _dispatch_negative_cache_reason "$candidate" >/dev/null; then
	print_result "new PR revision invalidates the checkpoint" 0
else
	print_result "new PR revision invalidates the checkpoint" 1
fi
write_pr_snapshot 430 first-head 12345
if ! _dispatch_negative_cache_reason "$candidate" >/dev/null; then
	print_result "missing PR invalidates the checkpoint" 0
else
	print_result "missing PR invalidates the checkpoint" 1
fi
write_pr_snapshot 901 first-head
if ! _dispatch_negative_cache_reason "$candidate" >/dev/null; then
	print_result "stale snapshot cannot suppress dispatch" 0
else
	print_result "stale snapshot cannot suppress dispatch" 1
fi
write_pr_snapshot 430 first-head
if ! _dispatch_negative_cache_reason "${candidate/12:01:00/12:02:00}" >/dev/null; then
	print_result "edited issue invalidates the checkpoint" 0
else
	print_result "edited issue invalidates the checkpoint" 1
fi

rm -f "$cache_file"
_dispatch_negative_cache_record "$candidate" dedup_active_claim
if [[ ! -f "$cache_file" ]]; then
	print_result "available unassigned claim does not write an unusable hint" 0
else
	print_result "available unassigned claim does not write an unusable hint" 1
fi

# GH#33026: a live worktree-owner refusal holds the issue across the refused
# attempt's own claim-comment updatedAt bump, only while that owner generation
# is alive and still owns the recorded worktree. The owner row is never touched.
LIVE_OWNER_TOKEN="Wed Sep 30 10:00:00 2026"
REGISTRY_OWNER_PID=4242
held_worktree="${TEST_ROOT}/wt/owned gh33026"
_wt_process_start_token_for_pid() {
	[[ "$1" == 4242 && -n "$LIVE_OWNER_TOKEN" ]] || return 1
	printf '%s' "$LIVE_OWNER_TOKEN"
	return 0
}
check_worktree_owner_snapshot() {
	[[ "$1" == "$held_worktree" && -n "$REGISTRY_OWNER_PID" ]] || return 1
	printf '%s|worker-session||t1|2026-09-29T00:00:00Z|token\n' "$REGISTRY_OWNER_PID"
	return 0
}
held_candidate='{"number":33026,"repo_slug":"owner/repo","updatedAt":"2026-09-29T12:01:00Z","assignees":[],"labels":["status:available","solved:worker"]}'
held_bumped="${held_candidate/12:01:00/12:05:00}"
: >"$LOGFILE"
printf '%s\n' '[pulse-wrapper] DISPATCH_CANDIDATE_ATTEMPT #33026 (owner/repo)' \
	"[dispatch_with_dedup] WORKTREE_LIVE_OWNER_REFUSED issue=#33026 repo=owner/repo owner_pid=4242 owner_start=Wed_Sep_30_10:00:00_2026 action=hold_until_owner_exits_or_changes worktree=${held_worktree}" \
	>>"$LOGFILE"
_DISPATCH_CANDIDATE_ELIGIBILITY=""
_dispatch_cache_confirmed_block "$held_candidate" 33026 owner/repo
if [[ "$(_dispatch_negative_cache_reason "$held_bumped")" == worktree_live_owner_refused ]] &&
	_dispatch_prefilter_owned_candidate "$held_bumped" 33026 owner/repo &&
	grep -q 'cross-cycle ownership block:worktree_live_owner_refused' "$LOGFILE"; then
	print_result "unchanged live owner refusal holds an available issue across the claim bump" 0
else
	print_result "unchanged live owner refusal holds an available issue across the claim bump" 1
fi
if [[ "$(grep -c 'is OPEN with solved:worker while a live owner holds its worktree' "$LOGFILE")" == 1 ]] &&
	! grep -qi 'close' <<<"$(grep -v 'solved:worker' "$LOGFILE")"; then
	print_result "solved:worker inconsistency is one diagnostic line, never a close" 0
else
	print_result "solved:worker inconsistency is one diagnostic line, never a close" 1
fi
LIVE_OWNER_TOKEN=""
if ! _dispatch_negative_cache_reason "$held_bumped" >/dev/null; then
	print_result "owner exit re-enables dispatch" 0
else
	print_result "owner exit re-enables dispatch" 1
fi
LIVE_OWNER_TOKEN="Wed Sep 30 11:00:00 2026"
if ! _dispatch_negative_cache_reason "$held_bumped" >/dev/null; then
	print_result "reused PID with a new process generation re-enables dispatch" 0
else
	print_result "reused PID with a new process generation re-enables dispatch" 1
fi
LIVE_OWNER_TOKEN="Wed Sep 30 10:00:00 2026"
REGISTRY_OWNER_PID=5555
if ! _dispatch_negative_cache_reason "$held_bumped" >/dev/null; then
	print_result "ownership handover re-enables dispatch" 0
else
	print_result "ownership handover re-enables dispatch" 1
fi
REGISTRY_OWNER_PID=4242
unrelated_candidate='{"number":33027,"repo_slug":"owner/repo","updatedAt":"2026-09-29T12:01:00Z","assignees":[],"labels":["status:available"]}'
if ! _dispatch_negative_cache_reason "$unrelated_candidate" >/dev/null &&
	[[ "$(_dispatch_negative_cache_reason "$held_bumped")" == worktree_live_owner_refused ]]; then
	print_result "unrelated candidate is not held by another issue's live owner" 0
else
	print_result "unrelated candidate is not held by another issue's live owner" 1
fi
: >"$LOGFILE"
rm -f "${HOME}/.aidevops/logs/dispatch-negative-cache/owner--repo--33026"
printf '%s\n' '[pulse-wrapper] DISPATCH_CANDIDATE_ATTEMPT #33026 (owner/repo)' \
	'[dispatch_with_dedup] PRE_RUNTIME_FAILURE issue=33026 repo=owner/repo reason=worktree_precreation_failed #33026 (owner/repo)' \
	>>"$LOGFILE"
_dispatch_cache_confirmed_block "$held_candidate" 33026 owner/repo
if [[ ! -f "${HOME}/.aidevops/logs/dispatch-negative-cache/owner--repo--33026" ]]; then
	print_result "generic precreation failures stay uncached" 0
else
	print_result "generic precreation failures stay uncached" 1
fi

# GH#33332: an unowned issue held by terminal-blocker backoff is cached across
# cycles until edited, without needing claim labels.
backoff_cache="${HOME}/.aidevops/logs/dispatch-negative-cache/owner--repo--33026"
rm -f "$backoff_cache"
_dispatch_negative_cache_record "$held_candidate" terminal_blocker_backoff
if [[ "$(_dispatch_negative_cache_reason "$held_candidate")" == terminal_blocker_backoff ]] &&
	! _dispatch_negative_cache_reason "$held_bumped" >/dev/null &&
	[[ "$_DISPATCH_TERMINAL_BACKOFF_CACHE_TTL_SECONDS" -le 900 ]]; then
	print_result "terminal-blocker backoff caches an unowned issue until it changes" 0
else
	print_result "terminal-blocker backoff caches an unowned issue until it changes" 1
fi

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$TESTS_RUN"
	exit 0
fi
printf '%d / %d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
