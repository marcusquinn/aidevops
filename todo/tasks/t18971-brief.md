<!-- aidevops:brief-schema=v2 -->

## Origin

- **Created:** 2026-11-12
- **Created by:** ai-interactive (requested by the maintainer)
- **Parent task:** none. Companion docs: `.agents/tools/deployment/cloudron-package-onboarding.md` (marcusquinn/aidevops#37830)
- **Blocked by:** none
- **Conversation context:** A Cloudron package repository was registered without `aidevops init`. It had Pulse and maintenance off, no `app_type`/`cloudron_package` entry, no aidevops labels, no `.aidevops.json` and missing managed workflows. Its `auto-dispatch` task could not run and a new upstream release went unnoticed until a manual check. The maintainer asked that aidevops catch these gaps for new package repositories automatically.

## What

Add a deterministic Cloudron package setup audit so missed onboarding steps surface without anyone reading the checklist:

1. A report-only `setup` mode in `cloudron-package-monitor-helper.sh` that finds registered repositories containing `CloudronManifest.json` and prints one `SETUP <slug>: <gap>; fix: <command>` line per gap.
2. The weekly `compatibility` run also runs the setup audit first, so the existing r917 routine surfaces it with no routine change.
3. A warning at registration (`aidevops repos add` / `aidevops init`) when a Cloudron package is registered without `cloudron_package.upstream_slug`, pointing at the onboarding checklist.
4. A compatibility finding when the manifest sets `packageUrl` and `packagerUrl` to the same URL, which means the Community Apps "By" link opens the repository instead of the maintainer.

## Why

Prose checklists are skipped. The monitor only reads entries that already have `app_type == "cloudron-package"` and `maintenance != false` (`cloudron-package-monitor-helper.sh:894`), so the exact repositories that missed onboarding are invisible to every existing Cloudron routine.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Additive shell changes across three scripts with a verified reference pattern (`_cloudron_monitor_compatibility_entry`, `cloudron_package_compatibility_findings`); no design decisions remain open, but it spans multiple functions and needs test coverage of a new mode.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/cloudron-package-monitor-helper.sh:862-935` — add `_cloudron_monitor_setup_entry` and `_cloudron_monitor_setup_run`, a `setup` mode in `main`, help text, and a call from `compatibility` mode.
- `EDIT: .agents/scripts/cloudron-package-release-lib.sh:206-209` — add the `packagerUrl == packageUrl` finding to `cloudron_package_compatibility_findings`.
- `EDIT: .agents/scripts/aidevops-cli/aidevops-repos-lib.sh:639-643` — warn in `_register_repo_locked` when a Cloudron manifest is detected and the resulting entry has no `cloudron_package.upstream_slug`.
- `EDIT: .agents/scripts/tests/test-cloudron-package-monitor.sh` — fixture cases for `setup`.
- `EDIT: .agents/tools/deployment/cloudron-package-onboarding.md` — note that the weekly compatibility routine and `cloudron-package-monitor-helper.sh setup` audit steps 1–5.

### Complete Write Surface

- **Callers/readers:** r917 in `.agents/scripts/routines/core-routines.sh` invokes `cloudron-package-monitor-helper.sh compatibility --apply`; `aidevops.sh` `_repos_add` and `aidevops init` call `register_repo`; `cloudron-package-helper.sh check-compatibility` (`cloudron-package-helper.sh:1242`) and the monitor call `cloudron_package_compatibility_findings`.
- **Writers/mutation paths:** the setup audit writes nothing (stdout only). The compatibility finding flows through the existing `_cloudron_monitor_apply_finding` issue path. The registration warning prints only; `repos.json` writes are unchanged.
- **Existing verification/tests:** `.agents/scripts/tests/test-cloudron-package-monitor.sh` (fixture `repos.json`, stubbed `gh`), `.agents/scripts/tests/test-cloudron-package-release.sh`, `.agents/scripts/tests/test-cloudron-package-routines.sh`, `.agents/scripts/tests/test-cloudron-package-init.sh`.
- **Schemas/config:** reads existing `repos.json` fields only (`reference/repos-json-fields.md` `cloudron_package`); no new fields.
- **Generated/deployed mirrors:** deployed copies under `~/.aidevops/agents/scripts/` refresh via `setup.sh`; nothing generated.
- **Migrations/backfills:** N/A because the audit is read-only and adds no stored state.
- **Cleanup/rollback paths:** N/A because the audit creates no persistent state; reverting the three script changes restores prior behaviour.

### Implementation Steps

1. `_cloudron_monitor_setup_entry "$entry"` (model on `_cloudron_monitor_compatibility_entry`, `cloudron-package-monitor-helper.sh:772`): resolve `path` (expand `~`), return 0 unless `${path}/CloudronManifest.json` exists. Print one line per gap and return 3 if any were printed:
   - `app_type` is not `cloudron-package` → `fix: aidevops init (in a linked worktree)`.
   - no `${path}/.aidevops.json` → `fix: aidevops init`.
   - `maintenance == false` → `fix: aidevops repos maintenance on <slug>`; `pulse != true` → `fix: aidevops repos pulse on <slug>`.
   - `cloudron_package.upstream_slug` empty → `fix: set cloudron_package.upstream_slug (reference/repos-json-fields.md)`. An explicit `monitor_upstream: false` with a slug set is a deliberate opt-out; do not report it.
   - `gh api "repos/<slug>/labels/auto-dispatch"` fails with 404 → `fix: label-sync-helper.sh sync --repo <slug>`. Other API errors are reported as `SETUP <slug>: could not verify labels` and counted as failure, not as a gap.
2. `_cloudron_monitor_setup_run`: iterate `jq -c '.initialized_repos[] | select((.local_only // false) != true and (.slug // "") != "")'` (deliberately not filtered by `app_type` or `maintenance`). Return 0 when no gaps, 1 on read failures. Gaps alone return 0 so the weekly routine is not marked failed.
3. `main`: add `setup)` (ignores `--apply`), and in `compatibility` call `_cloudron_monitor_setup_run` before `_cloudron_monitor_run`, preserving the existing exit-code handling including `75`. Update `show_help`.
4. In `cloudron_package_compatibility_findings` before the final return:

   ```bash
   if jq -e '(.packageUrl // "") != "" and .packageUrl == .packagerUrl' "$manifest_path" >/dev/null 2>&1; then
   	printf '%s\n' '- packagerUrl equals packageUrl; set packagerUrl to the maintainer profile so the Community Apps "By" link is correct (cloudron-app-publishing-skill.md).'
   	findings=$((findings + 1))
   fi
   ```

5. In `_register_repo_locked`, after the registration write and only when `app_type_default == cloudron-package`, read the entry's `cloudron_package.upstream_slug`; if empty, `print_warning "Cloudron package registered without upstream monitoring; complete tools/deployment/cloudron-package-onboarding.md"`. Keep `return 0`.
6. Add fixture cases to `test-cloudron-package-monitor.sh` (see Verification).

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A because the audit only reads `repos.json` and GitHub; the existing registry lock still guards registration writes.
- **Migration/rollback:** no stored state; revert restores old behaviour.
- **Mixed-version/backward compatibility:** older `repos.json` entries without `cloudron_package` are exactly the reported case; nothing fails closed on missing fields.
- **Idempotency/retry:** report-only output is identical on repeat runs; the compatibility issue keeps its checksum fingerprint deduplication.
- **Partial failure/recovery:** a GitHub label lookup error marks the setup run failed without suppressing the existing compatibility loop; rate limit (75) still propagates.
- The new compatibility finding will open one issue in each package repository whose current manifest still has `packagerUrl == packageUrl`. That is intended and overlaps the open `packagerUrl` tasks in those repositories; the existing dedupe prevents repeats.

### Complexity Impact

- **Target function:** `cloudron_package_compatibility_findings` in `.agents/scripts/cloudron-package-release-lib.sh`
- **Current line count:** 71 lines (threshold: 100 lines for function-complexity)
- **Estimated growth:** +4 lines
- **Projected post-change:** 75 lines (75% of threshold)
- **Action required:** None. Put the setup audit in new functions, not in `_cloudron_monitor_run` or `_register_repo_locked` bodies beyond a call and the warning.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-cloudron-package-monitor.sh
bash .agents/scripts/tests/test-cloudron-package-release.sh
bash .agents/scripts/tests/test-cloudron-package-routines.sh
bash .agents/scripts/tests/test-cloudron-package-init.sh
shellcheck .agents/scripts/cloudron-package-monitor-helper.sh .agents/scripts/cloudron-package-release-lib.sh .agents/scripts/aidevops-cli/aidevops-repos-lib.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** new monitor test cases prove: a manifest repo with no `app_type`, Pulse off and no `upstream_slug` prints the matching `SETUP` lines; a fully configured fixture prints nothing; a repo without a manifest is ignored; `setup` never calls `gh issue create`. The release test proves the `packagerUrl == packageUrl` finding and its absence when they differ. Routines and init tests prove r917 and registration are unbroken. ShellCheck and `linters-local.sh --changed` cover style and complexity gates.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** the setup audit never edits `repos.json`, labels, workflows or package repositories, and never files issues; only the existing compatibility path files issues. Do not change routine schedules or add new routines.

**AI brief owner:** the maintainer's interactive session that filed this issue.

### Files Scope

- `.agents/scripts/cloudron-package-monitor-helper.sh`
- `.agents/scripts/cloudron-package-release-lib.sh`
- `.agents/scripts/aidevops-cli/aidevops-repos-lib.sh`
- `.agents/scripts/tests/test-cloudron-package-monitor.sh`
- `.agents/tools/deployment/cloudron-package-onboarding.md`

## Acceptance Criteria

- [ ] `cloudron-package-monitor-helper.sh setup` lists each onboarding gap for a manifest-bearing registered repository, with a fix command, including repositories without `app_type` or with maintenance off.
- [ ] `cloudron-package-monitor-helper.sh compatibility` runs the setup audit, and `cloudron-package-helper.sh check-compatibility` reports `packagerUrl == packageUrl`.
- [ ] Registering a Cloudron package without `upstream_slug` prints the onboarding warning.
- [ ] Regression guard: a fully configured package prints no `SETUP` lines, the setup audit never creates issues or edits files, and existing monitor/release/routines/init tests still pass.

## Context & Decisions

- Report-only for local registry gaps: they live in the maintainer's `~/.config/aidevops/repos.json`, which a worker cannot edit, so filing dispatchable issues for them would be wrong.
- The URL finding is repository content, so it uses the existing compatibility issue path.
