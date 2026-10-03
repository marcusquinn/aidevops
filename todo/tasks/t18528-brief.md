<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18528: keywords routine refreshes GSC/Bing exports before import

## Origin

- **Created:** 2026-09-28
- **Session:** opencode interactive (Build+)
- **Created by:** ai-interactive
- **Parent task:** none (found while adding Bing data to the aidevops keywords registry)
- **Conversation context:** The weekly `r-keywords-track` routine (`aidevops keywords routine-run`) imports only the newest `gsc-*.toon` / `bing-*.toon` files already present under `~/.aidevops/.agent-workspace/work/seo-data/<domain>/`. Nothing runs the exporters, so Search Console and Bing positions go stale unless someone runs `/seo-export` by hand. The Bing API key was also stored under an account-suffixed gopass name (`BING_WEBMASTER_API_KEY_<ACCOUNT>`), which `seo-export-bing.sh` cannot find because it only reads `BING_WEBMASTER_API_KEY` from env or `credentials.sh`.

## What

`keywords routine-run` refreshes GSC and Bing exports for each property's `domains` before importing them, when credentials are available, and `seo-export-bing.sh` resolves its API key from gopass (including a single account-suffixed entry) as well as env/`credentials.sh`.

## Why

Search-engine positions are the main signal for website targets. The routine already has the import path (`_latest_exports` → `track.from_export`), but without a refresh step the data is only as fresh as the last manual export, so trends and striking-distance reports silently stop moving.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/keywords_routine.py:65-96` — add `_refresh_exports(domains)` called at the start of the export block in `_free_sources`: for each domain and each source in (`gsc`, `bing`), run `~/.aidevops/agents/scripts/seo-export-helper.sh <source> <domain> --days 28` (resolve via `Path(__file__).parent / "seo-export-helper.sh"`) with `subprocess.run(..., timeout=300, check=False, capture_output=True)`; record `refreshed`/`skipped:<reason>` per source in the counts dict; never raise.
- `EDIT: .agents/scripts/seo-export-bing.sh:38-50` — `get_api_key`: after env and `credentials.sh`, try `gopass show -o aidevops/BING_WEBMASTER_API_KEY`; if absent and exactly one `aidevops/BING_WEBMASTER_API_KEY_*` entry exists (`gopass ls --flat aidevops/`), use it. Never print the value.
- `EDIT: .agents/scripts/seo-export-bing.sh:196-232` — help text lists the gopass lookup.
- `EDIT: .agents/seo/keywords-standard.md` — routine section: routine-run refreshes GSC/Bing exports (28 days) when credentials exist; missing credentials are skipped, not errors.

### Complete Write Surface

- **Callers/readers:** `keywords_routine.run` → `_free_sources`; `keywords-helper.sh routine-run` (routines `r-keywords-track` weekly, `r-keywords-paid` monthly) is the only caller. `seo-export-helper.sh bing` dispatches to `seo-export-bing.sh`. `rg -n "_free_sources|_latest_exports|get_api_key" .agents/scripts/keywords_routine.py .agents/scripts/seo-export-bing.sh` lists all uses.
- **Writers/mutation paths:** exporters write new TOON files under `~/.aidevops/.agent-workspace/work/seo-data/<domain>/`; the existing marker `store_dir()/state/<prop>.exports` then gates import. No registry write path changes.
- **Existing verification/tests:** `.agents/scripts/tests/test-keywords-helper.sh` ("routine-run completes offline" must keep passing with no credentials and no network).
- **Schemas/config:** N/A because no config keys are added; export window is fixed at 28 days in code.
- **Generated/deployed mirrors:** `~/.aidevops/agents/scripts/` via `setup.sh`.
- **Migrations/backfills:** N/A because existing export files and markers remain valid.
- **Cleanup/rollback paths:** N/A because only additive export files are written; reverting the two scripts restores import-only behaviour.

### Implementation Steps

1. In `keywords_routine.py`, add `_refresh_exports(domains: list[str]) -> dict[str, str]`; skip entirely when `AIDEVOPS_KEYWORDS_OFFLINE` is set or the helper is missing (the offline test must not hit the network — check how `test-keywords-helper.sh` isolates `routine-run` and follow that switch).
2. Call it before `_latest_exports` in `_free_sources`; merge results into `counts`.
3. In `seo-export-bing.sh` `get_api_key`, add the gopass fallback described above, guarded by `command -v gopass`.
4. Update help text and `keywords-standard.md`.

### Hazards and Compatibility

- **Concurrency/atomicity:** exporters write one new file per run; import picks the newest file by mtime, so a partial file from a timed-out export could be imported — write exports to a temp name and rename, or have `_refresh_exports` delete the file when the helper exits non-zero.
- **Migration/rollback:** N/A because behaviour without credentials is unchanged (skip).
- **Mixed-version/backward compatibility:** an unchanged `seo-export-bing.sh` still works when the key is in env/`credentials.sh`.
- **Idempotency/retry:** repeated runs create more dated export files; `_latest_exports` already takes only the newest.
- **Partial failure/recovery:** one source failing (e.g. Bing "No data returned" for a newly added site) must not stop GSC import or the rest of the routine.

### Complexity Impact

- **Target function:** `_free_sources` in `.agents/scripts/keywords_routine.py`
- **Current line count:** 22 lines (threshold: 100)
- **Estimated growth:** +2 lines (new logic lives in `_refresh_exports`, ~20 lines)
- **Projected post-change:** ~24 lines
- **Action required:** None

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-keywords-helper.sh
shellcheck .agents/scripts/seo-export-bing.sh
aidevops keywords routine-run      # on an install with GSC credentials: summary shows gsc refreshed/imported counts
~/.aidevops/agents/scripts/seo-export-helper.sh bing <verified-domain> --days 7   # key only in gopass
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the keywords test covers offline routine behaviour; the live routine run proves refresh + import; the Bing export proves the gopass key lookup; changed-file lint covers docs.
- **Broad verification trigger:** Not required.

### Files Scope

- .agents/scripts/keywords_routine.py
- .agents/scripts/seo-export-bing.sh
- .agents/seo/keywords-standard.md

## Acceptance Criteria

- [ ] `keywords routine-run` exports fresh GSC and Bing data for each property domain when credentials exist, then imports it.
- [ ] Missing credentials or "no data" for a source are reported as skipped in the summary; the routine still succeeds.
- [ ] `seo-export-bing.sh` finds a key stored in gopass as `BING_WEBMASTER_API_KEY` or a single `BING_WEBMASTER_API_KEY_*` entry.
- [ ] `test-keywords-helper.sh` passes without network access.
- [ ] No credential values are printed.
