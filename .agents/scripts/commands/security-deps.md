---
description: Scan dependencies for known vulnerabilities using OSV database
agent: Build+
mode: subagent
---

Scan project dependencies for known vulnerabilities using the OSV (Open Source Vulnerabilities) database.

Target: $ARGUMENTS

## Quick Reference

- **Tool**: OSV-Scanner (Google) — aggregates CVEs, GHSAs via OSV.dev
- **Command**: `./.agents/scripts/security-helper.sh scan-deps`

## Process

1. Run scan: `./.agents/scripts/security-helper.sh scan-deps`
2. Review findings by severity
3. For each vulnerability: check if it affects usage, find fixed version, assess upgrade risk
4. Generate upgrade plan

## Supported Lockfiles

npm/Yarn/pnpm (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`), pip (`requirements.txt`, `Pipfile.lock`), Go (`go.mod`), Cargo (`Cargo.lock`), Composer (`composer.lock`), Maven (`pom.xml`), Gradle (`gradle.lockfile`).

## Options

```bash
/security-deps --format=json      # JSON output
/security-deps ./packages/api     # Specific directory
```

Recursive scan is enabled by default (hardcoded in `security-helper.sh`).

## Remediation

1. Prioritize critical/high severity first
2. Check compatibility, then update (`npm update <pkg>`, `yarn upgrade <pkg>`, `pip install --upgrade <pkg>`)
3. Test after updates
4. Re-scan to verify fixes

## CI/CD Integration

```yaml
- name: Dependency Scan
  run: |
    ./.agents/scripts/security-helper.sh scan-deps --format=sarif > deps.sarif

- name: Upload SARIF
  uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: deps.sarif
```

## Related

- `/security-analysis` — full code security analysis
- `/security-scan` — quick secrets + vulnerability scan
