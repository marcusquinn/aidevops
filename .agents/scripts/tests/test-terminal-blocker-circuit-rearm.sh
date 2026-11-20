#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Permission-window and mechanical re-arm cases for the terminal-blocker circuit.
# Sourced by test-terminal-blocker-circuit.sh (shares its fixtures, print_result
# and TEST_* state); not executable standalone.

if [[ -n "${_TBC_REARM_TESTS_LOADED:-}" ]]; then
	return 0 2>/dev/null || exit 0
fi
_TBC_REARM_TESTS_LOADED=1

# GH#36232: a permission_required hold with no published permission request
# re-arms once per backoff window; a real request (label or undecided request
# marker) keeps it held, and timeout classes stay retry-only.
test_unevidenced_permission_window_rearm() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		export ZERO_OUTPUT_HOLD_WINDOW_SECONDS=43200
		export TERMINAL_BLOCKER_NOW_EPOCH=1793361600 # 2026-10-30T12:00:00Z
		local issue='{"title":"Fix helper","body":"original","labels":[{"name":"status:blocked"}]}'
		local revision="" fingerprint="" observation="" tb_comments="" variant="" receipt_log=""
		local projected=0 receipts=0 rc=0 request=""
		set_issue_status() {
			projected=$((projected + 1))
			return 0
		}
		_tbr_post_rearm_receipt() {
			local marker="$3"
			receipts=$((receipts + 1))
			receipt_log+="${marker};"
			tb_comments=$(jq -c --arg body "$marker" '. + [{id:(90 + length),body:$body,author_association:"MEMBER",created_at:"2026-10-30T11:59:00Z"}]' <<<"$tb_comments")
			return 0
		}
		gh_issue_edit_safe() { return 0; }
		fingerprint=$(_terminal_blocker_hash v2:permission_required)
		revision=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" permission_required) || exit 1
		# 14 hours old: one full window has elapsed (index 1).
		observation=$(jq -nc --arg r "$revision" --arg f "$fingerprint" \
			'[{id:10,body:("<!-- aidevops:terminal-blocker-observation revision="+$r+" blocker="+$f+" -->\nTerminal blocker: reason=permission_required owner=permission-maintainer"),author:"runner-b",author_association:"MEMBER",created_at:"2026-10-29T22:00:00Z"}]')
		request='{"id":11,"body":"<!-- aidevops-permission-request -->\n## Maintainer permission required\n\n**Request:** perm-0123456789abcdef","author":"runner-b","author_association":"COLLABORATOR","created_at":"2026-10-29T22:00:05Z"}'
		# Positive: unevidenced and older than the window is not an active hold.
		terminal_blocker_permission_request_evidenced "$observation" "$issue" && exit 1
		[[ "$(terminal_blocker_permission_window_expired "$observation" "$issue" "$(jq -c '.[0]' <<<"$observation")")" == 1 ]] || exit 1
		terminal_blocker_observation_hold_active "$observation" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		# The recovery pass projects status:available once with only the hidden receipt.
		tb_comments="$observation"
		_tbr_release_circuit_hold owner/repo 42 "$issue" "$tb_comments" 2>"${TEST_ROOT}/permission-window.err" || exit 1
		[[ "$projected" -eq 1 && "$receipts" -eq 1 ]] || exit 1
		[[ "$receipt_log" =~ ^'<!-- aidevops:terminal-blocker-rearmed key='[a-f0-9]{24}' -->;'$ ]] || exit 1
		grep -q 'reason=unevidenced_permission_window' "${TEST_ROOT}/permission-window.err" || exit 1
		# A second pass in the same window writes nothing.
		_tbr_release_circuit_hold owner/repo 42 "$issue" "$tb_comments" 2>/dev/null || exit 1
		[[ "$projected" -eq 1 && "$receipts" -eq 1 ]] || exit 1
		# The next window may release the same unchanged event once more.
		TERMINAL_BLOCKER_NOW_EPOCH=$((1793361600 + 43200)) _tbr_release_circuit_hold owner/repo 42 "$issue" "$tb_comments" 2>/dev/null || exit 1
		[[ "$projected" -eq 2 && "$receipts" -eq 2 ]] || exit 1
		# Negative: inside the window the observation still holds and writes nothing.
		projected=0 receipts=0
		variant=$(jq -c '.[0].created_at="2026-10-30T06:00:00Z"' <<<"$observation")
		terminal_blocker_observation_hold_active "$variant" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
		[[ "$(terminal_blocker_permission_rearm_after "$variant" "$issue")" == $((1793361600 - 21600 + 43200)) ]] || exit 1
		rc=0
		_tbr_release_circuit_hold owner/repo 42 "$issue" "$variant" 2>/dev/null || rc=$?
		[[ "$rc" -eq 2 && "$projected" -eq 0 ]] || exit 1
		# Negative: needs-maintainer-permissions keeps the hold; the label guard writes nothing.
		variant=$(jq -c '.labels += [{name:"needs-maintainer-permissions"}]' <<<"$issue")
		terminal_blocker_permission_request_evidenced "$observation" "$variant" || exit 1
		terminal_blocker_observation_hold_active "$observation" "$variant" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
		terminal_blocker_permission_rearm_after "$observation" "$variant" >/dev/null && exit 1
		_tbr_release_circuit_hold owner/repo 42 "$variant" "$observation" 2>/dev/null || exit 1
		[[ "$projected" -eq 0 ]] || exit 1
		# Negative: an undecided request marker keeps the hold.
		tb_comments=$(jq -c --argjson request "$request" '. + [$request]' <<<"$observation")
		terminal_blocker_permission_request_evidenced "$tb_comments" "$issue" || exit 1
		terminal_blocker_observation_hold_active "$tb_comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
		rc=0
		_tbr_release_circuit_hold owner/repo 42 "$issue" "$tb_comments" 2>/dev/null || rc=$?
		[[ "$rc" -eq 2 && "$projected" -eq 0 ]] || exit 1
		exit 0
	); then
		status=1
	fi
	print_result "unevidenced permission hold re-arms once per window; label or undecided request keeps it held" "$status"
	return 0
}

