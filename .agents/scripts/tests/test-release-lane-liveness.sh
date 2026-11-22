#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Offline production recovery/merge functions with bounded forge fixtures.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../release-lane-helper.sh
source "$SCRIPT_DIR/release-lane-helper.sh"
# t18896: dead-executor notices and hints use a scratch session bus, never the real one.
BUS_DIR=$(mktemp -d)
trap 'rm -rf "$BUS_DIR"' EXIT
export AIDEVOPS_SESSION_BUS_DIR="$BUS_DIR"
unset AIDEVOPS_OPENCODE_SESSION_ID OPENCODE_SESSION_ID

BASE='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":101,"phase":"reserved","tag":null,"updated_at":"2020-01-01T00:00:00Z","terminal_receipt":null,"operation_token":"fixture","reservation_contract":"fenced-prepublication/v1","executor":{"pid":123,"host_id":"fixture","started_at":"fixture"}}'
STATE="$BASE"
HEAD_SHA="1111111111111111111111111111111111111111"
OWNER_STATE=dead
READ_FAIL=0
WRITE_FAIL=0
PERMISSION=true
WRITES=0

release_lane_read() {
	[[ "$READ_FAIL" == 0 ]] || return 1
	_AIDEVOPS_RELEASE_LANE_JSON="$STATE"
	_AIDEVOPS_RELEASE_LANE_HEAD="$HEAD_SHA"
	return 0
}
_release_lane_executor_observe() {
	jq -cn --arg state "$OWNER_STATE" '{state:$state,reason:"fixture"}'
	return 0
}
_release_lane_write() {
	[[ "$WRITE_FAIL" == 0 && "$3" == "$HEAD_SHA" ]] || return 2
	WRITES=$((WRITES + 1))
	STATE="$2"
	_AIDEVOPS_RELEASE_LANE_JSON="$STATE"
	return 0
}
gh() {
	[[ "$*" == 'api repos/test/repo --jq '* ]] || return 1
	[[ "$PERMISSION" != unavailable ]] || return 1
	printf '%s\n' "$PERMISSION"
	return 0
}

refused() {
	local name="$1"
	local before="$STATE"
	if release_lane_recover_reservation test/repo 101 >/dev/null 2>&1; then
		printf 'FAIL unexpectedly recovered: %s\n' "$name"
		exit 1
	fi
	[[ "$STATE" == "$before" && "$WRITES" == 0 ]] || exit 1
	printf 'PASS refusal: %s\n' "$name"
	return 0
}

for OWNER_STATE in live unknown; do refused "$OWNER_STATE executor"; done
OWNER_STATE=dead
for transform in 'del(.reservation_contract)' '.tag="v1.2.3"' '.phase="preparing"' '.phase="remote-publication"' '.phase="future"' '.prepublication_recovery={}' '.aggregate_recovery={}' '.aggregate_successor={}' '.reserved_authorization_refresh={}' '.terminal_receipt="failed"' '.source_pr=202'; do
	STATE=$(jq -c "$transform" <<<"$BASE")
	refused "$transform"
done
STATE=$(jq -c --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '.updated_at=$now' <<<"$BASE")
refused 'recent reservation'
STATE="$BASE"
READ_FAIL=1
refused 'unavailable lane'
READ_FAIL=0
for PERMISSION in false unavailable; do refused 'unverified write authority'; done
PERMISSION=true
WRITE_FAIL=1
refused 'competing CAS writer'
WRITE_FAIL=0
if release_lane_recover_reservation test/repo 101 "2222222222222222222222222222222222222222"; then exit 1; fi
[[ "$WRITES" == 0 ]] || exit 1
printf 'PASS stale observation refuses mutation\n'

