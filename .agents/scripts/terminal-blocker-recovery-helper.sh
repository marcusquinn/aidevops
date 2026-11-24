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
# GH#37978: pending also queues open issues whose only hold is a bare
# status:blocked with no open dependency and no terminal-blocker record
# (intake unclassified_hold), so the supervisor records a reason, releases
# the issue or names the one human input. The helper itself only queues.
# GH#38311: pending also queues hold-for-review issues this runner's login
# answered with a plain reply (intake answered_hold) or held with no stated
# reason (intake unexplained_hold); a maintainer reply newer than a recorded
# human_decision ends its suppression. See terminal-blocker-recovery-holds.sh.
# t19068: record stamps human_decision with the repo recovery policy's actions
# fingerprint; a later added, restored, edited or withdrawn policy ends that
# suppression too, so newly delegated authority is applied on the next pass.
# GH#39232: a standing human_decision also suspends the permission_required
# backoff-window re-arm (both passes); a trusted retry or revision still wakes it.
#
# Queue records are evidence, never authority. Its only issue write is the
# re-armed status:blocked → status:available release (GH#33138); it never
# edits bodies, posts retry directives, changes assignees or grants
# permissions. The supervisor applies reference/worker-discipline.md
# "Terminal-blocker recovery".
#
# Usage:
#   terminal-blocker-recovery-helper.sh enqueue <owner/repo> <issue> [reason] [local|policy_remote|remote_observation|unclassified_hold]
#   terminal-blocker-recovery-helper.sh seed [--force]
#   terminal-blocker-recovery-helper.sh pending [--count]   # --count leaves the cursor before the first counted entry
#   terminal-blocker-recovery-helper.sh rearm   # discovery + queued holds; no LLM work, seed, unclassified or holds stage
#   terminal-blocker-recovery-helper.sh discover   # discovery stage only
#   terminal-blocker-recovery-helper.sh unclassified   # unclassified-hold stage only
#   terminal-blocker-recovery-helper.sh holds   # hold-for-review reply/reason stage only
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
#   BLOCKER_RECOVERY_UNCLASSIFIED_INTERVAL seconds between complete
#                                 unclassified-hold listings per repo (default 21600)
#   BLOCKER_RECOVERY_UNCLASSIFIED_MIN_AGE seconds an issue must be unchanged
#                                 before it is queued as unclassified (default 86400)
#   BLOCKER_RECOVERY_UNCLASSIFIED_MAX new unclassified entries per pass (default 10);
#                                 the stage shares the discovery cap
#   BLOCKER_RECOVERY_HOLD_INTERVAL seconds between complete hold listings per repo (default 3600)
#   BLOCKER_RECOVERY_HOLD_EXPLAIN_AGE seconds a hold may go unexplained before
#                                 it is queued as unexplained_hold (default 86400)
#   BLOCKER_RECOVERY_HOLD_MAX     held issues read per pass (default 10)
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
# GH#40120: re-poll interval for external_trigger decisions without recheck_after.
TBR_EXTERNAL_TRIGGER_RECHECK="${BLOCKER_RECOVERY_EXTERNAL_TRIGGER_RECHECK:-259200}"
TBR_REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
TBR_EXCERPT_DIR="${AIDEVOPS_WORKER_FAILURE_EXCERPT_DIR:-${HOME}/.aidevops/logs/worker-failure-excerpts}"
TBR_CIRCUIT_MARKER="TERMINAL_BLOCKER_CIRCUIT active=true"
TBR_BUDGET_SECONDS="${BLOCKER_RECOVERY_BUDGET_SECONDS:-45}"
TBR_STAGE_SECONDS="${BLOCKER_RECOVERY_STAGE_SECONDS:-8}"
TBR_DISCOVERY_SECONDS="${BLOCKER_RECOVERY_DISCOVERY_SECONDS:-15}"
TBR_DISCOVERY_OVERLAP="${BLOCKER_RECOVERY_DISCOVERY_OVERLAP:-900}"
TBR_UNCLASSIFIED_INTERVAL="${BLOCKER_RECOVERY_UNCLASSIFIED_INTERVAL:-21600}"
TBR_UNCLASSIFIED_MIN_AGE="${BLOCKER_RECOVERY_UNCLASSIFIED_MIN_AGE:-86400}"
TBR_UNCLASSIFIED_MAX="${BLOCKER_RECOVERY_UNCLASSIFIED_MAX:-10}"
# Labels that stop dispatch by themselves: their reason belongs to the label,
# so neither re-arm projection nor unclassified intake touches such an issue.
# Input: array of label names. #aidevops:trust-boundary
# shellcheck disable=SC2016 # jq variables are bound by callers.
_TBR_OTHER_HOLDS_JQ='def other_holds($blocked): [.[] | select(. == "needs-maintainer-permissions" or
	. == "hold-for-review" or . == "no-auto-dispatch" or . == "parent-task" or
	. == "needs-maintainer-review" or
	(startswith("status:") and . != $blocked and . != "status:available"))];'
