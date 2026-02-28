# High-Stakes Operations Taxonomy

Reference document defining which operations qualify as "high-stakes" and should
trigger parallel model verification before execution. Part of the multi-model
orchestration system (plan p035, task t1364.1).

## Purpose

Single-model AI agents can hallucinate destructive commands. Parallel model
verification catches these errors by having a second model (preferably from a
different provider) independently assess whether the proposed operation is safe
and correct. This taxonomy defines WHAT gets verified; the verification agent
(t1364.2) defines HOW.

**Design principle:** This taxonomy is guidance for AI agents, not a mechanical
regex filter. Agents use judgment to decide whether an operation matches a
category. The trigger patterns in `configs/verification-triggers.json` provide
machine-readable hints, but the agent's contextual understanding takes
precedence.

## Risk Levels

| Level | Policy | Description |
|-------|--------|-------------|
| **critical** | Always verify | Irreversible operations with production impact. Verification cannot be disabled per-repo. |
| **high** | Verify by default | Destructive or hard-to-reverse operations. Can be disabled per-repo via `.aidevops.json` or `repos.json`. |
| **medium** | Opt-in verification | Operations with moderate risk. Verification only when explicitly enabled per-repo. |

## Gate Behaviours

When verification is triggered, the system applies one of three gate behaviours:

| Gate | Behaviour | Use when |
|------|-----------|----------|
| **block** | Halt execution until verification passes. If the verifier disagrees, escalate to opus-tier or the user. | Critical operations where proceeding incorrectly is worse than waiting. |
| **warn** | Log the verification result and present it to the agent/user, but allow the operation to proceed. | High-risk operations where the operator has context the verifier may lack. |
| **log** | Record the operation and verification result silently. No interruption. | Medium-risk operations for audit trail and pattern detection. |

## Operation Categories

### Git Destructive Operations

**Risk level:** critical

Operations that rewrite history, destroy commits, or force-overwrite remote
state. These are irreversible once pushed.

| Operation | Example | Gate |
|-----------|---------|------|
| Force push | `git push --force`, `git push --force-with-lease` | block |
| Hard reset | `git reset --hard` | block |
| Branch deletion (remote) | `git push origin --delete`, `git branch -D` + push | block |
| History rewrite | `git rebase` on pushed commits, `git filter-branch` | block |
| Tag deletion (remote) | `git push --delete origin v1.0.0` | block |
| Submodule removal | `git submodule deinit`, `git rm <submodule>` | warn |

**Context signals:** Operating on `main`/`master`/`release/*` branches
increases severity. Force push to a personal feature branch is lower risk than
force push to main.

### Production Deployments

**Risk level:** critical

Operations that change what runs in production environments. Includes direct
deployments, infrastructure changes, and DNS modifications.

| Operation | Example | Gate |
|-----------|---------|------|
| Production deploy | `coolify deploy --env production`, `vercel --prod` | block |
| DNS changes | Modifying A/AAAA/CNAME records, nameserver changes | block |
| SSL/TLS certificate changes | Replacing or revoking certificates | block |
| Load balancer config | Changing routing rules, backend pools | block |
| Container orchestration | `docker stack deploy`, Kubernetes apply to prod | block |
| Rollback | `coolify rollback`, `vercel rollback` | warn |

**Context signals:** The word "production", "prod", or environment variables
like `NODE_ENV=production` are strong indicators. Staging/preview deployments
are lower risk.

### Data Migrations

**Risk level:** high

Operations that modify database schemas, move data between systems, or alter
stored data in ways that may be difficult to reverse.

| Operation | Example | Gate |
|-----------|---------|------|
| Schema migration (destructive) | `DROP TABLE`, `DROP COLUMN`, `ALTER TABLE ... DROP` | block |
| Bulk data modification | `UPDATE ... WHERE` affecting >1000 rows, `DELETE FROM` | block |
| Database restore/overwrite | Restoring a backup over a live database | block |
| Schema migration (additive) | `CREATE TABLE`, `ADD COLUMN` | warn |
| Data export/dump | `pg_dump`, `mysqldump` | log |
| Index changes | `CREATE INDEX`, `DROP INDEX` | log |

**Context signals:** Presence of `--production` flags, connection strings
pointing to production hosts, or migration files with "down" in the name
(rollback migrations that drop data).

### Security-Sensitive Changes

**Risk level:** high

Operations that affect authentication, authorization, encryption, or access
control. Mistakes here create vulnerabilities.

