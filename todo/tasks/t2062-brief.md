---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2062: self-improvement: test scripts you depend on from a clean checkout, not your dirty worktree

## Origin

- **Created:** 2026-04-13
- **Session:** opencode interactive (claude-opus-4-6, GH#18538 follow-up session)
- **Created by:** ai-interactive
- **Conversation context:** While shipping the `--admin` fallback for `full-loop-helper.sh merge` (PR #18748 → GH#18538), the wrapper's self-test passed locally — but only because uncommitted edits in the worktree included a critical `set -e` bug fix. The shipped main code was buggy and would have failed silently for the next worker. Caught and hotfixed in PR #18750, but the failure mode is general.

## What

Add a rule to `prompts/build.txt` (and a brief mention in `AGENTS.md` runtime testing section) that says: **when you change a script that the test harness itself depends on, you MUST verify the change from a clean checkout — not from a worktree with uncommitted edits.** Specifically:

1. Add a "Self-modifying script test discipline" subsection under "Runtime Testing Gate" or "Quality Standards" in `prompts/build.txt`.
2. State the rule: any edit to a script that you (or the wrapper running you) will subsequently invoke as part of verification MUST be committed before the verification call. Or: re-source/re-fetch the script from main after commit, before running it.
3. Cite the GH#18538 / PR #18748 / PR #18750 chain as the canonical evidence.
4. Optionally: a one-line lint check / suggestion in `cmd_merge` itself — "if the file you just edited matches the script invoking you, suggest a clean re-test".

The deliverable is the documentation rule, not the lint hook (which can be a follow-up if anyone wants it).

## Why

This is a class of failure that's invisible to local testing:

- A local edit to `full-loop-helper.sh merge` looks correct.
- Running `.agents/scripts/full-loop-helper.sh merge ...` from the worktree path executes the *uncommitted* version — not what's in git.
- The wrapper succeeds.
- The commit + push + merge ships a *different* (broken) version to main.
- Next worker runs the deployed copy and silently fails.
- The cycle is invisible until someone notices nothing is being merged.

In the GH#18538 case it was caught in a single iteration because I happened to look at the diff between fresh main and my local worktree and noticed the if-form fix wasn't there. In the worst case, it's the kind of bug that ships, breaks every interactive PR for a day, and only gets noticed when a maintainer looks at why nothing is moving.

The general principle: **for any script that's in the test loop, the local working copy IS the test environment.** That's a footgun unique to self-modifying tooling (frameworks, build systems, CI helpers). It doesn't apply to product code where local edits and the runtime are separate concerns.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** (`prompts/build.txt` + maybe `.agents/AGENTS.md`)
- [x] **Complete code blocks for every edit?** (the new subsection text below)
- [x] **No judgment or design decisions?** (rule is fully specified)
- [x] **No error handling or fallback logic to design?** (docs only)
- [x] **Estimate 1h or less?** (~30m)
- [x] **4 or fewer acceptance criteria?** (3 below)

**Selected tier:** `tier:simple`

**Tier rationale:** Pure documentation edit with the new subsection text fully specified in the How section. No judgment, no code, no fallback logic. Single file (with optional second).

## How

### Files to Modify

- `EDIT: .agents/prompts/build.txt` — add a new subsection under "Quality Standards" or "Runtime Testing Gate"
- `EDIT (optional): .agents/AGENTS.md` — one-line cross-reference if a natural anchor exists

### Implementation

Add this subsection to `prompts/build.txt`. Anchor it under "Runtime Testing Gate" (after the existing risk/patterns table) or under a new "Quality Standards" subsection if cleaner:

```markdown
# Self-modifying tooling test discipline (GH#18538 / t2062)
# When you edit a script that's part of the test/verification loop you'll
# subsequently invoke (e.g., `full-loop-helper.sh`, `pre-edit-check.sh`,
# `claim-task-id.sh`, anything in your own dev wrapper chain), the local
# working copy IS your test environment. Running the script from the
# worktree path executes uncommitted edits, not what's in git.
#
# Failure mode: the wrapper succeeds locally because of an uncommitted
# fix; you commit a different (incomplete) version; main ships broken;
# next worker silently fails. Invisible until someone notices nothing
# is merging.
#
# Rule:
# 1. Commit the change BEFORE running it as part of verification, OR
# 2. Re-test after `git stash && git checkout origin/main -- <script>`
#    to confirm the committed version actually does what you tested.
# 3. For wrappers that invoke themselves (full-loop-helper.sh merge
#    being the canonical case), prefer #2 because #1 can't catch the
#    "I forgot to stage one of the files" variant.
#
# This rule applies to scripts only. Product code where the runtime is
# separate from the source tree (built binaries, deployed services,
# language runtimes) doesn't have this footgun.
#
# Canonical evidence: GH#18538 → PR #18748 (shipped a `set -e` bug
# that the local self-test passed because of an uncommitted if-form
# fix) → PR #18750 (hotfix). Both PRs verified the rule end-to-end.
```

### Verification

```bash
# Confirm the rule landed in build.txt
grep -A5 "Self-modifying tooling test discipline" .agents/prompts/build.txt

# Confirm a fresh checkout sees the same content
git stash
git show HEAD:.agents/prompts/build.txt | grep -c "GH#18538 / t2062"
git stash pop
```

(The verification block itself is the rule in action — checking that committed content matches local content.)

## Acceptance Criteria

- [ ] `prompts/build.txt` contains the new subsection with the rule, the failure-mode explanation, and the GH#18538/PR#18748/PR#18750 evidence chain.
- [ ] `setup.sh --non-interactive` deploys the new build.txt to `~/.aidevops/agents/prompts/build.txt`.
- [ ] The verification command above returns the expected match count.

## Context

- **Trigger session:** GH#18538 (post-merge-review-scanner worker-actionable bodies)
- **Bug PR:** [#18748](https://github.com/marcusquinn/aidevops/pull/18748) shipped the bare `_merge_out=$(...)` form that exits silently under `set -e`
- **Hotfix PR:** [#18750](https://github.com/marcusquinn/aidevops/pull/18750) switched to the if-form
- **Related rule:** existing "Runtime Testing Gate" in `prompts/build.txt` covers risk-appropriate verification but doesn't address the self-modifying-tooling case specifically
- **Out of scope:** an automatic lint/hint inside `cmd_merge` ("you just edited the file you're about to invoke — re-test from main?") would be useful but is a separate task; ship the rule first
