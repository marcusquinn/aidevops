---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2208: Restore Codacy badge in README.md once grade reaches A

## Origin

- **Created:** 2026-04-18
- **Session:** OpenCode interactive (marcusquinn)
- **Created by:** marcusquinn (human-directed AI-interactive)
- **Parent task:** t2178 (hidden the badge) → t2182 → t2191 → this task (restore it).
- **Conversation context:** In t2178 the Codacy badge in README.md was hidden inside an HTML comment because the repo grade had dropped to E (mostly due to a Codacy re-index LOC-denominator collapse, not an actual quality regression). Subsequent work in t2178 + t2182 + t2191 pulled the grade back up; at last check it was B and still re-indexing as Prospector findings were removed from the index. Once the grade is A, the badge should come back — but not before, because we don't want users seeing B/C transients.

## What

When Codacy reports grade **A** for the repo AND all three subcategories (Issues, Complexity, Duplication) also show **A**, remove the HTML comment wrappers around the Codacy badge block in `README.md` (~lines 55-61) so it renders again. The restoration pointer is inside the HTML comment itself — follow it verbatim rather than re-deriving the badge URL.

## Why

- A B-grade badge is worse than no badge; it telegraphs "we tried and fell short".
- The t2178 hide was always temporary, anchored to a restoration gate. Leaving the badge hidden indefinitely means the t2178-t2182-t2191 quality work has no visible outcome for users.
- The trigger (grade = A) is well-defined and cheap to verify via API — a short task, not worth queuing indefinitely.

## Tier

### Tier checklist (verify before assigning)

- [x] 2 or fewer files to modify? — **Yes** (`README.md`).
- [x] Every target file under 500 lines? — **Yes**.
- [ ] Exact `oldString`/`newString` for every edit? — **Possibly** (depends on whether the HTML comment wrappers are stable enough to paste into a brief; they are — the t2178 PR pinned the format).
- [x] No judgment or design decisions? — **Yes** (the only decision — "is grade A" — is the trigger condition, not the implementation).
- [x] No error handling or fallback logic to design? — **Yes**.
- [x] No cross-package or cross-module changes? — **Yes**.
- [x] Estimate 1h or less? — **Yes** (10 minutes of actual work).
- [x] 4 or fewer acceptance criteria? — **Yes**.

**Selected tier:** `tier:simple`

**Tier rationale:** Single-file edit, exact oldString/newString available via the restoration pointer in README.md, no judgment once the trigger fires. The only reason this isn't already `tier:simple` auto-dispatched is the trigger is external (Codacy grade observation).

## PR Conventions

Leaf (non-parent) issue. Use `Resolves #19694` in the PR body.

## Trigger Condition (MANUAL)

**Do NOT auto-dispatch.** This task has an external trigger that requires API verification. Only implement when ALL four conditions are true:

1. Codacy top-level grade = **A** for `marcusquinn/aidevops`.
2. Issues subcategory = **A**.
3. Complexity subcategory = **A**.
4. Duplication subcategory = **A**.

Verify via the API, not just the UI (UI can show stale cached values for hours):

```bash
# Requires CODACY_API_TOKEN in gopass (aidevops/CODACY_API_TOKEN)
token=$(aidevops secret get aidevops/CODACY_API_TOKEN 2>/dev/null \
  || cat ~/.config/aidevops/credentials.sh | awk -F'=' '/CODACY_API_TOKEN/ {print $2}' | tr -d '"')
curl -s -H "api-token: $token" \
  'https://app.codacy.com/api/v3/analysis/organizations/gh/marcusquinn/repositories/aidevops' | \
  jq '.data | {grade, issuesGrade: .metrics.issues.grade, complexityGrade: .metrics.complexity.grade, duplicationGrade: .metrics.duplication.grade}'
```

Expected output when trigger fires:

```json
{"grade": "A", "issuesGrade": "A", "complexityGrade": "A", "duplicationGrade": "A"}
```

If any field is not A, defer. This task is a watch-and-trigger — there's no benefit to acting on a B/C state.

## How (Approach)

### Files to Modify

- `EDIT: README.md:55-61` (or wherever the Codacy badge HTML comment currently sits). The restoration pointer is a `<!-- ... -->` block pointing at the exact lines to uncomment.

### Implementation Steps

1. **Verify the trigger** — run the API check above. Abort if not all A.
2. **Find the HTML comment** in README.md:

   ```bash
   grep -nA 10 "<!-- Codacy badge hidden in t2178" README.md
   ```

   (the exact marker was set by t2178; confirm by reading the file before editing.)

3. **Restore the badge** — remove the `<!--` at the start and the `-->` at the end of the wrapped block, leaving the badge markdown in place. Do NOT touch the badge URL or image path — they were correct in t2178.
4. **Verify the badge renders** locally:

   ```bash
   # If a markdown preview is available:
   grip README.md --export /tmp/readme-preview.html 2>/dev/null
   # Otherwise just confirm the raw text shows the badge syntax (no <!-- around it):
   grep -A 5 "app.codacy.com" README.md
   ```

5. **Commit with grade evidence in the message:**

   ```
   t2208: restore Codacy badge (grade: A all categories)

   Triggered by: Codacy API returning {grade:A, issuesGrade:A, complexityGrade:A, duplicationGrade:A}
   at YYYY-MM-DDTHH:MM:SSZ. Hidden in t2178 when grade dropped to E; recovered via
   t2178 (exclusions) + t2182 (engine disables + .bandit) + t2191 (biome.json +
   pre-commit hook).

   Resolves #19694
   ```

### Verification

```bash
# 1. Badge visible in rendered README (check GitHub PR preview or local grip).
# 2. No Codacy subcategory below A at commit time.
# 3. Next Codacy scan after merge doesn't downgrade the grade
#    (monitor for 24h post-merge via the API check above).
```

## Acceptance Criteria

- [ ] Codacy API confirms grade = A across all four categories (top-level + Issues + Complexity + Duplication) at time of commit.
- [ ] `README.md` Codacy badge is rendered (outside any HTML comment wrapper).
- [ ] Commit message records the grade at un-hide time for future audit.
- [ ] 24h post-merge: Codacy grade remains A (a scan can re-surface findings; if the grade drops below A within 24h, revert the badge un-hide and re-file work).

## Context & Decisions

- **Why not `#auto-dispatch`:** the trigger condition requires external verification (Codacy API call) that the worker cannot autonomously establish. An auto-dispatched worker would either have to ignore the trigger and un-hide prematurely, or it would fail the trigger check and close the task without action — both wasteful.
- **Why A and not B:** the badge hide was a t2178 decision to "prevent the E/C/B transient from being visible to users". B is still in that transient band.
- **Why watch all three subcategories:** a top-level A with a B in Complexity is not really an A — readers who click through will see the weakest subcategory. All four gates must be green.
- **Why record grade at un-hide time:** future audit — if the badge regresses within days, the commit message gives the baseline we trusted to un-hide. Helps diagnose whether it was a Codacy re-index glitch or a real regression.

## Relevant Files

- `README.md` — target file.
- PR #19637 (t2178, merged 30ee0ea27) — the hide PR. Restoration pointer was placed by this PR.
- PR #19647 (t2182, merged 4ac67d3948) — engine disables + `.bandit`.
- PR #19683 (t2191, merged a9da95157) — biome.json + pre-commit hook.
- Codacy dashboard: https://app.codacy.com/gh/marcusquinn/aidevops/dashboard

## Dependencies

- **Blocked by:** Codacy re-index reaching A (external).
- **Blocks:** none.
- **External:** Codacy API token (gopass `aidevops/CODACY_API_TOKEN`).
