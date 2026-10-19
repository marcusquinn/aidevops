# Recovery producers: verified compact capture transaction

Issue: #35144.
Parent: #35110. Overall objective: #35078.

## Execution ownership

Origin: interactive user request to split #35110 into smaller tasks. The originating interactive session retains implementation ownership, as explicitly required by #35078 and the existing hold on #35110. Keep `no-auto-dispatch`; this is a durable manual-ownership hold, not a request to launch a worker. No real worktree removal, legacy migration, deployment or release is authorized by this issue.

## Goal and boundary

Deliver a callable compact capture transaction, without switching any production caller yet. Use the existing `worktree-archive-helper.sh` representation, including ignored files and Git administration. Do not add another archive format or full recovery copy.

At decomposition, an uncommitted prototype existed with compilation-only evidence. That prototype is not an authoritative contract; delivery is governed by the acceptance criteria and recorded runtime verification.

## Implementation

- Add `.agents/scripts/worktree_recovery_producer.py` with capture, verification, source-match and source-removal receipt operations. Names may change only with corresponding updates to dependent briefs.
- Reuse archive CLI verification, independent restore, snapshot comparison, fsync and private-journal primitives from `worktree_lifetime_archive.py`, `worktree_recovery_migrate.py`, `worktree_recovery_migration_state.py` and `worktree_recovery_migration_scratch.py`; do not clone the preservation implementation.
- Bind a durable reservation to the exact source and Git-admin identity. Preserve interrupted output and refuse duplicate capture after drift. Concurrent capture must remain serialized even if its parent process dies while a child helper runs.
- Require self-contained preservation and an independently restored snapshot matching the source before publishing a verified receipt. Preserve staged, unstaged, ignored/untracked and supported Git-admin/history state.
- Keep archives pinned. Define explicit storage-root precedence and discoverability for the later cutover. Do not invent an issue association from a pathname; local/non-forge sources must have honest attribution.
- Unsupported inputs, insufficient capacity, missing evidence and partial restores preserve the source with a precise diagnostic. No sudo, fake enrollment or retention decision.

Scope clarification from a reproduced review finding: new producer receipts also seal the complete physical restore tree, including unreachable Git objects, using the existing retirement fingerprint primitive. The shared scratch verifier checks that optional seal before and after quarantine. Existing legacy receipts keep their compatibility behavior; this is not a legacy migration rollout.

## Verification

Extend the existing `ArchiveLifecycle` suite in `.agents/scripts/tests/test-worktree-archive-lifecycle.py`; no new test runner.

```bash
python3 .agents/scripts/tests/test-worktree-archive-lifecycle.py
python3 -m py_compile .agents/scripts/worktree_recovery_producer.py
git diff --check
```

Required focused cases: real capture/restore comparison; repeated capture returns the same verified archive; source/admin replacement and late writes fail closed; interruption retains one attempt; ignored data and staged/unstaged state survive independent restore; no source is removed. Existing migration tests must remain green after any shared-helper change.

## Acceptance

- [ ] Transaction is exercised through its actual CLI, not only mocks.
- [ ] Receipt cannot become verified without durable independently restored evidence.
- [ ] Retry, corruption, source drift and interrupted construction preserve data without duplicate captures.
- [ ] Production callers remain unchanged in this PR.

## Scope and delivery

Tier: thinking — source identity, transaction recovery and durable removal evidence are safety boundaries.
Discovery: exact producer search found the existing central full-copy implementation and four callers; no separate open producer PR was found. The Git-admin preservation prerequisite #35109 is closed. Draft PR deferred until this unit has runtime evidence.

### Files Scope

- `.agents/scripts/worktree_recovery_producer.py`
- `.agents/scripts/worktree_recovery_migration_state.py`
- `.agents/scripts/worktree_recovery_migration_scratch.py`
- `.agents/scripts/tests/test-worktree-archive-lifecycle.py`
- `.agents/scripts/tests/worktree_recovery_producer_cases.py` — focused cases imported by the existing suite; extracted after CI reported a file-complexity regression, with no new runner or fixture infrastructure

Shared helper edits outside this scope require inspection and explicit scope expansion, not copying a parallel implementation. PR references this leaf with its closing keyword and uses `For #35110` / `For #35078` for the parents. Stop at the verified PR/merge boundary; no publication or installed-store operations.
