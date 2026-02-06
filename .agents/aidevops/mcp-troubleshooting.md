---
description: Quick troubleshooting for MCP connection issues
mode: subagent
tools:
  read: true
  bash: true
  glob: true
  grep: true
---

# MCP Troubleshooting Quick Reference

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Diagnose and fix MCP connection failures
- **Scripts**: `mcp-diagnose.sh`, `tool-version-check.sh`
- **Common cause**: Version mismatch (outdated tool with changed MCP command)

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| "Config file is invalid" | Unrecognized key in config | Remove unsupported keys (see below) |
| "Connection closed" | Wrong command or outdated version | Update tool, check command syntax |
| "Command not found" | Tool not installed | `npm install -g {package}` |
| "Permission denied" | Missing credentials | Check `~/.config/aidevops/credentials.sh` |
| "Timeout" | Server not starting | Check Node.js version, run manually |
| "unauthorized" | HTTP server instead of MCP | Use correct MCP command (not serve) |

### Config Validation Errors

If you see `Unrecognized key: "xxx"`, OpenCode doesn't support that config key.

**Common unsupported keys**:

- `workdir` - Not supported in OpenCode MCP config
- `cwd` - Use shell wrapper instead: `["/bin/bash", "-c", "cd /path && command"]`
- `env` - Use `environment` instead

**Fix**: Edit `~/.config/opencode/opencode.json` and remove the unsupported key.

## Diagnostic Commands

```bash
# Full diagnosis for specific MCP
~/.aidevops/agents/scripts/mcp-diagnose.sh <mcp-name>

# Check all tool versions
~/.aidevops/agents/scripts/tool-version-check.sh

# Update outdated tools
~/.aidevops/agents/scripts/tool-version-check.sh --update

# Verify MCP status in OpenCode
opencode mcp list
```

<!-- AI-CONTEXT-END -->

## Version-Specific Issues

### osgrep

| Version | MCP Command | Notes |
|---------|-------------|-------|
| v0.4.x | `osgrep serve` | HTTP server, NOT MCP-compatible |
| v0.5.x | `osgrep mcp` | Native MCP support |

**Fix**: Update to v0.5+ and run `osgrep install-opencode`

```bash
npm update -g osgrep
osgrep install-opencode
```

### augment-context-engine

| Issue | Solution |
|-------|----------|
| "unauthorized" | Run `auggie login` first |
| Session expired | Re-run `auggie login` |

**Correct command**: `["auggie", "--mcp"]`

### context7

Context7 is a remote MCP - no local installation needed.

**Correct config**:

```json
{
  "context7": {
    "type": "remote",
    "url": "https://mcp.context7.com/mcp",
    "enabled": true
  }
}
```

## Diagnostic Workflow

1. **Check MCP status**:

   ```bash
   opencode mcp list
   ```

2. **If "failed" or "Connection closed"**:

   ```bash
   ~/.aidevops/agents/scripts/mcp-diagnose.sh <mcp-name>
   ```

3. **Check for updates**:

   ```bash
   ~/.aidevops/agents/scripts/tool-version-check.sh
   ```

4. **Update if needed**:

   ```bash
   npm update -g <package>
   ```

5. **Re-verify**:

   ```bash
   opencode mcp list
   ```

## OpenCode Config Location

- **Config file**: `~/.config/opencode/opencode.json`
- **Tool shims**: `~/.config/opencode/tool/`
- **Agent configs**: `~/.config/opencode/agent/`

## Manual MCP Testing

Test MCP command directly (should output JSON-RPC):

```bash
# osgrep
osgrep mcp

# augment
auggie --mcp

# Most MCPs
<tool> serve
```

If it outputs HTTP server info instead of JSON-RPC, you're using the wrong command.

## Related Documentation

- [add-new-mcp-to-aidevops.md](add-new-mcp-to-aidevops.md) - MCP setup workflow
- [tools/opencode/opencode.md](../tools/opencode/opencode.md) - OpenCode configuration
- [troubleshooting.md](troubleshooting.md) - General troubleshooting
