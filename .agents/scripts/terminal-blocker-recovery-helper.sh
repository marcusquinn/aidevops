#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# =============================================================================
# terminal-blocker-recovery-helper.sh — runner-local AI owner intake for
# terminal-blocker circuits (t18514, GH#32754).
#
# A repeated known worker blocker opens TERMINAL_BLOCKER_CIRCUIT on the issue.
# The circuit correctly stops redispatch, but nothing owned the follow-up: the
# issue stayed status:available until a human noticed. This helper keeps a
# private queue of circuits opened by THIS runner (where the protected failure
# excerpts live) so the pulse supervisor can act as the AI brief owner.
# GH#34846: it also queues held first observations of classes that re-arm on
# a brief/dependency revision, and returns them to status:available once the
# revision changes or a trusted retry lands.
# GH#35129: when the repo's pinned recovery policy enables an action, seed
# also queues OWNER/MEMBER circuits opened by other runners (intake
# policy_remote, public evidence only, no local excerpts).
# GH#36114: rearm first runs an incremental owner-scoped discovery of held
# issues, so trusted retries on holds this runner never queued still apply.
# Holds carrying only another runner's observation are queued with intake
# remote_observation: public evidence only, because local excerpts are named
# by issue number alone and may belong to another repository.
#
# Queue records are evidence, never authority. Its only issue write is the
# re-armed status:blocked → status:available release (GH#33138); it never
# edits bodies, posts retry directives, changes assignees or grants
# permissions. The supervisor applies reference/worker-discipline.md
# "Terminal-blocker recovery".
#
# Usage:
#   terminal-blocker-recovery-helper.sh enqueue <owner/repo> <issue> [reason] [local|policy_remote|remote_observation]
#   terminal-blocker-recovery-helper.sh seed [--force]
#   terminal-blocker-recovery-helper.sh pending [--count]
#   terminal-blocker-recovery-helper.sh rearm   # discovery + queued holds; no LLM work or seed
#   terminal-blocker-recovery-helper.sh discover   # discovery stage only
#   terminal-blocker-recovery-helper.sh record <owner/repo> <issue>   # JSON on stdin
#
# Env:
#   AIDEVOPS_BLOCKER_RECOVERY_DIR   queue root (default ~/.aidevops/.agent-workspace/terminal-blocker-recovery)
#   BLOCKER_RECOVERY_SEED_INTERVAL  seconds between automatic seeds (default 21600)
#   BLOCKER_RECOVERY_DECISION_TTL   seconds a recorded decision suppresses re-assessment (default 86400)
#   BLOCKER_RECOVERY_BUDGET_SECONDS overall pending/seed budget (default 45)
#   BLOCKER_RECOVERY_STAGE_SECONDS identity/seed budget (default 8); entries use
#                                 the remaining queue budget, rotating on timeout
#   BLOCKER_RECOVERY_DISCOVERY_SECONDS discovery cap (default 15, at most half
#                                 the budget so the queue pass keeps its share)
#   BLOCKER_RECOVERY_DISCOVERY_OVERLAP seconds re-searched before the last
#                                 complete discovery, for search-index lag (default 900)
# Incomplete observations return 2 and a diagnostic on stderr; stdout remains
# JSONL (or a partial count). Retry resumes after the last attempted entry.
# =============================================================================

[[ "${BASH_SOURCE[0]}" == "$0" ]] && set -euo pipefail
_TBR_SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_TBR_SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && _TBR_SCRIPT_DIR="."

# shellcheck source=terminal-blocker-github.sh
source "${_TBR_SCRIPT_DIR}/terminal-blocker-github.sh"

TBR_ROOT="${AIDEVOPS_BLOCKER_RECOVERY_DIR:-${HOME}/.aidevops/.agent-workspace/terminal-blocker-recovery}"
TBR_SEED_INTERVAL="${BLOCKER_RECOVERY_SEED_INTERVAL:-21600}"
TBR_DECISION_TTL="${BLOCKER_RECOVERY_DECISION_TTL:-86400}"
TBR_REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
TBR_EXCERPT_DIR="${AIDEVOPS_WORKER_FAILURE_EXCERPT_DIR:-${HOME}/.aidevops/logs/worker-failure-excerpts}"
TBR_CIRCUIT_MARKER="TERMINAL_BLOCKER_CIRCUIT active=true"
TBR_BUDGET_SECONDS="${BLOCKER_RECOVERY_BUDGET_SECONDS:-45}"
TBR_STAGE_SECONDS="${BLOCKER_RECOVERY_STAGE_SECONDS:-8}"
TBR_DISCOVERY_SECONDS="${BLOCKER_RECOVERY_DISCOVERY_SECONDS:-15}"
TBR_DISCOVERY_OVERLAP="${BLOCKER_RECOVERY_DISCOVERY_OVERLAP:-900}"
# Evaluated-issue memory older than this is pruned after a complete pass.
TBR_DISCOVERY_RETENTION_DAYS=30

_tbr_start_budget() {
	[[ "$TBR_BUDGET_SECONDS" =~ ^[1-9][0-9]*$ && "$TBR_STAGE_SECONDS" =~ ^[1-9][0-9]*$ ]] || return 2
	[[ "$TBR_DISCOVERY_SECONDS" =~ ^[1-9][0-9]*$ ]] || return 2
	TBR_DEADLINE="${TBR_DEADLINE:-$((SECONDS + TBR_BUDGET_SECONDS))}"
	# shellcheck source=shared-constants.sh
	declare -F timeout_sec >/dev/null || source "${_TBR_SCRIPT_DIR}/shared-constants.sh"
	return 0
}

