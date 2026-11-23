## What

Make the Pulse steering relay and issue-watch reads revalidate for free. Replace the per-repo `issues?since=<moving timestamp>` listing, whose URL changes on every run, with stable per-issue reads, so the transport governor's conditional cache (GH#38566) gets `304 Not Modified` at zero primary-quota cost when nothing changed.

## Why

Evidence from `~/.aidevops/logs/gh-api-calls.log` on one host, 2026-11-21, about 2.2h window:

- `worker-bus-relay-helper.sh` made 460 attempts: 440 paid `200` (cost 1 each) and 20 free `304`, a 4% free share. Host-wide REST traffic in the same period was about 42% free `304`.
- Trailing hour: the relay was the 9th-largest REST cost caller at 182 points on 188 attempts. That is about 5% of the 3,800-point logged REST-core hour on a PAT budget the governor already holds near saturation (see GH#39611).
- Cause: `_relay_repo` (`.agents/scripts/worker-bus-relay-helper.sh:399-422`) lists `repos/{repo}/issues?state=all&since=${since_iso}...`, where `since` is `min(checked) - 60`. `checked` advances every run (`WORKER_BUS_RELAY_MIN_INTERVAL`, default 120 s; run every 2 min by `worker-watchdog.sh` and at each Pulse cycle), so the URL never repeats and `gh_conditional_cache` never holds a validator for it. The watch pass (`.agents/scripts/worker-bus-relay-watches.sh:345`) has the same pattern.
- `repos/{repo}/issues/{n}` has a stable URL. An unchanged issue returns `304` (free), and `comments` and `updated_at` in the body already tell the relay whether to read comments (`_relay_worker`, lines 349-372).

## How

- In `_relay_repo` / `_relay_worker`, read each due worker's issue with `_relay_get "repos/${repo}/issues/${issue_number}"` (stable URL, conditional-cache eligible) instead of filtering a moving `since` listing. Keep the existing comment-count and `updated_at >= started` gate before any comments read, and the `delivery` admission class.
- Apply the same change to the issue-watch pass in `.agents/scripts/worker-bus-relay-watches.sh` (listing at line 345).
- Keep the single-runner lock, REST-core deferrable gate, stop flag and failure handling. A failed or deferred read leaves state unchanged, as today.
- Request count per run becomes one per due worker or watch instead of one per repo. That stays far below secondary limits at current scale (tens per run). Note the trade-off in `.agents/reference/session-bus.md` "Pulse steering relay" and in the helper header (lines 16-22).
- Before editing, read the GH#38566 notes in `.agents/scripts/gh-transport-governor.py` (lines 1-30) to confirm `gh api repos/{o}/{r}/issues/{n}` through the shim is an eligible conditional GET.

## Files Scope

- `.agents/scripts/worker-bus-relay-helper.sh`
- `.agents/scripts/worker-bus-relay-watches.sh`
- `.agents/reference/session-bus.md`

## Acceptance

- After deploy, with unchanged watched issues, relay attempts in `gh-api-calls.log` are mostly `304` with cost `0`, not `200` with cost `1`.
- Steering still arrives. A new comment, a steering label added after start, and issue closure each produce exactly one relay message, as before.
- Existing relay tests pass: `rg -l "worker-bus-relay" .agents/scripts/tests` lists them; run each with `bash`.

## Verification

- `shellcheck -x .agents/scripts/worker-bus-relay-helper.sh .agents/scripts/worker-bus-relay-watches.sh`
- The relay tests found above.
- Runtime, after deploy: tabulate the last hour of `worker-bus-relay-helper.sh` rows in `~/.aidevops/logs/gh-api-calls.log`, grouped by field 15 (HTTP status) and field 17 (quota cost). Compare against the 440/20 baseline.
