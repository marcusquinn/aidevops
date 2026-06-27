---
description: Manage aidevops Vault setup, lock state, encrypted sync, fleet trust, and protected-data dispatch metadata
agent: Vault
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Use this command guide for `aidevops vault` and Vault-related `aidevops fleet`
flows. Arguments: $ARGUMENTS

## Safety contract

- Never paste Vault passphrases, recovery material, private keys, or raw secrets
  into AI chat, CLI arguments, environment variables, logs, issue comments, PR
  bodies, screenshots, or fixtures.
- Run commands that need unlock material in a local terminal with the helper's
  hidden prompt.
- Treat Git, object storage, secure messaging, SSH, Tailscale/VPN, and VPS disks
  as untrusted transports. Sync only encrypted payloads plus signed metadata.
- Status, setup-state, public fingerprints, and sanitized error codes are safe
  evidence; secret values are not.

## Local Vault commands

```bash
aidevops vault init
aidevops vault setup-state
aidevops vault status
aidevops vault unlock
aidevops vault lock
aidevops vault lost-passphrase
aidevops vault lost-passphrase archive-and-start-fresh
```

Expected behaviour:

- `init` asks locally for a 12+ character passphrase, confirmation, and the exact
  no-recovery acknowledgement. Store the passphrase in a trusted password
  manager with backups.
- `unlock` uses a local hidden prompt; never pass unlock material as an argument
  or environment variable.
- `setup-state` gates migration. Real protected-data migration remains blocked
  until a fresh unlock proves the harmless setup test record is readable.
- `lost-passphrase archive-and-start-fresh` archives ciphertext and metadata; it
  does not decrypt or delete the archive.

## Fleet and sync flows

Use `workflows/vault-fleet.md` before advising multi-device operations.

- Device onboarding: exchange public fingerprints, verify through an
  authenticated human/local channel, then sign trust updates from an existing
  trusted device.
- Sync: export/import encrypted collection records only; plaintext filenames,
  private paths, client names, subjects, and collection entry IDs must not appear
  in transport-visible names.
- Remote lock: safe protective action when signed by a trusted device.
- Unlock-request: preferred remote access pattern; approval happens locally and
  rewraps only scoped collection keys.
- True remote unlock: default-disabled unless an audited, opt-in, device-bound,
  short-lived policy exception exists; passphrases still never travel through
  chat, args, env vars, logs, or fixtures.

## Dispatch/preflight metadata

Worker-ready tasks that may touch protected data must include:

```yaml
needs_vault: locked-ok|unlocked|true
needs_collections: <collection names, not secrets>
needs_device: <device class or identifier reference>
needs_remote_unlock: false|request-only|required
data_classification: public|internal|confidential|client-confidential|secret|local-only|provider-allowed|local-LLM-only
runtime_policy: provider-ai|provider-ai-approved|local-ai|local-LLM-only|hybrid
```

The deterministic policy gate fails closed when remote providers are selected
for `local-only`/`local-LLM-only`, when confidential data lacks provider
approval, or when prompt context is `secret`.
