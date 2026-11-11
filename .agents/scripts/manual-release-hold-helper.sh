#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Advisory merge hold and roll-out owner record for MANUAL releases
# (maintained non-aidevops repos released by a version-bump PR and a tag).
# The aidevops repo's own lane (release-lane-helper.sh) is unaffected.
#
# Storage: a remote branch holding one JSON file, so every session and pulse
# worker sees the same record:
#   aidevops/manual-release-hold          {repository, pr, version, owner_session, created_at, expires_at}
#   aidevops/manual-release-owner/<tag>   {repository, tag, session, recorded_at}
#
# Advisory: expired holds are ignored and API failures fail open with a warning.
# Forced updates are not mutually exclusive: concurrent renewals or replacements
# of expired holds may overwrite each other. Only initial ref creation is atomic.

_MRH_UPDATE="update"
_MRH_FILE="manual-release.json"
_MRH_HOLD_REF="aidevops/manual-release-hold"
_MRH_OWNER_PREFIX="aidevops/manual-release-owner"
_MRH_DEFAULT_TTL_MINUTES=60

# Overridable in tests.
_mrh_api() {
	gh api "$@"
	return $?
}

_mrh_now() {
	date -u +%s
	return 0
}

_mrh_iso() {
	local epoch="$1"
	date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ
	return $?
}

_mrh_session_id() {
	local id="${AIDEVOPS_OPENCODE_SESSION_ID:-${OPENCODE_SESSION_ID:-}}"
	[[ "$id" =~ ^[A-Za-z0-9_.-]{1,128}$ ]] || id=""
	printf '%s\n' "$id"
	return 0
}

_mrh_valid_repo() {
	local repo="$1"
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
	return $?
}

