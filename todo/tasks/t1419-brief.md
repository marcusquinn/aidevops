<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1419: Contribution-watch — monitor external issues/PRs for new comments

## Origin

- **Created:** 2026-03-08
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human + ai-interactive)
- **Conversation context:** User received a comment on an opencode issue (#12472) and asked about systematically monitoring external repos where we've contributed issues/PRs. Discussion covered discovery, polling intervals, reply discipline, and prompt injection safety.

## What

A `contribution-watch` system that:
1. Auto-discovers all issues/PRs authored by or commented on by the authenticated GitHub user (resolved via `gh api user --jq '.login'`) across GitHub (using `gh api search/issues?q=commenter:{login}` and `author:{login}`)
2. Tracks external repos in `repos.json` with a `"contributed": true` type (distinct from `"pulse": true`)
3. Detects new comments on watched items since last check
4. Surfaces items needing attention — only when someone else commented after our last comment (not a "reply guy" — skip items where we have the last word)
5. Runs on an adaptive polling schedule (15min when hot, 1h default, 6h when dormant)

## Why

We have ~30 open items across ~15 external repos. Without monitoring, we miss responses to our feature requests, bug reports, and PRs — sometimes for weeks. The opencode #12472 comment that triggered this task sat for hours before we noticed it manually. Timely responses to maintainer feedback on our PRs/issues directly affects whether our contributions get merged.

## How (Approach)

### 1. `contribution-watch-helper.sh`

Core script with subcommands:
- `scan` — query GitHub search API for items with activity since `last_seen`
- `seed` — initial discovery of all external contributions, populate watch list
- `status` — show watched items and their state
- `install` / `uninstall` — launchd plist (`sh.aidevops.contribution-watch`)

State file: `~/.aidevops/cache/contribution-watch.json`
```json
{
  "last_scan": "ISO8601",
  "items": {
    "anomalyco/opencode#12472": {
      "type": "issue",
      "role": "commenter",
      "last_our_comment": "2026-03-08T...",
      "last_any_comment": "2026-03-08T...",
      "last_notified": "2026-03-08T...",
      "hot_until": "2026-03-09T..."
    }
  }
}
```

### 2. repos.json schema extension

```json
{
  "slug": "anomalyco/opencode",
  "contributed": true,
  "pulse": false,
  "path": null,
  "watch": {
    "issues": [12472, 14740, 13041, 7399, 5214, 16269],
    "prs": [14741, 16271, 7271]
  }
}
```

### 3. Adaptive polling

- Default: 1 hour
- Hot (activity < 24h): 15 minutes
- Dormant (no activity > 7 days): 6 hours
- Cost: ~30-50 GitHub API calls/day total (negligible)

### 4. Pulse integration

Add a lightweight step to pulse-wrapper.sh (or separate launchd job) that:
- Runs `contribution-watch-helper.sh scan`
- Outputs summary to pulse log: "3 external items need attention"
- Does NOT process comment bodies through LLM in the pulse context

### 5. Notification delivery

Two channels, both zero-cost:

**Terminal greeting** — `aidevops-update-check.sh` already runs on every interactive session start. When `contribution-watch.json` has items needing attention, append a line to the greeting: `"2 external contributions need your reply (run /contributions to see them)."` This is when you're already in a position to act.

**macOS notification** — the launchd scan job fires `osascript -e 'display notification "2 contributions need reply" with title "aidevops"'` when new items are detected. Catches time-sensitive replies between sessions (e.g., maintainer requesting changes on your PR).

Future options (not in scope for v1): email digest via email-agent, messaging bridge via matterbridge/Signal/Slack.

### 6. Prompt injection safety (CRITICAL)

Architecture principle: **the automated system with privileges never processes untrusted content through an LLM. The system that processes untrusted content never has write privileges without human approval.**

- The scanner is deterministic (timestamp comparison, authorship check) — no LLM involved
- Comment bodies are NEVER fed into the pulse agent context
- Responses happen only in interactive sessions where the user reviews content
- Comment bodies go through `prompt-guard-helper.sh scan` before any LLM processing
- If auto-response is ever added: sandboxed context, read-only token, human approval gate

## Acceptance Criteria

- [ ] `contribution-watch-helper.sh seed` discovers all external issues/PRs by the authenticated GitHub user (via `gh api user`)
  ```yaml
  verify:
    method: bash
    run: "contribution-watch-helper.sh seed --dry-run 2>&1 | grep -c '/' | xargs test 0 -lt"
  ```
- [ ] `contribution-watch-helper.sh scan` detects new comments since last check
- [ ] Items where we have the last word are excluded from "needs attention" output
- [ ] Adaptive polling: hot (15min), default (1h), dormant (6h) based on activity recency
- [ ] repos.json supports `"contributed": true` entries without `path` or `pulse`
- [ ] Pulse integration surfaces count of items needing attention without processing comment bodies
- [ ] Comment bodies are NEVER passed to LLM in automated/pulse context
- [ ] `prompt-guard-helper.sh scan` is called before any LLM processes external comment content in interactive sessions
- [ ] `contribution-watch-helper.sh install` creates launchd plist `sh.aidevops.contribution-watch`
- [ ] Terminal greeting shows contribution count when items need attention
- [ ] macOS notification fires on new items detected during launchd scan
- [ ] ShellCheck passes on all new scripts
- [ ] Lint clean

## Context & Decisions

- **Why not `pulse: true`?** The pulse merges PRs, dispatches workers, edits TODO.md — none of which applies to external repos. A distinct `contributed` type keeps the scope clean.
- **Why not auto-respond?** Prompt injection risk. External comments are untrusted content. Auto-responding would require the privileged pulse agent to process attacker-controlled text. The safe architecture is: detect (automated) → review (human) → respond (human-supervised).
- **Why adaptive polling?** Fixed intervals are either too frequent (wasteful for dormant items) or too slow (miss active conversations). The hot/default/dormant tiers match real conversation patterns.
- **Reply discipline:** Not every comment warrants a response. The scanner flags items for attention; the human decides whether to reply. "Don't be a reply guy" is a design principle, not just social advice.
- **Username resolution:** The seed command resolves the username dynamically from `gh api user --jq '.login'` — never hardcoded. This ensures it works for any aidevops user with `gh` authenticated.

## Relevant Files

- `~/.config/aidevops/repos.json` — schema extension for `contributed` type
- `~/.aidevops/agents/scripts/pulse-wrapper.sh` — integration point for scan step
- `~/.aidevops/agents/scripts/pulse.md` — pulse documentation
- `~/.aidevops/agents/tools/security/prompt-injection-defender.md` — injection defense patterns
- `~/.aidevops/agents/scripts/prompt-guard-helper.sh` — content scanning
- `~/.aidevops/cache/contribution-watch.json` — state file (new)

## Dependencies

- **Blocked by:** nothing
- **Blocks:** nothing immediately, but enables timely response to external contributions
- **External:** GitHub API (search endpoint, issue/PR comments endpoint)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Review repos.json schema, pulse integration points, prompt-guard |
| Implementation | 3h | contribution-watch-helper.sh, repos.json schema, pulse integration |
| Testing | 30m | seed, scan, adaptive polling, injection safety |
| **Total** | **4h** | |
