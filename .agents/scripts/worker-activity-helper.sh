#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# worker-activity-helper.sh — Canonical worker activity summary (t3215, GH#21949)
#
# One command that answers "are workers actually running and producing PRs?"
# by reading the canonical sources in precedence order:
#
#   1. ~/.aidevops/logs/headless-runtime-metrics.jsonl
#      Authoritative per-worker outcome record (success / watchdog_stall_killed /
#      watchdog_stall_continue / rate_limit / other failure).
#   2. ~/.aidevops/logs/pulse-stats.json
#      Pulse-level dispatch counters (each value is an array of unix-second
#      timestamps; query with `jq '.counters[<name>] // []'`).
#   3. Optional `gh issue list label:solved:worker --state closed`
#      External truth: did headless workers actually solve tasks? Disabled by
#      default because gh issue search uses the GraphQL search path.
#
# Replaces the misdiagnosis-prone habit of reading worker-NNN.log mtimes,
# which was the exact mistake that triggered this task. mtime tells you when
# the file was touched, not whether work succeeded; canonical sources tell you
# the outcome.
#
# Usage:
#   worker-activity-helper.sh summary [--since 1h|6h|24h|48h|7d]
#                                     [--json]
#                                     [--pr-check|--no-pr-check]
#                                     [--repo OWNER/REPO]
#   worker-activity-helper.sh providers [--since 1h|6h|24h|48h|7d]
#                                      [--json]
#   worker-activity-helper.sh help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# Source shared-constants for color helpers, _file_mtime_epoch (stat portability),
# safe_grep_count (counter safety), and the bash-3.2 re-exec self-heal.
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# Path overrides (testing).
WAH_METRICS_FILE="${WAH_METRICS_FILE:-${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl}"
WAH_PULSE_STATS_FILE="${WAH_PULSE_STATS_FILE:-${HOME}/.aidevops/logs/pulse-stats.json}"
WAH_PR_CACHE_FILE="${WAH_PR_CACHE_FILE:-${HOME}/.aidevops/cache/worker-activity-prs.json}"
WAH_OAUTH_POOL_FILE="${WAH_OAUTH_POOL_FILE:-${HOME}/.aidevops/oauth-pool.json}"
WAH_PR_CACHE_TTL="${WAH_PR_CACHE_TTL:-60}" # seconds
WAH_SERVICE_INTERRUPTION_RESULT="service_interruption_continue"
WAH_RESULT_WATCHDOG_STALL_KILLED="watchdog_stall_killed"

#######################################
# Convert short window spec to seconds. Caller owns the cutoff math.
# $1 — one of 1h | 6h | 24h | 48h | 7d
# stdout — integer seconds, or empty + return 1 on bad input.
#######################################
_wah_parse_since() {
	local spec="$1"
	case "$spec" in
	1h) printf '3600\n' ;;
	6h) printf '21600\n' ;;
	24h) printf '86400\n' ;;
	48h) printf '172800\n' ;;
	7d) printf '604800\n' ;;
	*) return 1 ;;
	esac
	return 0
}

