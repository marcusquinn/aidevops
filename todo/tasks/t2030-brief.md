---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2030: refactor(maintainer-gate): move Check -1 out of the empty-linked-issues branch (P1)

## Origin

- **Created:** 2026-04-13
- **Session:** OpenCode:interactive (same session as t2015/t2018/t2027/t2028/t2029)
- **Created by:** marcusquinn (ai-interactive, gap-closing per build.txt policy clarification)
- **Parent task:** none
- **Conversation context:** During the gap-closing pass I identified a documented-vs-implemented mismatch in `maintainer-gate.yml` (P1 in the session's gap list). `.agents/prompts/build.txt` says "`origin:interactive` implies maintainer approval — PRs tagged `origin:interactive` pass the maintainer gate automatically when the PR author is `OWNER` or `MEMBER`, no separate sudo approval needed." But Check -1 in `maintainer-gate.yml:164-191` is NESTED inside `if [[ -z "$LINKED_ISSUES" ]]`, so the exemption only fires for PRs with no linked issues. For PRs WITH linked issues + origin:interactive + OWNER/MEMBER (the common maintainer flow), the gate falls through to the full linked-issue check loop and the maintainer still has to assign + approve every linked issue. The user chose Option 1 ("build.txt rule is source of truth") when I presented the policy question. This task ships that policy change.

## What

Check -1 (the `origin:interactive` + OWNER/MEMBER exemption) applies to ALL PRs, not just PRs without linked issues. A maintainer opening an interactive PR for an externally-reported bug passes the maintainer gate on first Job 1 run without needing `sudo aidevops approve issue` on every linked issue. The PR itself becomes the approval signal; the maintainer being present and directing the work is the trust boundary.

End-state: a PR with `origin:interactive` label AND `authorAssociation == OWNER/MEMBER` short-circuits the gate with success regardless of whether it has linked issues. COLLABORATOR PRs are unaffected — they still go through the full gate (same as before).

## Why

**The documented-vs-implemented mismatch.** `.agents/prompts/build.txt`:

> **`origin:interactive` implies maintainer approval**: PRs tagged `origin:interactive` pass the maintainer gate automatically when the PR author is `OWNER` or `MEMBER` — the maintainer was present and directing the work. No separate `sudo aidevops approve` is needed. Contributors (`COLLABORATOR`) with `origin:interactive` still go through the normal gate — the label alone is not sufficient.

The current `maintainer-gate.yml:164-191` implementation only fires the exemption when `LINKED_ISSUES` is empty. For the common case — maintainer opens an interactive PR that links an externally-reported issue — the exemption does NOT apply and the maintainer still needs to sudo-approve every linked issue.

**Impact per hit.** During the t2015 `/pr-loop` in THIS session:
1. PR #18474 opened, `origin:interactive`, author OWNER, linked to externally-reported #18429.
2. Gate ran, fell through Check -1 because `LINKED_ISSUES=18429` (not empty).
3. Gate blocked on `Issue #18429 has needs-maintainer-review`.
4. User ran `sudo aidevops approve issue 18429` (~30s of context switch + sudo password prompt).
5. Gate re-ran (via t2018 fix) and passed.

With this fix, steps 3–5 are eliminated. The user opens the PR, sees the gate pass, merges. That's ~1 minute saved per maintainer-authored fix on an externally-reported bug, compounding over every external-bug triage.

**Security model unchanged.** The existing `PR_AUTHOR_ASSOCIATION == OWNER/MEMBER` check in the Check -1 block is the security boundary. `COLLABORATOR` with `origin:interactive` still falls through to the full gate. A malicious collaborator cannot set `origin:interactive` and bypass — their `authorAssociation` doesn't clear the check. The only PRs that gain the shortcut are those where a maintainer (OWNER or MEMBER) explicitly set the label during an interactive session, which already carries the trust signal.

## Tier

### Tier checklist

- [x] **≤2 files to modify?** — 1 file: `.github/workflows/maintainer-gate.yml`
- [x] **Complete code blocks for every edit?** — yes, exact before/after diff below
- [x] **No judgment or design decisions?** — the user picked Option 1 (build.txt is source of truth); the move is mechanical
- [x] **No error handling or fallback logic to design?** — no new paths, just a move
- [x] **≤1h estimate?** — ~25 minutes
- [x] **≤4 acceptance criteria?** — exactly 4

**Selected tier:** `tier:simple`

**Why simple despite workflow-security scope:** the change is a lexical move. The existing security-boundary condition (`PR_AUTHOR_ASSOCIATION == OWNER/MEMBER`) is preserved intact. No new evaluation paths, no new trust decisions. The risk is entirely "did the move break the YAML/shell structure", which is verifiable by YAML parse + visual diff review.

## How

### Files to Modify

- `EDIT: .github/workflows/maintainer-gate.yml:164-212` — move the Check -1 block from inside `if [[ -z "$LINKED_ISSUES" ]]; then` to a new location immediately before that `if` statement. The existing no-linked-issues early exit (lines 193-211) stays where it is.

### Implementation

**Step 1: Extract Check -1 to a new location before the `if [[ -z "$LINKED_ISSUES" ]]` branch.**

Find the current block (lines 164-212):

```bash
          if [[ -z "$LINKED_ISSUES" ]]; then
          # ---------------------------------------------------------------
          # Check -1: origin:interactive — implied maintainer approval
          # GH#18285 post-mortem: PRs created during interactive maintainer
          # sessions carry origin:interactive. The maintainer was present and
          # directing the work — no separate cryptographic approval is needed.
          #
          # Security gate: ONLY passes for OWNER or MEMBER author_association.
          # COLLABORATOR is excluded — write-access contributors must still go
          # through the normal gate. A contributor could apply origin:interactive
          # manually (labels are not protected like origin:worker), so we verify
          # the PR author is actually a maintainer via GitHub's author_association.
          # ---------------------------------------------------------------
          if echo "$PR_LABELS" | grep -q 'origin:interactive'; then
            if [[ "$PR_AUTHOR_ASSOCIATION" == "OWNER" ]] || \
               [[ "$PR_AUTHOR_ASSOCIATION" == "MEMBER" ]]; then
              echo "PASS: PR #$PR_NUMBER has origin:interactive and author is maintainer ($PR_AUTHOR_ASSOCIATION) — implied approval"
              gh api "repos/${REPO}/statuses/${HEAD_SHA}" \
                --method POST \
                -f state=success \
                -f context="maintainer-gate" \
                -f description="origin:interactive by maintainer ($PR_AUTHOR_ASSOCIATION) — implied approval" \
                2>/dev/null || true
              exit 0
            else
              echo "SKIP: PR #$PR_NUMBER has origin:interactive but author is $PR_AUTHOR_ASSOCIATION (not OWNER/MEMBER) — continuing normal gate checks"
            fi
          fi

            echo "No linked issues found — gate passes (no issues to check)"
            echo "blocked=false" >> "$GITHUB_OUTPUT"
            echo "reason=" >> "$GITHUB_OUTPUT"
            # Post success commit status so branch protection sees the result
            # Fail-closed: if status post fails after retry, fail the job (GH#14277)
            gh api "repos/${REPO}/statuses/${HEAD_SHA}" \
              --method POST \
              -f state=success \
              -f context="maintainer-gate" \
              -f description="No linked issues to check" \
              2>/dev/null || { sleep 5 && gh api "repos/${REPO}/statuses/${HEAD_SHA}" \
              --method POST \
              -f state=success \
              -f context="maintainer-gate" \
              -f description="No linked issues to check"; } || {
              echo "::error::Failed to post maintainer-gate commit status after retry"
              exit 1
            }
            exit 0
          fi
```

Replace with:

```bash
          # ---------------------------------------------------------------
          # Check -1: origin:interactive — implied maintainer approval (t2030)
          # GH#18285 post-mortem: PRs created during interactive maintainer
          # sessions carry origin:interactive. The maintainer was present and
          # directing the work — no separate cryptographic approval is needed.
          #
          # t2030: applies to ALL PRs (with or without linked issues). The
          # previous placement inside `if [[ -z "$LINKED_ISSUES" ]]` was a
          # documented-vs-implemented mismatch — build.txt says "PRs tagged
          # origin:interactive pass the maintainer gate automatically when
          # the PR author is OWNER or MEMBER", full stop. Nested placement
          # narrowed the rule to "only PRs with no linked issues", which
          # made the common maintainer-triages-external-bug flow still hit
          # the full linked-issue gate despite being the exact case the
          # rule was supposed to cover.
          #
          # Security gate: ONLY passes for OWNER or MEMBER author_association.
          # COLLABORATOR is excluded — write-access contributors must still go
          # through the normal gate. A contributor could apply origin:interactive
          # manually (labels are not protected like origin:worker), so we verify
          # the PR author is actually a maintainer via GitHub's author_association.
          # The authorship check is unchanged from the pre-t2030 version — the
          # only change is which PRs reach it.
          # ---------------------------------------------------------------
          if echo "$PR_LABELS" | grep -q 'origin:interactive'; then
            if [[ "$PR_AUTHOR_ASSOCIATION" == "OWNER" ]] || \
               [[ "$PR_AUTHOR_ASSOCIATION" == "MEMBER" ]]; then
              echo "PASS: PR #$PR_NUMBER has origin:interactive and author is maintainer ($PR_AUTHOR_ASSOCIATION) — implied approval (t2030: applies to linked-issue PRs too)"
              gh api "repos/${REPO}/statuses/${HEAD_SHA}" \
                --method POST \
                -f state=success \
                -f context="maintainer-gate" \
                -f description="origin:interactive by maintainer ($PR_AUTHOR_ASSOCIATION) — implied approval" \
                2>/dev/null || true
              exit 0
            else
              echo "SKIP: PR #$PR_NUMBER has origin:interactive but author is $PR_AUTHOR_ASSOCIATION (not OWNER/MEMBER) — continuing normal gate checks"
            fi
          fi

          if [[ -z "$LINKED_ISSUES" ]]; then
            echo "No linked issues found — gate passes (no issues to check)"
            echo "blocked=false" >> "$GITHUB_OUTPUT"
            echo "reason=" >> "$GITHUB_OUTPUT"
            # Post success commit status so branch protection sees the result
            # Fail-closed: if status post fails after retry, fail the job (GH#14277)
            gh api "repos/${REPO}/statuses/${HEAD_SHA}" \
              --method POST \
              -f state=success \
              -f context="maintainer-gate" \
              -f description="No linked issues to check" \
              2>/dev/null || { sleep 5 && gh api "repos/${REPO}/statuses/${HEAD_SHA}" \
              --method POST \
              -f state=success \
              -f context="maintainer-gate" \
              -f description="No linked issues to check"; } || {
              echo "::error::Failed to post maintainer-gate commit status after retry"
              exit 1
            }
            exit 0
          fi
```

**Step 2: YAML lint and visual diff.**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/maintainer-gate.yml'))"
git diff .github/workflows/maintainer-gate.yml | head -120
```

The diff should show:
- Check -1 block moved up by one indentation level (previously 12 spaces, now 10 spaces — same level as the `if [[ -z "$LINKED_ISSUES" ]]` check)
- No logic changes inside the block
- The no-linked-issues early exit's `if`/`fi` still wraps the early-exit body

### Verification

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/maintainer-gate.yml'))" \
  && grep -c "t2030: applies to linked-issue PRs too" .github/workflows/maintainer-gate.yml \
  && grep -c "origin:interactive" .github/workflows/maintainer-gate.yml
```

**Runtime verification:** the next maintainer-authored interactive PR that links a `needs-maintainer-review` issue should pass the gate on first run without requiring `sudo aidevops approve`. Observable the next time I open a PR for an external-bug triage — until then, this is a self-assessed change that ships behind the existing Check -1 security boundary.

## Acceptance Criteria

- [ ] `.github/workflows/maintainer-gate.yml` has Check -1 placed BEFORE the `if [[ -z "$LINKED_ISSUES" ]]` branch, not inside it.
  ```yaml
  verify:
    method: codebase
    pattern: "t2030: applies to linked-issue PRs too"
    path: ".github/workflows/maintainer-gate.yml"
  ```
- [ ] The `PR_AUTHOR_ASSOCIATION == OWNER/MEMBER` check is still present and unchanged.
  ```yaml
  verify:
    method: codebase
    pattern: 'PR_AUTHOR_ASSOCIATION.*OWNER.*MEMBER'
    path: ".github/workflows/maintainer-gate.yml"
  ```
- [ ] The workflow file still parses as valid YAML.
  ```yaml
  verify:
    method: bash
    run: "python3 -c 'import yaml; yaml.safe_load(open(\".github/workflows/maintainer-gate.yml\"))'"
  ```
- [ ] The no-linked-issues early exit block still runs (not deleted or merged into Check -1).
  ```yaml
  verify:
    method: codebase
    pattern: "No linked issues found — gate passes"
    path: ".github/workflows/maintainer-gate.yml"
  ```

## Context & Decisions

**Why ship P1 separately from G3 (Job 3 refactor).** G3 — reducing Job 3's duplicate inline gate logic — was originally bundled with P1 under "t2030". I rescoped to P1-only because:
1. P1 is a lexical move with preserved security boundary; risk is essentially "did the YAML parse".
2. G3 touches how Job 3 signals authoritative state and deserves its own PR surface for review.
3. Two smaller PRs > one larger PR when the workflow file is security-critical and six non-admin collaborators are affected by any mistake.

G3 will be filed as a follow-up task (t2035 or whatever the next available ID is) if this session still has budget.

**Why not also move Check -1 ABOVE Check 0 (PR-level NMR label).** Check 0 (PR labeled `needs-maintainer-review`) is a stronger signal than origin:interactive — if the PR itself has the NMR label, the maintainer gate MUST enforce cryptographic approval. If we moved Check -1 above Check 0, a maintainer could apply origin:interactive to a PR that is otherwise flagged for NMR and skip the cryptographic gate. Keep Check 0 first.

**Why keep the security gate unchanged.** The `OWNER/MEMBER` check is the only thing preventing a malicious COLLABORATOR from bypassing via origin:interactive. Labels are not protected the way origin:worker is, so label-based gates need an independent authentication signal. Preserving this check is non-negotiable for this change.

**What COLLABORATORs see after this change.** Unchanged. The `else` branch of Check -1 (the `SKIP` case) continues to fall through to the normal gate. A COLLABORATOR who sets origin:interactive will still have their linked issues evaluated for NMR + assignee.

**Non-goals:**
- Refactoring Job 3's inline gate evaluation (G3, separate task).
- Changing what triggers Check 0 (PR-level NMR label check).
- Adding new gate conditions or new exemption categories.
- Changing the set of labels the gate checks.

## Relevant Files

- `.github/workflows/maintainer-gate.yml:164-212` — the block being moved.
- `.github/workflows/maintainer-gate.yml:71-109` — Check 0 (PR-level NMR), stays above Check -1.
- `.agents/prompts/build.txt` "origin:interactive implies maintainer approval" — the rule being honoured.
- GH#18285 — the post-mortem that introduced Check -1 in the narrower placement.

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing hard. Saves ~1 minute per maintainer-authored external-bug PR.
- **External:** none

## Estimate Breakdown

| Phase | Time |
|-------|------|
| Write brief | (done) |
| Implementation | 10m |
| YAML lint + visual diff review | 5m |
| Commit + PR + /pr-loop | ~20m incl. CI |
| **Total** | **~15m hands-on + ~20m CI** |
