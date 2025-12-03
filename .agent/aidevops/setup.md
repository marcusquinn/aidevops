# Setup Guide - AI Assistant for setup.sh

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Script**: `~/Git/aidevops/setup.sh`
- **Purpose**: Deploy aidevops agents to user's system
- **Target**: `~/.aidevops/agents/`

**What setup.sh does**:
1. Checks system requirements (jq, curl, ssh)
2. Checks optional dependencies (sshpass, git CLIs)
3. Copies `.agent/` contents to `~/.aidevops/agents/`
4. Backs up existing configs to `~/.aidevops/config-backups/[timestamp]/`
5. Injects reference into AI assistant AGENTS.md files
6. Updates OpenCode agent paths in `opencode.json`

**Run**:
```bash
cd ~/Git/aidevops
./setup.sh
```

**Post-setup locations**:
- Agents: `~/.aidevops/agents/`
- Backups: `~/.aidevops/config-backups/`
- Credentials: `~/.config/aidevops/mcp-env.sh`

<!-- AI-CONTEXT-END -->

## Detailed Setup Process

### Prerequisites

**Required:**
- `jq` - JSON processing
- `curl` - HTTP requests
- `ssh` - Server access

**Optional:**
- `sshpass` - Password-based SSH (for Hostinger)
- `gh` - GitHub CLI
- `glab` - GitLab CLI
- `tea` - Gitea CLI

### What Gets Deployed

```
~/.aidevops/
├── agents/                    # Full agent structure
│   ├── AGENTS.md             # User entry point
│   ├── aidevops.md           # Main agents
│   ├── wordpress.md
│   ├── aidevops/             # Subagent folders
│   ├── tools/
│   ├── services/
│   ├── workflows/
│   └── scripts/              # Helper scripts
└── config-backups/           # Timestamped backups
    └── [YYYYMMDD_HHMMSS]/
```

### AI Assistant Integration

Setup.sh adds this line to AI assistant config files:

```
Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.
```

**Files modified:**
- `~/.opencode/AGENTS.md`
- `~/.cursor/AGENTS.md`
- `~/.claude/AGENTS.md`
- `~/.config/cursor/AGENTS.md`

### OpenCode Configuration

Setup.sh updates `~/.config/opencode/opencode.json` agent paths to point to `~/.aidevops/agents/`.

**Backup created before modification.**

### Manual Configuration

If setup.sh doesn't support your AI assistant:

1. Add to your AI assistant's AGENTS.md or config:
   ```
   Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.
   ```

2. Point agent configurations to `~/.aidevops/agents/[agent].md`

### Updating

Re-run setup.sh after pulling updates:

```bash
cd ~/Git/aidevops
git pull
./setup.sh
```

Previous configs are backed up automatically.

### Troubleshooting

**"Command not found" errors:**
```bash
# Install missing dependencies
brew install jq curl  # macOS
apt-get install jq curl  # Ubuntu/Debian
```

**OpenCode not finding agents:**
- Check `~/.config/opencode/opencode.json` agent paths
- Verify `~/.aidevops/agents/` exists and contains files
- See `tools/opencode/opencode.md` for path details

**Permissions issues:**
```bash
# Ensure correct permissions
chmod 600 ~/.config/aidevops/mcp-env.sh
chmod 755 ~/.aidevops/agents/scripts/*.sh
```

## Future Enhancements

**Terminal UI** (planned): Interactive setup with options for:
- Selecting which AI assistants to configure
- Choosing which agents to deploy
- Custom configuration paths
- Visual progress indicators

For now, setup.sh runs all steps automatically. See the script source for customization.
