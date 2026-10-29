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
#
# Queue records are evidence, never authority. Its only issue write is the
# re-armed status:blocked → status:available release (GH#33138); it never
# edits bodies, posts retry directives, changes assignees or grants
# permissions. The supervisor applies reference/worker-discipline.md
# "Terminal-blocker recovery".
#
# Usage:
#   terminal-blocker-recovery-helper.sh enqueue <owner/repo> <issue> [reason] [local|policy_remote]
#   terminal-blocker-recovery-helper.sh seed [--force]
#   terminal-blocker-recovery-helper.sh pending [--count]
#   terminal-blocker-recovery-helper.sh record <owner/repo> <issue>   # JSON on stdin
#
# Env:
#   AIDEVOPS_BLOCKER_RECOVERY_DIR   queue root (default ~/.aidevops/.agent-workspace/terminal-blocker-recovery)
#   BLOCKER_RECOVERY_SEED_INTERVAL  seconds between automatic seeds (default 21600)
#   BLOCKER_RECOVERY_DECISION_TTL   seconds a recorded decision suppresses re-assessment (default 86400)
#   BLOCKER_RECOVERY_BUDGET_SECONDS overall pending/seed budget (default 45)
#   BLOCKER_RECOVERY_STAGE_SECONDS identity/seed budget (default 8); entries use
#                                 the remaining queue budget, rotating on timeout
# Incomplete observations return 2 and a diagnostic on stderr; stdout remains
# JSONL (or a partial count). Retry resumes after the last attempted entry.
# =============================================================================

[[ "${BASH_SOURCE[0]}" == "$0" ]] && set -euo pipefail
_TBR_SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_TBR_SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && _TBR_SCRIPT_DIR="."

TBR_ROOT="${AIDEVOPS_BLOCKER_RECOVERY_DIR:-${HOME}/.aidevops/.agent-workspace/terminal-blocker-recovery}"
TBR_SEED_INTERVAL="${BLOCKER_RECOVERY_SEED_INTERVAL:-21600}"
TBR_DECISION_TTL="${BLOCKER_RECOVERY_DECISION_TTL:-86400}"
TBR_REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
TBR_EXCERPT_DIR="${AIDEVOPS_WORKER_FAILURE_EXCERPT_DIR:-${HOME}/.aidevops/logs/worker-failure-excerpts}"
TBR_CIRCUIT_MARKER="TERMINAL_BLOCKER_CIRCUIT active=true"
TBR_BUDGET_SECONDS="${BLOCKER_RECOVERY_BUDGET_SECONDS:-45}"
TBR_STAGE_SECONDS="${BLOCKER_RECOVERY_STAGE_SECONDS:-8}"

