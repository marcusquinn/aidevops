#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

# Shared containment for cross-runner protected-label oscillation (GH#35793).
# Configuration: comma-separated PROTECTED_LABEL_FLAP_LABELS; positive integer
# PROTECTED_LABEL_FLAP_THRESHOLD (transitions, default 4), WINDOW_SECONDS (21600)
# and COOLDOWN_SECONDS (21600), with the same PROTECTED_LABEL_FLAP_ prefix.
# GitHub timeline and marker comments, not runner-local counters, own cooldown.

_PL_ADD_LABEL_FLAG="--add-label"
_PL_ARRAY_TYPE="array"

_protected_label_raw_edit() {
	local number="$1" repo="$2"
	shift 2
	if declare -F gh_issue_edit_safe >/dev/null 2>&1; then
		gh_issue_edit_safe "$number" --repo "$repo" "$@" || return 1
	else
		gh issue edit "$number" --repo "$repo" "$@" || return 1
	fi
	return 0
}

# Output one JSON summary, validating every page before flattening. Count actual
# alternating transitions rather than repeated copies of the same event type.
_protected_label_flap_summary() {
	local timeline="$1" label="$2" window="$3" since="$4"
	printf '%s' "$timeline" | jq -ce --arg label "$label" \
		--arg array_type "$_PL_ARRAY_TYPE" --argjson window "$window" --argjson since "$since" '
		if type != $array_type or any(.[]; type != $array_type) then error("invalid timeline")
		else add // [] end
		| [.[] | select(.label.name? == $label and
			(.event == "labeled" or .event == "unlabeled"))
			| . + {epoch: (.created_at | fromdateiso8601)}
			| select(.epoch >= (now - $window) and .epoch > $since)]
		| sort_by(.epoch, .id)
		| reduce .[] as $e ({count:0, last:"", actors:[], latest:0};
			if .last != $e.event then .count += 1 else . end
			| .last = $e.event | .latest = $e.epoch
			| .actors += [$e.actor.login // "unknown"])
		| .actors |= unique'
	return $?
}

# Return 1 for a held label, including when containment/diagnostics cannot be
# verified. Never turn missing history into permission to remove a trust gate.
_protected_label_check() {
	local number="$1" repo="$2" label="$3" operation="$4" decision="$5"
	local threshold="${PROTECTED_LABEL_FLAP_THRESHOLD:-4}"
	local window="${PROTECTED_LABEL_FLAP_WINDOW_SECONDS:-21600}"
	local cooldown="${PROTECTED_LABEL_FLAP_COOLDOWN_SECONDS:-21600}"
	local value="" timeline="" comments="" marker="" since=0 active=0 summary=""
	for value in "$threshold" "$window" "$cooldown"; do
		[[ "$value" =~ ^[1-9][0-9]{0,7}$ ]] || return 1
	done
	marker="<!-- aidevops:protected-label-flap:${label}:v1 -->"
	# A failed read may not prevent an add: adding is always containment, never
	# authority to dispatch. Removals require complete live evidence.
	timeline=$(gh api --paginate --slurp "repos/${repo}/issues/${number}/timeline?per_page=100" 2>/dev/null) || {
		[[ "$operation" == "$_PL_ADD_LABEL_FLAG" ]] && return 0
		return 1
	}
	summary=$(_protected_label_flap_summary "$timeline" "$label" "$window" 0) || {
		[[ "$operation" == "$_PL_ADD_LABEL_FLAG" ]] && return 0
		return 1
	}
	comments=$(gh api --paginate --slurp "repos/${repo}/issues/${number}/comments?per_page=100" 2>/dev/null) || {
		[[ "$operation" == "$_PL_ADD_LABEL_FLAG" ]] && return 0
		return 1
	}
	# Untrusted comments cannot authorize removals or shorten a cooldown. Ignore
	# their markers, including forged expiry/incident metadata.
	since=$(printf '%s' "$comments" | jq -er --arg marker "$marker" --arg array_type "$_PL_ARRAY_TYPE" '
		if type != $array_type or any(.[]; type != $array_type) then error("invalid comments")
		else add // [] end
		| [.[] | select(.author_association == "OWNER" or .author_association == "MEMBER" or
			(.user.type == "Bot" and .performed_via_github_app.permissions.issues == "write"))
			| select((.body // "") | startswith($marker))
			| .created_at | fromdateiso8601] | max // 0') || return 1
	active=$(jq -nr --argjson since "$since" --argjson cooldown "$cooldown" \
		'if $since > 0 and now < ($since + $cooldown) then 1 else 0 end') || return 1
	if [[ "$active" -eq 0 && "$since" -gt 0 ]]; then
		# An expired incident must not retrigger forever on its old events.
		summary=$(_protected_label_flap_summary "$timeline" "$label" "$window" "$since") || return 1
	fi
	if [[ "$active" -eq 0 ]] && [[ "$(printf '%s' "$summary" | jq -r '.count')" -lt "$threshold" ]]; then
		return 0
	fi
	local live=""
	live=$(gh api "repos/${repo}/issues/${number}" 2>/dev/null) || return 1
	if ! printf '%s' "$live" | jq -e --arg label "$label" --arg array_type "$_PL_ARRAY_TYPE" \
		'.labels | if type != $array_type then error("invalid labels") else any(.[]; .name == $label) end' >/dev/null; then
		# Restore once if the final observed transition was a removal. Never clear
		# unrelated labels or promote lifecycle state while held.
		_protected_label_raw_edit "$number" "$repo" "$_PL_ADD_LABEL_FLAG" "$label" || return 1
	fi
	if [[ "$active" -eq 0 ]]; then
		_protected_label_report "$number" "$repo" "$label" "$marker" "$summary" "$decision" "$cooldown" || return 1
	fi
	return 1
}

_protected_label_report() {
	local number="$1" repo="$2" label="$3" marker="$4" summary="$5" decision="$6" cooldown="$7"
	local body="" dir="" version="unknown" actors=""
	dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
	if [[ -r "${dir}/../../VERSION" ]]; then
		IFS= read -r version <"${dir}/../../VERSION" || true
	fi
	actors=$(printf '%s' "$summary" | jq -r '.actors | join(", ")') || return 1
	body="${marker}
Protected label \`${label}\` is held applied for ${cooldown}s after repeated timeline transitions.
Timeline actors: ${actors}.
Detecting runner: ${AIDEVOPS_RUNNER_ID:-${HOSTNAME:-unknown}}; aidevops ${version}; decision: ${decision}.
GitHub timeline events do not expose historical runner versions or trust decisions; these are unavailable, not inferred from actor identity.
Investigate token authority, permission caches and version skew before retrying."
	printf '%s\n' "$body" | "${dir}/gh-write-helper.sh" issue comment "$number" --repo "$repo" --body-file - || return 1
	"${dir}/gh-audit-log-helper.sh" record --op issue.edit --repo "$repo" --number "$number" \
		--caller-script protected-label-guard.sh --caller-function _protected_label_report \
		--flags-json "$(jq -cn --arg label "$label" '{protected_label_flap:$label}')" >/dev/null || return 1
	return 0
}

# Args: number, repository, diagnostic trust decision, followed by edit flags.
# A held edit returns failure so callers cannot report successful normalization.
protected_label_edit() {
	local number="$1" repo="$2" decision="$3"
	shift 3
	local operation="" label="" previous=""
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$number" =~ ^[1-9][0-9]*$ ]] || return 1
	for label in "$@"; do
		operation="$previous"
		previous="$label"
		[[ "$operation" == "$_PL_ADD_LABEL_FLAG" || "$operation" == "--remove-label" ]] || continue
		case ",${PROTECTED_LABEL_FLAP_LABELS:-needs-maintainer-review}," in
		*,"$label",*) _protected_label_check "$number" "$repo" "$label" "$operation" "$decision" || return 1 ;;
		esac
	done
	_protected_label_raw_edit "$number" "$repo" "$@" || return 1
	return 0
}
