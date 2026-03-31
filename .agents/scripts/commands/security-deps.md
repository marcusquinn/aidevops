---
description: Scan dependencies for known vulnerabilities using OSV database
agent: Build+
mode: subagent
---

Scan project dependencies for known vulnerabilities with OSV.

Target: $ARGUMENTS

## Quick Reference

- **Tool**: OSV-Scanner — CVEs and GHSAs via OSV.dev
- **Command**: `./.agents/scripts/security-helper.sh scan-deps`

## Process

1. Run `./.agents/scripts/security-helper.sh scan-deps`
2. Prioritize critical/high findings
3. For each finding, confirm the package is used, identify the fixed version, and assess upgrade risk
4. Update dependencies, test, then re-scan

## Supported Lockfiles

npm/Yarn/pnpm (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`), pip (`requirements.txt`, `Pipfile.lock`), Go (`go.mod`), Cargo (`Cargo.lock`), Composer (`composer.lock`), Maven (`pom.xml`), Gradle (`gradle.lockfile`).

## Options

```bash
/security-deps --format=json      # JSON output
/security-deps ./packages/api     # Specific directory
```

Recursive scan is enabled by default in `security-helper.sh`.

## Remediation

- Check compatibility before upgrading (`npm update <pkg>`, `yarn upgrade <pkg>`, `pip install --upgrade <pkg>`)
- Treat unfixable findings as triage work: document reachability, compensating controls, and follow-up

## CI Example

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
