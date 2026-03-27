# High-Stakes Operations Taxonomy

Defines which operations trigger parallel model verification (p035, t1364.1).
This taxonomy defines WHAT gets verified; the verification agent (t1364.2)
defines HOW. Agent judgment overrides pattern matching in both directions.
Machine-readable hints: `configs/verification-triggers.json`.

## Risk Levels

| Level | Policy | Description |
|-------|--------|-------------|
| **critical** | Always verify | Irreversible, production impact. Cannot be disabled per-repo. |
| **high** | Verify by default | Destructive or hard-to-reverse. Disable per-repo via `.aidevops.json` or `repos.json`. |
| **medium** | Opt-in | Moderate risk. Verify only when explicitly enabled per-repo. |

## Gate Behaviours

| Gate | Behaviour | Use when |
|------|-----------|----------|
| **block** | Halt until verification passes; escalate on disagreement | Proceeding incorrectly is worse than waiting |
| **warn** | Log result, allow operation to proceed | Operator has context verifier may lack |
| **log** | Record silently, no interruption | Audit trail and pattern detection |

## Operation Categories

### Git Destructive (critical)

| Operation | Example | Gate |
|-----------|---------|------|
| Force push | `git push --force`, `--force-with-lease` | block |
| Hard reset | `git reset --hard` | block |
| Remote branch/tag deletion | `git push origin --delete`, `git push --delete origin v1.0.0` | block |
| History rewrite | `git rebase` on pushed commits, `git filter-branch` | block |
| Submodule removal | `git submodule deinit`, `git rm <submodule>` | warn |

**Signals:** `main`/`master`/`release/*` increases severity. Feature branch force-push is lower risk.

### Production Deployments (critical)

| Operation | Example | Gate |
|-----------|---------|------|
| Production deploy | `coolify deploy --env production`, `vercel --prod` | block |
| DNS changes | A/AAAA/CNAME records, nameserver changes | block |
| SSL/TLS, load balancer | Certificate replacement, routing rules, backend pools | block |
| Container orchestration | `docker stack deploy`, Kubernetes apply to prod | block |
| Rollback | `coolify rollback`, `vercel rollback` | warn |

**Signals:** "production"/"prod", `NODE_ENV=production`. Staging/preview is lower risk.

### Data Migrations (high)

| Operation | Example | Gate |
|-----------|---------|------|
| Destructive schema change | `DROP TABLE`, `DROP COLUMN`, `ALTER TABLE ... DROP` | block |
| Bulk data modification | `UPDATE`/`DELETE` affecting >1000 rows | block |
| Database restore/overwrite | Restoring backup over live database | block |
| Additive schema change | `CREATE TABLE`, `ADD COLUMN` | warn |
| Data export, index changes | `pg_dump`, `mysqldump`, `CREATE/DROP INDEX` | log |

**Signals:** `--production` flags, production connection strings, "down" migration files.

### Security-Sensitive (high)

| Operation | Example | Gate |
|-----------|---------|------|
| Permission/ACL changes | `chmod 777`, IAM policies, RBAC rules | block |
| Firewall rule changes | Opening ports, security groups | block |
| Encryption key management | Generating, rotating, or deleting keys | block |
| Secret exposure risk | Committing `.env`, `credentials.json`, private keys | block |
| Credential rotation, auth config | API keys, OAuth providers, SSO, MFA settings | warn |

**Signals:** `*.pem`, `*.key`, `.env*`, `credentials.*`, `secrets.*`; `chmod`, `iptables`, `ufw`.

### Financial Operations (high)

| Operation | Example | Gate |
|-----------|---------|------|
| Payment gateway config | Stripe/RevenueCat webhook URLs, API key changes | block |
| Pricing changes | Product prices, subscription tiers | block |
| Refund processing | Refunds, credits, adjustments | warn |
| Invoice generation | Creating/modifying invoice templates | warn |
| Financial report export | Exporting transaction data | log |

**Signals:** Payment/billing directories, Stripe/RevenueCat API calls, currency/price fields.

### Infrastructure Destruction (critical)

| Operation | Example | Gate |
|-----------|---------|------|
| Resource deletion | `terraform destroy`, `pulumi destroy` | block |
| Volume/disk deletion | Persistent volumes, EBS volumes | block |
| Account/org changes | Deleting cloud accounts, changing org ownership | block |
| Backup deletion | Removing snapshots, retention policy changes | block |
| Network destruction | Deleting VPCs, subnets, peering connections | block |

**Signals:** Terraform/Pulumi state files, `destroy`/`delete` in infra commands, `--force` flags.

## Verification Policy Schema

Per-repo config in `.aidevops.json` (repo root) or `repos.json` entry:

```json
{
  "verification": {
    "enabled": true,              // master switch (default: true)
    "default_gate": "warn",       // fallback when no category override
    "overrides": {                // per-category: { "gate": "block"|"warn"|"log", "enabled": bool }
      "git_destructive":            { "gate": "block", "enabled": true },
      "production_deploy":          { "gate": "block", "enabled": true },
      "data_migration":             { "gate": "warn",  "enabled": true },
      "security_sensitive":         { "gate": "warn",  "enabled": true },
      "financial":                  { "gate": "warn",  "enabled": false },
      "infrastructure_destruction": { "gate": "block", "enabled": true }
    },
    "cross_provider": true,       // prefer different provider for verifier
    "verifier_tier": "sonnet",    // model tier for verification
    "escalation_tier": "opus"     // model tier when primary + verifier disagree
  }
}
```

## Trigger Detection

Detection priority: (1) **agent judgment** (overrides all), (2) **context signals** (branch, paths, env vars), (3) **command patterns** (`configs/verification-triggers.json`).

## Related

- `scripts/pre-edit-check.sh` -- sets `REQUIRES_VERIFICATION=1`
- Verification agent (t1364.2) -- verdict; pipeline (t1364.3) -- dispatch wiring
- `configs/verification-triggers.json`, `configs/model-routing-table.json`
- `tools/context/model-routing.md`, `reference/orchestration.md`
