<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2235: forbid self-invented task ID suffixes in build.txt Traceability rules

**Session origin:** interactive (maintainer, Marcus Quinn)
**GitHub:** GH#19744
**Parent:** t2228 / GH#19734
**Tier:** tier:simple (prompt text edit + optional helper regex)

## What

Add an explicit rule to `build.txt` Traceability section forbidding self-invented task ID suffixes, prefixes, or variants (`t2213b`, `t2213-2`, `t2213.fix`, `t2213-followup`). Optionally add a regex warning in `worktree-helper.sh add` when the branch name contains such a variant.

## Why

On 2026-04-18 I invented task ID `t2213b` for a follow-up phase after t2213 merged. Had to rename the branch from `feature/t2213b-cloudron-review-nits` to `feature/t2214-cloudron-review-nits` after `full-loop-helper.sh commit-and-pr --issue` required a real issue number. Wasted time creating and renaming a branch.

Current `build.txt` Traceability section explicitly forbids prefixes ("NEVER use 'qd-', bare numbers, or invented prefixes") but **not suffixes/variants**. An agent reasoning about "follow-up phase indicators" can plausibly invent `t2213b` thinking it's allowed.

The `t2047` commit-msg collision guard catches this only at commit time, by which point the agent has already created a branch and written files.

## How

### Layer 1 — `.agents/prompts/build.txt` (mandatory)

Search for the existing line "NEVER use 'qd-', bare numbers, or invented prefixes" in the Traceability section. Extend it:

**Before:**

> NEVER use `qd-`, bare numbers, or invented prefixes.

**After:**

> NEVER use `qd-`, bare numbers, or invented prefixes.
> NEVER invent suffixes or variants either — `t2213b`, `t2213-2`, `t2213.fix`, `t2213-followup` are all forbidden. Task IDs come EXCLUSIVELY from `claim-task-id.sh` output. For follow-up work on a merged task, claim a FRESH task ID via `claim-task-id.sh` — don't extend the old one.

### Layer 2 — `.agents/scripts/worktree-helper.sh add` (optional)

In the `add` subcommand, after branch name validation, add a regex check. File reference: search for the branch-prefix check (currently validates `feature/`, `bugfix/`, etc.).

```bash
# Detect self-invented task ID variants
if [[ "$branch" =~ t[0-9]+[a-z]|t[0-9]+[-._][0-9]+ ]]; then
    print_warning "Branch name contains a non-claimed task ID variant ($branch)."
    print_warning "Task IDs come ONLY from claim-task-id.sh. For follow-ups, claim a fresh ID."
    if [[ -t 0 ]]; then  # interactive
        read -rp "Continue with this branch name anyway? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
    fi
    # headless: warn only, don't block (could be legitimate in rare cases)
fi
```

### Files to modify

- EDIT: `.agents/prompts/build.txt` — Traceability section
- EDIT (optional): `.agents/scripts/worktree-helper.sh` — `add` subcommand

## Acceptance criteria

- [ ] `build.txt` Traceability section explicitly forbids suffixes/variants (Layer 1)
- [ ] Examples include `t2213b`, `t2213-2`, `t2213.fix`, `t2213-followup`
- [ ] Regression: valid patterns still pass (`t9999-descriptive-suffix` is fine; `t9999b` is not)
- [ ] Optional: `worktree-helper.sh add feature/t9999b-test` warns in interactive sessions

## Verification

```bash
# Layer 1 verification (manual agent test)
# Prompt a fresh agent: "I need to fix a nit after t9999 merged. What task ID do I use?"
# Agent should answer: "Claim a fresh ID via claim-task-id.sh, don't invent t9999b"

# Layer 2 verification (if implemented)
~/.aidevops/agents/scripts/worktree-helper.sh add feature/t9999b-test  # should warn
~/.aidevops/agents/scripts/worktree-helper.sh add feature/t9999-test   # should pass cleanly
~/.aidevops/agents/scripts/worktree-helper.sh add chore/t2228-lifecycle-retrospective  # pass
```

## Context

- Session: 2026-04-18, follow-up to t2213 (PR #19708 merged).
- Layer 2 is optional because prompt-level discipline (Layer 1) plus the existing t2047 commit-msg guard provides defence in depth. A regex warning is nice-to-have but not critical.
- Auto-dispatchable — deterministic text edit.

## Tier rationale

`tier:simple` — prompt text edit with exact insertion point and verbatim replacement text. Optional helper edit has a verbatim code block. Auto-dispatch.
