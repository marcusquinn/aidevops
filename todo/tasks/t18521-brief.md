<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18521: Public-repo keywords backfill issues need hub access, not auto-dispatch

## Origin

- **Created:** 2026-09-28
- **Session:** opencode interactive (Build+)
- **Created by:** ai-interactive
- **Parent task:** none (follow-up to t18509 rollout)
- **Conversation context:** `aidevops keywords issues --apply` filed `auto-dispatch` backfill issues in 26 repos. For the only public repo (marcusquinn/aidevops, GH#32796) a worker on another operator's runner merged PR #32797 (gitignore + AGENTS.md pointer only) and closed the issue with "populating local data next". The private hub stayed empty: the worker had no hub slug or access (hub config is local-only by design). The maintainer then populated the registry interactively and synced it. All 9 closed private-repo issues did commit real registries (10-14 targets, 6-8 questions).

## What

For repositories whose keywords data mode is `ignored` (public repos), backfill issues are filed without `auto-dispatch`, with `no-auto-dispatch` and a recorded reason, and their body requires hub-sync evidence. `survey`/`issues` treat a property that already exists in the hub/local store as populated, so re-running `issues --apply` never files a duplicate.

## Why

Registry data for public repos must only live in the private team hub. Workers cannot reach it, so any worker run can only scaffold and must not close the issue. Pulse would otherwise dispatch work that cannot meet its acceptance criteria and mark it `solved:worker`.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/keywords-helper.sh:514-524` — `_kw_file_issue` takes the repo path, resolves `_kw_data_mode` (line ~220), and for `ignored` uses labels `no-auto-dispatch,tier:standard,enhancement` plus a public-repo body variant.
- `EDIT: .agents/scripts/keywords-helper.sh:448-500` — `_kw_issue_body` accepts the mode; the `ignored` variant states "Interactive/maintainer only: registry data is written only to the private team hub, which workers cannot access" and makes "`aidevops keywords sync` output showing `published: true`" an acceptance criterion.
- `EDIT: .agents/scripts/keywords-helper.sh:384-399` — `_kw_survey_rows` sets `has_keywords=true` when `context/keywords.md` exists OR the property directory exists under the configured data root (hub checkout or local store; property id = `owner__repo`).
- `EDIT: .agents/scripts/tests/test-keywords-helper.sh` — extend the existing public-repo case: `issues` dry run reports the ignored mode; survey counts a hub-only property as populated.
- `EDIT: .agents/seo/keywords-standard.md` — one line under rollout: public-repo backfill is maintainer-only.

### Complete Write Surface

- **Callers/readers:** `cmd_issues` (line ~526) and `cmd_survey` (line ~401) consume `_kw_survey_rows`; `_kw_file_issue` is only called from `cmd_issues`. `rg -n "_kw_survey_rows|_kw_file_issue|_kw_issue_body" .agents/scripts` confirms.
- **Writers/mutation paths:** GitHub issue creation via `gh_create_issue` (`shared-gh-wrappers-create.sh`); labels come only from `_kw_file_issue`.
- **Existing verification/tests:** `.agents/scripts/tests/test-keywords-helper.sh` (36 offline tests, includes "scaffold ignored data" public case); `pre-dispatch-validator-helper.sh scope-check` for the generated body.
- **Schemas/config:** N/A — no config keys change; hub location still comes from `keywords.hub_slug` / `AIDEVOPS_KEYWORDS_*`.
- **Generated/deployed mirrors:** `~/.aidevops/agents/scripts/keywords-helper.sh` via `setup.sh`.
- **Migrations/backfills:** N/A because no stored data changes; the only public-repo issue (GH#32796) is already closed and its registry is in the hub, so existing issues need no relabelling.
- **Cleanup/rollback paths:** N/A because the change persists no state; reverting `.agents/scripts/keywords-helper.sh` restores the previous labels.

### Implementation Steps

1. Change `_kw_file_issue <slug> <repo_path>`; compute `mode=$(_kw_data_mode "$repo_path")` and pick labels:

```bash
local labels="auto-dispatch,tier:standard,enhancement"
if [[ "$mode" == "ignored" ]]; then
	labels="no-auto-dispatch,tier:standard,enhancement"
fi
```

2. Pass `mode` into `_kw_issue_body`; for `ignored`, append a `## Dispatch` section stating the durable reason (private hub access) and replace the public-repo acceptance line with the sync-evidence criterion. Keep the canonical `### Files Scope` (validated by `pre-dispatch-validator-helper.sh scope-check`).
3. In `cmd_issues`, pass `repo_path` to `_kw_file_issue` and include `mode=` in the dry-run line.
4. In `_kw_survey_rows`, after the local-file check, call the Python helper or compute the property path to set `has_keywords=true` when the property exists in the data root. Reuse `keywords_hub.property_id` / `data_root` via `_kw_py` rather than re-implementing path logic in shell.
5. Extend the test cases; run shellcheck, the test suite and `linters-local.sh --changed`.

### Hazards and Compatibility

- **Concurrency/atomicity:** read-only survey plus single issue creation per repo; unchanged from today.
- **Migration/rollback:** no stored data; revert is safe.
- **Mixed-version/backward compatibility:** older helper versions keep filing `auto-dispatch` for public repos until updated; the fix only affects new issues.
- **Idempotency/retry:** the hub-aware `has_keywords` makes `issues --apply` idempotent for public repos after interactive population (today it would re-file).
- **Partial failure/recovery:** if the hub is unreachable, survey falls back to the local-file check (current behaviour); creation failures already warn and continue.

### Complexity Impact

- **Target function:** `_kw_survey_rows` in `.agents/scripts/keywords-helper.sh`
- **Current line count:** ~16 lines (threshold: 100)
- **Estimated growth:** +6 lines
- **Projected post-change:** ~22 lines
- **Action required:** None

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/keywords-helper.sh .agents/scripts/tests/test-keywords-helper.sh
bash .agents/scripts/tests/test-keywords-helper.sh
aidevops keywords issues          # dry run: marcusquinn/aidevops no longer listed (hub has the property)
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** shellcheck covers both edited scripts; the test suite proves label selection by mode and hub-aware survey (acceptance 1-3); the live dry run proves idempotency against the real hub; changed-file lint covers the doc line.
- **Broad verification trigger:** Not required.

### Files Scope

- .agents/scripts/keywords-helper.sh
- .agents/scripts/tests/test-keywords-helper.sh
- .agents/seo/keywords-standard.md

## Acceptance Criteria

- [ ] Public (`data: ignored`) repos get `no-auto-dispatch` backfill issues with the hub-access reason and a sync-evidence acceptance criterion.
- [ ] Private repos keep `auto-dispatch` and the current body.
- [ ] `survey` reports a hub-only property as populated; `issues --apply` does not re-file for it.
- [ ] Generated bodies pass `pre-dispatch-validator-helper.sh scope-check`.
- [ ] Test suite passes.
