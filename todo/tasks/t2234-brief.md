<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2234: brief-template.md — document planning-PR title collision risk (t2219)

## Origin

- **Created:** 2026-04-18
- **Session:** Claude Code interactive session (continuation of t2225/t2227 filing session)
- **Created by:** ai-interactive (Marcus Quinn driving)
- **Conversation context:** The `templates/brief-template.md` "PR Conventions" section documents the t2046 parent-task `For/Ref` keyword rule but does not warn about a known non-parent-task pitfall: planning PRs whose title leads with a `tNNN:` that matches any `For/Ref`-referenced issue's title prefix will have `status:done` falsely applied to that issue via the `issue-sync.yml` title-fallback bug (t2219). This bug fired twice in the 2026-04-18 sessions (PR #19701 → #19692; PR #19724 → #19718). Until t2219 ships, agents composing planning PRs need explicit warning so they check post-merge state.

## What

Edit `.agents/templates/brief-template.md` "PR Conventions" section (around lines 53-71) to add a short note below the existing parent-task `For/Ref` documentation explaining the t2219 collision risk and the post-merge workaround. Wrap the note in an HTML comment TODO marker (`<!-- TODO(t2219): delete this note once t2219 merges -->`) for easy future cleanup.

## Why

- **Every `/new-task`, `/define`, and brief-writing agent reads this template.** Adding the warning here is the highest-leverage spot for awareness — it's literally the place agents look when composing a PR body.
- **Two reproductions in one day.** The failure mode is deterministic (title-prefix match + `For/Ref`-only body = false `status:done`). Agents that don't know about it will keep hitting it until t2219 ships.
- **Pairs with t2225 (post-merge helper) and t2227 (AGENTS.md).** All three together address: prevent (this), automate (t2225), and reference (t2227) — full coverage of the known gap.
- **Deletable when t2219 merges.** HTML-comment TODO marker makes retirement trivial.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** (1 file)
- [x] **Every target file under 500 lines?** (brief-template.md is 267 lines; edit is to one specific section)
- [x] **Exact `oldString`/`newString` for every edit?** (yes — see Implementation Steps)
- [x] **No judgment or design decisions?** (note wording provided verbatim)
- [x] **No error handling or fallback logic to design?** (doc change only)
- [x] **No cross-package or cross-module changes?** (one file)
- [x] **Estimate 1h or less?** (~5 min)
- [x] **4 or fewer acceptance criteria?** (3)

**Selected tier:** `tier:simple`

**Tier rationale:** Single-file doc edit with verbatim oldString/newString and explicit insertion point. Pure append within an existing HTML comment block.

## PR Conventions

Leaf (non-parent) issue. PR body MUST use `Resolves #19741`.

## Files to Modify

- `EDIT: .agents/templates/brief-template.md` — append planning-PR collision note to the existing t2046 `PR KEYWORD RULE` comment block (around lines 55-68)

## Implementation Steps

### Step 1: Locate the exact insertion point

The existing HTML comment block ends with:

```markdown
     Leaf (non-parent) issue PRs: use `Resolves #NNN` or `Closes #NNN` as normal. -->
```

Insert the new block immediately AFTER that line (still within the `_Conventions_` section, but outside the existing HTML comment — so it becomes a second comment block sitting directly below the first).

### Step 2: Add the planning-PR collision warning

**oldString:**

```markdown
     Leaf (non-parent) issue PRs: use `Resolves #NNN` or `Closes #NNN` as normal. -->

{If this task is for a `parent-task`-labeled issue, confirm: PR body will use `For #NNN`, not `Resolves`.}
{If leaf task: use `Resolves #NNN` as normal — delete this section or leave it blank.}
```

**newString:**

```markdown
     Leaf (non-parent) issue PRs: use `Resolves #NNN` or `Closes #NNN` as normal. -->

