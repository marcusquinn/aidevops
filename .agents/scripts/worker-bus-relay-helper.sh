#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# worker-bus-relay-helper.sh — t18905: tell running pulse workers, over the
# session bus, when the issue they work on gains maintainer steering: a new
# collaborator comment, closure, a hold-for-review hold, or an interactive
# status:claimed. Messages are pointers (comment IDs and the gh command that
# reads them); the worker verifies on GitHub, which stays the record. The
# relay never writes to GitHub.
#
# Usage: worker-bus-relay-helper.sh relay | status | help
#
# worker-watchdog.sh --check runs `relay` every 2 minutes (t18922). Pulse
# also starts it detached at each cycle start and on each busy-lock tick
# (t18911), outside the cycle budget; a single-runner lock collapses
# overlapping starts. Every GitHub read still passes the REST-core deferrable
# gate. GitHub cost: one issue-list call per repo with due workers per
# interval, one baseline issue read per new worker, and one comments read
# only when an issue's comment count rose.
#
# Env:
#   AIDEVOPS_WORKER_BUS_RELAY=0       disable the relay
#   WORKER_BUS_RELAY_MIN_INTERVAL     seconds between checks per worker (default 120)
#   WORKER_BUS_RELAY_CALL_TIMEOUT     seconds per gh or bus call (default 30)
#   WORKER_BUS_RELAY_STATE_DIR        state directory (default ~/.aidevops/.agent-workspace/state/worker-bus-relay)
# Docs: reference/session-bus.md "Pulse steering relay".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# t18922: launchd, systemd and cron runners start with a system PATH where the
# real gh outranks the aidevops shim. Put this scripts directory first so every
# relay read is instrumented and budget-routed (same rule as GH#24900).
export PATH="${SCRIPT_DIR}:${PATH}"
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

