## What

macOS profile README "Screen time" under-reports. For 2026-11-08 the README showed 8.0h (and interactive `profile-stats` 7.1h) while pmset display assertions now show 12.4h. Fix the four collection defects below so the macOS row measures display-on time correctly in both the launchd (no Full Disk Access) and interactive paths.

## Why

Evidence (maintainer Mac, local TZ +0000):

1. **Backlit stream parsed inverted.** Each knowledgeC `/display/isBacklit` row is a completed span: the display held `ZVALUEINTEGER` from `ZSTARTDATE` to `ZENDDATE`; the row is written (`ZCREATIONDATE`) when the span ends. `parse_backlit_rows` treats `(ZCREATIONDATE, value)` as "state from now on", so every on-span is counted as off and vice versa. Per-day overlap with the pmset ∪ app-usage reference, 2026-10-22..11-05: current parse 0.0h overlap (it counts the complement; current + span ≈ 24h each day), span parse ≈ 100% overlap. Totals looked plausible because a 10-14h working day leaves 10-14h off.
2. **pmset misses the currently-held display assertion.** The parser reads only `Summary`/`Released` log lines. After the 2026-11-08 19:35 reboot no `Summary` lines were logged; the assertion appeared only when released at 2026-11-09 04:26 (duration 08:50:40). `pmset -g assertions` exposes the held assertion live (`pid 390(powerd): [...] 03:22:07 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"`).
3. **Snapshot never revisits a day.** The launchd snapshot recorded 2026-11-08 = 8.0h at 2026-11-09T01:40:31Z while the display was still on; replaying the parser at that instant reproduces 7.97h, now 12.38h. `cmd_snapshot` skips any already-recorded date, so the under-count is permanent and the README (history-preferred for the pmset proxy) shows it.
4. **Knowledge DB never unioned with pmset.** `collect()` uses pmset only when the knowledge DB is `unavailable`; a readable but gapped backlit stream (no rows ~2026-11-06..11-08 13:48) is never filled.

## How

- `.agents/scripts/screen_time_macos.py`: read `ZSTARTDATE, ZENDDATE, ZVALUEINTEGER` for `/display/isBacklit`; parse to `(start, end, on)` spans; on-intervals are the value-1 spans; observations are span ends.
- `.agents/scripts/screen_time_macos_pmset.py`: add the live held display assertion from `pmset -g assertions` as `[now - held, now]`; fixture env `AIDEVOPS_PMSET_ASSERTIONS_FIXTURE`; when `AIDEVOPS_PMSET_FIXTURE` is set without it, no live read (deterministic tests). Keep unmatched `Display is turned on` notifications ignored (existing test intent).
- `.agents/scripts/screen-time-interval-engine.py` `collect()`: union the selected knowledge-DB intervals with pmset intervals when both are available; label the merged source.
- `.agents/scripts/screen-time-helper.sh` `cmd_snapshot` + engine `revisable-dates`: re-record a date from the last 3 completed local days only when the recomputed value exceeds the recorded one (history is append-only; last row per date wins).
- `.agents/scripts/tests/test-screen-time-helper.sh`: backlit fixtures use span semantics; cover held assertion and snapshot revision.

## Acceptance

- `bash .agents/scripts/tests/test-screen-time-helper.sh` passes; ShellCheck clean on changed shell files.
- On a Mac: `screen-time-helper.sh profile-stats` day/week no longer equal the display-off complement; launchd-equivalent run (`AIDEVOPS_KNOWLEDGE_DB=/nonexistent ... profile-stats`) day value after a fresh `snapshot` reflects the full pmset day.

### Files Scope

- `.agents/scripts/screen_time_macos.py`
- `.agents/scripts/screen_time_macos_pmset.py`
- `.agents/scripts/screen_time_sources.py` (new: per-platform source selection and the Knowledge/pmset union, kept out of the engine for its Qlty file-complexity budget)
- `.agents/scripts/screen-time-interval-engine.py`
- `.agents/scripts/screen-time-helper.sh`
- `.agents/scripts/tests/test-screen-time-helper.sh`
- `.agents/scripts/tests/test-profile-readme-boundary.sh` (deployed-module copy list)
