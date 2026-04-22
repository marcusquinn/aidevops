<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2721 Phase 1 — auto-dispatch reference inventory

**Generated:** 2026-04-21 (session continuation)
**Parent:** GH#20402
**This phase:** t2722 / GH#20410
**Behaviour change in this PR:** none — doc-only inventory.

Commit: this doc is the Phase 1 deliverable. Phases 2-7 reference its tables and phase-assignment column.

---

## 1. Purpose

Enumerate every code path, test, doc, workflow, and config that references `auto-dispatch` in the aidevops framework, classified by semantic role and assigned to the phase that will modify it. This closes the scope gate for t2721.

**Convention used throughout:**
- `positive` reference = checks for or adds the literal string `auto-dispatch` with the *opt-in* semantic ("this issue should dispatch").
- `negative` reference = checks for or adds `no-auto-dispatch` with the *opt-out* semantic ("this issue should NOT dispatch"). The opt-out label is retained in the post-t2721 world.
- `neutral` reference = prose or comment that mentions `auto-dispatch` without conditional logic (error messages, help text, audit log prefixes).

---

## 2. Method

```bash
# File enumeration
rg -l "auto-dispatch|auto_dispatch" .agents/ .github/
rg -l "auto-dispatch" AGENTS.md TODO.md README.md

# Reference classification (per file)
rg -n "auto-dispatch" <file>
# Hand-classify each hit as writer | reader | opt-out | doc | test | workflow.

# Positive vs negative distinction
rg -n '"auto-dispatch"|'\''auto-dispatch'\''|#auto-dispatch' <file>    # positive
rg -n "no-auto-dispatch" <file>                                          # negative
```

---

## 3. Writers — code paths that ADD the `auto-dispatch` label

All of these must be updated in **Phase 5** (scanner / wrapper strip) unless the inventory reveals a semantic that should be retained as a future opt-in signal.

| File | Line | What it does | Phase |
|---|---|---|---|
| `.agents/scripts/approval-helper.sh` | 345 | `gh issue edit ... --add-label "auto-dispatch"` after removing NMR | 5 |
| `.agents/scripts/auto-decomposer-scanner.sh` | 326 | Files decomposer issues with `--label "auto-dispatch,tier:thinking,${SCANNER_LABEL},origin:worker"` | 5 |
| `.agents/scripts/gh-failure-miner-helper.sh` | 1074 | `LAUNCHD_LABELS_CSV="auto-dispatch"` for launchd-generated issues | 5 |
| `.agents/scripts/pulse-nmr-approval.sh` | 545 | `--add-label "auto-dispatch"` in `auto_approve_maintainer_issues` after removing NMR | 5 (see risk §12.2) |
| `.agents/scripts/pulse-simplification-state.sh` | 433 | `--label "function-complexity-debt" --label "$tier_label" --label "auto-dispatch"` | 5 |
| `.agents/scripts/pulse-simplification.sh` | 1739 | `--label "function-complexity-debt" --label "auto-dispatch" --label "tier:thinking"` | 5 |
| `.agents/scripts/issue-sync-helper.sh` | 273-278 | Tag-to-label mapping: `parent-task \| meta \| auto-dispatch \| no-auto-dispatch \| no-takeover` are all protected from cleanup | 5 (remove `auto-dispatch`, keep `no-auto-dispatch`) |

**Count:** 7 writer sites across 7 files.

---

## 4. Readers — code paths that CHECK for `auto-dispatch`

### 4.1 Self-assignment carveouts (the three t-numbered skips)

All three skip self-assignment when the label is present. Invert in **Phase 6** to: skip self-assignment UNLESS an explicit `assignee:` hint is in the TODO entry.

