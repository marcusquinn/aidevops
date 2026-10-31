# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh-api-aggregate.awk -- Aggregate logical gh events and transport attempts
# =============================================================================
# Reads legacy three/seven-column records and versioned v2 records emitted by
# gh-api-instrument.sh. Legacy rows remain logical observations; they are never
# represented as proven network attempts. Designed for BSD awk (macOS default).
#
# Required -v variables: now (inclusive fixed-window end), cutoff, window
# Output: one deterministic JSON document on stdout.
# =============================================================================

BEGIN {
	total_calls = 0
	logical_events = 0
	cache_events = 0
	evidence_events = 0
	timeout_events = 0
	timeout_elapsed_ms = 0
	unknown_timeout_elapsed_events = 0
	legacy_events = 0
	attempted_requests = 0
	opaque_paginated_attempts = 0
}

function metric_add(group, value, metric, amount,    key) {
	if (value == "") value = "unknown"
	key = group SUBSEP value
	group_keys[key] = 1
	metrics[key SUBSEP metric] += amount
}

function metric_get(group, value, metric) {
	return metrics[group SUBSEP value SUBSEP metric] + 0
}

# auth_reason is a per-record global (field 18) so existing call sites keep
# their signature; it is reset for every record in the main rule.
function metric_add_dimensions(caller, path, auth, pool, decision, metric, amount) {
	metric_add("caller", caller, metric, amount)
	metric_add("path", path, metric, amount)
	metric_add("auth", auth, metric, amount)
	metric_add("reason", auth_reason, metric, amount)
	metric_add("consumer", auth_consumer, metric, amount)
	metric_add("pool", pool, metric, amount)
	metric_add("decision", decision, metric, amount)
}

function percentile(histogram, total, percent,    target, cumulative, key, values, n, i) {
	if (total < 1) return 0
	for (key in histogram) values[++n] = key + 0
	sort_values(values, n)
	target = int((total * percent + 99) / 100)
	for (i = 1; i <= n; i++) {
		cumulative += histogram[values[i]]
		if (cumulative >= target) return values[i]
	}
	return values[n] + 0
}

function sort_values(values, n,    i, j, swap) {
	for (i = 2; i <= n; i++) {
		for (j = i; j > 1 && values[j - 1] > values[j]; j--) {
			swap = values[j]
			values[j] = values[j - 1]
			values[j - 1] = swap
		}
	}
}

function emit_group(title, group,    pair, parts, values, n, i, value) {
	printf "  \"%s\": {\n", title
	n = 0
	for (pair in group_keys) {
		split(pair, parts, SUBSEP)
		if (parts[1] == group) values[++n] = parts[2]
	}
	sort_values(values, n)
	for (i = 1; i <= n; i++) {
		value = values[i]
		if (i > 1) print ","
		printf "    \"%s\": {\n", value
		printf "      \"graphql_calls\": %d,\n", metric_get(group, value, "graphql_calls")
		printf "      \"rest_calls\": %d,\n", metric_get(group, value, "rest_calls")
		printf "      \"search_graphql_calls\": %d,\n", metric_get(group, value, "search_graphql_calls")
		printf "      \"search_rest_calls\": %d,\n", metric_get(group, value, "search_rest_calls")
		printf "      \"other_calls\": %d,\n", metric_get(group, value, "other_calls")
		printf "      \"total\": %d,\n", metric_get(group, value, "total")
		printf "      \"logical_events\": %d,\n", metric_get(group, value, "logical_events")
		printf "      \"cache_events\": %d,\n", metric_get(group, value, "cache_events")
		printf "      \"evidence_events\": %d,\n", metric_get(group, value, "evidence_events")
		printf "      \"timeout_events\": %d,\n", metric_get(group, value, "timeout_events")
		printf "      \"timeout_elapsed_ms\": %d,\n", metric_get(group, value, "timeout_elapsed_ms")
		printf "      \"unknown_timeout_elapsed_events\": %d,\n", metric_get(group, value, "unknown_timeout_elapsed_events")
		printf "      \"legacy_events\": %d,\n", metric_get(group, value, "legacy_events")
		printf "      \"attempted_requests\": %d,\n", metric_get(group, value, "attempted_requests")
		printf "      \"opaque_paginated_attempts\": %d,\n", metric_get(group, value, "opaque_paginated_attempts")
		printf "      \"retries\": %d,\n", metric_get(group, value, "retries")
		printf "      \"pages\": %d,\n", metric_get(group, value, "pages")
		printf "      \"additional_pages\": %d,\n", metric_get(group, value, "additional_pages")
		printf "      \"successful_attempts\": %d,\n", metric_get(group, value, "successful_attempts")
		printf "      \"failed_attempts\": %d,\n", metric_get(group, value, "failed_attempts")
		printf "      \"elapsed_ms\": %d,\n", metric_get(group, value, "elapsed_ms")
		printf "      \"unknown_elapsed_attempts\": %d,\n", metric_get(group, value, "unknown_elapsed_attempts")
		printf "      \"known_quota_cost\": %d,\n", metric_get(group, value, "known_quota_cost")
		printf "      \"unknown_quota_cost_attempts\": %d\n", metric_get(group, value, "unknown_quota_cost_attempts")
		printf "    }"
	}
	if (n > 0) print ""
	print "  }"
}

