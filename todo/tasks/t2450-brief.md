---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2450: Gate labelless-backfill on `authorAssociation` to prevent external-contributor dispatch

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `"labelless backfill author association"`, `"reconcile_labelless_aidevops_issues origin:worker"` → 0 + 1 hits — the one hit (t2112 working solution) confirms the function exists as described and has no prior author-association check.
- [x] Discovery pass: 0 merged PRs / 0 open PRs touch `pulse-issue-reconcile.sh`'s `reconcile_labelless_aidevops_issues` in last 48h. Last change was the t2112 introduction (PR #19098, 2026-04-09). Workflow `maintainer-gate.yml` was last touched by t2395 (#19989, 2026-04-19) for the `source:*` assignee-exemption — no overlap with origin:worker protection block at lines 720-793.
- [x] File refs verified: `pulse-issue-reconcile.sh:1508-1676`, `maintainer-gate.yml:720-793`, `tests/test-pulse-labelless-reconcile.sh` — all present at HEAD.
- [x] Tier: `tier:standard` — multi-file change across shell + YAML + test; branching logic + regression coverage; narrative brief sufficient, no exact oldString/newString for every edit. Disqualifiers: >2 files (3), cross-subsystem (script + workflow + test).

## Origin

- **Created:** 2026-04-20
- **Session:** opencode:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** none (standalone security fix)
- **Conversation context:** User reviewed #20180 and asked why the external contributor's issue wasn't NMR-gated. Sub-agent review confirmed `reconcile_labelless_aidevops_issues` applies `origin:worker + tier:standard` based on title shape alone with no author-association check; the server-side `origin:worker` protection handler only strips the origin label, leaving `tier:standard` intact and no NMR applied — so the issue remained dispatchable.

## What

Close the gating gap that let #20180 — an issue filed by an external CONTRIBUTOR — reach worker dispatch without maintainer review. Two code paths need hardening:

1. **Primary: `reconcile_labelless_aidevops_issues`** (`pulse-issue-reconcile.sh`) — the pulse's cycle-time label backfill for labelless aidevops-shaped issues. Currently applies `origin:worker + tier:standard + body_tags` based on title shape alone. Must check `authorAssociation` and branch behaviour by class.

2. **Defense-in-depth: `origin-worker-protection`** (`maintainer-gate.yml:720-793`) — the workflow that strips `origin:worker` when applied by a non-allowlisted actor. Currently only removes `origin:worker`; must also strip `tier:*` and apply `needs-maintainer-review` when the issue author is external, since `tier:standard` alone remaining is what enables dispatch.

Deliverable: after merge, an external-contributor-authored labelless issue titled `tNNN: ...` is backfilled with `needs-maintainer-review` + body tags only, never becomes dispatchable, and receives a distinct mentorship comment explaining the human-triage pipeline. The existing internal-author path (OWNER/MEMBER/COLLABORATOR) is unchanged.

## Why

Trust-model inversion: the framework treats "used `gh_create_issue` wrapper" as automation evidence and "bare `gh issue create`" as a bypass to backfill. External contributors always use bare `gh issue create` — they don't have or wouldn't use the internal wrapper. The `tNNN:` title convention is publicly documented in AGENTS.md. Any contributor who follows docs trips the backfill.

