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
	previous=$(jq -er --argjson trusted_logins "$trusted_logins" \
		--argjson release "$release_id" --arg head "$head" "${_PCC_JQ_RELEASE_DEFS}"'
		[flatten[] | select(.id == $release and trusted_event and unedited) |
			[body_lines | select(is_release)] | select(length == 1) | .[0] |
			select(([scan("(?:^| )checkpoint_head=([^ ]+)")] | length) == 1) |
			select(([scan("(?:^| )checkpoint_tier=([^ ]+)")] | length) == 1) |
			select(field("checkpoint_head") == $head) | field("checkpoint_tier") |
			select(test("^(simple|standard|thinking)$"))] |
		select(length == 1) | .[0]
	' <<<"$comments") || return 1
	next=$(model_tier_next "$previous") || return 1
	model=$("${SCRIPT_DIR}/model-availability-helper.sh" resolve "$next" --quiet) || return 1
	# Even if a resolver changes its fallback policy, never accept a model from
	# another tier. Passing both model and tier preserves tier-specific reasoning.
	model_tier_candidate_index "$next" "$model" >/dev/null 2>&1 || return 1
	printf '%s\t%s\n' "$next" "$model"
	return 0
}
