def _wah_empty_if_null: if . == null then "" else . end;
def _wah_failure_family:
  if ((.result // "") | test("rate_limit"))
    or ((.failure_reason // "") | test("rate_limit"))
    or (.provider_status == "429") then "rate-limit"
  elif (.launch_failure_cause == "elapsed_cap_while_active")
    or (.kill_reason == "hard_kill_cap_active") then "elapsed-cap-active"
  elif ((.result // "") | test("watchdog_stall"))
    or (.launch_failure_cause == "stall_hard_killed")
    or (.kill_reason == "hard_kill_stall") then "watchdog-stall"
  elif ((.result // "") | test("recovery"))
    or ((.failure_reason // "") | test("recovery"))
    or ((.next_action // "") | test("recovery")) then "recovery-failure"
  elif (.result == $local_kill_result)
    or (.launch_failure_cause == $local_kill_result)
    or ((.kill_reason // "") | test("kill")) then "local-kill"
  elif (.failure_reason == "local_error")
    or (.launch_failure_cause == "local_runtime_error")
    or ((.runtime_error_type | _wah_empty_if_null) != "") then "local-runtime-error"
  elif ((.launch_failure_cause // "") != "")
    or ((.result // "") | test("launch")) then "launch-failure"
  else "other-failure" end;
# GH#33331: each attempt writes one metric row; continuation attempts carry
# routing_reason=continuation_retry. Join them to the terminal session row so
# "continuations exhausted" is distinguishable from "never attempted".
def _wah_is_premature_exit:
  .result == "premature_exit" or .launch_failure_cause == "model_stopped_before_completion";
def _wah_with_continuations($events):
  map(. as $t
    | (($t.session_key // "") | tostring) as $key
    | . + {continuation_retries: (if $key == "" then 0 else
        [$events[] | select(
          .routing_reason == "continuation_retry"
          and ((.session_key // "") | tostring) == $key
          and (.repo_slug // "") == ($t.repo_slug // "")
          and ((($t.attempt_id // "") == "") or (.attempt_id // "") == $t.attempt_id)
          and (.ts // 0) <= ($t.ts // 0)
        )] | length end)});
def _wah_continuation_recovery:
  {
    retries_total: (map(.continuation_retries // 0) | add // 0),
    recovered_sessions: (map(select(_wah_runtime_handoff and (.continuation_retries // 0) > 0)) | length),
    exhausted_sessions: (map(select(_wah_is_premature_exit and (.continuation_retries // 0) > 0)) | length),
    not_attempted_sessions: (map(select(_wah_is_premature_exit and (.continuation_retries // 0) == 0)) | length)
  };
def _wah_failure_family_summary:
  map(select(_wah_effective_failure))
  | map(. + {failure_family: _wah_failure_family})
  | group_by(.failure_family)
  | map({
    fingerprint: ("ff-v1:" + .[0].failure_family),
    family: .[0].failure_family,
    launch_failure_cause: ([.[].launch_failure_cause // empty | select(length > 0)][0] // "unknown"),
    kill_reason: ([.[].kill_reason // empty | select(length > 0)][0] // ""),
    next_action: ([.[].next_action // empty | select(length > 0)][0] // ""),
    count: length,
    distinct_sessions: (map((.repo_slug // "legacy") + "|" + (.session_key // (.session_id // "unknown"))) | unique | length),
    first_ts: (map(.ts // 0) | min),
    last_ts: (map(.ts // 0) | max),
    confidence: (if length >= 3 and (map((.repo_slug // "legacy") + "|" + (.session_key // (.session_id // "unknown"))) | unique | length) >= 2 then "high" elif length >= 2 then "medium" else "low" end),
    recovery_outcome: (if length >= 3 then "recurring" else "observed" end),
    occurrences: length,
    continuation_retries: (map(.continuation_retries // 0) | add // 0),
    continuation_outcome: (
      if any(.[]; _wah_is_premature_exit and (.continuation_retries // 0) > 0) then "exhausted"
      elif any(.[]; _wah_is_premature_exit) then "not_attempted"
      else "not_applicable" end),
    results: (reduce .[] as $row ({}; .[$row.result // "unknown"] += 1)),
    models: (reduce .[] as $row ({}; .[$row.model // "unknown"] += 1)),
    examples: (sort_by(.ts // 0) | reverse | .[0:3] | map({ts, result, exit_code, launch_failure_cause, kill_reason, next_action, model, continuation_retries}))
  })
  | sort_by(.count) | reverse | .[0:10];
