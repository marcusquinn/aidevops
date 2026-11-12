#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Resumable dependency graph checkpoints; sourced by pulse-dep-graph.sh.

# Retain only enabled repositories, without promoting their freshness. The
# generation start survives retries, even when rebuilding takes longer than TTL.
_dep_graph_checkpoint_seed() {
	local previous="$1" repos="$2" now="$3" slugs=""
	slugs=$(printf '%s\n' "$repos" | jq -sc '[.[].slug | select(type == "string" and length > 0)] | unique') || return 1
	if ! printf '%s\n' "$previous" | jq -e '.repos | type == "object"' >/dev/null 2>&1; then
		previous='{}'
	fi
	printf '%s\n' "$previous" | jq -c --argjson slugs "$slugs" --argjson now "$now" '
		. as $old
		| (if .rebuild_complete == false and (.rebuild_pending | type) == "array"
		   then [.rebuild_pending[], ($slugs[] | select($old.repos[.] == null))] | unique
		   else $slugs end) as $pending
		|
		(if .rebuild_complete == false and (.rebuild_started_at | type) == "number"
			and .rebuild_started_at > 0 and .rebuild_started_at <= $now
		 then .rebuild_started_at else $now end) as $start
		| {built_at:($start | todateiso8601), rebuild_started_at:$start,
		   rebuild_complete:false, rebuild_pending:($pending | map(select(. as $s | $slugs | index($s)))),
		   repos:((.repos // {})
		   | with_entries(select(.key as $key | $slugs | index($key)))
		   | map_values(.built_at //= 0))}' || return 1
	return 0
}

# Exclude this generation's successful reads and visit the oldest remaining
# snapshots first. Missing/legacy snapshots sort before successfully built data.
_dep_graph_checkpoint_order() {
	local repos="$1" graph="$2"
	printf '%s\n' "$repos" | jq -sc --argjson graph "$graph" '
		unique_by(.slug) | map(select(.slug | type == "string" and length > 0))
		| map(select(.slug as $s | $graph.rebuild_pending | index($s)))
		| sort_by($graph.repos[.slug].built_at // 0)[]' || return 1
	return 0
}

_dep_graph_checkpoint_budget_allows() {
	local deadline="${PULSE_STAGE_DEADLINE_EPOCH:-}" now=""
	[[ "$deadline" =~ ^[1-9][0-9]*$ ]] || return 0
	now=$(date +%s) || return 1
	[[ "$now" -lt "$deadline" ]] || return 1
	return 0
}

# Never fall back to a PID-only temporary name: both writers may share a PID.
# On any failure the last valid checkpoint remains visible to readers.
_dep_graph_checkpoint_write() {
	local cache_file="$1" graph="$2" complete="$3" temporary=""
	mkdir -p "$(dirname "$cache_file")" || return 1
	temporary=$(mktemp "${cache_file}.tmp.XXXXXX") || return 1
	if ! printf '%s\n' "$graph" | jq -c --argjson complete "$complete" \
		'.rebuild_complete = $complete' >"$temporary"; then
		rm -f "$temporary"
		return 1
	fi
	if ! mv "$temporary" "$cache_file"; then
		rm -f "$temporary"
		return 1
	fi
	return 0
}
