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
# GitHub cost per interval: one issue-list call (`since=`) per repo with due
# watches, one issue read for a watch first seen outside that listing, and one
# comments read only when an item's comment count rose. Every read goes
# through _relay_get (stop flag, breaker, REST-core deferrable gate).
# Docs: reference/session-bus.md "Issue watches".

# Labels whose changes are progress news for a watcher (#aidevops:trust-boundary:
# names only, sanitised; maintainers own label creation).
RELAY_WATCH_LABELS_RE='^(status:[a-z-]+|hold-for-review|needs-maintainer-review)$'
# A fresh watch (the session just created the item) reports a worker pickup or
# closure that beat the first pass: these dispatch labels and the assignees then
# count as new.
# Creation labels vary (status:available default, explicit status:*, publication
# holds), so everything else seen first is the baseline.
RELAY_WATCH_PICKUP_LABELS='["status:queued","status:in-progress"]'
# Items listed per message; the rest keep their state and go in the next pass.
RELAY_WATCH_PER_MESSAGE=6

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
			| {watch: $w, state: ({
				v: 1, subscriber: $w.subscriber, key: $w.key, repo: $w.repo, number: $w.number,
				created: (($w.created_ms // 0) / 1000 | floor), checked: 0, baseline: null,
				comments_seen: -1, last_comment_id: 0
			} + (if ($state.key // "") == $w.key then $state else {} end))}
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
		def changes($added; $removed): [($added[] | "+" + .), ($removed[] | "-" + .)] | join(" ");
		"open" as $open | "closed" as $closed
		| . as $i
		| ($i.pull_request != null) as $pr
		| {labels: ([$i.labels[]? | (.name // "") | clean | select(test($re))] | unique),
			assignees: ([$i.assignees[]? | (.login // "") | gsub("[^A-Za-z0-9-]"; "") | select(. != "")] | unique),
			state: ($i.state // $open)} as $cur
		| [$cur.labels[] | select(IN($pickup[]))] as $picked
		| (if $e.state.baseline != null then $e.state.baseline
			elif $e.watch.fresh == true then
				($cur | .state = $open
					| if ($picked | length) > 0 or $cur.state == $closed then .labels -= $picked | .assignees = [] else . end)
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

# Check one due watch; append its result to the subscriber's batch.
_relay_watch_one() {
	local entry="$1"
	local list_file="$2"
	local work="$3"
	local now="$4"
	local subscriber key repo issue_number created need_fetch issue_file rc=0
	subscriber=$(jq -r '.state.subscriber' <<<"$entry")
	key=$(jq -r '.state.key' <<<"$entry")
	repo=$(jq -r '.state.repo' <<<"$entry")
	issue_number=$(jq -r '.state.number' <<<"$entry")
	created=$(jq -r '.state.created' <<<"$entry")
	need_fetch=$(jq -r 'if .state.baseline == null then "1" else "0" end' <<<"$entry")
	issue_file="${work}/watch-issue-${subscriber}-${key}.json"

	_relay_issue_from_listing "$list_file" "$repo" "$issue_number" "$need_fetch" "$issue_file" || rc=$?
	if [[ "$rc" -eq 2 ]]; then
		# Unchanged since the listing's `since`: only the check time moves.
		_relay_watch_write_state "$(jq -c --argjson now "$now" '.state | .checked = $now' <<<"$entry")" || true
		return 0
	fi
	if [[ "$rc" -ne 0 ]]; then
		# A missing item (typo, deleted, or no access) is told once and not read again.
		# The repo listing just succeeded, so a 404 here is the item, not the repo
		# or transport ("gh: Not Found (HTTP 404)" survives the excerpt as "not found").
		if [[ "$RELAY_FAILURE" == "gh-rc="*" not found"* ]]; then
			jq -nc --argjson e "$entry" --argjson now "$now" '{
				line: "- \($e.state.repo)#\($e.state.number): not found on GitHub (wrong number, deleted, or no access); this watch is no longer checked.",
				state: ($e.state + {checked: $now, gone: true})}' >>"${work}/watch-batch-${subscriber}.jsonl" || true
			return 0
		fi
		_relay_log "watch ${repo}#${issue_number} deferred or failed (${RELAY_FAILURE:-listing-parse}); watch keeps its state"
		return 0
	fi

	local count seen last_id updated comments='[]'
	count=$(jq -r '.comments // 0' "$issue_file")
	seen=$(jq -r '.state.comments_seen' <<<"$entry")
	last_id=$(jq -r '.state.last_comment_id' <<<"$entry")
	updated=$(jq -r '(.updated_at // "1970-01-01T00:00:00Z") | fromdateiso8601' "$issue_file" 2>/dev/null || printf '0')
	local new_last="$last_id"
	if [[ "$count" != "$seen" && "$count" -gt 0 && "$updated" -ge "$created" ]]; then
		local comments_file="${work}/watch-comments-${subscriber}-${key}.json" since_iso
		since_iso=$(jq -rn --argjson s "$created" '$s | todateiso8601')
		if _relay_get "repos/${repo}/issues/${issue_number}/comments?since=${since_iso}&per_page=${RELAY_PAGE}" "$comments_file" "watch-comments"; then
			comments=$(_relay_watch_comments "$comments_file" "$last_id" "$created")
			[[ -n "$comments" ]] || comments='[]'
			new_last=$(jq -r --argjson last "$last_id" '[.[]?.id | numbers] + [$last] | max' "$comments_file")
		else
			_relay_log "watch comments ${repo}#${issue_number} deferred or failed (${RELAY_FAILURE}); will retry"
			count="$seen"
		fi
	fi

	local result line
	result=$(_relay_watch_diff "$entry" "$issue_file" "$comments" "$count" "$new_last" "$now") || return 0
	[[ -n "$result" ]] || return 0
	line=$(jq -r '.line' <<<"$result")
	if [[ -z "$line" ]]; then
		_relay_watch_write_state "$(jq -c '.state' <<<"$result")" || true
		return 0
	fi
	jq -c '.' <<<"$result" >>"${work}/watch-batch-${subscriber}.jsonl"
	return 0
}

# One message per subscriber. Only the items it lists advance their state; on a
# failed send nothing is written, so the next run reads from the old `since`.
_relay_watch_send() {
	local batch="$1"
	local work="$2"
	local subscriber text_file total
	subscriber=$(basename "$batch" .jsonl)
	subscriber="${subscriber#watch-batch-}"
	text_file="${work}/watch-message-${subscriber}.txt"
	total=$(jq -s 'length' "$batch")
	jq -rs --argjson max "$RELAY_WATCH_PER_MESSAGE" '
		(["Issue watch: changes on items this session watches (from any runner):"]
			+ [.[:$max][] | .line]
			+ (if length > $max then ["- \(length - $max) more changed item(s) follow in the next relay pass."] else [] end)
			+ ["These are pointers; verify them on GitHub, which stays the record. Stop one with: aidevops sessions watch-issue <owner/repo#N> --off"])
		| join("\n") | .[0:1990]' "$batch" >"$text_file" || return 0
	if ! _relay_bus send "$subscriber" --sender "$RELAY_SENDER" --text-file "$text_file" >/dev/null 2>&1; then
		_relay_log "watch notice to ${subscriber} failed; will retry"
		return 0
	fi
	_relay_log "watch notice to ${subscriber}: items=$((total < RELAY_WATCH_PER_MESSAGE ? total : RELAY_WATCH_PER_MESSAGE))"
	local state
	while IFS= read -r state; do
		[[ -n "$state" ]] && { _relay_watch_write_state "$state" || true; }
	done < <(jq -c --argjson max "$RELAY_WATCH_PER_MESSAGE" -s '.[:$max][] | .state' "$batch")
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
	while IFS= read -r repo; do
		[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || continue
		local since since_iso slug list_file entry
		since=$(jq -s --arg repo "$repo" '[.[] | select(.state.repo == $repo)
			| (if .state.checked > 0 then .state.checked else .state.created end) - 60] | min' "$due_file")
		[[ "$since" =~ ^-?[0-9]+$ ]] || continue
		[[ "$since" -gt 0 ]] || since=0
		since_iso=$(jq -rn --argjson s "$since" '$s | todateiso8601')
		slug=$(printf '%s' "$repo" | tr '/' '_')
		list_file="${work}/watch-list-${slug}.json"
		if ! _relay_get "repos/${repo}/issues?state=all&since=${since_iso}&per_page=${RELAY_PAGE}&sort=updated&direction=desc" \
			"$list_file" "watch-list"; then
			_relay_log "watch listing ${repo} deferred or failed (${RELAY_FAILURE}); watches keep their state"
			continue
		fi
		while IFS= read -r entry; do
			[[ -n "$entry" ]] || continue
			_relay_watch_one "$entry" "$list_file" "$work" "$now" || true
		done < <(jq -c --arg repo "$repo" 'select(.state.repo == $repo)' "$due_file")
	done < <(jq -rs '[.[].state.repo] | unique | .[]' "$due_file" 2>/dev/null)
	local batch
	for batch in "$work"/watch-batch-*.jsonl; do
		[[ -s "$batch" ]] || continue
		_relay_watch_send "$batch" "$work" || true
	done
	return 0
}
