---
description: Highest-capability model for architecture decisions, novel problems, and complex multi-step reasoning
mode: subagent
model: anthropic/claude-opus-4-6
model-tier: opus
model-fallback: openai/gpt-5.4
fallback-chain:
  - anthropic/claude-opus-4-6
  - openai/gpt-5.4
  - anthropic/claude-sonnet-4-6
  - openrouter/anthropic/claude-opus-4-6
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: false
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Opus Tier Model

Highest-capability tier for tasks where stronger reasoning materially changes the outcome.

## Use For

- Architecture and system design decisions
- Novel problems with no established pattern
- Security audits requiring deep reasoning
- Multi-step plans with hard dependencies
- Trade-off analysis across many variables
- Evaluating other models' outputs

## Routing Rules

- Default to sonnet unless the task genuinely needs extra reasoning depth.
- Route routine implementation, code review, and docs → sonnet.
- Route very large context needs (100K+ tokens) → pro.

## Constraints

- Do not use for tasks solvable by sonnet — opus costs 5× more per output token.
- Do not use for simple classification or formatting — route to haiku.

## Model Details

| Field | Value |
|-------|-------|
| Provider | Anthropic |
| Default model | claude-opus-4-6 |
| Context | 1M tokens (800K auto-compact) |
| Max output | 64K tokens |
| Input cost | $5.00/1M tokens |
| Output cost | $25.00/1M tokens |
| Tier | opus (highest capability, highest cost) |

Opus 4.6 is the `tier:thinking` default AND the penultimate rung in the
cascade. If opus-4.6 fails its escalation threshold, the cascade adds the
`model:opus-4-7` label and re-dispatches on 4.7 before handing off to NMR.

## Opus 4.7 (escalation target + opt-in)

Available as `claude-opus-4-7` (released 2026-04-16). Two paths route to it:

1. **Auto-cascade (failure-driven):** when a `tier:thinking` task exhausts
   its retries at opus-4.6, `escalate_issue_tier` in
   `worker-lifecycle-common.sh` adds the `model:opus-4-7` label. The next
   dispatch routes to 4.7 via `pulse-model-routing.sh`, which honours the
   label-override before tier resolution. If 4.7 also fails its threshold,
   the cascade terminates and the issue escalates to NMR (human review).
2. **Opt-in (intent-driven):** apply the `model:opus-4-7` label manually
   when you know up-front that 4.7 is the right tool for the task. The
   label takes precedence over any `tier:*` label, so it also works on
   a `tier:standard` issue if you want to jump straight to 4.7.

The framework registers 4.7 with a **250K context limit** (not the 1M API
ceiling) so OpenCode's 80% auto-compact threshold triggers at the 200K
reliability boundary — the point past which MRCR retrieval collapses.
Sessions get the full still-functional window before compaction kicks in,
instead of compacting prematurely at 160K (what an unaligned 200K cap
produces).

#### User override: `AIDEVOPS_OPUS_47_CONTEXT` (t2435)

The 250K cap is the right *default*, but it is not the right value for every
user. If you want to opt into a larger context (up to the 1M API ceiling),
set the env var before launching OpenCode/Claude Code:

```bash
# Use the full 1M API ceiling
export AIDEVOPS_OPUS_47_CONTEXT=1000000

# Or a custom value somewhere between
export AIDEVOPS_OPUS_47_CONTEXT=500000
```

Both the built-in `anthropic` provider (via the OAuth pool) and the
`claudecli` provider read this value via the shared `model-limits.mjs`
helper, so OpenCode's 80% auto-compact threshold moves with it
(e.g. 1000000 → ~800K compaction trigger).

**Validation:**

- Unset / empty / non-numeric / `<=0` → default 250000 (silent for unset/empty;
  warned at plugin init for invalid values).
- `> 1000000` → clamped to the 1M API ceiling, with a warning.
- Otherwise → the integer is used verbatim, with an MRCR-collapse warning at
  plugin init so the cost is visible in your logs.

**Tradeoffs you accept by overriding:**

- MRCR v2 8-needle retrieval drops from 91.9% (256K) → 59.2% (256K, 4.7) →
  32.2% (1M, 4.7). Your worker may "lose the plot" mid-session as the cold
  context grows beyond the reliability boundary.
- 4.7's tokenizer adds 20-60% to English token counts at identical pricing.
  A 1M-token session costs 1.2-1.6x what the same content would cost on 4.6.
