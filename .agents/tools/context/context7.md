---
description: Real-time library documentation via Context7 MCP
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Context7 MCP Setup Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Real-time access to latest library/framework documentation
- **Package**: `@upstash/context7-mcp` (formerly `@context7/mcp-server`)
- **CLI**: `npx ctx7` for skills and setup commands
- **Telemetry**: Disable with `export CTX7_TELEMETRY_DISABLED=1`

**MCP Tools**:
- `resolve-library-id` → Resolves library name to Context7 ID (e.g., "next.js" → "/vercel/next.js")
- `query-docs` → Retrieves documentation for a library ID with a query

**Common Library IDs**:
- Frontend: `/vercel/next.js`, `/facebook/react`, `/vuejs/vue`
- Backend: `/expressjs/express`, `/nestjs/nest`
- DB/ORM: `/prisma/prisma`, `/supabase/supabase`, `/drizzle-team/drizzle-orm`
- Tools: `/vitejs/vite`, `/typescript-eslint/typescript-eslint`

**Skills Registry**: Context7 hosts a searchable skills registry at [context7.com/skills](https://context7.com/skills). Search, install, and suggest skills for your project:

```bash
npx ctx7 skills search react        # Search registry
npx ctx7 skills suggest             # Auto-suggest from project deps
npx ctx7 skills install /anthropics/skills pdf  # Install a skill
```

Skills found in the Context7 registry can be imported into aidevops using `/add-skill`. See "Skill Discovery and Import" section below.

**Config Location**: `~/Library/Application Support/Claude/claude_desktop_config.json`
<!-- AI-CONTEXT-END -->

Context7 MCP provides AI assistants with real-time access to the latest documentation for thousands of development tools, frameworks, and libraries.

## 🎯 **What is Context7 MCP?**

Context7 MCP is a Model Context Protocol server that gives AI assistants access to:

- **Latest documentation** for popular development tools and frameworks
- **Version-specific** documentation and guides
- **AI-optimized** content format for better understanding
- **Real-time updates** as libraries and tools evolve
- **Comprehensive coverage** of the development ecosystem

## 🚀 **Benefits for AI-Assisted Development**

### **Before Context7 MCP:**

- AI assistants work with **outdated training data**
- **Guessing** at API changes and new features
- **Inconsistent** information across different versions
- **Limited** knowledge of recent tools and updates

### **After Context7 MCP:**

- **Real-time access** to latest documentation
- **Version-specific** guidance and examples
- **Accurate** API references and best practices
- **Comprehensive** coverage of your development stack

## 📦 **Installation & Setup**

### **Prerequisites:**

- **Node.js 18+** installed
- **npm or npx** available
- **AI assistant** that supports MCP (Claude Code recommended)

### **1. Test Context7 MCP Server:**

```bash
# Test the server (no installation needed with npx)
npx -y @upstash/context7-mcp --help

# This should show the Context7 MCP server help
```

### **2. Add to Your AI Assistant Configuration:**

> **Note**: aidevops configures Context7 automatically via `setup.sh`. The sections below document config formats for other tools as MCP reference.

#### **For Claude Code:**

```bash
claude mcp add --scope user context7 -- npx -y @upstash/context7-mcp
```

#### **For Claude Desktop:**

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    }
  }
}
```

#### **Remote Server Connection (recommended):**

For any MCP client that supports remote servers:

```json
{
  "mcpServers": {
    "context7": {
      "url": "https://mcp.context7.com/mcp"
    }
  }
}
```

#### **Automated Setup:**

```bash
# Auto-configures MCP server and rule for your AI assistant
npx ctx7 setup
# Use --cursor, --claude, or --opencode to target a specific agent
```

### **3. Framework Configuration:**

```bash
# Copy the Context7 MCP configuration template
cp configs/context7-mcp-config.json.txt configs/context7-mcp-config.json

# Edit with your commonly used libraries and preferences
```

## 🔧 **Usage Examples**

### **1. Library Resolution:**

```bash
# Always resolve library names first
resolve-library-id("next.js")
# Returns: "/vercel/next.js"

resolve-library-id("react")
# Returns: "/facebook/react"

resolve-library-id("supabase")
# Returns: "/supabase/supabase"
```

### **2. Getting Documentation:**

```bash
# Get general documentation
get-library-docs("/vercel/next.js")

# Get topic-specific documentation
get-library-docs("/vercel/next.js", topic="routing")

# Get version-specific documentation
get-library-docs("/vercel/next.js/v14.3.0-canary.87")

