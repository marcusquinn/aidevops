<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Diagnostics Discipline

Source: extracted from `.agents/AGENTS.md` Framework Rules (Phase 1 of #22616 — progressive-disclosure decomposition). Read this file before publishing any incident attribution, runtime-debug claim, or productivity-level statement about the pulse / workers / dispatch system. The four rules below — t2036, t2204, t3215, t3222 — all fire at the **diagnosis-publish step** and all demand evidence-then-claim.

When to load:

- Incident triage (a worker died, a PR didn't merge, dispatch looks stuck).
- Runtime debugging rooted in logs, artifacts, or deployed-script behaviour.
- Answering productivity questions ("is the pulse working?", "are workers running?", "did we ship anything today?").
- Drafting any public comment that blames a specific task ID, issue number, PR, or commit.

For prompt-economy reasons these rules live here rather than in always-on AGENTS.md context. The pointer in AGENTS.md (`### Diagnostics discipline`) names all four task IDs so a `grep` for any of them in AGENTS.md still hits a forwarding address.

## Stale-symptom investigations (runtime debugging, t2036)

The deployed copy at `~/.aidevops/agents/scripts/FILE` may differ from source at `~/Git/aidevops/.agents/scripts/FILE`. Pulse executes the deployed copy — reading source-as-truth when debugging runtime symptoms wastes hours.

- Before publishing runtime attribution, run `attribution-check-helper.sh --file .agents/scripts/FILE [--symbol fn] [--claim tNNN]` and use its evidence to distinguish deployed state from source hypotheses.
- When symptom timestamps in logs predate the deployed file mtime, the symptom is historical — it reflects pre-deploy behaviour. Verify the symptom still reproduces against the current deploy before filing an investigation issue.
- Scope: source-only debugging is fine for design, refactoring, and new code. This rule applies to runtime diagnostics rooted in logs/artifacts.
- Related: "Pre-implementation discovery (t2046)" — complementary rule for checking git log before WRITING new code. Both check "is the world what I think it is?"; this one fires during investigation, t2046 fires before implementation.

## Attribution before verification (t2204 — MANDATORY before publishing blame)

When an incident appears to match a bug in TODO.md or recent commits, READ the cited function body before publishing attribution. Symptom-level pattern match is a hypothesis. Published wrong attribution creates noise and trains future sessions to trust pattern-matching over code-reading. (Canonical failure: t2190/t2108.)

- "This looks like tNNN" is a hypothesis. It belongs in your notes.
- "This was caused by tNNN" is a diagnosis. It belongs in a public comment (`gh issue comment`, `gh pr comment`, issue close body, escalation report) ONLY after you have (a) located the cited function/line, (b) read the body, and (c) confirmed the actual behaviour matches your hypothesis.
- Internal drafting, TODO entries, and private notes can name suspected bugs freely — the rule fires at the publish step, not the hypothesis step.
- Scope: applies to attributions blaming a specific task ID, issue number, PR, or commit. Generic "this seems to be a pulse-merge edge case" is fine without code-level verification; "this is the t2108 bug" is not.
- Related: "Scientific reasoning" (hypothesis framing), "Claim discipline" (proof artifacts), "Stale-symptom investigations" (stale symptoms vs deployed file mtime). This rule sits alongside, not inside, any of them.

## Pulse activity verification (canonical sources, t3215)

When verifying whether workers are actually running, dispatching, or producing PRs — i.e. answering "is the pulse alive and productive?" — use the canonical outcome ledger, not file timestamps. File mtime tells you when something was *touched*; the canonical sources tell you the *outcome*. Confusing the two is a recurring misdiagnosis class (canonical failure: t3215, where a session reported "0 workers in 48h" from `worker-NNN.log` mtimes while canonical sources showed 28 successful workers and 49 PRs in the same window).

Start with `worker-activity-helper.sh summary [--since 1h|6h|24h|48h|7d] [--json] [--no-pr-check] [--repo OWNER/REPO]` for historical productivity. For “right now” questions, use `pulse-current-state-helper.sh --window 15m`.

NOT canonical sources:

- `worker-NNN.log` mtime (`ls -lt ~/.aidevops/logs/worker-*.log`) — file touch time, not outcome. A killed worker still leaves a recently-touched log.
- `pgrep -f "headless-runtime-helper.sh run"` — counts live processes, not productivity. A worker stuck in a 30-min watchdog stall counts the same as one shipping code.
- "Recent dispatch comments on issues" — only visible if dispatch reached the gh-write step; misses pre-flight rejections in the canonical counters.

Scope: applies before publishing any productivity-level claim ("workers aren't running", "dispatch is broken", "the pulse is dead", "we shipped N PRs today"). Internal hypotheses that lead to a canonical-source check are fine; published claims that skipped the check are not. This rule sits alongside t2204 (Attribution before verification) — both fire at the diagnosis-publish step, both demand evidence-then-claim.

## Productivity questions are current-state queries (t3222 — MANDATORY)

When the user asks any variant of "is the pulse working?" / "are workers running?" / "is real work happening now?" / "why so many failed-looking comments?" — answer from a **5-15 minute window of current-state evidence**, never from 24h/48h historical aggregates. The act of the user asking is itself signal that real-time progress notifications are missing; presenting historical totals to defend a degraded present is misdirect.

Run `pulse-current-state-helper.sh --window 15m` before answering. It summarizes dispatch stages, worker terminal events, pulse counters, wrapper activity, and worker worktrees from a current evidence window.

For provider/model/account questions, use `worker-activity-helper.sh providers --since 1h` before reading raw logs. Do not run broad recursive searches over `~/.aidevops/logs` or OpenCode storage for routine diagnostics; use bounded helpers first, then inspect a named log only if the helper identifies a specific timeframe or failure class.

**Anti-patterns (forbidden answers to productivity questions):**

- "113 PRs merged in 48h, 87% rate" — historical, says nothing about now.
- "ps -eo shows 0 workers" as the sole signal — dispatch is **bursty**; a single `ps` instant lands between waves and lies. Always cross-reference with `dispatch-stages.tsv`.
- "Workers spawned, fixes will land" — `worker_spawn` is initiation, not success. Land = merged PR closing the linked issue. Track to merge before claiming completion.
- Listing aggregate failure-mode counts ("66 circuit-breaker trips in 48h") without checking whether they fired in the last 10 min.

This rule sits alongside t3215 (canonical sources) and t2204 (attribution before verification) — all three fire at the diagnosis-publish step, all three demand evidence-then-claim.