- Default behaviour is unchanged for all other Claude models — the override
  is opus-4-7-only.

If you set this and find sessions degrading, unset the env var (or reduce
the value) and restart OpenCode. The cap exists for a reason; treat the
override as a calibrated experiment, not a free upgrade.

### When to apply `model:opus-4-7`

- **Short brief + high-reasoning task.** Architecture calls, security
  audits, novel algorithms where the input is well under 50K tokens. The
  MRCR regression doesn't apply and you get the SWE-Bench gains +
  `xhigh` effort level.
- **Long-running agentic work where coherence matters.** Multi-hour
  full-loop runs where the worker is building and maintaining state
  across many tool calls rather than reading large files cold. Agentic
  coherence is a different axis from cold retrieval; 4.7 is observably
  better here.
- **A task you've seen 4.6 thrash on.** Incoherent retries, losing
  the plot mid-session, re-dispatching without progress. Skip the next
  4.6 retry and go straight to 4.7.
- **Vision tasks on high-resolution images.** 4.7 supports up to 2576px
  on the long edge (~3.75MP) — more than 3× prior Claude models.
- **Tasks benefitting from the `xhigh` effort level.** This is a 4.7-only
  capability; 4.6 doesn't expose it.

### When NOT to apply `model:opus-4-7`

- **Briefs requiring >200K tokens of source material read cold.**
  Whole-repo audits, cross-file refactors with many large references.
  MRCR regression dominates; 4.6 retrieves more reliably. Stay on 4.6.
- **Routine implementation / bug fixes / refactors.** Sonnet is
  sufficient, opus-tier is overkill either way — 4.7 is not a
  sonnet-replacement.
- **CJK-heavy briefs.** The new tokenizer's English bloat (+58.8%) is
  the main driver of 4.7's cost delta; CJK tokenization is roughly
  flat (+4-6%) so the relative *cost* difference is smaller — but 4.7
  also brings no offsetting advantage on non-English, and the cold
  retrieval regression still applies.
- **Cost-sensitive batch work.** 20-60% tokenizer bloat on English
  prompts + identical per-token pricing = real $ impact at scale. A
  run of 100 small opus tasks is measurably more expensive on 4.7
  than 4.6.

### Tradeoffs vs 4.6 (data)

- **Long-context retrieval regression** (MRCR v2 8-needle, Anthropic's
  own system card §8.7.2):
  - 256K: 91.9% → 59.2% (−32.7 pts)
  - 1M: 78.3% → 32.2% (−46.1 pts)
  - This is a cold-retrieval benchmark: pre-load 256K or 1M of content,
    ask needle questions. It models "read a large file, answer a
    question about it" — NOT "build context incrementally through
    tool calls across a long session." Worker dispatches look more
    like the latter.
- **Tokenizer bloat** (new 4.7-only tokenizer):
  - English: +58.8% tokens vs 4.6 (135 vs 85 for identical prompt)
  - French: +34.0%, Python: +21.4%, mixed multilingual: +22.8%
  - CJK (Korean/Japanese/Chinese): +4-6%
  - At identical per-token pricing ($5/$25), this is a 20-60%
    effective cost increase on English-heavy prompts. Framework
    prompts and issue bodies are English-heavy, so this tax lands
    on most worker dispatches.
- **Stricter literal instruction-following**: prompts tuned for 4.6's
  looser interpretation may behave unexpectedly. Anthropic's migration
  guide acknowledges this explicitly. Our framework prompts were
  written against 4.6 — monitor for regressions specific to 4.7
  dispatches and tune prompts before routing more traffic there.

### Why auto-cascade and not replace 4.6

Two separate capability axes are in tension:

- **Cold retrieval over pre-loaded large context** — 4.6 wins
  (91.9% vs 59.2% at 256K, 78.3% vs 32.2% at 1M).
- **Agentic coherence in long tool-call sessions** — 4.7 wins
  in observed practice, at the cost of the tokenizer tax.

Making 4.7 the terminal cascade rung (above 4.6) lets the framework
exploit both: 4.6 handles the first retry (where prior-attempt context
is summarised into an escalation report, i.e. cold-retrieval territory),
and 4.7 handles the final retry (where the prior failures suggest a
coherence problem 4.6 struggled with). Promoting 4.7 to `tier:thinking`
default would forfeit 4.6's retrieval advantage on the common case.

### Migration guide

<https://platform.claude.com/docs/en/about-claude/models/migration-guide#migrating-to-claude-opus-4-7>
