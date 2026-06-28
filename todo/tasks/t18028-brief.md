# t18028: Fix vault remote-control CI test isolation

## Origin

- **Created:** 2026-06-28
- **Session:** batch-2026-06-28
- **Created by:** ai-interactive (batch mode via /new-task --batch)
- **Task ref:** GH#25827

## What

Fix the release CI failure in the Vault Security Suite by making the vault remote-control helper test isolate each local inbox scenario. The `revoked controller` assertion must not observe stale expired messages from the prior stale-message scenario.

## Why

Release `v3.29.23` created successfully, but the release push `Code Quality Analysis` workflow failed in `Framework Validation → Vault Security Suite`. The failed log showed `test-vault-remote-control-helper.sh` reporting `revoked controller was not rejected` after retry.

Root cause: `test-vault-remote-control-helper.sh` reuses `target_dir/message-encrypted-inbox` between stale-message and revoked-controller cases. Because message IDs are random, the stale expired message can sort before the revoked message and cause `VAULT_MESSAGE_EXPIRED` to be emitted before the revoked-device check, making the revoked assertion flaky.

## Tier

**Selected tier:** `tier:standard`

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/tests/test-vault-remote-control-helper.sh` — clear `message-encrypted-inbox` before isolated stale and revoked receive checks.

### Implementation Steps

1. Before the stale-message receive assertion, remove `target_dir/message-encrypted-inbox` along with the replay cache and inbox JSON so only the stale transport message is collected.
2. Before the revoked-controller receive assertion, remove `target_dir/message-encrypted-inbox` along with the replay cache and inbox JSON so the revoked transport message cannot be masked by an earlier expired message.
3. Keep the production helpers unchanged; this is test isolation only.

### Verification

```bash
shellcheck .agents/scripts/tests/test-vault-remote-control-helper.sh
bash -n .agents/scripts/tests/test-vault-remote-control-helper.sh
git diff --check
# Runtime verifier in CI: Code Quality Analysis → Framework Validation → Vault Security Suite
```

## Acceptance Criteria

- [ ] Implementation matches the What section
- [ ] `Framework Validation → Vault Security Suite` passes in CI.
- [ ] `shellcheck .agents/scripts/tests/test-vault-remote-control-helper.sh` passes.
- [ ] `bash -n .agents/scripts/tests/test-vault-remote-control-helper.sh` passes.

## Context

- Related release: `v3.29.23`.
- Failed run: `Code Quality Analysis` for release commit `5871f3c7f`.
- Local runtime execution is blocked on this machine by missing Python `cryptography` in the default `python3`; CI has the runtime environment used by the failing gate.
