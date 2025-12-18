# AI DevOps Framework - Developer Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Contributing to aidevops framework development
- **User Guide**: `.agent/AGENTS.md` (deployed to `~/.aidevops/agents/`)
- **Repo**: `~/Git/aidevops/`

**OpenCode Paths** (commonly needed):
- Config: `~/.config/opencode/opencode.json`
- Agents: `~/.config/opencode/agent/`
- Alternative: `~/.opencode/`

**Development Commands**:

```bash
# Deploy agents locally
./setup.sh

# Quality check
.agent/scripts/linters-local.sh

# Release
.agent/scripts/version-manager.sh release [major|minor|patch]
```text

**Quality Standards**: SonarCloud A-grade, ShellCheck zero violations,
`local var="$1"` pattern, explicit returns

**File Structure**:

```text
.agent/
├── AGENTS.md              # User guide (distributed)
├── {domain}.md            # Main agents (aidevops, wordpress, seo, etc.)
├── {domain}/              # Subagents for each domain
├── tools/                 # Cross-domain utilities
├── services/              # External integrations  
├── workflows/             # Process guides
└── scripts/               # Helper scripts
```text

<!-- AI-CONTEXT-END -->

## Two AGENTS.md Files

This repository has two AGENTS.md files with different purposes:

| File | Purpose | Audience |
|------|---------|----------|
| `~/Git/aidevops/AGENTS.md` | Development guide | Contributors |
| `~/Git/aidevops/.agent/AGENTS.md` | User guide | Users of aidevops |

The `.agent/AGENTS.md` is copied to `~/.aidevops/agents/AGENTS.md` by `setup.sh`.

## Contributing

See `.agent/aidevops/` for framework development guidance:

| File | Purpose |
|------|---------|
| `build-agent.md` | Composing efficient agents (main agent) |
| `build-agent/agent-review.md` | Reviewing and improving agents |
| `architecture.md` | Framework structure |
| `setup.md` | AI guide to setup.sh |

## Agent Design Principles

From `build-agent.md`:

1. **Instruction budget**: ~50-100 max in root AGENTS.md
2. **Universal applicability**: Every instruction relevant to >80% of tasks
3. **Progressive disclosure**: Pointers to subagents, not inline content
4. **Code examples**: Only when authoritative (use `file:line` refs otherwise)
5. **Self-assessment**: Flag issues with evidence, complete task first

## Security

- Never commit credentials
- Store secrets in `~/.config/aidevops/mcp-env.sh` (600 permissions)
- Confirm destructive operations before execution
- Use placeholders in examples, note secure storage location

## Quality Workflow

```bash
# Before committing
.agent/scripts/linters-local.sh

# ShellCheck all scripts
find .agent/scripts/ -name "*.sh" -exec shellcheck {} \;

# Release new version
.agent/scripts/version-manager.sh release [major|minor|patch]
```text

## Self-Assessment Protocol

When developing agents, apply self-assessment from `build-agent.md`:

- **Triggers**: Observable failure, user correction, contradiction, staleness
- **Process**: Complete task, cite evidence, check duplicates, propose fix
- **Duplicates**: Always `rg "pattern" .agent/` before adding instructions
