<!-- aidevops:brief-schema=v2 -->

# t18135: Preserve privacy scanning through native gh reads

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `27804 privacy gh recursion` → 1 hit — prior review confirmed both nested reads recurse and posting comments reproduced the fail-open warning
- [x] Discovery pass: 0 relevant commits / 0 relevant merged PRs / 0 relevant open PRs supersede the two affected call sites
- [x] File refs verified: 8 refs checked against current `origin/main`, all present
- [x] Tier: `tier:standard` — four coordinated shell/test surfaces and a privacy safety gate disqualify `tier:simple`, but the design decision is resolved
- [x] Seeded draft PR decision recorded: skipped — security-sensitive code should be implemented with focused tests in the worker worktree

## Origin

- **Created:** 2026-07-15
- **Session:** OpenCode interactive review and auto-dispatch handoff
- **Created by:** AI DevOps (ai-interactive), directed and cryptographically approved by the maintainer
- **Parent task:** None; leaf task for GH#27804
- **Blocked by:** None
- **Conversation context:** Review confirmed that the active shim sentinel blocks both `gh auth status` and the subsequent `gh api` cold probe, causing `_shim_privacy_scan` to treat public visibility as unknown and allow the write without scanning public-target content.

## What

Give `privacy_is_target_public()` an optional trusted native-gh execution path and have `_shim_privacy_scan()` supply its already-validated `REAL_GH`. Use that path for both authentication and repository-visibility reads while preserving standalone helper behavior, cache semantics, native resolver guarantees, and the recursion sentinel.

## Why

Every cold-cache shim privacy check currently re-enters the PATH shim and exits 126. The helper logs a false unauthenticated warning and the write path fails open, bypassing public-target secret/privacy scanning. Fixing only the first nested call would merely move failure to the repository API call.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The native binary contract and expected behavior are decided, but implementation spans shim/helper boundaries and must preserve security, cache, standalone, and error semantics.

## PR Conventions

Leaf task: title the implementation PR `t18135: ...` and use `Resolves #27804`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** No untested security-gate implementation should be pre-seeded.
- **Status:** `not-created`
- **Freshness evidence:** Current shim/helper/test call sites checked on 2026-07-15.
- **Verification run:** The review reproduced recursion/fail-open warnings; implementation tests are unrun.
- **Stale-assumption warning:** Re-check native resolver/recursion changes if `.agents/scripts/gh` changes before dispatch.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/gh:461,899-954` — pass the resolved native executable into the privacy target check.
- `EDIT: .agents/scripts/privacy-guard-helper.sh:71-148` — accept optional native-gh path and use it for both cold reads.
- `EDIT: .agents/scripts/test-privacy-guard.sh:264-361` — add stubbed cold-cache public/private/auth/API tests without network.
- `EDIT: .agents/scripts/tests/test-gh-shim.sh:341-357` — integration test that ordinary recursion stays blocked while the internal privacy probe reaches native gh.

### Complete Write Surface

- **Callers/readers:** `_shim_privacy_scan` in `.agents/scripts/gh` is the affected nested caller; standalone hooks/scripts call `privacy_is_target_public` with only a URL and must retain PATH behavior.
- **Writers/mutation paths:** The helper writes `~/.aidevops/cache/repo-privacy.json` through `_privacy_cache_write`; the shim only passes an executable capability and scans write content.
- **Tests/fixtures:** `.agents/scripts/test-privacy-guard.sh` owns target classification/cache behavior; `.agents/scripts/tests/test-gh-shim.sh` owns native resolution and recursion integration.
- **Schemas/config:** Cache `{private, checked_at}` schema and return codes 0/1/2 remain unchanged; no new persistent config.
- **Generated/deployed mirrors:** `setup.sh` deploys both scripts; edit only repository sources.
- **Migrations/backfills:** N/A because the cache schema is unchanged and existing entries remain valid.
- **Cleanup/rollback paths:** N/A for data cleanup because no new state is introduced; rollback reverts the optional executable contract and shim call together.

### Implementation Steps

1. Extend the helper contract with an optional executable path (second argument preferred) and select it only after validating non-empty/executable input; otherwise preserve ordinary `gh` lookup.

```bash
privacy_is_target_public() {
	local url="$1"
	local gh_bin="${2:-gh}"
	# Existing parse/cache logic.
	# Use "$gh_bin" for BOTH auth status and api repos/${slug}.
	return 0
}
```

2. In `_shim_privacy_scan`, call `privacy_is_target_public "$target_url" "$REAL_GH"`. Do not export a global bypass and do not relax `_AIDEVOPS_GH_SHIM_ACTIVE` handling.
3. Preserve return codes/log messages, but distinguish genuine native-gh auth/API failure from recursive shim failure in tests.
4. Add hermetic native-gh stubs that record argv and return public/private/unauthenticated/API-error fixtures. Assert both cold reads use the supplied executable and cache hits make neither read.
5. Add a shim integration fixture where public classification succeeds and secret-material scanning executes, while a direct recursive shim invocation still exits 126.

### Hazards and Compatibility

- **Concurrency/atomicity:** Existing cache write atomicity is unchanged; executable selection is local to one call.
- **Migration/rollback:** No migration. Revert both caller and optional parameter together.
- **Mixed-version/backward compatibility:** One-argument standalone callers continue resolving `gh`; the shim on the same deployed bundle passes native `REAL_GH`.
- **Idempotency/retry:** Cache semantics and retry-on-next-call behavior remain unchanged; no global shim-disable state leaks to children.
- **Partial failure/recovery:** Native auth/API failures still return unknown/fail-open as documented, but recursive failure must be eliminated and public positive paths must execute content scanning.

### Complexity Impact

- **Target function:** `privacy_is_target_public` and `_shim_privacy_scan`.
- **Current line count:** Both are below the 100-line function threshold but `_shim_privacy_scan` is substantial.
- **Estimated growth:** Net +10-25 production lines.
- **Projected post-change:** Keep executable selection in a tiny helper if validation adds branches.
- **Action required:** Do not move resolver logic into the privacy helper or grow the recursion guard.

### Verification Before Dispatch

```bash
bash .agents/scripts/test-privacy-guard.sh
bash .agents/scripts/tests/test-gh-shim.sh
bash .agents/scripts/tests/test-gh-shim-native-resolution.sh
shellcheck .agents/scripts/gh .agents/scripts/privacy-guard-helper.sh .agents/scripts/test-privacy-guard.sh .agents/scripts/tests/test-gh-shim.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Privacy tests prove cold/cache/error behavior; shim tests prove native routing plus recursion invariant; native-resolution suite protects #27479; ShellCheck/lint cover shell safety.
- **Broad verification trigger:** Not required unless resolver ordering, cache schema, or shared privacy scan APIs beyond this optional argument change.

