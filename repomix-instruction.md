# AI DevOps Framework - Context Instructions

This codebase is the **aidevops framework** - a collection of AI agent instructions
and helper scripts for DevOps automation across 30+ services.

## Key Understanding

### Directory Structure

- **`.agents/`** - Canonical source for all agent definitions (other dirs are symlinks)
- **`.agents/scripts/`** - Helper shell scripts for service automation
- **`configs/`** - MCP configuration templates (`.json.txt` files are safe to read)
- **`AGENTS.md`** - Developer guide for contributing
- **`.agents/AGENTS.md`** - User guide distributed to `~/.aidevops/agents/`

### Symlink Architecture

These directories are **symlinks to `.agents/`** - don't analyze them separately:
- `.ai/`, `.continue/`, `.cursor/`, `.claude/`, `.factory/`, `.codex/`, `.kiro/`, `.opencode/`

Focus on `.agents/` for the authoritative content.

### Code Quality Standards

- **ShellCheck compliant**: All scripts pass ShellCheck with zero violations
- **Variable pattern**: `local var="$1"` for function parameters
- **Explicit returns**: All functions end with `return 0` or appropriate code
- **SonarCloud A-grade**: Maintained quality gate status

### Agent Design Principles

1. **Token efficiency**: Agents use progressive disclosure (pointers to subagents)
2. **AI-CONTEXT sections**: Quick reference blocks at top of each file
3. **No duplication**: Check existing content before adding instructions
4. **Security-first**: Credentials stored in `~/.config/aidevops/credentials.sh`

## When Analyzing This Codebase

- **For architecture understanding**: Focus on `.agents/AGENTS.md` and `.agents/aidevops/architecture.md`
- **For script patterns**: Reference `.agents/scripts/` - all follow consistent conventions
- **For service integrations**: Check `.agents/services/` and `configs/`
- **For workflows**: See `.agents/workflows/` for release, versioning, bug-fixing guides

## Common Tasks

| Task | Key Files |
|------|-----------|
| Add new service | `.agents/aidevops/add-new-mcp-to-aidevops.md` |
| Create agent | `.agents/build-agent.md` |
| Review agents | `.agents/build-agent/agent-review.md` |
| Release version | `.agents/workflows/release-process.md` |
