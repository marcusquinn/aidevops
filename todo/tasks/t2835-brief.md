# t2835 — Manual single-issue dispatch CLI for smoke-testing pulse worker dispatch

## Session Origin

Interactive session investigation of pulse cycle delays (median 23.5 min, max 3.5 h between
cycles). 5-issue productivity batch filed; this is item 5/5 — a developer-experience helper
that provides a fast, deterministic way to validate the dispatch path without waiting for the
next pulse cycle. Implemented in same interactive session as t2829 (stale-lock breaker fix);
the two together address "pulse stops dispatching" (t2829) and "I want to test dispatch
without waiting for the pulse" (t2835).

## Canonical brief

The full brief lives in the GitHub issue body — it is worker-ready (per t2417 heuristic) and
duplicating it here would create two sources of truth.

→ <https://github.com/marcusquinn/aidevops/issues/20882>

## Implementation summary

- New helper `.agents/scripts/dispatch-single-issue-helper.sh` (subcommands: `dispatch`,
  `status`, `help`).
- New slash command doc `.agents/scripts/commands/dispatch-issue.md`.
- Brief stub (this file).

## Acceptance

See issue body. Verified locally (interactive session):

- `shellcheck` clean.
- `--dry-run` prints planned dispatch including dedup status.
- `--model <id>` overrides label-inferred model.
- Closed/missing issues rejected with clear error messages.
- `status` reads `dispatch-ledger-helper.sh check-issue` correctly.

## Notes

- Helper deliberately skips `dispatch_with_dedup` (`pulse-dispatch-core.sh:969`) which has
  20+ transitive dependencies and 9+ dedup gates — that ceremony belongs in the pulse loop,
  not in a manual smoke-test CLI. The helper still calls `dispatch-dedup-helper.sh
  is-assigned` for the user-safety check (so manual dispatch can't double-launch).
- Worker shape mirrors `pulse-dispatch-engine.sh:489` — `/full-loop Implement issue #N
  (<url>)`. `headless-runtime-lib` auto-appends `HEADLESS_CONTINUATION_CONTRACT_V6`.

## Origin

`#interactive` (implemented in active interactive session, not queued for worker).
