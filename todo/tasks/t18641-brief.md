# t18641: GH#34180 Leaf C: interactive worktree add never provisions node_modules (controller-not-owner)

Issue: GH#34224 | Parent: GH#34180

## What

Leaf C of #34180. Interactive `worktree-helper.sh add` never provisions `node_modules` from the canonical checkout: `_provision_worktree_node_modules` refuses before the validator runs because the registered worktree owner is the session runtime, not the helper process. Make the existing bounded, controller-owned snapshot provisioning actually run for the worktree that `cmd_add` has just created and verified, without weakening the ownership trust boundary.

## Why

Observed in the #34199 end-to-end run (fixture npm project; OpenCode session): every admission reported `JS_TOOL_READINESS=blocked:snapshot-controller-not-owner`, and the pre-change deployed helper also left `node_modules` unrestored. Root cause by code trace:

- `_cmd_add_verify_created_generation` (`.agents/scripts/worktree-helper-add.sh`, `rg -n "_cmd_add_verify_created_generation\(\)"`) registers the owner through `_resolve_worktree_owner_pid ""`, which returns `OPENCODE_PID` or the AI runtime grandparent (`.agents/scripts/shared-worktree-registry.sh`, `rg -n "^_resolve_worktree_owner_pid"`).
- `_provision_worktree_node_modules` requires `owner_pid == $$` (the `worktree-helper.sh` process) and then `worktree_has_exact_owner_contract "$wt_path" "$$" ...`, which also requires a non-empty session and task ID. Interactive adds without `--issue` have an empty task ID.
- Result: the restore loop in `cmd_add` is effectively dead for interactive sessions, so the first visible failure is the pre-push lint gate (the #34180 symptom). #34199 now names the refusal (`reason=controller-not-owner`) instead of hiding it.

## How

1. Pass the exact registration contract that `cmd_add` just created and verified (`registered_owner_pid`, `registered_owner_session`, `registered_task`, `registered_created_at` in `_cmd_add_verify_created_generation`) to the provisioner as the expected owner, instead of assuming `$$`. Re-check that exact contract (and the process start token) immediately before publish, as the function does today.
2. Keep refusing foreign, live-other, continuation or changed owners; keep the no-existing-destination check, the validator, staging, snapshot comparison and atomic no-replace publish unchanged. Mark the changed check with `#aidevops:trust-boundary`.
3. Decide explicitly how an empty task ID (interactive add without `--issue`) is handled; record the decision in the PR body. Do not relax the contract to "any owner".
4. Touch the shared registry helper only if a contract helper must accept an explicit expected owner; the pulse lock test is regression-only.
5. Leave the pulse worker path (`_dlw_restore_worktree_deps` in `.agents/scripts/pulse-dispatch-worker-launch.sh`) behaviourally unchanged unless the same defect is proven there with evidence.

### Files Scope

- `.agents/scripts/worktree-helper-add.sh`
- `.agents/scripts/shared-worktree-registry.sh`
- `.agents/scripts/tests/test-worktree-js-dependency-bootstrap.sh`
- `.agents/scripts/tests/test-pulse-dispatch-worker-launch-lock.sh`

## Acceptance

- [ ] Positive: interactive-style `cmd_add` (owner = runtime PID, exact contract registered by this add) provisions an eligible npm/pnpm snapshot and `worktree-js-readiness-helper.sh probe` reports `ready` for a fixture with complete tooling.
- [ ] Negative: a foreign or changed owner contract between registration and publish still refuses with a named reason; no copy occurs.
- [ ] Regression: validator budgets (64 MiB / 20000 entries) unchanged; `bash .agents/scripts/tests/test-pulse-dispatch-worker-launch-lock.sh` and `python3 .agents/scripts/tests/test-worktree-dependency-provision.py` pass; no canonical mutation.

## Verification

```bash
bash .agents/scripts/tests/test-worktree-js-dependency-bootstrap.sh
bash .agents/scripts/tests/test-pulse-dispatch-worker-launch-lock.sh
python3 .agents/scripts/tests/test-worktree-dependency-provision.py
shellcheck .agents/scripts/worktree-helper-add.sh .agents/scripts/shared-worktree-registry.sh && git diff --check
```

## Tier

`tier:thinking` — ownership trust-boundary change on the controller provisioning path.
