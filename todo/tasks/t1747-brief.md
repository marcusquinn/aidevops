<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1747: Results Tracking and Cross-Session Memory for Autoresearch

## Origin

- **Created:** 2026-04-01
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) + AI (interactive)
- **Parent task:** t1741
- **Conversation context:** Discussed how Hyperspace AGI's cross-pollination (agents adopt peers' discoveries) maps to aidevops's cross-session memory and the existing SQLite mailbox system. Each research session should start by recalling what worked before and checking peer discoveries, and end by storing what was learned. Concurrent agents share findings in real-time via mailbox `discovery` messages grouped by `convoy` ID.

## What

Implement structured experiment tracking (results.tsv), cross-session memory integration, and inter-agent discovery sharing so that:
1. Every experiment is logged with its hypothesis, metric, and outcome
2. Findings persist across sessions via the memory system
3. Future research sessions start by recalling relevant prior findings
4. Concurrent agents share discoveries in real-time via the mailbox system
5. All discoveries from one research campaign are grouped by convoy ID for review
6. Completion summaries are generated for PR bodies and human review

## Why

Without persistent tracking:
- The same failed hypotheses get retried across sessions (wasted tokens)
- Successful patterns aren't carried forward (missed compound learning)
- Humans can't review what was tried without reading git log
- PR descriptions are generic instead of showing the research journey