function record_budget(pool, budget, ts) {
	if (budget !~ /^[0-9]+$/) return
	budget_keys[pool] = 1
	if (!(pool in budget_min) || budget + 0 < budget_min[pool] + 0) budget_min[pool] = budget
	if (!(pool in budget_last_ts) || ts >= budget_last_ts[pool]) {
		budget_last_ts[pool] = ts
		budget_last[pool] = budget
	}
}

function emit_budgets(    pool, values, n, i) {
	print "  \"budget_by_pool\": {"
	n = 0
	for (pool in budget_keys) values[++n] = pool
	sort_values(values, n)
	for (i = 1; i <= n; i++) {
		pool = values[i]
		if (i > 1) print ","
		printf "    \"%s\": {\"min_remaining\": %d, \"last_remaining\": %d}", pool, budget_min[pool] + 0, budget_last[pool] + 0
	}
	if (n > 0) print ""
	print "  }"
}

# A credential digest identifies an auth source, not necessarily a unique user
# quota: multiple tokens may share one upstream pool. Never merge them by guess.
# Old rows remain readable but cannot prove a pool/reset series.
function collect_quota(    series, row, minute) {
	if (pool != "rest-core") return
	if (length($20) != 64 || $20 !~ /^[a-f0-9]+$/ || $21 !~ /^[1-9][0-9]*$/) {
		unattributed_missing_metadata_attempts++
		# Native commands without response headers (for example writes) know
		# their credential and cost but not the reset series. Keep that cost
		# visible beside the same credential's residuals; never subtract it.
		if (length($20) == 64 && $20 ~ /^[a-f0-9]+$/ && quota_cost ~ /^[0-9]+$/) {
			minute = int(ts / 60) * 60
			quota_reset_unknown_cost[$20 SUBSEP minute] += quota_cost
			quota_reset_unknown_total[$20] += quota_cost
		}
		return
	}
	series = pool ":" $20 ":" $21
	quota_series[series] = 1
	row = ++quota_rows
	quota_order[row] = row
	quota_key[row] = series
	quota_ts[row] = ts
	quota_budget[row] = budget
	quota_logged[row] = quota_cost
}

# Concurrent processes append on completion; sort by captured sample time and,
# within a second, decreasing remaining. Ignore counter increases rather than
# creating negative drain. The first sample is a baseline, not an interval.
function replay_quota(    i, j, row, prev, series, drop, cost, minute, key, residual) {
	for (i = 2; i <= quota_rows; i++) {
		row = quota_order[i]
		j = i
		while (j > 1) {
			prev = quota_order[j - 1]
			if (quota_ts[prev] < quota_ts[row] || (quota_ts[prev] == quota_ts[row] && quota_budget[prev] + 0 >= quota_budget[row] + 0)) break
			quota_order[j] = prev
			j--
		}
		quota_order[j] = row
	}
	for (i = 1; i <= quota_rows; i++) {
		row = quota_order[i]
		series = quota_key[row]
		cost = quota_logged[row]
		if (cost ~ /^[0-9]+$/) quota_pending[series] += cost
		else quota_unknown[series]++
		if (quota_budget[row] !~ /^[0-9]+$/) continue
		if (series in quota_previous) {
			drop = quota_previous[series] - quota_budget[row]
			if (drop >= 0) {
				minute = int(quota_ts[row] / 60) * 60
				key = series SUBSEP minute
				quota_minutes[key] = 1
				quota_drops[series] += drop
				quota_costs[series] += quota_pending[series]
				quota_minute_drop[key] += drop
				quota_minute_cost[key] += quota_pending[series]
			} else quota_increases[series]++
		}
		quota_previous[series] = quota_budget[row] + 0
		quota_pending[series] = 0
	}
	for (key in quota_minutes) {
		residual = quota_minute_drop[key] - quota_minute_cost[key]
		quota_residual[key] = (residual > 0) ? residual : 0
		split(key, quota_parts, SUBSEP)
		quota_unattributed[quota_parts[1]] += quota_residual[key]
	}
}

