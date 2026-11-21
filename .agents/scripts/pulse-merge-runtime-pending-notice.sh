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
#   3. with no such session (including after a notified session exits
#      without verifying), logs an ATTENTION line (PR, age, reason), the
#      format the merge pass already uses for work that needs a human;
#   4. when the head's required checks are terminal-red on a worker PR, routes
#      it to the existing in-place CI repair (t19244). The hold makes the merge
#      pass skip the PR before its own CI repair stage, so without this a red
#      runtime-pending PR waits for a human. The hold is never removed here.
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

# Return 0 when the head's required checks are terminal-green, 2 when at least
# one required check failed terminally, 1 when checks are pending or unreadable.
# Runtime evidence binds to the exact head, so a verifier is never asked to
# exercise a head that is still running CI or is red: the CI repair would move
# the head and void the evidence. Pending or unreadable state defers silently
# to the next recheck; a terminal failure logs which contexts block
# verification. Outside the merge pass (required-check helpers not sourced) the
# gate is skipped.
# Pending and failed states come from one exact-head rollup read, so a sibling
# re-run between two reads cannot pair an old failure with a stale "nothing
# pending" and route repair while a required check is active (t19244 review).
# The states match _check_required_checks_have_pending_or_in_progress and
# _required_checks_terminal_failure_names in pulse-merge-required-checks.sh.
# Arguments: $1 repo slug, $2 PR number, $3 head SHA
_pmrp_head_ci_ready() {
	local repo_slug="$1"
	local pr_number="$2"
	local head="$3"
	local contexts="" rollup="" state="" failed=""
	declare -F _required_contexts_for_default_branch >/dev/null 2>&1 || return 0
	declare -F gh_pr_check_runs_rest >/dev/null 2>&1 || return 0
	contexts=$(_required_contexts_for_default_branch "$repo_slug") || return 1
	[[ -n "$contexts" ]] || return 0
	rollup=$(gh_pr_check_runs_rest "$repo_slug" "$head" 2>/dev/null) || return 1
	# The rollup goes through stdin: a large one overflows argv (GH#39650).
	state=$(printf '%s' "$rollup" | jq -r --arg req "$contexts" '
		if type != "array" then error("invalid rollup") else
		. as $checks
		| [$req | split("\n")[] | select(length > 0)
			| . as $ctx | {ctx: $ctx, c: ($checks | map(select((.name // "") == $ctx)) | last)}] as $rows
		| if any($rows[]; .c == null or ((.c.conclusion // "") | length) == 0
			or ((.c.status // "" | ascii_downcase) | test("^(queued|pending|in_progress|waiting|requested)$")))
		then "pending"
		else ([$rows[] | select((.c.conclusion // "" | ascii_downcase) | test("^(failure|cancelled|timed_out)$")) | .ctx]
			| unique | sort | join(", ")) as $failed
			| if $failed == "" then "green" else "red:" + $failed end
		end end' 2>/dev/null) || return 1
	case "$state" in
	green) return 0 ;;
	red:?*) failed="${state#red:}" ;;
	*) return 1 ;;
	esac
	echo "[pulse-merge] runtime-pending notice for ${repo_slug}#${pr_number}@${head:0:12} deferred: required checks failing (${failed}); CI must be green before runtime verification (GH#39645)" >>"$LOGFILE"
	return 2
}

# Route a terminal-red head of a held runtime-pending PR to the existing CI
# repair (t19244). The repair runs on the PR branch, so the hold and the
# runtime-pending declaration stay, and the verifier notice follows once the
# repaired head is green. Nothing here removes the hold or merges. If in-place
# repair is impossible or exhausted, the close-and-redispatch fallback reaches
# the feedback finalizer, which defers any PR whose hold lacks automation
# provenance, so a runtime-pending PR is never closed this way. A deferred or
# maintainer-preserved route logs ATTENTION, so the stall states its reason.
# Arguments: $1 PR number, $2 repo slug, $3 linked issue (may be empty),
#            $4 live PR labels (comma-separated), $5 head SHA
_pmrp_route_held_ci_repair() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local labels="$4"
	local head="$5"
	local route_rc=0
	# #aidevops:trust-boundary — worker or takeover origin only. External,
	# no-takeover, needs-maintainer-review and live interactive PRs stay with
	# their owners. The hold may be ignored in this label check only because
	# runtime-pending-notice already scoped it to runtime-pending alone; a
	# missing gate fails closed.
	declare -F _feedback_route_labels_allow_worker_route >/dev/null 2>&1 || return 0
	declare -F _route_pr_to_fix_worker >/dev/null 2>&1 || return 0
	_feedback_route_labels_allow_worker_route "$labels" 1 || return 0
	_route_pr_to_fix_worker "$pr_number" "$repo_slug" "$linked_issue" ci "$labels" "" "" "$head" || route_rc=$?
	echo "[pulse-merge] held runtime-pending PR ${repo_slug}#${pr_number}@${head:0:12} has failing required checks; CI repair route rc=${route_rc}; hold-for-review kept (t19244)" >>"$LOGFILE"
	if [[ "$route_rc" -eq "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" || "$route_rc" -eq "${PULSE_FEEDBACK_ROUTE_MAINTAINER_RC:-76}" ]]; then
		echo "[pulse-merge] ATTENTION: PR #${pr_number} in ${repo_slug} is held as runtime-pending with failing required checks and CI repair could not proceed (route rc=${route_rc}; in-place repair exhausted, deferred or maintainer-preserved — see preceding _dispatch_ci_fix_worker / feedback finalizer lines) (t19244)" >>"$LOGFILE"
	fi
	return 0
}

# Route one held PR. Never fails the merge pass. The caller only passes
# non-draft PRs carrying hold-for-review.
# Arguments: $1 PR number, $2 repo slug, $3 linked issue (optional),
#            $4 live PR labels (optional; without them no CI repair routes)
_pmrp_route_held_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="${3:-}"
	local labels="${4:-}"
	local ci_rc=0
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
	# Gate every pass, notified head or not: a sent notice records delivery, not
	# lasting CI success, and a same-head re-run can turn red (t19244 review).
	# The longer recheck interval after a notice bounds these reads.
	_pmrp_head_ci_ready "$repo_slug" "$pr_number" "$head" || ci_rc=$?
	if [[ "$ci_rc" -eq 2 ]]; then
		_pmrp_route_held_ci_repair "$pr_number" "$repo_slug" "$linked_issue" "$labels" "$head"
	fi
	[[ "$ci_rc" -eq 0 ]] || return 0

	sessions=$(_pmrp_interactive_sessions "$repo_slug")
	if [[ -z "$sessions" ]]; then
		_pmrp_attention_line "$notice" "$now" >>"$LOGFILE" || true
		return 0
	fi
	# Dedupe after the no-session branch: if the notified session exits without
	# verifying, the still-held PR must surface ATTENTION instead of going silent.
	[[ "$sent_head" != "$head" ]] || return 0
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
