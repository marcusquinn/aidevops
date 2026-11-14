#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

# Sourced by checkpoint continuation. Route only a release already admitted by
# _pcc_stall_release_evidence; never infer a tier from labels or local telemetry.
# shellcheck source=shared-model-tier.sh
source "${SCRIPT_DIR}/shared-model-tier.sh"

# Args: comments, trusted logins, admitted release id, exact head
# Output: next tier<TAB>available concrete model. Unknown/ceiling stays paused.
_pcc_next_stalled_tier() {
	local comments="$1" trusted_logins="$2" release_id="$3" head="$4"
	local previous="" next="" model=""
	[[ -z "${PR_REVIEW_THREAD_RESPONSE_MODEL:-}" ]] || return 1
	# aidevops:trust-boundary — the caller's admitted release is rechecked for
	# trusted authorship, unedited body, unique fields and exact head binding.
	previous=$(jq -er --argjson trusted_logins "$trusted_logins" --arg pattern "$_PCC_STALL_RELEASE_PATTERN" \
		--argjson release "$release_id" --arg head "$head" "${_PCC_JQ_RELEASE_DEFS}"'
		[flatten[] | select(.id == $release and trusted_event and unedited) |
			select(release_reason | test($pattern)) |
			[body_lines | select(is_release)] | select(length == 1) | .[0] |
			select(([scan("(?:^| )checkpoint_head=([^ ]+)")] | length) == 1) |
			select(([scan("(?:^| )checkpoint_tier=([^ ]+)")] | length) == 1) |
			select(field("checkpoint_head") == $head) | field("checkpoint_tier") |
			select(test("^(simple|standard|thinking)$"))] |
		select(length == 1) | .[0]
	' <<<"$comments") || return 1
	next=$(model_tier_next "$previous") || return 1
	while [[ -n "$next" ]]; do
		# Never accept a resolver fallback from another tier. Both arguments
		# preserve tier-specific reasoning when one model serves multiple tiers.
		if model=$("${SCRIPT_DIR}/model-availability-helper.sh" resolve "$next" --quiet) &&
			model_tier_candidate_index "$next" "$model" >/dev/null 2>&1; then
			printf '%s\t%s\n' "$next" "$model"
			return 0
		fi
		next=$(model_tier_next "$next") || return 1
	done
	return 1
}

# Append routing identity without resetting another release's bounded state.
_pcc_escalated_fingerprint() {
	local fingerprint="$1"
	if [[ -n "${PCC_ESCALATION_TIER:-}" ]]; then
		[[ "$PCC_HEAD_OID" == "$PCC_ESCALATION_HEAD" ]] || return 1
		fingerprint="${fingerprint}:tier-${PCC_ESCALATION_TIER}:release-${PCC_ESCALATION_RELEASE}"
	fi
	printf '%s\n' "$fingerprint"
	return 0
}

# Set caller-local routing fields only for a verified two-stall, unfused head.
# Args: repo, PR, head, release, stalls, nonprogress, total, comments, logins
_pcc_prepare_stall_escalation() {
	local repo="$1" pr="$2" head="$3" release_id="$4" stalls="$5"
	local nonprogress="$6" pr_releases="$7" comments="$8" trusted_logins="$9" escalation=""
	[[ "$stalls" -ge 2 && "$nonprogress" -lt "$_PCC_MAX_PR_RELEASES" &&
		"$pr_releases" -lt "$_PCC_MAX_PR_PROGRESS_RELEASES" ]] || return 1
	if ! escalation=$(_pcc_next_stalled_tier "$comments" "$trusted_logins" "$release_id" "$head"); then
		printf 'STALLED_CHECKPOINT_TIER_UNAVAILABLE: PR #%s in %s head=%s release=%s retaining bounded pause\n' \
			"$pr" "$repo" "$head" "$release_id"
		return 1
	fi
	IFS=$'\t' read -r PCC_ESCALATION_TIER PCC_ESCALATION_MODEL <<<"$escalation"
	PCC_ESCALATION_RELEASE="$release_id"
	PCC_ESCALATION_HEAD="$head"
	printf 'STALLED_CHECKPOINT_TIER_ESCALATED: PR #%s in %s head=%s release=%s tier=%s\n' \
		"$pr" "$repo" "$head" "$release_id" "$PCC_ESCALATION_TIER"
	return 0
}

# Keep a capability-ineligible runner off the dispatch path, even at higher tier.
_pcc_runner_capability_fenced() {
	local repo="$1" issue="$2" pr="$3" head="$4" comments="$5" head_date="$6" login="$7"
	local self_release=""
	self_release=$(_pcc_self_capability_release "$comments" "$head_date" "$login" 2>/dev/null) || return 1
	printf 'STALLED_CHECKPOINT_CONTINUATION_SKIPPED: PR #%s in %s head=%s — runner %s already released it as runner_capability_unmet (release=%s) issue=#%s\n' \
		"$pr" "$repo" "$head" "$login" "$self_release" "$issue"
	return 0
}
