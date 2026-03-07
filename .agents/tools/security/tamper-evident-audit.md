---
description: Tamper-evident audit logging with SHA-256 hash chaining for security-sensitive operations
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

# Tamper-Evident Audit Logging

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Script**: `audit-log-helper.sh` (`~/.aidevops/agents/scripts/audit-log-helper.sh`)
- **Log file**: `~/.aidevops/.agent-workspace/observability/audit.jsonl`
- **Log entry**: Append to chain with `audit-log-helper.sh log <type> <message> [--detail k=v ...]`
- **Verify chain**: `audit-log-helper.sh verify`
- **View recent**: `audit-log-helper.sh tail [N]`
- **Status**: `audit-log-helper.sh status`
- **Related**: `tools/security/prompt-injection-defender.md`, `tools/security/opsec.md`

**When to read this doc**: When logging security-sensitive operations (dispatch, credential access, config changes) or verifying audit trail integrity.

<!-- AI-CONTEXT-END -->

## How It Works

Each audit log entry is a JSON object appended to an append-only JSONL file. Every entry includes:

- `seq` — monotonic sequence number
- `ts` — ISO 8601 UTC timestamp
- `type` — event type (hierarchical, e.g., `worker.dispatch`)
- `msg` — human-readable description
- `detail` — optional key-value metadata
- `actor` — session ID or username
- `host` — hostname
- `prev_hash` — SHA-256 hash of the previous entry (genesis hash for first entry)
- `hash` — SHA-256 hash of this entry (computed over all fields except `hash`)

The hash chain creates tamper evidence: modifying or deleting any entry changes its hash, which breaks the `prev_hash` link in the next entry. The `verify` command walks the entire chain and reports any breaks.

## Event Types

| Type | When to log |
|------|-------------|
| `worker.dispatch` | Worker spawned by pulse/supervisor/manual dispatch |
| `worker.complete` | Worker finished (include success/failure in detail) |
| `worker.error` | Worker encountered a fatal error |
| `credential.access` | Credential read via gopass, credentials.sh, or env |
| `credential.rotate` | Credential rotation event |
| `config.change` | Framework config file modified |
| `config.deploy` | Config deployed via setup.sh |
| `security.event` | Generic security event |
| `security.injection` | Prompt injection detected by prompt-guard-helper.sh |
| `security.scan` | Security scan performed |
| `operation.verify` | High-stakes operation verified by verify-operation-helper.sh |
| `operation.block` | High-stakes operation blocked |
| `system.startup` | Framework startup |
| `system.update` | Framework update (aidevops update) |
| `system.rotate` | Audit log rotation |

## Integration Points

### Worker Dispatch (`dispatch.sh`)

Log every worker spawn:

```bash
audit-log-helper.sh log worker.dispatch "Dispatched worker for ${task_id}" \
  --detail repo="${repo_slug}" \
  --detail task_id="${task_id}" \
  --detail branch="${branch_name}"
```

### Credential Access

Log credential reads (key names only, never values):

```bash
audit-log-helper.sh log credential.access "Read token for dispatch" \
  --detail scope="repo:read" \
  --detail source="gopass"
```

### Prompt Injection Detection

Log when prompt-guard-helper.sh detects an injection:

```bash
audit-log-helper.sh log security.injection "Injection detected in PR body" \
  --detail pr="${pr_number}" \
  --detail severity="${severity}" \
  --detail pattern="${pattern_name}"
```

### High-Stakes Operation Verification

Log verify-operation-helper.sh decisions:

```bash
audit-log-helper.sh log operation.verify "Force push verified by cross-provider check" \
  --detail operation="git push --force" \
  --detail verifier="gemini-2.5-flash" \
  --detail result="approved"
```

## Verification

Run `audit-log-helper.sh verify` to check the entire chain. This should be run:

- Before log rotation (automatic)
- As part of security audits
- When investigating suspicious activity
- Periodically via scheduled task (optional)

Exit codes: 0 = chain intact, 1 = chain broken (tampered or corrupted).

## Log Rotation

Logs are rotated when they exceed a size threshold (default: 50 MB):

```bash
audit-log-helper.sh rotate --max-size 50
```

Rotated files are renamed with a timestamp suffix and set to read-only (0400). A rotation event is logged in the new file to maintain the audit trail across rotations.

## Limitations

- **Not tamper-proof, tamper-evident.** An attacker with write access to the log file can delete or modify entries. The hash chain makes this detectable but cannot prevent it. For tamper-prevention, forward logs to a remote syslog server (future enhancement).
- **Single-machine scope.** The log file lives on the local machine. If the machine is compromised, the attacker can destroy the log. Remote forwarding addresses this.
- **No encryption.** Log entries are plaintext JSON. Do not log credential values — only key names and access metadata.
- **Sequential writes.** Concurrent writers to the same log file may produce race conditions. In practice, aidevops operations are serialized (one pulse at a time), so this is unlikely.

## File Permissions

- Log file: `0600` (owner read/write only)
- Log directory: `0700` (owner access only)
- Rotated files: `0400` (owner read-only)
