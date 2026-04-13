<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2059: docs — promote worker-is-triager to universal worker rule in build.txt + AGENTS.md

## Origin

- **Created:** 2026-04-13
- **Session:** OpenCode:feature-gh18538-worker-is-triager
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** — (follow-up to GH#18538)
- **Conversation context:** GH#18538 shipped the worker-is-triager rule inside `post-merge-review-scanner.sh` only (header comment + issue-body preamble). The maintainer asked to promote it to a framework-wide rule so it applies to every worker dispatched against any auto-generated issue body — not just review-followup issues.

## What

Add a short, universal "Worker triage responsibility" rule to `prompts/build.txt` (the system prompt harness every agent loads) AND a matching pointer in `.agents/AGENTS.md` (the user-facing guide). The rule tells every worker, at system-prompt level:

> When dispatched against an auto-generated issue body (review-followup, quality-debt, contribution-watch, framework-routing, etc.), you are the triager. Verify the finding's factual premise before acting. End in exactly one of three outcomes — Outcome A (premise falsified → close with rationale comment, no PR), Outcome B (premise correct + obvious fix → implement and PR), Outcome C (genuinely ambiguous architectural/policy/breaking-change decision → decision comment with Premise check / Analysis / Recommended path / Specific question, then apply `needs-maintainer-review` and stop).

After this ships, `post-merge-review-scanner.sh`'s preamble becomes an application of the universal rule rather than a one-off. Other scanners (quality-feedback-helper, framework-routing-helper, contribution-watch-helper) can reference the rule by name instead of re-explaining the three outcomes.

## Why

- Prevents drift: without a central rule, every new scanner will reinvent the "should we gate on maintainer review?" question, and most will default to the wrong answer (apply `needs-maintainer-review` by default, as PR #18610 did before the #18743 course correction).
- Token budget: workers currently learn the rule only if the issue body carries it. A system-prompt-level rule means the worker already knows the three outcomes before it even reads the issue body.
- Consistency with existing principles: "Reasoning responsibility" (build.txt line 55) already says "you do the thinking; never punt analysis back as questions". The worker-is-triager rule is the exact same principle applied to the dispatch layer — it belongs next to it.
- Auditability: a named rule in one canonical location can be referenced from commit messages, review comments, and future bot-noise meta-issues.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** (`prompts/build.txt` + `.agents/AGENTS.md`)
- [x] **Complete code blocks for every edit?** (exact text provided below)
- [x] **No judgment or design decisions?** (wording is spec'd in this brief)
- [x] **No error handling or fallback logic to design?**
- [x] **Estimate 1h or less?** (~20m)
- [x] **4 or fewer acceptance criteria?**

**Selected tier:** `tier:simple`

**Tier rationale:** Pure docs edit with copy-pasteable text for both files. No judgment, no design, no new code.

## PR Conventions

Leaf task — use `Resolves #18745` in the PR body.

## How (Approach)

### Files to Modify

- `EDIT: .agents/prompts/build.txt` — insert new section "Worker triage responsibility" immediately after the existing "Reasoning responsibility" section (currently lines 55-59).
- `EDIT: .agents/AGENTS.md` — add a one-line pointer under the existing "Agent Framework" or "Self-Improvement" section referencing the new rule.

### Implementation Steps

**Step 1 — `prompts/build.txt`.** Insert the following block between the current "Reasoning responsibility" section (ends at line 59) and "Goal-constraint surfacing" (line 61). Use `oldString` matching the last line of the previous section through the first line of the next:

- `oldString`:

```
# Reasoning responsibility
You do the thinking. User gets your recommendation with reasoning — not a menu of questions.
- Present: recommended approach, why, alternatives considered, what would change your mind.
- NEVER punt analysis back as "questions to consider". That's the model's job.
- Multiple viable approaches? Recommend one. Mention alternatives briefly with trade-offs.

# Goal-constraint surfacing
```

- `newString`:

```
# Reasoning responsibility
You do the thinking. User gets your recommendation with reasoning — not a menu of questions.
- Present: recommended approach, why, alternatives considered, what would change your mind.
- NEVER punt analysis back as "questions to consider". That's the model's job.
- Multiple viable approaches? Recommend one. Mention alternatives briefly with trade-offs.

# Worker triage responsibility (GH#18538)
When dispatched against an auto-generated issue body (review-followup, quality-debt, contribution-watch, framework-routing, any scanner output), YOU are the triager. Verify the factual premise before acting — bot findings can be wrong (hallucinated line refs, false assumptions about codebase structure, template sweeps without measurements). End in exactly one of three outcomes:
- **A. Premise falsified → close the issue** with a `> Premise falsified. <claim>. <code reality>. Not acting.` rationale comment. No PR. The closing comment trains the next session and the noise filter.
- **B. Premise correct + obvious fix → implement and PR** with normal lifecycle gate (`Resolves #<this-issue>`).
- **C. Premise correct but genuinely ambiguous** (architecture / policy / breaking change the worker cannot resolve autonomously) → post a decision comment containing: **Premise check** (one line), **Analysis** (2-4 bullets on trade-offs), **Recommended path** (what you would do if the call were yours, with rationale), **Specific question** (yes/no or pick-one — not open-ended). Then apply `needs-maintainer-review` and stop. The human wakes up to a ready-to-approve recommendation, not a blank task.
Ambiguity about scope or style is NOT Outcome C. Applying `needs-maintainer-review` at issue creation time — the "punt analysis to a human who hands it back to an AI" anti-pattern — is forbidden. Reasoning responsibility applies here too: you do the thinking.

# Goal-constraint surfacing
```

**Step 2 — `.agents/AGENTS.md`.** Add a one-line pointer to the new rule in the "Agent Framework" section (or wherever you judge most discoverable). Suggested insertion after the existing "Agent Framework" bullets:

```markdown
## Worker Triage Responsibility (GH#18538)

Workers dispatched against auto-generated issue bodies (review-followup, quality-debt, contribution-watch, framework-routing) are the triagers. See `prompts/build.txt` "Worker triage responsibility" for the three-outcome rule (falsify-and-close / implement-and-PR / escalate-with-recommendation). Never apply `needs-maintainer-review` unconditionally at issue creation.
```

### Verification

```bash
# Rule is in build.txt
grep -q "Worker triage responsibility" ~/Git/aidevops/.agents/prompts/build.txt && echo "build.txt: OK"

# Rule is referenced in AGENTS.md
grep -q "Worker Triage Responsibility" ~/Git/aidevops/.agents/AGENTS.md && echo "AGENTS.md: OK"

# Both files still parse / render
markdownlint-cli2 ~/Git/aidevops/.agents/AGENTS.md 2>&1 | grep -v "^$" || echo "markdown: clean"
```

## Acceptance Criteria

- [ ] `prompts/build.txt` contains a new "Worker triage responsibility (GH#18538)" section immediately after "Reasoning responsibility".
  ```yaml
  verify:
    method: codebase
    pattern: "Worker triage responsibility"
    path: ".agents/prompts/build.txt"
  ```
- [ ] The new section names all three outcomes (A/B/C) with their exact labels.
  ```yaml
  verify:
    method: bash
    run: "grep -c 'Outcome A\\|Outcome B\\|Outcome C\\|Premise falsified\\|implement and PR\\|decision comment' .agents/prompts/build.txt | xargs test 3 -le"
  ```
- [ ] `.agents/AGENTS.md` contains a one-line pointer to the new build.txt rule.
  ```yaml
  verify:
    method: codebase
    pattern: "Worker Triage Responsibility"
    path: ".agents/AGENTS.md"
  ```
- [ ] Markdown lint clean on AGENTS.md.
  ```yaml
  verify:
    method: bash
    run: "markdownlint-cli2 .agents/AGENTS.md 2>&1 | grep -v '^$' | wc -l | xargs test 0 -eq"
  ```

## Context & Decisions

- **Why build.txt and not just AGENTS.md:** build.txt is the system prompt loaded by every agent on every turn. AGENTS.md is reference material. The rule must reach the worker at dispatch time, before it starts reading the issue body — system prompt is the only layer that guarantees that.
- **Why a pointer in AGENTS.md too:** maintainers and humans read AGENTS.md for context; a pointer gives them a discoverable entry point. The pointer is one sentence so it doesn't duplicate the rule.
- **What we're NOT doing:** touching `post-merge-review-scanner.sh`. The script's inline preamble and header comment stay as a concrete worked example of the universal rule. Once this task merges, the script's preamble could reference the universal rule by name — but that's a separate cleanup task, not this one.
- **Prior art:** PR #18610 (initial wrong design), PR #18743 (course correction), GH#18538 thread.

## Relevant Files

- `.agents/prompts/build.txt:55-60` — "Reasoning responsibility" section; new rule inserts immediately after.
- `.agents/AGENTS.md` — "Agent Framework" section or similar discoverable location for the pointer.
- `.agents/scripts/post-merge-review-scanner.sh` — the concrete worked example of the rule (read-only for this task).

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Read current "Reasoning responsibility" context + pick AGENTS.md insertion point |
| Implementation | 10m | Two copy-pasteable edits |
| Testing | 5m | markdownlint + grep verification |
| **Total** | **~20m** | |