# GH#38360: a companion that already names a human or dependency owner makes a
# hold classified; only bare or needs-ai-recovery holds enter unclassified intake.
_TBR_CLASSIFIED_COMPANION_JQ='def classified_companion: any(.[]; . == "needs-maintainer-input" or
	. == "needs-credentials" or . == "needs-source-access" or . == "needs-dependency");'
# GH#39710: set_issue_status removes status:blocked before it adds the target
# (remove-first), so a stage timeout between those writes leaves no status:*
# label and a blocked-owned companion behind. That is this supervisor's own
# release cut short, not a resolved hold, so projection must finish it.
_TBR_INTERRUPTED_RELEASE_JQ='def interrupted_release: (any(.[]; startswith("status:")) | not) and
	any(.[]; . == "needs-ai-recovery" or . == "needs-dependency" or . == "needs-maintainer-input" or
	. == "needs-source-access");'
# Shape predicates for listing/comment validation.
_TBR_SHAPE_JQ='def arr: type == ([] | type); def bool: type == (true | type);'
# Evaluated-issue memory older than this is pruned after a complete pass.
TBR_DISCOVERY_RETENTION_DAYS=30
# shellcheck source=terminal-blocker-recovery-holds.sh
source "${_TBR_SCRIPT_DIR}/terminal-blocker-recovery-holds.sh"
# shellcheck source=./terminal-blocker-recovery-release.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _TBR_SCRIPT_DIR
source "${_TBR_SCRIPT_DIR}/terminal-blocker-recovery-release.sh"
# shellcheck source=./terminal-blocker-recovery-pending.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _TBR_SCRIPT_DIR
source "${_TBR_SCRIPT_DIR}/terminal-blocker-recovery-pending.sh"

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
	# Seed, holds and unclassified stages run after the queue pass, in its reserve.
	if [[ "$stage" != seed && "$stage" != unclassified && "$stage" != holds && -n "${TBR_QUEUE_DEADLINE:-}" ]]; then
		remaining=$((TBR_QUEUE_DEADLINE - SECONDS))
	fi
	# GH#38232: the seed stops early enough to leave unclassified its share.
	if [[ "$stage" == seed && -n "${TBR_SEED_DEADLINE:-}" ]]; then
		remaining=$((TBR_SEED_DEADLINE - SECONDS))
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
	if [[ "$stage" == discovery || "$stage" == unclassified || "$stage" == holds ]]; then
		# GH#36114: never more than half the budget, so the queue pass can
		# apply what discovery finds in the same run. GH#37978: the
		# unclassified listing shares this cap and resumes from a saved list.
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
		export BLOCKER_RECOVERY_UNCLASSIFIED_INTERVAL="$TBR_UNCLASSIFIED_INTERVAL"
		export BLOCKER_RECOVERY_UNCLASSIFIED_MIN_AGE="$TBR_UNCLASSIFIED_MIN_AGE"
		export BLOCKER_RECOVERY_UNCLASSIFIED_MAX="$TBR_UNCLASSIFIED_MAX"
		export BLOCKER_RECOVERY_HOLD_INTERVAL="$TBR_HOLD_INTERVAL" BLOCKER_RECOVERY_HOLD_EXPLAIN_AGE="$TBR_HOLD_EXPLAIN_AGE"
		export BLOCKER_RECOVERY_HOLD_MAX="$TBR_HOLD_MAX"
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

# GH#38232: resume AT the cursor. The seed repo cursor names the repo that was
# interrupted; exclusive rotation sends it to the back, where faster repos use
# the stage cap first and it never completes. Per-item cursors (seed issues,
# discovery) keep _tbr_rotate so one stalled item cannot block the rest.
_tbr_rotate_inclusive() {
	local lines="$1" cursor="$2"
	printf '%s\n' "$lines" | jq -Rnr --arg cursor "$cursor" '
		[inputs | select(length > 0)] | unique |
		(map(select(. >= $cursor)) + map(select(. < $cursor)))[]' || return 1
	return 0
}

_tbr_save_cursor() {
	local name="$1" value="$2"
	printf '%s\n' "$value" >"${TBR_ROOT}/${name}.tmp.$$" || return 1
	mv -f "${TBR_ROOT}/${name}.tmp.$$" "${TBR_ROOT}/${name}" || return 1
	return 0
}

