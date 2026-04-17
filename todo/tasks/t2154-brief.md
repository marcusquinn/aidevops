<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2154: raise claude-opus-4-7 context cap to 250K to align with OpenCode 80% auto-compact threshold

## Origin

- **Created:** 2026-04-17
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Conversation context:** Discussed the existing 200K cap on `claude-opus-4-7` (added in t2140 / PR #19325 to keep users inside the still-reliable retrieval window). User pointed out OpenCode auto-compacts at 80% of the configured limit, so a 200K limit triggers compaction at 160K — wasting 40K of usable window. Setting the limit to 250K aligns the 80% trigger with the 200K reliability boundary.

## What

Raise the registered context limit for `claude-opus-4-7` from 200000 to 250000 in both registration paths (the OpenCode plugin's `CLAUDE_MODEL_LIMITS` map and the Claude CLI proxy model list), and update the `models-opus.md` "Opus 4.7 (opt-in)" section so the documented limit and the rationale match the new value.

After this change, an OpenCode session running on `claude-opus-4-7` will reach its 80% auto-compact trigger at 200K tokens (the reliability boundary established by Anthropic's MRCR v2 8-needle data), instead of triggering at 160K under the prior 200K cap.

## Why

The 200K cap chosen in t2140 was based on Anthropic's MRCR v2 retrieval data showing collapse past 200K (256K: 91.9% → 59.2%, 1M: 78.3% → 32.2%). That reasoning still holds — we still want to keep sessions inside the reliable window. What it didn't account for is that OpenCode's auto-compaction kicks in at 80% of the configured limit, not at the limit itself, so a 200K cap actually means "compact at 160K". That truncates 20% of the still-functional window before the model would degrade.

Sizing the cap to 250K shifts the 80% trigger to exactly 200K, so users get the full reliable window before compaction starts. The 1M API ceiling remains off-limits — the new cap is still well inside the regression cliff.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** — 2 code files + 1 doc file (3 total). Borderline; doc is a one-line change.
- [x] **Every target file under 500 lines?** — `config-hook.mjs` 331 lines, `claude-proxy.mjs` 394 lines, `models-opus.md` 89 lines. All well under.
- [x] **Exact `oldString`/`newString` for every edit?** — yes, see Implementation Steps below.
- [x] **No judgment or design decisions?** — value is fully determined (250K = 200K / 0.8).
- [x] **No error handling or fallback logic to design?**
- [x] **No cross-package or cross-module changes?** — single plugin + one doc.
- [x] **Estimate 1h or less?** — ~15m.
- [x] **4 or fewer acceptance criteria?**

**Selected tier:** `tier:simple`

**Tier rationale:** Pure value-and-comment swap with verbatim oldString/newString blocks; no logic, no design.

## How (Approach)

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/config-hook.mjs:45-49` — change `200000` to `250000` in the `CLAUDE_MODEL_LIMITS` entry for `claude-opus-4-7`, update the comment to explain the auto-compact alignment.
- `EDIT: .agents/plugins/opencode-aidevops/claude-proxy.mjs:115-124` — change `contextWindow: 200000` to `250000` in the `claude-opus-4-7` Claude CLI proxy model entry, update the comment.
- `EDIT: .agents/tools/ai-assistants/models-opus.md:66` — change "200K context limit" to "250K context limit" and add a sentence explaining the 80%/200K alignment.

### Implementation Steps

1. `config-hook.mjs` — replace block:

```js
  // Opus 4.7 context intentionally capped at 200K (not the 1M API ceiling).
  // Anthropic's own MRCR v2 8-needle data shows long-context retrieval collapse:
  // 256K drops 91.9% -> 59.2%, 1M drops 78.3% -> 32.2%. Users opting into 4.7
  // should stay inside the still-functional window. See models-opus.md "Opus 4.7 (opt-in)".
  "claude-opus-4-7":   { context:  200000, output: 64000 },
```

with:

```js
  // Opus 4.7 context capped at 250K (not the 1M API ceiling). Anthropic's own
  // MRCR v2 8-needle data shows long-context retrieval collapse past 200K
  // (256K: 91.9% -> 59.2%, 1M: 78.3% -> 32.2%). Setting the limit to 250K lets
  // OpenCode's 80% auto-compact threshold trigger right at the 200K reliability
  // boundary -- users get the full functional window before compaction kicks in,
  // instead of compacting at 160K (80% of a 200K cap). See models-opus.md.
  "claude-opus-4-7":   { context:  250000, output: 64000 },
```

2. `claude-proxy.mjs` — replace the `claude-opus-4-7` entry comment + `contextWindow` value with the same rationale.
3. `models-opus.md` — update the "200K context limit" sentence to "250K context limit" and append the auto-compact alignment note.

### Verification

```bash
# Both registration paths agree on 250000:
rg -n 'claude-opus-4-7' .agents/plugins/opencode-aidevops/config-hook.mjs .agents/plugins/opencode-aidevops/claude-proxy.mjs
# Doc reflects 250K:
rg -n '250K context limit' .agents/tools/ai-assistants/models-opus.md
# No stale 200000 left for opus-4-7:
rg -n 'claude-opus-4-7.*200000' .agents/
```

## Acceptance Criteria

- [ ] `CLAUDE_MODEL_LIMITS["claude-opus-4-7"].context === 250000` in `config-hook.mjs`.

  ```yaml
  verify:
    method: bash
    run: "rg -n 'claude-opus-4-7.*context.*250000' .agents/plugins/opencode-aidevops/config-hook.mjs > /dev/null"
  ```

- [ ] `claude-opus-4-7` entry in `claude-proxy.mjs` reports `contextWindow: 250000`.

  ```yaml
  verify:
    method: bash
    run: "rg -nU 'id:\\s*\"claude-opus-4-7\"[\\s\\S]{0,300}contextWindow:\\s*250000' .agents/plugins/opencode-aidevops/claude-proxy.mjs > /dev/null"
  ```

- [ ] `models-opus.md` documents the 250K limit + the 80% / 200K auto-compact alignment.

  ```yaml
  verify:
    method: codebase
    pattern: "250K context limit"
    path: ".agents/tools/ai-assistants/models-opus.md"
  ```

- [ ] No remaining `claude-opus-4-7` rows or entries pinned to `200000` anywhere under `.agents/`.

  ```yaml
  verify:
    method: bash
    run: "! rg -n 'claude-opus-4-7\\|.*\\|200000\\||\"claude-opus-4-7\":\\s*\\{\\s*context:\\s*200000|claude-opus-4-7[^|]*\\n[^\\n]*200000' .agents/"
  ```

## Context & Decisions

- **Why not 1M?** MRCR v2 8-needle retrieval at 1M is 32.2% on Opus 4.7. The 1M window is functionally broken for retrieval-style work (full-loop, cross-file refactors, whole-repo audits). Cap stays well inside the cliff.
- **Why exactly 250K?** 200K (reliability boundary) ÷ 0.8 (OpenCode auto-compact threshold) = 250K. Any larger cap and compaction starts after the model has already entered the regression zone.
- **Why update both registration paths?** `config-hook.mjs` registers `anthropic` + `claudecli` providers via the shared `CLAUDE_MODEL_LIMITS` map. `claude-proxy.mjs` separately seeds the Claude CLI proxy's own model list (different code path, same model). Both must agree or OpenCode's UI shows two different context limits depending on which provider is selected.
- **Non-goal:** revisiting the 4.6 / 4.5 / sonnet limits. Those have been validated separately and are out of scope.

## Relevant Files

- `.agents/plugins/opencode-aidevops/config-hook.mjs:39-50` — the `CLAUDE_MODEL_LIMITS` source-of-truth map.
- `.agents/plugins/opencode-aidevops/claude-proxy.mjs:115-124` — Claude CLI proxy model list entry for 4.7.
- `.agents/tools/ai-assistants/models-opus.md:62-89` — opus 4.7 doc section.
- PR #19325 (t2140) — original 4.7 registration with the 200K cap.

## Dependencies

- **Blocked by:** none.
- **Blocks:** none.
- **External:** none — pure config change.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | already done in the conversation |
| Implementation | 5m | three exact-string edits |
| Testing | 5m | grep verification |
| **Total** | **15m** | |