# GH#39232: after one window re-arm, a recorded human_decision keeps the
# permission hold through later windows. Only a plain OWNER/MEMBER reply, a
# trusted retry or a revision releases it; the cache drops the window wake.
test_decided_permission_window_holds() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		TBR_ROOT="${TEST_ROOT}/decided-permission"
		mkdir -p "${TBR_ROOT}/decisions" || exit 1
		export ZERO_OUTPUT_HOLD_WINDOW_SECONDS=43200
		export TERMINAL_BLOCKER_NOW_EPOCH=1793361600 # 2026-10-30T12:00:00Z
		local issue='{"title":"Fix workflow","body":"original","labels":[{"name":"status:blocked"},{"name":"needs-maintainer-input"}]}'
		local revision="" fingerprint="" tb_comments="" base="" variant="" entry="" rc=0
		local projected=0 receipts=0
		set_issue_status() {
			projected=$((projected + 1))
			return 0
		}
		_tbr_post_rearm_receipt() {
			local marker="$3"
			receipts=$((receipts + 1))
			tb_comments=$(jq -c --arg body "$marker" '. + [{id:(90 + length),body:$body,author_association:"MEMBER",created_at:"2026-10-30T12:00:30Z"}]' <<<"$tb_comments")
			return 0
		}
		gh_issue_edit_safe() { return 0; }
		fingerprint=$(_terminal_blocker_hash v2:permission_required)
		revision=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" permission_required) || exit 1
		tb_comments=$(jq -nc --arg r "$revision" --arg f "$fingerprint" \
			'[{id:10,body:("<!-- aidevops:terminal-blocker-observation revision="+$r+" blocker="+$f+" -->\nTerminal blocker: reason=permission_required owner=permission-maintainer"),author:"runner-b",author_association:"MEMBER",created_at:"2026-10-29T22:00:00Z"}]')
		# Window 1 re-arms as before (no decision recorded yet).
		_tbr_release_circuit_hold owner/repo 42 "$issue" "$tb_comments" 2>/dev/null || exit 1
		[[ "$projected" -eq 1 && "$receipts" -eq 1 ]] || exit 1
		# The brief owner re-holds and records human_decision (2026-10-30T12:30:00Z).
		printf '{"wake":"human_decision","recorded_epoch":1793363400}\n' >"${TBR_ROOT}/decisions/owner--repo--42.json"
		base="$tb_comments"
		export TERMINAL_BLOCKER_NOW_EPOCH=$((1793361600 + 43200))
		rc=0
		_tbr_release_circuit_hold owner/repo 42 "$issue" "$base" 2>"${TEST_ROOT}/decided-permission.err" || rc=$?
		[[ "$rc" -eq 4 && "$projected" -eq 1 && "$receipts" -eq 1 ]] || exit 1
		grep -q 'reason=decided_permission_hold' "${TEST_ROOT}/decided-permission.err" || exit 1
		# The decided stamp drops the time-based wake; an undecided one keeps it.
		entry="${TBR_ROOT}/entry.json"
		printf '{"rearm_after":1}\n' >"$entry"
		_tbr_stamp_rearm_check "$entry" 2026-10-31T00:00:00Z "$base" "$issue" decided || exit 1
		jq -e 'has("rearm_after") | not' "$entry" >/dev/null || exit 1
		# A signed or automation comment is not a reply and keeps the hold.
		variant=$(jq -c '. + [{id:200,body:"Decision\n<!-- aidevops:sig -->",author_association:"OWNER",created_at:"2026-10-30T13:00:00Z"}]' <<<"$base")
		rc=0
		_tbr_release_circuit_hold owner/repo 42 "$issue" "$variant" 2>/dev/null || rc=$?
		[[ "$rc" -eq 4 && "$projected" -eq 1 ]] || exit 1
		# A plain OWNER reply newer than the decision releases it.
		tb_comments=$(jq -c '. + [{id:201,body:"Granted the workflow scope.",author_association:"OWNER",created_at:"2026-10-30T13:00:00Z"}]' <<<"$base")
		_tbr_release_circuit_hold owner/repo 42 "$issue" "$tb_comments" 2>"${TEST_ROOT}/decided-permission.err" || exit 1
		[[ "$projected" -eq 2 && "$receipts" -eq 2 ]] || exit 1
		grep -q 'reason=unevidenced_permission_window' "${TEST_ROOT}/decided-permission.err" || exit 1
		# A trusted retry releases despite a standing decision.
		tb_comments=$(jq -c '. + [{id:202,body:"terminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-10-30T13:00:00Z"}]' <<<"$base")
		_tbr_release_circuit_hold owner/repo 42 "$issue" "$tb_comments" 2>"${TEST_ROOT}/decided-permission.err" || exit 1
		[[ "$projected" -eq 3 && "$receipts" -eq 3 ]] || exit 1
		grep -q 'reason=trusted_retry' "${TEST_ROOT}/decided-permission.err" || exit 1
		exit 0
	); then
		status=1
	fi
	print_result "recorded human_decision suspends the permission window re-arm until a reply or trusted retry" "$status"
	return 0
}

