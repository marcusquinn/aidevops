<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Open issue backlog mission — 2026-10-03

## Authority and objective

The repository owner requested an unattended orchestrator mission to resolve all
solvable remaining open issues, complete full-loop verification and merges, make
intermediate releases when useful, and publish a final release. Preserve source,
permission, trust, billing, and worktree isolation boundaries. Do not mistake
closing an issue, dispatching a worker, or opening a PR for verified delivery.

## Baseline

- Repository: `marcusquinn/aidevops`; authenticated permission: admin/maintain/write.
- Initial inventory: 27 open issues and 8 open PRs.
- Persistent dashboards (not implementation backlog): #24670, #23855, #23404,
  #23126. Leave their routine-owned lifecycle intact.
- Pulse dispatch circuit: closed. Eligible work is repeatedly deferred by file
  overlap with stuck PRs: #33419 by #32618; #33356 by #32453.
- No issue-backed worker is launched by this mission before deduplication,
  source/brief verification, and scope assignment.

## Stable units and ownership

Concurrency cap: two independent mission workers; existing unrelated workers are
not stopped. Serialize shared-file work. Parent owns integration, review, merge,
issue disposition, release, and durable continuation.

| Unit | Issues / PRs | Scope / owner | Dependency | Tier | Status / reuse key |
|---|---|---|---|---|---|
| P1 | #33248 / #33271 | Runtime-pin helper; parent verification/merge | None | standard | Merged `f5ac9141c783`; routine-owned cleanup |
| P2 | #33150 / #33318 | Curated skill sync; parent verification/merge | None | standard | Merged `84b76dcf8468`; 36 checks and 418 links reverified |
| P3 | #33048 / #33052; #33110 | Pulse reconciliation refactor; parent integration | None | standard | Merged `19d6b2e46e91`; #33048 closed and scope verified |
| P4 | #32618 / #32643 | Plugin provenance; parent verification/merge | W7 OC2 completion | standard | Merged `8aaf3b4b958b`; OC1/OC2 rows independently selected |
| P5 | #32644 / #32702 | On-demand tool loading; parent disposition | P4 (shared plugin files) | standard | Merged `49f11d3085a5`; usage/registration-boundary correction, no ineffective deferral or claimed saving |
| P6 | #32453 / #32459 | Canonical synchronization/health; parent verification | None | standard | Merged `9d8ca71ac3f6`; preservation/auth/health fixtures independently reverified |
| P7 | #32446 / #32457 | NanoGPT probe; parent integration | None | standard | Offline scope merged `ac0bd52d58`; live criterion remains blocked, issue open |
| P8 | closed #32682 / #32756 | Quoted body flags; parent verification | P4/P5 (plugin files) | standard | Merged `45b6fdf609`; reviewed head `9f4930d2c4`, 84/84 tests and gates pass |
| W1 | #33303 / #33446 | Pre-edit manual-worker identity; parent verification | None | standard | Merged `d7ac7ce2bc8a`; scope-close verification passes |
| W2 | #33113 / #33447 | Old-bundle Pulse refills; scoped worker | None; exclude W1 ownership files | thinking | Merged `359c2e964917`; 12 parent-reverified checks; no active dispatch |
| W3 | #33356 / #33445 | Targeted backup deletion | P6 (preservation docs) | standard | Merged `1ebba531f9`; destructive execution remains opt-in |
| W4 | #33419 / #33451 | Playwright artifact path handling | P4/P5 (plugin files) | standard | Merged `86172c3e16`; external-directory boundary preserved |
| W5 | #28838 / #33327 / #33449 | Headless library canary extraction; scoped worker | Disjoint from W2's explicit files | thinking | Merged `183e65abec`; original 1966 lines, module 366; debt and duplicate consolidation closed |
| W6 | #33292 / #33441 | Browser-QA layout/viewport journey; parent verification | Supersedes closed #33436 | standard | Merged `a04b3b03bb5a`; 26 real-browser checks independently pass |
| W7 | #32619 / #33440; #32622 / #33439 | OC2 observability; tool descriptions | P4/P5/P8 (plugin files) | standard | OC2 merged `f157e301057b`; descriptions merged `9c574f0d73`, live 467-token saving verified |
| W8 | #31068 / #33457 / #33463 | Full-loop readiness extraction; scoped worker | Gate repair W10 must be merged first | thinking | Merged `b1b35bd87c`; ten function bodies byte-identical; 29 assertions and gates pass |
| W9 | #33454 / #33455 | Onboarding guide list; parent integration | None | standard | Merged `ae41781bbc`; two list lines only, normal CLI/gates pass |
| W10 | #33456 / #33458; #33450 | SKIPPED admission; parent integration | None | standard | Fix merged `3bca975837`; 29 assertions pass; TODO PR merged `fa1c15b150` |
| W11 | #33467 / #33469 | V2 SDK dependency removal; parent integration | None | standard | Merged `84ce13e94dfb`; GitHub dependency alert fixed; 27/47 focused checks and native request pass |
| W12 | #33471 | V2 compaction stable-prefix boundary; scoped worker | W11; disjoint from W13 | standard | Active local dispatch `manual-cli-33471-1791029638`; parent owns live acceptance/integration |
| W13 | #33470 | Post-compaction next-action precedence; scoped worker | Disjoint from W12 | standard | Active local dispatch `manual-cli-33470-1791029829`; parent owns live acceptance/integration |
| A1 | #33278, #32829, #32820, #32523, #32273 | Manual/upstream/runtime reviews; parent | Evidence-specific | standard | OC1 and usage aggregates collected; real OC2 compaction/cache remains active, not inferred blocked |
| A2 | #33139 | Framework value audit; parent verification | Onboarding residual W9 | thinking | Closed; final observed guide-list residual is merged |
| R1 | Final release | Canonical publisher lane; parent | All safely solvable units verified | standard | Explicit release authority from current request |

