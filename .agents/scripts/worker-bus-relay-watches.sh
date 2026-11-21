#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# worker-bus-relay-watches.sh — t19157/GH#39240: the issue-watch pass of
# worker-bus-relay-helper.sh (sourced; not run directly). Interactive sessions
# watch owner/repo#N through `aidevops sessions watch-issue`; claim-task-id.sh
# watches the issues an interactive session files. Each relay run diffs the
# watched items' status labels, assignees, state and comments against per-watch
# state and sends each watching session one batched pointer message, so a
# worker on any runner picking up, blocking on or finishing that work reaches
# the session that filed it. The pass never writes to GitHub and never copies
# titles or comment bodies.
#
# GitHub cost per interval: one issue read (stable URL, so an unchanged item
# revalidates as a free 304; t19234) per due watch, and up to
# RELAY_WATCH_COMMENT_PAGES comment pages only when an item's comment count
# rose. Every read goes
# through _relay_get (stop flag, breaker, REST-core deferrable gate).
# Docs: reference/session-bus.md "Issue watches".

# Labels whose changes are progress news for a watcher (#aidevops:trust-boundary:
# names only, sanitised; maintainers own label creation).
RELAY_WATCH_LABELS_RE='^(status:[a-z-]+|hold-for-review|needs-maintainer-review)$'
# A fresh watch (the session just created the item) reports a worker pickup or
# closure that beat the first pass: these dispatch labels, and every assignee
# then, count as new. Without them, any assignee other than the item's author
# is new; the author's own creation-time self-assignment (claim-task-id.sh
# assigns non-auto-dispatch issues to their creator) is not.
# Creation labels vary (status:available default, explicit status:*, publication
# holds), so other labels seen first are the baseline.
RELAY_WATCH_PICKUP_LABELS='["status:queued","status:in-progress"]'
# Items listed per message, within the bus text limit; the rest keep their state
# and go in the next pass.
RELAY_WATCH_PER_MESSAGE=6
RELAY_WATCH_MESSAGE_CHARS=1990
# Comment pages (RELAY_PAGE each) read per item per pass.
RELAY_WATCH_COMMENT_PAGES=3

_relay_watch_state_file() {
	local subscriber="$1"
	local key="$2"
	printf '%s/watch/%s/%s.json\n' "$RELAY_STATE_DIR" "$subscriber" "$key"
	return 0
}

_relay_watch_write_state() {
	local state_json="$1"
	local subscriber key file tmp
	subscriber=$(jq -r '.subscriber' <<<"$state_json")
	key=$(jq -r '.key' <<<"$state_json")
	[[ "$subscriber" =~ ^[A-Za-z0-9_-]{1,128}$ && "$key" =~ ^[a-z0-9_.-]+@[a-z0-9_.-]+@[0-9]+$ ]] || return 1
	file=$(_relay_watch_state_file "$subscriber" "$key")
	mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
	tmp="${file}.tmp.$$"
	printf '%s\n' "$state_json" >"$tmp" 2>/dev/null || return 1
	mv -f "$tmp" "$file" 2>/dev/null || {
		rm -f "$tmp"
		return 1
	}
	return 0
}

