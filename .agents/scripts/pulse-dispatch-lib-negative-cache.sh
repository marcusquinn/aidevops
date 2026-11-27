#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Extracted from pulse-dispatch-lib.sh; source the orchestrator, not this file.

[[ -n "${_PULSE_DISPATCH_NEGATIVE_CACHE_LIB_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_NEGATIVE_CACHE_LIB_LOADED=1
# Persist only verified ownership blocks, not uncertain lookups or mutable policy
# gates. Each record is an atomic per-issue hint; a failed read/write falls through
# to the full authoritative dispatch ceremony.
_dispatch_negative_cache_path() {
	local issue="$1" repo="$2"
	[[ "$issue" =~ ^[0-9]+$ && "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
	printf '%s/.aidevops/logs/dispatch-negative-cache/%s--%s--%s\n' "$HOME" "${repo%%/*}" "${repo##*/}" "$issue"
	return 0
}

_DISPATCH_LIVE_OWNER_HOLD_REASON="worktree_live_owner_refused"

# GH#33026: a live-owner hold is valid only while the exact refusing process
# generation is alive and still owns the recorded worktree. Owner exit, PID
# reuse or ownership handover invalidates it at once; missing helpers fail open.
_dispatch_live_owner_hold_valid() {
	local owner_pid="$1" owner_start="$2" worktree_path="$3" live_start="" owner_info="" registry_pid=""
	[[ "$owner_pid" =~ ^[1-9][0-9]*$ && -n "$owner_start" && -n "$worktree_path" ]] || return 1
	declare -F _wt_process_start_token_for_pid >/dev/null 2>&1 || return 1
	declare -F check_worktree_owner_snapshot >/dev/null 2>&1 || return 1
	live_start=$(_wt_process_start_token_for_pid "$owner_pid" 2>/dev/null) || return 1
	[[ "${live_start//[^A-Za-z0-9_.:-]/_}" == "$owner_start" ]] || return 1
	owner_info=$(check_worktree_owner_snapshot "$worktree_path" 2>/dev/null) || return 1
	registry_pid="${owner_info%%|*}"
	[[ "$registry_pid" == "$owner_pid" ]] || return 1
	return 0
}

# Parse the latest structured refusal from one candidate's recent log lines.
# Output: pid<TAB>start<TAB>worktree
_dispatch_live_owner_refusal_fields() {
	local lines="$1" line="" found=""
	local pattern='WORKTREE_LIVE_OWNER_REFUSED issue=#[0-9]+ repo=[^[:space:]]+ owner_pid=([1-9][0-9]*) owner_start=([A-Za-z0-9_.:-]+) action=[a-z_]+ worktree=(.+)$'
	while IFS= read -r line; do
		if [[ "$line" =~ $pattern ]]; then
			found="${BASH_REMATCH[1]}"$'\t'"${BASH_REMATCH[2]}"$'\t'"${BASH_REMATCH[3]}"
		fi
	done <<<"$lines"
	[[ -n "$found" ]] || return 1
	printf '%s\n' "$found"
	return 0
}

# GH#33538: blocks that only a maintainer action (visible as an issue change)
# can clear. They hold unowned available issues, so no ownership evidence.
_dispatch_maintainer_gate_reason() {
	local reason="$1"
	case "$reason" in
	approval_signer_unverifiable) return 0 ;;
	permission_grant_unverified | needs_maintainer_permissions | cost_budget_exceeded | consolidated) return 0 ;;
	esac
	return 1
}

# Extract a deterministic maintainer gate from one candidate's attempt lines.
# Transient verifier results (API_ERROR, HELPER_MISSING, NO_KEY, unknown) never
# qualify: they must be re-checked on the next cycle.
# Stdout: reason token. Returns 0 when found, 1 otherwise.
_dispatch_maintainer_gate_from_lines() {
	local lines="$1"
	if [[ "$lines" == *"DISPATCH_BLOCK_REASON reason=approval_signer_unverifiable "* ]]; then
		printf 'approval_signer_unverifiable\n'
		return 0
	fi
	if [[ "$lines" =~ DISPATCH_BLOCK_REASON\ reason=permission_grant_unverified\ signal=(STALE_APPROVAL|NO_APPROVAL|UNTRUSTED_APPROVAL|LEGACY_APPROVAL|MALFORMED_APPROVAL)([[:space:]]|$) ]]; then
		printf 'permission_grant_unverified\n'
		return 0
	fi
	if [[ "$lines" == *"DISPATCH_BLOCK_REASON reason=needs_maintainer_permissions "* ]]; then
		printf 'needs_maintainer_permissions\n'
		return 0
	fi
	if [[ "$lines" == *"DISPATCH_BLOCK_REASON reason=cost_budget_exceeded signal=COST_BUDGET_EXCEEDED"* ]]; then
		printf 'cost_budget_exceeded\n'
		return 0
	fi
	if [[ "$lines" == *"Dispatch deferred for #"*": issue needs comment consolidation"* ]]; then
		printf 'consolidated\n'
		return 0
	fi
	return 1
}

# Strip leading zeros before arithmetic, rejecting values beyond a portable
# signed 32-bit range without ever evaluating the unbounded input in Bash:
# the length guard short-circuits first, so arithmetic sees at most 10 digits,
# well inside Bash's 64-bit integers.
_dispatch_checkpoint_decimal() {
	local value="$1" fallback="$2"
	if [[ "$value" =~ ^0*([1-9][0-9]*|0)$ ]]; then
		value="${BASH_REMATCH[1]}"
		if [[ "${#value}" -le 10 ]] && [[ "$value" -lt 2147483648 ]]; then
			printf '%s\n' "$value"
			return 0
		fi
	fi
	printf '%s\n' "$fallback"
	return 0
}

# Read boundary evidence once per ceremony, not on cache hits. Conservatively
# include every claim/lease expiry and attention re-arm, even obsolete or
# untrusted records: extra wakeups are safe, delayed continuations are not.
# GH#37514: the fleet re-arm in pr-checkpoint-continuation-helper.sh
# (_pcc_fleet_rearm_allowed) is anchored on an attention record or a stall
# release and doubles up to _PCC_ATTENTION_REARM_MAX_DOUBLINGS (6) times, so
# every such anchor contributes each doubled deadline.
# Assigned issues must retain the live/stale-owner checks on every cycle.
# GH#38353: an external_trigger_pending hold also wakes at its first revisit
# deadline and at the next revisit recorded by terminal-blocker-trigger-revisit.sh.
_dispatch_draft_hint_boundary() {
	local candidate="$1" repo="$2" issue="$3" comments="" rearm="" observed="" revisit="" due=""
	local helper="${SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}/terminal-blocker-trigger-revisit.sh"
	jq -e '(.assignees // [] | length) == 0' <<<"$candidate" >/dev/null || return 1
	rearm=$(_dispatch_checkpoint_decimal "${AIDEVOPS_PCC_ATTENTION_REARM_SECONDS:-43200}" 43200)
	revisit=$(_dispatch_checkpoint_decimal "${AIDEVOPS_TRIGGER_REVISIT_INTERVAL_S:-86400}" 86400)
	[[ ! -x "$helper" ]] || due=$("$helper" next-due "$repo" "$issue" 2>/dev/null) || due=""
	due=$(_dispatch_checkpoint_decimal "$due" 0)
	# A deadline crossed during the bounded read must still invalidate the hint.
	observed=$(date +%s)
	comments=$(timeout_sec "$_DISPATCH_NEGATIVE_PR_REST_TIMEOUT_SECONDS" \
		gh api "repos/${repo}/issues/${issue}/comments?per_page=100" --paginate --slurp 2>/dev/null) || return 1
	jq -er --argjson rearm "$rearm" --argjson observed "$observed" --argjson revisit "$revisit" --argjson due "$due" '
		if type != "array" then error("invalid comments") else flatten end |
		[.[] | (.body // "") as $body |
			($body | scan("expires_at=([0-9]+)") | .[0] | tonumber),
			(select($rearm > 0 and ($body | test("aidevops:(blocked|stalled)-checkpoint-attention|(^|\n)CLAIM_RELEASED "))) |
				(.created_at | fromdateiso8601) as $anchor | range(0; 7) | $anchor + $rearm * pow(2; .) | floor),
			(select($revisit > 0 and ($body | test("(^|\n)Terminal blocker: reason=external_trigger_pending "))) |
				(.created_at | fromdateiso8601) + $revisit | floor)] + [$due] |
		map(select(. >= $observed)) | (min // 0) | tostring + ":" + ($rearm | tostring)
	' <<<"$comments" 2>/dev/null
	return $?
}

# GH#38237: use the existing hasher over canonical material inputs, not updatedAt.
# A missing body can still be recorded, but cannot prove a later bump is noise.
_dispatch_negative_cache_material() {
	local candidate="$1" material="" fingerprint="" body_state="metadata"
	material=$(jq -cS '{labels: ([.labels[]? | .name? // .] | sort),
		assignees: ([.assignees[]? | .login? // .] | sort), body: (.body // null)}' <<<"$candidate" 2>/dev/null) || return 1
	if jq -e '.body | type == "string"' <<<"$candidate" >/dev/null 2>&1; then
		body_state="body"
	fi
	fingerprint=$(_dispatch_capability_fingerprint "" "$material" "") || return 1
	printf '%s:%s\n' "$body_state" "$fingerprint"
	return 0
}

# Reuse the gh shim's audit classifier; only the legacy first-token events need
# the dispatch-specific fallback. Keep the shim's globals isolated from pulse.
_dispatch_negative_cache_ops_only() (
	local comments="$1" body=""
	source "${_PULSE_DISPATCH_LIB_DIR}/gh-api-guards-lib.sh"
	jq -e 'type == "array" and length < 100 and all(.[]; (.body | type) == "string")' <<<"$comments" >/dev/null 2>&1 || return 1
	while IFS= read -r body; do
		body=$(jq -r '.' <<<"$body") || return 1
		# The footer classifier also accepts unmarked routine descriptions and
		# embedded dispatch text; only its explicit ops markers are noise here.
		# Actionable directives (e.g. a standalone retry line) are never noise.
		if [[ "$body" =~ (^|$'\n')[[:space:]]*terminal-blocker-circuit:retry ]]; then
			return 1
		fi
		if [[ "$body" == *'<!-- ops:start'* ]] && _shim_body_is_ops_audit "$body"; then
			continue
		fi
		case "$body" in
		DISPATCH_CLAIM[[:space:]]* | DISPATCH_LEASE[[:space:]]* | CLAIM_RELEASED[[:space:]]* | CHECKPOINT_CONTINUATION_APPROVED[[:space:]]* | 'Dispatching worker'[[:space:]]*) ;;
		*) return 1 ;;
		esac
	done < <(jq -c '.[].body' <<<"$comments")
	return 0
)

#######################################
# GH#38352: log one draft-checkpoint record skip per issue, revision, cache
# reason and skip reason. The marker is a sibling of the per-issue record
# (readers open only the exact record path), so every pulse process and
# parallel dispatch child shares the once-per-issue suppression. detail=assigned
# is by design: assigned issues keep live/stale-owner checks every cycle.
# Args: candidate JSON, candidate revision, cache reason, skip reason
# Returns: 0 always (diagnostic only; never changes the dispatch decision)
#######################################
_dispatch_negative_cache_skip_log() {
	local candidate="$1" updated="$2" cache_reason="$3" skip_reason="$4"
	local fields issue repo file marker previous detail=unavailable
	previous=""
	fields=$(jq -r "$_DISPATCH_NEGATIVE_CACHE_IDENTITY_JQ" <<<"$candidate" 2>/dev/null) || return 0
	IFS=$'\t' read -r issue repo _ <<<"$fields"
	file=$(_dispatch_negative_cache_path "$issue" "$repo") || return 0
	if [[ "$skip_reason" == boundary ]] && jq -e '(.assignees // [] | length) > 0' <<<"$candidate" >/dev/null 2>&1; then
		detail=assigned
	fi
	marker="${skip_reason}:${detail}:${cache_reason}:${updated}"
	if [[ -f "${file}.skip" && ! -L "${file}.skip" ]]; then
		IFS= read -r previous <"${file}.skip" || previous=""
	fi
	[[ "$previous" != "$marker" ]] || return 0
	mkdir -p "${file%/*}" 2>/dev/null || return 0
	[[ ! -L "${file}.skip" ]] || return 0
	(umask 077 && printf '%s\n' "$marker" >"${file}.skip") 2>/dev/null || true
	echo "[pulse-wrapper] negative_cache_record_skipped reason=${skip_reason} detail=${detail} cache_reason=${cache_reason} issue=#${issue} repo=${repo}" >>"${LOGFILE:-/dev/null}"
	return 0
}

_dispatch_negative_cache_record() {
	local candidate="$1" reason="$2" pr="${3:-}" fingerprint="${4:-}" owner_path="${5:-}"
	local fields="" issue="" repo="" updated="" file="" tmp="" checkpoint_boundary="" material=""
	if ! _dispatch_maintainer_gate_reason "$reason"; then
		case "$reason" in dedup_active_claim | dedup_active_claim_live_owner | dedup_active_claim_durable_launch | dedup_pr_evidence | worker_draft_checkpoint_blocked | stale_draft_checkpoint | worker_draft_checkpoint_cooldown | terminal_blocker_circuit | terminal_blocker_backoff | terminal_blocker_fleet_hold | zero_attempt_backoff | "$_DISPATCH_LIVE_OWNER_HOLD_REASON") ;; *) return 0 ;; esac
	fi
	if [[ "$reason" == "$_DISPATCH_LIVE_OWNER_HOLD_REASON" ]]; then
		[[ "$pr" =~ ^[1-9][0-9]*$ && "$fingerprint" =~ ^[A-Za-z0-9_.:-]+$ && -n "$owner_path" ]] || return 0
		[[ "$owner_path" != *$'\t'* && "$owner_path" != *$'\n'* ]] || return 0
	else
		owner_path=""
		fingerprint=""
	fi
	fields=$(jq -r "$_DISPATCH_NEGATIVE_CACHE_IDENTITY_JQ" <<<"$candidate") || return 0
	IFS=$'\t' read -r issue repo updated <<<"$fields"
	[[ "$updated" =~ ^[0-9TZ:.-]+$ ]] || return 0
	# Unassigned/available claim hints cannot pass the reader's owner gate.
	# Do not repeatedly write records that can never be used.
	if [[ "$reason" == dedup_active_claim* ]] && ! jq -e '(.assignees // [] | length) > 0 and
		([.labels[]? | .name? // .] | any(. == "status:claimed" or . == "status:in-progress" or . == "status:in-review"))' <<<"$candidate" >/dev/null 2>&1; then
		return 0
	fi
	# GH#38352: a draft-checkpoint hint that cannot be recorded names its
	# reason once per issue revision instead of silently re-running the ceremony.
	if [[ "$reason" == worker_draft_checkpoint_blocked || "$reason" == stale_draft_checkpoint ]]; then
		fingerprint=$(_dispatch_negative_pr_fingerprint "$repo" "$pr") ||
			{ _dispatch_negative_cache_skip_log "$candidate" "$updated" "$reason" fingerprint; return 0; }
		owner_path=$(_dispatch_draft_hint_boundary "$candidate" "$repo" "$issue") ||
			{ _dispatch_negative_cache_skip_log "$candidate" "$updated" "$reason" boundary; return 0; }
	fi
	if [[ "$reason" == dedup_pr_evidence ]]; then
		fingerprint=$(_dispatch_pr_evidence_fingerprint "$repo" "$pr") || return 0
	fi
	if [[ "$reason" == worker_draft_checkpoint_cooldown ]]; then
		[[ "$_DISPATCH_CHECKPOINT_COOLDOWN_SECONDS" -gt 0 ]] || return 0
		checkpoint_boundary=$(_dispatch_draft_hint_boundary "$candidate" "$repo" "$issue") ||
			{ _dispatch_negative_cache_skip_log "$candidate" "$updated" "$reason" boundary; return 0; }
		owner_path=$(_dispatch_checkpoint_pr_head "$repo" "$pr" allow_rest) ||
			{ _dispatch_negative_cache_skip_log "$candidate" "$updated" "$reason" pr_head; return 0; }
		fingerprint=$(_dispatch_checkpoint_fingerprint "$candidate") ||
			{ _dispatch_negative_cache_skip_log "$candidate" "$updated" "$reason" fingerprint; return 0; }
	fi
	# Live-owner holds never consult material; skip the issue read for them.
	if [[ "$reason" != "$_DISPATCH_LIVE_OWNER_HOLD_REASON" ]] &&
		_dispatch_negative_cache_load_source "$candidate" allow_rest exact; then
		material=$(_dispatch_negative_cache_material "$_DISPATCH_NEGATIVE_CACHE_SOURCE") || material=""
	fi
	[[ -n "$material" ]] || material=$(_dispatch_negative_cache_material "$candidate") || return 0
	file=$(_dispatch_negative_cache_path "$issue" "$repo") || return 0
	mkdir -p "${file%/*}" 2>/dev/null || return 0
	tmp=$(mktemp "${file}.XXXXXX") || return 0
	chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
	if printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$updated" "$reason" "$pr" "$fingerprint" "$owner_path" "$checkpoint_boundary" "$material" "$updated" >"$tmp"; then
		if mv -f "$tmp" "$file"; then
			if [[ "$reason" == worker_draft_checkpoint_cooldown ]]; then
				_DISPATCH_CHECKPOINT_COOLDOWN_RECORDED=1
			fi
		else
			rm -f "$tmp"
		fi
	else
		rm -f "$tmp"
	fi
	return 0
}

# Quiet eligibility is fixed at write time, independently of record age.
_dispatch_checkpoint_cooldown_ttl() {
	local candidate="$1" stamp="$2" ttl="$_DISPATCH_CHECKPOINT_COOLDOWN_SECONDS"
	local quiet_ttl="${AIDEVOPS_DISPATCH_CHECKPOINT_QUIET_COOLDOWN_SECONDS:-21600}"
	local quiet_after="${AIDEVOPS_DISPATCH_CHECKPOINT_QUIET_AFTER_SECONDS:-14400}" revision_epoch=""
	[[ "$ttl" -gt 0 ]] || return 1
	quiet_ttl=$(_dispatch_checkpoint_decimal "$quiet_ttl" 21600)
	((quiet_ttl <= 86400)) || quiet_ttl=86400
	quiet_after=$(_dispatch_checkpoint_decimal "$quiet_after" 14400)
	if ((quiet_ttl > ttl)); then
		revision_epoch=$(jq -er 'select((.assignees // [] | length) == 0) |
			.updatedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' <<<"$candidate" 2>/dev/null) || revision_epoch=""
		if [[ "$revision_epoch" =~ ^[0-9]+$ ]] && ((stamp >= revision_epoch && stamp - revision_epoch >= quiet_after)); then
			ttl="$quiet_ttl"
		fi
	fi
	printf '%s\n' "$ttl"
	return 0
}

# GH#37780: return 0 only when the candidate has assignees and none of them is
# this runner. An unset or malformed self login fails closed (returns 1).
_dispatch_claim_owned_elsewhere() {
	local candidate="$1" self="${_DISPATCH_SELF_LOGIN:-}"
	[[ "$self" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || return 1
	jq -e --arg self "$self" '
		[.assignees // [] | .[] | (.login? // .) | strings | ascii_downcase] as $owners |
		($owners | length) > 0 and all($owners[]; . != ($self | ascii_downcase))' <<<"$candidate" >/dev/null 2>&1 || return 1
	return 0
}

# Reasons whose hint carries its own validity evidence (exact PR fingerprint,
# owner generation, maintainer gate or a self-expiring window) instead of the
# claimed-owner snapshot check that active-claim hints require.
_dispatch_negative_cache_self_validating_reason() {
	local reason="$1"
	case "$reason" in
	terminal_blocker_circuit | terminal_blocker_backoff | terminal_blocker_fleet_hold | zero_attempt_backoff | worker_draft_checkpoint_blocked | stale_draft_checkpoint | worker_draft_checkpoint_cooldown | dedup_pr_evidence | "$_DISPATCH_LIVE_OWNER_HOLD_REASON")
		return 0
		;;
	esac
	_dispatch_maintainer_gate_reason "$reason"
	return $?
}

_dispatch_negative_cache_material_matches() {
	local candidate="$1" checkpoint_mode="$2" material="$3" current=''
	[[ "$checkpoint_mode" != snapshot_only && "$material" == body:* ]] || return 1
	_dispatch_negative_cache_load_source "$candidate" "$checkpoint_mode" || return 1
	current=$(_dispatch_negative_cache_material "$_DISPATCH_NEGATIVE_CACHE_SOURCE") || return 1
	[[ "$current" == "$material" ]] || return 1
	return 0
}

_dispatch_negative_cache_refresh_revision() {
	local candidate="$1" checkpoint_mode="$2" record="$3" file="$4"
	local stamp='' cached='' reason='' pr='' fingerprint='' owner_path='' checkpoint_boundary='' material='' revision_anchor=''
	local comments='' updated='' repo='' issue='' tmp=''
	IFS=$'\034' read -r stamp cached reason pr fingerprint owner_path checkpoint_boundary material revision_anchor <<<"${record//$'\t'/$'\034'}" || return 1
	[[ "$cached" =~ ^[0-9TZ:.-]+$ ]] || return 1
	_dispatch_negative_cache_material_matches "$candidate" "$checkpoint_mode" "$material" || return 1
	IFS=$'\t' read -r issue repo updated < <(jq -r '[.number, .repo_slug, .updatedAt] | @tsv' <<<"$candidate") || return 1
	comments=$(timeout_sec "$_DISPATCH_NEGATIVE_PR_REST_TIMEOUT_SECONDS" \
		gh api "repos/${repo}/issues/${issue}/comments?since=${cached}&per_page=100" 2>/dev/null) || return 1
	_dispatch_negative_cache_ops_only "$comments" || return 1
	# Checkpoint hints embed boundary evidence (expiries, re-arm deadlines);
	# new comments that introduce such events must force a recompute.
	case "$reason" in
	worker_draft_checkpoint_blocked | stale_draft_checkpoint | worker_draft_checkpoint_cooldown)
		if jq -e 'any(.[]; (.body // "") | test("expires_at=[0-9]|aidevops:(blocked|stalled)-checkpoint-attention|(^|\n)CLAIM_RELEASED |(^|\n)CHECKPOINT_CONTINUATION_APPROVED "))' <<<"$comments" >/dev/null 2>&1; then
			return 1
		fi
		;;
	esac
	# Refresh the revision, never the TTL or reason-specific evidence. Preserve
	# the original revision anchor used for write-time quiet-TTL eligibility.
	tmp=$(mktemp "${file}.XXXXXX") || return 1
	chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
	if ! printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$stamp" "$updated" "$reason" "$pr" "$fingerprint" "$owner_path" "$checkpoint_boundary" "$material" "${revision_anchor:-$cached}" >"$tmp" ||
		! mv -f "$tmp" "$file"; then
		rm -f "$tmp"
		return 1
	fi
	return 0
}

# Fixed TTL ceiling per hint reason. Checkpoint reasons compute their own TTL in
# _dispatch_negative_cache_reason; everything else uses the general TTL.
_dispatch_negative_cache_reason_ttl() {
	local reason="$1"
	case "$reason" in
	terminal_blocker_circuit) printf '%s\n' "$_DISPATCH_TERMINAL_CIRCUIT_CACHE_TTL_SECONDS" ;;
	# GH#36214: the zero-attempt backoff is windowed and self-expiring like
	# the unknown-blocker backoff; a reset comment bumps updatedAt at once.
	# GH#36772: a fleet hold can wake on runner capability without an
	# issue edit, so it keeps this short ceiling instead of the circuit's.
	terminal_blocker_backoff | zero_attempt_backoff | terminal_blocker_fleet_hold)
		printf '%s\n' "$_DISPATCH_TERMINAL_BACKOFF_CACHE_TTL_SECONDS"
		;;
	dedup_pr_evidence) printf '%s\n' "$_DISPATCH_PR_EVIDENCE_CACHE_TTL_SECONDS" ;;
	permission_grant_unverified | needs_maintainer_permissions | cost_budget_exceeded | consolidated)
		printf '%s\n' "$_DISPATCH_MAINTAINER_GATE_CACHE_TTL_SECONDS"
		;;
	*) printf '%s\n' "$_DISPATCH_NEGATIVE_CACHE_TTL_SECONDS" ;;
	esac
	return 0
}

_dispatch_negative_cache_reason() {
	local candidate="$1" fields="" issue="" repo="" updated="" file="" stamp="" cached="" reason="" now="" pr="" fingerprint="" current="" owner_path=""
	local expected_reason="${2:-}" checkpoint_mode="${3:-allow_rest}" checkpoint_boundary="" record="" material="" revision_anchor=""
	local ttl=""
	local quiet_ttl="${AIDEVOPS_DISPATCH_CHECKPOINT_QUIET_COOLDOWN_SECONDS:-21600}"
	fields=$(jq -r "$_DISPATCH_NEGATIVE_CACHE_IDENTITY_JQ" <<<"$candidate") || return 1
	IFS=$'\t' read -r issue repo updated <<<"$fields"
	[[ "$updated" =~ ^[0-9TZ:.-]+$ ]] || return 1
	file=$(_dispatch_negative_cache_path "$issue" "$repo") || return 1
	[[ -f "$file" && ! -L "$file" ]] || return 1
	IFS= read -r record <"$file" || return 1
	# Non-whitespace separators preserve empty optional fields in old/new records.
	IFS=$'\034' read -r stamp cached reason pr fingerprint owner_path checkpoint_boundary material revision_anchor <<<"${record//$'\t'/$'\034'}" || return 1
	[[ -z "$expected_reason" || "$reason" == "$expected_reason" ]] || return 1
	# A signer diagnostic must be recomputed after any issue/comment revision,
	# including operational comments that the material-only refresh can ignore.
	[[ "$reason" != approval_signer_unverifiable || "$cached" == "$updated" ]] || return 1
	[[ "$stamp" =~ ^[0-9]+$ ]] || return 1
	ttl=$(_dispatch_negative_cache_reason_ttl "$reason")
	# GH#38261: only the cheap gate here. The material and comment reads run in
	# the refresh below, after the TTL checks, so expired hints cost no API call.
	[[ "$cached" == "$updated" || "$reason" == "$_DISPATCH_LIVE_OWNER_HOLD_REASON" ]] ||
		[[ "$checkpoint_mode" != snapshot_only && "$material" == body:* ]] || return 1
	if ! _dispatch_negative_cache_self_validating_reason "$reason"; then
		# Ownership hints: the snapshot must independently still show a claimed
		# owner. The worker-draft exception uses the exact PR fingerprint from a
		# fresh complete snapshot or one bounded REST read; neither permits a launch.
		jq -e '(.assignees // [] | length) > 0 and
			([.labels[]? | .name? // .] | any(. == "status:claimed" or . == "status:in-progress" or . == "status:in-review"))' <<<"$candidate" >/dev/null 2>&1 || return 1
	fi
	case "$reason" in
	worker_draft_checkpoint_cooldown)
		ttl=$(_dispatch_checkpoint_cooldown_ttl "$(jq --arg updated "${revision_anchor:-$cached}" '.updatedAt=$updated' <<<"$candidate")" "$stamp") || return 1
		[[ -n "$fingerprint" ]] || return 1
		# Quiet hints must obey the same owner/re-arm limits as draft blocks.
		# Legacy records without boundary evidence run the ceremony once.
		jq -e '(.assignees // [] | length) == 0' <<<"$candidate" >/dev/null || return 1
		[[ "$checkpoint_boundary" =~ ^([0-9]+):([0-9]+)$ ]] || return 1
		local checkpoint_deadline="${BASH_REMATCH[1]}" checkpoint_rearm="${BASH_REMATCH[2]}"
		[[ "$checkpoint_rearm" == "$(_dispatch_checkpoint_decimal "${AIDEVOPS_PCC_ATTENTION_REARM_SECONDS:-43200}" 43200)" ]] || return 1
		now=$(date +%s)
		((checkpoint_deadline == 0 || now < checkpoint_deadline)) || return 1
		current=$(_dispatch_checkpoint_fingerprint "$candidate") || return 1
		[[ "$current" == "$fingerprint" ]] || return 1
		# Expire before the optional REST read; enumeration remains network-free.
		((now >= stamp && now - stamp < ttl)) || return 1
		current=$(_dispatch_checkpoint_pr_head "$repo" "$pr" "$checkpoint_mode") || return 1
		[[ -n "$owner_path" && "$current" == "$owner_path" ]] || return 1
		;;
	terminal_blocker_circuit | terminal_blocker_backoff | zero_attempt_backoff | terminal_blocker_fleet_hold) ;;
	dedup_active_claim | dedup_active_claim_live_owner | dedup_active_claim_durable_launch)
		# Empty worker pools must retain the authoritative active-claim recheck
		# for claims this runner could own. GH#37780: an empty local pool says
		# nothing about another runner's claim, and rechecking those every cycle
		# spent the dispatch reserve and kept the pool empty.
		if [[ "${_DISPATCH_ACTIVE_WORKERS:-0}" == 0 ]]; then
			_dispatch_claim_owned_elsewhere "$candidate" || return 1
		fi
		;;
	worker_draft_checkpoint_blocked | stale_draft_checkpoint)
		[[ -n "$fingerprint" ]] || return 1
		# Older records lack boundary evidence and must run the ceremony once.
		[[ "$owner_path" =~ ^([0-9]+):([0-9]+)$ ]] || return 1
		local boundary="${BASH_REMATCH[1]}" rearm="${BASH_REMATCH[2]}"
		[[ "$rearm" == "$(_dispatch_checkpoint_decimal "${AIDEVOPS_PCC_ATTENTION_REARM_SECONDS:-43200}" 43200)" ]] || return 1
		jq -e '(.assignees // [] | length) == 0' <<<"$candidate" >/dev/null || return 1
		ttl=$(_dispatch_checkpoint_decimal "$quiet_ttl" 21600)
		((ttl <= 21600)) || ttl=21600
		# GH#34402: the PR read can cost an API call, so expire first.
		now=$(date +%s)
		((now >= stamp && now - stamp < ttl)) || return 1
		((boundary == 0 || now < boundary)) || return 1
		current=$(_dispatch_negative_pr_fingerprint "$repo" "$pr") || return 1
		[[ "$current" == "$fingerprint" ]] || return 1
		;;
	dedup_pr_evidence)
		_dispatch_pr_evidence_hint_valid "$repo" "$pr" "$fingerprint" "$stamp" "$ttl" || return 1
		;;
	"$_DISPATCH_LIVE_OWNER_HOLD_REASON")
		_dispatch_live_owner_hold_valid "$pr" "$fingerprint" "$owner_path" || return 1
		;;
	# GH#33538: material issue revisions invalidate maintainer-gate hints.
	approval_signer_unverifiable | permission_grant_unverified | needs_maintainer_permissions | cost_budget_exceeded | consolidated) ;;
	*) return 1 ;;
	esac
	now=$(date +%s)
	((now >= stamp && now - stamp < ttl)) || return 1
	# Live-owner holds remain keyed to owner generation, not claim-comment bumps.
	if [[ "$cached" != "$updated" && "$reason" != "$_DISPATCH_LIVE_OWNER_HOLD_REASON" ]]; then
		_dispatch_negative_cache_refresh_revision "$candidate" "$checkpoint_mode" "$record" "$file" || return 1
	fi
	printf '%s\n' "$reason"
	return 0
}