# GH#36232: request evidence trust, the repeated-circuit form and the
# unchanged retry-only timeout classes.
test_unevidenced_permission_window_evidence() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		export ZERO_OUTPUT_HOLD_WINDOW_SECONDS=43200
		export TERMINAL_BLOCKER_NOW_EPOCH=1793361600 # 2026-10-30T12:00:00Z
		local issue='{"title":"Fix helper","body":"original","labels":[{"name":"status:blocked"}]}'
		local revision="" fingerprint="" observation="" tb_comments="" variant="" circuit=""
		local projected=0 rc=0 request="" timeout_fp=""
		set_issue_status() {
			projected=$((projected + 1))
			return 0
		}
		_tbr_post_rearm_receipt() { return 0; }
		fingerprint=$(_terminal_blocker_hash v2:permission_required)
		revision=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" permission_required) || exit 1
		observation=$(jq -nc --arg r "$revision" --arg f "$fingerprint" \
			'[{id:10,body:("<!-- aidevops:terminal-blocker-observation revision="+$r+" blocker="+$f+" -->"),author:"runner-b",author_association:"MEMBER",created_at:"2026-10-29T22:00:00Z"}]')
		request='{"id":11,"body":"<!-- aidevops-permission-request -->\n**Request:** perm-0123456789abcdef","author":"runner-b","author_association":"COLLABORATOR","created_at":"2026-10-29T22:00:05Z"}'
		tb_comments=$(jq -c --argjson request "$request" '. + [$request]' <<<"$observation")
		terminal_blocker_permission_request_evidenced "$tb_comments" "$issue" || exit 1
		# A foreign (NONE) marker is not request evidence; neither is quoted prose.
		variant=$(jq -c '.[1].author="outsider" | .[1].author_association="NONE"' <<<"$tb_comments")
		terminal_blocker_permission_request_evidenced "$variant" "$issue" && exit 1
		variant=$(jq -c '.[1].body = ("> " + .[1].body)' <<<"$tb_comments")
		terminal_blocker_permission_request_evidenced "$variant" "$issue" && exit 1
		# A later OWNER/MEMBER signed decision for that request ends the evidence;
		# a COLLABORATOR or other-request decision does not.
		variant=$(jq -c '. + [{id:12,body:"<!-- aidevops-signed-permission-withdrawal -->\nperm-0123456789abcdef",author_association:"COLLABORATOR",created_at:"2026-10-29T23:00:00Z"}]' <<<"$tb_comments")
		terminal_blocker_permission_request_evidenced "$variant" "$issue" || exit 1
		variant=$(jq -c '. + [{id:12,body:"<!-- aidevops-signed-permission-grant -->\nperm-ffffffffffffffff",author_association:"OWNER",created_at:"2026-10-29T23:00:00Z"}]' <<<"$tb_comments")
		terminal_blocker_permission_request_evidenced "$variant" "$issue" || exit 1
		variant=$(jq -c '. + [{id:12,body:"<!-- aidevops-signed-permission-grant -->\nperm-0123456789abcdef",author_association:"OWNER",created_at:"2026-10-29T23:00:00Z"}]' <<<"$tb_comments")
		terminal_blocker_permission_request_evidenced "$variant" "$issue" && exit 1
		terminal_blocker_observation_hold_active "$variant" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		# A repeated permission circuit follows the same window in dispatch and recovery.
		circuit=$(jq -c '.[0].body |= sub("terminal-blocker-observation"; "terminal-blocker-circuit")' <<<"$observation")
		terminal_blocker_circuit_active "$circuit" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		_tbr_circuit_blocks_release "$(jq -c '.[0]' <<<"$circuit")" '' "$issue" owner/repo 42 "$TEST_ROOT" "$circuit" && exit 1
		# Without the comments, request evidence is unknown: keep the circuit.
		_tbr_circuit_blocks_release "$(jq -c '.[0]' <<<"$circuit")" '' "$issue" owner/repo 42 "$TEST_ROOT" || exit 1
		variant=$(jq -c --argjson request "$request" '. + [$request]' <<<"$circuit")
		terminal_blocker_circuit_active "$variant" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
		variant=$(jq -c '.[0].created_at="2026-10-30T06:00:00Z"' <<<"$circuit")
		terminal_blocker_circuit_active "$variant" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
		# Push/network policy timeouts stay retry-only however old they are.
		for timeout_fp in push_policy_timeout network_policy_timeout; do
			projected=0
			variant=$(jq -c --arg f "$(_terminal_blocker_hash "v2:${timeout_fp}")" \
				'.[0].body |= sub("blocker=[a-f0-9]{24}"; "blocker=" + $f) | .[0].created_at="2026-09-01T00:00:00Z"' <<<"$observation")
			terminal_blocker_observation_hold_active "$variant" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
			rc=0
			_tbr_release_circuit_hold owner/repo 42 "$issue" "$variant" 2>/dev/null || rc=$?
			[[ "$rc" -eq 2 && "$projected" -eq 0 ]] || exit 1
		done
		exit 0
	); then
		status=1
	fi
	print_result "permission request evidence is trust-bound; circuits share the window; timeouts stay retry-only" "$status"
	return 0
}

