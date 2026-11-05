#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-nmr-approval-revalidation.sh — NMR reason metadata and durable state.
# Sourced by pulse-nmr-approval.sh after its NMR constants are initialized.
# Depends on the parent's API helpers, breaker retry checks, gh wrappers and jq
# filters; preserves fail-closed evidence handling and bounded state pruning.

[[ -n "${_PULSE_NMR_APPROVAL_REVALIDATION_LOADED:-}" ]] && return 0
_PULSE_NMR_APPROVAL_REVALIDATION_LOADED=1

#######################################
# Classify an NMR episode into a stable reason code. Explicit structured
# markers win; legacy breaker text is mapped without copying prose or paths.
# Stdout: {code,class,source,revalidate_after_seconds,requires_crypto}
#######################################
_nmr_reason_metadata_from_comments() {
	local comments_json="$1"
	local revalidate_seconds="$NMR_TEMPORARY_REVALIDATE_SECONDS"
	local metadata_json=""
	[[ "$revalidate_seconds" =~ ^[0-9]+$ ]] || revalidate_seconds=3600
	metadata_json=$(printf '%s' "$comments_json" | jq -c --argjson revalidate "$revalidate_seconds" \
		-f "$NMR_REASON_FILTER" 2>/dev/null) || return 1
	[[ -n "$metadata_json" ]] || return 1
	printf '%s\n' "$metadata_json"
	return 0
}

_nmr_reason_metadata() {
	local issue_num="$1"
	local slug="$2"
	local comments_json="[]"
	local comments_path=""
	comments_path=$(_nmr_issue_api_path "$issue_num" "$slug" "$NMR_API_COMMENTS_SUFFIX")
	comments_json=$(gh api "$comments_path" --paginate --slurp 2>/dev/null) || return 1
	printf '%s' "$comments_json" | jq -e 'arrays' >/dev/null 2>&1 || return 1
	_nmr_reason_metadata_from_comments "$comments_json"
	return $?
}