# Bound whole stages, including paginated reads and nested revision helpers.
# A timeout is never evidence that a hold resolved or a policy was withdrawn.
_tbr_run_stage() {
	local stage="$1" action="$2"
	shift 2
	local remaining=$((TBR_DEADLINE - SECONDS)) rc=0
	if [[ "$stage" != seed && -n "${TBR_QUEUE_DEADLINE:-}" ]]; then
		remaining=$((TBR_QUEUE_DEADLINE - SECONDS))
	fi
	[[ "$remaining" -gt 0 ]] || {
		printf 'blocker-recovery: incomplete stage=%s reason=budget_exhausted\n' "$stage" >&2
		return 2
	}
	# An entry includes several GitHub reads and revision checks. Capping that
	# entire transaction at eight seconds repeatedly loses all partial work.
	# Keep the overall deadline and saved cursor, but let an entry finish within
	# the queue's share; discovery still has its separate reserved stage cap.
	local cap="$TBR_STAGE_SECONDS"
	if [[ "$stage" == discovery ]]; then
		# GH#36114: never more than half the budget, so the queue pass can
		# apply what discovery finds in the same run.
		cap="$TBR_DISCOVERY_SECONDS"
		[[ "$cap" -le $((TBR_BUDGET_SECONDS / 2)) ]] || cap=$((TBR_BUDGET_SECONDS / 2))
		[[ "$cap" -ge 1 ]] || cap=1
	fi
	if [[ "$stage" != entry && "$remaining" -gt "$cap" ]]; then
		remaining="$cap"
	fi
	printf 'blocker-recovery: checking stage=%s\n' "$stage" >&2
	(
		export AIDEVOPS_BLOCKER_RECOVERY_DIR="$TBR_ROOT" REPOS_JSON="$TBR_REPOS_JSON"
		export AIDEVOPS_WORKER_FAILURE_EXCERPT_DIR="$TBR_EXCERPT_DIR"
		export BLOCKER_RECOVERY_SEED_INTERVAL="$TBR_SEED_INTERVAL" BLOCKER_RECOVERY_DECISION_TTL="$TBR_DECISION_TTL"
		export BLOCKER_RECOVERY_DISCOVERY_OVERLAP="$TBR_DISCOVERY_OVERLAP"
		timeout_sec "$remaining" bash "${_TBR_SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" _stage "$action" "$@"
	) || rc=$?
	case "$rc" in
	0) return 0 ;;
	1)
		[[ "$stage" == entry ]] && return 1
		printf 'blocker-recovery: incomplete stage=%s rc=1\n' "$stage" >&2
		return 2
		;;
	*)
		printf 'blocker-recovery: incomplete stage=%s rc=%s\n' "$stage" "$rc" >&2
		return 2
		;;
	esac
}

_tbr_rotate() {
	local lines="$1" cursor="$2"
	printf '%s\n' "$lines" | jq -Rnr --arg cursor "$cursor" '
		[inputs | select(length > 0)] | unique |
		(map(select(. > $cursor)) + map(select(. <= $cursor)))[]' || return 1
	return 0
}

_tbr_save_cursor() {
	local name="$1" value="$2"
	printf '%s\n' "$value" >"${TBR_ROOT}/${name}.tmp.$$" || return 1
	mv -f "${TBR_ROOT}/${name}.tmp.$$" "${TBR_ROOT}/${name}" || return 1
	return 0
}

_tbr_valid_ref() {
	local repo="$1"
	local issue="$2"
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
	return 0
}

_tbr_registered_repo() {
	local repo="$1" rc=0
	jq -e --arg slug "$repo" '.initialized_repos | arrays | any(.[]; .slug == $slug)' \
		"$TBR_REPOS_JSON" >/dev/null 2>&1 || rc=$?
	# Missing/unreadable registry is not evidence that a repo was removed.
	[[ "$rc" -le 1 ]] || return 2
	return "$rc"
}

_tbr_entry_registered() {
	local file="$1" rc=0
	local repo=""
	local issue=""
	repo=$(jq -r '.repo // ""' "$file" 2>/dev/null) || return 2
	issue=$(jq -r '.issue // ""' "$file" 2>/dev/null) || return 2
	_tbr_valid_ref "$repo" "$issue" || { rm -f "$file"; return 1; }
	_tbr_registered_repo "$repo" || rc=$?
	[[ "$rc" -ne 2 ]] || return 2
	if [[ "$rc" -eq 1 ]]; then
		rm -f "$file" "${TBR_ROOT}/decisions/$(_tbr_key "$repo" "$issue").json"
		return 1
	fi
	return 0
}

_tbr_key() {
	local repo="$1"
	local issue="$2"
	printf '%s--%s\n' "${repo//\//--}" "$issue"
	return 0
}

_tbr_init_dirs() {
	mkdir -p "${TBR_ROOT}/queue" "${TBR_ROOT}/decisions" || return 1
	chmod 700 "$TBR_ROOT" 2>/dev/null || true
	return 0
}

_tbr_self_login() {
	local login="${WORKER_GITHUB_LOGIN:-${AIDEVOPS_WORKER_GITHUB_LOGIN:-}}"
	if [[ -z "$login" ]]; then
		login=$(gh api user --jq '.login' 2>/dev/null) || {
			login=$(gh api graphql -f query='{viewer{login}}' --jq 'select((.errors // [] | length) == 0) | .data.viewer.login' 2>/dev/null) || login=""
		}
	fi
	[[ "$login" =~ ^[A-Za-z0-9-]+$ ]] || return 1
	printf '%s\n' "$login"
	return 0
}

_tbr_repo_path() {
	local repo="$1"
	[[ -f "$TBR_REPOS_JSON" ]] || return 0
	jq -r --arg slug "$repo" \
		'[.initialized_repos[]? | select(.slug == $slug) | .path] | first // ""' \
		"$TBR_REPOS_JSON" 2>/dev/null | sed "s|^~|${HOME}|"
	return 0
}

#######################################
# Add or refresh one queue entry. Idempotent per repo+issue.
#######################################
tbr_enqueue() {
	local repo="${1:-}"
	local issue="${2:-}"
	local reason="${3:-unknown}"
	# GH#35129: `policy_remote` marks a circuit another runner opened, queued
	# only under repo-delegated recovery policy; its evidence is public-only.
	# GH#36114: `remote_observation` marks another runner's held observation;
	# also public-only, but not tied to repo policy.
	local intake="${4:-local}"
	_tbr_valid_ref "$repo" "$issue" || return 1
	_tbr_registered_repo "$repo" || return $?
	[[ "$reason" =~ ^[a-z_]+$ ]] || reason="unknown"
	[[ "$intake" == policy_remote || "$intake" == remote_observation ]] || intake="local"
	_tbr_init_dirs || return 1
	local file="" tmp=""
	file="${TBR_ROOT}/queue/$(_tbr_key "$repo" "$issue").json"
	tmp="${file}.tmp.$$"
	jq -nc --arg repo "$repo" --argjson issue "$issue" --arg reason "$reason" \
		--arg opened_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg intake "$intake" \
		'{repo:$repo, issue:$issue, reason:$reason, opened_at:$opened_at, intake:$intake}' >"$tmp" || {
		rm -f "$tmp"
		return 1
	}
	mv -f "$tmp" "$file" || return 1
	return 0
}

