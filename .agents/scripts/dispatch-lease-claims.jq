[.[] |
    (.body | capture("nonce=(?<nonce>[^ ]+) runner=(?<runner>[^ ]+) ts=(?<ts>[^ ]+)(?: max_age_s=[^ ]+)?(?: version=(?<version>[^ ]+))?")) as $fields |
    ((.body | try capture("lease_token=(?<value>[^ ]+)").value catch "") // "") as $token |
    ((.body | try capture("device=(?<value>[^ ]+)").value catch "") // "") as $device |
    ((.body | try capture("expires_at=(?<value>[0-9]+)").value catch "0") // "0") as $expires |
    {
        id: .id, nonce: $fields.nonce, runner: $fields.runner, ts: $fields.ts,
        version: ($fields.version // "unknown"),
        lease_token: (if $token == "" then $fields.nonce else $token end),
        device: (if $device == "" then "legacy" else $device end),
        lease_expires_at: ($expires | tonumber? // 0),
        created_at: .created_at,
        created_epoch: (.created_at | fromdateiso8601? // 0)
    }
] |
map(. + {age_seconds: ($now - .created_epoch)}) |
map(. as $claim |
    ([ $comments[]
       | select((.body // "") | contains("lease_token=" + $claim.lease_token))
       | select((.body // "") | contains("DISPATCH_LEASE"))
       | . + ((.body | capture("phase=(?<phase>[^ ]+).*expires_at=(?<expires>[0-9]+)")) as $t
              | {transition_phase:$t.phase, transition_expires:($t.expires|tonumber), transition_epoch:(.created_at | fromdateiso8601? // 0)})
     ] | sort_by(.created_at, .id)) as $transitions |
    (reduce $transitions[] as $event
      ({phase:"prelaunch", expires:$claim.lease_expires_at};
       if .phase == "terminal" or .expires < $event.transition_epoch then .
       elif $event.transition_phase == "ready" and .phase == "prelaunch" and $event.transition_expires >= $event.transition_epoch
         then {phase:"ready", expires:$event.transition_expires}
       elif $event.transition_phase == "terminal" and (.phase == "prelaunch" or .phase == "ready")
         then {phase:"terminal", expires:0}
       else . end)) as $state |
    $claim + {lease_phase:$state.phase, lease_expires_at:$state.expires}) |
map(select(.age_seconds >= 0 and .age_seconds <= $max_age)) |
map(select(.lease_phase != "terminal" and ((.lease_expires_at // 0) == 0 or .lease_expires_at >= $now))) |
sort_by([.created_at, .nonce])
