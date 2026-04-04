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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Tamper-Evident Audit Logging

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Script**: `audit-log-helper.sh` (`~/.aidevops/agents/scripts/audit-log-helper.sh`)
- **Log file**: `~/.aidevops/.agent-workspace/observability/audit.jsonl`
- **Commands**: `log <type> <message> [--detail k=v ...]` | `verify` | `tail [N]` | `status`
- **Related**: `tools/security/prompt-injection-defender.md`, `tools/security/opsec.md`

**When to read**: Logging security-sensitive operations or verifying audit trail integrity.

<!-- AI-CONTEXT-END -->

## How It Works

Append-only JSONL file. Each entry contains:

| Field | Description |
|-------|-------------|
| `seq` | Monotonic sequence number |
| `ts` | ISO 8601 UTC timestamp |
| `type` | Hierarchical event type (e.g., `worker.dispatch`) |
| `msg` | Human-readable description |
| `detail` | Optional key-value metadata |
| `actor` | Session ID or username |
| `host` | Hostname |
| `prev_hash` | SHA-256 of previous entry (genesis hash for first) |
| `hash` | SHA-256 of this entry (all fields except `hash`) |

Modifying or deleting any entry breaks the `prev_hash` link in the next entry. `audit-log-helper.sh verify` walks the chain and reports breaks.

## Event Types

| Type | When to log |
|------|-------------|
| `worker.dispatch` | Worker spawned (pulse/supervisor/manual) |
| `worker.complete` | Worker finished (include success/failure) |
| `worker.error` | Worker fatal error |
| `credential.access` | Credential read (gopass, credentials.sh, env) |
| `credential.rotate` | Credential rotation |
| `config.change` | Framework config modified |
| `config.deploy` | Config deployed via setup.sh |
| `security.event` | Generic security event |
| `security.injection` | Prompt injection detected (prompt-guard-helper.sh) |
| `security.scan` | Security scan performed |
| `operation.verify` | High-stakes op verified (verify-operation-helper.sh) |
| `operation.block` | High-stakes op blocked |
| `system.startup` | Framework startup |
| `system.update` | Framework update |
| `system.rotate` | Audit log rotation |

## Integration Examples

### Worker Dispatch

```bash
audit-log-helper.sh log worker.dispatch "Dispatched worker for ${task_id}" \
  --detail repo="${repo_slug}" \
  --detail task_id="${task_id}" \
  --detail branch="${branch_name}"
```

### Credential Access (key names only, never values)

```bash
audit-log-helper.sh log credential.access "Read token for dispatch" \
  --detail scope="repo:read" \
  --detail source="gopass"
```

### Prompt Injection Detection

```bash
audit-log-helper.sh log security.injection "Injection detected in PR body" \
  --detail pr="${pr_number}" \
  --detail severity="${severity}" \
  --detail pattern="${pattern_name}"
```

### High-Stakes Operation Verification

```bash
audit-log-helper.sh log operation.verify "Force push verified by cross-provider check" \
  --detail operation="git push --force" \
  --detail verifier="gemini-2.5-flash" \
  --detail result="approved"
```

## Verification

Run `audit-log-helper.sh verify` before log rotation, during security audits, or when investigating suspicious activity. Exit: 0 = intact, 1 = broken (tampered/corrupted).

## Log Rotation

Threshold: 50 MB (default). Rotated files get a timestamp suffix and `0400` permissions. A rotation event is logged in the new file to maintain chain continuity.

```bash
audit-log-helper.sh rotate --max-size 50
```

## Limitations

- **Tamper-evident, not tamper-proof.** Write access to the log allows modification; the hash chain makes this detectable. Future: remote syslog forwarding.
- **Single-machine scope.** Local-only; compromised host can destroy logs. Remote forwarding addresses this.
- **No encryption.** Plaintext JSON. Never log credential values -- only key names and access metadata.
- **Sequential writes.** Concurrent writers may race. In practice, aidevops serializes operations (one pulse at a time).

## File Permissions

| Path | Mode | Access |
|------|------|--------|
| Log file | `0600` | Owner read/write |
| Log directory | `0700` | Owner only |
| Rotated files | `0400` | Owner read-only |
