#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by test-terminal-blocker-circuit.sh; no standalone runner.

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
