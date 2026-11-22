# Process observation contract

This is the implemented observation boundary, not a claim that the full durable
lifecycle described in DESIGN.md is implemented.

## Readiness first

At the start of each bounded invocation: select the native adapter, capture the
observer's own identity (including boot identity), and verify it is alive. Failure
returns exit 2 before reading target input or processing any lifecycle records.
No privileges are requested, no sandbox is bypassed, and no state is rewritten.

Readiness is necessary, not sufficient: individual process queries still handle
access failures and races. A future scheduler will back off common readiness
failures; no scheduler or retry loop exists in this slice.

## Identity schema 1

| Field | Meaning |
|-------|---------|
| installation_id | Canonical UUID, supplied by the installation owner, never guessed from a host name |
| platform | `linux` or `darwin` |
| boot_id | Canonical boot UUID from the native API |
| scope | Linux PID namespace device/inode token, or macOS host scope |
| pid | Positive signed-32-bit PID |
| generation | Native start ticks on Linux; seconds:microseconds on macOS |
| uid | Observed user identity; not authorization |

Installation UUID is not yet provisioned automatically. Tests generate temporary
UUIDs for isolation. Production registration and protection against copying state
between hosts belong to the storage/admission slice.

The supplied identity must come from trusted capture/storage. The inspection CLI
does not authenticate caller JSON: a fabricated boot UUID can produce a hypothetical
previous-boot result. These outputs must never be used directly as deletion proof.

## Observations

| Status | Reasons and interpretation |
|--------|----------------------------|
| alive | Exact recorded identity matches at sampling time |
| ended | Previous boot, absent PID, replaced generation, or exited/zombie process |
| unknown | Unsupported schema/context, foreign installation/user, access error, malformed metadata, or ambiguous sampling |

Linux validates procfs context before/after sampling; macOS checks boot identity
and exact native return sizes. A zombie is not executing, but its children may
still be running. An alive observation can become stale immediately. Native start
timestamps have finite precision and are not cryptographic incarnation IDs.

## Worker and session ownership (next slice)

Process identity is not a session ID. One interactive session may bind multiple
worktree generations. Several sessions may share one runtime process and must
retain distinct session/run IDs and binding records. Process death ends the
execution backing those sessions; process survival alone does not prove an
individual session is still active. Missing session completion remains unresolved
until a defined session-level observation or admission protocol resolves it.

One generation has at most one effective authority/owner under the future active
protocol. Observe-only mode can report conflicting claims but cannot prevent them or
transfer actual ownership. A helper-created child does not implicitly own its
parent's worktrees. Transfers require explicit expected-owner/version checks.

## Native verification

Run the shared tests on each actual OS. Linux passing does not validate macOS
ctypes execution. The existing Mac probe reports validate API feasibility on
12.7.6 Intel only. The operator attributed the earlier boot-read denial to Codex
sandboxing; the successful later unprivileged report does not justify bypassing
access errors in other contexts.

The standard-library tests include real owned-process capture, independent fresh
observer and natural exit/reap. Access-denial injection verifies the early-stop
control flow, not an actual OS policy. Reboot, PID reuse, corruption, durable
recovery and multi-writer fencing are not claimed by these tests.
