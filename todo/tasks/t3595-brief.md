---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t3595: pin LOC badge tokei installation

## Pre-flight

- [x] Memory recall: `review issue PR GH#24541 TODO worker-ready brief loc badge tokei` → 0 hits — no relevant lessons found.
- [x] Discovery pass: 0 recent commits / 0 merged PRs / 0 open PRs found by `prework-discovery-helper.sh` for `GH#24541 loc badge tokei apt install rustup cargo pinned release binary` on the target files.
- [x] File refs verified: 3 refs checked at HEAD: `.github/workflows/loc-badge-reusable.yml:111-118`, `.agents/aidevops/badges.md:124-125`, `.agents/scripts/loc-badge-helper.sh:40-42`.
- [x] Tier: `tier:standard` — workflow install hardening needs version/checksum/cache/timeout judgment plus docs and helper metadata updates; not a copy-paste `tier:simple` edit.
- [x] Seeded draft PR decision recorded: skipped — the issue review identified root cause and scope; no partial implementation is needed before worker dispatch.

## Origin

- **Created:** 2026-06-08
- **Session:** opencode:Issue #24541 review follow-up
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** — (standalone leaf for GH#24541)
- **Blocked by:** — none known
- **Conversation context:** Review of GH#24541 approved the issue as real and identified that the reusable LOC badge workflow still installs `tokei` from Ubuntu apt. The review also found missing task artifacts, so this brief makes the accepted fix worker-ready.

## What

Make the reusable LOC badge workflow install a deterministic, versioned `tokei` binary instead of relying on Ubuntu's `apt` package availability/version, and align local-development dependency guidance with that workflow reality.

The resulting workflow must still install/use `jq`, print both tool versions, and generate LOC badges through `.agents/scripts/loc-badge-helper.sh` exactly as before.

## Why

The current workflow depends on `sudo apt-get install ... tokei jq` in `.github/workflows/loc-badge-reusable.yml:111-118`. That creates CI drift risk when the Ubuntu package disappears, changes version unexpectedly, or lags behind the version expected by the helper. The reviewed solution direction explicitly rejected `curl | rustup`; workers need a pinned, auditable install path instead.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** No — workflow plus two docs/helper metadata files, with tests possibly adjusted if install commands are asserted.
- [x] **Every target file under 500 lines?** Yes for the workflow/docs; `loc-badge-helper.sh` is larger but only dependency comments are in scope unless tests reveal a needed metadata update.
- [ ] **Exact `oldString`/`newString` for every edit?** No — worker must choose the safest pinned install mechanism and checksum source.
- [ ] **No judgment or design decisions?** No — release binary vs locked Cargo install trade-off must be resolved.
- [ ] **No error handling or fallback logic to design?** No — timeout/cache/checksum behavior needs care.
- [x] **No cross-package or cross-module changes?** Yes — all changes stay in LOC badge workflow/docs/helper metadata.
- [ ] **Estimate 1h or less?** No — estimate ~2h including verification.
- [x] **4 or fewer acceptance criteria?** Yes.
- [x] **Dispatch-path classification:** No self-hosting dispatch path files are in scope.

**Selected tier:** `tier:standard`

**Tier rationale:** The change is narrow, but deterministic CI dependency installation needs judgment on pinned artifacts, checksums, cache behavior, and workflow portability.

## PR Conventions

Leaf issue — PR body should use `Resolves #24541`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The review comment and this brief provide enough implementation context; a partial workflow edit would risk anchoring the worker to an unverified install URL/checksum.
- **Status:** `not-created`
- **Freshness evidence:** Memory recall, duplicate/collision discovery, and file-ref verification completed against current worktree HEAD.
- **Verification run:** Brief-only; no workflow tests run yet.
- **Stale-assumption warning:** Re-check upstream `tokei` release assets and target workflow lines before editing; do not assume the checksum or asset naming from this brief.

## How (Approach)

### Files to Modify

- `EDIT: .github/workflows/loc-badge-reusable.yml:111-118` — replace apt `tokei` install with deterministic pinned install; keep `jq` install explicit or otherwise guaranteed.
- `EDIT: .agents/aidevops/badges.md:124-125` — update local-development dependency guidance so Ubuntu does not imply apt `tokei` is the supported CI path.
- `EDIT: .agents/scripts/loc-badge-helper.sh:40-42` — update dependency comments away from `apt: tokei` if the supported Linux install path changes.
- `NEW: .agents/scripts/tests/test-loc-badge-reusable-install.sh` — assert the reusable workflow pins `tokei`, uses locked Cargo install with timeout, and does not install `tokei` via apt.

### Current Evidence / Verified Anchors

- `.github/workflows/loc-badge-reusable.yml:111-118` currently runs `sudo apt-get update -qq`, comments that `tokei` lands in Ubuntu repos, installs `tokei jq` via apt, then prints versions.
- `.agents/aidevops/badges.md:124-125` currently documents `brew install tokei jq` and `# apt install tokei jq` for local development.
- `.agents/scripts/loc-badge-helper.sh:40-42` currently documents `tokei` as `(apt: tokei, brew: tokei, cargo: tokei)`.
- GH#24541 review approved the issue and recommended a pinned/versioned `tokei` install path, preferably release binary with checksum or locked Cargo install with timeout/cache; it explicitly discouraged `curl | rustup`.

### Implementation Steps

1. Choose the deterministic install strategy.
   - Prefer an official `tokei` release binary pinned to an explicit version and verified with a checked-in or inline expected SHA256.
   - If no suitable release asset/checksum path exists, use `cargo install tokei --version <version> --locked` with a workflow cache and an explicit timeout. Do **not** pipe remote installer scripts into a shell.
   - Keep `jq` installation reliable. Installing `jq` via apt is acceptable; the bug is the unpinned `tokei` package.

2. Update `.github/workflows/loc-badge-reusable.yml`.
   - Rename the step if needed, for example `Install pinned tokei + jq`.
   - Keep `set -euo pipefail`.
   - Print `tokei --version` and `jq --version` after installation.
   - Ensure failures are explicit when the binary download/checksum/Cargo install fails.

3. Update docs/helper dependency guidance.
   - `.agents/aidevops/badges.md` should show macOS and Linux local-development commands without claiming the workflow-supported Linux path is `apt install tokei` unless that remains intentionally true only for local use.
   - `.agents/scripts/loc-badge-helper.sh` dependency comments should mention the pinned workflow install path or `cargo --locked` path accurately.

4. Update or add regression coverage if the repo has workflow-text tests for LOC badge install commands.
   - Search for tests that assert `apt-get install ... tokei` or the old step name.
   - If none exist, add the smallest focused assertion that the reusable workflow no longer installs `tokei` via apt and contains the chosen pinned install marker/version/checksum.

### Verification

Run from repo root:

```bash
rg 'apt(-get)? install .*tokei|apt: tokei|curl .*rustup|rustup' .github/workflows/loc-badge-reusable.yml .agents/aidevops/badges.md .agents/scripts/loc-badge-helper.sh .agents/scripts/tests
.agents/scripts/tests/test-loc-badge-reusable-install.sh
bash .agents/scripts/loc-badge-helper.sh --json-only | jq .total
.agents/scripts/linters-local.sh
```

If workflow tests are added/changed, run the specific test file as well. If the install path uses Cargo, verify the workflow uses `--locked`, a fixed version, and a timeout/cache strategy.

### Files Scope

- `.github/workflows/loc-badge-reusable.yml`
- `.agents/aidevops/badges.md`
- `.agents/scripts/loc-badge-helper.sh`
- `.agents/scripts/tests/*loc*`
- `TODO.md`
- `todo/tasks/t3595-brief.md`

## Acceptance Criteria

- [ ] `.github/workflows/loc-badge-reusable.yml` no longer installs `tokei` via `apt-get install`/`apt install` and uses a pinned/versioned install path.
- [ ] The workflow does not use `curl | rustup` or equivalent remote-installer piping.
- [ ] `jq` remains available and both `tokei --version` and `jq --version` are printed before badge generation.
- [ ] `.agents/aidevops/badges.md` and `.agents/scripts/loc-badge-helper.sh` dependency guidance matches the supported install strategy.
- [ ] Relevant tests/lint pass, or any skipped checks are justified with exact blockers.

## References

- GH#24541 review comment approved the issue and identified the apt-install root cause.
- `.github/workflows/loc-badge-reusable.yml:111-118` — current unpinned install step.
- `.agents/aidevops/badges.md:124-125` — current local dependency docs.
- `.agents/scripts/loc-badge-helper.sh:40-42` — current dependency comment.
