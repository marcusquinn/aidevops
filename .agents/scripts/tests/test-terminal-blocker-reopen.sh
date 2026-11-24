#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#40206: production-path replay, isolated from providers and GitHub writes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export AIDEVOPS_BLOCKER_RECOVERY_DIR="$ROOT/recovery"
export AIDEVOPS_WORKER_BLOCKER_LOG_FILE="$ROOT/captured.jsonl"
export TERMINAL_BLOCKER_SELF_LOGIN=runner-b TERMINAL_BLOCKER_NOW_EPOCH=1795521600
unset WORKER_ISSUE_NUMBER DISPATCH_REPO_SLUG
# shellcheck source=../terminal-blocker-circuit.sh
source "$SCRIPT_DIR/terminal-blocker-circuit.sh"
# shellcheck source=../terminal-blocker-recovery-helper.sh
source "$SCRIPT_DIR/terminal-blocker-recovery-helper.sh"

_terminal_blocker_triage_unknown() { return 1; }

report='BLOCKED: source_exhausted; official API returned HTTP 500. Recheck after 24 h.'
jq -nc --arg text "$report" '{type:"text",text:$text}' >"$ROOT/output"
terminal_blocker_capture_output "$ROOT/output"
[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == external_trigger_pending ]]
[[ "$AIDEVOPS_TERMINAL_BLOCKER_RECHECK_AFTER" == 2026-11-25T12:00:00Z ]]
fragment=$(terminal_blocker_observation_fragment aaaaaaaaaaaaaaaaaaaaaaaa "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT" first status:blocked)
[[ "$fragment" == *'Recheck after: 2026-11-25T12:00:00Z'* ]]
comments=$(jq -nc --arg body "$fragment" '[{id:1,author:"runner_a",author_association:"MEMBER",created_at:"2026-11-24T12:00:00Z",body:$body}]')
terminal_blocker_dated_hold_active "$comments"
terminal_blocker_task_revision() { printf 'bbbbbbbbbbbbbbbbbbbbbbbb\n'; return 0; }
terminal_blocker_observation_hold_active "$comments" '{"body":"changed brief"}' owner/repo 42 ''
terminal_blocker_circuit_active "$comments" '{}' owner/repo 42 ''
rc=0
_tbr_release_circuit_hold owner/repo 42 '{"labels":[{"name":"status:blocked"}]}' "$comments" || rc=$?
[[ "$rc" != 0 ]]
printf 'PASS final exit capture, public timestamp, cross-runner hold and release guard\n'

captured=$(jq -nc '{detail:"BLOCKED: source_exhausted; recheck after 2026-11-27"}')
[[ "$(_terminal_blocker_recheck_after "$captured")" == 2026-11-27T00:00:00Z ]]
captured=$(jq -nc '{detail:"BLOCKED: recheck after 2026-02-30"}')
[[ -z "$(_terminal_blocker_recheck_after "$captured")" ]]
for reason in permission_required input_required runner_capability_unmet; do
	jq -nc --arg text "$report"$'\n'"TERMINAL_BLOCKER_REASON=$reason"$'\nTERMINAL_BLOCKER_INPUT_OWNER=maintainer' '{type:"text",text:$text}' >"$ROOT/output"
	terminal_blocker_capture_output "$ROOT/output"
	[[ -z "$AIDEVOPS_TERMINAL_BLOCKER_RECHECK_AFTER" ]]
done
# Neither tool output nor an earlier assistant part may introduce a deadline.
jq -nc --arg text "$report" '{type:"tool_result",text:$text},{type:"text",text:"BLOCKED: unspecified"}' >"$ROOT/output"
terminal_blocker_capture_output "$ROOT/output"
[[ -z "$AIDEVOPS_TERMINAL_BLOCKER_RECHECK_AFTER" ]]
TERMINAL_BLOCKER_NOW_EPOCH=1795608000
if terminal_blocker_dated_hold_active "$comments"; then exit 1; fi
printf 'PASS date validation, class isolation, final-only evidence and expiry\n'