function emit_quota_minutes(series, top,    key, parts, minutes, n, i, j, swap, a, b, fingerprint) {
	split(series, parts, ":")
	fingerprint = parts[2]
	n = 0
	for (key in quota_minutes) {
		split(key, parts, SUBSEP)
		if (parts[1] == series) minutes[++n] = parts[2] + 0
	}
	sort_values(minutes, n)
	if (top) {
		for (i = 2; i <= n; i++) {
			for (j = i; j > 1; j--) {
				a = quota_residual[series SUBSEP minutes[j - 1]]
				b = quota_residual[series SUBSEP minutes[j]]
				if (a >= b) break
				swap = minutes[j]; minutes[j] = minutes[j - 1]; minutes[j - 1] = swap
			}
		}
		if (n > 10) n = 10
	}
	printf "["
	for (i = 1; i <= n; i++) {
		key = series SUBSEP minutes[i]
		if (i > 1) printf ", "
		printf "{\"minute_ts\": %d, \"remaining_drop\": %d, \"logged_quota_cost\": %d, \"unattributed_cost\": %d, \"same_credential_reset_unknown_cost\": %d}", minutes[i], quota_minute_drop[key], quota_minute_cost[key], quota_residual[key], quota_reset_unknown_cost[fingerprint SUBSEP minutes[i]] + 0
	}
	printf "]"
}

function emit_quota(    series, values, n, i, parts) {
	replay_quota()
	print "  \"rest_core_attribution\": {"
	print "    \"minute_assignment\": \"interval-ending-sample\","
	print "    \"sample_time_basis\": \"command-completion-under-credential-lock\","
	print "    \"unattributed_is_upper_bound\": true,"
	printf "    \"missing_metadata_attempts\": %d,\n", unattributed_missing_metadata_attempts + 0
	print "    \"series\": ["
	for (series in quota_series) values[++n] = series
	sort_values(values, n)
	for (i = 1; i <= n; i++) {
		series = values[i]
		split(series, parts, ":")
		if (i > 1) print ","
		printf "      {\"pool\": \"%s\", \"auth_fingerprint\": \"%s\", \"reset_epoch\": %s, ", parts[1], parts[2], parts[3]
		printf "\"remaining_drop\": %d, \"logged_quota_cost\": %d, \"unattributed_cost\": %d, ", quota_drops[series], quota_costs[series], quota_unattributed[series]
		printf "\"unknown_cost_attempts\": %d, \"counter_increases\": %d, ", quota_unknown[series], quota_increases[series]
		# Credential-wide, not series-owned: a credential may span several resets.
		printf "\"same_credential_reset_unknown_cost\": %d, \"minutes\": ", quota_reset_unknown_total[parts[2]] + 0
		emit_quota_minutes(series, 0)
		printf ", \"top_unattributed_minutes\": "
		emit_quota_minutes(series, 1)
		printf "}"
	}
	if (n > 0) print ""
	print "    ]"
	print "  }"
}

# Reject records without a numeric timestamp or the legacy prefix.
$1 !~ /^[0-9]+$/ || NF < 3 {
	malformed_records++
	next
}

