<!-- aidevops:brief-schema=v2 -->

# fix(recovery): repo recovery policy survives the .aidevops.json untrack migration

## Pre-flight

- [x] Memory recall: `recovery policy aidevops.json untrack` → 0 relevant hits
- [x] Discovery pass: last changes to `recovery-policy-helper.sh` came from GH#35129; 0 open PRs touch it
- [x] File refs verified: `recovery-policy-helper.sh:125-152`, `aidevops-cli/aidevops-project-config-lib.sh:183-190`, `aidevops-cli/aidevops-init-lib.sh:1468,1539`, `tests/test-recovery-policy.sh:55-124` present at HEAD
- [x] Tier: `tier:standard`
- [x] Seeded draft PR decision recorded: skipped (interactive session implements directly)

## Origin

- **Created:** 2026-11-16
- **Created by:** ai-interactive (productivity mission, GH#38332 follow-up)
- **Conversation context:** The blocker-recovery decision audit showed that most recovery outcomes go back to the maintainer, even when the repo has already delegated those decisions to AI.

## What

`recovery-policy-helper.sh` still reads `.aidevops.json` `recovery_policy` from the remote default branch. When `.aidevops.json` is missing there (HTTP 404) or has no `recovery_policy` key, it falls back to the conventional tracked document `.agents/recovery-policy.md`, heading `Recovery policy`, at the same pinned revision. If neither exists it returns 3 (no policy), as today. A declared fallback document that is invalid fails closed (1). The untrack migration issue body tells repos that declare `recovery_policy` to move the policy to the conventional document in the same PR.

## Why

- The framework gitignores `.aidevops.json` on init (`aidevops-init-lib.sh:1539`), and `aidevops update` files "stop tracking .aidevops.json" migrations for repos that still track it (`aidevops-project-config-lib.sh:147-198`). GH#35129 reads the policy pointer only from that file on the default branch, so every migrated repo silently loses its delegated recovery authority.
- Observed case: a managed private repo wired its policy in `.aidevops.json` (its PR on 2026-11-10), then merged the framework's untrack migration the next day. `recovery-policy-helper.sh <repo>` now returns 3. Of 40 terminal-blocker recovery decisions recorded on this runner in the last 24h, 30 were `wake=human_decision`. Many ask the maintainer to "choose exhausted-outlier hold or supply an approved source", which is exactly the `outlier_hold` action the repo already delegated. Each one costs maintainer attention that the repo's own policy says AI should spend.

## Tier

**Selected tier:** `tier:standard`. **Tier rationale:** a small loader change at a trust boundary, with existing mocked tests to extend.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/recovery-policy-helper.sh`: in `recovery_policy_load`, when `.aidevops.json` returns `RECOVERY_POLICY_NONE` or lacks the key, use `path=.agents/recovery-policy.md` and `heading="Recovery policy"`. A document 404 → return 3; any other failure → 1. Keep `.aidevops.json` precedence, the write-access check and revision pinning unchanged.
- `EDIT: .agents/scripts/tests/test-recovery-policy.sh`: mock `contents/.agents/recovery-policy.md`. Cases: no config + no conventional doc → 3; no config + valid doc → 0 with `.path == ".agents/recovery-policy.md"`; config without key + invalid doc → 1; a declared config pointer still wins over the conventional doc.
- `EDIT: .agents/reference/recovery-policy.md`: document the fallback location and why it exists (`.aidevops.json` is local and gitignored).
- `EDIT: .agents/scripts/aidevops-cli/aidevops-project-config-lib.sh`: the migration body adds one line: if `.aidevops.json` declares `recovery_policy`, move that section's json block to `.agents/recovery-policy.md` under `# Recovery policy` in the same PR.

### Complete Write Surface

- **Callers/readers:** `terminal-blocker-recovery-helper.sh:820` (`_tbr_policy_enabled`), and the supervisor prompt in `pulse-wrapper-cycle.sh:273` (it invokes the helper; the contract is unchanged).
- **Writers:** none (read-only helper).
- **Schemas/config:** `aidevops-config.schema.json` `recovery_policy` description is unchanged; the fallback needs no config key.
- **Generated/deployed mirrors:** deployed via `setup.sh`.
- **Migrations/backfills:** managed repos that lost their pointer add `.agents/recovery-policy.md` (separate repo change).
- **Cleanup/rollback paths:** revert the PR; repos fall back to exit 3 as today.

### Hazards and Compatibility

- **Trust boundary:** unchanged. Policy is read only after the write-access check, only from the pinned default-branch commit, and never from a PR checkout. The fallback path is a fixed constant, not user input.
- **Precedence:** an explicit `.aidevops.json` pointer always wins, so no repo's current behaviour changes.
- **Fail closed:** an invalid conventional document → 1, as for a declared document.

### Verification

```bash
bash .agents/scripts/tests/test-recovery-policy.sh
bash .agents/scripts/tests/test-terminal-blocker-circuit.sh
shellcheck .agents/scripts/recovery-policy-helper.sh .agents/scripts/tests/test-recovery-policy.sh .agents/scripts/aidevops-cli/aidevops-project-config-lib.sh
.agents/scripts/linters-local.sh --changed
```

### Files Scope

- `.agents/scripts/recovery-policy-helper.sh`
- `.agents/scripts/tests/test-recovery-policy.sh`
- `.agents/reference/recovery-policy.md`
- `.agents/scripts/aidevops-cli/aidevops-project-config-lib.sh`

## Acceptance Criteria

- [ ] With no remote `.aidevops.json`, a valid `.agents/recovery-policy.md#Recovery policy` loads (exit 0) at the pinned revision; without it the helper returns 3.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-recovery-policy.sh"
  ```

- [ ] An explicit `.aidevops.json` `recovery_policy` pointer still takes precedence; all existing fail-closed cases still return 1.
- [ ] Read-only access still fails closed before any contents read.
- [ ] ShellCheck is clean and `linters-local.sh --changed` passes.
