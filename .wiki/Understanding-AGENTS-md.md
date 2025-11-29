# Understanding AGENTS.md

`AGENTS.md` is the **single source of truth** for AI assistant behavior in this framework. This page explains how it works and why it's designed this way.

## What is AGENTS.md?

It's a comprehensive instruction file that tells AI assistants:

- **What services are available** (30+ integrations)
- **How to use them securely** (credential management, confirmation requirements)
- **Where to find documentation** (`.agent/` directory structure)
- **Quality standards to maintain** (code quality, testing requirements)
- **Working directory rules** (where to create files)

## Why a Single Source of Truth?

### Problem: Conflicting Instructions

Without centralized guidance, AI assistants might receive conflicting instructions from:
- Multiple configuration files
- Different project READMEs
- Various system prompts

### Solution: Authoritative File

`AGENTS.md` provides:
- **One place** for all operational guidance
- **Consistent behavior** across AI tools
- **Security controls** in one location
- **Easy updates** that propagate everywhere

## File Structure

```text
AGENTS.md
├── Security Warning          # Critical security guidelines
├── Service Reliability       # Status pages and troubleshooting
├── AI Context Location       # Where to find documentation
├── Agent Behavior            # How AI should operate
├── Working Directories       # File organization rules
├── Quality Standards         # Code quality requirements
├── Service Categories        # All 30+ integrations
├── Security Contract         # Credential management
└── Quality Monitoring        # Current metrics and targets
```

## Key Sections Explained

### 🔒 Security Contract

```text
All credentials stored in configs/[service]-config.json (gitignored)
Templates in configs/[service]-config.json.txt (committed)
Never expose credentials in logs, output, or error messages
```

**Why:** Prevents accidental credential exposure. AI assistants know to never echo passwords.

### 📁 Working Directories

```text
~/.agent/
├── tmp/      # Temporary files
├── work/     # Project files  
└── memory/   # Persistent context
```

**Why:** Prevents AI from littering your home directory with random files.

### 🏆 Quality Standards

```text
SonarCloud: A-grades required
CodeFactor: 85%+ A-grade files
ShellCheck: Zero violations
```

**Why:** Maintains code quality across all contributions.

## How AI Assistants Use It

### 1. Initial Context

When you mention DevOps tasks, the AI reads `AGENTS.md` to understand:
- Available services
- Security requirements
- Where to find details

### 2. Task Execution

For specific tasks, the AI:
1. Reads relevant `.agent/*.md` documentation
2. Uses appropriate `.agent/scripts/*.sh` helpers
3. Follows security and quality guidelines

### 3. File Operations

Before creating files, the AI checks:
- Is this the right working directory?
- Does this follow naming conventions?
- Are credentials handled securely?

## Template Files vs Authoritative File

| Location | Purpose | Content |
|----------|---------|---------|
| `~/git/aidevops/AGENTS.md` | **Authoritative** | Complete instructions |
| `~/AGENTS.md` | Template | Reference to authoritative file |
| `~/git/AGENTS.md` | Template | Reference to authoritative file |

**Templates are minimal** to prevent conflicting instructions and security issues.

## Updating AGENTS.md

When making changes:

1. **Only edit the authoritative file** at `~/git/aidevops/AGENTS.md`
2. **Never add detailed instructions** to template files
3. **Update AI-CONTEXT blocks** when changing referenced content
4. **Test with an AI assistant** to verify behavior

## For AI Tool Developers

If building AI integrations, you can:

1. **Reference AGENTS.md** in your system prompts
2. **Use the `.agent/` structure** as context
3. **Follow the security contract** for credential handling
4. **Adopt the working directory conventions** for file operations

## Related Pages

- **[The .agent Directory](The-Agent-Directory)** - Framework structure details
- **[Workflows Guide](Workflows-Guide)** - Development processes
- **[For Humans](For-Humans)** - Non-technical overview
