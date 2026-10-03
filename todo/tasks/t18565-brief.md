# t18565: chore: retire code-search leftovers, llm-tldr, context-builder/repomix and rapidfuzz

## Origin

- **Created:** 2026-09-30
- **Created by:** ai-interactive
- **Issue:** GH#33140
- **Conversation context:** Framework value audit (parent GH#33139); maintainer approved retiring redundant tooling while keeping the useful ideas.

## Why

Agent guidance still routes to Augment, which was removed in GH#22068 and GH#31203. The context-packing and indexing tools have no executable callers. Current harnesses do exact search and targeted reads directly, so these add setup and context cost with no benefit.

## What

Remove guidance and tooling for code indexing and context packing, which current models and harnesses no longer need. Parent: GH#33139.

- `.agents/build-plus.md:113` and `:124` still route agents to "Augment for semantic search" and "exact search → Augment (semantic)", but Augment was removed in GH#22068 and GH#31203. Replace both with exact search (`rg` or `git grep`, then targeted Read), then Context7 for library docs.
- `README.md:235` and `:379` advertise "semantic code search". Reword to exact search plus Context7, keeping the sentences' structure.
- llm-tldr has no executable caller: `.agents/tools/context/llm-tldr.md` and `configs/mcp-templates/llm-tldr.json`. Delete both and the link in `.agents/tools/context/pageindex.md:133`.
- context-builder is a repomix wrapper (`.agents/scripts/context-builder-helper.sh`, a header "inspired by RepoPrompt Code Maps"). Its jobs are now covered by the `ai-research` tool's `files` parameter, `/cross-review`, and `gh api .../git/trees` for remote repos. Delete the helper, both docs, the `/context` slash command generated in `.agents/scripts/generate-claude-commands.sh` and `.agents/scripts/claude-command-defs.bash` (and the OpenCode equivalent in `generate-opencode-commands-utility.sh` if present), the `tool-version-check.sh:125` entry, and `configs/context-builder-config.json.txt`.
- `repomix.config.json` at the repo root: delete it unless an executable consumer is found (`rg -n repomix` outside docs).
- `.agents/tools/context/rapidfuzz.md` has no caller. Delete it.

## How: reference pattern

Model the deployed-file cleanup on the osgrep retirement in `.agents/scripts/setup/modules/migrations.sh:160-170`, where deleted agent docs are listed for removal from `~/.aidevops/agents/`. Add the deleted doc and helper paths to that list so existing installs drop them.

### Files Scope

- `.agents/build-plus.md`
- `README.md`
- `.agents/tools/context/llm-tldr.md`
- `configs/mcp-templates/llm-tldr.json`
- `.agents/tools/context/pageindex.md`
- `.agents/tools/context/context-builder.md`
- `.agents/tools/context/context-builder-agent.md`
- `.agents/tools/context/rapidfuzz.md`
- `.agents/tools/context/mcp-discovery.md`
- `.agents/tools/context/context-guardrails.md`
- `.agents/tools/build-mcp/build-mcp.md`
- `.agents/tools/build-agent/build-agent.md`
- `.agents/workflows/wiki-update.md`
- `.agents/scripts/context-builder-helper.sh`
- `configs/context-builder-config.json.txt`
- `repomix.config.json`
- `.secretlintignore`
- `.agents/scripts/generate-claude-commands.sh`
- `.agents/scripts/claude-command-defs.bash`
- `.agents/scripts/generate-opencode-commands-utility.sh`
- `.agents/scripts/tool-version-check.sh`
- `.agents/scripts/tests/test-tool-version-check-opencode.sh`
- `.agents/scripts/pre-commit-hook.sh`
- `.agents/scripts/setup/modules/migrations.sh`
- `.agents/configs/simplification-state.json`
- `.agents/configs/repo-layout-policy.conf`
- `.agents/configs/allowed-urls.txt`
- `.agents/subagent-index.toon`
- `.opencode/server/mcp-dashboard.ts`
- `.opencode/server/mcp-test-config.json`
- `.opencode/MCP-TESTING-GUIDE.md`

## Acceptance criteria

- [ ] `rg -n -i 'augment|llm-tldr|context-builder|repomix|rapidfuzz' .agents README.md configs .opencode` returns only migration cleanup entries, the bot-skip rules for the augmentcode review bot, and the `mcp-audit-helper.sh` test fixture.
- [ ] `/context` is no longer generated for Claude Code or OpenCode.
- [ ] Existing installs lose the deleted deployed docs and helper on the next `setup.sh --non-interactive` run.
- [ ] `subagent-index.toon` is regenerated, not hand-edited.

## Verification

```bash
rg -n -i 'augment|llm-tldr|context-builder|repomix|rapidfuzz' .agents README.md configs .opencode
shellcheck .agents/scripts/generate-claude-commands.sh .agents/scripts/tool-version-check.sh .agents/scripts/setup/modules/migrations.sh
.agents/scripts/linters-local.sh
```

Parent: #33139