_tbr_start_budget() {
	[[ "$TBR_BUDGET_SECONDS" =~ ^[1-9][0-9]*$ && "$TBR_STAGE_SECONDS" =~ ^[1-9][0-9]*$ ]] || return 2
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
	if [[ "$stage" != entry && "$remaining" -gt "$TBR_STAGE_SECONDS" ]]; then
		remaining="$TBR_STAGE_SECONDS"
	fi
	printf 'blocker-recovery: checking stage=%s\n' "$stage" >&2
	(
		export AIDEVOPS_BLOCKER_RECOVERY_DIR="$TBR_ROOT" REPOS_JSON="$TBR_REPOS_JSON"
		export AIDEVOPS_WORKER_FAILURE_EXCERPT_DIR="$TBR_EXCERPT_DIR"
		export BLOCKER_RECOVERY_SEED_INTERVAL="$TBR_SEED_INTERVAL" BLOCKER_RECOVERY_DECISION_TTL="$TBR_DECISION_TTL"
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
		login=$(gh api user --jq '.login' 2>/dev/null) || login=""
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
	local intake="${4:-local}"
	_tbr_valid_ref "$repo" "$issue" || return 1
	_tbr_registered_repo "$repo" || return $?
	[[ "$reason" =~ ^[a-z_]+$ ]] || reason="unknown"
	[[ "$intake" == policy_remote ]] || intake="local"
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
	local self="" slug="" issue="" comments="" reason="" policy_enabled="" intake="" candidates="" incomplete=0 policy_rc=0
	local repos="" repo_cursor="" issue_cursor="" cursor_name=""
	repos=$(jq -r 'if (.initialized_repos | type) != "array" then error("invalid registry") else
		.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and (.slug // "") != "") | .slug end' \
		"$TBR_REPOS_JSON" 2>/dev/null) || return 2
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
			comments=$(gh api "repos/${slug}/issues/${issue}/comments?per_page=100" --paginate --slurp 2>/dev/null) || {
				incomplete=1
				continue
			}
			reason=$(_tbr_seed_reason "$comments" "$self" "$policy_enabled") || continue
			intake=local
			if ! _tbr_has_own_circuit "$comments" "$self" && [[ "$policy_enabled" == true ]] &&
				_tbr_has_foreign_circuit "$comments" "$self"; then
				intake=policy_remote
			fi
			tbr_enqueue "$slug" "$issue" "$reason" "$intake" || incomplete=1
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
		"label:\"status:blocked\" \"Terminal blocker\" in:comments"; do
		result=$(gh api -X GET search/issues -f q="repo:${slug} is:issue is:open ${query}" \
			--jq '.items[].number' 2>/dev/null) || return 2
		numbers+="${result}"$'\n'
	done
	printf '%s' "$numbers" | sort -un
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
	# The key binds the observed event, destination revision and retry event.
	# A public receipt, not runner-local queue retirement, suppresses replay.
	# Hash immutable event identity only, not mutable author associations or prose.
	receipt_key=$(jq -nc --argjson evidence "$evidence" --argjson retry "${retry:-null}" \
		--arg observed "$observed_rev" --arg fingerprint "$fingerprint" --arg current "$current_rev" --arg decision "$decision" \
		'{event: ($evidence | {id,created_at}), observed:$observed, fingerprint:$fingerprint, current:$current,
		 retry: (if $decision == "trusted_retry" then ($retry | {id,created_at}) else null end)}') || return 2
	receipt_key=$(_terminal_blocker_hash "$receipt_key") || return 2
	receipt="<!-- aidevops:terminal-blocker-rearmed key=${receipt_key} -->"
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
	if printf '%s' "$labels" | jq -e 'index("status:blocked") != null' >/dev/null; then
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
	issue_json=$(gh api "repos/${repo}/issues/${issue}" 2>/dev/null) || return 2
	state=$(printf '%s' "$issue_json" | jq -r '.state // ""')
	[[ "$state" == open || "$state" == closed ]] || return 2
	if [[ "$state" != "open" ]]; then
		rm -f "$file" "${TBR_ROOT}/decisions/${key}.json"
		return 1
	fi
	# shellcheck source=terminal-blocker-circuit.sh
	source "${_TBR_SCRIPT_DIR}/terminal-blocker-circuit.sh" || return 1
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
		[[ "$release_rc" -lt 2 ]] || return 2
		rm -f "$file" "${TBR_ROOT}/decisions/${key}.json"
		return 1
	fi
	# Indeterminate revision: keep the entry for the next pass, report nothing.
	[[ "$hold_rc" -eq 0 ]] || return 2
	_tbr_decision_active "$key" && return 1
	local excerpts="[]"
	# Another runner's circuit: public issue/PR evidence only. Same-number
	# excerpts on this runner belong to a different attempt or repository.
	if [[ "$intake" != policy_remote ]]; then
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
	[[ ! -f "${TBR_ROOT}/pending_cursor" ]] || read -r cursor <"${TBR_ROOT}/pending_cursor" || true
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
			_tbr_save_cursor pending_cursor "${file##*/}" || return 2
			observed+="${file##*/};"
			rc=0
			if [[ "$mode" == "--count" ]]; then
				_tbr_run_stage entry _tbr_check_entry "$file" >/dev/null || rc=$?
			else
				_tbr_run_stage entry _tbr_check_entry "$file" || rc=$?
			fi
			[[ "$rc" -ne 0 ]] || count=$((count + 1))
			[[ "$rc" -lt 2 ]] || incomplete=1
		done
	done
	# Existing ownership is observed before potentially slow remote discovery.
	# Seed has its own stage cap and cannot consume more than the overall budget.
	rc=0
	_tbr_run_stage seed tbr_seed || rc=$?
	[[ "$rc" -eq 0 ]] || incomplete=1
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
		_tbr_self_login | _tbr_check_entry | tbr_seed) "$stage_action" "$@" ;;
		*) return 2 ;;
		esac
		;;
	enqueue) tbr_enqueue "$@" ;;
	seed)
		_tbr_start_budget || return 2
		_tbr_run_stage seed tbr_seed "$@"
		;;
	pending) tbr_pending "$@" ;;
	record) tbr_record "$@" ;;
	help | --help | -h)
		sed -n '4,36p' "${BASH_SOURCE[0]}"
		;;
	*) return 2 ;;
	esac
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	tbr_main "$@"
fi
