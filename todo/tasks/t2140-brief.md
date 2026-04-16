---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2140: Register claude-opus-4-7 as opt-in model (defaults stay on 4.6)

## Origin

- **Created:** 2026-04-16
- **Session:** claude-code:interactive
- **Created by:** marcus (human)
- **Conversation context:** Anthropic released Opus 4.7 on 2026-04-16. User asked to add it as an option in the aidevops plugin, explicitly noting documented tradeoffs (Anthropic's own migration guide: 1.0-1.35x tokenizer expansion, more output tokens, stricter literal instruction-following) plus third-party data (MRCR v2 long-context collapse: 256K 91.9%->59.2%, 1M 78.3%->32.2%; English tokenizer +58.8% vs 4.6 on paragraph samples). Decision: register 4.7 so it's selectable but keep every default on 4.6 until we've validated it against the framework's agentic workloads.

## What

- Users can select `claude-opus-4-7` from the OpenCode model picker (both the `anthropic` built-in provider and the `claudecli` proxy provider).
- The model is registered in the `compare-models-helper.sh` MODEL_DATA registry with correct pricing ($5/$25) and a realistic context window (200K, not 1M — see tradeoffs below).
- `models-opus.md` documents an "Opus 4.7 (opt-in)" section with the three concrete regressions so users can make an informed choice.
- **No default tier mappings change.** `opus`, `coding`, and all fallback chains continue to route to `claude-opus-4-6`. Users who want to try 4.7 override via `custom/configs/model-routing-table.json`.

## Why

Anthropic shipped a new flagship. The framework needs to know the model exists so users can opt in, and so `compare-models` / registry sync / label helpers don't get out-of-sync when users select it. But the documented regressions make flipping the default premature:

- **Long-context retrieval collapse** (MRCR v2 8-needle, Anthropic's own system card): 4.7 drops from 91.9% to 59.2% at 256K and 78.3% to 32.2% at 1M. For any worker that ingests large context (full-loop, cross-file refactors, whole-repo audits), this is a functional regression.
- **Tokenizer bloat on Latin scripts**: English +58.8%, French +34%, Python code +21.4%, mixed multilingual +22.8%. At identical per-token pricing this is a 20-60% real cost increase on the framework's English-heavy prompts.
- **Stricter literal instruction-following**: existing prompts tuned for 4.6's looser interpretation may misbehave. The framework has 50+ headless dispatch scripts with prompts not specifically audited for literal-mode safety.

Registering at **200K context** (not the 1M API ceiling) is deliberate: the 1M window is functionally broken per MRCR, and the framework already has a `/compact` soft-prompt at 200K. Advertising 1M would route users into a dead zone.

## Tier

### Tier checklist

- [x] 2 or fewer files to modify? **No** — 4 files
- [x] Every target file under 500 lines? **No** — `compare-models-helper.sh` is 3400+ lines
- [x] Exact `oldString`/`newString` for every edit? **Yes** (provided below)
- [x] No judgment or design decisions? **Yes** — decisions made in this brief
- [x] No error handling or fallback logic to design? **Yes**
- [x] No cross-package or cross-module changes? **Yes** — all within `.agents/plugins/` and `.agents/scripts/` and `.agents/tools/ai-assistants/`
- [x] Estimate 1h or less? **Yes**
- [x] 4 or fewer acceptance criteria? **Yes** — 4

**Selected tier:** `tier:simple`

**Tier rationale:** Four files, all edits are exact oldString/newString additions of a new model entry following existing patterns (4-6 entries as models). `compare-models-helper.sh` is large but the edit is a single-line append to a readonly string and one case branch addition — both mechanical.

## PR Conventions

Leaf task, not a parent-task. PR body uses `Resolves #NNN`.

## How (Approach)

### Files to Modify

- EDIT: `.agents/plugins/opencode-aidevops/config-hook.mjs` — add `claude-opus-4-7` entry to `CLAUDE_MODEL_LIMITS` and both name maps
- EDIT: `.agents/plugins/opencode-aidevops/claude-proxy.mjs` — add `claude-opus-4-7` entry to `getClaudeProxyModels()`
- EDIT: `.agents/scripts/compare-models-helper.sh` — add entry to `MODEL_DATA` and `_api_model_string`
- EDIT: `.agents/tools/ai-assistants/models-opus.md` — add "Opus 4.7 (opt-in)" section

### Implementation Steps

1. **config-hook.mjs** — Add after the `claude-opus-4-6` line in `CLAUDE_MODEL_LIMITS`:
   ```js
   "claude-opus-4-7":   { context:  200000, output: 64000 },
   ```
   And to both `ANTHROPIC_MODELS` and `CLAUDECLI_MODELS` name maps:
   ```js
   "claude-opus-4-7":   "Claude Opus 4.7 (via aidevops)",
   "claude-opus-4-7":   "Claude Opus 4.7 (via CLI)",
   ```
   Context window intentionally capped at 200K, not 1M — see brief "Why" for MRCR data.

2. **claude-proxy.mjs** — Append to `getClaudeProxyModels()` array:
   ```js
   {
     id: "claude-opus-4-7",
     name: "Claude Opus 4.7 (via Claude CLI)",
     reasoning: true,
     contextWindow: 200000,
     maxTokens: 64000,
   },
   ```

3. **compare-models-helper.sh** — Add after the `claude-opus-4-6` line in `MODEL_DATA` (line 154):
   ```
   claude-opus-4-7|Anthropic|Claude Opus 4.7|200000|5.00|25.00|high|code,reasoning,architecture,vision,tools|Higher coding scores but long-context regression and +20-60% tokenizer cost vs 4.6 — opt-in only
   ```
   And to `_api_model_string` case branch (line 2497):
   ```bash
   claude-opus-4-7) echo "claude-opus-4-7" ;;
   ```
   (No dated suffix is documented yet; the short ID is the canonical form per the Anthropic blog.)

4. **models-opus.md** — Append new section after "Model Details" table:

   ```markdown
   ## Opus 4.7 (opt-in)

   Available as `claude-opus-4-7` in the OpenCode model picker. Not wired as the default
   for any tier — opt in explicitly via `custom/configs/model-routing-table.json`.

   ### Tradeoffs vs 4.6

   - **Long-context retrieval regression** (MRCR v2 8-needle, Anthropic system card):
     - 256K: 91.9% -> 59.2% (-32.7 pts)
     - 1M: 78.3% -> 32.2% (-46.1 pts)
     - Framework registers 4.7 at 200K context only to keep users inside the
       still-functional window. Do not use 4.7 for whole-repo or long-session work.
   - **Tokenizer bloat** (same paragraph, new tokenizer):
     - English: +58.8% tokens vs 4.6
     - French: +34%, Python: +21.4%, mixed multilingual: +22.8%
     - CJK: +4-6% (minor — old tokenizer was already inefficient there)
     - At identical per-token pricing this is a 20-60% effective cost increase on
       English-heavy prompts.
   - **Stricter literal instruction-following**: prompts tuned for 4.6's looser
     interpretation may behave unexpectedly. Re-tune prompts before using 4.7 for
     agentic workloads.

   ### When 4.7 may be worth it

   - Short-context, well-structured one-shot coding tasks (strong SWE-Bench gains)
     where the regressions above don't apply.
   - Tasks that benefit from the new `xhigh` effort level.
   - Vision work on high-resolution images (4.7 supports up to 2576px on long edge).
   ```

### Verification

1. `jq '.[]' /dev/null < .agents/configs/model-routing-table.json && bash -n .agents/scripts/compare-models-helper.sh` — syntax clean
2. `.agents/scripts/compare-models-helper.sh list | grep -c "claude-opus-4-7"` — returns 1
3. `grep -c "claude-opus-4-7" .agents/plugins/opencode-aidevops/config-hook.mjs` — returns 3 (limits + 2 name maps)
4. `grep -c "claude-opus-4-6" .agents/configs/model-routing-table.json` — returns 2 (opus + coding tiers, unchanged — confirms defaults were NOT flipped)
5. `shellcheck .agents/scripts/compare-models-helper.sh` — no new violations

## Acceptance Criteria

- [ ] `claude-opus-4-7` appears in OpenCode's model picker via both `anthropic` and `claudecli` providers
- [ ] `compare-models-helper.sh list` shows the new model with $5/$25 pricing and 200K context
- [ ] `model-routing-table.json` and all other tier mappings still point to `claude-opus-4-6` (defaults unchanged)
- [ ] `models-opus.md` documents the three tradeoffs with concrete numbers

## Context

- Anthropic announcement: <https://www.anthropic.com/news/claude-opus-4-7>
- Migration guide tradeoffs: tokenizer 1.0-1.35x expansion, stricter instructions
- MRCR v2 data: Anthropic system card section 8.7.2 (user-supplied screenshot)
- Tokenizer comparison: third-party analysis of paragraph-level token counts (user-supplied screenshot)
