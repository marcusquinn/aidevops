## What

Supervisor recovery decisions recorded with `wake=external_trigger` never expire on time. Holds waiting on something only polling can see (a website recovering, a ceremony date passing, a "recheck after" time) are therefore parked indefinitely, and the AI owner never looks again. Add an optional structured `recheck_after` to `terminal-blocker-recovery-helper.sh record`, and give `external_trigger` decisions without one a bounded default re-poll interval. When either is due, the entry returns to the supervisor for re-assessment.

## Why

`_tbr_decision_active` (`.agents/scripts/terminal-blocker-recovery-release.sh:114`) treats `external_trigger` like `human_decision`: it wakes only on a maintainer reply or a policy change. GH#39688 (t19249) added `external_trigger` so that settled holds stay out of the `/decisions` "Needs your decision" list, and it inherited the no-TTL rule from GH#38692. That rule is right for a pending human answer. It is wrong for events no GitHub signal will ever report.

Evidence from one runner's recovery store (2026-11-24, a managed product repo):

- 25 `external_trigger` decisions (median age 2.1 days, maximum 7.6 days). At least 13 have a time-bound `next_action`, for example "Recheck after 2026-11-23T15:12Z", "Recheck after 2026-11-23T10:51Z", "Recheck after 2026-11-24T16:00Z", "Keep holding until after the 30 November 2026 ceremony", "seven days of recorded 503 checks (on or after 2026-11-28)".
- Three of those rechecks fell due 9–14 hours earlier and nothing re-assessed them. Each one stays `status:blocked` until a person happens to reply.
- This is the "blocked is a label, not an instruction" gap. The AI owner wrote down when to look again, and the framework has nowhere to keep that.

## How

1. `.agents/scripts/terminal-blocker-recovery-helper.sh` `tbr_record`: accept an optional `recheck_after` (ISO 8601 UTC, `YYYY-MM-DDTHH:MM:SSZ`), only with `wake=external_trigger`. Validate it with jq `fromdateiso8601` and store it as `recheck_after_epoch`. Reject an unknown key or a malformed or misplaced `recheck_after` with the existing error.
2. `.agents/scripts/terminal-blocker-recovery-release.sh` `_tbr_decision_active`: an `external_trigger` decision becomes inactive once `now >= recheck_after_epoch`, or, without one, once `recorded_epoch + BLOCKER_RECOVERY_EXTERNAL_TRIGGER_RECHECK` (new, default 259200, three days) has passed. `human_decision` keeps its positive-wake-only rule (GH#38692). Reply and policy-change wakes are unchanged.
3. `.agents/reference/worker-integration-recovery.md` step 6 and `.agents/reference/recovery-policy.md` step 5: document `recheck_after` and the default re-poll. Re-recording after a re-check sets the next `recheck_after`.

`/decisions` classification (`maintainer-decisions-helper.sh`) is unchanged; these holds still show as parked, not as questions.

### Files Scope

- `.agents/scripts/terminal-blocker-recovery-helper.sh`
- `.agents/scripts/terminal-blocker-recovery-release.sh`
- `.agents/reference/worker-integration-recovery.md`
- `.agents/reference/recovery-policy.md`

## Acceptance

- `record` accepts `{"wake":"external_trigger","next_action":...,"evidence":...,"recheck_after":"2026-11-25T16:00:00Z"}` and stores `recheck_after_epoch`. It rejects `recheck_after` on other wakes and rejects malformed values.
- `_tbr_decision_active` is active before `recheck_after` and inactive after it. Without `recheck_after`, it is inactive after the default interval. `human_decision` is still active past both.
- `shellcheck` is clean; `tests/test-recovery-policy.sh`, `tests/test-terminal-blocker-circuit-discovery.sh` and `tests/test-terminal-blocker-circuit-rearm.sh` pass.

## Cost

About 25 parked holds resurface roughly every three days (≈8 per day), against the 60+ per day that GH#38692 fixed. The decided-tier queue share from t19105 bounds the effect on undecided entries.