# GH#36342: the window re-arms an unevidenced permission hold once per
# unchanged result. After a repeated identical exit it waits for a new
# OWNER/MEMBER comment, a trusted retry or a brief revision.
test_permission_window_rearms_once_per_result() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		export ZERO_OUTPUT_HOLD_WINDOW_SECONDS=43200
		export TERMINAL_BLOCKER_NOW_EPOCH=1793361600 # 2026-10-30T12:00:00Z
		local issue='{"title":"Live probe","body":"needs operator billing","labels":[{"name":"status:blocked"}]}'
		local revision="" fingerprint="" observation="" tb_comments="" repeated="" variant="" edited=""
		local projected=0 receipts=0 rc=0 receipt_at=2026-10-30T11:59:00Z
		local later=$((1793361600 + 86400)) # 2026-10-31T12:00:00Z
		set_issue_status() {
			projected=$((projected + 1))
			return 0
		}
		_tbr_post_rearm_receipt() {
			local marker="$3" extra="${4:-}"
			receipts=$((receipts + 1))
			tb_comments=$(jq -c --arg body "${marker}"$'\n'"${extra}"$'\n<!-- aidevops:origin:worker -->' --arg at "$receipt_at" \
				'. + [{id:(100 + length),body:$body,author:"runner-a",author_association:"MEMBER",created_at:$at}]' <<<"$tb_comments")
			return 0
		}
		add_comment() {
			local body="$1" at="$2" association="${3:-MEMBER}"
			tb_comments=$(jq -c --arg body "$body" --arg at "$at" --arg a "$association" \
				'. + [{id:(100 + length),body:$body,author:"runner-a",author_association:$a,created_at:$at}]' <<<"$tb_comments")
			return 0
		}
		gh_issue_edit_safe() { return 0; }
		fingerprint=$(_terminal_blocker_hash v2:permission_required)
		revision=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" permission_required) || exit 1
		observation="<!-- aidevops:terminal-blocker-observation revision=${revision} blocker=${fingerprint} -->"
		# An older OWNER condition predates the hold; it is not new input.
		tb_comments='[{"id":5,"body":"Operator billing authority is required.\n<!-- aidevops:origin:interactive -->","author":"owner","author_association":"OWNER","created_at":"2026-10-03T07:56:53Z"}]'
		add_comment $'CLAIM_RELEASED reason=blocked runner=runner-a\n'"${observation}" 2026-10-29T22:00:00Z
		# First window (the GH#36232 runner-local case): re-arms once and records the brief.
		terminal_blocker_permission_window_spent "$tb_comments" "$issue" "$(jq -c '.[1]' <<<"$tb_comments")" && exit 1
		_tbr_release_circuit_hold owner/repo 42 "$issue" "$tb_comments" 2>/dev/null || exit 1
		[[ "$projected" -eq 1 && "$receipts" -eq 1 ]] || exit 1
		jq -e 'last.body | test("<!-- aidevops:terminal-blocker-rearm-brief revision=[a-f0-9]{24} -->")' <<<"$tb_comments" >/dev/null || exit 1
		# The re-armed attempt repeats the identical result (circuit form).
		repeated=$(jq -c --arg r "$revision" --arg f "$fingerprint" \
			'. + [{id:200,body:("CLAIM_RELEASED reason=blocked runner=runner-a\n<!-- aidevops:terminal-blocker-circuit revision=" + $r + " blocker=" + $f + " -->"),author:"runner-a",author_association:"MEMBER",created_at:"2026-10-30T12:05:00Z"}]' <<<"$tb_comments")
		export TERMINAL_BLOCKER_NOW_EPOCH="$later"
		terminal_blocker_permission_window_spent "$repeated" "$issue" "$(jq -c 'last' <<<"$repeated")" || exit 1
		terminal_blocker_circuit_active "$repeated" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
		terminal_blocker_permission_rearm_after "$repeated" "$issue" >/dev/null && exit 1
		rc=0
		_tbr_release_circuit_hold owner/repo 42 "$issue" "$repeated" 2>/dev/null || rc=$?
		[[ "$rc" -eq 2 && "$projected" -eq 1 ]] || exit 1
		# Open-circuit form: a bare blocked release after the re-arm is also a repeat.
		repeated=$(jq -c '. + [{id:201,body:"CLAIM_RELEASED reason=blocked runner=runner-a ts=2026-10-30T12:05:00Z\n<!-- aidevops:origin:worker -->",author:"runner-a",author_association:"MEMBER",created_at:"2026-10-30T12:05:00Z"}]' <<<"$tb_comments")
		terminal_blocker_observation_hold_active "$repeated" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
		rc=0
		_tbr_release_circuit_hold owner/repo 42 "$issue" "$repeated" 2>"${TEST_ROOT}/permission-spent.err" || rc=$?
		[[ "$rc" -eq 2 && "$projected" -eq 1 ]] || exit 1
		grep -q 'reason=permission_window_spent' "${TEST_ROOT}/permission-spent.err" || exit 1
		# Automation comments from an OWNER-associated runner are not new input.
		variant=$(jq -c '. + [{id:202,body:"<!-- ops:start -->\nDISPATCH_CLAIM nonce=abc runner=runner-a",author:"owner",author_association:"OWNER",created_at:"2026-10-30T13:00:00Z"}]' <<<"$repeated")
		terminal_blocker_observation_hold_active "$variant" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
		# A collaborator comment is not trusted input either.
		variant=$(jq -c '. + [{id:202,body:"Any update?",author:"helper",author_association:"COLLABORATOR",created_at:"2026-10-30T13:00:00Z"}]' <<<"$repeated")
		terminal_blocker_observation_hold_active "$variant" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
		# A newer OWNER/MEMBER comment re-arms the window once more.
		variant=$(jq -c '. + [{id:202,body:"Billing scope is configured now.",author:"owner",author_association:"OWNER",created_at:"2026-10-30T13:00:00Z"}]' <<<"$repeated")
		terminal_blocker_observation_hold_active "$variant" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		tb_comments="$variant" receipt_at=2026-10-30T13:05:00Z
		_tbr_release_circuit_hold owner/repo 42 "$issue" "$tb_comments" 2>/dev/null || exit 1
		[[ "$projected" -eq 2 && "$receipts" -eq 2 ]] || exit 1
		# A repeat after that input is spent again.
		add_comment $'CLAIM_RELEASED reason=blocked runner=runner-a\n<!-- aidevops:origin:worker -->' 2026-10-30T13:10:00Z
		terminal_blocker_observation_hold_active "$tb_comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
		# A brief revision differs from the recorded brief: one more re-arm.
		edited=$(jq -c '.body = "operator billing scope supplied"' <<<"$issue")
		terminal_blocker_observation_hold_active "$tb_comments" "$edited" owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		receipt_at=2026-10-30T13:20:00Z
		_tbr_release_circuit_hold owner/repo 42 "$edited" "$tb_comments" 2>/dev/null || exit 1
		[[ "$projected" -eq 3 && "$receipts" -eq 3 ]] || exit 1
		add_comment $'CLAIM_RELEASED reason=blocked runner=runner-a\n<!-- aidevops:origin:worker -->' 2026-10-30T13:30:00Z
		terminal_blocker_observation_hold_active "$tb_comments" "$edited" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
		# Issue metadata without a brief cannot fake a brief revision.
		terminal_blocker_observation_hold_active "$tb_comments" '{}' owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
		exit 0
	); then
		status=1
	fi
	print_result "permission window re-arms once per unchanged result; new trusted input or brief revision re-arms it" "$status"
	return 0
}