#######################################
# Backfill open circuits authored by this runner (GitHub search on the
# circuit marker) and, GH#34846, held first observations of revision-re-armed
# classes (status:blocked issues with a recovery observation). Rate-limited by
# TBR_SEED_INTERVAL unless --force.
#######################################
tbr_seed() {
	local force="${1:-}"
	_tbr_init_dirs || return 1
	local stamp="${TBR_ROOT}/last_seed_epoch" now last=0
	now=$(date +%s)
	[[ -f "$stamp" ]] && read -r last <"$stamp"
	[[ "$last" =~ ^[0-9]+$ ]] || last=0
	if [[ "$force" != "--force" && $((now - last)) -lt "$TBR_SEED_INTERVAL" ]]; then
		return 0
	fi
	local self="" slug="" issue="" policy_enabled="" candidates="" incomplete=0 policy_rc=0
	local repos="" repo_cursor="" issue_cursor="" cursor_name=""
	repos=$(_tbr_pulse_repos) || return 2
	[[ ! -f "${TBR_ROOT}/seed_repo_cursor" ]] || read -r repo_cursor <"${TBR_ROOT}/seed_repo_cursor" || true
	repos=$(_tbr_rotate "$repos" "$repo_cursor") || return 2
	printf 'blocker-recovery: checking stage=seed_identity\n' >&2
	self=$(_tbr_self_login) || return 1
	# shellcheck source=terminal-blocker-circuit.sh
	source "${_TBR_SCRIPT_DIR}/terminal-blocker-circuit.sh" || return 1
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		_tbr_valid_ref "$slug" 1 || {
			incomplete=1
			continue
		}
		_tbr_save_cursor seed_repo_cursor "$slug" || return 2
		printf 'blocker-recovery: checking stage=seed_policy repo=%s\n' "$slug" >&2
		policy_enabled=false
		policy_rc=0
		_tbr_policy_enabled "$slug" && policy_enabled=true || policy_rc=$?
		[[ "$policy_rc" -lt 2 ]] || incomplete=1
		printf 'blocker-recovery: checking stage=seed_candidates repo=%s\n' "$slug" >&2
		candidates=$(_tbr_seed_candidates "$slug") || {
			incomplete=1
			continue
		}
		cursor_name="seed-${slug//\//--}.cursor"
		issue_cursor=""
		[[ ! -f "${TBR_ROOT}/${cursor_name}" ]] || read -r issue_cursor <"${TBR_ROOT}/${cursor_name}" || true
		candidates=$(_tbr_rotate "$candidates" "$issue_cursor") || return 2
		while IFS= read -r issue; do
			[[ "$issue" =~ ^[0-9]+$ ]] || continue
			_tbr_save_cursor "$cursor_name" "$issue" || return 2
			printf 'blocker-recovery: checking stage=seed_comments repo=%s issue=%s\n' "$slug" "$issue" >&2
			_tbr_intake_issue "$slug" "$issue" "$self" "$policy_enabled" || incomplete=1
		done <<<"$candidates"
		rm -f "${TBR_ROOT}/${cursor_name}"
	done <<<"$repos"
	[[ "$incomplete" -eq 0 ]] || return 2
	rm -f "${TBR_ROOT}/seed_repo_cursor"
	printf '%s\n' "$now" >"$stamp"
	return 0
}

# Candidate issue numbers for one repo: open circuits, plus open blocked
# issues carrying a terminal-blocker observation. Deduplicated.
_tbr_seed_candidates() {
	local slug="$1"
	local query="" result="" numbers=""
	for query in "\"TERMINAL_BLOCKER_CIRCUIT\" in:comments" \
		"label:\"status:blocked\" \"Terminal blocker\" in:comments" \
		'label:"status:blocked" "CLAIM_RELEASED reason=blocked" in:comments'; do
		result=$(terminal_blocker_search_issues "repo:${slug} is:issue is:open ${query}") || return 2
		numbers+="${result}"$'\n'
	done
	printf '%s' "$numbers" | sort -un
	return 0
}