# Adjust token limits for more/less detail
get-library-docs("/facebook/react", tokens=10000)
```

### **3. Common Development Workflows:**

#### **Starting a New Project:**

```bash
# Get setup documentation for your stack
resolve-library-id("next.js") -> get-library-docs("/vercel/next.js", topic="getting-started")
resolve-library-id("tailwind") -> get-library-docs("/tailwindlabs/tailwindcss", topic="installation")
resolve-library-id("prisma") -> get-library-docs("/prisma/prisma", topic="setup")
```

#### **Debugging Issues:**

```bash
# Get troubleshooting guides
get-library-docs("/vercel/next.js", topic="troubleshooting")

# Check API changes between versions
get-library-docs("/facebook/react/v18.2.0")
get-library-docs("/facebook/react/v18.3.0")
```

#### **Learning New Tools:**

```bash
# Comprehensive documentation for new library
resolve-library-id("drizzle-orm") -> get-library-docs("/drizzle-team/drizzle-orm")

# Get examples and best practices
get-library-docs("/drizzle-team/drizzle-orm", topic="examples")
```

## 📚 **Common Library Categories**

### **Frontend Frameworks:**

- `/vercel/next.js` - Next.js React framework
- `/facebook/react` - React library
- `/vuejs/vue` - Vue.js framework
- `/angular/angular` - Angular framework
- `/sveltejs/svelte` - Svelte framework

### **Backend Frameworks:**

- `/expressjs/express` - Express.js for Node.js
- `/nestjs/nest` - NestJS framework
- `/fastify/fastify` - Fastify web framework
- `/django/django` - Django Python framework
- `/flask/flask` - Flask Python framework

### **Databases & ORMs:**

- `/mongodb/docs` - MongoDB database
- `/postgres/postgres` - PostgreSQL database
- `/supabase/supabase` - Supabase platform
- `/prisma/prisma` - Prisma ORM
- `/drizzle-team/drizzle-orm` - Drizzle ORM

### **Development Tools:**

- `/microsoft/vscode` - VS Code editor
- `/typescript-eslint/typescript-eslint` - TypeScript ESLint
- `/prettier/prettier` - Code formatter
- `/vitejs/vite` - Vite build tool
- `/webpack/webpack` - Webpack bundler

### **AI/ML Tools:**

- `/openai/openai-node` - OpenAI Node.js SDK
- `/anthropic/anthropic-sdk-typescript` - Anthropic TypeScript SDK
- `/langchain-ai/langchainjs` - LangChain JavaScript
- `/huggingface/transformers.js` - Hugging Face Transformers

### **Generative Media:**

- `/websites/higgsfield_ai` - Higgsfield AI (100+ image/video/audio models)

## 🛠️ **Best Practices**

### **Library Resolution:**

1. **Always resolve first**: Use `resolve-library-id` before `get-library-docs`
2. **Use specific names**: "next.js" is better than "nextjs"
3. **Check alternatives**: Some libraries have multiple valid IDs
4. **Cache results**: Store resolved IDs for repeated use

### **Documentation Retrieval:**

1. **Use topics**: Specify topics for focused results (`topic="routing"`)
2. **Manage tokens**: Adjust token limits based on detail needed
3. **Version-specific**: Use specific versions when working with older code
4. **Combine sources**: Get docs from multiple related libraries

### **Development Workflow:**

1. **Start with docs**: Get documentation before coding
2. **Reference during development**: Keep docs accessible while coding
3. **Check for updates**: Regularly verify you're using latest practices
4. **Validate approaches**: Use docs to verify your implementation approach

## 🔍 **Troubleshooting**

### **Common Issues:**

#### **Library Not Found:**

```bash
# Try different variations
resolve-library-id("nextjs")      # Try without dots
resolve-library-id("next")        # Try shortened name
resolve-library-id("vercel/next") # Try with org prefix
```

#### **Documentation Seems Outdated:**

```bash
# Check for specific version
get-library-docs("/vercel/next.js/v14.0.0")

# Verify library has moved or been renamed
resolve-library-id("new-library-name")
```

#### **MCP Server Not Responding:**

```bash
# Test the server directly
npx -y @upstash/context7-mcp --help

# Check your AI assistant's MCP configuration
# Restart your AI assistant
```

## 🎯 **Integration with Your Workflow**

### **Project Setup:**

```bash
# Create project-specific library list
echo '["next.js", "tailwind", "prisma", "supabase"]' > .context7-libraries

# Get setup docs for all libraries
for lib in $(cat .context7-libraries); do
  resolve-library-id("$lib") && get-library-docs(result, topic="setup")