## Verification and completion

Use normal CLI/runtime paths, scoped lint and existing tests. High-risk changes
require runtime evidence and independent review. Review every included PR commit,
repair only terminal failures for the exact current head, and merge through the
full-loop helper. Existing PR issue closure requires the issue-close verifier.
No test infrastructure, guard bypasses, blanket permission grants, or spending
authority are introduced merely to finish the backlog.

For each unit, record verified disposition, immutable commit/PR evidence, tests,
remaining criteria, executor, next action, and wake condition. A real external
blocker remains open with its exact prerequisite; persistent dashboards remain
open by design. A checkpoint is continuation evidence, not mission completion.

## Verified delivery checkpoint — 2026-10-03 03:27 UTC

- #33318: exact head `307ea91038132165fe139fb8ab9033150fc9df37`, merged as
  `84b76dcf8468c7c3892a7d45fd855340dfbaf1e9`. Parent inspected curated import,
  registry ownership, scanner rejection propagation, exact retirement cleanup,
  and preservation of custom files. Re-ran 36 normal-flow regression assertions
  and all 418 nested skill links. Required checks and review gate passed.
- #33440: exact head `86ce47eefae114f74898da25c148cb403aae266c`, merged as
  `f157e301057ba0d6323174dc92f8fbeead7d0ad9`. Parent independently inspected
  released step-event projection, bounded tracking, malformed-event handling,
  replay deduplication and unchanged OC1 recording. Re-ran 49 focused checks;
  missing local dependencies were installed from the committed lockfile without
  lifecycle scripts. Review bundle:
  `e882c4430f0cc9513264bb33e66c65afa78917a00056ce4f17505f9df4fc2859`.
- Read-only production SQLite independently confirms OC2 row `1299159` has
  runtime `2.0.3`, adapter `opencode-v2@3.38.0`, and input/output `3/4`; OC1 row
  `1299197` has runtime `1.18.34`, adapter `opencode-v1@3.38.0`, and `3/4`.
  Final release/deployment remains pending; recheck fresh runtime acceptance at
  postflight rather than treating historical null rows as a backfill target.
- #33436 was closed unmerged by terminal CI-feedback routing. #33441 recovers
  its implementation and reduces Qlty smells; all reported checks are green at
  head `24a96b15a8434ba7ae255c42434ea0f514229614`. Parent review is next.