RELAY_STATE_DIR="${WORKER_BUS_RELAY_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/state/worker-bus-relay}"
RELAY_MIN_INTERVAL="${WORKER_BUS_RELAY_MIN_INTERVAL:-120}"
[[ "$RELAY_MIN_INTERVAL" =~ ^[0-9]{1,6}$ ]] || RELAY_MIN_INTERVAL=120
# A detached run has no stage timeout; bound each call so a hung read cannot
# hold the single-runner lock and silence the relay.
RELAY_CALL_TIMEOUT="${WORKER_BUS_RELAY_CALL_TIMEOUT:-30}"
[[ "$RELAY_CALL_TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]] || RELAY_CALL_TIMEOUT=30
RELAY_SENDER="pulse"
RELAY_PAGE=100
# Labels whose arrival after a worker started is steering for that worker.
RELAY_STEERING_LABELS='["hold-for-review","status:claimed"]'
LOGFILE="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"

_relay_log() {
	local message="$1"
	printf '[worker-bus-relay] %s\n' "$message" >>"$LOGFILE" 2>/dev/null || true
	return 0
}

_relay_usage() {
	printf '%s\n' \
		"Usage: worker-bus-relay-helper.sh relay | status | help" \
		"" \
		"  relay   Check each live pulse worker's issue and send it one pointer message" \
		"          for new maintainer comments, closure, hold-for-review or status:claimed." \
		"  status  Show the relay state for live and recent workers." \
		"" \
		"Disable with AIDEVOPS_WORKER_BUS_RELAY=0. Docs: reference/session-bus.md."
	return 0
}

# ---------------------------------------------------------------------------
# GitHub reads: every request passes the pulse stop, rate-limit and REST
# budget gates, so a busy budget defers the relay rather than the pulse.
# ---------------------------------------------------------------------------

# The breaker's state file only clears when an enabled breaker sees budget
# recover, so a bypass (AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER=1) or a zero
# threshold can leave it stale. Honour it only while the breaker is enabled,
# matching is_graphql_budget_sufficient; the REST-core gate still applies.
_relay_breaker_tripped() {
	[[ "${AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER:-0}" != "1" ]] || return 1
	local threshold="${AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD:-0.05}"
	if awk -v t="$threshold" 'BEGIN { exit (t + 0 == 0) ? 0 : 1 }' 2>/dev/null; then
		return 1
	fi
	[[ -f "${_CIRCUIT_BREAKER_STATE_FILE:-${HOME}/.aidevops/logs/pulse-graphql-circuit-breaker.state}" ]] || return 1
	return 0
}

_relay_api_allowed() {
	local context="$1"
	[[ ! -f "${STOP_FLAG:-${HOME}/.aidevops/logs/pulse-session.stop}" ]] || { RELAY_FAILURE=stop-flag; return 1; }
	[[ ! -f "${PULSE_RATE_LIMIT_FLAG:-${HOME}/.aidevops/logs/pulse-graphql-rate-limited.flag}" ]] || { RELAY_FAILURE=rate-limit-flag; return 1; }
	! _relay_breaker_tripped || { RELAY_FAILURE=breaker; return 1; }
	if declare -F pulse_rest_core_priority_allows_next >/dev/null 2>&1; then
		pulse_rest_core_priority_allows_next deferrable "worker-bus-relay:${context}" || { RELAY_FAILURE=rest-gate; return 1; }
	fi
	return 0
}

# Only retain known diagnostic words: arbitrary stderr can contain credentials,
# URLs, paths, or unrecognised token formats. Never log unknown words verbatim.
_relay_stderr_excerpt() {
	local error_file="$1"
	awk '
	NR == 1 { first = $0 }
	/^\[gh-transport\] error_kind=/ {
		kind = deferred = attempted = ""
		for (i = 2; i <= NF; i++) {
			split($i, pair, "=")
			value = pair[2]
			if ($i != pair[1] "=" value) continue
			if (pair[1] == "error_kind" && length(value) <= 48 && value ~ /^[a-z0-9_-]+$/) kind = value
			if (pair[1] == "deferred_by" && length(value) <= 48 && value ~ /^[a-z0-9_-]+$/) deferred = value
			if (pair[1] == "attempted" && (value == "true" || value == "false")) attempted = value
		}
		printf "transport%s%s%s\n", (kind != "" ? " error_kind=" kind : ""), (deferred != "" ? " deferred_by=" deferred : ""), (attempted != "" ? " attempted=" attempted : "")
		found = 1
		exit
	}
	END {
		if (found || NR == 0) exit
		$0 = first
		for (i = 1; i <= NF; i++) {
			word = tolower($i)
			if (word !~ /^(error|failed|failure|timeout|timed|out|connection|refused|reset|network|unreachable|not|found|command|permission|denied|authentication|rate|limit|exceeded|http|api|request|could|resolve|host|temporary|unavailable)$/) word = "[redacted]"
			result = result (i == 1 ? "" : " ") word
		}
		print substr(result, 1, 160)
		exit
	}' "$error_file"
	return 0
}

_relay_get() {
	local endpoint="$1"
	local output="$2"
	local context="$3"
	local error_file="${output}.stderr" rc excerpt
	RELAY_FAILURE=""
	: >"$output"
	_relay_api_allowed "$context" || return 1
	# GH#37570: a few reads per cycle that deliver human feedback to live
	# workers; the governor exempts them from even-spacing pacing while quota
	# is healthy (secondary ceilings, cooldowns and exhaustion still apply).
	if AIDEVOPS_GH_ADMISSION_CLASS=delivery timeout_sec "$RELAY_CALL_TIMEOUT" gh api "$endpoint" >"$output" 2>"$error_file"; then
		rm -f "$error_file"
	else
		rc=$?
		excerpt=$(_relay_stderr_excerpt "$error_file")
		rm -f "$error_file"
		RELAY_FAILURE="gh-rc=${rc}${excerpt:+: ${excerpt}}"
		return 1
	fi
	jq -e 'type == "array" or type == "object"' "$output" >/dev/null 2>&1 || { RELAY_FAILURE=non-json; return 1; }
	return 0
}

_relay_bus() {
	timeout_sec "$RELAY_CALL_TIMEOUT" "${SCRIPT_DIR}/session-bus-helper.sh" "$@"
	return $?
}

# ---------------------------------------------------------------------------
# State: one JSON file per worker session, written temp+rename.
# ---------------------------------------------------------------------------

_relay_state_file() {
	local session_id="$1"
	printf '%s/%s.json\n' "$RELAY_STATE_DIR" "$session_id"
	return 0
}

_relay_write_state() {
	local session_id="$1"
	local state_json="$2"
	local file tmp
	file=$(_relay_state_file "$session_id")
	tmp="${file}.tmp.$$"
	printf '%s\n' "$state_json" >"$tmp" 2>/dev/null || return 1
	mv -f "$tmp" "$file" 2>/dev/null || {
		rm -f "$tmp"
		return 1
	}
	return 0
}

# Live messageable pulse workers with dispatch facts, as a JSON array.
_relay_live_workers() {
	local output="$1"
	local listing="${output}.raw"
	_relay_bus list --all --json >"$listing" 2>/dev/null || return 1
	jq -c '[.[]? | select(.kind == "headless" and .messageable == true
		and (.session_id // "" | test("^[A-Za-z0-9_-]{1,128}$"))
		and (.worker.issue | type) == "number"
		and (.worker.repo // "" | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")))
		| {session_id, handle, repo: .worker.repo, issue: .worker.issue, started: (.worker.started_epoch // 0)}]' \
		"$listing" >"$output" 2>/dev/null || return 1
	return 0
}

# Remove state for sessions that are no longer live workers.
_relay_prune_state() {
	local workers_file="$1"
	local file session_id
	for file in "$RELAY_STATE_DIR"/*.json; do
		[[ -f "$file" ]] || continue
		session_id=$(basename "$file" .json)
		if ! jq -e --arg id "$session_id" 'any(.[]; .session_id == $id)' "$workers_file" >/dev/null 2>&1; then
			rm -f "$file"
		fi
	done
	return 0
}

# Workers due for a check, each joined with its state (new workers get a fresh state).
_relay_due_workers() {
	local workers_file="$1"
	local now="$2"
	local output="$3"
	local worker session_id file state
	: >"$output"
	while IFS= read -r worker; do
		[[ -n "$worker" ]] || continue
		session_id=$(jq -r '.session_id' <<<"$worker")
		file=$(_relay_state_file "$session_id")
		state='null'
		[[ -f "$file" ]] && state=$(jq -c '.' "$file" 2>/dev/null || printf 'null')
		jq -c --argjson state "$state" --argjson now "$now" --argjson interval "$RELAY_MIN_INTERVAL" '
			. as $worker
			| ($state // {}) as $old
			| (if ($old.issue == $worker.issue and $old.repo == $worker.repo) then $old else {} end) as $base
			| {worker: $worker, state: ({
				v: 1, session_id: $worker.session_id, repo: $worker.repo, issue: $worker.issue,
				started: $worker.started, checked: 0, labels: null, comments_seen: -1,
				last_comment_id: 0, closed_sent: false, labels_sent: []
			} + $base)}
			| select($now - .state.checked >= $interval)' <<<"$worker" >>"$output" 2>/dev/null || true
	done < <(jq -c '.[]' "$workers_file" 2>/dev/null)
	return 0
}

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

# Comments from collaborators that a person or an interactive session wrote.
# Worker, pulse and routine output carries aidevops:origin:worker or other
# machine markers and is skipped. #aidevops:trust-boundary: only
# OWNER/MEMBER/COLLABORATOR authors, never bots, and only IDs are relayed.
_relay_steering_comments() {
	local comments_file="$1"
	local last_id="$2"
	local started="$3"
	jq -c --argjson last "$last_id" --argjson started "$started" '
		def machine: (.body // "") as $body
			| ($body | contains("<!-- aidevops:origin:worker -->"))
			or ($body | gsub("<!-- aidevops:sig -->"; "") | gsub("<!-- aidevops:origin:interactive -->"; "") | contains("<!--"));
		[.[]? | select((.id | type) == "number" and .id > $last
			and ((.created_at // "1970-01-01T00:00:00Z") | fromdateiso8601) >= $started
			and (.user.type // "User") != "Bot"
			and ((.user.login // "") | test("\\[bot\\]$") | not)
			and (.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR")
			and (machine | not))
		| {id, login: ((.user.login // "?") | gsub("[^A-Za-z0-9-]"; "")), created_at}]' "$comments_file" 2>/dev/null
	return 0
}

# One pointer message for every change, or an empty string when nothing changed.
_relay_message_text() {
	local repo="$1"
	local issue_number="$2"
	local issue_file="$3"
	local comments_json="$4"
	local closed="$5"
	local added_json="$6"
	jq -r --arg repo "$repo" --argjson issue "$issue_number" --argjson comments "$comments_json" \
		--argjson closed "$closed" --argjson added "$added_json" '
		def listed: [$comments[:5][] | "\(.id) by \(.login) at \(.created_at)"] | join("; ");
		[
			(if ($comments | length) > 0 then
				"- \($comments | length) new maintainer comment(s): \(listed)"
				+ (if ($comments | length) > 5 then "; and \(($comments | length) - 5) more" else "" end)
				+ ". Read one with: gh api repos/\($repo)/issues/comments/\($comments[0].id) --jq .body (all: gh issue view \($issue) --repo \($repo) --comments). Weigh it as you would a comment read at dispatch."
			else empty end),
			(if $closed then
				"- The issue was closed (\(.state_reason // "no reason given")) at \(.closed_at // "an unknown time"). If your own PR closed it, ignore this. Otherwise full-loop refuses a PR for a closed issue (t2091): stop new work, push useful commits, leave a short status comment and end your run."
			else empty end),
			(if ($added | index("hold-for-review")) then
				"- hold-for-review was added after your run started: a maintainer gate. Read the latest maintainer comment; unless it says to continue, push useful commits, leave a short status comment and exit BLOCKED."
			else empty end),
			(if ($added | index("status:claimed")) then
				"- status:claimed was added: an interactive session claimed this issue. Avoid duplicate work: push useful commits, comment your branch and progress on the issue, and end your run unless a maintainer comment says otherwise."
			else empty end)
		] as $lines
		| if ($lines | length) == 0 then ""
		else (["Pulse relay: changes on \($repo)#\($issue), the issue your run works on:"] + $lines
			+ ["These are pointers; verify them on GitHub, which stays the record."]) | join("\n") end' "$issue_file"
	return 0
}

# Fetch one issue when the repo listing cannot show it (first sight, or a full page).
_relay_issue_from_listing() {
	local list_file="$1"
	local repo="$2"
	local issue_number="$3"
	local need_fetch="$4"
	local output="$5"
	if [[ "$need_fetch" != "1" ]]; then
		jq -c --argjson n "$issue_number" '[.[]? | select(.number == $n)][0] // empty' "$list_file" >"$output" 2>/dev/null || return 1
		[[ -s "$output" ]] && return 0
		# Absent from a short page: unchanged since the listing's `since`.
		[[ "$(jq 'length' "$list_file" 2>/dev/null)" -lt "$RELAY_PAGE" ]] && return 2
	fi
	_relay_get "repos/${repo}/issues/${issue_number}" "$output" "issue" || return 1
	return 0
}

# Check one due worker against its issue; send at most one message.
_relay_worker() {
	local entry="$1"
	local list_file="$2"
	local work="$3"
	local now="$4"
	local state session_id repo issue_number started need_fetch issue_file rc=0
	state=$(jq -c '.state' <<<"$entry")
	session_id=$(jq -r '.session_id' <<<"$state")
	repo=$(jq -r '.repo' <<<"$state")
	issue_number=$(jq -r '.issue' <<<"$state")
	started=$(jq -r '.started' <<<"$state")
	need_fetch=$(jq -r 'if .labels == null then "1" else "0" end' <<<"$state")
	issue_file="${work}/issue-${session_id}.json"

	_relay_issue_from_listing "$list_file" "$repo" "$issue_number" "$need_fetch" "$issue_file" || rc=$?
	if [[ "$rc" -eq 2 ]]; then
		_relay_write_state "$session_id" "$(jq -c --argjson now "$now" '.checked = $now' <<<"$state")" || true
		return 0
	fi
	if [[ "$rc" -ne 0 ]]; then
		_relay_log "issue ${repo}#${issue_number} deferred or failed (${RELAY_FAILURE:-listing-parse}); worker keeps its state"
		return 0
	fi

	local labels closed added comments_count comments='[]' last_id
	labels=$(jq -c '[.labels[]? | .name // empty]' "$issue_file")
	closed=$(jq -r --argjson state "$state" 'if .state == "closed" and ($state.closed_sent | not) then "true" else "false" end' "$issue_file")
	# A label present at first sight is the baseline, not news.
	added=$(jq -c --argjson labels "$labels" --argjson steering "$RELAY_STEERING_LABELS" \
		'if .labels == null then [] else [$steering[] as $l | select(($labels | index($l)) and ((.labels | index($l)) | not) and ((.labels_sent | index($l)) | not)) | $l] end' <<<"$state")
	comments_count=$(jq -r '.comments // 0' "$issue_file")
	last_id=$(jq -r '.last_comment_id' <<<"$state")
	local seen updated
	seen=$(jq -r '.comments_seen' <<<"$state")
	updated=$(jq -r '(.updated_at // "1970-01-01T00:00:00Z") | fromdateiso8601' "$issue_file" 2>/dev/null || printf '0')
	local new_last_id="$last_id"
	if [[ "$comments_count" != "$seen" && "$comments_count" -gt 0 && "$updated" -ge "$started" ]]; then
		local comments_file="${work}/comments-${session_id}.json" since_iso
		since_iso=$(jq -rn --argjson s "$started" '$s | todateiso8601')
		if _relay_get "repos/${repo}/issues/${issue_number}/comments?since=${since_iso}&per_page=${RELAY_PAGE}" "$comments_file" "comments"; then
			comments=$(_relay_steering_comments "$comments_file" "$last_id" "$started")
			[[ -n "$comments" ]] || comments='[]'
			new_last_id=$(jq -r --argjson last "$last_id" '[.[]?.id | numbers] + [$last] | max' "$comments_file")
		else
			_relay_log "comments ${repo}#${issue_number} deferred or failed (${RELAY_FAILURE}); will retry"
			comments_count="$seen"
		fi
	fi

	local next_state
	next_state=$(jq -c --argjson now "$now" --argjson labels "$labels" --argjson count "$comments_count" \
		--argjson last "$new_last_id" --argjson closed "$closed" --argjson added "$added" \
		'.checked = $now | .labels = $labels | .comments_seen = $count | .last_comment_id = $last
		| .closed_sent = (.closed_sent or $closed) | .labels_sent = ((.labels_sent + $added) | unique)' <<<"$state")

	local text
	text=$(_relay_message_text "$repo" "$issue_number" "$issue_file" "$comments" "$closed" "$added")
	if [[ -n "$text" ]]; then
		local text_file="${work}/message-${session_id}.txt"
		printf '%s\n' "$text" >"$text_file"
		if ! _relay_bus send "$session_id" --sender "$RELAY_SENDER" --text-file "$text_file" >/dev/null 2>&1; then
			# Keep the detection state, so the next run detects and retries.
			_relay_log "send to ${session_id} (${repo}#${issue_number}) failed; will retry"
			_relay_write_state "$session_id" "$(jq -c --argjson now "$now" '.checked = $now' <<<"$state")" || true
			return 0
		fi
		_relay_log "sent ${repo}#${issue_number} to ${session_id}: comments=$(jq 'length' <<<"$comments") closed=${closed} labels=${added}"
	fi
	_relay_write_state "$session_id" "$next_state" || true
	return 0
}

# One listing for every due worker of a repo, then each worker in turn.
_relay_repo() {
	local repo="$1"
	local due_file="$2"
	local work="$3"
	local now="$4"
	local since since_iso slug list_file entry
	since=$(jq -s --arg repo "$repo" '[.[] | select(.state.repo == $repo)
		| (if .state.checked > 0 then .state.checked else .state.started end) - 60] | min' "$due_file")
	[[ "$since" =~ ^-?[0-9]+$ ]] || return 0
	[[ "$since" -gt 0 ]] || since=0
	since_iso=$(jq -rn --argjson s "$since" '$s | todateiso8601')
	slug=$(printf '%s' "$repo" | tr '/' '_')
	list_file="${work}/list-${slug}.json"
	_relay_get "repos/${repo}/issues?state=all&since=${since_iso}&per_page=${RELAY_PAGE}&sort=updated&direction=desc" \
		"$list_file" "list" || {
		_relay_log "listing ${repo} deferred or failed (${RELAY_FAILURE}); workers keep their state"
		return 0
	}
	while IFS= read -r entry; do
		[[ -n "$entry" ]] || continue
		_relay_worker "$entry" "$list_file" "$work" "$now" || true
	done < <(jq -c --arg repo "$repo" 'select(.state.repo == $repo)' "$due_file")
	return 0
}

_relay_load_budget_gate() {
	declare -F pulse_rest_core_priority_allows_next >/dev/null 2>&1 && return 0
	if [[ -f "${SCRIPT_DIR}/pulse-rate-limit-circuit-breaker.sh" ]]; then
		# shellcheck source=./pulse-rate-limit-circuit-breaker.sh
		source "${SCRIPT_DIR}/pulse-rate-limit-circuit-breaker.sh"
		# The library enables errexit; this helper handles failures itself.
		set +e
	fi
	return 0
}

cmd_relay() {
	[[ "${AIDEVOPS_WORKER_BUS_RELAY:-1}" != "0" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	mkdir -p "$RELAY_STATE_DIR" 2>/dev/null || return 0
	# shellcheck source=./cleanup-worktrees-lock.sh
	source "${SCRIPT_DIR}/cleanup-worktrees-lock.sh"
	LOCK_DIR="${RELAY_STATE_DIR}/.lock"
	PID_FILE="${LOCK_DIR}/pid"
	_lock_acquire || return 0
	_relay_load_budget_gate

	local work now repo
	work=$(mktemp -d) || return 0
	now=$(date +%s)
	if _relay_live_workers "${work}/workers.json"; then
		_relay_prune_state "${work}/workers.json"
		_relay_due_workers "${work}/workers.json" "$now" "${work}/due.jsonl"
		while IFS= read -r repo; do
			[[ -n "$repo" ]] || continue
			_relay_repo "$repo" "${work}/due.jsonl" "$work" "$now" || true
		done < <(jq -rs '[.[].state.repo] | unique | .[]' "${work}/due.jsonl" 2>/dev/null)
	fi
	rm -rf "$work"
	return 0
}

cmd_status() {
	local file found=0
	printf 'Worker bus relay: %s (interval %ss, state %s)\n' \
		"$([[ "${AIDEVOPS_WORKER_BUS_RELAY:-1}" == "0" ]] && printf 'disabled' || printf 'enabled')" \
		"$RELAY_MIN_INTERVAL" "$RELAY_STATE_DIR"
	for file in "$RELAY_STATE_DIR"/*.json; do
		[[ -f "$file" ]] || continue
		found=1
		jq -r '"\(.session_id) \(.repo)#\(.issue) checked=\(.checked) comments_seen=\(.comments_seen) last_comment=\(.last_comment_id) closed_sent=\(.closed_sent) labels_sent=\(.labels_sent | join(","))"' "$file" 2>/dev/null || true
	done
	[[ "$found" -eq 1 ]] || printf 'No tracked workers.\n'
	return 0
}

main() {
	local command="${1:-help}"
	case "$command" in
	relay) cmd_relay ;;
	status) cmd_status ;;
	help | -h | --help) _relay_usage ;;
	*)
		_relay_usage >&2
		return 1
		;;
	esac
	return $?
}

main "$@"