# Put a scan cursor back to an earlier value; an empty value means "start of
# queue", which is the same as no cursor file.
_tbr_restore_cursor() {
	local name="$1" value="$2"
	if [[ -z "$value" ]]; then
		rm -f "${TBR_ROOT}/${name}" || return 1
		return 0
	fi
	_tbr_save_cursor "$name" "$value" || return 1
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
	# GH#37978: `unclassified_hold` marks a bare status:blocked hold with no
	# recorded reason; public evidence only, never released by this helper.
	local intake="${4:-local}"
	# GH#38311: optional extra fields; only reply_comment_id is kept.
	local extra="${5:-}"
	[[ -n "$extra" ]] || extra='{}'
	_tbr_valid_ref "$repo" "$issue" || return 1
	_tbr_registered_repo "$repo" || return $?
	[[ "$reason" =~ ^[a-z_]+$ ]] || reason="unknown"
	# GH#38311: answered_hold / unexplained_hold mark hold-for-review issues;
	# public evidence only, and this helper never removes the hold.
	case "$intake" in
	policy_remote | remote_observation | unclassified_hold | answered_hold | unexplained_hold | persistent_exclusion) ;;
	*) intake="local" ;;
	esac
	_tbr_init_dirs || return 1
	local file="" tmp=""
	file="${TBR_ROOT}/queue/$(_tbr_key "$repo" "$issue").json"
	tmp="${file}.tmp.$$"
	jq -nc --arg repo "$repo" --argjson issue "$issue" --arg reason "$reason" \
		--arg opened_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg intake "$intake" --argjson extra "$extra" \
		'{repo:$repo, issue:$issue, reason:$reason, opened_at:$opened_at, intake:$intake}
		+ ($extra | if type == "object" then {reply_comment_id} | with_entries(select(.value | type == "number")) else {} end)' >"$tmp" || {
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
	local repos="" repo_cursor="" issue_cursor="" cursor_name="" retried="" first=1
	repos=$(_tbr_pulse_repos) || return 2
	[[ ! -f "${TBR_ROOT}/seed_repo_cursor" ]] || read -r repo_cursor <"${TBR_ROOT}/seed_repo_cursor" || true
	[[ ! -f "${TBR_ROOT}/seed_repo_retry" ]] || read -r retried <"${TBR_ROOT}/seed_repo_retry" || true
	# GH#38232: start at the interrupted repo so it gets the stage cap first.
	# If it already started first last run and was interrupted again, let
	# the other repos run before it this time; per-repo issue cursors keep
	# its progress either way.
	if [[ -n "$repo_cursor" && "$retried" == "$repo_cursor" ]]; then
		rm -f "${TBR_ROOT}/seed_repo_retry"
		repos=$(_tbr_rotate "$repos" "$repo_cursor") || return 2
	else
		repos=$(_tbr_rotate_inclusive "$repos" "$repo_cursor") || return 2
	fi
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
		if [[ "$first" -eq 1 && -n "$repo_cursor" && "$slug" == "$repo_cursor" ]]; then
			_tbr_save_cursor seed_repo_retry "$slug" || return 2
		fi
		first=0
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
	rm -f "${TBR_ROOT}/seed_repo_cursor" "${TBR_ROOT}/seed_repo_retry"
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

