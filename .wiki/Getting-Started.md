# Getting Started

This guide helps you set up and start using the AI DevOps Framework.

## Prerequisites

| Requirement | Purpose |
|-------------|---------|
| Git | Version control |
| Node.js 18+ | Script runtime |
| GitHub CLI (`gh`) | GitHub operations |
| Bash shell | Script execution |

## Installation

### Step 1: Clone the Repository

```bash
# Create standard directory structure
mkdir -p ~/git
cd ~/git

# Clone the framework
git clone https://github.com/marcusquinn/aidevops.git
cd aidevops
```

### Step 2: Configure Your AI Assistant

Add this to your AI assistant's system prompt or instructions:

```
Before performing DevOps operations, read ~/git/aidevops/AGENTS.md 
for authoritative guidance on this infrastructure management framework.
```

**For specific tools:**

| Tool | Configuration |
|------|---------------|
| **Claude Projects** | Add AGENTS.md as project knowledge |
| **Cursor** | Reference in `.cursorrules` |
| **VS Code + Continue** | Add to context |
| **OpenCode** | Uses AGENTS.md automatically |

### Step 3: Set Up API Keys (Optional)

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

```
~/git/aidevops/
├── AGENTS.md              # 📖 AI assistant instructions
├── CHANGELOG.md           # Version history
├── .agent/                # 🤖 All AI-relevant content
│   ├── scripts/           # 90+ automation scripts
│   ├── workflows/         # Development process guides
│   ├── memory/            # Context persistence templates
│   └── *.md               # Service documentation
├── .github/workflows/     # CI/CD automation
└── configs/               # Configuration templates
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

```
~/.agent/
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

1. **[Understanding AGENTS.md](Understanding-AGENTS-md)** - Learn how AI guidance works
2. **[The .agent Directory](The-Agent-Directory)** - Explore the framework structure
3. **[Workflows Guide](Workflows-Guide)** - Development processes

## Troubleshooting

### AI Can't Find AGENTS.md

Ensure the repository is at the standard location:
```bash
ls ~/git/aidevops/AGENTS.md
```

### Scripts Not Executable

```bash
chmod +x ~/git/aidevops/.agent/scripts/*.sh
```

### API Keys Not Working

```bash
# Verify keys are loaded
source ~/.config/aidevops/mcp-env.sh
env | grep -i api
```
