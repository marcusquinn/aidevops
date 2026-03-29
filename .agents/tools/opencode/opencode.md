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

## Quick Reference

- **Primary Agent**: `aidevops` — full framework access
- **Subagents**: hostinger, hetzner, wordpress, seo, code-quality, browser-automation, etc.
- **Setup**: `cd ~/Git/aidevops && .agents/scripts/generate-opencode-agents.sh`
- **MCPs disabled globally** — enabled per-agent to save context tokens

| Purpose | Path |
|---------|------|
| Main config | `~/.config/opencode/opencode.json` |
| Agent files | `~/.config/opencode/agent/*.md` |
| Alternative config | `~/.opencode/` (some installations) |
| aidevops agents | `~/.aidevops/agents/` (after setup.sh) |
| Credentials | `~/.config/aidevops/credentials.sh` |

## Authentication

See `tools/opencode/opencode-anthropic-auth.md` for full auth setup (OAuth pool, API key, version-specific notes).

> Do NOT add `opencode-anthropic-auth` to `opencode.json` plugins — double-loading causes a TypeError.

## Agent Architecture

| Agent | Description | MCPs Enabled |
|-------|-------------|--------------|
| `aidevops` | Full framework (primary) | context7 |
| `hostinger` | Hosting, WordPress, DNS | hostinger-api |
| `hetzner` | Cloud infrastructure | hetzner-* (4 accounts) |
| `wordpress` | Local dev, MainWP | localwp, context7 |
| `seo` | Search Console, Ahrefs | gsc, ahrefs |
| `code-quality` | Quality scanning + learning loop | context7 |
| `browser-automation` | Testing, scraping | chrome-devtools, context7 |
| `git-platforms` | GitHub, GitLab, Gitea | context7 |
| `dns-providers` | DNS management | hostinger-api (DNS) |
| `agent-review` | Session analysis, improvements | (read/write only) |

## Configuration

MCPs defined with `enabled: false` globally; tools disabled with `"mcp_*": false`. Each subagent enables its specific tools.

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": { "hostinger-api": { "type": "local", "command": ["..."], "enabled": false } },
  "tools": { "hostinger-api_*": false },
  "agent": {
    "hostinger": { "description": "...", "mode": "subagent", "tools": { "hostinger-api_*": true } }
  }
}
```

Agent markdown format (`~/.config/opencode/agent/*.md`):

```markdown
---
description: Short description
mode: subagent
temperature: 0.1
tools:
  bash: true
  mcp-name_*: true
---
```

## Usage

- **Tab**: Cycle through primary agents
- **@agent-name**: Invoke a subagent (one `@mention` per message)

### Workflow Order

| Phase | Agents | Execution |
|-------|--------|-----------|
| 1. Plan/Research | @context7-mcp-setup, @seo, @browser-automation | Parallel |
| 2. Infrastructure | @dns-providers → @hetzner → @hostinger | Sequential |
| 3. Development | @wordpress, @git-platforms, @crawl4ai-usage | Parallel |
| 4. Quality | @code-standards → @agent-review | Sequential (always last) |

### End-of-Session (MANDATORY)

1. **@code-standards** — fix quality issues
2. **@agent-review** — analyze session, suggest improvements, optionally create PR

`@agent-review` has restricted bash — only `git *` and `gh pr *` commands allowed.

## CLI Testing

TUI requires restart for config changes. Use CLI for quick iteration:

```bash
opencode run "List your available tools" --agent SEO
opencode run "Quick test" --agent Build+ --model anthropic/claude-sonnet-4-6

# Persistent server (keeps MCPs warm)
opencode serve --port 4096                                             # Terminal 1
opencode run --attach http://localhost:4096 "Test query" --agent SEO  # Terminal 2

# Helper shortcuts
~/.aidevops/agents/scripts/opencode-test-helper.sh test-mcp dataforseo SEO
~/.aidevops/agents/scripts/opencode-test-helper.sh list-tools Build+
~/.aidevops/agents/scripts/opencode-test-helper.sh serve 4096
```

**Adding a new MCP:** Edit `opencode.json` → test with CLI → fix errors → restart TUI → update `generate-opencode-agents.sh`.

## MCP Server Configuration

Credentials in `~/.config/aidevops/credentials.sh`:

```bash
export HOSTINGER_API_TOKEN="your-token"
export HCLOUD_TOKEN_AWARDSAPP="your-token"   # Hetzner per-account
# GSC: service account JSON at ~/.config/aidevops/gsc-credentials.json
```

**MCP env var limitation:** OpenCode `environment` blocks do NOT expand `${VAR}` — use bash wrapper:

```json
"ahrefs": {
  "type": "local",
  "command": ["/bin/bash", "-c", "API_KEY=$AHREFS_API_KEY /opt/homebrew/bin/npx -y @ahrefs/mcp@latest"]
}
```

## Troubleshooting

| Problem | Steps |
|---------|-------|
| MCPs not loading | Check `enabled` in opencode.json → verify env vars → test MCP command manually |
| Agent not found | Check file in `~/.config/opencode/agent/` → verify YAML frontmatter → restart |
| Tools not available | Check tools enabled in agent config → verify glob patterns → check MCP responding |

## Permission Model

Subagents do NOT inherit parent permission restrictions. Parent `write: false` does not apply to spawned subagents.

| Configuration | Actually Read-Only? |
|---------------|---------------------|
| `write: false, edit: false, task: true` | **NO** — subagents can write |
| `write: false, edit: false, bash: true` | **NO** — bash can write files |
| `write: false, edit: false, bash: false, task: false` | **YES** |

For true read-only: set both `bash: false` AND `task: false`.

```json
"@plan-plus": {
  "permission": { "edit": "deny", "write": "deny", "bash": "deny" },
  "tools": { "write": false, "edit": false, "bash": false, "task": false, "read": true, "glob": true, "grep": true, "webfetch": true }
}
```

## Parallel Sessions

```bash
opencode run "Task description" --agent Build+ --title "Task Name" &
opencode serve --port 4097
opencode run --attach http://localhost:4097 "Task" --agent Build+
~/.aidevops/agents/scripts/worktree-helper.sh add feature/parallel-task
```

See `workflows/session-manager.md` for session lifecycle, terminal tab spawning, and worktree integration.

## References

- [OpenCode Agents Documentation](https://opencode.ai/docs/agents)
- [OpenCode MCP Servers](https://opencode.ai/docs/mcp-servers/)