| File | Line | Carveout | Task ID | Phase |
|---|---|---|---|---|
| `.agents/scripts/claim-task-id-issue.sh` | 52-67 | `_auto_assign_issue` skip when `TASK_LABELS` contains `auto-dispatch` | t2218 | 6 |
| `.agents/scripts/claim-task-id-issue.sh` | 133-161 | `_interactive_claim_issue` skip (t2132 Fix B) when auto-dispatch label | t2132 | 6 |
| `.agents/scripts/issue-sync-helper.sh` | 581-590 | `_push_auto_assign_interactive` skip when `all_labels` contains `auto-dispatch` | t2157 | 6 |
| `.agents/scripts/shared-gh-wrappers.sh` | 511-520 | `gh_create_issue` skip when `_gh_wrapper_args_have_label "auto-dispatch"` | t2406 | 6 |

**Count:** 4 carveouts across 3 files (claim-task-id-issue.sh has 2).

### 4.2 Interactive session helper — t2218 heal

The `post-merge` path in `interactive-session-helper.sh` unassigns PR authors from `(origin:interactive + auto-dispatch)` issues to work around t2218.

| File | Line | Behaviour | Phase |
|---|---|---|---|
| `.agents/scripts/interactive-session-helper.sh` | 1240, 1300-1346 | `post-merge` heal: unassign author if issue has `origin:interactive` + `auto-dispatch` + no active status | 6 |

Once the `auto-dispatch` label stops being treated as a dispatch gate (Phase 4) AND self-assignment stops being conditional on it (Phase 6), this heal becomes a no-op. Remove in Phase 6 or leave as a dead branch that logs-and-skips (Phase 7 decides final form).

### 4.3 Reconciliation — triage-missing counter

| File | Line | Behaviour | Phase |
|---|---|---|---|
| `.agents/scripts/pulse-issue-reconcile.sh` | 298, 427, 483 | `is_triage_missing` check: `origin:interactive AND no tier AND no auto-dispatch AND no status:*` | 4 or 7 |

This is a *telemetry* counter — it increments a stat. Not a dispatch gate. In post-t2721 world the "no auto-dispatch" clause becomes vacuous. Remove the clause in Phase 4 (or 7); the rest of the detector (tier check, status check) stays.

### 4.4 Dispatch core — NOT a reader

Critical confirmation: `.agents/scripts/pulse-dispatch-core.sh` has exactly **1** reference to `auto-dispatch`, and it is a **comment** on line 79:

```shell
# $1 - comma-separated label list (e.g., "bug,tier:simple,auto-dispatch")
```

No functional check against `auto-dispatch` in the core dispatch path. Confirms the summary's claim that the candidate selector (`list_dispatchable_issue_candidates_json` in `pulse-repo-meta.sh`) is label-agnostic for opt-in purposes — it filters on BLOCKERS (`status:blocked`, `needs-*`, `supervisor`, `persistent`, `routine-tracking`, etc.) only.

**Implication for Phase 4:** the behaviour flip is primarily a doc change + removal of writer sites, not a dispatch-core rewrite. The only `pulse-*.sh` file that needs a logic edit is `pulse-issue-reconcile.sh:427` (telemetry detector).

**Count (readers):** 4 carveouts + 1 heal + 1 telemetry = 6 reader sites across 4 files.

---

## 5. Opt-out references (`no-auto-dispatch`) — RETAIN

The `no-auto-dispatch` label is the canonical opt-out in the post-t2721 world. All references below are RETAINED. Listed here for completeness so a future reader doesn't confuse opt-out references with opt-in references.

| File | Refs | Role |
|---|---|---|
| `.agents/scripts/interactive-session-helper.sh` | ~19 | `lockdown` / `unlock` apply/remove `no-auto-dispatch`; help text |
| `.agents/scripts/issue-sync-helper.sh` | 2 | Tag-to-label mapping; label protection |
| `.agents/AGENTS.md` | 262 | Documents `lockdown` semantics |

**Policy:** anything that references `no-auto-dispatch` (with the `no-` prefix) is out of scope for removal. Only the *positive* `auto-dispatch` references are in scope for t2721.