_mrh_valid_version() {
	local version="$1"
	[[ "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*)?(\+[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*)?$ ]]
	return $?
}

_mrh_tag_ref_part() {
	local tag="$1"
	[[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || return 1
	printf '%s\n' "$tag"
	return 0
}

# Prints the JSON record. Return: 0 found, 3 absent, 1 error (caller fails open).
_mrh_read() {
	local repo="$1"
	local ref="$2"
	local out="" err_file="" rc=0 content=""
	err_file=$(mktemp) || return 1
	out=$(_mrh_api "repos/${repo}/contents/${_MRH_FILE}?ref=refs/heads/${ref}" --jq '.content // empty' 2>"$err_file") || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		if grep -q -e "404" -e "Not Found" "$err_file"; then
			rm -f "$err_file"
			return 3
		fi
		rm -f "$err_file"
		return 1
	fi
	rm -f "$err_file"
	[[ -n "$out" ]] || return 3
	content=$(printf '%s' "$out" | base64 -d 2>/dev/null) || return 1
	printf '%s\n' "$content"
	return 0
}

_mrh_write() {
	local repo="$1"
	local ref="$2"
	local json="$3"
	local mode="$4" # create|update
	local payload="" blob="" tree="" commit=""
	payload=$(jq -cn --arg c "$json" '{content:$c,encoding:"utf-8"}') || return 1
	blob=$(_mrh_api "repos/${repo}/git/blobs" --method POST --input - --jq '.sha' <<<"$payload") || return 1
	payload=$(jq -cn --arg p "$_MRH_FILE" --arg s "$blob" '{tree:[{path:$p,mode:"100644",type:"blob",sha:$s}]}') || return 1
	tree=$(_mrh_api "repos/${repo}/git/trees" --method POST --input - --jq '.sha' <<<"$payload") || return 1
	payload=$(jq -cn --arg t "$tree" '{message:"chore(release): manual release record",tree:$t,parents:[]}') || return 1
	commit=$(_mrh_api "repos/${repo}/git/commits" --method POST --input - --jq '.sha' <<<"$payload") || return 1
	if [[ "$mode" == "create" ]]; then
		payload=$(jq -cn --arg r "refs/heads/${ref}" --arg s "$commit" '{ref:$r,sha:$s}') || return 1
		_mrh_api "repos/${repo}/git/refs" --method POST --input - >/dev/null <<<"$payload" || return 2
	else
		# GitHub has no conditional PATCH here; this is an advisory last-writer-wins update.
		payload=$(jq -cn --arg s "$commit" '{sha:$s,force:true}') || return 1
		_mrh_api "repos/${repo}/git/refs/heads/${ref}" --method PATCH --input - >/dev/null <<<"$payload" || return 1
	fi
	return 0
}

_mrh_delete() {
	local repo="$1"
	local ref="$2"
	_mrh_api "repos/${repo}/git/refs/heads/${ref}" --method DELETE >/dev/null 2>&1
	return $?
}

# Reads the hold; prints it only when active. Return 0 active, 3 none/expired, 1 error.
_mrh_active_hold() {
	local repo="$1"
	local json="" rc=0 expires=""
	json=$(_mrh_read "$repo" "$_MRH_HOLD_REF") || rc=$?
	[[ "$rc" -eq 0 ]] || return "$rc"
	expires=$(jq -r '.expires_at_epoch // 0' <<<"$json" 2>/dev/null) || return 1
	[[ "$expires" =~ ^[0-9]+$ ]] || return 1
	if [[ "$expires" -le "$(_mrh_now)" ]]; then
		return 3
	fi
	printf '%s\n' "$json"
	return 0
}

# Merge guard. Return 0 to proceed, 1 when another PR's hold is active.
manual_release_hold_check() {
	local repo="${1:-}"
	local pr="${2:-}"
	local json="" rc=0 hold_pr="" owner="" expires="" version=""
	_mrh_valid_repo "$repo" && [[ "$pr" =~ ^[0-9]+$ ]] || return 0
	json=$(_mrh_active_hold "$repo") || rc=$?
	case "$rc" in
	0) ;;
	3) return 0 ;;
	*)
		printf 'WARNING: manual release hold unreadable for %s; failing open\n' "$repo" >&2
		return 0
		;;
	esac
	hold_pr=$(jq -r '.pr // empty' <<<"$json")
	[[ "$hold_pr" != "$pr" ]] || return 0
	owner=$(jq -r '.owner_session // "unknown"' <<<"$json")
	expires=$(jq -r '.expires_at // "unknown"' <<<"$json")
	version=$(jq -r '.version // ""' <<<"$json")
	printf 'MANUAL_RELEASE_HOLD repo=%s release_pr=%s version=%s owner_session=%s expires_at=%s\n' \
		"$repo" "$hold_pr" "${version:-unknown}" "$owner" "$expires" >&2
	printf 'Merge of PR #%s deferred: release PR #%s is in flight. Retry after the hold is released or expires.\n' "$pr" "$hold_pr" >&2
	return 1
}

# Open release PRs for a version other than the given one. Prints "<number>" lines.
_mrh_duplicate_prs() {
	local repo="$1"
	local version="$2"
	local except_pr="${3:-0}"
	if ! _mrh_api -X GET "search/issues" -f "q=repo:${repo} is:pr is:open in:title release ${version}" \
		--jq ".items[].number | select(. != ${except_pr})" 2>/dev/null; then
		printf 'WARNING: duplicate release PR search failed for %s; failing open\n' "$repo" >&2
	fi
	return 0
}

cmd_hold() {
	local repo="${1:-}"
	shift || true
	local pr="" version="" ttl="$_MRH_DEFAULT_TTL_MINUTES"
	while [[ $# -gt 0 ]]; do
		case "${1:-}" in
		--pr)
			pr="${2:-}"
			shift 2
			;;
		--version)
			version="${2:-}"
			shift 2
			;;
		--ttl-minutes)
			ttl="${2:-}"
			shift 2
			;;
		*) return 1 ;;
		esac
	done
	_mrh_valid_repo "$repo" && [[ "$pr" =~ ^[0-9]+$ && "$ttl" =~ ^[0-9]+$ ]] || {
		printf 'Usage: aidevops release hold OWNER/REPO --pr N [--version vX.Y.Z] [--ttl-minutes M]\n' >&2
		return 1
	}
	[[ "$ttl" -ge 1 && "$ttl" -le 720 ]] || return 1
	if [[ -n "$version" ]] && ! _mrh_valid_version "$version"; then
		printf 'Invalid release version: expected [v]X.Y.Z with optional prerelease/build suffixes\n' >&2
		return 1
	fi
	local existing="" rc=0 existing_pr="" dups="" now="" expires="" json="" mode="create"
	existing=$(_mrh_active_hold "$repo") || rc=$?
	case "$rc" in
	0)
		existing_pr=$(jq -r '.pr // empty' <<<"$existing")
		if [[ "$existing_pr" != "$pr" ]]; then
			printf 'Refused: hold for release PR #%s is already active (owner_session=%s)\n' \
				"$existing_pr" "$(jq -r '.owner_session // "unknown"' <<<"$existing")" >&2
			return 1
		fi
		mode="$_MRH_UPDATE"
		;;
	3) _mrh_read "$repo" "$_MRH_HOLD_REF" >/dev/null 2>&1 && mode="$_MRH_UPDATE" || true ;;
	*)
		printf 'WARNING: cannot read manual release hold for %s; not holding\n' "$repo" >&2
		return 1
		;;
	esac
	if [[ -n "$version" ]]; then
		dups=$(_mrh_duplicate_prs "$repo" "$version" "$pr") || dups=""
		if [[ -n "$dups" ]]; then
			printf 'Refused: release %s already has open PR(s): %s\n' "$version" "$(tr '\n' ' ' <<<"$dups")" >&2
			return 1
		fi
	fi
	now=$(_mrh_now)
	expires=$((now + ttl * 60))
	json=$(jq -cn --arg repo "$repo" --argjson pr "$pr" --arg version "$version" --arg owner "$(_mrh_session_id)" \
		--arg created "$(_mrh_iso "$now")" --arg exp "$(_mrh_iso "$expires")" --argjson expe "$expires" \
		'{repository:$repo,pr:$pr,version:$version,owner_session:$owner,created_at:$created,expires_at:$exp,expires_at_epoch:$expe}') || return 1
	rc=0
	_mrh_write "$repo" "$_MRH_HOLD_REF" "$json" "$mode" || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		printf 'Refused: could not record hold\n' >&2
		return 1
	fi
	if [[ "$mode" == "$_MRH_UPDATE" ]]; then
		printf 'WARNING: hold update is advisory; concurrent updates may overwrite it\n' >&2
	fi
	printf 'MANUAL_RELEASE_HOLD_SET repo=%s release_pr=%s expires_at=%s\n' "$repo" "$pr" "$(_mrh_iso "$expires")"
	return 0
}

