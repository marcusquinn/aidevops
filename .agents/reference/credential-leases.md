# Encrypted run-scoped credential leases

`scripts/credential-lease-helper.py` is an opt-in, versioned API for credentials
generated for one disposable run. It does not read, overwrite, reconcile or delete
ordinary gopass/tenant credentials, and never uses the plaintext fallback.

This is a narrow encrypted capsule, not a second general password manager. It
reuses installed GPG with an explicitly selected, already trusted recipient
fingerprint. It never imports/generates keys, retrieves keys over the network,
relaxes trust, installs dependencies or initializes a store. Missing/locked keys
are a refusal. Operating the API needs separate credential-lifecycle authority;
approving its source changes does not authorize sealing or decrypting real values.

## API

Use `python3 scripts/credential-lease-helper.py capabilities` for a non-operative
protocol check. Version 1 advertises encrypted-only, create-only storage and
conditional removal. The other modes require a canonical UUID and an existing
owner-only mode-0700 directory immediately beneath the owner-only
`AIDEVOPS_TEMP_DIR` (default `~/.aidevops/.agent-workspace/tmp`), outside Git.
Symlinks and broad/public directories are refused.

- `seal --directory <directory> --run-id <uuid> --recipient <fingerprint>` accepts
  a bounded JSON object of environment names/values on stdin. Generate values in
  the caller process; never put them in arguments, chat, dotenv or a plaintext
  input file. GPG ciphertext is written exclusively, followed by an immutable
  non-secret ownership receipt, then published with an atomic no-clobber link.
  Any collision refuses; there is no overwrite option. Only fresh lease
  directories are eligible. Do not reuse a directory after removal.
- `exec --directory <directory> --run-id <uuid> --cwd <checkout>
  --budget-seconds <1..3600> -- <reviewed command>` verifies the receipt and
  ciphertext, decrypts only in memory and supplies values to that child. Ambient
  credentials and dotenv sources are not inherited by the launcher. The child
  must not load dotenv after injection. Its stdin, stdout and stderr are disabled;
  the API emits only fixed outcome classifications. Do not use it for a command
  requiring stdin or raw logs. Common loader, interpreter, shell and Git
  execution-hook names are refused; that denylist is not exhaustive, so seal
  only the names the reviewed command expects.
- `remove --directory <directory> --run-id <uuid>` checks directory identity,
  run, device/inode and ciphertext digest. Removal requires no decryption/key
  unlock. It retains the non-secret receipt and is idempotent after confirmed
  removal. It never removes the directory or unreceipted/changed ciphertext.

No command prints a value, hash of a plaintext value, decrypted envelope or raw
GPG/child error. The receipt records only a ciphertext digest, recipient
fingerprint, environment names and filesystem/run identities. OS-user access to
the GPG keyring remains the security boundary; the run UUID is ownership metadata,
not a bearer credential. Do not share private directories or race them with
manual file edits. Operations serialize on the same per-directory advisory lock.

## Failure and recovery

An interrupted seal can leave pending ciphertext. If its immutable receipt is
present and valid, `remove` validates and removes exactly that object. Ciphertext
without a valid receipt is an uncertain initialization: preserve it for explicit
review, never clean by prefix. A changed object during retirement is restored
without overwriting another object; failed restoration leaves encrypted material
at the documented `credential-lease.retired.gpg` path and refuses cleanup.

Execution requires Linux and Python 3.11 or later. The launcher assigns its child
an owned process group (not a detached session), retains the unreaped leader to
pin that identity, and drains the group on success, timeout or interruption before
reporting the outcome. SIGTERM/SIGINT received while the child runs stop it as
an interruption; repeated signals during the drain are recorded, never allowed
to abort it. Remaining live group members cause refusal. Reviewed
commands must not daemonize, start another session, or escape that group.

Run `exec` only within an existing bounded owner with independent resource
restoration registered. It is not a durable supervisor and does not certify
listener or Docker cleanup. SIGKILL/host loss requires the caller's receipt-scoped recovery.
Acceptance and resource/credential cleanup are separate outcomes. A failed or
uncertain cleanup can never become a successful run merely because a child exits.

Offline regression command (synthetic ciphertext and mocked GPG/children only):

```bash
python3 .agents/scripts/tests/test-credential-lease.py
```

No CI gate, service, key provisioning or real credential-store operation is
required to run those tests. Deployment of this framework addition is a separate
operation; consumers can name a reviewed source helper explicitly until approved.
