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

- **Primary Agent**: `aidevops` - Full framework access
- **Subagents**: hostinger, hetzner, wordpress, seo, code-quality, browser-automation, etc.
- **Setup**: `./setup.sh` (from aidevops repo)
- **MCPs disabled globally** - enabled per-agent to save context tokens

**Critical Paths** (AI assistants often need these):

| Purpose | Path |
|---------|------|
| Main config | `~/.config/opencode/opencode.json` |
| Agent files | `~/.config/opencode/agent/*.md` |
| Alternative config | `~/.opencode/` (some installations) |
| aidevops agents | `~/.aidevops/agents/` (after setup.sh) |
| Credentials | `~/.config/aidevops/mcp-env.sh` |

**Key Commands**:

```bash
# Install agents
.agent/scripts/generate-opencode-agents.sh

# Check status
.agent/scripts/generate-opencode-agents.sh

# In OpenCode:
# - Tab to switch primary agents
# - @agent-name to invoke subagents
```text

<!-- AI-CONTEXT-END -->

## Overview

OpenCode is a CLI AI assistant that supports specialized agents and MCP (Model Context Protocol) servers. This integration configures OpenCode with aidevops-specific agents and MCPs.

## Antigravity OAuth Plugin

The aidevops setup automatically installs the [opencode-antigravity-auth](https://github.com/NoeFabris/opencode-antigravity-auth) plugin, enabling Google OAuth authentication for premium model access.

**Authenticate after setup:**

```bash
opencode auth login
# Select: Google → OAuth with Google (Antigravity)
# Press Enter to skip Project ID prompt
```text

**Available models via Antigravity:**

- `gemini-3-pro-high` / `gemini-3-pro-low` / `gemini-3-flash`
- `claude-sonnet-4-5` / `claude-sonnet-4-5-thinking` / `claude-opus-4-5-thinking`
- `gpt-oss-120b-medium`

**Multi-account load balancing:** Add multiple Google accounts for automatic rate limit distribution. Run `opencode auth login` again to add more accounts.

## Installation

### Prerequisites

1. **OpenCode CLI** installed - https://opencode.ai
2. **aidevops framework** cloned to `~/Git/aidevops/`
3. **MCP servers** installed (optional, per-service)

### Quick Setup

```bash
# Run the setup script
cd ~/Git/aidevops
.agent/scripts/generate-opencode-agents.sh
```text

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
```text

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
```text

## Usage

### Switching Agents

- **Tab**: Cycle through primary agents
- **@agent-name**: Invoke a subagent

### Agent Invocation Order

OpenCode doesn't have built-in workflow orchestration, but agents should be invoked in logical order based on dependencies:

#### Recommended Workflow Order

```text
┌─────────────────────────────────────────────────────────────────┐
│                    DEVELOPMENT WORKFLOW                         │
├─────────────────────────────────────────────────────────────────┤
│  1. PLAN/RESEARCH (parallel)                                    │
│     @context7-mcp-setup  - Get documentation                    │
│     @seo                 - Research keywords/competitors        │
│     @browser-automation  - Scrape/test existing sites           │
│                                                                 │
│  2. INFRASTRUCTURE (sequential)                                 │
│     @dns-providers       - Configure DNS first                  │
│     @hetzner             - Provision servers                    │
│     @hostinger           - Setup hosting/WordPress              │
│                                                                 │
│  3. DEVELOPMENT (parallel)                                      │
│     @wordpress           - Local development                    │
│     @git-platforms       - Repository management                │
│     @crawl4ai-usage      - Data extraction                      │
│                                                                 │
│  4. QUALITY (sequential)                                        │
│     @code-standards        - Run checks, apply fixes              │
│     @agent-review        - Session analysis + PR                │
└─────────────────────────────────────────────────────────────────┘
```text

#### Parallel vs Sequential

| Type | Agents | When to Use |
|------|--------|-------------|
| **Parallel** | Research agents (seo, context7, browser) | No dependencies between tasks |
| **Sequential** | Infrastructure (dns → server → hosting) | Output of one is input to next |
| **Always Last** | code-quality, agent-review | Requires completed work to review |

#### Invoking Multiple Agents

OpenCode processes one `@mention` per message. For parallel work, send separate messages:

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
```text

#### End-of-Session Pattern (MANDATORY)

**Always end sessions with these agents in order:**

1. **@code-standards** - Fix any quality issues introduced
2. **@agent-review** - Analyze session, suggest improvements, optionally create PR

```bash
> @code-standards check and fix any issues in today's changes
# Wait for fixes...
> @agent-review analyze this session
```text

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
> @code-standards run ShellCheck on all scripts
```text

## CLI Testing Mode

The OpenCode TUI requires a restart to pick up configuration changes (new MCPs, agents, slash commands). Use the CLI for quick testing without restarting.

### When to Use CLI Testing

- **New MCP servers** added to `opencode.json`
- **Agent configuration changes** (tools, permissions)
- **Slash commands** added or modified
- **Quick one-off commands** with specific agents
- **Debugging MCP connection issues**

### Basic CLI Testing

```bash
# Test with specific agent (fresh config load)
opencode run "List your available tools" --agent SEO

# Test new MCP functionality
opencode run "Use dataforseo to get SERP for 'test query'" --agent SEO

# Test with different model
opencode run "Quick test" --agent Build+ --model anthropic/claude-sonnet-4-20250514

# Capture errors for debugging
opencode run "Test the serper MCP" --agent SEO 2>&1
```text

### Persistent Server Mode (Faster Iteration)

For iterative testing, use serve mode to avoid MCP cold boot on each run:

```bash
# Terminal 1: Start headless server (keeps MCPs warm)
opencode serve --port 4096

# Terminal 2: Run tests against it (fast, reuses MCP connections)
opencode run --attach http://localhost:4096 "Test query" --agent SEO
opencode run --attach http://localhost:4096 "Another test" --agent SEO

# After config changes: Ctrl+C in Terminal 1, restart server
```text

### Testing Scenarios

| Scenario | Command |
|----------|---------|
| New MCP added | `opencode run "List tools from [mcp]_*" --agent [agent]` |
| MCP auth issues | `opencode run "Call [mcp]_[tool]" --agent [agent] 2>&1` |
| Agent permissions | `opencode run "Try to write a file" --agent Plan+` |
| Slash command | `opencode run "/new-command arg1 arg2" --agent Build+` |
| Quick task | `opencode run "Do X quickly" --agent Build+` |

### Helper Script

Use the helper script for common testing tasks:

```bash
# Test if MCP is accessible
~/.aidevops/agents/scripts/opencode-test-helper.sh test-mcp dataforseo SEO

# Test agent permissions
~/.aidevops/agents/scripts/opencode-test-helper.sh test-agent Plan+

# List tools available to agent
~/.aidevops/agents/scripts/opencode-test-helper.sh list-tools Build+

# Start persistent server
~/.aidevops/agents/scripts/opencode-test-helper.sh serve 4096
```text

### Workflow: Adding New MCP

1. Edit `~/.config/opencode/opencode.json` - add MCP config
2. Test with CLI: `opencode run "Test [mcp]" --agent [agent] 2>&1`
3. If errors, check stderr output and fix config
4. If working, restart TUI to use interactively
5. Update `generate-opencode-agents.sh` to persist changes

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
```text

### Installing MCP Servers

```bash
# Hostinger MCP
npm install -g hostinger-api-mcp

# Hetzner MCP
brew install mcp-hetzner

# LocalWP MCP
brew install mcp-local-wp

# Chrome DevTools MCP (auto-installed via npx)
```text

### OpenCode MCP Environment Variable Limitation

**Important**: OpenCode's MCP `environment` blocks do NOT expand shell variables like `${VAR}` - they are treated as literal strings.

**Solution**: Use bash wrapper pattern to expand variables at runtime:

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
```text

This pattern:
1. Uses `/bin/bash -c` to run a shell command
2. Sets the required env var by reading from your shell environment
3. Then executes the MCP server with that variable set

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

**OpenCode Configuration:**

| Path | Purpose | Notes |
|------|---------|-------|
| `~/.config/opencode/opencode.json` | Main configuration | MCP servers, agents, tools |
| `~/.config/opencode/agent/*.md` | Agent markdown files | Per-agent instructions |
| `~/.opencode/` | Alternative location | Some installations use this |
| `~/.opencode/agent/` | Alternative agent location | Check if ~/.config not working |

**aidevops Integration:**

| Path | Purpose | Notes |
|------|---------|-------|
| `~/.aidevops/agents/` | Deployed aidevops agents | Created by setup.sh |
| `~/.config/aidevops/mcp-env.sh` | API credentials | 600 permissions |
| `~/Git/aidevops/.agent/` | Source agents | Development repo |
| `~/Git/aidevops/setup.sh` | Deployment script | Copies to ~/.aidevops/ |

**Troubleshooting Path Issues:**

```bash
# Check which OpenCode config is active
ls -la ~/.config/opencode/ ~/.opencode/ 2>/dev/null

# Verify agent deployment
ls -la ~/.aidevops/agents/ 2>/dev/null

# Check if aidevops agents are referenced
grep -l "aidevops" ~/.config/opencode/agent/*.md 2>/dev/null
```text

## Permission Model Limitations

### Critical: Subagent Permission Inheritance

**OpenCode subagents do NOT inherit parent agent permission restrictions.**

When a parent agent uses the `task` tool to spawn a subagent:
- The subagent runs with its OWN tool permissions
- Parent's `write: false` is NOT enforced on the subagent
- Parent's `bash: deny` is NOT enforced on the subagent

**Implications for Read-Only Agents:**

| Configuration | Is Actually Read-Only? |
|---------------|----------------------|
| `write: false, edit: false, task: true` | NO - subagents can write |
| `write: false, edit: false, bash: true` | NO - bash can write files |
| `write: false, edit: false, bash: false, task: false` | YES - truly read-only |

**Example**: Plan+ with `task: true` could call a subagent that creates files, defeating its read-only purpose.

### Bash Escapes All Restrictions

When `bash: true`, the agent can execute ANY shell command, including:
- `echo "content" > file.txt` - creates files
- `sed -i 's/old/new/' file.txt` - modifies files
- `rm file.txt` - deletes files

**For true read-only behavior**: Set both `bash: false` AND `task: false`

### Plan+ Read-Only Configuration

Plan+ is configured as strictly read-only:

```json
"Plan+": {
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
```text

Use Build+ (Tab) for any operations requiring file changes.

## Continuous Improvement with @agent-review

**End every session by calling `@agent-review`** to analyze the conversation and improve agents:

```text
@agent-review analyze this session and suggest improvements to the agents used
```text

The review agent will:
1. Identify which agents were used
2. Evaluate missing, incorrect, or excessive information
3. Suggest specific improvements to agent files
4. Generate ready-to-apply edits
5. **Optionally compose a PR** to contribute improvements back to aidevops

**Feedback Loop:**

```text
Session → @agent-review → Improvements → Better Agents → Better Sessions
                ↓
         PR to aidevops repo (optional)
```text

**Contributing back:**

```text
@agent-review create a PR for improvement #2
```text

This creates a branch, applies changes, and submits a PR to `marcusquinn/aidevops`. The agent has restricted bash permissions - only `git *` and `gh pr *` commands are allowed (with confirmation).

## Code Quality Learning Loop

The `@code-standards` agent doesn't just fix issues - it learns from them:

```text
Quality Issue → Fix Applied → Pattern Identified → Framework Updated → Issue Prevented
```text

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
