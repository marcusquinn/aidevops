<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Approval-Bound Local Marketing Actions

Use this workflow only for exact, reversible edits to version-controlled files in
an isolated linked worktree. It turns recommendations validated against
`.agents/configs/marketing-decision.schema.json` into a separate action proposal;
the decision report remains a non-mutating handoff and is never approval.

## Supported Surface

The executor supports one exact UTF-8 replacement per file for `title`,
`meta_description`, and `internal_link`. The plan binds the current bytes,
resulting bytes, exact diff, source evidence, owner, project/worktree identity,
action set, limits, and rollback method into `plan_digest`.

`noindex`, canonical, redirect, delete, budget, bid, negative-keyword, campaign,
pixel, conversion, moderation, and posting proposals are rendered as
`handoff_only`; they cannot be applied. Canonical checkouts, default branches,
symlinks, untracked files, CMS/ad accounts, generated deployments, commits,
pushes, publication, and account operations are always rejected or absent.

```bash
python3 .agents/scripts/marketing-action-helper.py plan \
  --input .agents/scripts/tests/fixtures/marketing-decisions/actions-plan.json \
  --dry-run
```

## Operator Approval

Apply and rollback run only with a fresh operator approval record. The operator
creates it in their own terminal; agents and workers must never run this
(it needs sudo and an interactive TTY):

```bash
sudo aidevops approve marketing-plan /path/to/reviewed-plan.json
sudo aidevops approve marketing-plan --rollback /path/to/receipt.json
```

The ceremony (`marketing_action_approval.mint`) refuses unless it runs as root
with `SUDO_USER` set and an interactive stdin. It reads the plan or receipt
without following symlinks and only when the operator owns the file. It
recomputes the plan digest, then prints the authorised action set and every
ready action. Each action shows its before hash and the exact `old`/`new` text
that apply will execute, not the stored diff. It also lists the handoff-only
items. Control characters are escaped. A review over 400 lines is refused rather
than truncated. Then it requires a typed `APPROVE` and writes a v2
record (`aidevops.marketing-action-approval/v2`) to
`~/.aidevops/approval-keys/marketing-actions/{apply|rollback}-<digest>.json`.
That directory is root-owned and not group/other writable. The record binds:

- the operation
- the plan schema and digest
- the plan's schema-specific binding (for local plans: project root and worktree identity)
- the ordered action set and the OS owner
- issue and expiry times (at most 15 minutes apart)
- a nonce and the cancellation path
- for rollback, the exact receipt digest

`apply` and `rollback` accept only a regular, root-owned record in that
directory that matches exactly. A missing, user-owned, symlinked, stale,
wrong-operation, wrong-digest, wrong-binding or cancelled record fails closed
before any file changes. The v1 inherited-pipe variables
(`AIDEVOPS_MARKETING_APPROVAL_FD`) no longer grant anything. Same-user processes
cannot create root-owned files, which is what separates the operator from agents.

The ceremony also creates an operator-owned mode-0600 cancellation file
(`~/.aidevops/.agent-workspace/marketing-action-cancellations/<nonce>`, created
with dropped privileges) containing `active:<nonce>`. The executor checks it
immediately before each write. Overwrite it to cancel an in-flight approval.
Re-approving the same digest replaces the record with a new nonce.

Within the approval window, the operator or an agent may run:

```bash
python3 .agents/scripts/marketing-action-helper.py apply \
  --plan /path/to/reviewed-plan.json \
  --receipt-dir "$HOME/.aidevops/.agent-workspace/marketing-action-receipts"
python3 .agents/scripts/marketing-action-helper.py rollback \
  --receipt "$HOME/.aidevops/.agent-workspace/marketing-action-receipts/PLAN_DIGEST.json"
```

The paths above are placeholders, not authorization. Scheduled runs need a fresh
operator record per plan; nothing infers approval merely because the CLI exists.
Other plan schemas (for example, remote ad-account adapters) register their bound
fields in `PLAN_BINDINGS` in `.agents/scripts/marketing_action_approval.py`.

## Recovery and Rollback

Each operation takes a non-blocking worktree lock. Before a file write, a private
mode-0600 receipt records its exact before bytes and before/after hashes. After
the write, the checkpoint removes that action from `remaining_action_ids`.
A fresh exact approval can deterministically resume an interrupted `applying`
receipt when every touched file is still at its recorded before or after state.
An exact replay of a completed plan is a verified no-op.

Rollback requires a fresh operation-specific approval and verifies every current
file still equals this operation's after-state before restoring any file. A
single mismatch preserves all evidence and refuses the entire rollback, so
unrelated edits are never overwritten. Repeated rollback is a no-op. Recovery
never runs reset, clean, commit, push, publication, or remote/account commands.

## Verification Boundary

Focused tests use synthetic linked worktrees, and they patch the trusted approver
UID and operator home so they can run without root. They prove the
local guard and recovery contract only; they do not establish ROI, authorize a
real proposal, or activate scheduled/live-site execution.