#######################################
# Aggregate worker outcomes from headless-runtime-metrics.jsonl.
# Single jq streaming pass: filter by ts cutoff, bucket by result + exit_code.
# Bucketing lives entirely in jq (not awk) so we don't need positional
# field references in shell. `inputs` avoids reading unrelated old entries into
# memory before filtering the append-only jsonl.
#
# $1 — cutoff_epoch (entries with ts < cutoff are dropped).
# $2 — optional now_epoch (entries with ts > now are dropped).
# stdout — seven space-separated integers:
#   total succeeded watchdog_killed watchdog_continued service_interrupted rate_limited other_failure
#######################################
_wah_aggregate_metrics() {
	local cutoff_epoch="$1"
	local metrics="$WAH_METRICS_FILE"
	local now_epoch

	if [[ ! -f "$metrics" ]]; then
		printf '0 0 0 0 0 0 0\n'
		return 0
	fi
	now_epoch="${2:-$(date +%s)}"

	# Bucket semantics (must match the original awk fallthrough chain):
	#   succ — result=="success" AND exit_code==0
	#   wk   — result=="watchdog_stall_killed"   (terminal)
	#   wc   — result=="watchdog_stall_continue" (heartbeat, NOT terminal)
	#   sic  — result=="service_interruption_continue" (heartbeat, NOT terminal)
	#   rl   — result=="rate_limit"
	#   of   — everything else (catches "premature_exit" and any new
	#          failure result-name not yet enumerated; explicitly excludes
	#          watchdog_stall_continue and service_interruption_continue
	#          heartbeats even when their exit_code
	#          is nonzero)
	# Fail-open to zeros if jq fails (stale/corrupt jsonl).
	local result service_result watchdog_killed_result
	service_result="$WAH_SERVICE_INTERRUPTION_RESULT"
	watchdog_killed_result="$WAH_RESULT_WATCHDOG_STALL_KILLED"
	result=$(jq -rn --argjson cutoff "$cutoff_epoch" --argjson now "$now_epoch" --arg service_result "$service_result" --arg watchdog_killed_result "$watchdog_killed_result" '
		[inputs | select((.ts // 0) >= $cutoff and (.ts // 0) <= $now)] as $w | {
			total:  ($w | length),
			succ:   ([$w[] | select(.result == "success" and .exit_code == 0)] | length),
			wk:     ([$w[] | select(.result == $watchdog_killed_result)] | length),
			wc:     ([$w[] | select(.result == "watchdog_stall_continue")] | length),
			sic:    ([$w[] | select(.result == $service_result)] | length),
			rl:     ([$w[] | select(.result == "rate_limit")] | length),
			of:     ([$w[] | select(
				(.result != "success" or .exit_code != 0)
				and .result != $watchdog_killed_result
				and .result != "watchdog_stall_continue"
				and .result != $service_result
				and .result != "rate_limit"
			)] | length)
		} | "\(.total) \(.succ) \(.wk) \(.wc) \(.sic) \(.rl) \(.of)"
	' <"$metrics" 2>/dev/null) || result="0 0 0 0 0 0 0"

	[[ -n "$result" ]] || result="0 0 0 0 0 0 0"
	printf '%s\n' "$result"
	return 0
}

#######################################
# Emit richer metric detail for JSON consumers.
#
# $1 — cutoff_epoch (entries with ts < cutoff are dropped).
# $2 — optional now_epoch (entries with ts > now are dropped).
# stdout — JSON object containing result counts, duration summary, and examples.
#######################################
_wah_metric_details_json() {
	local cutoff_epoch="$1"
	local metrics="$WAH_METRICS_FILE"
	local now_epoch

	if [[ ! -f "$metrics" ]]; then
		printf '{"result_counts":{},"diagnostic_focus":{},"timing_ms":{"avg":0,"max":0,"samples":0},"recent_examples":[],"failure_groups":[],"failure_families":[]}'
		return 0
	fi
	now_epoch="${2:-$(date +%s)}"

	jq -rn --argjson cutoff "$cutoff_epoch" --argjson now "$now_epoch" --arg watchdog_killed_result "$WAH_RESULT_WATCHDOG_STALL_KILLED" '
		[inputs | select((.ts // 0) >= $cutoff and (.ts // 0) <= $now)] as $w
		| ($w | map(.duration_ms // 0)) as $durations
		| ($w | map(select((.result // "") != "success" or (.exit_code // 1) != 0))) as $failures
		| {
			result_counts: (reduce $w[] as $row ({}; .[$row.result // "unknown"] += 1)),
			diagnostic_focus: {
				premature_exit: ($failures | map(select(.result == "premature_exit" or .launch_failure_cause == "model_stopped_before_completion")) | length),
				local_runtime_error: ($failures | map(select(.failure_reason == "local_error" or .launch_failure_cause == "local_runtime_error" or (.runtime_error_type != null and .runtime_error_type != ""))) | length),
				stall_hard_killed: ($failures | map(select(.result == $watchdog_killed_result or .launch_failure_cause == "stall_hard_killed" or .kill_reason == "hard_kill_stall")) | length)
			},
			timing_ms: {
				samples: ($durations | length),
				avg: (if ($durations | length) > 0 then (($durations | add) / ($durations | length) | floor) else 0 end),
				max: (if ($durations | length) > 0 then ($durations | max) else 0 end)
			},
				recent_examples: ($w | sort_by(.ts // 0) | reverse | .[0:5] | map({
				ts,
				session_key,
				session_id,
				issue_number,
				repo_slug,
				model,
				provider,
				result,
				exit_code,
				failure_reason,
				provider_error_type,
				provider_status,
				runtime_error_type,
				classification_source,
				classification_pattern,
				launch_failure_cause,
				kill_reason,
				next_action,
				duration_ms,
				work_dir,
				output_file,
				load_1min,
				load_per_cpu
			})),
			failure_groups: (
				$failures
				| group_by([.result // "unknown", .failure_reason // "", .provider_error_type // "", .provider_status // "", .runtime_error_type // "", .classification_source // "", .classification_pattern // "", .launch_failure_cause // "", .kill_reason // "", .next_action // "", .provider // "", .model // "", .session_key // "", (.issue_number // "" | tostring), .repo_slug // ""])
				| map({
					result: (.[0].result // "unknown"),
					failure_reason: (.[0].failure_reason // ""),
					provider_error_type: (.[0].provider_error_type // ""),
					provider_status: (.[0].provider_status // ""),
					runtime_error_type: (.[0].runtime_error_type // ""),
					classification_source: (.[0].classification_source // ""),
					classification_pattern: (.[0].classification_pattern // ""),
					launch_failure_cause: (.[0].launch_failure_cause // ""),
					kill_reason: (.[0].kill_reason // ""),
					next_action: (.[0].next_action // ""),
					provider: (.[0].provider // ""),
					model: (.[0].model // ""),
					session_key: (.[0].session_key // ""),
					issue_number: (.[0].issue_number // null),
					repo_slug: (.[0].repo_slug // ""),
					count: length,
					examples: (sort_by(.ts // 0) | reverse | .[0:3] | map({ts, session_id, work_dir, output_file, exit_code, duration_ms, provider_error_type, provider_status, runtime_error_type, classification_source, classification_pattern, launch_failure_cause, kill_reason, next_action}))
				})
				| sort_by(.count) | reverse | .[0:10]),
			failure_families: (
				$failures
				| group_by([.launch_failure_cause // "unknown", .kill_reason // "", .next_action // ""])
				| map({
					launch_failure_cause: (.[0].launch_failure_cause // "unknown"),
					kill_reason: (.[0].kill_reason // ""),
					next_action: (.[0].next_action // ""),
					count: length,
					results: (reduce .[] as $row ({}; .[$row.result // "unknown"] += 1)),
					examples: (sort_by(.ts // 0) | reverse | .[0:3] | map({ts, session_key, issue_number, repo_slug, result, exit_code, output_file, launch_failure_cause, kill_reason, next_action}))
				})
				| sort_by(.count) | reverse | .[0:10])
		}' <"$metrics" 2>/dev/null || \
		printf '{"result_counts":{},"diagnostic_focus":{},"timing_ms":{"avg":0,"max":0,"samples":0},"recent_examples":[],"failure_groups":[],"failure_families":[]}'
	return 0
}

#######################################
# Emit bounded provider/model/account-pool usage from canonical metrics.
# This is the narrow diagnostic path for recent worker provider questions; it
# intentionally avoids recursive searches over logs or OpenCode storage.
#
# $1 — cutoff_epoch (entries with ts < cutoff are dropped).
# stdout — JSON object containing provider/model counts, recent worker samples,
#          and redacted OAuth pool aggregate counts (no emails/tokens).
#######################################
_wah_provider_usage_json() {
	local cutoff_epoch="$1"
	local metrics="$WAH_METRICS_FILE"
	local pool="$WAH_OAUTH_POOL_FILE"
	local now_epoch input_file account_multiplier

	now_epoch=$(date +%s)
	input_file="/dev/null"
	[[ -f "$metrics" ]] && input_file="$metrics"
	account_multiplier="${WAH_PROVIDER_ACCOUNT_SLOT_MULTIPLIER:-${PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER:-2}}"
	[[ "$account_multiplier" =~ ^[0-9]+$ ]] || account_multiplier=2
	((account_multiplier < 1)) && account_multiplier=1

	if [[ -f "$pool" ]]; then
		jq -rn --slurpfile pool "$pool" --argjson cutoff "$cutoff_epoch" --argjson now "$now_epoch" --argjson account_multiplier "$account_multiplier" --arg status_empty '' --arg status_auth_error 'auth-error' --arg status_rate_limited 'rate-limited' --arg status_active 'active' --arg status_idle 'idle' '
			def account_status: .status // $status_empty;
			def available_account:
				(account_status) as $status
				| $status != $status_auth_error
				and (($status != $status_rate_limited) or ((.cooldownUntil // 0) <= ($now * 1000)));
			def active_or_idle:
				(.status // $status_idle) as $status
				| $status == $status_active or $status == $status_idle;
			($pool[0] // {}) as $pool_data
			| [inputs | select((.ts // 0) >= $cutoff and (.ts // 0) <= $now)] as $w
			| {
				provider_model_usage: (
					$w
					| group_by([.provider // "unknown", .model // "unknown"])
					| map({
						provider: (.[0].provider // "unknown"),
						model: (.[0].model // "unknown"),
						count: length,
						success: (map(select(.result == "success" and (.exit_code // 1) == 0)) | length),
						rate_limited: (map(select(.result == "rate_limit" or .provider_error_type == "rate_limit" or .provider_status == "429")) | length),
						other_failure: (map(select((.result != "success" or (.exit_code // 1) != 0) and .result != "rate_limit" and .provider_error_type != "rate_limit" and .provider_status != "429")) | length),
						latest_ts: (map(.ts // 0) | max)
					})
					| sort_by(.count, .latest_ts) | reverse | .[0:12]
				),
				recent_events: (
					$w | sort_by(.ts // 0) | reverse | .[0:10]
					| map({ts, provider, model, result, exit_code, issue_number, session_key})
				),
				account_pool: (
					$pool_data
					| to_entries
					| map(select(.key == "anthropic" or .key == "openai" or .key == "cursor" or .key == "google"))
					| map({
						provider: .key,
						total: (.value | length),
						available: (.value | map(select(available_account)) | length),
						capacity_slots: ((.value | map(select(available_account)) | length) * $account_multiplier),
						active_idle: (.value | map(select(active_or_idle)) | length),
						rate_limited: (.value | map(select(account_status == $status_rate_limited and ((.cooldownUntil // 0) > ($now * 1000)))) | length),
						auth_errors: (.value | map(select(account_status == $status_auth_error)) | length),
						latest_last_used: (.value | map(.lastUsed // empty) | max // "")
					})
					| sort_by(.provider)
				)
			}' <"$input_file" 2>/dev/null || printf '{"provider_model_usage":[],"recent_events":[],"account_pool":[]}'
	else
		jq -rn --argjson cutoff "$cutoff_epoch" --argjson now "$now_epoch" '
			[inputs | select((.ts // 0) >= $cutoff and (.ts // 0) <= $now)] as $w
			| {
				provider_model_usage: ($w | group_by([.provider // "unknown", .model // "unknown"]) | map({provider: (.[0].provider // "unknown"), model: (.[0].model // "unknown"), count: length, success: (map(select(.result == "success" and (.exit_code // 1) == 0)) | length), rate_limited: (map(select(.result == "rate_limit" or .provider_error_type == "rate_limit" or .provider_status == "429")) | length), other_failure: (map(select((.result != "success" or (.exit_code // 1) != 0) and .result != "rate_limit" and .provider_error_type != "rate_limit" and .provider_status != "429")) | length), latest_ts: (map(.ts // 0) | max)}) | sort_by(.count, .latest_ts) | reverse | .[0:12]),
				recent_events: ($w | sort_by(.ts // 0) | reverse | .[0:10] | map({ts, provider, model, result, exit_code, issue_number, session_key})),
				account_pool: []
			}' <"$input_file" 2>/dev/null || printf '{"provider_model_usage":[],"recent_events":[],"account_pool":[]}'
	fi
	return 0
}

#######################################
# Count pulse-stats counter entries since cutoff.
# Counter values in pulse-stats.json are arrays of unix-second timestamps.
# Reading via `// []` handles missing keys without masking real counts.
#
# $1 — counter name
# $2 — cutoff_epoch
# stdout — integer count (0 on missing file/key/jq failure).
#######################################
_wah_count_stats_counter() {
	local key="$1" cutoff_epoch="$2"
	local file="$WAH_PULSE_STATS_FILE"

	if [[ ! -f "$file" ]]; then
		printf '0\n'
		return 0
	fi

	jq -r --arg key "$key" --argjson cutoff "$cutoff_epoch" \
		'(.counters[$key] // []) | map(select(. >= $cutoff)) | length' \
		"$file" 2>/dev/null || printf '0\n'
}

#######################################
# Get issue count for `solved:worker` issues closed since `since_iso`.
# Caches result for $WAH_PR_CACHE_TTL seconds to avoid hammering gh.
#
# $1 — since_iso (YYYY-MM-DDTHH:MM:SSZ)
# $2 — repo_slug (optional; empty = current repo)
# stdout — integer issue count, or "?" on gh failure.
#######################################
_wah_solved_worker_count() {
	local since_iso="$1" repo_slug="${2:-}"
	local cache="$WAH_PR_CACHE_FILE"
	local cache_key="solved-worker|${repo_slug:-current}|${since_iso}"

	# Check cache freshness (portable mtime via shared-constants).
	if [[ -f "$cache" ]]; then
		local mtime now age cached_key cached_count
		mtime=$(_file_mtime_epoch "$cache" 2>/dev/null) || mtime=0
		now=$(date +%s)
		age=$((now - mtime))
		if [[ $age -lt $WAH_PR_CACHE_TTL ]]; then
			cached_key=$(jq -r '.key // ""' "$cache" 2>/dev/null) || cached_key=""
			if [[ "$cached_key" == "$cache_key" ]]; then
				cached_count=$(jq -r '.count // "?"' "$cache" 2>/dev/null) || cached_count="?"
				printf '%s\n' "$cached_count"
				return 0
			fi
		fi
	fi

	# Cache miss — query gh (5s timeout via gh's own client). solved:worker is
	# the completion-attribution signal; origin:worker alone only says who
	# created the PR and can over-credit interactive fixes.
	local count gh_args=(issue list --search "closed:>=${since_iso} label:solved:worker" --state closed --limit 1000 --json number)
	[[ -n "$repo_slug" ]] && gh_args+=(--repo "$repo_slug")
	count=$(gh "${gh_args[@]}" 2>/dev/null | jq 'length' 2>/dev/null) || count="?"

	# Best-effort cache write.
	mkdir -p "$(dirname "$cache")" 2>/dev/null || true
	if [[ "$count" != "?" ]]; then
		local cache_ts
		cache_ts=$(date +%s)
		jq -n --arg key "$cache_key" --argjson count "$count" --argjson ts "$cache_ts" \
			'{key: $key, count: $count, ts: $ts}' >"$cache" 2>/dev/null || true
	fi
	printf '%s\n' "$count"
	return 0
}

#######################################
# Render summary in human-readable form.
# All inputs are pre-formatted strings/integers from cmd_summary.
#######################################
_wah_emit_human() {
	local since_label="$1" cutoff_iso="$2"
	local total="$3" succ="$4" wk="$5" wc="$6" sic="$7" rl="$8" of="$9"
	local cb="${10}" gqlow="${11}" db_skip="${12}" nwbreaker="${13}"
	local solved_count="${14}" pr_check_state="${15}" repo_label="${16}"
	local details_json="${17}"

	local divider="==========================================================="

	# Compute success rate (terminal events only — exclude watchdog_continue
	# which is a heartbeat sample, not a terminal outcome).
	local terminal=$((succ + wk + rl + of))
	local rate_pct="n/a"
	if [[ $terminal -gt 0 ]]; then
		rate_pct=$(awk -v s="$succ" -v t="$terminal" 'BEGIN{printf "%.0f%%", (s/t)*100}')
	fi

	printf '%s\n' "$divider"
	printf 'Worker activity since %s (cutoff: %s)\n' "$since_label" "$cutoff_iso"
	[[ -n "$repo_label" ]] && printf 'Repo: %s\n' "$repo_label"
	printf '%s\n' "$divider"
	printf '\n'
	printf 'headless-runtime-metrics.jsonl (canonical worker outcomes):\n'
	printf '  Total events:                %d\n' "$total"
	printf '  Succeeded:                   %d  (%s of terminal)\n' "$succ" "$rate_pct"
	printf '  Watchdog stall-killed:       %d\n' "$wk"
	printf '  Watchdog stall-continued:    %d  (heartbeat, not terminal)\n' "$wc"
	printf '  Service interruption resumed:%d  (heartbeat, not terminal)\n' "$sic"
	printf '  Rate-limited:                %d\n' "$rl"
	printf '  Other failure:               %d\n' "$of"
	printf '  Result classes:              %s\n' "$(printf '%s' "$details_json" | jq -c '.result_counts' 2>/dev/null || printf '{}')"
	printf '  Diagnostic focus:            %s\n' "$(printf '%s' "$details_json" | jq -c '.diagnostic_focus // {}' 2>/dev/null || printf '{}')"
	printf '  Timing ms (avg/max/samples): %s/%s/%s\n' \
		"$(printf '%s' "$details_json" | jq -r '.timing_ms.avg // 0' 2>/dev/null || printf '0')" \
		"$(printf '%s' "$details_json" | jq -r '.timing_ms.max // 0' 2>/dev/null || printf '0')" \
		"$(printf '%s' "$details_json" | jq -r '.timing_ms.samples // 0' 2>/dev/null || printf '0')"
	printf '  Provider/model usage:        worker-activity-helper.sh providers --since %s\n' "$since_label"
	printf '  Failure groups:             %s\n' "$(printf '%s' "$details_json" | jq -c '.failure_groups // []' 2>/dev/null || printf '[]')"
	printf '  Failure families:           %s\n' "$(printf '%s' "$details_json" | jq -c '.failure_families // []' 2>/dev/null || printf '[]')"
	printf '\n'
	printf 'pulse-stats.json (dispatch-side counters):\n'
	printf '  pulse_dispatch_circuit_broken:           %d\n' "$cb"
	printf '  pulse_cycle_skipped_graphql_low:         %d\n' "$gqlow"
	printf '  dispatch_backoff_skipped:                %d\n' "$db_skip"
	printf '  pulse_dispatch_no_work_breaker_tripped:  %d\n' "$nwbreaker"
	printf '\n'
	printf 'solved:worker issues closed in window:\n'
	printf '  %s' "$solved_count"
	[[ "$pr_check_state" == "skipped" ]] && printf '  (skipped; use --pr-check)'
	[[ "$pr_check_state" == "failed" ]] && printf '  (gh query failed)'
	printf '\n'
	printf '%s\n' "$divider"
	return 0
}

#######################################
# Render provider/model/account-pool usage in human-readable form.
# Args: since_label cutoff_iso usage_json
#######################################
_wah_emit_providers_human() {
	local since_label="$1" cutoff_iso="$2" usage_json="$3"
	local divider="==========================================================="

	printf '%s\n' "$divider"
	printf 'Worker provider/model/account usage since %s (cutoff: %s)\n' "$since_label" "$cutoff_iso"
	printf '%s\n' "$divider"
	printf '\n'
	printf 'Provider/model usage (from headless-runtime-metrics.jsonl):\n'
	printf '%s' "$usage_json" | jq -r '
		(.provider_model_usage // []) as $rows
		| if ($rows | length) == 0 then "  (no worker metric events in window)"
		else $rows[] | "  \(.provider)/\(.model): count=\(.count) success=\(.success) rate_limited=\(.rate_limited) other_failure=\(.other_failure) latest_ts=\(.latest_ts)"
		end' 2>/dev/null || printf '  (provider/model usage unavailable)\n'
	printf '\n'
	printf 'OAuth account pool aggregate (redacted; no emails/tokens):\n'
	printf '%s' "$usage_json" | jq -r '
		(.account_pool // []) as $rows
		| if ($rows | length) == 0 then "  (no oauth-pool.json account summary available)"
		else $rows[] | "  \(.provider): total=\(.total) available=\(.available) capacity_slots=\(.capacity_slots // 0) active_idle=\(.active_idle) rate_limited=\(.rate_limited) auth_errors=\(.auth_errors) latest_last_used=\(.latest_last_used // "")"
		end' 2>/dev/null || printf '  (account pool summary unavailable)\n'
	printf '\n'
	printf 'Recent worker samples (bounded to 10):\n'
	printf '%s' "$usage_json" | jq -r '
		(.recent_events // []) as $rows
		| if ($rows | length) == 0 then "  (no recent samples)"
		else $rows[] | "  ts=\(.ts) provider=\(.provider // "") model=\(.model // "") result=\(.result // "") issue=\(.issue_number // "") session=\(.session_key // "")"
		end' 2>/dev/null || printf '  (recent samples unavailable)\n'
	printf '%s\n' "$divider"
	return 0
}

#######################################
# Render summary in JSON. All inputs are pre-formatted scalars.
#######################################
_wah_emit_json() {
	local since_label="$1" cutoff_iso="$2" cutoff_epoch="$3"
	local total="$4" succ="$5" wk="$6" wc="$7" sic="$8" rl="$9" of="${10}"
	local cb="${11}" gqlow="${12}" db_skip="${13}" nwbreaker="${14}"
	local solved_count="${15}" pr_check_state="${16}" repo_label="${17}"
	local details_json="${18}"

	# solved_count may be "?" on gh failure — coerce to null in JSON.
	local solved_json="$solved_count"
	[[ "$solved_count" == "?" ]] && solved_json="null"

	jq -n \
		--arg since "$since_label" \
		--arg cutoff_iso "$cutoff_iso" \
		--argjson cutoff_epoch "$cutoff_epoch" \
		--argjson total "$total" \
		--argjson succ "$succ" \
		--argjson wk "$wk" \
		--argjson wc "$wc" \
		--argjson sic "$sic" \
		--argjson rl "$rl" \
		--argjson of "$of" \
		--argjson cb "$cb" \
		--argjson gqlow "$gqlow" \
		--argjson db_skip "$db_skip" \
		--argjson nwbreaker "$nwbreaker" \
		--argjson solved_count "$solved_json" \
		--argjson details "$details_json" \
		--arg pr_check_state "$pr_check_state" \
		--arg repo "$repo_label" \
		'{
			window: { since: $since, cutoff_iso: $cutoff_iso, cutoff_epoch: $cutoff_epoch },
			repo: (if $repo == "" then null else $repo end),
			metrics: {
				total: $total,
				succeeded: $succ,
				watchdog_killed: $wk,
				watchdog_continued: $wc,
				service_interrupted: $sic,
				rate_limited: $rl,
				other_failure: $of,
				result_counts: $details.result_counts,
				diagnostic_focus: ($details.diagnostic_focus // {}),
				timing_ms: $details.timing_ms,
				recent_examples: $details.recent_examples,
				failure_groups: ($details.failure_groups // []),
				failure_families: ($details.failure_families // [])
			},
			pulse_stats: {
				pulse_dispatch_circuit_broken: $cb,
				pulse_cycle_skipped_graphql_low: $gqlow,
				dispatch_backoff_skipped: $db_skip,
				pulse_dispatch_no_work_breaker_tripped: $nwbreaker
			},
			worker_solved_issues: { count: $solved_count, check_state: $pr_check_state },
			worker_prs: { count: $solved_count, check_state: $pr_check_state, deprecated: true }
		}'
	return 0
}

#######################################
# Orchestrate one summary run. Parses args, calls aggregators, dispatches
# to the right emitter.
#######################################
cmd_summary() {
	local since_label="24h" emit_json=0 do_pr_check=0 repo_label=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--since)
			since_label="${2:-}"
			shift 2
			;;
		--json)
			emit_json=1
			shift
			;;
		--pr-check)
			do_pr_check=1
			shift
			;;
		--no-pr-check)
			do_pr_check=0
			shift
			;;
		--repo)
			repo_label="${2:-}"
			shift 2
			;;
		-h | --help)
			cmd_help
			return 0
			;;
		*)
			printf 'unknown flag: %s\n' "$arg" >&2
			return 2
			;;
		esac
	done

	local since_seconds
	since_seconds=$(_wah_parse_since "$since_label") || {
		printf 'invalid --since value: %s (use 1h|6h|24h|48h|7d)\n' "$since_label" >&2
		return 2
	}

	local now_epoch cutoff_epoch cutoff_iso
	now_epoch=$(date +%s)
	cutoff_epoch=$((now_epoch - since_seconds))
	cutoff_iso=$(date -u -r "$cutoff_epoch" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) ||
		cutoff_iso=$(date -u -d "@${cutoff_epoch}" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) ||
		cutoff_iso="(unknown)"

	# Aggregate metrics (single jq+awk pass).
	local agg total succ wk wc sic rl of details_json
	agg=$(_wah_aggregate_metrics "$cutoff_epoch" "$now_epoch")
	read -r total succ wk wc sic rl of <<<"$agg"
	details_json=$(_wah_metric_details_json "$cutoff_epoch" "$now_epoch")

	# Pulse-stats counters.
	local cb gqlow db_skip nwbreaker
	cb=$(_wah_count_stats_counter "pulse_dispatch_circuit_broken" "$cutoff_epoch")
	gqlow=$(_wah_count_stats_counter "pulse_cycle_skipped_graphql_low" "$cutoff_epoch")
	db_skip=$(_wah_count_stats_counter "dispatch_backoff_skipped" "$cutoff_epoch")
	nwbreaker=$(_wah_count_stats_counter "pulse_dispatch_no_work_breaker_tripped" "$cutoff_epoch")

	# Solved issue count (optional, network-dependent).
	local pr_count="?" pr_check_state="ok"
	if [[ $do_pr_check -eq 1 ]]; then
		pr_count=$(_wah_solved_worker_count "$cutoff_iso" "$repo_label")
		[[ "$pr_count" == "?" ]] && pr_check_state="failed"
	else
		pr_count="?"
		pr_check_state="skipped"
	fi

	if [[ $emit_json -eq 1 ]]; then
		_wah_emit_json "$since_label" "$cutoff_iso" "$cutoff_epoch" \
			"$total" "$succ" "$wk" "$wc" "$sic" "$rl" "$of" \
			"$cb" "$gqlow" "$db_skip" "$nwbreaker" \
			"$pr_count" "$pr_check_state" "$repo_label" "$details_json"
	else
		_wah_emit_human "$since_label" "$cutoff_iso" \
			"$total" "$succ" "$wk" "$wc" "$sic" "$rl" "$of" \
			"$cb" "$gqlow" "$db_skip" "$nwbreaker" \
			"$pr_count" "$pr_check_state" "$repo_label" "$details_json"
	fi
	return 0
}

#######################################
# Orchestrate bounded provider/model/account-pool diagnostics.
#######################################
cmd_providers() {
	local since_label="24h" emit_json=0
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--since)
			since_label="${2:-}"
			shift 2
			;;
		--json)
			emit_json=1
			shift
			;;
		-h | --help)
			cmd_help
			return 0
			;;
		*)
			printf 'unknown flag: %s\n' "$arg" >&2
			return 2
			;;
		esac
	done

	local since_seconds
	since_seconds=$(_wah_parse_since "$since_label") || {
		printf 'invalid --since value: %s (use 1h|6h|24h|48h|7d)\n' "$since_label" >&2
		return 2
	}

	local now_epoch cutoff_epoch cutoff_iso usage_json
	now_epoch=$(date +%s)
	cutoff_epoch=$((now_epoch - since_seconds))
	cutoff_iso=$(date -u -r "$cutoff_epoch" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) ||
		cutoff_iso=$(date -u -d "@${cutoff_epoch}" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) ||
		cutoff_iso="(unknown)"
	usage_json=$(_wah_provider_usage_json "$cutoff_epoch")

	if [[ $emit_json -eq 1 ]]; then
		jq -n \
			--arg since "$since_label" \
			--arg cutoff_iso "$cutoff_iso" \
			--argjson cutoff_epoch "$cutoff_epoch" \
			--argjson usage "$usage_json" \
			'{window: {since: $since, cutoff_iso: $cutoff_iso, cutoff_epoch: $cutoff_epoch}, provider_diagnostics: $usage}'
	else
		_wah_emit_providers_human "$since_label" "$cutoff_iso" "$usage_json"
	fi
	return 0
}

#######################################
# Help text.
#######################################
cmd_help() {
	cat <<'EOF'
worker-activity-helper.sh — Canonical worker activity summary

Usage:
  worker-activity-helper.sh summary [OPTIONS]
  worker-activity-helper.sh providers [OPTIONS]
  worker-activity-helper.sh help

Options:
  --since 1h|6h|24h|48h|7d   Lookback window (default: 24h)
  --json                     Emit machine-readable JSON
  --pr-check                 Run the gh solved-issue query (GraphQL search path)
  --no-pr-check              Explicitly keep the gh solved-issue query skipped (default)
  --repo OWNER/REPO          Constrain solved-issue query to a single repo

Sources read (in canonical-precedence order):
  1. ~/.aidevops/logs/headless-runtime-metrics.jsonl  (worker outcomes)
  2. ~/.aidevops/logs/pulse-stats.json                (dispatch counters)
  3. gh issue list label:solved:worker                (optional external truth)

Examples:
  # Last 24 hours, human-readable.
  worker-activity-helper.sh summary

  # Last 6 hours as JSON.
  worker-activity-helper.sh summary --since 6h --json

  # Bounded provider/model/account-pool diagnostics; no recursive log search.
  worker-activity-helper.sh providers --since 1h

  # Last 7 days, single repo, no network call.
  worker-activity-helper.sh summary --since 7d --repo marcusquinn/aidevops --no-pr-check

  # Include solved:worker issue search when GraphQL budget is healthy.
  worker-activity-helper.sh summary --since 24h --pr-check

NOT a substitute for:
  - worker-NNN.log mtime → file touch time, not outcome.
  - pgrep -fc 'headless-runtime-helper.sh run' → live worker count.
  - recursive grep over ~/.aidevops/logs or OpenCode storage → unbounded noise.
  - pulse-runner-health-helper.sh diagnose → per-runner zero-attempt breaker.

Filed under: t3215 / GH#21949
EOF
	return 0
}

#######################################
# main — dispatch on subcommand.
#######################################
main() {
	local cmd="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$cmd" in
	summary) cmd_summary "$@" ;;
	providers | provider-usage) cmd_providers "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		printf 'unknown command: %s\n' "$cmd" >&2
		cmd_help >&2
		return 2
		;;
	esac
}

main "$@"
