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

- **Scripts**: `mcp-diagnose.sh check-all`, `tool-version-check.sh`
- **Common cause**: Version mismatch (outdated tool with changed MCP command)
- **Config**: `~/.config/opencode/opencode.json`

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| "Config file is invalid" | Unsupported key (`workdir`, `cwd`, `env`) | Remove key; use `environment` instead of `env`; wrap `cwd` as `["/bin/bash", "-c", "cd /path && cmd"]` |
| "Connection closed" | Wrong command or outdated version | Update tool, check command syntax |
| "Command not found" | Tool not installed | `npm install -g {package}` |
| "Permission denied" | Missing credentials | Check `~/.config/aidevops/credentials.sh` |
| "Timeout" | Server not starting | Check Node.js version, run command manually |
| "unauthorized" | HTTP server instead of MCP | Use correct MCP command (not `serve`) |

## Errored Servers — Dead Tool Schemas (t1682)

When an MCP server fails to start, its tool schemas remain in the tool list. Every call returns "MCP error -32000: Connection closed", wasting context tokens.

```bash
# Detect errored servers
~/.aidevops/agents/scripts/mcp-diagnose.sh check-all

# Disable persistently errored server (removes schemas from context)
# In ~/.config/opencode/opencode.json:
{ "playwright": { "enabled": false } }
# Restart runtime to reload tool list.
```

**Agent rule:** On "MCP error -32000" or "Connection closed", mark that server unavailable for the session — do not retry. See `prompts/build.txt` "Errored MCP Server Guard".

## Diagnostic Commands

```bash
~/.aidevops/agents/scripts/mcp-diagnose.sh check-all   # scan all servers (t1682)
~/.aidevops/agents/scripts/mcp-diagnose.sh <mcp-name>  # diagnose specific MCP
~/.aidevops/agents/scripts/tool-version-check.sh        # check versions
~/.aidevops/agents/scripts/tool-version-check.sh --update  # update outdated tools
opencode mcp list                                        # verify MCP status
```

<!-- AI-CONTEXT-END -->

## Version-Specific Issues

### augment-context-engine

| Issue | Solution |
|-------|----------|
| "unauthorized" | Run `auggie login` first |
| Session expired | Re-run `auggie login` |

**Correct command**: `["auggie", "--mcp"]`

### context7

Remote MCP — no local installation needed.

```json
{ "context7": { "type": "remote", "url": "https://mcp.context7.com/mcp", "enabled": true } }
```

## Manual MCP Testing

Run the MCP command directly — it should output JSON-RPC, not HTTP server info:

```bash
auggie --mcp   # augment
<tool> serve   # most MCPs
```

## Related

- [add-new-mcp-to-aidevops.md](add-new-mcp-to-aidevops.md) — MCP setup workflow
- [tools/opencode/opencode.md](../tools/opencode/opencode.md) — OpenCode configuration
- [troubleshooting.md](troubleshooting.md) — General troubleshooting
