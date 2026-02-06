---
description: Scan git history for security vulnerabilities introduced in past commits
agent: Build+
mode: subagent
---

Scan git history for security vulnerabilities that may have been introduced in past commits.

Target: $ARGUMENTS

## Quick Reference

- **Purpose**: Find vulnerabilities in historical commits
- **Use case**: Audit, compliance, incident investigation
- **Default**: Last 50 commits

## Process

1. **Determine scope** from $ARGUMENTS:
   - Empty → Last 50 commits
   - Number (e.g., `100`) → Last N commits
   - Range (e.g., `abc123..def456`) → Specific commit range
   - `--since="2024-01-01"` → Commits since date
   - `--author="email"` → Commits by author

2. **Run history scan**:

   ```bash
   # Last 50 commits (default)
   ./.agents/scripts/security-helper.sh history

   # Last 100 commits
   ./.agents/scripts/security-helper.sh history 100

   # Specific range
   ./.agents/scripts/security-helper.sh history abc123..def456

   # Since date
   ./.agents/scripts/security-helper.sh history --since="2024-01-01"
   ```

3. **Review findings** with commit context

4. **Assess impact**:
   - Is the vulnerability still present?
   - Was it ever deployed to production?
   - What data may have been exposed?

## Output Format

```text
Git History Security Scan
=========================
Scanned: 50 commits
Vulnerabilities: 2 found

[HIGH] Commit abc1234 (2024-01-15)
  Author: developer@example.com
  Message: Add user authentication
  File: src/auth/login.ts:45
  Issue: Hardcoded API key introduced
  Status: Still present in HEAD

[MEDIUM] Commit def5678 (2024-01-10)
  Author: developer@example.com
  Message: Add database queries
  File: src/db/users.ts:23
  Issue: SQL injection vulnerability
  Status: Fixed in commit ghi9012
```

## Use Cases

### Compliance Audit

```bash
# Scan all commits in the last quarter
/security-history --since="2024-01-01" --until="2024-03-31"
```

### Incident Investigation

```bash
# Scan commits around suspected breach
/security-history abc123~10..abc123+10
```

### New Team Member Audit

```bash
# Review commits by specific author
/security-history --author="new-dev@example.com"
```

### Pre-Release Audit

```bash
# Scan all commits since last release
/security-history v1.0.0..HEAD
```

## Remediation

For vulnerabilities still present:

1. **Create fix** in new commit
2. **Consider** if secrets need rotation
3. **Check** if vulnerability was deployed
4. **Document** in security incident log

For historical vulnerabilities (already fixed):

1. **Verify** fix is complete
2. **Check** if secrets were exposed (rotate if needed)
3. **Add** to lessons learned

## Related Commands

- `/security-analysis` - Analyze current code
- `/security-scan` - Quick security check
- `/security-deps` - Dependency vulnerabilities