_nmr_revalidation_due() {
	local metadata_json="$1"
	local label_at="$2"
	local now_epoch=""
	local label_epoch=""
	local after_seconds=""
	now_epoch=$(date +%s 2>/dev/null || true)
	label_epoch=$(date -u -d "$label_at" '+%s' 2>/dev/null || TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$label_at" '+%s' 2>/dev/null || true)
	after_seconds=$(printf '%s' "$metadata_json" | jq -r '.revalidate_after_seconds // 0' 2>/dev/null) || after_seconds=0
	[[ "$now_epoch" =~ ^[0-9]+$ && "$label_epoch" =~ ^[0-9]+$ && "$after_seconds" =~ ^[0-9]+$ ]] || return 1
	[[ $((now_epoch - label_epoch)) -ge "$after_seconds" ]]
	return $?
}

_nmr_temporary_assumption_resolved() {
	local issue_num="$1"
	local slug="$2"
	local code="$3"
	local label_at="$4"
	# Recovery-loop markers classify as diagnostic ambiguity, while rate-limit
	# and zero-session markers classify as transient infrastructure. Both may use
	# the existing one-retry-per-breaker-release gate; stale/manual diagnostics
	# remain preserved because _nmr_breaker_release_retry_reason rejects them.
	if [[ "$code" == "transient_infrastructure" || "$code" == "diagnostic_ambiguity" ]]; then
		local retry_reason=""
		retry_reason=$(_nmr_breaker_release_retry_reason "$issue_num" "$slug" "$label_at") || retry_reason=""
		if [[ -n "$retry_reason" ]]; then
			printf '%s\n' "$retry_reason"
			return 0
		fi
	fi

	local issue_json="{}"
	local issue_path=""
	issue_path=$(_nmr_issue_api_path "$issue_num" "$slug")
	issue_json=$(gh api "$issue_path" 2>/dev/null) || issue_json="{}"
	if [[ "$code" == "missing_context" ]] && printf '%s' "$issue_json" | jq -e '
		((.body // "") | contains("## Worker Guidance")) and
		((.body // "") | contains("### Verification"))
	' >/dev/null 2>&1; then
		printf 'worker guidance and verification are now present\n'
		return 0
	fi

	local comments_json="[]"
	local comments_path=""
	comments_path=$(_nmr_issue_api_path "$issue_num" "$slug" "$NMR_API_COMMENTS_SUFFIX")
	comments_json=$(gh api "$comments_path" --paginate --slurp 2>/dev/null) || comments_json="[]"
	if printf '%s' "$comments_json" | jq -e -f "$NMR_TRUSTED_RESOLUTION_FILTER" >/dev/null 2>&1; then
		printf 'trusted revalidation evidence resolved the temporary assumption\n'
		return 0
	fi
	return 1
}

_nmr_record_revalidation_state() {
	local issue_num="$1"
	local slug="$2"
	local metadata_json="$3"
	local label_at="$4"
	local status="$5"
	local state_dir="${NMR_REVALIDATION_STATE_FILE%/*}"
	[[ "$state_dir" != "$NMR_REVALIDATION_STATE_FILE" ]] || return 0
	mkdir -p "$state_dir" 2>/dev/null || return 0
	local current="{}"
	if [[ -f "$NMR_REVALIDATION_STATE_FILE" ]]; then
		current=$(cat "$NMR_REVALIDATION_STATE_FILE" 2>/dev/null) || current="{}"
	fi
	printf '%s' "$current" | jq empty >/dev/null 2>&1 || current="{}"
	local key="${slug}#${issue_num}"
	local tmp_file=""
	tmp_file=$(mktemp "${state_dir}/.nmr-revalidation.XXXXXX") || return 0
	printf '%s' "$current" | jq --arg key "$key" --arg label_at "$label_at" --arg status "$status" \
		--argjson metadata "$metadata_json" -f "$NMR_STATE_RECORD_FILTER" \
		>"$tmp_file" 2>/dev/null || {
		rm -f "$tmp_file"
		return 0
	}
	mv "$tmp_file" "$NMR_REVALIDATION_STATE_FILE" 2>/dev/null || rm -f "$tmp_file"
	return 0
}

_nmr_prune_closed_revalidation_state() {
	[[ -f "$NMR_REVALIDATION_STATE_FILE" ]] || return 0
	local limit="$NMR_STATE_PRUNE_LIMIT"
	[[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=25
	local current=""
	current=$(<"$NMR_REVALIDATION_STATE_FILE") || return 0
	printf '%s' "$current" | jq -e '.entries | type == "object"' >/dev/null 2>&1 || return 0
	local cursor=""
	cursor=$(printf '%s' "$current" | jq -r '.prune_cursor // empty' 2>/dev/null) || cursor=""

	local key=""
	local slug=""
	local issue_num=""
	local issue_json=""
	local state=""
	local gate_live=""
	local checked=0
	while IFS= read -r key; do
		[[ "$checked" -lt "$limit" ]] || break
		checked=$((checked + 1))
		cursor="$key"
		[[ "$key" == *#* ]] || continue
		slug="${key%#*}"
		issue_num="${key##*#}"
		[[ -n "$slug" && "$issue_num" =~ ^[0-9]+$ ]] || continue
		issue_json=$(gh api "$(_nmr_issue_api_path "$issue_num" "$slug")" 2>/dev/null) || continue
		state=$(printf '%s' "$issue_json" | jq -r '.state // empty' 2>/dev/null) || continue
		[[ -n "$state" ]] || continue
		if [[ "$state" != "closed" && "$state" != "CLOSED" ]]; then
			# Open issues stay tracked only while a gate label the entry describes
			# still exists; missing/unparseable labels fail closed (keep entry).
			gate_live=$(printf '%s' "$issue_json" | jq -r --argjson gates "$NMR_STATE_LIVE_GATE_LABELS" '
				if (.labels | type) != "array" then "unknown"
				else [.labels[] | (.name? // .)] | any(.[]; . as $l | $gates | index($l)) | tostring end
			' 2>/dev/null) || continue
			[[ "$gate_live" == "false" ]] || continue
		fi
		current=$(printf '%s' "$current" | jq --arg key "$key" 'del(.entries[$key])' 2>/dev/null) || return 0
	done < <(printf '%s' "$current" | jq -r --arg cursor "$cursor" '
		.entries | keys as $keys | (($keys | map(select(. > $cursor))) + ($keys | map(select(. <= $cursor))))[]
	' 2>/dev/null)

	[[ "$checked" -gt 0 ]] || return 0
	current=$(printf '%s' "$current" | jq --arg cursor "$cursor" '.prune_cursor = $cursor' 2>/dev/null) || return 0
	local state_dir="${NMR_REVALIDATION_STATE_FILE%/*}"
	[[ "$state_dir" != "$NMR_REVALIDATION_STATE_FILE" ]] || return 0
	local tmp_file=""
	tmp_file=$(mktemp "${state_dir}/.nmr-prune.XXXXXX") || return 0
	printf '%s\n' "$current" >"$tmp_file" || {
		rm -f "$tmp_file"
		return 0
	}
	mv "$tmp_file" "$NMR_REVALIDATION_STATE_FILE" 2>/dev/null || rm -f "$tmp_file"
	return 0
}

_nmr_emit_decision_packet() {
	local issue_num="$1"
	local slug="$2"
	local reason_code="$3"
	local marker="nmr-decision-packet reason=${reason_code}"
	local prior_count="0"
	local comments_path=""
	local comments_json="[]"
	comments_path=$(_nmr_issue_api_path "$issue_num" "$slug" "$NMR_API_COMMENTS_SUFFIX")
	comments_json=$(gh api "$comments_path" --paginate --slurp 2>/dev/null) || return 0
	prior_count=$(printf '%s' "$comments_json" | jq -r --arg marker "$marker" --arg array_type "array" '
		(if type == $array_type and (.[0]? | type) == $array_type then [.[][]]
		elif type == $array_type then . else [] end)
		| [.[] | select((.body // "") | contains($marker))] | length
	' 2>/dev/null) || return 0
	[[ "$prior_count" =~ ^[0-9]+$ ]] || return 0
	[[ "$prior_count" -eq 0 ]] || return 0
	gh_issue_comment "$issue_num" --repo "$slug" --body "<!-- ${marker} -->
## Maintainer decision required

- Reason: ${reason_code}
- Evidence: explicit durable reason metadata requires a human content, policy, security, billing, or authority decision.
- Options: resolve the decision and remove \`hold-for-review\`, or document the rejected/alternative direction.

Trusted-author normalization will replace NMR with \`hold-for-review\`; elapsed time is never approval." 2>/dev/null || true
	return 0
}

_nmr_latest_event_json() {
	local issue_num="$1"
	local slug="$2"
	local timeline_path=""
	local timeline_json=""
	timeline_path=$(_nmr_issue_api_path "$issue_num" "$slug" "/timeline")
	timeline_json=$(gh api "$timeline_path" --paginate --slurp 2>/dev/null) || return 1
	printf '%s' "$timeline_json" | jq -c -f "$NMR_LATEST_EVENT_FILTER" 2>/dev/null
	return $?
}
