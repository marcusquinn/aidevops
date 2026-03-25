---
description: OpenCode CLI integration and configuration
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
---

# OpenCode Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Primary Agent**: `aidevops` — full framework access
- **Subagents**: hostinger, hetzner, wordpress, seo, code-quality, browser-automation, etc.
- **Setup**: `./setup.sh` (from aidevops repo)
- **MCPs disabled globally** — enabled per-agent to save context tokens

**Critical Paths:**

| Purpose | Path |
|---------|------|
| Main config | `~/.config/opencode/opencode.json` |
| Agent files | `~/.config/opencode/agent/*.md` |
| Alternative config | `~/.opencode/` (some installations) |
| aidevops agents | `~/.aidevops/agents/` (after setup.sh) |
| Credentials | `~/.config/aidevops/credentials.sh` |

**Key Commands:**

```bash
# Install/update agents
.agents/scripts/generate-opencode-agents.sh

# Authenticate (built-in OAuth, v1.1.36+)
opencode auth login
# Select: Anthropic → Claude Pro/Max (or Create an API Key)

# In OpenCode:
# - Tab to switch primary agents
# - @agent-name to invoke subagents
```

<!-- AI-CONTEXT-END -->

## Anthropic OAuth (Built-in)

OpenCode v1.1.36+ includes Anthropic OAuth natively. No external plugin needed.

```bash
opencode auth login
# Select: Anthropic → Claude Pro/Max (or Create an API Key)
# Complete OAuth flow in browser, paste authorization code when prompted
```

| Method | Use Case | Cost |
|--------|----------|------|
| **Claude Pro/Max** | Active subscription holders | $0 (subscription covers usage) |
| **Create API Key** | OAuth-based key creation | Standard API rates |
| **Manual API Key** | Existing API keys | Standard API rates |

OAuth benefits: automatic token refresh, beta features auto-enabled, zero cost for Pro/Max subscribers, no manual key management.

> **Note:** The external `opencode-anthropic-auth` plugin is no longer needed. Remove it from `opencode.json` plugins if present — adding it alongside the built-in version causes a TypeError due to double-loading.

## Installation

### Prerequisites

1. **OpenCode CLI** installed — https://opencode.ai
2. **aidevops framework** cloned to `~/Git/aidevops/`
3. **MCP servers** installed (optional, per-service)

### Quick Setup

```bash
cd ~/Git/aidevops
.agents/scripts/generate-opencode-agents.sh
```

This creates `~/.config/opencode/agent/` with agent markdown files and updates `opencode.json` with agent configurations.

## Agent Architecture

### Primary Agent: aidevops

The main agent with full framework access. Use `Tab` to switch to it. Has all built-in tools (write, edit, bash, read, glob, grep, webfetch, task) plus access to all helper scripts and documentation.

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
| `git-platforms` | GitHub, GitLab, Gitea | context7 |
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
      "command": ["..."],
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

**Design pattern:** MCPs are defined but `enabled: false` globally. Tools are disabled with `"mcp_*": false`. Each subagent enables its specific tools with `"mcp_*": true` — this saves context tokens by only loading MCP tools when the relevant subagent is invoked.

### Agent Markdown Format

Agents are defined as markdown files in `~/.config/opencode/agent/`:

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
- **@agent-name**: Invoke a subagent (one `@mention` per message)

### Recommended Workflow Order

| Phase | Agents | Execution |
|-------|--------|-----------|
| 1. Plan/Research | @context7-mcp-setup, @seo, @browser-automation | Parallel (no dependencies) |
| 2. Infrastructure | @dns-providers → @hetzner → @hostinger | Sequential (output chains) |
| 3. Development | @wordpress, @git-platforms, @crawl4ai-usage | Parallel |
| 4. Quality | @code-standards → @agent-review | Sequential (always last) |

```bash
# Parallel research (send in quick succession)
> @seo analyze competitors for example.com
> @context7-mcp-setup get Next.js caching docs
> @browser-automation screenshot example.com homepage

# Sequential infrastructure (wait for each to complete)
> @dns-providers create A record for app.example.com → 1.2.3.4
# Wait for DNS propagation...
> @hetzner create server app-server in brandlight
# Wait for server...
> @hostinger deploy WordPress to app.example.com
```

