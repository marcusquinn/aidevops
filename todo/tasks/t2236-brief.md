<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2236: document `origin:interactive` auto-merge window and draft-PR strategy

**Session origin:** interactive (maintainer, Marcus Quinn)
**GitHub:** GH#19751
**Parent:** t2228 / GH#19734
**Tier:** tier:simple (docs edit)

## What

Clarify `.agents/AGENTS.md` so agents reading it understand the distinction between `pulse auto-close` (never on `origin:interactive`) and `pulse auto-merge` (frequent on `origin:interactive` + OWNER + green checks, within ~4-10 min of PR creation). Add three mitigation strategies for folding review-bot nits before auto-merge.

## Why

On 2026-04-18, PR #19708 (t2213) auto-merged ~4 min after creation. Gemini-code-assist review posted ~2 min after creation, leaving no practical window to fold its two nits into the original PR. I misread the existing AGENTS.md line:

> The pulse also never auto-closes `origin:interactive` PRs via the deterministic merge pass...

...as meaning "never auto-merges" — planned my iteration expecting indefinite time. Had to file a follow-up PR (#19715 t2214) for two-line cosmetic nits. Extra task ID, extra claim, extra CI run, extra ceremony.

Root cause: the existing text is correct but ambiguous. "Auto-close" and "auto-merge" are different pulse actions. An agent reading only the "never auto-closes" line plans as if it has indefinite time.

## How

### File to modify

- EDIT: `.agents/AGENTS.md` — section headed `origin:interactive implies maintainer approval` (or the analogous "origin:interactive" paragraph in the Git Workflow section)

### Insertion

After the existing paragraph about "The pulse also never auto-closes...", add:

> **Auto-merge timing**: PRs tagged `origin:interactive` from `OWNER`/`MEMBER` authors merge as soon as all required checks pass — typically 4-10 minutes depending on CI fleet. Review bots (gemini-code-assist, coderabbitai) post within ~1-3 minutes. If you need to fold bot nits into the same PR, use ONE of:
>
> - **Run `review-bot-gate-helper.sh check <PR>` before pushing** — streams current bot feedback. Push when ready.
> - **Open as draft** — `gh pr create --draft`, wait for bot reviews to settle, `gh pr ready <PR>` when content is final.
> - **Accept the window** — file a follow-up PR for nits (low-friction but adds a task ID and a merge cycle).
>
> The "pulse never auto-closes `origin:interactive` PRs" rule (above) applies to AUTO-CLOSE (abandoning stale incremental PRs on the same task ID), NOT to auto-merge of green PRs. These are separate pulse actions.

### Acceptance criteria

- [ ] AGENTS.md explicitly documents the ~4-10 min auto-merge window
- [ ] Three mitigation strategies listed: local gate check, draft PR, follow-up PR
- [ ] Distinction between auto-close and auto-merge is clear
- [ ] No regression — existing "origin:interactive skips maintainer gate" rule remains

## Verification

```bash
grep -n "Auto-merge timing" ~/.aidevops/agents/AGENTS.md  # should match new heading
grep -n "auto-close" ~/.aidevops/agents/AGENTS.md         # existing text still present
```

Manual: read the section end-to-end — should leave no ambiguity.

## Context

- Session: 2026-04-18, PR #19708 (t2213) auto-merged at 17:16:56Z, gemini review at 17:14:49Z. Window was ~2 min between review and merge.
- t2214 follow-up (#19715) merged at 17:41:13Z — same lifecycle, extra PR.
- The helper `review-bot-gate-helper.sh` already supports local `check <PR>` invocation; this docs edit just makes agents aware of it as a mitigation tool.
- Auto-dispatchable — pure docs edit with exact insertion location.

## Tier rationale

`tier:simple` — single-file docs edit. Verbatim insertion text provided. Auto-dispatch.
