---
description: Scan git history for security vulnerabilities introduced in past commits
agent: Build+
mode: subagent
---

Scan git history for security vulnerabilities in past commits.

Target: $ARGUMENTS

## Quick Reference

- **Purpose**: Find vulnerabilities in historical commits
- **Use case**: Audit, compliance, incident investigation
- **Default**: Last 50 commits

## Process

1. **Determine scope** from $ARGUMENTS:
   - Empty → last 50 commits
   - Number (e.g., `100`) → last N commits
   - Range (e.g., `abc123..def456`) → specific commit range
   - `--since="2024-01-01"` → commits since date
   - `--author="email"` → commits by author

2. **Run history scan**:

   ```bash
   ./.agents/scripts/security-helper.sh history              # default: last 50
   ./.agents/scripts/security-helper.sh history 100           # last N
   ./.agents/scripts/security-helper.sh history abc123..def456 # range
   ./.agents/scripts/security-helper.sh history --since="2024-01-01"
   ```

3. **Review findings** with commit context

4. **Assess impact**: still present? deployed to production? data exposed?

## Output Format

Each finding includes severity, commit, author, file, issue description, and current status (still present or fixed in which commit).

## Use Cases

```bash
/security-history --since="2024-01-01" --until="2024-03-31"  # compliance audit
/security-history abc123~10..abc123+10                        # incident investigation
/security-history --author="new-dev@example.com"              # team member audit
/security-history v1.0.0..HEAD                                # pre-release audit
```

## Remediation

**Still present:** create fix, rotate exposed secrets, check if deployed, document in incident log.

**Already fixed:** verify fix completeness, rotate secrets if exposed, add to lessons learned.

## Related Commands

- `/security-analysis` — analyze current code
- `/security-scan` — quick security check
- `/security-deps` — dependency vulnerabilities