test_mechanical_rearm_pass() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		TBR_ROOT="${TEST_ROOT}/mechanical-rearm"
		TBR_REPOS_JSON="$REPOS_JSON"
		# Load shared runtime functions before installing write stubs: the first
		# budget initialization otherwise replaces set_issue_status.
		_tbr_start_budget || exit 1
		local tb_fixture_comments='[]' fixture_at=2026-10-30T01:00:00Z
		local revision="" fingerprint="" queue_file="" rc=0 projected=0 receipts=0
		local fixture_issue='{"state":"open","title":"Fix helper","body":"original","labels":[{"name":"status:blocked"}]}'
		export TERMINAL_BLOCKER_SELF_LOGIN=runner-one
		# Exercise the real queue/mode logic in process with the suite's existing
		# write stubs; bounded subprocess execution is covered by intake tests.
		_tbr_run_stage() { shift; "$@"; return $?; }
		tbr_seed() { exit 1; }
		# Discovery has its own coverage (test_owner_scoped_discovery).
		tbr_discover() { return 0; }
		_tbr_decision_active() { exit 1; }
		gh() {
			local args="$*"
			[[ "$args" == 'api repos/owner/repo/issues/42' ]] || return 1
			printf '%s\n' "$fixture_issue" | jq -c --arg at "$fixture_at" '. + {updated_at:$at}'
			return 0
		}
		terminal_blocker_fetch_trusted_comments() {
			printf 'read\n' >>"${TBR_ROOT}/comment-reads"
			printf '%s\n' "$tb_fixture_comments"
			return 0
		}
		set_issue_status() { projected=$((projected + 1)); return 0; }
		_tbr_post_rearm_receipt() { receipts=$((receipts + 1)); return 0; }
		revision=$(terminal_blocker_task_revision "$fixture_issue" owner/repo 42 "$TEST_ROOT" permission_required) || exit 1
		fingerprint=$(_terminal_blocker_hash v2:permission_required)
		tb_fixture_comments=$(jq -nc --arg r "$revision" --arg f "$fingerprint" \
			'[{id:10,body:("<!-- aidevops:terminal-blocker-observation revision="+$r+" blocker="+$f+" -->"),author_association:"MEMBER",created_at:"2026-10-30T00:00:00Z"}]')
		tbr_enqueue owner/repo 42 permission_required || exit 1
		queue_file="${TBR_ROOT}/queue/owner--repo--42.json"
		tbr_main rearm >"${TBR_ROOT}/out" || exit 1
		[[ -f "$queue_file" && "$projected" -eq 0 && "$receipts" -eq 0 && ! -s "${TBR_ROOT}/out" ]] || exit 1
		[[ "$(jq -r .rearm_checked_updated_at "$queue_file")" == "$fixture_at" ]] || exit 1
		# GH#36232: an unevidenced permission hold records its next window
		# boundary; unchanged snapshots are skipped only until then.
		[[ "$(jq -r .rearm_after "$queue_file")" == $((1793318400 + ZERO_OUTPUT_HOLD_WINDOW_SECONDS)) ]] || exit 1
		tbr_main rearm >"${TBR_ROOT}/out" || exit 1
		TERMINAL_BLOCKER_NOW_EPOCH=$((1793318400 + ZERO_OUTPUT_HOLD_WINDOW_SECONDS - 1)) tbr_main rearm >"${TBR_ROOT}/out" || exit 1
		[[ "$(wc -l <"${TBR_ROOT}/comment-reads")" -eq 1 && "$projected" -eq 0 ]] || exit 1
		# An incomplete fetch must not stamp the newer snapshot or lose intake.
		fixture_at=2026-10-30T02:00:00Z
		terminal_blocker_fetch_trusted_comments() { return 1; }
		tbr_main rearm >"${TBR_ROOT}/out" || rc=$?
		[[ "$rc" -eq 2 && "$(jq -r .rearm_checked_updated_at "$queue_file")" != "$fixture_at" ]] || exit 1
		terminal_blocker_fetch_trusted_comments() { printf '%s\n' "$tb_fixture_comments"; return 0; }
		tb_fixture_comments=$(jq -c '. + [{id:11,body:"terminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-10-30T01:30:00Z"}]' <<<"$tb_fixture_comments")
		tbr_main rearm >"${TBR_ROOT}/out" || exit 1
		[[ ! -f "$queue_file" && "$projected" -eq 1 && "$receipts" -eq 1 && ! -s "${TBR_ROOT}/out" ]] || exit 1
		[[ -f "${TBR_ROOT}/rearm_cursor" && ! -f "${TBR_ROOT}/pending_cursor" ]] || exit 1
		# Target movement must re-arm both first observations and circuits even
		# when the issue snapshot (including updated_at) has not changed.
		_tbr_repo_path() { printf '%s\n' "$TEST_ROOT"; return 0; }
		local marker=""
		for marker in observation circuit; do
			projected=0 receipts=0
			TEST_TARGET_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
			revision=$(terminal_blocker_task_revision "$fixture_issue" owner/repo 42 "$TEST_ROOT" target_code_blocker) || exit 1
			fingerprint=$(_terminal_blocker_hash v2:target_code_blocker)
			tb_fixture_comments=$(jq -nc --arg r "$revision" --arg f "$fingerprint" --arg m "$marker" \
				'[{id:10,body:("<!-- aidevops:terminal-blocker-"+$m+" revision="+$r+" blocker="+$f+" -->"),author_association:"MEMBER",created_at:"2026-10-30T00:00:00Z"}]')
			tbr_enqueue owner/repo 42 target_code_blocker || exit 1
			tbr_main rearm >"${TBR_ROOT}/out" || exit 1
			[[ -f "$queue_file" && "$projected" -eq 0 && "$(jq -r .rearm_checked_updated_at "$queue_file")" == "$fixture_at" ]] || exit 1
			TEST_TARGET_REVISION=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
			tbr_main rearm >"${TBR_ROOT}/out" || exit 1
			[[ ! -f "$queue_file" && "$projected" -eq 1 && "$receipts" -eq 1 && ! -s "${TBR_ROOT}/out" ]] || exit 1
		 done
		exit 0
	); then
		status=1
	fi
	print_result "mechanical rearm releases trusted retry without LLM work, skips unchanged comments and retries incomplete reads" "$status"
	return 0
}

