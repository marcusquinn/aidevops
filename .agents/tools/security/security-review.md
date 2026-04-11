<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# /security-review

Review quarantined security items and apply learn actions to update the security config. Run after headless worker batches or when `quarantine-helper.sh stats` shows pending items.

## Sources

Ambiguous items flagged but not auto-blocked:

- **prompt-guard-helper.sh** — WARN-level prompt injection detections
- **network-tier-helper.sh** — Tier 4 unknown domains allowed but flagged
- **sandbox-exec-helper.sh** — Tier 5 denied domains from sandbox pre-checks
- **mcp-audit** — MCP tool descriptions with ambiguous injection patterns

## Learn actions

| Action | Effect | Config file |
|--------|--------|-------------|
| `allow` | Add domain to Tier 3 (known tools, allowed + logged) | `~/.config/aidevops/network-tiers-custom.conf` |
| `deny` | Add domain to Tier 5 (blocked) or pattern to prompt guard deny list | `network-tiers-custom.conf` or `prompt-guard-custom.txt` |
| `trust` | Add MCP server to trusted list | `~/.config/aidevops/mcp-trusted-servers.txt` |
| `dismiss` | Mark as false positive, no config change | `reviewed.jsonl` |

## Usage

```bash
# View queue (~/.aidevops/.agent-workspace/security/quarantine/{pending,reviewed}.jsonl)
quarantine-helper.sh digest                                    # full digest
quarantine-helper.sh digest --source network-tier              # filter by source
quarantine-helper.sh digest --source prompt-guard --severity MEDIUM
quarantine-helper.sh list --last 10

# Apply a decision
quarantine-helper.sh learn <item-id> allow                     # Tier 3 (known tools)
quarantine-helper.sh learn <item-id> deny                      # Tier 5 or deny list
quarantine-helper.sh learn <item-id> trust                     # trusted MCP server
quarantine-helper.sh learn <item-id> dismiss                   # false positive
quarantine-helper.sh learn <item-id> allow --value api.example.com

# Stats and maintenance
quarantine-helper.sh stats
quarantine-helper.sh purge --older-than 60 --reviewed-only
```

## Related

- `prompt-guard-helper.sh` — Prompt injection detection
- `network-tier-helper.sh` — Network domain tiering
- `sandbox-exec-helper.sh` — Execution sandboxing
- `tools/security/prompt-injection-defender.md` — Security architecture
