---
description: Scan dependencies for known vulnerabilities using OSV database
agent: Build+
mode: subagent
---

Scan dependency lockfiles for known vulnerabilities with OSV.

Target: $ARGUMENTS

## Command

- Tool: OSV-Scanner via OSV.dev (CVEs, GHSAs)
- Run: `./.agents/scripts/security-helper.sh scan-deps`
- Scope: pass a directory path (for example `/security-deps ./packages/api`)
- Output: add `--format=json` for machine-readable results
- Recursive scan is enabled by default in `security-helper.sh`

## Workflow

1. Run `./.agents/scripts/security-helper.sh scan-deps`
2. Triage critical/high findings first
3. For each finding, confirm the package is used, identify the fixed version, and assess upgrade risk
4. Upgrade, test, and re-scan
5. If no fix exists, document reachability, compensating controls, and follow-up

## Supported Lockfiles

npm/Yarn/pnpm (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`), pip (`requirements.txt`, `Pipfile.lock`), Go (`go.mod`), Cargo (`Cargo.lock`), Composer (`composer.lock`), Maven (`pom.xml`), and Gradle (`gradle.lockfile`).

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
