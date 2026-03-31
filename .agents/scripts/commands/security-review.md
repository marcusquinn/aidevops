# /security-review

Review ambiguous security items that were flagged but not auto-blocked, then feed the decision back into the security config.

## Review sources

- `prompt-guard-helper.sh` — WARN-level prompt injection detections below the block threshold
- `network-tier-helper.sh` — Tier 4 unknown domains that were allowed but flagged
- `sandbox-exec-helper.sh` — Tier 5 denied domains from sandbox pre-checks
- `mcp-audit` — MCP tool descriptions with ambiguous injection patterns

## Usage

```bash
# Show the full digest
quarantine-helper.sh digest

# Filter by source
quarantine-helper.sh digest --source network-tier

# Filter by severity
quarantine-helper.sh digest --source prompt-guard --severity MEDIUM

# Quick list view
quarantine-helper.sh list
quarantine-helper.sh list --last 10

# Apply a decision
quarantine-helper.sh learn <item-id> allow   # Add domain to Tier 3 (known tools)
quarantine-helper.sh learn <item-id> deny    # Add to Tier 5 or prompt-guard deny list
quarantine-helper.sh learn <item-id> trust   # Add MCP server to trusted list
quarantine-helper.sh learn <item-id> dismiss # False positive, no action

# With explicit value
quarantine-helper.sh learn <item-id> allow --value api.legitimate-tool.com

# View statistics
quarantine-helper.sh stats

# Maintenance
quarantine-helper.sh purge --older-than 60 --reviewed-only
```

## Learn actions

| Action | Effect | Config file modified |
|--------|--------|---------------------|
| `allow` | Add domain to Tier 3 so future access is allowed and logged | `~/.config/aidevops/network-tiers-custom.conf` |
| `deny` | Add a domain to Tier 5 or a pattern to the prompt-guard deny list | `~/.config/aidevops/network-tiers-custom.conf` (network-tier / sandbox-exec) or `~/.config/aidevops/prompt-guard-custom.txt` (prompt-guard / mcp-audit) |
| `trust` | Add an MCP server to the trusted list | `~/.config/aidevops/mcp-trusted-servers.txt` |
| `dismiss` | Mark as false positive without config changes; recorded in `reviewed.jsonl` | None |

## Effect of each decision

1. `allow` reduces repeat noise for legitimate domains.
2. `deny` blocks known-bad domains or prompt patterns.
3. `trust` suppresses false positives from approved MCP servers.
4. `dismiss` records false positives so `quarantine-helper.sh stats` can track accuracy.

Over time, the quarantine queue shrinks as the system learns which domains, patterns, and servers are legitimate.

## Queue files

- Pending: `~/.aidevops/.agent-workspace/security/quarantine/pending.jsonl`
- Reviewed: `~/.aidevops/.agent-workspace/security/quarantine/reviewed.jsonl`

## Run when

- After headless worker batches (`pulse` / dispatch)
- When `quarantine-helper.sh stats` shows queue growth
- During periodic security review

## Related

- `prompt-guard-helper.sh` — prompt injection detection
- `network-tier-helper.sh` — network domain tiering
- `sandbox-exec-helper.sh` — execution sandboxing
- `tools/security/prompt-injection-defender.md` — security architecture