done
```

### **Code Review:**

- **Verify best practices** against latest documentation
- **Check for deprecated** APIs and patterns
- **Reference migration guides** for version updates
- **Validate security practices** with official guidelines

### **Learning & Development:**

- **Explore new libraries** with comprehensive documentation
- **Understand breaking changes** between versions
- **Learn best practices** from official examples
- **Stay updated** with latest features and improvements

## 🌟 **Advanced Features**

### **Version-Specific Documentation:**

```bash
# Get docs for specific version
get-library-docs("/vercel/next.js/v13.5.0")

# Compare between versions
get-library-docs("/react-router/react-router/v5.3.0")
get-library-docs("/react-router/react-router/v6.0.0")
```

### **Topic-Focused Queries:**

```bash
# Get specific topic documentation
get-library-docs("/vercel/next.js", topic="api-routes")
get-library-docs("/prisma/prisma", topic="migrations")
get-library-docs("/supabase/supabase", topic="authentication")
```

### **Token Management:**

```bash
# Brief overview (default: 5000 tokens)
get-library-docs("/facebook/react")

# Detailed documentation (more tokens)
get-library-docs("/facebook/react", tokens=15000)

# Quick reference (fewer tokens)
get-library-docs("/facebook/react", tokens=2000)
```

## Skill Discovery and Import

Context7 maintains a searchable [skills registry](https://context7.com/skills) with trust scores, install counts, and prompt injection scanning. Skills follow the [Agent Skills](https://agentskills.io) open standard (`SKILL.md` format).

### Searching for Skills

```bash
# Search the Context7 registry
npx ctx7 skills search react
npx ctx7 skills search "typescript testing"

# Auto-suggest skills based on project dependencies
npx ctx7 skills suggest

# View details about a repository's skills
npx ctx7 skills info /anthropics/skills
```

### Installing Skills via Context7

```bash
# Interactive selection from a repository
npx ctx7 skills install /anthropics/skills

# Install a specific skill
npx ctx7 skills install /anthropics/skills pdf

# Install globally (available in all projects)
npx ctx7 skills install /anthropics/skills pdf --global

# Target a specific client
npx ctx7 skills install /anthropics/skills pdf --claude
```

### Importing Skills into aidevops

Skills discovered in the Context7 registry can be imported into the aidevops framework using the `/add-skill` system. This converts them to aidevops subagent format with frontmatter, registers them for update tracking, and places them in the appropriate `.agents/` directory.

**Workflow:**

1. **Search** the Context7 registry: `npx ctx7 skills search <query>`
2. **Evaluate** trust score (7+ = high, 3-6.9 = medium, <3 = review carefully)
3. **Import** into aidevops: `/add-skill <github-repo>` (e.g., `/add-skill anthropics/skills`)
4. **Verify** the imported skill passes security scanning (Cisco Skill Scanner)
5. **Deploy** with `./setup.sh` to create symlinks for all AI assistants

**Example -- importing a skill found via Context7:**

```bash
# 1. Search Context7 for Supabase skills
npx ctx7 skills search supabase
# Found: /supabase-community/supabase-custom-claims (trust: 7.2)

# 2. Import into aidevops
/add-skill supabase-community/supabase-custom-claims

# 3. The skill is placed in .agents/ with -skill suffix
# → .agents/services/database/supabase-custom-claims-skill.md
```

**Key differences between Context7 install and aidevops import:**

| Aspect | `ctx7 skills install` | `/add-skill` |
|--------|----------------------|--------------|
| Format | SKILL.md (as-is) | Converted to aidevops subagent |
| Location | Client skill dirs (`.claude/skills/`) | `.agents/` directory |
| Tracking | None | `skill-sources.json` with update checks |
| Security | Context7 trust score | Cisco Skill Scanner + trust score |
| Cross-tool | Single client | All AI assistants via `setup.sh` |

### Managing Skills

```bash
# List installed Context7 skills
npx ctx7 skills list

# List aidevops-imported skills
/add-skill list

# Check for upstream updates
/add-skill check-updates

# Remove a skill
npx ctx7 skills remove pdf
/add-skill remove <name>
```

**Related**: `scripts/commands/add-skill.md`, `tools/build-agent/add-skill.md`, `tools/deployment/agent-skills.md`

## Disabling Telemetry

The Context7 CLI (`ctx7`) collects anonymous usage data. To disable:

```bash
# For a single command
CTX7_TELEMETRY_DISABLED=1 npx ctx7 skills search pdf

# Permanent -- add to shell profile (~/.bashrc, ~/.zshrc, etc.)
export CTX7_TELEMETRY_DISABLED=1
```

aidevops recommends disabling telemetry in automated/CI environments. Add the export to `~/.config/aidevops/credentials.sh` or your shell profile.