{
	auth_consumer = (NF >= 19 && $19 != "") ? $19 : "unknown"
	if (ENVIRON["AIDEVOPS_GH_REPORT_CONSUMER"] != "" && auth_consumer != ENVIRON["AIDEVOPS_GH_REPORT_CONSUMER"]) next
	ts = $1 + 0
	if (ts > now) next
	caller = ($2 != "") ? $2 : "unknown"
	path = ($3 != "") ? $3 : "other"
	auth = (NF >= 4 && $4 != "") ? $4 : "unknown"
	pool = (NF >= 5 && $5 != "") ? $5 : path
	decision = (NF >= 6 && $6 != "") ? $6 : "unspecified"
	budget = (NF >= 7) ? $7 : ""
	version = (NF >= 8) ? $8 : ""
	auth_reason = (NF >= 18 && $18 != "") ? $18 : "unrouted"
	attempt_unidentified = 0
	attempt_duplicate = 0
	attempt_page_unknown = 0

	if (version == "v2" && NF < 17) {
		malformed_records++
		malformed_v2_records++
		if (ts >= cutoff) window_malformed_v2_records++
		next
	}

	if (version == "v2") {
		kind = ($9 != "") ? $9 : "logical"
		logical_id = $10
		attempt_id = $11
		page = $12
		retry = $13
		outcome = ($14 != "") ? $14 : "unknown"
		http_status = $15
		elapsed_ms = $16
		quota_cost = $17
	} else {
		kind = "legacy"
		logical_id = ""
		attempt_id = ""
		page = ""
		retry = ""
		outcome = "unknown"
		http_status = ""
		elapsed_ms = ""
		quota_cost = ""
		retained_legacy_records++
	}

	retained_records++
	if (first_retained_record_ts == 0 || ts < first_retained_record_ts) first_retained_record_ts = ts
	if (ts > last_retained_record_ts) last_retained_record_ts = ts

	if (kind == "attempt") {
		if (attempt_id == "" || attempt_id == "unknown") {
			retained_unidentified_attempts++
			attempt_unidentified = 1
		} else if (attempt_id in seen_retained_attempt_id) {
			retained_duplicate_attempt_ids++
		} else {
			seen_retained_attempt_id[attempt_id] = 1
		}
		if (page !~ /^[0-9]+$/ || page + 0 < 1) {
			retained_unknown_page_attempts++
			attempt_page_unknown = 1
		}
		if (first_observed_attempt_ts == 0 || ts < first_observed_attempt_ts) first_observed_attempt_ts = ts
		if (ts > last_observed_attempt_ts) last_observed_attempt_ts = ts
	}

	if (ts < cutoff) next
	window_records++
	if (kind == "attempt" && !attempt_unidentified) {
		if (attempt_id in seen_window_attempt_id) {
			attempt_duplicate = 1
		} else {
			seen_window_attempt_id[attempt_id] = 1
		}
	}
	record_budget(pool, budget, ts)
	if (logical_id != "" && logical_id != "unknown" && !(logical_id in seen_window_logical_id)) {
		seen_window_logical_id[logical_id] = 1
		logical_operations++
	}

	if (kind == "evidence") {
		evidence_events++
		metric_add_dimensions(caller, path, auth, pool, decision, "evidence_events", 1)
		next
	}
	if (kind == "timeout") {
		timeout_events++
		metric_add_dimensions(caller, path, auth, pool, decision, "timeout_events", 1)
		metric_add("outcome", outcome, "timeout_events", 1)
		if (elapsed_ms ~ /^[0-9]+$/) {
			timeout_elapsed_ms += elapsed_ms
			metric_add_dimensions(caller, path, auth, pool, decision, "timeout_elapsed_ms", elapsed_ms)
		} else {
			unknown_timeout_elapsed_events++
			metric_add_dimensions(caller, path, auth, pool, decision, "unknown_timeout_elapsed_events", 1)
		}
		next
	}

	if (kind != "attempt") {
		total_calls++
		metric_add_dimensions(caller, path, auth, pool, decision, "total", 1)
		if (path == "graphql") call_metric = "graphql_calls"
		else if (path == "rest") call_metric = "rest_calls"
		else if (path == "search-graphql") call_metric = "search_graphql_calls"
		else if (path == "search-rest") call_metric = "search_rest_calls"
		else call_metric = "other_calls"
		metric_add_dimensions(caller, path, auth, pool, decision, call_metric, 1)
		if (kind == "cache") {
			cache_events++
			metric_add_dimensions(caller, path, auth, pool, decision, "cache_events", 1)
		} else if (kind == "legacy") {
			legacy_events++
			metric_add_dimensions(caller, path, auth, pool, decision, "legacy_events", 1)
		} else {
			logical_events++
			metric_add_dimensions(caller, path, auth, pool, decision, "logical_events", 1)
		}
		next
	}
	if (attempt_unidentified) unidentified_attempts++
	if (attempt_duplicate) {
		duplicate_attempt_ids++
		next
	}
	if (first_window_attempt_ts == 0 || ts < first_window_attempt_ts) first_window_attempt_ts = ts
	if (ts > last_window_attempt_ts) last_window_attempt_ts = ts
	if (attempt_page_unknown) unknown_page_attempts++
	collect_quota()

	attempted_requests++
	minute = int(ts / 60)
	minute_attempts[minute]++
	if (minute_attempts[minute] > peak_attempts_per_minute) {
		peak_attempts_per_minute = minute_attempts[minute]
	}
	metric_add_dimensions(caller, path, auth, pool, decision, "attempted_requests", 1)
	metric_add("outcome", outcome, "attempted_requests", 1)
	if (decision == "native-pagination-opaque") {
		opaque_paginated_attempts++
		metric_add_dimensions(caller, path, auth, pool, decision, "opaque_paginated_attempts", 1)
	}
	if (retry ~ /^[0-9]+$/ && retry + 0 > 0) {
		retries++
		metric_add_dimensions(caller, path, auth, pool, decision, "retries", 1)
		metric_add("outcome", outcome, "retries", 1)
	}
	if (page ~ /^[0-9]+$/ && page + 0 > 0) {
		pages++
		metric_add_dimensions(caller, path, auth, pool, decision, "pages", 1)
		if (page + 0 > 1) {
			additional_pages++
			metric_add_dimensions(caller, path, auth, pool, decision, "additional_pages", 1)
		}
	}
	if (outcome == "success") {
		successful_attempts++
		metric_add_dimensions(caller, path, auth, pool, decision, "successful_attempts", 1)
	} else {
		failed_attempts++
		metric_add_dimensions(caller, path, auth, pool, decision, "failed_attempts", 1)
	}
	if (elapsed_ms ~ /^[0-9]+$/) {
		elapsed_value = elapsed_ms + 0
		elapsed_ms_total += elapsed_value
		latency_hist[elapsed_value]++
		latency_count++
		metric_add_dimensions(caller, path, auth, pool, decision, "elapsed_ms", elapsed_ms)
	} else {
		unknown_elapsed_attempts++
		metric_add_dimensions(caller, path, auth, pool, decision, "unknown_elapsed_attempts", 1)
	}
	if (quota_cost ~ /^[0-9]+$/) {
		known_quota_cost += quota_cost
		metric_add_dimensions(caller, path, auth, pool, decision, "known_quota_cost", quota_cost)
	} else {
		unknown_quota_cost_attempts++
		metric_add_dimensions(caller, path, auth, pool, decision, "unknown_quota_cost_attempts", 1)
	}
	if (http_status ~ /^[0-9]+$/) metric_add("http_status", http_status, "attempted_requests", 1)
}

