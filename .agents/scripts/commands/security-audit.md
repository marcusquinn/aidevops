---
description: Comprehensive security audit of external repositories by URL
agent: Build+
mode: subagent
---

Perform a comprehensive security audit of an external repository.

Target: $ARGUMENTS

## Quick Reference

- **Purpose**: Full security audit of external repos by URL
- **Methodology**: `tools/code-review/security-audit.md`
- **Reuses**: `security-helper.sh` (secrets, deps, analysis), `secretlint-helper.sh`
- **Cleanup**: Cloned repos removed after audit

## Process

1. **Parse the target** from $ARGUMENTS:
   - GitHub URL (e.g., `https://github.com/owner/repo`)
   - GitLab URL, or any git-cloneable URL
   - If no URL provided, show usage and exit

2. **Read the full methodology**: Read `tools/code-review/security-audit.md` for the complete audit methodology, category definitions, and report template.

3. **Clone the repository**:

   ```bash
   AUDIT_DIR="$HOME/.aidevops/.agent-workspace/tmp/security-audit"
   mkdir -p "$AUDIT_DIR"
   REPO_NAME=$(basename "$REPO_URL" .git)
   CLONE_DIR="$AUDIT_DIR/$REPO_NAME"
   rm -rf "$CLONE_DIR"
   git clone --depth 1 "$REPO_URL" "$CLONE_DIR"
   ```

4. **Detect languages and frameworks** by checking for:
   - `Cargo.toml` / `Cargo.lock` (Rust)
   - `package.json` / `package-lock.json` (Node.js)
   - `requirements.txt` / `Pipfile` / `pyproject.toml` (Python)
   - `go.mod` / `go.sum` (Go)
   - `Dockerfile` / `docker-compose.yml` (Docker)
   - `.github/workflows/` (GitHub Actions)
   - `*.sh` files (Shell scripts)

5. **Run all applicable scans** from the methodology in `tools/code-review/security-audit.md`. Run scans in parallel where possible.

6. **Produce the structured report** using the template from the methodology.

7. **Clean up** the cloned repository:

   ```bash
   rm -rf "$CLONE_DIR"
   ```

## Output

Present the full audit report directly to the user in the conversation. The report follows the structured format defined in `tools/code-review/security-audit.md`.

## When to Use

- Evaluating third-party dependencies before adoption
- Security review of open-source projects
- Due diligence on external code
- Comparing security posture across projects

## Related Commands

- `/security-analysis` - Deep analysis of the current repo's code
- `/security-scan` - Quick secrets + vulnerability scan (current repo)
- `/security-deps` - Dependency vulnerability scan (current repo)
- `/security-history` - Git history scan (current repo)
