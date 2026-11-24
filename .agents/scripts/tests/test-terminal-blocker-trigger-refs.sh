#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by test-terminal-blocker-circuit.sh; no standalone runner.

# t19343: table-driven parser cases plus the empty-refs backfill gate.
_trigger_revisit_refs_parser_cases() {
	local row="" text="" want="" got=""
	local -a rows=(
		'Issue 31853 (people phase) closed|31853'
		'GH#34444 (fix) merges to develop|34444'
		'GH#9999999 merges|9999999'
		'GH#12345678 merges|'
		'issue 9999999 closes|9999999'
		'issue 12345678 closes|'
		'#9999999 closes|9999999'
		'#12345678 closes|'
		'PR #12345678 merges|'
		'phase 12345678 completes|'
		'GH#12345678901234567890 and issue 31853 close|31853'
		'gH#34444 and pUlL rEqUeSt 35555 merge|34444 35555'
		'owner/service-GH#34444 merges|'
		'owner/service-GH#34444 and GH#35555 merge|35555'
		'fix for issue 31960 (worker PR 32080) into develop|31960 32080'
		'Media phase 32312 reconciles|32312'
		'PR #7 merged|7'
		'#7 merged|7'
		'Issue #7 closes|7'
		'owner/repo#7 merged|'
		'phase 2 completes|'
		'ceremony on 25 November 2026|'
	)
	for row in "${rows[@]}"; do
		text="${row%%|*}"
		want="${row#*|}"
		got=$(_tbtr_trigger_refs "$text" | tr '\n' ' ')
		got="${got% }"
		[[ "$got" == "$want" ]] || { printf 'refs parser: "%s" -> "%s" (want "%s")\n' "$text" "$got" "$want" >&2; return 1; }
	done
	# Waiting record with empty refs and no refs_parser is due once for a re-parse.
	_tbtr_ref_wake_due owner/repo 42 '{"decision":"scheduled","trigger_refs":[]}' || return 1
	! _tbtr_ref_wake_due owner/repo 42 '{"decision":"scheduled","trigger_refs":[],"refs_parser":2}' || return 1
	# Legacy acknowledgements must not prevent re-parsing nonempty ref sets.
	_tbtr_ref_wake_due owner/repo 42 '{"decision":"still_pending","trigger_refs":[30000],"refs_met":true}' || return 1
	_trigger_revisit_refs_ack_cases || return 1
	return 0
}

# Acknowledgements belong to the parsed set, not just the observation.
_trigger_revisit_refs_ack_cases() (
	local record='{"decision":"still_pending","trigger_refs":[30000],"refs_met":true,"refs_parser":2}' state=""
	_tbtr_refs_resolved() { return 0; }
	state=$(_tbtr_refs_state owner/repo '#30000 and GH#34444 merge' "$record")
	[[ "$state" == '[30000,34444] true true' ]] || return 1
	_tbtr_refs_resolved() { return 1; }
	state=$(_tbtr_refs_state owner/repo '#30000 and GH#34444 merge' "$record")
	[[ "$state" == '[30000,34444] false false' ]] || return 1
	_tbtr_record_scheduled owner/repo 42 "$record" key updated 9999999999 1 '[30000,34444]' false
	record=$(_tbtr_record_read owner/repo 42) || return 1
	jq -e '.trigger_refs == [30000,34444] and .refs_met == false' <<<"$record" >/dev/null || return 1
	! _tbtr_ref_wake_due owner/repo 42 "$record" || return 1
	_tbtr_refs_resolved() { return 0; }
	_tbtr_ref_wake_due owner/repo 42 "$record" || return 1
	# Unchanged sets (including reordered storage) retain their acknowledgement.
	record=$(jq -c '.refs_met = true | .trigger_refs = [34444,30000]' <<<"$record")
	state=$(_tbtr_refs_state owner/repo '#30000 and GH#34444 merge' "$record")
	[[ "$state" == '[30000,34444] true false' ]] || return 1
	_tbtr_record_scheduled owner/repo 42 "$record" key updated 9999999999 1 '[30000,34444]' false
	record=$(_tbtr_record_read owner/repo 42) || return 1
	jq -e '.refs_met == true' <<<"$record" >/dev/null || return 1
	! _tbtr_ref_wake_due owner/repo 42 "$record" || return 1
	return 0
)
