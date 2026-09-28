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
#
# Queue records are evidence, never authority. This helper never edits issues,
# posts retry directives, changes labels/assignees or grants permissions. The
# supervisor applies reference/worker-discipline.md "Terminal-blocker recovery".
#
# Usage:
#   terminal-blocker-recovery-helper.sh enqueue <owner/repo> <issue> [reason]
#   terminal-blocker-recovery-helper.sh seed [--force]
#   terminal-blocker-recovery-helper.sh pending [--count]
#   terminal-blocker-recovery-helper.sh record <owner/repo> <issue>   # JSON on stdin
#
# Env:
#   AIDEVOPS_BLOCKER_RECOVERY_DIR   queue root (default ~/.aidevops/.agent-workspace/terminal-blocker-recovery)
#   BLOCKER_RECOVERY_SEED_INTERVAL  seconds between automatic seeds (default 21600)
#   BLOCKER_RECOVERY_DECISION_TTL   seconds a recorded decision suppresses re-assessment (default 86400)
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

_tbr_valid_ref() {
	local repo="$1"
	local issue="$2"
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
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
	_tbr_valid_ref "$repo" "$issue" || return 1
	[[ "$reason" =~ ^[a-z_]+$ ]] || reason="unknown"
	_tbr_init_dirs || return 1
	local file="" tmp=""
	file="${TBR_ROOT}/queue/$(_tbr_key "$repo" "$issue").json"
	tmp="${file}.tmp.$$"
	jq -nc --arg repo "$repo" --argjson issue "$issue" --arg reason "$reason" \
		--arg opened_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{repo:$repo, issue:$issue, reason:$reason, opened_at:$opened_at}' >"$tmp" || {
		rm -f "$tmp"
		return 1
	}
	mv -f "$tmp" "$file" || return 1
	return 0
}

#######################################
# Backfill open circuits authored by this runner (GitHub search on the
# circuit marker). Rate-limited by TBR_SEED_INTERVAL unless --force.
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
	local self="" slug="" issue="" comments=""
	self=$(_tbr_self_login) || return 1
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		while IFS= read -r issue; do
			[[ "$issue" =~ ^[0-9]+$ ]] || continue
			comments=$(gh api "repos/${slug}/issues/${issue}/comments?per_page=100" --paginate --slurp 2>/dev/null) || continue
			# Only circuits this runner opened: the protected dossier lives here.
			if printf '%s' "$comments" | jq -e --arg self "$self" --arg marker "$TBR_CIRCUIT_MARKER" '
				[flatten[] | select((.user.login // "") == $self and ((.body // "") | contains($marker)))] | length > 0
			' >/dev/null 2>&1; then
				tbr_enqueue "$slug" "$issue" "$(_tbr_reason_from_comments "$comments")" || true
			fi
		done < <(gh api -X GET search/issues \
			-f q="repo:${slug} is:issue is:open \"TERMINAL_BLOCKER_CIRCUIT\" in:comments" \
			--jq '.items[].number' 2>/dev/null)
	done < <(jq -r '.initialized_repos[]? | select(.pulse == true and (.local_only // false) == false and (.slug // "") != "") | .slug' \
		"$TBR_REPOS_JSON" 2>/dev/null)
	printf '%s\n' "$now" >"$stamp"
	return 0
}

_tbr_reason_from_comments() {
	local comments="$1"
	printf '%s' "$comments" | jq -r '
		[flatten[] | (.body // "") | capture("Terminal blocker: reason=(?<r>[a-z_]+)")? | .r] | last // "unknown"
	' 2>/dev/null || printf 'unknown\n'
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
# Re-verify one entry against GitHub. Prints a JSON line when the circuit is
# still active and unowned; retires the entry when resolved. Returns 0 when
# printed, 1 otherwise.
#######################################
_tbr_check_entry() {
	local file="$1"
	local repo="" issue="" reason="" opened_at="" key=""
	repo=$(jq -r '.repo // ""' "$file" 2>/dev/null) || return 1
	issue=$(jq -r '.issue // ""' "$file" 2>/dev/null) || return 1
	_tbr_valid_ref "$repo" "$issue" || {
		rm -f "$file"
		return 1
	}
	reason=$(jq -r '.reason // "unknown"' "$file")
	opened_at=$(jq -r '.opened_at // ""' "$file")
	key=$(_tbr_key "$repo" "$issue")
	local issue_json="" state=""
	issue_json=$(gh api "repos/${repo}/issues/${issue}" 2>/dev/null) || return 1
	state=$(printf '%s' "$issue_json" | jq -r '.state // ""')
	if [[ "$state" != "open" ]]; then
		rm -f "$file" "${TBR_ROOT}/decisions/${key}.json"
		return 1
	fi
	# shellcheck source=terminal-blocker-circuit.sh
	source "${_TBR_SCRIPT_DIR}/terminal-blocker-circuit.sh" || return 1
	local comments="" brief="" repo_path=""
	comments=$(terminal_blocker_fetch_trusted_comments "$issue" "$repo") || return 1
	brief=$(printf '%s' "$issue_json" | jq -c '{title: (.title // ""), body: (.body // "")}')
	repo_path=$(_tbr_repo_path "$repo")
	if ! terminal_blocker_circuit_active "$comments" "$brief" "$repo" "$issue" "$repo_path" >/dev/null 2>&1; then
		# Brief revision, retry directive or backoff expiry re-armed dispatch.
		rm -f "$file" "${TBR_ROOT}/decisions/${key}.json"
		return 1
	fi
	_tbr_decision_active "$key" && return 1
	local excerpts=""
	excerpts=$(find "$TBR_EXCERPT_DIR" -maxdepth 1 -type f -name "*-${issue}-*.log" 2>/dev/null | sort | tail -3 |
		jq -R . | jq -sc .) || excerpts="[]"
	jq -nc --arg repo "$repo" --argjson issue "$issue" --arg reason "$reason" \
		--arg opened_at "$opened_at" --arg title "$(printf '%s' "$issue_json" | jq -r '.title // ""')" \
		--argjson excerpts "${excerpts:-[]}" \
		'{repo:$repo, issue:$issue, title:$title, reason:$reason, opened_at:$opened_at, local_excerpts:$excerpts}'
	return 0
}

tbr_pending() {
	local mode="${1:-}"
	_tbr_init_dirs || return 1
	tbr_seed || true
	local file="" count=0
	for file in "${TBR_ROOT}"/queue/*.json; do
		[[ -f "$file" ]] || continue
		if [[ "$mode" == "--count" ]]; then
			_tbr_check_entry "$file" >/dev/null && count=$((count + 1))
		else
			_tbr_check_entry "$file" || true
		fi
	done
	[[ "$mode" == "--count" ]] && printf '%s\n' "$count"
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
	enqueue) tbr_enqueue "$@" ;;
	seed) tbr_seed "$@" ;;
	pending) tbr_pending "$@" ;;
	record) tbr_record "$@" ;;
	help | --help | -h)
		sed -n '4,28p' "${BASH_SOURCE[0]}"
		;;
	*) return 2 ;;
	esac
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	tbr_main "$@"
fi