cmd_unhold() {
	local repo="${1:-}"
	_mrh_valid_repo "$repo" || return 1
	local rc=0
	_mrh_read "$repo" "$_MRH_HOLD_REF" >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -eq 3 ]]; then
		printf 'No manual release hold for %s\n' "$repo"
		return 0
	fi
	_mrh_delete "$repo" "$_MRH_HOLD_REF" || {
		printf 'Could not delete hold ref for %s\n' "$repo" >&2
		return 1
	}
	printf 'MANUAL_RELEASE_HOLD_RELEASED repo=%s\n' "$repo"
	return 0
}

cmd_status() {
	local repo="${1:-}"
	_mrh_valid_repo "$repo" || return 1
	local json="" rc=0
	json=$(_mrh_active_hold "$repo") || rc=$?
	case "$rc" in
	0) printf '%s\n' "$json" ;;
	3) printf 'No active manual release hold for %s\n' "$repo" ;;
	*)
		printf 'Hold unreadable for %s\n' "$repo" >&2
		return 1
		;;
	esac
	return 0
}

cmd_owner() {
	local repo="${1:-}"
	local tag="${2:-}"
	shift 2 || true
	local session=""
	while [[ $# -gt 0 ]]; do
		case "${1:-}" in
		--session)
			session="${2:-}"
			shift 2
			;;
		*) return 1 ;;
		esac
	done
	local part=""
	part=$(_mrh_tag_ref_part "$tag") || return 1
	_mrh_valid_repo "$repo" && [[ "$session" =~ ^[A-Za-z0-9_.-]{1,128}$ ]] || {
		printf 'Usage: aidevops release owner OWNER/REPO TAG --session ID\n' >&2
		return 1
	}
	local ref="${_MRH_OWNER_PREFIX}/${part}" mode="create" rc=0 json=""
	_mrh_read "$repo" "$ref" >/dev/null 2>&1 && mode="$_MRH_UPDATE" || true
	json=$(jq -cn --arg repo "$repo" --arg tag "$tag" --arg s "$session" --arg at "$(_mrh_iso "$(_mrh_now)")" \
		'{repository:$repo,tag:$tag,session:$s,recorded_at:$at}') || return 1
	_mrh_write "$repo" "$ref" "$json" "$mode" || rc=$?
	[[ "$rc" -eq 0 ]] || return 1
	printf 'MANUAL_RELEASE_OWNER repo=%s tag=%s session=%s\n' "$repo" "$tag" "$session"
	return 0
}

