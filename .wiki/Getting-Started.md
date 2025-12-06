# Getting Started

This guide helps you set up and start using the AI DevOps Framework.

## Quick Install

Run this single command to install or update:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/marcusquinn/aidevops/main/setup.sh)
```

This handles everything automatically:

- Clones repository to `~/Git/aidevops`
- Installs the `aidevops` CLI command globally
- Detects and uses your package manager (brew, apt, dnf, yum, pacman, apk)
- Configures all supported AI assistants
- Offers to install recommended tools

## What Setup Installs

### Required Dependencies (Auto-installed)

| Dependency | Purpose |
|------------|---------|
| git | Version control |
| jq | JSON processing |
| curl | HTTP requests |
| ssh | Remote connections |

### Optional Dependencies

| Dependency | Purpose |
|------------|---------|
| sshpass | Password-based SSH authentication |

### Recommended Tools (Prompted)

| Tool | Purpose |
|------|---------|
| [Tabby](https://tabby.sh) | Modern terminal with AI features |
| [Zed](https://zed.dev) | High-performance editor with AI |
| OpenCode for Zed | AI coding extension |

### Git CLI Tools (Prompted)

| Tool | Purpose |
|------|---------|
| gh | GitHub CLI |
| glab | GitLab CLI |

### SSH Key

Setup offers to generate an Ed25519 SSH key if you don't have one.

## The `aidevops` CLI

After installation, you have the `aidevops` command available globally:

```bash
aidevops status      # Check installation status
aidevops update      # Update to latest version
aidevops uninstall   # Remove from system
aidevops version     # Show version info
aidevops help        # Show all commands
```

See [CLI Reference](CLI-Reference) for complete documentation.

## Manual Installation

If you prefer manual setup:

```bash
# Clone the repository
mkdir -p ~/Git
cd ~/Git
git clone https://github.com/marcusquinn/aidevops.git
cd aidevops

# Run setup
./setup.sh
```

## AI Assistant Configuration

Setup automatically configures these AI assistants:

| Tool | Configuration File |
|------|-------------------|
| **OpenCode** | `~/.config/opencode/AGENTS.md` |
| **Cursor** | `.cursorrules` |
| **Claude Code** | `CLAUDE.md` |
| **Windsurf** | `.windsurfrules`, `WINDSURF.md` |
| **Continue.dev** | `.continuerules` |
| **Gemini** | `GEMINI.md` |
| **Warp** | `WARP.md` |
| **Codex** | `.codex/AGENTS.md` |
| **Kiro** | `.kiro/` |

## API Keys (Optional)

For services requiring authentication:

```bash
# Use the secure key management script
bash .agent/scripts/setup-local-api-keys.sh

# Example: Add a service key
bash .agent/scripts/setup-local-api-keys.sh set codacy-api-key YOUR_KEY

# List configured services
bash .agent/scripts/setup-local-api-keys.sh list
```

**Keys are stored securely in:** `~/.config/aidevops/mcp-env.sh`

## Directory Structure

```text
~/Git/aidevops/              # Repository location
├── AGENTS.md                # AI assistant instructions
├── aidevops.sh              # CLI source script
├── setup.sh                 # Installer/updater
├── .agent/                  # All AI-relevant content
│   ├── scripts/             # 90+ automation scripts
│   ├── workflows/           # Development process guides
│   ├── memory/              # Context persistence templates
│   └── *.md                 # Service documentation
├── .github/workflows/       # CI/CD automation
└── configs/                 # Configuration templates

~/.aidevops/                 # User installation
├── agents/                  # Deployed agent files
│   └── AGENTS.md            # User guide
└── backups/                 # Configuration backups

/usr/local/bin/aidevops      # CLI command (or ~/.local/bin/)
```

## First Steps with Your AI

### Ask Your AI to Help With:

1. **"Show me what services are available"**
   - AI reads `.agent/` documentation

2. **"Help me set up Hostinger hosting"**
   - AI uses `.agent/hostinger.md` and scripts

3. **"Check code quality for this project"**
   - AI uses quality CLI helpers

4. **"Create a new GitHub repository"**
   - AI uses GitHub CLI helper scripts

### Example Conversation

> **You:** I want to deploy a WordPress site on Hostinger
>
> **AI:** I'll help you deploy WordPress on Hostinger. Let me check the framework documentation...
>
> *AI reads `.agent/hostinger.md` and uses `hostinger-helper.sh`*
>
> **AI:** I found the Hostinger helper. First, let's verify your account is configured...

## Working Directories

The framework creates organized working directories:

```text
~/.aidevops/.agent-workspace/
├── tmp/        # Temporary session files (auto-cleanup)
├── work/       # Project working directories
│   ├── wordpress/
│   ├── hosting/
│   ├── seo/
│   └── development/
└── memory/     # Persistent AI context
```

**Rule:** AI assistants never create files in `~/` root - always in organized directories.

## Next Steps

1. **[CLI Reference](CLI-Reference)** - Master the `aidevops` command
2. **[Understanding AGENTS.md](Understanding-AGENTS-md)** - Learn how AI guidance works
3. **[The .agent Directory](The-Agent-Directory)** - Explore the framework structure
4. **[Workflows Guide](Workflows-Guide)** - Development processes

## Troubleshooting

### Check Installation Status

```bash
aidevops status
```

This shows the status of all components including version, dependencies, and tools.

### AI Can't Find AGENTS.md

Ensure the repository is at the standard location:

```bash
ls ~/Git/aidevops/AGENTS.md
```

### Scripts Not Executable

```bash
chmod +x ~/Git/aidevops/.agent/scripts/*.sh
```

### API Keys Not Working

```bash
# Verify keys are loaded
source ~/.config/aidevops/mcp-env.sh
env | grep -i api
```

### Update to Latest Version

```bash
aidevops update
```
