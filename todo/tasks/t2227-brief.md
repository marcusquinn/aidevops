<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2227: AGENTS.md — correct t2157 auto-dispatch carve-out doc to note claim-task-id.sh gap

## Origin

- **Created:** 2026-04-18
- **Session:** Claude Code interactive session (continuation of t2225 filing session)
- **Created by:** ai-interactive (Marcus Quinn driving)
- **Conversation context:** Current AGENTS.md documents the t2157 rule as universal framework behaviour ("`#auto-dispatch` skips `origin:interactive` self-assignment") but t2157 was only implemented in `issue-sync-helper.sh`. The more common path for agents creating follow-up issues — `claim-task-id.sh` — does NOT honor the carve-out (bug tracked as t2218/GH#19718). A new agent reading AGENTS.md gets a false sense of protection and walks into the trap. This doc fix adds one explicit sentence pointing at the gap and the manual workaround until t2218 ships.

## What

Edit `.agents/AGENTS.md` "Auto-Dispatch and Completion" section (the paragraph starting with `**#auto-dispatch skips origin:interactive self-assignment (t2157)**:` around line 105) to append a one-sentence gap note. The sentence must:

1. State that the carve-out is currently only in `issue-sync-helper.sh`.
2. State that `claim-task-id.sh` does NOT honor it yet, and that this is tracked as t2218/GH#19718.
3. Point at the workaround: manual `gh issue edit --remove-assignee <user>` OR `interactive-session-helper.sh post-merge <PR>` (t2225) once that lands.
4. Include a TODO marker (`<!-- TODO(t2218): delete this sentence once t2218 merges -->` HTML comment) so the next agent touching this section knows to remove the note.

## Why

- **Prevents the next agent from hitting the same trap.** Session on 2026-04-18 created 5 `auto-dispatch` issues via `claim-task-id.sh` (#19692/#19693/#19694/#19718/#19719) and all 5 were self-assigned despite the `auto-dispatch` label. The fix was manual `gh issue edit`. A new agent reading AGENTS.md sees only the happy-path description and has no idea the gap exists.
- **Deletable when t2218 merges.** The HTML-comment TODO makes retirement trivial.
- **One-sentence cost.** Minimal context budget impact (<120 chars added to the AGENTS.md instruction budget).

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** (1 file)
- [x] **Every target file under 500 lines?** (AGENTS.md is long but the edit is to one specific paragraph — the edit itself is exact)
- [x] **Exact `oldString`/`newString` for every edit?** (yes — see Implementation Steps)
- [x] **No judgment or design decisions?** (sentence wording is provided verbatim)
- [x] **No error handling or fallback logic to design?** (doc change only)
- [x] **No cross-package or cross-module changes?** (one file)
- [x] **Estimate 1h or less?** (~5 min)
- [x] **4 or fewer acceptance criteria?** (3)

**Selected tier:** `tier:simple`

**Tier rationale:** Single-file doc edit with verbatim oldString/newString. Pure insertion into existing paragraph.

## PR Conventions

Leaf (non-parent) issue. PR body MUST use `Resolves #19733`.

## Files to Modify

- `EDIT: .agents/AGENTS.md` — append gap-note sentence to the `**#auto-dispatch skips origin:interactive self-assignment (t2157)**:` paragraph (around line 105)

## Implementation Steps

### Step 1: Locate the exact paragraph

The paragraph ends with the sentence `Regression test: \`.agents/scripts/tests/test-auto-dispatch-no-assign.sh\`.` Search for that string; the paragraph is unique.

### Step 2: Append the gap note before the regression test reference

**oldString:**

```markdown
**`#auto-dispatch` skips `origin:interactive` self-assignment (t2157)**: When `issue-sync-helper.sh` creates an issue from a TODO entry tagged `#auto-dispatch`, it does NOT self-assign the pusher even when the session origin is `interactive`. The `#auto-dispatch` tag signals "let a worker handle this" — self-assignment would create the `(origin:interactive + assigned + active status)` combo that GH#18352/t1996 treats as a permanent dispatch block, stranding the issue until manual `gh issue edit --remove-assignee` or the 24h `STAMPLESS_INTERACTIVE_AGE_THRESHOLD` safety net (t2148). An `[INFO]` log line is emitted when the skip fires. Regression test: `.agents/scripts/tests/test-auto-dispatch-no-assign.sh`.
```

**newString:**

```markdown
**`#auto-dispatch` skips `origin:interactive` self-assignment (t2157)**: When `issue-sync-helper.sh` creates an issue from a TODO entry tagged `#auto-dispatch`, it does NOT self-assign the pusher even when the session origin is `interactive`. The `#auto-dispatch` tag signals "let a worker handle this" — self-assignment would create the `(origin:interactive + assigned + active status)` combo that GH#18352/t1996 treats as a permanent dispatch block, stranding the issue until manual `gh issue edit --remove-assignee` or the 24h `STAMPLESS_INTERACTIVE_AGE_THRESHOLD` safety net (t2148). An `[INFO]` log line is emitted when the skip fires. <!-- TODO(t2218): delete the next sentence once t2218 merges --> **Gap pending t2218:** `claim-task-id.sh` (the more common path for agent-created follow-up issues) does NOT currently honor this carve-out — it self-assigns in `_auto_assign_issue` before the `_interactive_session_auto_claim_new_task` label check runs. Workaround until t2218 (GH#19718) lands: manual `gh issue edit <N> --repo <slug> --remove-assignee <user>` after any `claim-task-id.sh` invocation that creates an `auto-dispatch` issue, or run `interactive-session-helper.sh post-merge <PR>` (t2225) which automates this heal for all issues referenced in the just-merged PR. Regression test: `.agents/scripts/tests/test-auto-dispatch-no-assign.sh`.
```

### Step 3: Confirm rendering

The HTML comment `<!-- TODO(t2218): ... -->` is inline and will be stripped by most markdown renderers. Verify the paragraph still reads cleanly by opening the file in a preview (or `mdcat` / `glow`).

## Verification

```bash
# 1. Grep confirms the gap note is present
grep -q 'Gap pending t2218' .agents/AGENTS.md && echo "PASS: gap note present"

# 2. Grep confirms the TODO marker is present for future cleanup
grep -q 'TODO(t2218)' .agents/AGENTS.md && echo "PASS: TODO marker present"

# 3. markdownlint passes (if configured — should; this is appending a sentence)
markdownlint-cli2 .agents/AGENTS.md 2>&1 | grep -v 'Summary:' || echo "PASS: no new lint violations"
```

## Acceptance Criteria

- [ ] Gap-note sentence appended to the t2157 paragraph citing t2218 and the manual workaround
- [ ] Inline `<!-- TODO(t2218): ... -->` HTML comment placed so future cleanup is obvious
- [ ] `markdownlint-cli2` clean (no new violations introduced)

## Context & Decisions

- **Why extend the existing paragraph instead of a new subsection?** The gap is semantically part of the same rule; readers should see the full story in one place. A separate subsection would fragment the rule and risk being missed.

- **Why cite both the manual workaround AND the t2225 helper?** Dual fallback: the manual workaround works today; the helper works once t2225 merges. Citing both future-proofs the doc for the brief window where t2225 exists but hasn't been wired into common workflows yet.

- **Why an HTML comment for the TODO marker instead of a visible note?** Keeps the rendered Markdown clean while giving future agents a greppable signal. The pattern is borrowed from existing `<!-- t2XXX: ... -->` markers in AGENTS.md and build.txt (there are ~20 of them already).

- **No `auto-dispatch` on this task — remove it from the `--labels` arg?** Intentionally kept `auto-dispatch` because the task is fully specified and trivial; a worker can implement it. The gap-note sentence is verbatim in the brief. Worker just needs to paste it in.

## Relevant files

- **Edit:** `.agents/AGENTS.md` — the t2157 paragraph at approximately line 105
- **Pattern source:** existing `<!-- TODO(tXXXX): ... -->` HTML comments scattered in AGENTS.md and build.txt
- **Related bugs:** t2218 (GH#19718) — the source fix this note points at
- **Related task:** t2225 (GH#19732) — the post-merge helper this note cites as a workaround

## Dependencies

- **Soft dependency on t2225:** ideally t2225 lands first so the helper this note cites actually exists. If t2225 is delayed, the gap-note can still ship citing only the manual workaround; the `interactive-session-helper.sh post-merge` reference becomes aspirational but documents direction-of-travel.
- **Independent of t2218:** this note describes the current state of t2218 being open; when t2218 merges, this note is deleted. The ordering only matters for retirement (delete this when t2218 ships), not for creation.