# Remove state for watches that ended (expired, stopped, or session gone).
_relay_watch_prune_state() {
	local watches_file="$1"
	local dir file subscriber key
	for dir in "$RELAY_STATE_DIR"/watch/*/; do
		[[ -d "$dir" ]] || continue
		subscriber=$(basename "$dir")
		for file in "$dir"*.json; do
			[[ -f "$file" ]] || continue
			key=$(basename "$file" .json)
			jq -e --arg s "$subscriber" --arg k "$key" 'any(.[]; .subscriber == $s and .key == $k)' \
				"$watches_file" >/dev/null 2>&1 || rm -f "$file"
		done
		rmdir "$dir" 2>/dev/null || true
	done
	return 0
}

# Watches due for a check, each joined with its state (first sight: baseline null).
# State from an earlier watch on the same item (ended, then re-added before the
# prune) has another start time and is ignored.
_relay_watch_due() {
	local watches_file="$1"
	local now="$2"
	local output="$3"
	local watch subscriber key file state
	: >"$output"
	while IFS= read -r watch; do
		[[ -n "$watch" ]] || continue
		subscriber=$(jq -r '.subscriber' <<<"$watch")
		key=$(jq -r '.key' <<<"$watch")
		[[ "$subscriber" =~ ^[A-Za-z0-9_-]{1,128}$ && "$key" =~ ^[a-z0-9_.-]+@[a-z0-9_.-]+@[0-9]+$ ]] || continue
		file=$(_relay_watch_state_file "$subscriber" "$key")
		state='null'
		[[ -f "$file" ]] && state=$(jq -c '.' "$file" 2>/dev/null || printf 'null')
		jq -c --argjson state "$state" --argjson now "$now" --argjson interval "$RELAY_MIN_INTERVAL" '
			. as $w
			| (($w.created_ms // 0) / 1000 | floor) as $created
			| {watch: $w, state: ({
				v: 1, subscriber: $w.subscriber, key: $w.key, repo: $w.repo, number: $w.number,
				created: $created, checked: 0, baseline: null,
				comments_seen: -1, last_comment_id: 0
			} + (if ($state.key // "") == $w.key and ($state.created // -1) == $created then $state else {} end))}
			| select(.state.gone != true and $now - .state.checked >= $interval)' <<<"$watch" >>"$output" 2>/dev/null || true
	done < <(jq -c '.[]?' "$watches_file" 2>/dev/null)
	return 0
}

# Steering-free comment pointers since the watch began: people and workers,
# never bots or audit-trail (ops) comments. IDs, logins and times only.
_relay_watch_comments() {
	local comments_file="$1"
	local last_id="$2"
	local created="$3"
	jq -c --argjson last "$last_id" --argjson created "$created" '
		[.[]? | select((.id | type) == "number" and .id > $last
			and ((.created_at // "1970-01-01T00:00:00Z") | fromdateiso8601) >= $created
			and (.user.type // "User") != "Bot"
			and ((.user.login // "") | test("\\[bot\\]$") | not)
			and ((.body // "") | contains("<!-- ops:start") | not))
		| {id, login: ((.user.login // "?") | gsub("[^A-Za-z0-9-]"; "")), created_at}]' "$comments_file" 2>/dev/null
	return 0
}

# {line, state}: one pointer line (or "") and the next state for one watch.
_relay_watch_diff() {
	local entry="$1"
	local issue_file="$2"
	local comments_json="$3"
	local comments_count="$4"
	local last_id="$5"
	local now="$6"
	jq -c --argjson e "$entry" --argjson comments "$comments_json" --argjson count "$comments_count" \
		--argjson last "$last_id" --argjson now "$now" --arg re "$RELAY_WATCH_LABELS_RE" \
		--argjson pickup "$RELAY_WATCH_PICKUP_LABELS" '
		def clean: gsub("[^A-Za-z0-9:_.-]"; "");
		def login: (.login // "") | gsub("[^A-Za-z0-9-]"; "");
		def changes($added; $removed): [($added[] | "+" + .), ($removed[] | "-" + .)] | join(" ");
		"open" as $open | "closed" as $closed
		| . as $i
		| ($i.pull_request != null) as $pr
		| {labels: ([$i.labels[]? | (.name // "") | clean | select(test($re))] | unique),
			assignees: ([$i.assignees[]? | login | select(. != "")] | unique),
			state: ($i.state // $open)} as $cur
		| [$cur.labels[] | select(IN($pickup[]))] as $picked
		| ($i.user // {} | login) as $author
		| (if $e.state.baseline != null then $e.state.baseline
			elif $e.watch.fresh == true then
				($cur | .state = $open | .labels -= $picked
					| .assignees = (if ($picked | length) > 0 or $cur.state == $closed then []
						else [.assignees[] | select(. == $author)] end))
			else $cur end) as $old
		| ($cur.labels - $old.labels) as $la | ($old.labels - $cur.labels) as $lr
		| ($cur.assignees - $old.assignees) as $aa | ($old.assignees - $cur.assignees) as $ar
		| ($comments | length) as $n
		| (($i.state_reason // "no reason given") | clean) as $reason
		| ($i.closed_at // "an unknown time") as $closed_at
		| [
			(if ($la + $lr | length) > 0 then "labels " + changes($la; $lr) else empty end),
			(if ($aa + $ar | length) > 0 then "assignees " + changes($aa; $ar) else empty end),
			(if $n > 0 then
				"\($n) new comment(s): " + ([$comments[:3][] | "\(.id) by \(.login) at \(.created_at)"] | join(", "))
				+ (if $n > 3 then ", and \($n - 3) more" else "" end)
			else empty end),
			(if $old.state == $open and $cur.state == $closed then
				(if ($i.pull_request.merged_at // null) != null then "merged at \($i.pull_request.merged_at)"
				else "closed (\($reason)) at \($closed_at)" end)
			elif $old.state == $closed and $cur.state == $open then "reopened"
			else empty end)
		] as $parts
		| (if $pr then " (PR)" else "" end) as $suffix
		| (if $pr then "pr" else "issue" end) as $kind
		| ($parts | join("; ")) as $summary
		| {
			line: (if ($parts | length) == 0 then ""
				else "- \($e.watch.repo)#\($e.watch.number)\($suffix): \($summary). Read: gh \($kind) view \($e.watch.number) --repo \($e.watch.repo) --comments"
				end),
			state: ($e.state + {checked: $now, baseline: $cur, comments_seen: $count, last_comment_id: $last})
		}' "$issue_file"
	return 0
}

# Comments updated since $3 (epoch seconds) into $4, following pagination for up
# to RELAY_WATCH_COMMENT_PAGES pages. Returns 1 when a read fails, so the
# caller keeps its state and retries the whole window.
_relay_watch_fetch_comments() {
	local repo="$1"
	local issue_number="$2"
	local since="$3"
	local output="$4"
	local since_iso page=1 page_file count
	since_iso=$(jq -rn --argjson s "$since" '$s | todateiso8601') || return 1
	printf '[]\n' >"$output" || return 1
	while [[ "$page" -le "$RELAY_WATCH_COMMENT_PAGES" ]]; do
		page_file="${output%.json}-page${page}.json"
		_relay_get "repos/${repo}/issues/${issue_number}/comments?since=${since_iso}&per_page=${RELAY_PAGE}&page=${page}" \
			"$page_file" "watch-comments" || return 1
		count=$(jq 'if type == "array" then length else -1 end' "$page_file" 2>/dev/null || printf '%s' "-1")
		[[ "$count" =~ ^[0-9]+$ ]] || return 1
		if ! jq -s '.[0] + .[1]' "$output" "$page_file" >"${output}.tmp" 2>/dev/null || ! mv -f "${output}.tmp" "$output"; then
			return 1
		fi
		[[ "$count" -lt "$RELAY_PAGE" ]] && return 0
		page=$((page + 1))
	done
	_relay_log "watch comments ${repo}#${issue_number}: over ${RELAY_WATCH_COMMENT_PAGES} pages since the last check; later comments are not listed"
	return 0
}

# Check one due watch; append its result to the subscriber's batch.
_relay_watch_one() {
	local entry="$1"
	local work="$2"
	local now="$3"
	local subscriber key repo issue_number created issue_file
	subscriber=$(jq -r '.state.subscriber' <<<"$entry")
	key=$(jq -r '.state.key' <<<"$entry")
	repo=$(jq -r '.state.repo' <<<"$entry")
	issue_number=$(jq -r '.state.number' <<<"$entry")
	created=$(jq -r '.state.created' <<<"$entry")
	issue_file="${work}/watch-issue-${subscriber}-${key}.json"

	if ! _relay_get "repos/${repo}/issues/${issue_number}" "$issue_file" "watch-issue"; then
		# A missing item (typo, deleted, or no access) is told once and not read again.
		# "gh: Not Found (HTTP 404)" survives the excerpt as "not found"; transport
		# and deferral failures never match it.
		if [[ "$RELAY_FAILURE" == "gh-rc="*" not found"* ]]; then
			# A private repo that lost access also reads as 404: mark gone only when
			# the repository itself is readable, otherwise keep the watch state.
			if ! _relay_get "repos/${repo}" "${work}/watch-repo-${subscriber}-${key}.json" "watch-repo"; then
				_relay_log "watch ${repo}#${issue_number} not found but repository unreadable (${RELAY_FAILURE:-read}); watch keeps its state"
				return 0
			fi
			jq -nc --argjson e "$entry" --argjson now "$now" '{
				line: "- \($e.state.repo)#\($e.state.number): not found on GitHub (wrong number, deleted, or no access); this watch is no longer checked.",
				state: ($e.state + {checked: $now, gone: true})}' >>"${work}/watch-batch-${subscriber}.jsonl" || true
			return 0
		fi
		_relay_log "watch ${repo}#${issue_number} deferred or failed (${RELAY_FAILURE:-read}); watch keeps its state"
		return 0
	fi

	local count seen last_id updated comments='[]' retry_comments=0
	count=$(jq -r '.comments // 0' "$issue_file")
	seen=$(jq -r '.state.comments_seen' <<<"$entry")
	last_id=$(jq -r '.state.last_comment_id' <<<"$entry")
	updated=$(jq -r '(.updated_at // "1970-01-01T00:00:00Z") | fromdateiso8601' "$issue_file" 2>/dev/null || printf '0')
	local new_last="$last_id"
	if [[ "$count" != "$seen" && "$count" -gt 0 && "$updated" -ge "$created" ]]; then
		local comments_file="${work}/watch-comments-${subscriber}-${key}.json" comments_since
		# Comments since the previous check (with slack), or since the watch began.
		comments_since=$(jq -r '.state | if .checked > 0 then ([.created, .checked - 60] | max) else .created end' <<<"$entry")
		if _relay_watch_fetch_comments "$repo" "$issue_number" "$comments_since" "$comments_file"; then
			comments=$(_relay_watch_comments "$comments_file" "$last_id" "$created")
			[[ -n "$comments" ]] || comments='[]'
			new_last=$(jq -r --argjson last "$last_id" '[.[]?.id | numbers] + [$last] | max' "$comments_file")
		else
			_relay_log "watch comments ${repo}#${issue_number} deferred or failed (${RELAY_FAILURE}); will retry"
			count="$seen"
			retry_comments=1
		fi
	fi

	local result line
	result=$(_relay_watch_diff "$entry" "$issue_file" "$comments" "$count" "$new_last" "$now") || return 0
	[[ -n "$result" ]] || return 0
	if [[ "$retry_comments" -eq 1 ]]; then
		# Keep the previous check time, so the comments read is retried.
		result=$(jq -c --argjson e "$entry" '.state.checked = $e.state.checked' <<<"$result") || return 0
	fi
	line=$(jq -r '.line' <<<"$result")
	if [[ -z "$line" ]]; then
		_relay_watch_write_state "$(jq -c '.state' <<<"$result")" || true
		return 0
	fi
	jq -c '.' <<<"$result" >>"${work}/watch-batch-${subscriber}.jsonl"
	return 0
}

# One message per subscriber, holding only complete pointers that fit the bus
# text limit. Only the items it lists advance their state; on a failed send
# nothing is written, so the next run reads them again.
_relay_watch_send() {
	local batch="$1"
	local work="$2"
	local subscriber text_file plan_file listed
	subscriber=$(basename "$batch" .jsonl)
	subscriber="${subscriber#watch-batch-}"
	text_file="${work}/watch-message-${subscriber}.txt"
	plan_file="${work}/watch-plan-${subscriber}.json"
	jq -s --argjson max "$RELAY_WATCH_PER_MESSAGE" --argjson chars "$RELAY_WATCH_MESSAGE_CHARS" '
		"Issue watch: changes on items this session watches (from any runner):" as $head
		| "These are pointers; verify them on GitHub, which stays the record. Stop one with: aidevops sessions watch-issue <owner/repo#N> --off" as $foot
		| [.[].line] as $lines
		# Reserve room for the header, footer and the "more follow" line.
		| ($chars - ($head | length) - ($foot | length) - 80) as $budget
		| (reduce $lines[:$max][] as $line ({n: 0, used: 0, open: true};
			if .open and .used + ($line | length) + 1 <= $budget then .n += 1 | .used += ($line | length) + 1
			else .open = false end)) as $fit
		| ([$fit.n, 1] | max) as $n
		| {listed: $n, text: ([$head] + $lines[:$n]
			+ (if ($lines | length) > $n then ["- \(($lines | length) - $n) more changed item(s) follow in the next relay pass."] else [] end)
			+ [$foot] | join("\n") | .[0:$chars])}' "$batch" >"$plan_file" 2>/dev/null || return 0
	listed=$(jq -r '.listed' "$plan_file")
	[[ "$listed" =~ ^[0-9]+$ ]] || return 0
	jq -r '.text' "$plan_file" >"$text_file" || return 0
	if ! _relay_bus send "$subscriber" --sender "$RELAY_SENDER" --text-file "$text_file" >/dev/null 2>&1; then
		_relay_log "watch notice to ${subscriber} failed; will retry"
		return 0
	fi
	_relay_log "watch notice to ${subscriber}: items=${listed}"
	local state
	while IFS= read -r state; do
		[[ -n "$state" ]] && { _relay_watch_write_state "$state" || true; }
	done < <(jq -c --argjson n "$listed" -s '.[:$n][] | .state' "$batch")
	return 0
}

# The issue-watch pass; called by cmd_relay under the single-runner lock.
_relay_watches() {
	local work="$1"
	local now="$2"
	local watches_file="${work}/watches.json" due_file="${work}/watch-due.jsonl" repo
	_relay_bus watches --all --json >"$watches_file" 2>/dev/null || return 0
	jq -e 'type == "array"' "$watches_file" >/dev/null 2>&1 || return 0
	_relay_watch_prune_state "$watches_file"
	_relay_watch_due "$watches_file" "$now" "$due_file"
	[[ -s "$due_file" ]] || return 0
	# Stop reading before the relay watchdog so completed batches are still sent;
	# unreached watches keep their state and stay due for the next run.
	local budget="${RELAY_WATCH_PASS_BUDGET:-60}" started=$SECONDS out_of_time=0
	[[ "$budget" =~ ^[0-9]+$ ]] || budget=60
	while IFS= read -r repo; do
		[[ "$out_of_time" -eq 0 ]] || break
		[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || continue
		local entry
		while IFS= read -r entry; do
			[[ -n "$entry" ]] || continue
			if [[ $((SECONDS - started)) -ge "$budget" ]]; then
				out_of_time=1
				_relay_log "watch pass reached its ${budget}s budget; remaining watches stay due"
				break
			fi
			_relay_watch_one "$entry" "$work" "$now" || true
		done < <(jq -c --arg repo "$repo" 'select(.state.repo == $repo)' "$due_file")
	done < <(jq -rs '[.[].state.repo] | unique | .[]' "$due_file" 2>/dev/null)
	local batch
	for batch in "$work"/watch-batch-*.jsonl; do
		[[ -s "$batch" ]] || continue
		_relay_watch_send "$batch" "$work" || true
	done
	return 0
}
