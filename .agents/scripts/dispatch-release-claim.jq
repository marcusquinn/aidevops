# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# A snapshot fence, not a GitHub compare-and-swap. Never reconstruct a claim
# from a release or treat repository-management permission as claim ownership.
def fields:
    split(" ")[1:] as $parts |
    if all($parts[]; test("^[a-z_]+=[^[:space:]]+$")) then
        ($parts | map(split("=") | {key:.[0], value:(.[1:] | join("="))})) as $pairs |
        if ($pairs | map(.key) | unique | length) == ($pairs | length)
        then $pairs | from_entries else null end
    else null end;
def unedited:
    (.created_at | type) == "string" and
    (try (.created_at | fromdateiso8601) catch null) != null and ._release_body_unedited == true;
def bound($event):
    $event.comment.user.login == $runner and
    $event.f.runner == $runner and $event.f.lease_token == $token and
    $event.f.device == $device and $event.f.session == $session;
def lease_bound($event):
    $event.comment.user.login == $runner and
    $event.f.lease_token == $token and $event.f.device == $device and $event.f.session == $session;
def closes_claim($claim):
    .comment.user.login == $runner and .f != null and .f.runner == $runner and
    .f.claim_id == ($claim.comment.id | tostring) and .f.nonce == $token and
    (.comment | unedited);

[.[][] | . as $comment | .body | split("\n")[] |
 select(test("^(DISPATCH_CLAIM|DISPATCH_LEASE|CLAIM_RELEASED) ")) |
 {comment:$comment, line:., kind:split(" ")[0], f:fields}] as $events |
[$events[] | select(.kind == "DISPATCH_CLAIM" and .comment.user.login == $runner) |
 select((.line | split(" ") | index("nonce=" + $token)) != null)] as $claims |
if ($claims | length) == 0 then {verdict:"unowned"}
elif ($claims | length) != 1 then {verdict:"ambiguous"}
else $claims[0] as $claim |
    if $claim.f == null or ($claim.f.phase // "prelaunch") != "prelaunch" then {verdict:"ambiguous"}
    elif (bound($claim) | not) then {verdict:"unowned"}
    elif ($claim.comment | unedited | not) then {verdict:"edited"}
    elif any($events[]; (.comment.id | type) != "number" or .comment.id <= 0 or
             (.comment.id | floor) != .comment.id) then {verdict:"ambiguous"}
    elif ([$events[] | select(.comment.id >= $claim.comment.id) | .comment.id] |
          length != (unique | length)) then {verdict:"ambiguous"}
    else [$events[] | select(.comment.id > $claim.comment.id)] as $later |
        # A competing/replacement claim is not authority to release an older
        # generation. Retain state rather than adjudicating a claim race here.
        if any($later[]; .kind == "DISPATCH_CLAIM") then {verdict:"superseded"}
        elif $projection_line == "" and any($later[]; .kind == "CLAIM_RELEASED") then
             if all($later[] | select(.kind == "CLAIM_RELEASED"); closes_claim($claim))
             then {verdict:"released"} else {verdict:"ambiguous"} end
        elif $projection_line == "" and any($later[];
             .kind == "DISPATCH_LEASE" and lease_bound(.) and .f.phase == "terminal") then {verdict:"terminal"}
        elif any($later[]; .f == null or (.comment | unedited | not)) then {verdict:"ambiguous"}
        elif any($later[]; .kind == "DISPATCH_LEASE" and
             ((lease_bound(.) | not) or
              (.f.phase != "prelaunch" and .f.phase != "ready" and .f.phase != "terminal"))) then {verdict:"ambiguous"}
        elif any($later[]; .kind == "CLAIM_RELEASED" and
             (.line != $projection_line or (bound(.) | not) or
              .f.nonce != $token or .f.claim_id != ($claim.comment.id | tostring))) then {verdict:"ambiguous"}
        elif $projection_line != "" and
             ([$later[] | select(.kind == "CLAIM_RELEASED" and .line == $projection_line)] | length) != 1
             then {verdict:"ambiguous"}
        else {verdict:"owned", claim_id:$claim.comment.id}
        end
    end
end