# t19170: list the queued holds this search saw change since their last rearm
# check (a trusted retry, a reply, a brief revision) in changed_entries, which
# _tbr_pending_scan_changed checks before the rotation. Local reads only; the
# hold intakes the rearm pass never reads are skipped. Merged sorted and unique.
_tbr_note_changed_entries() {
	local candidates="$1"
	local list="${TBR_ROOT}/changed_entries" names=""
	local repo issue updated file
	while IFS=$'\t' read -r repo issue updated; do
		_tbr_valid_ref "$repo" "$issue" || continue
		file="${TBR_ROOT}/queue/${repo//\//--}--${issue}.json"
		[[ -f "$file" ]] || continue
		jq -e --arg u "$updated" '(.intake | tostring | test("^(unclassified|answered|unexplained)_hold$") | not)
			and ((.rearm_checked_updated_at // "") as $s | $s == "" or $u > $s)' "$file" >/dev/null 2>&1 || continue
		names+="${file##*/}"$'\n'
	done <<<"$candidates"
	[[ -n "$names" ]] || return 0
	if [[ -f "$list" ]]; then
		while IFS= read -r file; do
			names+="${file}"$'\n'
		done <"$list"
	fi
	printf '%s' "$names" | sort -u >"${list}.tmp.$$" || return 1
	mv -f "${list}.tmp.$$" "$list" || return 1
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
	# Before the reads below, so a pass cut short by its cap still lists them.
	_tbr_note_changed_entries "$candidates" || return 2
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
		# t19170: a hold queued here changed in this window too; check it first.
		[[ ! -f "${TBR_ROOT}/queue/${key}.json" ]] || printf '%s.json\n' "$key" >>"${TBR_ROOT}/changed_entries" || return 2
		# An unreadable policy may have hidden eligibility; evaluate it again.
		[[ "$policy_rc" -ge 2 ]] || _tbr_save_cursor "discovered/${key}" "$updated" || return 2
	done <<<"$candidates"
	[[ "$incomplete" -eq 0 ]] || return 2
	rm -f "${TBR_ROOT}/discovery_cursor"
	find "${TBR_ROOT}/discovered" -type f -mtime +"$TBR_DISCOVERY_RETENTION_DAYS" -delete 2>/dev/null || true
	_tbr_save_cursor last_discovery_epoch "$now" || return 2
	return 0
}

#######################################
# GH#37978: queue open issues whose only dispatch stop is a bare
# status:blocked: no other hold label, no open dependency, no terminal-blocker
# record and no change for TBR_UNCLASSIFIED_MIN_AGE. Neither the dependency
# sweep nor the phrase discovery above can see them. Each pulse repo is listed
# once per TBR_UNCLASSIFIED_INTERVAL with one paginated GraphQL query; the
# listing is saved, so a timed-out or capped pass resumes after its cursor
# without listing again. At most TBR_UNCLASSIFIED_MAX new entries per pass.
# A failed read is never absence: that repo stays unstamped. Each evaluated
# issue is remembered with its updated_at (separate from discovered/), so a
# retired entry is not queued again until the issue changes.
# #aidevops:trust-boundary — this stage only queues evidence. It never
# releases, labels or comments: missing evidence is not a reason to release
# (GH#35540, GH#35569); the supervisor decides after reading the issue.
#######################################
_TBR_UNCLASSIFIED_QUEUED=0
tbr_discover_unclassified() {
	_tbr_init_dirs || return 1
	local dir="${TBR_ROOT}/unclassified" memo="${TBR_ROOT}/unclassified-evaluated"
	mkdir -p "$dir" "$memo" || return 1
	[[ "$TBR_UNCLASSIFIED_INTERVAL" =~ ^[0-9]+$ && "$TBR_UNCLASSIFIED_MIN_AGE" =~ ^[0-9]+$ ]] || return 2
	[[ "$TBR_UNCLASSIFIED_MAX" =~ ^[1-9][0-9]*$ ]] || return 2
	local repos="" slug="" rkey="" last=0 now="" incomplete=0 rc=0
	now=$(date +%s)
	repos=$(_tbr_pulse_repos) || return 2
	_TBR_UNCLASSIFIED_QUEUED=0
	# shellcheck source=terminal-blocker-circuit.sh
	source "${_TBR_SCRIPT_DIR}/terminal-blocker-circuit.sh" || return 1
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		_tbr_valid_ref "$slug" 1 || {
			incomplete=1
			continue
		}
		rkey="${slug//\//--}"
		last=0
		[[ ! -f "${dir}/${rkey}.epoch" ]] || read -r last <"${dir}/${rkey}.epoch" || true
		[[ "$last" =~ ^[0-9]+$ ]] || last=0
		[[ $((now - last)) -ge "$TBR_UNCLASSIFIED_INTERVAL" ]] || continue
		rc=0
		_tbr_unclassified_repo "$slug" "$dir" "$memo" "$now" || rc=$?
		# Per-pass cap reached: stop; the next pass resumes this repo.
		[[ "$rc" -ne 3 ]] || return 0
		[[ "$rc" -eq 0 ]] || incomplete=1
	done <<<"$repos"
	[[ "$incomplete" -eq 0 ]] || return 2
	find "$memo" -type f -mtime +"$TBR_DISCOVERY_RETENTION_DAYS" -delete 2>/dev/null || true
	return 0
}

# One repo of the unclassified stage. Returns 0 when complete (stamped),
# 2 incomplete, 3 when the per-pass cap stopped it (list and cursor kept).
_tbr_unclassified_repo() {
	local slug="$1" dir="$2" memo="$3" now="$4"
	local cursor=0 rkey="${slug//\//--}" list="" listing="" number="" listed_at="" incomplete=0 rc=0
	list="${dir}/${rkey}.list"
	if [[ ! -f "$list" ]]; then
		printf 'blocker-recovery: checking stage=unclassified_list repo=%s\n' "$slug" >&2
		listing=$(_tbr_unclassified_listing "$slug" "$((now - TBR_UNCLASSIFIED_MIN_AGE))") || return 2
		rm -f "${dir}/${rkey}.cursor"
		_tbr_save_cursor "unclassified/${rkey}.list" "$listing" || return 2
	fi
	[[ ! -f "${dir}/${rkey}.cursor" ]] || read -r cursor <"${dir}/${rkey}.cursor" || true
	[[ "$cursor" =~ ^[0-9]+$ ]] || cursor=0
	while IFS=$'\t' read -r number listed_at; do
		[[ "$number" =~ ^[1-9][0-9]*$ && "$number" -gt "$cursor" ]] || continue
		[[ "$_TBR_UNCLASSIFIED_QUEUED" -lt "$TBR_UNCLASSIFIED_MAX" ]] || return 3
		_tbr_save_cursor "unclassified/${rkey}.cursor" "$number" || return 2
		rc=0
		_tbr_unclassified_intake "$slug" "$number" "$listed_at" "$memo" "$now" || rc=$?
		[[ "$rc" -eq 0 ]] || incomplete=1
	done <"$list"
	rm -f "$list" "${dir}/${rkey}.cursor"
	[[ "$incomplete" -eq 0 ]] || return 2
	_tbr_save_cursor "unclassified/${rkey}.epoch" "$now" || return 2
	return 0
}

# Paginated listing of open status:blocked issues that pass every listing
# filter: complete labels with no other hold, a complete native blockedBy set
# with no open blocker, and updatedAt at or before the cutoff epoch. Prints
# "number<TAB>updatedAt" sorted by number. Any read or shape failure fails
# (return 2) and prints nothing: an unreadable listing is never absence.
_tbr_unclassified_listing() {
	local repo="$1" cutoff="$2"
	local owner="${repo%%/*}" name="${repo#*/}" pages="" blocked=status:blocked
	[[ "$cutoff" =~ ^-?[0-9]+$ ]] || return 2
	# One label in the filter: a GraphQL labels list matches any entry.
	# shellcheck disable=SC2016 # GraphQL variables are expanded by GitHub.
	pages=$(gh api graphql --paginate --slurp -f owner="$owner" -f name="$name" -f label="$blocked" \
		-f query='query($owner:String!,$name:String!,$label:String!,$endCursor:String){repository(owner:$owner,name:$name){issues(states:OPEN,labels:[$label],first:100,after:$endCursor){nodes{number updatedAt labels(first:50){nodes{name} pageInfo{hasNextPage}} blockedBy(first:20){nodes{state} pageInfo{hasNextPage}}} pageInfo{hasNextPage endCursor}}}}' \
		2>/dev/null) || return 2
	# shellcheck disable=SC2016 # jq variables are supplied via --arg/--argjson
	printf '%s' "$pages" | jq -r --argjson cutoff "$cutoff" --arg blocked "$blocked" "${_TBR_SHAPE_JQ}${_TBR_OTHER_HOLDS_JQ}${_TBR_CLASSIFIED_COMPANION_JQ}"'
		if arr and length > 0
			and all(.[]; (.errors // [] | length) == 0
				and (.data.repository.issues.nodes | arr)
				and (.data.repository.issues.pageInfo.hasNextPage | bool))
			and .[-1].data.repository.issues.pageInfo.hasNextPage == false
		then [.[] | .data.repository.issues.nodes[]] else error("invalid listing") end
		| if all(.[]; (.number | type) == "number" and (.updatedAt | type) == "string"
			and (.labels.nodes | arr) and (.labels.pageInfo.hasNextPage | bool)
			and (.blockedBy.nodes | arr) and (.blockedBy.pageInfo.hasNextPage | bool))
		then . else error("invalid node") end
		| sort_by(.number)[]
		| select(.labels.pageInfo.hasNextPage == false)
		| select(.labels.nodes | map(.name) | (index($blocked) != null) and (other_holds($blocked) | length == 0)
			and (classified_companion | not))
		| select(.blockedBy.pageInfo.hasNextPage == false and all(.blockedBy.nodes[]; .state == "CLOSED"))
		| select((.updatedAt | fromdateiso8601) <= $cutoff)
		| "\(.number)\t\(.updatedAt)"
	' 2>/dev/null || return 2
	return 0
}

# 0 when status:blocked is the issue's only dispatch stop, 1 otherwise,
# 2 when the labels are unreadable. #aidevops:trust-boundary
_tbr_unclassified_labels_ok() {
	local issue_json="$1" rc=0
	# shellcheck disable=SC2016 # jq variables are supplied via --arg
	jq -e --arg blocked status:blocked "${_TBR_SHAPE_JQ}${_TBR_OTHER_HOLDS_JQ}${_TBR_CLASSIFIED_COMPANION_JQ}"'
		(.labels | if arr then map(.name) else error("labels") end)
		| (index($blocked) != null) and (other_holds($blocked) | length == 0)
			and (classified_companion | not)
	' <<<"$issue_json" >/dev/null 2>&1 || rc=$?
	[[ "$rc" -le 1 ]] || return 2
	return "$rc"
}

# 0 when any comment, from any author, carries a terminal-blocker observation,
# circuit, legacy blocked release or "Terminal blocker" line: normal intake
# owns that issue. 1 when none, 2 when the comments are unreadable.
_tbr_has_blocker_record() {
	local comments="$1" rc=0
	printf '%s' "$comments" | jq -e "${_TBR_SHAPE_JQ}"'
		if arr | not then error("comments") else
		any(flatten[]; (.body // "") | test("aidevops:terminal-blocker-(observation|circuit)|TERMINAL_BLOCKER_CIRCUIT|CLAIM_RELEASED reason=blocked|Terminal blocker: reason=")) end
	' >/dev/null 2>&1 || rc=$?
	[[ "$rc" -le 1 ]] || return 2
	return "$rc"
}

# Evaluate one listed issue with fresh reads and queue it when still eligible.
# Returns 0 when queued or ineligible, 2 when evidence could not be read or the
# entry not written (the issue is evaluated again on a later pass).
_tbr_unclassified_intake() {
	local slug="$1" issue="$2" listed_at="$3" memo="$4" now="$5"
	local key="" seen="" issue_json="" updated="" updated_epoch="" comments="" rc=0 memo_name=""
	key=$(_tbr_key "$slug" "$issue")
	memo_name="${memo##*/}/${key}"
	# Already queued: the queue pass owns it.
	[[ ! -f "${TBR_ROOT}/queue/${key}.json" ]] || return 0
	# Evaluated at this listing's updatedAt: skip without any read.
	[[ ! -f "${memo}/${key}" ]] || read -r seen <"${memo}/${key}" || true
	[[ -z "$seen" || "$seen" != "$listed_at" ]] || return 0
	printf 'blocker-recovery: checking stage=unclassified_issue repo=%s issue=%s\n' "$slug" "$issue" >&2
	issue_json=$(terminal_blocker_fetch_issue "$slug" "$issue") || return 2
	[[ "$(jq -r '.state // ""' <<<"$issue_json")" == open ]] || return 0
	updated=$(jq -r '.updated_at // ""' <<<"$issue_json")
	updated_epoch=$(jq -nr --arg t "$updated" '$t | fromdateiso8601' 2>/dev/null) || return 2
	[[ -z "$seen" || "$seen" != "$updated" ]] || return 0
	# Changed since the listing: not unchanged for the minimum age yet.
	[[ "$updated_epoch" -le $((now - TBR_UNCLASSIFIED_MIN_AGE)) ]] || return 0
	_tbr_unclassified_labels_ok "$issue_json" || rc=$?
	[[ "$rc" -lt 2 ]] || return 2
	# Another hold label owns it, or a terminal-blocker record hands it to
	# normal intake: remember it until the issue changes.
	if [[ "$rc" -eq 0 ]]; then
		comments=$(terminal_blocker_fetch_comments "$slug" "$issue") || return 2
		_tbr_has_blocker_record "$comments" || rc=$?
		[[ "$rc" -ne 2 ]] || return 2
		rc=$((1 - rc))
	fi
	if [[ "$rc" -ne 0 ]]; then
		_tbr_save_cursor "$memo_name" "$updated" || return 2
		return 0
	fi
	# An open or unknown text dependency holds it; no memo, so it is evaluated
	# again once the dependency closes (that need not touch this issue).
	_tbr_dependency_unresolved "$slug" "$issue" "$issue_json" unclassified unclassified && return 0
	tbr_enqueue "$slug" "$issue" unknown unclassified_hold || return 2
	_tbr_save_cursor "$memo_name" "$updated" || return 2
	_TBR_UNCLASSIFIED_QUEUED=$((_TBR_UNCLASSIFIED_QUEUED + 1))
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

_tbr_release_circuit_hold() {
	local repo="$1"
	local issue="$2"
	local issue_json="$3"
	local comments="$4"
	local labels=""
	local blocked_status="status:blocked"
	labels=$(printf '%s' "$issue_json" | jq -ce '.labels | select(type == "array") | map(.name)' 2>/dev/null) || return 2
	printf '%s' "$labels" | jq -e --arg blocked "$blocked_status" "${_TBR_OTHER_HOLDS_JQ}${_TBR_INTERRUPTED_RELEASE_JQ}"'
		((index($blocked) != null) or (index("status:available") != null) or interrupted_release) and
		(other_holds($blocked) | length == 0)
	' >/dev/null 2>&1 || return 0
	# GH#35540: absence of an applicable hold is NOT positive re-arm evidence.
	# In particular, intake can see a foreign COLLABORATOR observation which
	# the authoritative hold selectors deliberately ignore. Never release it.
	local observation="" circuit="" evidence="" parsed="" observed_rev="" fingerprint=""
	local current_rev="" retry="" decision="" repo_path=""
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
	local input_hold_rc=0
	terminal_blocker_input_circuit_active "$comments" "$issue_json" "$repo" "$issue" "$repo_path" || input_hold_rc=$?
	[[ "$input_hold_rc" -eq 1 ]] || return 2
	# Retry-only holds include legacy timeout hashes: neither a changed brief
	# nor changed code/dependencies may release those observations implicitly.
	current_rev="$observed_rev"
	if ! terminal_blocker_rearms_on_retry_only "$reason"; then
		current_rev=$(terminal_blocker_task_revision "$issue_json" "$repo" "$issue" "$repo_path" "$reason") || return 2
	fi
	retry=$(_terminal_blocker_latest_retry_comment "$comments") || return 2
	decision=unchanged
	local window_index=""
	if _terminal_blocker_retry_after "$retry" "$evidence"; then
		decision=trusted_retry
	elif [[ "$current_rev" != "$observed_rev" ]]; then
		decision=revision_changed
	elif [[ "$reason" == "$_TBC_PERMISSION_REQUIRED" ]] &&
		window_index=$(terminal_blocker_permission_window_expired "$comments" "$issue_json" "$evidence"); then
		# GH#36232 #aidevops:trust-boundary: no published request to approve.
		# Schedules one new attempt per window; it grants no permission.
		decision=unevidenced_permission_window
		# GH#39232: the brief owner already named the human input; only a
		# reply, revision, retry or policy change may wake this hold.
		if _tbr_human_decision_standing "$repo" "$issue" "$comments"; then
			decision=decided_permission_hold
		fi
	elif [[ "$reason" == "$_TBC_PERMISSION_REQUIRED" ]] &&
		terminal_blocker_permission_window_spent "$comments" "$issue_json" "$evidence"; then
		# GH#36342 #aidevops:trust-boundary: the window re-arm already repeated
		# this result; only a retry, new trusted input or brief revision wakes it.
		decision=permission_window_spent
	elif [[ "$reason" == "$_TBC_UNKNOWN" ]] && _tbr_lifecycle_recovered "$repo" "$issue" "$evidence"; then
		decision=lifecycle_recovered
	fi
	# A newer circuit for the current revision wins over an older observation
	# or retry; unreadable evidence must not fall through into label projection.
	local active_rc=0
	_tbr_circuit_blocks_release "$circuit" "$retry" "$issue_json" "$repo" "$issue" "$repo_path" "$comments" || active_rc=$?
	[[ "$active_rc" -eq 1 || "$decision" == lifecycle_recovered ]] || decision=active_circuit
	[[ "$active_rc" -lt 2 ]] || decision=indeterminate_circuit
	printf 'rearm_decision issue=%s observed_rev=%s current_rev=%s reason=%s\n' \
		"$issue" "$observed_rev" "$current_rev" "$decision" >&2
	[[ "$decision" != decided_permission_hold ]] || return 4
	[[ "$decision" == revision_changed || "$decision" == trusted_retry ||
		"$decision" == unevidenced_permission_window || "$decision" == lifecycle_recovered ]] || return 2
	# GH#36126: hold without a receipt while a dependency is open.
	_tbr_dependency_unresolved "$repo" "$issue" "$issue_json" "$observed_rev" "$current_rev" && return 3
	_tbr_release_decided_hold "$repo" "$issue" "$issue_json" "$comments" "$evidence" "${retry:-null}" \
		"$observed_rev" "$fingerprint" "$current_rev" "$decision" "$window_index"
	return $?
}

#######################################
# Re-verify one entry against GitHub. Prints a JSON line when the circuit is
# still active and unowned; retires the entry when resolved. Returns 0 when
# printed, 1 otherwise.
#######################################
_tbr_check_entry() {
	local file="$1"
	local mode="${2:-}" updated_at=""
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
	# GH#37978/GH#38311: the mechanical rearm pass never reads, reports or
	# releases an unclassified or hold-for-review intake; only the supervisor
	# pass re-checks them.
	case "$intake" in
	unclassified_hold | answered_hold | unexplained_hold | persistent_exclusion) [[ "$mode" != rearm ]] || return 1 ;;
	esac
	if [[ "$intake" == policy_remote ]]; then
		_tbr_check_entry_policy "$file" "$repo" "$issue" "$key" || return $?
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
	local intake_rc=0
	_tbr_check_intake_entry "$file" "$repo" "$issue" "$key" "$issue_json" "$reason" "$opened_at" "$intake" || intake_rc=$?
	[[ "$intake_rc" -eq 3 ]] || return "$intake_rc"
	# shellcheck source=terminal-blocker-circuit.sh
	source "${_TBR_SCRIPT_DIR}/terminal-blocker-circuit.sh" || return 1
	updated_at=$(printf '%s' "$issue_json" | jq -r '.updated_at // ""')
	_tbr_skip_unchanged_entry "$file" "$updated_at" "$reason" "$mode" && return 1
	local comments="" brief="" repo_path=""
	printf 'blocker-recovery: checking stage=entry_comments repo=%s issue=%s\n' "$repo" "$issue" >&2
	# GH#35355: keep this runner's own comments whatever association GitHub reports.
	comments=$(terminal_blocker_fetch_trusted_comments "$issue" "$repo" "${TERMINAL_BLOCKER_SELF_LOGIN:-}") || return 2
	# Labels let the permission-request predicate see needs-maintainer-permissions.
	brief=$(printf '%s' "$issue_json" | jq -c '{title: (.title // ""), body: (.body // ""), labels: (.labels // [])}')
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
		if [[ "$release_rc" -eq 4 ]]; then
			# GH#39232: decided permission hold. Keep the entry and its
			# decision; the supervisor already owns it, so print nothing,
			# unless its external_trigger re-check is due (GH#40120).
			_tbr_stamp_rearm_check "$file" "$updated_at" "$comments" "$brief" decided || return 2
			[[ "$mode" != rearm ]] || return 1
			_tbr_decision_active "$key" "$comments" && return 1
			_tbr_print_entry "$repo" "$issue" "$reason" "$opened_at" "$intake" "$issue_json"
			return $?
		fi
		[[ "$release_rc" -lt 2 ]] || return 2
		rm -f "$file" "${TBR_ROOT}/decisions/${key}.json"
		return 1
	fi
	# Indeterminate revision: keep the entry for the next pass, report nothing.
	[[ "$hold_rc" -eq 0 ]] || return 2
	# Infrastructure recovery is a positive wake condition even for an active
	# unknown circuit. The release helper still enforces labels and dependencies.
	if [[ "$reason" == unknown ]]; then
		local lifecycle_rc=0
		_tbr_release_circuit_hold "$repo" "$issue" "$issue_json" "$comments" || lifecycle_rc=$?
		if [[ "$lifecycle_rc" -eq 0 ]]; then
			rm -f "$file" "${TBR_ROOT}/decisions/${key}.json"
			return 1
		fi
	fi
	if [[ "$mode" == rearm ]]; then
		# Only a complete, still-held observation may skip unchanged comments.
		# Do not consult owner decisions or collect excerpts for the LLM.
		_tbr_stamp_rearm_check "$file" "$updated_at" "$comments" "$brief" || return 2
		return 1
	fi
	_tbr_decision_active "$key" "$comments" && return 1
	_tbr_print_entry "$repo" "$issue" "$reason" "$opened_at" "$intake" "$issue_json"
	return $?
}


#######################################
# Record an owner decision. stdin: {"wake":..., "next_action":..., "evidence":...}
# plus, for external_trigger only, an optional future "recheck_after"
# (YYYY-MM-DDTHH:MM:SSZ).
# wake ∈ brief_revision | environment_fix | owner_change | dependency_change | human_decision | external_trigger
# external_trigger = decided hold waiting on a named external event; it is
# shown as parked by /decisions. GH#40120: unlike human_decision it is
# re-assessed at recheck_after, or after BLOCKER_RECOVERY_EXTERNAL_TRIGGER_RECHECK
# without one, because only polling observes most external events.
#######################################
tbr_record() {
	local repo="${1:-}"
	local issue="${2:-}"
	_tbr_valid_ref "$repo" "$issue" || return 1
	_tbr_init_dirs || return 1
	local input="" actor="" key=""
	input=$(jq -ec --argjson now "$(date +%s)" '
		def recheck_ok: (has("recheck_after") | not) or (.wake == "external_trigger"
			and (.recheck_after | type) == "string"
			and (.recheck_after | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
			# jq normalises calendar-invalid dates (02-30 -> 03-02); require a round trip.
			and ((.recheck_after | try (fromdateiso8601 | todateiso8601) catch "") == .recheck_after)
			and ((.recheck_after | fromdateiso8601) > $now));
		select((del(.recheck_after) | keys) == ["evidence","next_action","wake"] and
			(.wake | IN("brief_revision","environment_fix","owner_change","dependency_change","human_decision","external_trigger"))
			and recheck_ok)
		| if .recheck_after then .recheck_after_epoch = (.recheck_after | fromdateiso8601) else . end') || {
		printf 'record: stdin must be {"wake","next_action","evidence"} with a known wake value; optional recheck_after (future YYYY-MM-DDTHH:MM:SSZ) is for external_trigger only\n' >&2
		return 1
	}
	#aidevops:trust-boundary — decision authorship comes from the authenticated
	# GitHub identity, never from stdin.
	actor=$(_tbr_self_login) || return 1
	key=$(_tbr_key "$repo" "$issue")
	# t19068: stamp the policy a human_decision was made under; an unreadable
	# policy leaves no stamp, which later compares as "none".
	local stamp='{}'
	if [[ "$(jq -r '.wake' <<<"$input")" =~ ^(human_decision|external_trigger)$ ]] && _tbr_policy_load "$repo"; then
		stamp=$(jq -nc --arg fingerprint "${_TBR_POLICY_STATE%:*}" '{policy_fingerprint:$fingerprint}') || stamp='{}'
	fi
	printf '%s' "$input" | jq -c --arg actor "$actor" --arg repo "$repo" --argjson issue "$issue" \
		--argjson now "$(date +%s)" --argjson stamp "$stamp" \
		'. + {actor:$actor, repo:$repo, issue:$issue, recorded_epoch:$now} + $stamp' \
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
		_tbr_self_login | _tbr_check_entry | tbr_seed | tbr_discover | tbr_discover_unclassified | tbr_discover_holds) "$stage_action" "$@" ;;
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
	unclassified)
		_tbr_start_budget || return 2
		_tbr_run_stage unclassified tbr_discover_unclassified
		;;
	holds)
		_tbr_start_budget || return 2
		_tbr_run_stage holds tbr_discover_holds
		;;
	pending) tbr_pending "$@" ;;
	rearm) tbr_pending --rearm-only ;;
	record) tbr_record "$@" ;;
	help | --help | -h)
		# Print the whole header block, opening rule through closing rule.
		sed -n '4,72p' "${BASH_SOURCE[0]}"
		;;
	*) return 2 ;;
	esac
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	tbr_main "$@"
fi
