#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by terminal-blocker-recovery-helper.sh (GH#39539 file split).
# Policy, re-arm and release evaluation for held terminal-blocker entries.
# Functions moved verbatim; shared TBR_* state lives in the orchestrator.

# Include guard
[[ -n "${_TBR_RELEASE_LIB_LOADED:-}" ]] && return 0
_TBR_RELEASE_LIB_LOADED=1

_tbr_reason_from_comments() {
	local comments="$1"
	printf '%s' "$comments" | jq -r '
		[flatten[] | (.body // "") | capture("Terminal blocker: reason=(?<r>[a-z_]+)")? | .r] | last // "unknown"
	' 2>/dev/null || printf 'unknown\n'
	return 0
}

# True when this runner's own login posted an open circuit marker.
_tbr_has_own_circuit() {
	local comments="$1"
	local self="$2"
	printf '%s' "$comments" | jq -e --arg self "$self" --arg marker "$TBR_CIRCUIT_MARKER" '
		[flatten[] | select((.user.login // "") == $self and ((.body // "") | contains($marker)))] | length > 0
	' >/dev/null 2>&1 || return 1
	return 0
}

# True when another OWNER/MEMBER login posted a circuit marker.
#aidevops:trust-boundary — matches terminal-blocker-circuit.sh's authoritative
# associations: another runner's bare-COLLABORATOR circuit is never trusted
# hold evidence, so it is never queued for policy recovery either.
_tbr_has_foreign_circuit() {
	local comments="$1"
	local self="$2"
	printf '%s' "$comments" | jq -e --arg self "$self" --arg marker "$TBR_CIRCUIT_MARKER" '
		[flatten[] | select((.user.login // "") != $self) |
		select((.author_association // "") | IN("OWNER", "MEMBER")) |
		select((.body // "") | contains($marker))] | length > 0
	' >/dev/null 2>&1 || return 1
	return 0
}

# Loader seam: prints the policy JSON; exit codes as recovery-policy-helper.sh.
_tbr_policy_read() {
	local repo="$1"
	bash "${_TBR_SCRIPT_DIR}/recovery-policy-helper.sh" "$repo" 2>/dev/null
	return $?
}

# GH#35129/t19068: load the repo's pinned default-branch recovery policy once
# per process (callers must not use command substitution, which would drop
# the cache). Sets _TBR_POLICY_STATE to "<fingerprint>:<enabled 0|1>", where
# the fingerprint hashes the normalized actions, or is "none" when no action
# is declared. Fingerprinting actions, not the pinned revision, keeps
# unrelated default-branch commits from looking like a policy change.
# Returns 0 when observed, 2 when the policy could not be read.
_TBR_POLICY_CACHE=""
_TBR_POLICY_STATE=""
_tbr_policy_load() {
	local repo="$1"
	local cache=";${_TBR_POLICY_CACHE};" policy="" actions="" fingerprint=none enabled=0 rc=0
	if [[ "$cache" == *";${repo}="* ]]; then
		cache="${cache#*;"${repo}"=}"
		_TBR_POLICY_STATE="${cache%%;*}"
		return 0
	fi
	policy=$(_tbr_policy_read "$repo") || rc=$?
	# Absence (3) is authoritative; failed observation is not withdrawal.
	[[ "$rc" -eq 0 || "$rc" -eq 3 ]] || return 2
	if [[ "$rc" -eq 0 ]]; then
		actions=$(printf '%s' "$policy" | jq -Sce '.actions | select(length > 0)' 2>/dev/null) || actions=""
	fi
	if [[ -n "$actions" ]]; then
		# shellcheck source=terminal-blocker-circuit.sh
		source "${_TBR_SCRIPT_DIR}/terminal-blocker-circuit.sh" || return 2
		fingerprint=$(_terminal_blocker_hash "$actions") || return 2
		enabled=1
	fi
	_TBR_POLICY_STATE="${fingerprint}:${enabled}"
	_TBR_POLICY_CACHE="${_TBR_POLICY_CACHE};${repo}=${_TBR_POLICY_STATE}"
	return 0
}

# GH#35129: true only when the repo's pinned default-branch recovery policy
# loads and enables at least one action for this authenticated writer.
_tbr_policy_enabled() {
	local repo="$1"
	_tbr_policy_load "$repo" || return 2
	[[ "$_TBR_POLICY_STATE" == *:1 ]] || return 1
	return 0
}

# t19068: true when the decision file's repo policy now differs from the one
# stamped at record time. Legacy records carry no stamp and count as "none",
# so a policy that appeared since wakes them once. A record without a repo,
# or an unreadable current policy, keeps the decision (fail closed).
_tbr_policy_changed_since() {
	local file="$1"
	local repo="" recorded=""
	repo=$(jq -r '.repo // ""' "$file" 2>/dev/null) || return 1
	[[ -n "$repo" ]] || return 1
	recorded=$(jq -r '.policy_fingerprint // "none"' "$file" 2>/dev/null) || return 1
	_tbr_policy_load "$repo" || return 1
	[[ "${_TBR_POLICY_STATE%:*}" != "$recorded" ]] || return 1
	return 0
}

# Optional $2: comments already read for this entry. GH#38311: a maintainer
# reply newer than a recorded human_decision ends its suppression, so the
# supervisor re-assesses on its next pass instead of after the TTL. t19068:
# so does a change to the repo's delegated recovery policy. Optional $3
# "standing" ignores a due external_trigger re-check (GH#40120): a due re-check
# only returns the entry to the supervisor; it never ends the standing guard.
_tbr_decision_active() {
	local key="$1" comments="${2:-}" scope="${3:-}"
	local file="${TBR_ROOT}/decisions/${key}.json"
	[[ -f "$file" ]] || return 1
	local ts="" now="" wake=""
	ts=$(jq -r '.recorded_epoch // 0' "$file" 2>/dev/null) || ts=0
	[[ "$ts" =~ ^[0-9]+$ ]] || ts=0
	now=$(date +%s)
	wake=$(jq -r '.wake // ""' "$file" 2>/dev/null) || wake=""
	# GH#38692: a human_decision ends only on a positive wake signal (reply or
	# policy change below), never on the flat TTL, so decided holds stop
	# resurfacing daily and crowding out undecided entries.
	if [[ "$wake" != human_decision && "$wake" != external_trigger ]]; then
		[[ $((now - ts)) -lt "$TBR_DECISION_TTL" ]] || return 1
		return 0
	fi
	# GH#40120: no GitHub event reports a site recovering or a date passing, so
	# an external_trigger decision is re-assessed at its recheck_after, or after
	# a bounded re-poll interval without one. human_decision stays event-only.
	if [[ "$wake" == external_trigger && "$scope" != standing ]]; then
		local due="" interval="${TBR_EXTERNAL_TRIGGER_RECHECK:-259200}"
		[[ "$interval" =~ ^[0-9]+$ ]] || interval=259200
		due=$(jq -r '.recheck_after_epoch // empty' "$file" 2>/dev/null) || due=""
		[[ "$due" =~ ^[0-9]+$ ]] || due=$((ts + interval))
		[[ "$now" -lt "$due" ]] || return 1
	fi
	if [[ -n "$comments" ]] && _tbr_reply_after "$comments" "$ts"; then
		return 1
	fi
	if _tbr_policy_changed_since "$file"; then
		return 1
	fi
	return 0
}

# GH#39232 #aidevops:trust-boundary: true while this runner's brief owner has a
# recorded human_decision for the issue that no reply or policy change has
# ended. It suspends only the time-window re-arm of a permission hold; a
# trusted retry or a relevant revision still releases it. A due
# external_trigger re-check does not end it (GH#40120). Args: repo issue comments
_tbr_human_decision_standing() {
	local repo="$1" issue="$2" comments="$3"
	local key=""
	key=$(_tbr_key "$repo" "$issue")
	# A missing or unreadable record prints nothing, so it is not standing.
	[[ "$(jq -r '.wake // ""' "${TBR_ROOT}/decisions/${key}.json" 2>/dev/null)" =~ ^(human_decision|external_trigger)$ ]] || return 1
	_tbr_decision_active "$key" "$comments" standing || return 1
	return 0
}

#######################################
# GH#33138: a circuit this runner opened projects status:blocked; GH#34846:
# so does a runtime-owned first observation. When the hold re-arms (trusted
# retry, relevant revision or backoff expiry), return the issue to
# status:available exactly once. Never releases brief holds,
# dependency blocks, permission-helper holds or maintainer holds: only a plain
# status:blocked issue with no other hold label is touched.
# Args: repo issue issue_json comments_json. Returns 2 on incomplete evidence
# or writes, so the queue entry survives for a later verified pass; 3 while a
# dependency is open; 4 when a standing human_decision keeps a permission hold
# whose window expired (GH#39232).
#######################################
_tbr_post_rearm_receipt() {
	local repo="$1"
	local issue="$2"
	local marker="$3"
	local extra="${4:-}"
	# The key marker stays on its own line: replay suppression matches lines.
	{
		printf '%s\n' "$marker"
		[[ -z "$extra" ]] || printf '%s\n' "$extra"
	} | bash "${_TBR_SCRIPT_DIR}/gh-write-helper.sh" issue comment "$issue" \
		--repo "$repo" --body-file - >/dev/null || return 2
	return 0
}

# GH#36061: only authenticated bare producer releases qualify. A structured
# marker anywhere in the history excludes legacy fallback, even if unreadable.
_tbr_latest_legacy_release() {
	local comments="$1" self="$2"
	local now="${TERMINAL_BLOCKER_NOW_EPOCH:-}"
	[[ "$now" =~ ^[0-9]+$ ]] || now=$(date -u '+%s')
	jq -c --arg self "$self" --argjson now "$now" \
		--argjson associations "$_TBC_AUTHORITATIVE_ASSOCIATIONS" "${_TBC_ORDER_JQ}${_TBC_HOLD_EVIDENCE_JQ}"'
		flatten | if any(.[]; (.body // "") | test("aidevops:terminal-blocker-(observation|circuit)"))
		then empty else
		[.[] | select(hold_evidence($associations; $self))
		| select(valid_time) | select((.created_at | fromdateiso8601) <= $now)
		| . as $event
		| ((.body // "") | try capture("(?m)^CLAIM_RELEASED reason=blocked runner=(?<runner>[A-Za-z0-9-]+) ") catch null) as $release
		| select($release != null and $release.runner == ($event.author // $event.user.login // ""))
		| select((.body // "") | contains("Terminal blocker: reason=") | not)]
		| sort_by(.created_at, (comment_id // 9007199254740992), .body) | last // empty end
	' <<<"$comments"
	return $?
}

# A later OWNER/MEMBER retry binds a bare release to the current label hold.
# Backoff expiry and brief changes never authorize legacy label projection.
_tbr_release_legacy_hold() {
	local repo="$1" issue="$2" issue_json="$3" comments="$4" evidence="$5"
	local key="" retry="" events="" label="" receipt="" backoff_rc=0
	local now="${TERMINAL_BLOCKER_NOW_EPOCH:-}"
	local blocked='status:blocked' array_type='array' order_jq="$_TBC_ORDER_JQ"
	[[ "$now" =~ ^[0-9]+$ ]] || now=$(date -u '+%s')
	terminal_blocker_backoff_active "$comments" >/dev/null || backoff_rc=$?
	[[ "$backoff_rc" -lt 2 ]] || return 2
	retry=$(_terminal_blocker_latest_retry_comment "$comments") || return 2
	[[ -n "$retry" ]] || return 2
	events=$(gh api "repos/${repo}/issues/${issue}/events?per_page=100" --paginate --slurp 2>/dev/null) || return 2
	# shellcheck disable=SC2016 # jq variables are supplied via --arg/--argjson
	local label_filter='
		if type != $array or any(.[]; type != $array) then error("invalid history") else flatten end
		| map(select((.event == "labeled" or .event == "unlabeled") and .label.name == $blocked))
		| if any(.[]; (comment_id == null) or (valid_time | not) or
			(.created_at | fromdateiso8601) > $now) then error("invalid event") else . end
		| sort_by(.created_at, .id) | last | select(.event == "labeled")
	'
	label=$(jq -ce --argjson now "$now" --arg blocked "$blocked" --arg array "$array_type" "${order_jq}${label_filter}" <<<"$events") || return 2
	# shellcheck disable=SC2016 # jq variables are supplied via --argjson
	local key_filter='
		select(comment_id != null and ($release | comment_id) != null and ($retry | comment_id) != null)
		| select(($retry.created_at | fromdateiso8601) <= $now)
		| select($retry.created_at > .created_at and $retry.created_at > $release.created_at)
		| {release:$release.id, label:.id, retry:$retry.id}
	'
	key=$(jq -cer --argjson release "$evidence" --argjson retry "$retry" --argjson now "$now" "${order_jq}${key_filter}" <<<"$label") || return 2
	key=$(_terminal_blocker_hash "$key") || return 2
	receipt="<!-- aidevops:terminal-blocker-rearmed key=${key} -->"
	# Permit receipt replay after projection, but never a new release without
	# the label still present. Receipt suppression alone grants no release.
	if ! jq -e --arg blocked "$blocked" 'any(.labels[]; .name == $blocked)' <<<"$issue_json" >/dev/null; then
		jq -e --arg marker "$receipt" 'any(.[]; (.body // "") | split("\n") | index($marker) != null)' <<<"$comments" >/dev/null || return 2
	fi
	_tbr_dependency_unresolved "$repo" "$issue" "$issue_json" legacy legacy && return 3
	printf 'rearm_decision issue=%s observed_rev=legacy current_rev=legacy reason=trusted_retry\n' "$issue" >&2
	_tbr_project_rearm "$repo" "$issue" "$issue_json" "$comments" "$receipt" legacy legacy \
		"$(_tbr_rearm_reason_line trusted_retry legacy legacy)"
	return $?
}

# Unlike the historical dispatch predicate, indeterminate circuit revisions
# are not evidence of inactivity at a write boundary.
# Optional $7: trusted comments. Only with them can an unevidenced permission
# circuit past its backoff window (GH#36232) stop blocking; without them the
# permission request evidence is unknown, so the circuit keeps holding.
_tbr_circuit_blocks_release() {
	local circuit="$1" retry="$2" issue_json="$3" repo="$4" issue="$5" repo_path="$6"
	local comments="${7:-}"
	local parsed="" revision="" fingerprint="" current=""
	local reason=""
	[[ -n "$circuit" ]] || return 1
	parsed=$(printf '%s' "$circuit" | jq -er '.body | capture("<!-- aidevops:terminal-blocker-circuit revision=(?<r>[a-f0-9]{24}) blocker=(?<f>[a-f0-9]{24}) -->") | [.r,.f] | join(" ")') || return 2
	IFS=' ' read -r revision fingerprint <<<"$parsed"
	reason=$(_terminal_blocker_reason "$fingerprint")
	[[ "$reason" != "$_TBC_UNKNOWN" ]] || return 2
	if terminal_blocker_rearms_on_retry_only "$reason"; then
		_terminal_blocker_retry_after "$retry" "$circuit" && return 1
		if [[ "$reason" == "$_TBC_PERMISSION_REQUIRED" && -n "$comments" ]] &&
			terminal_blocker_permission_window_expired "$comments" "$issue_json" "$circuit" >/dev/null; then
			return 1
		fi
		return 0
	fi
	current=$(terminal_blocker_task_revision "$issue_json" "$repo" "$issue" "$repo_path" "$reason") || return 2
	[[ "$revision" == "$current" ]] || return 1
	_terminal_blocker_retry_after "$retry" "$circuit" && return 1
	return 0
}

#######################################
# GH#36126: a re-armed release must respect dispatch's own blocked-by gate.
# The dependency normalizer re-blocks an issue with an open blocker within
# minutes, and a posted rearm receipt would then retire the queue entry for
# good, so nothing releases it once the blocker closes.
# Mirrors stale recovery (_stale_recovery_has_unresolved_blocked_by): native
# relationships first, body markers as fallback, an unavailable native lookup
# counts as blocked. When the dependency library cannot be loaded, keep the
# pre-GH#36126 behaviour (fail open) rather than holding every re-arm.
# Args: repo slug, issue number, issue JSON, observed and current revisions
# Returns: 0 (and logs the decision) while a declared dependency is open or
# unknown; 1 otherwise.
#######################################
_tbr_dependency_unresolved() {
	local repo="$1" issue="$2" issue_json="$3" observed_rev="${4:-unknown}" current_rev="${5:-unknown}"
	local body=""
	# Standalone runs do not load pulse-wrapper-config.sh: mirror its cache
	# defaults so the library's cache reader works under set -u.
	DEP_GRAPH_CACHE_FILE="${DEP_GRAPH_CACHE_FILE:-${HOME}/.aidevops/.agent-workspace/supervisor/dep-graph-cache.json}"
	DEP_GRAPH_CACHE_TTL_SECS="${DEP_GRAPH_CACHE_TTL_SECS:-300}"
	if ! declare -F is_blocked_by_unresolved >/dev/null 2>&1; then
		# shellcheck source=pulse-dep-graph.sh
		source "${_TBR_SCRIPT_DIR}/pulse-dep-graph.sh" >/dev/null 2>&1 || true
	fi
	declare -F is_blocked_by_unresolved >/dev/null 2>&1 || return 1
	body=$(printf '%s' "$issue_json" | jq -r '.body // ""' 2>/dev/null) || body=""
	# The dependency library appends diagnostics to the pulse log, which a
	# standalone CLI run does not define.
	local LOGFILE="${LOGFILE:-/dev/null}"
	is_blocked_by_unresolved "$body" "$repo" "$issue" || return 1
	printf 'rearm_decision issue=%s observed_rev=%s current_rev=%s reason=dependency_blocked\n' \
		"$issue" "$observed_rev" "$current_rev" >&2
	return 0
}

#######################################
# Release a re-armed hold: project status:blocked -> status:available and
# post the public rearm receipt.
# Args: repo slug, issue number, issue JSON, trusted comments JSON
# Returns: 0 released, suppressed or not applicable; 1 no authoritative
# evidence (retire the entry); 2 indeterminate; 3 re-armed but a declared
# blocked-by dependency is unresolved (GH#36126: keep the entry, write nothing).
#######################################
# GH#36457: only protected, metric-bound excerpts from this repository qualify.
# A full quiet pulse window plus fresh positive admission proves local recovery;
# silence alone (an offline/broken plugin) is never evidence of health.
_tbr_lifecycle_recovered() {
	local repo="$1" issue="$2" evidence="$3"
	local metrics="${AIDEVOPS_HEADLESS_METRICS_FILE:-${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl}"
	python3 - "$repo" "$issue" "$evidence" "$metrics" "$TBR_EXCERPT_DIR" \
		"${HOME}/.aidevops/logs/lifecycle-admission" "${TERMINAL_BLOCKER_NOW_EPOCH:-}" \
		"${AIDEVOPS_PULSE_MIN_INTERVAL_S:-90}" <<'PY'
import datetime
import json
import re
import sys
import time
from pathlib import Path

repo, issue, evidence, metrics, excerpts, admissions, clock, window = sys.argv[1:]
try:
    now = int(clock) if clock else int(time.time())
    window = max(90, int(window))
    observed = datetime.datetime.fromisoformat(json.loads(evidence)["created_at"].replace("Z", "+00:00")).timestamp()
    rows = [json.loads(line) for line in Path(metrics).open()]
    rows = [r for r in rows if r.get("repo_slug", "").lower() == repo.lower()
            and str(r.get("issue_number")) == issue and r.get("role") == "worker"]
    latest = max(rows, key=lambda r: r["ts"])
    if latest.get("result") != "blocked" or not 0 <= observed - latest["ts"] <= 3600:
        sys.exit(1)
    path = Path(latest["output_file"])
    if path.parent.resolve() != Path(excerpts).resolve() or path.is_symlink():
        sys.exit(1)
    if not re.fullmatch(r"issue-" + re.escape(issue) + r"-\d{8}T\d{6}Z-\d+\.log", path.name):
        sys.exit(1)
    text = path.read_text()
    # Match an actual failed tool result, not quoted assistant commentary.
    signature = r"^BLOCKED: lifecycle owner admission is unavailable(?: \([A-Za-z0-9_.-]+\))?; no write authorized$"
    refused = False
    for line in text.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        part = event.get("part", {})
        state = part.get("state", {})
        if event.get("type") == "tool_use" and state.get("status") == "error":
            refused |= bool(re.fullmatch(signature, state.get("error", "")))
    if not refused or re.search(r"TERMINAL_BLOCKER_(?:REASON|MISSING_SECRETS)=", text):
        sys.exit(1)
    events = [json.loads(line) for p in Path(admissions).glob("*.jsonl") for line in p.open()]
    if not events or not all(e.get("schema") == 1 and isinstance(e.get("ts"), int) for e in events):
        sys.exit(1)
    boundary = max([e["ts"] / 1000 for e in events if e.get("outcome") == "refused"]
                   or [min(e["ts"] / 1000 for e in events)])
    # Schema-1 observe-only compatibility is a deliberate linked-worktree
    # success path (GH#36430), not ownership. Non-repository/excluded operations
    # cannot prove that linked-worktree tooling has recovered.
    passed = max(e["ts"] / 1000 for e in events if e.get("outcome") == "passed"
                 and e.get("status") in ("admitted", "coverage-gap"))
    if not (boundary <= now - window and boundary < passed <= now and now - passed <= window):
        sys.exit(1)
except (OSError, ValueError, KeyError, TypeError, AttributeError):
    sys.exit(1)
sys.exit(0)
PY
	return $?
}


# Post the keyed receipt and project a decided re-arm.
# The key binds the observed event, destination revision and retry event.
# A public receipt, not runner-local queue retirement, suppresses replay.
# Hash immutable event identity only, not mutable author associations or prose.
# GH#36232: a window release also binds its window index, so each window
# releases at most once; other decisions keep their historical key shape.
# GH#36342: it also binds and records the brief, so a brief revision after a
# spent window releases once more without waiting for the next window.
_tbr_release_decided_hold() {
	local repo="$1" issue="$2" issue_json="$3" comments="$4" evidence="$5" retry="$6"
	local observed_rev="$7" fingerprint="$8" current_rev="$9" decision="${10}" window_index="${11}"
	local receipt_key="" receipt="" brief_rev="" brief_line=""
	if [[ "$decision" == unevidenced_permission_window ]]; then
		brief_rev=$(terminal_blocker_permission_brief_revision "$issue_json") || brief_rev=""
		[[ -z "$brief_rev" ]] || brief_line="<!-- ${_TBC_PERMISSION_BRIEF_MARKER} revision=${brief_rev} -->"
	fi
	receipt_key=$(jq -nc --argjson evidence "$evidence" --argjson retry "$retry" \
		--arg observed "$observed_rev" --arg fingerprint "$fingerprint" --arg current "$current_rev" --arg decision "$decision" \
		--arg window "$window_index" --arg brief "$brief_rev" \
		'{event: ($evidence | {id,created_at}), observed:$observed, fingerprint:$fingerprint, current:$current,
		 retry: (if $decision == "trusted_retry" then ($retry | {id,created_at}) else null end)}
		 + (if $decision == "unevidenced_permission_window" then {window: ($window | tonumber), brief: $brief} else {} end)') || return 2
	receipt_key=$(_terminal_blocker_hash "$receipt_key") || return 2
	receipt="<!-- aidevops:terminal-blocker-rearmed key=${receipt_key} -->"
	_tbr_project_rearm "$repo" "$issue" "$issue_json" "$comments" "$receipt" "$observed_rev" "$current_rev" \
		"$(_tbr_rearm_reason_line "$decision" "$observed_rev" "$current_rev" "$brief_line")"
	return $?
}

# GH#37970: tell the re-armed worker why it was woken, so a brief revision is
# not mistaken for an unchanged body. Informational only: replay suppression
# still matches the keyed marker line, never this line.
# Args: decision observed_rev current_rev [extra_line]. Prints the receipt lines.
_tbr_rearm_reason_line() {
	local decision="$1" observed_rev="$2" current_rev="$3" extra="${4:-}"
	printf '<!-- aidevops:terminal-blocker-rearm-reason reason=%s observed_rev=%s current_rev=%s -->' \
		"$decision" "$observed_rev" "$current_rev"
	[[ -z "$extra" ]] || printf '\n%s' "$extra"
	return 0
}

# GH#40445: has status:blocked been labeled after the keyed receipt comment?
# Returns: 0 yes (a newer hold), 1 no, 2 unreadable history (fail closed).
_tbr_reblocked_after_receipt() {
	local repo="$1" issue="$2" comments="$3" receipt="$4"
	local receipt_at="" events="" verdict=""
	receipt_at=$(printf '%s' "$comments" | jq -r --arg marker "$receipt" '
		[.[] | select((.body // "") | contains($marker)) | .created_at // empty] | min // ""
	' 2>/dev/null) || return 2
	[[ -n "$receipt_at" ]] || return 2
	events=$(gh api "repos/${repo}/issues/${issue}/events?per_page=100" --paginate --slurp 2>/dev/null) || return 2
	local page_type='array' added_event='labeled'
	verdict=$(printf '%s' "$events" | jq -r --arg at "$receipt_at" --arg pt "$page_type" --arg ev "$added_event" '
		if (type == $pt and all(.[]; type == $pt)) | not then "invalid"
		elif any(.[][]; .event == $ev and .label.name == "status:blocked" and (.created_at // "") > $at) then "yes"
		else "no" end' 2>/dev/null) || return 2
	case "$verdict" in
	yes) return 0 ;;
	no) return 1 ;;
	esac
	return 2
}

# Shared idempotent projection for structured and legacy re-arm decisions.
# Optional $8: extra receipt lines (GH#37970 re-arm reason, GH#36342 window
# brief record).
_tbr_project_rearm() {
	local repo="$1" issue="$2" issue_json="$3" comments="$4" receipt="$5"
	local observed_rev="$6" current_rev="$7" extra="${8:-}"
	local receipt_present=false live_issue="" live_comments=""
	local interrupted_jq="${_TBR_INTERRUPTED_RELEASE_JQ:-def interrupted_release: false;}"
	# The caller must still decide the re-arm from authoritative evidence; a
	# receipt suppresses publication, never grants release authority by itself.
	if printf '%s' "$comments" | jq -e --arg marker "$receipt" 'any(.[]; (.body // "") | split("\n") | index($marker) != null)' >/dev/null; then
		printf 'rearm_decision issue=%s observed_rev=%s current_rev=%s reason=already_released\n' "$issue" "$observed_rev" "$current_rev" >&2
		receipt_present=true
		# A receipt may have landed before a failed label projection. Re-read
		# rather than acting on a stale blocked snapshot or retiring its queue.
		live_issue=$(terminal_blocker_fetch_issue "$repo" "$issue") || return 2
		printf '%s' "$live_issue" | jq -e '.state == "open" and (.labels | type == "array")' >/dev/null || return 2
		printf '%s' "$live_issue" | jq -e --arg blocked status:blocked "${_TBR_OTHER_HOLDS_JQ}"'
			[.labels[]?.name] | other_holds($blocked) | length == 0' >/dev/null || return 2
		printf '%s' "$live_issue" | jq -e --arg blocked status:blocked "${interrupted_jq}"'
			[.labels[]?.name] | (index($blocked) != null) or interrupted_release' >/dev/null || return 0
		# GH#40445: the receipt only repairs a projection it interrupted. A
		# status:blocked applied after the receipt is a newer hold (dated
		# external trigger, dependency normalizer); replaying the old receipt
		# would release it again on every pass, flapping the labels.
		local reblocked_rc=0
		_tbr_reblocked_after_receipt "$repo" "$issue" "$comments" "$receipt" || reblocked_rc=$?
		[[ "$reblocked_rc" -ne 0 ]] || {
			printf 'rearm_decision issue=%s observed_rev=%s current_rev=%s reason=reblocked_after_receipt\n' "$issue" "$observed_rev" "$current_rev" >&2
			return 0
		}
		[[ "$reblocked_rc" -eq 1 ]] || return 2
		# Do not clear a newer owner's block with the old receipt. Changed brief
		# or coordination evidence restarts the decision on the next queue pass.
		printf '%s' "$live_issue" | jq -e --argjson old "$issue_json" '
			((.assignees // []) | length == 0) and
			({title,body} == ($old | {title,body}))' >/dev/null || return 2
		live_comments=$(terminal_blocker_fetch_trusted_comments "$issue" "$repo" "${TERMINAL_BLOCKER_SELF_LOGIN:-}") || return 2
		[[ "$(jq -Sc 'sort_by(.id)' <<<"$live_comments")" == "$(jq -Sc 'sort_by(.id)' <<<"$comments")" ]] || return 2
		issue_json="$live_issue"
	fi
	if ! declare -F set_issue_status >/dev/null 2>&1; then
		# shellcheck source=shared-constants.sh
		source "${_TBR_SCRIPT_DIR}/shared-constants.sh" >/dev/null 2>&1 || return 2
	fi
	declare -F set_issue_status >/dev/null 2>&1 || return 2
	if declare -F issue_has_active_brief_hold >/dev/null 2>&1; then
		local held_rc=0
		issue_has_active_brief_hold "$comments" "$(printf '%s' "$issue_json" | jq -r '.body // ""')" || held_rc=$?
		[[ "$held_rc" -ne 1 ]] && return 0
	fi
	# Persist continuation evidence before removing either blocked-owned label.
	# A failed receipt keeps the hold and (return 2) the recovery queue intact.
	if [[ "$receipt_present" == false ]]; then
		_tbr_post_rearm_receipt "$repo" "$issue" "$receipt" "$extra" || return 2
	fi
	# GH#39710: finish a projection cut off after removing status:blocked.
	if printf '%s' "$issue_json" | jq -e --arg blocked status:blocked "${interrupted_jq}"'
		[.labels[]?.name] | (index($blocked) != null) or interrupted_release' >/dev/null; then
		# GH#38360: the re-arm is the trusted retry or revision that the
		# needs-credentials companion asked for, so it leaves with the hold.
		# set_issue_status removes the blocked-owned companions itself.
		local -a release_args=()
		printf '%s' "$issue_json" | jq -e 'any(.labels[]; .name == "needs-credentials")' >/dev/null &&
			release_args+=(--remove-label needs-credentials)
		printf '%s' "$issue_json" | jq -e 'any(.labels[]; .name == "needs-source-access")' >/dev/null &&
			release_args+=(--remove-label needs-source-access)
		# A consolidated spec without auto-dispatch is never dispatched again
		# (_has_consolidated_label); restore it on release. Same label gate as
		# dispatch-dedup-helper.sh release-stale-recovery.
		# shellcheck disable=SC2016 # jq program, not shell
		printf '%s' "$issue_json" | jq -e '
			([.labels[]?.name] as $l
			| ($l | index("consolidated")) != null
			and ($l | index("auto-dispatch")) == null
			and ($l | index("no-auto-dispatch")) == null
			and ($l | index("hold-for-review")) == null
			and ($l | index("parent-task")) == null
			and ((.body // "") | test("(^|\\n)_Supersedes #[0-9]+ (—|-) this issue is the consolidated spec\\._(\\n|$)")))
		' >/dev/null 2>&1 && release_args+=(--add-label auto-dispatch)
		set_issue_status "$issue" "$repo" available ${release_args[@]+"${release_args[@]}"} >/dev/null 2>&1 || return 2
	fi
	return 0
}

# GH#36232: an unevidenced permission hold wakes on its next backoff window
# boundary, which no issue edit records. Returns 0 once that boundary passed.
_tbr_rearm_window_due() {
	local file="$1"
	local rearm_after="" now_epoch="${TERMINAL_BLOCKER_NOW_EPOCH:-}"
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=$(date -u '+%s')
	rearm_after=$(jq -r '.rearm_after // ""' "$file" 2>/dev/null) || return 1
	[[ "$rearm_after" =~ ^[0-9]+$ && "$now_epoch" -ge "$rearm_after" ]]
	return $?
}

# Record the checked snapshot and, for an unevidenced permission hold, its
# next window boundary (removed when no longer applicable). Optional $5
# "decided" (GH#39232): a standing human_decision has no time-based wake, so
# only an issue update (reply, revision, retry) re-reads the entry.
_tbr_stamp_rearm_check() {
	local file="$1" updated_at="$2" comments="$3" brief="$4" decided="${5:-}"
	local next_window=""
	if [[ "$decided" != decided ]]; then
		next_window=$(terminal_blocker_permission_rearm_after "$comments" "$brief" 2>/dev/null) || next_window=""
	fi
	jq --arg at "$updated_at" --arg after "$next_window" '.rearm_checked_updated_at = $at
		| if $after == "" then del(.rearm_after) else .rearm_after = ($after | tonumber) end' "$file" >"${file}.tmp.$$" &&
		mv -f "${file}.tmp.$$" "$file" || return 1
	return 0
}

# Snapshot caching cannot suppress time-based infrastructure recovery.
_tbr_skip_unchanged_entry() {
	local file="$1" updated_at="$2" reason="$3" mode="$4"
	local last_updated_at=""
	[[ "$mode" == rearm && "$reason" != unknown ]] || return 1
	last_updated_at=$(jq -r '.rearm_checked_updated_at // ""' "$file") || return 1
	# Cache the remote snapshot, not wall-clock time: a retry arriving during
	# this check must still be seen next pass. Missing timestamps never skip.
	[[ -n "$updated_at" && -n "$last_updated_at" && ! "$updated_at" > "$last_updated_at" ]] || return 1
	terminal_blocker_rearms_on_revision "$reason" && return 1
	_tbr_rearm_window_due "$file" && return 1
	return 0
}

#######################################
# GH#37978: re-check an open unclassified_hold entry (supervisor pass only).
# No circuit, observation or lifecycle release applies: there is no recorded
# evidence. Retires the entry and its decision once status:blocked is gone,
# another hold label owns the issue, or a terminal-blocker record exists
# (normal intake then owns it). Kept silently while a dependency is open.
# Otherwise prints the usual JSON line with public evidence only. Makes no
# GitHub write. Returns 0 when printed, 1 otherwise, 2 on unreadable evidence.
#######################################
_tbr_check_unclassified_entry() {
	local file="$1" repo="$2" issue="$3" key="$4" issue_json="$5" reason="$6" opened_at="$7"
	local comments="" rc=0
	_tbr_unclassified_labels_ok "$issue_json" || rc=$?
	[[ "$rc" -lt 2 ]] || return 2
	if [[ "$rc" -eq 1 ]]; then
		rm -f "$file" "${TBR_ROOT}/decisions/${key}.json"
		return 1
	fi
	printf 'blocker-recovery: checking stage=entry_comments repo=%s issue=%s\n' "$repo" "$issue" >&2
	comments=$(terminal_blocker_fetch_comments "$repo" "$issue") || return 2
	rc=0
	_tbr_has_blocker_record "$comments" || rc=$?
	[[ "$rc" -lt 2 ]] || return 2
	if [[ "$rc" -eq 0 ]]; then
		rm -f "$file" "${TBR_ROOT}/decisions/${key}.json"
		return 1
	fi
	_tbr_dependency_unresolved "$repo" "$issue" "$issue_json" unclassified unclassified && return 1
	_tbr_decision_active "$key" "$comments" && return 1
	_tbr_print_entry "$repo" "$issue" "$reason" "$opened_at" unclassified_hold "$issue_json"
	return $?
}

# Print one supervisor JSON line. Only local intake carries excerpts: another
# runner's circuit or observation (policy_remote, remote_observation), an
# unclassified hold and a hold-for-review intake use public issue/PR evidence
# only, because same-number excerpts on this runner belong to a different
# attempt or repository. Optional $7: extra JSON fields (GH#38311 reply id).
_tbr_print_entry() {
	local repo="$1" issue="$2" reason="$3" opened_at="$4" intake="$5" issue_json="$6" extra="${7:-}"
	local excerpts="[]"
	[[ -n "$extra" ]] || extra='{}'
	if [[ "$intake" == local ]]; then
		excerpts=$(find "$TBR_EXCERPT_DIR" -maxdepth 1 -type f -name "*-${issue}-*.log" 2>/dev/null | sort | tail -3 |
			jq -R . | jq -sc .) || excerpts="[]"
	fi
	jq -nc --arg repo "$repo" --argjson issue "$issue" --arg reason "$reason" \
		--arg opened_at "$opened_at" --arg title "$(printf '%s' "$issue_json" | jq -r '.title // ""')" \
		--argjson excerpts "${excerpts:-[]}" --arg intake "$intake" --argjson extra "$extra" \
		'{repo:$repo, issue:$issue, title:$title, reason:$reason, opened_at:$opened_at, intake:$intake, local_excerpts:$excerpts} + $extra'
	return 0
}

#######################################
# GH#35129: cross-runner intake exists only while repo policy enables it.
# Returns 0 to continue, 1 after retiring a disabled entry, 2 when the
# policy is unreadable (keep the entry for the next pass).
# Args: file repo issue key
#######################################
_tbr_check_entry_policy() {
	local file="$1" repo="$2" issue="$3" key="$4"
	local policy_rc=0
	printf 'blocker-recovery: checking stage=entry_policy repo=%s issue=%s\n' "$repo" "$issue" >&2
	_tbr_policy_enabled "$repo" || policy_rc=$?
	[[ "$policy_rc" -lt 2 ]] || return 2
	if [[ "$policy_rc" -eq 1 ]]; then
		rm -f "$file" "${TBR_ROOT}/decisions/${key}.json"
		return 1
	fi
	return 0
}

# GH#38692: true when a recorded human_decision still stands locally (no network
# read). Such entries are scanned after every undecided entry so they cannot
# starve the queue budget; a reply or policy change still wakes them when reached.
_tbr_entry_decided() {
	local file="$1"
	local repo issue key
	repo=$(jq -r '.repo // ""' "$file" 2>/dev/null) || return 1
	issue=$(jq -r '.issue // ""' "$file" 2>/dev/null) || return 1
	[[ -n "$repo" && -n "$issue" ]] || return 1
	key=$(_tbr_key "$repo" "$issue")
	[[ -f "${TBR_ROOT}/decisions/${key}.json" ]] || return 1
	[[ "$(jq -r '.wake // ""' "${TBR_ROOT}/decisions/${key}.json" 2>/dev/null)" =~ ^(human_decision|external_trigger)$ ]] || return 1
	return 0
}
