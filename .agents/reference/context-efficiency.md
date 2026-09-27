<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Context efficiency without guidance loss

Optimise verified outcomes per resource budget, not cache percentage or prompt
length in isolation. Framework guidance is hard-won: preserve its meaning,
authority, safety constraints and availability. Load full domain instructions
when their trigger applies; never remove them merely to meet a token target.

## OpenCode loading contract

- `context-catalogue.mjs` lists generated aidevops command-skill wrappers
  (exact description `Run the aidevops X workflow when explicitly requested.`)
  once by name under one shared trigger; an OpenCode 2 `<id>` that differs from
  the name is kept inline. Full skill bodies, discovery and invocation permissions
  are unchanged. Specialist descriptions, custom triggers, extra metadata,
  non-standard locations and unknown formats stay verbatim. This is deterministic
  lossless factoring, not a keyword classifier deciding which guidance is shown.
- Only separately supplied `Instructions from:` system blocks with byte-identical
  bodies share an already loaded copy. Differing scoped instructions remain intact,
  including whitespace differences. Provenance and applicability remain explicit.
- OpenCode 1 Read reminders: `instruction-reminders.mjs` replaces a nearby
  instruction document in Read output only when its file bytes equal an
  instruction file already in the session system prompt (for example the repo
  `.agents/AGENTS.md` copy of the deployed guide). It runs once in
  `tool.execute.after`, before storage, so replayed history stays byte-stable;
  host `metadata.loaded` dedupe is untouched. OpenCode 2 publishes nearby
  instructions as a separate synthetic message and is not rewritten.
- The plugin session greeting is off by default in OpenCode 1 (the global
  AGENTS.md fallback greets) and on in OpenCode 2, whose isolated config home
  has no fallback and whose runtime version only the plugin knows.
  `AIDEVOPS_PLUGIN_SESSION_GREETING=1|0` forces it on or off. The block is
  appended after durable guidance for every provider with the
  root-session-only gate unchanged. The system
  transform mutates the host array in place so its blocks reach OpenCode 1 as
  well as OpenCode 2. Anthropic OAuth keeps the billing header and the exact
  Claude Code identity block in `system`; provider auth redistributes all other
  system text into the first user message.
- Anthropic OAuth `cch` signing targets the billing header's own placeholder via
  a random per-request sentinel, never the first placeholder in serialized
  `messages`, so quoted history cannot change the cached prefix. System text
  redistributed into the first user message keeps its `cache_control` marker
  within the four-breakpoint limit.
- Keep stable instruction/tool ordering. Do not add timestamps, per-request
  randomness, or quota state ahead of reusable guidance. Do not force cache
  retention parameters onto an OAuth endpoint without validating support.
- Successful verbose test/build receipts already use `output-compaction.mjs`.
  Do not discard failure diagnostics or blindly summarise source files. Read
  targeted ranges and load retained evidence when needed.

## Astra compaction

`registerAstraContextLimits` defaults to 240,000 usable input tokens, matching
GPT-5.6. `aidevops astra-context enable` persists that target and enables the
managed Astra cap. `aidevops astra-context disable` selects the extended 400,000
target, preserving an existing native-metadata opt-out. `status` reports
the selection and nonce-bound fresh-process plugin/config evidence; unavailable,
old or failed probes are not reported as applied. If automatic compaction is
disabled in OpenCode, status reports that separately.

With OpenCode's default 20,000-token reserve, 240K advertises input 260,000;
400K advertises input 420,000. Managed context also accommodates output.
An explicit `compaction.reserved` (including zero) is honoured without changing
the global setting. GPT-5.6 retains its separate ~240K target. These are operational
budgets, not provider capacity claims or measured subscription savings. Earlier
compaction may add summary overhead and lose information; judge total outcomes.