# GH#36126: a re-armed hold whose declared blocked-by dependency is still open
# stays blocked without a receipt and keeps its queue entry, rechecking every
# pass even when the issue snapshot is unchanged, then releases once the
# dependency resolves.
test_rearm_waits_for_blocked_by_dependency() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		TBR_ROOT="${TEST_ROOT}/dependency-rearm"
		TBR_REPOS_JSON="$REPOS_JSON"
		# Load shared runtime functions before installing write stubs.
		_tbr_start_budget || exit 1
		# Fixture names must not collide with _tbr_check_entry locals (issue,
		# comments): stubs run under bash dynamic scoping.
		local dep_fixture_comments='[]' revision="" marker="" queue_file="" rc=0 projected=0 receipts=0 dep_checks=0
		local dep_fixture_issue='{"state":"open","title":"Publish logos","body":"original","labels":[{"name":"status:blocked"}],"updated_at":"2026-10-30T01:00:00Z"}'
		export TERMINAL_BLOCKER_SELF_LOGIN=runner-one
		_tbr_run_stage() { shift; "$@"; return $?; }
		tbr_seed() { exit 1; }
		_tbr_decision_active() { exit 1; }
		gh() {
			[[ "$*" == 'api repos/owner/repo/issues/42' ]] || return 1
			printf '%s\n' "$dep_fixture_issue"
			return 0
		}
		terminal_blocker_fetch_trusted_comments() { printf '%s\n' "$dep_fixture_comments"; return 0; }
		set_issue_status() { projected=$((projected + 1)); return 0; }
		_tbr_post_rearm_receipt() { receipts=$((receipts + 1)); return 0; }
		is_blocked_by_unresolved() {
			local repo_slug="$2"
			local issue_number="$3"
			dep_checks=$((dep_checks + 1))
			[[ "$repo_slug" == owner/repo && "$issue_number" == 42 ]] || exit 1
			[[ "$TEST_BLOCKED_BY" == unresolved ]] && return 0
			return 1
		}
		revision=$(terminal_blocker_task_revision "$dep_fixture_issue" owner/repo 42 "$TEST_ROOT" permission_required) || exit 1
		marker="<!-- ${_TBC_OBSERVATION_MARKER} revision=${revision} blocker=$(_terminal_blocker_hash v2:permission_required) -->"
		dep_fixture_comments=$(jq -nc --arg m "$marker" \
			'[{id:10,body:$m,author_association:"MEMBER",created_at:"2026-10-30T00:00:00Z"},
			  {id:11,body:"Maintainer recovery.\n\nterminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-10-30T00:30:00Z"}]')
		# The release helper itself reports the dependency hold distinctly.
		TEST_BLOCKED_BY=unresolved
		_tbr_release_circuit_hold owner/repo 42 "$dep_fixture_issue" "$dep_fixture_comments" 2>"${TEST_ROOT}/dependency-rearm.err" || rc=$?
		[[ "$rc" -eq 3 && "$projected" -eq 0 && "$receipts" -eq 0 ]] || exit 1
		[[ "$(<"${TEST_ROOT}/dependency-rearm.err")" == *'reason=dependency_blocked'* ]] || exit 1
		tbr_enqueue owner/repo 42 permission_required || exit 1
		queue_file="${TBR_ROOT}/queue/owner--repo--42.json"
		# Two complete passes with an unchanged snapshot: held, never stamped.
		dep_checks=0
		tbr_main rearm >"${TBR_ROOT}/out" 2>/dev/null || exit 1
		tbr_main rearm >"${TBR_ROOT}/out" 2>/dev/null || exit 1
		[[ -f "$queue_file" && "$projected" -eq 0 && "$receipts" -eq 0 && "$dep_checks" -eq 2 && ! -s "${TBR_ROOT}/out" ]] || exit 1
		[[ -z "$(jq -r '.rearm_checked_updated_at // ""' "$queue_file")" ]] || exit 1
		# The blocker closes without touching this issue: the next pass releases.
		TEST_BLOCKED_BY=resolved
		tbr_main rearm >"${TBR_ROOT}/out" 2>/dev/null || exit 1
		[[ ! -f "$queue_file" && "$projected" -eq 1 && "$receipts" -eq 1 && ! -s "${TBR_ROOT}/out" ]] || exit 1
		exit 0
	); then
		status=1
	fi
	print_result "re-armed hold with an unresolved blocked-by dependency stays queued without a receipt and releases once it resolves" "$status"
	return 0
}