- P3 and P6 are the next independent repair units. Children own only their listed
  PR write surfaces, use fresh linked worktrees, preserve original commits, and
  fast-forward-update existing PR branches without force. They must not merge,
  release, edit this plan, delegate again, or weaken quality/security gates.

## Subsequent integration evidence

- #33441 merged as `a04b3b03bb5a20fd5f7ea0d2c0a92ce01f2dd004`. Parent recovered
  the immutable PR head through its retained pull ref after the remote branch
  was removed, inspected all three commits, and reran the normal browser journey
  CLI suite: 26 passed, 0 failed, 0 skipped. Scope-close verification passes.
- #32459 merged as `9d8ca71ac3f6d2dcd354b975cf7a73160016130f`, exact repaired
  head `2daa6c4799e4e0a08e6a9682391e3b41a6bbc002`. Parent independently reviewed
  the complete production diff, read-only convergence choice allowed by the
  brief, credential-host isolation and real-Git preservation fixture. Re-ran
  sync/auth/preservation checks plus 37 health checks; all pass. Scope-close
  verification passes. An unrelated whole-host remote scan was bounded and
  remains unverified; it is not claimed as acceptance evidence.
- #33052 recovery required one parent intervention: finish the last cited
  oversized function rather than close a 3→1 partial reduction. Final counts
  are 65, 84 and 52; all helper/cycle state remains caller-owned. Exact head
  `acbc2c70c6c944a5c3e0fd265681a211e62cbd71`, bundle
  `73587666493650a2890d5ed8a62beaa67746535ca88e89c4b35ae68fcbe074ca`.
  Required checks pass; parent marked ready and is updating the stale draft body
  before gate-enforced merge.
- W1 was dispatched by the normal consensus/ownership path at current main.
  W2's explicit write boundary excludes W1 ownership files, preserving the
  two-worker cap and preventing overlapping runtime-library edits.

## Continuation checkpoint — 2026-10-03 04:30 UTC

- Fresh inventory: 22 open issues (four persistent dashboards) and eight open
  PRs before the #33052 merge. Admin/maintain/write authority reverified.
- #33052 merged at 04:24:17 UTC as
  `19d6b2e46e91d8273d1a48d1721eda1b43fec958`; exact reviewed head is unchanged.
  Required checks and review gate pass, #33048 is closed, and the issue-close
  verifier independently matches the production file. The audited helper also
  synchronized the canonical mirror; its post-merge process exceeded 60 seconds,
  so remaining receipt finalization must be inspected rather than inferred.
- W1 has no live PID/active dispatch; successor ready PR #33446 awaits parent
  review. Other newly visible PRs #33442 and #33444 belong to existing independent
  issue workers; do not redispatch their issues.
- #33439 still explicitly requires live Anthropic OAuth token/cache evidence.
  Parent can see configured Anthropic OAuth through `opencode auth list`; run the
  existing isolated context-budget capture path rather than accepting character
  estimates or preserving a worker-only auth blocker without reassessment.
- Research child `ses_efffb0bdeffeSpCs6fKaACgZS0` cannot execute gh/Bash or the
  scanner. Its result establishes a child capability limit, not any issue blocker.
  Parent must collect A1 evidence or supply bounded, scanned research staging.

## Live verification checkpoint — 2026-10-03 04:50 UTC

- #33439 exact head `6194242cf8d77d4ac91893aff237508bbe7b7a58`: seven focused
  tests and changed-file lint pass. Live OAuth paired first-prompt totals are
  34,356→33,889 (467 fewer API tokens); cached prefixes 34,352/33,885 are reused
  in full on turn 2. Wire invariants are all true and unchanged. Six-character
  skill-catalogue variation is disclosed, not attributed to the trim. Update
  draft body from `backlog-pr33439-body.md`, mark ready and gate-merge next.
- Captures: control `oc1-backlog-32622-base-5642-{1,2}.json`; candidate
  `oc1-backlog-32622-trim-70331-{1,2}.json` in the managed context-budget directory.
  Initial Haiku capture `oc1-backlog-32622-control-76577-1.json` had only one
  request and is not full-cache acceptance evidence.
