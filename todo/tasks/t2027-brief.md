---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2027: docs(pr-loop): add gate-failure playbook mapping reasons to user commands

## Origin

- **Created:** 2026-04-13
- **Session:** OpenCode:interactive (same session as t2015, t2018)
- **Created by:** marcusquinn (ai-interactive gap-closing pass after t2018)
- **Parent task:** none
- **Conversation context:** During the t2015 `/pr-loop` run I saw the required `Maintainer Review & Assignee Gate` check failing with "Issue #18429 has `needs-maintainer-review`". I then spent ~3 minutes reading `.github/workflows/maintainer-gate.yml` to figure out what command the user needed to run (`sudo aidevops approve issue N`). That information is already documented in `build.txt` and in the gate's own auto-posted comment on the PR, but the `/pr-loop` command doc doesn't close the loop from "I see failure reason X in the gate output" → "tell the user to run command Y". Every future LLM session driving a `/pr-loop` through a maintainer-gate failure will re-derive the same playbook. This task adds a small playbook table to the command doc so future sessions surface the fix path on iteration 1 instead of iteration 2-3.

## What

`.agents/scripts/commands/pr-loop.md` contains a "Gate Failure Playbook" section that maps each observable `Maintainer Review & Assignee Gate` failure reason to the corresponding user action. When a future LLM session runs `/pr-loop` and hits a gate failure, it reads the playbook instead of reading the workflow source.

Out of scope: changing gate behaviour, adding new gate reasons, editing the workflow file, or documenting other bot gates.

## Why

The `/pr-loop` command is the canonical loop for driving a PR to merge. When it hits a failure it should already know what to do, not re-derive the response. Four specific patterns show up in practice:

1. **`needs-maintainer-review` on linked issue** — requires `sudo aidevops approve issue N` from the user (cryptographic, cannot be bypassed by LLM).
2. **No assignee on linked issue** — requires `gh issue edit N --add-assignee USER`.
3. **`needs-maintainer-review` on the PR itself** — requires `sudo aidevops approve pr N` (external-contributor PRs).
4. **Title-based issue lookup failed** — requires either fixing the PR title to `tNNN: ...` format or explicitly linking the issue with `Closes #NNN`.

All four are observable from the gate comment body or the `gh pr checks` output. Mapping them to specific commands saves ~3 minutes per hit and removes a source of "LLM wandering" (reading workflow source to re-derive the fix path).

## Tier

### Tier checklist

- [x] **≤2 files to modify?** — 1 file: `.agents/scripts/commands/pr-loop.md`
- [x] **Complete content block for every edit?** — yes, full playbook table below
- [x] **No judgment or design decisions?** — mapping is mechanical; failure strings come from the workflow source verbatim
- [x] **No error handling or fallback logic to design?** — it's documentation
- [x] **≤1h estimate?** — ~15 minutes
- [x] **≤4 acceptance criteria?** — 3

**Selected tier:** `tier:simple`

## How

### Files to Modify

- `EDIT: .agents/scripts/commands/pr-loop.md` — insert a new "Gate Failure Playbook" section after the "Review Bot Gate (t1382)" section (line 48 area) and before "Completion Promises" (line 50).

### Content to add

Insert after `AI review verification rules: ...` line:

```markdown
### Gate Failure Playbook

When `Maintainer Review & Assignee Gate` fails, the `maintainer-gate` status-context description and the auto-posted gate comment on the PR say why. Map the reason to the fix path below — do not re-read `maintainer-gate.yml` to re-derive it.

| Failure reason (observable in gate output) | Fix path | Who runs it |
|---|---|---|
| `Issue #N has needs-maintainer-review label` | `sudo aidevops approve issue N` (cryptographic, posts signed comment, removes label) | **User only** — requires sudo + root-protected SSH key; LLM cannot forge |
| `Issue #N has no assignee` | `gh issue edit N --add-assignee USER` | LLM or user |
| `PR #N has needs-maintainer-review label` | `sudo aidevops approve pr N` | **User only** |
| `Title-based issue lookup failed` | Either fix PR title to `tNNN: ...` format or add `Closes #NNN` to PR body | LLM |

