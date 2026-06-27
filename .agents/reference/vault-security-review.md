<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Vault Security Review and Release Criteria

Use this checklist before enabling Vault destructive migration, remote unlock, or
fleet sync by default. The fast deterministic gate is
`.agents/scripts/tests/test-vault-security-suite.sh`; broad fleet and recovery
drills remain staging/release advisory until they are stable enough for every PR.

## Required before default-on release

- External crypto/security review covers `vault-crypto-helper.py`,
  `vault_crypto_core.py`, broker lifecycle, device registry, sync, remote control,
  audit chain, and migration rollback paths.
- Destructive migration stays behind explicit operator intent until recovery from
  interrupted migration and rollback is verified on a disposable copy of each
  protected data plane.
- True remote unlock remains default-disabled behind a feature flag. Remote lock
  and unlock-request are the safe default; true remote unlock requires a written
  threat-model exception, device-bound encryption, short TTL, audit events, and a
  local kill switch.
- Public/private Git, object storage, SimpleX, SSH, Tailscale, and VPS disks are
  treated as untrusted transports. Only ciphertext, opaque ids, public keys, and
  signed metadata may cross them.
- Passphrases, recovery material, root keys, private device keys, and plaintext
  protected data are never accepted through chat, issue bodies, CLI args,
  environment variables, logs, or test fixtures.

## Fast required security gate

The fast suite must pass locally and in CI before Vault changes merge:

```bash
./.agents/scripts/tests/test-vault-security-suite.sh
```

It aggregates the existing Vault helper tests and pins these failure modes:

- wrong passphrase and non-TTY passphrase input fail closed without echoing the
  supplied value;
- broker crash/app restart simulation returns Vault to `locked` and denies reads;
- locked data-plane access and locked migration fail before plaintext removal;
- interrupted or tampered migration/audit/sync inputs fail with stable errors;
- replayed sync records, remote commands, stale commands, and revoked devices are
  rejected;
- public Git/message transports expose only ciphertext and opaque paths;
- deterministic scans reject plaintext secret-like test fixtures.

## Staging or release advisory drills

Run these on disposable test Vaults before release candidates and before changing
Vault defaults:

1. Reboot simulation: unlock, write entries, terminate broker/session, restart the
   host or runtime, and verify locked status before any plaintext read.
2. Interrupted migration: stop the migration after encrypt-before-remove and
   after remove-before-manifest-finalise; verify rollback restores only from
   verified Vault entries.
3. Interrupted sync: stop export/import mid-record and verify replay/rollback
   protection rejects partial or stale records.
4. Interrupted audit write: force an audit append failure with
   `AIDEVOPS_VAULT_AUDIT_REQUIRE=1`; sensitive operations must fail closed.
5. Public ciphertext scan: scan public transport repos for client names, local
   paths, entry ids, plaintext payloads, and search indexes.

## Honest security-limit wording

Vault does not protect data from malware/root access while unlocked, provider-side
AI logs after plaintext is sent to a third-party provider, unsupported runtime
caches, unmanaged crash reports, terminal scrollback, screenshots, OS crash
dumps/swap/hibernation, snapshots/backups created before encryption, or durable
plaintext already committed to Git history.