- #33446 merged independently as `d7ac7ce2bc8a3061eec96f6e6c571de8d2a02851`;
  production fix was already in #33403, and successor adds isolated regression
  coverage only. No current dispatch remains; issue scope verifies.
- W2's first dispatch launcher was cancelled before worker registration. Its
  queued self-assignment was safely released after confirming no active dispatch.
  Normal dispatch then launched PID 91163 in the 044227 worktree. Preserve the
  unused 043427 preparation worktree until guarded cleanup; no worker owns it.
- Fresh 30-day tool telemetry: 2020 active sessions; session naming 247 (12.228%),
  branch sync 34 (1.683%). Mandatory/gated tools remain excluded. P5 requires an
  evidence-based new disposition, not a replay of old assumptions.
- #33110 now has zero open function-complexity debt; close with the verified
  #33052 evidence. W5 still has real file-size debt and needs implementation.
- A1: current bodies and listed comments scanned clean. Configured Anthropic
  catalogue has no Haiku 5.5. Upstream #51430/#51431 remains open/draft with no
  maintainer review or new qualifying response. KVM issue still explicitly lacks
  operator-selected host and cost/security authority. Real-session observation
  tasks #32829/#32820 remain locally executable, not assumed external blockers.

## Continuation checkpoint — 2026-10-03 06:50 UTC

- Objective remains ACTIVE. Final release is authorized but not yet invoked.
- P5 merged at 06:32:50 as `49f11d3085a53fffc7236e2d00f24651405ccee8`.
  Parent readiness/review gate passed; another merger completed the same exact
  head before the parent merge mutation. The helper correctly refused the stale
  mutation. Fresh merged evidence and issue-close scope are verified.
- P8 head `9f4930d2c42a5c42c2e862c148724f684b1e81d0`, bundle
  `2e0be2f5d6a707ed54b9130662394195f54888db0e2f70f35d993cc2a10cb709`.
  Quote-aware scanning, literal backslash preservation and decoy-file protection
  pass 84 existing/focused assertions. Qlty regression went +5 to +3 to +1;
  the final cohesive dynamic-body extraction has no currently reported failed
  checks. Revalidate exact-head review and merge through the sanctioned helper.
- Onboarding residual is #33454 / ready PR #33455. Only two advertised guide
  entries change; normal help, unknown-guide and GitHub-guide paths plus ShellCheck
  and bash syntax pass. Its sole source worktree is the onboarding repair branch,
  not the mission documentation branch; the interactive claim was refreshed there.
- PR #33450 is a verified TODO-only publication, but the wrapper misclassifies
  required `SKIPPED` gates as terminal failures. Exact reproducer and two-file
  repair surface are in `backlog-required-skip-brief.md`; implement the narrow
  state/bucket correction and keep cancellation/unknown/pending fail-closed.
- P7's current reviewed diff is an offline-only fixture harness. No paid call,
  browser profile or credential use is authorized by the historical benchmark.
  Parent is repairing new-function shell return/argument discipline before tests,
  independent review, body clarification and conditional partial-delivery merge.
- Real-session evidence: the latest 12 OC1 summaries contain all five expected
  host headings; 11 include explicit continuation, and resumed tools are observed.
  Headless telemetry since September 28 proves Anthropic and OpenAI model use
  (including 4 Haiku, 36 Sonnet 5, 129 Sonnet 5.5 and 33 Opus sessions).
  Current compaction cost fields are local estimates, not provider invoices;
  v3.38.0 has 53 observations averaging 1853 output tokens and estimated $0.0073,
  with changed model mix. No causal 240K-target saving is inferred.
  OC2 compaction/cache remains without qualifying runtime evidence.
- Dependabot alert 133 is distinct from historic merged PR #133: GHSA-ch52-4w7c-c8xp
  affects transitive http-cache-semantics 4.2.0 under the OC2 SDK's npm-fetch graph.
  Upstream issue 56 remains open, no patched version is listed. Investigate the
  actual cache policy before attributing shared-server exposure; do not guess an
  override, dismiss the alert or expose credentials.
