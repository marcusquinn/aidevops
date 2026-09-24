<!-- aidevops:brief-schema=v2 -->

# t18475: Fail closed on public routine comments before Pulse worker launch

## Pre-flight

- [x] Memory recall: `routine-comment-responder pulse public comments worker authority check auto-dispatch security issue duplicate trust boundary` → 0 relevant memories.
- [x] Discovery pass: 2 recent commits touch Pulse preflight scheduling, but neither changes the routine-comment trust check; no matching open issue or PR. Prior merged routine-comment PRs addressed JSON validity, dispatch splitting, and ops filtering, not this boundary.
- [x] File refs verified: `routine-comment-responder.sh:245-274,302-326`, `pulse-ancillary-dispatch.sh:945-974`, `pulse-dispatch-preflight-lib.sh:405-410`, `dispatch-single-issue-helper.sh:224-278`, and `headless-runtime-invoke.sh:194-219,238-298` at `a77b49761`.
- [x] Tier: `tier:thinking` — author authority, data-versus-instructions, and worker confinement require a consequential trust-boundary decision; this is also a worker-dispatch path.
- [x] Seeded draft PR: skipped — an untested patch would anchor the worker to an undecided authority/isolation design.

## Origin

- **Created:** 2026-09-24
- **Session:** OpenCode interactive; security follow-up to the public-content-to-Pulse audit.
- **Created by:** AI interactive, at user request for an auto-dispatchable issue.
- **Conversation context:** The user wants public issues, comments and PRs unable to compromise the host or disclose private information or credentials. This brief fixes the demonstrated routine-comment entry point and verifies it does not bypass existing issue/PR gates; it does not claim all public-content paths are already safe.

## What

Make Pulse's routine-tracking comment responder fail closed at the boundary between public GitHub text and a tool-capable headless worker. Untrusted comments and issue context must not confer authority to run commands, modify a repository or routine schedule, read host-private data, or send credentials. Keep an auditable, safe way to respond to ordinary questions or hand them off without dropping them. Maintain the ordinary issue- and PR-dispatch trust boundaries.

## Why

`pulse-dispatch-preflight-lib.sh:405-410` invokes the comment path. `routine-comment-responder.sh:245-274` filters bot/ops comments but not author authority; `:302-326` injects both comment and issue text into a worker prompt. `:161-165` instructs that worker to edit `TODO.md` directly on `main` for change requests, and `:190-198` launches the headless `worker` role. Ordinary issue dispatch separately verifies authority in `dispatch-single-issue-helper.sh:224-278`; that guard does not protect the routine-comment path. `headless-runtime-invoke.sh:194-219,279-298` has policy-dependent sandbox/egress behavior, so a clean `HOME` or prompt guard is not proof of host containment. This is a trust-boundary gap in the current source, not an observed exploit.

## Tier

**Selected tier:** `tier:thinking`. Resolve the authorization and worker capability boundary before editing; preserve independent runtime and repository gates rather than treating model instructions or text scanning as isolation.

## How (Approach)

### Progressive Context Plan

- **Read first:** `routine-comment-responder.sh:68-203,213-335` and `pulse-ancillary-dispatch.sh:945-981` — identify both the scan and re-fetch/launch path; `dispatch-single-issue-helper.sh:224-278` — reference for a fail-closed author-authority check, not a complete substitute for containment.
- **Load only if:** `headless-runtime-invoke.sh:194-298` and `sandbox-exec-helper.sh:4-16` if any tool-capable worker remains; check what happens when process-tree sandbox/egress is unavailable. Existing `test-shared-gh-actor-authority.sh` covers the authority helper if reused.
- **Why:** public text is data, not permission; a missing API result, missing sandbox, or failed re-fetch cannot authorize a privileged fallback. Model a low-privilege response or a logged human handoff instead of silently losing the comment.
- **Stop when:** the actual eligibility check, capabilities at launch, retry/handoff semantics and focused regression command are known. Do not load unrelated Pulse subsystems.

### Files to Modify

