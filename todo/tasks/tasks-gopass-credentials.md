---
mode: subagent
---
# Tasks: gopass Integration & Credentials Rename

Based on [ai-dev-tasks](https://github.com/snarktank/ai-dev-tasks) task format, with time tracking.

**PRD:** [prd-gopass-credentials.md](prd-gopass-credentials.md)
**Created:** 2026-02-06
**Status:** Not Started
**Estimate:** ~2d (ai:1d test:4h read:4h)

<!--TOON:tasks_meta{id,feature,prd,status,est,est_ai,est_test,est_read,logged,started,completed}:
tasks-gopass-credentials,gopass Integration & Credentials Rename,prd-gopass-credentials,not_started,2d,1d,4h,4h,2026-02-06T20:00Z,,
-->

## Relevant Files

### Part A: Rename (high-impact files)

- `.agents/scripts/setup-local-api-keys.sh` - Primary key management script (29 refs)
- `.agents/scripts/credential-helper.sh` - Multi-tenant credential management (7 refs)
- `.agents/scripts/list-keys-helper.sh` - Key discovery tool (27 refs)
- `.agents/scripts/watercrawl-helper.sh` - WaterCrawl integration (30 refs)
- `.agents/scripts/unstract-helper.sh` - Unstract integration (23 refs)
- `.agents/scripts/onboarding-helper.sh` - Onboarding flow (3 refs)
- `.agents/scripts/wordpress-mcp-helper.sh` - WordPress MCP (3 refs)
- `setup.sh` - Main installer (11 refs)
- `.agents/tools/credentials/api-key-setup.md` - Setup docs (10 refs)
- `.agents/tools/credentials/multi-tenant.md` - Multi-tenant docs (11 refs)
- `.agents/AGENTS.md` - User guide (2 refs)

### Part B: gopass integration

- `.agents/scripts/credential-helper.sh` - Extend with gopass backend
- `.agents/tools/credentials/gopass.md` - New: gopass subagent
- `.agents/tools/credentials/api-key-setup.md` - Update with gopass as primary
- `.opencode/tool/api-keys.ts` - Update to support gopass actions
- `setup.sh` - Add gopass installation option

### Part C: Documentation

- `.agents/AGENTS.md` - Add "never accept secrets in context" rule
- `.agents/tools/credentials/psst.md` - New: psst as alternative
- `.agents/aidevops/security.md` - Update security guidance

## Notes

- Part A (rename) is mechanical but high-volume -- use `rg` + `sed` for bulk updates, manual review for scripts
- Part B (gopass) requires gopass installed locally for testing
- The 7 scripts with `MCP_ENV_FILE` variable use `readonly` -- single point of change per script
- MCP template configs in `configs/mcp-templates/` embed the path in JSON -- careful with quoting
- Symlink migration must handle: fresh install, upgrade from old, both files exist

## Instructions

**IMPORTANT:** As you complete each task, check it off by changing `- [ ]` to `- [x]`.

Update after completing each sub-task, not just parent tasks.

## Tasks

### Part A: Rename mcp-env.sh to credentials.sh

- [ ] 1.0 Rename variable and path in scripts ~2h (ai:2h test:30m)
  - [ ] 1.1 Update `MCP_ENV_FILE` to `CREDENTIALS_FILE` in `setup-local-api-keys.sh` ~15m
  - [ ] 1.2 Update `MCP_ENV_FILE` to `CREDENTIALS_FILE` in `list-keys-helper.sh` ~15m
  - [ ] 1.3 Update `MCP_ENV_FILE` to `CREDENTIALS_FILE` in `watercrawl-helper.sh` ~15m
  - [ ] 1.4 Update `MCP_ENV_FILE` to `CREDENTIALS_FILE` in `unstract-helper.sh` ~15m
  - [ ] 1.5 Update `MCP_ENV_FILE` to `CREDENTIALS_FILE` in `onboarding-helper.sh` ~5m
  - [ ] 1.6 Update `MCP_ENV_FILE` to `CREDENTIALS_FILE` in `wordpress-mcp-helper.sh` ~5m
  - [ ] 1.7 Update path references in remaining ~18 scripts (no variable, just string path) ~30m
  - [ ] 1.8 Run ShellCheck on all modified scripts ~10m

- [ ] 2.0 Update setup.sh migration logic ~1h (ai:45m test:15m)
  - [ ] 2.1 Change `setup.sh` to create `credentials.sh` as canonical file ~15m
  - [ ] 2.2 Add migration function: detect `mcp-env.sh`, move to `credentials.sh`, create symlink ~20m
  - [ ] 2.3 Update shell rc injection to source `credentials.sh` (keep `mcp-env.sh` symlink) ~10m
  - [ ] 2.4 Update multi-tenant paths: `tenants/{name}/mcp-env.sh` to `tenants/{name}/credentials.sh` ~15m

- [ ] 3.0 Update documentation references ~1h (ai:45m read:15m)
  - [ ] 3.1 Update ~40 agent docs (`.agents/**/*.md`) with new path ~30m
  - [ ] 3.2 Update ~10 SEO docs with new path ~10m
  - [ ] 3.3 Update ~8 service docs with new path ~10m
  - [ ] 3.4 Update config templates in `configs/` ~10m

- [ ] 4.0 Update plugins and configs ~15m (ai:15m)
  - [ ] 4.1 Update `.agents/plugins/opencode-aidevops/index.mjs` ~5m
  - [ ] 4.2 Update `configs/mcp-templates/*.json` ~5m
  - [ ] 4.3 Update `configs/wordpress-sites-config.json.txt` placeholder ~5m

- [ ] 5.0 Verify rename completeness ~30m (ai:15m test:15m)
  - [ ] 5.1 Run `rg 'mcp-env' .agents/ setup.sh configs/ templates/` -- expect 0 results ~5m
  - [ ] 5.2 Run `rg 'MCP_ENV' .agents/scripts/` -- expect 0 results ~5m
  - [ ] 5.3 Test `source ~/.config/aidevops/mcp-env.sh` still works via symlink ~5m
  - [ ] 5.4 Test `source ~/.config/aidevops/credentials.sh` works directly ~5m
  - [ ] 5.5 Run `linters-local.sh` on all modified files ~10m

### Part B: gopass Integration

- [ ] 6.0 gopass setup and documentation ~2h (ai:1.5h read:30m)
  - [ ] 6.1 Create `.agents/tools/credentials/gopass.md` subagent ~45m
    - Installation (brew/apt/pacman/scoop)
    - Setup wizard (`gopass setup`)
    - Store structure for aidevops (`aidevops/` prefix)
    - Team sharing (multi-recipient GPG, git sync)
    - Integration with git-credential-gopass
    - Integration with gopass-bridge (browser)
    - Integration with gopass-hibp (leak checking)
  - [ ] 6.2 Add gopass to `subagent-index.toon` ~5m
  - [ ] 6.3 Update `api-key-setup.md` to recommend gopass as primary ~30m
  - [ ] 6.4 Update `multi-tenant.md` to document gopass mount mapping ~30m

- [ ] 7.0 Build `aidevops secret` wrapper ~3h (ai:2.5h test:30m)
  - [ ] 7.1 Create `secret-helper.sh` with core commands ~1.5h
    - `init` -- run `gopass setup` if not initialized
    - `set NAME` -- delegate to `gopass insert aidevops/NAME`
    - `list` -- delegate to `gopass ls aidevops/`
    - `run CMD` -- inject all gopass secrets into subprocess, redact output
    - `NAME [NAME...] -- CMD` -- inject specific secrets, redact output
    - `import-credentials` -- read key names from credentials.sh, prompt user to re-enter via gopass
    - `get NAME` -- print value (human debugging only, with warning)
  - [ ] 7.2 Implement output redaction function ~30m
    - Capture stdout/stderr from subprocess
    - Replace all secret values with `[REDACTED]`
    - Support `--no-mask` flag for debugging
  - [ ] 7.3 Add gopass detection to `credential-helper.sh` ~30m
    - Check if gopass is installed and initialized
    - Prefer gopass for `set` operations when available
    - Fall back to credentials.sh when gopass not available
  - [ ] 7.4 Add `aidevops secret` subcommand to `aidevops.sh` CLI ~15m
  - [ ] 7.5 ShellCheck and test all new code ~15m

- [ ] 8.0 Update api-keys tool ~30m (ai:30m)
  - [ ] 8.1 Update `.opencode/tool/api-keys.ts` to detect gopass and prefer it ~15m
  - [ ] 8.2 Add `secret-*` actions that delegate to `secret-helper.sh` ~15m

- [ ] 9.0 Add gopass to setup.sh ~30m (ai:20m test:10m)
  - [ ] 9.1 Add `setup_gopass()` function -- detect, offer install, run setup ~20m
  - [ ] 9.2 Add to `setup_credentials()` flow -- gopass init after credentials.sh migration ~10m

### Part C: Agent Instructions & Documentation

- [ ] 10.0 Update agent instructions ~1h (ai:45m read:15m)
  - [ ] 10.1 Add mandatory rule to `.agents/AGENTS.md`: never accept secrets in context ~15m
  - [ ] 10.2 Update `AGENTS.md` Quick Reference credentials path ~5m
  - [ ] 10.3 Update `build-agent.md` security section ~10m
  - [ ] 10.4 Update `aidevops/security.md` with gopass guidance ~15m
  - [ ] 10.5 Update `onboarding.md` with gopass setup step ~15m

- [ ] 11.0 Document psst as alternative ~30m (ai:25m read:5m)
  - [ ] 11.1 Create `.agents/tools/credentials/psst.md` subagent ~20m
    - Installation, setup, usage
    - Trade-offs vs gopass (simpler UX, less mature, no team features, Bun dep)
    - When to prefer psst (solo developer, quick setup, no GPG)
  - [ ] 11.2 Add psst to `subagent-index.toon` ~5m
  - [ ] 11.3 Cross-reference from `gopass.md` and `api-key-setup.md` ~5m

- [ ] 12.0 Testing & Quality ~1h (ai:30m test:30m)
  - [ ] 12.1 Test fresh install flow (no existing credentials) ~15m
  - [ ] 12.2 Test migration flow (existing mcp-env.sh with keys) ~15m
  - [ ] 12.3 Test `aidevops secret run` with output redaction ~10m
  - [ ] 12.4 Test symlink backward compatibility ~5m
  - [ ] 12.5 Run `linters-local.sh` on all changes ~10m
  - [ ] 12.6 Run ShellCheck on all modified scripts ~5m

- [ ] 13.0 Final review & PR ~30m (ai:15m test:15m)
  - [ ] 13.1 Self-review all changes ~10m
  - [ ] 13.2 Update CHANGELOG.md ~5m
  - [ ] 13.3 Commit with descriptive message ~5m
  - [ ] 13.4 Push branch and create PR ~10m

<!--TOON:tasks[14]{id,parent,desc,est,est_ai,est_test,status,actual,completed}:
1.0,,Rename variable and path in scripts,2h,2h,30m,pending,,
2.0,,Update setup.sh migration logic,1h,45m,15m,pending,,
3.0,,Update documentation references,1h,45m,,pending,,
4.0,,Update plugins and configs,15m,15m,,pending,,
5.0,,Verify rename completeness,30m,15m,15m,pending,,
6.0,,gopass setup and documentation,2h,1.5h,,pending,,
7.0,,Build aidevops secret wrapper,3h,2.5h,30m,pending,,
8.0,,Update api-keys tool,30m,30m,,pending,,
9.0,,Add gopass to setup.sh,30m,20m,10m,pending,,
10.0,,Update agent instructions,1h,45m,,pending,,
11.0,,Document psst as alternative,30m,25m,,pending,,
12.0,,Testing and quality,1h,30m,30m,pending,,
13.0,,Final review and PR,30m,15m,15m,pending,,
-->

## Time Tracking

| Task | Estimated | Actual | Variance |
|------|-----------|--------|----------|
| 1.0 Rename scripts | 2h | - | - |
| 2.0 setup.sh migration | 1h | - | - |
| 3.0 Update docs | 1h | - | - |
| 4.0 Plugins/configs | 15m | - | - |
| 5.0 Verify rename | 30m | - | - |
| 6.0 gopass docs | 2h | - | - |
| 7.0 secret wrapper | 3h | - | - |
| 8.0 api-keys tool | 30m | - | - |
| 9.0 setup.sh gopass | 30m | - | - |
| 10.0 Agent instructions | 1h | - | - |
| 11.0 psst alternative | 30m | - | - |
| 12.0 Testing | 1h | - | - |
| 13.0 Final review | 30m | - | - |
| **Total** | **~14h** | **-** | **-** |

<!--TOON:time_summary{total_est,total_actual,variance_pct}:
14h,,
-->

## Completion Checklist

Before marking this task list complete:

- [ ] All tasks checked off
- [ ] `rg 'mcp-env' .agents/ setup.sh configs/ templates/` returns 0 results
- [ ] `rg 'MCP_ENV' .agents/scripts/` returns 0 results
- [ ] Symlink `mcp-env.sh -> credentials.sh` works
- [ ] `aidevops secret set/list/run` functional with gopass
- [ ] Output redaction verified (secret values replaced with [REDACTED])
- [ ] ShellCheck zero violations on all modified scripts
- [ ] Linters passing
- [ ] Documentation updated
- [ ] CHANGELOG.md updated
- [ ] PR created and ready for review
- [ ] Time actuals recorded
