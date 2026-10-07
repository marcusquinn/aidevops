<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- aidevops:brief-schema=v2 -->

# GH#33891: Fix NixOS PATH and native tool discovery

Issue: https://github.com/marcusquinn/aidevops/issues/33891

## Pre-flight

- [x] Memory recall: NixOS PATH/native binary — no matching lessons.
- [x] Discovery pass: native-Git merge checks recently changed; current patch preserves them. No matching open PATH PR was found by prework discovery. Existing source-access changes fix approvals, not NixOS executable selection.
- [x] File refs verified: existing targets read in the linked worktree; new runtime helpers have verified parent directories.
- [x] Tier: thinking — shared launch plumbing and privileged source-access tool selection require a trust-preserving cross-runtime review.
- [x] Seeded draft PR decision: skipped; implement in the owning interactive session, then publish the verified patch.

## Origin

- Created: 2026-10-07
- Created by: interactive session, at the operator's request
- Target repository: marcusquinn/aidevops
- Assignee: vladimirdulov
- Conversation context: a screenshot showed native Git at `/run/current-system/sw/bin/git`, while the merge helper defaulted to `/usr/bin/git`. The operator requests TODO, brief, assigned issue, implementation, commit, push, PR loop, and merge. No release publication is requested.

## Reproducer

On NixOS, `type -a -p git` lists aidevops Git wrappers followed by
`/run/current-system/sw/bin/git`, with no `/usr/bin/git`. The full-loop merge
helper's default native-Git path fails even though Git is installed. Starting a
helper with a minimal scheduler PATH similarly loses Nix-installed tools.
`test-runtime-env.sh` reproduces a shim-only inherited PATH and proves recovery
from synthetic Nix profiles without changing the host filesystem.

## What

Recover stable Nix profile PATH entries at shared shell, OpenCode plugin, and scheduler/service boundaries. Discover native Git without selecting framework wrappers. Remove FHS-only executable assumptions from the identified source-access and team-interface entrypoints, keeping approval and project-root validation unchanged.

## Why

Per-command native-Git overrides only hide the immediate failure. Non-login processes also lose other Nix-installed tools, and privileged code must not solve portability by trusting caller-controlled executables.

## How

### Files Scope

- `.agents/scripts/runtime-env.sh`
- `.agents/scripts/shared-constants.sh`
- `.agents/scripts/git`
- `.agents/scripts/canonical-recovery-helper.sh`
- `.agents/plugins/opencode-aidevops/runtime-path.mjs`
- `.agents/plugins/opencode-aidevops/shell-env.mjs`
- `.agents/scripts/setup/modules/schedulers-pulse.sh`
- `.agents/scripts/opencode_service_lifecycle.py`
- `.agents/scripts/source_access_core.py`
- `.agents/scripts/setup/modules/source-access.sh`
- `.agents/scripts/team-interface-buzz-worktree.sh`
- `.agents/scripts/team-interface-opencode-project-root.mjs`
- `.agents/scripts/tests/test-runtime-env.sh`
- `.agents/plugins/opencode-aidevops/tests/test-shell-env-origin.mjs`
- `.agents/scripts/tests/test_opencode_service.py`
- `.agents/scripts/tests/test-source-access-helper.py`
- `.agents/scripts/tests/test-setup-source-access-broker.sh`
- `.agents/reference/platform-support.md`
- `TODO.md`
- `todo/tasks/gh33891-brief.md`
- `todo/research/nixos-command-lookup.md`

### Reference Pattern

Follow `shared-constants.sh` shared initialization, `shell-env.mjs` guard/project PATH precedence, and `opencode_service_lifecycle.py` isolated service environments. The source-access setup module is signed standalone code: keep its system-tool lookup self-contained, and preserve its signed-release verification and non-TTY privilege refusal.

### Files to Modify

- `NEW: .agents/scripts/runtime-env.sh` — stable profiles and shim-safe native Git resolution.
- `NEW: .agents/plugins/opencode-aidevops/runtime-path.mjs` — shared plugin subprocess PATH recovery.
- `EDIT: .agents/scripts/source_access_core.py` — fixed trusted system roots for Git and SSH keygen, never caller PATH.
- `EDIT: .agents/scripts/setup/modules/source-access.sh` — self-contained trusted system lookup for signed broker setup commands.
- `EDIT: .agents/scripts/team-interface-buzz-worktree.sh` and `.agents/scripts/team-interface-opencode-project-root.mjs` — trusted Nix system Git probes.
- Other explicitly listed Files Scope targets integrate those helpers, provide scoped regression evidence, and record the issue/PR lifecycle.

### Complete Write Surface

