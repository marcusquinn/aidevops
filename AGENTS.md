# AI DevOps Framework - Developer Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Contributing to aidevops framework development
- **User Guide**: `.agents/AGENTS.md` (deployed to `~/.aidevops/agents/`)
- **Repo**: `~/Git/aidevops/`

**OpenCode Paths** (aidevops recommends OpenCode as primary tool):
- Config: `~/.config/opencode/opencode.json`
- Agents: `~/.config/opencode/agent/`
- Alternative: `~/.opencode/`

**Claude Code Paths** (also supported):
- Config: `~/.claude/`
- Settings: `~/.claude/settings.json`

**Development Commands**:

```bash
# Deploy agents locally
./setup.sh

# Quality check
.agents/scripts/linters-local.sh

# Release
.agents/scripts/version-manager.sh release [major|minor|patch]
```text

**Quality Standards**: SonarCloud A-grade, ShellCheck zero violations,
`local var="$1"` pattern, explicit returns

**File Structure**:

```text
/
├── TODO.md                # Quick tasks, backlog (root level)
├── todo/
│   ├── PLANS.md           # Complex execution plans
│   └── tasks/             # PRD and task files
│       ├── prd-*.md       # Product requirement documents
│       └── tasks-*.md     # Implementation task lists
└── .agents/
    ├── AGENTS.md          # User guide (distributed)
    ├── {domain}.md        # Main agents (aidevops, wordpress, seo, etc.)
    ├── {domain}/          # Subagents for each domain
    ├── tools/             # Cross-domain utilities
    ├── services/          # External integrations  
    ├── workflows/         # Process guides (incl. plans.md, plans-quick.md)
    ├── templates/         # PRD and task templates
    └── scripts/           # Helper scripts
```

**Before extending aidevops**: Read `.agents/aidevops/architecture.md` for:
- Agent design patterns (progressive disclosure, context offloading, Ralph loop)
- Extension guide (adding services, tools, documentation standards)
- Framework conventions (naming, code standards, security requirements)

<!-- AI-CONTEXT-END -->

## Two AGENTS.md Files

This repository has two AGENTS.md files with different purposes:

| File | Purpose | Audience |
|------|---------|----------|
| `~/Git/aidevops/AGENTS.md` | Development guide | Contributors |
| `~/Git/aidevops/.agents/AGENTS.md` | User guide | Users of aidevops |

The `.agents/AGENTS.md` is copied to `~/.aidevops/agents/AGENTS.md` by `setup.sh`.

## Contributing

See `.agents/aidevops/` for framework development guidance:

| File | Purpose |
|------|---------|
| `tools/build-agent/build-agent.md` | Composing efficient agents |
| `tools/build-agent/agent-review.md` | Reviewing and improving agents |
| `tools/build-mcp/build-mcp.md` | MCP server development |
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

- Never commit credentials
- Store secrets via `aidevops secret set NAME` (gopass encrypted) or `~/.config/aidevops/credentials.sh` (plaintext fallback, 600 permissions)
- NEVER accept secret values in AI conversation context
- Confirm destructive operations before execution
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

When developing agents, apply self-assessment from `tools/build-agent/build-agent.md`:

- **Triggers**: Observable failure, user correction, contradiction, staleness
- **Process**: Complete task, cite evidence, check duplicates, propose fix
- **Duplicates**: Always `rg "pattern" .agents/` before adding instructions
