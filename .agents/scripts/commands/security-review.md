# /security-review

Review quarantined security items and provide feedback to improve detection accuracy.

## What it does

Presents a digest of ambiguous security items that were flagged but not automatically blocked. These items come from:

- **prompt-guard-helper.sh** — WARN-level prompt injection detections (below block threshold)
- **network-tier-helper.sh** — Tier 4 unknown domains (allowed but flagged)
- **sandbox-exec-helper.sh** — Tier 5 denied domains from sandbox pre-checks
- **mcp-audit** — MCP tool descriptions with ambiguous injection patterns

Each item can be reviewed and a decision applied that feeds back into the security configuration, creating a self-improving feedback loop.

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
| `allow` | Add domain to Tier 3 (known tools, allowed + logged) | `~/.config/aidevops/network-tiers-custom.conf` |
| `deny` | Add domain to Tier 5 (blocked) or pattern to prompt guard deny list | `network-tiers-custom.conf` (for network-tier/sandbox-exec sources) or `prompt-guard-custom.txt` (for prompt-guard/mcp-audit sources) |
| `trust` | Add MCP server to trusted list | `~/.config/aidevops/mcp-trusted-servers.txt` |
| `dismiss` | Mark as false positive, no config change | None (recorded in reviewed.jsonl) |

## Feedback loop

Each review decision improves future accuracy:

1. **allow** decisions add domains to Tier 3, so future access to that domain is logged but not flagged
2. **deny** decisions add domains to Tier 5 (blocked) or patterns to the prompt guard custom deny list
3. **trust** decisions whitelist MCP servers so their tool descriptions are not flagged
4. **dismiss** decisions are recorded as false positives — the `stats` command tracks the false positive rate

Over time, the quarantine queue shrinks as the system learns which domains, patterns, and servers are legitimate vs malicious.

## Queue files

- **Pending**: `~/.aidevops/.agent-workspace/security/quarantine/pending.jsonl`
- **Reviewed**: `~/.aidevops/.agent-workspace/security/quarantine/reviewed.jsonl`

## When to run

- After a batch of headless worker sessions (pulse/dispatch)
- When the quarantine queue has accumulated items (check with `quarantine-helper.sh stats`)
- As part of a periodic security review cadence

## Related

- `prompt-guard-helper.sh` — Prompt injection detection
- `network-tier-helper.sh` — Network domain tiering
- `sandbox-exec-helper.sh` — Execution sandboxing
- `tools/security/prompt-injection-defender.md` — Security architecture
