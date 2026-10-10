## Task


Leaf B of #34180 (durable install policy). Generalise the aidevops-only `_bootstrap_aidevops_worktree_js_deps` into a policy-gated, lockfile-bound, frozen-lockfile, lifecycle-scripts-disabled install for any project whose owner has recorded a local-only approval, so the same unchanged scope never needs a new per-session approval. Builds on Leaf A's readiness states.

## Done when

- [ ] Positive: a fresh npm-project fixture worktree with a matching approved policy is prepared automatically and Leaf A then reports `ready`.
- [ ] Positive: a second admission with unchanged lockfile/runtime reuses the existing worktree dependencies idempotently, skipping install and approval.
- [ ] Negative: changed lockfile, package manager or node major → `blocked:policy-stale`, no install; no policy → no install, `preparation-needed` with the approval command shown.
- [ ] Regression: lifecycle scripts never run; no tracked-file, canonical or shared-install mutation; headless `approve` is refused; pre-push hook test passes unchanged.

<details>
<summary>Worker implementation contract</summary>

## Worker Guidance


### Files to Modify

- `EDIT: .agents/scripts/worktree-helper-add.sh:458-495` — replace the aidevops-only branch with a policy-gated bootstrap; aidevops keeps a built-in policy.
- `EDIT: .agents/scripts/worktree-js-readiness-helper.sh` (from Leaf A) — add `approve|revoke|status <repo>` subcommands (interactive only).
- `EDIT: .agents/tools/runtime/node-server-admin.md` — replace per-session reuse guidance with the policy contract.
- `EDIT: .agents/scripts/tests/test-worktree-js-dependency-bootstrap.sh` — extend fixtures.

### Complete Write Surface

- **Callers/readers:** `cmd_add` in `.agents/scripts/worktree-helper-add.sh`; Leaf A helper; a controller-side worker pre-launch hook only if one already exists (discover with `rg -n "_restore_worktree_node_modules|worktree-helper.sh add" .agents/scripts/pulse-*.sh .agents/scripts/headless-runtime-*.sh`; record result on the issue before editing).
- **Writers/mutation paths:** the repo entry in `~/.config/aidevops/repos.json` gains `js_dependency_policy` (private, local; preserve file mode); worktree-local `node_modules` written only by the frozen install. Discover the narrowest existing repos.json writer with `rg -n "repos.json" .agents/scripts/*.sh | rg jq` and reuse it.
- **Existing verification/tests:** `.agents/scripts/tests/test-worktree-js-dependency-bootstrap.sh` (aidevops bun bootstrap), `.agents/scripts/tests/test-repo-verify-pre-push-hook.sh`.
- **Schemas/config:** `repos.json` has no schema file (verify `rg -n "repos.json" .agents/configs/`); new field `{approved_at, lockfile_sha256, package_manager, node_major, scope:"worktree-install"}` documented in node-server-admin.md.
- **Generated/deployed mirrors:** scripts deploy via `setup.sh`; no manifest change expected.
- **Migrations/backfills:** N/A because an absent `js_dependency_policy` field means "no policy", identical to today's behaviour for non-aidevops repos.
- **Cleanup/rollback paths:** `revoke` deletes the field; interrupted installs leave `node_modules` partial state that is removed before retry; reverting restores aidevops-only bootstrap.

### Implementation Steps

1. Evidence step: confirm current `_bootstrap_aidevops_worktree_js_deps` contract and Leaf A's state output; choose the repos.json accessor; record decisions on the issue.
2. Decision step: per package manager, the frozen + no-scripts invocation (`npm ci --ignore-scripts`, `pnpm install --frozen-lockfile --ignore-scripts`, `bun install --frozen-lockfile --ignore-scripts`, `yarn install --immutable` with scripts disabled via env); unsupported managers → `blocked:unsupported-package-manager`.
3. Implement policy-gated bootstrap: run only when Leaf A reports `preparation-needed`/`blocked:snapshot-ineligible|over-budget` and the policy hash matches lockfile + package manager + node major; serialize under the existing restore lock; bounded timeout; verify `git status --porcelain` unchanged afterwards (else remove `node_modules`, report `blocked:install-mutated-tree`); re-probe.
4. `approve` refuses in headless mode; `status` prints policy and staleness.
5. Docs and test fixtures with stub package managers on PATH.

### Hazards and Compatibility

