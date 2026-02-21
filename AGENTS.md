# AI DevOps Framework - Developer Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **User Guide**: `.agents/AGENTS.md` (deployed to `~/.aidevops/agents/`)
- **Commands**: `./setup.sh` (deploy) | `.agents/scripts/linters-local.sh` (quality) | `version-manager.sh release [major|minor|patch]`
- **Config**: `~/.config/opencode/opencode.json`, `~/.claude/settings.json`
- **Quality**: `prompts/build.txt`

**File Structure**: `TODO.md` (tasks), `todo/` (plans, PRDs), `.agents/` (agents, tools, services, workflows, scripts).

**Before extending**: Read `.agents/aidevops/architecture.md` (design patterns, conventions, extension guide).

<!-- AI-CONTEXT-END -->

## Two AGENTS.md Files

| File | Purpose | Audience |
|------|---------|----------|
| `~/Git/aidevops/AGENTS.md` | Development guide | Contributors |
| `~/Git/aidevops/.agents/AGENTS.md` | User guide | Users of aidevops |

The `.agents/AGENTS.md` is copied to `~/.aidevops/agents/AGENTS.md` by `setup.sh`.

## Development Lifecycle

See `.agents/AGENTS.md` "Development Lifecycle" for the full lifecycle.
Completion self-check: see `prompts/build.txt` "Completion and quality discipline".

## Contributing

See `.agents/aidevops/` for framework development guidance:

| File | Purpose |
|------|---------|
| `tools/build-agent/build-agent.md` | Composing efficient agents |
| `tools/build-agent/agent-review.md` | Reviewing and improving agents |
| `tools/build-mcp/build-mcp.md` | MCP server development |
| `tools/mcp-toolkit/mcporter.md` | MCP runtime toolkit (discover, call, generate CLIs) |
| `architecture.md` | Framework structure |
| `setup.md` | AI guide to setup.sh |

## Agent Design Principles

From `tools/build-agent/build-agent.md`:

1. **Instruction budget**: ~50-100 max in root AGENTS.md
2. **Universal applicability**: Every instruction relevant to >80% of tasks
3. **Progressive disclosure**: Pointers to subagents, not inline content
4. **Code examples**: Only when authoritative (use `file:line` refs otherwise)
5. **Self-assessment**: Flag issues with evidence, complete task first

## Security

Security rules: see `prompts/build.txt`. Additional contributor rule:
- Use placeholders in examples, note secure storage location

## Quality Workflow

```bash
# Before committing
.agents/scripts/linters-local.sh

# ShellCheck all scripts
find .agents/scripts/ -name "*.sh" -exec shellcheck {} \;

# Release new version
.agents/scripts/version-manager.sh release [major|minor|patch]
```text

## Self-Assessment Protocol

From `tools/build-agent/build-agent.md`:

- **Triggers**: Observable failure, user correction, contradiction, staleness
- **Process**: Complete task, cite evidence, check duplicates, propose fix
- **Duplicates**: Always `rg "pattern" .agents/` before adding instructions
