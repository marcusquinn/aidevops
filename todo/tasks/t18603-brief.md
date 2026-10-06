## Origin

- **Created:** 2026-10-06, interactive throughput review (maintainer session)
- **Evidence source:** `~/.aidevops/logs/pulse.log`, `~/.aidevops/logs/pulse-wrapper.log`, live `gh api` probe with gh 2.102.0

## What

Pulse conditional requests must recognise a GitHub `304 Not Modified` again, so unchanged repos and owners are served from cache instead of being refetched or treated as failures every cycle.

## Why

With gh 2.102.0 (released 2026-09-30), `gh api -i -H 'If-None-Match: <etag>' <path>` on a 304 writes **nothing to stdout**, prints `gh: HTTP 304` to stderr and exits 1. Both pulse consumers expect an `HTTP/... 304` header line:

- `pulse-batch-prefetch-helper.sh:690-694` writes stdout to the response file; `pulse-batch-conditional-cache.py` `_split_response` raises `missing HTTP status`, so the slug is logged `conditional REST ...: failed for <slug>; falling back` and refetched. `pulse.log` holds 4548 `conditional REST ... status=200` lines, 2261 `failed for` lines and **zero** 304s. Live probe: the stored ETag for an unchanged repo returns `gh: HTTP 304` with 0 stdout bytes.
- `pulse-events-tickle.sh:270-277` captures `2>&1` and `_events_tickle_parse_status` greps `^HTTP/`. In `pulse-wrapper.log` an unchanged org owner logged `fresh for owner=... (304 ETag match)` continuously until 2026-10-06T02:14Z, then only `unknown for owner=... (status=none exit=1)` from 03:10Z onward — a clean cutover consistent with the local gh upgrade.

Effect: unchanged owners and repos are never served from cache, so every cycle pays the full refetch. `pulse.log` contains 81 `prefetch_batch_refresh timed out` lines. This is a prerequisite for any per-repo sleep/wake design, which depends on cheap "nothing changed" signals.

The unit fixtures (`tests/test-pulse-batch-prefetch-conditional-rest.sh:77,84`, `tests/test-pulse-events-tickle.sh`) stub `gh` to print `HTTP/2 304` headers on stdout, which current gh never does, so tests pass.

## Tier

`tier:standard` — two consumers, one shared classification, realistic fixtures.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-batch-prefetch-helper.sh:686-705` — when the request exits non-zero, stdout is empty and stderr contains `HTTP 304`, write a synthetic `HTTP/2 304` header block (keeping the request ETag) to the response file before parsing; keep the existing 304 cache path.
- `EDIT: .agents/scripts/pulse-events-tickle.sh:129-137` — `_events_tickle_parse_status` also recognises `gh: HTTP <code>` lines (it already receives stderr via `2>&1`).
- `EDIT: .agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh` and `.agents/scripts/tests/test-pulse-events-tickle.sh` — make the 304 stub match gh 2.102 (empty stdout, `gh: HTTP 304` on stderr, exit 1); keep one legacy header-style case.
- Optional, same PR if small: `pulse-prefetch-workers.sh:37-73` — read this first; if a batch timeout (rc 124) drops the conditional/tickle counters before they reach pulse-health, report partial counters or log that they were lost. Skip if counters already survive timeouts.

### Complete Write Surface

- **Callers/readers:** `prefetch_batch_refresh` (pulse prefetch stage), `pulse-cache-prime.sh`, `events_tickle` callers in the batch helper.
- **Writers/mutation paths:** batch snapshot cache files under `~/.aidevops/logs/batch-prefetch/`, events ETag cache.
- **Other `gh api -i` users** (`shared-gh-wrappers-rest-read-semantics.sh:480`, `shared-gh-collaborator-permission.sh`, `cloudron-package-monitor-helper.sh:62`, `forge-image-embed-helper.sh:148`): send no `If-None-Match`, so they cannot receive 304; verify, no change expected.
- **Schemas/config/mirrors/migrations:** none. **Rollback:** revert.

### Hazards and Compatibility

- Only treat the empty-stdout `HTTP 304` stderr form as 304 when an `If-None-Match` was sent; any other non-zero exit keeps the existing fail-open fallback.
- Keep parsing real header output so older gh versions still work.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh
bash .agents/scripts/tests/test-pulse-events-tickle.sh
shellcheck .agents/scripts/pulse-batch-prefetch-helper.sh .agents/scripts/pulse-events-tickle.sh
```

Runtime: after deploy, `rg "conditional REST .*304 cache hit" ~/.aidevops/logs/pulse.log` shows hits and `prefetch_batch_refresh timed out` stops appearing every cycle.

- **Broad verification trigger:** Not required.

### Files Scope

- `.agents/scripts/pulse-batch-prefetch-helper.sh`
- `.agents/scripts/pulse-events-tickle.sh`
- `.agents/scripts/pulse-prefetch-workers.sh`
- `.agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh`
- `.agents/scripts/tests/test-pulse-events-tickle.sh`

## Acceptance Criteria

- [ ] Positive: an unchanged repo with a stored ETag is served from cache (`304 cache hit`) under gh 2.102 behaviour (empty stdout, `gh: HTTP 304` stderr, exit 1).
- [ ] Positive: events tickle reports `fresh (304 ETag match)` under the same behaviour.
- [ ] Regression: a non-304 failure still falls back as before; legacy header-style 304 output still works.
- [ ] All verification commands pass.
