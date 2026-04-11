---
description: Scan git history for security vulnerabilities introduced in past commits
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Scan git history for vulnerabilities introduced in past commits (audit, compliance, incident investigation).

Target: $ARGUMENTS

## Usage

```bash
./.agents/scripts/security-helper.sh history [scope]
```

**Scopes (from $ARGUMENTS):**
- Empty: last 50 commits (default)
- `N`: last N commits (e.g., `100`)
- `range`: explicit range (e.g., `abc123..def456`)
- `--since="YYYY-MM-DD"` / `--until="YYYY-MM-DD"`: date window
- `--author="email"`: author filter

## Common Invocations

```bash
/security-history --since="2024-01-01" --until="2024-03-31"  # compliance audit
/security-history abc123~10..abc123+10                        # incident investigation
/security-history --author="new-dev@example.com"              # team member audit
/security-history v1.0.0..HEAD                                # pre-release audit
```

## Process & Output

1. **Scan**: Run helper with resolved scope.
2. **Review Findings**: Includes severity, commit, author, file, description, and status (present/fixed).
3. **Assess Impact**: Check if still present in `HEAD`, if deployed, and what data/secrets were exposed.

## Remediation

- **Still present**: Fix in new commit, rotate secrets, check production reach, document incident.
- **Already fixed**: Verify fix completeness, confirm exposure, rotate if needed, capture lessons.

## Related Commands

- `/security-analysis` - Analyze current code
- `/security-scan` - Quick security check
- `/security-deps` - Dependency vulnerabilities