| Operation | Example | Gate |
|-----------|---------|------|
| Credential rotation | Changing API keys, passwords, tokens | warn |
| Permission/ACL changes | `chmod 777`, modifying IAM policies, RBAC rules | block |
| Firewall rule changes | Opening ports, modifying security groups | block |
| Encryption key management | Generating, rotating, or deleting encryption keys | block |
| Auth config changes | Modifying OAuth providers, SSO config, MFA settings | warn |
| Secret exposure risk | Committing `.env`, `credentials.json`, private keys | block |

**Context signals:** Files matching `*.pem`, `*.key`, `.env*`,
`credentials.*`, `secrets.*`. Commands containing `chmod`, `chown`, `iptables`,
`ufw`, `security-group`.

### Financial Operations

**Risk level:** high

Operations involving payment processing, billing, subscriptions, or financial
data. Errors can result in incorrect charges or revenue loss.

| Operation | Example | Gate |
|-----------|---------|------|
| Payment gateway config | Stripe/RevenueCat webhook URLs, API key changes | block |
| Pricing changes | Modifying product prices, subscription tiers | block |
| Refund processing | Issuing refunds, credits, adjustments | warn |
| Invoice generation | Creating or modifying invoice templates | warn |
| Financial report export | Exporting transaction data | log |

**Context signals:** Files in payment/billing directories, Stripe/RevenueCat
API calls, presence of currency amounts or price fields.

### Infrastructure Destruction

**Risk level:** critical

Operations that destroy or fundamentally alter infrastructure resources.

| Operation | Example | Gate |
|-----------|---------|------|
| Resource deletion | `terraform destroy`, `pulumi destroy` | block |
| Volume/disk deletion | Deleting persistent volumes, EBS volumes | block |
| Account/org changes | Deleting cloud accounts, changing org ownership | block |
| Backup deletion | Removing backup snapshots, retention policy changes | block |
| Network destruction | Deleting VPCs, subnets, peering connections | block |

**Context signals:** Terraform/Pulumi state files, `destroy` or `delete` in
infrastructure commands, cloud provider CLI commands with `--force` flags.

## Verification Policy Schema

Per-repo configuration lives in `.aidevops.json` at the repo root or in the
repo's entry in `~/.config/aidevops/repos.json`. The schema:

```json
{
  "verification": {
    "enabled": true,
    "default_gate": "warn",
    "overrides": {
      "git_destructive": { "gate": "block", "enabled": true },
      "production_deploy": { "gate": "block", "enabled": true },
      "data_migration": { "gate": "warn", "enabled": true },
      "security_sensitive": { "gate": "warn", "enabled": true },
      "financial": { "gate": "warn", "enabled": false },
      "infrastructure_destruction": { "gate": "block", "enabled": true }
    },
    "cross_provider": true,
    "verifier_tier": "sonnet",
    "escalation_tier": "opus"
  }
}
```

**Fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Master switch for verification in this repo. |
| `default_gate` | string | `"warn"` | Gate behaviour when no category-specific override exists. |
| `overrides` | object | `{}` | Per-category gate and enable/disable overrides. |
| `cross_provider` | boolean | `true` | Prefer a different provider for verification (e.g., Anthropic primary, Google verifier). |
| `verifier_tier` | string | `"sonnet"` | Model tier for the verification call. |
| `escalation_tier` | string | `"opus"` | Model tier when primary and verifier disagree. |

## Trigger Detection

The verification system detects high-stakes operations through three mechanisms:

1. **Command pattern matching** -- Regex patterns in
   `configs/verification-triggers.json` match against proposed shell commands
   and tool invocations.

2. **Context signals** -- Environmental indicators like branch name, file paths
   being modified, environment variables, and connection strings.

3. **Agent judgment** -- The AI agent's own assessment of whether an operation
   is high-stakes, based on the full context of the task. This is the most
   important mechanism and overrides pattern matching in both directions (an
   agent can flag an operation that doesn't match patterns, or clear one that
   does).

## Integration Points

- **pre-edit-check.sh** -- Sets `REQUIRES_VERIFICATION=1` when a high-stakes
  operation is detected via command patterns. The calling agent reads this flag.
- **Verification agent** (t1364.2) -- Receives the operation description and
  context, returns a verdict (proceed/warn/block).
- **Pipeline integration** (t1364.3) -- Wires verification into the dispatch
  and execution pipeline.

## Related Files

- `configs/verification-triggers.json` -- Machine-readable trigger patterns
- `scripts/pre-edit-check.sh` -- Branch protection and high-stakes detection
- `tools/context/model-routing.md` -- Model tier definitions
- `configs/model-routing-table.json` -- Provider/model resolution
- `reference/orchestration.md` -- Orchestration architecture
