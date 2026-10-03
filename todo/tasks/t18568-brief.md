# t18568: chore: retire Ralph loop commands, workflow and state readers

## Origin

- **Created:** 2026-09-30
- **Created by:** ai-interactive
- **Issue:** GH#33142
- **Conversation context:** Framework value audit (parent GH#33139); maintainer approved retiring redundant tooling while keeping the useful ideas.

## Why

The OpenCode continuation guard and `/full-loop` supersede the Ralph loop. Its leftover commands, workflow and state readers still appear in agent context and can send agents down a retired path.

## What

Remove the Ralph loop. Parent: GH#33139.

It was an early workaround for models that stopped too soon. Current models are built for long runs, and OpenCode already has a lighter guard, `.agents/plugins/opencode-aidevops/session-continuation-guard.mjs`, which catches completion claims made while todos are still open. A sibling child adds the same guard for Claude Code.

The Ralph helper was already archived; `migrations.sh:183` deletes it. Deploys still generate four commands, `/ralph-loop`, `/ralph-task`, `/cancel-ralph` and `/ralph-status`:

- `.agents/scripts/generate-opencode-commands-automation.sh:29-153` (called at `:321`)
- `.agents/scripts/generate-claude-commands.sh:679-771`

State readers also watch files nothing writes any more: `session-review-helper.sh:980`, `worktree-sessions.sh:104`, and `.agents/loop-state/ralph-loop.local.*` handling in `loop-common.sh` and `full-loop-helper-state-lifecycle.sh`.

## How

- Stop generating the four commands in both generators and in `claude-command-defs.bash`.
- Add the generated command files to the stale-command cleanup, so existing installs lose `/ralph-*` on the next setup run.
- Delete `.agents/workflows/ralph-loop.md`.
- Remove the Ralph state readers. Keep any generic loop-state code that `/full-loop` still uses; check with `rg -n loop-state`.
- Remove the `#ralph` / `ralph-promise` task-metadata guidance from the planning templates and docs.
- Remove the mentions in `full-loop.md`, `session-review.md`, `session-manager.md`, `plans.md`, `architecture.md`, `cron-agent.md`, `openprose.md` and `ai-orchestration/overview.md`.

## Reference pattern

Follow how retired commands are cleaned up elsewhere in `.agents/scripts/setup/modules/migrations.sh`: search it for `commands/` removal entries and reuse that mechanism.

### Files Scope

- `.agents/workflows/ralph-loop.md`
- `.agents/workflows/full-loop.md`
- `.agents/workflows/session-review.md`
- `.agents/workflows/session-manager.md`
- `.agents/workflows/plans.md`
- `.agents/templates/plans-template.md`
- `.agents/aidevops/architecture.md`
- `.agents/tools/automation/cron-agent.md`
- `.agents/tools/ai-orchestration/openprose.md`
- `.agents/tools/ai-orchestration/overview.md`
- `.agents/subagent-index.toon`
- `.agents/configs/simplification-state.json`
- `.agents/scripts/generate-claude-commands.sh`
- `.agents/scripts/claude-command-defs.bash`
- `.agents/scripts/generate-opencode-commands-automation.sh`
- `.agents/scripts/generate-opencode-commands.sh`
- `.agents/scripts/generate-opencode-agents.sh`
- `.agents/scripts/generate-runtime-config-agents.sh`
- `.agents/scripts/session-review-helper.sh`
- `.agents/scripts/worktree-sessions.sh`
- `.agents/scripts/loop-common.sh`
- `.agents/scripts/full-loop-helper-state-lifecycle.sh`
- `.agents/scripts/setup/modules/migrations.sh`

## Acceptance criteria

- [ ] No `/ralph-*` commands are generated for OpenCode or Claude Code, and existing generated ones are removed on setup.
- [ ] `rg -n -i ralph .agents` returns only migration cleanup entries.
- [ ] `/full-loop` still works; its loop-state handling is unaffected.
- [ ] ShellCheck is clean for all touched scripts.

## Verification

```bash
rg -n -i ralph .agents --glob '!CHANGELOG.md'
shellcheck .agents/scripts/generate-claude-commands.sh .agents/scripts/generate-opencode-commands-automation.sh .agents/scripts/loop-common.sh .agents/scripts/session-review-helper.sh .agents/scripts/worktree-sessions.sh
.agents/scripts/linters-local.sh
```

Parent: #33139