- #33452 runner-capability report is now closed by an independent owner; verify
  its merge evidence before relying on delivery. Persistent dashboards remain open.
- Next: finish P8 and onboarding, repair skipped-check admission and merge #33450,
  complete safe P7 delivery, document A1 evidence/real blockers, commit all mission
  artifacts, then run the canonical authorized patch release and verify channels,
  postflight and exact-tag deployment. No user clarification is currently needed.

## Continuation checkpoint — 2026-10-03 07:53 UTC

- Objective remains ACTIVE. Release is authorized but not invoked.
- P8 is merged as `45b6fdf609d20116d3028a35cd82a6ef8d24e1f6`; revalidation
  prevented a redundant attempt to mutate an already-merged PR.
- W9 merged as `ae41781bbcb04f9aafcba9413ae6182faf174368`. Required/review
  gates, canonical synchronization and closing-issue reconciliation are verified.
- W10 merged as `3bca975837d5866b3ea37152705e6aebc7dcf3b2`, reviewed head
  `afac1684930790d5c6a395c342dbaddf041120ef`. Independent bundle
  `e818d60c8ec2dff873c160f4f5b5b91ed30f2e6aa8dcc1d93823a99e1c896f3c`
  reviewed the prior head; post-rebase production and fixture bytes were proved
  identical. The 29-assertion remote-evidence suite, mapped efficient-orchestration
  suite, scoped lint and real pre-merge gate pass. Pending remains a waiting state;
  cancellation/failure/unknown skipping remain fail-closed.
- PR #33450 subsequently merged through the committed normal helper as
  `fa1c15b1505c4bc6ad8be8215489e6373d851f51`. Planning publication and canonical
  synchronization converged. No raw merge or gate bypass was used.
- P7 merged as `ac0bd52d58ad1394c914570402bb5f99944ae133`, final reviewed head
  `6f63469108aa4767887b6d3d3a9b109d3a3f14ea`. Production review bundle
  `c9916de02ac27ca574a36e36ccbb4582554a4c1c2bd6718657b1d1df03b89d90`
  found no introduced blocker. A test-only follow-up correctly moved the existing
  uninstalled-refusal assertion before installed fixtures; route suite and
  ShellCheck pass again. The PR uses a non-closing reference, and #32446 remains
  OPEN with `status:blocked`: no real transport, paid call or profile use is claimed.
- A merge's cleanup handoff deliberately changes its worktree registry owner to
  `full-loop-lifecycle`. Bounded execution then correctly refused further use of
  that worktree. Parent created a new helper-registered finalization worktree at
  current main; the guard was not disabled or bypassed, and no live owner adopted.
- W8 successor #33463 preserves the historic validator split and contributor
  attribution, then extracts only bounded readiness functions. A verified normal
  dispatch launched session `manual-cli-33463-1791013816` in the 075046 issue
  worktree. Live-process evidence now reports PID 10643; revalidate before any
  future side effect. Do not duplicate its implementation or edit its assigned files.
- Independent task #33459 appeared during the mission. A dry-run dedup check
  found it freshly assigned to @alex-solovyev; parent did not launch another
  worker. Its review helper/workflow files are disjoint from W8. Track delivery
  without stealing the active owner's claim.
- Observation evidence and exact unresolved criteria are in
  `backlog-observation-2026-10-03.md`; aggregate OC1 query is
  `backlog-session-review.sql`. These are observations, not economic causality.
- Next: complete consolidation disposition, finish A1 runtime/cache evidence and
  original unmet criteria, integrate W8 after exact-head review, reconcile the
  current inventory, commit/publish these mission artifacts, then run the canonical
  authorized release once and verify publication, postflight and exact-tag deployment.

## Integration and observation checkpoint before W11-W13

- #33459 / #33461 merged as `74bdf3df1dab7e144c47aee08c2d65a59ace550b`.
  Follow-on #33464 / #33465 merged as
  `6b1b893f67a8a9eab54361202950f619e8fea6f6`; both scope-close checks pass.
