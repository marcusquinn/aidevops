# Tamper-Evident Audit Logging (t1412.8)

Security-sensitive operations are logged to an append-only JSONL file with
SHA-256 hash chaining. Each entry includes the hash of the previous entry,
creating a chain. Modifying or deleting any entry breaks the chain, making
tampering detectable via `audit-log-helper.sh verify`.

## Usage

Log security-sensitive operations via `audit-log-helper.sh log <type> <message> [--detail k=v ...]`.

Event types: `worker.dispatch`, `worker.complete`, `worker.error`, `credential.access`, `credential.rotate`, `config.change`, `config.deploy`, `security.event`, `security.injection`, `security.scan`, `operation.verify`, `operation.block`, `system.startup`, `system.update`, `system.rotate`, `testing.runtime`.

Run `audit-log-helper.sh help` for details.

## Configuration

- Log file: `~/.aidevops/.agent-workspace/observability/audit.jsonl` (0600 permissions, owner-only).
- Verify chain integrity: `audit-log-helper.sh verify`. Run before log rotation and during security audits.
- NEVER log credential values — only key names, scopes, and access metadata. The audit log is plaintext.
- Full docs: `tools/security/tamper-evident-audit.md`.
