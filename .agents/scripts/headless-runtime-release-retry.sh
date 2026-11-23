#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
#
# GH#37344: durable retry evidence for terminal claim releases that could not be
# published (for example GitHub admission deferred during a quota window).
#
# Record: _release_dispatch_claim writes a private 0600 JSON row when a release
# fails. It holds claim identifiers and minimal structured blocker context;
# the repository path remains local and is never published in a comment.
# Drain: `headless-runtime-release-retry.sh drain` (run by the Pulse normalize
# pass) replays the exact release through the ordinary release path, which
# re-verifies repo authority, the original claim/lease and current ownership
# before any write. A row is removed only after that path reports success
# (including "already released", so replays never duplicate comments).

[[ -n "${_HRRR_LOADED:-}" ]] && return 0
_HRRR_LOADED=1

_HRRR_MAX_AGE_SECS="${AIDEVOPS_CLAIM_RELEASE_RETRY_MAX_AGE:-86400}"
_HRRR_MAX_ATTEMPTS="${AIDEVOPS_CLAIM_RELEASE_RETRY_MAX_ATTEMPTS:-10}"

_hrrr_dir() {
	printf '%s\n' "${AIDEVOPS_CLAIM_RELEASE_RETRY_DIR:-${HOME}/.aidevops/.agent-workspace/claim-release-retry}"
	return 0
}

# Args: $1 repo_slug, $2 issue_number, $3 session_key. Prints the row path.
_hrrr_path() {
	local repo_slug="$1" issue_number="$2" session_key="$3" name=""
	name="${repo_slug//\//_}-${issue_number}-${session_key}"
	name="${name//[^A-Za-z0-9._-]/_}"
	printf '%s/%s.json\n' "$(_hrrr_dir)" "${name:0:200}"
	return 0
}

# Digest immutable claim and observation fields, excluding retry bookkeeping.
# The private sidecar detects row replacement, not a hostile same-user writer.
# spec_dispatch joins the digest only when set, so rows written before GH#38021
# keep their binding.
_hrrr_binding() {
	local path="$1" value=""
	value=$(jq -cer '[.repo, .issue, .session_key, .reason, .exit, .session_count,
		.lease_token, .lease_device, .lease_session, .attempt_id, .blocker]
		+ (if .spec_dispatch == true then ["spec_dispatch"] else [] end)' "$path") || return 1
	_terminal_blocker_hash "$value" || return 1
	return 0
}

# GH#38021: a draft checkpoint on a canonical consolidated spec removes
# auto-dispatch, and only the run that removed it holds the proof. Report that
# proof so the row can carry it to the replay.
# Args: $1 reason, $2 repo_slug, $3 issue_number. Prints true or false.
_hrrr_spec_dispatch_receipt() {
	local reason="$1" repo_slug="$2" issue_number="$3"
	if [[ "$reason" == "${_HRW_REASON_DRAFT_CHECKPOINT:-worker_draft_checkpoint}" ]] &&
		declare -F _pmpc_holds_checkpoint_spec_receipt >/dev/null 2>&1 &&
		_pmpc_holds_checkpoint_spec_receipt "$repo_slug" "$issue_number"; then
		printf 'true\n'
		return 0
	fi
	printf 'false\n'
	return 0
}

