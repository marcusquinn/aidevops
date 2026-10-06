#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced scheduling gate. Never use this gate for PR/CI/checkpoint recovery.
[[ -n "${_PULSE_REPO_DORMANCY_LOADED:-}" ]] && return 0
_PULSE_REPO_DORMANCY_LOADED=1

_pulse_dormancy_prefix() {
	local slug="$1"
	[[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
	local dir="${PULSE_DORMANCY_DIR:-${HOME}/.aidevops/cache/pulse-dormancy}"
	mkdir -p "$dir" || return 1
	printf '%s/%s' "$dir" "${slug//\//--}"
	return 0
}

_pulse_dormancy_record() {
	local slug="$1" reason="$2"
	printf '[pulse-wrapper] dormancy repo=%s reason=%s\n' "$slug" "$reason" >>"${LOGFILE:-/dev/null}" 2>/dev/null || true
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "repo_dormancy_${reason}" 2>/dev/null || true
	fi
	return 0
}

# Independent atomic marker: never delete it, so a concurrent wake cannot be lost.
pulse_repo_wake() {
	local slug="$1" reason="${2:-interactive}" prefix="" tmp=""
	prefix=$(_pulse_dormancy_prefix "$slug") || return 1
	tmp=$(mktemp "${prefix}.wake.XXXXXX") || return 1
	printf '%s:%s:%s\n' "$reason" "$(date +%s)" "${tmp##*.}" >"$tmp" &&
		mv "$tmp" "${prefix}.wake" || { rm -f "$tmp"; return 1; }
	return 0
}

# Wake generations are acknowledged by successful full candidate scans, not
# consumed by a prefetch. A racing newer marker remains pending.
pulse_repo_wake_pending() {
	local slug="$1" prefix="" wake="" ack=""
	[[ "${PULSE_REPO_DORMANCY_ENABLED:-1}" == 1 ]] || return 1
	prefix=$(_pulse_dormancy_prefix "$slug") || return 1
	[[ -f "${prefix}.wake" ]] || return 1
	wake=$(<"${prefix}.wake")
	[[ ! -f "${prefix}.ack" ]] || ack=$(<"${prefix}.ack")
	[[ "$wake" != "$ack" ]] || return 1
	return 0
}

_pulse_dormancy_read() {
	local endpoint="$1" etag="${2:-}" response="" rc=0
	local args=(api --include "$endpoint")
	[[ -z "$etag" ]] || args+=(-H "If-None-Match: $etag")
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		response=$(_gh_with_timeout read gh "${args[@]}" 2>&1) || rc=$?
	else
		response=$(gh "${args[@]}" 2>&1) || rc=$?
	fi
	# gh 2.102 emits 304 on stderr with no stdout/headers and exit 1.
	local first_line="${response%%$'\n'*}"
	first_line="${first_line%$'\r'}"
	if [[ "$first_line" =~ ^HTTP/[0-9.]+[[:space:]]304([[:space:]]|$) ]] ||
		{ [[ "$rc" -ne 0 ]] && [[ "$first_line" =~ ^gh:[[:space:]]HTTP[[:space:]]304([[:space:]]|$) ]]; }; then
		[[ -n "$etag" ]] || return 1
		printf '%s' "$etag"
		return 0
	fi
	[[ "$rc" -eq 0 && "$first_line" =~ ^HTTP/[0-9.]+[[:space:]]200([[:space:]]|$) ]] || return 1
	local line=""
	while IFS= read -r line; do
		line="${line%$'\r'}"
		[[ -n "$line" ]] || return 1
		case "$line" in
		[Ee][Tt][Aa][Gg]:*) printf '%s' "${line#*: }"; return 0 ;;
		esac
	done <<<"$response"
	return 1
}

# Capture validators BEFORE the full scan, not after: changes racing the scan
# must wake on the next cycle. Absence of validators disables sleep safely.
pulse_repo_dormancy_prepare() {
	local slug="$1" prefix=""
	PULSE_DORMANCY_ISSUES_ETAG="" PULSE_DORMANCY_COMMITS_ETAG="" PULSE_DORMANCY_WAKE=""
	[[ "${PULSE_REPO_DORMANCY_ENABLED:-1}" == 1 ]] || return 0
	prefix=$(_pulse_dormancy_prefix "$slug") || return 0
	[[ ! -f "${prefix}.wake" ]] || PULSE_DORMANCY_WAKE=$(<"${prefix}.wake")
	PULSE_DORMANCY_ISSUES_ETAG=$(_pulse_dormancy_read "repos/${slug}/issues?state=all&sort=updated&direction=desc&per_page=1") || return 0
	PULSE_DORMANCY_COMMITS_ETAG=$(_pulse_dormancy_read "repos/${slug}/commits?per_page=1") || return 0
	return 0
}

# Same append-only local authority as dispatch-ledger-helper.sh. Any retained
# active/recovery/finalization entry (even expired) keeps scheduling awake until
# the lifecycle reconciler records its terminal outcome. Malformed data is unknown.
_pulse_dormancy_local_quiet() {
	local slug="$1"
	local ledger="${AIDEVOPS_DISPATCH_LEDGER_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/dispatch-ledger.jsonl"
	[[ -e "$ledger" ]] || return 0
	jq -se --arg slug "$slug" '
		if all(.[]; (.session_key | type) == "string" and (.repo_slug | type) == "string")
		then group_by(.session_key) | map(last) else error("unknown ledger record") end |
		all(.[]; .repo_slug != $slug or
			((.status == "completed" or .status == "failed") and
			 .attempt_finalization_status != "awaiting-finalization"))
	' "$ledger" >/dev/null 2>&1 || return 1
	return 0
}

# Return 1 only for proven dormant repositories. Unknown/error always scans.
pulse_repo_scan_allowed() {
	local slug="$1" prefix="" state="" wake="" old_wake="" entered=0 now=0 reason="" issues="" commits=""
	[[ "${PULSE_REPO_DORMANCY_ENABLED:-1}" == 1 ]] || return 0
	prefix=$(_pulse_dormancy_prefix "$slug") || return 0
	# A wake also bypasses hot/warm/cold cadence until a successful full scan.
	[[ ! -f "${prefix}.wake" ]] || wake=$(<"${prefix}.wake")
	[[ -f "${prefix}.json" ]] || return 0
	state=$(<"${prefix}.json")
	old_wake=$(jq -er '.wake' <<<"$state" 2>/dev/null) || old_wake=""
	entered=$(jq -er '.entered | select(type == "number" and . > 0)' <<<"$state" 2>/dev/null) || return 0
	now=$(date +%s)
	local backstop="${PULSE_DORMANCY_BACKSTOP_SECONDS:-21600}"
	[[ "$backstop" =~ ^[1-9][0-9]*$ ]] || backstop=21600
	if ! _pulse_dormancy_local_quiet "$slug"; then
		reason="woken_local_activity"
	elif [[ "$wake" != "$old_wake" ]]; then
		reason="woken_marker"
	elif ((now < entered || now - entered >= backstop)); then
		reason="backstop"
	else
		issues=$(jq -er '.issues_etag | select(length > 0)' <<<"$state" 2>/dev/null) || return 0
		commits=$(jq -er '.commits_etag | select(length > 0)' <<<"$state" 2>/dev/null) || return 0
		local current_issues="" current_commits=""
		current_issues=$(_pulse_dormancy_read "repos/${slug}/issues?state=all&sort=updated&direction=desc&per_page=1" "$issues") || reason="woken_error"
		current_commits=$(_pulse_dormancy_read "repos/${slug}/commits?per_page=1" "$commits") || reason="woken_error"
		if [[ -z "$reason" && "$current_issues" == "$issues" && "$current_commits" == "$commits" ]]; then
			_pulse_dormancy_record "$slug" skipped
			return 1
		fi
		[[ -n "$reason" ]] || reason="woken_remote"
	fi
	rm -f "${prefix}.json"
	# Persist a wake even on a backstop/error, bypassing tier and owner tickle.
	pulse_repo_wake "$slug" "$reason" || true
	_pulse_dormancy_record "$slug" "$reason"
	return 0
}

pulse_repo_dormancy_observe_candidates() {
	local slug="$1" issues="$2" candidates="$3" succeeded="$4" limit="$5" complete=0
	if [[ "$succeeded" == 1 ]] && jq -e --argjson limit "$limit" 'length < $limit' <<<"$issues" >/dev/null 2>&1; then
		complete=1
	fi
	pulse_repo_dormancy_observe "$slug" "$issues" "$candidates" "$complete"
	return 0
}

pulse_repo_dormancy_observe() {
	local slug="$1" issues="$2" candidates="$3" complete="$4" prefix="" prs="" tmp=""
	[[ "${PULSE_REPO_DORMANCY_ENABLED:-1}" == 1 && "$complete" == 1 ]] || return 0
	prefix=$(_pulse_dormancy_prefix "$slug") || return 0
	tmp=$(mktemp "${prefix}.ack.XXXXXX") || return 0
	printf '%s\n' "${PULSE_DORMANCY_WAKE:-}" >"$tmp" && mv "$tmp" "${prefix}.ack" || { rm -f "$tmp"; return 0; }
	[[ "$candidates" == '[]' ]] || return 0
	[[ -n "${PULSE_DORMANCY_ISSUES_ETAG:-}" && -n "${PULSE_DORMANCY_COMMITS_ETAG:-}" ]] || return 0
	_pulse_dormancy_local_quiet "$slug" || return 0
	# Conservative protection for active claims/workers and held recovery work.
	jq -e 'all(.[]; (.assignees | length) == 0 and
		([.labels[]? | (.name? // .)] | all(. != "status:claimed" and . != "status:in-progress" and . != "status:in-review" and (startswith("worker-") | not))))' <<<"$issues" >/dev/null 2>&1 || return 0
	# Any open PR (not just worker PRs) keeps this repository awake.
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		prs=$(_gh_with_timeout read gh api "repos/${slug}/pulls?state=open&per_page=1" 2>/dev/null) || return 0
	else
		prs=$(gh api "repos/${slug}/pulls?state=open&per_page=1" 2>/dev/null) || return 0
	fi
	jq -e 'type == "array" and length == 0' <<<"$prs" >/dev/null 2>&1 || return 0
	prefix=$(_pulse_dormancy_prefix "$slug") || return 0
	tmp=$(mktemp "${prefix}.state.XXXXXX") || return 0
	if jq -n --argjson entered "$(date +%s)" --arg wake "${PULSE_DORMANCY_WAKE:-}" \
		--arg issues "$PULSE_DORMANCY_ISSUES_ETAG" --arg commits "$PULSE_DORMANCY_COMMITS_ETAG" \
		'{entered:$entered,reason:"no_candidates_or_prs_or_claims",wake:$wake,issues_etag:$issues,commits_etag:$commits}' >"$tmp"; then
		mv "$tmp" "${prefix}.json"
		_pulse_dormancy_record "$slug" entered
	else
		rm -f "$tmp"
	fi
	return 0
}