END {
	effective_window_seconds = 0
	if (first_window_attempt_ts > 0 && last_window_attempt_ts >= first_window_attempt_ts) {
		effective_window_seconds = last_window_attempt_ts - first_window_attempt_ts
	}
	request_p50_ms = percentile(latency_hist, latency_count, 50)
	request_p95_ms = percentile(latency_hist, latency_count, 95)
	attempts_exact = (duplicate_attempt_ids == 0 && unidentified_attempts == 0 && unknown_page_attempts == 0 && window_malformed_v2_records == 0) ? "true" : "false"

	print "{"
	print "  \"_meta\": {"
	print "    \"schema_version\": 2,"
	printf "    \"generated_at_ts\": %d,\n", now
	printf "    \"since_ts\": %d,\n", cutoff
	printf "    \"requested_window_seconds\": %d,\n", window
	printf "    \"window_seconds\": %d,\n", window
	printf "    \"first_retained_ts\": %d,\n", first_window_attempt_ts + 0
	printf "    \"last_retained_ts\": %d,\n", last_window_attempt_ts + 0
	printf "    \"effective_window_seconds\": %d,\n", effective_window_seconds
	printf "    \"first_observed_attempt_ts\": %d,\n", first_observed_attempt_ts + 0
	printf "    \"last_observed_attempt_ts\": %d,\n", last_observed_attempt_ts + 0
	printf "    \"first_retained_record_ts\": %d,\n", first_retained_record_ts + 0
	printf "    \"last_retained_record_ts\": %d,\n", last_retained_record_ts + 0
	printf "    \"retained_records\": %d,\n", retained_records + 0
	printf "    \"window_records\": %d,\n", window_records + 0
	printf "    \"total_calls\": %d,\n", total_calls
	printf "    \"logical_operations\": %d,\n", logical_operations + 0
	printf "    \"logical_events\": %d,\n", logical_events
	printf "    \"cache_events\": %d,\n", cache_events
	printf "    \"evidence_events\": %d,\n", evidence_events
	printf "    \"timeout_events\": %d,\n", timeout_events
	printf "    \"timeout_elapsed_ms\": %d,\n", timeout_elapsed_ms
	printf "    \"unknown_timeout_elapsed_events\": %d,\n", unknown_timeout_elapsed_events
	printf "    \"legacy_events\": %d,\n", legacy_events
	printf "    \"attempted_requests\": %d,\n", attempted_requests
	printf "    \"opaque_paginated_attempts\": %d,\n", opaque_paginated_attempts + 0
	printf "    \"retries\": %d,\n", retries + 0
	printf "    \"pages\": %d,\n", pages + 0
	printf "    \"additional_pages\": %d,\n", additional_pages + 0
	printf "    \"successful_attempts\": %d,\n", successful_attempts + 0
	printf "    \"failed_attempts\": %d,\n", failed_attempts + 0
	printf "    \"elapsed_ms\": %d,\n", elapsed_ms_total + 0
	printf "    \"unknown_elapsed_attempts\": %d,\n", unknown_elapsed_attempts + 0
	printf "    \"request_p50_ms\": %d,\n", request_p50_ms + 0
	printf "    \"request_p95_ms\": %d,\n", request_p95_ms + 0
	printf "    \"peak_attempts_per_minute\": %d,\n", peak_attempts_per_minute + 0
	printf "    \"known_quota_cost\": %d,\n", known_quota_cost + 0
	printf "    \"unknown_quota_cost_attempts\": %d,\n", unknown_quota_cost_attempts + 0
	printf "    \"duplicate_attempt_ids\": %d,\n", duplicate_attempt_ids + 0
	printf "    \"unidentified_attempts\": %d,\n", unidentified_attempts + 0
	printf "    \"unknown_page_attempts\": %d,\n", unknown_page_attempts + 0
	printf "    \"retained_duplicate_attempt_ids\": %d,\n", retained_duplicate_attempt_ids + 0
	printf "    \"retained_unidentified_attempts\": %d,\n", retained_unidentified_attempts + 0
	printf "    \"retained_unknown_page_attempts\": %d,\n", retained_unknown_page_attempts + 0
	printf "    \"window_malformed_v2_records\": %d,\n", window_malformed_v2_records + 0
	printf "    \"legacy_retained_records\": %d,\n", retained_legacy_records + 0
	printf "    \"malformed_records\": %d,\n", malformed_records + 0
	printf "    \"attempts_exact\": %s\n", attempts_exact
	print "  },"
	emit_group("by_caller", "caller")
	print ","
	emit_group("by_path", "path")
	print ","
	emit_group("by_auth_mode", "auth")
	print ","
	emit_group("by_auth_reason", "reason")
	print ","
	emit_group("by_consumer", "consumer")
	print ","
	emit_group("by_api_pool", "pool")
	print ","
	emit_group("by_route_decision", "decision")
	print ","
	emit_group("by_outcome", "outcome")
	print ","
	emit_group("attempts_by_http_status", "http_status")
	print ","
	emit_budgets()
	print ","
	emit_quota()
	print "}"
}
