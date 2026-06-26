---
description: Encryption stack overview - gopass, SOPS, and gocryptfs decision guide
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Encryption Stack Overview

<!-- AI-CONTEXT-START -->

## Quick Reference

Use the smallest tool that fits the problem:

1. Single secret → `aidevops secret set NAME`
2. Structured file you must commit → `sops-helper.sh encrypt file.enc.yaml`
3. Sensitive directory at rest → `gocryptfs-helper.sh create vault-name`
4. Framework-wide protected data policy → `reference/vault.md`

| Tool | Best for | Scope | Git-safe | AI-safe | Docs |
|------|----------|-------|----------|---------|------|
| **gopass** | API keys, tokens, passwords | Per secret | No (separate store) | Yes (subprocess injection) | `tools/credentials/gopass.md` |
| **SOPS** | Structured config files with secrets | Per file | Yes (encrypted in repo) | Yes (stdout only) | `tools/credentials/sops.md` |
| **gocryptfs** | Sensitive directories at rest | Per directory | No (filesystem overlay) | Yes (mount/unmount) | `tools/credentials/gocryptfs.md` |
| **Vault RFC** | Protected data classes, routing, trust, sync, audit | Framework-wide | Policy-dependent | Provider-gated | `reference/vault.md` |

**Commands:** `aidevops secret set NAME` / `aidevops secret run CMD` (gopass) · `sops-helper.sh encrypt config.enc.yaml` (SOPS) · `gocryptfs-helper.sh create vault-name` (gocryptfs)

**Storage:** gopass → `~/.local/share/gopass/stores/root/aidevops/` (fallback: `~/.config/aidevops/credentials.sh`, 600 perms) · SOPS → encrypted files in git (age preferred, GPG, AWS/GCP/Azure KMS) · gocryptfs → `~/.aidevops/.agent-workspace/vaults/` (AES-256-GCM)

**Vault model:** `reference/vault.md` defines protected data classes, labels,
provider routing, trust boundaries, and future encrypted sync. It does not
replace gopass/SOPS/gocryptfs today; it explains when each primitive is the
right building block.

<!-- AI-CONTEXT-END -->

## Common Workflows

### New project setup

```bash
# 1. Initialize gopass for API keys
aidevops secret init
aidevops secret set DATABASE_URL
aidevops secret set API_KEY

# 2. Initialize SOPS for config files (two options)
aidevops init sops                    # Project-level: creates .sops.yaml + age key
sops-helper.sh init                   # Standalone: init without aidevops project config
sops-helper.sh encrypt config.enc.yaml

# 3. Create encrypted vault for sensitive workspace data
gocryptfs-helper.sh create myproject
gocryptfs-helper.sh open myproject
```

### CI/CD pipeline

```bash
# gopass: inject secrets into build
aidevops secret run docker build .

# SOPS: decrypt config for deployment
sops decrypt config.enc.yaml > /tmp/config.yaml
deploy --config /tmp/config.yaml
rm /tmp/config.yaml
```

### Team onboarding

```bash
# 1. Share gopass store via git
gopass recipients add teammate@example.com
gopass sync

# 2. Add teammate's age key to .sops.yaml
sops updatekeys config.enc.yaml

# 3. gocryptfs vaults are per-machine (no sharing needed)
```

## Security Principles

1. **Never expose secrets in AI context** -- use the AI-safe flows above.
2. **Encryption at rest** -- all three tools protect data when idle.
3. **Minimal exposure** -- decrypt only what you need, when you need it.
4. **Key separation** -- each tool uses independent key material.
5. **Audit trail** -- gopass and SOPS changes are git-versioned.

## Relationship to Aidevops Vault

Vault is the framework-level security model for memory, sessions, workspaces,
knowledge, mail/messages, config metadata, audit logs, device registry, and sync
collections. The existing tools remain the current implementation choices for
specific storage scopes:

- **gopass** stores individual `secret` values. Agents use `aidevops secret` so
  values stay out of AI context.
- **SOPS** stores structured secret-bearing files that must be committed to Git
  in encrypted form.
- **gocryptfs** protects sensitive directories at rest on local machines.
- **Vault** defines classification labels, provider routing, fleet trust,
  encrypted sync, and audit constraints across all protected data classes.

For first-use setup and fleet behaviour, use `workflows/vault-setup.md` and
`workflows/vault-fleet.md`.

## Related

- `reference/vault.md` -- Aidevops Vault threat model and architecture RFC
- `workflows/vault-setup.md` -- Vault first-use setup and migration workflow
- `workflows/vault-fleet.md` -- Vault device trust and sync workflow
- `tools/credentials/api-key-setup.md` -- API key setup guide
- `tools/credentials/multi-tenant.md` -- Multi-tenant credential storage
