# t19058: fix(setup): ai-session deploy redeploys incrementally when canonical main advances mid-deploy instead of rolling back into a full setup

**Task ID:** `t19058` | **Issue:** GH#38607

## Origin

Interactive session (productivity mission). A manual `aidevops update` to v3.39.211 timed out after 900s waiting for the setup lock. The lock owner was an auto-update `setup.sh --stage ai-session` that ran for about 35 minutes:

1. The incremental deploy captured `current_sha=1c8d94d1e8d5` and spent 14m25s in `deploy_aidevops_agents` (05:16:15Z→05:30:40Z).
2. Canonical `main` fast-forwarded to `3a6362f78661` at 05:28:59Z (a governed merge's canonical sync).
3. Verification failed with `Runtime bundle convergence failed: source checkout HEAD 3a6362f78661 does not match release commit 1c8d94d1e8d5`. Setup rolled the consistent 1c8d94 bundle back and ran a full setup, which redeployed for another 6m56s.

Read-only classification of all 193 `falling back to full setup` events in `~/.aidevops/logs/auto-update.log`:

| Cause | Count | Last 3 days |
|---|---|---|
| stale activation refused (older candidate) | 83 | 0 |
| setup implementation changed | 43 | 3 |
| **convergence: source checkout HEAD advanced** | **35** | **5** |
| setup.sh changed | 20 | 1 |
| deploy verification: stale core plugin file | 8 | 0 |
| other | 4 | 0 |

`deploy_aidevops_agents` wall time (from `setup-stage-timings.log`): median 207–318s per day for 2026-11-12..15, then 447s with p90 864s on 2026-11-16. The host runs 14–33 deploys a day. With a multi-minute deploy and frequent merges, the canonical checkout moving mid-deploy is routine, not exceptional.

## What

Make one bundle stage describe one commit end to end, and let the ai-session verification accept that commit when the checkout has only fast-forwarded past it.

1. `_runtime_bundle_stage` resolves the full source commit once (`_AIDEVOPS_STAGED_SOURCE_SHA`). The bundle ID, manifest `git_sha`, copied tree, `aidevops.sh` and `VERSION` all come from that one short window, followed by an assertion that HEAD did not move during the copy. Before this change:
   - the manifest re-read HEAD after the npm installs;
   - `aidevops.sh` was installed after post-copy;
   - `VERSION` was copied in post-copy.

   Any of these could mix a later commit into a bundle labelled with the earlier one.
2. `_runtime_bundle_validate` compares the bundle VERSION with the version read at the pinned commit. `_verify_deployed_core_plugin_freshness` compares the 54 core plugin files with the pinned commit's Git objects (`_core_plugin_file_check`), not the live checkout.
3. `runtime-bundle-verifier.sh`: opt-in caller-local `_AIDEVOPS_RUNTIME_VERIFY_ALLOW_SOURCE_ADVANCE=1` accepts a source checkout whose HEAD is a descendant of the expected commit and records `_AIDEVOPS_RUNTIME_VERIFY_SOURCE_ADVANCED_TO`. The manifest, bundle ID, VERSION, stamp and sentinel checks still pin the expected commit. Release, update and full-loop adoption callers do not set it and keep exact equality.
4. `setup.sh` `_setup_ai_session_verify_deploy <floor_sha>`: sets the allowance and verifies the activated bundle's stamp commit when it lies between the setup-start floor and HEAD. When the checkout advanced, it prints an info line instead of rolling back. The full-setup fallback captures the floor before the full setup runs, not after.

## Why

Each race costs a rollback of a correct runtime plus a full setup: a second multi-minute deploy, plist and scheduler refreshes, and a long-held setup lock. The lock blocks manual `aidevops update` and other setup callers; the 900s lock wait exits 1. The newer commit is deployed on the next auto-update cycle either way, so the full setup buys nothing.

## How (files)

- EDIT `.agents/scripts/runtime-bundle-verifier.sh` — `_runtime_bundle_verify_source`: opt-in descendant acceptance; reset `_AIDEVOPS_RUNTIME_VERIFY_SOURCE_ADVANCED_TO` in `verify_aidevops_runtime_bundle_convergence`.
- EDIT `.agents/scripts/setup/modules/agent-deploy-bundle.sh` — new `_runtime_bundle_source_sha` and `_runtime_bundle_assert_source_unchanged`; `_runtime_bundle_write_manifest` takes an optional pinned SHA; `_runtime_bundle_validate` takes the pinned version; `_runtime_bundle_stage` pins and moves `aidevops.sh` and `VERSION` into the copy window.
- EDIT `.agents/scripts/setup/modules/agent-deploy.sh` — `_core_plugin_file_check` helper used by `_verify_deployed_core_plugin_freshness`; post-copy copies VERSION only when the stage has not already.
- EDIT `setup.sh` — `_setup_ai_session_verify_deploy` and the ai-session full-setup fallback floor.

### Files Scope

- `.agents/scripts/runtime-bundle-verifier.sh`
- `.agents/scripts/setup/modules/agent-deploy-bundle.sh`
- `.agents/scripts/setup/modules/agent-deploy.sh`
- `setup.sh`
- `todo/tasks/t19058-brief.md`
- `TODO.md`

## Acceptance

- With the allowance set, a bundle at commit X verifies when HEAD is a descendant of X. It is rejected when HEAD has diverged or when a sentinel differs. Without the allowance, any HEAD ≠ X is rejected exactly as before.
- A bundle's ID, manifest `git_sha`, `aidevops.sh` and `VERSION` all come from the same commit. A HEAD move during the copy fails the stage with an explicit message instead of producing a mixed bundle.
- Existing suites pass: `test-runtime-bundle-verifier.sh`, `test-atomic-runtime-bundle-deploy.sh`, `test-agent-deploy-staging-invariant.sh`, `test-setup-scoped-dispatch.sh`, `test-aidevops-update-transaction.sh`, `test-script-drift-detection.sh`, `test-deploy-mutex.sh`, `test-agent-deploy-pulse-runtime.sh`, `test-runtime-bundle-rollback.sh`, `test-status-runtime-bundle-integrity.sh`.
- ShellCheck clean on changed shell files.
- Post-release production signal: `Runtime bundle convergence failed: source checkout HEAD … does not match release commit` stops appearing in `auto-update.log`, and `Checkout advanced to … during deploy` appears instead.

## Non-goals

- Deploy wall time itself (bimodal 22–44s vs 416–866s) — separate investigation; copies measured at 4–7s and `du` passes at about 17s, so the cost lies in later post-copy or activation steps.
- `aidevops update`'s own post-setup verification keeps exact equality with the pulled commit.

## Verification

```bash
shellcheck -x setup.sh .agents/scripts/runtime-bundle-verifier.sh .agents/scripts/setup/modules/agent-deploy-bundle.sh .agents/scripts/setup/modules/agent-deploy.sh
for t in test-runtime-bundle-verifier test-atomic-runtime-bundle-deploy test-agent-deploy-staging-invariant test-setup-scoped-dispatch test-aidevops-update-transaction test-runtime-bundle-rollback; do bash ".agents/scripts/tests/$t.sh"; done
rg -c "source checkout HEAD [0-9a-f]+ does not match release commit" ~/.aidevops/logs/auto-update.log
```
