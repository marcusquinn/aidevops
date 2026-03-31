---
description: psst - AI-native secret manager alternative to gopass
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

# psst - AI-Native Secret Manager (Alternative)

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Status**: Documented alternative; `gopass` remains the default recommendation
- **Repo**: https://github.com/nicholasgasior/psst (61 stars, v0.3.0)
- **Install**: `bun install -g psst-cli`
- **Requires**: Bun runtime
- **Use psst when**: you want the simplest solo setup, already use Bun, and do not need team sharing or an audit trail

| Feature | gopass (recommended) | psst |
|---------|----------------------|------|
| Maturity | 6.7k stars, 8+ years | 61 stars, v0.3.0 |
| Encryption | GPG/age (industry standard) | AES-256-GCM |
| Team sharing | Git sync + GPG recipients | No |
| Dependencies | Single Go binary | Bun runtime |
| AI-native | Via aidevops wrapper | Built-in |
| Audit trail | Git history | None |

<!-- AI-CONTEXT-END -->

## Installation

```bash
bun install -g psst-cli
```

## Usage

```bash
# Store a secret
psst set MY_API_KEY

# List secrets (names only)
psst list

# Use in subprocess (AI-safe)
psst run MY_API_KEY -- curl https://api.example.com
```

## Recommendation

Prefer `gopass` for most aidevops setups:

- Mature ecosystem (6.7k stars, 8+ years of development)
- GPG encryption (industry-standard, audited)
- Team sharing via git sync
- Zero runtime dependencies (single Go binary)
- Audit trail via git history
- `gopass audit` for breach detection

Choose psst only when simplicity matters more than maturity, team workflows, and auditability.

## Related

- `tools/credentials/gopass.md` -- Recommended encrypted backend
- `tools/credentials/api-key-setup.md` -- Plaintext credential setup