After user-only fixes, the required `Maintainer Review & Assignee Gate` CheckRun auto-refreshes via Job 3 of `maintainer-gate.yml` (t2018). Expect SUCCESS within ~20 seconds of the approval comment being posted; the PR becomes mergeable without manual `gh run rerun`.

If the required CheckRun does NOT refresh within ~60 seconds after an approval, fall back to manual: `gh run rerun <run_id> --failed` against the latest `Maintainer Gate` run for the PR's HEAD SHA.

**Hard rule:** NEVER remove `needs-maintainer-review` by direct `gh issue edit --remove-label`. The `protect-labels` job in `maintainer-gate.yml` re-applies it ~7 seconds later unless a `<!-- aidevops-signed-approval -->` comment exists on the issue. Removing the label without the signed comment is a guaranteed-to-fail path that wastes tool calls.
```

### Verification

```bash
grep -c "Gate Failure Playbook" .agents/scripts/commands/pr-loop.md  # expect: 1
grep -c "sudo aidevops approve issue N" .agents/scripts/commands/pr-loop.md  # expect: ≥1
markdownlint-cli2 .agents/scripts/commands/pr-loop.md 2>&1 | tail -5  # expect: no errors
```

## Acceptance Criteria

- [ ] `.agents/scripts/commands/pr-loop.md` contains a "Gate Failure Playbook" section with the 4-row table above.
  ```yaml
  verify:
    method: codebase
    pattern: "Gate Failure Playbook"
    path: ".agents/scripts/commands/pr-loop.md"
  ```
- [ ] The playbook includes the "never remove needs-maintainer-review directly" hard rule.
  ```yaml
  verify:
    method: codebase
    pattern: "NEVER remove .needs-maintainer-review. by direct"
    path: ".agents/scripts/commands/pr-loop.md"
  ```
- [ ] File passes markdownlint (same pass/fail as before the edit).
  ```yaml
  verify:
    method: bash
    run: "markdownlint-cli2 .agents/scripts/commands/pr-loop.md"
  ```

## Context & Decisions

- **Not using a separate playbook file.** The table fits in ~15 lines and is inline where LLM sessions already look when running `/pr-loop`. A separate `gate-failure-playbook.md` would require one more file-read from future sessions — the point is to eliminate wandering, not add layers.
- **Why all four cases.** I've only personally hit the `needs-maintainer-review` case this session, but the other three are observable in `maintainer-gate.yml:141, 261, 286` as distinct failure strings. Including them now costs ~5 extra lines and prevents future wandering on cases I haven't personally hit yet.
- **Why flag the "never remove directly" rule.** I tried to remove `needs-maintainer-review` earlier in this session (before reading build.txt carefully), watched `protect-labels` re-add it 7 seconds later, and wasted ~30 seconds of tool calls. The rule IS documented in `build.txt` but the signal is weak because it's buried in the security section. Surfacing it in the playbook where the LLM is already looking is a UX fix.
- **Non-goals:** generating the playbook programmatically from the workflow source (possible but >>15 minutes, not the scope here).

## Relevant Files

- `.agents/scripts/commands/pr-loop.md:1-82` — the file to edit.
- `.github/workflows/maintainer-gate.yml:92, 141, 261, 286` — source of the failure-reason strings.
- `.agents/prompts/build.txt` "Cryptographic issue/PR approval" — canonical rule this playbook surfaces.

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing (pure docs improvement)
- **External:** none

## Estimate Breakdown

| Phase | Time |
|-------|------|
| Write brief | (done) |
| Implementation | 5m |
| Lint + verify | 5m |
| Commit + PR + /pr-loop | ~20m incl. CI |
| **Total** | **~15m hands-on + ~20m CI wait** |
