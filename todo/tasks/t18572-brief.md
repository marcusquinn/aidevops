# t18572: chore: retire Beads integration and todo-ready.sh after the issue archive lands

## Origin

- **Created:** 2026-09-30
- **Created by:** ai-interactive
- **Issue:** GH#33148
- **Conversation context:** Framework value audit (parent GH#33139); maintainer approved retiring redundant tooling while keeping the useful ideas.

blocked-by: GH#33146

## Why

Beads provides no durable backup: `.beads` is gitignored and it only mirrors TODO.md, which is already in Git. It installs extra tools. The issue archive (GH#33146) takes over its resilience goal.

## What

Retire Beads once the issue/PR archive (GH#33146) provides real platform-loss resilience. Parent: GH#33139.

Beads does not meet its goal:

- `aidevops init` gitignores `.beads` (`.agents/scripts/aidevops-cli/aidevops-init-lib.sh:1550` and `:1595`).
- `beads-sync-helper.sh` only mirrors TODO.md, which is already in Git.
- `forge-portability.md:40` already states that ignored Beads SQLite/JSONL "is not a durable backup".

Setup still installs `bd` plus the optional `bv`, `beads-ui` and `bdui` (`.agents/scripts/setup/modules/tool-beads.sh`). `todo-ready.sh` duplicates the Beads "ready" view, has no executable caller, and writes to host `/tmp` at `:249-251`.

## How

- Stop installing Beads and its UI tools. Remove `tool-beads.sh`, its calls from the `setup/` modules, and the status and version-check entries.
- Remove the `beads` feature from `aidevops init`:
  - Keep accepting the feature name for existing `.aidevops.json` files, with a one-line deprecation notice.
  - Keep the existing `.beads` gitignore line; do not delete users' `.beads` directories.
  - Point to the issue archive.
- Delete `beads-sync-helper.sh`, `tools/task-management/beads.md`, `todo-ready.sh` and the `/sync-beads` hint.
- Keep `install-canonical-guard.sh`'s preservation of an existing "BEADS INTEGRATION" hook section unchanged. Users may still run Beads themselves, and removing that section would be destructive.
- Add a migration that removes the deployed helper and doc, and prints a one-line advisory with uninstall commands for `bd`, `bv`, `beads-ui` and `bdui` if present. Do not uninstall them automatically.
- Update the doc mentions: `purpose.md:37`, `domain-index.md`, `forge-portability.md`, `planning-detail.md`, `plans.md`, `branch.md`, `pr.md`, `show-plan.md`, `worker-efficiency-protocol.md`, the templates, and `.opencode/lib/ai-research.ts`.

## Reference pattern

Model the migration and advisory on `cleanup_osgrep()` in `.agents/scripts/setup/modules/migrations.sh:272-360`, but advise instead of force-removing user binaries.

### Files Scope

- `setup.sh`
- `aidevops.sh`
- `.agents/tools/task-management/beads.md`
- `.agents/scripts/beads-sync-helper.sh`
- `.agents/scripts/todo-ready.sh`
- `.agents/scripts/setup/modules/tool-beads.sh`
- `.agents/scripts/setup/_installation.sh`
- `.agents/scripts/setup/_services.sh`
- `.agents/scripts/setup/_common.sh`
- `.agents/scripts/setup/modules/core.sh`
- `.agents/scripts/setup/modules/post-setup.sh`
- `.agents/scripts/setup/modules/agent-deploy.sh`
- `.agents/scripts/setup/modules/migrations.sh`
- `.agents/scripts/aidevops-cli/aidevops-init-lib.sh`
- `.agents/scripts/aidevops-cli/aidevops-status-lib.sh`
- `.agents/scripts/tool-version-check.sh`
- `.agents/scripts/project-config-restore-helper.sh`
- `.agents/scripts/post-merge-review-scanner.sh`
- `.agents/scripts/tests/test-tool-version-check-opencode.sh`
- `.agents/scripts/tests/test-aidevops-init-help-gitignore.sh`
- `.agents/scripts/tests/test-init-repo-verify.sh`
- `.agents/scripts/tests/test-scoped-ripgrep-searches.sh`
- `tests/test-smoke-help.sh`
- `.agents/aidevops/purpose.md`
- `.agents/reference/domain-index.md`
- `.agents/reference/forge-portability.md`
- `.agents/reference/planning-detail.md`
- `.agents/reference/task-identity-parser-inventory.md`
- `.agents/workflows/plans.md`
- `.agents/workflows/branch.md`
- `.agents/workflows/pr.md`
- `.agents/workflows/show-plan.md`
- `.agents/prompts/worker-efficiency-protocol.md`
- `.agents/templates/todo-template.md`
- `.agents/templates/plans-template.md`
- `.agents/templates/mission-template.md`
- `.agents/content/optimization.md`
- `.opencode/lib/ai-research.ts`
- `.agents/configs/simplification-state.json`
- `.agents/subagent-index.toon`

## Acceptance criteria

- [ ] A fresh setup installs no Beads tooling, and `aidevops init beads` prints the deprecation notice and exits cleanly.
- [ ] Existing `.beads` directories and hook sections are left untouched.
- [ ] `rg -n -i 'beads|todo-ready' .agents setup.sh aidevops.sh` returns only the migration, deprecation-notice and hook-preservation code.
- [ ] ShellCheck is clean, and the init, smoke-help and version-check tests pass.

## Verification

```bash
rg -n -i 'beads|todo-ready' .agents setup.sh aidevops.sh --glob '!CHANGELOG.md'
bash .agents/scripts/tests/test-aidevops-init-help-gitignore.sh
bash tests/test-smoke-help.sh
.agents/scripts/linters-local.sh
```

Parent: #33139