### End-of-Session Pattern (MANDATORY)

Always end sessions with these agents in order:

1. **@code-standards** — fix any quality issues introduced
2. **@agent-review** — analyze session, suggest improvements, optionally create PR

The review agent identifies which agents were used, evaluates missing/incorrect/excessive information, generates ready-to-apply edits, and can compose a PR to contribute improvements back to aidevops.

```text
Session → @agent-review → Improvements → Better Agents → Better Sessions
                ↓
         PR to aidevops repo (optional)
```

```bash
> @agent-review create a PR for improvement #2
```

The agent has restricted bash permissions — only `git *` and `gh pr *` commands are allowed (with confirmation).

### Example Workflows

```bash
# Use main agent
opencode
> What services are available?

# Invoke subagents
> @hostinger list all websites
> @hetzner list servers in brandlight account
> @seo get top queries for example.com last 30 days
> @code-standards run ShellCheck on all scripts
```

## CLI Testing Mode

The OpenCode TUI requires a restart for config changes (new MCPs, agents, slash commands). Use the CLI for quick testing without restarting.

### Basic CLI Testing

```bash
# Test with specific agent (fresh config load)
opencode run "List your available tools" --agent SEO

# Test new MCP functionality
opencode run "Use dataforseo to get SERP for 'test query'" --agent SEO

# Test with different model
opencode run "Quick test" --agent Build+ --model anthropic/claude-sonnet-4-6

# Capture errors for debugging
opencode run "Test the serper MCP" --agent SEO 2>&1
```

### Persistent Server Mode (Faster Iteration)

For iterative testing, use serve mode to avoid MCP cold boot on each run:

```bash
# Terminal 1: Start headless server (keeps MCPs warm)
opencode serve --port 4096

# Terminal 2: Run tests against it (fast, reuses MCP connections)
opencode run --attach http://localhost:4096 "Test query" --agent SEO
opencode run --attach http://localhost:4096 "Another test" --agent SEO

# After config changes: Ctrl+C in Terminal 1, restart server
```

### Testing Scenarios

| Scenario | Command |
|----------|---------|
| New MCP added | `opencode run "List tools from [mcp]_*" --agent [agent]` |
| MCP auth issues | `opencode run "Call [mcp]_[tool]" --agent [agent] 2>&1` |
| Agent permissions | `opencode run "Try to write a file" --agent Build+` |
| Slash command | `opencode run "/new-command arg1 arg2" --agent Build+` |
| Quick task | `opencode run "Do X quickly" --agent Build+` |

### Helper Script

```bash
# Test if MCP is accessible
~/.aidevops/agents/scripts/opencode-test-helper.sh test-mcp dataforseo SEO

# Test agent permissions
~/.aidevops/agents/scripts/opencode-test-helper.sh test-agent Build+

# List tools available to agent
~/.aidevops/agents/scripts/opencode-test-helper.sh list-tools Build+

# Start persistent server
~/.aidevops/agents/scripts/opencode-test-helper.sh serve 4096
```

### Workflow: Adding New MCP

1. Edit `~/.config/opencode/opencode.json` — add MCP config
2. Test with CLI: `opencode run "Test [mcp]" --agent [agent] 2>&1`
3. If errors, check stderr output and fix config
4. If working, restart TUI to use interactively
5. Update `generate-opencode-agents.sh` to persist changes

## MCP Server Configuration

### Required Environment Variables

Store in `~/.config/aidevops/credentials.sh`:

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

### OpenCode MCP Environment Variable Limitation

OpenCode's MCP `environment` blocks do NOT expand shell variables like `${VAR}` — they are treated as literal strings. Use the bash wrapper pattern to expand variables at runtime:

```json
{
  "mcp": {
    "ahrefs": {
      "type": "local",
      "command": [
        "/bin/bash",
        "-c",
        "API_KEY=$AHREFS_API_KEY /opt/homebrew/bin/npx -y @ahrefs/mcp@latest"
      ],
      "enabled": true
    },
    "hetzner": {
      "type": "local",
      "command": [
        "/bin/bash",
        "-c",
        "HCLOUD_TOKEN=$HCLOUD_TOKEN_BRANDLIGHT /opt/homebrew/bin/hcloud-mcp-server"
      ],
      "enabled": true
    }
  }
}
```

## Troubleshooting

| Problem | Steps |
|---------|-------|
| **MCPs not loading** | 1. Check MCP `enabled` in opencode.json 2. Verify env vars set 3. Test MCP command manually |
| **Agent not found** | 1. Check file exists in `~/.config/opencode/agent/` 2. Verify frontmatter YAML valid 3. Restart OpenCode |
| **Tools not available** | 1. Check tools enabled in agent config 2. Verify glob patterns match MCP tool names 3. Check MCP server responding |

### File Locations

| Path | Purpose |
|------|---------|
| `~/.config/opencode/opencode.json` | Main config (MCP servers, agents, tools) |
| `~/.config/opencode/agent/*.md` | Agent markdown files |
| `~/.opencode/` | Alternative config location (some installations) |
| `~/.opencode/agent/` | Alternative agent location |
| `~/.aidevops/agents/` | Deployed aidevops agents (created by setup.sh) |
| `~/.config/aidevops/credentials.sh` | API credentials (600 permissions) |
| `~/Git/aidevops/.agents/` | Source agents (development repo) |
| `~/Git/aidevops/setup.sh` | Deployment script (copies to ~/.aidevops/) |

```bash
# Verify paths
ls -la ~/.config/opencode/ ~/.opencode/ 2>/dev/null
ls -la ~/.aidevops/agents/ 2>/dev/null
grep -l "aidevops" ~/.config/opencode/agent/*.md 2>/dev/null
```

## Permission Model Limitations

### Subagent Permission Inheritance

**OpenCode subagents do NOT inherit parent agent permission restrictions.** When a parent agent uses the `task` tool to spawn a subagent, the subagent runs with its OWN tool permissions — parent's `write: false` or `bash: deny` are NOT enforced.

| Configuration | Actually Read-Only? |
|---------------|---------------------|
| `write: false, edit: false, task: true` | **NO** — subagents can write |
| `write: false, edit: false, bash: true` | **NO** — bash can write files |
| `write: false, edit: false, bash: false, task: false` | **YES** — truly read-only |

**For true read-only behavior**: set both `bash: false` AND `task: false`.

### @plan-plus Read-Only Configuration

```json
"@plan-plus": {
  "permission": {
    "edit": "deny",
    "write": "deny",
    "bash": "deny"
  },
  "tools": {
    "write": false,
    "edit": false,
    "bash": false,
    "task": false,
    "read": true,
    "glob": true,
    "grep": true,
    "webfetch": true
  }
}
```

Use Build+ (Tab) for any operations requiring file changes.

## Code Quality Learning Loop

The `@code-standards` agent learns from issues it fixes:

```text
Quality Issue → Fix Applied → Pattern Identified → Framework Updated → Issue Prevented
```

After fixing violations (SonarCloud, Codacy, ShellCheck, etc.): categorize the issue, analyze root cause, update framework guidance, and submit a PR to contribute the prevention back to aidevops.

## Spawning Parallel Sessions

```bash
# Non-interactive execution
opencode run "Task description" --agent Build+ --title "Task Name"

# Background execution
opencode run "Long running task" --agent Build+ &

# Persistent server (reuses MCP connections)
opencode serve --port 4097
opencode run --attach http://localhost:4097 "Task" --agent Build+

# With worktree (recommended for parallel branches)
~/.aidevops/agents/scripts/worktree-helper.sh add feature/parallel-task
```

See `workflows/session-manager.md` for full session lifecycle guidance including terminal tab spawning, session handoff patterns, worktree integration, and loop completion detection.

## References

- [OpenCode Agents Documentation](https://opencode.ai/docs/agents)
- [OpenCode MCP Servers](https://opencode.ai/docs/mcp-servers/)
- [aidevops Framework](https://github.com/marcusquinn/aidevops)
