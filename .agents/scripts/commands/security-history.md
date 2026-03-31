---
description: Scan git history for security vulnerabilities introduced in past commits
agent: Build+
mode: subagent
---

Scan git history for vulnerabilities introduced in past commits.

Target: $ARGUMENTS

## Quick Reference

- **Default scope**: last 50 commits
- **Scopes**: commit count, commit range, `--since`, `--until`, `--author`
- **Helper**: `./.agents/scripts/security-helper.sh history`
- **Use cases**: audit, compliance, incident investigation

## Process

1. **Resolve scope** from `$ARGUMENTS`:
   - Empty → last 50 commits
   - Number (for example `100`) → last N commits
   - Range (for example `abc123..def456`) → explicit commit range
   - `--since="2024-01-01"` / `--until="2024-03-31"` → date window
   - `--author="email"` → author filter
2. **Run the history scan**:

   ```bash
   ./.agents/scripts/security-helper.sh history              # default: last 50
   ./.agents/scripts/security-helper.sh history 100           # last N
   ./.agents/scripts/security-helper.sh history abc123..def456 # range
   ./.agents/scripts/security-helper.sh history --since="2024-01-01"
   ```

3. **Review each finding** with commit, author, file, severity, and whether it is still present in `HEAD`.
4. **Assess impact**: is it still present, was it deployed, and what data or secrets may have been exposed?

## Output

Each finding includes severity, commit, author, file, issue description, and current status (still present or fixed in which commit).

## Common Invocations

```bash
/security-history --since="2024-01-01" --until="2024-03-31"  # compliance audit
/security-history abc123~10..abc123+10                        # incident investigation
/security-history --author="new-dev@example.com"              # team member audit
/security-history v1.0.0..HEAD                                # pre-release audit
```

## Remediation

**Still present:** fix in a new commit, rotate exposed secrets, check whether it reached production, and document the incident.

**Already fixed:** verify the fix is complete, confirm whether secrets were exposed, rotate if needed, and capture the lesson learned.

## Related Commands

- `/security-analysis` - Analyze current code
- `/security-scan` - Quick security check
- `/security-deps` - Dependency vulnerabilities