- **Callers/readers:** `full-loop-helper-merge.sh`, `canonical-recovery-helper.sh`, `shell-env.mjs`, `schedulers-pulse.sh`, `opencode_service_lifecycle.py`, `source_access_core.py`, source-access setup and team-interface validators.
- **Writers/mutation paths:** `shell-env.mjs` and service/scheduler environment construction; source-access setup writes stay behind existing signature, ownership, consent and privilege checks.
- **Existing verification/tests:** listed `.agents/scripts/tests/` and plugin tests exercise command discovery, Git guards, service isolation, approval security and project/worktree bindings.
- **Schemas/config:** `opencode_service_state.py` retains its current service schema and identity; source-access approval formats are unchanged.
- **Generated/deployed mirrors:** `.agents/` ships to deployed agents/runtime bundles; existing services require definition regeneration and running processes retain original environments. No deployed files are hand-edited.
- **Migrations/backfills:** no schema migration; regenerate definitions from `schedulers-pulse.sh` and `opencode_service_lifecycle.py` only after authorized deployment.
- **Cleanup/rollback paths:** revert this patch and regenerate service definitions; retain `source-access.sh` staged cleanup. Do not revoke consent, delete databases, or alter privileged trust material.

### Implementation Steps

1. Finish shared profile recovery and shim-safe Git selection in `runtime-env.sh`; integrate it at shared shell, plugin and scheduler/service boundaries without changing precedence.
2. Replace security-sensitive FHS executable literals with fixed-system-root lookup in source-access and team-interface code, keeping caller PATH/overrides out of privileged selection.
3. Run the focused commands below, review trust-boundary changes independently, and record coverage limits. Commit, push, open the linked PR, resolve actionable findings, and merge without publishing a release.

### Hazards and Compatibility

- **Concurrency/atomicity:** preserve source-access staged signed-byte verification, worktree ownership checks, and isolated service environments. No new persistent coordination or concurrent state mutation is introduced.
- **Migration/rollback:** service schemas and approval formats remain unchanged; revert source and regenerate PATH definitions for rollback, leaving trust material and history intact.
- **Mixed-version/backward compatibility:** runtime bundles must include new sibling helpers; preserve macOS/FHS system precedence and use stable Nix profile aliases rather than generation paths.
- **Idempotency/retry:** repeated profile recovery adds no duplicates; preserve explicit native-Git overrides, guard/project precedence, and current retry behavior.
- **Partial failure/recovery:** missing trusted system tools fail closed. Preserve staging cleanup and non-TTY sudo refusal; do not install packages, create compatibility symlinks, or select privileged tools through caller PATH.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-runtime-env.sh
python3 .agents/scripts/tests/test_opencode_service.py
node --test .agents/plugins/opencode-aidevops/tests/test-shell-env-origin.mjs
bash .agents/scripts/tests/test-canonical-git-command-guard.sh
bash .agents/scripts/tests/test-pulse-systemd-timeout.sh
bash .agents/scripts/tests/test-launchd-sanitized-path.sh
python3 .agents/scripts/tests/test-source-access-helper.py
bash .agents/scripts/tests/test-setup-source-access-broker.sh
node --test .agents/scripts/tests/test-team-interface-buzz-worktree.mjs .agents/scripts/tests/test-team-interface-opencode-overlay.mjs
bash .agents/scripts/linters-local.sh
```

- **Surface mapping:** runtime-env and plugin tests prove profile recovery/precedence; service tests prove serialization and isolated launch; Git guard tests prove policy preservation; scheduler tests prove PATH defaults; source-access tests prove signed/privileged boundaries; team-interface tests prove project/worktree binding. Changed-file lint covers every edited source.
- **Coverage limit:** a real NixOS host is not available in this runner. Verify minimal-PATH/profile behavior and trusted system-tool selection with focused regressions and record that limitation. Run independent trust-boundary review before PR readiness.

## Acceptance Criteria

- [x] Shared launch environments recover installed tools from stable Nix profile roots without replacing guards or project-selected versions; repeated initialization does not duplicate roots.
- [x] Merge/recovery native Git resolution skips framework wrappers and preserves explicit operator overrides and all Git policy gates.
- [x] Source-access tooling works with trusted Nix system binaries and never chooses caller-controlled PATH executables or expands automatic sudo authority.
- [x] Team-interface project/worktree validation no longer requires `/usr/bin/git`, retaining repository and host/agent ownership validation.
- [x] Focused checks, changed-file quality gates, and independent trust-boundary review pass; baseline-only failures and real-host coverage limits are recorded honestly.
- [ ] TODO and brief link the issue assigned to vladimirdulov; a verified PR is committed, pushed, reviewed and merged, without release publication.

## Recoverability

Commit a recoverable implementation checkpoint before broad gates. On a safety stop preserve exact head, unfinished criteria, next safe command and the linked issue/PR. Keep the issue open until the scoped fix is verified and merged.

## Out of Scope

Full NixOS packaging support for every third-party downloaded application, installation of missing tools, global NixOS configuration changes, publication/release, and unrelated baseline runtime-discovery test repairs.