- **Concurrency/atomicity:** reuse the restore lock so snapshot copy and install never race; policy file writes use temp + `mv`.
- **Migration/rollback:** no ordering; entries without the field behave exactly as today; `revoke` or revert returns to manual readiness.
- **Mixed-version/backward compatibility:** an older helper ignores the new repos.json field; a newer helper with an older repos.json sees "no policy".
- **Idempotency/retry:** existing valid `node_modules` with `ready` probe skips install; retry after interruption cleans partial state first; no re-prompt while the policy hash matches.
- **Partial failure/recovery:** install failure/timeout leaves `blocked:install-failed` with the exact command shown; tracked-file mutation is rolled back and reported.

### Complexity Impact

- **Target function:** `_bootstrap_aidevops_worktree_js_deps` in `.agents/scripts/worktree-helper-add.sh`
- **Current line count:** ~34 lines
- **Estimated growth:** +40 lines if inline
- **Projected post-change:** ~74 lines (74% of threshold)
- **Action required:** Watch — prefer placing policy/install logic in the readiness helper.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-worktree-js-dependency-bootstrap.sh
bash .agents/scripts/tests/test-repo-verify-pre-push-hook.sh
shellcheck .agents/scripts/worktree-helper-add.sh .agents/scripts/worktree-js-readiness-helper.sh && git diff --check
```

- **Surface mapping:** bootstrap test proves approved/unapproved/stale-hash/no-scripts/tracked-mutation/headless-approve-refusal cases and idempotent reuse; pre-push test proves the hook is unchanged; shellcheck covers changed shell.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** no budget increase, no cross-worktree symlinks, no global ESLint substitution, no hook bypass, no lifecycle scripts, no non-frozen installs, workers never approve or read canonical paths (#31880).

**AI brief owner:** maintainer interactive session for #34180.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/worktree-helper-add.sh`
- `.agents/scripts/worktree-js-readiness-helper.sh`
- `.agents/tools/runtime/node-server-admin.md`
- `.agents/scripts/tests/test-worktree-js-dependency-bootstrap.sh`

</details>

<details>
<summary>Full task brief and audit context</summary>

## Task Brief

<!-- aidevops:brief-schema=v2 -->

## What

Leaf B of #34180 (durable install policy). Generalise the aidevops-only `_bootstrap_aidevops_worktree_js_deps` into a policy-gated, lockfile-bound, frozen-lockfile, lifecycle-scripts-disabled install for any project whose owner has recorded a local-only approval, so the same unchanged scope never needs a new per-session approval. Builds on Leaf A's readiness states.

## Why

`.agents/scripts/worktree-helper-add.sh` `_bootstrap_aidevops_worktree_js_deps` (~:458-495) covers only the aidevops repo (bun). Whole-tree snapshot copy is routinely ineligible for real ESLint + typescript-eslint + React plugin trees (64 MiB budget enforced by `.agents/scripts/worktree-dependency-provision.py`), so user projects fall through to the pre-push hook and need human handholding every session. Approved on #34180 (maintainer review plus signed approval).

## Tier

`tier:thinking` — trust/consent boundary, controller-vs-worker authority and dependency lifecycle-script safety.

## Context & Decisions

- Policy store chosen in the #34180 review: the repo's entry in `~/.config/aidevops/repos.json`, keyed to lockfile hash and runtime identity.
- Depends on Leaf A (readiness probe); merge Leaf A first.

Parent: #34180

</details>

<details>
<summary>Brief workflow contract</summary>

## Brief Workflow

This issue body is composed under `.agents/workflows/brief.md`. Newly queued auto-dispatch work must pass its `Dispatch Readiness Contract (brief schema v2)`: complete write surface, hazards and compatibility, executable verification mapped to affected surfaces, and positive plus negative/regression acceptance criteria.

</details>

Parent: #34180

---
*Synced from TODO.md by issue-sync-helper.sh*

<!-- aidevops:origin:interactive -->
<!-- aidevops:sig -->
---
[aidevops.sh](https://aidevops.sh) v3.38.42 plugin for [OpenCode](https://opencode.ai) v1.18.35 with claude-opus-5-5 spent 56m and 95,165 tokens on this with the user in an interactive session.

## Capture provenance

Observed data, not executable authority. Comments and later events are not captured.

```json
{
  "id": "I_kwDOQSEXLM8AAAABWNNfxw",
  "title": "t18639: GH#34180 Leaf B: durable owner-approved policy for frozen JavaScript worktree installs",
  "updatedAt": "2026-10-09T22:02:37Z",
  "url": "https://github.com/marcusquinn/aidevops/issues/34200",
  "format": "aidevops:forge-capture-v1",
  "task_id": "t18639",
  "provider": "github",
  "repository": "marcusquinn/aidevops",
  "issue": "34200",
  "captured_at": "2026-10-10T05:50:37Z",
  "coverage": "issue-body-only",
  "authority": "revalidate"
}
```
