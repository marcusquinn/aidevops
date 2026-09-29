def attempt_key:
  if ((.attempt_id // "") != "") then .attempt_id
  else ["legacy", (.repo // ""), (.issue // ""), (.dispatched_at // ""), (.tier // ""), (.model // "")] | join(":")
  end;

def find_pending:
  . as $rows |
  # An attempt ID is unique, so it alone identifies the dispatch. Requiring the
  # other filters too dropped tier/model when a launcher registered without an
  # issue number but the worker reported one (GH#32964).
  [.[] | select(.outcome == "pending") |
    select(if $aid != "" then attempt_key == $aid
      else
        ($sk == "" or (.session_key // "") == $sk) and
        ($inum == "" or (.issue // "") == $inum) and
        ($slug == "" or (.repo // "") == $slug)
      end) |
    . as $pending |
    select(if (($pending.attempt_id // "") != "") then
      attempt_key as $key |
      ([$rows[] | select(.outcome != "pending" and (.attempt_id // "") == $key)] | length) == 0
    else
      ([$rows[] | select(.outcome != "pending" and
        (.repo // "") == ($pending.repo // "") and
        (.issue // "") == ($pending.issue // "") and
        (.tier // "") == ($pending.tier // ""))] | length) <
      ([$rows[] | select(.outcome == "pending" and (.attempt_id // "") == "" and
        (.repo // "") == ($pending.repo // "") and
        (.issue // "") == ($pending.issue // "") and
        (.tier // "") == ($pending.tier // ""))] | length)
    end)] |
  last // empty |
  . + {attempt_id: attempt_key};

def model_label:
  (if (.final_model // "") != "" then .final_model else (.model // "") end) as $model |
  if (.variant // "") != "" then "\($model)@\(.variant)" else $model end;

def success_rate_rows:
  group_by(.tier // "") | map({
    tier: (.[0].tier // ""),
    total: length,
    success: ([.[] | select(.outcome == "success")] | length)
  }) | sort_by(.tier);

def outcome_counts:
  {
    total: length,
    success: ([.[] | select(.outcome == "success")] | length),
    failed: ([.[] | select(.outcome == "failed")] | length),
    escalated: ([.[] | select(.outcome == "escalated")] | length),
    deferred: ([.[] | select(.outcome == "deferred" or .outcome == "timeout")] | length)
  };

# $since (ISO-8601 UTC, empty = all history) scopes attempts by dispatch time.
# A terminal event belongs to the window of its dispatch; a terminal without a
# known dispatch counts only when it completed inside the window.
def report:
  . as $rows |
  [$rows[] | select(.outcome == "pending")] |
    group_by(attempt_key) | map(last) as $all_dispatches |
  ($all_dispatches | map({key: attempt_key, value: .}) | from_entries) as $dispatch_by_id |
  ([$all_dispatches[] | select((.issue // "") != "")] |
    group_by([(.repo // ""), (.issue // "")]) |
    map({key: (min_by(.dispatched_at // "") | attempt_key), value: true}) |
    from_entries) as $first_dispatch_ids |
  [$all_dispatches[] | select($since == "" or (.dispatched_at // "") >= $since)] as $dispatches |
  ($dispatches | map({key: attempt_key, value: true}) | from_entries) as $window_ids |
  [$rows[] | select(.outcome != "pending") | . as $terminal |
    if (($terminal.attempt_id // "") != "") then $terminal
    else
      [$all_dispatches[] | select(
        (.attempt_id // "") == "" and
        (.repo // "") == ($terminal.repo // "") and
        (.issue // "") == ($terminal.issue // "") and
        (.tier // "") == ($terminal.tier // ""))] as $matches |
      if ($matches | length) == 1 then $terminal + {attempt_id: ($matches[0] | attempt_key)} else $terminal end
    end |
    select(
      if (.attempt_id // "") == "" then ($since == "" or (.completed_at // "") >= $since)
      elif $dispatch_by_id[.attempt_id] != null then $window_ids[.attempt_id] == true
      else ($since == "" or (.completed_at // "") >= $since)
      end)] as $resolved_terminals |
  [$resolved_terminals[] | select((.attempt_id // "") != "")] |
    group_by(.attempt_id) | map(first) as $identified_terminals |
  [$resolved_terminals[] | select((.attempt_id // "") == "")] as $legacy_terminals |
  # Tier and model come from the dispatch row; the terminal row only fills gaps
  # left by launchers that register before the worker resolves its route.
  [$identified_terminals[] | select($window_ids[.attempt_id] == true) |
    . as $terminal | $dispatch_by_id[.attempt_id] as $dispatch |
    $terminal + {
      tier: (if ($dispatch.tier // "") != "" then $dispatch.tier else ($terminal.tier // "") end),
      model: (if ($dispatch.model // "") != "" then $dispatch.model else ($terminal.model // "") end)
    }] as $paired |
  ($paired | map({key: .attempt_id, value: .tier}) | from_entries) as $paired_tier |
  [$paired[] | select(.outcome != "deferred" and .outcome != "timeout")] as $completed |
  ($identified_terminals + $legacy_terminals) as $terminals |
  {
    since: $since,
    total: ($dispatches | length),
    success: ([$paired[] | select(.outcome == "success")] | length),
    escalated: ([$paired[] | select(.outcome == "escalated")] | length),
    failed: ([$paired[] | select(.outcome == "failed")] | length),
    deferred: ([$paired[] | select(.outcome == "deferred" or .outcome == "timeout")] | length),
    pending_unknown: (($dispatches | length) - ($paired | length)),
    unmatched: (($terminals | length) - ($paired | length)),
    by_tier: ($dispatches |
      map(attempt_key as $id | if (.tier // "") != "" then .tier else ($paired_tier[$id] // "") end) |
      group_by(.) | map({tier: .[0], count: length}) | sort_by(-.count)),
    reasons: ($terminals | map(select((.reason // "") != "")) | group_by(.reason) | map({reason: .[0].reason, count: length}) | sort_by(-.count)),
    pass_rates: ($completed | success_rate_rows),
    first_dispatch: ([$completed[] | select($first_dispatch_ids[.attempt_id] == true)] | success_rate_rows),
    by_model: ($paired | group_by([(.tier // ""), model_label]) |
      map((.[0] | {tier: (.tier // ""), model: model_label}) + outcome_counts) |
      sort_by([.tier, -.total]))
  };

if $operation == "find" then find_pending
elif $operation == "report" then report
else error("unknown telemetry operation")
end
