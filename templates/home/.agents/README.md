# AI Agent Working Directory

**DEPRECATED: This location is being phased out.**

The aidevops framework now uses `~/.aidevops/` for all working files.

## New Structure

```text
~/.aidevops/
├── agents/                    # Agent files (deployed from repo)
├── .agent-workspace/          # Your working files
│   ├── work/[project]/        # Persistent project files
│   ├── tmp/session-*/         # Temporary session files
│   └── memory/                # Cross-session patterns
└── config-backups/            # Configuration backups
```

## Migration

Run `setup.sh` from the aidevops repository to deploy to the new location:

```bash
cd ~/Git/aidevops
./setup.sh
```

## Credential Storage

Credentials remain in `~/.config/aidevops/mcp-env.sh` (600 permissions).

---
**Repository**: https://github.com/marcusquinn/aidevops
