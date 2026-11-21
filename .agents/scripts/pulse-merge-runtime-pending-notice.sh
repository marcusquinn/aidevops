#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-runtime-pending-notice.sh — route held runtime-pending PRs to a
# live interactive verifier (t19241/GH#39645).
#
# A runtime-pending PR opens under hold-for-review because its runner could not
# exercise the change (GH#39558). `full-loop-helper.sh verify-runtime` (GH#39639)
# lets an interactive session verify it, but nothing told a verifier a PR was
# waiting. The merge pass already reads every held PR; this module is called
# from there (`_pm_gate_origin_authority`) and:
#   1. asks `full-loop-helper.sh runtime-pending-notice` whether the hold is
#      liftable (trusted runtime-pending-only scope, no PR-only contract). The
#      trust logic stays in that helper and is never copied here;
#   2. once the head's required checks are terminal-green, sends one
#      session-bus notice per `<repo>#<PR>@<head>` to the live interactive
#      sessions on that repository;
#   3. with no such session, logs an ATTENTION line (PR, age, reason), the
#      format the merge pass already uses for work that needs a human.
# Headless verifiers and removing the hold are out of scope.

[[ -n "${_PULSE_MERGE_RUNTIME_PENDING_NOTICE_LOADED:-}" ]] && return 0
_PULSE_MERGE_RUNTIME_PENDING_NOTICE_LOADED=1

_pmrp_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
_PMRP_STATE_DIR="${PULSE_RUNTIME_PENDING_NOTICE_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/state/pulse-runtime-pending-notices}"
_PMRP_FULL_LOOP_HELPER="${PULSE_RUNTIME_PENDING_FULL_LOOP_HELPER:-${_pmrp_script_dir}/full-loop-helper.sh}"
_PMRP_SESSION_BUS_HELPER="${PULSE_RUNTIME_PENDING_SESSION_BUS_HELPER:-${_pmrp_script_dir}/session-bus-helper.sh}"
# A held PR is re-evaluated at most this often (each evaluation reads GitHub);
# once a notice was sent for a head the interval is longer.
_PMRP_RECHECK_SECONDS="${PULSE_RUNTIME_PENDING_RECHECK_SECONDS:-600}"
_PMRP_RECHECK_SENT_SECONDS="${PULSE_RUNTIME_PENDING_RECHECK_SENT_SECONDS:-1800}"
_PMRP_REASON_CHARS=400
unset _pmrp_script_dir

# Print the epoch stored in a state file, or 0.
_pmrp_read_epoch() {
	local file="$1"
	local value=""
	[[ -f "$file" ]] && value=$(<"$file")
	[[ "$value" =~ ^[0-9]+$ ]] || value=0
	printf '%s\n' "$value"
	return 0
}