_dispatch_prefilter_owned_candidate() {
	local candidate="$1" issue="$2" repo="$3" reason=""
	_dispatch_ranked_candidate_consumed "$candidate"
	if reason=$(_dispatch_negative_cache_reason "$candidate"); then
		_DISPATCH_CANDIDATE_ELIGIBILITY="$_DISPATCH_ELIGIBILITY_INELIGIBLE"
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue} (${repo}) — cross-cycle ownership block:${reason}" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_negative_cache_hit"
		return 0
	fi
	# A live exact worker is a safe no-API skip on the very first cycle.
	if declare -F has_worker_for_repo_issue >/dev/null 2>&1 &&
		has_worker_for_repo_issue "$issue" "$repo"; then
		_DISPATCH_CANDIDATE_ELIGIBILITY="$_DISPATCH_ELIGIBILITY_INELIGIBLE"
		_dispatch_negative_cache_record "$candidate" dedup_active_claim_live_owner
		_dispatch_stats_increment "dispatch_candidate_live_worker_prefilter"
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue} (${repo}) — exact live worker prefilter" >>"$LOGFILE"
		return 0
	fi
	return 1
}

_dispatch_cache_confirmed_block() {
	local candidate="$1" issue="$2" repo="$3" reason="" lines="" pr=""
	lines=$(_dispatch_candidate_recent_lines "$issue" "$repo") || lines=""
	# A routed continuation must not fall through to any older ownership hint.
	[[ "$lines" != *"checkpoint_routed"* && "$lines" != *"CONTINUATION_ROUTED"* ]] || return 0
	# Already recorded by the benign result classifier; do not overwrite it with
	# the older PR-read cache (or an unusable available-issue active-claim hint).
	if [[ "${_DISPATCH_CHECKPOINT_COOLDOWN_RECORDED:-0}" == 1 ]] &&
		_dispatch_checkpoint_cooldown_eligible "$lines"; then
		return 0
	fi
	# Only a positively identified worker draft with an unchanged prefetched PR
	# can bypass the next ceremony. Never cache interactive checkpoint routing.
	if [[ "$lines" != *"checkpoint_routed"* &&
		"$lines" =~ WORKER_DRAFT_CHECKPOINT:[[:space:]]draft[[:space:]]PR[[:space:]]#([0-9]+) ]]; then
		pr="${BASH_REMATCH[1]}"
		reason=worker_draft_checkpoint_blocked
		[[ "$lines" != *"stale_draft_checkpoint"* ]] || reason=stale_draft_checkpoint
		_dispatch_negative_cache_record "$candidate" "$reason" "$pr"
		return 0
	fi
	# GH#38142: open, draft or merged PR evidence naming exactly one PR. Evidence
	# without a PR number (task-id matches) or naming several PRs (superseded
	# coverage) is not cached: a change to an unrecorded PR could lift the block.
	local evidence_pattern='DISPATCH_BLOCK_REASON reason=dedup_pr_evidence signal=pr_evidence_block: [^#]*PR #([1-9][0-9]*) ([^'$'\n'']*)'
	local second_pr_pattern='PR #[0-9]'
	if [[ "$lines" =~ $evidence_pattern ]]; then
		pr="${BASH_REMATCH[1]}"
		[[ "${BASH_REMATCH[2]}" =~ $second_pr_pattern ]] ||
			_dispatch_negative_cache_record "$candidate" dedup_pr_evidence "$pr"
		return 0
	fi
	# GH#33026: a live worktree owner refused this issue's claim. Hold until that
	# exact owner generation exits or hands over; never touch the owner row.
	local refusal="" owner_pid="" owner_start="" owner_path=""
	if refusal=$(_dispatch_live_owner_refusal_fields "$lines"); then
		IFS=$'\t' read -r owner_pid owner_start owner_path <<<"$refusal"
		_dispatch_negative_cache_record "$candidate" "$_DISPATCH_LIVE_OWNER_HOLD_REASON" "$owner_pid" "$owner_start" "$owner_path"
		if jq -e '[.labels[]? | .name? // .] | index("solved:worker") != null' <<<"$candidate" >/dev/null 2>&1; then
			# Diagnostic only: a merged worker PR does not prove completion.
			echo "[pulse-wrapper] Dispatch_max: #${issue} (${repo}) is OPEN with solved:worker while a live owner holds its worktree; verify remaining acceptance criteria before closing (no automatic close)" >>"$LOGFILE"
		fi
		return 0
	fi
	# GH#33538: persist deterministic maintainer gates only from exact attempt
	# evidence, so later cycles skip them without spending a wave slot.
	if reason=$(_dispatch_maintainer_gate_from_lines "$lines"); then
		_dispatch_negative_cache_record "$candidate" "$reason"
		return 0
	fi
	[[ "${_DISPATCH_CANDIDATE_ELIGIBILITY:-}" == "$_DISPATCH_ELIGIBILITY_INELIGIBLE" ]] || return 0
	reason=$(_dispatch_benign_blocked_candidate_reason "$issue" "$repo") || return 0
	# The ledger reason alone cannot distinguish a transient verifier error.
	_dispatch_maintainer_gate_reason "$reason" && return 0
	_dispatch_negative_cache_record "$candidate" "$reason"
	return 0
}

# Record an unlaunched dispatch_with_dedup result for one candidate.
# Args: candidate JSON, issue, repo slug, dispatch rc
# Returns: _DISPATCH_CYCLE_BUDGET_DEFER_RC for a deferral, else 1 (skipped)
_dispatch_record_and_cache_block() {
	local candidate="$1" issue="$2" repo="$3" rc="$4"
	if [[ "$rc" -eq "${_DISPATCH_CYCLE_BUDGET_DEFER_RC:-75}" ]]; then
		# GH#34428: no stage ran. Drop this attempt's recency stamp and skip
		# failure classification, so the candidate keeps its ranking and no
		# fast-fail, backoff, timeout or launch-failure evidence is recorded.
		_dispatch_attempt_recency_clear "$issue" "$repo"
		return "$rc"
	fi
	_dispatch_record_nonzero_dispatch_result "$issue" "$repo" "$rc" "$candidate"
	_dispatch_cache_confirmed_block "$candidate" "$issue" "$repo"
	return 1
}