- EDIT: `.agents/scripts/routine-comment-responder.sh:131-203,213-335` — separate untrusted content from authorized action; guard scan and definitive launch; remove the direct-main change-request instruction.
- EDIT: `.agents/scripts/pulse-ancillary-dispatch.sh:945-981` — if necessary, count only eligible launches, retain bounded retries/observability and avoid treating a blocked comment as dispatched.
- EDIT: `.agents/scripts/tests/test-routine-comment-responder-ops-filter.sh:61-137` — preserve ops and ordinary-comment regression coverage when eligibility behavior changes.
- NEW: `.agents/scripts/tests/test-routine-comment-responder-trust.sh` — focused, stubbed authority, failure, content and worker-capability matrix; model on `test-routine-comment-responder-ops-filter.sh`.
- EDIT (conditional): `.agents/scripts/headless-runtime-invoke.sh:194-298` and `.agents/scripts/tests/test-headless-runtime-helper.sh` — only if the approved reply path still launches a tool-capable worker and the existing role cannot fail closed with the required sandbox/egress/credential policy. Do not loosen other roles.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/pulse-dispatch-preflight-lib.sh:405-410` invokes `dispatch_routine_comment_responses` in `.agents/scripts/pulse-ancillary-dispatch.sh:945-981`, which scans and calls `.agents/scripts/routine-comment-responder.sh`.
- **Writers/mutation paths:** `.agents/scripts/routine-comment-responder.sh:234-236,292-326` touches per-repo response state and launches a child; its prompt currently asks the child to comment and edit `TODO.md:161-174`. Constrain both paths; no direct-main mutation.
- **Tests/fixtures:** `.agents/scripts/tests/test-routine-comment-responder-ops-filter.sh` is the existing gh-stub fixture; `.agents/scripts/tests/test-shared-gh-actor-authority.sh` and `.agents/scripts/tests/test-headless-runtime-helper.sh` apply if shared authority/runtime code is reused or changed.
- **Schemas/config:** `.agents/scripts/pulse-ancillary-dispatch.sh:951-974` reads `repos.json` and `ROUTINE_COMMENT_MAX_PER_CYCLE`; avoid adding a default-on privilege flag. If new settings are unavoidable, verify the documented config and fail-closed default.
- **Generated/deployed mirrors:** `setup.sh --non-interactive` deploys `.agents/scripts/` after merge/release; never edit the copy under the installed agent directory. Compare source and deployed behavior only at the appropriate deployment boundary.
- **Migrations/backfills:** no schema migration: the responder uses a per-repo responded-ID text file (`routine-comment-responder.sh:40-65`). Preserve existing IDs; do not mark denied/unknown comments answered merely to suppress a retry.
- **Cleanup/rollback paths:** `routine-comment-responder.sh:46-65,83-118` handles already-recorded and lookup-failed comments; rollback must restore prior safe behavior without replaying privileged requests or erasing existing responses.

### Implementation Steps

1. Establish the effective threat boundary by inspecting scan, definitive re-fetch, issue context and child launch. Apply an independent trusted-author/approval decision at launch; a scan preview or claimed author string is not authority. Treat unknown API/permission state and external author as unapproved.
2. Pick a bounded behavior for unapproved/public comments: no tool-capable worker. A read-only, credential-free/no-tools response may be retained only with a verified runtime contract; otherwise emit a content-free handoff/diagnostic and keep the comment recoverable. Never run comment or issue-body instructions as actions. Trusted change requests must use the standard authenticated Git workflow, not direct edits to `main`.
3. If an authorized response still needs tools, validate actual process-tree filesystem/secret and outbound-network controls *before* launch, with no bare/sandbox-disabled fallback or ambient host credentials. Restrict allowed destinations to required provider and scoped GitHub operations. If these guarantees cannot be established on a host, fail closed for that route and explain the safe fallback; do not claim a prompt scanner or command classifier supplies containment.
4. Add a targeted regression matrix for an external non-bot, trusted collaborator, spoofed/unknown author, missing/deleted comment, malicious issue context, and unavailable sandbox/egress/credentials. Confirm no unauthorized launch, `TODO.md` write, unexpected network route, or sensitive log body; preserve legitimate ops filtering and bounded retry/handoff.
5. Check the adjacent ordinary issue-author guard and PR review-triage gate are not bypassed by the new path. Keep their existing permissions independent; split demonstrably unrelated defects into separate worker-ready findings only with specific evidence.

### Hazards and Compatibility

- **Concurrency/atomicity:** Pulse may scan the same comment again; re-fetch and verify authorization immediately before launch. Retain existing response-ID dedup semantics, and do not race a state write against an incomplete launch.
- **Migration/rollback:** no backfill required for existing responded IDs; fail closed during rollout, then restore safe, bounded answers only after the capability boundary is verified.
- **Mixed-version/backward compatibility:** preflight and responder can be deployed at different times. Put the mandatory guard in the responder's definitive launch path so an older caller cannot bypass it; any new response-mode option defaults to the safe choice.
- **Idempotency/retry:** missing API authority or unavailable isolation must not be converted into a permanent answered state; avoid duplicate worker launches and noisy repeated comments when the failure persists.
- **Partial failure/recovery:** a missing runtime, permission service or egress backend yields a clear content-free diagnostic/hand-off, not a privileged fallback or credential-bearing error log.

### Complexity Impact

- **Target function:** `cmd_scan` in `.agents/scripts/routine-comment-responder.sh:213-279` is about 67 lines. Adding more than ~13 lines crosses the 80-line planning warning; extract authorization/eligibility into helpers before adding branches. `cmd_dispatch:286-334` is about 49 lines; keep its definitive check small.
- **Action required:** watch the existing 100-line function-complexity and 4-level nesting gates; extract rather than grow scan/dispatch or broad Pulse functions beyond limits.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-routine-comment-responder-ops-filter.sh
bash .agents/scripts/tests/test-routine-comment-responder-trust.sh
bash .agents/scripts/tests/test-shared-gh-actor-authority.sh
shellcheck .agents/scripts/routine-comment-responder.sh .agents/scripts/pulse-ancillary-dispatch.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the responder tests simulate the normal Pulse scan/re-fetch/launch with a stubbed `gh` and headless helper, exercising authorized, untrusted and infrastructure-failure paths; actor-authority tests protect the reused trust predicate; ShellCheck and changed-file lint cover the modified shell surface. If `headless-runtime-invoke.sh` changes, add its existing focused runtime test and verify the sandbox-enforcement branch before the changed-file gate.
- **Broad verification trigger:** only if shared headless isolation or egress code is changed and affects worker roles beyond this routine. In that case, run the relevant existing headless/sandbox checks first and expand gates according to demonstrated blast radius, not by default.

### Recoverability Checkpoint

- [ ] Focused responder and authority tests pass; a stubbed negative launch produces no worker invocation.
- [ ] Commit a WIP checkpoint before any evidence-triggered broad runtime gate.
- [ ] Broader isolation checks run only if shared headless runtime code changes.

### Safety-Stop Recovery

- **Original objective:** public GitHub content must not authorize workers to compromise a host or reveal private data or credentials.
- **Preserved user directions:** auto-dispatch the worker-ready fix; do not treat issue creation as authority to pause Pulse, change live configuration or publish a release.
- **Trigger and evidence:** not triggered at briefing; record any sandbox, API, fuse or resource failure without its sensitive body.
- **Completed and verified:** none of the implementation acceptance criteria are met by this brief alone.
- **Remaining acceptance criteria:** trusted-author gate, safe external path, enforced capabilities and regression evidence below.
- **Unsafe route not to repeat:** launching a normal tool-capable worker with public text before independent authorization and containment.
- **Next safe route:** content-free handoff, reduced-capability response, or a separate bounded isolation patch, with the issue left open.
- **Resume condition:** actual authority and isolation are verifiable in the runtime and the negative-path tests pass.
- **Owner and status:** assigned headless worker after canonical publication; not triggered.

### Scope Boundaries

Initial implementation map; if necessary adjacent integration is discovered, document/verify the minimal correction before editing. **Hard boundaries:** do not disable Pulse, change live configuration or credentials, reduce issue/PR review gates, edit canonical `main`, or publish a release as part of this issue without separate authority. **AI brief owner:** interactive issue filer; the worker may request a bounded scope adjustment, not infer approval from its own output.

### Files Scope

- `.agents/scripts/routine-comment-responder.sh`
- `.agents/scripts/pulse-ancillary-dispatch.sh`
- `.agents/scripts/tests/test-routine-comment-responder-ops-filter.sh`
- `.agents/scripts/tests/test-routine-comment-responder-trust.sh`
- `.agents/scripts/headless-runtime-invoke.sh`
- `.agents/scripts/tests/test-headless-runtime-helper.sh`

## Acceptance Criteria

- [ ] Authorized, routine-scoped user questions receive either a bounded safe response or a clear handoff, without granting comment text or issue text authority over the worker.
- [ ] Public/non-authorized or unverifiable comments never launch a tool-capable worker, edit `TODO.md`, or cause private data/credentials to appear in comment or log output; use a simulated external/non-bot fixture.
- [ ] A deleted comment, forged preview author, GitHub permission lookup failure, sandbox failure, or unavailable process-tree egress rejects privileged dispatch and preserves an observable recoverable state.
- [ ] Genuine maintainer change requests do not cause a worker to write directly to canonical `main`; normal PR/worktree authorization and review remain in force.
- [ ] Existing ordinary issue-author and PR-review trust checks remain independent; existing ops/audit comment filtering and legitimate reply deduplication still pass their focused tests.