test_mechanical_rearm_scheduler() {
	local status=0
	if ! (
		# shellcheck source=../pulse-dispatch-engine.sh
		source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"
		local PULSE_DIR="${TEST_ROOT}/rearm-pulse" LOGFILE="${TEST_ROOT}/rearm-pulse.log"
		local _CIRCUIT_BREAKER_STATE_FILE="${TEST_ROOT}/rearm-circuit" calls=0 cooldown=0
		local PULSE_BLOCKER_REARM_INTERVAL=600
		mkdir -p "$PULSE_DIR"
		bash() { [[ "$*" == "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh rearm" ]] || return 1; calls=$((calls + 1)); return 0; }
		_gh_secondary_cooldown_active() { [[ "$cooldown" -eq 1 ]] && return 0; return 1; }
		_pulse_rearm_blocker_holds 1000 || exit 1
		_pulse_rearm_blocker_holds 1599 || exit 1
		[[ "$calls" -eq 1 ]] || exit 1
		cooldown=1
		_pulse_rearm_blocker_holds 1600 || exit 1
		[[ "$calls" -eq 1 && "$(<"${PULSE_DIR}/last_blocker_rearm_check_epoch")" == 1000 ]] || exit 1
		cooldown=0
		printf 'active\n' >"$_CIRCUIT_BREAKER_STATE_FILE"
		_pulse_rearm_blocker_holds 1600 || exit 1
		[[ "$calls" -eq 1 ]] || exit 1
		rm -f "$_CIRCUIT_BREAKER_STATE_FILE"
		_pulse_rearm_blocker_holds 1600 || exit 1
		[[ "$calls" -eq 2 && ! -f "${PULSE_DIR}/last_blocker_recovery_check_epoch" && ! -f "${PULSE_DIR}/llm_trigger_mode" ]] || exit 1
		PULSE_BLOCKER_REARM_INTERVAL=0
		_pulse_rearm_blocker_holds 3000 || exit 1
		[[ "$calls" -eq 2 && "$(declare -f _run_preflight_stages)" == *'_pulse_rearm_blocker_holds'* ]] || exit 1
		exit 0
	); then
		status=1
	fi
	print_result "mechanical rearm cadence is independent of LLM state and respects API cooldown and circuit state" "$status"
	return 0
}
