#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Live external-issue intake, independent of prefetch and reconciliation cursor.

# Pulse provides the shared budget and bounded-read helpers. Do not load them
# here: sourcing intake must not replace the orchestrator's transport wrappers.

_pir_new_external_iso() {
	local epoch="$1"
	if [[ "$(uname)" == Darwin ]]; then
		date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' || return 1
	else
		date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ' || return 1
	fi
	return 0
}

_pir_new_external_search() {
	local qualifiers="$1" start="$2" end="$3"
	local lower="" upper="" search="" count=0
	lower=$(_pir_new_external_iso "$start") || return 1
	upper=$(_pir_new_external_iso "$end") || return 1
	search="$qualifiers created:${lower}..${upper}"
	local cursor="" response="" next="" rows="" all_rows=""
	local slug="" number="" association="" login="" actor_type="" labels="" rc=0
	local query="query(\$search:String!,\$cursor:String){search(query:\$search,type:ISSUE,first:100,after:\$cursor){issueCount pageInfo{hasNextPage endCursor} nodes{... on Issue{number repository{nameWithOwner} authorAssociation author{login __typename} labels(first:100){nodes{name} pageInfo{hasNextPage}}}}}}"
	while :; do
		# Respect both the shared circuit breaker and GraphQL reserve policy;
		# REST dispatch fallback is not permission to run a GraphQL search.
		is_graphql_budget_sufficient || return 1
		local decision=""
		decision=$(_pulse_graphql_budget_priority_decision) || return 1
		[[ "$decision" == normal\ * ]] || return 1
		local -a args=(api graphql -f "query=$query" -f "search=$search")
		[[ -z "$cursor" ]] || args+=(-f "cursor=$cursor")
		response=$(_cb_gh_read gh "${args[@]}") || return 1
		# Never checkpoint partial GraphQL errors or malformed data.
		printf '%s' "$response" | jq -e '
			((.errors // []) | length == 0) and
			(.data.search.issueCount | type == "number" and . >= 0) and
			(.data.search.nodes | type == "array") and
			(.data.search.pageInfo.hasNextPage | type == "boolean")' >/dev/null || return 1
		count=$(printf '%s' "$response" | jq -r '.data.search.issueCount') || return 1
		if [[ "$count" -gt 1000 ]]; then
			# Split busy windows instead of permanently retrying the search cap.
			# Non-overlapping seconds avoid duplicate edits between subdivisions.
			[[ "$start" -lt "$end" ]] || return 1
			local middle=$((start + (end - start) / 2))
			_pir_new_external_search "$qualifiers" "$start" "$middle" || return 1
			_pir_new_external_search "$qualifiers" "$((middle + 1))" "$end" || return 1
			return 0
		fi
		rows=$(printf '%s' "$response" | jq -r '.data.search.nodes[] |
			[.repository.nameWithOwner, (.number|tostring), .authorAssociation,
			 .author.login // "", .author.__typename // "", ([.labels.nodes[].name]|join(","))] | join("\u001f")') || return 1
		all_rows+="${rows}"$'\n'
		if printf '%s' "$response" | jq -e '.data.search.nodes[] | select(.labels.pageInfo.hasNextPage == true)' >/dev/null; then
			return 1
		fi
		next=$(printf '%s' "$response" | jq -r 'if .data.search.pageInfo.hasNextPage then .data.search.pageInfo.endCursor // "" else "" end') || return 1
		if [[ -z "$next" ]]; then
			printf '%s' "$response" | jq -e '.data.search.pageInfo.hasNextPage == false' >/dev/null || return 1
			break
		fi
		[[ "$next" != "$cursor" ]] || return 1
		cursor="$next"
	done
	# Gather pages before edits: adding the excluded label must not shift the
	# search cursor and skip the next page. Deduplicate overlapping search rows.
	local seen="," normalized_search="" normalized_slug=""
	normalized_search=$(printf '%s' "$search" | tr '[:upper:]' '[:lower:]') || return 1
	while IFS=$'\x1f' read -r slug number association login actor_type labels; do
		[[ -n "$slug" ]] || continue
		normalized_slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]') || return 1
		[[ " $normalized_search " == *" repo:${normalized_slug} "* && "$number" =~ ^[1-9][0-9]*$ ]] || return 1
		[[ "$seen" != *",${normalized_slug}#${number},"* ]] || continue
		seen+="${normalized_slug}#${number},"
		_PIR_NEW_CHECKED=$((_PIR_NEW_CHECKED + 1))
		_pir_labels_csv_contains "$labels" "$_PIR_NMR_LABEL" && continue
		_should_reconcile_external_issue_gate "$association" "$actor_type" false || continue
		rc=0
		_action_reconcile_external_issue_gate "$slug" "$number" "$labels" "$association" "$login" || rc=$?
		if [[ "${_PIR_EXTERNAL_GATE_MUTATED:-0}" -eq 1 ]]; then
			_PIR_NEW_GATED=$((_PIR_NEW_GATED + 1))
		elif [[ "$rc" -eq 0 ]]; then
			_PIR_NEW_COMPLETE=0
		fi
	done <<<"$all_rows"
	return 0
}

reconcile_new_external_issues() {
	local state_dir="${HOME}/.aidevops/state"
	local state_file="${state_dir}/pulse-new-external-issues.json"
	local now="" last="" slugs="" slug="" batch="" qualifier="" rc=0
	local _PIR_NEW_CHECKED=0 _PIR_NEW_GATED=0 _PIR_NEW_COMPLETE=1
	now=$(date +%s) || return 1
	if [[ -f "$state_file" ]]; then
		last=$(jq -r '.last_run // empty' "$state_file" 2>/dev/null) || last=""
	fi
	if [[ "$last" =~ ^[0-9]+$ && "$last" -le "$now" ]]; then
		last=$((last - 600))
	else
		last=$((now - 86400))
	fi
	slugs=$(jq -er '[.initialized_repos[] |
		select(.maintenance != false and .pulse == true and (.local_only // false) == false) |
		.slug // empty | select(test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))] | unique | .[]' "$REPOS_JSON") || rc=1
	local base="is:issue is:open -label:${_PIR_NMR_LABEL}"
	batch="$base"
	if [[ "$rc" -eq 0 ]]; then
		while IFS= read -r slug; do
			[[ -n "$slug" ]] || continue
			qualifier=" repo:${slug}"
			# Reserve 51 characters for the inclusive UTC creation-time range.
			if [[ $((${#batch} + ${#qualifier} + 51)) -gt 240 && "$batch" != "$base" ]]; then
				_pir_new_external_search "$batch" "$last" "$now" || { rc=1; break; }
				batch="$base"
			fi
			batch+="$qualifier"
		done <<<"$slugs"
		if [[ "$rc" -eq 0 && "$batch" != "$base" ]]; then
			_pir_new_external_search "$batch" "$last" "$now" || rc=1
		fi
	fi
	if [[ "$rc" -eq 0 && "$_PIR_NEW_COMPLETE" -eq 1 ]]; then
		mkdir -p "$state_dir" || return 1
		# Only a complete successful window advances the watermark. Atomic rename
		# leaves the previous window intact if the stage timeout interrupts us.
		local temporary="${state_file}.$$"
		printf '{"last_run":%s}\n' "$now" >"$temporary" && mv "$temporary" "$state_file" || rc=1
	fi
	printf '[pulse-wrapper] New external issue sweep: checked=%s gated=%s\n' "$_PIR_NEW_CHECKED" "$_PIR_NEW_GATED" >>"$LOGFILE"
	[[ "$rc" -eq 0 && "$_PIR_NEW_COMPLETE" -eq 1 ]] || return 1
	return 0
}
