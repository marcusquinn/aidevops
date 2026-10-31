<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Legacy worktree maintenance (user space only)

Historical `owner-cgroup-v1` observations sometimes lack a descendant-completion
contract. A dead PID, old timestamp or archive cannot manufacture that evidence.
Do not rewrite `running` records as `sealed` or retroactively enroll old worktrees.

`aidevops cleanup maintenance` uses the existing archive-first removal mechanism
with explicit, candidate-local user-space checks. It requires no root access,
sudo, privileged inspector, system service, rescue target or session shutdown.
It is never included in automatic `cleanup all --apply`.

## Plan and review

```bash
aidevops cleanup maintenance plan --repo /absolute/canonical/repository > /absolute/plan.json
```

The confirmation digest is printed on stderr. Keep the plan private: it includes
local paths and lifecycle identities. Plans bind the machine, repository/default
tip, source identity, HEAD and original record; they expire after seven days.
Planning is read-only and never fetches, commits, resets, clears locks or removes
files. Refresh stale default tracking refs separately before planning.

The default batch is 50 worktrees (`--limit 1..200`). `scan.next_offset` supplies
the next `--offset`; unexamined worktrees are not approved. Restart the inventory
if the Git listing changes and replan after every applied batch.

Candidates must be owned by the current user, clean, fully published in the
default branch, and backed by unchanged legacy records without live owners or
interrupted archive operations. Shared Pulse issue/PR retention rules apply,
including closed-PR protective labels, enrichment and repair attribution, and
fail-closed handling of unavailable, malformed or truncated GitHub responses.
Ignored files and forensic markers retain the source: the archive producer does
not yet capture ignored content, so a clean Git status alone is insufficient.

### Explicit worker archive plans

For a known Pulse worker source, an operator may select one worktree using its
independent controller launch log and the matching native runtime prefix:

```bash
aidevops cleanup maintenance plan --repo /absolute/canonical/repository \
  --worker-path /absolute/linked/worktree \
  --worker-launch-log /absolute/native/controller.log \
  --worker-runtime-log /absolute/native/runtime.log
```

The controller log must be beneath the current user's aidevops log root. Both
files must be regular, owned by that user, and not writable by others. The native
session, attempt, scope and prepared worktree must match; model output after
`pre_runtime_launch` is not evidence. Missing logs, ambiguous worker arguments or
incomplete process inspection retain the source.

The following choices are separate, explicit archive policies, not defaults:

- `--discard-ignored`: classify ignored content as disposable. It is not saved
  in the archive. Forensic markers still veto removal.
- `--archive-local-commits`: allow commits outside the recorded default tip;
  native archive and restoration verification remain mandatory.
- `--archive-blocked`: allow archival of an issue marked `status:blocked`.
  Security, forensics, open-PR and unavailable-retention-policy vetoes remain.

These choices are bound into the reviewed plan digest and rechecked on apply.
Worker plans preserve the local branch and never enroll, seal or replace legacy
lifecycle history. They support unchanged observation-only records or absent
records, not managed generations with unresolved completion contracts. Check and
apply use the same commands below and never pass `--force` to removal.

**This is not a CWD exemption.** Full CWD visibility remains required. A matching
active worker in the source or a child directory vetoes removal; absence from a
worker census does not prove descendant completion. On a host with unresolved
CWD observations, worker plans still stop with `maintenance:cwd-visibility-degraded`.

## Process evidence, not process exemptions

The Linux procfs observer is reused directly without a privileged inspector.
A readable CWD in the source or a descendant always vetoes removal. Unresolved
processes retain the source with `maintenance:cwd-visibility-degraded`; an empty
or unreadable snapshot is unusable. Process names, daemon roles, old PIDs and
plan confirmation never turn an unknown CWD into proof of absence.

This may retain every legacy candidate on a host with protected same-user
processes. That is an explicit limitation, not successful cleanup. Do not ask
for administrative access or stop sessions to change this result. Ordinary
managed cleanup continues to use genuinely saved lifetime proof where available;
this maintenance path does not manufacture such proof for legacy worktrees.

Enrollment and registered-owner checks precede the legacy global CWD scan, so
`maintenance:not-legacy-running` and `maintenance:live-owner` are not masked by
unrelated denied processes. Use ordinary lifecycle cleanup for managed records:
sealed proof, or read-only `cleanup-ready` classification before sealing, already
handles degraded CWD visibility without exempting readable positive matches.
Lifecycle reports expose `lifecycle.evidence_class`: `observation-only`,
`managed-contract-recorded`, `incomplete`, or `unrecorded`. These describe stored
evidence, not current process liveness or deletion authorization; the original
state and receipts remain unchanged.

Ordinary compact archives do not retain `COMMIT_EDITMSG` and do not require its
contents to match a committed message. Capture leaves the live file untouched.
Working files, the index, supported merge state and history checks remain under
their existing preservation policies; explicit Git-administration archives retain
their separate full-metadata capture contract.

## Check and apply

```bash
aidevops cleanup maintenance check --plan /absolute/plan.json --confirm REVIEWED_DIGEST
aidevops cleanup maintenance apply --plan /absolute/plan.json --confirm REVIEWED_DIGEST
```

Run as the same normal user, outside every candidate, with the usual GitHub
authentication available. `check` revalidates without deletion. `apply` calls
`worktree-helper.sh remove` without `--force`. Preparation and final native
removal independently repeat proof; failed proof never falls through to claiming,
sealing, missing-enrollment handling or degraded-CWD recovery.

The existing archive producer verifies restoration and source fingerprints.
Git locks, ownership and late source checks remain authoritative. Historical
lifecycle rows are unchanged; existing archive receipts and removal audit logs
retain the evidence. Each result records the plan digest, user/boot context,
exit code and source presence. A failed operation stops the batch and preserves
remaining candidates; do not delete recovery transactions to retry.

Linux user-space observation is supported, including NixOS. No macOS/Windows
maintenance adapter is claimed. Every computer needs its own reviewed plan.
Code installation or a successful plan/check is not reclaimed space: verify
source absence and archive evidence after an authorized application.