# Best-effort bus notice to the recorded roll-out owner. Never fails the caller.
cmd_owner_notify() {
	local repo="${1:-}"
	local tag="${2:-}"
	shift 2 || true
	local result="release run and update test finished"
	[[ "${1:-}" != "--result" ]] || result="${2:-$result}"
	local part="" json="" session="" text=""
	part=$(_mrh_tag_ref_part "$tag") || return 1
	_mrh_valid_repo "$repo" || return 1
	json=$(_mrh_read "$repo" "${_MRH_OWNER_PREFIX}/${part}") || {
		printf 'No roll-out owner recorded for %s %s\n' "$repo" "$tag"
		return 0
	}
	session=$(jq -r '.session // empty' <<<"$json")
	[[ "$session" =~ ^[A-Za-z0-9_.-]{1,128}$ ]] || return 0
	text="Release ${tag} of ${repo}: ${result}. You own the roll-out."
	if ! declare -F timeout_sec >/dev/null 2>&1; then
		# shellcheck source=shared-constants.sh
		source "$(dirname "${BASH_SOURCE[0]}")/shared-constants.sh" 2>/dev/null || true
	fi
	if command -v aidevops >/dev/null 2>&1 && declare -F timeout_sec >/dev/null 2>&1 &&
		timeout_sec 5 aidevops sessions send "$session" "$text" >/dev/null 2>&1; then
		printf 'MANUAL_RELEASE_OWNER_NOTIFIED repo=%s tag=%s session=%s\n' "$repo" "$tag" "$session"
	else
		printf 'MANUAL_RELEASE_OWNER_NOT_CONFIRMED repo=%s tag=%s session=%s\n' "$repo" "$tag" "$session" >&2
	fi
	return 0
}

cmd_duplicate_check() {
	local repo="${1:-}"
	local version="${2:-}"
	_mrh_valid_repo "$repo" && _mrh_valid_version "$version" || return 1
	local dups=""
	dups=$(_mrh_duplicate_prs "$repo" "$version" 0) || dups=""
	if [[ -n "$dups" ]]; then
		printf 'Duplicate: release %s already has open PR(s): %s\n' "$version" "$(tr '\n' ' ' <<<"$dups")" >&2
		return 1
	fi
	return 0
}

main() {
	local cmd="${1:-}"
	shift || true
	case "$cmd" in
	hold) cmd_hold "$@" ;;
	unhold | release) cmd_unhold "$@" ;;
	status | hold-status) cmd_status "$@" ;;
	check) manual_release_hold_check "$@" ;;
	owner) cmd_owner "$@" ;;
	owner-notify) cmd_owner_notify "$@" ;;
	duplicate-check) cmd_duplicate_check "$@" ;;
	*)
		printf 'Usage: manual-release-hold-helper.sh hold|unhold|status|check|owner|owner-notify|duplicate-check ...\n' >&2
		return 1
		;;
	esac
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	set -euo pipefail
	main "$@"
fi