Set `runtime.opencode.astra_context_cap` to `false` in aidevops settings to leave
Astra metadata untouched; `enable` explicitly clears that opt-out. The target is
stored separately as `runtime.opencode.astra_compaction_target` and survives normal
updates. Restart OpenCode after changing the selection or deploying plugin changes.
The running process retains its original loaded plugin/config. Custom upstream
output-token ceilings can affect the default reserve; an explicit reserve makes
the arithmetic unambiguous. Compaction can occur slightly beyond the target due
to a completed response/tool step; do not issue synthetic 400K-token paid requests
merely to verify this arithmetic.

## GPT-6 Sol and Luna compaction

`gpt-6-sol`, `gpt-6-sol-fast`, `gpt-6-luna`, and `gpt-6-luna-fast` default to
a 240,000-token usable-input target. Explicit per-model context/input limits
take precedence unless `aidevops gpt6-context enable` forces the budget.
`disable` leaves native provider metadata untouched rather than restoring a
hard-coded snapshot. The saved `runtime.opencode.gpt6_context_cap` preference
survives normal updates; an unset preference uses the default without overriding
explicit per-model limits.

The managed input limit is the 240K target plus OpenCode's configured reserve;
managed context is input plus the model's explicit or native output limit.
Model options, reasoning variants, Fast service-tier options, and global
compaction settings are preserved. `status` validates nonce-bound fresh-process
health evidence for all four model IDs and reports disabled automatic compaction
separately. Restart OpenCode after changing the preference. Use the effective-
config probe instead of synthetic paid long-context requests.

## Default budget across resolved models

On the first request for each resolved model, the OpenCode 1 request hook applies
a 240K usable-input ceiling to models with larger native windows, including
built-in and newly discovered provider models absent from the config hook's model
list. Native Anthropic Opus 5.5+, Fable 5.1+, and Sonnet 5+ instead target 500K
usable input. Haiku 4.5 is capped at its 200K physical context and targets
180K usable input. When the output limit and compaction reserve require more
than 20K headroom, the effective trigger is earlier (for a 32K output limit,
no later than 168K before considering any extra reserve). The policy does not
expand smaller windows, modify output limits or variants, or override explicit
`provider.<name>.models.<id>.limit.context/input` entries.
Existing GPT-5.6, Astra, and GPT-6 opt-outs/extended-target selections are
respected. Native Anthropic Opus 4.7 retains a 200K usable-input reliability
target (or its explicit `AIDEVOPS_OPUS_47_CONTEXT` override). An explicit global
`compaction.auto=false` is respected. The limit is applied to the resolved
model used by OpenCode's subsequent overflow check; it
does not alter its model catalogue before the first request. A resumed session
may require one request to register the budget before it can compact; restart
OpenCode to load plugin changes. A completed response can exceed the budget.
This request-time cap is implemented by the OpenCode 1 plugin; OpenCode 2
uses a separate adapter and must be qualified independently before claiming
the same compaction threshold.

## Efficiency scorecard

Run `/report-token-use efficiency --since 7d` or the helper's `efficiency`
subcommand; add `--json` for the full evidence contract. It queries SQLite in
read-only mode and never rewrites historical costs. It includes reasoning,
median/p95 prompt sizes by model/effort, current-table repricing, historical price
versions, routing observation coverage and parent-plus-child session families.
Session output uses fingerprints rather than titles, paths or raw session IDs. When runtime objective events are available, the scorecard reports only aggregate outcomes joined through explicit unique request attachments; it does not allocate shared work or infer acceptance from a finished response.

Cache hits remain billable for many APIs. A smaller useful prompt may reduce the
hit percentage while saving money. API-equivalent estimates are not subscription
allowance measurements or invoices; long-context/service-tier uplifts are outside
the flat pricing table. Unknown prices and verified completion stay unavailable
until authoritative evidence exists. Do not label host termination as success.

Compare matched task classes with parent and child work included: accepted result,
repair/escalation, human intervention, elapsed time and consistently priced tokens.
Retain the previous route if cheaper calls create extra repair or lose required
guidance. Existing lean-delegation rules remain in `reference/agent-routing.md`.
