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

- **Status**: Documented alternative (gopass is recommended primary)
- **Repo**: https://github.com/nicholasgasior/psst (61 stars, v0.3.0)
- **Install**: `bun install -g psst-cli`
- **Requires**: Bun runtime

**Trade-offs vs gopass**:

| Feature | gopass (recommended) | psst |
|---------|---------------------|------|
| Maturity | 6.7k stars, 8+ years | 61 stars, v0.3.0 |
| Encryption | GPG/age (industry standard) | AES-256-GCM |
| Team sharing | Git sync + GPG recipients | No |
| Dependencies | Single Go binary | Bun runtime |
| AI-native | Via aidevops wrapper | Built-in |
| Audit trail | Git history | None |

<!-- AI-CONTEXT-END -->

## When to Use psst

- Solo developer who wants simplest possible setup
- Already using Bun in your stack
- Don't need team sharing or audit trail
- Prefer AI-native design over established tooling

## Installation

```bash
# Requires Bun
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

For most users, **gopass is recommended** over psst because:

1. Mature ecosystem (6.7k stars, 8+ years of development)
2. GPG encryption (industry-standard, audited)
3. Team sharing via git sync
4. Zero runtime dependencies (single Go binary)
5. Audit trail via git history
6. `gopass audit` for breach detection

Use psst only if you specifically prefer its simplicity and don't need team features.

## Related

- `tools/credentials/gopass.md` -- Recommended encrypted backend
- `tools/credentials/api-key-setup.md` -- Plaintext credential setup
