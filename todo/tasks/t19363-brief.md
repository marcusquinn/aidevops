## What

Cut worker-lifecycle journal compaction from ~10 s to ~2 s, so it no longer holds the SQLite writer long enough to refuse tool-hook admission with `database-locked`. The second compaction query in `compact()` should look up the indexed `generation_admissions` table instead of a JSON copy of it that is rescanned for every candidate event.

## Why

- Workers fail on their first command. `BLOCKED: lifecycle owner admission is unavailable (database-locked); no write authorized` refuses even `gh issue view` and `git status`, so the worker ends with `TERMINAL_BLOCKER_REASON=runner_capability_unmet`.
  - About 35 worker failure excerpts in `~/.aidevops/logs/worker-failure-excerpts/` show it since 2026-11-13.
  - Four workers died together at 2026-11-24T21:10Z, on issues 32323, 32746, 32971 and 32994.
  - Interactive and bounded-operation sessions are refused too: 7 to 53 `database-locked` refusals a day in `~/.aidevops/logs/lifecycle-admission/*.jsonl`.
- Root cause, measured on a read-only copy of the live registry (89,386 events against a 100,000 cap):
  - `automatic_compaction()` (`journal.py`) runs inside every write connection (`storage.py` `connection()`), under `BEGIN IMMEDIATE`, once events reach 90% of the cap.
  - `compact()` takes 10.8 s. Query 2 accounts for 9.9 s of that.
  - `EXPLAIN QUERY PLAN` shows `CORRELATED SCALAR SUBQUERY ... SCAN json_each`. The `reservations` CTE parses a JSON array of all 2,346 `generation_admissions` rows once per candidate event.
- Hook admission (`worker-lifecycle-session-helper.py`) allows about 7 s: a 2 s busy timeout per attempt, plus retries of 0.25 s and 0.75 s. The plugin kills the helper at 10 s.
  - When the hook itself is the writer that triggers compaction, the kill rolls compaction back. The next writer then repeats it.
  - Evidence: duplicate same-size `events-archive-*.json` files a few seconds apart.
- Every refusal window lines up with an archive write:
  - From 2026-11-24T21:08:46Z to 21:10:27Z the journal recorded no events. The next archive was written at 21:10:27Z.
  - The 2026-11-24 and 2026-11-25 refusals match archive timestamps too.
- With roughly 12-16k events a day and about 1,000 archived per trigger, compaction fires about 15 times a day.

## How

- In `.agents/worker-lifecycle/worker_lifecycle/journal.py` `compact()`, when the `generation_admissions` table exists, have query 2 reference it directly:
  - `NOT EXISTS (SELECT 1 FROM generation_admissions a WHERE a.generation_id=g.generation_id)`;
  - `a.path=json_extract(e.payload,'$.source') OR a.generation_id IN (SELECT value FROM json_each(e.payload,'$.generations'))`.
  - `generation_id` is the primary key and `path` is UNIQUE, so both are indexed lookups.
- Schema-1 stores have no table. Keep an empty reservation set there, for example a CTE yielding no rows, so the SQL never names a missing table.
- Keep the eligible row set identical. On the live-store copy, the indexed variant ran in 1.26 s against 6.13-9.92 s and returned the same 27 rows in the same order.
- Change no policy: retention, the event types eligible for archiving, the archive-first write, tombstones and the lock sweep all stay the same.

### Files Scope

- `.agents/worker-lifecycle/worker_lifecycle/journal.py`

## Acceptance criteria

- `python3 -m unittest discover -s .agents/worker-lifecycle/tests -p 'test_*.py'` passes, or at least the suites covering compaction: `test_storage.py`, `test_admission.py`, `test_events.py`, `test_retirement.py`, `test_path_release.py` and `test_preservation.py`.
- On a copy of a large registry, `compact(apply=False)` returns the same `eligible_events` as before and runs at least 3x faster.
- Schema-1 stores (no `generation_admissions` table) still compact without SQL errors, covered by existing schema-1 tests.
- No change to the admission or refusal message contract. `terminal-blocker-recovery-release.sh` matches the exact refusal signature.

## Verification after deploy

- `rg -c '"reason":"database-locked"' ~/.aidevops/logs/lifecycle-admission/<day>.jsonl` drops well below the 7-53 a day baseline.
- No new worker failure excerpts with `database-locked`.