RECENT=$(python3 -c 'from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc)-timedelta(seconds=100)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
STATE=$(jq -c --arg recent "$RECENT" '.updated_at=$recent' <<<"$BASE")
AIDEVOPS_RELEASE_LANE_STALE_SECONDS=1 refused 'caller cannot shorten five-minute recovery grace'
report=$(release_lane_liveness_report "$STATE")
[[ "$report" == *"wait until the configured recovery grace"* &&
	"$report" == *"recover-reservation 101"* && "$report" != *"using aidevops release patch"* ]] || exit 1
printf 'PASS recent dead reservation reports the recovery grace instead of a nonfunctional patch retry\n'
STATE="$BASE"

STATE=$(jq -c '.phase="preparing"' <<<"$BASE")
report=$(release_lane_liveness_report "$STATE")
[[ "$report" == *"Rerun the exact authorized release command"* ]] || exit 1
printf 'PASS dead tagless preparing status routes through fenced same-command recovery\n'
STATE="$BASE"

AIDEVOPS_RELEASE_LANE_COORDINATED_REPO=test/repo release_lane_merge_guard test/repo 202 main feature/ordinary
[[ "$WRITES" == 0 ]] || exit 1
release_lane_recover_reservation test/repo 101
[[ "$WRITES" == 1 ]] || exit 1
jq -e '.active == false and .terminal_receipt == "abandoned-prepublication" and .reservation_recovery.observed_head != null' <<<"$STATE" >/dev/null
release_lane_recover_reservation test/repo 101
[[ "$WRITES" == 1 ]] || exit 1
printf 'PASS ordinary merge leaves publisher state unchanged; explicit recovery remains idempotent\n'

# The exiting owner is the sole exception to dead-executor recovery grace.
_release_lane_executor_capture() {
	jq -c '.executor' <<<"$BASE"
	return 0
}
_AIDEVOPS_RELEASE_LANE_TOKEN="fixture"
OWNER_STATE=live
RECENT_BASE=$(jq -c --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '.updated_at=$now' <<<"$BASE")
for transform in 'del(.reservation_contract)' '.tag="v1.2.3"' '.phase="preparing"' '.prepublication_recovery={}' '.aggregate_recovery={}' '.aggregate_successor={}' '.reserved_authorization_refresh={}' '.terminal_receipt="failed"' '.source_pr=202' '.operation_token="other"' '.executor.host_id="foreign"' '.executor.pid=456' '.executor.started_at="reused"' '.executor=null'; do
	STATE=$(jq -c "$transform" <<<"$RECENT_BASE")
	before="$STATE"
	WRITES=0
	if release_lane_abandon_owned_reservation test/repo 101; then exit 1; fi
	[[ "$STATE" == "$before" && "$WRITES" == 0 ]] || exit 1
done
STATE="$RECENT_BASE"
WRITE_FAIL=1
if release_lane_abandon_owned_reservation test/repo 101; then exit 1; fi
[[ "$STATE" == "$RECENT_BASE" && "$WRITES" == 0 ]] || exit 1
WRITE_FAIL=0
release_lane_abandon_owned_reservation test/repo 101
[[ "$WRITES" == 1 ]] || exit 1
jq -e '.active == false and .terminal_receipt == "abandoned-prepublication"
	and .reservation_recovery.reason == "owner-preparation-refused"' <<<"$STATE" >/dev/null
printf 'PASS only the exact exiting owner can release a recent untouched reservation; publication and CAS races refuse\n'

# t18896: owner_session is advisory. A live owner session never changes
# recovery; liveness sends one dead-executor notice; hints are best-effort.
bus_presence() {
	local session_id="$1"
	local handle="$2"
	node --input-type=module -e '
const [storePath, root, id, handle, pid] = process.argv.slice(1);
const bus = await import(storePath);
bus.writePresence(root, { v: bus.BUS_VERSION, session_id: id, pid: Number(pid), start_token: bus.startToken(Number(pid)),
  kind: "tui", messageable: true, repo: "test/repo", worktree: "/w", branch: "main", title: "", issue: null, pr: null,
  status: "busy", handle, last_activity_epoch: Math.floor(Date.now() / 1000) });' \
		"$SCRIPT_DIR/../plugins/opencode-aidevops/session-bus-store.mjs" "$BUS_DIR" "$session_id" "$handle" "$$"
	return $?
}
inbox_count() {
	local session_id="$1"
	local count=0 file=""
	for file in "$BUS_DIR/inbox/$session_id"/*-msg_*.json; do
		[[ -f "$file" ]] && count=$((count + 1))
	done
	printf '%s\n' "$count"
	return 0
}
recover_outcome() {
	local rc=0
	STATE="$1"
	WRITES=0
	release_lane_recover_reservation test/repo 101 >/dev/null 2>&1 || rc=$?
	printf '%s %s %s\n' "$rc" "$WRITES" "$(jq -c '{active,phase,terminal_receipt,reason:.reservation_recovery.reason}' <<<"$STATE")"
	return 0
}
bus_presence ses_ownerL1 repo-owner
bus_presence ses_watchL1 repo-watch
AIDEVOPS_OPENCODE_SESSION_ID=ses_watchL1 bash "$SCRIPT_DIR/session-bus-helper.sh" watch-release test/repo >/dev/null
OWNED_BASE=$(jq -c '.owner_session={session_id:"ses_ownerL1",captured_at:"2020-01-01T00:00:00Z"}' <<<"$BASE")
OWNER_STATE=dead
without=$(recover_outcome "$BASE")
with=$(recover_outcome "$OWNED_BASE")
[[ "$with" == "$without" && "$with" == "0 1 "* ]] || exit 1
OWNER_STATE=live
without=$(recover_outcome "$BASE")
with=$(recover_outcome "$OWNED_BASE")
[[ "$with" == "$without" && "$with" != "0 "* && "$with" == *" 0 "* ]] || exit 1
printf 'PASS a live owner_session never changes dead-executor recovery or live-executor refusal\n'

OWNER_STATE=dead
[[ "$(inbox_count ses_watchL1)" == 0 ]] || exit 1
off=$(AIDEVOPS_RELEASE_NOTICES=false release_lane_liveness_report "$OWNED_BASE")
[[ "$(inbox_count ses_watchL1)" == 0 ]] || exit 1
on=$(release_lane_liveness_report "$OWNED_BASE")
again=$(release_lane_liveness_report "$OWNED_BASE")
[[ "$on" == "$off" && "$again" == "$off" ]] || exit 1
[[ "$(inbox_count ses_watchL1)" == 1 && "$(inbox_count ses_ownerL1)" == 1 ]] || exit 1
jq -e '.type == "info" and (.text | test("PR #101 has a dead release executor") and test("Recovery command: aidevops release recover-reservation 101"))' \
	"$BUS_DIR"/inbox/ses_watchL1/*-msg_*.json >/dev/null || exit 1
jq -e '.notified_dead_at | type == "string"' "$BUS_DIR"/release-watch/test@repo/notices/*.json >/dev/null || exit 1
OWNER_STATE=live
release_lane_liveness_report "$OWNED_BASE" >/dev/null
[[ "$(inbox_count ses_watchL1)" == 1 ]] || exit 1
printf 'PASS one dead-executor notice across repeated observations; report output unchanged with notices off\n'

hint=$(release_lane_owner_session_hint "$OWNED_BASE")
[[ "$hint" == *"RELEASE_OWNER_SESSION handle=repo-owner status=busy"* &&
	"$hint" == *'aidevops sessions ask repo-owner "Is your release lane for PR #101 still in progress?"'* ]] || exit 1
hint=$(release_lane_owner_session_hint "$(jq -c '.owner_session.session_id="ses_goneL1"' <<<"$OWNED_BASE")")
[[ "$hint" == *"session=ses_goneL1 state=not-live"* && "$hint" == *"owner session is not live"* ]] || exit 1
[[ -z "$(AIDEVOPS_RELEASE_NOTICES=false release_lane_owner_session_hint "$OWNED_BASE")" ]] || exit 1
[[ -z "$(release_lane_owner_session_hint "$BASE")" ]] || exit 1
[[ -z "$(release_lane_owner_session_hint "$(jq -c '.owner_session.session_id="bad id;"' <<<"$OWNED_BASE")")" ]] || exit 1
[[ -z "$(_AIDEVOPS_RELEASE_LANE_LIB_DIR=/nonexistent release_lane_owner_session_hint "$OWNED_BASE")" ]] || exit 1
[[ "$(AIDEVOPS_OPENCODE_SESSION_ID=ses_ok_1 _release_lane_owner_session_capture | jq -r .session_id)" == ses_ok_1 ]] || exit 1
[[ "$(AIDEVOPS_OPENCODE_SESSION_ID='' OPENCODE_SESSION_ID=ses_fallback _release_lane_owner_session_capture | jq -r .session_id)" == ses_fallback ]] || exit 1
[[ "$(AIDEVOPS_OPENCODE_SESSION_ID='bad id;' _release_lane_owner_session_capture)" == null ]] || exit 1
printf 'PASS owner-session hint shows a live handle and ask, says not-live, and prints nothing on failure\n'
