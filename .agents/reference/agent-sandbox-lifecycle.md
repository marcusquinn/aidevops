<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Durable Agent Sandbox Lifecycle

Use `.agents/scripts/agent-sandbox-helper.sh` when an agent needs an explicitly
isolated, durable compute session. This is an opt-in execution boundary, not a
replacement for the existing local/headless worker path.

## Routing invariant

- No configured backend means `local`: preserve current local/headless execution.
- An explicitly requested sandbox must be available and support the requested
  operation. Never fall back from a requested sandbox to local execution.
- `configs/agent-sandbox-backends.json` is the capability authority. A provider
  name, installation, or marketing claim is not readiness evidence.

## Stable contract

| Operation | Contract |
|---|---|
| `create` | Validate immutable identity and limits, acquire generation 1, create a stopped resource, then atomically publish the receipt. Identical replay is a no-op; conflicting replay fails. |
| `start` | Verify the live lease, start the existing resource, and record `RUNNING` plus the conservative runtime expiry. |
| `attach` / `exec` | Verify `RUNNING`, the live lease, and a bounded command timeout. Commands are argv arrays, never shell strings. Output is not persisted by the helper. |
| `stop` | Gracefully stop, then record `STOPPED`. Repeated stop is safe. |
| `status` | Return the privacy-safe receipt plus a fresh backend state. It never acquires ownership. |
| `snapshot` | Check the backend capability before action. Unsupported or unredacted snapshot paths fail closed with exit 4. |
| `recover` | Fence the prior lease, increment its generation, verify immutable creation inputs, reconcile backend state, and recreate only a missing resource. |
| `destroy` | Verify ownership, stop/delete the resource and private network idempotently, then record `DESTROYED`. |

Exit 3 means the backend is unavailable, 4 means the capability is unsupported,
5 means lease or immutable-identity verification failed, and 124 means the
bounded backend command timed out.

## State and receipt model

States are `CREATED → RUNNING → STOPPED`, with recovery allowed from any
non-terminal state and `DESTROYED` terminal. Status reports a missing backend
resource as `backend_state: "missing"` without rewriting the last durable state;
`recover` reconstructs it from caller-supplied inputs matching the immutable
hashes.

Receipts live under `~/.aidevops/state/agent-sandboxes/` (directory mode 700,
files mode 600), or `AIDEVOPS_SANDBOX_STATE_DIR` in isolated tests. They contain:

- opaque sandbox and backend resource IDs;
- backend, lifecycle state, timestamps, and capability-safe errors;
- hashes of agent, session, worktree path, image, and immutable parameters;
- the worktree Git HEAD, resource limits, network mode, and runtime expiry;
- lease owner hash, generation, acquisition/expiry, and recovery count.

Receipts never contain command argv, output, environment, credentials, raw agent
or session IDs, repository remotes, image names, or raw worktree paths. Recovery
therefore requires the original image and worktree again and verifies their
hashes before recreating anything.

## Trust and isolation boundaries

| Boundary | Rule |
|---|---|
| Filesystem | Private read-only container root, private tmpfs runtime paths, and exactly one writable linked-worktree bind at `/workspace`. No host home mount. |
| Process | Workload runs in its backend VM/container with Linux capabilities dropped. Host commands are limited to the adapter's fixed argv templates. |
| Network | Apple resources use a per-sandbox `--internal` network, no DNS, and no published ports. |
| Resources | CPU and memory are explicit. Commands and uninterrupted runtime are time-bounded. Apple storage is isolated but its inspected CLI has no hard per-container quota, so strict storage-quota requests are unsupported. |
| Secrets | Never put secrets in images, command arguments, environment, receipts, logs, exports, or snapshots. Use an approved out-of-band broker mounted for one operation when that capability exists; this version exposes none. |
| Worktree | The caller supplies an existing linked worktree. Its canonical path hash and exact Git HEAD are immutable receipt inputs. |
| Snapshots | Retention defaults to zero. Apple filesystem export is not exposed because workload-created secrets cannot yet be proven absent or redacted. |

The `idle_timeout_seconds` bound is deliberately conservative for Apple
`container`: the container's PID 1 exits after that many seconds, so uninterrupted
runtime can never exceed the configured idle allowance. Restarting is an explicit
lease-owned action.

## Backend matrix

### Apple `container`

Executable only when all probes pass: Darwin, Apple silicon, macOS 26+, CLI
present, `container system version --format json` parseable, and
`container system status --format json` healthy. The adapter implements create,
start, attach/exec, stop, status, recover, and destroy. It does not expose
snapshots, secret injection, or hard storage quotas.

Primary source inspected 2026-09-16: `apple/container` release 1.4.1 and commit
`57f0b9392bbee1998e6c7f3f25db222fe1dcdd12`.

### Gonicus Bubbles

The inspected `app-v1.2.1` primary README documents a sandboxed Flatpak desktop
UI for creating, starting, opening terminals in, and deleting Linux environments.
No stable non-interactive lifecycle API was verified. The adapter reports the
provider as capability-only and every contract operation fails closed.

### Cloudron foundation

The inspected `aidevops-cloudron-app` v0.1.9 exposes authenticated task dispatch,
worker listing/cancellation, logs, and persistent `/app/data/workspace` storage
inside one Cloudron app container. It is not a per-agent sandbox provider. Never
assume nested virtualization, host privileges, VM lifecycle, snapshots, or
resource fencing from Cloudron. All sandbox contract operations fail closed.

## Operator examples

```bash
export AIDEVOPS_SANDBOX_SESSION_ID="<runtime-session-id>"

agent-sandbox-helper.sh resolve
agent-sandbox-helper.sh capabilities --backend apple-container
agent-sandbox-helper.sh create --id agent-01 --backend apple-container \
  --image '<reviewed-oci-image>' --worktree '<linked-worktree>'
agent-sandbox-helper.sh start --id agent-01
agent-sandbox-helper.sh exec --id agent-01 -- git status --short
agent-sandbox-helper.sh stop --id agent-01
agent-sandbox-helper.sh recover --id agent-01 \
  --image '<same-reviewed-oci-image>' --worktree '<same-linked-worktree>'
agent-sandbox-helper.sh destroy --id agent-01
```

Use `AIDEVOPS_SANDBOX_BACKEND=apple-container` only after `capabilities` reports
`available: true`. Set `AIDEVOPS_SANDBOX_REQUIRED=1` when local fallback is not
acceptable.
