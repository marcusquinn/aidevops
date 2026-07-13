def attempt_key:
  if ((.attempt_id // "") != "") then .attempt_id
  else ["legacy", (.repo // ""), (.issue // ""), (.dispatched_at // ""), (.tier // ""), (.model // "")] | join(":")
  end;

def find_pending:
  . as $rows |
  [.[] | select(.outcome == "pending") |
    select(($aid == "" or attempt_key == $aid) and
      ($sk == "" or (.session_key // "") == $sk) and
      ($inum == "" or (.issue // "") == $inum) and
      ($slug == "" or (.repo // "") == $slug)) |
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

def report:
  . as $rows |
  [$rows[] | select(.outcome == "pending")] |
    group_by(attempt_key) | map(last) as $dispatches |
  [$rows[] | select(.outcome != "pending") | . as $terminal |
    if (($terminal.attempt_id // "") != "") then $terminal
    else
      [$dispatches[] | select(
        (.attempt_id // "") == "" and
        (.repo // "") == ($terminal.repo // "") and
        (.issue // "") == ($terminal.issue // "") and
        (.tier // "") == ($terminal.tier // ""))] as $matches |
      if ($matches | length) == 1 then $terminal + {attempt_id: ($matches[0] | attempt_key)} else $terminal end
    end] as $resolved_terminals |
  [$resolved_terminals[] | select((.attempt_id // "") != "")] |
    group_by(.attempt_id) | map(first) as $identified_terminals |
  [$resolved_terminals[] | select((.attempt_id // "") == "")] as $legacy_terminals |
  [$identified_terminals[] | select(.attempt_id as $id | any($dispatches[]; attempt_key == $id))] as $paired |
  [$paired[] | select(.outcome != "deferred" and .outcome != "timeout")] as $completed |
  ($identified_terminals + $legacy_terminals) as $terminals |
  {
    total: ($dispatches | length),
    success: ([$paired[] | select(.outcome == "success")] | length),
    escalated: ([$paired[] | select(.outcome == "escalated")] | length),
    failed: ([$paired[] | select(.outcome == "failed")] | length),
    deferred: ([$paired[] | select(.outcome == "deferred" or .outcome == "timeout")] | length),
    pending_unknown: (($dispatches | length) - ($paired | length)),
    unmatched: (($terminals | length) - ($paired | length)),
    by_tier: ($dispatches | group_by(.tier // "") | map({tier: (.[0].tier // ""), count: length}) | sort_by(-.count)),
    reasons: ($terminals | map(select((.reason // "") != "")) | group_by(.reason) | map({reason: .[0].reason, count: length}) | sort_by(-.count)),
    pass_rates: ($completed | group_by(.tier // "") | map(
      .[0].tier as $tier | {
        tier: ($tier // ""),
        total: length,
        success: ([.[] | select(.outcome == "success")] | length)
      }) | sort_by(.tier))
  };

if $operation == "find" then find_pending
elif $operation == "report" then report
else error("unknown telemetry operation")
end