- #33463 / #33466 merged as `b1b35bd87c1ed08dd15b4946efa62f168e583cd4`.
  Parent proved all ten extracted function bodies byte-identical. The parent
  shrank 2362 to 1886 lines; the sibling is 514 lines. Syntax, ShellCheck,
  the 29-assertion remote-evidence suite, efficient-orchestration suite,
  scoped lint and exact-head merge gates pass. No worker remains active here.
- TODO-only PRs #33460 and #33462 merged as `ca5f36870c56` and `cab5b2f45e2f`.
- Current inventory is six follow-up issues plus four persistent dashboards,
  with no open PRs. Re-query before publication or another issue mutation.
- #32820's observation review now includes four current auto-compaction summary
  spot checks, seven resumed Git revalidations, model-matched request-cost and
  compaction-frequency data, and the superseding maintainer routing decision.
  Its limitations and completion rationale are in the observation artifact.
- #32829 is not complete: standalone V2 registration and actual compaction/cache
  evidence must be established, and first-tool housekeeping is distinguished
  from the observed first Bash action. Failed marker/service probes are not
  acceptance evidence. No auth or permission gate was weakened.
- Dependabot alert 133 remains high and open, without a patched version. The
  installed npm-fetch graph uses a private-cache policy; no universal safety,
  patch, dismissal or remediation claim is made.
- Release lane revalidation is inactive at terminal `v3.38.0`, source #33411.
  Publication remains authorized and pending. Finish the bounded V2 probe,
  publish this evidence PR, then invoke the canonical patch release once with
  its complete source snapshot and verify all publication/deployment receipts.

## Continuation checkpoint — 2026-10-03 12:20 UTC

- Original objective remains ACTIVE; final release is authorized and pending.
- W11 merged as `84ce13e94dfb43f8757f14b088897c8693937bfd`. Exact reviewed head
  `7f386bb4f3c676aede0185949cf21ea431a44283` passed required/review gates.
  Canonical synchronization, issue closure and guarded cleanup handoff converged.
  GitHub reports the dependency alert `fixed`; no guessed override or dismissal.
- The native V2 diagnostic did complete automatic compaction and marker-preserving
  resumption. Its compaction had zero cache reads and 135,903 cache writes; cache
  cause/repair remains open, not a successful cache-reuse criterion. Failed early
  probes are retained as historical evidence, not current runtime blockers.
- The refreshed single-session sample has nine first Bash Git revalidations, but
  the nine literal first tools were housekeeping. One complete first Bash command
  is present verbatim in its summary; this does not prove first-tool compliance.
  The old blanket byte-identity wording was corrected in the observation artifact.
- W12 owns only `v2.mjs` and its adapter test, worktree
  `aidevops-feature-auto-20261003-121444-gh33471`, launched worker PID 44303.
  W13 owns `compaction.mjs` and its existing focused test, worktree
  `aidevops-feature-auto-20261003-121803-gh33470`, launched PID 62386.
  Those PIDs and claims are point-in-time; revalidate before any side effect.
  First 60-second launch attempts ended before active dispatch; status confirmed
  no claim/worker, and bounded 120-second retries registered both real workers.
  No duplicate worker, source bypass, paid Stagehand call or provider experiment
  was authorized for either worker. Parent owns runtime evidence, review and merge.
- #33468 remains the evidence PR for completed #32820 observations. Refresh its
  proof/body, commit these amendments and briefs, rerun changed-file checks, and
  resolve the planning gate with its existing `allow-planning-close` label.
  #32829 remains open until its original review findings are dispositioned.
- Unchanged external prerequisites: #33278 supported model availability; #32523
  upstream response/release; #32446 fresh spend authority plus a verified hard
  pre-inference bound; #32273 operator-approved KVM host and billing/security scope.
  Four persistent dashboards stay open by design.
- Next: integrate W12/W13 after risk-appropriate live evidence, complete the
  manual-review disposition and evidence PR, then invoke one canonical patch
  release with the complete pinned source manifest. Verify all publication
  channels, exact-tag deployment, postflight and the terminal receipt.
