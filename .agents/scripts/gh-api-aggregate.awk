# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh-api-aggregate.awk -- Aggregate gh API call records into JSON (t2902)
# =============================================================================
# Reads tab-separated log lines `<unix_ts>\t<caller>\t<path>` (legacy) or
# `<unix_ts>\t<caller>\t<path>\t<auth>\t<pool>\t<decision>\t<budget>` and writes a
# JSON report keyed by caller. Designed for BSD awk (macOS default) — does
# not use systime() or other gawk extensions; receives `now` from the caller.
#
# Required -v variables:
#   now    — current unix timestamp (passed from bash; BSD awk lacks systime)
#   cutoff — entries older than this unix ts are ignored
#   window — window seconds (echoed in _meta.window_seconds)
#
# Path enum:
#   graphql | rest | search-graphql | search-rest | other
#
# Output: one JSON document on stdout.
#
# Used by: gh-api-instrument.sh (gh_aggregate_calls)
# =============================================================================

BEGIN { total = 0 }

function emit_count_section(title, keys, counts,    n, i, j, tmp, key, swap) {
	printf "  \"%s\": {\n", title
	n = 0
	for (key in keys) tmp[++n] = key
	for (i = 2; i <= n; i++) {
		for (j = i; j > 1 && tmp[j-1] > tmp[j]; j--) {
			swap = tmp[j]; tmp[j] = tmp[j-1]; tmp[j-1] = swap
		}
	}
	for (i = 1; i <= n; i++) {
		key = tmp[i]
		if (i > 1) print ","
		printf "    \"%s\": {\"total\": %d}", key, counts[key] + 0
	}
	if (n > 0) print ""
	print "  }"
}

# Sanity: skip lines that do not parse as <int>\t<caller>\t<path>
$1 ~ /^[0-9]+$/ && NF >= 3 && $1 >= cutoff {
	caller = $2
	path = $3
	auth = (NF >= 4 && $4 != "") ? $4 : "unknown"
	pool = (NF >= 5 && $5 != "") ? $5 : path
	decision = (NF >= 6 && $6 != "") ? $6 : "unspecified"
	budget = (NF >= 7) ? $7 : ""
	callers[caller] = 1
	auth_keys[auth] = 1
	pool_keys[pool] = 1
	decision_keys[decision] = 1
	if      (path == "graphql")        graphql[caller]++
	else if (path == "rest")           rest[caller]++
	else if (path == "search-graphql") sg[caller]++
	else if (path == "search-rest")    sr[caller]++
	else                                other[caller]++
	auth_counts[auth]++
	pool_counts[pool]++
	decision_counts[decision]++
	if (budget ~ /^[0-9]+$/) {
		budget_keys[pool] = 1
		budget_last[pool] = budget
		if (!(pool in budget_min) || budget + 0 < budget_min[pool] + 0) budget_min[pool] = budget
	}
	total++
}

END {
	print "{"
	print "  \"_meta\": {"
	printf "    \"generated_at_ts\": %d,\n", now
	printf "    \"since_ts\":        %d,\n", cutoff
	printf "    \"window_seconds\":  %d,\n", window
	printf "    \"total_calls\":     %d\n",  total
	print "  },"
	print "  \"by_caller\": {"
	# Sort caller keys for deterministic output.
	n = 0
	for (c in callers) keys[++n] = c
	for (i = 2; i <= n; i++) {
		for (j = i; j > 1 && keys[j-1] > keys[j]; j--) {
			t = keys[j]; keys[j] = keys[j-1]; keys[j-1] = t
		}
	}
	for (i = 1; i <= n; i++) {
		c = keys[i]
		g   = graphql[c] + 0
		r   = rest[c]    + 0
		s_g = sg[c]      + 0
		s_r = sr[c]      + 0
		o   = other[c]   + 0
		if (i > 1) print ","
		printf "    \"%s\": {\n", c
		printf "      \"graphql_calls\":        %d,\n", g
		printf "      \"rest_calls\":           %d,\n", r
		printf "      \"search_graphql_calls\": %d,\n", s_g
		printf "      \"search_rest_calls\":    %d,\n", s_r
		printf "      \"other_calls\":          %d,\n", o
		printf "      \"total\":                %d\n",  g + r + s_g + s_r + o
		printf "    }"
	}
	if (n > 0) print ""
	print "  },"
	emit_count_section("by_auth_mode", auth_keys, auth_counts)
	print ","
	emit_count_section("by_api_pool", pool_keys, pool_counts)
	print ","
	emit_count_section("by_route_decision", decision_keys, decision_counts)
	print ","
	print "  \"budget_by_pool\": {"
	nb = 0
	for (b in budget_keys) bkeys[++nb] = b
	for (i = 2; i <= nb; i++) {
		for (j = i; j > 1 && bkeys[j-1] > bkeys[j]; j--) {
			t = bkeys[j]; bkeys[j] = bkeys[j-1]; bkeys[j-1] = t
		}
	}
	for (i = 1; i <= nb; i++) {
		b = bkeys[i]
		if (i > 1) print ","
		printf "    \"%s\": {\"min_remaining\": %d, \"last_remaining\": %d}", b, budget_min[b] + 0, budget_last[b] + 0
	}
	if (nb > 0) print ""
	print "  }"
	print "}"
}
