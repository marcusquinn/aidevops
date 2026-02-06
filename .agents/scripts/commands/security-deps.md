---
description: Scan dependencies for known vulnerabilities using OSV database
agent: Build+
mode: subagent
---

Scan project dependencies for known vulnerabilities using the OSV (Open Source Vulnerabilities) database.

Target: $ARGUMENTS

## Quick Reference

- **Purpose**: Find vulnerable dependencies
- **Tool**: OSV-Scanner (Google's vulnerability scanner)
- **Database**: OSV.dev (aggregates CVEs, GHSAs, etc.)

## Process

1. **Run dependency scan**:

   ```bash
   ./.agents/scripts/security-helper.sh scan-deps
   ```

2. **Review findings** by severity

3. **For each vulnerability**:
   - Check if it affects your usage
   - Find fixed version
   - Assess upgrade risk

4. **Generate upgrade plan**

## Supported Package Managers

| Manager | Lockfile |
|---------|----------|
| npm/Yarn/pnpm | package-lock.json, yarn.lock, pnpm-lock.yaml |
| pip | requirements.txt, Pipfile.lock |
| Go | go.sum |
| Cargo | Cargo.lock |
| Composer | composer.lock |
| Maven/Gradle | pom.xml, build.gradle |

## Output Format

```text
Dependency Vulnerability Scan
=============================
Scanned: 245 packages
Vulnerabilities: 3 found

[HIGH] lodash@4.17.20
  CVE-2021-23337: Prototype pollution
  Fixed in: 4.17.21
  Upgrade: npm update lodash

[MEDIUM] axios@0.21.1
  CVE-2021-3749: ReDoS vulnerability
  Fixed in: 0.21.2
  Upgrade: npm update axios
```

## Options

Pass options via $ARGUMENTS:

```bash
# Recursive scan (monorepos)
/security-deps --recursive

# JSON output
/security-deps --format=json

# Specific directory
/security-deps ./packages/api
```

## Remediation Workflow

1. **Prioritize** by severity (critical/high first)
2. **Check compatibility** of newer versions
3. **Update** with appropriate command:

   ```bash
   # npm
   npm update <package>
   npm audit fix

   # yarn
   yarn upgrade <package>

   # pip
   pip install --upgrade <package>
   ```

4. **Test** after updates
5. **Re-scan** to verify fixes

## CI/CD Integration

Add to your pipeline:

```yaml
- name: Dependency Scan
  run: |
    ./.agents/scripts/security-helper.sh scan-deps --format=sarif > deps.sarif

- name: Upload SARIF
  uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: deps.sarif
```

## Related Commands

- `/security-analysis` - Full code security analysis
- `/security-scan` - Quick secrets + vulnerability scan