---

## 6. Docs — inconsistency map

The core doc inconsistency the user identified:

| File | Line | Says | Default |
|---|---|---|---|
| `.agents/AGENTS.md` | 102 | "Always add `#auto-dispatch` unless an exclusion applies" | **default-on** |
| `.agents/workflows/save-todo.md` | 31 | "**Default to `#auto-dispatch`** — omit only when..." | **default-on** |
| `.agents/workflows/plans.md` | 64 | "Add `#auto-dispatch` only when ALL inclusion criteria pass..." | **gated** |
| `.agents/workflows/plans.md` | 99 | "Only add `#auto-dispatch` if the brief has at least 2 specific acceptance criteria..." | **gated** |
| `.agents/workflows/new-task.md` | 108 | "Only add `#auto-dispatch` if brief has: (1) 2+ acceptance criteria..." | **gated** |
| `.agents/workflows/new-task.md` | 136 | Example TODO: `#feature #interactive #auto-dispatch` | (example) |

**Additional doc refs to update in Phase 7 (non-contradictory but teach the tag):**

| File | Line(s) | Role |
|---|---|---|
| `.agents/AGENTS.md` | 111, 154, 171, 262 | Documents t2157/t2218/t2406 carveouts, interactive-claim MANDATORY rule, t2211 parent-task rule, lockdown scope limitation |
| `.agents/workflows/brief.md` | 77 | Example TODO entry |
| `.agents/workflows/log-issue-aidevops.md` | 37, 62 | When auto-dispatch should/shouldn't be applied |
| `.agents/workflows/autoresearch.md` | 169 | Auto-dispatch application for research issues |
| `.agents/workflows/autoagent.md` | 94 | Auto-dispatch default guidance |
| `.agents/workflows/routine.md` | 96 | Auto-dispatch for routine-generated issues |
| `.agents/workflows/runners-check.md` | 30, 34, 41, 49, 81 | Health-check auto-dispatch semantics |
| `.agents/reference/planning-detail.md` | 25, 27 | Full tagging criteria |
| `.agents/reference/gh-audit-log.md` | 25, 30, 86, 132 | Audit-log label filter semantics |
| `.agents/reference/cross-runner-coordination.md` | 321 | Cross-runner dispatch coordination note |
| `.agents/templates/brief-template.md` | 129 | Brief template auto-dispatch guidance |
| `.agents/tools/code-review/code-simplifier.md` | 127, 152, 156 | Simplifier emits auto-dispatch issues |
| `.agents/tools/code-review/coderabbit.md` | 71 | CodeRabbit feedback auto-dispatch |
| `.agents/tools/build-agent/build-agent.md` | 137 | Agent-creation tagging guidance |
| `.agents/aidevops/onboarding.md` | 133 | Onboarding tutorial mentions tag |
| `.agents/aidevops/orchestration-analysis.md` | 83 | Analysis doc |
| `.agents/services/email/email-actions.md` | (TBD) | Email-triggered issue creation |
| `.agents/content/distribution-youtube-pipeline.md` | (TBD) | Content-generated issue tagging |

**Count (docs):** 21 unique doc files; 4 contradictory (AGENTS.md, save-todo.md vs plans.md, new-task.md); 17 teaching-but-consistent files.

---

## 7. Tests — assertion direction map

All 20 test files are in `.agents/scripts/tests/`. Classification of what each asserts:

### 7.1 Asserts the CURRENT (opt-in) behaviour — INVERT in Phase 7