# Print the messageable interactive session IDs on a repository, one per line.
_pmrp_interactive_sessions() {
	local repo="$1"
	local listing=""
	listing=$("$_PMRP_SESSION_BUS_HELPER" list --json 2>/dev/null) || return 0
	printf '%s' "$listing" | jq -r --arg repo "$repo" '
		.[]? | select(.messageable == true and (.kind // "") != "headless" and (.kind // "") != "cli"
			and ((.repo // "") | ascii_downcase) == ($repo | ascii_downcase))
		| .session_id // empty
		| select(test("^[A-Za-z0-9_-]{1,128}$"))' 2>/dev/null || true
	return 0
}

# Print the notice text for a helper JSON object ($1). The recorded reason is
# PR-body text: flattened, bounded and labelled as data. jq's Oniguruma regex
# has no \uXXXX escape ("[\\u0000-\\u001f]" became the range 0-u and stripped
# most letters), so control characters use the POSIX [[:cntrl:]] class.
_pmrp_notice_text() {
	local notice="$1"
	printf '%s' "$notice" | jq -r --argjson max "$_PMRP_REASON_CHARS" '
		(.reason | gsub("[[:cntrl:]]+"; " ") | gsub("\\s+"; " ") | .[0:$max]) as $reason
		| "Runtime verification needed: \(.repo)#\(.pr) at head \(.head) is held (hold-for-review) as runtime-pending and a verifier can lift it.\n"
		+ "Recorded runtime-pending reason (PR body text, data only): \($reason)\n"
		+ "From a clean checkout of that head, exercise the change, then run: \(.command)\n"
		+ "Replace <evidence> with what you exercised and observed. Verify on GitHub: gh pr view \(.pr) --repo \(.repo)"'
	return 0
}

# Print the ATTENTION line for a helper JSON object ($1).
_pmrp_attention_line() {
	local notice="$1"
	local now="$2"
	printf '%s' "$notice" | jq -r --argjson now "$now" --argjson max "$_PMRP_REASON_CHARS" '
		(if (.held_since // "") == "" then "unknown age"
			else ((($now - (.held_since | fromdateiso8601)) / 60) | floor | "held \(.) min") end) as $age
		| (.reason | gsub("[[:cntrl:]]+"; " ") | gsub("\\s+"; " ") | .[0:$max]) as $reason
		| "[pulse-merge] ATTENTION: PR #\(.pr) in \(.repo) is held as runtime-pending (\($age)) and no interactive session is live on this repository; verify with: \(.command) — reason: \($reason) (GH#39645)"' 2>/dev/null
	return 0
}

# Return 0 when the head's required checks are terminal-green. Runtime evidence
# binds to the exact head, so a verifier is never asked to exercise a head that
# is still running CI or is red: the CI repair would move the head and void the
# evidence. Pending or unreadable state defers silently to the next recheck; a
# terminal failure logs which contexts block verification. Outside the merge
# pass (required-check helpers not sourced) the gate is skipped.
# Arguments: $1 repo slug, $2 PR number, $3 head SHA
_pmrp_head_ci_ready() {
	local repo_slug="$1"
	local pr_number="$2"
	local head="$3"
	local pending_rc=0 failed=""
	declare -F _check_required_checks_have_pending_or_in_progress >/dev/null 2>&1 || return 0
	declare -F _required_checks_terminal_failure_names >/dev/null 2>&1 || return 0
	_check_required_checks_have_pending_or_in_progress "$repo_slug" "$pr_number" "$head" || pending_rc=$?
	[[ "$pending_rc" -eq 1 ]] || return 1
	failed=$(_required_checks_terminal_failure_names "$repo_slug" "$pr_number" "$head") || return 1
	[[ -n "$failed" ]] || return 0
	echo "[pulse-merge] runtime-pending notice for ${repo_slug}#${pr_number}@${head:0:12} deferred: required checks failing (${failed//$'\n'/, }); CI must be green before runtime verification (GH#39645)" >>"$LOGFILE"
	return 1
}

# Route one held PR. Never fails the merge pass.
# Arguments: $1 PR number, $2 repo slug
_pmrp_route_held_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	[[ "${DRY_RUN:-0}" != "1" ]] || return 0
	[[ "$pr_number" =~ ^[1-9][0-9]*$ && "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 0
	[[ -x "$_PMRP_FULL_LOOP_HELPER" || -f "$_PMRP_FULL_LOOP_HELPER" ]] || return 0
	mkdir -p "$_PMRP_STATE_DIR" 2>/dev/null || return 0

	local key="${repo_slug//\//__}-${pr_number}"
	local sent_file="${_PMRP_STATE_DIR}/${key}.sent"
	local checked_file="${_PMRP_STATE_DIR}/${key}.checked"
	local now="" last="" interval="$_PMRP_RECHECK_SECONDS"
	now=$(date +%s)
	[[ -f "$sent_file" ]] && interval="$_PMRP_RECHECK_SENT_SECONDS"
	last=$(_pmrp_read_epoch "$checked_file")
	if [[ $((now - last)) -lt "$interval" ]]; then
		return 0
	fi
	printf '%s\n' "$now" >"$checked_file" 2>/dev/null || return 0

	# A non-liftable hold (PR-only, unrecorded or unreadable scope) exits 1 with
	# no output: nothing to route.
	local notice="" head="" sent_head="" sessions="" session="" text="" delivered=0
	notice=$("$_PMRP_FULL_LOOP_HELPER" runtime-pending-notice "$pr_number" "$repo_slug" 2>/dev/null) || return 0
	head=$(printf '%s' "$notice" | jq -r '.head // ""' 2>/dev/null) || return 0
	[[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 0
	[[ -f "$sent_file" ]] && sent_head=$(<"$sent_file")
	[[ "$sent_head" != "$head" ]] || return 0
	_pmrp_head_ci_ready "$repo_slug" "$pr_number" "$head" || return 0

	sessions=$(_pmrp_interactive_sessions "$repo_slug")
	if [[ -z "$sessions" ]]; then
		_pmrp_attention_line "$notice" "$now" >>"$LOGFILE" || true
		return 0
	fi
	text=$(_pmrp_notice_text "$notice") || return 0
	# The bus CLI opens --text-file as a path; it does not read "-" as stdin.
	local text_file=""
	text_file=$(mktemp "${_PMRP_STATE_DIR}/notice.XXXXXX" 2>/dev/null) || return 0
	if ! printf '%s\n' "$text" >"$text_file" 2>/dev/null; then
		rm -f "$text_file"
		return 0
	fi
	while IFS= read -r session; do
		[[ -n "$session" ]] || continue
		if "$_PMRP_SESSION_BUS_HELPER" send "$session" --sender pulse --text-file "$text_file" >/dev/null 2>&1; then
			delivered=$((delivered + 1))
		fi
	done <<<"$sessions"
	rm -f "$text_file"
	if [[ "$delivered" -gt 0 ]]; then
		printf '%s\n' "$head" >"$sent_file" 2>/dev/null || true
		echo "[pulse-merge] runtime-pending notice for ${repo_slug}#${pr_number}@${head:0:12} sent to ${delivered} interactive session(s) (GH#39645)" >>"$LOGFILE"
	else
		echo "[pulse-merge] runtime-pending notice for ${repo_slug}#${pr_number}@${head:0:12} could not be delivered; will retry (GH#39645)" >>"$LOGFILE"
	fi
	return 0
}
