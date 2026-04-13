<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2036: add deployed-vs-source diagnostic rule to build.txt for runtime investigations

## Origin

- **Created:** 2026-04-13
- **Session:** claude-code (interactive)
- **Created by:** ai-interactive (session that produced t2014/t2017/t2024 + #18473 post-mortem)
- **Parent task:** none (sibling to #18508)
- **Conversation context:** During the same session that produced #18508 (Section 0 discovery discipline for implementation), a related but distinct failure surfaced: when investigating runtime pulse behaviour for #18473, the model read the source file in `~/Git/aidevops/.agents/scripts/pulse-ancillary-dispatch.sh` and reasoned about what the running pulse was doing — but the deployed copy at `~/.aidevops/agents/scripts/pulse-ancillary-dispatch.sh` was a NEWER version (mtime 02:09) than the log entries being investigated (timestamps 23:xx). The bug had already been fixed by t2019 / commit `a084f425f` and deployed before the investigation began. Reading source-as-truth led to a multi-hour mis-investigation and a duplicate fix attempt that had to be closed.

This is adjacent to #18508 ("check git log before implementing") but distinct: that rule catches duplicates BEFORE writing code; this rule catches stale-symptom investigations BEFORE writing the wrong analysis. Different failure modes, different fixes, both belong in the harness.

## What

Add a short, concrete diagnostic rule to `.agents/prompts/build.txt` that requires runtime investigations of pulse, agent, or worker behaviour to first establish the deployed-vs-source state of the relevant scripts before reading source code as a model of "what's running". The rule applies whenever an investigation is rooted in runtime artifacts (logs, observed timeouts, failed dispatches, suppressed comments, etc.) where the symptom may have been produced by a previously-deployed version.

The rule belongs in the existing "Error Prevention (top recurring patterns)" section of `build.txt` as a numbered entry — that section already houses similar diagnostic rules and is referenced from the system prompt's quality discipline pointers.

### Proposed text (verbatim, ~14 lines added)

```markdown
# 9. Stale-symptom investigations (runtime debugging)
# When investigating pulse, agent, or worker runtime behaviour reported via
# logs, timeouts, or failed dispatches, the deployed copy at
# `~/.aidevops/agents/scripts/<file>` may differ from the source in
# `~/Git/aidevops/.agents/scripts/<file>`. The pulse process executes
# DEPLOYED code; investigations that read source-as-truth can spend hours
# analysing a bug that was already fixed and deployed before the
# investigated symptoms occurred.
- Before reading source for runtime investigation: run
  `stat -f '%Sm' ~/.aidevops/agents/scripts/<file>` and compare to
  `git -C ~/Git/aidevops log -1 --format='%ai' -- .agents/scripts/<file>`.
  If they differ, identify whether you're reading the deployed version,
  the in-flight source, or somewhere between.
- When the symptom timestamps in logs predate the deployed file mtime,
  treat the symptom as historical — it reflects pre-deploy behaviour.
  Verify the symptom still reproduces against the current deploy before
  filing an investigation issue.
- Source-only debugging is fine for design questions, refactoring,
  and writing new code. The rule applies specifically to runtime
  diagnostics.
- Related discipline: section 7 (Pre-implementation discovery, t2036's
  sibling #18508) covers the complementary case — checking git log for
  recently-merged fixes before WRITING new code.
```

The numbering (`# 9.`) is illustrative — the actual number should follow whatever's currently the next free slot in the "Error Prevention" section at write time.

## Why

### Direct evidence from the session that produced this brief

The triage JSONL bug (#18473) was already fixed by commit `a084f425f` (t2019, PR #18491) which merged at 02:03 UTC and was deployed at 02:09 (verified post-failure via `stat -f '%Sm' ~/.aidevops/agents/scripts/pulse-ancillary-dispatch.sh`). The investigation that produced #18473 began after 02:09 but read pulse log entries from 23:xx — timestamps from BEFORE the deploy. The model:

1. Read the SOURCE file in `~/Git/aidevops/.agents/scripts/pulse-ancillary-dispatch.sh`
2. Found `2>&1` and "no JSONL parsing" in source
3. Concluded "this is the bug, the runtime must be doing this"
4. Wrote a detailed root-cause issue (#18473) based on that conclusion
5. Implemented a fix (#18498/t2025) based on the same conclusion

All of which was wrong because the runtime had already been running the FIXED code for ~30 minutes before the investigation began. A single `stat` command at the start would have surfaced "deployed file mtime 02:09, deployed file already has the fix, the symptoms in the log are historical" — and the investigation would have been "verify the deployed fix actually works" instead of "design a fix from scratch".

### Why this is a system-prompt rule, not a workflow doc reference

System-prompt rules are always in context. Workflow doc references require the model to remember to read the doc. For diagnostic discipline that should fire EVERY time a runtime investigation begins — not just when the model happens to think about workflow docs — the rule has to live where it can't be missed. `prompts/build.txt` is the right home because it's the always-present quality discipline layer.

### Why a separate rule from #18508 (Section 0 for implementation)

Both rules are about "check the world before believing your model of it", but they fire at different times and against different artifacts:

| Rule | Triggers when | Checks against | Fixes what |
|------|---------------|----------------|------------|
| #18508 | About to write code | Recent commits, merged PRs, in-flight work | Duplicate work |
| t2036 | About to investigate runtime symptoms | Deployed file mtime vs source commit | Stale-symptom mis-investigation |

A model that has #18508 in context still benefits from t2036 because the temporal-duplicate check fires when you've decided to implement; the deployed-vs-source check fires earlier, when you're still deciding what's broken. Both can be true: I had t2017 in context (which is the review-side equivalent of #18508) and I still failed both checks in #18473, in part because the rule for "investigating" wasn't explicit anywhere.

### Effect

- Catches the specific failure mode that produced #18473 → #18498/t2025 → close-as-duplicate cascade
- Maximum 14-line addition to `build.txt` (the file already has many comparable entries — adding one more doesn't bloat it)
- Costs nothing at runtime: just a one-time `stat` + `git log` per investigation
- Composes with #18508 (different failure modes, additive)

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** Yes — 1 file (`prompts/build.txt`)
- [ ] **Complete code blocks for every edit?** Yes, but the exact line number for the insertion depends on the current state of `build.txt` and may need adjustment by the implementer
- [x] **No judgment or design decisions?** Borderline — the WORDING matters because it's a system prompt. A small amount of editorial judgement is involved in fitting the new rule alongside existing entries without disrupting the section's voice
- [x] **No error handling or fallback logic to design?** Yes — pure text addition
- [x] **Estimate 1h or less?** Yes — ~15 minutes
- [x] **4 or fewer acceptance criteria?** Yes — 3

**Selected tier:** `tier:standard` (Sonnet) — not `tier:simple` because system-prompt edits warrant the editorial attention that Haiku's strict copy-paste bar doesn't accommodate. The verbatim text above is a starting point; the implementer should integrate it cleanly with the existing section voice and numbering.

**Origin label:** `needs-maintainer-review` (NOT `auto-dispatch`). System-prompt edits affect every future agent session and deserve human review with full awareness of blast radius. A worker dispatched to edit its own system prompt is a recursive footgun pattern worth avoiding by default.

## How (Approach)

### Files to modify

- `EDIT: .agents/prompts/build.txt` — add a new numbered entry to the "Error Prevention (top recurring patterns)" section (or whatever section currently houses the numbered diagnostic rules)

### Implementation steps

1. Read `.agents/prompts/build.txt` and locate the "Error Prevention" section (currently houses entries 1-8 covering webfetch failures, markdown formatter, file_not_found, edit:other, glob:other, repo slug hallucination, AI-generated issue quality, prompt injection)
2. Add a new numbered entry (the next free slot — likely `# 9.` but verify) using the verbatim text above as the starting point
3. Adjust the wording to match the section's existing voice (compact, action-oriented, with concrete bash commands where applicable)
4. Verify the cross-reference to "section 7 (Pre-implementation discovery)" makes sense — depends on whether #18508 has landed by the time this is implemented. If not yet, adjust the cross-reference to be forward-looking ("see also issue #18508")
5. Verify line count: the new entry should add ~14-18 lines. If significantly longer, condense.

### Verification

```bash
# 1. The new numbered entry exists
grep -A1 "Stale-symptom investigations" .agents/prompts/build.txt
# Expected: new entry text

# 2. The file still parses cleanly (no broken markdown / no orphaned headers)
markdownlint-cli2 .agents/prompts/build.txt
# Expected: 0 errors

# 3. The total line count increase is modest (< 25 lines added)
git diff --stat origin/main -- .agents/prompts/build.txt
# Expected: ~15-20 line insertion, 0 deletions
```

## Acceptance Criteria

- [ ] `.agents/prompts/build.txt` contains a new numbered entry under the "Error Prevention" section that explicitly addresses the deployed-vs-source mismatch for runtime investigations
  ```yaml
  verify:
    method: codebase
    pattern: "Stale-symptom|deployed.*source|deployed copy"
    path: ".agents/prompts/build.txt"
  ```
- [ ] The entry includes a concrete `stat` + `git log` command that the model can copy-paste during an investigation (not just a vague "check the deployed version")
  ```yaml
  verify:
    method: codebase
    pattern: 'stat -f.*aidevops/agents/scripts'
    path: ".agents/prompts/build.txt"
  ```
- [ ] `markdownlint-cli2 .agents/prompts/build.txt` exits 0 and the section's existing voice is preserved
  ```yaml
  verify:
    method: bash
    run: "markdownlint-cli2 .agents/prompts/build.txt"
  ```

## Context & Decisions

- **Why "Error Prevention" section and not a new section?** Because the failure mode this rule prevents is exactly the kind of recurring-error pattern that section already catalogues (webfetch failures, markdown formatter, file_not_found, etc.). A new section would dilute the structure; a new entry inside the existing section integrates naturally.
- **Why a `stat` command, not a more elaborate diagnostic helper?** Because diagnostic discipline that requires "first install/run a helper" is friction that gets skipped. A single `stat` invocation that any model already knows how to run has the lowest barrier to actual use. If the rule warrants automation later, a helper can be added — but the rule itself should be runnable from memory.
- **Why not check ALL deployed files?** Because the rule is about "investigations rooted in runtime symptoms". When you're investigating a pulse log entry, you already know which file is suspect (the log line tells you). Checking only the relevant file keeps the rule actionable; checking all files is busy-work.
- **Cross-referencing #18508:** The text references "section 7 (Pre-implementation discovery)" because that's where #18508's rule is intended to live. If #18508 ends up in a different section, this cross-reference needs updating at implementation time. Both PRs should not block on each other — the rules are independent and either can land first.
- **Non-goals:**
  - Adding the rule to `workflows/*.md` files (those are read on-demand; this needs to live in the always-loaded prompt)
  - Implementing a "deployed file diff" helper (premature optimization — the rule is the behaviour change, not the tooling)
  - Updating `reference/customization.md` (already documents deployed-vs-source for editing purposes; this rule covers the diagnostic angle which is distinct)
  - Updating `agent-routing.md` or any other doc — system-prompt rules don't need cross-references to be effective

## Relevant Files

- `.agents/prompts/build.txt` — target file (Error Prevention section)
- `.agents/reference/customization.md` — adjacent guidance about deployed vs source for editing (different angle, no change needed)
- `~/.aidevops/agents/scripts/` — the deployed copy directory the rule references
- `~/Git/aidevops/.agents/scripts/` — the source directory the rule contrasts against

## Dependencies

- **Blocked by:** none
- **Blocks:** none (rule is independent — composes with #18508 but doesn't require it)
- **Related:** #18508 (Pre-implementation discovery — sibling failure mode for the implementation phase rather than the investigation phase)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Locate insertion site + read context | 3m | Find the right section, match the voice |
| Write the entry | 5m | Adapt verbatim text to fit the section |
| Verification | 2m | markdownlint + diff inspection |
| Commit + PR | 5m | Conventional commit, PR body explaining the failure mode |
| **Total** | **~15m** | |
