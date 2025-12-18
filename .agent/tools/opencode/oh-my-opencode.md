---
description: Oh-My-OpenCode plugin integration and compatibility guide
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

# Oh-My-OpenCode Integration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Plugin**: [oh-my-opencode](https://github.com/code-yeongyu/oh-my-opencode) v2.2.0+
- **Purpose**: Coding productivity features (LSP, AST, background agents, hooks)
- **Relationship**: Complementary to aidevops (DevOps infrastructure)
- **Config**: `~/.config/opencode/oh-my-opencode.json`

**Key Commands**:

```bash
# Trigger maximum performance mode
> ultrawork implement the feature

# Use OmO curated agents
> @oracle review this architecture
> @librarian find GitHub examples
> @explore search codebase fast
```

**Compatibility Notes**:

- Context7 MCP: Disabled in OmO config (aidevops configures it)
- Antigravity OAuth: Both provide it; works together
- Agent names: No conflicts (different domains)

<!-- AI-CONTEXT-END -->

## Overview

**Oh-My-OpenCode** (OmO) is an OpenCode plugin that adds coding productivity features. It complements aidevops, which provides DevOps infrastructure management.

### Feature Comparison

| Category | aidevops | oh-my-opencode |
|----------|----------|----------------|
| **Focus** | DevOps infrastructure | Coding productivity |
| **Agents** | 14 primary + 80+ subagents | 7 curated agents |
| **MCPs** | 20+ (SEO, hosting, WordPress) | 3 (Context7, Exa, grep.app) |
| **Tools** | Helper scripts, workflows | LSP (11), AST-Grep |
| **Hooks** | None | 21 lifecycle hooks |
| **Background Agents** | No | Yes (parallel execution) |

### Why Use Both?

```text
┌─────────────────────────────────────────────────────────────────┐
│                    COMBINED CAPABILITIES                         │
├─────────────────────────────────────────────────────────────────┤
│  aidevops provides:                                              │
│  • Server management (Hostinger, Hetzner, Cloudflare)           │
│  • WordPress ecosystem (LocalWP, MainWP)                        │
│  • SEO tools (DataForSEO, Serper, Ahrefs, GSC)                 │
│  • Code quality (SonarCloud, Codacy, CodeRabbit)               │
│  • Git platform CLIs (GitHub, GitLab, Gitea)                   │
│  • Deployment (Coolify, Vercel)                                 │
│                                                                  │
│  oh-my-opencode provides:                                        │
│  • LSP tools (hover, goto, references, rename, diagnostics)     │
│  • AST-Grep (semantic code search/replace)                      │
│  • Background agents (parallel task execution)                  │
│  • Curated agents (Oracle, Librarian, Explore, Frontend)        │
│  • Claude Code compatibility (hooks, commands, skills)          │
│  • Session recovery and context window monitoring               │
└─────────────────────────────────────────────────────────────────┘
```

## Installation

### Via aidevops setup.sh

The setup script offers to install oh-my-opencode:

```bash
cd ~/Git/aidevops
./setup.sh
# Answer 'y' when prompted for Oh-My-OpenCode installation
```

### Manual Installation

Add to `~/.config/opencode/opencode.json`:

```json
{
  "plugin": [
    "oh-my-opencode",
    "opencode-antigravity-auth@latest"
  ]
}
```

## Configuration

### Recommended oh-my-opencode.json

The setup creates `~/.config/opencode/oh-my-opencode.json`:

```json
{
  "$schema": "https://raw.githubusercontent.com/code-yeongyu/oh-my-opencode/master/assets/oh-my-opencode.schema.json",
  "google_auth": false,
  "disabled_mcps": ["context7"],
  "agents": {}
}
```

**Key settings:**

| Setting | Value | Reason |
|---------|-------|--------|
| `google_auth` | `false` | Use Antigravity plugin instead (more features) |
| `disabled_mcps.context7` | disabled | aidevops configures Context7 separately |

### Customizing Agents

Override OmO agent models if needed:

```json
{
  "agents": {
    "oracle": {
      "model": "anthropic/claude-opus-4-5",
      "temperature": 0.3
    },
    "frontend-ui-ux-engineer": {
      "disable": true
    }
  }
}
```

## Oh-My-OpenCode Features

### 1. Curated Agents

| Agent | Model | Purpose |
|-------|-------|---------|
| **OmO** | Claude Opus 4.5 | Primary orchestrator, team leader |
| **oracle** | GPT 5.2 | Architecture, code review, strategy |
| **librarian** | Claude Sonnet 4.5 | Docs lookup, GitHub examples |
| **explore** | Grok Code | Fast codebase exploration |
| **frontend-ui-ux-engineer** | Gemini 3 Pro | UI development |
| **document-writer** | Gemini 3 Pro | Technical documentation |
| **multimodal-looker** | Gemini 2.5 Flash | PDF/image analysis |

**Usage:**

```bash
> @oracle review this authentication implementation
> @librarian how is rate limiting implemented in express.js?
> @explore find all API endpoints in this codebase
> @frontend-ui-ux-engineer create a dashboard component
```

### 2. Background Agents

Run agents in parallel:

```bash
# Start multiple tasks simultaneously
> Have @frontend-ui-ux-engineer build the UI while @oracle designs the API

# OmO orchestrates automatically with 'ultrawork'
> ultrawork implement user authentication with frontend and backend
```

### 3. LSP Tools

11 language server protocol tools:

| Tool | Purpose |
|------|---------|
| `lsp_hover` | Type info, docs at position |
| `lsp_goto_definition` | Jump to symbol definition |
| `lsp_find_references` | Find all usages |
| `lsp_document_symbols` | File symbol outline |
| `lsp_workspace_symbols` | Search symbols by name |
| `lsp_diagnostics` | Get errors/warnings |
| `lsp_servers` | List available LSP servers |
| `lsp_prepare_rename` | Validate rename operation |
| `lsp_rename` | Rename symbol across workspace |
| `lsp_code_actions` | Get quick fixes/refactorings |
| `lsp_code_action_resolve` | Apply code action |

### 4. AST-Grep

Semantic code search and replace:

```bash
# Search for patterns
> Use ast_grep_search to find all async functions without error handling

# Replace patterns
> Use ast_grep_replace to add try-catch to all async functions
```

Supports 25 languages including TypeScript, Python, Go, Rust, Java.

### 5. Keyword Detector

Automatic mode activation:

| Keyword | Mode | Effect |
|---------|------|--------|
| `ultrawork` / `ulw` | Maximum performance | Parallel agent orchestration |
| `search` / `find` | Search mode | Maximized search with explore + librarian |
| `analyze` / `investigate` | Analysis mode | Multi-phase expert consultation |

### 6. Lifecycle Hooks

21 built-in hooks including:

- **comment-checker**: Prevents AI-style comments
- **todo-continuation-enforcer**: Forces completion of all TODOs
- **context-window-monitor**: Warns at 70%+ usage
- **session-recovery**: Auto-recovers from errors
- **anthropic-auto-compact**: Auto-summarizes at token limits
- **grep-output-truncator**: Prevents context bloat

## Compatibility Notes

### MCP Overlap

| MCP | aidevops | oh-my-opencode | Resolution |
|-----|----------|----------------|------------|
| Context7 | Configured | Built-in | Disable in OmO |
| Exa | Not included | Built-in | OmO provides |
| grep.app | Not included | Built-in | OmO provides |

### Agent Namespace

No conflicts - different naming conventions:

- **aidevops**: `@hostinger`, `@hetzner`, `@wordpress`, `@seo`
- **oh-my-opencode**: `@oracle`, `@librarian`, `@explore`, `@frontend-ui-ux-engineer`

### Claude Code Compatibility

OmO provides full Claude Code compatibility:

| Feature | Location | OmO Support |
|---------|----------|-------------|
| Commands | `~/.claude/commands/` | Yes |
| Skills | `~/.claude/skills/` | Yes |
| Agents | `~/.claude/agents/` | Yes |
| MCPs | `~/.claude/.mcp.json` | Yes |
| Hooks | `~/.claude/settings.json` | Yes |

aidevops commands in `~/.config/opencode/commands/` work alongside Claude commands.

## Workflow Integration

### Combined Workflow Example

```bash
# 1. Research phase (OmO agents)
> @librarian find best practices for implementing OAuth2 in Node.js
> @explore search this codebase for existing auth patterns

# 2. Architecture review (OmO agent)
> @oracle review the proposed authentication architecture

# 3. Implementation (OmO background agents)
> ultrawork implement OAuth2 with @frontend-ui-ux-engineer handling UI

# 4. Infrastructure (aidevops agents)
> @hostinger configure SSL for auth.example.com
> @cloudflare add DNS records for the auth subdomain

# 5. Quality check (aidevops workflows)
> /preflight
> /pr review

# 6. Deployment (aidevops agents)
> @coolify deploy the authentication service
```

### Recommended Agent Order

```text
┌─────────────────────────────────────────────────────────────────┐
│                    COMBINED WORKFLOW                             │
├─────────────────────────────────────────────────────────────────┤
│  1. RESEARCH (parallel - OmO)                                    │
│     @librarian  - Documentation lookup                          │
│     @explore    - Codebase search                               │
│                                                                  │
│  2. ARCHITECTURE (OmO)                                           │
│     @oracle     - Design review                                 │
│                                                                  │
│  3. IMPLEMENTATION (parallel - OmO + aidevops)                   │
│     @frontend-ui-ux-engineer - UI components                    │
│     Build+ (aidevops)        - Backend logic                    │
│                                                                  │
│  4. INFRASTRUCTURE (sequential - aidevops)                       │
│     @dns-providers → @hetzner → @hostinger                      │
│                                                                  │
│  5. QUALITY (aidevops)                                           │
│     /preflight → /pr review                                     │
│                                                                  │
│  6. DEPLOYMENT (aidevops)                                        │
│     @coolify or @vercel                                         │
└─────────────────────────────────────────────────────────────────┘
```

## Troubleshooting

### Plugin Not Loading

```bash
# Check plugin is in config
cat ~/.config/opencode/opencode.json | jq '.plugin'

# Should show:
# ["oh-my-opencode", "opencode-antigravity-auth@latest"]

# Restart OpenCode after config changes
```

### LSP Tools Not Working

```bash
# Check LSP servers are installed
> Use lsp_servers to list available servers

# Install language servers as needed
npm install -g typescript-language-server
pip install python-lsp-server
```

### Context7 Duplicate

If you see Context7 errors:

```json
// ~/.config/opencode/oh-my-opencode.json
{
  "disabled_mcps": ["context7"]
}
```

### Agent Conflicts

If aidevops and OmO agents conflict:

```json
// Disable specific OmO agents
{
  "disabled_agents": ["explore"]
}
```

## References

- [Oh-My-OpenCode GitHub](https://github.com/code-yeongyu/oh-my-opencode)
- [Oh-My-OpenCode Schema](https://raw.githubusercontent.com/code-yeongyu/oh-my-opencode/master/assets/oh-my-opencode.schema.json)
- [OpenCode Plugin SDK](https://opencode.ai/docs/plugins)
- [aidevops OpenCode Integration](./opencode.md)
