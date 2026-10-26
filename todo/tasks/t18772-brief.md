# t18772: Permission holds — withdraw non-grantable requests, scratch-temp bash/read recovery, batch withdrawal

## Origin

- **Created by:** ai-interactive (maintainer-approved)
- **Issue:** GH#35676
- **Conversation context:** A maintainer cleared 12 stale `needs-maintainer-permissions` holds on a managed project repo. Each `--withdraw` needed its own sudo prompt and its own `WITHDRAW` confirmation. One hold (a `task`/`playwright` request) could not be withdrawn at all. Three holds came from workers touching scratch temp paths through `bash`/`read`.

## What

1. **Non-grantable requests can be withdrawn.** Split request validation into an identity check (schema, target, request id, digest, worker binding) and a grantability check. Withdrawals need only identity; grants need both. `verify-permissions` returns `WITHDRAWN` for a valid signed withdrawal of a non-grantable request, and `MALFORMED_REQUEST` otherwise.
2. **Non-grantable request comments print the withdraw command.**
3. **Scratch temp recovery covers `bash` and `read`** on `tmp`/`temp` paths outside `node_modules`. Caches stay excluded for `bash`/`read` because they hold real dependency content and keep the node_modules provisioning route.
4. **Batch withdrawal:** `sudo aidevops approve permissions batch --withdraw [--all-blocked] [issue:<n>:perm-<id> ...] [owner/repo]`. It preflights each request, shows one summary, takes one `WITHDRAW` confirmation, signs each request individually and kicks pulse once. There is no batch grant.

## Files Scope

- `.agents/scripts/approval-helper-permissions.sh`
- `.agents/scripts/approval-helper-commands.sh`
- `.agents/scripts/worker-permission-helper.sh`
- `.agents/reference/dispatch-blockers.md`
- `.agents/scripts/tests/test-permission-grant-verification.sh`
- `.agents/scripts/tests/test-worker-permission-helper.sh`

## Acceptance Criteria

- A signed withdrawal of a valid `task` request yields `WITHDRAWN`. Without one it yields `MALFORMED_REQUEST`, and such requests are never classified grantable.
- A scratch `external_directory` request via `bash`/`read` takes the owned-recovery path. Credential, `.git`, `..`, cache and `node_modules` paths are excluded.
- `approve permissions batch` refuses without `--withdraw`. It skips non-latest or missing requests before confirmation and signs N withdrawals after one confirmation.

## Verification

- `shellcheck` on the changed scripts
- `bash .agents/scripts/tests/test-permission-grant-verification.sh`
- `bash .agents/scripts/tests/test-worker-permission-helper.sh`
- `bash .agents/scripts/tests/test-approval-permissions-module.sh`
- `bash .agents/scripts/tests/test-permission-approval-content-binding.sh`
