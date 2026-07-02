def number_or_zero: (tonumber? // 0);

def finding($id; $severity; $title; $evidence; $recommendation; $autofile): {
  id: $id,
  severity: $severity,
  title: $title,
  evidence: $evidence,
  recommendation: $recommendation,
  autofile: $autofile
};

($current.pulse_gauges.dispatch_capacity_final_max_workers // 0 | number_or_zero) as $max_workers |
($current.current_state_guardrails.available_slots_last // $current.pulse_gauges.pulse_dispatch_guardrail_available_slots // 0 | number_or_zero) as $available_slots |
([$max_workers - $available_slots, 0] | max) as $inferred_active_workers |
(if ($current.active_worker_processes // null) == null then null else ($current.active_worker_processes | number_or_zero) end) as $active_worker_processes |
(if $active_worker_processes == null then $inferred_active_workers else $active_worker_processes end) as $active_workers |
(if $active_worker_processes == null then $available_slots else ([$max_workers - $active_worker_processes, 0] | max) end) as $effective_available_slots |
($queue.aggregate.available_unassigned // 0 | number_or_zero) as $available_issues |
($queue.aggregate.available_old // 0 | number_or_zero) as $old_available |
($queue.aggregate.needs_tier // 0 | number_or_zero) as $needs_tier |
($queue.aggregate.gh_errors // 0 | number_or_zero) as $gh_errors |
($queue.error // "") as $queue_error |
($current.worker_outcomes.spawned // 0 | number_or_zero) as $spawned |
($current.worker_outcomes.launch_validation_failed // $current.pulse_counter_hits.dispatch_worker_launch_failed // 0 | number_or_zero) as $launch_validation_failed |
($current.worker_terminal_events // 0 | number_or_zero) as $current_terminal_events |
($recent_summary.metrics.total // 0 | number_or_zero) as $recent_total |
($summary.metrics.total // 0 | number_or_zero) as $hist_total |
($summary.metrics.succeeded // 0 | number_or_zero) as $hist_success |
($api.graphql_circuit_breaker_trips // 0 | number_or_zero) as $graphql_trips |
{
  generated_at: (now | todateiso8601),
  inputs: {current_window: $window, historical_window: $since, recent_window: $recent},
  summary: {
    max_workers: $max_workers,
    active_workers: $active_workers,
    active_workers_source: (if $active_worker_processes == null then "capacity_gauge" else "process_scan" end),
    inferred_active_workers: $inferred_active_workers,
    available_slots: $effective_available_slots,
    dispatch_alive: ($current.dispatch_alive // false),
    dispatch_stage_events: ($current.dispatch_stage_events // 0),
    worker_launches_in_window: $spawned,
    worker_terminal_events_in_window: $current_terminal_events,
    worker_launch_validation_failures_in_window: $launch_validation_failed,
    recent_worker_events: $recent_total,
    historical_worker_events: $hist_total,
    historical_worker_successes: $hist_success,
    historical_success_rate: (if $hist_total > 0 then (($hist_success / $hist_total) * 100 | floor) else null end),
    auto_dispatch_open: ($queue.aggregate.auto_dispatch_open // 0),
    auto_dispatch_available_unassigned: $available_issues,
    auto_dispatch_available_old: $old_available,
    auto_dispatch_repos_with_available: ($queue.aggregate.repos_with_available // 0),
    auto_dispatch_scan_errors: $gh_errors,
    auto_dispatch_scan_state: (if $queue_error == "" then "scanned" else $queue_error end),
    graphql_budget_status: ($current.graphql_budget_status // "unknown"),
    runner_health: ($runner.finding // "unknown")
  },
  queue: ($queue.aggregate // {}),
  current_state: {
    dispatch_stage_counts: ($current.dispatch_stage_counts // {}),
    worker_outcomes: ($current.worker_outcomes // {}),
    pulse_counter_hits: ($current.pulse_counter_hits // {}),
    pulse_gauges: ($current.pulse_gauges // {}),
    current_state_guardrails: ($current.current_state_guardrails // {}),
    dispatch_pacing: ($current.dispatch_pacing // {}),
    active_worker_processes: ($current.active_worker_processes // null),
    top_pre_launch_blockers: ($current.top_pre_launch_blockers // [])
  },
  worker_activity: {
    historical: {
      window: ($summary.window // {}),
      metrics: (($summary.metrics // {}) | del(.recent_examples, .failure_groups, .failure_families)),
      pulse_stats: ($summary.pulse_stats // {})
    },
    recent: {
      window: ($recent_summary.window // {}),
      metrics: (($recent_summary.metrics // {}) | del(.recent_examples, .failure_groups, .failure_families)),
      pulse_stats: ($recent_summary.pulse_stats // {})
    },
    providers: ($providers.provider_diagnostics // {})
  },
  runner_health: $runner,
  api_budget: {
    graphql_circuit_breaker_trips: ($api.graphql_circuit_breaker_trips // 0),
    reserve_mode_cycles: ($api.reserve_mode_cycles // 0),
    deferred_optional_stages: ($api.deferred_optional_stages // 0),
    secondary_cooldown_state: ($api.secondary_cooldown_state // "unknown"),
    cadence_api_risk: ($api.cadence_api_risk // "unknown")
  },
  findings: ([
    if ($available_issues >= $threshold and $active_workers == 0) then
      finding(
        "pulse-underfilled-auto-dispatch-queue";
        "high";
        "Auto-dispatch queue is visible while worker capacity is empty";
        [
          ("active_workers=" + ($active_workers | tostring) + "/" + ($max_workers | tostring)),
          ("available_unassigned_auto_dispatch=" + ($available_issues | tostring)),
          ("available_older_than_threshold=" + ($old_available | tostring)),
          ("dispatch_stage_events=" + (($current.dispatch_stage_events // 0) | tostring))
        ];
        "Inspect why the pulse did not retain active workers for visible status:available auto-dispatch issues; start with pulse-current-state-helper, worker-activity-helper, and pulse-diagnose-helper cycle-health.";
        true
      )
    else empty end,
    if (($spawned - ([($recent_total), ($current_terminal_events)] | max) - $launch_validation_failed) >= 3 and $active_workers == 0) then
      finding(
        "pulse-launch-accounting-gap";
        "high";
        "Pulse recorded worker launches without active workers or recent terminal metrics";
        [
          ("worker_launches_in_current_window=" + ($spawned | tostring)),
          ("recent_worker_metric_events=" + ($recent_total | tostring)),
          ("worker_terminal_events_in_current_window=" + ($current_terminal_events | tostring)),
          ("worker_launch_validation_failures_in_current_window=" + ($launch_validation_failed | tostring)),
          ("active_workers=" + ($active_workers | tostring)),
          ("available_slots=" + ($available_slots | tostring))
        ];
        "Add or repair launch-validation evidence so every spawned worker becomes an active process, a terminal metric, or a classified launch failure.";
        true
      )
    else empty end,
    if ($needs_tier > 0) then
      finding(
        "auto-dispatch-missing-tier-labels";
        "medium";
        "Some auto-dispatch issues are missing tier labels";
        [("missing_tier_count=" + ($needs_tier | tostring))];
        "Run or repair label normalisation so auto-dispatch issues carry exactly one tier label before worker pickup.";
        false
      )
    else empty end,
    if ($gh_errors > 0) then
      finding(
        "pulse-check-gh-scan-errors";
        "medium";
        "Auto-dispatch queue scan had GitHub read errors";
        [("gh_errors=" + ($gh_errors | tostring))];
        "Check GitHub authentication and API budget before treating queue counts as complete.";
        false
      )
    else empty end,
    if ($queue_error != "") then
      finding(
        "pulse-check-queue-scan-skipped";
        "medium";
        "Auto-dispatch queue scan was skipped or incomplete";
        [("queue_scan_state=" + $queue_error)];
        "Re-run pulse-check after API cooldown clears before making queue-depth or underfill claims.";
        false
      )
    else empty end,
    if ($graphql_trips > 0 or ($current.dispatch_api_blocked // false) == true) then
      finding(
        "github-api-budget-blocking-dispatch";
        "high";
        "GitHub API budget is blocking or degrading dispatch";
        [("graphql_circuit_breaker_trips=" + ($graphql_trips | tostring)), ("dispatch_api_blocked=" + (($current.dispatch_api_blocked // false) | tostring))];
        "Use pulse-diagnose-helper api-budget to identify top callers and shift avoidable reads to cache/REST before increasing concurrency.";
        true
      )
    else empty end,
    if ($hist_total >= 10 and (($hist_success * 100) / $hist_total) < 70) then
      finding(
        "worker-success-rate-regression";
        "medium";
        "Historical worker success rate is below the productivity target";
        [("success_rate_percent=" + (((($hist_success * 100) / $hist_total) | floor) | tostring)), ("worker_events=" + ($hist_total | tostring))];
        "Cluster failure families with worker-activity-helper summary --json, then file targeted fixes for the dominant cause instead of increasing concurrency.";
        false
      )
    else empty end
  ])
}
