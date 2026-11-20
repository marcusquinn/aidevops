<!-- aidevops:brief-schema=v2 -->
# Operator approval records for marketing action plans

## What

Add an operator-only approval ceremony for marketing action plans: `sudo aidevops approve marketing-plan <plan.json>` (and `--rollback <receipt.json>`). It writes a short-lived, plan-bound approval record into a root-owned directory. `marketing_actions.py` apply/rollback then accepts only such root-owned records, replacing the inherited-pipe HMAC contract.

## Why

`workflows/marketing-actions.md:32-35` requires a "trusted runtime adapter", but none exists: `AIDEVOPS_MARKETING_APPROVAL_FD` is produced only by `tests/test-marketing-actions.py`. The HMAC contract also cannot separate operator from agent, because the verifier trusts whatever key arrives on the pipe (`marketing_actions.py:208-236`). Any same-user process can mint its own pipe, key and approval. A record that only root can write, created through the same sudo+TTY ceremony as `sudo aidevops approve issue`, gives a real operator boundary. It is also the prerequisite for remote ad-account actions (parent #39489).

## Tier

`tier:thinking`: changes an authority boundary and its verification contract.

## How

### Files to Modify

- `NEW: .agents/scripts/marketing_action_approval.py`: mint/verify/summarise approval records. Python 3.9-compatible because sudo may resolve `/usr/bin/python3`.
- `EDIT: .agents/scripts/marketing_actions.py:175-239`: replace `_read_inherited_fd`/`verify_runtime_approval` with the record verifier. Keep `_verify_cancellation`.
- `EDIT: .agents/scripts/marketing-action-helper.py`: add an `approve` subcommand (root+TTY only).
- `EDIT: .agents/scripts/approval-helper.sh:2045-2067`: route `marketing-plan` in `main()` after `_require_interactive_root`.
- `EDIT: .agents/scripts/approval-helper-commands.sh:78-114`: `cmd_help` lines.
- `EDIT: .agents/scripts/tests/test-marketing-actions.py:89-130`: replace the pipe `approval()` fixture with record writing. Patch `TRUSTED_APPROVAL_UID` and the approval home so no root is needed.
- `EDIT: .agents/workflows/marketing-actions.md:30-63`: rewrite "Trusted Approval Adapter".

### Complete Write Surface

- **Callers/readers:** `marketing_actions.apply_plan` and `rollback_receipt` are the only approval consumers (`rg -n verify_runtime_approval .agents` lists only these and their tests).
- **Writers/mutation paths:** the new mint function writes `~<operator>/.aidevops/approval-keys/marketing-actions/{apply|rollback}-<digest>.json` (dir root 0755, file root 0644). It also writes the operator-owned 0600 cancellation file under `~/.aidevops/.agent-workspace/marketing-action-cancellations/`.
- **Existing verification/tests:** `.agents/scripts/tests/test-marketing-actions.py` encodes the apply/rollback/denial contract and must keep passing with the new fixture.
- **Schemas/config:** approval schema bumps to `aidevops.marketing-action-approval/v2`; plan and receipt schemas are unchanged.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` to `~/.aidevops/agents/scripts/`; `rg -n marketing_action .agents/configs` finds no generated index entries.
- **Migrations/backfills:** none. No v1 approval was ever produced outside tests, per `rg -n AIDEVOPS_MARKETING_APPROVAL_FD .agents`.
- **Cleanup/rollback paths:** a code revert of `.agents/scripts/marketing_actions.py` restores the v1 contract. Expired records in `~/.aidevops/approval-keys/marketing-actions/` (15 minutes or less) are inert and removable with sudo. File rollback stays receipt-bound in `marketing_actions.rollback_receipt`.

### Implementation Steps

1. Create `marketing_action_approval.py` (3.9-safe). It holds the record schema, a per-plan-schema binding registry (`aidevops.marketing-action-plan/v1` binds `project_root` and `worktree_identity`), `approval_dir(owner)` resolved through `pwd`, `mint()` (euid 0, `SUDO_USER` equals the plan owner, TTY confirmation, `O_EXCL` temp file then `os.replace`), and `verify()` (uid/mode/symlink checks, field equality, freshness, cancellation).
2. Swap `verify_runtime_approval` in `marketing_actions.py` to call `verify()`. Drop the pipe, HMAC and `stat` FIFO code.
3. Add `approve --plan PATH [--operation apply|rollback] [--receipt PATH]` to `marketing-action-helper.py`, and route `approval-helper.sh marketing-plan` through `_require_interactive_root`.
4. Update the test fixture and the workflow doc, then run the verification below.

### Hazards and Compatibility

- **Concurrency/atomicity:** the record is written to an `O_EXCL` temp file and then `os.replace`d inside the root directory. Apply keeps its existing worktree lock and per-write cancellation checks.
- **Migration/rollback:** there is no data migration. Revert ordering is irrelevant because plans and receipts are unchanged.
- **Mixed-version/backward compatibility:** a v1 pipe approval is rejected with a clear error. No producer exists, so no caller breaks. Plan and receipt files from older versions remain valid.
- **Idempotency/retry:** re-approving the same digest replaces the record with a new nonce and cancellation file. Replay of an applied plan stays a verified no-op.
- **Partial failure/recovery:** a mint failure before `os.replace` leaves no record. A crash after it is bounded by the TTL, and the operator can cancel by editing the cancellation file.

### Verification Before Dispatch

```bash
python3 .agents/scripts/tests/test-marketing-actions.py
ruff check .agents/scripts/marketing_action_approval.py .agents/scripts/marketing_actions.py .agents/scripts/marketing-action-helper.py
shellcheck .agents/scripts/approval-helper.sh .agents/scripts/approval-helper-commands.sh
/usr/bin/python3 -c 'import sys; sys.path.insert(0, ".agents/scripts"); import marketing_action_approval'
python3 .agents/scripts/marketing-action-helper.py approve --plan .agents/scripts/tests/fixtures/marketing-decisions/actions-plan.json
```

- **Surface mapping:**
  - The test file covers acceptance criteria 1-3: apply/rollback success and every denial case.
  - `ruff` and `shellcheck` cover the changed files.
  - The `/usr/bin/python3` import covers sudo interpreter compatibility.
  - The final command, run as a normal user, must refuse (criterion 4).
- **Broad verification trigger:** Not required, because only marketing-action files and the approval router change.

### Files Scope

- `.agents/scripts/marketing_action_approval.py`
- `.agents/scripts/marketing_actions.py`
- `.agents/scripts/marketing-action-helper.py`
- `.agents/scripts/approval-helper.sh`
- `.agents/scripts/approval-helper-commands.sh`
- `.agents/scripts/tests/test-marketing-actions.py`
- `.agents/workflows/marketing-actions.md`

## Acceptance Criteria

- [ ] With a valid root-owned v2 record that matches plan digest, action set, owner and binding, `apply` and `rollback` succeed exactly as before, including replay no-ops.
- [ ] A missing, user-owned, symlinked, stale, wrong-operation, wrong-digest or cancelled record is refused, and no file changes.
- [ ] The inherited-pipe variables no longer grant anything; the `AIDEVOPS_MARKETING_APPROVAL_FD` path is removed.
- [ ] `approve` refuses without euid 0, without `SUDO_USER`, or with non-TTY stdin. It shows the plan summary and requires a typed `APPROVE`.