| Test | Asserts |
|---|---|
| `test-auto-dispatch-no-assign.sh` | `issue-sync-helper.sh` path: auto-dispatch label → no self-assign |
| `test-gh-create-issue-auto-dispatch-skip.sh` | `gh_create_issue` path: auto-dispatch label → no self-assign |
| `test-claim-task-id-autodispatch.sh` | `claim-task-id.sh` path: auto-dispatch → no self-assign (t2132/t2218) |
| `test-interactive-session-post-merge.sh` | `post-merge` heal unassigns author when `origin:interactive + auto-dispatch` |
| `test-auto-decomposer-scanner.sh` | Decomposer-filed issues get `auto-dispatch` label |
| `test-parent-tag-sync.sh` | `parent-task` tag applies `parent-task` label AND NOT `auto-dispatch` — partial invert needed (parent assertion stays; auto-dispatch assertion changes to "label not added by framework") |

**Count:** 6 tests to invert.

### 7.2 References auto-dispatch incidentally (as a test fixture label)

These tests use `auto-dispatch` as a convenience label in fixtures but don't assert its dispatch semantic. Adjust in Phase 7 only if fixtures break after the flip.

| Test | Usage |
|---|---|
| `test-dispatch-dedup-multi-operator.sh` | Fixture label |
| `test-enrich-dedup-guard.sh` | Fixture label |
| `test-issue-sync-pull-seeds-orphans.sh` | Fixture label |
| `test-issue-sync-tier-extraction.sh` | Fixture label |
| `test-label-invariants.sh` | Fixture label (protected-label list) |
| `test-pulse-dispatch-core-bot-cleanup.sh` | Fixture label |
| `test-pulse-dispatch-core-force-dispatch.sh` | Fixture label |
| `test-pulse-merge-fix-worker-dispatch.sh` | Fixture label |
| `test-pulse-nmr-automation-signature.sh` | Tests `pulse-nmr-approval.sh` behaviour (partial — assertion at line ~50 that NMR removal re-adds `auto-dispatch`; depends on §12.2 decision) |
| `test-pulse-sweep-budget.sh` | Fixture label |
| `test-gh-wrapper-rest-fallback.sh` | REST fallback test; fixture label |
| `test-tier-label-dedup.sh` | Tier-label dedup; fixture |
| `test-shellcheckrc-parity.sh` | Parity check |

**Count:** 13 tests with incidental references.

### 7.3 Unclassified (needs per-file read)

| Test | Notes |
|---|---|
| `test-staleness-check.sh` | 3 refs — classify during Phase 7 |

**Grand total tests:** 20 files. 6 inverts + 13 incidental + 1 unclassified.

---

## 8. GitHub Actions workflows

Both workflows STRIP the `auto-dispatch` label when their triage gate rejects an issue/PR. Behaviour to flip in Phase 5 or 7:

| Workflow | Line | Behaviour |
|---|---|---|
| `.github/workflows/issue-triage-gate.yml` | 122-123 | Removes `['status:available', 'auto-dispatch']` on triage failure |
| `.github/workflows/pr-triage-gate.yml` | 93-94 | Removes `['status:available', 'auto-dispatch']` on triage failure |

Post-t2721: invert to ADD `no-auto-dispatch` on rejection (the explicit opt-out). The current remove-auto-dispatch approach is effectively a no-op in the new world because nothing will be adding `auto-dispatch` in the first place.

**Count:** 2 workflows.

---

## 9. TODO.md

`TODO.md` contains **944** occurrences of `auto-dispatch` (line-matches), predominantly historical `#auto-dispatch` tags on completed tasks. These are bookkeeping — no behavioural impact.

**Policy:** do not bulk-rewrite historical `#auto-dispatch` tags. They are accurate audit trail for how tasks were labelled at the time of creation. Phase 7 updates only the top-level guidance and templates.

---

## 10. Writer helpers not currently in scope

Files that `rg` matched but don't actually write the label (only read or reference in comments):