<!-- TODO(t2219): delete this comment block once t2219 (GH#19719) merges.

     **Planning PR title-collision warning (active until t2219 ships).**

     If this task spawns a PR that (a) references future-work issues via
     `For #NNN` or `Ref #NNN` (not `Closes/Fixes/Resolves`) AND (b) has a
     title starting with a `tNNN:` that matches any of those referenced
     issues' title prefixes, the `issue-sync.yml::sync-on-pr-merge`
     title-fallback at lines 412-414 will apply `status:done` to the
     matching issue on merge — a false positive. The t2137 carve-out
     only protects `parent-task` issues; normal `tier:standard`/`simple`
     issues are vulnerable.

     Reproductions: PR #19701 (title `t2206:`) falsely closed #19692
     (title `t2206:`); PR #19724 (title `t2218:`) falsely closed #19718
     (title `t2218:`).

     **Workaround:** after merging such a PR, run
     `interactive-session-helper.sh post-merge <PR>` (t2225) which heals
     this automatically. If t2225 has not landed yet, manually:
     `gh issue edit <N> --repo <slug> --remove-label status:done --add-label status:available`. -->

{If this task is for a `parent-task`-labeled issue, confirm: PR body will use `For #NNN`, not `Resolves`.}
{If leaf task: use `Resolves #NNN` as normal — delete this section or leave it blank.}
```

### Step 3: Confirm rendering

Both HTML comment blocks are rendered as hidden commentary in most markdown previewers; agents reading the template directly will see them as inline guidance. Verify with a markdown renderer of your choice.

## Verification

```bash
# 1. Grep confirms the warning is present
grep -q 'Planning PR title-collision warning' .agents/templates/brief-template.md && echo "PASS: warning present"

# 2. Grep confirms the TODO marker is present
grep -q 'TODO(t2219)' .agents/templates/brief-template.md && echo "PASS: TODO marker present"

# 3. markdownlint passes
markdownlint-cli2 .agents/templates/brief-template.md 2>&1 | grep -v 'Summary:' || echo "PASS: no new lint violations"
```

## Acceptance Criteria

- [ ] Planning-PR title-collision warning added as a new HTML comment block below the existing t2046 keyword rule block
- [ ] Inline `<!-- TODO(t2219): ... -->` marker placed so future cleanup is obvious
- [ ] `markdownlint-cli2` clean (no new violations introduced)

## Context & Decisions

- **Why a new HTML comment block instead of extending the existing one?** Semantic separation: the existing block is about the t2046 parent-task rule (evergreen); this block is about a transient bug workaround (deletable when t2219 ships). Mixing them would force a future agent to carefully untangle the deletable parts from the permanent parts.

- **Why cite both the t2225 helper and the manual workaround?** The helper is a tier:standard fix that may or may not have shipped when a given agent reads this. Providing both fallbacks means the template stays correct regardless of merge ordering.

- **Why include the two historical reproductions?** The bug sounds abstract; concrete PR numbers make it tangible and quickly grep-able in git log when an agent is checking whether a given pattern applies to their situation.

- **Why `auto-dispatch` on this task?** Fully specified, trivial implementation, verbatim oldString/newString provided. Exactly the pattern that workers handle well without judgment.

## Relevant files

- **Edit:** `.agents/templates/brief-template.md` — PR Conventions section, append after the existing t2046 HTML comment block (around lines 53-71)
- **Pattern source:** existing `<!-- TODO(tXXXX): ... -->` HTML comments scattered across `.agents/**/*.md`
- **Related bug:** t2219 (GH#19719) — the source fix this note points at
- **Related tasks:** t2225 (GH#19732 — post-merge helper), t2227 (GH#19733 — AGENTS.md gap note)

## Dependencies

- **Soft dependency on t2225:** ideally t2225 lands first so the helper this note cites actually exists. If t2225 is delayed, the note's helper reference becomes aspirational but the manual workaround is valid immediately.
- **Independent of t2219:** this note describes the current state of t2219 being open; when t2219 merges, the whole comment block gets deleted.
