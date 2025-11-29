# OpenCode Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Primary Agent**: `aidevops` - Full framework access
- **Subagents**: hostinger, hetzner, wordpress, seo, code-quality, browser-automation, etc.
- **Setup**: `.agent/scripts/setup-opencode-agents.sh install`
- **Config**: `~/.config/opencode/opencode.json`
- **Agents**: `~/.config/opencode/agent/*.md`
- **MCPs disabled globally** - enabled per-agent to save context tokens

**Key Commands**:

```bash
# Install agents
.agent/scripts/setup-opencode-agents.sh install

# Check status
.agent/scripts/setup-opencode-agents.sh status

# In OpenCode:
# - Tab to switch primary agents
# - @agent-name to invoke subagents
```

<!-- AI-CONTEXT-END -->

## Overview

OpenCode is a CLI AI assistant that supports specialized agents and MCP (Model Context Protocol) servers. This integration configures OpenCode with aidevops-specific agents and MCPs.

## Installation

### Prerequisites

1. **OpenCode CLI** installed - https://opencode.ai
2. **aidevops framework** cloned to `~/git/aidevops/`
3. **MCP servers** installed (optional, per-service)

### Quick Setup

```bash
# Run the setup script
cd ~/git/aidevops
.agent/scripts/setup-opencode-agents.sh install
```

This creates:
- `~/.config/opencode/agent/` directory
- Agent markdown files for each service
- Updates `opencode.json` with agent configurations

## Agent Architecture

### Primary Agent: aidevops

The main agent with full framework access. Use `Tab` to switch to it.

**Capabilities**:
- All built-in tools (write, edit, bash, read, glob, grep, webfetch, task)
- Access to all helper scripts
- Full documentation access

### Subagents

Specialized agents invoked with `@agent-name`. MCPs are enabled only for relevant subagents.

| Agent | Description | MCPs Enabled |
|-------|-------------|--------------|
| `aidevops` | Full framework (primary) | context7 |
| `hostinger` | Hosting, WordPress, DNS | hostinger-api |
| `hetzner` | Cloud infrastructure | hetzner-* (4 accounts) |
| `wordpress` | Local dev, MainWP | localwp, context7 |
| `seo` | Search Console, Ahrefs | gsc, ahrefs |
| `code-quality` | Quality scanning + learning loop | context7 |
| `browser-automation` | Testing, scraping | chrome-devtools, context7 |
| `context7-mcp-setup` | Documentation | context7 |
| `git-platforms` | GitHub, GitLab, Gitea | gh_grep, context7 |
| `crawl4ai-usage` | Web crawling | context7 |
| `dns-providers` | DNS management | hostinger-api (DNS) |
| `agent-review` | Session analysis, improvements | (read/write only) |

## Configuration

### opencode.json Structure

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "hostinger-api": {
      "type": "local",
      "command": [...],
      "enabled": false
    }
  },
  "tools": {
    "hostinger-api_*": false
  },
  "agent": {
    "hostinger": {
      "description": "...",
      "mode": "subagent",
      "tools": {
        "hostinger-api_*": true
      }
    }
  }
}
```

**Key Design**:
- MCPs are defined but `enabled: false` (not started at launch)
- Tools are disabled globally with `"mcp_*": false`
- Each subagent enables its specific tools with `"mcp_*": true`

This saves context tokens by only loading MCP tools when the relevant subagent is invoked.

### Agent Markdown Format

Agents can be defined as markdown files in `~/.config/opencode/agent/`:

```markdown
---
description: Short description for the agent
mode: subagent
temperature: 0.1
tools:
  bash: true
  mcp-name_*: true
---

# Agent Name

Detailed instructions for the agent...
```

## Usage

### Switching Agents

- **Tab**: Cycle through primary agents
- **@agent-name**: Invoke a subagent

### Example Workflows

```bash
# Use main agent
opencode
> What services are available?

# Invoke Hostinger subagent
> @hostinger list all websites

# Invoke Hetzner subagent
> @hetzner list servers in brandlight account

# Invoke SEO subagent
> @seo get top queries for example.com last 30 days

# Invoke code quality
> @code-quality run ShellCheck on all scripts
```

## MCP Server Configuration

### Required Environment Variables

Store in `~/.config/aidevops/mcp-env.sh`:

```bash
# Hostinger
export HOSTINGER_API_TOKEN="your-token"

# Hetzner (per account)
export HCLOUD_TOKEN_AWARDSAPP="your-token"
export HCLOUD_TOKEN_BRANDLIGHT="your-token"
export HCLOUD_TOKEN_MARCUSQUINN="your-token"
export HCLOUD_TOKEN_STORAGEBOX="your-token"

# Google Search Console
# Requires service account JSON file at:
# ~/.config/aidevops/gsc-credentials.json
```

### Installing MCP Servers

```bash
# Hostinger MCP
npm install -g hostinger-api-mcp

# Hetzner MCP
brew install mcp-hetzner

# LocalWP MCP
brew install mcp-local-wp

# Chrome DevTools MCP (auto-installed via npx)
```

## Troubleshooting

### MCPs Not Loading

1. Check MCP is enabled in opencode.json
2. Verify environment variables are set
3. Test MCP command manually

### Agent Not Found

1. Check file exists in `~/.config/opencode/agent/`
2. Verify frontmatter YAML is valid
3. Restart OpenCode

### Tools Not Available

1. Check tools enabled in agent config
2. Verify glob patterns match MCP tool names
3. Check MCP server is responding

## File Locations

| File | Purpose |
|------|---------|
| `~/.config/opencode/opencode.json` | Main configuration |
| `~/.config/opencode/agent/*.md` | Agent definitions |
| `~/.config/aidevops/mcp-env.sh` | API credentials |
| `~/git/aidevops/.agent/scripts/setup-opencode-agents.sh` | Setup script |

## Continuous Improvement with @agent-review

**End every session by calling `@agent-review`** to analyze the conversation and improve agents:

```text
@agent-review analyze this session and suggest improvements to the agents used
```

The review agent will:
1. Identify which agents were used
2. Evaluate missing, incorrect, or excessive information
3. Suggest specific improvements to agent files
4. Generate ready-to-apply edits
5. **Optionally compose a PR** to contribute improvements back to aidevops

**Feedback Loop:**

```
Session → @agent-review → Improvements → Better Agents → Better Sessions
                ↓
         PR to aidevops repo (optional)
```

**Contributing back:**

```text
@agent-review create a PR for improvement #2
```

This creates a branch, applies changes, and submits a PR to `marcusquinn/aidevops`. The agent has restricted bash permissions - only `git *` and `gh pr *` commands are allowed (with confirmation).

## Code Quality Learning Loop

The `@code-quality` agent doesn't just fix issues - it learns from them:

```
Quality Issue → Fix Applied → Pattern Identified → Framework Updated → Issue Prevented
```

After fixing violations from SonarCloud, Codacy, ShellCheck, etc.:

1. **Categorize the issue** - Shell scripting, security, style, architecture
2. **Analyze root cause** - Why didn't the framework prevent this?
3. **Update framework** - Add guidance, examples, or checklist items
4. **Submit PR** - Contribute the prevention back to aidevops

Example: Finding 15 SC2162 violations (read without -r) leads to adding clear examples in AGENTS.md's shell best practices section.

## References

- [OpenCode Agents Documentation](https://opencode.ai/docs/agents)
- [OpenCode MCP Servers](https://opencode.ai/docs/mcp-servers/)
- [aidevops Framework](https://github.com/marcusquinn/aidevops)
