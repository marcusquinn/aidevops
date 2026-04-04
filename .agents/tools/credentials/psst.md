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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# psst - AI-Native Secret Manager Alternative

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Status**: documented alternative; `gopass` remains the default
- **Repo**: https://github.com/nicholasgasior/psst (61 stars, v0.3.0)
- **Install**: `bun install -g psst-cli`
- **Requires**: Bun runtime
- **Choose psst when**: you want the simplest solo setup, already use Bun, and do not need team sharing or an audit trail

| Feature | gopass (recommended) | psst |
|---------|----------------------|------|
| Maturity | 6.7k stars, 8+ years | 61 stars, v0.3.0 |
| Encryption | GPG/age (industry standard) | AES-256-GCM |
| Team sharing | Git sync + GPG recipients | No |
| Dependencies | Single Go binary | Bun runtime |
| AI-native | Via aidevops wrapper | Built-in |
| Audit trail | Git history | None |

**Recommendation**: prefer `gopass` for shared, long-lived, or compliance-sensitive secrets. Choose `psst` only when simplicity matters more than maturity, team workflows, and auditability.

<!-- AI-CONTEXT-END -->

## Installation

```bash
bun install -g psst-cli
```

## Usage

```bash
psst set MY_API_KEY
psst list
psst run MY_API_KEY -- curl https://api.example.com
```

## Why gopass remains the default

- Mature ecosystem (6.7k stars, 8+ years of development)
- GPG encryption (industry-standard, audited)
- Team sharing via git sync
- Single Go binary; no Bun runtime dependency
- Audit trail via git history
- `gopass audit` for breach detection

## Related

- `tools/credentials/gopass.md` -- Recommended encrypted backend
- `tools/credentials/api-key-setup.md` -- Plaintext credential setup