# Args: $1 session_key, $2 reason, $3 exit_code, $4 session_count.
# Non-fatal: failing to persist evidence never changes the release result.
_hrrr_record() {
	local session_key="$1" reason="$2" exit_code_arg="${3:-}" session_count_arg="${4:-}"
	local issue_number="${5:-}" repo_slug="${6:-}"
	local token="${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}"
	local device="${AIDEVOPS_DISPATCH_LEASE_DEVICE:-${AIDEVOPS_DEVICE_ID:-}}"
	local lease_session="${AIDEVOPS_DISPATCH_LEASE_SESSION:-$session_key}"
	local blocker_path="${AIDEVOPS_TERMINAL_BLOCKER_REPO_PATH:-}"
	local blocker_fingerprint="${AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT:-}"
	local missing_secrets="${AIDEVOPS_TERMINAL_BLOCKER_MISSING_SECRETS:-}"
	local dir="" path="" tmp="" now="" spec_dispatch=""

	[[ "${_HRRR_REPLAY:-0}" != 1 ]] || return 0
	# Without a bound claim there is nothing a later pass could safely release.
	[[ -n "$token" && -n "$device" && "$issue_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 0
	dir=$(_hrrr_dir)
	path=$(_hrrr_path "$repo_slug" "$issue_number" "$session_key")
	now=$(date +%s)
	# An earlier row for the same claim keeps its attempt count and creation time.
	if [[ -f "$path" ]]; then
		return 0
	fi
	spec_dispatch=$(_hrrr_spec_dispatch_receipt "$reason" "$repo_slug" "$issue_number")
	(
		umask 077
		mkdir -p "$dir" && chmod 700 "$dir" 2>/dev/null || true
		tmp=$(mktemp "${dir}/.row.XXXXXX") || exit 1
		if jq -n --arg repo "$repo_slug" --argjson issue "$issue_number" \
			--arg session_key "$session_key" --arg reason "$reason" \
			--arg exit_code "$exit_code_arg" --arg session_count "$session_count_arg" \
			--arg token "$token" --arg device "$device" --arg lease_session "$lease_session" \
			--arg blocker_path "$blocker_path" --arg fingerprint "$blocker_fingerprint" --arg missing_secrets "$missing_secrets" \
			--arg attempt "${AIDEVOPS_ATTEMPT_ID:-}" --argjson pid "$$" --argjson now "$now" \
			--arg spec_dispatch "$spec_dispatch" \
			'{schema: 1, repo: $repo, issue: $issue, session_key: $session_key, reason: $reason,
			  exit: $exit_code, session_count: $session_count, lease_token: $token,
			  lease_device: $device, lease_session: $lease_session, attempt_id: $attempt,
			  blocker: {path: $blocker_path, fingerprint: $fingerprint, missing_secrets: $missing_secrets},
			  pid: $pid, created: $now, next_after: ($now + 60), attempts: 0}
			 + (if $spec_dispatch == "true" then {spec_dispatch: true} else {} end)' >"$tmp" &&
			_hrrr_binding "$tmp" >"${path}.binding" && chmod 600 "${path}.binding" &&
			mv -f "$tmp" "$path"; then
			exit 0
		fi
		rm -f "$tmp"
		exit 1
	) || {
		print_warning "[lifecycle] claim_release_retry_evidence_unavailable issue=${issue_number}"
		return 0
	}
	print_warning "[lifecycle] claim_release_retry_recorded issue=${issue_number} reason=${reason}; Pulse will reconcile after GitHub admission recovers"
	return 0
}

# Args: $1 session_key, $2 issue_number, $3 repo_slug.
_hrrr_clear() {
	local session_key="$1" issue_number="$2" repo_slug="$3" path=""
	[[ "${_HRRR_REPLAY:-0}" != 1 ]] || return 0
	path=$(_hrrr_path "$repo_slug" "$issue_number" "$session_key")
	[[ ! -f "$path" ]] || rm -f "$path"
	rm -f "${path}.binding"
	return 0
}

# Populate the caller's dynamically scoped blocker fields only from this row.
_hrrr_read_blocker() {
	local path="$1" reason="$2"
	local binding="" expected=""
	[[ -f "${path}.binding" ]] || return 1
	IFS= read -r expected <"${path}.binding" || return 1
	binding=$(_hrrr_binding "$path") || return 1
	[[ "$binding" == "$expected" ]] || return 1
	[[ "$reason" == blocked || "$reason" == push_policy_timeout || "$reason" == network_policy_timeout ]] || return 0
	jq -e '.blocker | type == "object" and ([.path, .fingerprint, .missing_secrets] | all(type == "string"))' "$path" >/dev/null 2>&1 || return 1
	blocker_path=$(jq -r '.blocker.path' "$path") || return 1
	fingerprint=$(jq -r '.blocker.fingerprint' "$path") || return 1
	missing_secrets=$(jq -r '.blocker.missing_secrets' "$path") || return 1
	if [[ -n "$blocker_path" || -n "$fingerprint" ]]; then
		[[ -d "$blocker_path" && "$fingerprint" =~ ^[a-f0-9]{24}$ ]] || return 1
		if [[ "$(_terminal_blocker_reason "$fingerprint")" == unknown ]]; then
			[[ "$fingerprint" == "$(_terminal_blocker_hash 'v2:unknown')" ]] || return 1
		fi
	fi
	return 0
}

# GH#38021: hand the recording run's receipt to this replay. Call only after
# _hrrr_read_blocker verified the row's binding. A row without the field, or a
# module that cannot load, leaves the replay without a receipt: nothing is
# restored, which is the behaviour before GH#38021.
# Args: $1 row path, $2 repo_slug, $3 issue_number. Always returns 0.
_hrrr_adopt_spec_dispatch() {
	local path="$1" repo_slug="$2" issue_number="$3"
	jq -e '.spec_dispatch == true' "$path" >/dev/null 2>&1 || return 0
	# shellcheck source=pulse-merge-partial-continuation.sh
	source "${BASH_SOURCE[0]%/*}/pulse-merge-partial-continuation.sh" 2>/dev/null || return 0
	_pmpc_adopt_checkpoint_spec_receipt "$repo_slug" "$issue_number" || return 0
	return 0
}

# Process one row. Returns 0 when handled/removed, 1 when a replay was attempted
# and failed, 2 when retained before any replay (not due, live worker, invalid).
_hrrr_process_row() {
	local path="$1" now="$2"
	local repo="" issue="" session_key="" reason="" exit_code="" session_count="" token=""
	local device="" lease_session="" pid="" created="" next_after="" attempts="" attempt_id=""
	local fields=""
	local blocker_path="" fingerprint="" missing_secrets=""

	if ! fields=$(jq -er '[.repo, (.issue|tostring), .session_key, .reason, .exit, .session_count,
		.lease_token, .lease_device, .lease_session, (.pid|tostring), (.created|tostring),
		(.next_after|tostring), (.attempts|tostring), (.attempt_id // "")] | join("\u001f")' "$path" 2>/dev/null); then
		return 2
	fi
	IFS=$'\x1f' read -r repo issue session_key reason exit_code session_count token device \
		lease_session pid created next_after attempts attempt_id <<<"$fields"
	if [[ ! "$issue" =~ ^[0-9]+$ || ! "$created" =~ ^[0-9]+$ || ! "$attempts" =~ ^[0-9]+$ ||
		! "$next_after" =~ ^[0-9]+$ ]]; then
		return 2
	fi
	# Legacy blocked rows cannot distinguish a generic exit from a lost
	# classification. Never replay them as dispatchable without that evidence.
	_hrrr_read_blocker "$path" "$reason" || {
		print_warning "[lifecycle] claim_release_retry_unverifiable issue=${issue}; retaining evidence"
		return 2
	}
	# Expired or exhausted evidence yields to the ordinary active-worker TTL.
	if ((now - created > _HRRR_MAX_AGE_SECS || attempts >= _HRRR_MAX_ATTEMPTS)); then
		if [[ -n "$fingerprint" ]]; then
			print_warning "[lifecycle] claim_release_retry_exhausted issue=${issue}; retaining classified evidence"
			return 2
		fi
		print_warning "[lifecycle] claim_release_retry_expired issue=${issue}"
		rm -f "$path"
		rm -f "${path}.binding"
		return 0
	fi
	((now >= next_after)) || return 2
	# Never act while the original worker may still be running.
	if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
		return 2
	fi
	local rc=0
	(
		export _HRRR_REPLAY=1 WORKER_ISSUE_NUMBER="$issue" DISPATCH_REPO_SLUG="$repo"
		export AIDEVOPS_DISPATCH_LEASE_TOKEN="$token" AIDEVOPS_DISPATCH_LEASE_DEVICE="$device"
		export AIDEVOPS_DISPATCH_LEASE_SESSION="$lease_session" AIDEVOPS_ATTEMPT_ID="$attempt_id"
		# Never inherit another worker's blocker context from Pulse.
		export AIDEVOPS_TERMINAL_BLOCKER_REPO_PATH="$blocker_path" AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT="$fingerprint"
		export AIDEVOPS_TERMINAL_BLOCKER_MISSING_SECRETS="$missing_secrets" AIDEVOPS_TERMINAL_BLOCKER_REJECTED_SECRETS=""
		# Bounded and budget-aware: one post attempt, no authority sleeps.
		export AIDEVOPS_RELEASE_AUTHORITY_RETRY_DELAYS="" AIDEVOPS_CLAIM_RELEASE_POST_ATTEMPTS=1
		# Inside this subshell, so one row's receipt never reaches the next row.
		_hrrr_adopt_spec_dispatch "$path" "$repo" "$issue"
		_hrff_release_dispatch_claim_attempt "$session_key" "$reason" "$exit_code" "$session_count"
	) || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_info "[lifecycle] claim_release_retry_resolved issue=${issue}"
		rm -f "$path"
		rm -f "${path}.binding"
		return 0
	fi
	local backoff=$((300 * (1 << (attempts > 3 ? 3 : attempts))))
	local tmp=""
	tmp=$(mktemp "$(_hrrr_dir)/.row.XXXXXX") || return 1
	if jq --argjson next "$((now + backoff))" '.attempts += 1 | .next_after = $next' "$path" >"$tmp" 2>/dev/null; then
		mv -f "$tmp" "$path"
		chmod 600 "$path" 2>/dev/null || true
	else
		rm -f "$tmp"
	fi
	return 1
}

# Bounded drain; prints "candidates=N resolved=N retained=N".
_hrrr_drain() {
	local dir="" path="" now="" batch="${AIDEVOPS_CLAIM_RELEASE_RETRY_BATCH:-3}"
	local candidates=0 resolved=0 retained=0 processed=0
	dir=$(_hrrr_dir)
	[[ -d "$dir" ]] || {
		printf 'candidates=0 resolved=0 retained=0\n'
		return 0
	}
	[[ "$batch" =~ ^[1-9][0-9]*$ ]] || batch=3
	now=$(date +%s)
	for path in "$dir"/*.json; do
		[[ -f "$path" ]] || continue
		candidates=$((candidates + 1))
		if [[ "$processed" -ge "$batch" ]]; then
			retained=$((retained + 1))
			continue
		fi
		local row_rc=0
		_hrrr_process_row "$path" "$now" || row_rc=$?
		if [[ "$row_rc" -eq 0 ]]; then
			resolved=$((resolved + 1))
			processed=$((processed + 1))
		elif [[ "$row_rc" -eq 2 ]]; then
			# Retained before any replay: evidence kept, no batch slot consumed.
			retained=$((retained + 1))
		else
			retained=$((retained + 1))
			processed=$((processed + 1))
		fi
	done
	printf 'candidates=%s resolved=%s retained=%s\n' "$candidates" "$resolved" "$retained"
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	set -euo pipefail
	_hrrr_self_dir="${BASH_SOURCE[0]%/*}"
	# shellcheck source=shared-constants.sh
	source "${_hrrr_self_dir}/shared-constants.sh"
	# shellcheck source=headless-runtime-failure.sh
	source "${_hrrr_self_dir}/headless-runtime-failure.sh"
	case "${1:-}" in
	drain)
		if ! declare -F aidevops_can_manage_repo_issue_state >/dev/null 2>&1; then
			printf 'Cannot drain claim releases: repo-state guard unavailable\n' >&2
			exit 1
		fi
		_hrrr_drain
		;;
	*)
		printf 'Usage: %s drain\n' "${0##*/}" >&2
		exit 2
		;;
	esac
fi