### Recoverability Checkpoint

- [ ] Focused tests pass: `bash .agents/scripts/test-privacy-guard.sh && bash .agents/scripts/tests/test-gh-shim.sh`
- [ ] WIP commit created before broad gates: `wip: route privacy probes through native gh`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Restore public-target privacy scanning on cold-cache shim writes without weakening recursion safety.
- **Preserved user directions:** Auto-dispatch the maintainer-approved fix.
- **Trigger and evidence:** Not triggered; if a security test fails, stop only merge/dispatch continuation, preserve the branch and evidence.
- **Completed and verified:** None at brief creation.
- **Remaining acceptance criteria:** All criteria below until implementation verification completes.
- **Unsafe route not to repeat:** Bypassing or exempting the recursion guard globally.
- **Next safe route:** Use explicit native executable injection with hermetic tests.
- **Resume condition:** Focused privacy, shim, and native-resolution tests pass.
- **Owner and status:** Auto-dispatch worker; not-triggered.

### Files Scope

- `.agents/scripts/gh`
- `.agents/scripts/privacy-guard-helper.sh`
- `.agents/scripts/test-privacy-guard.sh`
- `.agents/scripts/tests/test-gh-shim.sh`

## Acceptance Criteria

- [ ] A cold-cache shim privacy check uses the resolved native executable for both `auth status` and `api repos/...`, then runs public-target content scanning.
- [ ] Cached public/private results retain current return codes and make no native gh calls before TTL expiry.
- [ ] Genuine unauthenticated/API failures retain documented unknown/fail-open behavior, while no recursive false-auth warning occurs on the positive path.
- [ ] Direct recursive shim entry still exits 126 and #27479 native-resolution tests remain green.
- [ ] Focused tests, ShellCheck, and changed-file lint pass.

## Context & Decisions

- Fix both nested reads; auth-only remediation is incomplete.
- `command gh` and `AIDEVOPS_GH_SHIM_DISABLE=1 gh` do not solve this ordering because recursion is checked first.
- Preserve the recursion sentinel and inject the already-resolved native capability instead of adding broad read exceptions.

## Relevant Files

- `.agents/scripts/gh:89-95` — fail-closed recursion sentinel.
- `.agents/scripts/gh:461-464` — trusted native `REAL_GH` resolution.
- `.agents/scripts/gh:899-954` — privacy scan caller and fail-open target handling.
- `.agents/scripts/privacy-guard-helper.sh:80-148` — cache plus both nested gh reads.
- `.agents/scripts/test-privacy-guard.sh:264-361` — current cache/target tests.
- `.agents/scripts/tests/test-gh-shim.sh:341-357` — current recursion regression.
- `.agents/scripts/tests/test-gh-shim-native-resolution.sh` — #27479 invariant.

## Dependencies

- **Blocked by:** None.
- **Blocks:** Reliable public-target privacy/secret scanning for shim-mediated GitHub writes.
- **External:** No credentials beyond the existing authenticated gh environment; tests are hermetic.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | Reconfirm helper callers and native resolver contract |
| Implementation | 50m | Optional executable path and shim wiring |
| Testing | 50m | Cold cache, recursion, native resolution, lint |
| **Total** | **2h** | |