# Pulse-enabled remote registry slugs: the only repos seed or discovery touch.
_tbr_pulse_repos() {
	jq -r 'if (.initialized_repos | type) != "array" then error("invalid registry") else
		.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and (.slug // "") != "") | .slug end' \
		"$TBR_REPOS_JSON" 2>/dev/null || return 2
	return 0
}

# Queue one candidate when this runner owns its recovery. Seed and discovery
# share these trust and eligibility rules. Returns 0 when queued or not
# eligible, 2 when the evidence could not be read or the entry not written.
_tbr_intake_issue() {
	local slug="$1"
	local issue="$2"
	local self="$3"
	local policy_enabled="$4"
	local comments="" reason="" intake=local
	comments=$(terminal_blocker_fetch_comments "$slug" "$issue") || return 2
	reason=$(_tbr_seed_reason "$comments" "$self" "$policy_enabled") || return 0
	if _tbr_has_own_circuit "$comments" "$self"; then
		intake=local
	elif [[ "$policy_enabled" == true ]] && _tbr_has_foreign_circuit "$comments" "$self"; then
		intake=policy_remote
	elif ! _tbr_has_own_observation "$comments" "$self"; then
		intake=remote_observation
	fi
	tbr_enqueue "$slug" "$issue" "$reason" "$intake" || return 2
	return 0
}

# GH#36114: true when this runner's own login posted a hold observation, so
# its local excerpts can belong to this issue. Fails closed (no excerpts).
_tbr_has_own_observation() {
	local comments="$1"
	local self="$2"
	local marker="${_TBC_OBSERVATION_MARKER:-} revision="
	[[ -n "${_TBC_OBSERVATION_MARKER:-}" ]] || return 1
	printf '%s' "$comments" | jq -e --arg self "$self" --arg marker "$marker" '
		[flatten[] | select((.user.login // "") == $self and ((.body // "") | contains($marker)))] | length > 0
	' >/dev/null 2>&1 || return 1
	return 0
}

# Registry slug for a search hit, matched case-insensitively. Input lines are
# "owner/repo<TAB>number<TAB>updated_at"; output keeps registry spelling, drops
# unregistered or malformed refs, and is sorted and unique.
_tbr_discovery_candidates() {
	local refs="$1"
	local repos="$2"
	printf '%s' "$refs" | jq -Rnr --arg repos "$repos" '
		($repos | split("\n") | map(select(length > 0) | {key: ascii_downcase, value: .}) | from_entries) as $registry |
		[inputs | split("\t") | select(length == 3) |
			{slug: $registry[.[0] | ascii_downcase], issue: .[1], updated: .[2]} |
			select(.slug != null and (.issue | test("^[1-9][0-9]*$")) and (.updated | length > 0)) |
			"\(.slug)\t\(.issue)\t\(.updated)"] | unique[]' || return 2
	return 0
}

#######################################
# GH#36114: incremental owner-scoped intake for the mechanical rearm cadence.
# The per-repo seed needs two searches per pulse repo and rarely completes in
# its stage cap, so held observations from other runners were never queued
# and trusted retries on them were never applied. Discovery searches held
# issues once per group of five owners (updated since the last complete pass,
# minus an overlap for search-index lag) and queues unqueued ones under the
# seed's trust and eligibility rules. Each evaluated issue is remembered with
# its updated_at, so an interrupted pass resumes without repeating reads and
# an unchanged issue is not re-queued after the queue retires it. Only a
# complete pass advances the window. Queue entries remain evidence only.
#######################################
tbr_discover() {
	_tbr_init_dirs || return 1
	mkdir -p "${TBR_ROOT}/discovered" || return 1
	local stamp="${TBR_ROOT}/last_discovery_epoch" now="" last=0 window="" since=""
	local repos="" owners="" line="" owner="" group="" refs="" result="" candidates="" cursor=""
	local issue="" repo="" updated="" seen="" self="" policy_enabled="" policy_rc=0 incomplete=0
	local key=""
	local -a owner_list=()
	[[ "$TBR_DISCOVERY_OVERLAP" =~ ^[0-9]+$ ]] || return 2
	now=$(date +%s)
	[[ ! -f "$stamp" ]] || read -r last <"$stamp" || true
	[[ "$last" =~ ^[0-9]+$ ]] || last=0
	# No stamp: search without a window so the first complete pass backfills.
	if [[ "$last" -gt "$TBR_DISCOVERY_OVERLAP" ]]; then
		since=$(jq -nr --argjson t "$((last - TBR_DISCOVERY_OVERLAP))" '$t | strftime("%Y-%m-%dT%H:%M:%S+00:00")') || return 2
		window=" updated:>=${since}"
	fi
	repos=$(_tbr_pulse_repos) || return 2
	owners=$(printf '%s\n' "$repos" | sed -n 's|^\([A-Za-z0-9_.-][A-Za-z0-9_.-]*\)/.*$|\1|p' | sort -fu)
	while IFS= read -r line; do
		[[ -n "${line// /}" ]] || continue
		read -ra owner_list <<<"$line"
		group=""
		for owner in "${owner_list[@]}"; do
			group+=" user:${owner}"
		done
		printf 'blocker-recovery: checking stage=discovery_search owners=%s\n' "${group# }" >&2
		# A failed group is incomplete, never absence: keep the window and
		# still queue what the other groups found.
		result=$(terminal_blocker_search_issue_refs \
			"is:issue is:open label:\"status:blocked\" \"Terminal blocker\" in:comments${window}${group}") || {
			incomplete=1
			continue
		}
		refs+="${result}"$'\n'
	done < <(printf '%s\n' "$owners" | paste -d' ' - - - - -)
	candidates=$(_tbr_discovery_candidates "$refs" "$repos") || return 2
	[[ ! -f "${TBR_ROOT}/discovery_cursor" ]] || read -r cursor <"${TBR_ROOT}/discovery_cursor" || true
	candidates=$(_tbr_rotate "$candidates" "$cursor") || return 2
	# shellcheck source=terminal-blocker-circuit.sh
	source "${_TBR_SCRIPT_DIR}/terminal-blocker-circuit.sh" || return 1
	while IFS=$'\t' read -r repo issue updated; do
		_tbr_valid_ref "$repo" "$issue" || continue
		key=$(_tbr_key "$repo" "$issue")
		# Already queued: the queue pass owns it. Unchanged since evaluated: skip.
		[[ ! -f "${TBR_ROOT}/queue/${key}.json" ]] || continue
		seen=""
		[[ ! -f "${TBR_ROOT}/discovered/${key}" ]] || read -r seen <"${TBR_ROOT}/discovered/${key}" || true
		[[ "$seen" != "$updated" ]] || continue
		_tbr_save_cursor discovery_cursor "$(printf '%s\t%s\t%s' "$repo" "$issue" "$updated")" || return 2
		if [[ -z "$self" ]]; then
			self="${TERMINAL_BLOCKER_SELF_LOGIN:-}"
			[[ -n "$self" ]] || self=$(_tbr_self_login) || return 1
		fi
		policy_enabled=false
		policy_rc=0
		_tbr_policy_enabled "$repo" && policy_enabled=true || policy_rc=$?
		[[ "$policy_rc" -lt 2 ]] || incomplete=1
		printf 'blocker-recovery: checking stage=discovery_comments repo=%s issue=%s\n' "$repo" "$issue" >&2
		_tbr_intake_issue "$repo" "$issue" "$self" "$policy_enabled" || {
			incomplete=1
			continue
		}
		# An unreadable policy may have hidden eligibility; evaluate it again.
		[[ "$policy_rc" -ge 2 ]] || _tbr_save_cursor "discovered/${key}" "$updated" || return 2
	done <<<"$candidates"
	[[ "$incomplete" -eq 0 ]] || return 2
	rm -f "${TBR_ROOT}/discovery_cursor"
	find "${TBR_ROOT}/discovered" -type f -mtime +"$TBR_DISCOVERY_RETENTION_DAYS" -delete 2>/dev/null || true
	_tbr_save_cursor last_discovery_epoch "$now" || return 2
	return 0
}

# Print the queue reason when this runner owns recovery for the issue: a
# circuit it opened, or (GH#34846) its newest observation of a class that
# re-arms on a revision (or, GH#35095, target_code_blocker). Circuits seed only
# for the runner that opened them; observations seed from any trusted runner.
# Returns 1 when not eligible.
_tbr_seed_reason() {
	local comments="$1"
	local self="$2"
	local policy_enabled="${3:-false}"
	local reason=""
	if _tbr_has_own_circuit "$comments" "$self"; then
		_tbr_reason_from_comments "$comments"
		return 0
	fi
	# GH#35129: with an enabled repo recovery policy, a circuit another runner
	# opened is queued here too, so an offline runner cannot strand it.
	if [[ "$policy_enabled" == true ]] && _tbr_has_foreign_circuit "$comments" "$self"; then
		_tbr_reason_from_comments "$(printf '%s' "$comments" | jq -c '[flatten[] |
			select((.author_association // "") | IN("OWNER", "MEMBER"))]')"
		return 0
	fi
	# GH#35095: the release decision needs only public markers plus the task
	# revision, so any runner's observation seeds re-arm evaluation (an offline
	# observing runner must not strand the hold). #aidevops:trust-boundary
	# Other logins count only as OWNER/MEMBER/COLLABORATOR; own login always.
	reason=$(printf '%s' "$comments" | jq -r --arg self "$self" '
		[flatten[] | select((.user.login // "") == $self or
			((.author_association // "") | . == "OWNER" or . == "MEMBER" or . == "COLLABORATOR"))
		| (.body // "")
		| select(contains("aidevops:terminal-blocker-observation revision="))
		| capture("Terminal blocker: reason=(?<r>[a-z_]+) ")? | .r] | last // ""
	' 2>/dev/null) || reason=""
	if [[ -z "$reason" && -n "$(_tbr_latest_legacy_release "$comments" "$self")" ]]; then
		printf 'unknown\n'
		return 0
	fi
	terminal_blocker_observation_recoverable "$reason" || return 1
	printf '%s\n' "$reason"
	return 0
}

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

# GH#35129: true only when the repo's pinned default-branch recovery policy
# loads and enables at least one action for this authenticated writer.
# Cached per process so one pending/seed pass loads each repo once.
_TBR_POLICY_CACHE=""
_tbr_policy_enabled() {
	local repo="$1"
	case ";${_TBR_POLICY_CACHE};" in
	*";${repo}=1;"*) return 0 ;;
	*";${repo}=0;"*) return 1 ;;
	esac
	local enabled=0 policy="" rc=0
	policy=$(bash "${_TBR_SCRIPT_DIR}/recovery-policy-helper.sh" "$repo" 2>/dev/null) || rc=$?
	# Absence (3) is authoritative; failed observation is not withdrawal.
	[[ "$rc" -eq 0 || "$rc" -eq 3 ]] || return 2
	if [[ "$rc" -eq 0 ]] && printf '%s' "$policy" | jq -e '.actions | length > 0' >/dev/null 2>&1; then
		enabled=1
	fi
	_TBR_POLICY_CACHE="${_TBR_POLICY_CACHE};${repo}=${enabled}"
	[[ "$enabled" -eq 1 ]] || return 1
	return 0
}

_tbr_decision_active() {
	local key="$1"
	local file="${TBR_ROOT}/decisions/${key}.json"
	[[ -f "$file" ]] || return 1
	local ts="" now=""
	ts=$(jq -r '.recorded_epoch // 0' "$file" 2>/dev/null) || ts=0
	[[ "$ts" =~ ^[0-9]+$ ]] || ts=0
	now=$(date +%s)
	[[ $((now - ts)) -lt "$TBR_DECISION_TTL" ]] || return 1
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
# or writes, so the queue entry survives for a later verified pass.
#######################################
_tbr_post_rearm_receipt() {
	local repo="$1"
	local issue="$2"
	local marker="$3"
	printf '%s\n' "$marker" | bash "${_TBR_SCRIPT_DIR}/gh-write-helper.sh" issue comment "$issue" \
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
	_tbr_project_rearm "$repo" "$issue" "$issue_json" "$comments" "$receipt" legacy legacy
	return $?
}

# Unlike the historical dispatch predicate, indeterminate circuit revisions
# are not evidence of inactivity at a write boundary.
_tbr_circuit_blocks_release() {
	local circuit="$1" retry="$2" issue_json="$3" repo="$4" issue="$5" repo_path="$6"
	local parsed="" revision="" fingerprint="" current=""
	local reason=""
	[[ -n "$circuit" ]] || return 1
	parsed=$(printf '%s' "$circuit" | jq -er '.body | capture("<!-- aidevops:terminal-blocker-circuit revision=(?<r>[a-f0-9]{24}) blocker=(?<f>[a-f0-9]{24}) -->") | [.r,.f] | join(" ")') || return 2
	IFS=' ' read -r revision fingerprint <<<"$parsed"
	reason=$(_terminal_blocker_reason "$fingerprint")
	[[ "$reason" != "$_TBC_UNKNOWN" ]] || return 2
	if terminal_blocker_rearms_on_retry_only "$reason"; then
		_terminal_blocker_retry_after "$retry" "$circuit" && return 1
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
_tbr_release_circuit_hold() {
	local repo="$1"
	local issue="$2"
	local issue_json="$3"
	local comments="$4"
	local labels=""
	local blocked_status="status:blocked"
	labels=$(printf '%s' "$issue_json" | jq -ce '.labels | select(type == "array") | map(.name)' 2>/dev/null) || return 2
	printf '%s' "$labels" | jq -e --arg blocked "$blocked_status" '
		((index($blocked) != null) or (index("status:available") != null)) and
		([.[] | select(. == "needs-maintainer-permissions" or . == "hold-for-review" or
			. == "no-auto-dispatch" or . == "parent-task" or . == "needs-maintainer-review" or
			startswith("status:") and . != $blocked and . != "status:available")] | length == 0)
	' >/dev/null 2>&1 || return 0
	# GH#35540: absence of an applicable hold is NOT positive re-arm evidence.
	# In particular, intake can see a foreign COLLABORATOR observation which
	# the authoritative hold selectors deliberately ignore. Never release it.
	local observation="" circuit="" evidence="" parsed="" observed_rev="" fingerprint=""
	local current_rev="" retry="" decision="" receipt="" receipt_key="" repo_path=""
	local reason=""
	observation=$(_terminal_blocker_latest_marker "$comments" "$_TBC_OBSERVATION_MARKER revision=") || return 2
	circuit=$(_terminal_blocker_latest_marker "$comments" "$_TBC_CIRCUIT_MARKER revision=") || return 2
	evidence=$(jq -nc --argjson observation "${observation:-null}" --argjson circuit "${circuit:-null}" \
		"${_TBC_ORDER_JQ}"'[ $observation, $circuit ] | map(select(. != null)) |
		sort_by(.created_at, (comment_id // 9007199254740992), .body) | last // empty') || return 2
	if [[ -z "$evidence" ]]; then
		evidence=$(_tbr_latest_legacy_release "$comments" "$(_terminal_blocker_self_login)") || return 2
		if [[ -n "$evidence" ]]; then
			_tbr_release_legacy_hold "$repo" "$issue" "$issue_json" "$comments" "$evidence"
			return $?
		fi
	fi
	[[ -n "$evidence" ]] || {
		# GH#35569: retire unverifiable intake, never project availability.
		# Missing evidence is final for this entry, not a transient API failure.
		printf 'rearm_decision issue=%s observed_rev=unknown current_rev=unknown reason=no_authoritative_evidence action=retire_entry\n' "$issue" >&2
		return 1
	}
	parsed=$(printf '%s' "$evidence" | jq -er '.body | capture("<!-- aidevops:terminal-blocker-(?:observation|circuit) revision=(?<revision>[a-f0-9]{24}) blocker=(?<blocker>[a-f0-9]{24}) -->") | "\(.revision) \(.blocker)"') || return 2
	IFS=' ' read -r observed_rev fingerprint <<<"$parsed"
	reason=$(_terminal_blocker_reason "$fingerprint")
	# GH#35745: the producer's own unknown class re-arms like the other held
	# classes. Any other fingerprint also maps to unknown; keep it held.
	if [[ "$reason" == "$_TBC_UNKNOWN" ]]; then
		[[ "$fingerprint" == "$(_terminal_blocker_hash "v2:${_TBC_UNKNOWN}")" ]] || return 2
	fi
	repo_path=$(_tbr_repo_path "$repo")
	# Retry-only holds include legacy timeout hashes: neither a changed brief
	# nor changed code/dependencies may release those observations implicitly.
	current_rev="$observed_rev"
	if ! terminal_blocker_rearms_on_retry_only "$reason"; then
		current_rev=$(terminal_blocker_task_revision "$issue_json" "$repo" "$issue" "$repo_path" "$reason") || return 2
	fi
	retry=$(_terminal_blocker_latest_retry_comment "$comments") || return 2
	decision=unchanged
	if _terminal_blocker_retry_after "$retry" "$evidence"; then
		decision=trusted_retry
	elif [[ "$current_rev" != "$observed_rev" ]]; then
		decision=revision_changed
	fi
	# A newer circuit for the current revision wins over an older observation
	# or retry; unreadable evidence must not fall through into label projection.
	local active_rc=0
	_tbr_circuit_blocks_release "$circuit" "$retry" "$issue_json" "$repo" "$issue" "$repo_path" || active_rc=$?
	[[ "$active_rc" -eq 1 ]] || decision=active_circuit
	[[ "$active_rc" -lt 2 ]] || decision=indeterminate_circuit
	printf 'rearm_decision issue=%s observed_rev=%s current_rev=%s reason=%s\n' \
		"$issue" "$observed_rev" "$current_rev" "$decision" >&2
	[[ "$decision" == revision_changed || "$decision" == trusted_retry ]] || return 2
	# GH#36126: hold without a receipt while a dependency is open.
	_tbr_dependency_unresolved "$repo" "$issue" "$issue_json" "$observed_rev" "$current_rev" && return 3
	# The key binds the observed event, destination revision and retry event.
	# A public receipt, not runner-local queue retirement, suppresses replay.
	# Hash immutable event identity only, not mutable author associations or prose.
	receipt_key=$(jq -nc --argjson evidence "$evidence" --argjson retry "${retry:-null}" \
		--arg observed "$observed_rev" --arg fingerprint "$fingerprint" --arg current "$current_rev" --arg decision "$decision" \
		'{event: ($evidence | {id,created_at}), observed:$observed, fingerprint:$fingerprint, current:$current,
		 retry: (if $decision == "trusted_retry" then ($retry | {id,created_at}) else null end)}') || return 2
	receipt_key=$(_terminal_blocker_hash "$receipt_key") || return 2
	receipt="<!-- aidevops:terminal-blocker-rearmed key=${receipt_key} -->"
	_tbr_project_rearm "$repo" "$issue" "$issue_json" "$comments" "$receipt" "$observed_rev" "$current_rev"
	return $?
}

# Shared idempotent projection for structured and legacy re-arm decisions.
_tbr_project_rearm() {
	local repo="$1" issue="$2" issue_json="$3" comments="$4" receipt="$5"
	local observed_rev="$6" current_rev="$7"
	# Suppression only: accepting a fetched collaborator receipt grants no release.
	if printf '%s' "$comments" | jq -e --arg marker "$receipt" 'any(.[]; (.body // "") | split("\n") | index($marker) != null)' >/dev/null; then
		printf 'rearm_decision issue=%s observed_rev=%s current_rev=%s reason=already_released\n' "$issue" "$observed_rev" "$current_rev" >&2
		return 0
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
	# Reconcile a failed receipt write after a successful projection without
	# projecting availability twice on the next pass.
	if printf '%s' "$issue_json" | jq -e --arg blocked status:blocked 'any(.labels[]; .name == $blocked)' >/dev/null; then
		set_issue_status "$issue" "$repo" available >/dev/null 2>&1 || return 2
	fi
	_tbr_post_rearm_receipt "$repo" "$issue" "$receipt" || return 2
	return 0
}

#######################################
# Re-verify one entry against GitHub. Prints a JSON line when the circuit is
# still active and unowned; retires the entry when resolved. Returns 0 when
# printed, 1 otherwise.
#######################################
_tbr_check_entry() {
	local file="$1"
	local mode="${2:-}" updated_at="" last_updated_at=""
	local repo="" issue="" reason="" opened_at="" key="" intake=""
	_tbr_entry_registered "$file" || return $?
	repo=$(jq -r '.repo // ""' "$file" 2>/dev/null) || return 1
	issue=$(jq -r '.issue // ""' "$file" 2>/dev/null) || return 1
	_tbr_valid_ref "$repo" "$issue" || {
		rm -f "$file"
		return 1
	}
	reason=$(jq -r '.reason // "unknown"' "$file")
	opened_at=$(jq -r '.opened_at // ""' "$file")
	intake=$(jq -r '.intake // "local"' "$file")
	key=$(_tbr_key "$repo" "$issue")
	# GH#35129: cross-runner intake exists only while repo policy enables it.
	if [[ "$intake" == policy_remote ]]; then
		local policy_rc=0
		printf 'blocker-recovery: checking stage=entry_policy repo=%s issue=%s\n' "$repo" "$issue" >&2
		_tbr_policy_enabled "$repo" || policy_rc=$?
		[[ "$policy_rc" -lt 2 ]] || return 2
		if [[ "$policy_rc" -eq 1 ]]; then
			rm -f "$file" "${TBR_ROOT}/decisions/${key}.json"
			return 1
		fi
	fi
	local issue_json="" state=""
	printf 'blocker-recovery: checking stage=entry_issue repo=%s issue=%s\n' "$repo" "$issue" >&2
	issue_json=$(terminal_blocker_fetch_issue "$repo" "$issue") || return 2
	state=$(printf '%s' "$issue_json" | jq -r '.state // ""')
	[[ "$state" == open || "$state" == closed ]] || return 2
	if [[ "$state" != "open" ]]; then
		rm -f "$file" "${TBR_ROOT}/decisions/${key}.json"
		return 1
	fi
	# shellcheck source=terminal-blocker-circuit.sh
	source "${_TBR_SCRIPT_DIR}/terminal-blocker-circuit.sh" || return 1
	if [[ "$mode" == rearm ]]; then
		updated_at=$(printf '%s' "$issue_json" | jq -r '.updated_at // ""')
		last_updated_at=$(jq -r '.rearm_checked_updated_at // ""' "$file")
		# Persist the remote snapshot, not wall-clock time: a retry arriving
		# during this check must still be seen on the next pass. Missing or
		# unreadable timestamps never suppress verification. Revision-bound
		# holds must recheck target/dependency changes independent of issue edits.
		if [[ -n "$updated_at" && -n "$last_updated_at" && ! "$updated_at" > "$last_updated_at" ]] &&
			! terminal_blocker_rearms_on_revision "$reason"; then
			return 1
		fi
	fi
	local comments="" brief="" repo_path=""
	printf 'blocker-recovery: checking stage=entry_comments repo=%s issue=%s\n' "$repo" "$issue" >&2
	# GH#35355: keep this runner's own comments whatever association GitHub reports.
	comments=$(terminal_blocker_fetch_trusted_comments "$issue" "$repo" "${TERMINAL_BLOCKER_SELF_LOGIN:-}") || return 2
	brief=$(printf '%s' "$issue_json" | jq -c '{title: (.title // ""), body: (.body // "")}')
	repo_path=$(_tbr_repo_path "$repo")
	local hold_rc=0
	printf 'blocker-recovery: checking stage=entry_revision repo=%s issue=%s\n' "$repo" "$issue" >&2
	if ! terminal_blocker_circuit_active "$comments" "$brief" "$repo" "$issue" "$repo_path" >/dev/null 2>&1; then
		# GH#34846: a held first observation (no circuit) re-arms on the same
		# relevant revision or trusted retry; an unreadable revision keeps it.
		terminal_blocker_observation_hold_active "$comments" "$brief" "$repo" "$issue" "$repo_path" \
			>/dev/null 2>&1 || hold_rc=$?
	fi
	if [[ "$hold_rc" -eq 1 ]]; then
		# Brief revision, retry directive or backoff expiry re-armed dispatch.
		# Return 1 retires evidence-free intake without releasing any hold.
		local release_rc=0
		_tbr_release_circuit_hold "$repo" "$issue" "$issue_json" "$comments" || release_rc=$?
		# GH#36126: dependency-held. Keep the entry and its decision, and do
		# not stamp rearm_checked_updated_at: a blocker closing need not touch
		# this issue's updated_at, so every pass must recheck it.
		[[ "$release_rc" -ne 3 ]] || return 1
		[[ "$release_rc" -lt 2 ]] || return 2
		rm -f "$file" "${TBR_ROOT}/decisions/${key}.json"
		return 1
	fi
	# Indeterminate revision: keep the entry for the next pass, report nothing.
	[[ "$hold_rc" -eq 0 ]] || return 2
	if [[ "$mode" == rearm ]]; then
		# Only a complete, still-held observation may skip unchanged comments.
		# Do not consult owner decisions or collect excerpts for the LLM.
		jq --arg at "$updated_at" '.rearm_checked_updated_at = $at' "$file" >"${file}.tmp.$$" &&
			mv -f "${file}.tmp.$$" "$file" || return 2
		return 1
	fi
	_tbr_decision_active "$key" && return 1
	local excerpts="[]"
	# Another runner's circuit or observation (policy_remote,
	# remote_observation): public issue/PR evidence only. Same-number excerpts
	# on this runner belong to a different attempt or repository.
	if [[ "$intake" == local ]]; then
		excerpts=$(find "$TBR_EXCERPT_DIR" -maxdepth 1 -type f -name "*-${issue}-*.log" 2>/dev/null | sort | tail -3 |
			jq -R . | jq -sc .) || excerpts="[]"
	fi
	jq -nc --arg repo "$repo" --argjson issue "$issue" --arg reason "$reason" \
		--arg opened_at "$opened_at" --arg title "$(printf '%s' "$issue_json" | jq -r '.title // ""')" \
		--argjson excerpts "${excerpts:-[]}" --arg intake "$intake" \
		'{repo:$repo, issue:$issue, title:$title, reason:$reason, opened_at:$opened_at, intake:$intake, local_excerpts:$excerpts}'
	return 0
}

tbr_pending() {
	local mode="${1:-}"
	local cursor_name=pending_cursor entry_mode=""
	if [[ "$mode" == --rearm-only ]]; then
		cursor_name=rearm_cursor
		entry_mode=rearm
	fi
	_tbr_init_dirs || return 1
	local TBR_DEADLINE="" TBR_QUEUE_DEADLINE="" cursor="" file="" pass=0 count=0 self_resolved=0 rc=0 incomplete=0 reserve=0 observed=";"
	_tbr_start_budget || return 2
	# Retire stale fixtures before any identity/API call, including entries past
	# the remote scan budget. Never retire evidence on an unreadable registry.
	for file in "${TBR_ROOT}"/queue/*.json; do
		[[ -f "$file" ]] || continue
		rc=0
		_tbr_entry_registered "$file" || rc=$?
		[[ "$rc" -lt 2 ]] || return 2
	done
	reserve=$((TBR_BUDGET_SECONDS / 2))
	[[ "$reserve" -le "$TBR_STAGE_SECONDS" ]] || reserve="$TBR_STAGE_SECONDS"
	TBR_QUEUE_DEADLINE=$((TBR_DEADLINE - reserve))
	[[ "$mode" != --rearm-only ]] || TBR_QUEUE_DEADLINE="$TBR_DEADLINE"
	# GH#36114: discover unqueued holds first, so a trusted retry on a hold this
	# runner never queued is applied by the queue pass below in the same run.
	# Its own cap leaves the queue at least half the budget.
	if [[ "$mode" == --rearm-only ]]; then
		rc=0
		_tbr_run_stage discovery tbr_discover || rc=$?
		[[ "$rc" -eq 0 ]] || incomplete=1
	fi
	[[ ! -f "${TBR_ROOT}/${cursor_name}" ]] || read -r cursor <"${TBR_ROOT}/${cursor_name}" || true
	# Resume in sorted order, then wrap. Advance only the scan cursor, never
	# queue ownership or decisions, even when a stage times out.
	for pass in 1 2; do
		for file in "${TBR_ROOT}"/queue/*.json; do
			[[ -f "$file" ]] || continue
			if [[ "$pass" -eq 1 ]]; then
				[[ "${file##*/}" > "$cursor" ]] || continue
			else
				[[ "${file##*/}" > "$cursor" ]] && continue
			fi
			if [[ "$SECONDS" -ge "$TBR_QUEUE_DEADLINE" ]]; then
				printf 'blocker-recovery: incomplete stage=queue reason=budget_exhausted\n' >&2
				incomplete=1
				break 2
			fi
			# GH#33025: resolve once, only when work exists, so this runner's own
			# collaborator-authored circuits stay recognised during recovery.
			if [[ "$self_resolved" -eq 0 && -z "${TERMINAL_BLOCKER_SELF_LOGIN:-}" ]]; then
				TERMINAL_BLOCKER_SELF_LOGIN=$(_tbr_run_stage identity _tbr_self_login) || {
					incomplete=1
					break 2
				}
				export TERMINAL_BLOCKER_SELF_LOGIN
			fi
			self_resolved=1
			_tbr_save_cursor "$cursor_name" "${file##*/}" || return 2
			observed+="${file##*/};"
			rc=0
			if [[ "$mode" == "--count" ]]; then
				_tbr_run_stage entry _tbr_check_entry "$file" >/dev/null || rc=$?
			else
				_tbr_run_stage entry _tbr_check_entry "$file" "$entry_mode" || rc=$?
			fi
			[[ "$rc" -ne 0 ]] || count=$((count + 1))
			[[ "$rc" -lt 2 ]] || incomplete=1
		done
	done
	# Existing ownership is observed before potentially slow remote discovery.
	# Seed has its own stage cap and cannot consume more than the overall budget.
	if [[ "$mode" != --rearm-only ]]; then
		rc=0
		_tbr_run_stage seed tbr_seed || rc=$?
		[[ "$rc" -eq 0 ]] || incomplete=1
	fi
	for file in "${TBR_ROOT}"/queue/*.json; do
		[[ -f "$file" ]] || continue
		case "$observed" in *";${file##*/};"*) continue ;; esac
		printf 'blocker-recovery: incomplete stage=queue reason=unobserved_entries\n' >&2
		incomplete=1
		break
	done
	[[ "$mode" == "--count" ]] && printf '%s\n' "$count"
	[[ "$incomplete" -eq 0 ]] || return 2
	return 0
}

#######################################
# Record an owner decision. stdin: {"wake":..., "next_action":..., "evidence":...}
# wake ∈ brief_revision | environment_fix | owner_change | dependency_change | human_decision
#######################################
tbr_record() {
	local repo="${1:-}"
	local issue="${2:-}"
	_tbr_valid_ref "$repo" "$issue" || return 1
	_tbr_init_dirs || return 1
	local input="" actor="" key=""
	input=$(jq -ec 'select((keys == ["evidence","next_action","wake"]) and
		(.wake | IN("brief_revision","environment_fix","owner_change","dependency_change","human_decision")))') || {
		printf 'record: stdin must be {"wake","next_action","evidence"} with a known wake value\n' >&2
		return 1
	}
	#aidevops:trust-boundary — decision authorship comes from the authenticated
	# GitHub identity, never from stdin.
	actor=$(_tbr_self_login) || return 1
	key=$(_tbr_key "$repo" "$issue")
	printf '%s' "$input" | jq -c --arg actor "$actor" --arg repo "$repo" --argjson issue "$issue" \
		--argjson now "$(date +%s)" '. + {actor:$actor, repo:$repo, issue:$issue, recorded_epoch:$now}' \
		>"${TBR_ROOT}/decisions/${key}.json" || return 1
	return 0
}

tbr_main() {
	local action="${1:-pending}"
	shift || true
	case "$action" in
	_stage)
		local stage_action="${1:-}"
		shift || return 2
		case "$stage_action" in
		_tbr_self_login | _tbr_check_entry | tbr_seed | tbr_discover) "$stage_action" "$@" ;;
		*) return 2 ;;
		esac
		;;
	enqueue) tbr_enqueue "$@" ;;
	seed)
		_tbr_start_budget || return 2
		_tbr_run_stage seed tbr_seed "$@"
		;;
	discover)
		_tbr_start_budget || return 2
		_tbr_run_stage discovery tbr_discover
		;;
	pending) tbr_pending "$@" ;;
	rearm) tbr_pending --rearm-only ;;
	record) tbr_record "$@" ;;
	help | --help | -h)
		# Print the whole header block, opening rule through closing rule.
		sed -n '4,52p' "${BASH_SOURCE[0]}"
		;;
	*) return 2 ;;
	esac
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	tbr_main "$@"
fi