The Hyperspace model shows that cross-pollination (sharing discoveries between agents) accelerates convergence. In aidevops, two mechanisms serve this:
- **Cross-session memory** — findings persist between sessions (same role as Hyperspace's GitHub archive layer)
- **Mailbox discoveries** — concurrent agents share findings in real-time (same role as Hyperspace's GossipSub layer)

The mailbox system already has the right primitives: `discovery` message type, `convoy` thread grouping, agent registry. This task wires them into the autoresearch data flow.

## How (Approach)

### results.tsv format

```tsv
iteration	commit	metric_name	metric_value	baseline	delta	status	hypothesis	timestamp	tokens_used
1	a1b2c3d	build_time_s	12.4	12.4	0.0	baseline	establish baseline	2026-04-01T10:00:00Z	0
2	b2c3d4e	build_time_s	11.1	12.4	-1.3	keep	remove unused lodash import	2026-04-01T10:12:00Z	2340
3	c3d4e5f	build_time_s	12.8	12.4	+0.4	discard	switch to esbuild (breaks API)	2026-04-01T10:24:00Z	3100
4	-	build_time_s	0	12.4	-	crash	double worker threads (OOM)	2026-04-01T10:36:00Z	1800
5	d4e5f6g	build_time_s	10.5	12.4	-1.9	keep	tree-shake utils/ barrel exports	2026-04-01T10:48:00Z	2800
```

Fields:
- `iteration` — sequential experiment number
- `commit` — short hash (or `-` for crashes/discards)
- `metric_name` — from research program
- `metric_value` — measured value
- `baseline` — original baseline value
- `delta` — change from baseline (signed)
- `status` — `baseline`, `keep`, `discard`, `crash`, `constraint_fail`
- `hypothesis` — what was tried (one line)
- `timestamp` — ISO 8601
- `tokens_used` — approximate tokens consumed by this iteration

### Memory integration

**Storing (after each experiment):**
```
memory store --confidence high "autoresearch:{domain}: removing barrel exports from utils/ reduced build time by 1.9s (15% improvement). Hypothesis: tree-shaking can eliminate dead code when barrel re-exports are replaced with direct imports."
```

**Recalling (at session start):**
```
memory recall "autoresearch:{domain} what worked what failed"
```

The recall feeds into hypothesis generation — the researcher model reads prior findings before proposing new experiments.

### Memory content format

```
autoresearch:{domain}:{repo}: {finding}
- Status: keep|discard|crash
- Metric: {name} {before} → {after} ({delta})
- Hypothesis: {what was tried}
- Why it worked/failed: {brief analysis}
```

### Mailbox discovery integration

For concurrent multi-dimension research, agents share findings via the mailbox:

**Sending (after each keep/discard in the loop):**

```bash
mail-helper.sh send \
  --to "broadcast" \
  --type discovery \
  --payload '{"campaign":"autoresearch-widget-2026-04-01","dimension":"build-perf","hypothesis":"removed lodash","status":"keep","metric_name":"build_time_s","metric_before":12.4,"metric_after":11.1,"metric_delta":-1.3,"files_changed":["src/utils/index.ts"],"iteration":5}' \
  --convoy "autoresearch-widget-2026-04-01"
```

**Receiving (before each hypothesis generation):**

```bash
mail-helper.sh check --agent "autoresearch-{name}" --unread-only
# Parse discovery payloads → add to hypothesis context
mail-helper.sh read <message-id> --agent "autoresearch-{name}"
```

**Convoy review (after campaign completion):**

```bash
# All discoveries from one campaign, threaded
sqlite3 ~/.aidevops/.agent-workspace/mail/mailbox.db \
  "SELECT from_agent, payload FROM messages WHERE convoy='autoresearch-widget-2026-04-01' AND type='discovery' ORDER BY created_at"
```

The convoy groups all inter-agent messages from one research campaign for post-hoc review. Humans can see how agents influenced each other's hypotheses.

**When no peers exist:** Mailbox calls are no-ops. `check` returns empty, `send` still stores the discovery (queryable later if another session starts on the same campaign). Memory storage happens regardless.

### Completion summary

On loop exit, generate a summary for the PR body:

```markdown
## Autoresearch Results

**Research:** {program name}
**Duration:** 2h 14m (28 iterations)
**Baseline → Best:** 12.4s → 9.2s (-26%)

### Key Findings
1. Tree-shaking barrel exports: -1.9s (keep)
2. Removing lodash: -1.3s (keep)
3. Parallel compilation: -0.9s (keep)

### Failed Hypotheses
- esbuild migration: broke API contract
- Worker threads doubling: OOM at 16 workers
- Dynamic imports: no measurable difference

### Token Usage
Total: ~68,000 tokens across 28 iterations
Cost estimate: ~$0.34 (sonnet)
```

This summary goes into:
1. The PR description (for human review)
2. Cross-session memory (for future sessions)
3. The research program file (appended as a `## History` section)
4. Convoy thread in the mailbox (for multi-dimension campaign review)

For multi-dimension campaigns, the orchestrator generates a **cross-dimension summary**:

```markdown
### Cross-Dimension Summary

| Dimension | Baseline | Best | Delta | Iterations |
|---|---|---|---|---|
| build-perf | 12.4s | 9.2s | -26% | 28 |
| test-speed | 45s | 31s | -31% | 22 |
| bundle-size | 142KB | 98KB | -31% | 19 |

### Cross-Pollination
- build-perf removed lodash -> test-speed adopted via discovery (iteration 14)
- bundle-size found tree-shaking barrel exports -> build-perf confirmed independently
```

### Visualization (stretch goal)

ASCII sparkline in the PR body showing metric progression:

```
Metric: build_time_s (lower = better)
 12.4 ┤██████████████████████
 11.1 ┤████████████████
 10.5 ┤██████████████
  9.8 ┤████████████
  9.2 ┤██████████
       1  5  10  15  20  25  28
```

## Acceptance Criteria

- [ ] results.tsv written with all specified columns
  ```yaml
  verify:
    method: codebase
    pattern: "results.tsv|iteration.*commit.*metric"
    path: ".agents/tools/autoresearch/"
  ```
- [ ] Memory store called after each experiment with structured finding
  ```yaml
  verify:
    method: codebase
    pattern: "memory.*store|aidevops_memory.*store"
    path: ".agents/tools/autoresearch/"
  ```
- [ ] Memory recall called at session start to inform hypothesis generation
  ```yaml
  verify:
    method: codebase
    pattern: "memory.*recall|prior.*findings"
    path: ".agents/tools/autoresearch/"
  ```
- [ ] Completion summary generated with key findings and failed hypotheses
- [ ] Summary included in PR body
- [ ] Token usage tracked per iteration
- [ ] Mailbox discovery messages sent with correct convoy grouping
  ```yaml
  verify:
    method: codebase
    pattern: "convoy|discovery.*payload|mail-helper.*send"
    path: ".agents/tools/autoresearch/"
  ```
- [ ] Cross-dimension summary generated for multi-dimension campaigns
- [ ] Discovery payload includes: campaign, dimension, hypothesis, status, metric delta, files changed
- [ ] Lint clean

## Context & Decisions

- TSV over JSON for results: TSV is human-readable in terminal (`column -t`), diffable in git, and appendable (no trailing comma issues). JSON would be more structured but harder to read inline.
- Memory per-experiment (not just per-session): individual findings are more useful than session summaries. "Removing barrel exports helped" is actionable; "session ran 28 experiments" is not.
- Token tracking is approximate: exact token counting requires API response parsing which may not be available. Estimate from character count is acceptable.
- Sparkline is stretch goal: useful for visual humans but not required for the core loop.
- **Two-layer sharing**: mailbox for real-time inter-agent (concurrent peers), memory for cross-session (sequential sessions). Same discovery content format for both, different transport. This mirrors Hyperspace's GossipSub (real-time) + GitHub archive (durable) stack.
- **Convoy as campaign thread**: all mailbox messages from one research campaign share a convoy ID. This makes post-hoc review trivial — query by convoy to see the full inter-agent conversation.

## Relevant Files

- `~/.aidevops/.agent-workspace/memory/` — memory storage location
- `~/.aidevops/.agent-workspace/mail/mailbox.db` — SQLite mailbox for inter-agent discoveries
- `.agents/scripts/mail-helper.sh` — mailbox CLI (send, check, read, convoy query)
- `.agents/tools/autoresearch/autoresearch.md` — subagent that calls these functions (t1744)
- `.agents/reference/memory-lookup.md` — memory system reference

## Dependencies

- **Blocked by:** t1744 (results tracking is called by the loop runner)
- **Blocks:** nothing

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | Review memory system, PR creation patterns |
| TSV format design | 20m | Column definitions, edge cases |
| Memory integration | 30m | Store/recall format, domain tagging |
| Summary generation | 30m | Template, key findings extraction |
| Token tracking | 20m | Estimation method |
| Mailbox discovery format | 30m | Payload schema, convoy ID generation |
| Cross-dimension summary | 30m | Aggregation across dimension agents |
| **Total** | **~3h** | |