The protection workflow partially fires (it correctly saw alex-solovyev's runner as non-owner and stripped `origin:worker` on #20180 at 21:48:15Z), but was designed pre-t2112-backfill and only knows about `origin:worker`. The `tier:standard` label remained; no NMR applied; next pulse cycle from marcusquinn's owner-runner dispatched a worker → PR #20184 closed CONFLICTING. The fix has to land at BOTH points because either alone is evadable:

- Pulse-only fix: if a future labelling code path applies `tier:standard` without going through `reconcile_labelless_aidevops_issues`, the workflow is the only backstop.
- Workflow-only fix: the workflow only fires when `origin:worker` is labeled/unlabeled. If the pulse applied `tier:standard` without `origin:worker`, the workflow would never run.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** — No (3 source files + 1 test file)
- [x] **Every target file under 500 lines?** — `pulse-issue-reconcile.sh` is 1676 lines (target section is ~170 lines); `maintainer-gate.yml` is 793 lines (target section ~70 lines); test is 210 lines. Section-scoped edits only.
- [ ] **Exact `oldString`/`newString` for every edit?** — Approximate; the jq filter extension and branching logic require judgment, not transcription.
- [ ] **No judgment or design decisions?** — Requires choosing which author-association values classify as "external" and designing the mentorship comment template.
- [ ] **No error handling or fallback logic to design?** — Requires fallback behaviour when `authorAssociation` field is absent or unrecognised (fail-closed to "external" → NMR).
- [ ] **No cross-package or cross-module changes?** — Crosses `.agents/scripts/` + `.github/workflows/` + `.agents/scripts/tests/`.
- [x] **Estimate 1h or less?** — 2h estimated.
- [x] **4 or fewer acceptance criteria?** — 8 criteria (see below).

Not-all-checked → **tier:standard**.

**Selected tier:** `tier:standard`

**Tier rationale:** Three-file change across shell script, GitHub workflow YAML, and bash test, with branching logic and regression coverage. Narrative brief with file references is sufficient; worker doesn't need exact oldString/newString blocks. No novel design — the author-association gating pattern is well-established in the framework (see `maintainer-gate.yml:757-764` allowlist, AGENTS.md "General dedup rule" combined-signal gate).

## PR Conventions

This is a leaf (non-parent) issue. PR body will use `Resolves #20192`. The issue itself (`#20192`) does NOT carry `parent-task`, so `Resolves` is correct and will auto-close on merge.

## How (Approach)

### Worker Quick-Start

```bash
# 1. External-contributor authorAssociation values to branch on:
#    (any of these → external path; anything else → internal path)
EXTERNAL_ASSOCIATIONS="CONTRIBUTOR NONE FIRST_TIME_CONTRIBUTOR FIRST_TIMER MANNEQUIN"

# 2. Internal-contributor values (unchanged path):
INTERNAL_ASSOCIATIONS="OWNER MEMBER COLLABORATOR"

# 3. Key jq pattern — extend the existing filter at pulse-issue-reconcile.sh:1557:
# BEFORE: select((.title | test(...)) and (.labels ... length == 0))
# AFTER: same, but .authorAssociation is now in the projected fields; branch
# label-application logic per issue based on the value.

# 4. Key workflow pattern — in maintainer-gate.yml:768-784, when removing
# origin:worker for a non-allowlisted actor, also:
#   - Fetch issue author's association via gh api repos/$REPO/issues/$NUM --jq '.author_association'
#   - If external: add needs-maintainer-review + remove tier:* labels
```

### Files to Modify

- `EDIT: .agents/scripts/pulse-issue-reconcile.sh:1508-1676` — function `reconcile_labelless_aidevops_issues`. Extend jq filter to project `authorAssociation`; add `_is_external_association` helper; branch label application and mentorship comment template on association.
- `EDIT: .github/workflows/maintainer-gate.yml:720-793` — `protect-origin-worker-label` job. When removing `origin:worker` from a non-allowlisted actor, also fetch author association; if external, `--add-label needs-maintainer-review` + `--remove-label tier:simple,tier:standard,tier:thinking` in the same edit call; update notice comment template to mention the NMR application.
- `EDIT: .agents/scripts/tests/test-pulse-labelless-reconcile.sh` — add fixture issues #503 (external CONTRIBUTOR, aidevops-shaped, labelless) and #504 (external NONE, aidevops-shaped, labelless). Extend assertions: #503/#504 MUST get `--add-label needs-maintainer-review` + NO `--add-label origin:worker` + NO `--add-label tier:standard`, and MUST get the external-specific comment sentinel.
- `EDIT: TODO.md` — already added t2450 entry (done above).

### Implementation Steps

**Step 1: Keep existing `gh issue list --json` call — authorAssociation is not a supported field**

**IMPORTANT GOTCHA** (verified 2026-04-20): `gh issue list --json` does NOT support `authorAssociation`. Available fields: `assignees, author, body, closed, closedAt, closedByPullRequestsReferences, comments, createdAt, id, isPinned, labels, milestone, number, projectCards, projectItems, reactionGroups, state, stateReason, title`. The `.author` field contains `{login, id, type, is_bot}` but NOT association.

The REST API `/repos/{owner}/{repo}/issues/{number}` DOES return `author_association` directly. Precedent: `maintainer-gate.yml:776` already uses `gh api "repos/${REPO}/issues/${ISSUE_NUMBER}" --jq '.user.login'` — we extend the same pattern to fetch `author_association` per candidate.

So: keep `gh issue list --json number,title,body,labels --limit 50` as-is. The jq filter at lines 1557-1565 stays the same (no `authorAssociation` field to project). Per-candidate, add a lightweight `gh api` call to get the association. Bounded at 10 candidates per repo per cycle, which matches the existing cap.

**Step 2: Add per-candidate association fetch and class helper**

Just before the `local -a add_args=(...)` assembly inside the per-issue loop, add:

```bash
# Fetch authorAssociation for this candidate (not available on gh issue list --json).
# Fail-closed: API error or unknown value → treat as external (safer default).
local assoc
assoc=$(gh api "repos/${slug}/issues/${num}" --jq '.author_association // "NONE"' 2>/dev/null || echo "NONE")
# Treat any value we don't explicitly recognise as internal as "external" (fail-closed).
local is_external="true"
case "$assoc" in
    OWNER|MEMBER|COLLABORATOR) is_external="false" ;;
esac
```

Then split `add_args` assembly and `labels_csv` assembly on `is_external`:

```bash
local -a add_args
local labels_csv
local comment_sentinel
local comment_template_use
if [[ "$is_external" == "true" ]]; then
    # External contributor: NMR only, no origin/tier, different comment.
    add_args=("--add-label" "needs-maintainer-review")
    labels_csv="needs-maintainer-review"
    comment_sentinel='<!-- aidevops:labelless-backfill-external -->'
    comment_template_use="$external_comment_template"  # defined up-front
else
    # Internal: current behaviour (origin:worker + tier:standard + body tags).
    add_args=("--add-label" "origin:worker"
        "--remove-label" "origin:interactive"
        "--remove-label" "origin:worker-takeover"
        "--add-label" "tier:standard")
    labels_csv="origin:worker,tier:standard"
    comment_sentinel="$sentinel"  # existing <!-- aidevops:labelless-backfill -->
    comment_template_use="$comment_template"  # existing internal template
fi
if [[ -n "$body_tags" ]]; then
    # Body tags apply to both classes — they're intent signals, not trust signals.
    local _saved_ifs="$IFS"
    IFS=','
    local _t
    for _t in $body_tags; do
        [[ -z "$_t" ]] && continue
        add_args+=("--add-label" "$_t")
    done
    IFS="$_saved_ifs"
    labels_csv="${labels_csv},${body_tags}"
fi
```

Define `external_comment_template` alongside the existing `comment_template` at the top of the function:

```bash
local external_comment_template="<!-- aidevops:labelless-backfill-external -->
Thanks for filing this issue! Because it was created by a contributor outside the maintainer team, it has been labelled \`needs-maintainer-review\` pending human triage. A maintainer will review the proposal, confirm the implementation approach, and either:

- Claim a fresh internal task ID via \`claim-task-id.sh\` and file a maintainer-authored follow-up issue (you'll be credited in the thank-you comment here), or
- Request changes or additional context on this issue directly.

This gate exists because the aidevops pulse auto-dispatches workers on issues that carry maintainer-trust labels (\`origin:worker\`, \`tier:*\`). Issues from external contributors need a maintainer in the loop before dispatch to catch injection attempts, scope/trust mismatches, and speculative work the pulse shouldn't burn a worker on.

Comment idempotent — the HTML sentinel prevents duplicates on subsequent pulse cycles."
```

Update the comment-post call to use `$comment_template_use` and `$comment_sentinel`.

**Step 3: Extend `origin-worker-protection` workflow**

In `maintainer-gate.yml` between lines 768-784, after the line that removes `origin:worker`, add author-association fetch + conditional NMR + tier strip. Keep existing re-apply path (when action=unlabeled) untouched for now — re-applying origin:worker is only triggered by the author being bot or owner, both of which are trusted paths.

Replace this block:

```yaml
if [[ "$ACTION" == "labeled" ]]; then
    # Non-allowlisted actor added the label — remove it
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label "origin:worker"
    NOTICE="The \`origin:worker\` label was removed automatically. This label is reserved for issues created by the automation pipeline and cannot be applied by non-maintainer contributors."
```

With:

```yaml
if [[ "$ACTION" == "labeled" ]]; then
    # Non-allowlisted actor added the label. Fetch issue author association
    # to decide whether to also apply NMR and strip tier:* labels.
    ISSUE_AUTHOR_ASSOC=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}" \
        --jq '.author_association // "NONE"' 2>/dev/null || echo "NONE")

    # External-contributor classes (fail-closed — unknown → treat as external).
    EXTERNAL_AUTHOR="true"
    case "$ISSUE_AUTHOR_ASSOC" in
        OWNER|MEMBER|COLLABORATOR) EXTERNAL_AUTHOR="false" ;;
    esac

    if [[ "$EXTERNAL_AUTHOR" == "true" ]]; then
        # External-authored — strip origin:worker + all tier:* labels
        # in one edit, and apply needs-maintainer-review.
        gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
            --remove-label "origin:worker" \
            --remove-label "tier:simple" \
            --remove-label "tier:standard" \
            --remove-label "tier:thinking" \
            --add-label "needs-maintainer-review"
        NOTICE="The \`origin:worker\` and \`tier:*\` labels were removed automatically and \`needs-maintainer-review\` applied. This issue was filed by an external contributor (\`author_association=${ISSUE_AUTHOR_ASSOC}\`) and requires maintainer review before a worker can be dispatched. Maintainers: review the proposal, then either claim a fresh internal task or apply \`sudo aidevops approve issue ${ISSUE_NUMBER}\` after review."
    else
        # Internal-authored but non-allowlisted actor — just strip origin:worker.
        gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label "origin:worker"
        NOTICE="The \`origin:worker\` label was removed automatically. This label is reserved for issues created by the automation pipeline and cannot be applied by non-maintainer contributors."
    fi
```

**Step 4: Extend regression test**

In `tests/test-pulse-labelless-reconcile.sh`:

1. Extend `FIXTURE_ISSUES_JSON` to add `#503` (external CONTRIBUTOR) and `#504` (external NONE). The fixture JSON itself does NOT include `authorAssociation` (matches production `gh issue list` output); the per-issue association is provided by a new `FIXTURE_ASSOC_MAP` associative array / case statement in the gh stub.
2. Extend the gh stub to handle `gh api repos/.../issues/N` calls with `--jq '.author_association'`:

   ```bash
   # gh api repos/test/repo/issues/NNN --jq '.author_association...'
   if [[ "$cmd" == "api" && "$sub" == "repos/test/repo/issues/"* ]]; then
       local num="${sub##*/}"
       case "$num" in
           500|502) printf '%s' "MEMBER" ;;
           503) printf '%s' "CONTRIBUTOR" ;;
           504) printf '%s' "NONE" ;;
           *) printf '%s' "NONE" ;;
       esac
       return 0
   fi
   ```

3. Add assertions:
   - `#503` edit MUST include `--add-label needs-maintainer-review`
   - `#503` edit MUST NOT include `--add-label origin:worker` or `--add-label tier:standard`
   - `#503` comment MUST contain `aidevops:labelless-backfill-external` marker
   - Same three assertions for `#504`
   - `#500` (existing MEMBER fixture, aidevops-shaped, labelless) still gets origin:worker + tier:standard (regression on unchanged path).

### Verification

```bash
# 1. shellcheck clean:
shellcheck .agents/scripts/pulse-issue-reconcile.sh

# 2. Regression test passes:
bash .agents/scripts/tests/test-pulse-labelless-reconcile.sh

# 3. Workflow YAML syntax valid:
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/maintainer-gate.yml'))"

# 4. Manual reproduction check — confirm #20180 would now be gated correctly:
gh api "repos/marcusquinn/aidevops/issues/20180" --jq '.author_association'
# Expect: "CONTRIBUTOR" — confirms the fixture class matches reality.
```

## Files Scope

- `.agents/scripts/pulse-issue-reconcile.sh`
- `.agents/scripts/tests/test-pulse-labelless-reconcile.sh`
- `.github/workflows/maintainer-gate.yml`
- `TODO.md`
- `todo/tasks/t2450-brief.md`

## Acceptance Criteria

- [ ] `reconcile_labelless_aidevops_issues` fetches `authorAssociation` via `gh issue list --json` and branches its label-application on it.

  ```yaml
  verify:
    method: codebase
    pattern: "authorAssociation"
    path: ".agents/scripts/pulse-issue-reconcile.sh"
  ```

- [ ] External-contributor issues (CONTRIBUTOR, NONE, FIRST_TIME_CONTRIBUTOR, FIRST_TIMER, MANNEQUIN) receive `needs-maintainer-review` + body tags; NO `tier:*`, NO `origin:*`.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-labelless-reconcile.sh"
  ```

- [ ] Maintainer/member/collaborator issues keep the current behaviour (`origin:worker + tier:standard + body_tags`).

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-labelless-reconcile.sh"
  ```

- [ ] Two mentorship comment sentinels exist and are idempotent: `<!-- aidevops:labelless-backfill -->` (internal) and `<!-- aidevops:labelless-backfill-external -->` (external).

  ```yaml
  verify:
    method: codebase
    pattern: "aidevops:labelless-backfill-external"
    path: ".agents/scripts/pulse-issue-reconcile.sh"
  ```

- [ ] `origin-worker-protection` workflow strips `tier:*` and applies `needs-maintainer-review` when the actor is non-allowlisted AND the issue author is external.

  ```yaml
  verify:
    method: codebase
    pattern: "needs-maintainer-review"
    path: ".github/workflows/maintainer-gate.yml"
  ```

- [ ] `test-pulse-labelless-reconcile.sh` has fixtures for OWNER/MEMBER (existing), CONTRIBUTOR (new), NONE (new), and all pass.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-labelless-reconcile.sh"
  ```

- [ ] Shellcheck clean on `pulse-issue-reconcile.sh`.

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-issue-reconcile.sh"
  ```

- [ ] Workflow YAML syntax validates.

  ```yaml
  verify:
    method: bash
    run: "python3 -c \"import yaml; yaml.safe_load(open('.github/workflows/maintainer-gate.yml'))\""
  ```

## Context & Decisions

- **Why a separate comment template, not a single parametrised comment?** The internal comment explains the wrapper-bypass and directs the author to `gh_create_issue`. The external comment has to do the opposite — thank the reporter, explain the triage gate, clarify that maintainers own the next step. Distinct wording is clearer than a parametrised one-size-fits-all.
- **Why fail-closed on unknown `authorAssociation`?** The `authorAssociation` enum is documented by GitHub but may gain new values (e.g., `MANNEQUIN` was added mid-2020). Treating unknown values as "external" is the safe default — the only cost is an extra NMR review; the cost of the opposite (unknown → internal) is re-opening the #20180 class of bug.
- **Why not reject `origin:worker` re-apply unconditionally on external-authored issues?** The re-apply branch (`ACTION == "unlabeled"`) fires when someone REMOVES `origin:worker`. It only re-applies when `ISSUE_AUTHOR` is the bot or the repo owner — both internal-trust paths. External-authored issues never hit the re-apply path because their author doesn't match. So no change needed there.
- **Non-goals:**
  - Changing the dispatch-dedup guard or the NMR-approval flow — those already handle NMR correctly once applied. The bug is that NMR was never applied.
  - Adding `authorAssociation` to other pulse scanners — out of scope; this is the specific labelless-backfill gap.
  - Auditing other labelling code paths for the same class of bug — separate task; record as a follow-up if any are found.

## Relevant Files

- `.agents/scripts/pulse-issue-reconcile.sh:1508-1676` — target function.
- `.agents/scripts/pulse-issue-reconcile.sh:1550-1565` — jq filter to extend.
- `.agents/scripts/pulse-issue-reconcile.sh:1608-1623` — `add_args` assembly (current unconditional origin+tier).
- `.github/workflows/maintainer-gate.yml:720-793` — `protect-origin-worker-label` job.
- `.github/workflows/maintainer-gate.yml:757-764` — actor allowlist (unchanged, reference).
- `.github/workflows/maintainer-gate.yml:768-784` — action branch to modify.
- `.agents/scripts/tests/test-pulse-labelless-reconcile.sh:55-78` — fixture JSON to extend.
- `.agents/scripts/tests/test-pulse-labelless-reconcile.sh:149-199` — assertion block to extend.
- `prompts/build.txt` "Worker triage responsibility" — reinforces the principle.
- AGENTS.md "General dedup rule — combined signal (t1996)" — the trust-model context the fix aligns with.

## Dependencies

- **Blocked by:** none
- **Blocks:** (potentially) any future work that relies on the assumption that `tier:*` on an issue implies maintainer review has occurred.
- **External:** none; GitHub `authorAssociation` field is documented, stable, and already returned by `gh issue list --json authorAssociation`.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | Re-read target sections, verify `authorAssociation` in `gh issue list --json` help, confirm enum values |
| Implementation | 1h | jq filter extension, branching logic, workflow YAML edit, comment template |
| Testing | 40m | Extend fixture JSON, add assertions, run test, manual `gh api` check against #20180 |
| **Total** | **2h** | |