| File | Refs | Role |
|---|---|---|
| `.agents/scripts/bundle-helper.sh` | 6 | Comments/documentation references |
| `.agents/scripts/dashboard-freshness-check.sh` | 1 | Comment |
| `.agents/scripts/gh-audit-log-helper.sh` | (several) | Audit log filter examples; query-string reference |
| `.agents/scripts/label-sync-helper.sh` | 2 | Label existence check (creates label if missing) |
| `.agents/scripts/new-task-helper.sh` | ~2 | Comment |
| `.agents/scripts/onboarding-helper.sh` | 3 | Onboarding tutorial prose |
| `.agents/scripts/pulse-dispatch-large-file-gate.sh` | 1 | Comment |
| `.agents/scripts/pulse-prefetch-infra.sh` | 1 | Comment |
| `.agents/scripts/pulse-prefetch-secondary.sh` | 1 | Comment |
| `.agents/scripts/pulse-triage.sh` | 1 | Comment |
| `.agents/scripts/self-evolution-helper.sh` | 1 | Comment |
| `.agents/scripts/test-staleness-check.sh` | 3 | Staleness test fixture |
| `.agents/scripts/worktree-helper.sh` | 1 | Comment |

**Phase assignment:** 7 (comment + doc sweep). No behaviour edits needed for these.

---

## 11. Phase map (rollup)

| Phase | Code edits | Doc edits | Test edits | Workflow edits |
|---|---|---|---|---|
| 2 (opt-out vocab) | 0 | `reference/dispatch-blockers.md` (NEW) | 0 | 0 |
| 3 (backfill) | 0 | 0 | 0 | 0 (one-shot API call) |
| 4 (pulse flip) | `pulse-issue-reconcile.sh` (telemetry) + `pulse-dispatch-core.sh` (comment only) + feature flag wiring | 0 | Add Phase 4 feature-flag test | 0 |
| 5 (scanner strip) | 7 writer files | 0 | Update/remove `test-auto-decomposer-scanner.sh` assertion | 0 |
| 6 (self-assign invert) | `claim-task-id-issue.sh` (2 sites), `issue-sync-helper.sh` (1 site), `shared-gh-wrappers.sh` (1 site), `interactive-session-helper.sh` (post-merge heal) | `AGENTS.md` lines 111, 154, 171, 262 | Invert 4 carveout tests | 0 |
| 7 (doc + test sweep) | 13 "comment-only" files (§10) | 17 teaching-but-consistent docs (§6) + 4 contradictory docs + `brief-template.md` | 13 incidental-reference tests + `test-staleness-check.sh` | 2 workflows |

**Edit counts by phase:**
- Phase 2: 1 file NEW
- Phase 3: 4 GH API calls, 0 file edits
- Phase 4: 2 files edited + 1 test added
- Phase 5: 7 files edited + 1 test adjusted
- Phase 6: 4 files edited + 4 tests inverted
- Phase 7: 34 files edited (13 code-comment + 17 teaching-docs + 4 contradictory-docs + template) + 14 tests + 2 workflows

Phase 7 is the largest. May need to split — flag for re-plan after Phase 6 lands.

---

## 12. Risks and open questions

### 12.1 `gh-failure-miner-helper.sh` infrastructure advisories (gh-failure-miner-helper.sh:878, 898, 932, 1074)

The helper *explicitly does NOT add* `auto-dispatch` to infrastructure advisory issues (lines 898, 932 both comment "Never add `auto-dispatch` — infrastructure outages self-resolve; code changes are wrong"), but DOES add it for launchd-derived issues at line 1074.

**Question for Phase 5:** does the launchd-issues path still need a dispatch signal, or should all gh-failure-miner issues become "silent until a human triages"? Recommend the latter — consistent with the t2721 principle that opt-in dispatch labels are vestigial.

### 12.2 `pulse-nmr-approval.sh:545` — NMR auto-approval re-adds the label

`auto_approve_maintainer_issues` currently adds `auto-dispatch` when removing `needs-maintainer-review`, intentionally overriding body prose like "Do NOT `#auto-dispatch`" (see `AGENTS.md:171` "Maintainer-authored research tasks MUST use `#parent`"). The t2211 rule says `#parent` is the only reliable dispatch block in this path.

