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

## Trusted Approval Adapter

Apply and rollback are disabled unless the host runtime supplies both
`AIDEVOPS_MARKETING_APPROVAL_FD` and `AIDEVOPS_MARKETING_APPROVAL_KEY_FD` as
inherited pipes. There is deliberately no CLI option that mints or accepts an
approval file. The runtime/operator adapter owns the HMAC key and writes a v1
approval containing the operation (`apply` or `rollback`), exact plan digest,
resolved project and worktree identity, ordered action set, current OS owner,
issued/expiry timestamps (maximum 15 minutes), nonce, and a private cancellation
state path. Rollback approval additionally binds the exact private receipt digest.
Unknown versions, ordinary files, missing adapters, generated JSON
flags, forged signatures, stale/future approvals, owner/scope/action mismatch,
or changed cancellation state fail closed.

The cancellation file must be an absolute, non-symlink, operator-owned mode-0600
file containing `active:<nonce>`. The executor checks it immediately before each
write. Runtime implementations must keep approval secrets and private receipts
outside prompts, repositories, and generated artifacts.

After an operator reviews the persisted output of `plan`, the trusted adapter may
run:

```bash
python3 .agents/scripts/marketing-action-helper.py apply \
  --plan /path/to/reviewed-plan.json \
  --receipt-dir "$HOME/.aidevops/.agent-workspace/marketing-action-receipts"
python3 .agents/scripts/marketing-action-helper.py rollback \
  --receipt "$HOME/.aidevops/.agent-workspace/marketing-action-receipts/PLAN_DIGEST.json"
```

The paths above are placeholders, not authorization. A scheduled invocation must
be explicitly enabled by an operator, use the same trusted adapter, preserve the
fresh approval and cancellation checks, and attach current validation evidence.
No runtime adapter is inferred merely because the CLI exists.

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

Focused tests use synthetic linked worktrees and inherited pipes. They prove the
local guard and recovery contract only; they do not establish ROI, authorize a
real proposal, or activate scheduled/live-site execution.