TEST_TIMELINE='[{"event":"cross-referenced","source":{"issue":{"number":101,"repository_url":"https://api.github.com/repos/Owner/Repo","pull_request":{}}}},{"event":"cross-referenced","source":{"issue":{"number":102,"repository_url":"https://api.github.com/repos/owner/repo","pull_request":{}}}},{"event":"cross-referenced","source":{"issue":{"number":101,"repository_url":"https://api.github.com/repos/owner/repo","pull_request":{}}}}]'
TEST_MERGED=true
gh() {
	local command="$1" path="${2:-}"
	[[ "$command" == api ]] || return 1
	if [[ "$path" == --paginate ]]; then
		printf '%s\n' "$TEST_TIMELINE"
	else
		jq -nc --argjson merged "$TEST_MERGED" '{merged:$merged,merged_at:(if $merged then "2026-11-24T11:00:00Z" else null end),body:"Partial implementation. For #42"}'
	fi
	return 0
}
cap_issue='{"body":"Maximum: two-session cap. Remaining ledger: source consent pending."}'
cap_hold=$(terminal_blocker_session_cap_hold_active "$cap_issue" owner/repo 42)
[[ "$cap_hold" == *'budget=2 merged_prs=101,102 next_action=session_cap_split'* ]]
TEST_MERGED=false
if terminal_blocker_session_cap_hold_active "$cap_issue" owner/repo 42; then exit 1; fi
TEST_MERGED=true
TEST_TIMELINE=$(jq -c '.[0:1]' <<<"$TEST_TIMELINE")
if terminal_blocker_session_cap_hold_active "$cap_issue" owner/repo 42; then exit 1; fi
printf 'PASS cap exhaustion, REST source shape, distinct merged partial PRs and unspent budget\n'

# Exercise the supervisor's remote-intake path without local excerpts or writes.
TEST_COMMENTS="$comments"
fixture_issue=$(jq -nc '{state:"open",body:"### Files Scope\n- helper.sh",title:"phase",updated_at:"2026-11-24T12:00:00Z",labels:[{name:"status:blocked"}]}')
_tbr_entry_registered() { return 0; }
_tbr_check_intake_entry() { return 3; }
_tbr_skip_decided_unchanged() { return 1; }
_tbr_skip_unchanged_entry() { return 1; }
_tbr_decision_active() { return 1; }
_tbr_repo_path() { return 0; }
terminal_blocker_task_revision() { printf 'aaaaaaaaaaaaaaaaaaaaaaaa\n'; return 0; }
terminal_blocker_fetch_queue_issue() { printf '%s\n' "$fixture_issue"; return 0; }
terminal_blocker_fetch_trusted_comments() { printf '%s\n' "$TEST_COMMENTS"; return 0; }
_tbr_print_entry() { printf '{"intake":"remote_observation"}\n'; return 0; }
jq -nc '{repo:"owner/repo",issue:42,reason:"external_trigger_pending",intake:"remote_observation"}' >"$ROOT/entry.json"
TERMINAL_BLOCKER_NOW_EPOCH=1795521600
rc=0
_tbr_check_entry "$ROOT/entry.json" >"$ROOT/pending" || rc=$?
[[ "$rc" == 1 && ! -s "$ROOT/pending" ]]
TERMINAL_BLOCKER_NOW_EPOCH=1795608000
_tbr_check_entry "$ROOT/entry.json" >"$ROOT/pending"
jq -e '.recheck_after == "2026-11-25T12:00:00Z" and .next_action == "recheck_external_trigger"' "$ROOT/pending"
fixture_issue=$(jq -c --arg body 'two-session cap; unfinished ledger' '.body=$body' <<<"$fixture_issue")
TEST_TIMELINE=$(jq -nc '[101,102] | map({event:"cross-referenced",source:{issue:{number:.,repository_url:"https://api.github.com/repos/owner/repo",pull_request:{}}}})')
_tbr_check_entry "$ROOT/entry.json" >"$ROOT/pending"
jq -e '.scheduling.next_action == "session_cap_split" and (.scheduling.evidence | contains("merged_prs=101,102"))' "$ROOT/pending"
printf 'PASS future holds park remote intake; due dates and spent caps reach supervisor\n'