**Question for Phase 5:** once dispatch is default-on (post-Phase 4), the auto-approval path no longer needs to ADD `auto-dispatch` — but should it instead ensure the issue isn't accidentally blocked by something else? Phase 5 should audit the approval path end-to-end.

**Impact on t2211:** the `parent-task` label remains the reliable block (its `PARENT_TASK_BLOCKED` short-circuit in `dispatch-dedup-helper.sh` is independent of `auto-dispatch`). Phase 5 removes a side-effect but the guarantee persists.

### 12.3 `pulse-issue-reconcile.sh:427` — triage-missing counter line edit

The triage-missing telemetry checks `origin:interactive AND no tier AND no auto-dispatch AND no status:*`. Once `auto-dispatch` is irrelevant, the detector becomes `origin:interactive AND no tier AND no status:*`. Value as a triage signal: arguably INCREASED, because every unlabelled interactive issue is now a dispatch candidate and "did the maintainer mean to dispatch it?" is a real question. Phase 4 may want to *rename* the counter (`triage_missing` → `tier_missing_interactive`) rather than just remove the `auto-dispatch` clause.

### 12.4 Doc sweep size (Phase 7)

17 teaching-but-consistent docs + 4 contradictory + 13 code-comment + 14 tests + 2 workflows = 50 files in Phase 7. That exceeds the "one coherent PR" target. **Likely split into 7a (docs), 7b (tests), 7c (workflows + code comments)** when Phase 6 lands and Phase 7 is scoped in detail.

### 12.5 Backward compatibility — old contributor docs

Contributors who cloned the repo months ago and read `.agents/workflows/plans.md` will still have the gated-add instruction in their muscle memory. The retained label acceptance (no error on presence) means their tagged-issues continue to work. But the framework stops teaching the tag. Add a one-line deprecation note to `AGENTS.md` ("Historical: `#auto-dispatch` is a no-op retained for backward compat; dispatch is now default-on, see `reference/dispatch-blockers.md` for opt-outs").

### 12.6 Third-party observers

The `aidevops.sh` plugin and any external monitors that filter GitHub events by `auto-dispatch` label will see the label stop appearing on new issues. Not a blocker (their filter can also match `no-auto-dispatch` absence, i.e., "any open issue not explicitly blocked"), but flag in the Phase 4 PR body so external consumers can adjust.

### 12.7 The t2157/t2218/t2406 carveouts are LOGIC DEBT

Phase 6 is the unwind. The three carveouts were individually sound fixes for a broken coupling between `origin:interactive` + assignment + dispatch. Once dispatch is default-on, the coupling dissolves — auto-assignment on interactive origin becomes safe again because "dispatch dedup gate" (AGENTS.md "combined signal — t1996") already handles the "active claim blocks worker" invariant without needing `auto-dispatch` as a discriminator.

**Expected Phase 6 net change:** 4 carveouts REMOVED, 1 new test added that asserts the correct t1996 dedup behaviour. Net lines deleted > lines added.

---

## 13. Scope-confirmation checklist for Phase 2+

This inventory covers:
- [x] All `.agents/scripts/*.sh` references (46 files, classified)
- [x] All `.agents/scripts/tests/*.sh` references (20 files, classified)
- [x] All `.agents/**/*.md` references (21 files, classified)
- [x] All `.github/workflows/*.yml` references (2 files, classified)
- [x] `TODO.md` reference count (bookkeeping only)
- [x] Top-level docs (AGENTS.md)
- [x] Positive vs negative reference distinction
- [x] Phase assignment per reference
- [x] Risk enumeration

**Known gap:** `services/email/email-actions.md` and `content/distribution-youtube-pipeline.md` were matched by `rg -l` but not opened for line-by-line classification. Flagged for Phase 7 spot-check.

**Gate:** Phase 2 may proceed.
