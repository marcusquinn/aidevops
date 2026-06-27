---
description: Manage Vault fleet trust, encrypted sync, secure messages, remote lock, and unlock-request policy
agent: Vault
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Use this command guide for `aidevops fleet` flows that coordinate Vault devices,
encrypted sync, secure messages, and remote-control policy. Arguments: $ARGUMENTS

## Safety contract

- Fleet transports are untrusted delivery mechanisms. Git, object storage,
  secure messaging, SSH, Tailscale/VPN, and VPS hosts may carry encrypted bundles
  plus signed metadata only.
- Device trust is explicit and revocable. Do not trust a device because it can
  reach the same account, network, remote, bucket, or message channel.
- Passphrases, recovery material, private keys, raw tokens, and protected
  plaintext never belong in chat, arguments, environment variables, logs,
  comments, PR bodies, screenshots, or fixtures.

## Fleet flow map

1. **Onboard device:** create local keys, exchange public fingerprints, verify via
   human/local authenticated channel, sign registry update from a trusted device,
   then rewrap only allowed collection keys.
2. **Sync collection:** export/import encrypted append-only records; reject
   unsigned, expired, replayed, rolled-back, tampered, or revoked-device records.
3. **Secure message:** send encrypted envelopes and signed acknowledgements;
   plaintext subjects, local paths, client names, and private basenames must not
   appear in transport-visible paths or payloads.
4. **Remote lock:** allow authorized signed protective commands and require a
   signed acknowledgement with status and audit head.
5. **Unlock-request:** queue a local operator decision and scope any approval to
   named collections, labels, and duration.
6. **True remote unlock:** default-disabled; only proceed when a future audited
   policy explicitly proves passphrases never travel through unsafe channels.

## Worker metadata

When dispatching fleet work, brief workers with `needs_vault`,
`needs_collections`, `needs_device`, `needs_remote_unlock`,
`data_classification`, and `runtime_policy`. Use collection names and device
classes only; do not include secret values, private paths, client names, or
plaintext message subjects.
