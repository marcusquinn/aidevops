#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Resumable dependency-cache writes. Sourced by pulse-dep-graph.sh.

# Seed only registered repositories, retaining their original freshness. Legacy
# entries have unknown age even though checkpointing updates the file's mtime.
_dep_graph_checkpoint_seed() {
	local old_graph="$1" repos="$2" timestamp="$3" slugs=""
	slugs=$(printf '%s\n' "$repos" | jq -sc '[.[].slug]') || return 1
	if ! printf '%s\n' "$old_graph" | jq -e '.repos | type == "object"' >/dev/null 2>&1; then
		old_graph='{}'
	fi
	printf '%s\n' "$old_graph" | jq -c --argjson slugs "$slugs" --arg timestamp "$timestamp" '
		{built_at:$timestamp, rebuild_complete:false,
		 repos:((.repos // {}) | with_entries(select(.key as $s | $slugs | index($s)))
		 | map_values(.built_at //= 0))}' || return 1
	return 0
}

# A watchdog may kill the builder between repositories. Process the oldest
# successful snapshots first next time rather than restarting at repos.json[0].
_dep_graph_checkpoint_order() {
	local repos="$1" graph="$2" ages=""
	ages=$(printf '%s\n' "$graph" | jq -c '.repos | map_values(.built_at // 0)') || return 1
	printf '%s\n' "$repos" | jq -sc --argjson ages "$ages" 'sort_by($ages[.slug] // 0)[]' || return 1
	return 0
}

# The parent watchdog remains authoritative. Yield before it expires so an
# incomplete pass is retryable and downstream recovery is not marked complete.
_dep_graph_checkpoint_budget_allows() {
	local deadline="${PULSE_STAGE_DEADLINE_EPOCH:-}" now=""
	[[ "$deadline" =~ ^[1-9][0-9]*$ ]] || return 0
	now=$(date +%s) || return 1
	if [[ $((deadline - now)) -le 20 ]]; then
		printf '%s\n' '[pulse-wrapper] dep-graph-cache: stage deadline near; preserving partial rebuild for resume' >>"$LOGFILE"
		return 1
	fi
	return 0
}

# Each writer owns a unique sibling temporary file. A failed write leaves the
# previous checkpoint intact; callers must not claim a completed rebuild.
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
